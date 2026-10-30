%% @doc mnesia 启动与表结构管理。
%%
%% lg_core 自己负责启动 mnesia：先把 mnesia 数据目录指到 `data_dir/mnesia`，
%% 再把 schema 转成 disc_copies、创建缺失的表并等待加载。
%% 表结构版本记录在 lg_meta 的 schema_version，升级逻辑写在 upgrade/1：
%% 先执行升级（可能改变字段），再校验字段与记录定义一致。升级前自动备份 mnesia。
%%
%% mnesia 以 permanent 启动：mnesia 自行退出（磁盘满、日志写失败）时整个节点退出，
%% 由 systemd / docker 拉起，而不是节点存活却持续 500。
%% 升级可重入：每张表转换完记进度，transform 对已是新形状的记录原样返回，中途崩溃后重启可续完。
%% 数据目录与节点名绑定：节点名不符时拒绝启动（见 check_node_name/0）。
-module(lg_schema).

-include("lg_core.hrl").

-export([init/0, tables/0, version/0, rename_node/1]).

-define(SCHEMA_VERSION, 4).
-define(WAIT_TIMEOUT, 30000).

%% @doc 启动 mnesia 并确保所有表就绪。
-spec init() -> ok | {error, term()}.
init() ->
    ok = set_mnesia_dir(),
    case check_node_name() of
        ok ->
            case application:ensure_all_started(mnesia, permanent) of
                {ok, _} ->
                    case ensure_disc_schema() of
                        ok -> ensure_tables();
                        Err -> Err
                    end;
                {error, _} = Err ->
                    Err
            end;
        Err ->
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

%% schema.DAT 记录了所属节点名。节点名变了（改 -name / -sname、开发 shell 与 release 不一致）时
%% mnesia 会以 ram schema 启动，并改写该目录的 LATEST.LOG（未转储的写入丢失），
%% 随后 ensure_disc_schema/0 还会就地新建一个空的 disc schema。必须在启动 mnesia 之前拒绝：
%% mnesia 未运行时 system_info(db_nodes) 只读地从 schema.DAT 取节点列表，不改写任何文件。
check_node_name() ->
    Dir = mnesia_dir(),
    Dat = filename:join(Dir, "schema.DAT"),
    case mnesia:system_info(is_running) =:= no andalso filelib:is_regular(Dat) of
        false ->
            ok;
        true ->
            _ = application:load(mnesia),
            Nodes = mnesia:system_info(db_nodes),
            case lists:member(node(), Nodes) of
                true ->
                    ok;
                false ->
                    logger:error(
                      "Refusing to start: mnesia directory ~s belongs to node ~p, but this node is ~p. "
                      "Start with the original node name, or migrate the schema offline with "
                      "lg_schema:rename_node/1 (see docs/deploy.md).", [Dir, Nodes, node()]),
                    {error, {node_name_mismatch, node(), Nodes}}
            end
    end.

%% 首次启动时 mnesia 用的是 ram schema，就地转成 disc_copies，无需停机重建。
%% 目录里已有 schema.DAT 却仍是 ram schema，说明磁盘 schema 没被本节点加载（节点名不符），
%% 此时转换会覆盖原库，拒绝（check_node_name/0 之外的兜底）。
ensure_disc_schema() ->
    case mnesia:table_info(schema, storage_type) of
        disc_copies ->
            ok;
        ram_copies ->
            case filelib:is_regular(filename:join(mnesia:system_info(directory), "schema.DAT")) of
                true -> {error, {schema, {disc_schema_not_loaded, node()}}};
                false -> create_disc_schema()
            end
    end.

create_disc_schema() ->
    case mnesia:change_table_copy_type(schema, node(), disc_copies) of
        {atomic, ok} ->
            logger:notice("mnesia disc schema created in ~s", [mnesia:system_info(directory)]),
            ok;
        {aborted, Reason} ->
            {error, {schema, Reason}}
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
    Steps = upgrade(V),
    ok = run_steps(V, Steps),
    logger:notice("mnesia schema upgraded from version ~b to ~b", [V, V + 1]),
    ok = mnesia:dirty_write(#lg_meta{key = schema_version, value = V + 1}),
    _ = [mnesia:dirty_delete(lg_meta, {schema_step, Tab, V}) || {Tab, _, _} <- Steps],
    migrate_from(V + 1);
migrate_from(V) ->
    {error, {schema_version_too_new, V, ?SCHEMA_VERSION}}.

%% 升级前的完整备份：data_dir/mnesia-backup-v<V>-<时间戳>.bup（mnesia:restore/2 可恢复）。
%% 同一版本已有备份（上次升级中途崩溃）时不再备份：保留的是升级前的原始状态。
backup(V) ->
    Dir = lg_config:data_dir(),
    case filelib:wildcard(filename:join(Dir, io_lib:format("mnesia-backup-v~b-*.bup", [V]))) of
        [Old | _] ->
            logger:notice("mnesia backup before upgrade already exists: ~s", [Old]);
        [] ->
            File = filename:join(Dir, io_lib:format("mnesia-backup-v~b-~b.bup", [V, lg_time:now_ms()])),
            case mnesia:backup(File) of
                ok -> logger:notice("mnesia backup before upgrade: ~s", [File]);
                {error, R} -> error({backup_failed, R})
            end
    end.

%% 版本 V -> V+1 的升级步骤 [{表, 转换函数, 新字段}]，新增版本时在这里加子句。
%% 转换函数只需匹配旧形状：step/3 让已是新形状的记录原样通过（按元组大小判断；
%% 新旧大小相同的变更须在转换函数里自行识别新形状）。
upgrade(0) ->
    [];
%% v2：lg_route 去掉 strategy / limits，增加 options；lg_credential 增加 options
upgrade(1) ->
    [step(lg_route,
          fun({lg_route, N, T, F, A, _Strategy, _Limits, E, C, U}) ->
                  {lg_route, N, T, F, A, #{}, E, C, U}
          end, record_info(fields, lg_route)),
     step(lg_credential,
          fun({lg_credential, Id, N, P, Url, Key, H, Prov, E, C, U}) ->
                  {lg_credential, Id, N, P, Url, Key, H, Prov, #{}, E, C, U}
          end, record_info(fields, lg_credential))];
%% v3：lg_api_key 增加默认标签 tags
upgrade(2) ->
    [step(lg_api_key,
          fun({lg_api_key, Id, H, P, N, U, AR, MT, E, Ex, C}) ->
                  {lg_api_key, Id, H, P, N, U, AR, MT, E, Ex, [], C}
          end, [id, hash, prefix, name, user_id, allowed_routes, max_tokens, enabled, expires_at, tags, created_at])];
%% v4：lg_api_key 增加扩展选项 options
upgrade(3) ->
    [step(lg_api_key,
          fun({lg_api_key, Id, H, P, N, U, AR, MT, E, Ex, T, C}) ->
                  {lg_api_key, Id, H, P, N, U, AR, MT, E, Ex, T, #{}, C}
          end, record_info(fields, lg_api_key))].

step(Tab, Fun, Fields) ->
    Size = length(Fields) + 1,
    {Tab, fun(R) when tuple_size(R) =:= Size -> R;
             (R) -> Fun(R)
          end, Fields}.

%% 每张表单独事务转换；完成后写进度 {schema_step, 表, V}，重启时跳过已完成的表。
%% 进度写入与转换之间崩溃时进度会丢，由 step/3 的形状判断兜底。版本号写入后清除进度。
run_steps(V, Steps) ->
    lists:foreach(
      fun({Tab, Fun, Fields}) ->
              Key = {schema_step, Tab, V},
              case mnesia:dirty_read(lg_meta, Key) of
                  [_] ->
                      logger:notice("mnesia schema v~b: ~p already upgraded, skipped", [V, Tab]);
                  [] ->
                      ok = transform(Tab, Fun, Fields),
                      ok = mnesia:dirty_write(#lg_meta{key = Key, value = lg_time:now_ms()})
              end
      end, Steps).

transform(Tab, Fun, Fields) ->
    case mnesia:transform_table(Tab, Fun, Fields) of
        {atomic, ok} -> ok;
        {aborted, R} -> error({transform_failed, Tab, R})
    end.

%%====================================================================
%% 节点名迁移
%%====================================================================

%% @doc 更换 -name / -sname 后迁移 mnesia 磁盘 schema（离线执行，本节点即新节点名）。
%%
%% 停服后以新节点名起一个临时节点，传入旧节点名：
%% ```
%% erl -noshell -pa /opt/litegate/lib/*/ebin -name litegate@127.0.0.1 \
%%     -mnesia dir '"/var/lib/litegate/mnesia"' \
%%     -eval 'ok = lg_schema:rename_node(litegate@oldhost), halt().'
%% '''
%% 步骤：以旧节点名起 peer 节点打开原目录做 mnesia 备份 → traverse_backup 把备份里的节点名
%% 换成 node() → 原目录整体改名为 `<dir>.pre-rename-<时间戳>` 留作备份（仍属旧节点名，确认无误后可手动删除）
%% → 在新的空目录装入 fallback，下次启动 mnesia 时自动恢复。旧节点名须未被占用（旧服务已停）。
-spec rename_node(node()) -> ok | {error, term()}.
rename_node(OldNode) when OldNode =:= node() ->
    {error, same_node};
rename_node(OldNode) ->
    case mnesia:system_info(is_running) of
        no -> do_rename_node(OldNode);
        _ -> {error, mnesia_running}
    end.

do_rename_node(OldNode) ->
    ok = set_mnesia_dir(),
    Dir = filename:absname(mnesia_dir()),
    Stamp = integer_to_list(lg_time:now_ms()),
    Bak = Dir ++ ".rename-" ++ Stamp ++ ".bup",
    Renamed = Dir ++ ".rename-" ++ Stamp ++ ".new.bup",
    Aside = Dir ++ ".pre-rename-" ++ Stamp,
    try
        filelib:is_regular(filename:join(Dir, "schema.DAT")) orelse error(no_disc_schema),
        ok = backup_as(OldNode, Dir, Bak),
        {ok, _} = mnesia:traverse_backup(Bak, Renamed, rename_fun(OldNode, node()), ok),
        ok = file:rename(Dir, Aside),
        ok = file:make_dir(Dir),
        _ = application:load(mnesia),
        ok = mnesia:install_fallback(Renamed, [{scope, local}, {mnesia_dir, Dir}]),
        _ = [file:delete(F) || F <- [Bak, Renamed]],
        logger:notice("mnesia schema moved from ~p to ~p; original directory kept at ~s",
                      [OldNode, node(), Aside]),
        ok
    catch
        error:Reason -> {error, Reason}
    end.

%% 旧节点名的临时节点只负责打开原目录并备份，不需要 LiteGate 代码
backup_as(OldNode, Dir, Bak) ->
    [Name, Host] = string:split(atom_to_list(OldNode), "@"),
    {ok, Peer, OldNode} = peer:start(#{name => Name, host => Host,
                                       longnames => lists:member($., Host),
                                       connection => standard_io}),
    try
        _ = peer:call(Peer, application, load, [mnesia]),
        ok = peer:call(Peer, application, set_env, [mnesia, dir, Dir]),
        ok = peer:call(Peer, mnesia, start, []),
        Tabs = peer:call(Peer, mnesia, system_info, [local_tables]),
        ok = peer:call(Peer, mnesia, wait_for_tables, [Tabs, ?WAIT_TIMEOUT]),
        ok = peer:call(Peer, mnesia, backup, [Bak]),
        stopped = peer:call(Peer, mnesia, stop, []),
        ok
    after
        peer:stop(Peer)
    end.

%% 备份条目里的节点名替换（mnesia 用户手册 Backup, Restore, Fallback 一节的做法）
rename_fun(From, To) ->
    Switch = fun(N) when N =:= From -> To; (N) -> N end,
    Copies = [ram_copies, disc_copies, disc_only_copies],
    fun({schema, db_nodes, Nodes}, Acc) ->
            {[{schema, db_nodes, lists:map(Switch, Nodes)}], Acc};
       ({schema, Tab, Opts}, Acc) when is_list(Opts) ->
            {[{schema, Tab, [case lists:member(K, Copies) of
                                 true -> {K, lists:map(Switch, V)};
                                 false -> {K, V}
                             end || {K, V} <- Opts]}], Acc};
       (Other, Acc) ->
            {[Other], Acc}
    end.

mnesia_dir() ->
    case application:get_env(mnesia, dir) of
        {ok, Dir} -> Dir;
        undefined -> filename:join(lg_config:data_dir(), "mnesia")
    end.
