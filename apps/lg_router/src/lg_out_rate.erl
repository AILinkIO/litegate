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

-export([start_link/0, record/1, allow/1, allow/2, rate/1, on_rate_limit/2, on_success/1,
         snapshot/0, reset/1, reset/0, reset_credential/1, wait/3, wait/4, state/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include_lib("lg_core/include/lg_core.hrl").

-define(WIN, lg_out_rate_win).
-define(STATE, lg_out_rate_state).
-define(SWEEP_MS, 60000).
-define(STATE_TTL_MS, 24 * 3600 * 1000).  %% 学习状态 24h 无更新回收
-define(RESERVED, {?MODULE, reserved}).    %% 进程字典：allow/1 已为该目标预占的计数

-type tkey() :: {binary(), binary()}.  %% {CredentialId, UpstreamModel}

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc 热路径：对目标发起一次上游请求时 +1（ets:update_counter 原子操作）。
%% 本进程刚由 allow/1 为同一目标预占过计数时不重复计数。
-spec record(tkey()) -> ok.
record(Key) ->
    case erase(?RESERVED) of
        Key -> ok;
        _ -> _ = catch bump(Key, 1), ok
    end.

bump(Key, N) ->
    Bucket = {Key, lg_time:now_ms() div 60000},
    ets:update_counter(?WIN, Bucket, N, {Bucket, 0}).

%% @doc 发送前判定：速率是否允许。ok | {throttle, RetryMs}。
%% 判定顺序：硬暂停 → 学习 Cap → 静态 max_rpm。
-spec allow(tkey()) -> ok | {throttle, pos_integer()}.
allow(Key) ->
    allow(Key, undefined).

%% @doc 同 allow/1，Cred 为调用方已有的凭证记录（尝试计划里带着），省去每次尝试查一次凭证（T32）；
%% undefined 时按 Key 查。
-spec allow(tkey(), #lg_credential{} | undefined) -> ok | {throttle, pos_integer()}.
allow(Key, Cred) ->
    case lg_config:get(out_rate_enabled) of
        false -> ok;
        true -> check_allow(Key, Cred)
    end.

%% @doc 排队等待到窗口滚动后重试（复用 lg_conc:wait 的分段 sleep 模式）。
%% 返回 ok | {error, timeout}；draining 时提前退出。
-spec wait(tkey(), pos_integer(), fun(() -> term()) | undefined) -> ok | {error, timeout}.
wait(Key, RetryMs, IdleCb) ->
    wait(Key, undefined, RetryMs, IdleCb).

-spec wait(tkey(), #lg_credential{} | undefined, pos_integer(), fun(() -> term()) | undefined) -> ok | {error, timeout}.
wait(Key, Cred, RetryMs, IdleCb) ->
    Deadline = lg_time:now_ms() + min(RetryMs, lg_config:get(queue_wait_ms)),
    wait_loop(Key, Cred, Deadline, IdleCb).

wait_loop(Key, Cred, Deadline, IdleCb) ->
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
            case allow(Key, Cred) of
                ok -> ok;
                {throttle, _} -> wait_loop(Key, Cred, Deadline, IdleCb)
            end
    end.

%% 有上限时放行即预占（计数 +1 后超限则回滚）：并发判定、排队者在窗口滚动时一起轮询，
%% 都不会超过上限放行（T17）。预占记在进程字典，紧随其后的 record/1 不再重复计数。
reserve(Key, Limit, Now) ->
    _ = erase(?RESERVED),
    _ = bump(Key, 1),
    case rate(Key) > Limit of
        true ->
            _ = bump(Key, -1),
            {throttle, window_retry_ms(Now)};
        false ->
            put(?RESERVED, Key),
            ok
    end.

check_allow(Key, Cred) ->
    Now = lg_time:now_ms(),
    St = state_of(Key),
    case St of
        #{paused_until := Until} when is_integer(Until), Until > Now ->
            {throttle, Until - Now};
        _ ->
            case effective_limit(Key, Cred, St) of
                N when is_integer(N), N > 0 -> reserve(Key, N, Now);
                _ -> ok
            end
    end.

%% 生效上限：min(学习 Cap, 凭证静态 max_rpm)；两者均无时 undefined（不限）
effective_limit(Key, Cred, St) ->
    MaxRpm = credential_max_rpm(Key, Cred),
    case St of
        #{cap := Cap} when is_integer(Cap), Cap > 0 ->
            case MaxRpm of
                N when is_integer(N), N > 0 -> min(Cap, N);
                _ -> Cap
            end;
        _ -> MaxRpm
    end.

%% 凭证选项中的静态 max_rpm（调用方给了凭证记录时直接用，否则按 Key 查）
credential_max_rpm(_Key, #lg_credential{options = O}) ->
    case maps:get(max_rpm, O, undefined) of
        N when is_integer(N), N > 0 -> N;
        _ -> undefined
    end;
credential_max_rpm({CId, _} = Key, undefined) ->
    case catch lg_credentials:get(CId) of
        {ok, #lg_credential{} = C} -> credential_max_rpm(Key, C);
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
%% Observed 取本次 429 时的滑动窗口速率（record/1 已计入本次请求）。
-spec on_rate_limit(tkey(), non_neg_integer() | undefined) -> ok.
on_rate_limit(Key, RetryAfterMs) ->
    Now = lg_time:now_ms(),
    St = state_of(Key),
    St1 = step_429(St#{observed => max(1, rate(Key))}, RetryAfterMs, Now),
    save_state(Key, St1),
    case {maps:get(cap, St), maps:get(cap, St1)} of
        {Old, Cap} when is_integer(Cap), Cap =/= Old ->
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
            case step_ok(St, Now) of
                St -> ok;
                St1 -> save_state(Key, St1)
            end;
        _ ->
            ok
    end.

%% @doc 目标的学习状态（控制台 / 测试用）。
-spec state(tkey()) -> map().
state(Key) ->
    state_of(Key).

%% state 条目：{Key, Cap, PausedUntil, Streak, Last429At, UpdatedAt, Observed, LastCutAt, RaisedAt}
%%   Last429At  最近一次 429 的时间（回升 / 解除都以它为起点，回升不重置）
%%   Observed   最近一次 429 时的实测速率（首犯 Cap 的基数、解除判据）
%%   LastCutAt  最近一次下调 Cap 的时间（同一波并发 429 只下调一次）
%%   RaisedAt   最近一次回升的时间（两次回升至少间隔 RecoveryMs）
state_of(Key) ->
    case ets:lookup(?STATE, Key) of
        [{_, Cap, Paused, Streak, Last429, _, Observed, LastCut, Raised}] ->
            #{cap => Cap, paused_until => Paused, streak => Streak, last_429_at => Last429,
              observed => Observed, last_cut_at => LastCut, raised_at => Raised};
        [] ->
            #{cap => undefined, paused_until => undefined, streak => 0, last_429_at => undefined,
              observed => 0, last_cut_at => undefined, raised_at => undefined}
    end.

save_state(Key, #{cap := Cap, paused_until := Paused, streak := Streak, last_429_at := Last429,
                  observed := Observed, last_cut_at := LastCut, raised_at := Raised}) ->
    true = ets:insert(?STATE, {Key, Cap, Paused, Streak, Last429, lg_time:now_ms(), Observed, LastCut, Raised}),
    ok.

%% 纯函数：429 后的 state 转移
step_429(#{last_cut_at := LastCut, cap := Cap} = St, RetryAfterMs, Now)
  when is_integer(LastCut), is_integer(Cap) ->
    case Now - LastCut < cut_gap_ms() of
        %% 同一波并发请求的 429（窗口内已下调过）：只更新 429 时间与暂停，不再减半
        true -> pause(St#{last_429_at => Now}, RetryAfterMs, Now);
        false -> cut(St, RetryAfterMs, Now)
    end;
step_429(St, RetryAfterMs, Now) ->
    cut(St, RetryAfterMs, Now).

cut(#{cap := Cap, streak := Streak, observed := Observed} = St, RetryAfterMs, Now) ->
    MinCap = lg_config:get(out_rate_min_rpm),
    Cap1 = case Cap of
               %% 首犯（含先收到过带 Retry-After 的 429）：Cap = max(MinCap, Observed × Factor)
               undefined -> max(MinCap, round(Observed * lg_config:get(out_rate_factor)));
               %% 再犯：减半，MinCap 保底
               _ -> max(MinCap, Cap bsr 1)
           end,
    pause(St#{cap => Cap1, streak => Streak + 1, last_429_at => Now, last_cut_at => Now,
              raised_at => undefined}, RetryAfterMs, Now).

%% 有 Retry-After：硬暂停最准（上游明说何时回来），同时照常建立 / 下调 Cap
pause(St, RetryAfterMs, Now) when is_integer(RetryAfterMs), RetryAfterMs > 0 ->
    St#{paused_until => Now + RetryAfterMs};
pause(St, _RetryAfterMs, _Now) ->
    St.

%% 同一波 429 的去重窗口：min(1s, RecoveryMs / 10)
cut_gap_ms() ->
    min(1000, lg_config:get(out_rate_recovery_ms) div 10).

%% 纯函数：成功后的 state 转移（加性回升 + 解除条件）
step_ok(#{cap := Cap, last_429_at := Last429, raised_at := Raised, observed := Observed} = St, Now) ->
    RecoveryMs = lg_config:get(out_rate_recovery_ms),
    Since = case {Last429, Raised} of
                {undefined, undefined} -> Now;
                {undefined, R} -> R;
                {L, undefined} -> L;
                {L, R} -> max(L, R)
            end,
    case Now - Since >= RecoveryMs of
        false ->
            St;
        true ->
            %% 距上次 429 / 上次回升都超过 RecoveryMs：Cap +10%
            Cap1 = Cap + max(1, round(Cap * 0.1)),
            Quiet = case Last429 of undefined -> RecoveryMs * 4; _ -> Now - Last429 end,
            case Cap1 >= Observed * 1.5 orelse (Quiet >= RecoveryMs * 4 andalso Cap1 >= Observed) of
                true ->
                    %% Cap 远超 429 时的速率，或持续 4×RecoveryMs 无 429 且已回到 429 时的速率：完全解除
                    #{cap => undefined, paused_until => undefined, streak => 0, last_429_at => undefined,
                      observed => 0, last_cut_at => undefined, raised_at => undefined};
                false ->
                    St#{cap => Cap1, streak => 0, raised_at => Now}
            end
    end.

-spec reset() -> ok.
reset() ->
    true = ets:delete_all_objects(?WIN),
    true = ets:delete_all_objects(?STATE),
    ok.

%% @doc 清空指定凭证所有目标的学习状态（凭证配置更新时调用）。
-spec reset_credential(binary()) -> ok.
reset_credential(CId) ->
    %% WIN 对象 {{{CId, Model}, Minute}, N}；STATE 对象 9 元组，键为 {CId, Model}
    ets:match_delete(?WIN, {{{CId, '_'}, '_'}, '_'}),
    ets:match_delete(?STATE, setelement(1, erlang:make_tuple(9, '_'), {CId, '_'})),
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

%% 删除 2 分钟前的桶（当前桶与上一分钟桶保留）；WIN 对象 {{Key, Minute}, N}
%% 学习状态 24h 无更新（期间既无 429 也无回升）回收
sweep() ->
    Now = lg_time:now_ms(),
    Old = Now div 60000 - 2,
    _ = ets:select_delete(?WIN, [{{{'_', '$1'}, '_'}, [{'<', '$1', Old}], [true]}]),
    _ = ets:select_delete(?STATE, [{setelement(6, erlang:make_tuple(9, '_'), '$1'),
                                    [{'<', '$1', Now - ?STATE_TTL_MS}], [true]}]),
    ok.
