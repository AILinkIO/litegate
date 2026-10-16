-module(lg_config_io_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("lg_core/include/lg_core.hrl").

config_io_test_() ->
    {foreach,
     fun() ->
             Dir = lg_core_test_util:start(),
             {ok, _} = application:ensure_all_started(lg_router),
             Dir
     end,
     fun(Dir) -> lg_core_test_util:stop(Dir) end,
     [{timeout, 60, ?_test(round_trip())},
      ?_test(errors())]}.

-define(PASS, <<"correct horse">>).

seed() ->
    {ok, #lg_credential{id = C1}} =
        lg_credentials:create(#{<<"name">> => <<"with-key">>, <<"protocol">> => <<"anthropic">>,
                                <<"base_url">> => <<"https://a.test">>, <<"api_key">> => <<"sk-secret-123">>,
                                <<"headers">> => #{<<"X-Org">> => <<"o">>},
                                <<"options">> => #{<<"responses_api">> => true,
                                                   <<"plan">> => #{<<"kind">> => <<"glm">>, <<"reserve_pct">> => 5},
                                                   <<"extra_body">> => #{<<"reasoning_split">> => true}}}),
    {ok, #lg_credential{id = C2}} =
        lg_credentials:create(#{<<"name">> => <<"no-key">>, <<"protocol">> => <<"openai">>,
                                <<"base_url">> => <<"http://local:8000/v1">>}),
    T = fun(C, M) -> #{<<"credential">> => C, <<"upstream_model">> => M} end,
    %% a 回退到 z：导入时 z 排在后面，验证两遍写入
    {ok, _} = lg_routes:create(#{<<"name">> => <<"z">>, <<"targets">> => [T(C2, <<"m2">>)],
                                 <<"aliases">> => [<<"claude-sonnet-4-5">>]}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"a">>, <<"targets">> => [T(C1, <<"m1">>)],
                                 <<"fallbacks">> => [<<"z">>], <<"options">> => #{<<"cache_ttl_s">> => 30}}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"w/*">>, <<"targets">> => [T(C2, <<"*">>)]}),
    {ok, Plain, #lg_api_key{id = K}} = lg_api_keys:create(#{<<"name">> => <<"k">>, <<"max_tokens">> => 10}),
    {ok, _} = lg_limits:set_limit({key, K}, #{<<"rpm">> => 5}),
    {ok, _} = lg_limits:set_limit({key_route, K, <<"a">>}, #{<<"max_parallel">> => 2}),
    {ok, _} = lg_limits:set_budget({key, K}, #{<<"period">> => <<"week">>, <<"max_usd">> => 3}),
    ok = lg_catalog:put_overlay({<<"p">>, <<"m">>}, #{<<"name">> => <<"Mine">>}),
    ok = lg_config:set(route_max_attempts, 7),
    {ok, _} = lg_users:create(#{<<"username">> => <<"boss">>, <<"password">> => <<"boss-password">>,
                                <<"role">> => <<"admin">>}),
    {ok, #lg_channel{id = Ch}} = lg_alerts:create_channel(#{<<"name">> => <<"ding">>, <<"type">> => <<"dingtalk">>,
                                                            <<"url">> => <<"https://oapi.dingtalk.com/robot/send?access_token=tok-123">>,
                                                            <<"secret">> => <<"SEC-456">>}),
    {ok, _} = lg_alerts:create_rule(#{<<"event">> => <<"budget">>, <<"threshold">> => 75, <<"channels">> => [Ch]}),
    {ok, _} = lg_middlewares:create(#{<<"name">> => <<"zh">>, <<"impl">> => <<"system_prompt">>, <<"position">> => 5,
                                      <<"routes">> => [<<"a">>], <<"options">> => #{<<"text">> => <<"用中文"/utf8>>}}),
    #{c1 => C1, c2 => C2, key => K, plain => Plain, channel => Ch}.

round_trip() ->
    #{c1 := C1, key := K, plain := Plain, channel := Ch} = seed(),
    {ok, Data} = lg_config_io:export(?PASS),
    Json = iolist_to_binary(json:encode(Data)),
    [?assertEqual(nomatch, binary:match(Json, Secret)) || Secret <- [<<"sk-secret-123">>, <<"tok-123">>, <<"SEC-456">>]],
    %% 模拟另一台机器：换主密钥、清空配置
    persistent_term:put({lg_crypto, master_key}, crypto:strong_rand_bytes(32)),
    wipe(),
    Decoded = json:decode(Json),
    ?assertEqual({error, bad_passphrase}, lg_config_io:import(Decoded, <<"wrong pass">>, merge, false)),
    %% 预览不写入
    {ok, Preview} = lg_config_io:import(Decoded, ?PASS, merge, true),
    ?assertMatch(#{credentials := #{new := 2, overwritten := 0}, routes := #{new := 3},
                   limits := #{new := 2}, users := #{new := 1}}, Preview),
    ?assertEqual([], lg_credentials:list()),
    %% 导入
    {ok, _} = lg_config_io:import(Decoded, ?PASS, merge, false),
    {ok, #lg_credential{api_key_enc = Enc, headers = H, options = O}} = lg_credentials:get(C1),
    ?assertEqual({ok, <<"sk-secret-123">>}, lg_crypto:decrypt(Enc)),
    ?assertEqual([{<<"x-org">>, <<"o">>}], H),
    ?assertMatch(#{responses_api := true, plan := #{<<"kind">> := <<"glm">>, <<"reserve_pct">> := 5},
                   extra_body := #{<<"reasoning_split">> := true}}, O),
    {ok, #lg_channel{type = dingtalk, url_enc = UEnc, secret_enc = SEnc}} = lg_alerts:channel(Ch),
    ?assertEqual({ok, <<"https://oapi.dingtalk.com/robot/send?access_token=tok-123">>}, lg_crypto:decrypt(UEnc)),
    ?assertEqual({ok, <<"SEC-456">>}, lg_crypto:decrypt(SEnc)),
    ?assertMatch([#lg_alert_rule{event = budget, threshold = 75, channels = [Ch]}], lg_alerts:rules()),
    ?assertMatch([#lg_middleware{name = <<"zh">>, impl = <<"system_prompt">>, position = 5, routes = [<<"a">>],
                                 options = #{<<"text">> := _}}], lg_middlewares:list()),
    ?assertMatch(#{chain := [#{name := <<"zh">>}]}, lg_middleware:begin_run(<<"a">>, #{})),
    ?assertMatch({ok, #lg_route{fallbacks = [<<"z">>], options = #{cache_ttl_s := 30}}}, lg_routes:get(<<"a">>)),
    ?assertMatch({ok, #lg_route{}}, lg_routes:get(<<"w/*">>)),
    ?assertEqual([<<"claude-sonnet-4-5">>], lg_routes:aliases(<<"z">>)),
    ?assertMatch({ok, #lg_api_key{id = K, max_tokens = 10}}, lg_api_keys:authenticate(Plain)),
    ?assertEqual(2, length(lg_limits:limits_for(K, <<"a">>))),
    ?assertMatch({ok, #lg_budget{period = week, max_usd = 3}}, lg_limits:get_budget({key, K})),
    ?assertMatch({ok, #{<<"name">> := <<"Mine">>}}, lg_catalog:overlay({<<"p">>, <<"m">>})),
    ?assertEqual(7, lg_config:get(route_max_attempts)),
    ?assertMatch({ok, _, _}, lg_users:login(<<"boss">>, <<"boss-password">>)),
    %% 再次合并导入：全部为覆盖；本地多出的路由保留
    {ok, _} = lg_routes:create(#{<<"name">> => <<"extra">>,
                                 <<"targets">> => [#{<<"credential">> => C1, <<"upstream_model">> => <<"x">>}]}),
    {ok, #{routes := #{new := 0, overwritten := 3, deleted := 0}}} = lg_config_io:import(Decoded, ?PASS, merge, false),
    ?assertMatch({ok, _}, lg_routes:get(<<"extra">>)),
    %% 替换导入：本地多出的删除
    {ok, #{routes := #{deleted := 4, new := 3}}} = lg_config_io:import(Decoded, ?PASS, replace, false),
    ?assertEqual(not_found, lg_routes:get(<<"extra">>)),
    %% 替换导入且文件中没有用户：保留现有用户
    {ok, _} = lg_config_io:import(Decoded#{<<"users">> => []}, ?PASS, replace, false),
    ?assertEqual(1, length(lg_users:list())).

wipe() ->
    _ = [mnesia:clear_table(T) || T <- [lg_credential, lg_route, lg_route_alias, lg_api_key, lg_limit, lg_budget,
                                    lg_model_overlay, lg_setting, lg_user, lg_channel, lg_alert_rule, lg_middleware]],
    ok = lg_middleware:reload().

errors() ->
    ?assertEqual({error, {invalid, <<"passphrase">>}}, lg_config_io:export(<<"short">>)),
    ?assertEqual({error, invalid_format}, lg_config_io:import(#{<<"x">> => 1}, ?PASS, merge, false)),
    {ok, Data} = lg_config_io:export(?PASS),
    ?assertEqual({error, {unsupported_version, 99}},
                 lg_config_io:import(Data#{<<"version">> => 99}, ?PASS, merge, false)),
    %% 路由引用了不存在的凭证：整体回滚
    Bad = Data#{<<"routes">> => [#{<<"name">> => <<"r">>,
                                   <<"targets">> => [#{<<"credential">> => <<"nope">>, <<"upstream_model">> => <<"m">>}]}]},
    ?assertEqual({error, {unknown_credential, <<"nope">>}}, lg_config_io:import(Bad, ?PASS, merge, false)),
    ?assertEqual(not_found, lg_routes:get(<<"r">>)).
