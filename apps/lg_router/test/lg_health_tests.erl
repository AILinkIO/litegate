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
      ?_test(probe_unreachable())]}.

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
