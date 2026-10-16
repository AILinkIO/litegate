-module(lg_rules_tests).

-include_lib("eunit/include/eunit.hrl").

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
