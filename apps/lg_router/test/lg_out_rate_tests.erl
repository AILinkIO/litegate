%% @doc T08 出站速率观测：分钟桶计数、滑动窗口、清扫。
-module(lg_out_rate_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("lg_core/include/lg_core.hrl").

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
      ?_test(reset_one()),
      ?_test(sweep_keeps_recent_buckets()),
      ?_test(reset_credential_clears_all_models())]}.

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

%% T17：sweep 只删 2 分钟前的桶（此前 match spec 把计数当成分钟，每次清空全部窗口）
sweep_keeps_recent_buckets() ->
    Key = {<<"c1">>, <<"m1">>},
    Min = lg_time:now_ms() div 60000,
    [ok = lg_out_rate:record(Key) || _ <- lists:seq(1, 5)],
    true = ets:insert(lg_out_rate_win, {{Key, Min - 1}, 3}),
    true = ets:insert(lg_out_rate_win, {{Key, Min - 5}, 7}),
    sweep(),
    ?assertEqual([{{Key, Min}, 5}], ets:lookup(lg_out_rate_win, {Key, Min})),
    ?assertEqual([{{Key, Min - 1}, 3}], ets:lookup(lg_out_rate_win, {Key, Min - 1})),
    ?assertEqual([], ets:lookup(lg_out_rate_win, {Key, Min - 5})).

%% T17：凭证更新后清空该凭证所有模型的窗口与学习状态，其他凭证不受影响
reset_credential_clears_all_models() ->
    K1 = {<<"c1">>, <<"m1">>},
    K2 = {<<"c1">>, <<"m2">>},
    K3 = {<<"c2">>, <<"m1">>},
    [begin
         [ok = lg_out_rate:record(K) || _ <- lists:seq(1, 20)],
         ok = lg_out_rate:on_rate_limit(K, undefined)
     end || K <- [K1, K2, K3]],
    ok = lg_out_rate:reset_credential(<<"c1">>),
    ?assertEqual(0, lg_out_rate:rate(K1)),
    ?assertEqual(0, lg_out_rate:rate(K2)),
    ?assertMatch(#{cap := undefined}, lg_out_rate:state(K1)),
    ?assertMatch(#{cap := undefined}, lg_out_rate:state(K2)),
    ?assertEqual(20, lg_out_rate:rate(K3)),
    ?assertMatch(#{cap := 14}, lg_out_rate:state(K3)).

%% 让 lg_out_rate 处理一次 sweep（handle_call 同步一次保证 sweep 已执行）
sweep() ->
    lg_out_rate ! sweep,
    ok = gen_server:call(lg_out_rate, sync).

%% T09 / T17：AIMD 控制律（首犯/再犯/保底/暂停/回升/解除/去重/预占）
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
      ?_test(concurrent_429_cut_once()),
      ?_test(cap_floor()),
      ?_test(retry_after_pause()),
      ?_test(retry_after_then_plain_429()),
      ?_test(success_recovers()),
      ?_test(recovery_releases_cap()),
      ?_test(allow_reserves_under_cap()),
      ?_test(record_after_allow_not_double_counted()),
      ?_test(allow_with_credential_record())]}.

first_429_establishes_cap() ->
    Key = {<<"c1">>, <<"m1">>},
    %% 先产生观测流量
    [ok = lg_out_rate:record(Key) || _ <- lists:seq(1, 20)],
    %% 首犯 429（无 RA）：Cap = max(MinCap=6, 20 × 0.7) = 14
    ok = lg_out_rate:on_rate_limit(Key, undefined),
    ?assertMatch(#{cap := 14, streak := 1, observed := 20}, lg_out_rate:state(Key)).

repeat_429_halves_cap() ->
    Key = {<<"c2">>, <<"m2">>},
    ok = lg_config:set(out_rate_recovery_ms, 10),   %% 去重窗口 = 1ms
    [ok = lg_out_rate:record(Key) || _ <- lists:seq(1, 20)],
    ok = lg_out_rate:on_rate_limit(Key, undefined),
    timer:sleep(5),
    %% 再犯：Cap 减半 = max(6, 14 bsr 1) = 7
    ok = lg_out_rate:on_rate_limit(Key, undefined),
    ?assertMatch(#{cap := 7, streak := 2}, lg_out_rate:state(Key)).

%% T17：同一波并发请求的多个 429 只下调一次
concurrent_429_cut_once() ->
    Key = {<<"c2">>, <<"m3">>},
    [ok = lg_out_rate:record(Key) || _ <- lists:seq(1, 40)],
    [ok = lg_out_rate:on_rate_limit(Key, undefined) || _ <- lists:seq(1, 10)],
    ?assertMatch(#{cap := 28, streak := 1}, lg_out_rate:state(Key)).

cap_floor() ->
    Key = {<<"c3">>, <<"m3">>},
    [ok = lg_out_rate:record(Key) || _ <- lists:seq(1, 4)],
    %% 首犯：Cap = max(6, 4 × 0.7) = max(6, 3) = 6（MinCap 保底）
    ok = lg_out_rate:on_rate_limit(Key, undefined),
    ?assertMatch(#{cap := 6, streak := 1}, lg_out_rate:state(Key)).

retry_after_pause() ->
    Key = {<<"c4">>, <<"m4">>},
    Now = lg_time:now_ms(),
    ok = lg_out_rate:on_rate_limit(Key, 5000),
    #{paused_until := Paused} = lg_out_rate:state(Key),
    ?assert(Paused > Now),
    %% allow/1 应返回 throttle
    ?assertMatch({throttle, _}, lg_out_rate:allow(Key)).

%% T17：先收到带 Retry-After 的 429，之后无 RA 的 429 仍能正常收紧（此前 cap 永远建不起来）
retry_after_then_plain_429() ->
    Key = {<<"c4">>, <<"m5">>},
    ok = lg_config:set(out_rate_recovery_ms, 10),
    [ok = lg_out_rate:record(Key) || _ <- lists:seq(1, 20)],
    ok = lg_out_rate:on_rate_limit(Key, 50),
    ?assertMatch(#{cap := 14, streak := 1}, lg_out_rate:state(Key)),
    timer:sleep(5),
    ok = lg_out_rate:on_rate_limit(Key, undefined),
    ?assertMatch(#{cap := 7, streak := 2}, lg_out_rate:state(Key)).

success_recovers() ->
    Key = {<<"c5">>, <<"m5">>},
    [ok = lg_out_rate:record(Key) || _ <- lists:seq(1, 20)],
    ok = lg_out_rate:on_rate_limit(Key, undefined),
    #{cap := Cap0} = lg_out_rate:state(Key),
    ?assert(is_integer(Cap0)),
    %% 设置 recovery_ms 很短，使下一次 on_success 触发回升
    ok = lg_config:set(out_rate_recovery_ms, 1),
    timer:sleep(2),
    ok = lg_out_rate:on_success(Key),
    #{cap := Cap1} = lg_out_rate:state(Key),
    ?assert(Cap1 > Cap0).

%% T17：持续无 429 时 Cap 逐步回升并最终解除（此前每次回升重置计时，解除分支到不了）
recovery_releases_cap() ->
    Key = {<<"c5">>, <<"m6">>},
    [ok = lg_out_rate:record(Key) || _ <- lists:seq(1, 20)],
    ok = lg_out_rate:on_rate_limit(Key, undefined),
    ok = lg_config:set(out_rate_recovery_ms, 2),
    Released = lists:any(fun(_) ->
                                 timer:sleep(3),
                                 ok = lg_out_rate:on_success(Key),
                                 maps:get(cap, lg_out_rate:state(Key)) =:= undefined
                         end, lists:seq(1, 20)),
    ?assert(Released),
    ?assertEqual(ok, lg_out_rate:allow(Key)).

%% T17：放行即预占，Cap 内最多放行 Cap 个（并发进程同时判定也不超）
allow_reserves_under_cap() ->
    Key = {<<"c6">>, <<"m6">>},
    %% 已建立 Cap = 7、窗口为空的目标
    Cap = 7,
    Now = lg_time:now_ms(),
    true = ets:insert(lg_out_rate_state, {Key, Cap, undefined, 1, Now, Now, 10, Now, undefined}),
    Self = self(),
    Pids = [spawn(fun() -> Self ! {allowed, self(), lg_out_rate:allow(Key)} end) || _ <- lists:seq(1, 50)],
    Results = [receive {allowed, P, R} -> R end || P <- Pids],
    ?assertEqual(Cap, length([ok || ok <- Results])),
    ?assertEqual(Cap, lg_out_rate:rate(Key)).

%% T17：allow/1 已预占时紧随其后的 record/1 不重复计数；没有上限时 record/1 照常计数
record_after_allow_not_double_counted() ->
    Key = {<<"c7">>, <<"m7">>},
    true = ets:insert(lg_out_rate_state, {Key, 100, undefined, 1, lg_time:now_ms(), lg_time:now_ms(),
                                          100, lg_time:now_ms(), undefined}),
    ok = lg_out_rate:allow(Key),
    ok = lg_out_rate:record(Key),
    ?assertEqual(1, lg_out_rate:rate(Key)),
    Free = {<<"c7">>, <<"free">>},
    ok = lg_out_rate:allow(Free),
    ok = lg_out_rate:record(Free),
    ?assertEqual(1, lg_out_rate:rate(Free)).

%% T32：allow/2 用调用方给的凭证记录取静态 max_rpm（不查凭证表；该凭证并不在库里）
allow_with_credential_record() ->
    Key = {<<"not-in-db">>, <<"m8">>},
    Cred = #lg_credential{id = <<"not-in-db">>, options = #{max_rpm => 2}},
    ok = lg_out_rate:allow(Key, Cred),
    ok = lg_out_rate:record(Key),
    ok = lg_out_rate:allow(Key, Cred),
    ok = lg_out_rate:record(Key),
    ?assertMatch({throttle, _}, lg_out_rate:allow(Key, Cred)),
    %% allow/1 按 Key 查凭证：查不到即无静态上限
    ?assertEqual(ok, lg_out_rate:allow(Key)),
    ?assertEqual({error, timeout}, lg_out_rate:wait(Key, Cred, 1, undefined)).
