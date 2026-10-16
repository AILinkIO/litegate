%% @doc 基于 lg_http_pool 的上游 HTTP 客户端。
%%
%% - request/5：同步请求，读完整个响应体
%% - stream_open/5 + stream_recv/2 + stream_close/1：拉取式流读取，
%%   由调用方（cowboy 处理进程）控制节奏，边读边写回客户端
%%
%% 非 2xx 响应总是读完响应体后以 {http_error, Status, Headers, Body} 返回，保留错误详情。
%% request/6 带 api => true 时（发往大模型 API 的请求），2xx 但不是 API 回复（HTML 页面、空体）以
%% {not_api_reply, Body} 返回（如 Cloudflare 验证页、登录页）；告警 webhook 等普通请求不做此检查。
%% 流式请求收到 2xx 的 JSON 响应（上游不支持流式或以 200 返回业务错误）时读完响应体，以 {json, ...} 返回。
%% 空闲池里取出的连接若在收到响应前就断开，自动换新连接重试一次。
%%
%% 等待回调（Opts 的 idle）：等待响应头或下一块数据时每 tick 毫秒（默认 1000）调用一次，
%% 供网关在上游迟迟不回复时向客户端写保活帧；回调在调用进程中执行。
-module(lg_http).

-export([request/5, request/6, stream_open/5, stream_open/6, stream_recv/2, stream_recv/3, stream_close/1]).

-type headers() :: [{binary(), iodata()}].
%% 句柄两种形态：连接句柄（可带 fin/body 标记已结束/未声明 content-type 的预读体）
%% 与已结束句柄（json_reply 合成的 #{fin => true}，只允许 stream_recv 取缓冲体）。
-type stream() :: #{conn := pid(), ref := reference(), fin => boolean(), body => binary()}
                | #{fin := true, body => binary()}.
-type error() :: {http_error, pos_integer(), headers(), binary()}
               | {not_api_reply, binary()}
               | {connect_failed, term()}
               | {request_failed, term()}
               | timeout.
-export_type([stream/0, error/0, headers/0]).

%%====================================================================
%% API
%%====================================================================

-spec request(binary(), binary(), headers(), iodata(), timeout()) ->
          {ok, pos_integer(), headers(), binary()} | {error, error()}.
request(Method, Url, Headers, Body, Timeout) ->
    request(Method, Url, Headers, Body, Timeout, #{}).

-spec request(binary(), binary(), headers(), iodata(), timeout(), map()) ->
          {ok, pos_integer(), headers(), binary()} | {error, error()}.
request(Method, Url, Headers, Body, Timeout, Opts) ->
    with_retry(Url, fun(Conn) ->
        Ref = send(Conn, Method, Url, Headers, Body),
        case await_response(Conn, Ref, Timeout, Opts) of
            {response, fin, Status, RespHeaders} ->
                api_check(done(Conn, Status, RespHeaders, <<>>), Opts);
            {response, nofin, Status, RespHeaders} ->
                case gun:await_body(Conn, Ref, Timeout) of
                    {ok, RespBody} -> api_check(done(Conn, Status, RespHeaders, RespBody), Opts);
                    {error, Reason} -> fail(Conn, Ref, Reason, true)
                end;
            {error, Reason} ->
                fail(Conn, Ref, Reason, false)
        end
    end).

%% @doc 发起流式请求，等到 2xx 响应头后返回流句柄。
-spec stream_open(binary(), binary(), headers(), iodata(), timeout()) ->
          {ok, pos_integer(), headers(), stream()} | {json, pos_integer(), headers(), binary()} | {error, error()}.
stream_open(Method, Url, Headers, Body, Timeout) ->
    stream_open(Method, Url, Headers, Body, Timeout, #{}).

-spec stream_open(binary(), binary(), headers(), iodata(), timeout(), map()) ->
          {ok, pos_integer(), headers(), stream()} | {json, pos_integer(), headers(), binary()} | {error, error()}.
stream_open(Method, Url, Headers, Body, Timeout, Opts) ->
    with_retry(Url, fun(Conn) ->
        Ref = send(Conn, Method, Url, Headers, Body),
        case await_response(Conn, Ref, Timeout, Opts) of
            {response, nofin, Status, RespHeaders} when Status >= 200, Status < 300 ->
                case content_type(RespHeaders) of
                    event_stream ->
                        {ok, Status, RespHeaders, #{conn => Conn, ref => Ref}};
                    Other ->
                        %% 不是 SSE：读完响应体再判断（HTML → 非 API 回复；JSON → 交给调用方）
                        case gun:await_body(Conn, Ref, Timeout) of
                            {ok, RespBody} ->
                                lg_http_pool:checkin(Conn),
                                case Other =:= json andalso not html_like(RespBody) of
                                    true -> {json, Status, RespHeaders, RespBody};
                                    false when Other =:= html -> {error, {not_api_reply, RespBody}};
                                    false ->
                                        case html_like(RespBody) of
                                            true -> {error, {not_api_reply, RespBody}};
                                            %% 未声明类型的 SSE（部分上游不带 content-type）：按 SSE 处理
                                            false -> {ok, Status, RespHeaders, #{conn => Conn, ref => Ref, fin => true,
                                                                                body => RespBody}}
                                        end
                                end;
                            {error, Reason} ->
                                fail(Conn, Ref, Reason, true)
                        end
                end;
            {response, fin, Status, RespHeaders} when Status >= 200, Status < 300 ->
                %% 空流：返回一个已结束的句柄
                lg_http_pool:checkin(Conn),
                {ok, Status, RespHeaders, #{conn => Conn, ref => Ref, fin => true}};
            {response, fin, Status, RespHeaders} ->
                done(Conn, Status, RespHeaders, <<>>);
            {response, nofin, Status, RespHeaders} ->
                case gun:await_body(Conn, Ref, Timeout) of
                    {ok, RespBody} -> done(Conn, Status, RespHeaders, RespBody);
                    {error, Reason} -> fail(Conn, Ref, Reason, true)
                end;
            {error, Reason} ->
                fail(Conn, Ref, Reason, false)
        end
    end).

%% @doc 读下一块数据。fin 表示流已结束（连接已归还）。
%%
%% 调用进程若 trap_exit，收到 'EXIT' 信号（如 cowboy 因客户端断开而结束请求进程）
%% 时立即返回 {exit, Reason}，由调用方中止上游流并记账，不必等上游下一块数据。
-spec stream_recv(stream(), timeout()) ->
          {data, binary(), stream()} | {fin, binary()} | {exit, term()} | {error, error()}.
stream_recv(S, Timeout) ->
    stream_recv(S, Timeout, #{}).

-spec stream_recv(stream(), timeout(), map()) ->
          {data, binary(), stream()} | {fin, binary()} | {exit, term()} | {error, error()}.
stream_recv(#{fin := true} = S, _Timeout, _Opts) ->
    {fin, maps:get(body, S, <<>>)};
stream_recv(#{conn := Conn, ref := Ref} = S, Timeout, Opts) ->
    MRef = monitor(process, Conn),
    Res = recv_loop(Conn, Ref, MRef, lg_time:now_ms() + Timeout, Opts),
    demonitor(MRef, [flush]),
    case Res of
        {data, D} ->
            {data, D, S};
        {fin, D} ->
            lg_http_pool:checkin(Conn),
            {fin, D};
        {exit, _} = Exit ->
            Exit;
        {error, R} ->
            fail(Conn, Ref, R, true)
    end.

recv_loop(Conn, Ref, MRef, Deadline, Opts) ->
    Wait = wait_ms(Deadline, Opts),
    receive
        {gun_data, Conn, Ref, nofin, Data} -> {data, Data};
        {gun_data, Conn, Ref, fin, Data} -> {fin, Data};
        {gun_trailers, Conn, Ref, _} -> {fin, <<>>};
        {gun_error, Conn, Ref, Reason} -> {error, Reason};
        {gun_error, Conn, Reason} -> {error, Reason};
        {'DOWN', MRef, process, Conn, Reason} -> {error, {down, Reason}};
        {'EXIT', _From, Reason} -> {exit, Reason}
    after Wait ->
        case lg_time:now_ms() >= Deadline of
            true -> {error, timeout};
            false -> idle(Opts), recv_loop(Conn, Ref, MRef, Deadline, Opts)
        end
    end.

%% 本次等待时长：有回调时每 tick 毫秒醒一次，否则等到截止
wait_ms(Deadline, Opts) ->
    Left = max(0, Deadline - lg_time:now_ms()),
    case maps:find(idle, Opts) of
        {ok, _} -> min(Left, maps:get(tick, Opts, 1000));
        error -> Left
    end.

idle(#{idle := F}) -> _ = catch F(), ok;
idle(_) -> ok.

%% @doc 提前结束流（客户端断开、出错等），连接直接丢弃。
-spec stream_close(stream()) -> ok.
stream_close(#{fin := true}) ->
    ok;
stream_close(#{conn := Conn, ref := Ref}) ->
    gun:flush(Ref),
    lg_http_pool:discard(Conn).

%%====================================================================
%% 内部函数
%%====================================================================

%% Fun 返回 {error, {retryable, Reason}} 表示连接在响应前失败，可换新连接重试
with_retry(Url, Fun) ->
    case lg_http_pool:checkout(Url) of
        {ok, Conn, Reused} ->
            case Fun(Conn) of
                {error, {retryable, _}} when Reused ->
                    case lg_http_pool:checkout_fresh(Url) of
                        {ok, Conn2, _} -> unwrap(Fun(Conn2));
                        {error, _} = Err -> Err
                    end;
                Other ->
                    unwrap(Other)
            end;
        {error, _} = Err ->
            Err
    end.

unwrap({error, {retryable, Reason}}) -> {error, {request_failed, Reason}};
unwrap(Other) -> Other.

send(Conn, Method, Url, Headers, Body) ->
    gun:request(Conn, Method, path(Url), with_user_agent(Headers), Body).

%% 补上默认 User-Agent（运行参数 user_agent）；调用方或凭证自定义头已带时不覆盖
-spec with_user_agent(headers()) -> headers().
with_user_agent(Headers) ->
    Has = lists:any(fun({K, _}) -> string:lowercase(iolist_to_binary(K)) =:= <<"user-agent">> end, Headers),
    case {Has, lg_config:get(user_agent)} of
        {false, UA} when is_binary(UA), UA =/= <<>> -> [{<<"user-agent">>, UA} | Headers];
        _ -> Headers
    end.

await_response(Conn, Ref, Timeout, Opts) ->
    await_loop(Conn, Ref, lg_time:now_ms() + Timeout, Opts).

await_loop(Conn, Ref, Deadline, Opts) ->
    case gun:await(Conn, Ref, wait_ms(Deadline, Opts)) of
        {inform, _, _} -> await_loop(Conn, Ref, Deadline, Opts);
        {error, timeout} = T ->
            case lg_time:now_ms() >= Deadline of
                true -> T;
                false -> idle(Opts), await_loop(Conn, Ref, Deadline, Opts)
            end;
        Other -> Other
    end.

done(Conn, Status, Headers, Body) when Status >= 200, Status < 300 ->
    lg_http_pool:checkin(Conn),
    {ok, Status, Headers, Body};
done(Conn, Status, Headers, Body) ->
    lg_http_pool:checkin(Conn),
    {error, {http_error, Status, Headers, Body}}.

%% GotResponse =:= false 且非超时：连接在响应前失败，可重试
fail(Conn, Ref, Reason, GotResponse) ->
    gun:flush(Ref),
    lg_http_pool:discard(Conn),
    case {Reason, GotResponse} of
        {timeout, _} -> {error, timeout};
        {_, false} -> {error, {retryable, Reason}};
        {_, true} -> {error, {request_failed, Reason}}
    end.

path(Url) ->
    #{path := P} = U = uri_string:parse(Url),
    Path = case P of <<>> -> <<"/">>; _ -> P end,
    case maps:get(query, U, <<>>) of
        <<>> -> Path;
        Q -> <<Path/binary, $?, Q/binary>>
    end.

api_check({ok, _, Headers, Body} = Ok, #{api := true}) ->
    case content_type(Headers) =:= html orelse html_like(Body) orelse Body =:= <<>> of
        true -> {error, {not_api_reply, Body}};
        false -> Ok
    end;
api_check(Res, _Opts) ->
    Res.

content_type(Headers) ->
    case lists:keyfind(<<"content-type">>, 1, Headers) of
        {_, V} ->
            L = string:lowercase(V),
            case {binary:match(L, <<"text/event-stream">>), binary:match(L, <<"json">>), binary:match(L, <<"text/html">>)} of
                {{_, _}, _, _} -> event_stream;
                {_, {_, _}, _} -> json;
                {_, _, {_, _}} -> html;
                _ -> other
            end;
        false ->
            other
    end.

%% 响应体看起来是网页（去掉前导空白后以 < 开头）
html_like(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t; C =:= $\r; C =:= $\n -> html_like(Rest);
html_like(<<"<", _/binary>>) -> true;
html_like(_) -> false.
