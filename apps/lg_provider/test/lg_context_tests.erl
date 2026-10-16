-module(lg_context_tests).

-include_lib("eunit/include/eunit.hrl").

anthropic_test() ->
    Body = #{<<"system">> => [#{<<"type">> => <<"text">>, <<"text">> => binary:copy(<<"abcd">>, 100)}],
             <<"tools">> => [#{<<"name">> => <<"Bash">>, <<"description">> => binary:copy(<<"x">>, 400),
                               <<"input_schema">> => #{}},
                             #{<<"name">> => <<"Read">>, <<"description">> => <<"r">>, <<"input_schema">> => #{}}],
             <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => binary:copy(<<"u">>, 40)},
                                #{<<"role">> => <<"assistant">>,
                                  <<"content">> => [#{<<"type">> => <<"thinking">>, <<"thinking">> => <<"hmm">>,
                                                      <<"signature">> => binary:copy(<<"s">>, 4000)},
                                                    #{<<"type">> => <<"tool_use">>, <<"id">> => <<"t1">>,
                                                      <<"name">> => <<"Bash">>, <<"input">> => #{<<"c">> => <<"ls">>}}]},
                                #{<<"role">> => <<"user">>,
                                  <<"content">> => [#{<<"type">> => <<"tool_result">>, <<"tool_use_id">> => <<"t1">>,
                                                      <<"content">> => binary:copy(<<"o">>, 80)},
                                                    #{<<"type">> => <<"image">>, <<"source">> => #{<<"data">> => <<"zz">>}}]}]},
    C = lg_context:breakdown(anthropic, Body),
    ?assertMatch(#{system := 100, images := 1500, messages := 3}, C),
    #{tool_list := [#{name := <<"Bash">>, tokens := Big}, #{name := <<"Read">>}], tools := Tools} = C,
    ?assert(Big > 100),
    ?assert(Tools > Big),
    %% 历史：首条用户消息 + 助手（签名不计）；本轮：工具结果
    #{history := H, input := I} = C,
    ?assert(H < 40),
    ?assertEqual(4 + 20, I),
    ?assertEqual(maps:get(total, C), 100 + Tools + H + I + 1500).

openai_test() ->
    Body = #{<<"messages">> => [#{<<"role">> => <<"system">>, <<"content">> => binary:copy(<<"s">>, 40)},
                                #{<<"role">> => <<"user">>, <<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"hello">>},
                                                                              #{<<"type">> => <<"image_url">>,
                                                                                <<"image_url">> => #{<<"url">> => <<"data:x">>}}]}],
             <<"tools">> => [#{<<"type">> => <<"function">>, <<"function">> => #{<<"name">> => <<"f">>}}]},
    C = lg_context:breakdown(openai, Body),
    ?assertMatch(#{system := 10, history := 0, input := 6, images := 1500, tool_list := [#{name := <<"f">>}]}, C).

responses_test() ->
    Body = #{<<"instructions">> => binary:copy(<<"i">>, 40),
             <<"input">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"do it">>},
                             #{<<"type">> => <<"reasoning">>, <<"encrypted_content">> => binary:copy(<<"e">>, 4000)},
                             #{<<"type">> => <<"function_call">>, <<"name">> => <<"sh">>, <<"arguments">> => <<"{}">>},
                             #{<<"type">> => <<"function_call_output">>, <<"output">> => binary:copy(<<"o">>, 40)}]},
    C = lg_context:breakdown(responses, Body),
    ?assertMatch(#{system := 10, input := 14, messages := 4}, C),
    ?assert(maps:get(history, C) < 30),
    ?assertMatch(#{system := 0, input := 7}, lg_context:breakdown(responses, #{<<"input">> => <<"hi there!">>})).
