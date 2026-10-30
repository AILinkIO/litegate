%% @doc 检索索引写入：BM25 + jieba 分词较慢，从写者拆出，避免拖慢日志与用量落盘。
%%
%% 写者在日志批次落盘后投递该批的检索文档；队列（以批计）超过 QUEUE_MAX 时丢弃整批并计数
%% litegate_store_degraded_total{level="index"}。检索是尽力而为：丢弃 / 写失败不影响日志。
-module(lg_store_indexer).
-behaviour(gen_server).

-export([start_link/0, index/1, sync/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% 积压上限（批数；每批 ≤ 200 篇、每篇 ≤ 32KB）
-define(QUEUE_MAX, 10).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc 投递一批检索文档 [{LogKey, Doc}]；积压过多或进程不在时丢弃。
-spec index([{binary(), map()}]) -> ok.
index([]) ->
    ok;
index(Docs) ->
    case whereis(?MODULE) of
        undefined ->
            dropped(Docs);
        Pid ->
            case process_info(Pid, message_queue_len) of
                {message_queue_len, N} when N < ?QUEUE_MAX -> gen_server:cast(Pid, {index, Docs});
                _ -> dropped(Docs)
            end
    end.

%% @doc 等待此前投递的文档写完（检索前调用）；超时或进程不在时直接返回。
-spec sync() -> ok.
sync() ->
    try gen_server:call(?MODULE, sync, 30000)
    catch exit:_ -> ok
    end.

init([]) ->
    %% 停止时先写完队列里已投递的文档（父进程的退出信号排在它们之后）
    process_flag(trap_exit, true),
    process_flag(message_queue_data, off_heap),
    {ok, #{}}.

handle_call(sync, _From, S) ->
    {reply, ok, S}.

handle_cast({index, Docs}, S) ->
    H = lg_store_handles:handle(search),
    %% 检索文档不支持原子批量写（值必须是 map），逐条写入
    _ = [case catch bitcask:put(H, K, Doc) of
             ok -> ok;
             Err -> lg_store_handles:write_error(search, Err)
         end || {K, Doc} <- Docs],
    {noreply, S}.

handle_info(_Msg, S) ->
    {noreply, S}.

dropped(Docs) ->
    lg_metrics:inc(litegate_store_degraded_total, [{level, index}], length(Docs)).
