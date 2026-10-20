-module(lg_router_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("lg_core/include/lg_core.hrl").

router_test_() ->
    {foreach,
     fun() ->
             Dir = lg_core_test_util:start(),
             {ok, _} = application:ensure_all_started(lg_router),
             Dir
     end,
     fun(Dir) ->
             application:stop(lg_router),
             lg_core_test_util:stop(Dir)
     end,
     [?_test(credentials()),
      ?_test(routes_validation()),
      ?_test(api_keys()),
      ?_test(access()),
      ?_test(plan_priority_and_weight()),
      ?_test(plan_cooldown_fallback_limit()),
      ?_test(wildcard_routes()),
      ?_test(plan_quota_tiers()),
      ?_test(aliases_and_prefix_wildcards()),
      ?_test(cooldown_kinds()),
      ?_test(retired()),
      ?_test(backup()),
      ?_test(concurrency()),
      ?_test(concurrency_race()),
      ?_test(concurrency_race_release()),
      ?_test(cooldown_race()),
      ?_test(affinity_choose()),
      ?_test(cooldown_sweep()),
      ?_test(affinity_token_sweep()),
      ?_test(strategies()),
      ?_test(timezone_note()),
      ?_test(skip_rules()),
      ?_test(nested_routes()),
     ?_test(hold_max()),
      ?_test(route_capabilities())]}.

cred(Name) ->
    {ok, #lg_credential{id = Id}} =
        lg_credentials:create(#{<<"name">> => Name, <<"protocol">> => <<"openai">>,
                                <<"base_url">> => <<"https://api.example.com/v1">>,
                                <<"api_key">> => <<"sk-0123456789">>}),
    Id.

target(C, M) -> target(C, M, #{}).
target(C, M, Extra) -> maps:merge(#{<<"credential">> => C, <<"upstream_model">> => M}, Extra).

credentials() ->
    ?assertEqual({error, {missing, <<"protocol">>}},
                 lg_credentials:create(#{<<"name">> => <<"x">>, <<"base_url">> => <<"https://a">>})),
    ?assertEqual({error, {invalid, <<"base_url">>}},
                 lg_credentials:create(#{<<"name">> => <<"x">>, <<"protocol">> => <<"openai">>,
                                         <<"base_url">> => <<"ftp://a">>})),
    ?assertEqual({error, {invalid, <<"protocol">>}},
                 lg_credentials:create(#{<<"name">> => <<"x">>, <<"protocol">> => <<"grpc">>,
                                         <<"base_url">> => <<"https://a">>})),
    Id = cred(<<"c">>),
    {ok, C} = lg_credentials:get(Id),
    ?assertMatch(#{<<"api_key_hint">> := <<"...6789">>, <<"protocol">> := <<"openai">>},
                 lg_credentials:to_map(C)),
    %% 更新不带 api_key 时保留原 Key
    {ok, C2} = lg_credentials:update(Id, #{<<"name">> => <<"renamed">>,
                                           <<"headers">> => #{<<"X-Org">> => <<"o">>}}),
    ?assertEqual(C#lg_credential.api_key_enc, C2#lg_credential.api_key_enc),
    ?assertEqual([{<<"x-org">>, <<"o">>}], C2#lg_credential.headers),
    {ok, #lg_credential{options = #{responses_api := true}}} =
        lg_credentials:update(Id, #{<<"options">> => #{<<"responses_api">> => true}}),
    ?assertEqual({error, {invalid, <<"options.responses_api">>}},
                 lg_credentials:update(Id, #{<<"options">> => #{<<"responses_api">> => <<"yes">>}})),
    {ok, C3} = lg_credentials:update(Id, #{<<"api_key">> => null}),
    ?assertEqual(undefined, C3#lg_credential.api_key_enc),
    %% 被路由引用时不可删除
    {ok, _} = lg_routes:create(#{<<"name">> => <<"r">>, <<"targets">> => [target(Id, <<"m">>)]}),
    ?assertEqual({error, {in_use, [<<"r">>]}}, lg_credentials:delete(Id)),
    ?assertEqual({error, not_found}, lg_credentials:update(<<"nope">>, #{})).

routes_validation() ->
    C = cred(<<"c">>),
    ?assertEqual({error, {invalid, <<"name">>}},
                 lg_routes:create(#{<<"name">> => <<"a b">>, <<"targets">> => [target(C, <<"m">>)]})),
    ?assertEqual({error, {missing, <<"targets">>}}, lg_routes:create(#{<<"name">> => <<"a">>})),
    ?assertEqual({error, {unknown_credential, <<"zz">>}},
                 lg_routes:create(#{<<"name">> => <<"a">>, <<"targets">> => [target(<<"zz">>, <<"m">>)]})),
    ?assertEqual({error, {invalid, <<"weight">>}},
                 lg_routes:create(#{<<"name">> => <<"a">>,
                                    <<"targets">> => [target(C, <<"m">>, #{<<"weight">> => 0})]})),
    ?assertEqual({error, {unknown_route, <<"b">>}},
                 lg_routes:create(#{<<"name">> => <<"a">>, <<"targets">> => [target(C, <<"m">>)],
                                    <<"fallbacks">> => [<<"b">>]})),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"b">>, <<"targets">> => [target(C, <<"m2">>)]}),
    %% 未知顶层字段（如把 rules 误放在顶层）拒绝并列出字段，不再静默丢弃
    ?assertEqual({error, {unknown_fields, [<<"rules">>]}},
                 lg_routes:create(#{<<"name">> => <<"a">>, <<"targets">> => [target(C, <<"m">>)],
                                    <<"rules">> => []})),
    {ok, A} = lg_routes:create(#{<<"name">> => <<"a">>,
                                 <<"targets">> => [target(C, <<"m">>, #{<<"model_ref">> => [<<"p">>, <<"x">>]})],
                                 <<"fallbacks">> => [<<"b">>], <<"access">> => [<<"k2">>, <<"k1">>]}),
    ?assertMatch(#lg_route{access = [<<"k1">>, <<"k2">>], fallbacks = [<<"b">>],
                           targets = [#{model_ref := {<<"p">>, <<"x">>}, weight := 1, priority := 0}]}, A),
    ?assertMatch(#{<<"targets">> := [#{<<"model_ref">> := [<<"p">>, <<"x">>]}], <<"access">> := [_, _]},
                 lg_routes:to_map(A)),
    ?assertEqual({error, already_exists},
                 lg_routes:create(#{<<"name">> => <<"a">>, <<"targets">> => [target(C, <<"m">>)]})),
    ?assertEqual({error, {invalid, <<"fallbacks">>}}, lg_routes:update(<<"a">>, #{<<"fallbacks">> => [<<"a">>]})),
    {ok, A2} = lg_routes:update(<<"a">>, #{<<"enabled">> => false, <<"name">> => <<"ignored">>}),
    ?assertMatch(#lg_route{name = <<"a">>, enabled = false, fallbacks = [<<"b">>]}, A2),
    %% 扩展选项：部分更新、null 删除、未知键与类型错误拒绝
    {ok, #lg_route{options = #{cache_ttl_s := 60}}} =
        lg_routes:update(<<"a">>, #{<<"options">> => #{<<"cache_ttl_s">> => 60}}),
    ?assertMatch(#{<<"options">> := #{<<"cache_ttl_s">> := 60}}, lg_routes:to_map(element(2, lg_routes:get(<<"a">>)))),
    {ok, #lg_route{options = #{cache_ttl_s := 60}}} = lg_routes:update(<<"a">>, #{<<"options">> => #{}}),
    {ok, #lg_route{options = Empty}} = lg_routes:update(<<"a">>, #{<<"options">> => #{<<"cache_ttl_s">> => null}}),
    ?assertEqual(#{}, Empty),
    ?assertEqual({error, {invalid, <<"options.nope">>}},
                 lg_routes:update(<<"a">>, #{<<"options">> => #{<<"nope">> => 1}})),
    ?assertEqual({error, {invalid, <<"options.cache_ttl_s">>}},
                 lg_routes:update(<<"a">>, #{<<"options">> => #{<<"cache_ttl_s">> => -1}})),
    ?assertEqual({error, {unknown_fields, [<<"rules">>]}}, lg_routes:update(<<"a">>, #{<<"rules">> => []})),
    ?assertEqual({error, {in_use, [<<"a">>]}}, lg_routes:delete(<<"b">>)),
    ?assertEqual(ok, lg_routes:delete(<<"a">>)),
    %% classifier 保存时校验：指向的路由必须存在且启用（R8）；被 classifier 引用的路由不可删除
    ?assertEqual({error, {unknown_route, <<"nope">>}},
                 lg_routes:create(#{<<"name">> => <<"cc">>, <<"targets">> => [target(C, <<"m">>)],
                                    <<"options">> => #{<<"classifier">> => <<"nope">>}})),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"cc">>, <<"targets">> => [target(C, <<"m">>)],
                                 <<"options">> => #{<<"classifier">> => <<"b">>}}),
    {ok, _} = lg_routes:update(<<"b">>, #{<<"enabled">> => false}),
    ?assertEqual({error, {disabled_route, <<"b">>}},
                 lg_routes:update(<<"cc">>, #{<<"options">> => #{<<"cache_ttl_s">> => 30}})),
    ?assertEqual({error, {in_use, [<<"cc">>]}}, lg_routes:delete(<<"b">>)),
    {ok, _} = lg_routes:update(<<"b">>, #{<<"enabled">> => true}),
    {ok, _} = lg_routes:update(<<"cc">>, #{<<"options">> => #{<<"classifier">> => null}}),
    ?assertEqual(ok, lg_routes:delete(<<"b">>)),
    ?assertEqual(ok, lg_routes:delete(<<"cc">>)).

api_keys() ->
    {ok, Plain, K} = lg_api_keys:create(#{<<"name">> => <<"k">>, <<"max_tokens">> => 100}),
    ?assertMatch(<<"lgk-", _/binary>>, Plain),
    ?assertEqual({ok, K}, lg_api_keys:authenticate(Plain)),
    ?assertEqual({error, invalid_key}, lg_api_keys:authenticate(<<"lgk-wrong">>)),
    ?assertNot(maps:is_key(<<"hash">>, lg_api_keys:to_map(K))),
    {ok, _} = lg_api_keys:update(K#lg_api_key.id, #{<<"enabled">> => false}),
    ?assertEqual({error, disabled}, lg_api_keys:authenticate(Plain)),
    {ok, _} = lg_api_keys:update(K#lg_api_key.id, #{<<"enabled">> => true, <<"expires_at">> => 1}),
    ?assertEqual({error, expired}, lg_api_keys:authenticate(Plain)),
    ?assertEqual({error, {invalid, <<"max_tokens">>}},
                 lg_api_keys:update(K#lg_api_key.id, #{<<"max_tokens">> => -1})),
    ?assertEqual({error, {missing, <<"name">>}}, lg_api_keys:create(#{})),
    ok = lg_api_keys:delete(K#lg_api_key.id),
    ?assertEqual({error, invalid_key}, lg_api_keys:authenticate(Plain)).

access() ->
    C = cred(<<"c">>),
    {ok, _, K1} = lg_api_keys:create(#{<<"name">> => <<"k1">>}),
    {ok, _, K2} = lg_api_keys:create(#{<<"name">> => <<"k2">>, <<"allowed_routes">> => [<<"open">>]}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"open">>, <<"targets">> => [target(C, <<"m">>)]}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"vip">>, <<"targets">> => [target(C, <<"m">>)],
                                 <<"access">> => [K1#lg_api_key.id]}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"off">>, <<"targets">> => [target(C, <<"m">>)],
                                 <<"enabled">> => false}),
    ?assertEqual([<<"open">>, <<"vip">>], lg_router:models(K1)),
    ?assertEqual([<<"open">>], lg_router:models(K2)),
    ?assertMatch({ok, #lg_route{name = <<"vip">>}, undefined}, lg_router:resolve(K1, <<"vip">>)),
    ?assertEqual({error, route_forbidden}, lg_router:resolve(K2, <<"vip">>)),
    ?assertEqual({error, route_not_found}, lg_router:resolve(K1, <<"off">>)),
    ?assertEqual({error, route_not_found}, lg_router:resolve(K1, <<"nope">>)).

plan_models(Route) ->
    [maps:get(upstream_model, T) || {_, T, _} <- lg_router:plan(Route)].

plan_priority_and_weight() ->
    application:set_env(lg_core, route_max_attempts, 10),
    C = cred(<<"c">>),
    Off = cred(<<"off">>),
    {ok, _} = lg_credentials:update(Off, #{<<"enabled">> => false}),
    {ok, R} = lg_routes:create(
                #{<<"name">> => <<"r">>,
                  <<"targets">> => [target(C, <<"p1-heavy">>, #{<<"priority">> => 1, <<"weight">> => 9}),
                                    target(C, <<"p1-light">>, #{<<"priority">> => 1, <<"weight">> => 1}),
                                    target(C, <<"p0">>),
                                    target(C, <<"disabled">>, #{<<"enabled">> => false}),
                                    target(Off, <<"cred-off">>)]}),
    Firsts = [lists:nth(2, plan_models(R)) || _ <- lists:seq(1, 1000)],
    Heavy = length([x || <<"p1-heavy">> <- Firsts]),
    ?assertEqual(<<"p0">>, hd(plan_models(R))),
    ?assertEqual(3, length(plan_models(R))),
    %% 权重 9:1，期望约 900
    ?assert(Heavy > 820 andalso Heavy < 970),
    application:unset_env(lg_core, route_max_attempts).

plan_cooldown_fallback_limit() ->
    C = cred(<<"c">>),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"fb">>,
                                 <<"targets">> => [target(C, <<"a">>), target(C, <<"fb-only">>)]}),
    {ok, R} = lg_routes:create(#{<<"name">> => <<"main">>,
                                 <<"targets">> => [target(C, <<"a">>), target(C, <<"b">>, #{<<"priority">> => 1})],
                                 <<"fallbacks">> => [<<"fb">>]}),
    application:set_env(lg_core, route_max_attempts, 10),
    %% 回退路由里与主路由重复的目标去重
    ?assertEqual([<<"a">>, <<"b">>, <<"fb-only">>], plan_models(R)),
    ?assertMatch([{<<"main">>, _, _}, {<<"main">>, _, _}, {<<"fb">>, _, _}], lg_router:plan(R)),
    %% 冷却中的目标排到最后
    ok = lg_cooldown:mark({C, <<"a">>}, #{kind => server, retry_after_ms => undefined}),
    ?assertEqual([<<"b">>, <<"a">>, <<"fb-only">>], plan_models(R)),
    ok = lg_cooldown:clear(),
    application:unset_env(lg_core, route_max_attempts),
    ?assertEqual(3, length(plan_models(R))),
    application:set_env(lg_core, route_max_attempts, 2),
    ?assertEqual([<<"a">>, <<"b">>], plan_models(R)),
    application:unset_env(lg_core, route_max_attempts).

wildcard_routes() ->
    Fixture = #{<<"openrouter">> => #{<<"name">> => <<"OpenRouter">>, <<"npm">> => <<"@openrouter/ai-sdk-provider">>,
                                      <<"models">> => #{<<"anthropic/claude-x">> => #{<<"cost">> => #{<<"input">> => 1}},
                                                        <<"deepseek/v3">> => #{}}}},
    {ok, _} = lg_catalog_sync:import(iolist_to_binary(json:encode(Fixture))),
    {ok, #lg_credential{id = OR}} =
        lg_credentials:create(#{<<"name">> => <<"or">>, <<"protocol">> => <<"openai">>,
                                <<"base_url">> => <<"https://openrouter.ai/api/v1">>, <<"provider">> => <<"openrouter">>}),
    C = cred(<<"plain">>),
    T = fun(Cred, M) -> #{<<"credential">> => Cred, <<"upstream_model">> => M} end,
    Upstreams = fun(Name) ->
                        {ok, R, Rest} = lg_routes:match(Name),
                        lists:sort([{Cr, maps:get(upstream_model, X), maps:get(model_ref, X, none)}
                                    || {_, #{credential := Cr} = X, _} <- lg_router:plan(R, all, Rest)])
                end,

    %% 名称校验：* 只能出现一次且在末尾（单独 * 或 前缀*）；* 目标只能出现在通配路由
    [?assertEqual({error, {invalid, <<"name">>}}, lg_routes:create(#{<<"name">> => N, <<"targets">> => [T(C, <<"m">>)]}))
     || N <- [<<"a/*/b">>, <<"a/**">>, <<"*/a">>]],
    ?assertEqual({error, {invalid, <<"upstream_model">>}},
                 lg_routes:create(#{<<"name">> => <<"exact">>, <<"targets">> => [T(C, <<"*">>)]})),

    {ok, _} = lg_routes:create(#{<<"name">> => <<"or/*">>, <<"targets">> => [T(OR, <<"*">>)]}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"or/anthropic/*">>,
                                 <<"targets">> => [T(OR, <<"*">>), T(C, <<"fixed">>)]}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"or/deepseek/v3">>, <<"targets">> => [T(C, <<"exact-model">>)]}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"*">>, <<"targets">> => [T(C, <<"*">>)]}),

    %% 精确优先；否则最长前缀；前缀本身（无剩余部分）落到更短的通配
    ?assertMatch({ok, #lg_route{name = <<"or/deepseek/v3">>}, undefined}, lg_routes:match(<<"or/deepseek/v3">>)),
    ?assertMatch({ok, #lg_route{name = <<"or/anthropic/*">>}, <<"claude-x">>}, lg_routes:match(<<"or/anthropic/claude-x">>)),
    ?assertMatch({ok, #lg_route{name = <<"or/*">>}, <<"meta/llama">>}, lg_routes:match(<<"or/meta/llama">>)),
    ?assertMatch({ok, #lg_route{name = <<"*">>}, <<"or/">>}, lg_routes:match(<<"or/">>)),
    ?assertMatch({ok, #lg_route{name = <<"*">>}, <<"anything">>}, lg_routes:match(<<"anything">>)),

    %% * 目标代入剩余部分；目录中有 {openrouter, 剩余部分} 时带计费参考，否则不计费
    ?assertEqual(lists:sort([{C, <<"fixed">>, none}, {OR, <<"claude-x">>, none}]),
                 Upstreams(<<"or/anthropic/claude-x">>)),
    ?assertEqual([{OR, <<"deepseek/v3x">>, none}], Upstreams(<<"or/deepseek/v3x">>)),
    {ok, OrAll, _} = lg_routes:match(<<"or/meta/llama">>),
    [{_, Billed, _}] = lg_router:plan(OrAll, all, <<"anthropic/claude-x">>),
    ?assertEqual({<<"openrouter">>, <<"anthropic/claude-x">>}, maps:get(model_ref, Billed)),
    %% 精确路由（剩余部分 undefined）跳过 * 目标
    ?assertEqual([], lg_router:plan(OrAll, all, undefined)),

    %% /v1/models：通配路由按目录供应商展开；无目录供应商的通配路由列出自身
    {ok, _, Key} = lg_api_keys:create(#{<<"name">> => <<"k">>}),
    Models = lg_router:models(Key),
    [?assert(lists:member(M, Models)) || M <- [<<"or/anthropic/claude-x">>, <<"or/deepseek/v3">>,
                                               <<"or/anthropic/anthropic/claude-x">>, <<"*">>]],
    ?assertNot(lists:member(<<"or/*">>, Models)).

%% 直接写入套餐配置与额度状态（绕过 lg_credentials，避免触发真实查询）
set_plan(CredId, UsedPct, ResetsAt) ->
    {ok, C} = lg_credentials:get(CredId),
    ok = lg_db:write(C#lg_credential{options = #{plan => #{<<"kind">> => <<"minimax">>, <<"reserve_pct">> => 20}}}),
    ets:insert(lg_plan_status, {CredId, #{kind => <<"minimax">>, reserve_pct => 20, level => null, error => null,
                                          fetched_at => lg_time:now_ms(), checked_at => lg_time:now_ms(),
                                          windows => [#{name => <<"5h">>, used_pct => UsedPct,
                                                        resets_at => ResetsAt}]}}).

plan_quota_tiers() ->
    application:set_env(lg_core, route_max_attempts, 10),
    Pay = cred(<<"pay">>),
    Sub = cred(<<"sub">>),
    Sub2 = cred(<<"sub2">>),
    {ok, R} = lg_routes:create(#{<<"name">> => <<"r">>,
                                 <<"targets">> => [target(Sub, <<"s">>, #{<<"weight">> => 100}), target(Pay, <<"p">>),
                                                   target(Sub2, <<"s2">>, #{<<"priority">> => 1})],
                                 %% 固定顺序：加权随机下 s 仍有约 1% 的概率不排第一
                                 <<"options">> => #{<<"strategy">> => <<"order">>}}),
    Later = lg_time:now_ms() + 3600000,
    set_plan(Sub, 10, Later),
    set_plan(Sub2, 10, Later),
    %% 额度正常：按优先级与权重
    ?assertEqual(<<"s">>, hd(plan_models(R))),
    %% 保留：排到同路由其他目标（含低优先级、冷却中的非保留目标之前的正常目标）之后
    set_plan(Sub, 85, Later),
    ?assertEqual([<<"p">>, <<"s2">>, <<"s">>], plan_models(R)),
    ok = lg_cooldown:mark({Pay, <<"p">>}, #{kind => server, retry_after_ms => undefined}),
    ?assertEqual([<<"s2">>, <<"s">>, <<"p">>], plan_models(R)),
    ok = lg_cooldown:clear(),
    %% 用尽：跳过；已过重置时刻即恢复
    set_plan(Sub, 100, Later),
    ?assertEqual([<<"p">>, <<"s2">>], plan_models(R)),
    set_plan(Sub, 100, lg_time:now_ms() - 1),
    ?assertEqual(3, length(plan_models(R))),
    %% 全部用尽：返回最早恢复时刻
    {ok, Only} = lg_routes:create(#{<<"name">> => <<"only">>,
                                    <<"targets">> => [target(Sub, <<"s">>), target(Sub2, <<"s2">>)]}),
    set_plan(Sub, 100, Later + 1000),
    set_plan(Sub2, 100, Later),
    ?assertEqual([], lg_router:plan(Only)),
    {ok, K, _} = lg_api_keys:create(#{<<"name">> => <<"k">>}),
    {ok, Key} = lg_api_keys:authenticate(K),
    ?assertMatch({error, {plan_exhausted, Later}, _},
                 lg_router:chat(openai, #{<<"model">> => <<"only">>, <<"messages">> => []}, #{key => Key})),
    application:unset_env(lg_core, route_max_attempts).

%% 编码工具的固定模型名：别名精确映射、任意前缀通配（claude-*）
aliases_and_prefix_wildcards() ->
    C = cred(<<"c">>),
    T = fun(M) -> [#{<<"credential">> => C, <<"upstream_model">> => M}] end,
    {ok, _} = lg_routes:create(#{<<"name">> => <<"glm">>, <<"targets">> => T(<<"glm-5">>),
                                 <<"aliases">> => [<<"claude-sonnet-4-5">>, <<"claude-sonnet-4-5">>]}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"claude-*">>, <<"targets">> => T(<<"fallback-model">>)}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"gpt-5*">>, <<"targets">> => T(<<"*">>)}),
    %% 别名优先于通配；前缀通配取最长；* 目标代入剩余部分
    ?assertMatch({ok, #lg_route{name = <<"glm">>}, undefined}, lg_routes:match(<<"claude-sonnet-4-5">>)),
    ?assertMatch({ok, #lg_route{name = <<"claude-*">>}, <<"haiku-4-5">>}, lg_routes:match(<<"claude-haiku-4-5">>)),
    {ok, R, Rest} = lg_routes:match(<<"gpt-5-codex">>),
    ?assertEqual([<<"-codex">>], [M || {_, #{upstream_model := M}, _} <- lg_router:plan(R, all, Rest)]),
    ?assertEqual([<<"claude-sonnet-4-5">>], lg_routes:aliases(<<"glm">>)),
    ?assertMatch(#{<<"aliases">> := [<<"claude-sonnet-4-5">>]}, lg_routes:to_map(element(2, lg_routes:get(<<"glm">>)))),
    %% 冲突：别名与路由名、其他路由的别名；路由名与已有别名；别名不能含 *
    ?assertEqual({error, {alias_conflict, <<"glm">>}},
                 lg_routes:create(#{<<"name">> => <<"x">>, <<"targets">> => T(<<"m">>), <<"aliases">> => [<<"glm">>]})),
    ?assertEqual({error, {alias_conflict, <<"claude-sonnet-4-5">>}},
                 lg_routes:create(#{<<"name">> => <<"y">>, <<"targets">> => T(<<"m">>),
                                    <<"aliases">> => [<<"claude-sonnet-4-5">>]})),
    ?assertEqual({error, already_exists},
                 lg_routes:create(#{<<"name">> => <<"claude-sonnet-4-5">>, <<"targets">> => T(<<"m">>)})),
    ?assertEqual({error, {invalid, <<"aliases">>}},
                 lg_routes:create(#{<<"name">> => <<"z">>, <<"targets">> => T(<<"m">>), <<"aliases">> => [<<"a*">>]})),
    ?assertEqual(not_found, lg_routes:get(<<"x">>)),
    %% 更新替换别名；Key 的模型列表包含别名
    {ok, _} = lg_routes:update(<<"glm">>, #{<<"aliases">> => [<<"claude-opus-4-1">>]}),
    ?assertMatch({ok, #lg_route{name = <<"claude-*">>}, _}, lg_routes:match(<<"claude-sonnet-4-5">>)),
    {ok, _, Key} = lg_api_keys:create(#{<<"name">> => <<"k">>}),
    ?assert(lists:member(<<"claude-opus-4-1">>, lg_router:models(Key))),
    %% 删除路由同时删除别名
    ok = lg_routes:delete(<<"glm">>),
    ?assertEqual([], mnesia:dirty_all_keys(lg_route_alias)).

%% 冷却分级：时长、连续再犯翻倍、作用范围、成功清除、额度恢复
cooldown_kinds() ->
    application:set_env(lg_core, route_cooldown_ms, 1000),
    C = cred(<<"c">>),
    Err = fun(Kind) -> #{kind => Kind, retry_after_ms => undefined, message => <<"m">>} end,
    Near = fun(Expected, Got) -> ?assert(Got =< Expected andalso Got > Expected - 200) end,
    %% 服务端错误：基础时长，连续再犯翻倍；只冷却该模型
    ok = lg_cooldown:mark({C, <<"a">>}, Err(server)),
    Near(1000, lg_cooldown:remaining_ms({C, <<"a">>})),
    ok = lg_cooldown:mark({C, <<"a">>}, Err(server)),
    Near(2000, lg_cooldown:remaining_ms({C, <<"a">>})),
    ?assertMatch(#{streak := 2, scope := target}, lg_cooldown:info({C, <<"a">>})),
    ?assertNot(lg_cooldown:cooling({C, <<"b">>})),
    %% 上限：限流 30 分钟、服务端 10 分钟
    ?assertEqual(1800000, lg_cooldown:duration(rate_limit, #{}, 30)),
    ?assertEqual(600000, lg_cooldown:duration(server, #{}, 30)),
    ?assertEqual(6000, lg_cooldown:duration(auth, #{}, 1)),
    %% Retry-After 优先，上限 1 小时
    ?assertEqual(5000, lg_cooldown:duration(rate_limit, #{retry_after_ms => 5000}, 3)),
    ?assertEqual(3600000, lg_cooldown:duration(rate_limit, #{retry_after_ms => 99999999}, 1)),
    %% 该模型不可用（unserved）：只冷却该模型，凭证其他模型不受影响
    ok = lg_cooldown:mark({C, <<"u">>}, Err(unserved)),
    ?assertMatch(#{kind := unserved, scope := target}, lg_cooldown:info({C, <<"u">>})),
    ?assertNot(lg_cooldown:cooling({C, <<"b">>})),
    %% 余额不足：30 分钟，整个凭证
    ok = lg_cooldown:mark({C, <<"a">>}, Err(credit)),
    Near(1800000, lg_cooldown:remaining_ms({C, <<"b">>})),
    %% 成功一次清除模型与凭证的冷却
    ok = lg_cooldown:succeeded({C, <<"a">>}),
    ?assertNot(lg_cooldown:cooling({C, <<"b">>})),
    ?assertNot(lg_cooldown:cooling({C, <<"a">>})),
    %% 额度用尽：错误中的重置时刻 → 套餐窗口 → 15 分钟；上限 8 天
    Now = lg_time:now_ms(),
    Near(3600000, lg_cooldown:duration(quota, #{reset_at => Now + 3600000}, 1)),
    ?assertEqual(8 * 86400000, lg_cooldown:duration(quota, #{reset_at => Now + 30 * 86400000}, 1)),
    ?assertEqual(900000, lg_cooldown:duration(quota, #{credential => C}, 1)),
    set_plan(C, 100, Now + 7200000),
    Near(7200000, lg_cooldown:duration(quota, #{credential => C}, 1)),
    ok = lg_cooldown:mark({C, <<"a">>}, Err(quota)),
    ?assert(lg_cooldown:cooling({C, <<"zzz">>})),
    %% 套餐额度恢复：解除额度冷却（其他类型的凭证冷却不受影响）
    ok = lg_cooldown:recovered(C),
    ?assertNot(lg_cooldown:cooling({C, <<"zzz">>})),
    ok = lg_cooldown:mark({C, <<"a">>}, Err(auth)),
    ok = lg_cooldown:recovered(C),
    ?assert(lg_cooldown:cooling({C, <<"zzz">>})),
    ok = lg_cooldown:clear(),
    application:unset_env(lg_core, route_cooldown_ms).

%% 模型退役：410 / 退役措辞识别、尝试顺序剔除、一周过期、成功恢复、/v1/models 隐藏
retired() ->
    application:set_env(lg_core, route_max_attempts, 10),
    C = cred(<<"c">>),
    {ok, R} = lg_routes:create(#{<<"name">> => <<"r">>,
                                 <<"targets">> => [target(C, <<"p1-heavy">>), target(C, <<"p1-light">>)]}),
    ?assert(lg_unfit:retired_error(410, <<"Gone">>)),
    ?assert(lg_unfit:retired_error(400, <<"Model exo-free has been deprecated.">>)),
    ?assert(lg_unfit:retired_error(404, <<"该模型已下架"/utf8>>)),
    ?assertNot(lg_unfit:retired_error(400, <<"invalid body">>)),
    ?assertNot(lg_unfit:retired_error(500, <<"deprecated">>)),
    %% 记为退役后从尝试顺序剔除，其他模型不受影响；成功后恢复
    ok = lg_unfit:retire(C, <<"p1-heavy">>, <<"Model exo-free has been deprecated.">>),
    ?assertNot(lists:member(<<"p1-heavy">>, plan_models(R))),
    ?assert(lists:member(<<"p1-light">>, plan_models(R))),
    ok = lg_unfit:clear_retired(C, <<"p1-heavy">>),
    ?assert(lists:member(<<"p1-heavy">>, plan_models(R))),
    %% 一周后过期（惰性清除）
    ok = lg_unfit:retire(C, <<"p1-heavy">>, <<"deprecated">>),
    ok = mnesia:dirty_write(#lg_unfit{key = {C, <<"p1-heavy">>, retired},
                                      message = <<"m">>, learned_at = lg_time:now_ms() - 8 * 86400000}),
    ?assertNot(lg_unfit:retired(C, <<"p1-heavy">>)),
    %% 唯一目标退役的精确路由不再出现在 /v1/models
    {ok, _} = lg_routes:create(#{<<"name">> => <<"solo">>, <<"targets">> => [target(C, <<"solo-model">>)]}),
    {ok, _, Key} = lg_api_keys:create(#{<<"name">> => <<"k">>}),
    ?assert(lists:member(<<"solo">>, lg_router:models(Key))),
    ok = lg_unfit:retire(C, <<"solo-model">>, <<"deprecated">>),
    ?assertNot(lists:member(<<"solo">>, lg_router:models(Key))),
    ok = lg_unfit:clear_retired(C, <<"solo-model">>),
    ?assert(lists:member(<<"solo">>, lg_router:models(Key))),
    ok = lg_routes:delete(<<"solo">>),
    ok = lg_routes:delete(<<"r">>),
    application:unset_env(lg_core, route_max_attempts).

%% 配置自动备份：导出加密快照、可按口令导入还原、滚动保留、非法文件名拒绝
backup() ->
    C = cred(<<"c">>),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"r">>, <<"targets">> => [target(C, <<"m">>)]}),
    ok = lg_config:set(backup_passphrase, <<"passphrase-123">>),
    ok = lg_config:set(backup_keep, 2),
    %% 未设口令时报错；设置后立即备份
    ok = lg_config:set(backup_passphrase, <<>>),
    {error, {invalid, <<"backup_passphrase">>}} = lg_backup:run(),
    ok = lg_config:set(backup_passphrase, <<"passphrase-123">>),
    {ok, #{file := F1, size := N1}} = lg_backup:run(),
    ?assertMatch(<<"litegate-backup-", _/binary>>, F1),
    ?assert(N1 > 0),
    %% 备份文件可用同一口令 dry-run 导入（内容完整可还原）
    {ok, Bin} = file:read_file(filename:join([lg_config:get(data_dir), <<"backups">>, F1])),
    {ok, _} = lg_config_io:import(json:decode(Bin), <<"passphrase-123">>, merge, true),
    %% 滚动保留：备 3 份只留 2 份（文件名秒级时间戳，间隔 1 秒保证不同名）
    timer:sleep(1100),
    {ok, #{file := F2}} = lg_backup:run(),
    timer:sleep(1100),
    {ok, #{file := F3}} = lg_backup:run(),
    Files = [F || #{file := F} <- lg_backup:list()],
    ?assertEqual([F3, F2], Files),
    %% 状态与列表
    #{ok := true, file := F3} = lg_backup:status(),
    %% 滚动保留已删掉最旧的 F1；F2 手动删除；路径穿越与随机名拒绝
    {error, not_found} = lg_backup:delete(F1),
    ok = lg_backup:delete(F2),
    {error, invalid_name} = lg_backup:delete(<<"../settings.dets">>),
    {error, invalid_name} = lg_backup:delete(<<"other.json">>),
    ok = lg_config:set(backup_keep, 14),
    ok = lg_config:set(backup_passphrase, <<>>).

%% 单凭证并发：占用、排队、超时、队列满、进程退出释放
concurrency() ->
    application:set_env(lg_core, queue_limit, 1),
    Hold = fun(C, Max) ->
                   Self = self(),
                   P = spawn(fun() -> Self ! {held, self(), lg_conc:acquire(C, Max)}, receive release -> lg_conc:release(C), receive stop -> ok end; stop -> ok end end),
                   receive {held, P, R} -> {P, R} end
           end,
    {P1, ok} = Hold(<<"c">>, 2),
    {P2, ok} = Hold(<<"c">>, 2),
    {P3, busy} = Hold(<<"c">>, 2),
    P3 ! stop,
    ?assertEqual(2, lg_conc:inflight(<<"c">>)),
    ?assert(lg_conc:full(<<"c">>, 2)),
    ?assertNot(lg_conc:full(<<"c">>, 0)),
    %% 排队超时
    ?assertEqual(timeout, lg_conc:wait(<<"c">>, 2, 50)),
    ?assertEqual(0, lg_conc:queued(<<"c">>)),
    %% 一个在排队，第二个排队者因队列满（queue_limit = 1）立即返回 full
    Self = self(),
    W = spawn(fun() -> Self ! {waited, lg_conc:wait(<<"c">>, 2, 5000)}, receive stop -> ok end end),
    wait_until(fun() -> lg_conc:queued(<<"c">>) =:= 1 end),
    ?assertEqual(full, lg_conc:wait(<<"c">>, 2, 1000)),
    %% 释放一个名额：排队者拿到
    P1 ! release,
    receive {waited, R} -> ?assertEqual(ok, R) after 2000 -> error(not_granted) end,
    ?assertEqual(2, lg_conc:inflight(<<"c">>)),
    %% 持有者进程退出：名额自动释放
    exit(W, kill),
    exit(P2, kill),
    P1 ! stop,
    wait_until(fun() -> lg_conc:inflight(<<"c">>) =:= 0 end),
    application:unset_env(lg_core, queue_limit).

wait_until(F) -> wait_until(F, 100).
wait_until(_F, 0) -> error(timeout);
wait_until(F, N) ->
    case F() of
        true -> ok;
        false -> timer:sleep(10), wait_until(F, N - 1)
    end.

%% 并发抢名额：8 个进程同时抢 4 个名额，恰好 4 个成功；持有窗口内 inflight 不超过上限
concurrency_race() ->
    C = <<"race-c">>,
    Self = self(),
    N = 8, Max = 4,
    _ = spawn(fun() -> sample_inflight(Self, C, 60, 0) end),
    Workers = [spawn(fun() ->
                             Self ! ready,
                             receive go -> ok end,
                             R = lg_conc:acquire(C, Max),
                             timer:sleep(30),
                             R =:= ok andalso lg_conc:release(C),
                             Self ! {done, R}
                     end) || _ <- lists:seq(1, N)],
    [receive ready -> ok end || _ <- Workers],
    [W ! go || W <- Workers],
    Results = [receive {done, R} -> R after 5000 -> error(acquire_timeout) end || _ <- Workers],
    ?assertEqual(Max, length([ok || ok <- Results])),
    receive {max_seen, Seen} -> ?assert(Seen =< Max) after 5000 -> error(sample_timeout) end,
    ?assertEqual(0, lg_conc:inflight(C)).

sample_inflight(Parent, _C, 0, MaxSeen) -> Parent ! {max_seen, MaxSeen};
sample_inflight(Parent, C, N, MaxSeen) ->
    M = lg_conc:inflight(C),
    timer:sleep(5),
    sample_inflight(Parent, C, N - 1, max(MaxSeen, M)).

%% 持有者进程同时退出：名额经监视释放，新请求能拿到
concurrency_race_release() ->
    C = <<"race-c2">>,
    Self = self(),
    Holders = [spawn(fun() -> Self ! {held, lg_conc:acquire(C, 4)}, receive stop -> ok end end)
               || _ <- lists:seq(1, 4)],
    [receive {held, ok} -> ok end || _ <- Holders],
    ?assertEqual(4, lg_conc:inflight(C)),
    [exit(H, kill) || H <- lists:sublist(Holders, 2)],
    wait_until(fun() -> lg_conc:inflight(C) =:= 2 end),
    New = [spawn(fun() -> Self ! {held2, lg_conc:acquire(C, 4)} end) || _ <- lists:seq(1, 2)],
    [receive {held2, ok} -> ok after 2000 -> error(not_released) end || _ <- New],
    [H ! stop || H <- Holders],
    wait_until(fun() -> lg_conc:inflight(C) =:= 0 end).

%% 并发冷却：16 个进程同时标记同一目标，冷却生效且不连带其他模型；成功清零
cooldown_race() ->
    C = cred(<<"race-cred">>),
    application:set_env(lg_core, route_cooldown_ms, 50),
    Err = #{kind => server, retry_after_ms => undefined, message => <<"m">>},
    Self = self(),
    [spawn(fun() -> lg_cooldown:mark({C, <<"a">>}, Err), Self ! marked end) || _ <- lists:seq(1, 16)],
    [receive marked -> ok end || _ <- lists:seq(1, 16)],
    ?assert(lg_cooldown:cooling({C, <<"a">>})),
    ?assertNot(lg_cooldown:cooling({C, <<"b">>})),
    ok = lg_cooldown:succeeded({C, <<"a">>}),
    ?assertNot(lg_cooldown:cooling({C, <<"a">>})),
    ok = lg_cooldown:clear(),
    application:unset_env(lg_core, route_cooldown_ms).

%% 会话粘性：命中、一轮之内保留、新的一轮缓存不足时放弃、冷却 / 窗口用满时放弃
affinity_choose() ->
    application:set_env(lg_core, route_max_attempts, 10),
    A = cred(<<"a">>),
    B = cred(<<"b">>),
    {ok, R} = lg_routes:create(#{<<"name">> => <<"r">>, <<"targets">> => [target(A, <<"ma">>), target(B, <<"mb">>, #{<<"priority">> => 1})]}),
    Plan = lg_router:plan(R),
    Models = fun(P) -> [maps:get(upstream_model, T) || {_, T, _} <- P] end,
    ?assertEqual({Plan, miss}, lg_affinity:choose(Plan, <<"r">>, <<"s">>, <<"auto">>, true)),
    ?assertEqual({Plan, miss}, lg_affinity:choose(Plan, <<"r">>, undefined, <<"auto">>, true)),
    ok = lg_affinity:put_target(<<"r">>, <<"s">>, {B, <<"mb">>}, 0),
    %% 一轮之内：保留
    {P1, hit} = lg_affinity:choose(Plan, <<"r">>, <<"s">>, <<"auto">>, false),
    ?assertEqual([<<"mb">>, <<"ma">>], Models(P1)),
    %% 新的一轮、没读到缓存：放弃；session 模式始终保留；off 不处理
    ?assertEqual({Plan, {broken, <<"cache_cold">>}}, lg_affinity:choose(Plan, <<"r">>, <<"s">>, <<"auto">>, true)),
    ?assertMatch({[_ | _], hit}, lg_affinity:choose(Plan, <<"r">>, <<"s">>, <<"session">>, true)),
    ?assertEqual({Plan, off}, lg_affinity:choose(Plan, <<"r">>, <<"s">>, <<"off">>, true)),
    %% 缓存读到 ≥ 1024：新的一轮也保留
    ok = lg_affinity:put_target(<<"r">>, <<"s">>, {B, <<"mb">>}, 2000),
    {P2, hit} = lg_affinity:choose(Plan, <<"r">>, <<"s">>, <<"auto">>, true),
    ?assertEqual([<<"mb">>, <<"ma">>], Models(P2)),
    %% 目标冷却中 / 套餐窗口 ≥ 98%：放弃
    ok = lg_cooldown:mark({B, <<"mb">>}, #{kind => server, retry_after_ms => undefined}),
    ?assertEqual({Plan, {broken, <<"cooling">>}}, lg_affinity:choose(Plan, <<"r">>, <<"s">>, <<"auto">>, false)),
    ok = lg_cooldown:clear(),
    set_plan(B, 99, lg_time:now_ms() + 3600000),
    ?assertEqual({Plan, {broken, <<"plan_window_full">>}}, lg_affinity:choose(Plan, <<"r">>, <<"s">>, <<"auto">>, false)),
    %% 目标已不在尝试列表中
    ok = lg_affinity:put_target(<<"r">>, <<"s">>, {B, <<"gone">>}, 0),
    ?assertEqual({Plan, {broken, <<"target_gone">>}}, lg_affinity:choose(Plan, <<"r">>, <<"s">>, <<"auto">>, false)),
    %% rotate 用的会话计数
    ok = lg_affinity:put_target(<<"r">>, <<"s2">>, {A, <<"ma">>}, 0),
    ?assertEqual(#{{B, <<"gone">>} => 1, {A, <<"ma">>} => 1}, lg_affinity:load(<<"r">>, 60000)),
    ok = lg_affinity:clear(),
    application:unset_env(lg_core, route_max_attempts).

%% 直接写入多窗口额度状态（保留比例 0，避免进入保留层影响策略顺序）
set_windows(CredId, Windows) ->
    set_windows(CredId, Windows, #{}).
set_windows(CredId, Windows, Caps) ->
    {ok, C} = lg_credentials:get(CredId),
    ok = lg_db:write(C#lg_credential{options = #{plan => #{<<"kind">> => <<"minimax">>}}}),
    ets:insert(lg_plan_status, {CredId, #{kind => <<"minimax">>, reserve_pct => 0, window_caps => Caps, level => null,
                                          error => null, fetched_at => lg_time:now_ms(), checked_at => lg_time:now_ms(),
                                          windows => [#{name => N, used_pct => U, resets_at => R} || {N, U, R} <- Windows]}}).

strategies() ->
    application:set_env(lg_core, route_max_attempts, 10),
    H = 3600000,
    Now = lg_time:now_ms(),
    [A, B, C, D, E] = [cred(N) || N <- [<<"a">>, <<"b">>, <<"c">>, <<"d">>, <<"e">>]],
    Route = fun(Strategy, Creds) ->
                    Name = <<"s-", Strategy/binary>>,
                    _ = lg_routes:delete(Name),
                    {ok, R} = lg_routes:create(#{<<"name">> => Name, <<"options">> => #{<<"strategy">> => Strategy},
                                                 <<"targets">> => [target(X, X) || X <- Creds]}),
                    R
            end,
    Order = fun(R) -> [Cr || {_, #{credential := Cr}, _} <- lg_router:plan(R)] end,
    ?assertEqual({error, {invalid, <<"options.strategy">>}},
                 lg_routes:create(#{<<"name">> => <<"bad">>, <<"options">> => #{<<"strategy">> => <<"x">>},
                                    <<"targets">> => [target(A, <<"m">>)]})),
    %% order：按配置顺序
    ROrder = Route(<<"order">>, [C, A, B]),
    [?assertEqual([C, A, B], Order(ROrder)) || _ <- lists:seq(1, 20)],
    %% rotate：无会话时轮转；有会话时承载最少的优先
    RRot = Route(<<"rotate">>, [A, B, C]),
    Firsts = lists:usort([hd(Order(RRot)) || _ <- lists:seq(1, 6)]),
    ?assertEqual(lists:sort([A, B, C]), Firsts),
    ok = lg_affinity:put_target(<<"s-rotate">>, <<"x1">>, {A, A}, 0),
    ok = lg_affinity:put_target(<<"s-rotate">>, <<"x2">>, {A, A}, 0),
    ok = lg_affinity:put_target(<<"s-rotate">>, <<"x3">>, {B, B}, 0),
    [?assertEqual(C, hd(Order(RRot))) || _ <- lists:seq(1, 6)],
    ?assertEqual(A, lists:last(Order(RRot))),
    %% usage：已用比例低的优先；无套餐时按近期 token 少的优先
    RUse = Route(<<"usage">>, [A, B, C]),
    ok = lg_affinity:add_tokens(A, 1000),
    ok = lg_affinity:add_tokens(B, 10),
    set_windows(C, [{<<"5h">>, 40, Now + H}]),
    ?assertEqual([B, A, C], Order(RUse)),
    %% smart：<90% 按最晚重置的窗口先重置的优先 → 90–98% → 无额度信息（按权重）→ ≥98%
    set_windows(A, [{<<"5h">>, 10, Now + H}, {<<"week">>, 50, Now + 48 * H}]),
    set_windows(B, [{<<"5h">>, 10, Now + 2 * H}, {<<"week">>, 60, Now + 24 * H}]),
    set_windows(C, [{<<"5h">>, 95, Now + H}, {<<"week">>, 30, Now + 10 * H}]),
    set_windows(D, [{<<"5h">>, 99, Now + H}, {<<"week">>, 30, Now + 5 * H}]),
    RSmart = Route(<<"smart">>, [A, B, C, D, E]),
    [?assertEqual([B, A, C, E, D], Order(RSmart)) || _ <- lists:seq(1, 10)],
    %% pace：周窗口剩余 ÷ 距重置小时数；相差 10% 以内按近期 token 少的优先；无额度信息的排后
    set_windows(A, [{<<"week">>, 50, Now + 10 * H}]),           %% 5.0
    set_windows(B, [{<<"1w">>, 20, Now + 100 * H}]),            %% 0.8
    set_windows(C, [{<<"week">>, 60, Now + 10 * H}]),           %% 4.0
    set_windows(D, [{<<"5h">>, 0, Now + H}, {<<"week">>, 48, Now + 10 * H}]),  %% 5.2
    ok = lg_affinity:add_tokens(D, 100000),
    RPace = Route(<<"pace">>, [A, B, C, D, E]),
    ?assertEqual([A, D, C, B, E], Order(RPace)),
    %% 窗口使用上限：超过即进入保留层
    set_windows(A, [{<<"5h">>, 55, Now + H}, {<<"week">>, 10, Now + 10 * H}], #{<<"5h">> => 50}),
    ?assertEqual(reserve, lg_plan:state(A)),
    set_windows(A, [{<<"5h">>, 45, Now + H}], #{<<"5h">> => 50}),
    ?assertEqual(normal, lg_plan:state(A)),
    ?assert(lg_plan:validate(#{<<"kind">> => <<"glm">>, <<"window_caps">> => #{<<"5h">> => 50, <<"1w">> => 40}})),
    ?assertNot(lg_plan:validate(#{<<"kind">> => <<"glm">>, <<"window_caps">> => #{<<"5h">> => 150}})),
    %% 决策说明
    ?assertMatch(<<"5h 45%", _/binary>>, lg_strategy:note(element(2, lg_credentials:get(A)))),
    ok = lg_affinity:clear(),
    application:unset_env(lg_core, route_max_attempts).

%% 决策说明里的重置时刻按配置时区显示（与规则时段判断的 timezone_offset_min 一致，不再硬编码 UTC+8）
timezone_note() ->
    C = cred(<<"tz-c">>),
    Ms = 1893456000000,   %% 2030-01-01 00:00:00 UTC（未来时刻，窗口未过期）
    set_windows(C, [{<<"5h">>, 45, Ms}]),
    application:set_env(lg_core, timezone_offset_min, 0),
    Note0 = lg_strategy:note(element(2, lg_credentials:get(C))),
    application:set_env(lg_core, timezone_offset_min, 480),
    Note8 = lg_strategy:note(element(2, lg_credentials:get(C))),
    application:unset_env(lg_core, timezone_offset_min),
    ?assertEqual(<<"5h 45% 重置 01-01 00:00"/utf8>>, Note0),
    ?assertEqual(<<"5h 45% 重置 01-01 08:00"/utf8>>, Note8).

%% skip 规则：既能按凭证 id 跳过直连目标，也能按路由名跳过嵌套成员目标
skip_rules() ->
    application:set_env(lg_core, route_max_attempts, 10),
    application:set_env(lg_core, patience_rounds, 0),   %% 500 属繁忙类错误，关掉整轮重试避免重复尝试
    Port = lg_mock_upstream:start(),
    Url = iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port), "/v1"]),
    Cred = fun(N) -> {ok, #lg_credential{id = Id}} =
                           lg_credentials:create(#{<<"name">> => N, <<"protocol">> => <<"openai">>,
                                                   <<"base_url">> => Url, <<"api_key">> => <<"sk-", N/binary>>}),
                     Id end,
    A = Cred(<<"sk-a">>), A2 = Cred(<<"sk-a2">>), B1 = Cred(<<"sk-b1">>), B2 = Cred(<<"sk-b2">>),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"sk-sub">>, <<"options">> => #{<<"strategy">> => <<"order">>},
                                 <<"targets">> => [#{<<"credential">> => B1, <<"upstream_model">> => <<"b1">>},
                                                    #{<<"credential">> => B2, <<"upstream_model">> => <<"b2">>}]}),
    Rule = fun(Skip) -> [#{<<"when">> => #{}, <<"skip">> => Skip}] end,
    {ok, _} = lg_routes:create(#{<<"name">> => <<"sk-main-nested">>, <<"options">> => #{<<"strategy">> => <<"order">>,
                                                                                       <<"rules">> => Rule([<<"sk-sub">>])},
                                 <<"targets">> => [#{<<"credential">> => A, <<"upstream_model">> => <<"a">>},
                                                   #{<<"route">> => <<"sk-sub">>}]}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"sk-main-cred">>, <<"options">> => #{<<"strategy">> => <<"order">>,
                                                                                     <<"rules">> => Rule([B1])},
                                 <<"targets">> => [#{<<"credential">> => A2, <<"upstream_model">> => <<"a2">>},
                                                   #{<<"route">> => <<"sk-sub">>}]}),
    {ok, _, Key} = lg_api_keys:create(#{<<"name">> => <<"sk-key">>}),
    %% 所有上游都返回 500：逐个尝试计划里的目标直到耗尽
    [lg_mock_upstream:expect({json, 500, #{}, <<"boom">>}) || _ <- lists:seq(1, 6)],
    Attempted = fun(Name) ->
                          Req = #{<<"model">> => Name,
                                  <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]},
                          {error, _, Out} = lg_router:chat(openai, Req, #{key => Key, new_turn => true}),
                          [maps:get(credential, X) || X <- maps:get(attempts, Out)]
                  end,
    %% 按路由名跳过嵌套成员：只剩直连凭证
    ?assertEqual([A], Attempted(<<"sk-main-nested">>)),
    ok = lg_cooldown:clear(),   %% 上一次尝试的 500 会让凭证进入冷却，避免影响下面的顺序
    %% 按凭证 id 跳过：嵌套路由里只剩 b2
    ?assertEqual([A2, B2], Attempted(<<"sk-main-cred">>)),
    lg_mock_upstream:stop(),
    application:unset_env(lg_core, route_max_attempts),
    application:unset_env(lg_core, patience_rounds).

%% 嵌套路由：校验、成环与层数、展开顺序与 via、删除保护、配置导出再导入
nested_routes() ->
    application:set_env(lg_core, route_max_attempts, 10),
    C = cred(<<"c">>),
    T = fun(M) -> target(C, M) end,
    N = fun(R) -> #{<<"route">> => R} end,
    Models = fun(Name) -> {ok, R} = lg_routes:get(Name), [maps:get(upstream_model, X) || {_, X, _} <- lg_router:plan(R)] end,
    {ok, _} = lg_routes:create(#{<<"name">> => <<"fast">>, <<"options">> => #{<<"strategy">> => <<"order">>},
                                 <<"targets">> => [T(<<"f1">>), T(<<"f2">>)]}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"wild/*">>, <<"targets">> => [T(<<"*">>)]}),
    %% 校验：不存在、自己、通配路由
    ?assertEqual({error, {unknown_route, <<"nope">>}},
                 lg_routes:create(#{<<"name">> => <<"x">>, <<"targets">> => [N(<<"nope">>)]})),
    ?assertEqual({error, {invalid, <<"targets">>}},
                 lg_routes:create(#{<<"name">> => <<"self">>, <<"targets">> => [N(<<"self">>)]})),
    ?assertEqual({error, {invalid, <<"targets">>}},
                 lg_routes:create(#{<<"name">> => <<"x">>, <<"targets">> => [N(<<"wild/*">>)]})),
    %% 展开：嵌套路由按它自己的策略原地展开，带 via；与其他目标按优先级排序
    {ok, _} = lg_routes:create(#{<<"name">> => <<"coder">>, <<"options">> => #{<<"strategy">> => <<"order">>},
                                 <<"targets">> => [T(<<"strong">>), (N(<<"fast">>))#{<<"priority">> => 1}]}),
    ?assertEqual([<<"strong">>, <<"f1">>, <<"f2">>], Models(<<"coder">>)),
    {ok, Coder} = lg_routes:get(<<"coder">>),
    ?assertEqual([undefined, [<<"fast">>], [<<"fast">>]],
                 [maps:get(via, X, undefined) || {_, X, _} <- lg_router:plan(Coder)]),
    ?assertMatch([#{<<"route">> := <<"fast">>, <<"priority">> := 1} | _],
                 lists:reverse(maps:get(<<"targets">>, lg_routes:to_map(Coder)))),
    %% 同一凭证 + 模型只尝试一次
    {ok, _} = lg_routes:update(<<"coder">>, #{<<"targets">> => [T(<<"f1">>), N(<<"fast">>)]}),
    ?assertEqual([<<"f1">>, <<"f2">>], Models(<<"coder">>)),
    %% 成环：fast 嵌套 coder → 拒绝
    ?assertMatch({error, {route_cycle, _}}, lg_routes:update(<<"fast">>, #{<<"targets">> => [N(<<"coder">>)]})),
    %% 层数：l0 → l1 → l2 → l3 → fast 共 4 层嵌套
    {ok, _} = lg_routes:create(#{<<"name">> => <<"l3">>, <<"targets">> => [N(<<"fast">>)]}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"l2">>, <<"targets">> => [N(<<"l3">>)]}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"l1">>, <<"targets">> => [N(<<"l2">>)]}),
    ?assertEqual({error, {invalid, <<"nesting_too_deep">>}},
                 lg_routes:create(#{<<"name">> => <<"l0">>, <<"targets">> => [N(<<"l1">>)]})),
    ?assertEqual([<<"f1">>, <<"f2">>], Models(<<"l1">>)),
    %% 删除保护；凭证删除检查不受嵌套目标影响
    ?assertEqual({error, {in_use, [<<"coder">>, <<"l3">>]}}, lg_routes:delete(<<"fast">>)),
    ?assertMatch({error, {in_use, _}}, lg_credentials:delete(C)),
    %% 配置导出再导入（嵌套目标引用的路由在文件中排在后面也能导入）
    {ok, Data} = lg_config_io:export(<<"passphrase-123">>),
    Decoded = json:decode(iolist_to_binary(json:encode(Data))),
    Routes = maps:get(<<"routes">>, Decoded),
    {ok, _} = lg_config_io:import(Decoded#{<<"routes">> => lists:reverse(Routes)}, <<"passphrase-123">>, replace, false),
    ?assertEqual([<<"f1">>, <<"f2">>], Models(<<"coder">>)),
    application:unset_env(lg_core, route_max_attempts).

%% 开流前等待总上限：hold_started 超过 stream_hold_max_ms 后不再尝试任何候选，直接 504；
%% 上限设 0（不限）时即使 hold_started 很老也照常开流
hold_max() ->
    application:set_env(lg_core, route_max_attempts, 10),
    Port = lg_mock_upstream:start(),
    Url = iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port), "/v1"]),
    {ok, #lg_credential{id = C}} =
        lg_credentials:create(#{<<"name">> => <<"hm">>, <<"protocol">> => <<"openai">>,
                                <<"base_url">> => Url, <<"api_key">> => <<"sk-hm">>}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"hm">>, <<"options">> => #{<<"strategy">> => <<"order">>},
                                 <<"targets">> => [#{<<"credential">> => C, <<"upstream_model">> => <<"m">>}]}),
    {ok, _, Key} = lg_api_keys:create(#{<<"name">> => <<"hm-key">>}),
    Req = #{<<"model">> => <<"hm">>,
            <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
            <<"stream">> => true},
    Old = lg_time:now_ms() - 999999,
    %% 已超上限：候选一个都不碰
    {error, #{kind := timeout, status := 504}, _} =
        lg_router:stream_open(openai, Req, #{key => Key, hold_started => Old}),
    [] = lg_mock_upstream:requests(),
    %% 上限 = 0（不限）：照常开流
    ok = lg_config:set(stream_hold_max_ms, 0),
    Frame = iolist_to_binary(lg_sse:encode(json:encode(
              #{<<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{<<"content">> => <<"ok">>}}]}))),
    lg_mock_upstream:expect({sse, [Frame]}),
    {ok, _, _} = lg_router:stream_open(openai, Req, #{key => Key, hold_started => Old}),
    lg_mock_upstream:stop(),
    application:unset_env(lg_core, route_max_attempts),
    ok = lg_config:unset(stream_hold_max_ms).

%% 路由能力：展开嵌套路由、规则 use、回退；按目录查能力并汇总；通配展开名代入上游模型
route_capabilities() ->
    Fixture = #{<<"p">> => #{<<"name">> => <<"P">>, <<"npm">> => <<"@ai-sdk/openai-compatible">>,
                             <<"models">> => #{<<"fast">> => #{<<"reasoning">> => false, <<"limit">> => #{<<"context">> => 128000, <<"output">> => 8000},
                                                               <<"modalities">> => #{<<"input">> => [<<"text">>, <<"image">>]}},
                                               <<"big">> => #{<<"reasoning">> => true, <<"limit">> => #{<<"context">> => 200000, <<"output">> => 32000},
                                                              <<"modalities">> => #{<<"input">> => [<<"text">>]}}}}},
    {ok, _} = lg_catalog_sync:import(iolist_to_binary(json:encode(Fixture))),
    {ok, #lg_credential{id = P}} =
        lg_credentials:create(#{<<"name">> => <<"pc">>, <<"protocol">> => <<"openai">>,
                                <<"base_url">> => <<"https://p.example.com/v1">>, <<"provider">> => <<"p">>}),
    Plain = cred(<<"plain">>),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"fast">>, <<"targets">> => [target(P, <<"fast">>)]}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"big">>, <<"targets">> => [target(P, <<"big">>)]}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"tier">>, <<"targets">> => [#{<<"route">> => <<"fast">>}],
                                 <<"options">> => #{<<"rules">> => [#{<<"when">> => #{<<"images">> => true}, <<"use">> => <<"big">>}]}}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"agg">>,
                                 <<"targets">> => [#{<<"route">> => <<"tier">>}, target(Plain, <<"kimi-for-coding">>)],
                                 <<"fallbacks">> => [<<"fast">>]}),
    {ok, #{route := <<"agg">>, targets := Ts, summary := S}} = lg_route_caps:get(<<"agg">>),
    %% kimi-for-coding（直连）、fast（经 tier）、big（tier 的规则）；回退里的 fast 去重
    ?assertEqual([{<<"kimi-for-coding">>, [<<"agg">>]}, {<<"fast">>, [<<"agg">>, <<"tier">>, <<"fast">>]},
                  {<<"big">>, [<<"agg">>, <<"tier">>, <<"big">>]}],
                 [{M, V} || #{upstream_model := M, via := V} <- Ts]),
    [Kimi, Fast, Big] = Ts,
    ?assertMatch(#{known := false, reasoning := null, locked_sampling := true}, Kimi),
    ?assertMatch(#{known := true, reasoning := false, output := 8000, images := true, locked_sampling := false}, Fast),
    ?assertMatch(#{known := true, reasoning := true, context := 200000, images := false}, Big),
    ?assertEqual(#{reasoning => some, context => 128000, output => 8000, images => some,
                   locked_sampling => true, unknown => 1}, S),
    ?assertMatch({ok, #{summary := #{reasoning := none, images := all, unknown := 0}}}, lg_route_caps:get(<<"fast">>)),
    %% 通配：p/* 展开名代入上游模型并查目录
    {ok, _} = lg_routes:create(#{<<"name">> => <<"p/*">>, <<"targets">> => [target(P, <<"*">>)]}),
    ?assertMatch({ok, #{route := <<"p/*">>, targets := [#{upstream_model := <<"big">>, reasoning := true}]}},
                 lg_route_caps:get(<<"p/big">>)),
    ?assertEqual(not_found, lg_route_caps:get(<<"nope">>)).

%% T02：cooldown 周期清扫 — 删除连续再犯窗口已过（Now > Until + 2*Duration）的条目
cooldown_sweep() ->
    application:set_env(lg_core, route_cooldown_ms, 1000),
    C = cred(<<"sw">>),
    Err = #{kind => server, retry_after_ms => undefined, message => <<"m">>},
    ok = lg_cooldown:clear(),
    %% 标记一次冷却：Duration=1000ms，Until=Now+1000
    ok = lg_cooldown:mark({C, <<"a">>}, Err),
    Now = lg_time:now_ms(),
    %% 手动把 Until 设为已过很久（Until + 2*Duration < Now）
    [{_, _, Kind, Streak, Dur, Reason}] = ets:lookup(lg_cooldown, {C, <<"a">>}),
    ets:insert(lg_cooldown, {{C, <<"a">>}, Now - 10 * Dur - 1, Kind, Streak, Dur, Reason}),
    %% 还在窗口内（Until + 2*Duration >= Now）→ 不会被清扫
    ok = lg_cooldown:mark({C, <<"b">>}, Err),
    %% 触发清扫
    ok = lg_cooldown:sweep(),
    ?assertEqual([], ets:lookup(lg_cooldown, {C, <<"a">>})),
    ?assertMatch([_], ets:lookup(lg_cooldown, {C, <<"b">>})),
    %% 清扫后再次失败的 streak 从 1 重计（与惰性覆盖语义一致）
    ok = lg_cooldown:mark({C, <<"a">>}, Err),
    ?assertMatch(#{streak := 1}, lg_cooldown:info({C, <<"a">>})),
    ok = lg_cooldown:clear(),
    application:unset_env(lg_core, route_cooldown_ms).

%% T02：affinity tokens 清扫 — 删除 30 天前的 token 条目
affinity_token_sweep() ->
    Now = lg_time:now_ms(),
    %% 近期 token → 不会被清扫
    ok = lg_affinity:add_tokens(<<"cred-new">>, 100),
    %% 30 天前的 token → 会被清扫
    ets:insert(lg_affinity, {{tokens, <<"cred-old">>}, 100.0, Now - 31 * 86400000}),
    ?assertEqual(2, length(length([1 || {{tokens, _}, _, _} <- ets:tab2list(lg_affinity)]))),
    %% 30 天前的 token 会在下次 sweep 时被清
    ?assertEqual([], ets:lookup(lg_affinity, {tokens, <<"cred-old">>})),
    ?assertEqual([], ets:lookup(lg_affinity, {tokens, <<"cred-old">>})),
    ?assertMatch([_], ets:lookup(lg_affinity, {tokens, <<"cred-new">>})).
