%% @doc 配置自动备份：定期把配置导出（口令加密，复用 lg_config_io）快照到 <data_dir>/backups/，滚动保留 N 份。
%%
%% 口令取运行参数 backup_passphrase；推荐用环境变量 LITEGATE_BACKUP_PASSPHRASE 设置——
%% 口令不落在 mnesia 里，mnesia 损坏后仍能解开备份文件。备份默认关闭（开了但没有可用口令只会报错）。
%% 每小时检查一次是否到期；run/0 立即执行（管理 API 与控制台「设置」页调用）。
%% 最近一次结果记 lg_meta.backup。
-module(lg_backup).
-behaviour(gen_server).

-include_lib("kernel/include/file.hrl").
-include_lib("lg_core/include/lg_core.hrl").

-export([start_link/0, run/0, list/0, delete/1, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(CHECK_MS, 3600000).  %% 每小时检查一次是否到期
%% 文件名精确到毫秒（T33；此前只到秒，同秒两次备份互相覆盖），旧的秒级文件名照常列出、滚动删除
-define(NAME_RE, "^litegate-backup-\\d{8}-\\d{6}(-\\d{3})?\\.json$").

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc 立即备份一次，返回 {ok, #{file, size}} 或 {error, term()}。
-spec run() -> {ok, map()} | {error, term()}.
run() ->
    gen_server:call(?MODULE, run, 120000).

%% @doc 备份文件列表（新 → 旧）。
-spec list() -> [map()].
list() ->
    [#{file => F, size => S, mtime => M} || {F, S, M} <- files()].

%% @doc 删除指定备份文件（只接受备份目录内的合法文件名）。
-spec delete(binary()) -> ok | {error, term()}.
delete(Name) when is_binary(Name) ->
    case re:run(Name, ?NAME_RE) of
        nomatch -> {error, invalid_name};
        _ ->
            case file:delete(filename:join(dir(), Name)) of
                ok -> ok;
                {error, enoent} -> {error, not_found};
                {error, _} = E -> E
            end
    end;
delete(_) ->
    {error, invalid_name}.

-spec status() -> map() | null.
status() ->
    case lg_db:read(lg_meta, backup) of
        {ok, #lg_meta{value = V}} -> V;
        not_found -> null
    end.

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    _ = erlang:send_after(?CHECK_MS, self(), tick),
    {ok, #{}}.

handle_call(run, _From, S) ->
    Res = do_backup(),
    finish(Res),
    {reply, Res, S};
handle_call(_Msg, _From, S) ->
    {noreply, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(tick, S) ->
    case due() of
        true -> Res = do_backup(), finish(Res);
        false -> ok
    end,
    _ = erlang:send_after(?CHECK_MS, self(), tick),
    {noreply, S};
handle_info(_Msg, S) ->
    {noreply, S}.

%%====================================================================
%% 内部函数
%%====================================================================

dir() ->
    filename:join(lg_config:get(data_dir), <<"backups">>).

%% 到期判断：开启、间隔 > 0、距上次成功 / 尝试超过间隔
due() ->
    lg_config:get(backup_enabled) andalso lg_config:get(backup_interval_h) > 0
        andalso (case status() of
                     #{at := At} -> lg_time:now_ms() - At >= lg_config:get(backup_interval_h) * 3600000;
                     null -> true
                 end).

do_backup() ->
    case lg_config:get(backup_passphrase) of
        Pass when is_binary(Pass), byte_size(Pass) >= 8 ->
            case lg_config_io:export(Pass) of
                {ok, Data} -> write_snapshot(iolist_to_binary(json:encode(Data)));
                {error, _} = E -> E
            end;
        _ ->
            {error, {invalid, <<"backup_passphrase">>}}
    end.

%% 目录建不了 / 写不了 / 改名失败都返回错误（由 finish/1 记日志与状态），不让 gen_server 崩溃
write_snapshot(Json) ->
    Name = name(),
    Tmp = filename:join(dir(), <<Name/binary, ".tmp">>),
    Path = filename:join(dir(), Name),
    case filelib:ensure_dir(Tmp) of
        ok ->
            case file:write_file(Tmp, Json) of
                ok ->
                    case file:rename(Tmp, Path) of
                        ok ->
                            prune(),
                            {ok, #{file => Name, size => byte_size(Json)}};
                        {error, Why} ->
                            _ = file:delete(Tmp),
                            {error, {rename, Why}}
                    end;
                {error, Why} ->
                    _ = file:delete(Tmp),
                    {error, {write, Why}}
            end;
        {error, Why} ->
            {error, {backup_dir, Why}}
    end.

%% 同一毫秒内已有同名文件时等到下一毫秒（备份经本进程串行，不会与自己并发）
name() ->
    Name = iolist_to_binary(io_lib:format("litegate-backup-~s.json", [ts()])),
    case filelib:is_file(filename:join(dir(), Name)) of
        true -> timer:sleep(1), name();
        false -> Name
    end.

finish({ok, #{file := F, size := N}}) ->
    ok = lg_db:write(#lg_meta{key = backup,
                              value = #{at => lg_time:now_ms(), ok => true, file => F, size => N}}),
    logger:notice("config backup written: ~ts (~p bytes)", [F, N]);
finish({error, Why}) ->
    ok = lg_db:write(#lg_meta{key = backup,
                              value = #{at => lg_time:now_ms(), ok => false, error => reason(Why)}}),
    logger:error("config backup failed: ~p", [Why]).

%% 文件名含时间戳，字典序即新→旧；超出 backup_keep 的最旧文件删除
prune() ->
    Files = files(),
    Keep = max(1, lg_config:get(backup_keep)),
    {_, Old} = lists:split(min(Keep, length(Files)), Files),
    _ = [file:delete(filename:join(dir(), F)) || {F, _, _} <- Old],
    ok.

files() ->
    Dir = dir(),
    case file:list_dir(Dir) of
        {ok, Names} ->
            %% file:list_dir 返回 char list；先转 binary 再按名字过滤（过滤器须为布尔表达式）
            Bin = [iolist_to_binary(N0) || N0 <- Names, is_list(N0)],
            %% 列目录与读文件信息之间被删掉的文件跳过
            Info = [{N, S, (calendar:datetime_to_gregorian_seconds(M) - 62167219200) * 1000}
                    || N <- Bin, re:run(N, ?NAME_RE) =/= nomatch,
                       {ok, #file_info{size = S, mtime = M}} <- [file:read_file_info(filename:join(Dir, N))]],
            lists:sort(fun({A, _, _}, {B, _, _}) -> A > B end, Info);
        {error, _} ->
            []
    end.

ts() ->
    Ms = os:system_time(millisecond),
    {{Y, Mo, D}, {H, Mi, S}} = calendar:system_time_to_local_time(Ms div 1000, second),
    io_lib:format("~4..0B~2..0B~2..0B-~2..0B~2..0B~2..0B-~3..0B", [Y, Mo, D, H, Mi, S, Ms rem 1000]).

reason({invalid, K}) -> <<"Invalid setting: ", K/binary>>;
reason(Why) -> iolist_to_binary(io_lib:format("~0p", [Why])).
