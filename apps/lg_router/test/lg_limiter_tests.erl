-module(lg_limiter_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("lg_core/include/lg_core.hrl").

limiter_test_() ->
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
     [?_test(rpm()),
      ?_test(tpm_and_adjust()),
      ?_test(parallel_and_crash()),
      ?_test(all_or_nothing()),
      ?_test(release_ownership()),
      ?_test(killed_after_take()),
      ?_test(estimate())]}.

lim(Scope, Fields) ->
    maps:fold(fun(rpm, V, L) -> L#lg_limit{rpm = V};
                 (tpm, V, L) -> L#lg_limit{tpm = V};
                 (max_parallel, V, L) -> L#lg_limit{max_parallel = V} end,
              #lg_limit{scope = Scope, updated_at = 0}, Fields).

rpm() ->
    L = lim({key, <<"k">>}, #{rpm => 3}),
    [{ok, _} = lg_limiter:acquire([L], 0) || _ <- [1, 2, 3]],
    {error, {rate_limited, rpm, {key, <<"k">>}, Retry}} = lg_limiter:acquire([L], 0),
    ?assert(Retry > 0 andalso Retry =< 60000),
    %% 其他作用域不受影响
    ?assertMatch({ok, _}, lg_limiter:acquire([lim({key, <<"other">>}, #{rpm => 3})], 0)).

tpm_and_adjust() ->
    L = lim({route, <<"r">>}, #{tpm => 1000}),
    {ok, T1} = lg_limiter:acquire([L], 600),
    ?assertMatch({error, {rate_limited, tpm, {route, <<"r">>}, _}}, lg_limiter:acquire([L], 600)),
    %% 实际只用了 100：补差后腾出额度
    ok = lg_limiter:release(T1, 100),
    ?assert(lg_limiter:rate({route, <<"r">>}, tpm) < 200),
    ?assertMatch({ok, _}, lg_limiter:acquire([L], 600)),
    %% 窗口为空时单个超大请求也放行
    L2 = lim({route, <<"big">>}, #{tpm => 10}),
    ?assertMatch({ok, _}, lg_limiter:acquire([L2], 5000)),
    ?assertMatch({error, {rate_limited, tpm, _, _}}, lg_limiter:acquire([L2], 1)).

parallel_and_crash() ->
    S = {key_route, <<"k">>, <<"r">>},
    L = lim(S, #{max_parallel => 2}),
    {ok, T1} = lg_limiter:acquire([L], 0),
    Parent = self(),
    Pid = spawn(fun() -> {ok, _} = lg_limiter:acquire([L], 0), Parent ! held, receive stop -> ok end end),
    receive held -> ok end,
    ?assertEqual(2, lg_limiter:parallel(S)),
    ?assertMatch({error, {rate_limited, parallel, S, _}}, lg_limiter:acquire([L], 0)),
    ?assertEqual(2, lg_limiter:parallel(S)),
    %% 持有槽位的进程崩溃：自动归还
    exit(Pid, kill),
    wait_until(fun() -> lg_limiter:parallel(S) =:= 1 end),
    ok = lg_limiter:release(T1, 0),
    wait_until(fun() -> lg_limiter:parallel(S) =:= 0 end).

all_or_nothing() ->
    A = lim({key, <<"a">>}, #{max_parallel => 5, rpm => 100}),
    B = lim({route, <<"b">>}, #{max_parallel => 1}),
    {ok, _} = lg_limiter:acquire([A, B], 0),
    %% B 满了：A 的槽位回滚，A 的 RPM 也不计数
    Rpm0 = lg_limiter:rate({key, <<"a">>}, rpm),
    ?assertMatch({error, {rate_limited, parallel, {route, <<"b">>}, _}}, lg_limiter:acquire([A, B], 0)),
    ?assertEqual(1, lg_limiter:parallel({key, <<"a">>})),
    ?assertEqual(Rpm0, lg_limiter:rate({key, <<"a">>}, rpm)).

%% 重复 release 只归还一次，不会减掉别的请求占着的槽位；release 可在别的进程里调用（按 ticket 归属）
release_ownership() ->
    S = {key, <<"own">>},
    L = lim(S, #{max_parallel => 3}),
    {ok, T1} = lg_limiter:acquire([L], 0),
    Parent = self(),
    Holder = spawn(fun() -> {ok, T} = lg_limiter:acquire([L], 0), Parent ! {held, T}, receive stop -> ok end end),
    T2 = receive {held, T} -> T end,
    ?assertEqual(2, lg_limiter:parallel(S)),
    ok = lg_limiter:release(T1, 0),
    ok = lg_limiter:release(T1, 0),
    ok = lg_limiter:release(T1, 0),
    _ = sys:get_state(lg_limiter),
    ?assertEqual(1, lg_limiter:parallel(S)),
    %% 别的进程持有的 ticket 在本进程归还
    ok = lg_limiter:release(T2, 0),
    _ = sys:get_state(lg_limiter),
    ?assertEqual(0, lg_limiter:parallel(S)),
    exit(Holder, kill).

%% 占槽前后任意时刻被 kill：槽位都被回收
killed_after_take() ->
    S = {key, <<"kill">>},
    L = lim(S, #{max_parallel => 1000}),
    Pids = [spawn(fun() -> {ok, _} = lg_limiter:acquire([L], 0), exit(self(), kill) end) || _ <- lists:seq(1, 100)]
        ++ [begin P = spawn(fun() -> {ok, _} = lg_limiter:acquire([L], 0), receive after infinity -> ok end end),
                  exit(P, kill), P end || _ <- lists:seq(1, 200)],
    ?assertEqual(300, length(Pids)),
    wait_until(fun() -> lg_limiter:parallel(S) =:= 0 andalso sys:get_state(lg_limiter) =:= #{} end).

estimate() ->
    ?assertEqual(0, lg_limiter:estimate_tokens(#{})),
    ?assertEqual(3, lg_limiter:estimate_tokens(#{<<"messages">> => [#{<<"content">> => <<"hello world">>}]})),
    %% CJK 每字 1 token；内容块与 system 也计入
    ?assertEqual(4 + 1, lg_limiter:estimate_tokens(
                          #{<<"system">> => <<"abcd">>,
                            <<"messages">> => [#{<<"content">> => [#{<<"type">> => <<"text">>,
                                                                     <<"text">> => <<"你好世界"/utf8>>}]}]})).

wait_until(F) -> wait_until(F, 50).
wait_until(F, 0) -> ?assert(F());
wait_until(F, N) ->
    case F() of
        true -> ok;
        false -> timer:sleep(10), wait_until(F, N - 1)
    end.
