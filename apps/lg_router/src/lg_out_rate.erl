%% @doc 出站速率观测（自适应限流 Phase 1，T08）：按 {凭证, 模型} 的分钟分桶滑动窗口计数。
%%
%% 热路径 `record/1` 只做一次 `ets:update_counter`，无进程调用。
%% gen_server 仅负责 60s 周期清扫（删除 2 分钟前的桶）与 gauge 注册。
%% T09：AIMD 反馈节流 — 429 时自动收紧 Cap、恢复后自动放开，对所有模型统一生效。
%%
%% 滑动窗口近似（对照 lg_limiter）：
%%   qpm = 上一分钟计数 × (1 - 本分钟已过比例) + 本分钟计数
-module(lg_out_rate).
-behaviour(gen_server).

-export([start_link/0, record/1, allow/1, rate/1, on_rate_limit/2, on_success/1,
         snapshot/0, reset/1, reset/0, reset_credential/1, wait/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include_lib("lg_core/include/lg_core.hrl").

-define(WIN, lg_out_rate_win).
-define(STATE, lg_out_rate_state).
-define(SWEEP_MS, 60000).

-type tkey() :: {binary(), binary()}.  %% {CredentialId, UpstreamModel}

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc 热路径：对目标发起一次上游请求时 +1（ets:update_counter 原子操作）。
-spec record(tkey()) -> ok.
record(Key) ->
    Bucket = {Key, lg_time:now_ms() div 60000},
    _ = catch ets:update_counter(?WIN, Bucket, 1, {Bucket, 0}),
    ok.

%% @doc 发送前判定：速率是否允许。ok | {throttle, RetryMs}。
%% 判定顺序：硬暂停 → 学习 Cap → 静态 max_rpm。
-spec allow(tkey()) -> ok | {throttle, pos_integer()}.
allow(Key) ->
    case lg_config:get(out_rate_enabled) of
        false -> ok;
        true -> check_allow(Key)
    end.

%% @doc 排队等待到窗口滚动后重试（复用 lg_conc:wait 的分段 sleep 模式）。
%% 返回 ok | {error, timeout}；draining 时提前退出。
-spec wait(tkey(), pos_integer(), fun(() -> term()) | undefined) -> ok | {error, timeout}.
wait(Key, RetryMs, IdleCb) ->
    Deadline = lg_time:now_ms() + min(RetryMs, lg_config:get(queue_wait_ms)),
    wait_loop(Key, Deadline, IdleCb).

wait_loop(Key, Deadline, IdleCb) ->
    Now = lg_time:now_ms(),
    lg_shutdown:draining() andalso exit(shutdown),
    case Now >= Deadline of
        true -> {error, timeout};
        false ->
            Step = min(500, Deadline - Now),
            _ = case IdleCb of
                    undefined -> timer:sleep(Step);
                    F -> timer:sleep(Step), F()
                end,
            case allow(Key) of
                ok -> ok;
                {throttle, _} -> wait_loop(Key, Deadline, IdleCb)
            end
    end.

check_allow(Key) ->
    Now = lg_time:now_ms(),
    Limit = effective_limit(Key),
    case state_of(Key) of
        #{paused_until := Until} when is_integer(Until), Until > Now ->
            {throttle, Until - Now};
        #{cap := Cap} when is_integer(Cap), Cap > 0 ->
            QPM = rate(Key),
            case QPM >= Limit of
                true -> {throttle, window_retry_ms(Now)};
                false -> ok
            end;
        _ ->
            case Limit of
                N when is_integer(N), N > 0 ->
                    QPM = rate(Key),
                    case QPM >= N of
                        true -> {throttle, window_retry_ms(Now)};
                        false -> ok
                    end;
                _ -> ok
            end
    end.

%% 生效上限：min(学习 Cap, 凭证静态 max_rpm)；两者均无时 undefined（不限）
effective_limit({_, _} = Key) ->
    MaxRpm = credential_max_rpm(Key),
    case state_of(Key) of
        #{cap := Cap} when is_integer(Cap), Cap > 0 ->
            case MaxRpm of
                N when is_integer(N), N > 0 -> min(Cap, N);
                _ -> Cap
            end;
        _ -> MaxRpm
    end.

%% 凭证选项中的静态 max_rpm
credential_max_rpm({CId, _}) ->
    case catch lg_credentials:get(CId) of
        {ok, #lg_credential{options = O}} ->
            case maps:get(max_rpm, O, undefined) of
                N when is_integer(N), N > 0 -> N;
                _ -> undefined
            end;
        _ -> undefined
    end.

%% 当前分钟结束时刻 - 现在 = 窗口滚动剩余毫秒
window_retry_ms(Now) -> 60000 - Now rem 60000.

%% @doc 最近 1 分钟滑动窗口的出站 QPM（近似值）。
-spec rate(tkey()) -> non_neg_integer().
rate(Key) ->
    Now = lg_time:now_ms(),
    CurMin = Now div 60000,
    Prev = bucket_count(Key, CurMin - 1),
    Cur = bucket_count(Key, CurMin),
    Frac = (Now rem 60000) / 60000,
    %% 上分钟计数 × (1 - 已过比例) + 本分钟计数
    round(Prev * (1 - Frac) + Cur).

bucket_count(Key, Min) ->
    case ets:lookup(?WIN, {Key, Min}) of
        [{_, N}] -> N;
        [] -> 0
    end.

%% @doc 全部目标的当前 QPM 快照（控制台 / OTLP gauge 用）。
-spec snapshot() -> [{tkey(), non_neg_integer()}].
snapshot() ->
    Keys = lists:usort([K || {{K, _}, _} <- ets:tab2list(?WIN)]),
    [{K, rate(K)} || K <- Keys].

%% @doc 清空指定目标的学习状态（凭证配置更新时调用）。
-spec reset(tkey()) -> ok.
reset(Key) ->
    ets:match_delete(?WIN, {{Key, '_'}, '_'}),
    ets:delete(?STATE, Key),
    ok.

%%====================================================================
%% AIMD 控制律（T09）
%%====================================================================

%% @doc 上游 429 回调：AIMD 下调 — 首犯 ×Factor、再犯减半；有 Retry-After 时硬暂停。
-spec on_rate_limit(tkey(), non_neg_integer() | undefined) -> ok.
on_rate_limit(Key, RetryAfterMs) ->
    Now = lg_time:now_ms(),
    St = state_of(Key),
    St1 = step_429(St#{ok_since => Now}, RetryAfterMs),
    save_state(Key, St1),
    case maps:find(cap, St1) of
        {ok, Cap} when is_integer(Cap) ->
            logger:notice("out_rate: ~p rate limited, cap=~b", [Key, Cap]);
        _ -> ok
    end,
    ok.

%% @doc 上游成功回调：仅在 Cap 已建立时回升。
-spec on_success(tkey()) -> ok.
on_success(Key) ->
    Now = lg_time:now_ms(),
    case state_of(Key) of
        #{cap := Cap} = St when is_integer(Cap), Cap > 0 ->
            St1 = step_ok(St, Now),
            save_state(Key, St1);
        _ ->
            ok
    end.

%% state 条目：{Key, Cap, PausedUntil, Streak, OkSince, UpdatedAt}
state_of(Key) ->
    case ets:lookup(?STATE, Key) of
        [{_, Cap, Paused, Streak, OkSince, _}] ->
            #{cap => Cap, paused_until => Paused, streak => Streak, ok_since => OkSince};
        [] ->
            #{cap => undefined, paused_until => undefined, streak => 0, ok_since => undefined}
    end.

save_state(Key, #{cap := Cap, paused_until := Paused, streak := Streak, ok_since := OkSince}) ->
    true = ets:insert(?STATE, {Key, Cap, Paused, Streak, OkSince, lg_time:now_ms()}),
    ok.

%% 纯函数：429 后的 state 转移
step_429(#{paused_until := _Paused, streak := Streak} = St, RetryAfterMs)
  when is_integer(RetryAfterMs), RetryAfterMs > 0 ->
    %% 有 Retry-After：硬暂停最准（上游明说何时回来）
    Now = lg_time:now_ms(),
    St#{paused_until => Now + RetryAfterMs, streak => Streak + 1};
step_429(#{cap := undefined, streak := 0} = St, _RA) ->
    %% 首犯且无 Cap：Cap = max(MinCap, Observed × Factor)
    MinCap = lg_config:get(out_rate_min_rpm),
    Factor = lg_config:get(out_rate_factor),
    Observed = max(1, maps:get(observed, St, 1)),
    Cap0 = max(MinCap, round(Observed * Factor)),
    St#{cap => Cap0, streak => 1};
step_429(#{cap := Cap, streak := Streak} = St, _RA) when is_integer(Cap) ->
    %% 再犯：Cap 减半，MinCap 保底
    MinCap = lg_config:get(out_rate_min_rpm),
    St#{cap => max(MinCap, Cap bsr 1), streak => Streak + 1};
step_429(St, _RA) ->
    St.

%% 纯函数：成功后的 state 转移（加性回升 + 解除条件）
step_ok(#{cap := Cap, ok_since := OkSince} = St, Now) ->
    RecoveryMs = lg_config:get(out_rate_recovery_ms),
    case OkSince of
        undefined -> St#{ok_since => Now};
        _ when Now - OkSince >= RecoveryMs ->
            %% 无 429 超过 RecoveryMs：Cap +10%
            Cap1 = Cap + max(1, round(Cap * 0.1)),
            Observed = maps:get(observed, St, 0),
            case Cap1 >= Observed * 1.5 andalso Now - OkSince >= RecoveryMs * 4 of
                true ->
                    %% 持续 4×RecoveryMs 无 429 且 Cap 超过健康峰值：完全解除
                    #{cap => undefined, paused_until => undefined, streak => 0, ok_since => undefined};
                false ->
                    St#{cap => Cap1, streak => 0, ok_since => Now}
            end;
        _ ->
            St
    end.

-spec reset() -> ok.
reset() ->
    true = ets:delete_all_objects(?WIN),
    true = ets:delete_all_objects(?STATE),
    ok.

%% @doc 清空指定凭证所有目标的学习状态（凭证配置更新时调用）。
-spec reset_credential(binary()) -> ok.
reset_credential(CId) ->
    ets:match_delete(?WIN, {{CId, '_'}, '_'}),
    ets:match_delete(?STATE, {CId, '_'}),
    ok.

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    ?WIN = ets:new(?WIN, [named_table, public, {write_concurrency, true}, {read_concurrency, true}]),
    ?STATE = ets:new(?STATE, [named_table, public, {write_concurrency, true}, {read_concurrency, true}]),
    lg_metrics:register_gauge(litegate_out_qpm, <<"Outbound requests per minute by credential and model">>,
                              fun() -> [{[C, M], QPM} || {{C, M}, QPM} <- snapshot()] end),
    _ = erlang:send_after(?SWEEP_MS, self(), sweep),
    {ok, #{}}.

handle_call(_Req, _From, S) ->
    {reply, ok, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(sweep, S) ->
    sweep(),
    _ = erlang:send_after(?SWEEP_MS, self(), sweep),
    {noreply, S};
handle_info(_Msg, S) ->
    {noreply, S}.

%% 删除 2 分钟前的桶（当前桶与上一分钟桶保留）
sweep() ->
    Old = lg_time:now_ms() div 60000 - 2,
    ets:select_delete(?WIN, [{{{'_', '_'}, '$1'}, [{'<', '$1', Old}], [true]}]),
    ok.
