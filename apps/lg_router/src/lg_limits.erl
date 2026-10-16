%% @doc 限额与预算配置（mnesia）。
%%
%% 作用域在 JSON 中表示为：
%%   限额 #{"type": "key" | "route" | "key_route", "key_id"?, "route"?}
%%   预算 #{"type": "key" | "user", "key_id"? | "user_id"?}
-module(lg_limits).

-include_lib("lg_core/include/lg_core.hrl").

-export([set_limit/2, delete_limit/1, get_limit/1, list_limits/0, limits_for/2,
         set_budget/2, delete_budget/1, get_budget/1, list_budgets/0,
         limit_to_map/1, budget_to_map/1, scope_from_map/1, scope_to_map/1,
         limit_fields/1, budget_status/1, purge/1]).

%%====================================================================
%% 限额
%%====================================================================

%% @doc Params：rpm / tpm / max_parallel（正整数或 null）。三项都为空时删除该条。
-spec set_limit(lg_limit_scope(), map()) -> {ok, #lg_limit{} | deleted} | {error, term()}.
set_limit(Scope, P) ->
    try
        Rec = #lg_limit{scope = Scope,
                        rpm = pos_or_null(<<"rpm">>, P),
                        tpm = pos_or_null(<<"tpm">>, P),
                        max_parallel = pos_or_null(<<"max_parallel">>, P),
                        updated_at = lg_time:now_ms()},
        case Rec of
            #lg_limit{rpm = undefined, tpm = undefined, max_parallel = undefined} ->
                ok = delete_limit(Scope),
                {ok, deleted};
            _ ->
                ok = lg_db:write(Rec),
                {ok, Rec}
        end
    catch
        throw:{invalid, _} = E -> {error, E}
    end.

-spec delete_limit(lg_limit_scope()) -> ok.
delete_limit(Scope) ->
    lg_db:delete(lg_limit, Scope).

-spec get_limit(lg_limit_scope()) -> {ok, #lg_limit{}} | not_found.
get_limit(Scope) ->
    lg_db:read(lg_limit, Scope).

-spec list_limits() -> [#lg_limit{}].
list_limits() ->
    lg_db:all(lg_limit).

%% @doc 一次请求命中的全部限额：Key 级、路由级、Key×路由级。
-spec limits_for(binary(), binary()) -> [#lg_limit{}].
limits_for(KeyId, Route) ->
    [L || S <- [{key, KeyId}, {route, Route}, {key_route, KeyId, Route}],
          {ok, L} <- [lg_db:read(lg_limit, S)]].

%%====================================================================
%% 预算
%%====================================================================

%% @doc Params：period（"day" | "week" | "month"）、max_usd（非负数）；max_usd 为 null 时删除。
-spec set_budget(lg_budget_scope(), map()) -> {ok, #lg_budget{} | deleted} | {error, term()}.
set_budget(Scope, #{<<"max_usd">> := null}) ->
    ok = delete_budget(Scope),
    {ok, deleted};
set_budget(Scope, P) ->
    Period = case maps:get(<<"period">>, P, <<"month">>) of
                 <<"day">> -> day;
                 <<"week">> -> week;
                 <<"month">> -> month;
                 _ -> invalid
             end,
    case {Period, maps:get(<<"max_usd">>, P, undefined)} of
        {invalid, _} ->
            {error, {invalid, <<"period">>}};
        {_, Max} when is_number(Max), Max >= 0 ->
            Rec = #lg_budget{scope = Scope, period = Period, max_usd = Max,
                             updated_at = lg_time:now_ms()},
            ok = lg_db:write(Rec),
            {ok, Rec};
        _ ->
            {error, {invalid, <<"max_usd">>}}
    end.

-spec delete_budget(lg_budget_scope()) -> ok.
delete_budget(Scope) ->
    lg_db:delete(lg_budget, Scope).

-spec get_budget(lg_budget_scope()) -> {ok, #lg_budget{}} | not_found.
get_budget(Scope) ->
    lg_db:read(lg_budget, Scope).

-spec list_budgets() -> [#lg_budget{}].
list_budgets() ->
    lg_db:all(lg_budget).

%% @doc 删除与某个 Key / 路由 / 用户相关的全部限额与预算（删除该对象时调用）。
-spec purge({key, binary()} | {route, binary()} | {user, binary()}) -> ok.
purge({key, K}) ->
    ok = delete_budget({key, K}),
    [delete_limit(S) || #lg_limit{scope = S} <- list_limits(),
                        S =:= {key, K} orelse element(1, S) =:= key_route andalso element(2, S) =:= K],
    ok;
purge({route, R}) ->
    [delete_limit(S) || #lg_limit{scope = S} <- list_limits(),
                        S =:= {route, R} orelse element(1, S) =:= key_route andalso element(3, S) =:= R],
    ok;
purge({user, U}) ->
    delete_budget({user, U}).

%%====================================================================
%% JSON 表示
%%====================================================================

%% @doc 某作用域的限额字段（无限额时为 null），用于嵌入 Key / 路由的列表项。
-spec limit_fields(lg_limit_scope()) -> map() | null.
limit_fields(Scope) ->
    case get_limit(Scope) of
        {ok, L} -> maps:with([<<"rpm">>, <<"tpm">>, <<"max_parallel">>], limit_to_map(L));
        not_found -> null
    end.

%% @doc 某作用域的预算与本期已用（无预算时为 null）。
-spec budget_status(lg_budget_scope()) -> map() | null.
budget_status(Scope) ->
    case get_budget(Scope) of
        {ok, #lg_budget{period = P} = B} ->
            Now = lg_time:now_ms(),
            (maps:with([<<"period">>, <<"max_usd">>], budget_to_map(B)))#{
              <<"spent_usd">> => lg_budget:spent(Scope, P),
              <<"resets_at">> => lg_budget:period_end(P, Now)};
        not_found ->
            null
    end.

-spec limit_to_map(#lg_limit{}) -> map().
limit_to_map(#lg_limit{scope = S, rpm = R, tpm = T, max_parallel = P, updated_at = U}) ->
    #{<<"scope">> => scope_to_map(S), <<"rpm">> => null_if(R), <<"tpm">> => null_if(T),
      <<"max_parallel">> => null_if(P), <<"updated_at">> => U}.

-spec budget_to_map(#lg_budget{}) -> map().
budget_to_map(#lg_budget{scope = S, period = P, max_usd = M, updated_at = U}) ->
    #{<<"scope">> => scope_to_map(S), <<"period">> => atom_to_binary(P),
      <<"max_usd">> => M, <<"updated_at">> => U}.

-spec scope_to_map(lg_limit_scope() | lg_budget_scope()) -> map().
scope_to_map({key, K}) -> #{<<"type">> => <<"key">>, <<"key_id">> => K};
scope_to_map({route, R}) -> #{<<"type">> => <<"route">>, <<"route">> => R};
scope_to_map({key_route, K, R}) -> #{<<"type">> => <<"key_route">>, <<"key_id">> => K, <<"route">> => R};
scope_to_map({user, U}) -> #{<<"type">> => <<"user">>, <<"user_id">> => U};
scope_to_map({tag, T}) -> #{<<"type">> => <<"tag">>, <<"tag">> => T}.

-spec scope_from_map(map()) -> {ok, lg_limit_scope() | lg_budget_scope()} | {error, term()}.
scope_from_map(#{<<"type">> := <<"key">>, <<"key_id">> := K}) when is_binary(K) -> {ok, {key, K}};
scope_from_map(#{<<"type">> := <<"route">>, <<"route">> := R}) when is_binary(R) -> {ok, {route, R}};
scope_from_map(#{<<"type">> := <<"key_route">>, <<"key_id">> := K, <<"route">> := R})
  when is_binary(K), is_binary(R) -> {ok, {key_route, K, R}};
scope_from_map(#{<<"type">> := <<"user">>, <<"user_id">> := U}) when is_binary(U) -> {ok, {user, U}};
scope_from_map(#{<<"type">> := <<"tag">>, <<"tag">> := T}) when is_binary(T) ->
    case lg_tags:normalize([T]) of
        [T] -> {ok, {tag, T}};
        _ -> {error, {invalid, <<"scope.tag">>}}
    end;
scope_from_map(_) -> {error, {invalid, <<"scope">>}}.

%%====================================================================
%% 内部函数
%%====================================================================

pos_or_null(K, P) ->
    case maps:get(K, P, null) of
        null -> undefined;
        N when is_integer(N), N > 0 -> N;
        _ -> throw({invalid, K})
    end.

null_if(undefined) -> null;
null_if(V) -> V.
