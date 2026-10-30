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
%% 空闲池里取出的连接若在收到响应前就断开，且可判定请求没被处理（gun 进程已不在，或发出后
%% ?RESEND_WINDOW_MS 内连接即被关闭——空闲连接恰好被对端关掉的竞态），自动换新连接重试一次；
%% 发出较久后才断开时上游可能已在处理，不重发（避免重复计费），以 request_failed 返回。
%%
%% 背压（T29）：流式请求以 gun flow 控制打开，窗口 ?FLOW 条 gun_data 消息；stream_recv 每取走一条
%% 补 1 个额度。调用方（cowboy 处理进程）在 cowboy_req:stream_body 里等 data_ack 时不再取数据，
%% gun 停止读 socket，背压经 TCP 传回上游，处理进程邮箱里的 gun_data 不超过窗口 + 1
%% （gun 补额度时可能多 arm 一次 socket，多读一个包）。窗口按消息计，每条为 gun 一次读 socket 的数据。
%%
%% 等待回调（Opts 的 idle）：等待响应头或下一块数据时每 tick 毫秒（默认 1000）调用一次，
%% 供网关在上游迟迟不回复时向客户端写保活帧；回调在调用进程中执行。
%%
%% 超时分级（超时与超限计入 litegate_upstream_timeouts_total{phase}）：
%%   first_byte  等响应头 / 流的首块数据，Timeout 参数（upstream_timeout_ms）
%%   idle        流已收到数据后块间空闲超过 stream_idle_timeout_ms（ping 注释帧也算数据）
%%   total       流开流后总时长超过 stream_max_ms；非流式读响应体超过请求截止（发出请求起 Timeout）
%%   too_large   非流式响应体累计超过 upstream_max_body_bytes，中止读取并丢弃连接
%%
%% 等待响应头时回调可抛出 {client_exit, Reason} 中止请求（上游流随即取消，见 await_idle/3）。
-module(lg_http).

-export([request/5, request/6, stream_open/5, stream_open/6, stream_recv/2, stream_recv/3, stream_close/1]).

-type headers() :: [{binary(), iodata()}].
%% 句柄两种形态：连接句柄（可带 fin/body 标记已结束/未声明 content-type 的预读体）
%% 与已结束句柄（json_reply 合成的 #{fin => true}，只允许 stream_recv 取缓冲体）。
%% started 为开流时刻（stream_max_ms 起点），active 表示已收到过数据（之后按 idle 超时）。
-type stream() :: #{conn := pid(), ref := reference(), url := binary(), fin => boolean(), body => binary(),
                    started => integer(), active => boolean()}
                | #{fin := true, body => binary()}.
-type phase() :: first_byte | idle | total.
-type error() :: {http_error, pos_integer(), headers(), binary()}
               | {not_api_reply, binary()}
               | {connect_failed, term()}
               | {request_failed, term()}
               | timeout                                %% 等响应头超时（first_byte）
               | {timeout, phase()}
               | {too_large, pos_integer()}.           %% 响应体超过上限（字节）
-export_type([stream/0, error/0, headers/0]).

-define(FLOW, 8).                 %% 流式响应的 gun flow 窗口（gun_data 消息条数）
-define(RESEND_WINDOW_MS, 50).    %% 复用连接发出后多久内断开仍视为请求未被处理

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
        SentAt = lg_time:now_ms(),
        Deadline = SentAt + Timeout,
        Ref = send(Conn, Method, Url, Headers, Body, #{}),
        case await_response(Conn, Ref, Timeout, Opts) of
            {response, fin, Status, RespHeaders} ->
                api_check(done(Conn, Url, Status, RespHeaders, <<>>), Opts);
            {response, nofin, Status, RespHeaders} ->
                case read_body(Conn, Ref, Deadline, Opts) of
                    {ok, RespBody} -> api_check(done(Conn, Url, Status, RespHeaders, RespBody), Opts);
                    {error, Reason} -> fail(Conn, Reason)
                end;
            {error, Reason} ->
                fail_unanswered(Conn, Reason, SentAt)
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
        SentAt = lg_time:now_ms(),
        Deadline = SentAt + Timeout,
        Ref = send(Conn, Method, Url, Headers, Body, #{flow => ?FLOW}),
        %% 开了 flow 的流读整个响应体时同样要逐条补额度，否则读到窗口用完就停住
        BodyOpts = Opts#{flow => true},
        case await_response(Conn, Ref, Timeout, Opts) of
            {response, nofin, Status, RespHeaders} when Status >= 200, Status < 300 ->
                case content_type(RespHeaders) of
                    event_stream ->
                        {ok, Status, RespHeaders, #{conn => Conn, ref => Ref, url => Url, started => lg_time:now_ms()}};
                    Other ->
                        %% 不是 SSE：读完响应体再判断（HTML → 非 API 回复；JSON → 交给调用方）
                        case read_body(Conn, Ref, Deadline, BodyOpts) of
                            {ok, RespBody} ->
                                lg_http_pool:checkin(Conn, Url),
                                case Other =:= json andalso not html_like(RespBody) of
                                    true -> {json, Status, RespHeaders, RespBody};
                                    false when Other =:= html -> {error, {not_api_reply, RespBody}};
                                    false ->
                                        case html_like(RespBody) of
                                            true -> {error, {not_api_reply, RespBody}};
                                            %% 未声明类型的 SSE（部分上游不带 content-type）：按 SSE 处理
                                            false -> {ok, Status, RespHeaders, #{conn => Conn, ref => Ref, url => Url,
                                                                                fin => true, body => RespBody}}
                                        end
                                end;
                            {error, Reason} ->
                                fail(Conn, Reason)
                        end
                end;
            {response, fin, Status, RespHeaders} when Status >= 200, Status < 300 ->
                %% 空流：返回一个已结束的句柄
                lg_http_pool:checkin(Conn, Url),
                {ok, Status, RespHeaders, #{conn => Conn, ref => Ref, url => Url, fin => true}};
            {response, fin, Status, RespHeaders} ->
                done(Conn, Url, Status, RespHeaders, <<>>);
            {response, nofin, Status, RespHeaders} ->
                case read_body(Conn, Ref, Deadline, BodyOpts) of
                    {ok, RespBody} -> done(Conn, Url, Status, RespHeaders, RespBody);
                    {error, Reason} -> fail(Conn, Reason)
                end;
            {error, Reason} ->
                fail_unanswered(Conn, Reason, SentAt)
        end
    end).

%% @doc 读下一块数据。fin 表示流已结束（连接已归还）。
%%
%% Timeout 是首块数据的等待时长；收到过数据后改按 stream_idle_timeout_ms 计块间空闲，
%% 开流超过 stream_max_ms 时以 {timeout, total} 结束（即使上游仍在发数据或 ping）。
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
stream_recv(#{conn := Conn, ref := Ref, url := Url} = S, Timeout, Opts) ->
    Now = lg_time:now_ms(),
    Total = maps:get(started, S, Now) + lg_config:get(stream_max_ms),
    {Wait, Phase} = case maps:get(active, S, false) of
                        true -> {lg_config:get(stream_idle_timeout_ms), idle};
                        false -> {Timeout, first_byte}
                    end,
    %% 截止取空闲截止与总截止中较早者，超时时据此判定 phase
    {Deadline, Phase1} = case Total =< Now + Wait of
                             true -> {Total, total};
                             false -> {Now + Wait, Phase}
                         end,
    case Now >= Total of
        true ->
            %% 已超总时长：不再读（上游持续发数据时 receive 总能先拿到消息，不会走到 after）
            fail(Conn, {timeout, total});
        false ->
            MRef = monitor(process, Conn),
            Res = recv_loop(Conn, Ref, MRef, Deadline, Opts),
            demonitor(MRef, [flush]),
            case Res of
                {data, D} ->
                    {data, D, S#{active => true}};
                {fin, D} ->
                    lg_http_pool:checkin(Conn, Url),
                    {fin, D};
                {exit, _} = Exit ->
                    Exit;
                {error, timeout} ->
                    fail(Conn, {timeout, Phase1});
                {error, R} ->
                    fail(Conn, R)
            end
    end.

%% 取走一条 gun_data 即补 1 个 flow 额度：调用方转发完这块（stream_body 拿到 data_ack）才会再来取，
%% 所以邮箱里未处理的 gun_data 不超过窗口（+1，见模块说明）
recv_loop(Conn, Ref, MRef, Deadline, Opts) ->
    Wait = wait_ms(Deadline, Opts),
    receive
        {gun_data, Conn, Ref, nofin, Data} -> gun:update_flow(Conn, Ref, 1), {data, Data};
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

%% 读完非流式响应体（替代 gun:await_body）：累计字节超过 upstream_max_body_bytes 立即中止，
%% 到达截止时刻（发出请求起 Timeout）以 {timeout, total} 结束，上游慢速滴数据也会超时。
%% 中止后由调用方 fail/2 丢弃连接（gun:close 结束连接进程，不再读剩余数据）。
%% Opts 带 flow => true（流式请求读非 SSE 响应体）时每收一块补 1 个 flow 额度。
read_body(Conn, Ref, Deadline, Opts) ->
    MRef = monitor(process, Conn),
    Res = body_loop(Conn, Ref, MRef, Deadline, lg_config:get(upstream_max_body_bytes), Opts, 0, []),
    demonitor(MRef, [flush]),
    Res.

body_loop(Conn, Ref, MRef, Deadline, Max, Opts, Size, Acc) ->
    Wait = wait_ms(Deadline, Opts),
    receive
        {gun_data, Conn, Ref, IsFin, Data} ->
            Size1 = Size + byte_size(Data),
            if Size1 > Max -> {error, {too_large, Max}};
               IsFin =:= fin -> {ok, iolist_to_binary(lists:reverse(Acc, [Data]))};
               true ->
                   credit(Conn, Ref, Opts),
                   body_loop(Conn, Ref, MRef, Deadline, Max, Opts, Size1, [Data | Acc])
            end;
        {gun_trailers, Conn, Ref, _} -> {ok, iolist_to_binary(lists:reverse(Acc))};
        {gun_error, Conn, Ref, Reason} -> {error, Reason};
        {gun_error, Conn, Reason} -> {error, Reason};
        {'DOWN', MRef, process, Conn, Reason} -> {error, {down, Reason}}
    after Wait ->
        case lg_time:now_ms() >= Deadline of
            true -> {error, {timeout, total}};
            false -> idle(Opts), body_loop(Conn, Ref, MRef, Deadline, Max, Opts, Size, Acc)
        end
    end.

credit(Conn, Ref, #{flow := true}) -> gun:update_flow(Conn, Ref, 1);
credit(_Conn, _Ref, _Opts) -> ok.

%% 本次等待时长：有回调时每 tick 毫秒醒一次，否则等到截止
wait_ms(Deadline, Opts) ->
    Left = max(0, Deadline - lg_time:now_ms()),
    case maps:find(idle, Opts) of
        {ok, _} -> min(Left, maps:get(tick, Opts, 1000));
        error -> Left
    end.

%% 读响应体 / 开流后的等待回调：这两个阶段不因客户端断开而中止（响应体要读完才能计费，
%% 开流后由 recv_loop 的 'EXIT' 分支处理）。回调取走了 'EXIT' 并抛出 client_exit 时把信号放回邮箱，
%% 交给外层（recv_loop / lg_web_llm:sync 收尾检查）处理，不能吞掉
idle(#{idle := F}) ->
    try F()
    catch
        throw:{client_exit, R} -> self() ! {'EXIT', self(), R};
        _:_ -> ok
    end,
    ok;
idle(_) -> ok.

%% @doc 提前结束流（客户端断开、出错等），连接直接丢弃。
-spec stream_close(stream()) -> ok.
stream_close(#{fin := true}) ->
    ok;
stream_close(#{conn := Conn}) ->
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

send(Conn, Method, Url, Headers, Body, ReqOpts) ->
    gun:request(Conn, Method, path(Url), with_user_agent(Headers), Body, ReqOpts).

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
                false -> await_idle(Conn, Ref, Opts), await_loop(Conn, Ref, Deadline, Opts)
            end;
        Other -> Other
    end.

%% 等待响应头期间的回调。回调抛出 {client_exit, _}（客户端已断开，T20）时取消上游流、
%% 丢弃连接后继续抛给路由层；其余异常忽略（同 idle/1）
await_idle(Conn, Ref, #{idle := F}) ->
    try F()
    catch
        throw:{client_exit, _} = E ->
            gun:cancel(Conn, Ref),
            lg_http_pool:discard(Conn),
            throw(E);
        _:_ -> ok
    end,
    ok;
await_idle(_Conn, _Ref, _Opts) ->
    ok.

done(Conn, Url, Status, Headers, Body) when Status >= 200, Status < 300 ->
    lg_http_pool:checkin(Conn, Url),
    {ok, Status, Headers, Body};
done(Conn, Url, Status, Headers, Body) ->
    lg_http_pool:checkin(Conn, Url),
    {error, {http_error, Status, Headers, Body}}.

%% 丢弃连接后返回错误。discard 先关连接再按连接清邮箱（含 gun_down）：
%% 超限中止时连接进程可能还在投递数据，关掉后才能清干净。
fail(Conn, Reason) ->
    lg_http_pool:discard(Conn),
    case Reason of
        timeout -> limit_hit(first_byte), {error, timeout};
        {timeout, P} -> limit_hit(P), {error, Reason};
        {too_large, _} -> limit_hit(too_large), {error, Reason};
        _ -> {error, {request_failed, Reason}}
    end.

%% 收到响应头之前失败：只有可判定上游没处理这个请求时才标记可重试（with_retry 仅对复用连接重发）
fail_unanswered(Conn, Reason, SentAt) ->
    case resend_safe(Reason, lg_time:now_ms() - SentAt) of
        true -> lg_http_pool:discard(Conn), {error, {retryable, Reason}};
        false -> fail(Conn, Reason)
    end.

%% gun 进程已不在（noproc）：请求根本没送出；连接被关闭（gun 的 closed / {closed, _} 流错误、
%% 连接进程退出）且发出不到 ?RESEND_WINDOW_MS：空闲连接被对端关掉的竞态，视为未处理。
%% 其余（超时、协议错误、发出较久后断开）上游可能已收到并在处理，不重发
resend_safe({down, noproc}, _Ms) -> true;
resend_safe({down, _}, Ms) -> Ms < ?RESEND_WINDOW_MS;
resend_safe({stream_error, closed}, Ms) -> Ms < ?RESEND_WINDOW_MS;
resend_safe({stream_error, {closed, _}}, Ms) -> Ms < ?RESEND_WINDOW_MS;
resend_safe(_, _Ms) -> false.

limit_hit(Phase) ->
    logger:warning("upstream ~s: phase=~s", [case Phase of too_large -> "response too large"; _ -> "timeout" end, Phase]),
    lg_metrics:inc(litegate_upstream_timeouts_total, [{phase, Phase}]).

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
