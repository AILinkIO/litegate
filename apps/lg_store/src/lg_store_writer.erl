%% @doc 交互数据唯一写入进程：持有四个 bitcask 的写句柄。
%%
%% - 日志：record 异步投递，攒批（≤50ms 或 200 条）后每个 cask 一次 put_batch_atomic，
%%   日志与其二级索引分属两个 cask，各自原子；索引先写，读侧遇到悬空索引会跳过
%% - 用量：内存累加，每 5s（或 flush/0 时）读-改-写合并到小时汇总；单写者无需 CAS
%% - 会话汇总：内存累加，随日志一起读-改-写合并，同时更新最近活动键
-module(lg_store_writer).
-behaviour(gen_server).

-export([start_link/0, record/3, session/2, flush/0, delete/2, put/3, merge_session/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(BATCH_MS, 50).
-define(BATCH_MAX, 200).
-define(USAGE_FLUSH_MS, 5000).
-define(CASKS, [logs, idx, msgs, usage, search, cache, responses, alerts, sessions]).
-define(SESSION_LIST_MAX, 10).
%% 持锁实例的身份文件：主机名，mtime 随用量落盘定时刷新作心跳
-define(OWNER_FILE, "owner").
-define(OWNER_STALE_S, 30).

-include_lib("kernel/include/file.hrl").

-record(st, {
    handles :: #{atom() => term()},
    pending = [] :: [{binary(), [binary()], binary(), binary() | undefined, map() | undefined}],
    pending_n = 0 :: non_neg_integer(),
    batch_timer :: reference() | undefined,
    usage = #{} :: #{{non_neg_integer(), tuple()} => map()},
    sessions = #{} :: #{binary() => map()}
}).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc 投递一条日志：{LogKey, 索引键列表, 日志值, 消息值（可无）, 检索文档（可无）}以及用量增量
%% （同一增量累加到每个用量键：维度行与各标签行）。
-spec record({binary(), [binary()], binary(), binary() | undefined, map() | undefined},
             [{non_neg_integer(), tuple()}], map()) -> ok.
record(Entry, UsageKeys, UsageDelta) ->
    gen_server:cast(?MODULE, {record, Entry, UsageKeys, UsageDelta}).

%% @doc 累加一次请求到会话汇总（随下一批日志落盘）。
-spec session(binary(), map()) -> ok.
session(Sid, Delta) ->
    gen_server:cast(?MODULE, {session, Sid, Delta}).

%% @doc 批量删除（数据保留清理用）；删除前先落盘缓冲，避免稍后又写回。
-spec delete(atom(), [binary()]) -> ok.
delete(_Cask, []) ->
    ok;
delete(Cask, Keys) ->
    gen_server:call(?MODULE, {delete, Cask, Keys}, 60000).

%% @doc 异步写入单条记录（响应缓存、Responses 会话等非日志数据）。
-spec put(atom(), binary(), binary()) -> ok.
put(Cask, Key, Value) ->
    gen_server:cast(?MODULE, {put, Cask, Key, Value}).

%% @doc 把缓冲的日志与用量全部落盘（查询前调用，保证读到最新数据）。
-spec flush() -> ok.
flush() ->
    gen_server:call(?MODULE, flush, 30000).

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    process_flag(trap_exit, true),
    Root = filename:join(lg_config:data_dir(), "store"),
    ok = clear_stale_locks(Root),
    case open_all(Root) of
        {ok, Handles} ->
            _ = [persistent_term:put({lg_store, C}, H) || C := H <- Handles],
            persistent_term:put({lg_store, root}, Root),
            persistent_term:put({lg_store, opened}, true),
            touch_owner(Root),
            erlang:send_after(?USAGE_FLUSH_MS, self(), flush_usage),
            {ok, #st{handles = Handles}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(flush, _From, S) ->
    {reply, ok, flush_usage(flush_logs(S))};
handle_call({delete, Cask, Keys}, _From, #st{handles = H} = S) ->
    S1 = flush_usage(flush_logs(S)),
    ok = batch(maps:get(Cask, H), [{remove, K} || K <- Keys]),
    {reply, ok, S1}.

handle_cast({put, Cask, Key, Value}, #st{handles = Handles} = S) ->
    case bitcask:put(maps:get(Cask, Handles), Key, Value) of
        ok -> ok;
        Err -> logger:warning("lg_store put ~p failed: ~p", [Cask, Err])
    end,
    {noreply, S};
handle_cast({session, Sid, Delta}, #st{sessions = Ss} = S) ->
    S1 = S#st{sessions = maps:update_with(Sid, fun(Old) -> merge_session(Old, Delta) end, Delta, Ss)},
    {noreply, ensure_timer(S1)};
handle_cast({record, Entry, UKeys, Delta}, #st{pending = P, pending_n = N, usage = U0} = S) ->
    U = lists:foldl(fun(UKey, Acc) -> maps:update_with(UKey, fun(Old) -> add(Old, Delta) end, Delta, Acc) end,
                    U0, UKeys),
    S1 = S#st{pending = [Entry | P], pending_n = N + 1, usage = U},
    case S1#st.pending_n >= ?BATCH_MAX of
        true -> {noreply, flush_logs(S1)};
        false -> {noreply, ensure_timer(S1)}
    end.

handle_info(flush_logs, S) ->
    {noreply, flush_logs(S#st{batch_timer = undefined})};
handle_info(flush_usage, S) ->
    erlang:send_after(?USAGE_FLUSH_MS, self(), flush_usage),
    touch_owner(persistent_term:get({lg_store, root})),
    {noreply, flush_usage(S)};
handle_info(_Msg, S) ->
    {noreply, S}.

terminate(_Reason, #st{handles = Handles} = S) ->
    _ = flush_usage(flush_logs(S)),
    _ = [begin
         persistent_term:erase({lg_store, C}),
         bitcask:close(H)
     end || C := H <- Handles],
    ok.

%%====================================================================
%% 内部函数
%%====================================================================

open_all(Root) ->
    lists:foldl(
      fun(_, {error, _} = Err) -> Err;
         (C, {ok, Acc}) ->
              Dir = filename:join(Root, atom_to_list(C)),
              ok = filelib:ensure_path(Dir),
              case bitcask:open(Dir, [read_write | cask_opts(C)]) of
                  {error, R} -> {error, {open_cask, C, R}};
                  H -> {ok, Acc#{C => H}}
              end
      end, {ok, #{}}, ?CASKS).

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

%% search 为 BM25 索引模式（jieba 分词，适合中英文混合）
cask_opts(search) -> [{analyzer, jieba}];
cask_opts(_) -> [].

ensure_timer(#st{batch_timer = undefined} = S) ->
    S#st{batch_timer = erlang:send_after(?BATCH_MS, self(), flush_logs)};
ensure_timer(S) ->
    S.

flush_logs(#st{pending = [], sessions = Ss} = S) when map_size(Ss) =:= 0 ->
    S;
flush_logs(#st{pending = []} = S) ->
    flush_sessions(S);
flush_logs(#st{pending = P, handles = H, batch_timer = T} = S) ->
    T =:= undefined orelse erlang:cancel_timer(T),
    Entries = lists:reverse(P),
    Idx = [{put, K, <<>>} || {_, IdxKeys, _, _, _} <- Entries, K <- IdxKeys],
    Logs = [{put, K, V} || {K, _, V, _, _} <- Entries],
    Msgs = [{put, K, M} || {K, _, _, M, _} <- Entries, M =/= undefined],
    ok = batch(maps:get(idx, H), Idx),
    ok = batch(maps:get(logs, H), Logs),
    ok = batch(maps:get(msgs, H), Msgs),
    %% 检索文档不支持原子批量写（值必须是二进制），逐条写入；尽力而为，不影响日志
    Search = maps:get(search, H),
    _ = [case bitcask:put(Search, K, Doc) of
             ok -> ok;
             Err -> logger:warning("lg_store search index put failed: ~p", [Err])
         end || {K, _, _, _, Doc} <- Entries, Doc =/= undefined],
    flush_sessions(S#st{pending = [], pending_n = 0, batch_timer = undefined}).

%% 会话汇总读-改-写；最近活动变化时删旧的最近活动键、写新的
flush_sessions(#st{sessions = Ss} = S) when map_size(Ss) =:= 0 ->
    S;
flush_sessions(#st{sessions = Ss, handles = #{sessions := H}} = S) ->
    Ops = lists:append(
            [begin
                 Key = lg_store_keys:session_key(Sid),
                 {Merged, OldLast} = case bitcask:get(H, Key) of
                                         {ok, Old} ->
                                             O = binary_to_term(Old),
                                             {merge_session(O, Delta), maps:get(last_ts, O)};
                                         not_found ->
                                             {Delta, undefined}
                                     end,
                 Last = maps:get(last_ts, Merged),
                 [{put, Key, term_to_binary(Merged#{id => Sid})}]
                     ++ case OldLast of
                            Last -> [];
                            undefined -> [{put, lg_store_keys:recent_key(Last, Sid), <<>>}];
                            _ -> [{remove, lg_store_keys:recent_key(OldLast, Sid)},
                                  {put, lg_store_keys:recent_key(Last, Sid), <<>>}]
                        end
             end || Sid := Delta <- Ss]),
    ok = batch(H, Ops),
    S#st{sessions = #{}}.

%% @doc 合并两份会话汇总：时间取最早 / 最晚，数值相加，列表取并集（最多 10 项），其余取后者。
-spec merge_session(map(), map()) -> map().
merge_session(A, B) ->
    maps:merge_with(fun(first_ts, X, Y) -> min(X, Y);
                       (last_ts, X, Y) -> max(X, Y);
                       (_, X, Y) when is_number(X), is_number(Y) -> X + Y;
                       (_, X, Y) when is_list(X), is_list(Y) ->
                            lists:sublist(X ++ [V || V <- Y, not lists:member(V, X)], ?SESSION_LIST_MAX);
                       (_, _X, Y) -> Y
                    end, A, B).

batch(_H, []) -> ok;
batch(H, Ops) ->
    case bitcask:put_batch_atomic(H, Ops) of
        ok -> ok;
        {error, R} -> logger:error("lg_store batch write failed: ~p", [R]), ok
    end.

flush_usage(#st{usage = U} = S) when map_size(U) =:= 0 ->
    S;
flush_usage(#st{usage = U, handles = #{usage := H}} = S) ->
    Ops = [begin
               Key = lg_store_keys:usage_key(Hour, Dims),
               Merged = case bitcask:get(H, Key) of
                            {ok, Old} -> add(binary_to_term(Old), Delta);
                            not_found -> Delta
                        end,
               {put, Key, term_to_binary(Merged)}
           end || {Hour, Dims} := Delta <- U],
    ok = batch(H, Ops),
    ok = bitcask:sync(H),
    S#st{usage = #{}}.

add(A, B) ->
    maps:merge_with(fun(_, X, Y) -> X + Y end, A, B).
