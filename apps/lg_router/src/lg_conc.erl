%% @doc 单凭证并发上限与排队（凭证选项 max_concurrency）。
%%
%% - 占用计数在 ETS（`inflight/1`、`full/2` 直接读，路由排序用），增减与排队由本进程串行处理
%% - 占用者进程被监视：进程退出（客户端断开、崩溃）自动释放它持有的全部名额
%% - 排队：名额满时调用方进入该凭证的 FIFO 队列；队列长度超过 queue_limit 立即返回 full，
%%   等待超过 queue_wait_ms 返回 timeout；释放名额时按顺序交给队首
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
    gen_server:call(?MODULE, {acquire, CredId, Max, self()}).

%% @doc 排队等待名额：ok | timeout | full。
-spec wait(binary(), pos_integer(), non_neg_integer()) -> ok | timeout | full.
wait(CredId, Max, TimeoutMs) ->
    wait(CredId, Max, TimeoutMs, undefined).

%% @doc 同 wait/3；Idle 为等待期间每秒调用一次的回调（流式请求写保活帧）。
-spec wait(binary(), pos_integer(), non_neg_integer(), fun(() -> term()) | undefined) -> ok | timeout | full.
wait(CredId, Max, TimeoutMs, Idle) ->
    Ref = make_ref(),
    case gen_server:call(?MODULE, {wait, CredId, Max, self(), Ref, lg_config:get(queue_limit)}) of
        ok -> ok;
        full -> full;
        queued -> await_grant(CredId, Ref, lg_time:now_ms() + TimeoutMs, Idle)
    end.

await_grant(CredId, Ref, Deadline, Idle) ->
    Left = max(0, Deadline - lg_time:now_ms()),
    Wait = case Idle of undefined -> Left; _ -> min(Left, 1000) end,
    receive
        {lg_conc_granted, Ref} -> ok
    after Wait ->
        case lg_time:now_ms() >= Deadline of
            false ->
                _ = catch Idle(),
                await_grant(CredId, Ref, Deadline, Idle);
            true ->
                case gen_server:call(?MODULE, {cancel, CredId, Ref}) of
                    cancelled -> timeout;
                    %% 取消前刚好被分到名额
                    granted -> receive {lg_conc_granted, Ref} -> ok end
                end
        end
    end.

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

%% State：holders => #{Pid => {MonitorRef, [CredId]}}，queues => #{CredId => queue({Pid, Ref, Max})}
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
                false -> {reply, queued, enqueue(C, {Pid, Ref, Max}, S)}
            end;
        Len >= Limit ->
            {reply, full, S};
        true ->
            {reply, queued, enqueue(C, {Pid, Ref, Max}, S)}
    end;
handle_call({cancel, C, Ref}, _From, #{queues := Qs} = S) ->
    Q = maps:get(C, Qs, queue:new()),
    Q1 = queue:filter(fun({_, R, _}) -> R =/= Ref end, Q),
    case queue:len(Q1) =:= queue:len(Q) of
        true -> {reply, granted, S};
        false -> {reply, cancelled, set_queue(C, Q1, S)}
    end.

handle_cast({release, C, Pid}, S) ->
    {noreply, drain(C, drop(C, Pid, S))}.

handle_info({'DOWN', _MRef, process, Pid, _}, #{holders := Hs, queues := Qs} = S) ->
    %% 释放持有的名额，并移出它所在的队列
    Held = case maps:find(Pid, Hs) of {ok, {_, Cs}} -> Cs; error -> [] end,
    S1 = S#{holders => maps:remove(Pid, Hs)},
    S2 = lists:foldl(fun(C, Acc) -> set_count(C, inflight(C) - 1), Acc end, S1, Held),
    S3 = maps:fold(fun(C, Q, Acc) -> set_queue(C, queue:filter(fun({P, _, _}) -> P =/= Pid end, Q), Acc) end,
                   S2, Qs),
    {noreply, lists:foldl(fun drain/2, S3, lists:usort(Held))};
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
        {{value, {Pid, Ref, Max}}, Q1} ->
            case inflight(C) < Max of
                true ->
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

enqueue(C, Item, #{queues := Qs} = S) ->
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
