%% @doc 上游目标冷却表（ETS）。目标失败后在一段时间内排到尝试顺序末尾。
%%
%% 按错误类型决定冷却时长与作用范围（{凭证, 模型} 或整个凭证 {凭证, '*'}）：
%%   credit      余额不足：30 分钟，整个凭证
%%   quota       额度用尽：到重置时刻（错误中解析 → 套餐窗口 → Retry-After → 15 分钟），上限 8 天，整个凭证
%%   rate_limit  Retry-After（上限 1 小时）；否则 route_cooldown_ms，连续再犯翻倍，上限 30 分钟
%%   auth        route_cooldown_ms × 6，连续再犯翻倍，上限 10 分钟，整个凭证
%%   unserved    该模型不可用（套餐不含 / 已下架）：route_cooldown_ms，连续再犯翻倍，上限 10 分钟，只冷却该模型
%%   其他        Retry-After（上限 1 小时）；否则 route_cooldown_ms，连续再犯翻倍，上限 10 分钟
%% 「连续再犯」：上次冷却结束后 2 倍冷却时长内再次同类失败；目标成功一次即清除。
-module(lg_cooldown).
-behaviour(gen_server).

-export([start_link/0, mark/2, cooling/1, clear/0, cooling_count/0, remaining_ms/1, reset/1,
         succeeded/1, recovered/1, recovered/2, info/1, duration/3, sweep/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, ?MODULE).
-define(MIN, 60000).
-define(HOUR, 3600000).
-define(DAY, 86400000).
-define(SWEEP_MS, 5 * 60000).

-type target_key() :: {binary(), binary()}.  %% {CredentialId, UpstreamModel}
%% mark/2 接受完整的上游错误，也接受余额轮询等本地合成的最小错误
-type mark_error() :: lg_llm_error:error()
                    | #{kind := lg_llm_error:kind(),
                        message => binary(),
                        retry_after_ms => non_neg_integer() | undefined,
                        reset_at => non_neg_integer() | undefined}.
%% 表项：{Key, Until, Kind, Streak, DurationMs, Reason}，Key 为 target_key() 或 {CredentialId, '*'}

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc 按错误类型冷却目标（额度、余额、鉴权错误冷却整个凭证）。
-spec mark(target_key(), mark_error()) -> ok.
mark({CredId, _} = Key0, #{kind := Kind} = Err) ->
    Key = case scope(Kind) of credential -> {CredId, '*'}; target -> Key0 end,
    Now = lg_time:now_ms(),
    Streak = case ets:lookup(?TAB, Key) of
                 [{_, Until, Kind, S, Dur, _}] when Now < Until + 2 * Dur -> S + 1;
                 _ -> 1
             end,
    Ms = duration(Kind, Err#{credential => CredId}, Streak),
    true = ets:insert(?TAB, {Key, Now + Ms, Kind, Streak, Ms, maps:get(message, Err, <<>>)}),
    ok.

%% @doc 冷却时长（毫秒）。Err 可带 credential（quota 时查套餐窗口的重置时刻）。
-spec duration(atom(), map(), pos_integer()) -> pos_integer().
duration(Kind, Err, Streak) ->
    Base = lg_config:get(route_cooldown_ms),
    RA = case maps:get(retry_after_ms, Err, undefined) of
             N when is_integer(N), N > 0 -> min(N, ?HOUR);
             _ -> undefined
         end,
    Grow = fun(B, Cap) -> min(Cap, B bsl min(Streak - 1, 20)) end,
    OutRateEnabled = lg_config:get(out_rate_enabled),
    Ms = case Kind of
             credit -> 30 * ?MIN;
             quota -> quota_ms(Err, RA);
             rate_limit when RA =/= undefined -> RA;
             %% T09：out_rate 启用时无 RA 的 rate_limit 不再翻倍（固定 Base），速率整形交给 AIMD
             rate_limit when OutRateEnabled -> Base;
             rate_limit -> Grow(Base, 30 * ?MIN);
             auth -> Grow(Base * 6, 10 * ?MIN);
             _ when RA =/= undefined -> RA;
             _ -> Grow(Base, 10 * ?MIN)
         end,
    max(1, Ms).

quota_ms(Err, RA) ->
    Now = lg_time:now_ms(),
    Plan = case maps:get(credential, Err, undefined) of
               undefined -> undefined;
               C -> plan_reset(C, Now)
           end,
    Ms = case {maps:get(reset_at, Err, undefined), Plan, RA} of
             {At, _, _} when is_integer(At), At > Now -> At - Now;
             {_, At, _} when is_integer(At) -> At - Now;
             {_, _, R} when is_integer(R) -> R;
             _ -> 15 * ?MIN
         end,
    min(Ms, 8 * ?DAY).

%% 套餐凭证中已用满（≥ 100%）窗口的最晚重置时刻
plan_reset(CredId, Now) ->
    case catch lg_plan:status(CredId) of
        #{windows := Ws} ->
            case [R || #{used_pct := U, resets_at := R} <- Ws, U >= 100, is_integer(R), R > Now] of
                [] -> undefined;
                Rs -> lists:max(Rs)
            end;
        _ -> undefined
    end.

scope(K) when K =:= credit; K =:= quota; K =:= auth -> credential;
scope(_) -> target.

-spec cooling(target_key()) -> boolean().
cooling(Key) ->
    remaining_ms(Key) > 0.

%% @doc 剩余冷却毫秒数（0 = 未冷却），同时考虑凭证级冷却。
-spec remaining_ms(target_key()) -> non_neg_integer().
remaining_ms({CredId, _} = Key) ->
    Now = lg_time:now_ms(),
    lists:max([0 | [Until - Now || K <- [Key, {CredId, '*'}], {_, Until, _, _, _, _} <- ets:lookup(?TAB, K)]]).

%% @doc 冷却详情（取剩余时间最长的一条）：#{remaining_ms, kind, reason, scope, streak}；未冷却时 undefined。
-spec info(target_key()) -> map() | undefined.
info({CredId, _} = Key) ->
    Now = lg_time:now_ms(),
    case lists:reverse(lists:keysort(2, [E || K <- [Key, {CredId, '*'}], {_, Until, _, _, _, _} = E <- ets:lookup(?TAB, K),
                                               Until > Now])) of
        [{K, Until, Kind, Streak, _, Reason} | _] ->
            #{remaining_ms => Until - Now, kind => Kind, reason => Reason, streak => Streak,
              scope => case K of {_, '*'} -> credential; _ -> target end};
        [] ->
            undefined
    end.

%% @doc 目标请求成功：清除它与所属凭证的冷却和连续失败计数。
-spec succeeded(target_key()) -> ok.
succeeded({CredId, _} = Key) ->
    true = ets:delete(?TAB, Key),
    true = ets:delete(?TAB, {CredId, '*'}),
    ok.

%% @doc 套餐额度已恢复（lg_plan 读到窗口重置）：解除凭证因额度用尽的冷却。
-spec recovered(binary()) -> ok.
recovered(CredId) ->
    recovered(CredId, quota).

%% @doc 解除凭证因某类原因（quota：套餐额度；credit：余额）的冷却。
-spec recovered(binary(), quota | credit) -> ok.
recovered(CredId, Kind) ->
    case ets:lookup(?TAB, {CredId, '*'}) of
        [{_, _, Kind, _, _, _}] -> true = ets:delete(?TAB, {CredId, '*'}), ok;
        _ -> ok
    end.

%% @doc 手动解除某个目标的冷却（连同凭证级冷却）。
-spec reset(target_key()) -> ok.
reset(Key) ->
    succeeded(Key).

%% @doc 当前处于冷却中的条目数（指标用）。
-spec cooling_count() -> non_neg_integer().
cooling_count() ->
    Now = lg_time:now_ms(),
    ets:select_count(?TAB, [{{'_', '$1', '_', '_', '_', '_'}, [{'>', '$1', Now}], [true]}]).

-spec clear() -> ok.
clear() ->
    true = ets:delete_all_objects(?TAB),
    ok.

init([]) ->
    ?TAB = ets:new(?TAB, [named_table, public, {read_concurrency, true},
                          {write_concurrency, true}]),
    lg_metrics:register_gauge(litegate_cooling_targets, <<"Upstream targets in cooldown">>,
                              fun() -> [{[], cooling_count()}] end),
    %% 首次调度；之后由 handle_info(sweep) 自行续期（T19：此前缺少首次调度，清扫从未运行）
    {ok, #{sweep => erlang:send_after(?SWEEP_MS, self(), sweep)}}.

handle_call(_Req, _From, S) ->
    {reply, ok, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(sweep, S) ->
    sweep(),
    {noreply, S#{sweep => erlang:send_after(?SWEEP_MS, self(), sweep)}};
handle_info(_Msg, S) ->
    {noreply, S}.

%% 清除「连续再犯窗口已过」的条目：Now > Until + 2*Duration 时再次同类失败 streak 从 1 重计（与惰性覆盖语义一致）
sweep() ->
    Now = lg_time:now_ms(),
    ets:select_delete(?TAB,
        [{{'_', '$1', '_', '_', '$2', '_'},
          [{'>', Now, {'+', '$1', {'*', 2, '$2'}}}],
          [true]}]),
    ok.
