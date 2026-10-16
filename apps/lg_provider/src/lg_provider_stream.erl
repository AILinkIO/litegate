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
    buf = <<>> :: binary(),
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
                {ok, S} ->
                    {ok, S#stream{client = responses,
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
                            {ok, #stream{http = #{fin => true}, buf = Sse, proc = Proc(), client = Client,
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
stream_next(#stream{http = Http, buf = Buf, timeout = Timeout, idle = Idle} = S) ->
    Opts = case Idle of undefined -> #{}; _ -> #{idle => Idle, tick => lg_config:get(keepalive_ms)} end,
    case lg_http:stream_recv(Http, Timeout, Opts) of
        {data, Data, Http1} ->
            {Frames, S1} = feed(<<Buf/binary, Data/binary>>, S#stream{http = Http1}),
            case S1#stream.proc =/= undefined andalso lg_stream:looped(S1#stream.proc) of
                true ->
                    %% 复读：结束上游流，按正常结束收尾（结束帧由 lg_stream 按客户端格式补齐）
                    lg_http:stream_close(Http1),
                    {Tail, Result} = finish_all(S1#stream{http = done}),
                    {done, Frames ++ Tail, Result#{loop_detected => true}};
                false ->
                    {frames, Frames, S1}
            end;
        {fin, Data} ->
            {Frames, S1} = feed(<<Buf/binary, Data/binary, "\n\n">>, S#stream{http = done}),
            {Tail, Result} = finish_all(S1),
            {done, Frames ++ Tail, Result};
        {exit, Reason} ->
            %% 调用进程收到退出信号（客户端断开）：中止上游，返回已累计的结果
            {exit, Reason, stream_abort(S)};
        {error, Reason} ->
            %% 开流后上游失败：以客户端格式的错误帧结束
            #{message := Msg} = E = lg_llm_error:classify(Reason),
            {_, Result} = finish_all(S),
            {done, [error_frame(S#stream.client, Msg)],
             Result#{error => #{<<"message">> => Msg, <<"kind">> => maps:get(kind, E)}}}
    end.

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

%% 第一级输出的 Chat SSE 帧 → Responses 事件帧
stage2(Frames, St) ->
    {Evs, _} = lg_sse:parse(iolist_to_binary(Frames)),
    lists:foldl(fun(#{data := D}, {Acc, S}) when D =/= undefined, D =/= <<"[DONE]">> ->
                        case catch json:decode(D) of
                            M when is_map(M) ->
                                {F, S1} = lg_resp_stream:feed(M, S),
                                {Acc ++ F, S1};
                            _ ->
                                {Acc, S}
                        end;
                   (_, Acc) ->
                        Acc
                end, {[], St}, Evs).

%% @doc 客户端断开等情况下提前结束，返回已累计的结果（用于记账）。
-spec stream_abort(#stream{}) -> result().
stream_abort(#stream{http = Http} = S) ->
    Http =:= done orelse lg_http:stream_close(Http),
    {_, Result} = finish_all(S),
    Result.

%% Responses 透传：事件直接交给第二级（原样转发并累计）
feed(Buf, #stream{proc = undefined, stage2 = St} = S) ->
    {Events, Rest} = lg_sse:parse(Buf),
    {Frames, St1} = lists:foldl(fun(Ev, {Acc, X}) ->
                                        {F, X1} = lg_resp_stream:feed(Ev, X),
                                        {[Acc, F], X1}
                                end, {[], St}, Events),
    {[Frames], S#stream{buf = Rest, stage2 = St1}};
%% Responses 转换：第一级（lg_stream）输出 Chat 帧，再经第二级转成 Responses 事件
feed(Buf, #stream{stage2 = St2} = S) when St2 =/= undefined ->
    {Frames, S1} = feed(Buf, S#stream{stage2 = undefined}),
    {Out, St3} = stage2(Frames, St2),
    {Out, S1#stream{stage2 = St3}};
feed(Buf, #stream{proc = Proc, think = Think0, structured = St0} = S) ->
    {Events, Rest} = lg_sse:parse(Buf),
    {Frames, Proc1, Think1, St1} =
        lists:foldl(fun(Ev0, {Acc, P, T, St}) ->
                            {Ev1, T1} = think_event(Ev0, T),
                            {Ev, St2} = structured_event(Ev1, St),
                            {F, P1} = lg_stream:feed(Ev, P),
                            {[F | Acc], P1, T1, St2}
                    end, {[], Proc, Think0, St0}, Events),
    {lists:append(lists:reverse(Frames)), S#stream{buf = Rest, proc = Proc1, think = Think1, structured = St1}}.

structured_state(undefined) -> undefined;
structured_state(json) -> undefined;
structured_state(Name) -> {Name, []}.

structured_event(Ev, undefined) ->
    {Ev, undefined};
structured_event(Ev, {Name, Idx}) ->
    {Ev1, Idx1} = lg_structured:stream_event({Ev, Idx}, Name),
    {Ev1, {Name, Idx1}}.

%% think_tags = split：改写上游 chunk 的 content / reasoning_content（同协议透传时也生效，raw 随之重写）
think_event(Ev, undefined) ->
    {Ev, undefined};
think_event(#{data := D} = Ev, T) when is_binary(D), D =/= <<"[DONE]">> ->
    case catch json:decode(D) of
        #{<<"choices">> := [_ | _]} = J ->
            {J1, T1} = lg_think:feed_chunk(J, T),
            D1 = iolist_to_binary(json:encode(J1)),
            {Ev#{data => D1, raw => iolist_to_binary(lg_sse:encode(D1))}, T1};
        _ ->
            {Ev, T}
    end;
think_event(Ev, T) ->
    {Ev, T}.

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
