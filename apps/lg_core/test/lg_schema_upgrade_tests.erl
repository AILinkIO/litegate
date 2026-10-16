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
