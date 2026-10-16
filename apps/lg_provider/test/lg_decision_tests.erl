-module(lg_decision_tests).

-include_lib("eunit/include/eunit.hrl").

-define(IS, [<<"美化：改进界面"/utf8>>, <<"读取文件：只读"/utf8>>]).

request_test() ->
    #{<<"state">> := #{<<"message">> := M}, <<"questions">> := Q} = lg_decision:request(noul, ?IS, <<"你好世界"/utf8>>, 2),
    ?assertEqual(<<"你好"/utf8>>, M),   %% 按字符截断
    ?assertEqual([<<"i1">>, <<"i2">>], lists:sort(maps:keys(Q))).

choice_questions_test() ->
    ?assertEqual(#{<<"intent">> => #{<<"type">> => <<"choice">>, <<"instructions">> => <<"这条消息属于哪一类？"/utf8>>,
                                     <<"criteria">> => #{<<"i1">> => <<"美化：改进界面"/utf8>>,
                                                         <<"i2">> => <<"读取文件：只读"/utf8>>,
                                                         <<"other">> => <<"以上都不是"/utf8>>}}},
                 lg_decision:questions(choice, ?IS)).

choice_parse_test() ->
    R = fun(C, Ps) -> #{<<"answers">> => #{<<"intent">> => #{<<"type">> => <<"choice">>, <<"choice">> => C,
                                                             <<"confidence">> => 0.9, <<"probabilities">> => Ps}}} end,
    Ps = #{<<"i1">> => 0.03, <<"i2">> => 0.91, <<"other">> => 0.06},
    ?assertEqual({ok, 2, <<"i2 0.91（i1 0.03 / i2 0.91 / other 0.06）"/utf8>>},
                 lg_decision:parse(choice, ?IS, json:encode(R(<<"i2">>, Ps)), 0.7)),
    %% 选中项概率不足阈值、选中 other、越界：都不是
    ?assertMatch({ok, 0, <<"i1 0.55", _/binary>>},
                 lg_decision:parse(choice, ?IS, R(<<"i1">>, #{<<"i1">> => 0.55, <<"other">> => 0.45}), 0.7)),
    ?assertMatch({ok, 0, <<"other", _/binary>>}, lg_decision:parse(choice, ?IS, R(<<"other">>, #{<<"other">> => 0.96}), 0.7)),
    ?assertMatch({ok, 0, _}, lg_decision:parse(choice, ?IS, R(<<"i9">>, #{<<"i9">> => 0.99}), 0.7)),
    %% 没有概率表时以 confidence 作为选中项概率
    ?assertMatch({ok, 1, _}, lg_decision:parse(choice, ?IS, #{<<"answers">> => #{<<"intent">> => #{<<"choice">> => <<"i1">>,
                                                                                                    <<"confidence">> => 0.8}}}, 0.7)),
    %% 回答缺题、上游错误
    ?assertEqual({error, <<"unexpected decision reply">>}, lg_decision:parse(choice, ?IS, #{<<"answers">> => #{}}, 0.7)),
    ?assertEqual({error, <<"bad key">>}, lg_decision:parse(choice, ?IS, #{<<"error">> => #{<<"message">> => <<"bad key">>}}, 0.7)).

summary_test() ->
    J = #{<<"answers">> => #{<<"department">> => #{<<"choice">> => <<"billing">>, <<"confidence">> => 0.88},
                             <<"escalate">> => #{<<"noul">> => 0.99},
                             <<"severity">> => #{<<"score">> => 2.25, <<"confidence">> => 0.91}}},
    ?assertEqual(<<"department=billing(0.88); escalate=0.99; severity=2.25">>, lg_decision:summary(J)),
    ?assertEqual(<<>>, lg_decision:summary(#{})).
