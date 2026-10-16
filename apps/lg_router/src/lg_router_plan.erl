%% @doc 路由计划：模型可见性、权限解析、候选展开与嵌套路由解析。
%%
%% 该模块只负责把路由配置展开成有序候选；不发起上游调用，也不修改 outcome。
%% `lg_router` 保留门面 API 与请求主循环。
-module(lg_router_plan).

-include_lib("lg_core/include/lg_core.hrl").

-define(MAX_NESTING, 3).

-export([models/1, resolve/2, plan/1, plan/2, plan/3, plan/4, candidates/1,
         exhausted_until/3, dedup/1, conc_full/1, tier/2, tkey/1]).

%%====================================================================
%% 模型可见性
%%====================================================================

%% @doc Key 可调用的模型名（/v1/models）：精确路由名及其别名，加上通配路由按其 `*` 目标凭证的
%% 目录供应商展开的 `前缀 + 模型 id`（无目录供应商时列出通配路由名本身）。
-spec models(#lg_api_key{}) -> [binary()].
models(Key) ->
    lists:usort(lists:append(
                  [expand(R) || #lg_route{enabled = true} = R <- lg_routes:list(), allowed(Key, R)])).

expand(#lg_route{name = N, targets = Ts}) ->
    case lg_routes:is_wildcard(N) of
        false ->
            case all_direct_retired(Ts) of
                true -> [];
                false -> [N | lg_routes:aliases(N)]
            end;
        true ->
            Prefix = binary:part(N, 0, byte_size(N) - 1),
            CredP = lists:usort([{C, P} || #{credential := C, upstream_model := <<"*">>} <- Ts,
                                           {ok, #lg_credential{provider = P}} <- [lg_credentials:get(C)],
                                           is_binary(P)]),
            Names = [<<Prefix/binary, Id/binary>> || {_, P} <- CredP, #{<<"id">> := Id} <- lg_catalog:models(P),
                                                     not retired_everywhere(Id, [C || {C, PP} <- CredP, PP =:= P])],
            case Names of
                [] -> [N];
                _ -> Names
            end
    end.

%% 精确路由：所有启用的直连目标都退役 → 路由不可服务（嵌套 / 回退目标无法判断，不影响）
all_direct_retired(Ts) ->
    Direct = [T || T <- Ts, maps:get(enabled, T, true), maps:is_key(credential, T)],
    Direct =/= [] andalso
        lists:all(fun(#{credential := C, upstream_model := M}) -> lg_unfit:retired(C, M) end, Direct).

%% 通配展开名：某目录模型在该供应商的全部 `*` 目标凭证上都退役 → 不列出
retired_everywhere(Id, Creds) ->
    Creds =/= [] andalso lists:all(fun(C) -> lg_unfit:retired(C, Id) end, Creds).

%% @doc 解析请求的模型名。通配路由返回剩余部分（代入 `*` 目标），精确路由为 undefined。
-spec resolve(#lg_api_key{}, binary()) ->
          {ok, #lg_route{}, binary() | undefined} | {error, route_not_found | route_forbidden}.
resolve(Key, Name) ->
    case lg_routes:match(Name) of
        {ok, #lg_route{enabled = true} = R, Rest} ->
            case allowed(Key, R) of
                true -> {ok, R, Rest};
                false -> {error, route_forbidden}
            end;
        _ ->
            %% 禁用与不存在对调用方不可区分
            {error, route_not_found}
    end.

allowed(#lg_api_key{id = ?LG_PLAYGROUND_KEY}, _Route) ->
    true;
allowed(#lg_api_key{id = Id, allowed_routes = KeyRoutes}, #lg_route{name = N, access = Access}) ->
    (KeyRoutes =:= all orelse lists:member(N, KeyRoutes))
        andalso (Access =:= all orelse lists:member(Id, Access)).

%%====================================================================
%% 尝试顺序
%%====================================================================

%% @doc 生成尝试列表 [{RouteName, Target, #lg_credential{}}]。
-spec plan(#lg_route{}) -> [{binary(), map(), #lg_credential{}}].
plan(Route) ->
    plan(Route, all).

%% @doc 只保留指定上游协议的目标（embeddings 仅 openai，count_tokens 仅 anthropic）。
-spec plan(#lg_route{}, all | [openai | anthropic]) -> [{binary(), map(), #lg_credential{}}].
plan(Route, Protocols) ->
    plan(Route, Protocols, undefined).

%% @doc Rest：通配匹配的剩余部分，代入上游模型为 `*` 的目标；undefined 时跳过这些目标。
-spec plan(#lg_route{}, all | [openai | anthropic], binary() | undefined) ->
          [{binary(), map(), #lg_credential{}}].
plan(Route, Protocols, Rest) ->
    plan(Route, Protocols, Rest, #{}).

%% Env：rules => {Client, Req, Ctx}（对话请求，嵌套路由到达时判定它自己的规则）；
%%      depth / visited / via（嵌套展开的层数、已经过的路由、经过的嵌套路由名）
plan(#lg_route{fallbacks = Fallbacks} = Route, Protocols, Rest, Env) ->
    Own = order(Route, Protocols, Rest, Env),
    Fb = lists:append([order(R, Protocols, Rest, Env) || F <- Fallbacks,
                                   {ok, #lg_route{enabled = true} = R} <- [lg_routes:get(F)]]),
    lists:sublist(dedup(Own ++ Fb), lg_config:get(route_max_attempts)).

%% @doc 路由当前的候选顺序（含回退与嵌套展开、包括套餐额度用尽的目标，不截断），实时路由页显示用。
-spec candidates(#lg_route{}) -> [{binary(), map(), #lg_credential{}, atom()}].
candidates(#lg_route{fallbacks = Fallbacks} = Route) ->
    All = tiered(Route, all, undefined)
        ++ lists:append([tiered(R, all, undefined) || F <- Fallbacks,
                                                  {ok, #lg_route{enabled = true} = R} <- [lg_routes:get(F)]]),
    {Out, _} = lists:foldl(fun({_, T, _, _} = X, {Acc, Seen}) ->
                                   K = tkey(T),
                                   case sets:is_element(K, Seen) of
                                       true -> {Acc, Seen};
                                       false -> {[X | Acc], sets:add_element(K, Seen)}
                                   end
                           end, {[], sets:new()}, All),
    lists:reverse(Out).

order(Route, Protocols, Rest, Env) ->
    [{N, T, C} || {N, T, C, Tier} <- tiered(Route, Protocols, Rest, Env), Tier =/= exhausted].

tiered(Route, Protocols, Rest) ->
    tiered(Route, Protocols, Rest, #{}).

%% 同优先级内按策略排序，再按层排序：正常 → 套餐保留 → 冷却中 → 冷却中且保留；套餐额度用尽的目标单独标出。
%% 嵌套路由成员先展开成它自己的候选列表（按它的策略、规则与回退），以其中第一个候选参与父路由的排序，排好后原地展开
tiered(#lg_route{name = Name, targets = Targets, options = Opts}, Protocols, Rest, Env0) ->
    Strategy = maps:get(strategy, Opts, <<"weighted">>),
    Env = Env0#{visited => [Name | maps:get(visited, Env0, [])]},
    Usable = lists:append([member(T, Protocols, Rest, Env) || T <- Targets, maps:get(enabled, T, true)]),
    Groups = group_by_priority(Usable),
    Ordered = lists:append([lg_strategy:order(Strategy, Name, G) || G <- Groups]),
    Via = maps:get(via, Env, []),
    Tiered = lists:append([case T of
                               #{sub := Sub} -> Sub;
                               _ -> [{Name, with_via(T, Via), C, tier(T, C)}]
                           end || {T, C} <- Ordered]),
    %% 同一层内，并发已满的凭证排到未满的后面
    Rank = fun({_, _, Cr, Tier}) -> {tier_rank(Tier), conc_full(Cr)} end,
    lists:sort(fun(A, B) -> Rank(A) =< Rank(B) end, Tiered).

member(#{credential := CId} = T, Protocols, Rest, _Env) ->
    [{T1, C} || {ok, #lg_credential{enabled = true, protocol = P} = C} <- [lg_credentials:get(CId)],
                Protocols =:= all orelse lists:member(P, Protocols),
                {ok, T1} <- [materialize(T, C, Rest)],
                %% 已退役的 {凭证, 模型} 不进尝试顺序（一周后自动恢复，lg_unfit:retired/2）
                not lg_unfit:retired(CId, maps:get(upstream_model, T1))];
member(#{route := RN} = T, Protocols, Rest, Env) ->
    Depth = maps:get(depth, Env, 0),
    case Depth < ?MAX_NESTING andalso not lists:member(RN, maps:get(visited, Env)) andalso lg_routes:get(RN) of
        {ok, #lg_route{enabled = true} = R2} ->
            Env2 = Env#{depth => Depth + 1, via => maps:get(via, Env, []) ++ [RN]},
            case nested(R2, Protocols, Rest, Env2) of
                [] -> [];
                [{_, _, C1, _} | _] = Sub -> [{T#{sub => Sub}, C1}]
            end;
        _ -> []
    end;
member(_, _, _, _) ->
    [].

%% 嵌套路由的候选：自己的目标与回退；对话请求时按同一上下文判定它自己的规则
nested(#lg_route{name = Name, fallbacks = Fallbacks} = R, Protocols, Rest, Env) ->
    Own = tiered(R, Protocols, Rest, Env),
    Fb = lists:append([tiered(F, Protocols, Rest, Env) || FN <- Fallbacks,
                                 not lists:member(FN, maps:get(visited, Env)),
                                 {ok, #lg_route{enabled = true} = F} <- [lg_routes:get(FN)]]),
    Base = Own ++ Fb,
    case maps:find(rules, Env) of
        {ok, {Client, Req, Ctx}} ->
            Decision = lg_rules:decide(R, Client, Req, Ctx),
            note_nested(Name, Decision),
            case Decision of
                #{rule := #{<<"use">> := Use}} when Use =/= Name ->
                    case lists:member(Use, maps:get(visited, Env)) orelse lg_routes:get(Use) of
                        {ok, #lg_route{enabled = true} = U} -> tiered(U, Protocols, Rest, Env) ++ Base;
                        _ -> Base
                    end;
                #{rule := #{<<"skip">> := Skip}} ->
                    %% 同 apply_rule：skip 列表可以是凭证 id，也可以是嵌套路由名
                    case [X || {N, _, #lg_credential{id = C}, _} = X <- Base,
                               not lists:member(C, Skip), not lists:member(N, Skip)] of
                        [] -> Base;
                        Kept -> Kept
                    end;
                _ -> Base
            end;
        error ->
            Base
    end.

%% 嵌套路由的规则判定记在进程字典里（run/5 在生成尝试顺序前后读写），写进日志供决策叙述使用
note_nested(_Name, none) ->
    ok;
note_nested(Name, D) ->
    case get(lg_nested_rules) of
        L when is_list(L) ->
            case lists:keymember(Name, 1, L) of
                true -> ok;
                false ->
                    Routed = case maps:get(rule, D, undefined) of
                                 #{<<"use">> := U} -> U;
                                 _ -> undefined
                             end,
                    Entry = maps:filter(fun(_, V) -> V =/= undefined end,
                                        #{route => Name, rule => maps:get(index, D, 0), routed_to => Routed,
                                          intent => maps:get(intent, D, undefined),
                                          rule_reused => case maps:get(reused, D, false) of true -> true; _ -> undefined end}),
                    put(lg_nested_rules, L ++ [{Name, Entry}])
            end;
        _ -> ok
    end.

with_via(T, []) -> T;
with_via(T, Via) -> T#{via => Via}.

conc_full(#lg_credential{id = Id} = C) ->
    lg_conc:full(Id, lg_conc:max_of(C)).

tier(T, #lg_credential{id = CId}) ->
    Cold = lg_cooldown:cooling(tkey(T)),
    case lg_plan:state(CId) of
        {exhausted, _} -> exhausted;
        reserve when Cold -> cold_reserve;
        reserve -> reserve;
        normal when Cold -> cold;
        normal -> hot
    end.

tier_rank(hot) -> 0;
tier_rank(reserve) -> 1;
tier_rank(cold) -> 2;
tier_rank(cold_reserve) -> 3;
tier_rank(exhausted) -> 4.

%% 路由（含回退）中所有目标都因套餐额度用尽被跳过时，最早恢复的时刻
exhausted_until(#lg_route{fallbacks = Fallbacks} = Route, Protocols, Rest) ->
    Routes = [Route | [R || F <- Fallbacks, {ok, #lg_route{enabled = true} = R} <- [lg_routes:get(F)]]],
    Resets = [case lg_plan:state(Id) of {exhausted, At} -> At; _ -> null end
              || R <- Routes, {_, _, #lg_credential{id = Id}, exhausted} <- tiered(R, Protocols, Rest)],
    case Resets of
        [] -> none;
        _ ->
            case [At || At <- Resets, is_integer(At)] of
                [] -> {ok, lg_time:now_ms() + 60000};
                Ats -> {ok, lists:min(Ats)}
            end
    end.

%% 通配目标：上游模型取剩余部分；计费参考为 {凭证的目录供应商, 剩余部分}（目录中存在才计费）
materialize(#{upstream_model := <<"*">>}, _C, undefined) ->
    skip;
materialize(#{upstream_model := <<"*">>} = T, #lg_credential{provider = P}, Rest) ->
    T1 = maps:remove(model_ref, T#{upstream_model => Rest}),
    case is_binary(P) andalso lg_catalog:model({P, Rest}) =/= not_found of
        true -> {ok, T1#{model_ref => {P, Rest}}};
        false -> {ok, T1}
    end;
materialize(T, _C, _Rest) ->
    {ok, T}.

group_by_priority(Items) ->
    M = lists:foldl(fun({T, _} = I, Acc) ->
                            P = maps:get(priority, T, 0),
                            Acc#{P => [I | maps:get(P, Acc, [])]}
                    end, #{}, Items),
    [lists:reverse(maps:get(P, M)) || P <- lists:sort(maps:keys(M))].

%% 同一 {凭证, 上游模型} 只尝试一次（主路由与回退路由可能指向同一目标）
dedup(L) ->
    {Out, _} = lists:foldl(fun({_, T, _} = A, {Acc, Seen}) ->
                                   K = tkey(T),
                                   case sets:is_element(K, Seen) of
                                       true -> {Acc, Seen};
                                       false -> {[A | Acc], sets:add_element(K, Seen)}
                                   end
                           end, {[], sets:new([{version, 2}])}, L),
    lists:reverse(Out).

tkey(#{credential := C, upstream_model := M}) -> {C, M}.

