%% 存储查询索引、派生行回填与 janitor 成本（T31）
-module(lg_store_migrate_tests).

-include_lib("eunit/include/eunit.hrl").

-define(H, 3600000).
-define(DAY, 86400000).

migrate_test_() ->
    {foreach,
     fun() ->
             Dir = lg_core_test_util:start(),
             {ok, _} = application:ensure_all_started(lg_store),
             Dir
     end,
     fun(Dir) ->
             catch meck:unload(bitcask),
             application:stop(lg_store),
             lg_core_test_util:stop(Dir)
     end,
     [{timeout, 120, ?_test(errors_index())},
      {timeout, 120, ?_test(overview_reads_hour_totals())},
      {timeout, 60, ?_test(migrate_old_format())},
      {timeout, 60, ?_test(downgrade_gap())},
      ?_test(alerts_latest()),
      ?_test(cache_rewrite_not_purged()),
      {timeout, 120, ?_test(janitor_bounded_queue())}]}.

id_at(Ms, Seq) ->
    lg_store_keys:id(lg_store_keys:log_key(Ms * 1000, Seq)).

log(Id, Extra) ->
    maps:merge(#{id => Id, route => <<"gpt">>, key_id => <<"k1">>, user_id => <<"u1">>, credential => <<"c1">>,
                 upstream_model => <<"up">>, status => 200, usage => #{input => 10, output => 5},
                 cost => 0.5, duration_ms => 100}, Extra).

h(C) -> lg_store_handles:handle(C).

%% 跑 5 次取中位数（毫秒）
ms(F) ->
    Runs = [begin
                T0 = erlang:monotonic_time(microsecond),
                R = F(),
                {(erlang:monotonic_time(microsecond) - T0) / 1000, R}
            end || _ <- lists:seq(1, 5)],
    {lists:nth(3, lists:sort([T || {T, _} <- Runs])), element(2, hd(Runs))}.

ids(#{items := Items}) -> [maps:get(id, L) || L <- Items].

%% 删掉回填标记：查询全部退回原有路径（等价于升级前的读法）
drop_marker() ->
    ok = bitcask:delete(h(usage), lg_store_keys:usage_meta_key()).

marker() ->
    {ok, V} = bitcask:get(h(usage), lg_store_keys:usage_meta_key()),
    binary_to_term(V).

restore_marker(M) ->
    ok = bitcask:put(h(usage), lg_store_keys:usage_meta_key(), term_to_binary(M)).

restart() ->
    ok = application:stop(lg_store),
    {ok, _} = application:ensure_all_started(lg_store),
    ok.

%% 5 万条日志、0.1% 错误：errors_only 首页走 $e 索引，与全扫结果一致
errors_index() ->
    Now = lg_time:now_ms(),
    N = 50000,
    lists:foreach(
      fun(I) ->
              Extra = case I rem 1000 of
                          0 -> #{status => 502, error => #{kind => server}};
                          500 -> #{status => 429};  %% 只有状态码没有 error：进索引，但不满足 errors_only
                          _ -> #{}
                      end,
              ok = lg_store:record(log(id_at(Now - (N - I) * 10, I), Extra), undefined),
              I rem 2000 =:= 0 andalso lg_store:flush(logs)
      end, lists:seq(1, N)),
    ok = lg_store:flush(),
    ?assert(lg_store_migrate:ready(errors, lg_store_keys:log_bounds(0, Now + 1))),
    {Fast, P1} = ms(fun() -> lg_store:logs(#{errors_only => true}) end),
    ?assertEqual(50, length(ids(P1))),
    #{items := [#{error := _} | _]} = P1,
    %% 翻页、叠加过滤
    #{items := A, next_cursor := C} = lg_store:logs(#{errors_only => true, limit => 20}),
    #{items := B} = lg_store:logs(#{errors_only => true, limit => 30, cursor => C}),
    ?assertEqual(ids(P1), ids(#{items => A ++ B})),
    ?assertEqual(ids(P1), ids(lg_store:logs(#{errors_only => true, key_id => <<"k1">>}))),
    ?assertEqual([], ids(lg_store:logs(#{errors_only => true, key_id => <<"nobody">>}))),
    %% 原有路径（全扫 + 逐条解码）结果一致
    M = marker(),
    drop_marker(),
    {Slow, P2} = ms(fun() -> lg_store:logs(#{errors_only => true}) end),
    restore_marker(M),
    ?assertEqual(ids(P2), ids(P1)),
    ?debugFmt("errors_only first page, ~p logs / 50 errors: index ~.1fms, full scan ~.1fms", [N, Fast, Slow]),
    ?assert(Fast < 200).

%% 概览：15 天按小时查询只解码总量行（行数 = 小时数），与逐行汇总一致；预算费用分解同理
overview_reads_hour_totals() ->
    Now = lg_time:now_ms(),
    Hours = 360,
    Keys = 20,
    lists:foreach(
      fun(I) ->
              Ts = Now - (I div Keys) * ?H - 1000,
              K = integer_to_binary(I rem Keys),
              ok = lg_store:record(log(id_at(Ts, I), #{key_id => <<"k", K/binary>>, user_id => <<"u", K/binary>>,
                                                       tags => [<<"t", K/binary>>],
                                                       cost => 0.25 * (I rem 4)}), undefined),
              I rem 2000 =:= 0 andalso lg_store:flush()
      end, lists:seq(0, Hours * Keys - 1)),
    ok = lg_store:flush(),
    Q = #{from => Now - 15 * ?DAY, to => Now + 1, group_by => [hour]},
    {Decoded, Hourly} = counted(fun() -> lg_store:usage(Q) end),
    {Fast, Hourly} = ms(fun() -> lg_store:usage(Q) end),
    ?assertEqual(length(Hourly), Decoded),
    ?assert(Decoded =< Hours + 1),
    Day = lg_store:usage(maps:remove(group_by, Q)),
    ByDay = lg_store:usage(Q#{group_by => [day]}),
    Costs = lg_store:usage_costs(Now - 31 * ?DAY, Now + 1),
    M = marker(),
    drop_marker(),
    {SlowDecoded, SlowHourly} = counted(fun() -> lg_store:usage(Q) end),
    {Slow, SlowHourly} = ms(fun() -> lg_store:usage(Q) end),
    {BudgetSlow, _} = ms(fun() -> lg_store:usage_costs(Now - 31 * ?DAY, Now + 1) end),
    SlowDay = lg_store:usage(maps:remove(group_by, Q)),
    SlowByDay = lg_store:usage(Q#{group_by => [day]}),
    SlowCosts = lg_store:usage_costs(Now - 31 * ?DAY, Now + 1),
    restore_marker(M),
    {BudgetFast, _} = ms(fun() -> lg_store:usage_costs(Now - 31 * ?DAY, Now + 1) end),
    ?assertEqual(SlowHourly, Hourly),
    ?assertEqual(SlowDay, Day),
    ?assertEqual(SlowByDay, ByDay),
    ?assertEqual(SlowCosts, Costs),
    ?assertEqual(Hours, length(Costs)),
    ?debugFmt("overview 15d hourly: totals ~p rows ~.1fms, per-row ~p rows ~.1fms; "
              "budget costs: cost rows ~.1fms, per-row ~.1fms", [Decoded, Fast, SlowDecoded, Slow, BudgetFast, BudgetSlow]).

%% 返回 {range_fold 回调次数（即读出并解码的行数）, 结果}
counted(F) ->
    Ref = counters:new(1, []),
    ok = meck:new(bitcask, [passthrough]),
    ok = meck:expect(bitcask, range_fold,
                     fun(H, R, O, Fun, Acc) ->
                             meck:passthrough([H, R, O, fun(K, V, T, Or, A) -> counters:add(Ref, 1, 1),
                                                                             Fun(K, V, T, Or, A) end, Acc])
                     end),
    try F() of
        Res -> {counters:get(Ref, 1), Res}
    after
        meck:unload(bitcask)
    end.

%% 旧格式数据（升级前写入：无派生行、无 $e、无过期索引）：升级后、回填后查询结果都与升级前一致
migrate_old_format() ->
    Now = lg_time:now_ms(),
    old_format_data(Now, 0),
    drop_marker(),
    Before = queries(Now),
    restart(),
    #{usage := {_, _}, errors := {_, _}, cache := all, responses := all} = marker(),
    same(Before, queries(Now)),
    Stats = lg_store_migrate:run(),
    ?assertMatch(#{usage_hours := 48, logs := 1000, cache := 4, responses := 2}, Stats),
    ?assertMatch(#{usage := none, errors := none, cache := none, responses := none}, marker()),
    ?assert(lg_store_migrate:ready(usage, {0, lg_store_keys:hour(Now)})),
    same(Before, queries(Now)),
    %% 幂等：再跑无事可做
    ?assertMatch(#{usage_hours := 0, logs := 0, cache := 0, responses := 0}, lg_store_migrate:run()),
    %% 旧缓存条目已建过期索引：清理删掉过期的 2 条，保留未过期的
    #{cache := 2, responses := 1} = lg_store_janitor:run(),
    ?assertMatch({ok, _}, lg_store:cache_get(<<"old-live-0">>)),
    ?assertEqual(not_found, bitcask:get(h(cache), <<"old-dead-0">>)),
    ?assertMatch({ok, _}, lg_store:response_get(<<"resp_live">>)),
    ?assertEqual(not_found, lg_store:response_get(<<"resp_old">>)).

%% 降级后再升级：旧版本运行期间（标记 alive 之后）写入的数据在重启时并入未覆盖范围
downgrade_gap() ->
    Now = lg_time:now_ms(),
    ok = lg_store:record(log(id_at(Now - ?H, 1), #{}), undefined),
    ok = lg_store:flush(),
    _ = lg_store_migrate:run(),
    #{usage := none, errors := none, cache := none, responses := none} = marker(),
    %% 模拟旧版本在本版本最后一次存活之后写入（只有原有格式：维度行、无 $e 的错误日志、无过期索引的缓存）
    timer:sleep(1100),
    old_format_data(lg_time:now_ms(), 1),
    restart(),
    #{usage := {_, _}, errors := {_, _}, cache := {_, _}, responses := {_, _}} = marker(),
    Before = queries(Now),
    ?assertMatch(#{usage_hours := UH, logs := 1000, cache := 4, responses := 2} when UH >= 1, lg_store_migrate:run()),
    #{usage := none, errors := none, cache := none, responses := none} = marker(),
    same(Before, queries(Now)),
    #{items := Errs} = lg_store:logs(#{errors_only => true, limit => 500}),
    ?assertEqual(300, length(Errs)).

%% 直接写入原有格式：48 小时 × 3 维度 + 标签行；1000 条日志（30% 错误）；缓存 / Responses 旧条目
old_format_data(Now, Shift) ->
    U = h(usage),
    Hour0 = lg_store_keys:hour(Now) - 47 * (1 - Shift),
    Row = fun(I) -> #{requests => I, errors => I rem 2, input => 10 * I, output => I, cost => 0.25 * I,
                      duration_ms => 100 * I, {lat, I rem 3} => I} end,
    ok = bitcask:put_batch_atomic(
           U, [{put, lg_store_keys:usage_key(Hour0 + H, Dims), term_to_binary(Row(H + D))}
               || H <- lists:seq(0, 47 * (1 - Shift)), {D, Dims} <- [{1, {<<"k1">>, <<"u1">>, <<"r">>, <<"c">>, <<"m">>}},
                                                                     {2, {<<"k2">>, <<"u1">>, <<"r">>, <<"c">>, <<"m">>}},
                                                                     {3, {<<"k3">>, undefined, <<"r2">>, <<"c">>, <<"m">>}},
                                                                     {4, {tag, <<"t1">>}}]]),
    %% 降级场景的日志须落在旧版本运行期间（最近 1 秒内）
    Logs = [{lg_store_keys:log_key((Now - I * (1000 - 999 * Shift)) * 1000, 70000 + Shift * 10000 + I),
             log(<<>>, case I rem 10 < 3 of
                           true -> #{error => #{kind => timeout}, status => 504};
                           false -> #{}
                       end)}
            || I <- lists:seq(1, 1000)],
    ok = bitcask:put_batch_atomic(h(logs), [{put, K, term_to_binary(L#{id => lg_store_keys:id(K), ts => lg_store_keys:ts_ms(K)})}
                                            || {K, L} <- Logs]),
    %% 旧版本同样写维度索引（只是没有 $e）
    ok = bitcask:put_batch_atomic(h(idx), [{put, lg_store_keys:idx_key(T, maps:get(F, L), K), <<>>}
                                           || {K, L} <- Logs, {T, F} <- [{k, key_id}, {r, route}, {u, user_id}]]),
    S = integer_to_binary(Shift),
    ok = bitcask:put_batch_atomic(
           h(cache), [{put, <<"old-dead-", S/binary>>, term_to_binary(#{body => <<"x">>, expires_at => Now - 1000})},
                      {put, <<"old-dead2-", S/binary>>, term_to_binary(#{body => <<"x">>, expires_at => Now - 5000})},
                      {put, <<"old-live-", S/binary>>, term_to_binary(#{body => <<"y">>, expires_at => Now + 600000})},
                      {put, <<"old-live2-", S/binary>>, term_to_binary(#{body => <<"y">>, expires_at => Now + 600000})}]),
    ok = bitcask:put_batch_atomic(
           h(responses), [{put, <<"resp_old">>, term_to_binary(#{x => 1, created_at => Now - 40 * ?DAY})},
                          {put, <<"resp_live">>, term_to_binary(#{x => 2, created_at => Now - ?DAY})}]).

%% 逐项比较查询结果，不一致时只打印第一处差异
same(A, B) ->
    Diff = [I || {I, X, Y} <- lists:zip3(lists:seq(1, length(A)), A, B), X =/= Y],
    Diff =/= [] andalso ?debugFmt("query ~p differs:~n~P~nvs~n~P", [hd(Diff), lists:nth(hd(Diff), A), 40,
                                                                     lists:nth(hd(Diff), B), 40]),
    ?assertEqual([], Diff).

queries(Now) ->
    Q = #{from => Now - 3 * ?DAY, to => Now + ?H},
    [lg_store:usage(Q), lg_store:usage(Q#{group_by => [hour]}), lg_store:usage(Q#{group_by => [day]}),
     lg_store:usage(Q#{group_by => [key_id, user_id]}), lg_store:usage(Q#{group_by => [tag]}),
     lg_store:usage(Q#{key_id => <<"k2">>}),
     lg_store:usage_costs(Now - 3 * ?DAY, Now + ?H),
     ids(lg_store:logs(#{errors_only => true})),
     ids(lg_store:logs(#{errors_only => true, limit => 500, from => Now - 500000})),
     ids(lg_store:logs(#{errors_only => true, route => <<"gpt">>}))].

%% 最近 N 条告警：只读最近的时间窗口，结果与全量排序一致（同一毫秒按 seq）
alerts_latest() ->
    Now = lg_time:now_ms(),
    All = [#{id => integer_to_binary(I), ts => Now - (I div 3) * 3600 * 1000 * 5, seq => 100000 - I}
           || I <- lists:seq(1, 600)],
    ok = bitcask:put_batch_atomic(h(alerts), [{put, <<Ts:64, Id/binary>>, term_to_binary(A#{created_at => Ts})}
                                              || #{id := Id, ts := Ts} = A <- All]),
    Sorted = lists:sort(fun(A, B) -> {maps:get(ts, A), maps:get(seq, A)} >= {maps:get(ts, B), maps:get(seq, B)} end,
                        [A#{created_at => Ts} || #{ts := Ts} = A <- All]),
    [?assertEqual(lists:sublist(Sorted, N), lg_store:alerts(N)) || N <- [1, 2, 5, 50, 200, 1000]],
    {Ms, _} = ms(fun() -> lg_store:alerts(10) end),
    ?debugFmt("alerts(10) of 600 over 50 days: ~.2fms", [Ms]).

%% 同一缓存键过期后重写（更晚的过期时间）：旧过期索引只删索引，不删新条目
cache_rewrite_not_purged() ->
    ok = lg_store:cache_put(<<"k">>, 1, #{body => <<"old">>}),
    ok = lg_store:flush(),
    timer:sleep(1100),
    ok = lg_store:cache_put(<<"k">>, 60, #{body => <<"new">>}),
    ok = lg_store:cache_put(<<"gone">>, 1, #{body => <<"x">>}),
    ok = lg_store:flush(),
    timer:sleep(1100),
    ?assertMatch(#{cache := 1}, lg_store_janitor:run()),
    ?assertMatch({ok, #{body := <<"new">>}}, lg_store:cache_get(<<"k">>)),
    %% 只剩新条目与它的过期索引
    [#{keys := 2}] = [S || #{cask := cache} = S <- lg_store:status()].

%% janitor 删除大量键：每次写者调用 ≤ 1000 键，同时有写入流量，写者邮箱峰值保持很低
janitor_bounded_queue() ->
    Now = lg_time:now_ms(),
    NCache = 50000,
    NLogs = 20000,
    lists:foreach(
      fun(Chunk) ->
              ok = bitcask:put_batch_atomic(
                     h(cache), lists:append([[{put, K, term_to_binary(#{body => <<"b">>, expires_at => Now - 1000})},
                                              lg_store_keys:expiry_op(expires_at, Now - 1000, K)]
                                             || I <- Chunk, K <- [<<"c", (integer_to_binary(I))/binary>>]]))
      end, chunks(lists:seq(1, NCache), 1000)),
    lists:foreach(
      fun(Chunk) ->
              Ks = [lg_store_keys:log_key((Now - 40 * ?DAY + I) * 1000, I) || I <- Chunk],
              ok = bitcask:put_batch_atomic(h(logs), [{put, K, term_to_binary(#{id => lg_store_keys:id(K)})} || K <- Ks]),
              ok = bitcask:put_batch_atomic(h(idx), [{put, lg_store_keys:idx_key(T, D, K), <<>>}
                                                     || K <- Ks, K0 <- [binary:decode_unsigned(K) rem 5000],
                                                        {T, D} <- [{k, <<"k-old">>}, {s, integer_to_binary(K0)}]])
      end, chunks(lists:seq(1, NLogs), 1000)),
    Writer = whereis(lg_store_writer),
    Self = self(),
    Sampler = spawn_link(fun() -> sample(Writer, 0, Self) end),
    Producer = spawn_link(fun() -> produce(0) end),
    T0 = erlang:monotonic_time(millisecond),
    Stats = lg_store_janitor:run(),
    Ms = erlang:monotonic_time(millisecond) - T0,
    unlink(Producer),
    exit(Producer, kill),
    Sampler ! stop,
    Peak = receive {peak, P} -> P after 5000 -> error(no_sample) end,
    ?assertMatch(#{cache := NCache, logs := NLogs}, Stats),
    ?assertEqual(NLogs * 2, maps:get(index, Stats)),
    ?debugFmt("janitor deleted ~p keys in ~pms, writer queue peak ~p",
              [NCache * 2 + NLogs * 3, Ms, Peak]),
    ?assert(Peak < 1000).

chunks([], _) -> [];
chunks(L, N) when length(L) =< N -> [L];
chunks(L, N) -> {A, B} = lists:split(N, L), [A | chunks(B, N)].

sample(Writer, Peak, Parent) ->
    receive
        stop -> Parent ! {peak, Peak}
    after 1 ->
            {message_queue_len, L} = process_info(Writer, message_queue_len),
            sample(Writer, max(Peak, L), Parent)
    end.

%% 写入流量：约 2000 条 / 秒
produce(I) ->
    ok = lg_store:record(log(lg_store:new_id(), #{}), undefined),
    timer:sleep(case I rem 2 of 0 -> 0; 1 -> 1 end),
    produce(I + 1).
