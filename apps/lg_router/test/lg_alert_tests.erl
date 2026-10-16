-module(lg_alert_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("lg_core/include/lg_core.hrl").

alert_test_() ->
    {setup,
     fun() ->
             Dir = lg_core_test_util:start(),
             {ok, _} = application:ensure_all_started(lg_router),
             Port = lg_mock_upstream:start(),
             {Dir, Port}
     end,
     fun({Dir, _}) ->
             lg_mock_upstream:stop(),
             application:stop(lg_router),
             lg_core_test_util:stop(Dir)
     end,
     fun({_, Port}) ->
             [?_test(config_validation(Port)),
              ?_test(upstream_down(Port)),
              ?_test(budget(Port)),
              ?_test(plan_quota(Port)),
              ?_test(catalog(Port)),
              ?_test(login_brute_force(Port)),
              ?_test(test_channel(Port))]
     end}.

hook(Port) -> iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port), "/hook"]).

channel(Port) ->
    {ok, #lg_channel{id = Id}} = lg_alerts:create_channel(#{<<"name">> => <<"hook">>, <<"type">> => <<"webhook">>,
                                                             <<"url">> => hook(Port)}),
    Id.

rule(Event, Threshold, Ch) ->
    {ok, #lg_alert_rule{id = Id}} = lg_alerts:create_rule(#{<<"event">> => Event, <<"threshold">> => Threshold,
                                                            <<"channels">> => [Ch]}),
    Id.

reset() ->
    [ok = lg_alerts:delete_rule(Id) || #lg_alert_rule{id = Id} <- lg_alerts:rules()],
    ets:insert(lg_mock_upstream, {requests, []}).

%% 等待模拟 webhook 收到 N 条通知，返回各条的 event / title
hooks(N) -> hooks(N, 100).
hooks(N, 0) -> error({expected_hooks, N, lg_mock_upstream:requests()});
hooks(N, Left) ->
    ok = lg_alert:flush(),
    case [B || #{path := <<"/hook">>, body := B} <- lg_mock_upstream:requests()] of
        L when length(L) >= N -> L;
        _ -> timer:sleep(20), hooks(N, Left - 1)
    end.

expect(N) -> [lg_mock_upstream:expect({json, 200, #{}, #{}}) || _ <- lists:seq(1, N)].

config_validation(Port) ->
    ?assertEqual({error, {invalid, <<"type">>}},
                 lg_alerts:create_channel(#{<<"name">> => <<"x">>, <<"type">> => <<"sms">>, <<"url">> => hook(Port)})),
    ?assertEqual({error, {invalid, <<"url">>}},
                 lg_alerts:create_channel(#{<<"name">> => <<"x">>, <<"type">> => <<"wecom">>, <<"url">> => <<"nope">>})),
    Ch = channel(Port),
    [#{<<"url_hint">> := Hint, <<"has_secret">> := false}] =
        [lg_alerts:channel_to_map(C) || #lg_channel{id = I} = C <- lg_alerts:channels(), I =:= Ch],
    ?assertEqual(<<"http://127.0.0.1/…hook"/utf8>>, Hint),
    ?assertEqual({error, {invalid, <<"channels">>}},
                 lg_alerts:create_rule(#{<<"event">> => <<"budget">>, <<"channels">> => [<<"missing">>]})),
    ?assertEqual({error, {invalid, <<"event">>}}, lg_alerts:create_rule(#{<<"event">> => <<"nope">>})),
    {ok, R} = lg_alerts:create_rule(#{<<"event">> => <<"plan_quota">>, <<"channels">> => [Ch]}),
    ?assertMatch(#{<<"threshold">> := 90}, lg_alerts:rule_to_map(R)),
    %% 删除渠道时从规则中移除
    ok = lg_alerts:delete_channel(Ch),
    ?assertMatch([#lg_alert_rule{channels = []}], lg_alerts:rules()),
    reset().

login_brute_force(Port) ->
    reset(),
    Ch = channel(Port),
    rule(<<"login_brute_force">>, 3, Ch),
    expect(1),
    Peer = {192, 0, 2, 24},
    [ok = lg_login_guard:failure(<<"admin">>, Peer) || _ <- lists:seq(1, 3)],
    [B] = hooks(1),
    ?assertMatch(#{<<"event">> := <<"login_brute_force">>, <<"level">> := <<"warning">>,
                   <<"data">> := #{<<"username">> := <<"admin">>, <<"peer">> := <<"192.0.2.24">>,
                                   <<"failures">> := 3}}, B),
    ok = lg_login_guard:reset(),
    reset().

upstream_down(Port) ->
    reset(),
    Ch = channel(Port),
    rule(<<"upstream_down">>, 2, Ch),
    {ok, #lg_credential{id = C}} = lg_credentials:create(#{<<"name">> => <<"up">>, <<"protocol">> => <<"openai">>,
                                                           <<"base_url">> => <<"https://x.test/v1">>}),
    T = {C, <<"m">>},
    expect(2),
    ok = lg_health:record(T, server, 10, <<"boom">>),
    ok = lg_health:record(T, client, 10, <<"bad request">>),   %% 请求错误不计入
    ?assertEqual([], [B || #{path := <<"/hook">>, body := B} <- lg_mock_upstream:requests()]),
    ok = lg_health:record(T, timeout, 10, undefined),
    ok = lg_health:record(T, server, 10, <<"again">>),         %% 已告警，不重复
    ok = lg_health:record(T, ok, 10, undefined),               %% 恢复
    [Down, Up] = hooks(2),
    ?assertMatch(#{<<"event">> := <<"upstream_down">>, <<"level">> := <<"critical">>,
                   <<"title">> := <<"上游故障：up / m"/utf8>>, <<"data">> := #{<<"failures">> := 2}}, Down),
    ?assertMatch(#{<<"level">> := <<"info">>, <<"title">> := <<"上游已恢复：up / m"/utf8>>}, Up),
    %% 通知记录带发送结果
    timer:sleep(100),
    [#{event := upstream_down, level := info, deliveries := [#{status := ok}]}, #{level := critical} | _] =
        lg_alert:history(10).

budget(Port) ->
    reset(),
    Ch = channel(Port),
    rule(<<"budget">>, 50, Ch),
    {ok, K, #lg_api_key{id = KeyId}} = lg_api_keys:create(#{<<"name">> => <<"spender">>}),
    _ = K,
    {ok, _} = lg_limits:set_budget({key, KeyId}, #{<<"period">> => <<"day">>, <<"max_usd">> => 1}),
    expect(1),
    ok = lg_budget:add(KeyId, undefined, [], 0.3),
    ok = lg_budget:add(KeyId, undefined, [], 0.3),     %% 60% → 告警
    ok = lg_budget:add(KeyId, undefined, [], 0.3),     %% 本周期不再重复
    [B] = hooks(1),
    timer:sleep(50),
    ?assertEqual(1, length([X || #{path := <<"/hook">>} = X <- lg_mock_upstream:requests()])),
    ?assertMatch(#{<<"event">> := <<"budget">>, <<"title">> := <<"预算告警：API Key spender"/utf8>>,
                   <<"data">> := #{<<"max_usd">> := 1}}, B).

plan_quota(Port) ->
    reset(),
    Ch = channel(Port),
    rule(<<"plan_quota">>, 90, Ch),
    At = lg_time:now_ms() + 3600000,
    W = fun(U, R) -> #{windows => [#{name => <<"5h">>, used_pct => U, resets_at => R}]} end,
    expect(2),
    ok = lg_alert:plan_status(<<"cred_x">>, <<"GLM">>, W(50, At)),
    ok = lg_alert:plan_status(<<"cred_x">>, <<"GLM">>, W(95, At)),
    ok = lg_alert:plan_status(<<"cred_x">>, <<"GLM">>, W(100, At)),   %% 同一窗口周期不重复
    ok = lg_alert:plan_status(<<"cred_x">>, <<"GLM">>, W(3, At + 5 * 3600000)),
    [Hit, Rec] = hooks(2),
    ?assertMatch(#{<<"title">> := <<"套餐额度告警：GLM"/utf8>>, <<"data">> := #{<<"used_pct">> := 95}}, Hit),
    ?assertMatch(#{<<"title">> := <<"套餐额度已恢复：GLM"/utf8>>}, Rec).

catalog(Port) ->
    reset(),
    Ch = channel(Port),
    rule(<<"catalog_sync_failed">>, null, Ch),
    expect(1),
    ok = lg_db:write(#lg_meta{key = catalog_sync, value = #{status => error, error => <<"timeout">>,
                                                           at => lg_time:now_ms(), source => <<"models.dev">>}}),
    lg_alert ! check,
    [B] = hooks(1),
    ?assertMatch(#{<<"event">> := <<"catalog_sync_failed">>, <<"text">> := <<"timeout">>}, B).

test_channel(Port) ->
    reset(),
    Ch = channel(Port),
    lg_mock_upstream:expect({json, 200, #{}, #{}}),
    ?assertEqual(ok, lg_alert:test_channel(Ch)),
    lg_mock_upstream:expect({json, 500, #{}, <<"down">>}),
    ?assertEqual({error, <<"HTTP 500: down">>}, lg_alert:test_channel(Ch)),
    ?assertEqual({error, not_found}, lg_alert:test_channel(<<"nope">>)).
