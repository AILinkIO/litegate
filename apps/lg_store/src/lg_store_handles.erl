%% @doc cask 句柄持有者：打开全部 bitcask 并放进 persistent_term，供写者与任意读者使用。
%%
%% 句柄生命周期与写者解耦：lg_store_sup 为 rest_for_one，本进程是第一个子进程，写者 / 检索索引
%% 进程崩溃重启不会关闭句柄，读者不受影响。只有本进程退出（应用停止）时才 close——libbitcask 的
%% close 要求无在途操作，而此时 lg_web / lg_router 已先停，没有读者。
%%
%% 同时持有写入健康状态（atomics，跨写者重启保留）：写者积压计数、最近写盘错误时间、连续失败次数，
%% 以及持锁实例的 owner 心跳。
-module(lg_store_handles).
-behaviour(gen_server).

-export([start_link/0, casks/0, handles/0, handle/1, stats/0, write_error/2, write_ok/0, health/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(CASKS, [logs, idx, msgs, usage, search, cache, responses, alerts, sessions]).
%% 持锁实例的身份文件：主机名，mtime 每 HEARTBEAT_MS 刷新作心跳
-define(OWNER_FILE, "owner").
-define(OWNER_STALE_S, 30).
-define(HEARTBEAT_MS, 5000).
%% 写盘错误后 /health 保持 degraded 的时长
-define(ERROR_WINDOW_MS, 300000).
%% atomics 下标
-define(BACKLOG, 1).
-define(LAST_ERROR, 2).
-define(CONSECUTIVE, 3).

-include_lib("kernel/include/file.hrl").

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec casks() -> [atom()].
casks() ->
    ?CASKS.

-spec handles() -> #{atom() => term()}.
handles() ->
    maps:from_list([{C, handle(C)} || C <- ?CASKS]).

%% @doc 读取 cask 句柄；未打开（应用未启动 / 正在重启）时抛 error:badarg。
-spec handle(atom()) -> term().
handle(Cask) ->
    persistent_term:get({lg_store, Cask}).

%% @doc 写入状态计数器（atomics）：1 = 写者积压，2 = 最近写盘错误时间（毫秒），3 = 连续失败次数。
-spec stats() -> atomics:atomics_ref().
stats() ->
    persistent_term:get({lg_store, stats}).

%% @doc 记录一次写盘错误：计数指标、更新健康状态、记日志。
-spec write_error(atom(), term()) -> ok.
write_error(Cask, Reason) ->
    lg_metrics:inc(litegate_store_write_errors_total, [{cask, Cask}]),
    Ref = stats(),
    atomics:put(Ref, ?LAST_ERROR, lg_time:now_ms()),
    atomics:add(Ref, ?CONSECUTIVE, 1),
    logger:error("lg_store ~p write failed: ~p", [Cask, Reason]),
    ok.

%% @doc 一次写盘成功：清零连续失败次数。
-spec write_ok() -> ok.
write_ok() ->
    Ref = stats(),
    atomics:get(Ref, ?CONSECUTIVE) =:= 0 orelse atomics:put(Ref, ?CONSECUTIVE, 0),
    ok.

%% @doc 写入健康：仍在连续失败，或最近 ERROR_WINDOW_MS 内有过写盘错误时为 degraded。
-spec health() -> ok | {degraded, #{last_write_error_ms := non_neg_integer(),
                                    consecutive_errors := non_neg_integer(),
                                    backlog := integer()}}.
health() ->
    try stats() of
        Ref ->
            Last = atomics:get(Ref, ?LAST_ERROR),
            N = atomics:get(Ref, ?CONSECUTIVE),
            case N > 0 orelse (Last > 0 andalso lg_time:now_ms() - Last < ?ERROR_WINDOW_MS) of
                true -> {degraded, #{last_write_error_ms => Last, consecutive_errors => N,
                                     backlog => atomics:get(Ref, ?BACKLOG)}};
                false -> ok
            end
    catch
        error:badarg -> ok  %% 存储未启动
    end.

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    process_flag(trap_exit, true),
    %% atomics 只建一次（不随应用重启重建 persistent_term），启动时清零
    Ref = case persistent_term:get({lg_store, stats}, undefined) of
              undefined ->
                  R = atomics:new(3, [{signed, true}]),
                  persistent_term:put({lg_store, stats}, R),
                  R;
              R -> R
          end,
    _ = [atomics:put(Ref, I, 0) || I <- [?BACKLOG, ?LAST_ERROR, ?CONSECUTIVE]],
    Root = filename:join(lg_config:data_dir(), "store"),
    ok = clear_stale_locks(Root),
    case open_all(Root) of
        {ok, Handles} ->
            _ = [persistent_term:put({lg_store, C}, H) || C := H <- Handles],
            persistent_term:put({lg_store, root}, Root),
            persistent_term:put({lg_store, opened}, true),
            touch_owner(Root),
            erlang:send_after(?HEARTBEAT_MS, self(), heartbeat),
            {ok, #{root => Root, handles => Handles}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(heartbeat, #{root := Root} = S) ->
    touch_owner(Root),
    erlang:send_after(?HEARTBEAT_MS, self(), heartbeat),
    {noreply, S};
handle_info(_Msg, S) ->
    {noreply, S}.

terminate(_Reason, #{handles := Handles}) ->
    _ = [begin
             persistent_term:erase({lg_store, C}),
             catch bitcask:close(H)
         end || C := H <- Handles],
    ok.

%%====================================================================
%% 内部函数
%%====================================================================

%% 中途失败时关闭已打开的 cask，避免写锁留到下次启动
open_all(Root) ->
    lists:foldl(
      fun(_, {error, _} = Err) -> Err;
         (C, {ok, Acc}) ->
              Dir = filename:join(Root, atom_to_list(C)),
              ok = filelib:ensure_path(Dir),
              case bitcask:open(Dir, [read_write | cask_opts(C)]) of
                  {error, R} ->
                      _ = [catch bitcask:close(H) || _ := H <- Acc],
                      {error, {open_cask, C, R}};
                  H -> {ok, Acc#{C => H}}
              end
      end, {ok, #{}}, ?CASKS).

%% search 为 BM25 索引模式（jieba 分词，适合中英文混合）
cask_opts(search) -> [{analyzer, jieba}];
cask_opts(_) -> [].

%% 回收上一实例被 SIGKILL 留下的写锁。libbitcask 以 kill(pid, 0) 判断锁是否失效，但容器里
%% beam 恒为 PID 1，锁里记的 pid 永远「存活」，锁永不回收，启动即 write_locked。
%%
%% 锁 pid 等于本进程 pid 时，原持锁进程必已不在（同一 pid 命名空间里 pid 唯一）——除非是
%% 挂同一数据目录的另一个容器（它也是 PID 1）。用 owner 文件区分：主机名相同（同一容器重启）
%% 或心跳已停 ?OWNER_STALE_S 秒以上才删锁。本 VM 打开过之后不再回收：那时的锁可能是本 VM 自己的。
clear_stale_locks(Root) ->
    Self = list_to_binary(os:getpid()),
    Locks = [L || C <- ?CASKS,
                  L <- [filename:join([Root, atom_to_list(C), "bitcask.write.lock"])],
                  lock_pid(L) =:= Self],
    case Locks =/= [] andalso not persistent_term:get({lg_store, opened}, false)
        andalso owner_gone(Root) of
        true ->
            logger:warning("lg_store: removing stale write locks left by a killed instance: ~p", [Locks]),
            lists:foreach(fun file:delete/1, Locks);
        false ->
            ok
    end.

%% 锁文件格式 "<pid> <activefile>\n<token>\n"，只看首个字段
lock_pid(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> hd(binary:split(Bin, [<<" ">>, <<"\n">>]));
        {error, _} -> undefined
    end.

owner_gone(Root) ->
    Path = filename:join(Root, ?OWNER_FILE),
    case {file:read_file(Path), file:read_file_info(Path, [{time, posix}])} of
        {{ok, Host}, {ok, #file_info{mtime = MTime}}} ->
            Host =:= hostname() orelse erlang:system_time(second) - MTime > ?OWNER_STALE_S;
        _ ->
            true
    end.

touch_owner(Root) ->
    _ = file:write_file(filename:join(Root, ?OWNER_FILE), hostname()),
    ok.

hostname() ->
    {ok, H} = inet:gethostname(),
    list_to_binary(H).
