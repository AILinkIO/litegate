%% @doc 预算：按 Key / 用户累计本期花费，超出后拒绝。
%%
%% 花费计数：ETS {{Scope, Period, PeriodStartMs}, MicroUsd}，每次请求结束累加到
%% Key 与用户两个作用域的日 / 周 / 月三个周期（与预算配置无关，改预算周期立即生效）。
%% 启动时从 lg_store 的小时用量汇总重建本月与本周（周可能跨月）的花费。
%% 周期按 UTC 计算：日从 00:00，周从周一，月从 1 日。
-module(lg_budget).
-behaviour(gen_server).

-include_lib("lg_core/include/lg_core.hrl").

-export([start_link/0, check/2, add/4, spent/2, period_start/2, period_end/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, lg_budget_spend).
-define(SWEEP_MS, 3600000).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc 检查 Key、其所属用户与请求各标签的预算。
-spec check(#lg_api_key{}, [binary()]) -> ok | {error, {budget_exceeded, lg_budget_scope(), ResetAtMs :: integer()}}.
check(#lg_api_key{id = K, user_id = U}, Tags) ->
    Scopes = [{key, K}] ++ [{user, U} || is_binary(U)] ++ [{tag, T} || T <- Tags],
    Now = lg_time:now_ms(),
    check_scopes(Scopes, Now).

%% @doc 请求结束后累加花费（美元）到 Key、用户与各标签。
-spec add(binary() | undefined, binary() | undefined, [binary()], number()) -> ok.
add(_KeyId, _UserId, _Tags, Cost) when Cost =< 0 ->
    ok;
add(KeyId, UserId, Tags, Cost) ->
    Micro = round(Cost * 1.0e6),
    Now = lg_time:now_ms(),
    Scopes = [{key, KeyId} || is_binary(KeyId)] ++ [{user, UserId} || is_binary(UserId)] ++ [{tag, T} || T <- Tags],
    _ = [bump({S, P, period_start(P, Now)}, Micro) || S <- Scopes, P <- [day, week, month]],
    %% 设了预算的作用域上报本期花费（告警判定）
    _ = [lg_alert:budget(S, P, micro(S, P, period_start(P, Now)) / 1.0e6, Max)
         || S <- Scopes, {ok, #lg_budget{period = P, max_usd = Max}} <- [lg_db:read(lg_budget, S)]],
    ok.

%% @doc 本期已花费（美元）。
-spec spent(lg_budget_scope(), day | week | month) -> float().
spent(Scope, Period) ->
    micro(Scope, Period, period_start(Period, lg_time:now_ms())) / 1.0e6.

-spec period_start(day | week | month, integer()) -> integer().
period_start(day, Ms) ->
    Ms - Ms rem 86400000;
period_start(week, Ms) ->
    Day = Ms div 86400000,
    %% 1970-01-01 是周四：(Day + 3) rem 7 为距周一的天数
    (Day - (Day + 3) rem 7) * 86400000;
period_start(month, Ms) ->
    {{Y, M, _}, _} = calendar:system_time_to_universal_time(Ms, millisecond),
    to_ms({{Y, M, 1}, {0, 0, 0}}).

-spec period_end(day | week | month, integer()) -> integer().
period_end(day, Ms) -> period_start(day, Ms) + 86400000;
period_end(week, Ms) -> period_start(week, Ms) + 7 * 86400000;
period_end(month, Ms) ->
    {{Y, M, _}, _} = calendar:system_time_to_universal_time(Ms, millisecond),
    {Y1, M1} = case M of 12 -> {Y + 1, 1}; _ -> {Y, M + 1} end,
    to_ms({{Y1, M1, 1}, {0, 0, 0}}).

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    _ = ets:new(?TAB, [named_table, public, {write_concurrency, true}, {read_concurrency, true}]),
    rebuild(),
    erlang:send_after(?SWEEP_MS, self(), sweep),
    {ok, #{}}.

handle_call(_Req, _From, S) ->
    {reply, ok, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

%% 删除早于上个月的周期计数
handle_info(sweep, S) ->
    Cutoff = lg_time:now_ms() - 40 * 86400000,
    ets:select_delete(?TAB, [{{{'_', '_', '$1'}, '_'}, [{'<', '$1', Cutoff}], [true]}]),
    erlang:send_after(?SWEEP_MS, self(), sweep),
    {noreply, S};
handle_info(_Msg, S) ->
    {noreply, S}.

%%====================================================================
%% 内部函数
%%====================================================================

check_scopes([], _Now) ->
    ok;
check_scopes([Scope | Rest], Now) ->
    case lg_db:read(lg_budget, Scope) of
        {ok, #lg_budget{period = P, max_usd = Max}} ->
            case micro(Scope, P, period_start(P, Now)) >= Max * 1.0e6 of
                true -> {error, {budget_exceeded, Scope, period_end(P, Now)}};
                false -> check_scopes(Rest, Now)
            end;
        not_found ->
            check_scopes(Rest, Now)
    end.

%% 从小时汇总重建：覆盖本周与本月中较早的起点（读每小时费用分解，见 lg_store:usage_costs/2）
rebuild() ->
    Now = lg_time:now_ms(),
    From = min(period_start(week, Now), period_start(month, Now)),
    lists:foreach(
      fun({HourMs, Costs}) ->
              [bump({S, P, period_start(P, HourMs)}, round(Cost * 1.0e6))
               || S := Cost <- Costs, P <- [day, week, month]]
      end, lg_store:usage_costs(From, Now + 1)).

micro(Scope, Period, Start) ->
    case ets:lookup(?TAB, {Scope, Period, Start}) of
        [{_, N}] -> N;
        [] -> 0
    end.

bump(Key, N) ->
    ets:update_counter(?TAB, Key, N, {Key, 0}).

to_ms(DateTime) ->
    (calendar:datetime_to_gregorian_seconds(DateTime)
     - calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})) * 1000.
