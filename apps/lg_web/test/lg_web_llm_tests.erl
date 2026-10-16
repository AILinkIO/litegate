%% @doc 端到端：gun 客户端 → cowboy → 路由 → 模拟上游。
-module(lg_web_llm_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("lg_core/include/lg_core.hrl").

web_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(Ctx) ->
             [?_test(health(Ctx)),
              ?_test(auth_errors(Ctx)),
              ?_test(models(Ctx)),
              ?_test(unknown_and_forbidden(Ctx)),
              ?_test(openai_sync_with_fallback(Ctx)),
              ?_test(client_error_not_retried(Ctx)),
              ?_test(quota_cools_credential(Ctx)),
              ?_test(concurrency_limit(Ctx)),
              ?_test(session_affinity(Ctx)),
              ?_test(stream_hold_keepalive(Ctx)),
              ?_test(non_api_replies(Ctx)),
              ?_test(rule_routing(Ctx)),
              ?_test(laya_intent(Ctx)),
              ?_test(otlp_export(Ctx)),
              ?_test(anthropic_client_stream_to_openai(Ctx)),
              ?_test(openai_stream_upstream_fails_before_open(Ctx)),
              ?_test(max_tokens_clamped(Ctx)),
              ?_test(bad_requests(Ctx)),
              ?_test(recorded(Ctx)),
              ?_test(rate_limited(Ctx)),
              ?_test(budget_exceeded(Ctx)),
              ?_test(parallel_limit(Ctx)),
              ?_test(embeddings(Ctx)),
              ?_test(metrics(Ctx)),
              ?_test(wildcard(Ctx)),
              ?_test(response_cache(Ctx)),
              ?_test(responses_api(Ctx)),
              ?_test(responses_passthrough_history(Ctx)),
              ?_test(responses_base_url(Ctx)),
              ?_test(plan_accounting(Ctx)),
              ?_test(think_tags_split(Ctx)),
              ?_test(playground(Ctx)),
              ?_test(anthropic_beta_retry(Ctx)),
              ?_test(request_tags(Ctx)),
              ?_test(client_detection(Ctx)),
              ?_test(balances(Ctx)),
              ?_test(nested_route_rules(Ctx)),
              ?_test(live_events(Ctx)),
              ?_test(structured_output(Ctx)),
              ?_test(middleware(Ctx)),
              ?_test(unfit_learning(Ctx)),
              ?_test(patience_retry(Ctx)),
              ?_test(loop_guard(Ctx)),
              ?_test(redaction(Ctx)),
              ?_test(sessions_view(Ctx)),
              ?_test(images(Ctx)),
              ?_test(speech(Ctx)),
              ?_test(systemone(Ctx)),
              ?_test(systemone_intent(Ctx)),
              ?_test(count_tokens(Ctx)),
              ?_test(client_disconnect_recorded(Ctx))]
     end}.

setup() ->
    Dir = lg_core_test_util:start(),
    application:set_env(lg_core, http_port, 0),
    %% 整轮重试默认关闭（多数用例按单轮的上游次数断言），patience 用例单独开启
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
    {ok, _} = lg_routes:create(#{<<"name">> => <<"gpt">>,
                                 <<"targets">> => [#{<<"credential">> => C1, <<"upstream_model">> => <<"up-1">>},
                                                   #{<<"credential">> => C2, <<"upstream_model">> => <<"up-2">>,
                                                     <<"priority">> => 1}]}),
    {ok, #lg_credential{id = CA}} =
        lg_credentials:create(#{<<"name">> => <<"anthropic">>, <<"protocol">> => <<"anthropic">>,
                                <<"base_url">> => binary:part(Base, 0, byte_size(Base) - 3),
                                <<"api_key">> => <<"ak">>}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"claude">>,
                                 <<"targets">> => [#{<<"credential">> => CA, <<"upstream_model">> => <<"claude-up">>}]}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"mixed">>,
                                 <<"targets">> => [#{<<"credential">> => CA, <<"upstream_model">> => <<"claude-up">>},
                                                   #{<<"credential">> => C1, <<"upstream_model">> => <<"emb-up">>,
                                                     <<"priority">> => 1}]}),
    {ok, #lg_credential{id = CR}} =
        lg_credentials:create(#{<<"name">> => <<"native-responses">>, <<"protocol">> => <<"openai">>,
                                <<"base_url">> => Base, <<"api_key">> => <<"rk">>,
                                <<"options">> => #{<<"responses_api">> => true}}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"native">>,
                                 <<"targets">> => [#{<<"credential">> => CR, <<"upstream_model">> => <<"rs-up">>}]}),
    {ok, K, _} = lg_api_keys:create(#{<<"name">> => <<"all">>}),
    {ok, Kc, _} = lg_api_keys:create(#{<<"name">> => <<"capped">>, <<"max_tokens">> => 50}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"secret">>,
                                 <<"targets">> => [#{<<"credential">> => C1, <<"upstream_model">> => <<"s">>}],
                                 <<"access">> => []}),
    #{dir => Dir, port => ranch:get_port(lg_http_listener), key => K, capped => Kc, c1 => C1, c2 => C2, base => Base}.

cleanup(#{dir := Dir}) ->
    lg_mock_upstream:stop(),
    [application:stop(A) || A <- [lg_web, lg_router, lg_provider, lg_catalog]],
    application:unset_env(lg_core, http_port),
    lg_core_test_util:stop(Dir).

%% 返回 {Status, Headers, Body}
req(#{port := Port}, Method, Path, Headers, Body) ->
    {ok, Conn} = gun:open("127.0.0.1", Port, #{retry => 0}),
    {ok, _} = gun:await_up(Conn, 5000),
    Ref = gun:request(Conn, Method, Path, Headers, Body),
    Res = case gun:await(Conn, Ref, 10000) of
              {response, fin, S, H} -> {S, H, <<>>};
              {response, nofin, S, H} -> {ok, B} = gun:await_body(Conn, Ref, 10000), {S, H, B}
          end,
    gun:close(Conn),
    Res.

post(Ctx, Path, Key, Body) ->
    post(Ctx, Path, [{<<"authorization">>, <<"Bearer ", Key/binary>>}], Key, Body).
post(Ctx, Path, Headers, _Key, Body) ->
    req(Ctx, <<"POST">>, Path, [{<<"content-type">>, <<"application/json">>} | Headers],
        json:encode(Body)).

chat(Model) ->
    #{<<"model">> => Model, <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]}.

completion(Text) ->
    #{<<"id">> => <<"cc">>, <<"model">> => <<"up">>,
      <<"choices">> => [#{<<"index">> => 0, <<"finish_reason">> => <<"stop">>,
                          <<"message">> => #{<<"role">> => <<"assistant">>, <<"content">> => Text}}],
      <<"usage">> => #{<<"prompt_tokens">> => 1, <<"completion_tokens">> => 1}}.

upstream_models() ->
    [maps:get(<<"model">>, B) || #{body := B} <- lg_mock_upstream:requests()].

reset_upstream() ->
    lg_cooldown:clear(),
    ets:insert(lg_mock_upstream, {requests, []}).

%%--------------------------------------------------------------------

health(Ctx) ->
    ?assertMatch({200, _, <<"{\"status\":\"ok\"}">>}, req(Ctx, <<"GET">>, <<"/health">>, [], <<>>)).

auth_errors(Ctx) ->
    {401, _, B1} = post(Ctx, <<"/v1/chat/completions">>, [], none, chat(<<"gpt">>)),
    ?assertMatch(#{<<"error">> := #{<<"type">> := <<"authentication_error">>,
                                    <<"message">> := <<"Missing API key">>}}, json:decode(B1)),
    {401, _, B2} = post(Ctx, <<"/v1/messages">>, [{<<"x-api-key">>, <<"lgk-bad">>}], none, chat(<<"gpt">>)),
    ?assertMatch(#{<<"type">> := <<"error">>, <<"error">> := #{<<"type">> := <<"authentication_error">>}},
                 json:decode(B2)).

models(#{key := K} = Ctx) ->
    {200, _, B} = req(Ctx, <<"GET">>, <<"/v1/models">>, [{<<"authorization">>, <<"Bearer ", K/binary>>}], <<>>),
    %% secret 路由的 access 为空列表，不可见
    #{<<"object">> := <<"list">>, <<"data">> := Data} = json:decode(B),
    ?assertEqual([<<"claude">>, <<"gpt">>, <<"mixed">>, <<"native">>], [maps:get(<<"id">>, M) || M <- Data]),
    {200, _, B2} = req(Ctx, <<"GET">>, <<"/v1/models">>,
                       [{<<"x-api-key">>, K}, {<<"anthropic-version">>, <<"2023-06-01">>}], <<>>),
    ?assertMatch(#{<<"data">> := [#{<<"type">> := <<"model">>, <<"id">> := <<"claude">>} | _],
                   <<"first_id">> := <<"claude">>, <<"last_id">> := <<"native">>, <<"has_more">> := false},
                 json:decode(B2)).

unknown_and_forbidden(#{key := K} = Ctx) ->
    {404, _, B} = post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"nope">>)),
    ?assertMatch(#{<<"error">> := #{<<"message">> := <<"The model `nope` does not exist">>}}, json:decode(B)),
    ?assertMatch({403, _, _}, post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"secret">>))).

openai_sync_with_fallback(#{key := K} = Ctx) ->
    reset_upstream(),
    lg_mock_upstream:expect({json, 503, #{}, <<"down">>}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"from backup">>)}),
    {200, H, B} = post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"gpt">>)),
    ?assertEqual(<<"application/json">>, proplists:get_value(<<"content-type">>, H)),
    ?assertMatch(#{<<"choices">> := [#{<<"message">> := #{<<"content">> := <<"from backup">>}}]},
                 json:decode(B)),
    ?assertEqual([<<"up-1">>, <<"up-2">>], upstream_models()),
    %% 主目标进入冷却：下一次直接走备用
    reset_upstream_keep_cooldown(),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"again">>)}),
    {200, _, _} = post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"gpt">>)),
    ?assertEqual([<<"up-2">>], upstream_models()).

%% 额度用尽：回退到下一个目标，整个凭证冷却到错误中写的重置时刻；成功后清除冷却
quota_cools_credential(#{key := K, c1 := C1} = Ctx) ->
    reset_upstream(),
    %% 重置时刻动态取 3 天后（reset_at 只接受 8 天以内的时刻，固定远期日期不再生效）
    {{Y, Mo, D}, {H, Mi, S}} =
        calendar:system_time_to_universal_time(lg_time:now_ms() + 3 * 86400000 + 8 * 3600000, millisecond),
    Err = iolist_to_binary(
            [<<"{\"error\":{\"code\":\"1308\",\"message\":\"已达到 5 小时的使用上限。您的限额将在 "/utf8>>,
             io_lib:format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B", [Y, Mo, D, H, Mi, S]),
             <<" 重置。\"}}"/utf8>>]),
    lg_mock_upstream:expect({json, 429, #{}, Err}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"from backup">>)}),
    {200, _, _} = post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"gpt">>)),
    ?assertEqual([<<"up-1">>, <<"up-2">>], upstream_models()),
    ?assert(lg_cooldown:cooling({C1, <<"other-model">>})),
    ?assertMatch(#{kind := quota, scope := credential}, lg_cooldown:info({C1, <<"up-1">>})),
    ?assert(lg_cooldown:remaining_ms({C1, <<"up-1">>}) > 2 * 86400000),
    ok = lg_cooldown:succeeded({C1, <<"up-1">>}),
    ?assertNot(lg_cooldown:cooling({C1, <<"other-model">>})).

%% 凭证并发上限：已满时跳到下一个目标；没有其他目标时排队，超时 429，名额释放后排队者继续
concurrency_limit(#{key := K, c1 := C1} = Ctx) ->
    reset_upstream(),
    {ok, _} = lg_credentials:update(C1, #{<<"options">> => #{<<"max_concurrency">> => 1}}),
    Self = self(),
    Holder = spawn(fun() -> Self ! {held, lg_conc:acquire(C1, 1)}, receive release -> lg_conc:release(C1) end,
                            receive stop -> ok end end),
    receive {held, ok} -> ok end,
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"from backup">>)}),
    {200, H, _} = post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"gpt">>)),
    ?assertEqual([<<"up-2">>], upstream_models()),
    %% 已满的凭证在排序时就排到了后面，直接用备用目标
    ?assertMatch(#{attempt_list := [#{ok := true, upstream_model := <<"up-2">>}]},
                 wait_log(proplists:get_value(<<"x-request-id">>, H))),
    %% 只有一个目标：排队等待，超时 429
    {ok, _} = lg_routes:create(#{<<"name">> => <<"solo">>,
                                 <<"targets">> => [#{<<"credential">> => C1, <<"upstream_model">> => <<"solo-up">>}]}),
    application:set_env(lg_core, queue_wait_ms, 100),
    {429, H2, B2} = post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"solo">>)),
    ?assertEqual(<<"1">>, proplists:get_value(<<"retry-after">>, H2)),
    ?assertMatch(#{<<"error">> := #{<<"type">> := <<"rate_limit_error">>}}, json:decode(B2)),
    #{queued_ms := Q} = wait_log(proplists:get_value(<<"x-request-id">>, H2)),
    ?assert(Q >= 100),
    %% 等待期间名额释放：排队者继续
    application:set_env(lg_core, queue_wait_ms, 5000),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"after wait">>)}),
    _ = spawn(fun() -> timer:sleep(100), Holder ! release end),
    {200, _, B3} = post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"solo">>)),
    ?assertMatch(#{<<"choices">> := [#{<<"message">> := #{<<"content">> := <<"after wait">>}}]}, json:decode(B3)),
    Holder ! stop,
    ?assertEqual(0, lg_conc:inflight(C1)),
    application:unset_env(lg_core, queue_wait_ms),
    {ok, _} = lg_credentials:update(C1, #{<<"options">> => #{<<"max_concurrency">> => null}}),
    ok = lg_routes:delete(<<"solo">>).

%% 会话粘性：回退到备用目标后，同一会话一轮之内留在备用；新的一轮没读到缓存时回到正常顺序；
%% 读到足够缓存时新的一轮也留下
session_affinity(#{key := K} = Ctx) ->
    reset_upstream(),
    lg_affinity:clear(),
    Sess = [{<<"authorization">>, <<"Bearer ", K/binary>>}, {<<"x-litegate-session">>, <<"sess-1">>}],
    Tool = #{<<"model">> => <<"gpt">>,
             <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>},
                                #{<<"role">> => <<"assistant">>, <<"content">> => null,
                                  <<"tool_calls">> => [#{<<"id">> => <<"c1">>, <<"type">> => <<"function">>,
                                                         <<"function">> => #{<<"name">> => <<"f">>, <<"arguments">> => <<"{}">>}}]},
                                #{<<"role">> => <<"tool">>, <<"tool_call_id">> => <<"c1">>, <<"content">> => <<"r">>}]},
    lg_mock_upstream:expect({json, 503, #{}, <<"down">>}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"backup">>)}),
    {200, H1, _} = post(Ctx, <<"/v1/chat/completions">>, Sess, K, chat(<<"gpt">>)),
    ?assertMatch(#{session := <<"sess-1">>, affinity := <<"miss">>}, wait_log(proplists:get_value(<<"x-request-id">>, H1))),
    lg_cooldown:clear(),
    %% 工具结果（同一轮）：留在备用目标
    reset_upstream_keep_cooldown(),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"same turn">>)}),
    {200, H2, _} = post(Ctx, <<"/v1/chat/completions">>, Sess, K, Tool),
    ?assertEqual([<<"up-2">>], upstream_models()),
    ?assertMatch(#{affinity := <<"hit">>}, wait_log(proplists:get_value(<<"x-request-id">>, H2))),
    %% 新的一轮、没读到缓存：回到主目标
    reset_upstream_keep_cooldown(),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"new turn">>)}),
    {200, H3, _} = post(Ctx, <<"/v1/chat/completions">>, Sess, K, chat(<<"gpt">>)),
    ?assertEqual([<<"up-1">>], upstream_models()),
    ?assertMatch(#{affinity := <<"broken:cache_cold">>}, wait_log(proplists:get_value(<<"x-request-id">>, H3))),
    %% 读到足够缓存后，新的一轮也留在原目标（这次是主目标，构造一次回退到备用并读到缓存）
    reset_upstream_keep_cooldown(),
    Cached = (completion(<<"cached">>))#{<<"usage">> => #{<<"prompt_tokens">> => 3000, <<"completion_tokens">> => 1,
                                                          <<"prompt_tokens_details">> => #{<<"cached_tokens">> => 2048}}},
    lg_mock_upstream:expect({json, 503, #{}, <<"down">>}),
    lg_mock_upstream:expect({json, 200, #{}, Cached}),
    {200, _, _} = post(Ctx, <<"/v1/chat/completions">>, Sess, K, chat(<<"gpt">>)),
    lg_cooldown:clear(),
    reset_upstream_keep_cooldown(),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"sticky">>)}),
    {200, _, _} = post(Ctx, <<"/v1/chat/completions">>, Sess, K, chat(<<"gpt">>)),
    ?assertEqual([<<"up-2">>], upstream_models()),
    lg_affinity:clear().

sse_chunks(Texts) ->
    [iolist_to_binary(lg_sse:encode(json:encode(#{<<"id">> => <<"c">>, <<"model">> => <<"up">>,
                                                  <<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{<<"content">> => T}}]})))
     || T <- Texts] ++ [lg_sse:done()].

%% 开流前保活：上游超过 stream_hold_ms 才回复时先发 200 与注释帧；之后全部失败以错误帧结束；开流后无数据时写注释帧
stream_hold_keepalive(#{key := K} = Ctx) ->
    reset_upstream(),
    application:set_env(lg_core, stream_hold_ms, 200),
    application:set_env(lg_core, keepalive_ms, 200),
    Stream = (chat(<<"gpt">>))#{<<"stream">> => true},
    %% 主目标 700ms 后返回 503，备用目标开流后两帧之间停 500ms
    lg_mock_upstream:expect({delay, 700, {json, 503, #{}, <<"down">>}}),
    lg_mock_upstream:expect({sse_slow, sse_chunks([<<"a">>, <<"b">>]), 500}),
    {200, H, Sse} = post(Ctx, <<"/v1/chat/completions">>, K, Stream),
    ?assertEqual(<<"text/event-stream">>, proplists:get_value(<<"content-type">>, H)),
    ?assertMatch(<<": litegate waiting\n\n", _/binary>>, Sse),
    ?assertNotEqual(nomatch, binary:match(Sse, <<": keepalive">>)),
    {Evs, _} = lg_sse:parse(Sse),
    Text = iolist_to_binary([C || #{data := D} <- Evs, D =/= <<"[DONE]">>,
                                  #{<<"choices">> := [#{<<"delta">> := #{<<"content">> := C}}]} <- [json:decode(D)]]),
    ?assertEqual(<<"ab">>, Text),
    ?assertEqual([<<"up-1">>, <<"up-2">>], upstream_models()),
    %% 已发 200 后全部失败：错误帧结束，日志记录实际错误码
    reset_upstream(),
    lg_mock_upstream:expect({delay, 400, {json, 500, #{}, <<"x">>}}),
    lg_mock_upstream:expect({json, 500, #{}, <<"y">>}),
    {200, H2, Sse2} = post(Ctx, <<"/v1/messages">>, [{<<"x-api-key">>, K}], K,
                           Stream#{<<"max_tokens">> => 10}),
    {Evs2, _} = lg_sse:parse(Sse2),
    ?assertMatch([#{event := <<"error">>}], Evs2),
    ?assertMatch(#{status := 500}, wait_log(proplists:get_value(<<"x-request-id">>, H2))),
    application:unset_env(lg_core, stream_hold_ms),
    application:unset_env(lg_core, keepalive_ms).

%% 非 API 回复：200 的 HTML 页面回退到下一个目标；流式请求收到 JSON 时，正常响应合成为 SSE，业务错误回退
non_api_replies(#{key := K} = Ctx) ->
    reset_upstream(),
    lg_mock_upstream:expect({raw, 200, <<"text/html">>, <<"<!DOCTYPE html><title>Just a moment...</title>">>}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"real">>)}),
    {200, _, B} = post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"gpt">>)),
    ?assertMatch(#{<<"choices">> := [#{<<"message">> := #{<<"content">> := <<"real">>}}]}, json:decode(B)),
    ?assertEqual([<<"up-1">>, <<"up-2">>], upstream_models()),
    %% 流式：HTML 同样回退
    reset_upstream(),
    Stream = (chat(<<"gpt">>))#{<<"stream">> => true},
    lg_mock_upstream:expect({raw, 200, <<"text/html; charset=utf-8">>, <<"<html>login</html>">>}),
    lg_mock_upstream:expect({sse, sse_chunks([<<"ok">>])}),
    {200, _, _} = post(Ctx, <<"/v1/chat/completions">>, K, Stream),
    ?assertEqual([<<"up-1">>, <<"up-2">>], upstream_models()),
    %% 流式请求收到正常 JSON：合成为 SSE（跨协议给 Anthropic 客户端）
    reset_upstream(),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"synth">>)}),
    {200, _, Sse} = post(Ctx, <<"/v1/messages">>, [{<<"x-api-key">>, K}], K, Stream#{<<"max_tokens">> => 10}),
    {Evs, _} = lg_sse:parse(Sse),
    ?assertEqual(<<"synth">>, iolist_to_binary([T || #{data := D} <- Evs,
                                                    #{<<"delta">> := #{<<"text">> := T}} <- [json:decode(D)]])),
    ?assertMatch([<<"message_start">> | _], [E || #{event := E} <- Evs]),
    %% 流式请求收到 MiniMax 业务错误（200 + base_resp）：按限流回退
    reset_upstream(),
    lg_mock_upstream:expect({json, 200, #{}, #{<<"base_resp">> => #{<<"status_code">> => 1002,
                                                                      <<"status_msg">> => <<"rate limit exceeded(RPM)">>}}}),
    lg_mock_upstream:expect({sse, sse_chunks([<<"ok">>])}),
    {200, _, _} = post(Ctx, <<"/v1/chat/completions">>, K, Stream),
    ?assertEqual([<<"up-1">>, <<"up-2">>], upstream_models()).

%% 规则路由：意图判断命中后发往规则指定的路由，同一轮沿用判定（不再调用判断模型）；
%% 不带意图的规则命中时不调用判断模型；时段跳过；判断超时照常路由
rule_routing(#{key := K, c1 := C1, c2 := C2} = Ctx) ->
    reset_upstream(),
    lg_affinity:clear(),
    T = fun(C, M) -> #{<<"credential">> => C, <<"upstream_model">> => M} end,
    {ok, _} = lg_routes:create(#{<<"name">> => <<"judge">>, <<"targets">> => [T(C2, <<"judge-up">>)]}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"strong">>, <<"targets">> => [T(C2, <<"strong-up">>)]}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"long">>, <<"targets">> => [T(C2, <<"long-up">>)]}),
    Rules = [#{<<"when">> => #{<<"min_tokens">> => 2000}, <<"use">> => <<"long">>},
             #{<<"when">> => #{<<"intent">> => <<"a quick question">>}, <<"use">> => <<"coder">>},
             #{<<"when">> => #{<<"intent">> => <<"writing or fixing tests">>}, <<"use">> => <<"strong">>}],
    {ok, _} = lg_routes:create(#{<<"name">> => <<"coder">>, <<"targets">> => [T(C1, <<"coder-up">>)],
                                 <<"options">> => #{<<"rules">> => Rules, <<"classifier">> => <<"judge">>}}),
    Sess = [{<<"authorization">>, <<"Bearer ", K/binary>>}, {<<"x-litegate-session">>, <<"rule-sess">>}],
    Ask = fun(Text) -> #{<<"model">> => <<"coder">>, <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => Text}]} end,
    %% 判断模型回答 2 → 规则 3（意图列表按规则顺序：1 quick question、2 tests）
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"2">>)}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"tests written">>)}),
    {200, H, _} = post(Ctx, <<"/v1/chat/completions">>, Sess, K, Ask(<<"给 cache.go 写单元测试"/utf8>>)),
    ?assertEqual([<<"judge-up">>, <<"strong-up">>], upstream_models()),
    [#{body := JudgeReq} | _] = lg_mock_upstream:requests(),
    #{<<"messages">> := [_, #{<<"content">> := JudgeUser}]} = JudgeReq,
    ?assertNotEqual(nomatch, binary:match(JudgeUser, <<"2. writing or fixing tests">>)),
    #{rule := 3, routed_to := <<"strong">>, intent := #{answer := 2}} = wait_log(proplists:get_value(<<"x-request-id">>, H)),
    %% 判断调用单独记日志，带 litegate:intent 标签
    {ok, #{items := [#{route := <<"judge">>} | _]}} = {ok, lg_store:logs(#{tag => <<"litegate:intent">>, limit => 1})},
    %% 同一轮（工具结果）：沿用判定，不再调用判断模型
    reset_upstream_keep_cooldown(),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"more">>)}),
    ToolTurn = (Ask(<<"给 cache.go 写单元测试"/utf8>>))#{<<"messages">> => [
        #{<<"role">> => <<"user">>, <<"content">> => <<"给 cache.go 写单元测试"/utf8>>},
        #{<<"role">> => <<"assistant">>, <<"content">> => null,
          <<"tool_calls">> => [#{<<"id">> => <<"c1">>, <<"type">> => <<"function">>,
                                 <<"function">> => #{<<"name">> => <<"f">>, <<"arguments">> => <<"{}">>}}]},
        #{<<"role">> => <<"tool">>, <<"tool_call_id">> => <<"c1">>, <<"content">> => <<"r">>}]},
    {200, _, _} = post(Ctx, <<"/v1/chat/completions">>, Sess, K, ToolTurn),
    ?assertEqual([<<"strong-up">>], upstream_models()),
    %% 长上下文：第 1 条规则（不带意图）命中，不调用判断模型
    reset_upstream_keep_cooldown(),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"long">>)}),
    {200, _, _} = post(Ctx, <<"/v1/chat/completions">>, K, Ask(binary:copy(<<"word ">>, 3000))),
    ?assertEqual([<<"long-up">>], upstream_models()),
    %% 判断模型回答 0：没有规则命中，按路由本身
    reset_upstream_keep_cooldown(),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"0">>)}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"plain">>)}),
    {200, H4, _} = post(Ctx, <<"/v1/chat/completions">>, K, Ask(<<"随便聊聊"/utf8>>)),
    ?assertEqual([<<"judge-up">>, <<"coder-up">>], upstream_models()),
    ?assertMatch(#{rule := 0, intent := #{answer := 0}}, wait_log(proplists:get_value(<<"x-request-id">>, H4))),
    %% 同一消息的判断结果缓存 10 分钟
    reset_upstream_keep_cooldown(),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"plain">>)}),
    {200, _, _} = post(Ctx, <<"/v1/chat/completions">>, K, Ask(<<"随便聊聊"/utf8>>)),
    ?assertEqual([<<"coder-up">>], upstream_models()),
    %% 判断超时：照常路由
    reset_upstream_keep_cooldown(),
    application:set_env(lg_core, intent_timeout_ms, 100),
    lg_mock_upstream:expect({delay, 400, {json, 200, #{}, completion(<<"1">>)}}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"plain">>)}),
    {200, H5, _} = post(Ctx, <<"/v1/chat/completions">>, K, Ask(<<"另一个问题"/utf8>>)),
    ?assertMatch(#{intent := #{error := <<"timeout">>}}, wait_log(proplists:get_value(<<"x-request-id">>, H5))),
    application:unset_env(lg_core, intent_timeout_ms),
    timer:sleep(400),
    %% 时段跳过：全天跳过主凭证 → 用备用（这里改为直接跳过 C1，路由只剩回退前的空列表时仍按原顺序）
    {ok, _} = lg_routes:update(<<"coder">>, #{<<"targets">> => [T(C1, <<"coder-up">>), T(C2, <<"coder-backup">>)],
                                              <<"options">> => #{<<"rules">> => [#{<<"when">> => #{<<"hours">> => <<"00:00-24:00">>},
                                                                                   <<"skip">> => [C1]}]}}),
    reset_upstream_keep_cooldown(),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"skipped">>)}),
    {200, _, _} = post(Ctx, <<"/v1/chat/completions">>, K, Ask(<<"x">>)),
    ?assertEqual([<<"coder-backup">>], upstream_models()),
    [ok = lg_routes:delete(N) || N <- [<<"coder">>, <<"judge">>, <<"strong">>, <<"long">>]],
    lg_affinity:clear().

%% 链路导出：父 span + 每次尝试一个子 span（含失败的），接入客户端 traceparent，成功的尝试带用量与费用
otlp_export(#{key := K, base := Base} = Ctx) ->
    reset_upstream(),
    Collector = binary:part(Base, 0, byte_size(Base) - 3),
    application:set_env(lg_core, otlp_enabled, true),
    application:set_env(lg_core, otlp_endpoint, Collector),
    application:set_env(lg_core, otlp_headers, <<"Authorization=Basic%20dGVzdA==">>),
    lg_mock_upstream:expect({json, 503, #{}, <<"down">>}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"traced">>)}),
    TP = <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>,
    {200, H, _} = post(Ctx, <<"/v1/chat/completions">>,
                       [{<<"authorization">>, <<"Bearer ", K/binary>>}, {<<"traceparent">>, TP},
                        {<<"x-litegate-session">>, <<"otlp-sess">>}], K, chat(<<"gpt">>)),
    _ = wait_log(proplists:get_value(<<"x-request-id">>, H)),
    lg_mock_upstream:expect({json, 200, #{}, #{}}),
    ok = lg_otlp:flush(),
    [#{path := <<"/v1/traces">>, headers := TH, body := Export}] =
        [R || #{path := <<"/v1/traces">>} = R <- lg_mock_upstream:requests()],
    ?assertEqual(<<"Basic dGVzdA==">>, maps:get(<<"authorization">>, TH)),
    #{<<"resourceSpans">> := [#{<<"scopeSpans">> := [#{<<"spans">> := Spans}]}]} = Export,
    [Root, Failed, Ok] = Spans,
    Attr = fun(S, Key) -> hd([V || #{<<"key">> := K2, <<"value">> := V} <- maps:get(<<"attributes">>, S), K2 =:= Key] ++ [none]) end,
    ?assertMatch(#{<<"name">> := <<"litegate.request">>, <<"traceId">> := <<"4bf92f3577b34da6a3ce929d0e0e4736">>,
                   <<"parentSpanId">> := <<"00f067aa0ba902b7">>}, Root),
    ?assertEqual(#{<<"stringValue">> => <<"otlp-sess">>}, Attr(Root, <<"langfuse.session.id">>)),
    ?assertEqual(#{<<"stringValue">> => <<"all">>}, Attr(Root, <<"langfuse.user.id">>)),
    RootId = maps:get(<<"spanId">>, Root),
    ?assertMatch(#{<<"name">> := <<"litegate.attempt">>, <<"parentSpanId">> := RootId,
                   <<"status">> := #{<<"code">> := 2}}, Failed),
    ?assertEqual(#{<<"stringValue">> => <<"up-1">>}, Attr(Failed, <<"gen_ai.response.model">>)),
    ?assertEqual(none, Attr(Failed, <<"gen_ai.usage.input_tokens">>)),
    ?assertMatch(#{<<"status">> := #{<<"code">> := 1}}, Ok),
    ?assertEqual(#{<<"intValue">> => <<"1">>}, Attr(Ok, <<"gen_ai.usage.input_tokens">>)),
    %% 路由目标没有计费参考（价格未知）：不发费用，由 Langfuse 自行计价
    ?assertEqual(none, Attr(Ok, <<"langfuse.observation.cost_details">>)),
    %% 默认不带内容
    ?assertEqual(none, Attr(Root, <<"langfuse.trace.input">>)),
    [application:unset_env(lg_core, X) || X <- [otlp_enabled, otlp_endpoint, otlp_headers]].

%% 本地意图判断（intent_engine = laya）：问 laya_url/v1/systemone；概率不足视为不命中；
%% Laya 失败时改问 classifier 路由（日志带 local_error），没有后备时照常路由
laya_intent(#{key := K, c1 := C1, c2 := C2, base := Base} = Ctx) ->
    reset_upstream(),
    lg_affinity:clear(),
    application:set_env(lg_core, laya_url, binary:part(Base, 0, byte_size(Base) - 3)),
    T = fun(C, M) -> #{<<"credential">> => C, <<"upstream_model">> => M} end,
    {ok, _} = lg_routes:create(#{<<"name">> => <<"l-judge">>, <<"targets">> => [T(C2, <<"judge-up">>)]}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"l-pretty">>, <<"targets">> => [T(C2, <<"pretty-up">>)]}),
    Rules = [#{<<"when">> => #{<<"intent">> => <<"美化：改进界面样式"/utf8>>}, <<"use">> => <<"l-pretty">>},
             #{<<"when">> => #{<<"intent">> => <<"读取文件：只读不修改"/utf8>>}, <<"use">> => <<"l-judge">>}],
    {ok, _} = lg_routes:create(#{<<"name">> => <<"l-main">>, <<"targets">> => [T(C1, <<"main-up">>)],
                                 <<"options">> => #{<<"rules">> => Rules, <<"intent_engine">> => <<"laya">>,
                                                    <<"classifier">> => <<"l-judge">>}}),
    Ask = fun(Text) -> #{<<"model">> => <<"l-main">>, <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => Text}]} end,
    Laya = fun(P1, P2) -> #{<<"answers">> => #{<<"i1">> => #{<<"type">> => <<"noul">>, <<"noul">> => P1},
                                                 <<"i2">> => #{<<"type">> => <<"noul">>, <<"noul">> => P2}}} end,
    Paths = fun() -> [P || #{path := P} <- lg_mock_upstream:requests()] end,
    %% 命中：每条意图一道 noul（i1、i2），取最高且不低于阈值的
    lg_mock_upstream:expect({json, 200, #{}, Laya(0.93, 0.1)}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"pretty">>)}),
    {200, H1, _} = post(Ctx, <<"/v1/chat/completions">>, K, Ask(<<"按钮配色调好看一点"/utf8>>)),
    ?assertEqual([<<"/v1/systemone">>, <<"/v1/chat/completions">>], Paths()),
    [#{body := #{<<"state">> := #{<<"message">> := <<"按钮配色调好看一点"/utf8>>},
                 <<"questions">> := Qs}} | _] = lg_mock_upstream:requests(),
    ?assertEqual([<<"i1">>, <<"i2">>], lists:sort(maps:keys(Qs))),
    ?assertMatch(#{rule := 1, routed_to := <<"l-pretty">>, intent := #{answer := 1, classifier := <<"laya">>}},
                 wait_log(proplists:get_value(<<"x-request-id">>, H1))),
    %% 概率不足：不命中，按路由本身
    reset_upstream_keep_cooldown(),
    lg_mock_upstream:expect({json, 200, #{}, Laya(0.2, 0.5)}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"main">>)}),
    {200, H2, _} = post(Ctx, <<"/v1/chat/completions">>, K, Ask(<<"你好"/utf8>>)),
    ?assertEqual([<<"/v1/systemone">>, <<"/v1/chat/completions">>], Paths()),
    ?assertMatch([_, #{body := #{<<"model">> := <<"main-up">>}}], lg_mock_upstream:requests()),
    ?assertMatch(#{rule := 0, intent := #{answer := 0}}, wait_log(proplists:get_value(<<"x-request-id">>, H2))),
    %% Laya 出错：改问后备判断路由（回答 2 → 读取文件 → l-judge）
    reset_upstream_keep_cooldown(),
    lg_mock_upstream:expect({json, 500, #{}, #{<<"error">> => #{<<"message">> => <<"boom">>}}}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"2">>)}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"read">>)}),
    {200, H3, _} = post(Ctx, <<"/v1/chat/completions">>, K, Ask(<<"看看 main.go 做什么"/utf8>>)),
    ?assertEqual([<<"/v1/systemone">>, <<"/v1/chat/completions">>, <<"/v1/chat/completions">>], Paths()),
    L3 = wait_log(proplists:get_value(<<"x-request-id">>, H3)),
    ?assertMatch(#{rule := 2, intent := #{answer := 2, classifier := <<"l-judge">>, local_error := <<"HTTP 500", _/binary>>}}, L3),
    ?assertMatch([_ | _], [T0 || #{text := T0} <- lg_narrate:lines(L3), binary:match(T0, <<"本地 Laya 判断失败"/utf8>>) =/= nomatch]),
    %% 全局关闭 laya_enabled：不问 Laya，直接问后备判断路由（回答 1 → 美化 → l-pretty）
    application:set_env(lg_core, laya_enabled, false),
    reset_upstream_keep_cooldown(),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"1">>)}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"pretty">>)}),
    {200, H35, _} = post(Ctx, <<"/v1/chat/completions">>, K, Ask(<<"配色再好看点"/utf8>>)),
    ?assertEqual([<<"/v1/chat/completions">>, <<"/v1/chat/completions">>], Paths()),
    ?assertMatch(#{rule := 1, intent := #{answer := 1, classifier := <<"l-judge">>}},
                 wait_log(proplists:get_value(<<"x-request-id">>, H35))),
    application:unset_env(lg_core, laya_enabled),
    %% 没有后备判断路由：Laya 出错照常路由
    {ok, _} = lg_routes:update(<<"l-main">>, #{<<"options">> => #{<<"classifier">> => null}}),
    reset_upstream_keep_cooldown(),
    lg_mock_upstream:expect({json, 500, #{}, #{<<"error">> => #{<<"message">> => <<"boom">>}}}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"main">>)}),
    {200, H4, _} = post(Ctx, <<"/v1/chat/completions">>, K, Ask(<<"又一个问题"/utf8>>)),
    ?assertMatch(#{intent := #{error := <<"HTTP 500", _/binary>>, classifier := <<"laya">>}},
                 wait_log(proplists:get_value(<<"x-request-id">>, H4))),
    %% 同一消息的判断结果缓存：不再问 Laya
    reset_upstream_keep_cooldown(),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"pretty">>)}),
    {200, _, _} = post(Ctx, <<"/v1/chat/completions">>, K, Ask(<<"按钮配色调好看一点"/utf8>>)),
    ?assertEqual([<<"/v1/chat/completions">>], Paths()),
    application:unset_env(lg_core, laya_url).

reset_upstream_keep_cooldown() ->
    ets:insert(lg_mock_upstream, {requests, []}).

client_error_not_retried(#{key := K} = Ctx) ->
    reset_upstream(),
    Err = json:encode(#{<<"error">> => #{<<"message">> => <<"bad param">>, <<"type">> => <<"invalid_request_error">>,
                                         <<"param">> => <<"temperature">>}}),
    lg_mock_upstream:expect({json, 400, #{}, Err}),
    {400, _, B} = post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"gpt">>)),
    %% 同协议：上游错误体原样返回
    ?assertEqual(iolist_to_binary(Err), B),
    ?assertEqual([<<"up-1">>], upstream_models()).

anthropic_client_stream_to_openai(#{key := K} = Ctx) ->
    reset_upstream(),
    Frames = [iolist_to_binary(lg_sse:encode(json:encode(C))) || C <-
                 [#{<<"id">> => <<"c">>, <<"model">> => <<"up-1">>,
                    <<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{<<"content">> => <<"Hel">>}}]},
                  #{<<"id">> => <<"c">>, <<"model">> => <<"up-1">>,
                    <<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{<<"content">> => <<"lo">>},
                                        <<"finish_reason">> => <<"stop">>}]},
                  #{<<"choices">> => [], <<"usage">> => #{<<"prompt_tokens">> => 3,
                                                          <<"completion_tokens">> => 2}}]]
             ++ [lg_sse:done()],
    lg_mock_upstream:expect({sse_slow, Frames, 10}),
    Body = #{<<"model">> => <<"gpt">>, <<"max_tokens">> => 20, <<"stream">> => true,
             <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]},
    {200, H, Sse} = post(Ctx, <<"/v1/messages">>, [{<<"x-api-key">>, K}], K, Body),
    ?assertEqual(<<"text/event-stream">>, proplists:get_value(<<"content-type">>, H)),
    {Evs, <<>>} = lg_sse:parse(Sse),
    ?assertEqual([<<"message_start">>, <<"content_block_start">>, <<"content_block_delta">>,
                  <<"content_block_delta">>, <<"content_block_stop">>, <<"message_delta">>,
                  <<"message_stop">>], [T || #{event := T} <- Evs]),
    Text = iolist_to_binary([T || #{data := D} <- Evs,
                                  #{<<"delta">> := #{<<"text">> := T}} <- [json:decode(D)]]),
    ?assertEqual(<<"Hello">>, Text),
    %% TTFT：首个内容在第 1 帧之后（模拟上游每帧间隔 10ms），不超过总耗时
    #{ttft_ms := Ttft, duration_ms := Dur} = wait_log(proplists:get_value(<<"x-request-id">>, H)),
    ?assert(is_integer(Ttft) andalso Ttft =< Dur).

openai_stream_upstream_fails_before_open(#{key := K} = Ctx) ->
    reset_upstream(),
    lg_mock_upstream:expect({json, 500, #{}, <<"x">>}),
    lg_mock_upstream:expect({json, 500, #{}, <<"y">>}),
    {Status, _, B} = post(Ctx, <<"/v1/chat/completions">>, K, (chat(<<"gpt">>))#{<<"stream">> => true}),
    %% 开流前全部失败：返回普通 JSON 错误而不是 200 + SSE
    ?assertEqual(500, Status),
    ?assertMatch(#{<<"error">> := #{<<"type">> := <<"api_error">>}}, json:decode(B)),
    ?assertEqual(2, length(upstream_models())).

max_tokens_clamped(#{capped := K} = Ctx) ->
    reset_upstream(),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"x">>)}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"x">>)}),
    {200, _, _} = post(Ctx, <<"/v1/chat/completions">>, K, (chat(<<"gpt">>))#{<<"max_tokens">> => 999}),
    {200, _, _} = post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"gpt">>)),
    ?assertEqual([50, 50], [maps:get(<<"max_tokens">>, B) || #{body := B} <- lg_mock_upstream:requests()]).

bad_requests(#{key := K} = Ctx) ->
    Auth = [{<<"authorization">>, <<"Bearer ", K/binary>>}],
    ?assertMatch({400, _, _}, req(Ctx, <<"POST">>, <<"/v1/chat/completions">>, Auth, <<"not json">>)),
    ?assertMatch({400, _, _}, post(Ctx, <<"/v1/chat/completions">>, K, #{<<"messages">> => []})),
    ?assertMatch({405, _, _}, req(Ctx, <<"GET">>, <<"/v1/chat/completions">>, Auth, <<>>)).

wait_log(Id) -> wait_log(Id, 50).
wait_log(Id, 0) -> error({log_not_found, Id});
wait_log(Id, N) ->
    lg_store:flush(),
    case lg_store:log(Id) of
        {ok, L} -> L;
        not_found -> timer:sleep(20), wait_log(Id, N - 1)
    end.

recorded(#{key := K} = Ctx) ->
    reset_upstream(),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"logged reply">>)}),
    {200, H, _} = post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"gpt">>)),
    Id = proplists:get_value(<<"x-request-id">>, H),
    ?assertMatch(#{status := 200, route := <<"gpt">>, upstream_model := <<"up-1">>, stream := false,
                   format := openai, attempts := 1, usage := #{input := 1, output := 1}},
                 wait_log(Id)),
    ?assertMatch({ok, #{response := <<"logged reply">>,
                        request := #{<<"messages">> := [#{<<"content">> := <<"hi">>}]}}},
                 lg_store:messages(Id)),
    %% 失败请求同样记录，带状态码与错误类型
    {404, H2, _} = post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"nope">>)),
    ?assertMatch(#{status := 404, error := #{kind := route_not_found}},
                 wait_log(proplists:get_value(<<"x-request-id">>, H2))).

client_disconnect_recorded(#{key := K, port := Port}) ->
    reset_upstream(),
    Frame = fun(T) -> iolist_to_binary(lg_sse:encode(json:encode(
                        #{<<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{<<"content">> => T}}]}))) end,
    lg_mock_upstream:expect({sse_slow, [Frame(<<"par">>), Frame(<<"tial">>), Frame(<<"never">>)], 300}),
    {ok, Conn} = gun:open("127.0.0.1", Port, #{retry => 0}),
    {ok, _} = gun:await_up(Conn, 5000),
    Ref = gun:post(Conn, <<"/v1/chat/completions">>,
                   [{<<"content-type">>, <<"application/json">>},
                    {<<"authorization">>, <<"Bearer ", K/binary>>}],
                   json:encode((chat(<<"gpt">>))#{<<"stream">> => true})),
    {response, nofin, 200, H} = gun:await(Conn, Ref, 5000),
    {data, nofin, _} = gun:await(Conn, Ref, 5000),
    gun:close(Conn),
    L = wait_log(proplists:get_value(<<"x-request-id">>, H)),
    ?assertMatch(#{client_aborted := true, stream := true}, L),
    {ok, #{response := Text}} = lg_store:messages(maps:get(id, L)),
    ?assertNotEqual(nomatch, binary:match(Text, <<"par">>)),
    ?assertEqual(nomatch, binary:match(Text, <<"never">>)).

rate_limited(#{key := K} = Ctx) ->
    reset_upstream(),
    {ok, _} = lg_limits:set_limit({route, <<"gpt">>}, #{<<"rpm">> => 1}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"ok">>)}),
    {200, _, _} = post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"gpt">>)),
    {429, H, B} = post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"gpt">>)),
    ?assertMatch(#{<<"error">> := #{<<"type">> := <<"rate_limit_error">>}}, json:decode(B)),
    Retry = binary_to_integer(proplists:get_value(<<"retry-after">>, H)),
    ?assert(Retry >= 1 andalso Retry =< 60),
    %% Anthropic 格式
    {429, _, B2} = post(Ctx, <<"/v1/messages">>, [{<<"x-api-key">>, K}], K,
                        #{<<"model">> => <<"gpt">>, <<"max_tokens">> => 5,
                          <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"x">>}]}),
    ?assertMatch(#{<<"type">> := <<"error">>, <<"error">> := #{<<"type">> := <<"rate_limit_error">>}},
                 json:decode(B2)),
    %% 被拒的请求不打到上游，但会记日志
    ?assertEqual(1, length(upstream_models())),
    #{items := [L | _]} = lg_store:logs(#{errors_only => true, limit => 1}),
    ?assertMatch(#{status := 429, error := #{kind := rate_limited}}, L),
    ok = lg_limits:delete_limit({route, <<"gpt">>}).

budget_exceeded(#{capped := K} = Ctx) ->
    reset_upstream(),
    {ok, #lg_api_key{id = KId}} = lg_api_keys:authenticate(K),
    {ok, _} = lg_limits:set_budget({key, KId}, #{<<"period">> => <<"day">>, <<"max_usd">> => 0}),
    {429, H, B} = post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"gpt">>)),
    ?assertMatch(#{<<"error">> := #{<<"type">> := <<"insufficient_quota">>}}, json:decode(B)),
    ?assert(binary_to_integer(proplists:get_value(<<"retry-after">>, H)) =< 86400),
    ?assertEqual([], upstream_models()),
    {ok, deleted} = lg_limits:set_budget({key, KId}, #{<<"max_usd">> => null}).

parallel_limit(#{key := K} = Ctx) ->
    reset_upstream(),
    {ok, #lg_api_key{id = KId}} = lg_api_keys:authenticate(K),
    {ok, _} = lg_limits:set_limit({key_route, KId, <<"gpt">>}, #{<<"max_parallel">> => 1}),
    Frame = iolist_to_binary(lg_sse:encode(json:encode(
              #{<<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{<<"content">> => <<"x">>}}]}))),
    lg_mock_upstream:expect({sse_slow, [Frame, Frame, lg_sse:done()], 200}),
    Parent = self(),
    spawn(fun() -> Parent ! {first, post(Ctx, <<"/v1/chat/completions">>, K,
                                         (chat(<<"gpt">>))#{<<"stream">> => true})} end),
    wait_until(fun() -> lg_limiter:parallel({key_route, KId, <<"gpt">>}) =:= 1 end),
    ?assertMatch({429, _, _}, post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"gpt">>))),
    receive {first, R} -> ?assertMatch({200, _, _}, R) after 5000 -> error(timeout) end,
    %% 流结束后归还槽位
    wait_until(fun() -> lg_limiter:parallel({key_route, KId, <<"gpt">>}) =:= 0 end),
    ok = lg_limits:delete_limit({key_route, KId, <<"gpt">>}).

wait_until(F) -> wait_until(F, 100).
wait_until(F, 0) -> ?assert(F());
wait_until(F, N) ->
    case F() of
        true -> ok;
        false -> timer:sleep(10), wait_until(F, N - 1)
    end.

embeddings(#{key := K} = Ctx) ->
    reset_upstream(),
    Resp = #{<<"object">> => <<"list">>, <<"data">> => [#{<<"embedding">> => [0.5]}],
             <<"usage">> => #{<<"prompt_tokens">> => 4, <<"total_tokens">> => 4}},
    lg_mock_upstream:expect({json, 200, #{}, Resp}),
    %% mixed 路由：跳过 anthropic 目标，只用 openai 目标
    {200, H, B} = post(Ctx, <<"/v1/embeddings">>, K, #{<<"model">> => <<"mixed">>, <<"input">> => <<"hi">>}),
    ?assertMatch(#{<<"data">> := [#{<<"embedding">> := [0.5]}]}, json:decode(B)),
    ?assertEqual([<<"emb-up">>], upstream_models()),
    #{path := Path} = lists:last(lg_mock_upstream:requests()),
    ?assertEqual(<<"/v1/embeddings">>, Path),
    Id = proplists:get_value(<<"x-request-id">>, H),
    ?assertMatch(#{format := embeddings, status := 200, usage := #{input := 4}}, wait_log(Id)),
    ?assertEqual(not_found, lg_store:messages(Id)),
    %% 只有 anthropic 目标：400
    {400, _, B2} = post(Ctx, <<"/v1/embeddings">>, K, #{<<"model">> => <<"claude">>, <<"input">> => <<"hi">>}),
    ?assertMatch(#{<<"error">> := #{<<"message">> := <<"Model `claude` does not support embeddings">>}},
                 json:decode(B2)).

%% 订阅套餐凭证：实际费用记 0、另记等价花费；额度用尽时 429 + Retry-After
plan_accounting(#{key := K} = Ctx) ->
    reset_upstream(),
    #{credential := C} = hd((element(2, lg_routes:get(<<"gpt">>)))#lg_route.targets),
    ok = lg_catalog:put_overlay({<<"subprov">>, <<"sub-m">>},
                                #{<<"name">> => <<"Sub">>, <<"cost">> => #{<<"input">> => 1000000, <<"output">> => 2000000}}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"subbed">>,
                                 <<"targets">> => [#{<<"credential">> => C, <<"upstream_model">> => <<"sub-m">>,
                                                     <<"model_ref">> => [<<"subprov">>, <<"sub-m">>]}]}),
    {ok, Cred} = lg_credentials:get(C),
    %% 直接写入套餐配置与额度状态，避免触发对模拟上游的额度查询
    ok = lg_db:write(Cred#lg_credential{options = #{plan => #{<<"kind">> => <<"glm">>}}}),
    Status = fun(Used, Reset) ->
                     ets:insert(lg_plan_status,
                                {C, #{kind => <<"glm">>, reserve_pct => 0, level => null, error => null,
                                      fetched_at => lg_time:now_ms(), checked_at => lg_time:now_ms(),
                                      windows => [#{name => <<"5h">>, used_pct => Used, resets_at => Reset}]}})
             end,
    Status(10, lg_time:now_ms() + 3600000),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"on plan">>)}),
    Req = #{<<"model">> => <<"subbed">>, <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]},
    {200, H1, _} = post(Ctx, <<"/v1/chat/completions">>, K, Req),
    ?assertMatch(#{plan := true, cost := +0.0, plan_usd := 3.0},
                 wait_log(proplists:get_value(<<"x-request-id">>, H1))),
    [Row] = lg_store:usage(#{from => lg_time:now_ms() - 3600000, to => lg_time:now_ms() + 1000,
                             route => <<"subbed">>, group_by => [route]}),
    ?assertMatch(#{plan_requests := 1, plan_usd := 3.0, cost := +0.0}, Row),
    %% 额度用尽：不访问上游
    Reset = lg_time:now_ms() + 120000,
    Status(100, Reset),
    {429, H2, B2} = post(Ctx, <<"/v1/chat/completions">>, K, Req),
    ?assertMatch(#{<<"error">> := #{<<"type">> := <<"insufficient_quota">>}}, json:decode(B2)),
    RA = binary_to_integer(proplists:get_value(<<"retry-after">>, H2)),
    ?assert(RA > 100 andalso RA =< 120),
    ?assertMatch(#{status := 429, error := #{kind := plan_exhausted}},
                 wait_log(proplists:get_value(<<"x-request-id">>, H2))),
    ?assertEqual(1, length(upstream_models())),
    ok = lg_db:write(Cred),
    ets:delete(lg_plan_status, C),
    ok = lg_routes:delete(<<"subbed">>).

%% think_tags = split：上游 content 里的 <think> 拆到 reasoning_content / thinking 块
think_tags_split(#{key := K} = Ctx) ->
    reset_upstream(),
    #{credential := C} = hd((element(2, lg_routes:get(<<"gpt">>)))#lg_route.targets),
    {ok, _} = lg_credentials:update(C, #{<<"options">> => #{<<"think_tags">> => <<"split">>,
                                                            <<"extra_body">> => #{<<"reasoning_split">> => false}}}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"thinker">>,
                                 <<"targets">> => [#{<<"credential">> => C, <<"upstream_model">> => <<"t-up">>}]}),
    Req = #{<<"model">> => <<"thinker">>, <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]},
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"<think>plan</think>\n\nhello">>)}),
    {200, _, B1} = post(Ctx, <<"/v1/chat/completions">>, K, Req),
    ?assertMatch(#{<<"choices">> := [#{<<"message">> := #{<<"content">> := <<"hello">>,
                                                          <<"reasoning_content">> := <<"plan">>}}]}, json:decode(B1)),
    #{body := UpBody} = lists:last(lg_mock_upstream:requests()),
    ?assertMatch(#{<<"reasoning_split">> := false, <<"model">> := <<"t-up">>}, UpBody),
    Frames = fun() ->
                     [iolist_to_binary(lg_sse:encode(json:encode(
                        #{<<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{<<"content">> => T},
                                              <<"finish_reason">> => F}]}))) || {T, F} <- [{<<"<thi">>, null},
                                                                                            {<<"nk>pl">>, null},
                                                                                            {<<"an</think>\n">>, null},
                                                                                            {<<"hel">>, null},
                                                                                            {<<"lo">>, <<"stop">>}]]
                         ++ [lg_sse:done()]
             end,
    %% OpenAI 客户端流式
    lg_mock_upstream:expect({sse, Frames()}),
    {200, _, S1} = post(Ctx, <<"/v1/chat/completions">>, K, Req#{<<"stream">> => true}),
    {Evs1, _} = lg_sse:parse(S1),
    Deltas = [D || #{data := Dt} <- Evs1, Dt =/= <<"[DONE]">>,
                   #{<<"choices">> := [#{<<"delta">> := D} | _]} <- [json:decode(Dt)]],
    ?assertEqual(<<"plan">>, iolist_to_binary([V || #{<<"reasoning_content">> := V} <- Deltas])),
    ?assertEqual(<<"hello">>, iolist_to_binary([V || #{<<"content">> := V} <- Deltas])),
    %% Anthropic 客户端流式：thinking 块 + text 块
    lg_mock_upstream:expect({sse, Frames()}),
    {200, _, S2} = post(Ctx, <<"/v1/messages">>, K, Req#{<<"stream">> => true, <<"max_tokens">> => 100}),
    {Evs2, _} = lg_sse:parse(S2),
    Starts = [T || #{event := <<"content_block_start">>, data := D} <- Evs2,
                   #{<<"content_block">> := #{<<"type">> := T}} <- [json:decode(D)]],
    ?assertEqual([<<"thinking">>, <<"text">>], Starts),
    Text = iolist_to_binary([T || #{event := <<"content_block_delta">>, data := D} <- Evs2,
                                  #{<<"delta">> := #{<<"text">> := T}} <- [json:decode(D)]]),
    ?assertEqual(<<"hello">>, Text),
    {ok, _} = lg_credentials:update(C, #{<<"options">> => #{<<"think_tags">> => null, <<"extra_body">> => null}}),
    ok = lg_routes:delete(<<"thinker">>).

%% Playground：控制台身份、不受路由访问列表约束，响应头带命中的上游，日志 source = playground
playground(Ctx) ->
    reset_upstream(),
    Req = #{<<"model">> => <<"secret">>, <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]},
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"from playground">>)}),
    {200, H, B} = post(Ctx, <<"/api/playground/chat">>, [], undefined, Req),
    ?assertMatch(#{<<"choices">> := [#{<<"message">> := #{<<"content">> := <<"from playground">>}}]}, json:decode(B)),
    ?assertEqual(<<"primary%20%2F%20s">>, proplists:get_value(<<"x-litegate-target">>, H)),
    ?assertEqual(<<"1">>, proplists:get_value(<<"x-litegate-attempts">>, H)),
    ?assertMatch(#{key_id := <<"playground">>, source := playground, user_id := <<"local">>},
                 wait_log(proplists:get_value(<<"x-request-id">>, H))),
    %% 流式（Anthropic 格式）
    lg_mock_upstream:expect({sse, [iolist_to_binary(lg_sse:encode(json:encode(
                                     #{<<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{<<"content">> => <<"s">>},
                                                           <<"finish_reason">> => <<"stop">>}]}))), lg_sse:done()]}),
    {200, H2, S2} = post(Ctx, <<"/api/playground/messages">>, [], undefined,
                         Req#{<<"stream">> => true, <<"max_tokens">> => 10}),
    ?assertNotEqual(undefined, proplists:get_value(<<"x-litegate-target">>, H2)),
    ?assertMatch({[#{event := <<"message_start">>} | _], _}, lg_sse:parse(S2)),
    %% 失败也带尝试次数；未知模型
    {404, H3, _} = post(Ctx, <<"/api/playground/responses">>, [], undefined, Req#{<<"model">> => <<"nope">>}),
    ?assertEqual(<<"0">>, proplists:get_value(<<"x-litegate-attempts">>, H3)),
    %% 开启控制台登录后需要会话
    ok = lg_config:set(console_auth, true),
    {401, _, _} = post(Ctx, <<"/api/playground/chat">>, [], undefined, Req),
    ok = lg_config:unset(console_auth).

%% Anthropic 兼容上游不认识客户端的 anthropic-beta：去掉后重试一次
anthropic_beta_retry(#{key := K} = Ctx) ->
    reset_upstream(),
    Msg = #{<<"id">> => <<"msg_1">>, <<"type">> => <<"message">>, <<"role">> => <<"assistant">>,
            <<"model">> => <<"claude-up">>, <<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"ok">>}],
            <<"stop_reason">> => <<"end_turn">>, <<"usage">> => #{<<"input_tokens">> => 3, <<"output_tokens">> => 1}},
    lg_mock_upstream:expect({json, 400, #{}, #{<<"type">> => <<"error">>,
                                               <<"error">> => #{<<"type">> => <<"invalid_request_error">>,
                                                                <<"message">> => <<"Unexpected value(s) `new-beta-2099` for the `anthropic-beta` header">>}}}),
    lg_mock_upstream:expect({json, 200, #{}, Msg}),
    Req = #{<<"model">> => <<"claude">>, <<"max_tokens">> => 10,
            <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]},
    {200, _, B} = post(Ctx, <<"/v1/messages">>,
                       [{<<"x-api-key">>, K}, {<<"anthropic-beta">>, <<"new-beta-2099">>}], K, Req),
    ?assertMatch(#{<<"content">> := [#{<<"text">> := <<"ok">>}]}, json:decode(B)),
    [#{headers := H1}, #{headers := H2}] = lg_mock_upstream:requests(),
    ?assertEqual(<<"new-beta-2099">>, maps:get(<<"anthropic-beta">>, H1)),
    ?assertNot(maps:is_key(<<"anthropic-beta">>, H2)),
    %% 与 beta 无关的 400 不重试
    reset_upstream(),
    lg_mock_upstream:expect({json, 400, #{}, #{<<"type">> => <<"error">>,
                                               <<"error">> => #{<<"type">> => <<"invalid_request_error">>,
                                                                <<"message">> => <<"max_tokens too large">>}}}),
    {400, _, _} = post(Ctx, <<"/v1/messages">>, [{<<"x-api-key">>, K}, {<<"anthropic-beta">>, <<"x">>}], K, Req),
    ?assertEqual(1, length(lg_mock_upstream:requests())).

%% 请求标签：请求头 + metadata.tags + Key 默认标签；日志、按标签用量、标签预算
request_tags(Ctx) ->
    reset_upstream(),
    {ok, K, #lg_api_key{id = KeyId}} = lg_api_keys:create(#{<<"name">> => <<"tagged">>, <<"tags">> => [<<"tool:cli">>]}),
    Req = #{<<"model">> => <<"gpt">>, <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
            <<"metadata">> => #{<<"tags">> => <<"proj:a,bad tag">>}},
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"ok">>)}),
    {200, H, _} = post(Ctx, <<"/v1/chat/completions">>,
                       [{<<"authorization">>, <<"Bearer ", K/binary>>}, {<<"x-litegate-tags">>, <<"team:x">>}], K, Req),
    ?assertMatch(#{tags := [<<"team:x">>, <<"proj:a">>, <<"tool:cli">>], key_id := KeyId},
                 wait_log(proplists:get_value(<<"x-request-id">>, H))),
    %% metadata.tags 不转发给上游（metadata 只有 tags 时整个去掉）
    #{body := UpBody} = lists:last(lg_mock_upstream:requests()),
    ?assertNot(maps:is_key(<<"metadata">>, UpBody)),
    %% 按标签筛选日志、按标签汇总用量
    #{items := [#{id := _}]} = lg_store:logs(#{tag => <<"proj:a">>, limit => 10}),
    Rows = lg_store:usage(#{from => lg_time:now_ms() - 3600000, to => lg_time:now_ms() + 1000, group_by => [tag]}),
    ?assertEqual([<<"proj:a">>, <<"team:x">>, <<"tool:cli">>],
                 lists:sort([T || #{tag := T, requests := 1} <- Rows, lists:member(T, [<<"proj:a">>, <<"team:x">>, <<"tool:cli">>])])),
    %% 标签预算：超出后 429（花费由模型定价产生，这里直接累计）
    {ok, _} = lg_limits:set_budget({tag, <<"proj:a">>}, #{<<"period">> => <<"day">>, <<"max_usd">> => 1}),
    ok = lg_budget:add(undefined, undefined, [<<"proj:a">>], 2.0),
    {429, H2, B2} = post(Ctx, <<"/v1/chat/completions">>, [{<<"authorization">>, <<"Bearer ", K/binary>>}], K, Req),
    ?assertNotEqual(undefined, proplists:get_value(<<"retry-after">>, H2)),
    ?assertMatch(#{<<"error">> := #{<<"message">> := <<"Budget exceeded for tag `proj:a`">>}}, json:decode(B2)),
    %% 不带该标签的请求不受影响
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"ok">>)}),
    {200, _, _} = post(Ctx, <<"/v1/chat/completions">>, [{<<"authorization">>, <<"Bearer ", K/binary>>}], K,
                       maps:remove(<<"metadata">>, Req)),
    ok = lg_limits:delete_budget({tag, <<"proj:a">>}).

%% 客户端识别：日志 client、按客户端筛选日志与汇总用量；规则 tool 条件
client_detection(#{key := K, c2 := C2} = Ctx) ->
    reset_upstream(),
    Claude = [{<<"authorization">>, <<"Bearer ", K/binary>>}, {<<"user-agent">>, <<"claude-cli/2.1.281 (external, cli)">>}],
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"ok">>)}),
    {200, H, _} = post(Ctx, <<"/v1/chat/completions">>, Claude, K, chat(<<"gpt">>)),
    ?assertMatch(#{client := <<"claude-code">>}, wait_log(proplists:get_value(<<"x-request-id">>, H))),
    ?assertNot(maps:is_key(user_agent, wait_log(proplists:get_value(<<"x-request-id">>, H)))),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"ok">>)}),
    {200, H2, _} = post(Ctx, <<"/v1/chat/completions">>,
                        [{<<"authorization">>, <<"Bearer ", K/binary>>}, {<<"user-agent">>, <<"curl/8.5.0">>}], K, chat(<<"gpt">>)),
    ?assertMatch(#{client := <<"other">>, user_agent := <<"curl/8.5.0">>}, wait_log(proplists:get_value(<<"x-request-id">>, H2))),
    #{items := Items} = lg_store:logs(#{client => <<"claude-code">>, limit => 50}),
    ?assert(lists:all(fun(#{client := C}) -> C =:= <<"claude-code">> end, Items)),
    ?assert(length(Items) >= 1),
    Rows = lg_store:usage(#{from => lg_time:now_ms() - 3600000, to => lg_time:now_ms() + 1000, group_by => [client]}),
    ?assertMatch([_ | _], [R || #{client := <<"claude-code">>, requests := N} = R <- Rows, N >= 1]),
    %% 规则 tool：Claude Code 的请求先发给 cc-only 路由
    {ok, _} = lg_routes:create(#{<<"name">> => <<"cc-only">>,
                                 <<"targets">> => [#{<<"credential">> => C2, <<"upstream_model">> => <<"cc-up">>}]}),
    {ok, _} = lg_routes:update(<<"gpt">>, #{<<"options">> => #{<<"rules">> => [#{<<"when">> => #{<<"tool">> => [<<"claude-code">>]},
                                                                                 <<"use">> => <<"cc-only">>}]}}),
    reset_upstream_keep_cooldown(),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"ok">>)}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"ok">>)}),
    {200, _, _} = post(Ctx, <<"/v1/chat/completions">>, Claude, K, chat(<<"gpt">>)),
    {200, _, _} = post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"gpt">>)),
    ?assertEqual([<<"cc-up">>, <<"up-1">>], upstream_models()),
    {ok, _} = lg_routes:update(<<"gpt">>, #{<<"options">> => #{<<"rules">> => null}}),
    ok = lg_routes:delete(<<"cc-only">>),
    lg_affinity:clear().

%% 按量付费 Key 的余额：mock 上游充当 New API 中转站；余额为 0 时凭证按余额不足冷却，恢复后解除；低于告警线时告警
balances(#{base := Base}) ->
    reset_upstream(),
    {ok, #lg_credential{id = C}} =
        lg_credentials:create(#{<<"name">> => <<"relay">>, <<"protocol">> => <<"openai">>, <<"base_url">> => Base,
                                <<"api_key">> => <<"relay-key">>,
                                <<"options">> => #{<<"balance">> => #{<<"kind">> => <<"newapi">>, <<"alert_below">> => 1}}}),
    ?assertMatch({error, {invalid, <<"options.balance">>}},
                 lg_credentials:update(C, #{<<"options">> => #{<<"balance">> => #{<<"kind">> => <<"nope">>}}})),
    {ok, Ch} = lg_alerts:create_channel(#{<<"name">> => <<"off">>, <<"type">> => <<"webhook">>,
                                          <<"url">> => <<"http://127.0.0.1:1/hook">>, <<"enabled">> => false}),
    {ok, _} = lg_alerts:create_rule(#{<<"event">> => <<"balance_low">>, <<"channels">> => [element(2, Ch)]}),
    %% 创建凭证时已异步查询过一次：等它消费掉预置的响应后再按顺序准备
    timer:sleep(300),
    ets:insert(lg_mock_upstream, {responses, []}),
    reset_upstream(),
    lg_mock_upstream:expect({json, 200, #{}, #{<<"data">> => #{<<"total_available">> => 0}}}),
    ok = lg_balance:refresh([C]),
    #{path := Path, headers := H} = lists:last(lg_mock_upstream:requests()),
    ?assertEqual(<<"/api/usage/token">>, Path),
    ?assertEqual(<<"Bearer relay-key">>, maps:get(<<"authorization">>, H)),
    [#{amount := +0.0, currency := <<"USD">>, error := null, alert_below := 1}] =
        [B || #{credential := C1} = B <- lg_balance:all(), C1 =:= C],
    ?assertMatch(#{kind := credit, scope := credential}, lg_cooldown:info({C, <<"any">>})),
    ok = lg_alert:flush(),
    ?assertMatch([#{event := balance_low} | _], [A || #{event := balance_low} = A <- lg_alert:history(20)]),
    %% 余额恢复：解除冷却
    lg_mock_upstream:expect({json, 200, #{}, #{<<"data">> => #{<<"total_available">> => 5000000}}}),
    ok = lg_balance:refresh([C]),
    ?assertNot(lg_cooldown:cooling({C, <<"any">>})),
    [#{amount := 10.0}] = [B || #{credential := C1} = B <- lg_balance:all(), C1 =:= C],
    %% 查询失败只记录错误，保留上次余额
    lg_mock_upstream:expect({json, 500, #{}, <<"boom">>}),
    ok = lg_balance:refresh([C]),
    [#{amount := 10.0, error := Err}] = [B || #{credential := C1} = B <- lg_balance:all(), C1 =:= C],
    ?assertMatch(<<"HTTP 500", _/binary>>, Err),
    ok = lg_credentials:delete(C).

%% 嵌套路由：到达嵌套路由时按同一请求判定它自己的规则；日志候选带 via
nested_route_rules(#{key := K, c1 := C1, c2 := C2} = Ctx) ->
    reset_upstream(),
    T = fun(C, M) -> #{<<"credential">> => C, <<"upstream_model">> => M} end,
    {ok, _} = lg_routes:create(#{<<"name">> => <<"inner">>, <<"targets">> => [T(C1, <<"in-1">>), T(C2, <<"in-2">>)],
                                 <<"options">> => #{<<"strategy">> => <<"order">>,
                                                    <<"rules">> => [#{<<"when">> => #{<<"hours">> => <<"00:00-24:00">>},
                                                                      <<"skip">> => [C1]}]}}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"outer">>, <<"targets">> => [#{<<"route">> => <<"inner">>}]}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"nested">>)}),
    {200, H, _} = post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"outer">>)),
    ?assertEqual([<<"in-2">>], upstream_models()),
    L = wait_log(proplists:get_value(<<"x-request-id">>, H)),
    ?assertMatch(#{upstream_model := <<"in-2">>, route := <<"outer">>}, L),
    %% 只剩一个候选时不记 plan_trace；改为两个目标再看 via
    {ok, _} = lg_routes:update(<<"inner">>, #{<<"options">> => #{<<"rules">> => null}}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"nested">>)}),
    {200, H2, _} = post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"outer">>)),
    #{plan_trace := [#{via := [<<"inner">>], route := <<"inner">>} | _]} = wait_log(proplists:get_value(<<"x-request-id">>, H2)),
    ok = lg_routes:delete(<<"outer">>),
    ok = lg_routes:delete(<<"inner">>),
    lg_affinity:clear().

%% 实时事件流：事件顺序与内容、快照计数；SSE 接口先推快照
live_events(#{key := K, port := Port} = Ctx) ->
    reset_upstream(),
    ok = lg_live:subscribe(),
    lg_mock_upstream:expect({json, 503, #{}, <<"down">>}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"live">>)}),
    {200, H, _} = post(Ctx, <<"/v1/chat/completions">>,
                       [{<<"authorization">>, <<"Bearer ", K/binary>>}, {<<"user-agent">>, <<"claude-cli/2.1.281">>}], K,
                       chat(<<"gpt">>)),
    Id = proplists:get_value(<<"x-request-id">>, H),
    Evs = collect_live(Id, []),
    ?assertEqual([request_start, decision, attempt_start, attempt_end, attempt_start, attempt_end, request_end],
                 [T || #{type := T} <- Evs]),
    [#{data := Start} | _] = Evs,
    ?assertMatch(#{client := <<"claude-code">>, key_name := <<"all">>, route := <<"gpt">>}, Start),
    #{data := End} = lists:last(Evs),
    ?assertMatch(#{status := 200, attempts := 2, narrative := [_ | _]}, End),
    ok = lg_live:unsubscribe(),
    #{routes := Routes, active := Active} = lg_live:state(#{route => <<"gpt">>}),
    [#{reroutes := Rer, clients := Clients}] = [R || #{route := <<"gpt">>} = R <- Routes],
    ?assert(Rer >= 1),
    ?assert(lists:any(fun(#{client := C}) -> C =:= <<"claude-code">> end, Clients)),
    ?assertEqual([], [A || #{request_id := I} = A <- Active, I =:= Id]),
    %% 刚失败的 up-1 在冷却中，排到 up-2 后面；快照带上这条路由最近一次请求的叙述
    #{targets := Targets, last := #{narrative := [_ | _]}} = lg_live:state(#{route => <<"gpt">>}),
    ?assertMatch([#{upstream_model := <<"up-2">>, state := idle}, #{upstream_model := <<"up-1">>, state := cooling,
                                                                    cooldown := #{kind := server}}], Targets),
    %% SSE：首条事件为 state
    {ok, Conn} = gun:open("127.0.0.1", Port, #{retry => 0}),
    {ok, _} = gun:await_up(Conn, 5000),
    Ref = gun:get(Conn, <<"/api/live/stream?route=gpt">>),
    {response, nofin, 200, RH} = gun:await(Conn, Ref, 5000),
    ?assertEqual(<<"text/event-stream">>, proplists:get_value(<<"content-type">>, RH)),
    {data, nofin, First} = gun:await(Conn, Ref, 5000),
    {[#{event := <<"state">>, data := D}], _} = lg_sse:parse(First),
    ?assertMatch(#{<<"selected">> := <<"gpt">>, <<"targets">> := [_ | _]}, json:decode(D)),
    gun:close(Conn).

collect_live(Id, Acc) ->
    receive
        {lg_live, #{data := #{request_id := Id}} = E} ->
            case E of
                #{type := request_end} -> lists:reverse([E | Acc]);
                _ -> collect_live(Id, [E | Acc])
            end;
        {lg_live, _} -> collect_live(Id, Acc)
    after 3000 -> error({live_timeout, lists:reverse(Acc)})
    end.

%% 结构化输出：OpenAI 客户端要求 JSON Schema，Anthropic 兼容上游（非官方主机）用强制工具方式，回复还原成正文 JSON
structured_output(#{key := K} = Ctx) ->
    reset_upstream(),
    Schema = #{<<"type">> => <<"object">>, <<"properties">> => #{<<"city">> => #{<<"type">> => <<"string">>}}},
    Req = (chat(<<"claude">>))#{<<"response_format">> => #{<<"type">> => <<"json_schema">>,
                                                            <<"json_schema">> => #{<<"name">> => <<"weather">>, <<"schema">> => Schema}}},
    ToolMsg = #{<<"id">> => <<"msg_1">>, <<"type">> => <<"message">>, <<"role">> => <<"assistant">>, <<"model">> => <<"claude-up">>,
                <<"stop_reason">> => <<"tool_use">>,
                <<"content">> => [#{<<"type">> => <<"tool_use">>, <<"id">> => <<"toolu_1">>, <<"name">> => <<"weather">>,
                                    <<"input">> => #{<<"city">> => <<"Paris">>}}],
                <<"usage">> => #{<<"input_tokens">> => 5, <<"output_tokens">> => 3}},
    lg_mock_upstream:expect({json, 200, #{}, ToolMsg}),
    {200, _, B} = post(Ctx, <<"/v1/chat/completions">>, K, Req),
    #{<<"choices">> := [#{<<"finish_reason">> := <<"stop">>, <<"message">> := #{<<"content">> := C}}]} = json:decode(B),
    ?assertEqual(#{<<"city">> => <<"Paris">>}, json:decode(C)),
    #{body := Up} = lists:last(lg_mock_upstream:requests()),
    ?assertMatch(#{<<"tool_choice">> := #{<<"type">> := <<"tool">>, <<"name">> := <<"weather">>},
                   <<"tools">> := [#{<<"name">> := <<"weather">>, <<"input_schema">> := Schema}]}, Up),
    %% 流式：工具参数分片还原成正文分片
    Ev = fun(T, D) -> iolist_to_binary(lg_sse:encode(T, json:encode(D#{<<"type">> => T}))) end,
    Frames = [Ev(<<"message_start">>, #{<<"message">> => maps:remove(<<"content">>, ToolMsg#{<<"content">> => []})}),
              Ev(<<"content_block_start">>, #{<<"index">> => 0, <<"content_block">> => #{<<"type">> => <<"tool_use">>, <<"id">> => <<"toolu_1">>,
                                                                                       <<"name">> => <<"weather">>, <<"input">> => #{}}}),
              Ev(<<"content_block_delta">>, #{<<"index">> => 0, <<"delta">> => #{<<"type">> => <<"input_json_delta">>, <<"partial_json">> => <<"{\"city\":">>}}),
              Ev(<<"content_block_delta">>, #{<<"index">> => 0, <<"delta">> => #{<<"type">> => <<"input_json_delta">>, <<"partial_json">> => <<"\"Paris\"}">>}}),
              Ev(<<"content_block_stop">>, #{<<"index">> => 0}),
              Ev(<<"message_delta">>, #{<<"delta">> => #{<<"stop_reason">> => <<"tool_use">>}, <<"usage">> => #{<<"output_tokens">> => 3}}),
              Ev(<<"message_stop">>, #{})],
    lg_mock_upstream:expect({sse, Frames}),
    {200, _, Sse} = post(Ctx, <<"/v1/chat/completions">>, K, Req#{<<"stream">> => true}),
    {Evs, _} = lg_sse:parse(Sse),
    Chunks = [json:decode(D) || #{data := D} <- Evs, D =/= <<"[DONE]">>],
    Text = iolist_to_binary([T || #{<<"choices">> := [#{<<"delta">> := #{<<"content">> := T}} | _]} <- Chunks, is_binary(T)]),
    ?assertEqual(#{<<"city">> => <<"Paris">>}, json:decode(Text)),
    ?assertEqual([<<"stop">>], [F || #{<<"choices">> := [#{<<"finish_reason">> := F}]} <- Chunks, F =/= null]),
    ?assertEqual([], [x || #{<<"choices">> := [#{<<"delta">> := #{<<"tool_calls">> := _}}]} <- Chunks]).

%% 网关中间件：三个钩子点位、按路由生效、拒绝、出错与超时放行、内置实现
middleware(#{key := K} = Ctx) ->
    reset_upstream(),
    application:set_env(lg_router, middleware_impls, #{<<"test">> => lg_mw_test}),
    %% 没有中间件时不经过
    ?assertEqual(none, lg_middleware:begin_run(<<"gpt">>, #{})),
    {ok, #lg_middleware{id = T}} = lg_middlewares:create(#{<<"name">> => <<"t">>, <<"impl">> => <<"test">>,
                                                            <<"routes">> => [<<"gpt">>]}),
    {ok, #lg_middleware{id = Sp}} = lg_middlewares:create(#{<<"name">> => <<"zh">>, <<"impl">> => <<"system_prompt">>,
                                                             <<"options">> => #{<<"text">> => <<"answer in Chinese">>},
                                                             <<"position">> => 1}),
    ?assertMatch({error, {invalid_options, _}}, lg_middlewares:create(#{<<"name">> => <<"x">>, <<"impl">> => <<"system_prompt">>})),
    ?assertMatch({error, {invalid, <<"impl">>}}, lg_middlewares:create(#{<<"name">> => <<"x">>, <<"impl">> => <<"nope">>})),
    %% on_request（system_prompt 追加系统消息）+ on_response（读到 on_request 留下的 state）
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"hello">>)}),
    {200, _, B} = post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"gpt">>)),
    ?assertMatch(#{<<"x_mw_seen">> := <<"gpt">>}, json:decode(B)),
    #{body := #{<<"messages">> := [#{<<"role">> := <<"system">>, <<"content">> := <<"answer in Chinese">>} | _]}} =
        lists:last(lg_mock_upstream:requests()),
    %% on_event：流式正文改成大写
    lg_mock_upstream:expect({sse, sse_chunks([<<"ab">>, <<"c">>])}),
    {200, _, Sse} = post(Ctx, <<"/v1/chat/completions">>, K, (chat(<<"gpt">>))#{<<"stream">> => true}),
    {Evs, _} = lg_sse:parse(Sse),
    ?assertEqual(<<"ABC">>, iolist_to_binary([C || #{data := D} <- Evs, D =/= <<"[DONE]">>,
                                                    #{<<"choices">> := [#{<<"delta">> := #{<<"content">> := C}} | _]} <- [json:decode(D)]])),
    %% 按路由生效：claude 路由只经过 system_prompt（routes = all）
    #{chain := [#{name := <<"zh">>}]} = lg_middleware:begin_run(<<"claude">>, #{}),
    %% 拒绝：按客户端格式返回，并记日志
    {ok, _} = lg_middlewares:update(T, #{<<"options">> => #{<<"mode">> => <<"reject">>}}),
    {403, H, RB} = post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"gpt">>)),
    ?assertMatch(#{<<"error">> := #{<<"message">> := <<"blocked by middleware">>, <<"type">> := <<"permission_error">>}}, json:decode(RB)),
    ?assertMatch(#{status := 403, error := #{kind := middleware_rejected, message := <<"blocked by middleware">>}},
                 wait_log(proplists:get_value(<<"x-request-id">>, H))),
    %% 出错与超时放行，并计数
    reset_upstream_keep_cooldown(),
    {ok, _} = lg_middlewares:update(T, #{<<"options">> => #{<<"mode">> => <<"crash">>}}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"ok">>)}),
    {200, _, _} = post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"gpt">>)),
    {ok, _} = lg_middlewares:update(T, #{<<"options">> => #{<<"mode">> => <<"slow">>}}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"ok">>)}),
    {200, _, _} = post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"gpt">>)),
    #{T := #{failures := Fails, last_error := #{hook := on_request, message := <<"timeout">>}}} = lg_middleware:stats(),
    ?assert(Fails >= 2),
    %% 内置 model_map：换模型名（换成的路由照常解析）
    ok = lg_middlewares:delete(T),
    {ok, _} = lg_middlewares:create(#{<<"name">> => <<"map">>, <<"impl">> => <<"model_map">>,
                                      <<"options">> => #{<<"mapping">> => #{<<"gpt-4o">> => <<"gpt">>}}}),
    reset_upstream_keep_cooldown(),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"mapped">>)}),
    {200, _, _} = post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"gpt-4o">>)),
    ?assertEqual([<<"up-1">>], upstream_models()),
    [ok = lg_middlewares:delete(Id) || #lg_middleware{id = Id} <- lg_middlewares:list()],
    _ = Sp,
    application:unset_env(lg_router, middleware_impls).

%% 上游参数兼容的自动学习：上游以 400 拒绝 temperature → 去掉后重试一次成功并记下；之后直接不带
unfit_learning(#{key := K, c1 := C1} = Ctx) ->
    reset_upstream(),
    ok = lg_unfit:forget_all(),
    Req = (chat(<<"gpt">>))#{<<"temperature">> => 0},
    Err = #{<<"error">> => #{<<"message">> => <<"invalid temperature: only 1 is allowed for this model">>,
                             <<"type">> => <<"invalid_request_error">>}},
    lg_mock_upstream:expect({json, 400, #{}, Err}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"ok">>)}),
    {200, _, _} = post(Ctx, <<"/v1/chat/completions">>, K, Req),
    [#{body := B1}, #{body := B2}] = lg_mock_upstream:requests(),
    ?assertEqual(0, maps:get(<<"temperature">>, B1)),
    ?assertNot(maps:is_key(<<"temperature">>, B2)),
    ?assertMatch([#{credential := C1, upstream_model := <<"up-1">>, feature := temperature}], lg_unfit:list()),
    %% 之后直接按已知限制改写，只请求一次
    reset_upstream_keep_cooldown(),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"ok">>)}),
    {200, _, _} = post(Ctx, <<"/v1/chat/completions">>, K, Req),
    [#{body := B3}] = lg_mock_upstream:requests(),
    ?assertNot(maps:is_key(<<"temperature">>, B3)),
    %% 认不出的 400 不重试，原样返回
    reset_upstream_keep_cooldown(),
    lg_mock_upstream:expect({json, 400, #{}, #{<<"error">> => #{<<"message">> => <<"bad param x">>}}}),
    {400, _, _} = post(Ctx, <<"/v1/chat/completions">>, K, Req#{<<"top_p">> => 0.1}),
    ?assertEqual(1, length(lg_mock_upstream:requests())),
    ok = lg_unfit:forget_all(),
    ?assertEqual([], lg_unfit:list()).

%% 全员繁忙时整轮重试：两个候选都 5xx → 等待后整轮再试，第二轮主目标成功；额度用尽类不重试
patience_retry(#{key := K} = Ctx) ->
    reset_upstream(),
    application:set_env(lg_core, patience_ms, 200),
    lg_mock_upstream:expect({json, 503, #{}, <<"busy">>}),
    lg_mock_upstream:expect({json, 502, #{}, <<"bad gateway">>}),   %% cowboy 不认识 529，mock 用 502
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"second round">>)}),
    T0 = erlang:monotonic_time(millisecond),
    {200, H, B} = post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"gpt">>)),
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    ?assertEqual([<<"up-1">>, <<"up-2">>, <<"up-1">>], upstream_models()),
    ?assertMatch(#{<<"choices">> := [#{<<"message">> := #{<<"content">> := <<"second round">>}}]}, json:decode(B)),
    ?assert(Elapsed >= 200),
    L = wait_log(proplists:get_value(<<"x-request-id">>, H)),
    ?assertMatch(#{rounds := 1, attempts := 3}, L),
    ?assert(lists:any(fun(#{text := T}) -> binary:match(T, <<"整轮再试"/utf8>>) =/= nomatch end, lg_narrate:lines(L))),
    %% 有一个是额度用尽：不重试
    reset_upstream(),
    lg_mock_upstream:expect({json, 503, #{}, <<"busy">>}),
    lg_mock_upstream:expect({json, 429, #{}, #{<<"error">> => #{<<"message">> => <<"usage limit reached">>}}}),
    {429, _, _} = post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"gpt">>)),
    ?assertEqual(2, length(upstream_models())),
    lg_cooldown:clear(),
    application:set_env(lg_core, patience_ms, 0).

%% 流式复读检测：上游陷入复读时网关提前结束，客户端收到正常的结束帧（OpenAI：length；Anthropic：max_tokens）
loop_guard(#{key := K} = Ctx) ->
    reset_upstream(),
    Loop = sse_chunks(lists:duplicate(80, <<"Now. Writing. Go. ">>)),
    lg_mock_upstream:expect({sse, Loop}),
    {200, H, Sse} = post(Ctx, <<"/v1/chat/completions">>, K, (chat(<<"gpt">>))#{<<"stream">> => true}),
    {Evs, _} = lg_sse:parse(Sse),
    Chunks = [json:decode(D) || #{data := D} <- Evs, D =/= <<"[DONE]">>],
    ?assertEqual([<<"length">>], [F || #{<<"choices">> := [#{<<"finish_reason">> := F}]} <- Chunks, F =/= null]),
    ?assertEqual(<<"[DONE]">>, maps:get(data, lists:last(Evs))),
    Text = iolist_to_binary([C || #{<<"choices">> := [#{<<"delta">> := #{<<"content">> := C}}]} <- Chunks, is_binary(C)]),
    ?assert(byte_size(Text) < 80 * 18),
    ?assertMatch(#{loop_detected := true, finish_reason := <<"length">>}, wait_log(proplists:get_value(<<"x-request-id">>, H))),
    %% Anthropic 客户端 → Anthropic 上游（透传）：关闭打开的内容块，max_tokens 结束
    reset_upstream(),
    Ev = fun(T, D) -> iolist_to_binary(lg_sse:encode(T, json:encode(D#{<<"type">> => T}))) end,
    Frames = [Ev(<<"message_start">>, #{<<"message">> => #{<<"id">> => <<"m">>, <<"model">> => <<"claude-up">>,
                                                           <<"usage">> => #{<<"input_tokens">> => 3}}}),
              Ev(<<"content_block_start">>, #{<<"index">> => 0, <<"content_block">> => #{<<"type">> => <<"text">>, <<"text">> => <<>>}})]
             ++ [Ev(<<"content_block_delta">>, #{<<"index">> => 0, <<"delta">> => #{<<"type">> => <<"text_delta">>,
                                                                                  <<"text">> => <<"现在开始写代码。"/utf8>>}})
                 || _ <- lists:seq(1, 80)]
             ++ [Ev(<<"content_block_stop">>, #{<<"index">> => 0}), Ev(<<"message_stop">>, #{})],
    lg_mock_upstream:expect({sse, Frames}),
    Req = #{<<"model">> => <<"claude">>, <<"max_tokens">> => 100, <<"stream">> => true,
            <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]},
    {200, _, Sse2} = post(Ctx, <<"/v1/messages">>, [{<<"x-api-key">>, K}], K, Req),
    {Evs2, _} = lg_sse:parse(Sse2),
    Types = [T || #{event := T} <- Evs2],
    ?assertEqual([<<"content_block_stop">>, <<"message_delta">>, <<"message_stop">>], lists:nthtail(length(Types) - 3, Types)),
    #{data := DeltaD} = lists:nth(length(Evs2) - 1, Evs2),
    ?assertMatch(#{<<"delta">> := #{<<"stop_reason">> := <<"max_tokens">>}}, json:decode(DeltaD)),
    %% 按路由关闭
    {ok, _} = lg_routes:update(<<"gpt">>, #{<<"options">> => #{<<"loop_guard">> => false}}),
    reset_upstream(),
    lg_mock_upstream:expect({sse, Loop}),
    {200, _, Sse3} = post(Ctx, <<"/v1/chat/completions">>, K, (chat(<<"gpt">>))#{<<"stream">> => true}),
    {Evs3, _} = lg_sse:parse(Sse3),
    ?assertEqual(81, length(Evs3)),
    {ok, _} = lg_routes:update(<<"gpt">>, #{<<"options">> => #{<<"loop_guard">> => null}}).

%% 敏感信息脱敏：按路由或 Key 开启；上游看到占位符，客户端拿到原值，日志里是脱敏后的内容
redaction(#{key := K} = Ctx) ->
    Secret = <<"sk-live0123456789abcdefghijkl">>,
    Ask = (chat(<<"gpt">>))#{<<"messages">> => [#{<<"role">> => <<"user">>,
                                                  <<"content">> => <<"my key is ", Secret/binary>>}]},
    Upstream = fun() -> [#{<<"content">> := C}] = maps:get(<<"messages">>, lists:last([B || #{body := B} <- lg_mock_upstream:requests()])), C end,
    %% 未开启：原样转发
    reset_upstream(),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"ok">>)}),
    {200, _, _} = post(Ctx, <<"/v1/chat/completions">>, K, Ask),
    ?assertEqual(<<"my key is ", Secret/binary>>, Upstream()),
    %% 路由开启：非流式
    {ok, _} = lg_routes:update(<<"gpt">>, #{<<"options">> => #{<<"redact">> => true}}),
    reset_upstream(),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"your key [[LG_SECRET_1]] is set">>)}),
    {200, H, B} = post(Ctx, <<"/v1/chat/completions">>, K, Ask),
    ?assertEqual(<<"my key is [[LG_SECRET_1]]">>, Upstream()),
    #{<<"choices">> := [#{<<"message">> := #{<<"content">> := Reply}}]} = json:decode(B),
    ?assertEqual(<<"your key ", Secret/binary, " is set">>, Reply),
    Id = proplists:get_value(<<"x-request-id">>, H),
    ?assertMatch(#{redacted := 1}, wait_log(Id)),
    ?assertMatch({ok, #{request := #{<<"messages">> := [#{<<"content">> := <<"my key is [[LG_SECRET_1]]">>}]},
                        response := <<"your key [[LG_SECRET_1]] is set">>}}, lg_store:messages(Id)),
    %% 流式：占位符被切在两个分片之间
    reset_upstream(),
    lg_mock_upstream:expect({sse, sse_chunks([<<"use [[LG_SEC">>, <<"RET_1]]">>, <<" now">>])}),
    {200, _, Sse} = post(Ctx, <<"/v1/chat/completions">>, K, Ask#{<<"stream">> => true}),
    {Evs, _} = lg_sse:parse(Sse),
    Text = iolist_to_binary([C || #{data := D} <- Evs, D =/= <<"[DONE]">>,
                                  #{<<"choices">> := [#{<<"delta">> := #{<<"content">> := C}}]} <- [json:decode(D)], is_binary(C)]),
    ?assertEqual(<<"use ", Secret/binary, " now">>, Text),
    {ok, _} = lg_routes:update(<<"gpt">>, #{<<"options">> => #{<<"redact">> => null}}),
    %% Key 开启：Anthropic 客户端
    {ok, Kr, #lg_api_key{id = KrId}} = lg_api_keys:create(#{<<"name">> => <<"redacted">>, <<"options">> => #{<<"redact">> => true}}),
    ?assertMatch({error, {invalid, <<"options">>}}, lg_api_keys:update(KrId, #{<<"options">> => #{<<"nope">> => 1}})),
    reset_upstream(),
    lg_mock_upstream:expect({json, 200, #{}, #{<<"id">> => <<"m">>, <<"type">> => <<"message">>, <<"role">> => <<"assistant">>,
                                               <<"model">> => <<"claude-up">>, <<"stop_reason">> => <<"end_turn">>,
                                               <<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"got [[LG_SECRET_1]]">>}],
                                               <<"usage">> => #{<<"input_tokens">> => 3, <<"output_tokens">> => 2}}}),
    Msg = #{<<"model">> => <<"claude">>, <<"max_tokens">> => 100,
            <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"key ", Secret/binary>>}]},
    {200, _, B2} = post(Ctx, <<"/v1/messages">>, [{<<"x-api-key">>, Kr}], Kr, Msg),
    ?assertEqual(<<"key [[LG_SECRET_1]]">>, Upstream()),
    #{<<"content">> := [#{<<"text">> := Reply2}]} = json:decode(B2),
    ?assertEqual(<<"got ", Secret/binary>>, Reply2),
    ok = lg_api_keys:delete(KrId).

%% 会话视图：同一会话标识的请求聚合；日志带提示词构成
sessions_view(#{key := K} = Ctx) ->
    Sid = <<"sess-view-1">>,
    H = [{<<"authorization">>, <<"Bearer ", K/binary>>}, {<<"x-litegate-session">>, Sid}],
    Body = (chat(<<"gpt">>))#{<<"messages">> => [#{<<"role">> => <<"system">>, <<"content">> => binary:copy(<<"s">>, 400)},
                                                 #{<<"role">> => <<"user">>, <<"content">> => <<"hello">>}],
                              <<"tools">> => [#{<<"type">> => <<"function">>,
                                                <<"function">> => #{<<"name">> => <<"lookup">>, <<"parameters">> => #{}}}]},
    reset_upstream(),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"one">>)}),
    {200, H1, _} = post(Ctx, <<"/v1/chat/completions">>, H, K, Body),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"two">>)}),
    Body2 = Body#{<<"messages">> => maps:get(<<"messages">>, Body)
                      ++ [#{<<"role">> => <<"assistant">>, <<"content">> => <<"one">>},
                          #{<<"role">> => <<"user">>, <<"content">> => <<"again">>}]},
    {200, _, _} = post(Ctx, <<"/v1/chat/completions">>, H, K, Body2),
    ?assertMatch(#{session := Sid, new_turn := true,
                   context := #{system := 100, history := 0, tool_list := [#{name := <<"lookup">>}]}},
                 wait_log(proplists:get_value(<<"x-request-id">>, H1))),
    {200, _, LB} = req(Ctx, <<"GET">>, <<"/api/sessions?limit=10">>, [], <<>>),
    #{<<"items">> := Items} = json:decode(LB),
    ?assertMatch([#{<<"requests">> := 2, <<"turns">> := 2, <<"routes">> := [<<"gpt">>]}],
                 [X || #{<<"id">> := I} = X <- Items, I =:= Sid]),
    {200, _, DB} = req(Ctx, <<"GET">>, <<"/api/sessions/", Sid/binary>>, [], <<>>),
    #{<<"logs">> := [L1, L2], <<"truncated">> := false} = json:decode(DB),
    ?assert(maps:get(<<"ts">>, L1) =< maps:get(<<"ts">>, L2)),
    ?assertMatch(#{<<"context">> := #{<<"history">> := Hist}} when Hist > 0, L2),
    {404, _, _} = req(Ctx, <<"GET">>, <<"/api/sessions/none">>, [], <<>>).

%% 图片生成：OpenAI 兼容上游透传；MiniMax 私有格式转换；按张计费
images(#{key := K} = Ctx) ->
    reset_upstream(),
    #{credential := C} = hd((element(2, lg_routes:get(<<"gpt">>)))#lg_route.targets),
    ok = lg_catalog:put_overlay({<<"imgprov">>, <<"img-m">>}, #{<<"name">> => <<"Img">>, <<"cost">> => #{<<"image">> => 0.05}}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"img">>,
                                 <<"targets">> => [#{<<"credential">> => C, <<"upstream_model">> => <<"img-m">>,
                                                     <<"model_ref">> => [<<"imgprov">>, <<"img-m">>]}]}),
    Req = #{<<"model">> => <<"img">>, <<"prompt">> => <<"a red apple">>, <<"n">> => 2, <<"size">> => <<"1792x1024">>},
    lg_mock_upstream:expect({json, 200, #{}, #{<<"created">> => 1, <<"data">> => [#{<<"url">> => <<"https://i/1.png">>},
                                                                               #{<<"url">> => <<"https://i/2.png">>}]}}),
    {200, H1, B1} = post(Ctx, <<"/v1/images/generations">>, K, Req),
    ?assertMatch(#{<<"data">> := [#{<<"url">> := <<"https://i/1.png">>}, _]}, json:decode(B1)),
    #{path := P1, body := Up1} = lists:last(lg_mock_upstream:requests()),
    ?assertEqual(<<"/v1/images/generations">>, P1),
    ?assertMatch(#{<<"model">> := <<"img-m">>, <<"size">> := <<"1792x1024">>}, Up1),
    ?assertMatch(#{format := images, usage := #{images := 2}, cost := 0.1},
                 wait_log(proplists:get_value(<<"x-request-id">>, H1))),
    %% MiniMax 格式
    {ok, _} = lg_credentials:update(C, #{<<"options">> => #{<<"media_api">> => <<"minimax">>}}),
    lg_mock_upstream:expect({json, 200, #{}, #{<<"data">> => #{<<"image_base64">> => [<<"QUJD">>]},
                                               <<"base_resp">> => #{<<"status_code">> => 0, <<"status_msg">> => <<"success">>}}}),
    {200, _, B2} = post(Ctx, <<"/v1/images/generations">>, K, Req#{<<"n">> => 1, <<"response_format">> => <<"b64_json">>}),
    ?assertMatch(#{<<"data">> := [#{<<"b64_json">> := <<"QUJD">>}]}, json:decode(B2)),
    #{path := P2, body := Up2} = lists:last(lg_mock_upstream:requests()),
    ?assertEqual(<<"/v1/image_generation">>, P2),
    ?assertMatch(#{<<"aspect_ratio">> := <<"16:9">>, <<"response_format">> := <<"base64">>, <<"prompt">> := <<"a red apple">>}, Up2),
    ?assertNot(maps:is_key(<<"size">>, Up2)),
    %% MiniMax 业务错误（200 + status_code）→ 对应的 HTTP 状态
    lg_mock_upstream:expect({json, 200, #{}, #{<<"base_resp">> => #{<<"status_code">> => 2013, <<"status_msg">> => <<"invalid params">>}}}),
    {400, _, _} = post(Ctx, <<"/v1/images/generations">>, K, Req),
    {ok, _} = lg_credentials:update(C, #{<<"options">> => #{<<"media_api">> => null}}),
    ok = lg_routes:delete(<<"img">>),
    lg_cooldown:clear().

%% 结构化决策（System One）：透传到 {base}/systemone，model 换为上游模型、响应换回路由名；
%% 按输入 token 计费；5xx 换下一个目标；只用 openai 协议的目标
systemone(#{key := K, c1 := C1, c2 := C2} = Ctx) ->
    reset_upstream(),
    ok = lg_catalog:put_overlay({<<"decprov">>, <<"dec-m">>}, #{<<"name">> => <<"Dec">>, <<"cost">> => #{<<"input">> => 1.0}}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"decide">>,
                                 <<"targets">> => [#{<<"credential">> => C1, <<"upstream_model">> => <<"dec-m">>,
                                                     <<"model_ref">> => [<<"decprov">>, <<"dec-m">>]},
                                                   #{<<"credential">> => C2, <<"upstream_model">> => <<"dec-b">>,
                                                     <<"priority">> => 1}]}),
    Q = #{<<"escalate">> => #{<<"type">> => <<"noul">>, <<"instructions">> => <<"是否需要通知值班？"/utf8>>},
          <<"team">> => #{<<"type">> => <<"choice">>, <<"criteria">> => #{<<"billing">> => <<"账单"/utf8>>,
                                                                       <<"tech">> => <<"技术"/utf8>>}}},
    Req = #{<<"model">> => <<"decide">>, <<"state">> => #{<<"content">> => <<"付款后未到账"/utf8>>}, <<"questions">> => Q},
    Answer = #{<<"model">> => <<"dec-m">>, <<"request_id">> => <<"rq-1">>, <<"latency_ms">> => 40.5,
               <<"answers">> => #{<<"escalate">> => #{<<"type">> => <<"noul">>, <<"noul">> => 0.99},
                                  <<"team">> => #{<<"type">> => <<"choice">>, <<"choice">> => <<"billing">>,
                                                  <<"confidence">> => 0.9,
                                                  <<"probabilities">> => #{<<"billing">> => 0.94, <<"tech">> => 0.06}}},
               <<"usage">> => #{<<"input_tokens">> => 125000}},
    lg_mock_upstream:expect({json, 200, #{}, Answer}),
    {200, H1, B1} = post(Ctx, <<"/v1/systemone">>, K, Req),
    ?assertMatch(#{<<"model">> := <<"decide">>, <<"request_id">> := <<"rq-1">>,
                   <<"answers">> := #{<<"team">> := #{<<"choice">> := <<"billing">>}}}, json:decode(B1)),
    #{path := P1, body := Up1} = lists:last(lg_mock_upstream:requests()),
    ?assertEqual(<<"/v1/systemone">>, P1),
    ?assertEqual(Req#{<<"model">> => <<"dec-m">>}, Up1),
    L1 = wait_log(proplists:get_value(<<"x-request-id">>, H1)),
    ?assertMatch(#{format := systemone, upstream_model := <<"dec-m">>, usage := #{input := 125000, output := 0}}, L1),
    ?assert(abs(maps:get(cost, L1) - 0.125) < 1.0e-9),
    {ok, #{request := #{<<"messages">> := [#{<<"role">> := <<"user">>, <<"content">> := St}], <<"questions">> := Q},
           response := <<"escalate=0.99; team=billing(0.90)">>}} = lg_store:messages(maps:get(id, L1)),
    ?assertEqual(#{<<"content">> => <<"付款后未到账"/utf8>>}, json:decode(St)),
    %% 首个目标 5xx：换下一个目标
    reset_upstream_keep_cooldown(),
    lg_mock_upstream:expect({json, 503, #{}, #{<<"error">> => #{<<"message">> => <<"busy">>}}}),
    lg_mock_upstream:expect({json, 200, #{}, Answer#{<<"model">> => <<"dec-b">>}}),
    {200, H2, B2} = post(Ctx, <<"/v1/systemone">>, K, Req),
    ?assertMatch(#{<<"model">> := <<"decide">>}, json:decode(B2)),
    ?assertMatch([#{body := #{<<"model">> := <<"dec-m">>}}, #{body := #{<<"model">> := <<"dec-b">>}}],
                 lg_mock_upstream:requests()),
    ?assertMatch(#{attempts := 2, upstream_model := <<"dec-b">>}, wait_log(proplists:get_value(<<"x-request-id">>, H2))),
    %% 上游 4xx：不重试，透传给客户端
    lg_cooldown:clear(),
    reset_upstream_keep_cooldown(),
    lg_mock_upstream:expect({json, 400, #{}, #{<<"error">> => #{<<"message">> => <<"questions required">>}}}),
    {400, _, B3} = post(Ctx, <<"/v1/systemone">>, K, Req),
    ?assertMatch(#{<<"error">> := #{<<"message">> := <<"questions required">>}}, json:decode(B3)),
    ?assertEqual(1, length(lg_mock_upstream:requests())),
    %% 只有 anthropic 协议目标的路由：不支持
    {400, _, _} = post(Ctx, <<"/v1/systemone">>, K, Req#{<<"model">> => <<"claude">>}),
    ok = lg_routes:delete(<<"decide">>),
    lg_cooldown:clear().

%% 意图判断用决策模型（intent_engine = systemone）：noul / choice 两种问法；出错改问后备判断路由
systemone_intent(#{key := K, c1 := C1, c2 := C2} = Ctx) ->
    reset_upstream(),
    lg_affinity:clear(),
    T = fun(C, M) -> #{<<"credential">> => C, <<"upstream_model">> => M} end,
    {ok, _} = lg_routes:create(#{<<"name">> => <<"s-dec">>, <<"targets">> => [T(C2, <<"dec-up">>)]}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"s-judge">>, <<"targets">> => [T(C2, <<"judge-up">>)]}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"s-pretty">>, <<"targets">> => [T(C2, <<"pretty-up">>)]}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"s-read">>, <<"targets">> => [T(C2, <<"read-up">>)]}),
    Rules = [#{<<"when">> => #{<<"intent">> => <<"美化：改进界面样式"/utf8>>}, <<"use">> => <<"s-pretty">>},
             #{<<"when">> => #{<<"intent">> => <<"读取文件：只读不修改"/utf8>>}, <<"use">> => <<"s-read">>}],
    {ok, _} = lg_routes:create(#{<<"name">> => <<"s-main">>, <<"targets">> => [T(C1, <<"main-up">>)],
                                 <<"options">> => #{<<"rules">> => Rules, <<"intent_engine">> => <<"systemone">>,
                                                    <<"decision_route">> => <<"s-dec">>, <<"decision_style">> => <<"noul">>,
                                                    <<"classifier">> => <<"s-judge">>}}),
    %% 被引用的决策路由不能删除
    ?assertMatch({error, {in_use, [<<"s-main">>]}}, lg_routes:delete(<<"s-dec">>)),
    Ask = fun(Text) -> #{<<"model">> => <<"s-main">>, <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => Text}]} end,
    Paths = fun() -> [P || #{path := P} <- lg_mock_upstream:requests()] end,
    Noul = fun(P1, P2) -> #{<<"answers">> => #{<<"i1">> => #{<<"type">> => <<"noul">>, <<"noul">> => P1},
                                                 <<"i2">> => #{<<"type">> => <<"noul">>, <<"noul">> => P2}},
                            <<"usage">> => #{<<"input_tokens">> => 30}} end,
    %% noul：每条意图一道是非题，经网关调用决策路由（model 为其上游模型）
    lg_mock_upstream:expect({json, 200, #{}, Noul(0.1, 0.93)}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"read">>)}),
    {200, H1, _} = post(Ctx, <<"/v1/chat/completions">>, K, Ask(<<"看看 main.go"/utf8>>)),
    ?assertEqual([<<"/v1/systemone">>, <<"/v1/chat/completions">>], Paths()),
    [#{body := #{<<"model">> := <<"dec-up">>, <<"state">> := #{<<"message">> := <<"看看 main.go"/utf8>>},
                 <<"questions">> := #{<<"i1">> := #{<<"type">> := <<"noul">>}, <<"i2">> := _}}},
     #{body := #{<<"model">> := <<"read-up">>}}] = lg_mock_upstream:requests(),
    ?assertMatch(#{rule := 2, routed_to := <<"s-read">>,
                   intent := #{answer := 2, classifier := <<"s-dec">>, reply := <<"i2 0.93", _/binary>>}},
                 wait_log(proplists:get_value(<<"x-request-id">>, H1))),
    %% choice（不写 decision_style 时的默认）：一道单选题（i1、i2 与 other）
    {ok, _} = lg_routes:update(<<"s-main">>, #{<<"options">> => #{<<"decision_style">> => null}}),
    reset_upstream_keep_cooldown(),
    lg_mock_upstream:expect({json, 200, #{}, #{<<"answers">> => #{<<"intent">> => #{
        <<"type">> => <<"choice">>, <<"choice">> => <<"i1">>, <<"confidence">> => 0.9,
        <<"probabilities">> => #{<<"i1">> => 0.88, <<"i2">> => 0.02, <<"other">> => 0.1}}}}}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"pretty">>)}),
    {200, H2, _} = post(Ctx, <<"/v1/chat/completions">>, K, Ask(<<"按钮配色调好看一点"/utf8>>)),
    [#{body := #{<<"questions">> := #{<<"intent">> := #{<<"type">> := <<"choice">>,
                                                         <<"criteria">> := #{<<"other">> := _, <<"i1">> := _, <<"i2">> := _}}}}},
     #{body := #{<<"model">> := <<"pretty-up">>}}] = lg_mock_upstream:requests(),
    ?assertMatch(#{rule := 1, intent := #{answer := 1, classifier := <<"s-dec">>}},
                 wait_log(proplists:get_value(<<"x-request-id">>, H2))),
    %% 决策模型出错：改问后备判断路由（回答 1 → 美化），说明里标明是决策模型失败
    reset_upstream_keep_cooldown(),
    lg_mock_upstream:expect({json, 400, #{}, #{<<"error">> => #{<<"message">> => <<"bad questions">>}}}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"1">>)}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"pretty">>)}),
    {200, H3, _} = post(Ctx, <<"/v1/chat/completions">>, K, Ask(<<"配色再调一下"/utf8>>)),
    ?assertEqual([<<"/v1/systemone">>, <<"/v1/chat/completions">>, <<"/v1/chat/completions">>], Paths()),
    L3 = wait_log(proplists:get_value(<<"x-request-id">>, H3)),
    ?assertMatch(#{rule := 1, intent := #{answer := 1, classifier := <<"s-judge">>, local_error := <<"bad questions">>,
                                          local_by := <<"s-dec">>}}, L3),
    ?assertMatch([_ | _], [T0 || #{text := T0} <- lg_narrate:lines(L3),
                                 binary:match(T0, <<"决策模型 s-dec 判断失败"/utf8>>) =/= nomatch]),
    ok = lg_routes:delete(<<"s-main">>),
    [ok = lg_routes:delete(R) || R <- [<<"s-dec">>, <<"s-judge">>, <<"s-pretty">>, <<"s-read">>]],
    lg_cooldown:clear().

%% 语音合成：OpenAI 兼容上游透传音频；MiniMax 十六进制音频解码；按字符计费
speech(#{key := K} = Ctx) ->
    reset_upstream(),
    #{credential := C} = hd((element(2, lg_routes:get(<<"gpt">>)))#lg_route.targets),
    ok = lg_catalog:put_overlay({<<"ttsprov">>, <<"tts-m">>}, #{<<"name">> => <<"TTS">>, <<"cost">> => #{<<"tts">> => 100000}}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"tts">>,
                                 <<"targets">> => [#{<<"credential">> => C, <<"upstream_model">> => <<"tts-m">>,
                                                     <<"model_ref">> => [<<"ttsprov">>, <<"tts-m">>]}]}),
    Req = #{<<"model">> => <<"tts">>, <<"input">> => <<"你好世界"/utf8>>, <<"voice">> => <<"alloy">>,
            <<"response_format">> => <<"wav">>},
    Wav = <<"RIFF", 0:32, "WAVEfmt ">>,
    lg_mock_upstream:expect({json, 200, #{<<"content-type">> => <<"audio/wav">>}, Wav}),
    {200, H1, B1} = post(Ctx, <<"/v1/audio/speech">>, K, Req),
    ?assertEqual(Wav, B1),
    ?assertEqual(<<"audio/wav">>, proplists:get_value(<<"content-type">>, H1)),
    #{path := P1, body := Up1} = lists:last(lg_mock_upstream:requests()),
    ?assertEqual(<<"/v1/audio/speech">>, P1),
    ?assertMatch(#{<<"model">> := <<"tts-m">>, <<"voice">> := <<"alloy">>}, Up1),
    %% 4 个字符 × 100000 / 1e6 = 0.4
    ?assertMatch(#{format := speech, usage := #{chars := 4}, cost := 0.4},
                 wait_log(proplists:get_value(<<"x-request-id">>, H1))),
    %% MiniMax：t2a_v2，音频十六进制；OpenAI 预置音色换成默认音色
    {ok, _} = lg_credentials:update(C, #{<<"options">> => #{<<"media_api">> => <<"minimax">>}}),
    Mp3 = <<"ID3", 1, 2, 3>>,
    lg_mock_upstream:expect({json, 200, #{}, #{<<"data">> => #{<<"audio">> => binary:encode_hex(Mp3), <<"status">> => 2},
                                               <<"base_resp">> => #{<<"status_code">> => 0}}}),
    {200, H2, B2} = post(Ctx, <<"/v1/audio/speech">>, K, maps:remove(<<"response_format">>, Req)),
    ?assertEqual(Mp3, B2),
    ?assertEqual(<<"audio/mpeg">>, proplists:get_value(<<"content-type">>, H2)),
    #{path := P2, body := Up2} = lists:last(lg_mock_upstream:requests()),
    ?assertEqual(<<"/v1/t2a_v2">>, P2),
    ?assertMatch(#{<<"text">> := <<"你好世界"/utf8>>, <<"stream">> := false,
                   <<"voice_setting">> := #{<<"voice_id">> := <<"male-qn-qingse">>},
                   <<"audio_setting">> := #{<<"format">> := <<"mp3">>}}, Up2),
    {ok, _} = lg_credentials:update(C, #{<<"options">> => #{<<"media_api">> => null}}),
    ok = lg_routes:delete(<<"tts">>),
    lg_cooldown:clear().

%% 透传会话同样在本地展开历史（上游可能无状态，如 MiniMax 会忽略 previous_response_id）
responses_passthrough_history(#{key := K} = Ctx) ->
    reset_upstream(),
    Native = fun(Id, Text) ->
                     #{<<"id">> => Id, <<"object">> => <<"response">>, <<"status">> => <<"completed">>,
                       <<"model">> => <<"rs-up">>,
                       <<"output">> => [#{<<"type">> => <<"message">>, <<"id">> => <<"msg_1">>,
                                          <<"role">> => <<"assistant">>, <<"status">> => <<"completed">>,
                                          <<"content">> => [#{<<"type">> => <<"output_text">>, <<"text">> => Text}]}],
                       <<"usage">> => #{<<"input_tokens">> => 3, <<"output_tokens">> => 2}}
             end,
    lg_mock_upstream:expect({json, 200, #{}, Native(<<"resp_up1">>, <<"first answer">>)}),
    {200, _, B1} = post(Ctx, <<"/v1/responses">>, K, #{<<"model">> => <<"native">>, <<"input">> => <<"q1">>}),
    #{<<"id">> := Id1} = json:decode(B1),
    timer:sleep(100),
    lg_mock_upstream:expect({json, 200, #{}, Native(<<"resp_up2">>, <<"second answer">>)}),
    {200, _, _} = post(Ctx, <<"/v1/responses">>, K,
                       #{<<"model">> => <<"native">>, <<"previous_response_id">> => Id1, <<"input">> => <<"q2">>}),
    #{path := Path, body := UpBody} = lists:last(lg_mock_upstream:requests()),
    ?assertEqual(<<"/v1/responses">>, Path),
    ?assertNot(maps:is_key(<<"previous_response_id">>, UpBody)),
    ?assertMatch([#{<<"role">> := <<"user">>, <<"content">> := <<"q1">>},
                  #{<<"role">> := <<"assistant">>, <<"content">> := [#{<<"text">> := <<"first answer">>}]},
                  #{<<"role">> := <<"user">>, <<"content">> := <<"q2">>}],
                 maps:get(<<"input">>, UpBody)).

%% 原生 Responses 与 Chat 不在同一基址（如智谱 /api/v1 与 /api/paas/v4）：options.responses_base_url
responses_base_url(#{key := K, base := Base} = Ctx) ->
    reset_upstream(),
    {ok, #lg_credential{id = C}} =
        lg_credentials:create(#{<<"name">> => <<"split-base">>, <<"protocol">> => <<"openai">>,
                                <<"base_url">> => <<"http://127.0.0.1:1/v4">>, <<"api_key">> => <<"k">>,
                                <<"options">> => #{<<"responses_api">> => true, <<"responses_base_url">> => Base}}),
    ?assertMatch({error, {invalid, <<"options.responses_base_url">>}},
                 lg_credentials:update(C, #{<<"options">> => #{<<"responses_base_url">> => <<"ftp://x">>}})),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"split">>,
                                 <<"targets">> => [#{<<"credential">> => C, <<"upstream_model">> => <<"sp-up">>}]}),
    lg_mock_upstream:expect({json, 200, #{}, #{<<"id">> => <<"resp_x">>, <<"object">> => <<"response">>,
                                               <<"status">> => <<"completed">>, <<"output">> => [],
                                               <<"usage">> => #{<<"input_tokens">> => 1, <<"output_tokens">> => 1}}}),
    {200, _, _} = post(Ctx, <<"/v1/responses">>, K, #{<<"model">> => <<"split">>, <<"input">> => <<"hi">>}),
    ?assertMatch(#{path := <<"/v1/responses">>, body := #{<<"model">> := <<"sp-up">>}}, lists:last(lg_mock_upstream:requests())),
    ok = lg_routes:delete(<<"split">>).

count_tokens(#{key := K} = Ctx) ->
    reset_upstream(),
    lg_mock_upstream:expect({json, 200, #{}, #{<<"input_tokens">> => 9}}),
    Body = #{<<"model">> => <<"mixed">>,
             <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]},
    #{items := Before} = lg_store:logs(#{limit => 500}),
    {200, _, B} = post(Ctx, <<"/v1/messages/count_tokens">>, [{<<"x-api-key">>, K}], K, Body),
    ?assertEqual(#{<<"input_tokens">> => 9}, json:decode(B)),
    ?assertEqual([<<"claude-up">>], upstream_models()),
    #{path := Path, headers := UpH} = lists:last(lg_mock_upstream:requests()),
    ?assertEqual(<<"/v1/messages/count_tokens">>, Path),
    ?assertEqual(<<"ak">>, maps:get(<<"x-api-key">>, UpH)),
    %% 不记日志
    #{items := After} = lg_store:logs(#{limit => 500}),
    ?assertEqual(length(Before), length(After)),
    %% gpt 路由只有 openai 目标：本地估算（带 x-litegate-estimated）
    Long = #{<<"model">> => <<"gpt">>, <<"system">> => <<"You are helpful.">>,
             <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"你好，世界！hello world">>}]},
    {200, H2, B2} = post(Ctx, <<"/v1/messages/count_tokens">>, [{<<"x-api-key">>, K}], K, Long),
    ?assertEqual(<<"true">>, proplists:get_value(<<"x-litegate-estimated">>, H2)),
    #{<<"input_tokens">> := N} = json:decode(B2),
    ?assert(N > 5 andalso N < 30),
    %% 上游对非空请求返回 0（智谱按量 API 实测）：改用本地估算
    lg_mock_upstream:expect({json, 200, #{}, #{<<"input_tokens">> => 0}}),
    {200, H0, B0} = post(Ctx, <<"/v1/messages/count_tokens">>, [{<<"x-api-key">>, K}], K, Body),
    ?assertEqual(<<"true">>, proplists:get_value(<<"x-litegate-estimated">>, H0)),
    ?assertMatch(#{<<"input_tokens">> := N0} when N0 > 0, json:decode(B0)),
    %% 上游不支持（404）：同样估算
    lg_mock_upstream:expect({json, 404, #{}, #{<<"error">> => #{<<"message">> => <<"not found">>}}}),
    {200, H3, _} = post(Ctx, <<"/v1/messages/count_tokens">>, [{<<"x-api-key">>, K}], K, Body),
    ?assertEqual(<<"true">>, proplists:get_value(<<"x-litegate-estimated">>, H3)),
    %% 路由不存在仍是 404
    {404, _, _} = post(Ctx, <<"/v1/messages/count_tokens">>, [{<<"x-api-key">>, K}], K, Body#{<<"model">> => <<"nope">>}),
    lg_cooldown:clear().

metrics(Ctx) ->
    {200, H, B} = req(Ctx, <<"GET">>, <<"/metrics">>, [], <<>>),
    ?assertMatch(<<"text/plain", _/binary>>, proplists:get_value(<<"content-type">>, H)),
    %% 之前的测试已有成功与被限流的请求、上游 503 尝试
    [?assertNotEqual(nomatch, binary:match(B, P)) || P <- [
        <<"litegate_requests_total{format=\"openai\",route=\"gpt\",status=\"200\"}">>,
        <<"litegate_rate_limited_total{reason=\"rpm\"}">>,
        <<"litegate_rate_limited_total{reason=\"budget\"}">>,
        <<"outcome=\"server\"">>,
        <<"litegate_request_duration_seconds_bucket{format=\"embeddings\"">>,
        <<"litegate_http_pool_idle_connections{host=\"tcp://127.0.0.1:">>,
        <<"litegate_cooling_targets ">>,
        <<"litegate_ttft_seconds_count{format=\"anthropic\",route=\"gpt\"}">>,
        <<"litegate_active_streams 0">>]],
    ok = lg_config:set(metrics_token, <<"s3cret">>),
    ?assertMatch({401, _, _}, req(Ctx, <<"GET">>, <<"/metrics">>, [], <<>>)),
    ?assertMatch({401, _, _}, req(Ctx, <<"GET">>, <<"/metrics">>, [{<<"authorization">>, <<"Bearer nope">>}], <<>>)),
    ?assertMatch({200, _, _}, req(Ctx, <<"GET">>, <<"/metrics">>, [{<<"authorization">>, <<"Bearer s3cret">>}], <<>>)),
    ok = lg_config:unset(metrics_token).

wildcard(#{key := K} = Ctx) ->
    reset_upstream(),
    {ok, #lg_route{targets = [#{credential := C1} | _]}} = lg_routes:get(<<"gpt">>),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"w/*">>,
                                 <<"targets">> => [#{<<"credential">> => C1, <<"upstream_model">> => <<"*">>}]}),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"wild">>)}),
    {200, H, _} = post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"w/vendor/some-model">>)),
    ?assertEqual([<<"vendor/some-model">>], upstream_models()),
    ?assertMatch(#{route := <<"w/*">>, model := <<"w/vendor/some-model">>, upstream_model := <<"vendor/some-model">>},
                 wait_log(proplists:get_value(<<"x-request-id">>, H))),
    %% 前缀本身不匹配
    ?assertMatch({404, _, _}, post(Ctx, <<"/v1/chat/completions">>, K, chat(<<"w/">>))),
    ok = lg_routes:delete(<<"w/*">>).

response_cache(#{key := K} = Ctx) ->
    reset_upstream(),
    {ok, _} = lg_routes:update(<<"gpt">>, #{<<"options">> => #{<<"cache_ttl_s">> => 60}}),
    Req = (chat(<<"gpt">>))#{<<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"cache me">>}]},
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"cached answer">>)}),
    {200, H1, B1} = post(Ctx, <<"/v1/chat/completions">>, K, Req),
    ?assertEqual(undefined, proplists:get_value(<<"x-litegate-cache">>, H1)),
    %% 缓存写入是异步的
    timer:sleep(100),
    %% 命中：不访问上游，响应体一致；user 字段不同不影响命中
    {200, H2, B2} = post(Ctx, <<"/v1/chat/completions">>, K, Req#{<<"user">> => <<"someone">>}),
    ?assertEqual(<<"hit">>, proplists:get_value(<<"x-litegate-cache">>, H2)),
    ?assertEqual(B1, B2),
    ?assertEqual(1, length(upstream_models())),
    ?assertMatch(#{cache_hit := true, cost := +0.0, usage := #{input := 0, output := 0}},
                 wait_log(proplists:get_value(<<"x-request-id">>, H2))),
    %% no-cache 跳过缓存
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"fresh">>)}),
    {200, H3, _} = post(Ctx, <<"/v1/chat/completions">>,
                        [{<<"authorization">>, <<"Bearer ", K/binary>>}, {<<"cache-control">>, <<"no-cache">>}], K, Req),
    ?assertEqual(undefined, proplists:get_value(<<"x-litegate-cache">>, H3)),
    ?assertEqual(2, length(upstream_models())),
    %% 不同请求体不命中；上游错误不缓存
    Req2 = Req#{<<"temperature">> => 0.5},
    lg_mock_upstream:expect({json, 500, #{}, <<"x">>}),
    lg_mock_upstream:expect({json, 500, #{}, <<"y">>}),
    {500, _, _} = post(Ctx, <<"/v1/chat/completions">>, K, Req2),
    lg_cooldown:clear(),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"after error">>)}),
    {200, H4, _} = post(Ctx, <<"/v1/chat/completions">>, K, Req2),
    ?assertEqual(undefined, proplists:get_value(<<"x-litegate-cache">>, H4)),
    %% 流式请求不走缓存
    Frames = [iolist_to_binary(lg_sse:encode(json:encode(
                #{<<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{<<"content">> => <<"s">>}}]})))
              , lg_sse:done()],
    lg_mock_upstream:expect({sse, Frames}),
    {200, H5, _} = post(Ctx, <<"/v1/chat/completions">>, K, Req#{<<"stream">> => true}),
    ?assertEqual(undefined, proplists:get_value(<<"x-litegate-cache">>, H5)),
    {ok, _} = lg_routes:update(<<"gpt">>, #{<<"options">> => #{<<"cache_ttl_s">> => null}}),
    lg_cooldown:clear().

responses_api(#{key := K} = Ctx) ->
    reset_upstream(),
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"first answer">>)}),
    {200, H1, B1} = post(Ctx, <<"/v1/responses">>, K, #{<<"model">> => <<"gpt">>, <<"input">> => <<"first question">>}),
    #{<<"id">> := Id1, <<"object">> := <<"response">>,
      <<"output">> := [#{<<"content">> := [#{<<"text">> := <<"first answer">>}]}]} = json:decode(B1),
    ?assertMatch(#{format := responses, status := 200}, wait_log(proplists:get_value(<<"x-request-id">>, H1))),
    ?assertMatch({ok, #{request := #{<<"messages">> := [#{<<"content">> := <<"first question">>}]},
                        response := <<"first answer">>}},
                 lg_store:messages(proplists:get_value(<<"x-request-id">>, H1))),
    timer:sleep(100),
    %% previous_response_id：在本地展开历史后转发
    lg_mock_upstream:expect({json, 200, #{}, completion(<<"second answer">>)}),
    {200, _, B2} = post(Ctx, <<"/v1/responses">>, K,
                        #{<<"model">> => <<"gpt">>, <<"previous_response_id">> => Id1,
                          <<"input">> => <<"second question">>, <<"store">> => false}),
    #{<<"id">> := Id2} = json:decode(B2),
    #{body := UpBody} = lists:last(lg_mock_upstream:requests()),
    ?assertEqual([<<"first question">>, <<"first answer">>, <<"second question">>],
                 [maps:get(<<"content">>, M) || M <- maps:get(<<"messages">>, UpBody)]),
    ?assertNot(maps:is_key(<<"previous_response_id">>, UpBody)),
    %% store: false 的响应不保存
    timer:sleep(100),
    {400, _, B3} = post(Ctx, <<"/v1/responses">>, K,
                        #{<<"model">> => <<"gpt">>, <<"previous_response_id">> => Id2, <<"input">> => <<"x">>}),
    ?assertMatch(#{<<"error">> := #{<<"message">> := <<"Previous response `", _/binary>>}}, json:decode(B3)),
    %% 流式
    Frames = [iolist_to_binary(lg_sse:encode(json:encode(C))) || C <-
                 [#{<<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{<<"content">> => <<"str">>}}]},
                  #{<<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{<<"content">> => <<"eam">>},
                                        <<"finish_reason">> => <<"stop">>}]},
                  #{<<"choices">> => [], <<"usage">> => #{<<"prompt_tokens">> => 2, <<"completion_tokens">> => 2}}]]
             ++ [lg_sse:done()],
    lg_mock_upstream:expect({sse, Frames}),
    {200, H4, Sse} = post(Ctx, <<"/v1/responses">>, K,
                          #{<<"model">> => <<"gpt">>, <<"input">> => <<"s">>, <<"stream">> => true}),
    {Evs, <<>>} = lg_sse:parse(Sse),
    ?assertEqual(<<"response.completed">>, maps:get(event, lists:last(Evs))),
    ?assertMatch(#{format := responses, stream := true, usage := #{input := 2, output := 2}, ttft_ms := _},
                 wait_log(proplists:get_value(<<"x-request-id">>, H4))).
