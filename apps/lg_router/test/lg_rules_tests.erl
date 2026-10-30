-module(lg_rules_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("lg_core/include/lg_core.hrl").

valid_test() ->
    ?assert(lg_rules:valid_rules([])),
    ?assert(lg_rules:valid_rules([#{<<"when">> => #{<<"min_tokens">> => 128000}, <<"use">> => <<"long">>},
                                  #{<<"when">> => #{<<"intent">> => <<"writing tests">>, <<"client">> => [<<"anthropic">>]},
                                    <<"use">> => <<"strong">>},
                                  #{<<"when">> => #{<<"hours">> => <<"22:00-06:00">>}, <<"skip">> => [<<"cred_x">>]},
                                  #{<<"use">> => <<"default">>}])),
    [?assertNot(lg_rules:valid_rules([R])) || R <- [
        #{<<"use">> => <<"a">>, <<"skip">> => [<<"c">>]},             %% 动作二选一
        #{<<"when">> => #{}},                                          %% 没有动作
        #{<<"when">> => #{<<"bogus">> => 1}, <<"use">> => <<"a">>},
        #{<<"when">> => #{<<"hours">> => <<"9-18">>}, <<"use">> => <<"a">>},
        %% 起始 24 点或带分钟数的 24 点结束界都不合法（历史上 24:xx 被放行但永不命中）
        #{<<"when">> => #{<<"hours">> => <<"24:30-02:00">>}, <<"use">> => <<"a">>},
        #{<<"when">> => #{<<"hours">> => <<"24:00-24:00">>}, <<"use">> => <<"a">>},
        #{<<"when">> => #{<<"hours">> => <<"09:00-24:30">>}, <<"use">> => <<"a">>},
        #{<<"when">> => #{<<"hours">> => <<"09:60-12:00">>}, <<"use">> => <<"a">>},
        #{<<"when">> => #{<<"client">> => [<<"grpc">>]}, <<"use">> => <<"a">>},
        #{<<"when">> => #{<<"images">> => <<"yes">>}, <<"use">> => <<"a">>},
        #{<<"skip">> => []},
        #{<<"use">> => <<"a">>, <<"extra">> => 1}]],
    ?assertNot(lg_rules:valid_rules(lists:duplicate(17, #{<<"use">> => <<"a">>}))),
    ?assertNot(lg_rules:valid_rules(#{})).

answer_test() ->
    ?assertEqual(2, lg_rules:parse_answer(<<"2">>, 3)),
    %% 回答开头（允许空白、标点、Markdown 装饰前缀）的整数
    ?assertEqual(2, lg_rules:parse_answer(<<" 2">>, 3)),
    ?assertEqual(2, lg_rules:parse_answer(<<"2. 编写测试"/utf8>>, 3)),
    ?assertEqual(1, lg_rules:parse_answer(<<"**1** writing tests">>, 3)),
    ?assertEqual(3, lg_rules:parse_answer(<<"(3)">>, 3)),
    %% 正文后置的数字视为叙述内容不作数（R7）
    ?assertEqual(0, lg_rules:parse_answer(<<"The answer is 1.">>, 3)),
    ?assertEqual(0, lg_rules:parse_answer(<<"kind #2">>, 3)),
    ?assertEqual(0, lg_rules:parse_answer(<<"第 2 类"/utf8>>, 3)),
    ?assertEqual(0, lg_rules:parse_answer(<<"0">>, 3)),
    ?assertEqual(0, lg_rules:parse_answer(<<"7">>, 3)),
    ?assertEqual(0, lg_rules:parse_answer(<<"none">>, 3)),
    %% 正文里的思考块（MiniMax OpenAI 接口实测）不参与解析
    ?assertEqual(2, lg_rules:parse_answer(<<"<think>\nThe kinds are 1. quick question and 2. tests.\n</think>\n\n2">>, 2)),
    ?assertEqual(0, lg_rules:parse_answer(<<"<think>\nKind 1 looks close">>, 2)),
    #{<<"user">> := U} = lg_rules:prompt([<<"a quick question">>, <<"writing tests">>], <<"写个测试"/utf8>>),
    ?assertEqual(<<"Kinds of request:\n1. a quick question\n2. writing tests\n\nMessage:\n写个测试"/utf8>>, U).

conditions_test() ->
    Facts = #{tokens => fun() -> 500 end, images => true, thinking => false},
    M = fun(W) -> lg_rules:matches(W, Facts, anthropic, #{tags => [<<"tool:cc">>]}) end,
    ?assert(M(#{})),
    ?assert(M(#{<<"min_tokens">> => 100, <<"max_tokens">> => 1000})),
    ?assertNot(M(#{<<"min_tokens">> => 1000})),
    ?assert(M(#{<<"images">> => true, <<"thinking">> => false})),
    ?assert(M(#{<<"client">> => [<<"openai">>, <<"anthropic">>]})),
    ?assertNot(M(#{<<"client">> => [<<"openai">>]})),
    ?assert(M(#{<<"tags">> => [<<"x">>, <<"tool:cc">>]})),
    ?assertNot(M(#{<<"tags">> => [<<"x">>]})),
    ?assert(M(#{<<"hours">> => <<"00:00-24:00">>})),   %% 24:00 作排他结束界 = 全天
    ?assertNot(M(#{<<"hours">> => <<"24:00-24:00">>})). %% 非法时段在校验层就被拒，判定层永不出现

laya_test() ->
    Is = [<<"美化：改进界面"/utf8>>, <<"读取文件：只读"/utf8>>],
    %% 每条意图一道 noul，id 为 ASCII 的 i1..iN
    ?assertEqual(#{<<"i1">> => #{<<"type">> => <<"noul">>, <<"instructions">> => <<"这条消息是否属于：美化：改进界面"/utf8>>},
                   <<"i2">> => #{<<"type">> => <<"noul">>, <<"instructions">> => <<"这条消息是否属于：读取文件：只读"/utf8>>}},
                 lg_laya:questions(Is)),
    R = fun(P1, P2) -> json:encode(#{<<"answers">> => #{<<"i1">> => #{<<"type">> => <<"noul">>, <<"noul">> => P1},
                                                         <<"i2">> => #{<<"type">> => <<"noul">>, <<"noul">> => P2}}}) end,
    ?assertEqual({ok, 2, <<"i2 0.91（0.30 / 0.91）"/utf8>>}, lg_laya:parse(Is, R(0.3, 0.91), 0.7)),
    ?assertMatch({ok, 1, _}, lg_laya:parse(Is, R(0.89, 0.48), 0.7)),
    %% 最高概率不足阈值：都不是
    ?assertMatch({ok, 0, <<"i1 0.69", _/binary>>}, lg_laya:parse(Is, R(0.69, 0.07), 0.7)),
    %% 缺少某道题的回答、上游错误、非 JSON
    ?assertEqual({error, <<"unexpected decision reply">>},
                 lg_laya:parse(Is, json:encode(#{<<"answers">> => #{<<"i1">> => #{<<"noul">> => 0.9}}}), 0.7)),
    ?assertEqual({error, <<"no GGUF">>}, lg_laya:parse(Is, json:encode(#{<<"error">> => #{<<"message">> => <<"no GGUF">>}}), 0.7)),
    ?assertMatch({error, _}, lg_laya:parse(Is, <<"not json">>, 0.7)).

%%====================================================================
%% T27：判断者熔断与相同判断合并（经模拟上游的判断路由）
%%====================================================================

classifier_test_() ->
    {setup,
     fun() ->
             Dir = lg_core_test_util:start(),
             {ok, _} = application:ensure_all_started(lg_router),
             Port = lg_mock_upstream:start(),
             Base = iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port), "/v1"]),
             {ok, #lg_credential{id = C}} = lg_credentials:create(#{<<"name">> => <<"j">>, <<"protocol">> => <<"openai">>,
                                                                     <<"base_url">> => Base, <<"api_key">> => <<"k">>}),
             T = #{<<"credential">> => C, <<"upstream_model">> => <<"judge-up">>},
             {ok, _} = lg_routes:create(#{<<"name">> => <<"judge">>, <<"targets">> => [T]}),
             {ok, _} = lg_routes:create(#{<<"name">> => <<"main">>, <<"targets">> => [T],
                                          <<"options">> => #{<<"classifier">> => <<"judge">>,
                                                             <<"rules">> => [#{<<"when">> => #{<<"intent">> => <<"tests">>},
                                                                               <<"use">> => <<"judge">>}]}}),
             {ok, _, Key} = lg_api_keys:create(#{<<"name">> => <<"k">>}),
             {Dir, Key}
     end,
     fun({Dir, _}) ->
             application:unset_env(lg_core, intent_timeout_ms),
             application:unset_env(lg_router, classifier_open_ms),
             lg_mock_upstream:stop(),
             application:stop(lg_router),
             lg_core_test_util:stop(Dir)
     end,
     fun({_, Key}) ->
             [{timeout, 30, ?_test(breaker(Key))},
              {timeout, 30, ?_test(singleflight(Key))}]
     end}.

completion(Text) ->
    {json, 200, #{}, #{<<"id">> => <<"cc">>, <<"model">> => <<"up">>,
                       <<"choices">> => [#{<<"index">> => 0, <<"finish_reason">> => <<"stop">>,
                                           <<"message">> => #{<<"role">> => <<"assistant">>, <<"content">> => Text}}],
                       <<"usage">> => #{<<"prompt_tokens">> => 1, <<"completion_tokens">> => 1}}}.

decide(Key, Text) ->
    {ok, R} = lg_routes:get(<<"main">>),
    T0 = erlang:monotonic_time(millisecond),
    D = lg_rules:decide(R, openai, #{<<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => Text}]},
                        #{new_turn => true, key => Key}),
    {maps:get(intent, D), erlang:monotonic_time(millisecond) - T0}.

judge_calls() ->
    length(lg_mock_upstream:requests()).

skipped() ->
    case ets:lookup(lg_metrics, {litegate_classifier_skipped_total, [{classifier, <<"judge">>}]}) of
        [{_, N}] -> N;
        [] -> 0
    end.

%% 判断模型持续超时：前 3 个请求各等满超时，第 4 个起直接跳过（不调用、无额外延迟）；
%% 打开期过后放行一个试探请求，失败重新打开，成功恢复
breaker(Key) ->
    lg_affinity:clear(),
    ets:insert(lg_mock_upstream, {requests, []}),
    application:set_env(lg_core, intent_timeout_ms, 150),
    application:set_env(lg_router, classifier_open_ms, 400),
    Slow = {delay, 600, completion(<<"1">>)},
    [lg_mock_upstream:expect(Slow) || _ <- lists:seq(1, 4)],
    [begin
         {I, Ms} = decide(Key, <<"q", (integer_to_binary(N))/binary>>),
         ?assertMatch(#{error := <<"timeout">>}, I),
         ?assert(Ms >= 150)
     end || N <- lists:seq(1, 3)],
    ?assertEqual(3, judge_calls()),
    S0 = skipped(),
    {I4, Ms4} = decide(Key, <<"q4">>),
    ?assertMatch(#{answer := 0, error := <<"classifier circuit open">>}, I4),
    ?assert(Ms4 < 100),
    ?assertEqual(3, judge_calls()),
    ?assertEqual(S0 + 1, skipped()),
    %% 打开期过后：试探请求仍超时 → 重新打开
    timer:sleep(450),
    {I5, _} = decide(Key, <<"q5">>),
    ?assertMatch(#{error := <<"timeout">>}, I5),
    ?assertEqual(4, judge_calls()),
    {I6, Ms6} = decide(Key, <<"q6">>),
    ?assertMatch(#{error := <<"classifier circuit open">>}, I6),
    ?assert(Ms6 < 100),
    %% 再过打开期：试探成功 → 关闭，之后照常判断
    timer:sleep(700),    %% 也等前面被放弃的判断跑完（照常记日志、计费）
    lg_mock_upstream:expect(completion(<<"1">>)),
    lg_mock_upstream:expect(completion(<<"0">>)),
    {I7, _} = decide(Key, <<"q7">>),
    ?assertMatch(#{answer := 1, classifier := <<"judge">>}, I7),
    {I8, _} = decide(Key, <<"q8">>),
    ?assertMatch(#{answer := 0}, I8),
    ?assertNot(maps:is_key(error, I8)),
    ?assertEqual(6, judge_calls()),
    %% 被放弃的判断（超时后不再杀掉）照常记了日志
    ?assert(intent_logs(6, 50) >= 6),
    application:unset_env(lg_router, classifier_open_ms),
    application:unset_env(lg_core, intent_timeout_ms).

intent_logs(N, Left) ->
    #{items := Logs} = lg_store:logs(#{tag => <<"litegate:intent">>, limit => 20}),
    case length(Logs) of
        L when L >= N; Left =:= 0 -> L;
        _ -> timer:sleep(50), intent_logs(N, Left - 1)
    end.

%% 相同消息的并发判断只调用一次判断模型，其余请求拿到同一结果
singleflight(Key) ->
    lg_affinity:clear(),
    ets:insert(lg_mock_upstream, {requests, []}),
    application:set_env(lg_core, intent_timeout_ms, 2000),
    lg_mock_upstream:expect({delay, 300, completion(<<"1">>)}),
    Self = self(),
    Pids = [spawn(fun() -> Self ! {self(), decide(Key, <<"same question">>)} end) || _ <- lists:seq(1, 4)],
    Rs = [receive {P, {I, _}} -> I after 5000 -> error(timeout) end || P <- Pids],
    ?assertEqual([1, 1, 1, 1], [A || #{answer := A} <- Rs]),
    ?assertEqual(3, length([x || #{shared := true} <- Rs])),
    ?assertEqual(1, judge_calls()),
    application:unset_env(lg_core, intent_timeout_ms).
