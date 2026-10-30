%% @doc 单凭证并发上限与排队（凭证选项 max_concurrency）。
%%
%% - 占用计数在 ETS（`inflight/1`、`full/2` 直接读，路由排序用），增减与排队由本进程串行处理
%% - 占用者进程被监视：进程退出（客户端断开、崩溃）自动释放它持有的全部名额
%% - 排队：名额满时调用方进入该凭证的 FIFO 队列；队列长度超过 queue_limit 立即返回 full，
%%   等待超过 queue_wait_ms 返回 timeout；释放名额时按顺序交给队首
%% - 排队者同样被监视：断开的客户端立即移出队列，不会占着 queue_limit
%% - 本进程忙（call 超时）或不在时调用方不崩溃：acquire 视为 busy，wait 视为 full；
%%   本进程重启后状态清空（ETS 随之重建），正在排队的调用方立即返回 timeout，
%%   已持有名额的请求不再计数（重启会短暂放宽并发上限）
-module(lg_conc).
-behaviour(gen_server).

-export([start_link/0, acquire/2, wait/3, wait/4, release/1, inflight/1, queued/1, full/2, max_of/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include_lib("lg_core/include/lg_core.hrl").

-define(TAB, lg_conc_inflight).   %% {CredId, InFlight, Queued}

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc 凭证的并发上限，0 = 不限。
-spec max_of(#lg_credential{}) -> non_neg_integer().
max_of(#lg_credential{options = #{max_concurrency := N}}) when is_integer(N) -> N;
max_of(_) -> 0.

%% @doc 立即占一个名额：ok | busy。
-spec acquire(binary(), pos_integer()) -> ok | busy.
acquire(CredId, Max) ->
    try gen_server:call(?MODULE, {acquire, CredId, Max, self()})
    catch exit:_ -> busy
    end.

%% @doc 排队等待名额：ok | timeout | full。
-spec wait(binary(), pos_integer(), non_neg_integer()) -> ok | timeout | full.
wait(CredId, Max, TimeoutMs) ->
    wait(CredId, Max, TimeoutMs, undefined).

%% @doc 同 wait/3；Idle 为等待期间每 250ms 调用一次的回调（流式请求写保活帧）。
%% Idle 抛出 {client_exit, _}（客户端断开，T20）时退出队列后继续抛出。
-spec wait(binary(), pos_integer(), non_neg_integer(), fun(() -> term()) | undefined) -> ok | timeout | full.
wait(CredId, Max, TimeoutMs, Idle) ->
    Ref = make_ref(),
    case whereis(?MODULE) of
        undefined ->
            full;
        Srv ->
            %% 监视本进程：排队期间它重启（队列丢失）时立即返回，不必等到超时
            SrvRef = erlang:monitor(process, Srv),
            Res = try gen_server:call(Srv, {wait, CredId, Max, self(), Ref, lg_config:get(queue_limit)}) of
                      ok -> ok;
                      full -> full;
                      queued -> await_grant(CredId, Ref, SrvRef, lg_time:now_ms() + TimeoutMs, Idle)
                  catch exit:_ -> full
                  end,
            erlang:demonitor(SrvRef, [flush]),
            Res
    end.

await_grant(CredId, Ref, SrvRef, Deadline, Idle) ->
    Left = max(0, Deadline - lg_time:now_ms()),
    Wait = case Idle of undefined -> Left; _ -> min(Left, 250) end,
    receive
        {lg_conc_granted, Ref} -> ok;
        {'DOWN', SrvRef, process, _, _} -> timeout
    after Wait ->
        case lg_time:now_ms() >= Deadline of
            false ->
                idle(CredId, Ref, Idle),
                await_grant(CredId, Ref, SrvRef, Deadline, Idle);
            true ->
                case catch gen_server:call(?MODULE, {cancel, CredId, Ref}) of
                    cancelled -> timeout;
                    %% 取消前刚好被分到名额（授予消息先于 cancel 的回复发出）；
                    %% 收不到说明本进程已重启、队列已丢失，按超时处理
                    granted ->
                        receive {lg_conc_granted, Ref} -> ok
                        after 1000 -> release(CredId), timeout
                        end;
                    _ -> timeout
                end
        end
    end.

%% 客户端已断开：取消排队（取消前刚好分到的名额立即归还），再把 client_exit 抛给路由层
idle(CredId, Ref, Idle) ->
    try Idle()
    catch
        throw:{client_exit, _} = E ->
            case catch gen_server:call(?MODULE, {cancel, CredId, Ref}) of
                granted ->
                    receive {lg_conc_granted, Ref} -> release(CredId)
                    after 1000 -> release(CredId)
                    end;
                _ -> ok
            end,
            throw(E);
        _:_ -> ok
    end,
    ok.

%% @doc 释放调用进程在该凭证上的一个名额。
-spec release(binary()) -> ok.
release(CredId) ->
    gen_server:cast(?MODULE, {release, CredId, self()}).

-spec inflight(binary()) -> non_neg_integer().
inflight(CredId) ->
    case ets:lookup(?TAB, CredId) of
        [{_, N, _}] -> N;
        [] -> 0
    end.

-spec queued(binary()) -> non_neg_integer().
queued(CredId) ->
    case ets:lookup(?TAB, CredId) of
        [{_, _, Q}] -> Q;
        [] -> 0
    end.

-spec full(binary(), non_neg_integer()) -> boolean().
full(_CredId, 0) -> false;
full(CredId, Max) -> inflight(CredId) >= Max.

%%====================================================================
%% gen_server
%%====================================================================

%% State：holders => #{Pid => {MonitorRef, [CredId]}}，
%% queues => #{CredId => queue({Pid, Ref, Max, MonitorRef})}（排队者各自一个 monitor）
init([]) ->
    ?TAB = ets:new(?TAB, [named_table, public, {read_concurrency, true}]),
    lg_metrics:register_gauge(litegate_credential_inflight, <<"Requests in flight per upstream credential">>,
                              fun() -> [{[{credential, C}], N} || {C, N, _} <- ets:tab2list(?TAB)] end),
    lg_metrics:register_gauge(litegate_credential_queued, <<"Requests queued per upstream credential">>,
                              fun() -> [{[{credential, C}], Q} || {C, _, Q} <- ets:tab2list(?TAB)] end),
    {ok, #{holders => #{}, queues => #{}}}.

handle_call({acquire, C, Max, Pid}, _From, S) ->
    case inflight(C) < Max andalso queue_len(C, S) =:= 0 of
        true -> {reply, ok, grant(C, Pid, S)};
        false -> {reply, busy, S}
    end;
handle_call({wait, C, Max, Pid, Ref, Limit}, _From, S) ->
    Len = queue_len(C, S),
    if
        Len =:= 0 ->
            case inflight(C) < Max of
                true -> {reply, ok, grant(C, Pid, S)};
                false -> {reply, queued, enqueue(C, Pid, Ref, Max, S)}
            end;
        Len >= Limit ->
            {reply, full, S};
        true ->
            {reply, queued, enqueue(C, Pid, Ref, Max, S)}
    end;
handle_call({cancel, C, Ref}, _From, #{queues := Qs} = S) ->
    Q = maps:get(C, Qs, queue:new()),
    {Mine, Q1} = lists:partition(fun({_, R, _, _}) -> R =:= Ref end, queue:to_list(Q)),
    case Mine of
        [] -> {reply, granted, S};
        _ ->
            _ = [erlang:demonitor(M, [flush]) || {_, _, _, M} <- Mine],
            {reply, cancelled, set_queue(C, queue:from_list(Q1), S)}
    end.

handle_cast({release, C, Pid}, S) ->
    {noreply, drain(C, drop(C, Pid, S))}.

handle_info({'DOWN', _MRef, process, Pid, _}, #{holders := Hs, queues := Qs} = S) ->
    %% 释放持有的名额，并移出它所在的队列
    Held = case maps:find(Pid, Hs) of {ok, {_, Cs}} -> Cs; error -> [] end,
    S1 = S#{holders => maps:remove(Pid, Hs)},
    S2 = lists:foldl(fun(C, Acc) -> set_count(C, inflight(C) - 1), Acc end, S1, Held),
    %% 同一进程可能既持有名额又在排队（两个 monitor 各来一次 DOWN），按 Pid 处理保证幂等
    {S3, Left} = maps:fold(fun(C, Q, {Acc, Cs}) ->
                                   Q1 = queue:filter(fun({P, _, _, _}) -> P =/= Pid end, Q),
                                   case queue:len(Q1) =:= queue:len(Q) of
                                       true -> {Acc, Cs};
                                       false -> {set_queue(C, Q1, Acc), [C | Cs]}
                                   end
                           end, {S2, []}, Qs),
    {noreply, lists:foldl(fun drain/2, S3, lists:usort(Held ++ Left))};
handle_info(_Msg, S) ->
    {noreply, S}.

%%====================================================================
%% 内部函数
%%====================================================================

grant(C, Pid, #{holders := Hs} = S) ->
    Entry = case maps:find(Pid, Hs) of
                {ok, {M, Cs}} -> {M, [C | Cs]};
                error -> {erlang:monitor(process, Pid), [C]}
            end,
    set_count(C, inflight(C) + 1),
    S#{holders => Hs#{Pid => Entry}}.

drop(C, Pid, #{holders := Hs} = S) ->
    case maps:find(Pid, Hs) of
        {ok, {M, Cs}} ->
            case lists:member(C, Cs) of
                true ->
                    set_count(C, inflight(C) - 1),
                    case lists:delete(C, Cs) of
                        [] ->
                            erlang:demonitor(M, [flush]),
                            S#{holders => maps:remove(Pid, Hs)};
                        Rest ->
                            S#{holders => Hs#{Pid => {M, Rest}}}
                    end;
                false -> S
            end;
        error -> S
    end.

%% 有空名额时按顺序交给队首（跳过已退出的进程）
drain(C, #{queues := Qs} = S) ->
    Q = maps:get(C, Qs, queue:new()),
    case queue:out(Q) of
        {{value, {Pid, Ref, Max, M}}, Q1} ->
            case inflight(C) < Max of
                true ->
                    erlang:demonitor(M, [flush]),
                    S1 = set_queue(C, Q1, S),
                    case is_process_alive(Pid) of
                        true ->
                            Pid ! {lg_conc_granted, Ref},
                            drain(C, grant(C, Pid, S1));
                        false ->
                            drain(C, S1)
                    end;
                false -> S
            end;
        {empty, _} -> S
    end.

enqueue(C, Pid, Ref, Max, #{queues := Qs} = S) ->
    Item = {Pid, Ref, Max, erlang:monitor(process, Pid)},
    set_queue(C, queue:in(Item, maps:get(C, Qs, queue:new())), S).

set_queue(C, Q, #{queues := Qs} = S) ->
    Len = queue:len(Q),
    ets:insert(?TAB, {C, inflight(C), Len}),
    case Len of
        0 -> S#{queues => maps:remove(C, Qs)};
        _ -> S#{queues => Qs#{C => Q}}
    end.

set_count(C, N) ->
    ets:insert(?TAB, {C, max(0, N), queued(C)}).

queue_len(C, #{queues := Qs}) ->
    case maps:find(C, Qs) of
        {ok, Q} -> queue:len(Q);
        error -> 0
    end.
