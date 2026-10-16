-module(lg_config_tests).

-include_lib("eunit/include/eunit.hrl").

config_test_() ->
    {setup, fun lg_core_test_util:start/0, fun lg_core_test_util:stop/1,
     [?_test(layers()),
      ?_test(env_conversion()),
      ?_test(unknown_key()),
      ?_test(all_sources())]}.

layers() ->
    K = upstream_timeout_ms,
    ?assertEqual(300000, lg_config:get(K)),                       %% 默认值
    application:set_env(lg_core, K, 1000),
    ?assertEqual(1000, lg_config:get(K)),                         %% sys.config
    with_env("LITEGATE_UPSTREAM_TIMEOUT_MS", "2000",
             fun() ->
                 ?assertEqual(2000, lg_config:get(K)),             %% 环境变量
                 ok = lg_config:set(K, 3000),
                 ?assertEqual(3000, lg_config:get(K)),             %% 运行参数
                 ok = lg_config:unset(K),
                 ?assertEqual(2000, lg_config:get(K))
             end),
    application:unset_env(lg_core, K),
    ?assertEqual(300000, lg_config:get(K)).

env_conversion() ->
    with_env("LITEGATE_RECORD_MESSAGES", "false",
             fun() -> ?assertEqual(false, lg_config:get(record_messages)) end),
    with_env("LITEGATE_CATALOG_URL", "http://x",
             fun() -> ?assertEqual(<<"http://x">>, lg_config:get(catalog_url)) end).

unknown_key() ->
    ?assertError({unknown_config, nope}, lg_config:get(nope)),
    ?assertError({unknown_config, nope}, lg_config:set(nope, 1)).

all_sources() ->
    ok = lg_config:set(record_messages, false),
    All = lg_config:all(),
    ?assertMatch([#{value := false, source := runtime}],
                 [E || E = #{key := record_messages} <- All]),
    ?assertMatch([#{source := default}],
                 [E || E = #{key := session_ttl_ms} <- All]),
    ok = lg_config:unset(record_messages).

with_env(Name, Value, Fun) ->
    os:putenv(Name, Value),
    try Fun() after os:unsetenv(Name) end.
