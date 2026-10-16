-module(lg_plan_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("lg_core/include/lg_core.hrl").

plan_test_() ->
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
             [?_test(validation()),
              ?_test(states(Port))]
     end}.

validation() ->
    Base = #{<<"name">> => <<"v">>, <<"protocol">> => <<"openai">>, <<"base_url">> => <<"https://x.test/v1">>},
    Bad = [#{<<"kind">> => <<"other">>}, #{<<"kind">> => <<"glm">>, <<"reserve_pct">> => 101},
           #{<<"kind">> => <<"glm">>, <<"extra">> => 1}, <<"glm">>],
    [?assertEqual({error, {invalid, <<"options.plan">>}},
                  lg_credentials:create(Base#{<<"options">> => #{<<"plan">> => P}})) || P <- Bad],
    {ok, #lg_credential{id = Id}} = lg_credentials:create(Base),
    ?assertEqual(normal, lg_plan:state(Id)),
    ?assertEqual([], lg_plan:all()).

remains(Pct, End) ->
    {json, 200, #{}, #{<<"model_remains">> =>
                           [#{<<"model_name">> => <<"general">>, <<"current_interval_remaining_percent">> => Pct,
                              <<"end_time">> => End, <<"current_weekly_remaining_percent">> => 100,
                              <<"weekly_end_time">> => End + 1000000}]}}.

states(Port) ->
    Later = lg_time:now_ms() + 3600000,
    %% 创建时异步刷新一次，随后同步刷新一次
    lg_mock_upstream:expect(remains(71, Later)),
    lg_mock_upstream:expect(remains(71, Later)),
    {ok, #lg_credential{id = Id}} =
        lg_credentials:create(#{<<"name">> => <<"mm">>, <<"protocol">> => <<"openai">>,
                                <<"base_url">> => iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port), "/v1"]),
                                <<"api_key">> => <<"k">>,
                                <<"options">> => #{<<"plan">> => #{<<"kind">> => <<"minimax">>, <<"reserve_pct">> => 20}}}),
    ok = lg_plan:refresh([Id]),
    #{path := Path, headers := H} = lists:last(lg_mock_upstream:requests()),
    ?assertEqual(<<"/v1/token_plan/remains">>, Path),
    ?assertEqual(<<"Bearer k">>, maps:get(<<"authorization">>, H)),
    ?assertMatch([#{credential := Id, kind := <<"minimax">>, state := <<"normal">>, error := null,
                    windows := [#{name := <<"5h">>, used_pct := 29}, #{name := <<"week">>}]}], lg_plan:all()),
    ?assertEqual(normal, lg_plan:state(Id)),
    %% 已用 85% ≥ 100 - 20 → 保留
    lg_mock_upstream:expect(remains(15, Later)),
    ok = lg_plan:refresh([Id]),
    ?assertEqual(reserve, lg_plan:state(Id)),
    %% 用尽 → 到重置时刻
    lg_mock_upstream:expect(remains(0, Later)),
    ok = lg_plan:refresh(all),
    ?assertEqual({exhausted, Later}, lg_plan:state(Id)),
    %% 窗口已过重置时刻 → 视为恢复
    lg_mock_upstream:expect(remains(0, lg_time:now_ms() - 1)),
    ok = lg_plan:refresh([Id]),
    ?assertEqual(normal, lg_plan:state(Id)),
    %% 查询失败保留上次窗口，记录错误
    lg_mock_upstream:expect({json, 401, #{}, <<"denied">>}),
    ok = lg_plan:refresh([Id]),
    ?assertMatch([#{error := <<"HTTP 401: denied">>, windows := [_, _]}], lg_plan:all()),
    %% 去掉套餐配置后不再列出
    {ok, _} = lg_credentials:update(Id, #{<<"options">> => #{<<"plan">> => null}}),
    ok = lg_plan:refresh(all),
    ?assertEqual([], lg_plan:all()),
    ?assertEqual(normal, lg_plan:state(Id)).
