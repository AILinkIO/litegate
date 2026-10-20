%% @doc T08 出站速率观测：分钟桶计数、滑动窗口、清扫。
-module(lg_out_rate_tests).

-include_lib("eunit/include/eunit.hrl").

out_rate_test_() ->
    {foreach,
     fun() ->
             Dir = lg_core_test_util:start(),
             {ok, _} = application:ensure_all_started(lg_router),
             ok = lg_out_rate:reset(),
             Dir
     end,
     fun(Dir) -> lg_core_test_util:stop(Dir) end,
     [?_test(record_and_rate()),
      ?_test(snapshot()),
      ?_test(reset_one())]}.

record_and_rate() ->
    Key = {<<"c1">>, <<"m1">>},
    %% 初始为 0
    ?assertEqual(0, lg_out_rate:rate(Key)),
    %% 发 5 个请求
    [ok = lg_out_rate:record(Key) || _ <- lists:seq(1, 5)],
    %% 本分钟计数 = 5（无上分钟数据，滑动窗口 = 5 × 1 + 0 = 5）
    ?assertEqual(5, lg_out_rate:rate(Key)),
    %% 另一个目标互不影响
    ?assertEqual(0, lg_out_rate:rate({<<"c1">>, <<"m2">>})),
    ?assertEqual(0, lg_out_rate:rate({<<"c2">>, <<"m1">>})).

snapshot() ->
    Key1 = {<<"c1">>, <<"m1">>},
    Key2 = {<<"c2">>, <<"m2">>},
    [ok = lg_out_rate:record(Key1) || _ <- lists:seq(1, 3)],
    [ok = lg_out_rate:record(Key2) || _ <- lists:seq(1, 1)],
    Snap = lg_out_rate:snapshot(),
    ?assert(lists:member({Key1, 3}, Snap)),
    ?assert(lists:member({Key2, 1}, Snap)).

reset_one() ->
    Key1 = {<<"c1">>, <<"m1">>},
    Key2 = {<<"c2">>, <<"m2">>},
    ok = lg_out_rate:record(Key1),
    ok = lg_out_rate:record(Key2),
    ok = lg_out_rate:reset(Key1),
    ?assertEqual(0, lg_out_rate:rate(Key1)),
    ?assertEqual(1, lg_out_rate:rate(Key2)).

%% T09：AIMD 纯函数测试（首犯/再犯/保底/暂停/回升/解除）
aimd_test_() ->
    {foreach,
     fun() ->
             Dir = lg_core_test_util:start(),
             {ok, _} = application:ensure_all_started(lg_router),
             ok = lg_out_rate:reset(),
             Dir
     end,
     fun(Dir) -> lg_core_test_util:stop(Dir) end,
     [?_test(first_429_establishes_cap()),
      ?_test(repeat_429_halves_cap()),
      ?_test(cap_floor()),
      ?_test(retry_after_pause()),
      ?_test(success_recovers())]}.

first_429_establishes_cap() ->
    Key = {<<"c1">>, <<"m1">>},
    %% 先产生观测流量
    [ok = lg_out_rate:record(Key) || _ <- lists:seq(1, 20)],
    %% 首犯 429（无 RA）：Cap = max(MinCap=6, 20 × 0.7) = 14
    ok = lg_out_rate:on_rate_limit(Key, undefined),
    State = ets:lookup(lg_out_rate_state, Key),
    ?assertMatch([{_, Cap, _, 1, _, _}] when Cap =:= 14, State).

repeat_429_halves_cap() ->
    Key = {<<"c2">>, <<"m2">>},
    [ok = lg_out_rate:record(Key) || _ <- lists:seq(1, 20)],
    ok = lg_out_rate:on_rate_limit(Key, undefined),
    %% 再犯：Cap 减半 = max(6, 14 bsr 1) = 7
    ok = lg_out_rate:on_rate_limit(Key, undefined),
    State = ets:lookup(lg_out_rate_state, Key),
    ?assertMatch([{_, Cap, _, 2, _, _}] when Cap =:= 7, State).

cap_floor() ->
    Key = {<<"c3">>, <<"m3">>},
    [ok = lg_out_rate:record(Key) || _ <- lists:seq(1, 4)],
    %% 首犯：Cap = max(6, 4 × 0.7) = max(6, 3) = 6（MinCap 保底）
    ok = lg_out_rate:on_rate_limit(Key, undefined),
    State = ets:lookup(lg_out_rate_state, Key),
    ?assertMatch([{_, 6, _, 1, _, _}], State).

retry_after_pause() ->
    Key = {<<"c4">>, <<"m4">>},
    Now = lg_time:now_ms(),
    ok = lg_out_rate:on_rate_limit(Key, 5000),
    State = ets:lookup(lg_out_rate_state, Key),
    ?assertMatch([{_, _, Paused, _, _, _}] when Paused > Now, State),
    %% allow/1 应返回 throttle
    ?assertMatch({throttle, _}, lg_out_rate:allow(Key)).

success_recovers() ->
    Key = {<<"c5">>, <<"m5">>},
    [ok = lg_out_rate:record(Key) || _ <- lists:seq(1, 20)],
    ok = lg_out_rate:on_rate_limit(Key, undefined),
    [{_, Cap0, _, _, _, _}] = ets:lookup(lg_out_rate_state, Key),
    ?assert(is_integer(Cap0)),
    %% 设置 recovery_ms 很短，使下一次 on_success 触发回升
    ok = lg_config:set(out_rate_recovery_ms, 1),
    timer:sleep(2),
    ok = lg_out_rate:on_success(Key),
    [{_, Cap1, _, _, _, _}] = ets:lookup(lg_out_rate_state, Key),
    ?assert(Cap1 > Cap0).
