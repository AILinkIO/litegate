%% @doc 上游流式状态机：开流、SSE 解析、Responses 两级流、保活、中止与错误帧。
%%
%% 非流式响应转换与上游请求构造仍在 `lg_provider`；该模块只处理 2xx 之后的流生命周期。
-module(lg_provider_stream).

-include_lib("lg_core/include/lg_core.hrl").

-export([stream_open/3, stream_next/1, stream_abort/1, stream_set_idle/2, stream_output_started/1, error_frame/2]).

-type format() :: openai | anthropic | responses.
-type target() :: map().
-type result() :: lg_stream:result().

-record(stream, {
    http :: lg_http:stream() | done,
    buf = lg_sse:new() :: lg_sse:buffer(),   %% 未结束的 SSE 事件（增量扫描）
    proc :: term(),                          %% lg_stream 状态（Responses 透传时为 undefined）
    stage2 :: term(),                        %% Responses 客户端的第二级（lg_resp_stream）
    client :: format(),
    timeout :: timeout(),
    think :: lg_think:state() | undefined,   %% 凭证 think_tags = split 时拆分上游 content 里的 <think>
    idle :: fun(() -> term()) | undefined,    %% 开流后上游无数据时的回调（保活）
    structured :: {binary(), [integer()]} | undefined   %% 强制工具方式的结构化输出：{工具名, 已改写的内容块}
}).

%%====================================================================
%% 流式
%%====================================================================

-spec stream_open(format(), map(), target()) -> {ok, #stream{}} | {error, lg_llm_error:error()}.
stream_open(responses, Req, Target) ->
    case lg_provider:responses_passthrough(Target) of
        true -> lg_provider:with_unfit_retry(Target, fun(T) -> responses_stream_native(Req, T) end);
        false -> responses_stream_converted(Req, Target)
    end;
stream_open(Client, Req, Target) ->
    lg_provider:with_beta_retry(Target, fun(T) -> lg_provider:with_unfit_retry(T, fun(T2) -> stream_open_once(Client, Req, T2) end) end).

%% 原生 Responses 流式透传（凭证 options.responses_api = true）
responses_stream_native(Req, #{credential := Cred, upstream_model := Model} = Target) ->
    case lg_provider:auth_headers(openai, Cred, openai, Target) of
        {ok, H} ->
            Timeout = lg_config:get(upstream_timeout_ms),
            BodyMap = lg_provider:extra_body(Cred, lg_unfit:apply(openai, Cred#lg_credential.id, Model,
                                                      lg_quirks:apply(openai, Cred, Model,
                                                                      Req#{<<"model">> => Model, <<"stream">> => true}),
                                                      true)),
            case lg_http:stream_open(<<"POST">>, lg_provider:responses_url(Cred), H ++ Cred#lg_credential.headers,
                                     json:encode(BodyMap), Timeout, http_opts(Target)) of
                {ok, _, _, Http} ->
                    {ok, #stream{http = Http, client = responses, timeout = Timeout,
                                 stage2 = lg_resp_stream:new(#{mode => passthrough, request => Req})}};
                {json, _, RespH, RespBody} ->
                    %% 原生 Responses 返回 JSON：只识别业务错误，正常响应不合成（按非 API 回复回退）
                    case json_reply(openai, 200, RespH, RespBody) of
                        {error, _} = Err -> Err;
                        {ok, _} -> {error, lg_llm_error:classify({not_api_reply, RespBody})}
                    end;
                {error, R} ->
                    {error, lg_provider:sent_error(R, BodyMap)}
            end;
        {error, R} ->
            {error, lg_llm_error:classify(R)}
    end.

responses_stream_converted(Req, Target) ->
    case lg_conv_responses:request_to_chat(Req#{<<"stream">> => true}) of
        {ok, ChatReq} ->
            case stream_open(openai, ChatReq, Target) of
                {ok, #stream{proc = Proc} = S} ->
                    %% 第一级直接输出 Chat chunk map，第二级不必再解析、解码
                    {ok, S#stream{client = responses, proc = lg_stream:map_output(Proc),
                                  stage2 = lg_resp_stream:new(#{mode => converted, request => Req})}};
                Err ->
                    Err
            end;
        {error, R} ->
            {error, lg_llm_error:classify(R)}
    end.

stream_open_once(Client, Req, Target) ->
    ClientWantsUsage = client_wants_usage(Client, Req),
    case lg_provider:upstream_request(Client, Req#{<<"stream">> => true}, Target) of
        {ok, #{url := Url, headers := H, body := B, upstream := Up} = U} ->
            Structured = maps:get(structured, U, undefined),
            Timeout = lg_config:get(upstream_timeout_ms),
            Proc = fun() -> lg_stream:new(#{client => Client, upstream => Up,
                                            include_usage => ClientWantsUsage,
                                            strip_usage => not ClientWantsUsage,
                                            loop_guard => maps:get(loop_guard, Target, true)})
                   end,
            Think = case lg_think:enabled(maps:get(credential, Target)) of
                        true -> lg_think:new();
                        false -> undefined
                    end,
            case lg_http:stream_open(<<"POST">>, Url, H, B, Timeout, http_opts(Target)) of
                {ok, _Status, _RespH, Http} ->
                    {ok, #stream{http = Http, proc = Proc(), client = Client, timeout = Timeout, think = Think,
                                 structured = structured_state(Structured)}};
                {json, Status, RespH, RespBody} ->
                    %% 要求流式却返回 JSON：业务错误按错误处理（可回退）；正常响应合成为 SSE 照常输出
                    case json_reply(Up, Status, RespH, RespBody) of
                        {ok, Sse} ->
                            {ok, #stream{http = #{fin => true, body => Sse}, proc = Proc(), client = Client,
                                         timeout = Timeout, think = Think, structured = structured_state(Structured)}};
                        {error, E0} ->
                            {error, E0#{sent => maps:get(body_map, U)}}
                    end;
                {error, Reason} ->
                    {error, lg_provider:sent_error(Reason, maps:get(body_map, U))}
            end;
        {error, Reason} ->
            {error, lg_llm_error:classify(Reason)}
    end.

json_reply(Up, Status, RespH, RespBody) ->
    try json:decode(RespBody) of
        J when is_map(J) ->
            case lg_sse_synth:error_body(J) of
                ok -> {ok, lg_sse_synth:sse(Up, J)};   %% 结构化输出的还原在逐事件改写时完成
                {minimax, Code} ->
                    Msg = maps:get(<<"status_msg">>, maps:get(<<"base_resp">>, J), <<>>),
                    {error, lg_media:minimax_error(Code, Msg)};
                {error, S} ->
                    {error, lg_llm_error:classify({http_error, S, RespH, RespBody})}
            end;
        _ ->
            {error, lg_llm_error:classify({not_api_reply, RespBody})}
    catch
        error:_ ->
            _ = Status,
            {error, lg_llm_error:classify({not_api_reply, RespBody})}
    end.

%% 等待上游时的回调（Target 的 idle：网关在开流前向客户端写保活帧）
http_opts(#{idle := F}) when is_function(F, 0) -> #{idle => F, tick => 250};
http_opts(_) -> #{}.

%% @doc 设置开流后的等待回调：上游一段时间没有数据时调用（网关写保活注释帧）。
-spec stream_set_idle(#stream{}, fun(() -> term()) | undefined) -> #stream{}.
stream_set_idle(S, F) ->
    S#stream{idle = F}.

-spec stream_next(#stream{}) -> {frames, [iodata()], #stream{}} | {done, [iodata()], result()}
                                | {exit, term(), result()}.
stream_next(#stream{http = Http, timeout = Timeout, idle = Idle} = S) ->
    Opts = case Idle of undefined -> #{}; _ -> #{idle => Idle, tick => lg_config:get(keepalive_ms)} end,
    case lg_http:stream_recv(Http, Timeout, Opts) of
        {data, Data, Http1} ->
            {Frames, S1} = feed(Data, S#stream{http = Http1}),
            Max = lg_config:get(sse_max_event_bytes),
            Pending = lg_sse:buffered(S1#stream.buf),
            case S1#stream.proc =/= undefined andalso lg_stream:looped(S1#stream.proc) of
                _ when Pending > Max ->
                    %% 未结束的 SSE 事件超过 sse_max_event_bytes：中止上游，已解析的帧照常输出后以错误帧结束
                    lg_http:stream_close(Http1),
                    logger:warning("upstream response too large: phase=too_large (SSE event over ~b bytes)", [Max]),
                    lg_metrics:inc(litegate_upstream_timeouts_total, [{phase, too_large}]),
                    {done, Tail, Result} = stream_failed(S1#stream{http = done, buf = lg_sse:new()}, {too_large, Max}),
                    {done, Frames ++ Tail, Result};
                true ->
                    %% 复读：结束上游流，按正常结束收尾（结束帧由 lg_stream 按客户端格式补齐）
                    lg_http:stream_close(Http1),
                    {Tail, Result} = finish_all(S1#stream{http = done}),
                    {done, Frames ++ Tail, Result#{loop_detected => true}};
                false ->
                    {frames, Frames, S1}
            end;
        {fin, Data} ->
            {Frames, S1} = feed(<<Data/binary, "\n\n">>, S#stream{http = done}),
            {Tail, Result} = finish_all(S1),
            {done, Frames ++ Tail, Result};
        {exit, Reason} ->
            %% 调用进程收到退出信号（客户端断开）：中止上游，返回已累计的结果
            {exit, Reason, stream_abort(S)};
        {error, Reason} ->
            stream_failed(S, Reason)
    end.

%% 开流后上游失败（含分级超时、SSE 事件超限）：以客户端格式的错误帧结束
stream_failed(S, Reason) ->
    #{message := Msg} = E = lg_llm_error:classify(Reason),
    {_, Result} = finish_all(S),
    {done, [error_frame(S#stream.client, Msg)],
     Result#{error => #{<<"message">> => Msg, <<"kind">> => maps:get(kind, E)}}}.

%% @doc 是否已向客户端输出首个实际内容（TTFT 计时点）。
-spec stream_output_started(#stream{}) -> boolean().
stream_output_started(#stream{proc = undefined, stage2 = St}) ->
    maps:get(text, lg_resp_stream:result(St)) =/= <<>>;
stream_output_started(#stream{proc = Proc}) ->
    lg_stream:output_started(Proc).

%% 结束两级处理，返回剩余帧与结果（Responses 客户端的结果带最终 response 对象）
finish_all(#stream{proc = undefined, stage2 = St}) ->
    %% Responses 透传
    {_, St1} = lg_resp_stream:finish(undefined, St),
    #{response := R, usage := U, text := T} = lg_resp_stream:result(St1),
    Base = #{usage => U, text => T, finish_reason => null, model => <<>>, id => <<>>, error => undefined},
    {[], case R of
             undefined -> Base;
             _ -> maps:merge(lg_provider:responses_result(R), #{text => T})
         end};
finish_all(#stream{proc = Proc, stage2 = undefined}) ->
    lg_stream:finish(Proc);
finish_all(#stream{proc = Proc, stage2 = St}) ->
    {Tail, Result} = lg_stream:finish(Proc),
    {F1, St1} = stage2(Tail, St),
    {F2, St2} = lg_resp_stream:finish(maps:get(usage, Result), St1),
    {F1 ++ F2, Result#{response => maps:get(response, lg_resp_stream:result(St2))}}.

%% 第一级输出的 Chat chunk map（lg_stream:map_output/1）→ Responses 事件帧
stage2(Chunks, St) ->
    lists:foldl(fun(M, {Acc, S}) ->
                        {F, S1} = lg_resp_stream:feed(M, S),
                        {Acc ++ F, S1}
                end, {[], St}, Chunks).

%% @doc 客户端断开等情况下提前结束，返回已累计的结果（用于记账）。
-spec stream_abort(#stream{}) -> result().
stream_abort(#stream{http = Http} = S) ->
    Http =:= done orelse lg_http:stream_close(Http),
    {_, Result} = finish_all(S),
    Result.

%% Responses 透传：事件直接交给第二级（原样转发并累计）
feed(Data, #stream{proc = undefined, stage2 = St, buf = Buf} = S) ->
    {Events, Buf1} = lg_sse:feed(Data, Buf),
    {Frames, St1} = lists:foldl(fun(Ev, {Acc, X}) ->
                                        {F, X1} = lg_resp_stream:feed(Ev, X),
                                        {[Acc, F], X1}
                                end, {[], St}, Events),
    {[Frames], S#stream{buf = Buf1, stage2 = St1}};
%% Responses 转换：第一级（lg_stream）输出 Chat chunk map，再经第二级转成 Responses 事件
feed(Data, #stream{stage2 = St2} = S) when St2 =/= undefined ->
    {Chunks, S1} = feed(Data, S#stream{stage2 = undefined}),
    {Out, St3} = stage2(Chunks, St2),
    {Out, S1#stream{stage2 = St3}};
%% 每个事件只解码一次：think 拆分、结构化输出改写、lg_stream 都在同一个 map 上处理，
%% 被改写的事件在透传出口按 map 重新编码一次
feed(Data, #stream{buf = Buf, proc = Proc, think = Think0, structured = St0} = S) ->
    {Events, Buf1} = lg_sse:feed(Data, Buf),
    {Frames, Proc1, Think1, St1} =
        lists:foldl(fun(#{raw := Raw0} = Ev, {Acc, P, T, St}) ->
                            J0 = decode(Ev),
                            {Raw1, J1, T1} = think_event(Raw0, J0, T),
                            {Raw, J, St2} = structured_event(Ev, Raw1, J1, St),
                            {F, P1} = lg_stream:feed_decoded(Raw, J, P),
                            {[F | Acc], P1, T1, St2}
                    end, {[], Proc, Think0, St0}, Events),
    {lists:append(lists:reverse(Frames)), S#stream{buf = Buf1, proc = Proc1, think = Think1, structured = St1}}.

%% 事件 data 解码；[DONE]、无 data、非 JSON 为 undefined
decode(#{data := D}) when is_binary(D), D =/= <<"[DONE]">> ->
    try json:decode(D) catch error:_ -> undefined end;
decode(_) ->
    undefined.

structured_state(undefined) -> undefined;
structured_state(json) -> undefined;
structured_state(Name) -> {Name, []}.

structured_event(_Ev, Raw, J, undefined) ->
    {Raw, J, undefined};
structured_event(#{event := E}, Raw, J, {Name, Idx}) when is_map(J) ->
    case lg_structured:stream_event({J, Idx}, Name) of
        {keep, Idx1} -> {Raw, J, {Name, Idx1}};
        {{rewrite, J1}, Idx1} -> {{encode, E}, J1, {Name, Idx1}}
    end;
structured_event(_Ev, Raw, J, St) ->
    {Raw, J, St}.

%% think_tags = split：改写上游 chunk 的 content / reasoning_content（同协议透传时也生效，raw 按 data-only 帧重新编码）
think_event(Raw, J, undefined) ->
    {Raw, J, undefined};
think_event(_Raw, #{<<"choices">> := [_ | _]} = J, T) ->
    {J1, T1} = lg_think:feed_chunk(J, T),
    {{encode, undefined}, J1, T1};
think_event(Raw, J, T) ->
    {Raw, J, T}.

%% @doc 客户端格式的错误帧（开流后失败时结束流）。
-spec error_frame(format(), binary()) -> iodata().
error_frame(responses, Msg) ->
    lg_sse:encode(<<"error">>, json:encode(#{<<"type">> => <<"error">>, <<"code">> => <<"upstream_error">>,
                                             <<"message">> => Msg}));
error_frame(openai, Msg) ->
    lg_sse:encode(lg_llm_error:render(openai, 502, <<"api_error">>, Msg));
error_frame(anthropic, Msg) ->
    lg_sse:encode(<<"error">>, lg_llm_error:render(anthropic, 502, <<"api_error">>, Msg)).

%% OpenAI 客户端显式要求 usage 块时才转发；Anthropic 客户端的用量在事件里，总是保留
client_wants_usage(openai, #{<<"stream_options">> := #{<<"include_usage">> := true}}) -> true;
client_wants_usage(openai, _) -> false;
client_wants_usage(anthropic, _) -> true.
