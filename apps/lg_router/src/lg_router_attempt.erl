%% @doc 路由执行：attempt 轮次、并发名额、失败回退与 outcome 记账。
%%
%% 输入是 `lg_router_plan` 展开后的候选；输出上游结果或带 attempt 列表的 outcome。
%% `lg_router` 保留请求门面、准入、缓存与请求调整。
-module(lg_router_attempt).

-include_lib("lg_core/include/lg_core.hrl").

-export([attempt_rounds/7, attempt/6, finalize/2, release_conc/1]).

%% 开流前等待总上限（stream_hold_max_ms）：超过后不再尝试新候选，直接以 504 结束，
%% 免得客户端只收到一串注释帧却永远等不到开流。chat 路径不带 hold_started，不受影响。
attempt(Plan, Client, Req, Ctx, Call, Out) ->
    case hold_expired(Ctx) of
        true -> {error, hold_error(), Out};
        false -> attempt_plan(Plan, Client, Req, Ctx, Call, Out)
    end.

hold_expired(#{hold_started := T}) ->
    Max = lg_config:get(stream_hold_max_ms),
    Max > 0 andalso lg_time:now_ms() - T >= Max;
hold_expired(_) ->
    false.

hold_error() ->
    #{kind => timeout, status => 504, retryable => true, retry_after_ms => 1000, upstream => undefined,
      message => <<"Upstream did not start streaming within the hold limit">>}.

%% 成功回答后记下会话所在的目标与读到的缓存
remember(#{session := Sid, route := Route, credential := C, upstream_model := M}, #{usage := U} = Result) ->
    case maps:get(error, Result, undefined) of
        undefined -> lg_affinity:put_target(Route, Sid, {C, M}, maps:get(cache_read, U, 0));
        _ -> ok
    end;
remember(_Out, _Result) ->
    ok.

%% 整轮重试：一轮的所有候选都以「繁忙」类错误失败（客户端还没收到任何内容）时，等待 patience_ms 后按原顺序再试，
%% 最多 patience_rounds 轮。额度用尽、余额不足、鉴权、请求错误、并发排队超时不算繁忙
attempt_rounds(Plan, Client, Req, Ctx, Call, Out0, Round) ->
    Before = length(maps:get(attempts, Out0)),
    case attempt(Plan, Client, Req, Ctx, Call, Out0) of
        {error, E, Out} = Err ->
            ThisRound = lists:nthtail(Before, maps:get(attempts, Out)),
            Wait = lg_config:get(patience_ms),
            case Round < lg_config:get(patience_rounds) andalso Wait > 0 andalso ThisRound =/= []
                andalso lists:all(fun busy_failure/1, ThisRound) andalso busy_kind(maps:get(kind, E, undefined))
                andalso not hold_expired(Ctx) andalso not lg_shutdown:draining() of
                true ->
                    logger:notice("route ~s: all ~b candidates busy, retrying in ~b ms",
                                  [maps:get(route, Out), length(ThisRound), Wait]),
                    case client_wait(fun() -> patience_wait(Wait, maps:get(idle, Ctx, undefined)) end) of
                        ok -> attempt_rounds(Plan, Client, Req, Ctx, Call, Out#{rounds => Round + 1, patience_ms => Wait}, Round + 1);
                        {error, CE} -> {error, CE, Out}
                    end;
                false ->
                    Err
            end;
        Ok ->
            Ok
    end.

busy_failure(#{busy := true}) -> false;
busy_failure(#{ok := false, kind := K}) -> busy_kind(K);
busy_failure(_) -> false.

busy_kind(K) -> lists:member(K, [server, timeout, network, rate_limit]).

%% 等待期间流式请求照常写保活帧（idle 回调每 250ms 一次，客户端断开时抛出 client_exit）；节点关停时提前结束
patience_wait(Ms, Idle) ->
    Step = min(Ms, 250),
    timer:sleep(Step),
    idle(Idle),
    case Ms - Step of
        Left when Left > 0 -> lg_shutdown:draining() orelse patience_wait(Left, Idle), ok;
        _ -> ok
    end.

%% 等待回调：client_exit 继续抛出，其余异常忽略（写保活帧失败不影响请求）
idle(undefined) -> ok;
idle(F) ->
    try F() catch throw:{client_exit, _} = E -> throw(E); _:_ -> ok end,
    ok.

%% T20：等待回调在客户端断开时抛出 {client_exit, _}（排队、patience、等待上游响应头时）。
%% 捕获后以 client_closed 错误结束：不再尝试后续候选、不计入目标健康；上游流已由 lg_http 取消，
%% 名额由调用方照常归还，日志 499 与记账由 lg_web 完成
client_wait(Fun) ->
    try Fun() catch throw:{client_exit, _} -> {error, closed_error()} end.

closed_error() ->
    #{kind => client_closed, status => 499, retryable => false, retry_after_ms => undefined, upstream => undefined,
      message => <<"Client closed the connection before the upstream replied">>}.

%% 凭证有并发上限时先占名额：满了且后面还有未满的候选 → 跳过（不冷却）；否则排队等待
attempt_plan([{RouteName, T, Cred} | Rest], Client, Req, Ctx, Call, Out) ->
    %% T09：先检查出站速率（节流），再检查并发
    case lg_out_rate:allow(lg_router_plan:tkey(T), Cred) of
        {throttle, RetryMs} ->
            rate_throttled([{RouteName, T, Cred} | Rest], Client, Req, Ctx, Call, Out, RetryMs);
        ok ->
            attempt_plan_conc([{RouteName, T, Cred} | Rest], Client, Req, Ctx, Call, Out)
    end.

attempt_plan_conc([{RouteName, T, Cred} | Rest], Client, Req, Ctx, Call, Out) ->
    case lg_conc:max_of(Cred) of
        0 ->
            attempt_held([{RouteName, T, Cred} | Rest], Client, Req, Ctx, Call, Out);
        Max ->
            #lg_credential{id = CId} = Cred,
            case lg_conc:acquire(CId, Max) of
                ok ->
                    attempt_held([{RouteName, T, Cred} | Rest], Client, Req, Ctx, Call, Out#{conc => CId});
                busy ->
                    Skip = lists:any(fun({_, _, C2}) -> not lg_router_plan:conc_full(C2) end, Rest),
                    Info = #{route => RouteName, credential => CId, upstream_model => maps:get(upstream_model, T),
                             started_at => lg_time:now_ms(), duration_ms => 0, ok => false, busy => true},
                    case Skip of
                        true ->
                            attempt(Rest, Client, Req, Ctx, Call, Out#{attempts => maps:get(attempts, Out) ++ [Info]});
                        false ->
                            T0 = lg_time:now_ms(),
                            Res = client_wait(fun() -> lg_conc:wait(CId, Max, lg_config:get(queue_wait_ms),
                                                                     maps:get(idle, Ctx, undefined)) end),
                            Out1 = Out#{queued_ms => maps:get(queued_ms, Out, 0) + lg_time:now_ms() - T0},
                            case Res of
                                ok ->
                                    attempt_held([{RouteName, T, Cred} | Rest], Client, Req, Ctx, Call, Out1#{conc => CId});
                                {error, CE} ->
                                    {error, CE, (with_target(Out1, T, Cred))#{attempts => maps:get(attempts, Out1) ++ [Info]}};
                                _ ->
                                    {error, concurrency_error(Res),
                                     (with_target(Out1, T, Cred))#{attempts => maps:get(attempts, Out1) ++ [Info]}}
                            end
                    end
            end
    end.

%% T09：目标被自适应节流 — 有候选 → 跳过（busy attempt）；唯一候选 → 快速失败 429
rate_throttled([{RouteName, T, Cred} | Rest], Client, Req, Ctx, Call, Out, RetryMs) ->
    CId = Cred#lg_credential.id,
    Info = #{route => RouteName, credential => CId, upstream_model => maps:get(upstream_model, T),
             started_at => lg_time:now_ms(), duration_ms => 0, ok => false, busy => true},
    Skip = lists:any(fun({_, _, C2}) -> not lg_router_plan:conc_full(C2) end, Rest),
    case Skip of
        true ->
            lg_metrics:inc(litegate_out_throttled_total,
                           [{credential, CId}, {model, maps:get(upstream_model, T)}]),
            attempt(Rest, Client, Req, Ctx, Call, Out#{attempts => maps:get(attempts, Out) ++ [Info]});
        false ->
            lg_metrics:inc(litegate_out_throttled_total,
                           [{credential, CId}, {model, maps:get(upstream_model, T)}]),
            %% T11：queue 策略（默认）等待窗口滚动；fail 策略立即 429
            case lg_config:get(out_rate_wait) of
                queue ->
                    Idle = maps:get(idle, Ctx, undefined),
                    T0 = lg_time:now_ms(),
                    case client_wait(fun() -> lg_out_rate:wait(lg_router_plan:tkey(T), Cred, RetryMs, Idle) end) of
                        ok ->
                            Out1 = Out#{queued_ms => maps:get(queued_ms, Out, 0) + lg_time:now_ms() - T0},
                            %% 保留后续候选：该目标排队后再失败仍可回退（T17）
                            attempt_plan_conc([{RouteName, T, Cred} | Rest], Client, Req, Ctx, Call,
                                              Out1#{attempts => maps:get(attempts, Out1) ++ [Info]});
                        {error, #{kind := client_closed} = CE} ->
                            {error, CE, (with_target(Out, T, Cred))#{attempts => maps:get(attempts, Out) ++ [Info]}};
                        {error, timeout} ->
                            {error, #{kind => rate_limit, status => 429, retryable => false,
                                      retry_after_ms => RetryMs, upstream => undefined,
                                      message => <<"Upstream target throttled; timed out waiting in queue">>},
                             (with_target(Out, T, Cred))#{attempts => maps:get(attempts, Out) ++ [Info]}}
                    end;
                _ ->
                    {error, #{kind => rate_limit, status => 429, retryable => false,
                              retry_after_ms => RetryMs, upstream => undefined,
                              message => <<"Upstream target throttled by adaptive rate limiter">>},
                     (with_target(Out, T, Cred))#{attempts => maps:get(attempts, Out) ++ [Info]}}
            end
    end.

concurrency_error(Why) ->
    #{kind => concurrency, status => 429, retryable => false, retry_after_ms => 1000, upstream => undefined,
      message => case Why of
                     full -> <<"Upstream concurrency limit reached and the queue is full">>;
                     timeout -> <<"Upstream concurrency limit reached; timed out waiting in queue">>
                 end}.

%% 释放名额：同步请求在上游返回后释放；流式请求开流成功后保留，由 finalize/2 释放
release_conc(#{conc := CId} = Out) ->
    lg_conc:release(CId),
    maps:remove(conc, Out);
release_conc(Out) ->
    Out.

attempt_held([{RouteName, T, Cred} | Rest], Client, Req, Ctx, Call, Out0) ->
    Target0 = #{credential => Cred,
                upstream_model => maps:get(upstream_model, T),
                default_max_tokens => lg_router:default_max_tokens(T),
                client_headers => maps:get(client_headers, Ctx, []),
                loop_guard => maps:get(loop_guard, Ctx, true)},
    Target = case maps:find(idle, Ctx) of
                 {ok, F} -> Target0#{idle => F};
                 error -> Target0
             end,
    T0 = lg_time:now_ms(),
    LiveId = maps:get(id, Ctx, undefined),
    LiveInfo = #{route => RouteName, credential => Cred#lg_credential.id,
                 credential_name => Cred#lg_credential.name, upstream_model => maps:get(upstream_model, T)},
    lg_live:attempt_start(LiveId, LiveInfo),
    lg_out_rate:record(lg_router_plan:tkey(T)),
    Res = client_wait(fun() -> Call(Client, Req, Target) end),
    lg_live:attempt_end(LiveId, LiveInfo#{ok => element(1, Res) =:= ok, duration_ms => lg_time:now_ms() - T0,
                                          kind => case Res of {error, #{kind := EK0}} -> EK0; _ -> null end}),
    Out = case Res of
              {ok, _, undefined} -> Out0;     %% 流式：开流成功，名额留到流结束
              _ -> release_conc(Out0)
          end,
    Outcome = case Res of
                  {ok, _, _} -> ok;
                  {error, #{kind := K}} -> K
              end,
    lg_metrics:inc(litegate_upstream_attempts_total,
                   [{credential, Cred#lg_credential.id}, {outcome, Outcome}]),
    Duration = lg_time:now_ms() - T0,
    %% 客户端断开不是目标的问题，不计入健康
    _ = Outcome =:= client_closed orelse
        lg_health:record(lg_router_plan:tkey(T), Outcome, Duration,
                         case Res of {error, #{message := M}} -> M; _ -> undefined end),
    %% 套餐凭证：用量变化后刷新额度；额度用尽 / 余额不足时立即重新查询，被限流时尽快重新查询
    case Outcome of
        QK when QK =:= quota; QK =:= credit -> lg_plan:exhausted(Cred#lg_credential.id),
                                               lg_balance:exhausted(Cred#lg_credential.id);
        rate_limit -> lg_plan:quota_error(Cred#lg_credential.id),
                      lg_out_rate:on_rate_limit(lg_router_plan:tkey(T),
                          case Res of {error, #{retry_after_ms := RA}} when is_integer(RA), RA > 0 -> RA; _ -> undefined end);
        ok -> lg_cooldown:succeeded(lg_router_plan:tkey(T)), lg_out_rate:on_success(lg_router_plan:tkey(T)),
              lg_plan:touched(Cred#lg_credential.id),
              lg_balance:touched(Cred#lg_credential.id),
              lg_unfit:clear_retired(Cred#lg_credential.id, maps:get(upstream_model, T));
        _ -> lg_plan:touched(Cred#lg_credential.id)
    end,
    Info0 = #{route => RouteName, credential => Cred#lg_credential.id,
              upstream_model => maps:get(upstream_model, T),
              started_at => T0, duration_ms => Duration},
    Info = case Res of
               {error, #{kind := EK, message := EM}} -> Info0#{ok => false, kind => EK, message => EM};
               _ -> Info0#{ok => element(1, Res) =:= ok}
           end,
    Out1 = (with_target(Out, T, Cred))#{attempts => maps:get(attempts, Out) ++ [Info]},
    case Res of
        {ok, Body, Result} ->
            {ok, Body, maybe_finalize(Out1, Result)};
        {error, #{kind := Kind, status := Status, message := Msg} = E} ->
            %% 上游宣告模型退役（410 / 退役措辞）：记入 lg_unfit，本周从尝试顺序剔除；换下一个目标
            Retired = lg_unfit:retired_error(Status, Msg),
            ok = case Retired of
                     true -> lg_unfit:retire(Cred#lg_credential.id, maps:get(upstream_model, T), Msg);
                     false -> ok
                 end,
            case lg_llm_error:retryable(E) orelse Kind =:= auth orelse Retired of
                true ->
                    lg_cooldown:mark(lg_router_plan:tkey(T), E),
                    logger:warning("route ~s: target ~s/~s failed (~p), ~b left",
                                   [RouteName, Cred#lg_credential.id, maps:get(upstream_model, T),
                                    Kind, length(Rest)]),
                    %% 节点关停中不再换候选：尽快结束并记账
                    case Rest =:= [] orelse lg_shutdown:draining() of
                        true -> {error, E, Out1};
                        false -> attempt(Rest, Client, Req, Ctx, Call, Out1)
                    end;
                false ->
                    {error, E, Out1}
            end
    end.

with_target(Out, T, #lg_credential{id = CId} = Cred) ->
    O0 = Out#{credential => CId, upstream_model => maps:get(upstream_model, T)},
    O = case lg_plan:plan_of(Cred) of
            undefined -> maps:remove(plan, O0);
            _ -> O0#{plan => true}
        end,
    case maps:find(model_ref, T) of
        {ok, Ref} -> O#{model_ref => Ref};
        error -> maps:remove(model_ref, O)
    end.

maybe_finalize(Out, undefined) -> Out;   %% 流式：结束后由调用方 finalize/2
maybe_finalize(Out, Result) -> finalize(Out, Result).

%% @doc 记录上游结果并按目录定价计费。
-spec finalize(map(), lg_stream:result()) -> map().
finalize(Out0, #{usage := Usage} = Result) ->
    Out = release_conc(Out0),
    remember(Out, Result),
    case maps:find(credential, Out) of
        {ok, CId} -> lg_affinity:add_tokens(CId, maps:get(input, Usage, 0) + maps:get(output, Usage, 0));
        error -> ok
    end,
    Cost = case maps:find(model_ref, Out) of
               {ok, Ref} ->
                   case lg_catalog:pricing(Ref) of
                       {ok, P} -> lg_usage:cost(Usage, P);
                       not_found -> 0.0
                   end;
               error -> 0.0
           end,
    %% 套餐凭证不产生实际费用，按定价算出的费用记为套餐等价花费
    Costs = case maps:get(plan, Out, false) of
                true -> #{cost => 0.0, plan_usd => Cost};
                false -> #{cost => Cost}
            end,
    maps:merge(Out, Costs#{result => Result, duration_ms => lg_time:now_ms() - maps:get(started_at, Out)}).
