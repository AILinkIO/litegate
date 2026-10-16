%% @doc 测试辅助：在临时目录里启动 lg_core。
-module(lg_core_test_util).

-export([start/0, stop/1]).

start() ->
    Dir = filename:join([os:getenv("TMPDIR", "/tmp"),
                         "lg_core_test_" ++ integer_to_list(erlang:unique_integer([positive]))]),
    ok = filelib:ensure_path(Dir),
    application:unset_env(mnesia, dir),
    application:set_env(lg_core, data_dir, Dir),
    {ok, _} = application:ensure_all_started(lg_core),
    Dir.

%% 按依赖倒序停掉全部 LiteGate 应用：漏停的应用会持有已删除数据目录的句柄，污染下一个测试
stop(Dir) ->
    [application:stop(A) || A <- [lg_web, lg_router, lg_store, lg_provider, lg_catalog]],
    application:stop(lg_core),
    application:stop(mnesia),
    application:unset_env(mnesia, dir),
    application:unset_env(lg_core, data_dir),
    file:del_dir_r(Dir).
