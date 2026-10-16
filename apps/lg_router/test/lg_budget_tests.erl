-module(lg_budget_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("lg_core/include/lg_core.hrl").

budget_test_() ->
    {foreach,
     fun() ->
             Dir = lg_core_test_util:start(),
             {ok, _} = application:ensure_all_started(lg_router),
             Dir
     end,
     fun(Dir) ->
             application:stop(lg_router),
             application:stop(lg_store),
             lg_core_test_util:stop(Dir)
     end,
     [?_test(periods()),
      ?_test(check_and_add()),
      ?_test(rebuild_from_store()),
      ?_test(config_validation())]}.

ms(DT) -> (calendar:datetime_to_gregorian_seconds(DT) - 62167219200) * 1000.

periods() ->
    %% 2026-09-24 是周四
    T = ms({{2026, 9, 24}, {15, 30, 0}}),
    ?assertEqual(ms({{2026, 9, 24}, {0, 0, 0}}), lg_budget:period_start(day, T)),
    ?assertEqual(ms({{2026, 9, 21}, {0, 0, 0}}), lg_budget:period_start(week, T)),
    ?assertEqual(ms({{2026, 9, 1}, {0, 0, 0}}), lg_budget:period_start(month, T)),
    ?assertEqual(ms({{2026, 10, 1}, {0, 0, 0}}), lg_budget:period_end(month, T)),
    ?assertEqual(ms({{2027, 1, 1}, {0, 0, 0}}), lg_budget:period_end(month, ms({{2026, 12, 31}, {23, 0, 0}}))),
    %% 周一当天仍属本周
    Mon = ms({{2026, 9, 21}, {0, 0, 0}}),
    ?assertEqual(Mon, lg_budget:period_start(week, Mon)).

check_and_add() ->
    Key = #lg_api_key{id = <<"k1">>, user_id = <<"u1">>, hash = <<>>, prefix = <<>>, name = <<>>,
                      created_at = 0},
    ?assertEqual(ok, lg_budget:check(Key, [])),
    {ok, _} = lg_limits:set_budget({key, <<"k1">>}, #{<<"period">> => <<"day">>, <<"max_usd">> => 1}),
    {ok, _} = lg_limits:set_budget({user, <<"u1">>}, #{<<"period">> => <<"month">>, <<"max_usd">> => 5}),
    ok = lg_budget:add(<<"k1">>, <<"u1">>, [], 0.6),
    ?assertEqual(ok, lg_budget:check(Key, [])),
    ok = lg_budget:add(<<"k1">>, <<"u1">>, [], 0.5),
    {error, {budget_exceeded, {key, <<"k1">>}, Reset}} = lg_budget:check(Key, []),
    ?assertEqual(lg_budget:period_end(day, lg_time:now_ms()), Reset),
    ?assertEqual(1.1, lg_budget:spent({key, <<"k1">>}, day)),
    %% 调高 Key 预算后，用户预算仍未超
    {ok, _} = lg_limits:set_budget({key, <<"k1">>}, #{<<"period">> => <<"day">>, <<"max_usd">> => 10}),
    ?assertEqual(ok, lg_budget:check(Key, [])),
    %% 同用户的其他 Key 受用户预算约束
    ok = lg_budget:add(<<"k2">>, <<"u1">>, [], 4),
    Other = Key#lg_api_key{id = <<"k2">>},
    ?assertMatch({error, {budget_exceeded, {user, <<"u1">>}, _}}, lg_budget:check(Other, [])),
    {ok, deleted} = lg_limits:set_budget({user, <<"u1">>}, #{<<"max_usd">> => null}),
    ?assertEqual(ok, lg_budget:check(Other, [])).

rebuild_from_store() ->
    Now = lg_time:now_ms(),
    Log = fun(Cost) -> #{id => lg_store:new_id(), key_id => <<"kr">>, user_id => <<"ur">>, route => <<"r">>,
                         cost => Cost, usage => #{input => 1, output => 1, cache_read => 0, cache_write => 0}} end,
    ok = lg_store:record(Log(0.25), undefined),
    ok = lg_store:record(Log(0.5), undefined),
    ok = lg_store:flush(),
    %% 重启 lg_router：花费从用量汇总重建
    ok = application:stop(lg_router),
    {ok, _} = application:ensure_all_started(lg_router),
    ?assertEqual(0.75, lg_budget:spent({key, <<"kr">>}, day)),
    ?assertEqual(0.75, lg_budget:spent({user, <<"ur">>}, month)),
    ?assert(Now > 0).

config_validation() ->
    ?assertEqual({error, {invalid, <<"period">>}},
                 lg_limits:set_budget({key, <<"k">>}, #{<<"period">> => <<"year">>, <<"max_usd">> => 1})),
    ?assertEqual({error, {invalid, <<"max_usd">>}},
                 lg_limits:set_budget({key, <<"k">>}, #{<<"max_usd">> => -1})),
    ?assertEqual({error, {invalid, <<"rpm">>}}, lg_limits:set_limit({key, <<"k">>}, #{<<"rpm">> => 0})),
    {ok, #lg_limit{rpm = 5, tpm = undefined}} = lg_limits:set_limit({key, <<"k">>}, #{<<"rpm">> => 5}),
    {ok, _} = lg_limits:set_limit({key_route, <<"k">>, <<"r">>}, #{<<"max_parallel">> => 2}),
    ?assertEqual(2, length(lg_limits:limits_for(<<"k">>, <<"r">>))),
    ?assertEqual(1, length(lg_limits:limits_for(<<"k">>, <<"other">>))),
    %% 全部为空即删除
    {ok, deleted} = lg_limits:set_limit({key, <<"k">>}, #{<<"rpm">> => null}),
    ?assertEqual(not_found, lg_limits:get_limit({key, <<"k">>})),
    ?assertEqual({ok, {key_route, <<"k">>, <<"r">>}},
                 lg_limits:scope_from_map(lg_limits:scope_to_map({key_route, <<"k">>, <<"r">>}))),
    ?assertEqual({error, {invalid, <<"scope">>}}, lg_limits:scope_from_map(#{<<"type">> => <<"x">>})).
