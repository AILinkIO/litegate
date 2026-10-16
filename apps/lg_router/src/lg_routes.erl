%% @doc L3 路由表管理：对外宣告的模型名 → 上游目标列表。
%%
%% 参数（JSON，binary 键）：
%%   name        对外模型名，不可含空白；以 `*` 结尾为通配路由（任意前缀，如 `openrouter/*`、`claude-*`；单独 `*` 为兜底）
%%   aliases     [精确模型名]，同样路由到本路由；与路由名、其他路由的别名都不能重复
%%   targets     [#{credential, upstream_model, model_ref?: [Provider, ModelId],
%%                  weight?: 1, priority?: 0, enabled?: true}
%%                | #{route, weight?, priority?, enabled?}]   嵌套路由：另一条非通配路由作为一个成员，
%%                最多 3 层，不能成环（只按嵌套关系检查；回退只展开一层，不会形成死循环）
%%   fallbacks   [RouteName]，本路由所有目标失败后按顺序尝试（只展开一层）
%%   access      "all" | [ApiKeyId]
%%   options     #{cache_ttl_s}（部分更新，null 删除）
%%   enabled
-module(lg_routes).

-include_lib("lg_core/include/lg_core.hrl").

-export([create/1, update/2, delete/1, get/1, list/0, to_map/1, match/1, is_wildcard/1, build_tx/2, build_tx/3,
         aliases/1, check_graph_tx/0]).

-define(MAX_NESTING, 3).

%% 合法顶层字段；未知字段（如把 rules/classifier 误放在顶层）静默丢弃会让用户误以为已保存，直接拒绝
-define(FIELDS, [<<"name">>, <<"targets">>, <<"fallbacks">>, <<"access">>, <<"options">>, <<"aliases">>, <<"enabled">>]).

-spec create(map()) -> {ok, #lg_route{}} | {error, term()}.
create(#{<<"name">> := Name} = P) when is_binary(Name) ->
    Now = lg_time:now_ms(),
    Tx = fun() ->
                 case mnesia:read(lg_route, Name) =/= [] orelse mnesia:read(lg_route_alias, Name) =/= [] of
                     true -> mnesia:abort(already_exists);
                     false -> write(build(P, #lg_route{name = Name, created_at = Now,
                                                       updated_at = Now}))
                 end
         end,
    case check_name(Name) of
        ok -> lg_db:transaction(Tx);
        Err -> Err
    end;
create(_) ->
    {error, {missing, <<"name">>}}.

%% @doc 部分更新（不可改名）。
-spec update(binary(), map()) -> {ok, #lg_route{}} | {error, term()}.
update(Name, P) ->
    Tx = fun() ->
                 case mnesia:read(lg_route, Name) of
                     [Old] -> write(build(maps:remove(<<"name">>, P),
                                          Old#lg_route{updated_at = lg_time:now_ms()}));
                     [] -> mnesia:abort(not_found)
                 end
         end,
    lg_db:transaction(Tx).

%% @doc 被其他路由作为回退、嵌套目标或意图判断路由（classifier / decision_route）引用时拒绝删除。
-spec delete(binary()) -> ok | {error, term()}.
delete(Name) ->
    case [N || #lg_route{name = N, fallbacks = F, targets = Ts, options = O} <- lg_db:all(lg_route),
                lists:member(Name, F)
                orelse lists:any(fun(#{route := R}) -> R =:= Name; (_) -> false end, Ts)
                orelse maps:get(classifier, O, none) =:= Name
                orelse maps:get(decision_route, O, none) =:= Name] of
        [] ->
            ok = lg_limits:purge({route, Name}),
            {ok, ok} = lg_db:transaction(fun() ->
                                                 [mnesia:delete({lg_route_alias, A}) || A <- aliases_tx(Name)],
                                                 mnesia:delete({lg_route, Name})
                                         end),
            ok;
        Users -> {error, {in_use, Users}}
    end.

%% @doc 按请求的模型名匹配路由：路由名 → 别名 → 前缀最长的通配路由。
%% 返回剩余部分（通配时代入目标中的 `*` 上游模型；精确匹配时为 undefined）。
-spec match(binary()) -> {ok, #lg_route{}, binary() | undefined} | not_found.
match(Name) ->
    case lg_db:read(lg_route, Name) of
        {ok, R} ->
            {ok, R, undefined};
        not_found ->
            case lg_db:read(lg_route_alias, Name) of
                {ok, #lg_route_alias{route = RN}} ->
                    case lg_db:read(lg_route, RN) of
                        {ok, R} -> {ok, R, undefined};
                        not_found -> match_wildcard(Name)
                    end;
                not_found ->
                    match_wildcard(Name)
            end
    end.

match_wildcard(Name) ->
    Cands = [{byte_size(P), R, binary:part(Name, byte_size(P), byte_size(Name) - byte_size(P))}
             || #lg_route{name = N} = R <- lg_db:all(lg_route), is_wildcard(N),
                P <- [prefix(N)],
                byte_size(Name) > byte_size(P),
                binary:part(Name, 0, byte_size(P)) =:= P],
    case lists:reverse(lists:keysort(1, Cands)) of
        [{_, R, Rest} | _] -> {ok, R, Rest};
        [] -> not_found
    end.

-spec is_wildcard(binary()) -> boolean().
is_wildcard(<<"*">>) -> true;
is_wildcard(N) -> N =/= <<>> andalso binary:last(N) =:= $*.

%% 通配前缀（去掉末尾的 *）
prefix(<<"*">>) -> <<>>;
prefix(N) -> binary:part(N, 0, byte_size(N) - 1).

%% @doc 路由的别名（排序）。
-spec aliases(binary()) -> [binary()].
aliases(Name) ->
    lists:sort([A || #lg_route_alias{alias = A} <- mnesia:dirty_index_read(lg_route_alias, Name, #lg_route_alias.route)]).

aliases_tx(Name) ->
    [A || #lg_route_alias{alias = A} <- mnesia:index_read(lg_route_alias, Name, #lg_route_alias.route)].

-spec get(binary()) -> {ok, #lg_route{}} | not_found.
get(Name) ->
    lg_db:read(lg_route, Name).

-spec list() -> [#lg_route{}].
list() ->
    lists:keysort(#lg_route.name, lg_db:all(lg_route)).

-spec to_map(#lg_route{}) -> map().
to_map(#lg_route{name = N, targets = Ts, fallbacks = F, access = A, options = O,
                 enabled = E, created_at = C, updated_at = U}) ->
    #{<<"name">> => N,
      <<"targets">> => [target_out(T) || T <- Ts],
      <<"fallbacks">> => F,
      <<"access">> => case A of all -> <<"all">>; L -> L end,
      <<"options">> => lg_options:to_json(O),
      <<"aliases">> => aliases(N),
      <<"enabled">> => E, <<"created_at">> => C, <<"updated_at">> => U}.

%%====================================================================
%% 内部函数（事务内执行，校验失败以 mnesia:abort 返回）
%%====================================================================

write(Route) ->
    ok = mnesia:write(Route),
    ok = check_graph_tx(),
    Route.

%% @doc 检查整个路由图的嵌套关系（事务内）：不能成环，嵌套深度不超过 3 层。
-spec check_graph_tx() -> ok.
check_graph_tx() ->
    Edges = maps:from_list([{N, [R || #{route := R} <- Ts]}
                            || #lg_route{name = N, targets = Ts} <- mnesia:select(lg_route, [{'_', [], ['$_']}])]),
    _ = maps:fold(fun(N, _, Memo) -> depth(N, Edges, [], Memo) end, #{}, Edges),
    ok.

%% 从 N 出发的嵌套深度（N 本身为 0）；Path 用于发现环
depth(N, Edges, Path, Memo) ->
    case lists:member(N, Path) of
        true -> mnesia:abort({route_cycle, lists:reverse([N | Path])});
        false -> ok
    end,
    case maps:find(N, Memo) of
        {ok, _} -> Memo;
        error ->
            Kids = maps:get(N, Edges, []),
            Memo1 = lists:foldl(fun(K, M) -> depth(K, Edges, [N | Path], M) end, Memo, Kids),
            D = lists:max([0 | [maps:get(K, Memo1, 0) + 1 || K <- Kids]]),
            D =< ?MAX_NESTING orelse mnesia:abort({invalid, <<"nesting_too_deep">>}),
            Memo1#{N => D}
    end.

%% @doc 在 mnesia 事务中按参数构建路由记录（校验失败 mnesia:abort），供配置导入复用。
-spec build_tx(map(), #lg_route{}) -> #lg_route{}.
build_tx(P, R0) ->
    build(P, R0).

%% @doc 同 build_tx/2；Opts 的 check_refs => false 时不检查嵌套目标引用的路由是否存在（配置导入第一遍）。
-spec build_tx(map(), #lg_route{}, map()) -> #lg_route{}.
build_tx(P, R0, Opts) ->
    put(lg_routes_check_refs, maps:get(check_refs, Opts, true)),
    try build(P, R0) after erase(lg_routes_check_refs) end.

build(P, R0) ->
    case maps:keys(P) -- ?FIELDS of
        [] -> ok;
        Unknown -> mnesia:abort({unknown_fields, Unknown})
    end,
    R1 = case maps:find(<<"targets">>, P) of
             {ok, Ts} when is_list(Ts), Ts =/= [] ->
                 Targets = [target_in(R0#lg_route.name, T) || T <- Ts],
                 is_wildcard(R0#lg_route.name) orelse
                     not lists:any(fun(#{upstream_model := M}) -> M =:= <<"*">>; (_) -> false end, Targets)
                     orelse mnesia:abort({invalid, <<"upstream_model">>}),
                 R0#lg_route{targets = Targets};
             {ok, _} -> mnesia:abort({invalid, <<"targets">>});
             error when R0#lg_route.targets =:= [] -> mnesia:abort({missing, <<"targets">>});
             error -> R0
         end,
    R2 = case maps:find(<<"fallbacks">>, P) of
             {ok, F} when is_list(F) -> R1#lg_route{fallbacks = [fallback(R1#lg_route.name, X) || X <- F]};
             {ok, _} -> mnesia:abort({invalid, <<"fallbacks">>});
             error -> R1
         end,
    R3 = case maps:find(<<"access">>, P) of
             {ok, <<"all">>} -> R2#lg_route{access = all};
             {ok, L} when is_list(L) ->
                 lists:all(fun is_binary/1, L) orelse mnesia:abort({invalid, <<"access">>}),
                 R2#lg_route{access = lists:usort(L)};
             {ok, _} -> mnesia:abort({invalid, <<"access">>});
             error -> R2
         end,
    R4 = case maps:find(<<"options">>, P) of
             {ok, O} ->
                 case lg_options:merge(lg_options:route_spec(), O, R3#lg_route.options) of
                     {ok, Opts} -> R3#lg_route{options = Opts};
                     {error, E} -> mnesia:abort(E)
                 end;
             error -> R3
         end,
    check_classifier(R4),
    case maps:find(<<"aliases">>, P) of
        {ok, As} when is_list(As) -> set_aliases(R4#lg_route.name, As);
        {ok, _} -> mnesia:abort({invalid, <<"aliases">>});
        error -> ok
    end,
    case maps:find(<<"enabled">>, P) of
        {ok, En} when is_boolean(En) -> R4#lg_route{enabled = En};
        {ok, _} -> mnesia:abort({invalid, <<"enabled">>});
        error -> R4
    end.

%% 嵌套路由目标：另一条非通配路由
target_in(Self, #{<<"route">> := R} = T) when is_binary(R) ->
    R =/= Self orelse mnesia:abort({invalid, <<"targets">>}),
    is_wildcard(R) andalso mnesia:abort({invalid, <<"targets">>}),
    erlang:get(lg_routes_check_refs) =:= false orelse mnesia:read(lg_route, R) =/= []
        orelse mnesia:abort({unknown_route, R}),
    #{route => R,
      weight => pos_int(maps:get(<<"weight">>, T, 1), <<"weight">>),
      priority => non_neg_int(maps:get(<<"priority">>, T, 0), <<"priority">>),
      enabled => maps:get(<<"enabled">>, T, true) =/= false};
target_in(_Self, T) ->
    target_in(T).

target_in(#{<<"credential">> := C, <<"upstream_model">> := M} = T)
  when is_binary(C), is_binary(M), M =/= <<>> ->
    mnesia:read(lg_credential, C) =/= [] orelse mnesia:abort({unknown_credential, C}),
    Base = #{credential => C, upstream_model => M,
             weight => pos_int(maps:get(<<"weight">>, T, 1), <<"weight">>),
             priority => non_neg_int(maps:get(<<"priority">>, T, 0), <<"priority">>),
             enabled => maps:get(<<"enabled">>, T, true) =/= false},
    case maps:get(<<"model_ref">>, T, null) of
        [P, Id] when is_binary(P), is_binary(Id) -> Base#{model_ref => {P, Id}};
        null -> Base;
        _ -> mnesia:abort({invalid, <<"model_ref">>})
    end;
target_in(_) ->
    mnesia:abort({invalid, <<"targets">>}).

target_out(#{route := R} = T) ->
    #{<<"route">> => R, <<"weight">> => maps:get(weight, T, 1), <<"priority">> => maps:get(priority, T, 0),
      <<"enabled">> => maps:get(enabled, T, true)};
target_out(T) ->
    Base = #{<<"credential">> => maps:get(credential, T),
             <<"upstream_model">> => maps:get(upstream_model, T),
             <<"weight">> => maps:get(weight, T, 1),
             <<"priority">> => maps:get(priority, T, 0),
             <<"enabled">> => maps:get(enabled, T, true)},
    case maps:find(model_ref, T) of
        {ok, {P, M}} -> Base#{<<"model_ref">> => [P, M]};
        error -> Base#{<<"model_ref">> => null}
    end.

%% 替换路由的别名：精确名（不含 *），不能与任何路由名或其他路由的别名重复
set_aliases(Route, As) ->
    Uniq = lists:usort(As),
    lists:foreach(fun(A) ->
                          (is_binary(A) andalso check_name(A) =:= ok andalso not is_wildcard(A) andalso A =/= Route)
                              orelse mnesia:abort({invalid, <<"aliases">>}),
                          mnesia:read(lg_route, A) =:= [] orelse mnesia:abort({alias_conflict, A}),
                          case mnesia:read(lg_route_alias, A) of
                              [#lg_route_alias{route = R}] when R =/= Route -> mnesia:abort({alias_conflict, A});
                              _ -> ok
                          end
                  end, Uniq),
    [mnesia:delete({lg_route_alias, A}) || A <- aliases_tx(Route), not lists:member(A, Uniq)],
    [mnesia:write(#lg_route_alias{alias = A, route = Route}) || A <- Uniq],
    ok.

fallback(Self, Self) ->
    mnesia:abort({invalid, <<"fallbacks">>});
fallback(_Self, F) when is_binary(F) ->
    mnesia:read(lg_route, F) =/= [] orelse mnesia:abort({unknown_route, F}),
    F;
fallback(_, _) ->
    mnesia:abort({invalid, <<"fallbacks">>}).

%% classifier / decision_route 指向的路由必须存在且启用：不校验会到运行时才静默失败（intent 判不出来），
%% 与回退 / 嵌套目标的存在性校验同级。
%% 导入第一遍（check_refs => false）跳过——被引用的路由可能尚未导入，第二遍完整校验。
check_classifier(#lg_route{options = O}) ->
    SkipRefs = erlang:get(lg_routes_check_refs) =:= false,
    lists:foreach(
      fun(Ref) ->
              case mnesia:read(lg_route, Ref) of
                  [] when not SkipRefs -> mnesia:abort({unknown_route, Ref});
                  [#lg_route{enabled = false}] -> mnesia:abort({disabled_route, Ref});
                  _ -> ok
              end
      end, [V || K <- [classifier, decision_route], {ok, V} <- [maps:find(K, O)]]).

pos_int(N, _) when is_integer(N), N > 0 -> N;
pos_int(_, K) -> mnesia:abort({invalid, K}).

non_neg_int(N, _) when is_integer(N), N >= 0 -> N;
non_neg_int(_, K) -> mnesia:abort({invalid, K}).

%% `*` 只能出现一次且在末尾：单独的 `*`（兜底）或 `前缀*`
check_name(Name) ->
    Stars = length(binary:matches(Name, <<"*">>)),
    Ok = Name =/= <<>> andalso nomatch =:= re:run(Name, "\\s") andalso byte_size(Name) =< 128
        andalso (Stars =:= 0 orelse (Stars =:= 1 andalso is_wildcard(Name))),
    case Ok of
        true -> ok;
        false -> {error, {invalid, <<"name">>}}
    end.
