%% @doc v1 → v4 升级：v2 中 lg_route 去掉 strategy / limits、增加 options，lg_credential 增加 options；
%% v3 中 lg_api_key 增加 tags；v4 中 lg_api_key 增加 options。
-module(lg_schema_upgrade_tests).

-include_lib("eunit/include/eunit.hrl").
-include("lg_core.hrl").

upgrade_from_v1_test() ->
    Dir = filename:join([os:getenv("TMPDIR", "/tmp"),
                         "lg_upgrade_" ++ integer_to_list(erlang:unique_integer([positive]))]),
    ok = filelib:ensure_path(Dir),
    MDir = filename:join(Dir, "mnesia"),
    application:set_env(mnesia, dir, MDir),
    application:set_env(lg_core, data_dir, Dir),
    try
        %% 按 v1 字段建库并写入旧格式数据
        ok = mnesia:create_schema([node()]),
        ok = mnesia:start(),
        {atomic, ok} = mnesia:create_table(lg_meta, [{attributes, [key, value]}, {disc_copies, [node()]}]),
        {atomic, ok} = mnesia:create_table(
                         lg_route, [{attributes, [name, targets, fallbacks, access, strategy, limits,
                                                  enabled, created_at, updated_at]},
                                    {disc_copies, [node()]}]),
        {atomic, ok} = mnesia:create_table(
                         lg_credential, [{attributes, [id, name, protocol, base_url, api_key_enc, headers,
                                                       provider, enabled, created_at, updated_at]},
                                         {disc_copies, [node()]}]),
        {atomic, ok} = mnesia:create_table(
                         lg_api_key, [{attributes, [id, hash, prefix, name, user_id, allowed_routes, max_tokens,
                                                    enabled, expires_at, created_at]},
                                      {disc_copies, [node()]}]),
        ok = mnesia:dirty_write({lg_api_key, <<"k">>, <<"h">>, <<"lgk-x">>, <<"key">>, undefined, all, undefined,
                                 true, undefined, 5}),
        ok = mnesia:dirty_write({lg_meta, schema_version, 1}),
        ok = mnesia:dirty_write({lg_route, <<"r">>, [#{credential => <<"c">>, upstream_model => <<"m">>}],
                                 [], all, weighted, #{}, true, 1, 2}),
        ok = mnesia:dirty_write({lg_credential, <<"c">>, <<"cred">>, openai, <<"https://x/v1">>, undefined,
                                 [], <<"openai">>, false, 3, 4}),
        stopped = mnesia:stop(),

        {ok, _} = application:ensure_all_started(lg_core),
        ?assertEqual({ok, #lg_meta{key = schema_version, value = 4}}, lg_db:read(lg_meta, schema_version)),
        ?assertMatch({ok, #lg_api_key{id = <<"k">>, name = <<"key">>, tags = [], options = #{}, created_at = 5}},
                     lg_db:read(lg_api_key, <<"k">>)),
        ?assertMatch({ok, #lg_route{name = <<"r">>, targets = [#{upstream_model := <<"m">>}], access = all,
                                    options = #{}, enabled = true, created_at = 1, updated_at = 2}},
                     lg_db:read(lg_route, <<"r">>)),
        ?assertMatch({ok, #lg_credential{id = <<"c">>, provider = <<"openai">>, options = #{},
                                         enabled = false, created_at = 3}},
                     lg_db:read(lg_credential, <<"c">>)),
        %% 升级前留有备份；新增的表已创建
        ?assertMatch([_], filelib:wildcard(filename:join(Dir, "mnesia-backup-v1-*.bup"))),
        ?assertMatch([_], filelib:wildcard(filename:join(Dir, "mnesia-backup-v2-*.bup"))),
        ?assertMatch([_], filelib:wildcard(filename:join(Dir, "mnesia-backup-v3-*.bup"))),
        ?assert(lists:member(lg_limit, mnesia:system_info(tables))),
        %% 重启不再升级
        ok = application:stop(lg_core),
        stopped = mnesia:stop(),
        {ok, _} = application:ensure_all_started(lg_core),
        ?assertMatch([_], filelib:wildcard(filename:join(Dir, "mnesia-backup-v1-*.bup")))
    after
        application:stop(lg_core),
        mnesia:stop(),
        application:unset_env(mnesia, dir),
        application:unset_env(lg_core, data_dir),
        file:del_dir_r(Dir)
    end.

%%====================================================================
%% T26：迁移可重入与节点名防护
%%====================================================================

-define(V1_ROUTE, [name, targets, fallbacks, access, strategy, limits, enabled, created_at, updated_at]).
-define(V1_CRED, [id, name, protocol, base_url, api_key_enc, headers, provider, enabled, created_at, updated_at]).
-define(V1_KEY, [id, hash, prefix, name, user_id, allowed_routes, max_tokens, enabled, expires_at, created_at]).

with_dir(Fun) ->
    Dir = filename:join([os:getenv("TMPDIR", "/tmp"),
                         "lg_upgrade_" ++ integer_to_list(erlang:unique_integer([positive]))]),
    ok = filelib:ensure_path(Dir),
    MDir = filename:join(Dir, "mnesia"),
    application:set_env(mnesia, dir, MDir),
    application:set_env(lg_core, data_dir, Dir),
    try
        Fun(Dir, MDir)
    after
        application:stop(lg_core),
        mnesia:stop(),
        application:unset_env(mnesia, dir),
        application:unset_env(lg_core, data_dir),
        file:del_dir_r(Dir)
    end.

create(Tab, Attrs) ->
    {atomic, ok} = mnesia:create_table(Tab, [{attributes, Attrs}, {disc_copies, [node()]}]).

%% 模拟 v1→v2 在 lg_route 转换提交后崩溃：lg_route 已是新格式、lg_credential 仍是旧格式，
%% 版本号仍为 1；WithMarker 决定崩溃发生在写进度之后还是之前。重启后迁移续完，记录全部为新格式。
crash_midway_test_() ->
    [?_test(crash_midway(true)), ?_test(crash_midway(false))].

crash_midway(WithMarker) ->
    with_dir(
      fun(_Dir, _MDir) ->
              ok = mnesia:create_schema([node()]),
              ok = mnesia:start(),
              create(lg_meta, [key, value]),
              create(lg_route, record_info(fields, lg_route)),
              create(lg_credential, ?V1_CRED),
              create(lg_api_key, ?V1_KEY),
              ok = mnesia:dirty_write({lg_meta, schema_version, 1}),
              ok = case WithMarker of
                       true -> mnesia:dirty_write({lg_meta, {schema_step, lg_route, 1}, 1});
                       false -> ok
                   end,
              Route = {lg_route, <<"r">>, [], [], all, #{cache_ttl_s => 5}, true, 1, 2},
              ok = mnesia:dirty_write(Route),
              ok = mnesia:dirty_write({lg_credential, <<"c">>, <<"cred">>, openai, <<"https://x/v1">>, undefined,
                                       [], <<"openai">>, false, 3, 4}),
              ok = mnesia:dirty_write({lg_api_key, <<"k">>, <<"h">>, <<"lgk-x">>, <<"key">>, undefined, all,
                                       undefined, true, undefined, 5}),
              stopped = mnesia:stop(),

              {ok, _} = application:ensure_all_started(lg_core),
              ?assertEqual({ok, #lg_meta{key = schema_version, value = 4}}, lg_db:read(lg_meta, schema_version)),
              %% 已转换的 lg_route 原样保留（未被当成旧格式再转一次）
              ?assertEqual({ok, Route}, lg_db:read(lg_route, <<"r">>)),
              ?assertMatch({ok, #lg_credential{id = <<"c">>, options = #{}, enabled = false, created_at = 3}},
                           lg_db:read(lg_credential, <<"c">>)),
              ?assertMatch({ok, #lg_api_key{id = <<"k">>, tags = [], options = #{}, created_at = 5}},
                           lg_db:read(lg_api_key, <<"k">>)),
              %% 进度标记在版本号写入后清除
              ?assertEqual([], [K || K = {schema_step, _, _} <- mnesia:dirty_all_keys(lg_meta)])
      end).

%% 数据已是 v4 格式但版本号停在 3（转换完成、版本号写入前崩溃）：重跑迁移不改动数据
rerun_on_migrated_data_test() ->
    with_dir(
      fun(Dir, _MDir) ->
              ok = mnesia:create_schema([node()]),
              ok = mnesia:start(),
              create(lg_meta, [key, value]),
              create(lg_api_key, record_info(fields, lg_api_key)),
              ok = mnesia:dirty_write({lg_meta, schema_version, 3}),
              Key = #lg_api_key{id = <<"k">>, hash = <<"h">>, prefix = <<"lgk-x">>, name = <<"key">>,
                                tags = [<<"t">>], options = #{redact => true}, created_at = 5},
              ok = mnesia:dirty_write(Key),
              stopped = mnesia:stop(),

              {ok, _} = application:ensure_all_started(lg_core),
              ?assertEqual({ok, #lg_meta{key = schema_version, value = 4}}, lg_db:read(lg_meta, schema_version)),
              ?assertEqual({ok, Key}, lg_db:read(lg_api_key, <<"k">>)),
              ?assertMatch([_], filelib:wildcard(filename:join(Dir, "mnesia-backup-v3-*.bup"))),
              %% 再重启一次：无升级、无新备份、数据不变
              ok = application:stop(lg_core),
              stopped = mnesia:stop(),
              {ok, _} = application:ensure_all_started(lg_core),
              ?assertEqual({ok, Key}, lg_db:read(lg_api_key, <<"k">>)),
              ?assertMatch([_], filelib:wildcard(filename:join(Dir, "mnesia-backup-v3-*.bup")))
      end).

%% 同一版本的升级重跑（上次中途崩溃）不再追加备份：保留升级前的原始备份
backup_once_per_version_test() ->
    with_dir(
      fun(Dir, _MDir) ->
              ok = mnesia:create_schema([node()]),
              ok = mnesia:start(),
              create(lg_meta, [key, value]),
              create(lg_route, ?V1_ROUTE),
              create(lg_credential, ?V1_CRED),
              create(lg_api_key, ?V1_KEY),
              ok = mnesia:dirty_write({lg_meta, schema_version, 1}),
              Old = filename:join(Dir, "mnesia-backup-v1-1.bup"),
              ok = mnesia:backup(Old),
              stopped = mnesia:stop(),
              {ok, _} = application:ensure_all_started(lg_core),
              ?assertEqual([Old], filelib:wildcard(filename:join(Dir, "mnesia-backup-v1-*.bup")))
      end).

%% 以不同节点名打开已有数据目录：启动 mnesia 之前就拒绝，目录里的文件一字节不改；
%% rename_node/1 迁移后可正常启动，数据保留，原目录留作备份
node_name_mismatch_test_() ->
    {timeout, 60, ?_test(node_name_mismatch())}.

node_name_mismatch() ->
    with_dir(
      fun(Dir, MDir) ->
              {ok, Peer, Other} = peer:start(#{name => peer:random_name(lg_schema_peer), host => "127.0.0.1",
                                               longnames => true, connection => standard_io}),
              try
                  _ = peer:call(Peer, application, load, [mnesia]),
                  ok = peer:call(Peer, application, set_env, [mnesia, dir, MDir]),
                  ok = peer:call(Peer, mnesia, create_schema, [[Other]]),
                  ok = peer:call(Peer, mnesia, start, []),
                  {atomic, ok} = peer:call(Peer, mnesia, create_table,
                                           [lg_meta, [{attributes, [key, value]}, {disc_copies, [Other]}]]),
                  ok = peer:call(Peer, mnesia, dirty_write, [{lg_meta, schema_version, lg_schema:version()}]),
                  ok = peer:call(Peer, mnesia, dirty_write, [{lg_meta, marker, <<"kept">>}]),
                  stopped = peer:call(Peer, mnesia, stop, [])
              after
                  peer:stop(Peer)
              end,
              Before = snapshot(MDir),
              ?assertEqual({error, {node_name_mismatch, node(), [Other]}}, lg_schema:init()),
              ?assertEqual(no, mnesia:system_info(is_running)),
              ?assertEqual(Before, snapshot(MDir)),
              ?assertMatch({error, _}, application:ensure_all_started(lg_core)),
              ?assertEqual(Before, snapshot(MDir)),

              ?assertEqual({error, same_node}, lg_schema:rename_node(node())),
              ?assertEqual(ok, lg_schema:rename_node(Other)),
              {ok, _} = application:ensure_all_started(lg_core),
              ?assertEqual([node()], mnesia:table_info(lg_meta, disc_copies)),
              ?assertEqual({ok, #lg_meta{key = marker, value = <<"kept">>}}, lg_db:read(lg_meta, marker)),
              [Aside] = filelib:wildcard(MDir ++ ".pre-rename-*"),
              %% 原目录整体留作备份（旧节点名打开过一次，日志已正常转储；schema 仍属旧节点）
              ?assertEqual(lists:keyfind("schema.DAT", 1, Before), lists:keyfind("schema.DAT", 1, snapshot(Aside))),
              ?assertEqual([], filelib:wildcard(filename:join(Dir, "*.bup")))
      end).

snapshot(D) ->
    {ok, Fs} = file:list_dir(D),
    lists:sort([{F, erlang:md5(element(2, {ok, _} = file:read_file(filename:join(D, F))))} || F <- Fs]).
