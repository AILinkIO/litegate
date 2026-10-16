-module(lg_conv_req_tests).

-include_lib("eunit/include/eunit.hrl").

o2a(Req) -> {ok, B} = lg_conv_req:openai_to_anthropic(Req, #{}), B.
a2o(Req) -> {ok, B} = lg_conv_req:anthropic_to_openai(Req, #{}), B.

o2a_basic_test() ->
    B = o2a(#{<<"model">> => <<"x">>, <<"temperature">> => 1.5, <<"stop">> => <<"END">>,
              <<"stream">> => true, <<"user">> => <<"u1">>, <<"frequency_penalty">> => 1,
              <<"messages">> => [#{<<"role">> => <<"system">>, <<"content">> => <<"sys">>},
                                 #{<<"role">> => <<"developer">>, <<"content">> => <<"dev">>},
                                 #{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]}),
    ?assertEqual(#{<<"system">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"sys">>},
                                    #{<<"type">> => <<"text">>, <<"text">> => <<"dev">>}],
                   <<"messages">> => [#{<<"role">> => <<"user">>,
                                        <<"content">> => [#{<<"type">> => <<"text">>,
                                                            <<"text">> => <<"hi">>}]}],
                   <<"max_tokens">> => 4096, <<"temperature">> => 1.0,
                   <<"stop_sequences">> => [<<"END">>], <<"stream">> => true,
                   <<"metadata">> => #{<<"user_id">> => <<"u1">>}}, B).

o2a_tools_test() ->
    B = o2a(#{<<"max_tokens">> => 100, <<"parallel_tool_calls">> => false,
              <<"tool_choice">> => <<"required">>,
              <<"tools">> => [#{<<"type">> => <<"function">>,
                                <<"function">> => #{<<"name">> => <<"get">>,
                                                    <<"description">> => <<"d">>,
                                                    <<"parameters">> => #{<<"type">> => <<"object">>}}}],
              <<"messages">> =>
                  [#{<<"role">> => <<"user">>, <<"content">> => <<"q">>},
                   #{<<"role">> => <<"assistant">>, <<"content">> => null,
                     <<"tool_calls">> => [#{<<"id">> => <<"c1">>, <<"type">> => <<"function">>,
                                            <<"function">> => #{<<"name">> => <<"get">>,
                                                                <<"arguments">> => <<"{\"k\":1}">>}},
                                          #{<<"id">> => <<"c2">>, <<"type">> => <<"function">>,
                                            <<"function">> => #{<<"name">> => <<"get">>,
                                                                <<"arguments">> => <<"">>}}]},
                   #{<<"role">> => <<"tool">>, <<"tool_call_id">> => <<"c1">>, <<"content">> => <<"r1">>},
                   #{<<"role">> => <<"tool">>, <<"tool_call_id">> => <<"c2">>, <<"content">> => <<"r2">>},
                   #{<<"role">> => <<"user">>, <<"content">> => <<"next">>}]}),
    ?assertEqual([#{<<"name">> => <<"get">>, <<"description">> => <<"d">>,
                    <<"input_schema">> => #{<<"type">> => <<"object">>}}], maps:get(<<"tools">>, B)),
    ?assertEqual(#{<<"type">> => <<"any">>, <<"disable_parallel_tool_use">> => true},
                 maps:get(<<"tool_choice">>, B)),
    [U1, A, U2] = maps:get(<<"messages">>, B),
    ?assertMatch(#{<<"role">> := <<"user">>}, U1),
    ?assertMatch(#{<<"role">> := <<"assistant">>,
                   <<"content">> := [#{<<"type">> := <<"tool_use">>, <<"id">> := <<"c1">>,
                                       <<"input">> := #{<<"k">> := 1}},
                                     #{<<"type">> := <<"tool_use">>, <<"input">> := #{}}]}, A),
    %% 两条 tool 消息 + 后续 user 合并为一条 user，tool_result 在前
    ?assertMatch(#{<<"role">> := <<"user">>,
                   <<"content">> := [#{<<"type">> := <<"tool_result">>, <<"tool_use_id">> := <<"c1">>},
                                     #{<<"type">> := <<"tool_result">>, <<"tool_use_id">> := <<"c2">>},
                                     #{<<"type">> := <<"text">>, <<"text">> := <<"next">>}]}, U2).

o2a_image_and_unsupported_test() ->
    B = o2a(#{<<"messages">> =>
                  [#{<<"role">> => <<"user">>,
                     <<"content">> => [#{<<"type">> => <<"image_url">>,
                                         <<"image_url">> => #{<<"url">> => <<"data:image/png;base64,QUJD">>}},
                                       #{<<"type">> => <<"image_url">>,
                                         <<"image_url">> => #{<<"url">> => <<"https://x/y.png">>}}]}]}),
    [#{<<"content">> := [I1, I2]}] = maps:get(<<"messages">>, B),
    ?assertEqual(#{<<"type">> => <<"base64">>, <<"media_type">> => <<"image/png">>,
                   <<"data">> => <<"QUJD">>}, maps:get(<<"source">>, I1)),
    ?assertEqual(#{<<"type">> => <<"url">>, <<"url">> => <<"https://x/y.png">>},
                 maps:get(<<"source">>, I2)),
    ?assertEqual({error, {unsupported, <<"content part input_audio">>}},
                 lg_conv_req:openai_to_anthropic(
                   #{<<"messages">> => [#{<<"role">> => <<"user">>,
                                          <<"content">> => [#{<<"type">> => <<"input_audio">>}]}]}, #{})).

o2a_reasoning_test() ->
    B = o2a(#{<<"max_tokens">> => 1000, <<"reasoning_effort">> => <<"low">>, <<"temperature">> => 0.2,
              <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]}),
    ?assertMatch(#{<<"thinking">> := #{<<"budget_tokens">> := 2048}, <<"max_tokens">> := 3072}, B),
    ?assertNot(maps:is_key(<<"temperature">>, B)),
    {ok, B2} = lg_conv_req:openai_to_anthropic(
                 #{<<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]},
                 #{default_max_tokens => 777}),
    ?assertEqual(777, maps:get(<<"max_tokens">>, B2)).

a2o_test() ->
    B = a2o(#{<<"model">> => <<"x">>, <<"max_tokens">> => 50, <<"stream">> => true,
              <<"system">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"s1">>},
                               #{<<"type">> => <<"text">>, <<"text">> => <<"s2">>}],
              <<"stop_sequences">> => [<<"X">>],
              <<"metadata">> => #{<<"user_id">> => <<"u">>},
              <<"tools">> => [#{<<"name">> => <<"get">>, <<"input_schema">> => #{}},
                              #{<<"type">> => <<"web_search_20250305">>, <<"name">> => <<"web_search">>}],
              <<"tool_choice">> => #{<<"type">> => <<"tool">>, <<"name">> => <<"get">>},
              <<"messages">> =>
                  [#{<<"role">> => <<"user">>, <<"content">> => <<"q">>},
                   #{<<"role">> => <<"assistant">>,
                     <<"content">> => [#{<<"type">> => <<"thinking">>, <<"thinking">> => <<"hmm">>},
                                       #{<<"type">> => <<"text">>, <<"text">> => <<"let me">>},
                                       #{<<"type">> => <<"tool_use">>, <<"id">> => <<"t1">>,
                                         <<"name">> => <<"get">>, <<"input">> => #{<<"a">> => 1}}]},
                   #{<<"role">> => <<"user">>,
                     <<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"and">>},
                                       #{<<"type">> => <<"tool_result">>, <<"tool_use_id">> => <<"t1">>,
                                         <<"content">> => [#{<<"type">> => <<"text">>,
                                                             <<"text">> => <<"res">>}]},
                                       #{<<"type">> => <<"image">>,
                                         <<"source">> => #{<<"type">> => <<"base64">>,
                                                           <<"media_type">> => <<"image/jpeg">>,
                                                           <<"data">> => <<"AA">>}}]}]}),
    ?assertMatch(#{<<"max_tokens">> := 50, <<"stop">> := [<<"X">>], <<"user">> := <<"u">>,
                   <<"stream_options">> := #{<<"include_usage">> := true},
                   <<"tool_choice">> := #{<<"function">> := #{<<"name">> := <<"get">>}}}, B),
    ?assertEqual(1, length(maps:get(<<"tools">>, B))),
    [Sys, U1, A, T, U2] = maps:get(<<"messages">>, B),
    ?assertEqual(#{<<"role">> => <<"system">>, <<"content">> => <<"s1\ns2">>}, Sys),
    ?assertEqual(#{<<"role">> => <<"user">>, <<"content">> => <<"q">>}, U1),
    ?assertMatch(#{<<"content">> := <<"let me">>,
                   <<"tool_calls">> := [#{<<"id">> := <<"t1">>,
                                          <<"function">> := #{<<"arguments">> := <<"{\"a\":1}">>}}]}, A),
    ?assertEqual(#{<<"role">> => <<"tool">>, <<"tool_call_id">> => <<"t1">>, <<"content">> => <<"res">>}, T),
    ?assertMatch(#{<<"role">> := <<"user">>,
                   <<"content">> := [#{<<"type">> := <<"text">>},
                                     #{<<"image_url">> := #{<<"url">> := <<"data:image/jpeg;base64,AA">>}}]}, U2).

%% Claude Code 在对话中插入的 system 消息（内容块形式）→ OpenAI system 消息
a2o_inline_system_test() ->
    B = a2o(#{<<"max_tokens">> => 10,
              <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"q">>},
                                 #{<<"role">> => <<"system">>,
                                   <<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"reminder">>}]}]}),
    ?assertEqual([#{<<"role">> => <<"user">>, <<"content">> => <<"q">>},
                  #{<<"role">> => <<"system">>, <<"content">> => <<"reminder">>}], maps:get(<<"messages">>, B)).
