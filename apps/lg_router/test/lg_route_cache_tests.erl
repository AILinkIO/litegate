%% @doc T16：通配路由缓存由常驻进程持有 —— 跨进程、重启、重建期间都能命中。
-module(lg_route_cache_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("lg_core/include/lg_core.hrl").

route_cache_test_() ->
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
     [?_test(survives_writer_exit()),
      ?_test(rebuilt_on_restart()),
      {timeout, 30, ?_test(no_gap_during_rebuild())},
      ?_test(longest_prefix_and_empty_rest())]}.

cred() ->
    {ok, #lg_credential{id = Id}} =
        lg_credentials:create(#{<<"name">> => <<"c">>, <<"protocol">> => <<"openai">>,
                                <<"base_url">> => <<"https://api.example.com/v1">>}),
    Id.

wildcard(C, Name) ->
    {ok, _} = lg_routes:create(#{<<"name">> => Name,
                                 <<"targets">> => [#{<<"credential">> => C, <<"upstream_model">> => <<"*">>}]}),
    ok.

%% 在另一个进程里执行并等它退出（模拟 cowboy 请求进程）
in_process(Fun) ->
    {Pid, MRef} = spawn_monitor(fun() -> exit({done, Fun()}) end),
    receive {'DOWN', MRef, process, Pid, {done, R}} -> R end.

%% 写路由的请求进程退出后缓存仍在（此前表的 owner 是首个调用者，随请求进程一起销毁）
survives_writer_exit() ->
    C = cred(),
    ok = in_process(fun() -> wildcard(C, <<"or/*">>) end),
    ?assertMatch({ok, #lg_route{name = <<"or/*">>}, <<"x">>},
                 in_process(fun() -> lg_routes:match(<<"or/x">>) end)),
    ?assertMatch({ok, #lg_route{name = <<"or/*">>}, <<"y">>}, lg_routes:match(<<"or/y">>)).

%% 应用重启后首个请求即命中（缓存在 init 里从路由表构建）
rebuilt_on_restart() ->
    C = cred(),
    ok = wildcard(C, <<"gw/*">>),
    ok = application:stop(lg_router),
    {ok, _} = application:ensure_all_started(lg_router),
    ?assertMatch({ok, #lg_route{name = <<"gw/*">>}, <<"m">>},
                 in_process(fun() -> lg_routes:match(<<"gw/m">>) end)).

%% 重建期间读者始终看到完整集合
no_gap_during_rebuild() ->
    C = cred(),
    ok = wildcard(C, <<"a/*">>),
    Stop = atomics:new(1, []),
    Self = self(),
    Readers = [spawn_link(fun() -> Self ! {misses, self(), read_loop(Stop, 0)} end) || _ <- lists:seq(1, 4)],
    [ok = lg_routes:rebuild_wildcards() || _ <- lists:seq(1, 300)],
    atomics:put(Stop, 1, 1),
    Misses = lists:sum([receive {misses, P, N} -> N end || P <- Readers]),
    ?assertEqual(0, Misses).

read_loop(Stop, Misses) ->
    case atomics:get(Stop, 1) of
        1 -> Misses;
        _ ->
            case lg_routes:match(<<"a/b">>) of
                {ok, _, <<"b">>} -> read_loop(Stop, Misses);
                _ -> read_loop(Stop, Misses + 1)
            end
    end.

%% 最长前缀优先；名称恰好等于前缀时落到更短的通配；删除后不再命中
longest_prefix_and_empty_rest() ->
    C = cred(),
    ok = wildcard(C, <<"*">>),
    ok = wildcard(C, <<"p/*">>),
    ok = wildcard(C, <<"p/q/*">>),
    ?assertMatch({ok, #lg_route{name = <<"p/q/*">>}, <<"r">>}, lg_routes:match(<<"p/q/r">>)),
    ?assertMatch({ok, #lg_route{name = <<"p/*">>}, <<"q/">>}, lg_routes:match(<<"p/q/">>)),
    ?assertMatch({ok, #lg_route{name = <<"*">>}, <<"p/">>}, lg_routes:match(<<"p/">>)),
    ok = lg_routes:delete(<<"p/q/*">>),
    ?assertMatch({ok, #lg_route{name = <<"p/*">>}, <<"q/r">>}, lg_routes:match(<<"p/q/r">>)).
