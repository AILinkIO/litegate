-module(lg_conv_responses_tests).

-include_lib("eunit/include/eunit.hrl").

to_chat(Req) -> {ok, C} = lg_conv_responses:request_to_chat(Req), C.

request_basic_test() ->
    C = to_chat(#{<<"model">> => <<"m">>, <<"instructions">> => <<"be brief">>, <<"input">> => <<"hi">>,
                  <<"max_output_tokens">> => 50, <<"temperature">> => 0.3,
                  <<"reasoning">> => #{<<"effort">> => <<"low">>}, <<"stream">> => true}),
    ?assertEqual(#{<<"model">> => <<"m">>,
                   <<"messages">> => [#{<<"role">> => <<"system">>, <<"content">> => <<"be brief">>},
                                      #{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
                   <<"max_tokens">> => 50, <<"temperature">> => 0.3, <<"reasoning_effort">> => <<"low">>,
                   <<"stream">> => true, <<"stream_options">> => #{<<"include_usage">> => true}}, C).

request_items_and_tools_test() ->
    C = to_chat(#{<<"model">> => <<"m">>,
                  <<"input">> => [#{<<"role">> => <<"developer">>, <<"content">> => <<"dev">>},
                                  #{<<"type">> => <<"message">>, <<"role">> => <<"user">>,
                                    <<"content">> => [#{<<"type">> => <<"input_text">>, <<"text">> => <<"look">>},
                                                      #{<<"type">> => <<"input_image">>,
                                                        <<"image_url">> => <<"data:image/png;base64,AA">>}]},
                                  #{<<"type">> => <<"reasoning">>, <<"summary">> => []},
                                  #{<<"type">> => <<"message">>, <<"role">> => <<"assistant">>,
                                    <<"content">> => [#{<<"type">> => <<"output_text">>, <<"text">> => <<"calling">>}]},
                                  #{<<"type">> => <<"function_call">>, <<"call_id">> => <<"c1">>, <<"name">> => <<"f">>,
                                    <<"arguments">> => <<"{}">>},
                                  #{<<"type">> => <<"function_call">>, <<"call_id">> => <<"c2">>, <<"name">> => <<"g">>,
                                    <<"arguments">> => <<"{\"a\":1}">>},
                                  #{<<"type">> => <<"function_call_output">>, <<"call_id">> => <<"c1">>, <<"output">> => <<"r1">>},
                                  #{<<"type">> => <<"function_call_output">>, <<"call_id">> => <<"c2">>, <<"output">> => <<"r2">>}],
                  <<"tools">> => [#{<<"type">> => <<"function">>, <<"name">> => <<"f">>, <<"description">> => <<"d">>,
                                    <<"parameters">> => #{<<"type">> => <<"object">>}, <<"strict">> => true},
                                  #{<<"type">> => <<"web_search_preview">>}],
                  <<"tool_choice">> => #{<<"type">> => <<"function">>, <<"name">> => <<"f">>},
                  <<"parallel_tool_calls">> => false,
                  <<"text">> => #{<<"format">> => #{<<"type">> => <<"json_schema">>, <<"name">> => <<"out">>,
                                                    <<"schema">> => #{<<"type">> => <<"object">>}}}}),
    [Sys, User, Asst, T1, T2] = maps:get(<<"messages">>, C),
    ?assertEqual(#{<<"role">> => <<"system">>, <<"content">> => <<"dev">>}, Sys),
    ?assertMatch(#{<<"role">> := <<"user">>,
                   <<"content">> := [#{<<"type">> := <<"text">>}, #{<<"image_url">> := #{<<"url">> := _}}]}, User),
    %% 助手文本与随后的两个 function_call 合并为一条消息
    ?assertMatch(#{<<"role">> := <<"assistant">>, <<"content">> := <<"calling">>,
                   <<"tool_calls">> := [#{<<"id">> := <<"c1">>}, #{<<"id">> := <<"c2">>,
                                                                  <<"function">> := #{<<"arguments">> := <<"{\"a\":1}">>}}]},
                 Asst),
    ?assertEqual(#{<<"role">> => <<"tool">>, <<"tool_call_id">> => <<"c1">>, <<"content">> => <<"r1">>}, T1),
    ?assertMatch(#{<<"tool_call_id">> := <<"c2">>}, T2),
    %% 内置工具丢弃，function 工具扁平 → 嵌套
    ?assertEqual([#{<<"type">> => <<"function">>,
                    <<"function">> => #{<<"name">> => <<"f">>, <<"description">> => <<"d">>,
                                        <<"parameters">> => #{<<"type">> => <<"object">>}, <<"strict">> => true}}],
                 maps:get(<<"tools">>, C)),
    ?assertEqual(#{<<"type">> => <<"function">>, <<"function">> => #{<<"name">> => <<"f">>}},
                 maps:get(<<"tool_choice">>, C)),
    ?assertEqual(false, maps:get(<<"parallel_tool_calls">>, C)),
    ?assertMatch(#{<<"type">> := <<"json_schema">>, <<"json_schema">> := #{<<"name">> := <<"out">>}},
                 maps:get(<<"response_format">>, C)).

request_unsupported_test() ->
    ?assertMatch({error, {unsupported, _}},
                 lg_conv_responses:request_to_chat(#{<<"input">> => [#{<<"type">> => <<"computer_call">>}]})).

response_test() ->
    Chat = #{<<"id">> => <<"cc">>, <<"model">> => <<"up">>,
             <<"choices">> => [#{<<"finish_reason">> => <<"tool_calls">>,
                                 <<"message">> => #{<<"content">> => <<"ok">>,
                                                    <<"tool_calls">> => [#{<<"id">> => <<"call_1">>,
                                                                           <<"function">> => #{<<"name">> => <<"f">>,
                                                                                               <<"arguments">> => <<"{}">>}}]}}],
             <<"usage">> => #{<<"prompt_tokens">> => 10, <<"completion_tokens">> => 4,
                              <<"prompt_tokens_details">> => #{<<"cached_tokens">> => 6}}},
    R = lg_conv_responses:chat_to_response(Chat, #{id => <<"resp_1">>, request => #{<<"instructions">> => <<"i">>}}),
    ?assertMatch(#{<<"id">> := <<"resp_1">>, <<"object">> := <<"response">>, <<"status">> := <<"completed">>,
                   <<"model">> := <<"up">>, <<"instructions">> := <<"i">>,
                   <<"output">> := [#{<<"type">> := <<"message">>, <<"role">> := <<"assistant">>,
                                      <<"content">> := [#{<<"type">> := <<"output_text">>, <<"text">> := <<"ok">>}]},
                                    #{<<"type">> := <<"function_call">>, <<"call_id">> := <<"call_1">>,
                                      <<"name">> := <<"f">>, <<"arguments">> := <<"{}">>}],
                   <<"usage">> := #{<<"input_tokens">> := 10, <<"output_tokens">> := 4, <<"total_tokens">> := 14,
                                    <<"input_tokens_details">> := #{<<"cached_tokens">> := 6}}}, R),
    Trunc = lg_conv_responses:chat_to_response(
              Chat#{<<"choices">> => [#{<<"finish_reason">> => <<"length">>, <<"message">> => #{<<"content">> => <<"x">>}}]},
              #{id => <<"r">>, request => #{}}),
    ?assertMatch(#{<<"status">> := <<"incomplete">>,
                   <<"incomplete_details">> := #{<<"reason">> := <<"max_output_tokens">>}}, Trunc).

codex_tools() ->
    [#{<<"type">> => <<"function">>, <<"name">> => <<"exec_command">>, <<"parameters">> => #{<<"type">> => <<"object">>}},
     #{<<"type">> => <<"custom">>, <<"name">> => <<"apply_patch">>, <<"description">> => <<"Patch files">>,
       <<"format">> => #{<<"type">> => <<"grammar">>, <<"syntax">> => <<"lark">>, <<"definition">> => <<"start: x">>}},
     #{<<"type">> => <<"namespace">>, <<"name">> => <<"multi_agent_v1">>,
       <<"tools">> => [#{<<"type">> => <<"function">>, <<"name">> => <<"spawn_agent">>,
                         <<"parameters">> => #{<<"type">> => <<"object">>}}]},
     #{<<"type">> => <<"web_search">>}].

%% Codex 的工具：custom → 单参数函数；namespace 展开；web_search 丢弃
codex_tools_request_test() ->
    {ok, C} = lg_conv_responses:request_to_chat(#{<<"model">> => <<"m">>, <<"input">> => <<"hi">>,
                                                  <<"tools">> => codex_tools()}),
    Names = [N || #{<<"function">> := #{<<"name">> := N}} <- maps:get(<<"tools">>, C)],
    ?assertEqual([<<"exec_command">>, <<"apply_patch">>, <<"multi_agent_v1__spawn_agent">>], Names),
    [_, #{<<"function">> := #{<<"description">> := D, <<"parameters">> := #{<<"required">> := [<<"input">>]}}}, _] =
        maps:get(<<"tools">>, C),
    ?assertNotEqual(nomatch, binary:match(D, <<"start: x">>)).

%% 历史中的 custom_tool_call / 命名空间调用 / reasoning 项 → Chat 消息
codex_history_test() ->
    Items = [#{<<"type">> => <<"message">>, <<"role">> => <<"user">>, <<"content">> => <<"fix">>},
             #{<<"type">> => <<"reasoning">>, <<"content">> => [#{<<"type">> => <<"reasoning_text">>, <<"text">> => <<"think">>}]},
             #{<<"type">> => <<"custom_tool_call">>, <<"call_id">> => <<"c1">>, <<"name">> => <<"apply_patch">>,
               <<"input">> => <<"*** Begin Patch">>},
             #{<<"type">> => <<"function_call">>, <<"call_id">> => <<"c2">>, <<"name">> => <<"spawn_agent">>,
               <<"namespace">> => <<"multi_agent_v1">>, <<"arguments">> => <<"{}">>},
             #{<<"type">> => <<"custom_tool_call_output">>, <<"call_id">> => <<"c1">>, <<"output">> => <<"done">>},
             #{<<"type">> => <<"function_call_output">>, <<"call_id">> => <<"c2">>, <<"output">> => <<"ok">>}],
    [U, A, T1, T2] = lg_conv_responses:chat_messages(Items),
    ?assertEqual(<<"fix">>, maps:get(<<"content">>, U)),
    ?assertMatch(#{<<"role">> := <<"assistant">>, <<"reasoning_content">> := <<"think">>,
                   <<"tool_calls">> := [#{<<"function">> := #{<<"name">> := <<"apply_patch">>,
                                                              <<"arguments">> := <<"{\"input\":\"*** Begin Patch\"}">>}},
                                        #{<<"function">> := #{<<"name">> := <<"multi_agent_v1__spawn_agent">>}}]}, A),
    ?assertMatch(#{<<"role">> := <<"tool">>, <<"tool_call_id">> := <<"c1">>, <<"content">> := <<"done">>}, T1),
    ?assertMatch(#{<<"tool_call_id">> := <<"c2">>}, T2).

%% Chat 响应 → reasoning 项 + custom_tool_call + 带 namespace 的 function_call
codex_response_test() ->
    Chat = #{<<"model">> => <<"up">>,
             <<"choices">> => [#{<<"finish_reason">> => <<"tool_calls">>,
                                 <<"message">> => #{<<"reasoning_content">> => <<"plan">>,
                                                    <<"tool_calls">> => [
                                                      #{<<"id">> => <<"c1">>, <<"function">> => #{<<"name">> => <<"apply_patch">>,
                                                                                                    <<"arguments">> => <<"{\"input\":\"P\"}">>}},
                                                      #{<<"id">> => <<"c2">>, <<"function">> => #{<<"name">> => <<"multi_agent_v1__spawn_agent">>,
                                                                                                    <<"arguments">> => <<"{}">>}}]}}]},
    #{<<"output">> := [R, Cu, Fc]} =
        lg_conv_responses:chat_to_response(Chat, #{id => <<"resp_1">>, request => #{<<"tools">> => codex_tools()}}),
    ?assertMatch(#{<<"type">> := <<"reasoning">>, <<"content">> := [#{<<"text">> := <<"plan">>}]}, R),
    ?assertMatch(#{<<"type">> := <<"custom_tool_call">>, <<"call_id">> := <<"c1">>, <<"name">> := <<"apply_patch">>,
                   <<"input">> := <<"P">>}, Cu),
    ?assertMatch(#{<<"type">> := <<"function_call">>, <<"name">> := <<"spawn_agent">>,
                   <<"namespace">> := <<"multi_agent_v1">>}, Fc).
