-module(lg_health_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("lg_core/include/lg_core.hrl").

health_test_() ->
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
     [?_test(window_stats()),
      ?_test(probe_unreachable()),
      ?_test(last_sweep()),
      ?_test(live_last_sweep())]}.

cred(Url) ->
    {ok, #lg_credential{id = Id}} =
        lg_credentials:create(#{<<"name">> => <<"c">>, <<"protocol">> => <<"openai">>, <<"base_url">> => Url}),
    Id.

window_stats() ->
    C = cred(<<"https://x.test/v1">>),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"r">>,
                                 <<"targets">> => [#{<<"credential">> => C, <<"upstream_model">> => <<"busy">>},
                                                   #{<<"credential">> => C, <<"upstream_model">> => <<"idle">>}]}),
    T = {C, <<"busy">>},
    [ok = lg_health:record(T, ok, 100, undefined) || _ <- [1, 2, 3]],
    ok = lg_health:record(T, server, 500, <<"boom">>),
    ok = lg_cooldown:mark(T, #{kind => server, retry_after_ms => 60000}),
    %% 通配代入的目标（未配置在路由表中）也会出现
    ok = lg_health:record({C, <<"wild/model">>}, ok, 50, undefined),
    Rows = maps:from_list([{M, R} || #{upstream_model := M} = R <- lg_health:snapshot()]),
    ?assertEqual([<<"busy">>, <<"idle">>, <<"wild/model">>], lists:sort(maps:keys(Rows))),
    Busy = maps:get(<<"busy">>, Rows),
    ?assertMatch(#{ok := 3, errors := 1, error_kinds := #{server := 1}, avg_ms := 200,
                   last_error := #{kind := server, message := <<"boom">>}, credential_name := <<"c">>}, Busy),
    ?assertEqual(0.75, maps:get(success_rate, Busy)),
    ?assert(maps:get(cooldown_ms, Busy) > 50000),
    ?assertMatch(#{ok := 0, errors := 0, success_rate := null, last_error := null},
                 maps:get(<<"idle">>, Rows)),
    ok = lg_cooldown:reset(T),
    ?assertEqual(0, lg_cooldown:remaining_ms(T)).

probe_unreachable() ->
    {ok, L} = gen_tcp:listen(0, []),
    {ok, Port} = inet:port(L),
    gen_tcp:close(L),
    C = cred(iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port), "/v1"])),
    [P] = [P || #{credential := Id} = P <- lg_health:probe_now([C]), Id =:= C],
    ?assertMatch(#{result := network}, P).

%% T32：最近结果表 24h 无更新的条目随周期清扫删除
last_sweep() ->
    Now = lg_time:now_ms(),
    ok = lg_health:record({<<"c">>, <<"fresh">>}, ok, 10, undefined),
    true = ets:insert(lg_health_last, {{{<<"c">>, <<"stale">>}, error}, Now - 25 * 3600000, server, <<"old">>}),
    lg_health ! sweep,
    _ = sys:get_state(lg_health),
    ?assertEqual([], ets:lookup(lg_health_last, {{<<"c">>, <<"stale">>}, error})),
    ?assertMatch([_], ets:lookup(lg_health_last, {{<<"c">>, <<"fresh">>}, ok})).

%% T32：lg_live 每条路由最近一次叙述 24h 无更新的随周期清扫删除
live_last_sweep() ->
    Now = lg_time:now_ms(),
    ok = lg_live:request_end(<<"req-1">>, #{route => <<"fresh">>, status => 200, narrative => [<<"n">>]}),
    true = ets:insert(lg_live_stats, {{last, <<"stale">>}, [<<"old">>], Now - 25 * 3600000}),
    lg_live ! prune,
    _ = sys:get_state(lg_live),
    ?assertEqual([], ets:lookup(lg_live_stats, {last, <<"stale">>})),
    ?assertMatch([_], ets:lookup(lg_live_stats, {last, <<"fresh">>})).
