-module(lg_conc_tests).

-include_lib("eunit/include/eunit.hrl").

conc_test_() ->
    {foreach,
     fun() ->
             Dir = lg_core_test_util:start(),
             {ok, _} = application:ensure_all_started(lg_router),
             Dir
     end,
     fun(Dir) ->
             application:stop(lg_router),
             lg_core_test_util:stop(Dir)
     end,
     [?_test(waiter_killed()),
      ?_test(server_killed())]}.

%% 排队者被 kill：立即移出队列，ETS 计数同步；名额释放后交给下一个活着的排队者
waiter_killed() ->
    C = <<"cw">>,
    ok = lg_conc:acquire(C, 1),
    Parent = self(),
    W1 = spawn(fun() -> Parent ! {self(), lg_conc:wait(C, 1, 10000)} end),
    wait_until(fun() -> lg_conc:queued(C) =:= 1 end),
    W2 = spawn(fun() -> Parent ! {self(), lg_conc:wait(C, 1, 10000)} end),
    wait_until(fun() -> lg_conc:queued(C) =:= 2 end),
    exit(W1, kill),
    wait_until(fun() -> lg_conc:queued(C) =:= 1 end),
    #{queues := #{C := Q}} = sys:get_state(lg_conc),
    ?assertEqual(1, queue:len(Q)),
    lg_conc:release(C),
    receive {W2, Res} -> ?assertEqual(ok, Res) after 2000 -> ?assert(false) end,
    ?assertEqual(0, lg_conc:queued(C)).

%% lg_conc 被 kill（队列丢失）：所有排队者 ≤1.5 秒内返回 timeout，不会永久阻塞
server_killed() ->
    C = <<"ck">>,
    ok = lg_conc:acquire(C, 1),
    Parent = self(),
    Ws = [spawn(fun() -> Parent ! {self(), lg_conc:wait(C, 1, 30000, Idle)} end)
          || Idle <- [undefined, fun() -> ok end, undefined]],
    wait_until(fun() -> lg_conc:queued(C) =:= 3 end),
    Old = whereis(lg_conc),
    T0 = erlang:monotonic_time(millisecond),
    exit(Old, kill),
    [receive {W, Res} -> ?assertEqual(timeout, Res) after 1500 -> ?assert(false) end || W <- Ws],
    ?assert(erlang:monotonic_time(millisecond) - T0 =< 1500),
    %% 重启后照常工作
    wait_until(fun() -> is_pid(whereis(lg_conc)) andalso whereis(lg_conc) =/= Old end),
    ?assertEqual(ok, lg_conc:acquire(C, 1)).

wait_until(F) -> wait_until(F, 200).
wait_until(F, 0) -> ?assert(F());
wait_until(F, N) ->
    case catch F() of
        true -> ok;
        _ -> timer:sleep(10), wait_until(F, N - 1)
    end.
