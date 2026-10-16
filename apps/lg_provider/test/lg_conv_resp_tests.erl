-module(lg_conv_resp_tests).

-include_lib("eunit/include/eunit.hrl").

resp_a2o_test() ->
    R = lg_conv_resp:anthropic_to_openai(
          #{<<"id">> => <<"msg_1">>, <<"model">> => <<"claude">>, <<"stop_reason">> => <<"tool_use">>,
            <<"content">> => [#{<<"type">> => <<"thinking">>, <<"thinking">> => <<"t">>},
                              #{<<"type">> => <<"text">>, <<"text">> => <<"hello">>},
                              #{<<"type">> => <<"tool_use">>, <<"id">> => <<"tu">>,
                                <<"name">> => <<"f">>, <<"input">> => #{}}],
            <<"usage">> => #{<<"input_tokens">> => 5, <<"output_tokens">> => 7}}),
    ?assertMatch(#{<<"id">> := <<"msg_1">>, <<"object">> := <<"chat.completion">>,
                   <<"choices">> := [#{<<"finish_reason">> := <<"tool_calls">>,
                                       <<"message">> := #{<<"content">> := <<"hello">>,
                                                          <<"reasoning_content">> := <<"t">>,
                                                          <<"tool_calls">> := [#{<<"id">> := <<"tu">>}]}}],
                   <<"usage">> := #{<<"prompt_tokens">> := 5, <<"completion_tokens">> := 7}}, R).

resp_o2a_test() ->
    R = lg_conv_resp:openai_to_anthropic(
          #{<<"id">> => <<"cc">>, <<"model">> => <<"gpt">>,
            <<"choices">> => [#{<<"finish_reason">> => <<"length">>,
                                <<"message">> => #{<<"content">> => <<"hi">>,
                                                   <<"tool_calls">> => [#{<<"id">> => <<"c">>,
                                                                          <<"function">> => #{<<"name">> => <<"f">>,
                                                                                              <<"arguments">> => <<"{\"x\":2}">>}}]}}],
            <<"usage">> => #{<<"prompt_tokens">> => 10, <<"completion_tokens">> => 3,
                             <<"prompt_tokens_details">> => #{<<"cached_tokens">> => 4}}}),
    ?assertMatch(#{<<"type">> := <<"message">>, <<"stop_reason">> := <<"max_tokens">>,
                   <<"content">> := [#{<<"type">> := <<"text">>, <<"text">> := <<"hi">>},
                                     #{<<"type">> := <<"tool_use">>, <<"input">> := #{<<"x">> := 2}}],
                   <<"usage">> := #{<<"input_tokens">> := 6, <<"cache_read_input_tokens">> := 4,
                                    <<"output_tokens">> := 3}}, R).
