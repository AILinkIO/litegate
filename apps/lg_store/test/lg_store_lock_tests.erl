-module(lg_store_lock_tests).

-include_lib("eunit/include/eunit.hrl").

%% 模拟上一实例被 SIGKILL：各 cask 残留写锁，锁里的 pid 恰是本进程（容器里恒为 PID 1）
lock_test_() ->
    {foreach,
     fun() ->
             Dir = lg_core_test_util:start(),
             persistent_term:erase({lg_store, opened}),
             Dir
     end,
     fun(Dir) ->
             application:stop(lg_store),
             lg_core_test_util:stop(Dir)
     end,
     [fun(Dir) -> ?_test(same_host_reclaimed(Dir)) end,
      fun(Dir) -> ?_test(no_owner_reclaimed(Dir)) end,
      fun(Dir) -> ?_test(live_other_host_kept(Dir)) end,
      fun(Dir) -> ?_test(dead_other_host_reclaimed(Dir)) end]}.

store(Dir) ->
    filename:join(Dir, "store").

plant_locks(Dir) ->
    [begin
         D = filename:join(store(Dir), C),
         ok = filelib:ensure_path(D),
         ok = file:write_file(filename:join(D, "bitcask.write.lock"),
                              [os:getpid(), " ", D, "/1.bitcask.data\n0\n"])
     end || C <- ["logs", "idx", "usage"]].

owner(Dir, Host, AgeS) ->
    ok = filelib:ensure_path(store(Dir)),
    Path = filename:join(store(Dir), "owner"),
    ok = file:write_file(Path, Host),
    ok = file:change_time(Path, calendar:system_time_to_local_time(
                                  erlang:system_time(second) - AgeS, second)).

host() ->
    {ok, H} = inet:gethostname(),
    H.

same_host_reclaimed(Dir) ->
    plant_locks(Dir),
    owner(Dir, host(), 0),
    ?assertMatch({ok, _}, application:ensure_all_started(lg_store)).

no_owner_reclaimed(Dir) ->
    plant_locks(Dir),
    ?assertMatch({ok, _}, application:ensure_all_started(lg_store)).

%% 另一容器挂同一数据目录且心跳新鲜：不能删它的锁
live_other_host_kept(Dir) ->
    plant_locks(Dir),
    owner(Dir, "other-container", 0),
    ?assertMatch({error, _}, application:ensure_all_started(lg_store)),
    ?assert(filelib:is_file(filename:join([store(Dir), "logs", "bitcask.write.lock"]))).

dead_other_host_reclaimed(Dir) ->
    plant_locks(Dir),
    owner(Dir, "other-container", 120),
    ?assertMatch({ok, _}, application:ensure_all_started(lg_store)).
