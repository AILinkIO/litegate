-module(lg_config_tests).

-include_lib("eunit/include/eunit.hrl").

config_test_() ->
    {setup, fun lg_core_test_util:start/0, fun lg_core_test_util:stop/1,
     [?_test(layers()),
      ?_test(env_conversion()),
      ?_test(unknown_key()),
      ?_test(all_sources()),
      ?_test(invalidate_all()),
      ?_test(concurrent_set_get())]}.

%% T18：缓存随 lg_core 启停，重启后不会读到上一轮运行参数
restart_clears_cache_test() ->
    Dir1 = lg_core_test_util:start(),
    ok = lg_config:set(upstream_timeout_ms, 1234),
    ?assertEqual(1234, lg_config:get(upstream_timeout_ms)),
    lg_core_test_util:stop(Dir1),
    Dir2 = lg_core_test_util:start(),
    try ?assertEqual(300000, lg_config:get(upstream_timeout_ms))
    after lg_core_test_util:stop(Dir2)
    end.

layers() ->
    K = upstream_timeout_ms,
    ?assertEqual(300000, lg_config:get(K)),                       %% 默认值
    application:set_env(lg_core, K, 1000),
    ?assertEqual(1000, lg_config:get(K)),                         %% sys.config（不缓存，实时读）                         %% sys.config
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

%% T18：导入等直接写 lg_setting 的路径靠 invalidate_all/0 让缓存失效
invalidate_all() ->
    K = upstream_timeout_ms,
    ?assertEqual(300000, lg_config:get(K)),
    ok = mnesia:dirty_write({lg_setting, K, 4321, 0}),
    ?assertEqual(300000, lg_config:get(K)),                       %% 仍命中缓存
    ok = lg_config:invalidate_all(),
    ?assertEqual(4321, lg_config:get(K)),
    ok = lg_config:unset(K).

%% T18：并发 set 与 get 交错后，缓存值必须等于最后一次写入（旧快照回填不能覆盖失效）
concurrent_set_get() ->
    K = route_max_attempts,
    Stop = atomics:new(1, []),
    Self = self(),
    Readers = [spawn_link(fun() -> read_loop(K, Stop), Self ! {done, self()} end) || _ <- lists:seq(1, 8)],
    [ok = lg_config:set(K, N) || N <- lists:seq(1, 2000)],
    atomics:put(Stop, 1, 1),
    [receive {done, P} -> ok end || P <- Readers],
    ?assertEqual(2000, lg_config:get(K)),
    ok = lg_config:unset(K).

read_loop(K, Stop) ->
    case atomics:get(Stop, 1) of
        1 -> ok;
        _ -> _ = lg_config:get(K), read_loop(K, Stop)
    end.

%% 环境变量层首次读取后缓存，测试中途修改需 invalidate_all/0
with_env(Name, Value, Fun) ->
    os:putenv(Name, Value),
    ok = lg_config:invalidate_all(),
    try Fun() after os:unsetenv(Name), lg_config:invalidate_all() end.
