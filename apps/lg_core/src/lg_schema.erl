%% @doc mnesia 启动与表结构管理。
%%
%% lg_core 自己负责启动 mnesia：先把 mnesia 数据目录指到 `data_dir/mnesia`，
%% 再把 schema 转成 disc_copies、创建缺失的表并等待加载。
%% 表结构版本记录在 lg_meta 的 schema_version，升级逻辑写在 upgrade/1：
%% 先执行升级（可能改变字段），再校验字段与记录定义一致。升级前自动备份 mnesia。
-module(lg_schema).

-include("lg_core.hrl").

-export([init/0, tables/0, version/0, rename_node/1]).

-define(SCHEMA_VERSION, 4).
-define(WAIT_TIMEOUT, 30000).

%% @doc 启动 mnesia 并确保所有表就绪。
-spec init() -> ok | {error, term()}.
init() ->
    ok = set_mnesia_dir(),
    case application:ensure_all_started(mnesia) of
        {ok, _} ->
            case ensure_disc_schema() of
                ok -> ensure_tables();
                Err -> Err
            end;
        {error, _} = Err ->
            Err
    end.

-spec version() -> non_neg_integer().
version() -> ?SCHEMA_VERSION.

%% @doc 表定义：{表名, 创建选项}。
-spec tables() -> [{atom(), list()}].
tables() ->
    [
     {lg_meta,             disc(lg_meta, record_info(fields, lg_meta), [])},
     {lg_setting,          disc(lg_setting, record_info(fields, lg_setting), [])},
     {lg_catalog_provider, disc(lg_catalog_provider, record_info(fields, lg_catalog_provider), [])},
     {lg_catalog_model,    disc(lg_catalog_model, record_info(fields, lg_catalog_model), [provider])},
     {lg_model_overlay,    disc(lg_model_overlay, record_info(fields, lg_model_overlay), [provider])},
     {lg_credential,       disc(lg_credential, record_info(fields, lg_credential), [])},
     {lg_route,            disc(lg_route, record_info(fields, lg_route), [])},
     {lg_route_alias,      disc(lg_route_alias, record_info(fields, lg_route_alias), [route])},
     {lg_user,             disc(lg_user, record_info(fields, lg_user), [username])},
     {lg_api_key,          disc(lg_api_key, record_info(fields, lg_api_key), [hash, user_id])},
     {lg_session,          disc(lg_session, record_info(fields, lg_session), [user_id])},
     {lg_limit,            disc(lg_limit, record_info(fields, lg_limit), [])},
     {lg_budget,           disc(lg_budget, record_info(fields, lg_budget), [])},
     {lg_channel,          disc(lg_channel, record_info(fields, lg_channel), [])},
     {lg_alert_rule,       disc(lg_alert_rule, record_info(fields, lg_alert_rule), [])},
     {lg_middleware,       disc(lg_middleware, record_info(fields, lg_middleware), [])},
     {lg_unfit,            disc(lg_unfit, record_info(fields, lg_unfit), [])}
    ].

%%====================================================================
%% 内部函数
%%====================================================================

disc(Record, Fields, Index) ->
    [{attributes, Fields},
     {record_name, Record},
     {disc_copies, [node()]},
     {index, Index}].

set_mnesia_dir() ->
    case application:get_env(mnesia, dir) of
        {ok, _} ->
            ok;  %% 显式配置优先
        undefined ->
            Dir = filename:join(lg_config:data_dir(), "mnesia"),
            ok = filelib:ensure_path(Dir),
            application:set_env(mnesia, dir, Dir)
    end.

%% 首次启动时 mnesia 用的是 ram schema，就地转成 disc_copies，无需停机重建。
ensure_disc_schema() ->
    case mnesia:table_info(schema, storage_type) of
        disc_copies ->
            ok;
        ram_copies ->
            case mnesia:change_table_copy_type(schema, node(), disc_copies) of
                {atomic, ok} ->
                    logger:notice("mnesia disc schema created in ~s",
                                  [mnesia:system_info(directory)]),
                    ok;
                {aborted, Reason} ->
                    {error, {schema, Reason}}
            end
    end.

ensure_tables() ->
    Existing = mnesia:system_info(tables),
    Created = [Name || {Name, Opts} <- tables(),
                       not lists:member(Name, Existing),
                       ok =:= create_table(Name, Opts)],
    Names = [Name || {Name, _} <- tables()],
    case mnesia:wait_for_tables(Names, ?WAIT_TIMEOUT) of
        ok ->
            case migrate(Created) of
                ok -> check_attributes();
                Err -> Err
            end;
        {timeout, Bad} ->
            {error, {tables_not_loaded, Bad}};
        {error, _} = Err ->
            Err
    end.

create_table(Name, Opts) ->
    case mnesia:create_table(Name, Opts) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, Name}} -> ok;
        {aborted, Reason} -> error({create_table, Name, Reason})
    end.

%% 记录字段变了但没写迁移时直接拒绝启动，避免读出错位的数据。
check_attributes() ->
    Mismatch = [Name || {Name, Opts} <- tables(),
                        mnesia:table_info(Name, attributes)
                            =/= proplists:get_value(attributes, Opts)],
    case Mismatch of
        [] -> ok;
        _ -> {error, {attributes_mismatch, Mismatch}}
    end.

migrate(Created) ->
    Fresh = lists:member(lg_meta, Created),
    Current = case mnesia:dirty_read(lg_meta, schema_version) of
                  [#lg_meta{value = V}] -> V;
                  [] when Fresh -> ?SCHEMA_VERSION;
                  [] -> 0
              end,
    migrate_from(Current).

migrate_from(?SCHEMA_VERSION) ->
    mnesia:dirty_write(#lg_meta{key = schema_version, value = ?SCHEMA_VERSION});
migrate_from(V) when V < ?SCHEMA_VERSION ->
    ok = backup(V),
    ok = upgrade(V),
    logger:notice("mnesia schema upgraded from version ~b to ~b", [V, V + 1]),
    ok = mnesia:dirty_write(#lg_meta{key = schema_version, value = V + 1}),
    migrate_from(V + 1);
migrate_from(V) ->
    {error, {schema_version_too_new, V, ?SCHEMA_VERSION}}.

%% 升级前的完整备份：data_dir/mnesia-backup-v<V>-<时间戳>.bup（mnesia:restore/2 可恢复）
backup(V) ->
    File = filename:join(lg_config:data_dir(),
                         io_lib:format("mnesia-backup-v~b-~b.bup", [V, lg_time:now_ms()])),
    case mnesia:backup(File) of
        ok -> logger:notice("mnesia backup before upgrade: ~s", [File]);
        {error, R} -> error({backup_failed, R})
    end.

%% 版本 V -> V+1 的升级步骤，新增版本时在这里加子句。
upgrade(0) ->
    ok;
%% v2：lg_route 去掉 strategy / limits，增加 options；lg_credential 增加 options
upgrade(1) ->
    transform(lg_route,
              fun({lg_route, N, T, F, A, _Strategy, _Limits, E, C, U}) ->
                      {lg_route, N, T, F, A, #{}, E, C, U}
              end, record_info(fields, lg_route)),
    transform(lg_credential,
              fun({lg_credential, Id, N, P, Url, Key, H, Prov, E, C, U}) ->
                      {lg_credential, Id, N, P, Url, Key, H, Prov, #{}, E, C, U}
              end, record_info(fields, lg_credential));
%% v3：lg_api_key 增加默认标签 tags
upgrade(2) ->
    transform(lg_api_key,
              fun({lg_api_key, Id, H, P, N, U, AR, MT, E, Ex, C}) ->
                      {lg_api_key, Id, H, P, N, U, AR, MT, E, Ex, [], C}
              end, [id, hash, prefix, name, user_id, allowed_routes, max_tokens, enabled, expires_at, tags, created_at]);
%% v4：lg_api_key 增加扩展选项 options
upgrade(3) ->
    transform(lg_api_key,
              fun({lg_api_key, Id, H, P, N, U, AR, MT, E, Ex, T, C}) ->
                      {lg_api_key, Id, H, P, N, U, AR, MT, E, Ex, T, #{}, C}
              end, record_info(fields, lg_api_key)).

transform(Tab, Fun, Fields) ->
    case mnesia:transform_table(Tab, Fun, Fields) of
        {atomic, ok} -> ok;
        {aborted, R} -> error({transform_failed, Tab, R})
    end.

%%====================================================================
%% 节点名迁移
%%====================================================================

%% @doc 更换 -name / -sname 后迁移 mnesia 磁盘 schema。
%%
%% 离线执行：以临时节点把 mnesia 目录指到数据目录，传入旧节点名：
%% ```
%% erl -pa $RELEASE_LIB/*/ebin -mnesia dir '"/var/lib/litegate/mnesia"' -sname tmp \
%%     -eval 'ok = lg_schema:rename_node(old@host), halt().'
%% ```
%% 备份写在 mnesia 目录的 mnesia-rename.bak（成功后保留，确认服务正常可手动删除）。
-spec rename_node(node()) -> ok | {error, term()}.
rename_node(OldNode) ->
    case node() of
        OldNode ->
            {error, same_node};
        _ ->
            Backup = filename:join(mnesia_dir(), "mnesia-rename.bak"),
            try
                ok = mnesia:backup(Backup),
                %% OTP 28 的 Dialyzer contract 漏掉官方支持的 {rename, {schema, Node}} 选项；
                %% 用动态调用收敛该已知标准库误报，运行时语义保持不变。
                Restore = erlang:apply(mnesia, restore, [Backup, [{rename, {schema, OldNode}}]]),
                case Restore of
                    {ok, _} ->
                        logger:notice("mnesia schema moved from ~p to ~p (backup: ~s)",
                                      [OldNode, node(), Backup]),
                        ok;
                    {error, _} = E ->
                        E
                end
            catch
                error:Reason -> {error, Reason}
            end
    end.

mnesia_dir() ->
    case application:get_env(mnesia, dir) of
        {ok, Dir} -> Dir;
        undefined -> filename:join(lg_config:data_dir(), "mnesia")
    end.
