%% @doc 端到端（T20）：客户端在拿到回复前断开——排队中、首包前、非流式等待上游 / 读响应体时。
%% 断开后 1s 内停止等待、取消上游、释放名额；日志记 499（client_closed），已产生的用量照常计费。
-module(lg_web_disconnect_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("lg_core/include/lg_core.hrl").

disconnect_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(Ctx) ->
             [{timeout, 20, ?_test(queued_stream(Ctx))},
              {timeout, 20, ?_test(before_first_byte(Ctx))},
              {timeout, 20, ?_test(sync_waiting_upstream(Ctx))},
              {timeout, 20, ?_test(sync_after_reply_billed(Ctx))}]
     end}.

setup() ->
    Dir = lg_core_test_util:start(),
    application:set_env(lg_core, http_port, 0),
    application:set_env(lg_core, patience_ms, 0),
    {ok, _} = application:ensure_all_started(lg_web),
    Up = lg_mock_upstream:start(),
    Base = iolist_to_binary(["http://127.0.0.1:", integer_to_list(Up), "/v1"]),
    Cred = fun(N) ->
                   {ok, #lg_credential{id = Id}} =
                       lg_credentials:create(#{<<"name">> => N, <<"protocol">> => <<"openai">>,
                                               <<"base_url">> => Base, <<"api_key">> => N}),
                   Id
           end,
    C1 = Cred(<<"primary">>),
    C2 = Cred(<<"backup">>),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"solo">>,
                                 <<"targets">> => [#{<<"credential">> => C1, <<"upstream_model">> => <<"solo-up">>}]}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"duo">>,
                                 <<"targets">> => [#{<<"credential">> => C1, <<"upstream_model">> => <<"up-1">>},
                                                   #{<<"credential">> => C2, <<"upstream_model">> => <<"up-2">>,
                                                     <<"priority">> => 1}]}),
    {ok, K, _} = lg_api_keys:create(#{<<"name">> => <<"all">>}),
    #{dir => Dir, port => ranch:get_port(lg_http_listener), key => K, c1 => C1}.

cleanup(#{dir := Dir}) ->
    lg_mock_upstream:stop(),
    [application:stop(A) || A <- [lg_web, lg_router, lg_provider, lg_catalog]],
    application:unset_env(lg_core, http_port),
    application:unset_env(lg_core, patience_ms),
    lg_core_test_util:stop(Dir).

%%--------------------------------------------------------------------

chat(Model) ->
    #{<<"model">> => Model, <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]}.

completion(Text) ->
    #{<<"id">> => <<"cc">>, <<"model">> => <<"up">>,
      <<"choices">> => [#{<<"index">> => 0, <<"finish_reason">> => <<"stop">>,
                          <<"message">> => #{<<"role">> => <<"assistant">>, <<"content">> => Text}}],
      <<"usage">> => #{<<"prompt_tokens">> => 1, <<"completion_tokens">> => 1}}.

reset_upstream() ->
    lg_cooldown:clear(),
    lg_out_rate:reset(),
    ets:insert(lg_mock_upstream, {requests, []}).

%% 发起请求但不读回复，返回连接（之后 gun:close 模拟客户端断开）。日志按请求标签查找
open_post(#{port := Port}, Key, Tag, Body) ->
    {ok, Conn} = gun:open("127.0.0.1", Port, #{retry => 0}),
    {ok, _} = gun:await_up(Conn, 5000),
    _ = gun:post(Conn, <<"/v1/chat/completions">>,
                 [{<<"content-type">>, <<"application/json">>},
                  {<<"authorization">>, <<"Bearer ", Key/binary>>},
                  {<<"x-litegate-tags">>, Tag}],
                 json:encode(Body)),
    Conn.

wait_until(F, Ms) when Ms =< 0 ->
    ?assert(F());
wait_until(F, Ms) ->
    case F() of
        true -> ok;
        false -> timer:sleep(20), wait_until(F, Ms - 20)
    end.

tag_log(Tag) ->
    lg_store:flush(),
    case lg_store:logs(#{tag => Tag, limit => 5}) of
        #{items := [#{id := Id} | _]} -> {ok, L} = lg_store:log(Id), L;
        _ -> undefined
    end.

wait_tag_log(Tag, Ms) ->
    wait_until(fun() -> tag_log(Tag) =/= undefined end, Ms),
    tag_log(Tag).

upstream_count() ->
    length(lg_mock_upstream:requests()).

%% 追踪 gun:cancel/2（无 meck：用调用追踪断言上游流被取消）
trace_cancel(On) ->
    erlang:trace_pattern({gun, cancel, 2}, On, [global]),
    erlang:trace(all, On, [call]).

assert_cancelled() ->
    receive
        {trace, _, call, {gun, cancel, [_, _]}} -> ok
    after 1000 ->
        ?assert(false)
    end.

%%--------------------------------------------------------------------

%% lg_conc 排队期间断开：1s 内退出队列，日志 499，不访问上游
queued_stream(#{key := K, c1 := C1} = Ctx) ->
    reset_upstream(),
    {ok, _} = lg_credentials:update(C1, #{<<"options">> => #{<<"max_concurrency">> => 1}}),
    Self = self(),
    Holder = spawn(fun() -> Self ! {held, lg_conc:acquire(C1, 1)}, receive stop -> ok end end),
    receive {held, ok} -> ok end,
    Tag = <<"t20:queued">>,
    Conn = open_post(Ctx, K, Tag, (chat(<<"solo">>))#{<<"stream">> => true}),
    wait_until(fun() -> lg_conc:queued(C1) =:= 1 end, 3000),
    T0 = erlang:monotonic_time(millisecond),
    gun:close(Conn),
    wait_until(fun() -> lg_conc:queued(C1) =:= 0 end, 1000),
    L = wait_tag_log(Tag, 1000),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 1500),
    ?assertMatch(#{status := 499, stream := true, client_aborted := true, error := #{kind := client_closed}}, L),
    ?assertEqual(0, upstream_count()),
    %% 只有 Holder 占着名额
    ?assertEqual(1, lg_conc:inflight(C1)),
    Holder ! stop,
    wait_until(fun() -> lg_conc:inflight(C1) =:= 0 end, 1000),
    {ok, _} = lg_credentials:update(C1, #{<<"options">> => #{<<"max_concurrency">> => null}}).

%% 流式首包前断开：上游流被 cancel，不再尝试备用目标，并发名额归还
before_first_byte(#{key := K, c1 := C1} = Ctx) ->
    reset_upstream(),
    {ok, _} = lg_credentials:update(C1, #{<<"options">> => #{<<"max_concurrency">> => 2}}),
    lg_mock_upstream:expect({delay, 3000, {json, 200, #{}, completion(<<"late">>)}}),
    Tag = <<"t20:first-byte">>,
    Conn = open_post(Ctx, K, Tag, (chat(<<"duo">>))#{<<"stream">> => true}),
    wait_until(fun() -> upstream_count() =:= 1 end, 3000),
    ?assertEqual(1, lg_conc:inflight(C1)),
    trace_cancel(true),
    gun:close(Conn),
    try
        assert_cancelled()
    after
        trace_cancel(false)
    end,
    L = wait_tag_log(Tag, 1000),
    ?assertMatch(#{status := 499, stream := true, error := #{kind := client_closed},
                   attempt_list := [#{upstream_model := <<"up-1">>, kind := client_closed}]}, L),
    ?assertEqual(0, lg_conc:inflight(C1)),
    timer:sleep(300),
    ?assertEqual([<<"up-1">>], [maps:get(<<"model">>, B) || #{body := B} <- lg_mock_upstream:requests()]),
    {ok, _} = lg_credentials:update(C1, #{<<"options">> => #{<<"max_concurrency">> => null}}).

%% 非流式等待上游响应头时断开：同样取消上游、不回退，日志 499
sync_waiting_upstream(#{key := K} = Ctx) ->
    reset_upstream(),
    lg_mock_upstream:expect({delay, 3000, {json, 200, #{}, completion(<<"late">>)}}),
    Tag = <<"t20:sync-wait">>,
    Conn = open_post(Ctx, K, Tag, chat(<<"duo">>)),
    wait_until(fun() -> upstream_count() =:= 1 end, 3000),
    trace_cancel(true),
    T0 = erlang:monotonic_time(millisecond),
    gun:close(Conn),
    try
        assert_cancelled()
    after
        trace_cancel(false)
    end,
    L = wait_tag_log(Tag, 1000),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 1500),
    ?assertMatch(#{status := 499, stream := false, error := #{kind := client_closed}}, L),
    timer:sleep(300),
    ?assertEqual(1, upstream_count()).

%% 非流式：上游已回复（读响应体期间）客户端断开，日志仍在、按用量计费、预算已扣
sync_after_reply_billed(Ctx) ->
    reset_upstream(),
    ok = lg_catalog:put_overlay({<<"t20prov">>, <<"t20-m">>},
                                #{<<"name">> => <<"T20">>, <<"cost">> => #{<<"input">> => 1000000, <<"output">> => 2000000}}),
    #{c1 := C1} = Ctx,
    {ok, _} = lg_routes:create(#{<<"name">> => <<"priced">>,
                                 <<"targets">> => [#{<<"credential">> => C1, <<"upstream_model">> => <<"t20-m">>,
                                                     <<"model_ref">> => [<<"t20prov">>, <<"t20-m">>]}]}),
    {ok, K, _} = lg_api_keys:create(#{<<"name">> => <<"t20-billed">>}),
    {ok, #lg_api_key{id = KId}} = lg_api_keys:authenticate(K),
    lg_mock_upstream:expect({body_delay, 600, 200, completion(<<"paid">>)}),
    Tag = <<"t20:sync-billed">>,
    Conn = open_post(Ctx, K, Tag, chat(<<"priced">>)),
    wait_until(fun() -> upstream_count() =:= 1 end, 3000),
    timer:sleep(150),
    gun:close(Conn),
    L = wait_tag_log(Tag, 3000),
    ?assertMatch(#{status := 499, stream := false, client_aborted := true, cost := 3.0,
                   usage := #{input := 1, output := 1}}, L),
    ?assert(abs(lg_budget:spent({key, KId}, day) - 3.0) < 1.0e-9),
    ok = lg_routes:delete(<<"priced">>).
