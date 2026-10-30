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

%% T23：刷新去重与 worker 化（meck 替换上游额度 / 余额接口）
dedup_test_() ->
    {setup,
     fun() ->
             Dir = lg_core_test_util:start(),
             {ok, _} = application:ensure_all_started(lg_router),
             ok = meck:new(lg_plan_quota, [passthrough]),
             ok = meck:new(lg_balance_api, [passthrough]),
             Dir
     end,
     fun(Dir) ->
             meck:unload([lg_plan_quota, lg_balance_api]),
             application:stop(lg_router),
             lg_core_test_util:stop(Dir)
     end,
     [?_test(plan_storm()),
      ?_test(balance_storm()),
      ?_test(stuck_fetch())]}.

cred(Name, Opts) ->
    {ok, #lg_credential{id = Id}} =
        lg_credentials:create(#{<<"name">> => Name, <<"protocol">> => <<"openai">>,
                                <<"base_url">> => <<"http://127.0.0.1:1/v1">>, <<"api_key">> => <<"k">>,
                                <<"options">> => Opts}),
    Id.

refreshing(Tab, Id) -> ets:member(Tab, {refreshing, Id}).

%% 让上次查询“很久以前”，然后 1000 个进程并发 touched：只查一次上游
storm(Tab, Mod, Id, Touch) ->
    wait_until(fun() -> meck:num_calls(Mod, fetch, '_') >= 1 andalso not refreshing(Tab, Id) end),
    [{_, St}] = ets:lookup(Tab, Id),
    ets:insert(Tab, {Id, St#{checked_at => 0}}),
    meck:reset(Mod),
    Parent = self(),
    Ps = [spawn(fun() -> Touch(Id), Parent ! {touched, self()} end) || _ <- lists:seq(1, 1000)],
    [receive {touched, P} -> ok end || P <- Ps],
    wait_until(fun() -> not refreshing(Tab, Id) end),
    ?assertEqual(1, meck:num_calls(Mod, fetch, '_')),
    ?assertMatch([{_, #{error := null}}], ets:lookup(Tab, Id)).

plan_storm() ->
    meck:expect(lg_plan_quota, fetch, fun(_, _, _) -> timer:sleep(200), {ok, #{windows => [], level => null}} end),
    Id = cred(<<"storm-plan">>, #{<<"plan">> => #{<<"kind">> => <<"minimax">>}}),
    storm(lg_plan_status, lg_plan_quota, Id,
          fun(I) -> lg_plan:touched(I), lg_plan:quota_error(I), lg_plan:exhausted(I) end),
    ok = lg_credentials:delete(Id).

balance_storm() ->
    meck:expect(lg_balance_api, fetch,
                fun(_, _, _) -> timer:sleep(200), {ok, #{amount => 5, currency => <<"USD">>, details => []}} end),
    Id = cred(<<"storm-balance">>, #{<<"balance">> => #{<<"kind">> => <<"newapi">>}}),
    storm(lg_balance_status, lg_balance_api, Id, fun(I) -> lg_balance:touched(I), lg_balance:exhausted(I) end),
    ok = lg_credentials:delete(Id).

%% 查询卡住：status / state / all 与 gen_server 本身都不阻塞；worker 崩溃后标记清除并记录错误
stuck_fetch() ->
    Parent = self(),
    meck:expect(lg_plan_quota, fetch, fun(_, _, _) -> Parent ! {fetching, self()}, receive after infinity -> ok end end),
    Id = cred(<<"stuck-plan">>, #{<<"plan">> => #{<<"kind">> => <<"glm">>}}),
    W = receive {fetching, P} -> P after 2000 -> error(no_fetch) end,
    T0 = erlang:monotonic_time(millisecond),
    ?assertEqual(undefined, lg_plan:status(Id)),
    ?assertEqual(normal, lg_plan:state(Id)),
    ?assertMatch(#{workers := #{Id := _}}, sys:get_state(lg_plan, 500)),
    ?assertMatch([#{refreshing := true}], [E || #{credential := C} = E <- lg_plan:all(), C =:= Id]),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 500),
    %% 进行中再触发：不会起第二个 worker
    lg_plan:exhausted(Id),
    gen_server:cast(lg_plan, {refresh, [Id]}),
    _ = sys:get_state(lg_plan),
    ?assertEqual(1, meck:num_calls(lg_plan_quota, fetch, '_')),
    exit(W, kill),
    %% 配置变更触发的那一轮在崩溃后补跑一次（同样卡住），再 kill 掉
    W2 = receive {fetching, P2} -> P2 after 2000 -> error(no_rerun) end,
    ?assertMatch(#{error := <<"{worker_down,killed}">>}, lg_plan:status(Id)),
    exit(W2, kill),
    wait_until(fun() -> not refreshing(lg_plan_status, Id) end),
    ?assertMatch(#{workers := Ws} when map_size(Ws) =:= 0, sys:get_state(lg_plan)),
    ok = lg_credentials:delete(Id).

wait_until(F) -> wait_until(F, 300).
wait_until(F, 0) -> ?assert(F());
wait_until(F, N) ->
    case F() of
        true -> ok;
        false -> timer:sleep(10), wait_until(F, N - 1)
    end.
