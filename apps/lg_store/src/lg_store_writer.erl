%% @doc 交互数据唯一写入进程（检索索引除外，见 lg_store_indexer）；句柄由 lg_store_handles 持有。
%%
%% - 日志：record 异步投递，攒批（≤50ms 或 200 条）后每个 cask 一次 put_batch_atomic，
%%   日志与其二级索引分属两个 cask，各自原子；索引先写，读侧遇到悬空索引会跳过
%% - 用量：内存累加，每 5s（或 flush/0 时）读-改-写合并到小时汇总；单写者无需 CAS。同一原子批里
%%   维护每小时总量行与费用分解行（派生行，见 lg_store_keys；旧数据由 lg_store_migrate 回填）
%% - 会话汇总：内存累加，随日志一起读-改-写合并，同时更新最近活动键
%% - 背压：投递时按积压计数（atomics，投递 +1、处理 -1）分级降级：超过 store_queue_soft 丢弃对话、
%%   检索文档与响应缓存，超过 store_queue_hard 只保留用量增量；计数 litegate_store_degraded_total{level}
%% - 写盘错误：计数 litegate_store_write_errors_total{cask} 并进入 /health。用量 / 会话只在原子批写入
%%   成功后才从 State 清空，失败时保留重试；写入后不再有可能崩溃的步骤，terminate 不会重放已落盘部分
-module(lg_store_writer).
-behaviour(gen_server).

-export([start_link/0, record/3, session/2, flush/0, flush/1, delete/2, put/3, put/4, migrate/4,
         merge_session/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(BATCH_MS, 50).
-define(BATCH_MAX, 200).
-define(USAGE_FLUSH_MS, 5000).
-define(SESSION_LIST_MAX, 10).
%% 回填标记中 alive（最近存活时间）的刷新间隔
-define(ALIVE_MS, 60000).
%% lg_store_handles:stats/0 中的积压计数下标
-define(BACKLOG, 1).

-record(st, {
    handles :: #{atom() => term()},
    stats :: atomics:atomics_ref(),
    pending = [] :: [{binary(), [binary()], binary(), binary() | undefined, map() | undefined}],
    pending_n = 0 :: non_neg_integer(),
    batch_timer :: reference() | undefined,
    usage = #{} :: #{{non_neg_integer(), tuple()} => map()},
    sessions = #{} :: #{binary() => map()},
    alive_at = 0 :: non_neg_integer()
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
%% 积压超过 store_queue_soft 时去掉对话与检索文档，超过 store_queue_hard 只投递用量增量。
record({Key, IdxKeys, Log, _Msgs, _Doc} = Entry, UsageKeys, UsageDelta) ->
    case level() of
        normal ->
            send({record, Entry, UsageKeys, UsageDelta});
        soft ->
            degraded(soft),
            send({record, {Key, IdxKeys, Log, undefined, undefined}, UsageKeys, UsageDelta});
        hard ->
            degraded(hard),
            send({usage, UsageKeys, UsageDelta})
    end.

%% @doc 累加一次请求到会话汇总（随下一批日志落盘）。
-spec session(binary(), map()) -> ok.
session(Sid, Delta) ->
    send({session, Sid, Delta}).

%% @doc 批量删除（数据保留清理用，调用方每批 ≤ 1000 键）；删除前先落盘日志批次（删 usage 时另落盘用量），
%% 避免稍后又写回。
-spec delete(atom(), [binary()]) -> ok | {error, write_failed}.
delete(_Cask, []) ->
    ok;
delete(Cask, Keys) ->
    gen_server:call(?MODULE, {delete, Cask, Keys}, 60000).

%% @doc 异步写入单条记录（响应缓存、Responses 会话等非日志数据）；积压超过 soft 时丢弃响应缓存。
-spec put(atom(), binary(), binary()) -> ok.
put(cache, Key, Value) ->
    case level() of
        normal -> send({put, cache, Key, Value});
        _ -> degraded(soft)
    end;
put(Cask, Key, Value) ->
    send({put, Cask, Key, Value}).

%% @doc 同 put/3，另带同批原子写入的附加操作（过期索引）。
-spec put(atom(), binary(), binary(), [{put, binary(), binary()}]) -> ok.
put(cache, Key, Value, Extra) ->
    case level() of
        normal -> send({put_batch, cache, [{put, Key, Value} | Extra]});
        _ -> degraded(soft)
    end;
put(Cask, Key, Value, Extra) ->
    send({put_batch, Cask, [{put, Key, Value} | Extra]}).

%% @doc 回填（lg_store_migrate 调用）：标记 gen 与 Gen 一致时写入 Ops（{usage_hour, Hour} 表示由写者按该小时
%% 维度行重算派生行），再把 Update 合并进标记；gen 已变（写者重启过）返回 stale。
-spec migrate(non_neg_integer(), atom(), [tuple()] | {usage_hour, non_neg_integer()}, map()) ->
          ok | stale | {error, write_failed}.
migrate(Gen, Cask, Ops, Update) ->
    gen_server:call(?MODULE, {migrate, Gen, Cask, Ops, Update}, 60000).

%% @doc 把缓冲的日志与用量全部落盘（查询前调用，保证读到最新数据）。
-spec flush() -> ok.
flush() ->
    flush(all).

%% @doc 按范围落盘：logs 只写日志与会话批次，all 另做用量合并。
-spec flush(logs | all) -> ok.
%% 写者积压超时或正在重启时直接返回（读到的数据可能稍旧），不让查询方崩溃。
flush(Scope) ->
    try gen_server:call(?MODULE, {flush, Scope}, 30000)
    catch exit:_ -> ok
    end.

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    process_flag(trap_exit, true),
    %% 邮箱放堆外：积压时 GC 不扫描整个队列
    process_flag(message_queue_data, off_heap),
    Stats = lg_store_handles:stats(),
    %% 上一个写者邮箱里的消息已随其退出丢失
    atomics:put(Stats, ?BACKLOG, 0),
    erlang:send_after(?USAGE_FLUSH_MS, self(), flush_usage),
    Handles = lg_store_handles:handles(),
    Now = lg_time:now_ms(),
    ok = lg_store_migrate:init(Handles, Now),
    {ok, #st{handles = Handles, stats = Stats, alive_at = Now}}.

handle_call({flush, logs}, _From, S) ->
    {reply, ok, flush_logs(S)};
handle_call({flush, all}, _From, S) ->
    {reply, ok, flush_usage(flush_logs(S))};
handle_call({delete, Cask, Keys}, _From, #st{handles = H} = S) ->
    S1 = case Cask of
             usage -> flush_usage(flush_logs(S));
             _ -> flush_logs(S)
         end,
    Reply = case write(Cask, maps:get(Cask, H), fun() -> [{remove, K} || K <- Keys] end) of
                ok -> ok;
                error -> {error, write_failed}
            end,
    {reply, Reply, S1};
%% 重算某小时的派生行不需要先落盘内存里的增量：增量稍后落盘时同时加到维度行与派生行，两者之和仍一致
handle_call({migrate, Gen, Cask, Ops, Update}, _From, #st{handles = H} = S) ->
    U = maps:get(usage, H),
    OpsFun = case Ops of
                 {usage_hour, Hour} -> fun() -> rebuild_ops(U, Hour) end;
                 _ -> fun() -> Ops end
             end,
    Reply = case lg_store_migrate:gen(U) of
                Gen ->
                    case write(Cask, maps:get(Cask, H), OpsFun) =:= ok andalso
                        write(usage, U, fun() -> lg_store_migrate:marker_ops(U, Update) end) of
                        ok -> ok;
                        _ -> {error, write_failed}
                    end;
                _ ->
                    stale
            end,
    {reply, Reply, S}.

handle_cast(Msg, #st{stats = Stats} = S) ->
    atomics:sub(Stats, ?BACKLOG, 1),
    cast(Msg, S).

cast({put, Cask, Key, Value}, #st{handles = Handles} = S) ->
    case catch bitcask:put(maps:get(Cask, Handles), Key, Value) of
        ok -> ok;
        Err -> lg_store_handles:write_error(Cask, Err)
    end,
    {noreply, S};
cast({put_batch, Cask, Ops}, #st{handles = Handles} = S) ->
    _ = put_batch(Cask, maps:get(Cask, Handles), Ops),
    {noreply, S};
cast({session, Sid, Delta}, #st{sessions = Ss} = S) ->
    S1 = S#st{sessions = maps:update_with(Sid, fun(Old) -> merge_session(Old, Delta) end, Delta, Ss)},
    {noreply, ensure_timer(S1)};
cast({usage, UKeys, Delta}, S) ->
    {noreply, add_usage(UKeys, Delta, S)};
cast({record, Entry, UKeys, Delta}, #st{pending = P, pending_n = N} = S) ->
    S1 = (add_usage(UKeys, Delta, S))#st{pending = [Entry | P], pending_n = N + 1},
    case S1#st.pending_n >= ?BATCH_MAX of
        true -> {noreply, flush_logs(S1)};
        false -> {noreply, ensure_timer(S1)}
    end.

handle_info(flush_logs, S) ->
    {noreply, flush_logs(S#st{batch_timer = undefined})};
handle_info(flush_usage, #st{stats = Stats} = S) ->
    erlang:send_after(?USAGE_FLUSH_MS, self(), flush_usage),
    %% 积压计数按实际邮箱长度校准（投递到已退出写者的消息等会造成漂移）
    {message_queue_len, Len} = process_info(self(), message_queue_len),
    atomics:put(Stats, ?BACKLOG, Len),
    %% 顺带重试上次写失败而保留的会话汇总
    {noreply, alive(flush_usage(flush_logs(S)))};
handle_info(_Msg, S) ->
    {noreply, S}.

%% 只写尚未落盘的部分（State 中的用量 / 会话只在落盘成功后清空）；句柄由 lg_store_handles 关闭
terminate(_Reason, S) ->
    try flush_usage(flush_logs(S)) of
        _ -> ok
    catch
        C:R -> logger:error("lg_store writer final flush failed: ~p:~p", [C, R])
    end.

%%====================================================================
%% 内部函数
%%====================================================================

%% 按积压计数分级；存储未启动时视为无积压
level() ->
    N = try atomics:get(lg_store_handles:stats(), ?BACKLOG) catch error:badarg -> 0 end,
    case N >= lg_config:get(store_queue_soft) of
        false -> normal;
        true ->
            case N >= lg_config:get(store_queue_hard) of
                true -> hard;
                false -> soft
            end
    end.

degraded(Level) ->
    lg_metrics:inc(litegate_store_degraded_total, [{level, Level}]),
    ok.

%% 写者不在（正在重启）时与 gen_server:cast 一样静默丢弃
send(Msg) ->
    case whereis(?MODULE) of
        undefined ->
            ok;
        Pid ->
            atomics:add(lg_store_handles:stats(), ?BACKLOG, 1),
            gen_server:cast(Pid, Msg)
    end.

add_usage(UKeys, Delta, #st{usage = U0} = S) ->
    S#st{usage = lists:foldl(fun(UKey, Acc) -> maps:update_with(UKey, fun(Old) -> add(Old, Delta) end, Delta, Acc) end,
                             U0, UKeys)}.

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
    %% 日志明细写失败只计数不重试（磁盘满时重试只会让积压更大）
    _ = write(idx, maps:get(idx, H), fun() -> [{put, K, <<>>} || {_, IdxKeys, _, _, _} <- Entries, K <- IdxKeys] end),
    Logged = write(logs, maps:get(logs, H), fun() -> [{put, K, V} || {K, _, V, _, _} <- Entries] end),
    _ = write(msgs, maps:get(msgs, H), fun() -> [{put, K, M} || {K, _, _, M, _} <- Entries, M =/= undefined] end),
    %% 检索文档交给 lg_store_indexer（尽力而为，不影响日志）；日志没写成就不索引
    Logged =:= ok andalso
        lg_store_indexer:index([{K, Doc} || {K, _, _, _, Doc} <- Entries, Doc =/= undefined]),
    flush_sessions(S#st{pending = [], pending_n = 0, batch_timer = undefined}).

%% 会话汇总读-改-写；最近活动变化时删旧的最近活动键、写新的
flush_sessions(#st{sessions = Ss} = S) when map_size(Ss) =:= 0 ->
    S;
flush_sessions(#st{sessions = Ss, handles = #{sessions := H}} = S) ->
    Ops = fun() -> lists:append(
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
             end || Sid := Delta <- Ss]) end,
    case write(sessions, H, Ops) of
        ok -> S#st{sessions = #{}};
        error -> S  %% 原子批未写入任何内容，保留增量稍后重试
    end.

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

%% 构造写操作（可能先读旧值）并原子写入。任何异常都按写失败处理（计数 + /health），
%% 保证调用方在写入前后都不会崩溃：State 里的用量 / 会话不会在 terminate 中被重放
write(Cask, H, OpsFun) ->
    try OpsFun() of
        [] -> ok;
        Ops -> put_batch(Cask, H, Ops)
    catch
        C:R -> failed(Cask, {C, R})
    end.

put_batch(Cask, H, Ops) ->
    try bitcask:put_batch_atomic(H, Ops) of
        ok -> lg_store_handles:write_ok();
        {error, R} -> failed(Cask, R)
    catch
        C:R -> failed(Cask, {C, R})
    end.

failed(Cask, Reason) ->
    lg_store_handles:write_error(Cask, Reason),
    error.

flush_usage(#st{usage = U} = S) when map_size(U) =:= 0 ->
    S;
flush_usage(#st{usage = U, handles = #{usage := H}} = S) ->
    Ops = fun() ->
                  {Totals, Costs} = maps:fold(fun derive/3, {#{}, #{}}, U),
                  [merge_row(H, lg_store_keys:usage_key(Hour, Dims), Delta) || {Hour, Dims} := Delta <- U]
                      ++ [merge_row(H, lg_store_keys:usage_total_key(Hour), T) || Hour := T <- Totals]
                      ++ [merge_row(H, lg_store_keys:usage_cost_key(Hour), C) || Hour := C <- Costs]
          end,
    case write(usage, H, Ops) of
        ok ->
            %% 批次已写入：sync 失败只计数，不保留增量（否则下次重复累加）
            try bitcask:sync(H) of
                ok -> ok;
                {error, R} -> failed(usage, {sync, R})
            catch
                C:R -> failed(usage, {sync, {C, R}})
            end,
            S#st{usage = #{}};
        error ->
            S  %% 原子批未写入任何内容，保留增量下次重试
    end.

merge_row(H, Key, Delta) ->
    Merged = case bitcask:get(H, Key) of
                 {ok, Old} -> add(binary_to_term(Old), Delta);
                 not_found -> Delta
             end,
    {put, Key, term_to_binary(Merged)}.

%% 维度行累加进小时总量；维度行与标签行的费用累加进费用分解（预算按 key / 用户 / 标签计，只记 > 0 的费用）
derive({Hour, Dims}, Delta, {Totals, Costs}) ->
    T1 = case tuple_size(Dims) of
             5 -> maps:update_with(Hour, fun(Old) -> add(Old, Delta) end, Delta, Totals);
             _ -> Totals
         end,
    C1 = case cost_scopes(Dims, maps:get(cost, Delta, 0.0)) of
             Empty when map_size(Empty) =:= 0 -> Costs;
             Scopes -> maps:update_with(Hour, fun(Old) -> add(Old, Scopes) end, Scopes, Costs)
         end,
    {T1, C1}.

cost_scopes(_, Cost) when Cost =< 0 ->
    #{};
cost_scopes({K, U, _, _, _}, Cost) ->
    maps:from_list([{{key, K}, Cost} || is_binary(K)] ++ [{{user, U}, Cost} || is_binary(U)]);
cost_scopes({tag, T}, Cost) ->
    #{{tag, T} => Cost};
cost_scopes(_, _) ->
    #{}.

%% 按某小时现有的维度 / 标签行重算其派生行（回填用；该小时无数据时删除派生行）
rebuild_ops(H, Hour) ->
    Fun = fun(<<_:32, DimsBin/binary>>, V, _Ts, _Ord, Acc) ->
                  derive({Hour, binary_to_term(DimsBin)}, binary_to_term(V), Acc)
          end,
    case bitcask:range_fold(H, {<<Hour:32>>, <<(Hour + 1):32>>}, [], Fun, {#{}, #{}}) of
        {error, R} ->
            error({store_range, R});
        {Totals, Costs} ->
            [case maps:find(Hour, Rows) of
                 {ok, Row} -> {put, Key, term_to_binary(Row)};
                 error -> {remove, Key}
             end || {Key, Rows} <- [{lg_store_keys:usage_total_key(Hour), Totals},
                                    {lg_store_keys:usage_cost_key(Hour), Costs}]]
    end.

%% 每分钟把当前时间写进回填标记的 alive（下次启动据此判断旧版本可能写入数据的时段）
alive(#st{alive_at = At, handles = #{usage := H}} = S) ->
    Now = lg_time:now_ms(),
    case Now - At >= ?ALIVE_MS of
        true ->
            _ = write(usage, H, fun() -> lg_store_migrate:marker_ops(H, #{alive => Now}) end),
            S#st{alive_at = Now};
        false ->
            S
    end.

add(A, B) ->
    maps:merge_with(fun(_, X, Y) -> X + Y end, A, B).
