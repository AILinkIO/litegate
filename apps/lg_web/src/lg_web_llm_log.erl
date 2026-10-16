%% @doc LLM 请求收尾：结构化日志、Prometheus 指标、OTLP 导出与 Responses 会话保存。
%%
%% 该模块只消费已完成的 outcome；不解析 HTTP 请求，也不生成客户端响应。
-module(lg_web_llm_log).

-include_lib("lg_core/include/lg_core.hrl").

-export([record/6]).

%% count_tokens 不记日志（高频、无计费），只收尾
record(#{kind := count_tokens}, _F, _Stream, _Body, Out, _Status) ->
    lg_router:done(Out);
record(#{id := Id, kind := Kind} = Ctx, F, Stream, Body, Out, Status) ->
    ok = lg_router:done(Out),
    Result = maps:get(result, Out, #{}),
    Format = case Kind of chat -> F; _ -> Kind end,
    metrics(Format, Status, Out, Result),
    Source = case maps:get(key_id, Out) of ?LG_PLAYGROUND_KEY -> playground; _ -> gateway end,
    Log0 = #{id => Id, format => Format, stream => Stream, status => Status, source => Source,
             route => maps:get(route, Out), model => maps:get(model, Out, maps:get(route, Out)),
             key_id => maps:get(key_id, Out),
             user_id => maps:get(user_id, Out),
             attempts => length(maps:get(attempts, Out)),
             duration_ms => lg_time:now_ms() - maps:get(started_at, Out)},
    Log = maps:merge(Log0, maps:filter(fun(_, V) -> V =/= undefined end,
               #{credential => maps:get(credential, Out, undefined),
                 upstream_model => maps:get(upstream_model, Out, undefined),
                 model_ref => maps:get(model_ref, Out, undefined),
                 usage => maps:get(usage, Result, undefined),
                 cost => maps:get(cost, Out, undefined),
                 finish_reason => maps:get(finish_reason, Result, undefined),
                 client_aborted => maps:get(client_aborted, Out, undefined),
                 ttft_ms => maps:get(ttft_ms, Out, undefined),
                 queued_ms => maps:get(queued_ms, Out, undefined),
                 rounds => maps:get(rounds, Out, undefined),
                 loop_detected => case maps:get(loop_detected, Result, false) of true -> true; _ -> undefined end,
                 patience_ms => maps:get(patience_ms, Out, undefined),
                 redacted => case Ctx of #{redact := RMap} -> map_size(RMap); _ -> undefined end,
                 session => maps:get(session, Out, undefined),
                 new_turn => case maps:get(new_turn, Ctx, false) of true -> true; _ -> undefined end,
                 session_source => maps:get(session_source, Ctx, undefined),
                 context => context(Kind, F, Body),
                 client => maps:get(client, Ctx, undefined),
                 user_agent => case maps:get(client, Ctx, undefined) of
                                   <<"other">> -> maps:get(user_agent, Ctx, undefined);
                                   _ -> undefined
                               end,
                 affinity => affinity_text(maps:get(affinity, Out, undefined)),
                 rule => maps:get(rule, Out, undefined),
                 rule_reused => case maps:get(rule_reused, Out, false) of true -> true; _ -> undefined end,
                 affinity_prev => maps:get(affinity_prev, Out, undefined),
                 routed_to => maps:get(routed_to, Out, undefined),
                 nested_rules => maps:get(nested_rules, Out, undefined),
                 intent => maps:get(intent, Out, undefined),
                 attempt_list => case maps:get(attempts, Out) of [] -> undefined; As -> As end,
                 plan_trace => case maps:get(plan_trace, Out, []) of [_, _ | _] = Tr -> Tr; _ -> undefined end,
                 cache_hit => maps:get(cache_hit, Out, undefined),
                 saved_usd => maps:get(saved_usd, Out, undefined),
                 plan => maps:get(plan, Out, undefined),
                 tags => case maps:get(tags, Out, []) of [] -> undefined; Ts -> Ts end,
                 plan_usd => maps:get(plan_usd, Out, undefined),
                 error => error_info(Out, Result)})),
    %% embeddings 输入可能很大且无回复文本，不记录内容
    Messages = case {Kind, F} of
                   {embeddings, _} -> undefined;
                   {speech, _} -> #{request => #{<<"messages">> => [#{<<"role">> => <<"user">>,
                                                                        <<"content">> => maps:get(<<"input">>, Body, <<>>)}]},
                                    response => <<>>};
                   {systemone, _} -> #{request => lg_router:systemone_request(Body),
                                       response => maps:get(text, Result, <<>>)};
                   {images, _} -> #{request => #{<<"messages">> => [#{<<"role">> => <<"user">>,
                                                                        <<"content">> => maps:get(<<"prompt">>, Body, <<>>)}]},
                                    response => maps:get(text, Result, <<>>)};
                   {chat, responses} -> #{request => responses_request(Body),
                                          response => maps:get(text, Result, <<>>)};
                   {chat, _} -> #{request => maps:with([<<"system">>, <<"messages">>], Body),
                                  response => maps:get(text, Result, <<>>)}
               end,
    ok = lg_store:record(Log, Messages),
    LiveEnd = maps:filter(fun(_, V) -> V =/= undefined end,
                          maps:with([route, client, status, attempts, error, usage, cost, plan, duration_ms,
                                     ttft_ms, credential, upstream_model], Log)),
    lg_live:request_end(Id, LiveEnd#{narrative => try lg_narrate:lines(Log) catch _:_ -> [] end}),
    lg_otlp:submit(Log, Messages, #{started_at => maps:get(started_at, Out),
                                    traceparent => maps:get(traceparent, Ctx, undefined)}),
    case Ctx of
        #{redact := Map, original := Orig} ->
            %% Responses 会话保存原值：下一轮按 previous_response_id 展开后会重新脱敏，占位符编号与本轮无关
            save_response(F, Orig, Out, lg_redact:restore_json(Result, Map));
        _ ->
            save_response(F, Body, Out, Result)
    end.

%% 提示词构成：对话请求按系统提示、工具、历史、本轮输入、图片估算 token
context(chat, F, Body) ->
    try lg_context:breakdown(F, Body) catch _:_ -> undefined end;
context(_, _, _) ->
    undefined.

affinity_text(undefined) -> undefined;
affinity_text(off) -> undefined;
affinity_text({broken, Why}) -> <<"broken:", Why/binary>>;
affinity_text(A) when is_atom(A) -> atom_to_binary(A).

%% Responses 请求记入日志时转成 system + messages，便于查看与全文检索
responses_request(Body) ->
    Items = try lg_conv_responses:chat_messages(lg_conv_responses:input_items(Body))
            catch _:_ -> []
            end,
    maps:filter(fun(_, V) -> V =/= undefined end,
                #{<<"system">> => maps:get(<<"instructions">>, Body, undefined), <<"messages">> => Items}).

%% 保存 Responses 会话（store: false 时不保存）：输入与输出项，透传模式另存目标
save_response(responses, Body, #{credential := CId, upstream_model := M}, #{response := #{<<"id">> := Id} = Resp})
  when is_binary(Id) ->
    case maps:get(<<"store">>, Body, true) of
        false ->
            ok;
        _ ->
            Items = #{input => lg_conv_responses:input_items(Body),
                      output => lg_conv_responses:output_items(Resp)},
            Rec = case lg_credentials:get(CId) of
                      {ok, #lg_credential{protocol = openai, options = #{responses_api := true}}} ->
                          Items#{mode => passthrough, credential => CId, upstream_model => M};
                      _ ->
                          Items#{mode => converted}
                  end,
            lg_store:response_put(Id, Rec)
    end;
save_response(_, _, _, _) ->
    ok.

metrics(Format, Status, #{route := Route} = Out, Result) ->
    L = [{route, Route}, {format, Format}],
    lg_metrics:inc(litegate_requests_total, [{status, Status} | L]),
    lg_metrics:observe(litegate_request_duration_seconds, L,
                       lg_time:now_ms() - maps:get(started_at, Out)),
    case maps:find(ttft_ms, Out) of
        {ok, T} -> lg_metrics:observe(litegate_ttft_seconds, L, T);
        error -> ok
    end,
    Usage = maps:get(usage, Result, #{}),
    _ = [lg_metrics:inc(litegate_tokens_total, [{route, Route}, {type, T}], maps:get(T, Usage, 0))
         || T <- [input, output, cache_read, cache_write]],
    lg_metrics:inc(litegate_cost_usd_total, [{route, Route}], round(maps:get(cost, Out, 0.0) * 1.0e6)),
    case maps:get(error, Out, undefined) of
        {rate_limited, Reason, _, _} -> lg_metrics:inc(litegate_rate_limited_total, [{reason, Reason}]);
        {budget_exceeded, _, _} -> lg_metrics:inc(litegate_rate_limited_total, [{reason, budget}]);
        {plan_exhausted, _} -> lg_metrics:inc(litegate_rate_limited_total, [{reason, plan}]);
        _ -> ok
    end.

%% 请求失败（开流前）或流中途出错
error_info(#{error := #{kind := K, message := M}}, _) -> #{kind => K, message => M};
error_info(#{error := E}, _) when is_atom(E) -> #{kind => E};
error_info(#{error := {rate_limited, R, _, _}}, _) -> #{kind => rate_limited, message => atom_to_binary(R)};
error_info(#{error := {budget_exceeded, _, _}}, _) -> #{kind => budget_exceeded};
error_info(#{error := {plan_exhausted, _}}, _) -> #{kind => plan_exhausted};
error_info(#{error := {unsupported_operation, Op}}, _) -> #{kind => unsupported_operation, message => Op};
error_info(#{error := {middleware_rejected, _, Msg}}, _) -> #{kind => middleware_rejected, message => Msg};
error_info(_, #{error := E}) when is_map(E) -> #{kind => stream, detail => E};
error_info(_, _) -> undefined.
