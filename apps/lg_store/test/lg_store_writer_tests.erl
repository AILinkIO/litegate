%% 写者背压、写盘错误与句柄解耦（T21）
-module(lg_store_writer_tests).

-include_lib("eunit/include/eunit.hrl").

writer_test_() ->
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
     [{timeout, 60, ?_test(degrade_under_slow_writer())},
      ?_test(sync_failure_no_double_count()),
      ?_test(batch_failure_retains_usage()),
      ?_test(writer_killed_readers_unaffected()),
      ?_test(handles_down_cache_miss()),
      ?_test(write_error_health())]}.

log(Id) ->
    #{id => Id, route => <<"gpt">>, key_id => <<"k1">>, status => 200,
      usage => #{input => 10, output => 5}, cost => 0.5, duration_ms => 100}.

msgs() ->
    #{request => #{<<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hello gateway">>}]},
      response => <<"hi">>}.

counter(Name, Labels) ->
    case ets:lookup(lg_metrics, {Name, Labels}) of
        [{_, V}] -> V;
        [] -> 0
    end.

keys(Cask) ->
    [N] = [N || #{cask := C, keys := N} <- lg_store:status(), C =:= Cask],
    N.

requests() ->
    case lg_store:usage(#{}) of
        [] -> 0;
        [#{requests := N}] -> N
    end.

slow_batches(Ms) ->
    ok = meck:new(bitcask, [passthrough]),
    ok = meck:expect(bitcask, put_batch_atomic,
                     fun(H, Ops) -> timer:sleep(Ms), meck:passthrough([H, Ops]) end).

%% 写者被拖慢（每批 200ms）时按积压分级降级：前 soft 条完整，soft..hard 去掉对话与检索文档，
%% 超过 hard 只保留用量；用量一条不丢，积压计数回零
degrade_under_slow_writer() ->
    ok = lg_config:set(store_queue_soft, 100),
    ok = lg_config:set(store_queue_hard, 400),
    slow_batches(200),
    Soft0 = counter(litegate_store_degraded_total, [{level, <<"soft">>}]),
    Hard0 = counter(litegate_store_degraded_total, [{level, <<"hard">>}]),
    Writer = whereis(lg_store_writer),
    %% 暂停写者让积压确定地累积（等价于写者远远跟不上）
    ok = sys:suspend(Writer),
    [ok = lg_store:record(log(lg_store:new_id()), msgs()) || _ <- lists:seq(1, 2000)],
    {message_queue_len, 2000} = process_info(Writer, message_queue_len),
    ok = sys:resume(Writer),
    ?assertEqual(300, counter(litegate_store_degraded_total, [{level, <<"soft">>}]) - Soft0),
    ?assertEqual(1600, counter(litegate_store_degraded_total, [{level, <<"hard">>}]) - Hard0),
    ok = lg_store:flush(),
    ?assertEqual(2000, requests()),
    ?assertEqual(400, keys(logs)),
    ?assertEqual(100, keys(msgs)),
    lg_store_indexer:sync(),
    ?assertEqual(100, keys(search)),
    ?assertEqual(0, atomics:get(lg_store_handles:stats(), 1)),
    %% 积压消退后恢复完整写入
    Id = lg_store:new_id(),
    ok = lg_store:record(log(Id), msgs()),
    ok = lg_store:flush(),
    ?assertMatch({ok, _}, lg_store:messages(Id)),
    ok = lg_config:unset(store_queue_soft),
    ok = lg_config:unset(store_queue_hard).

%% 用量批次已写入而 sync 失败（返回错误或抛出）：不崩溃、不保留增量，重启后不重复计数
sync_failure_no_double_count() ->
    ok = meck:new(bitcask, [passthrough]),
    ok = meck:expect(bitcask, sync, fun(_) -> {error, eio} end),
    [ok = lg_store:record(log(lg_store:new_id()), undefined) || _ <- lists:seq(1, 3)],
    ok = lg_store:flush(),
    ok = meck:expect(bitcask, sync, fun(_) -> error(eio) end),
    ok = lg_store:record(log(lg_store:new_id()), undefined),
    Writer = whereis(lg_store_writer),
    ok = lg_store:flush(),
    ?assertEqual(Writer, whereis(lg_store_writer)),
    ?assertEqual(2, counter(litegate_store_write_errors_total, [{cask, <<"usage">>}])),
    ok = meck:unload(bitcask),
    ok = application:stop(lg_store),
    {ok, _} = application:ensure_all_started(lg_store),
    ?assertEqual(4, requests()).

%% 用量原子批写失败：增量保留，恢复后补写，既不丢也不重复
batch_failure_retains_usage() ->
    Usage = lg_store_handles:handle(usage),
    ok = meck:new(bitcask, [passthrough]),
    ok = meck:expect(bitcask, put_batch_atomic,
                     fun(H, _Ops) when H =:= Usage -> {error, enospc};
                        (H, Ops) -> meck:passthrough([H, Ops])
                     end),
    [ok = lg_store:record(log(lg_store:new_id()), undefined) || _ <- lists:seq(1, 3)],
    ?assertEqual(0, requests()),
    ?assertEqual(0, requests()),
    ok = meck:unload(bitcask),
    ?assertEqual(3, requests()),
    ok = application:stop(lg_store),
    {ok, _} = application:ensure_all_started(lg_store),
    ?assertEqual(3, requests()).

%% 写者被 kill：句柄不随之关闭，读者照常读到缓存；写者重启后继续写入
writer_killed_readers_unaffected() ->
    ok = lg_store:cache_put(<<"k1">>, 60, #{body => <<"b">>}),
    ok = lg_store:flush(),
    Self = self(),
    Reader = spawn_link(fun() -> Self ! {reads, read_loop(2000, [])} end),
    Writer = whereis(lg_store_writer),
    exit(Writer, kill),
    Results = receive {reads, R} -> R after 10000 -> error(timeout) end,
    unlink(Reader),
    ?assertEqual([hit], lists:usort(Results)),
    ok = wait_restarted(Writer, 50),
    Id = lg_store:new_id(),
    ok = lg_store:record(log(Id), undefined),
    ok = lg_store:flush(),
    ?assertMatch({ok, _}, lg_store:log(Id)).

read_loop(0, Acc) ->
    Acc;
read_loop(N, Acc) ->
    R = case lg_store:cache_get(<<"k1">>) of
            {ok, _} -> hit;
            miss -> miss
        end,
    read_loop(N - 1, [R | Acc]).

wait_restarted(_Old, 0) ->
    error(writer_not_restarted);
wait_restarted(Old, N) ->
    case whereis(lg_store_writer) of
        P when is_pid(P), P =/= Old -> ok;
        _ -> timer:sleep(20), wait_restarted(Old, N - 1)
    end.

%% 句柄不可用（存储重启中）时热路径读按未命中处理，不抛异常
handles_down_cache_miss() ->
    ok = lg_store:cache_put(<<"k1">>, 60, #{body => <<"b">>}),
    ok = lg_store:response_put(<<"r1">>, #{x => 1}),
    ok = lg_store:flush(),
    ?assertMatch({ok, _}, lg_store:cache_get(<<"k1">>)),
    ok = application:stop(lg_store),
    ?assertEqual(miss, lg_store:cache_get(<<"k1">>)),
    ?assertEqual(not_found, lg_store:response_get(<<"r1">>)),
    ?assertEqual(ok, lg_store:flush()),
    ?assertEqual(ok, lg_store:health()).

%% 日志批写失败：计数指标、/health 进入 degraded；恢复写入后连续失败清零（窗口内仍 degraded）
write_error_health() ->
    ?assertEqual(ok, lg_store:health()),
    ok = meck:new(bitcask, [passthrough]),
    ok = meck:expect(bitcask, put_batch_atomic, fun(_, _) -> {error, enospc} end),
    ok = lg_store:record(log(lg_store:new_id()), undefined),
    ok = lg_store:flush(),
    ?assertEqual(1, counter(litegate_store_write_errors_total, [{cask, <<"logs">>}])),
    ?assertEqual(1, counter(litegate_store_write_errors_total, [{cask, <<"idx">>}])),
    ?assertMatch({degraded, #{consecutive_errors := N, last_write_error_ms := T}} when N > 0 andalso T > 0,
                 lg_store:health()),
    ok = meck:unload(bitcask),
    ok = lg_store:record(log(lg_store:new_id()), undefined),
    ok = lg_store:flush(),
    ?assertMatch({degraded, #{consecutive_errors := 0}}, lg_store:health()),
    %% 失败批次的用量增量保留到恢复后写入
    ?assertEqual(2, requests()).
