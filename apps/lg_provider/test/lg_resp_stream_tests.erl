-module(lg_resp_stream_tests).

-include_lib("eunit/include/eunit.hrl").

events(Frames) ->
    {Evs, <<>>} = lg_sse:parse(iolist_to_binary(Frames)),
    [json:decode(D) || #{data := D} <- Evs].

converted_test() ->
    Chunk = fun(D) -> #{<<"model">> => <<"up">>, <<"choices">> => [#{<<"index">> => 0, <<"delta">> => D}]} end,
    S0 = lg_resp_stream:new(#{mode => converted, request => #{<<"model">> => <<"pub">>}, id => <<"resp_x">>}),
    {F, S} = lists:foldl(fun(C, {Acc, St}) -> {Fr, St1} = lg_resp_stream:feed(C, St), {Acc ++ Fr, St1} end,
                         {[], S0},
                         [Chunk(#{<<"role">> => <<"assistant">>, <<"content">> => <<>>}),
                          Chunk(#{<<"content">> => <<"He">>}),
                          Chunk(#{<<"content">> => <<"llo">>}),
                          Chunk(#{<<"tool_calls">> => [#{<<"index">> => 0, <<"id">> => <<"call_1">>,
                                                          <<"function">> => #{<<"name">> => <<"f">>, <<"arguments">> => <<"{\"a\"">>}}]}),
                          Chunk(#{<<"tool_calls">> => [#{<<"index">> => 0, <<"function">> => #{<<"arguments">> => <<":1}">>}}]}),
                          #{<<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{}, <<"finish_reason">> => <<"tool_calls">>}]}]),
    Usage = #{input => 3, output => 5, cache_read => 0, cache_write => 0, reasoning => 0},
    {Tail, S1} = lg_resp_stream:finish(Usage, S),
    Evs = events(F ++ Tail),
    ?assertEqual([<<"response.created">>, <<"response.in_progress">>,
                  <<"response.output_item.added">>, <<"response.content_part.added">>,
                  <<"response.output_text.delta">>, <<"response.output_text.delta">>,
                  <<"response.output_text.done">>, <<"response.content_part.done">>, <<"response.output_item.done">>,
                  <<"response.output_item.added">>,
                  <<"response.function_call_arguments.delta">>, <<"response.function_call_arguments.delta">>,
                  <<"response.function_call_arguments.done">>, <<"response.output_item.done">>,
                  <<"response.completed">>], [maps:get(<<"type">>, E) || E <- Evs]),
    ?assertEqual(lists:seq(0, length(Evs) - 1), [maps:get(<<"sequence_number">>, E) || E <- Evs]),
    [TextDone] = [E || #{<<"type">> := <<"response.output_text.done">>} = E <- Evs],
    ?assertEqual(<<"Hello">>, maps:get(<<"text">>, TextDone)),
    [ArgsDone] = [E || #{<<"type">> := <<"response.function_call_arguments.done">>} = E <- Evs],
    ?assertEqual(<<"{\"a\":1}">>, maps:get(<<"arguments">>, ArgsDone)),
    #{<<"response">> := Final} = lists:last(Evs),
    ?assertMatch(#{<<"id">> := <<"resp_x">>, <<"status">> := <<"completed">>, <<"model">> := <<"up">>,
                   <<"output">> := [#{<<"type">> := <<"message">>}, #{<<"type">> := <<"function_call">>,
                                                                     <<"call_id">> := <<"call_1">>,
                                                                     <<"status">> := <<"completed">>}],
                   <<"usage">> := #{<<"input_tokens">> := 3, <<"output_tokens">> := 5}}, Final),
    ?assertMatch(#{response := #{<<"id">> := <<"resp_x">>}, text := <<"Hello">>}, lg_resp_stream:result(S1)).

passthrough_test() ->
    Resp = #{<<"id">> => <<"resp_up">>, <<"model">> => <<"up">>, <<"status">> => <<"completed">>,
             <<"usage">> => #{<<"input_tokens">> => 9, <<"output_tokens">> => 2,
                              <<"input_tokens_details">> => #{<<"cached_tokens">> => 4}}},
    Frames = [lg_sse:encode(<<"response.output_text.delta">>,
                            json:encode(#{<<"type">> => <<"response.output_text.delta">>, <<"delta">> => <<"hi">>})),
              lg_sse:encode(<<"response.completed">>,
                            json:encode(#{<<"type">> => <<"response.completed">>, <<"response">> => Resp}))],
    %% 上游多发的 [DONE]（智谱 GLM）被丢弃
    {Evs, <<>>} = lg_sse:parse(iolist_to_binary([Frames, lg_sse:done()])),
    S0 = lg_resp_stream:new(#{mode => passthrough, request => #{}}),
    {Out, S} = lists:foldl(fun(E, {Acc, St}) -> {F, St1} = lg_resp_stream:feed(E, St), {[Acc, F], St1} end,
                           {[], S0}, Evs),
    ?assertEqual(iolist_to_binary(Frames), iolist_to_binary(Out)),
    ?assertMatch(#{text := <<"hi">>, usage := #{input := 5, cache_read := 4, output := 2},
                   response := #{<<"id">> := <<"resp_up">>}}, lg_resp_stream:result(S)).

%% 流式：reasoning_content → reasoning 项事件；custom 工具参数不逐片输出，结束时给出 input
reasoning_and_custom_stream_test() ->
    Req = #{<<"tools">> => [#{<<"type">> => <<"custom">>, <<"name">> => <<"apply_patch">>}]},
    S0 = lg_resp_stream:new(#{mode => converted, request => Req, id => <<"resp_s">>}),
    Chunks = [#{<<"choices">> => [#{<<"delta">> => #{<<"reasoning_content">> => <<"th">>}}]},
              #{<<"choices">> => [#{<<"delta">> => #{<<"reasoning_content">> => <<"ink">>}}]},
              #{<<"choices">> => [#{<<"delta">> => #{<<"tool_calls">> => [#{<<"index">> => 0, <<"id">> => <<"c1">>,
                                                                             <<"function">> => #{<<"name">> => <<"apply_patch">>,
                                                                                                 <<"arguments">> => <<"{\"input\":">>}}]}}]},
              #{<<"choices">> => [#{<<"delta">> => #{<<"tool_calls">> => [#{<<"index">> => 0,
                                                                             <<"function">> => #{<<"arguments">> => <<"\"P\"}">>}}]},
                                    <<"finish_reason">> => <<"tool_calls">>}]}],
    {Frames, S1} = lists:foldl(fun(C, {Acc, S}) -> {F, S2} = lg_resp_stream:feed(C, S), {Acc ++ F, S2} end,
                               {[], S0}, Chunks),
    {Tail, S2} = lg_resp_stream:finish(undefined, S1),
    {Evs, _} = lg_sse:parse(iolist_to_binary(Frames ++ Tail)),
    Types = [T || #{event := T} <- Evs],
    ?assert(lists:member(<<"response.reasoning_text.delta">>, Types)),
    ?assert(lists:member(<<"response.custom_tool_call_input.done">>, Types)),
    ?assertNot(lists:member(<<"response.function_call_arguments.delta">>, Types)),
    #{response := #{<<"output">> := [R, C]}} = lg_resp_stream:result(S2),
    ?assertMatch(#{<<"type">> := <<"reasoning">>, <<"content">> := [#{<<"text">> := <<"think">>}]}, R),
    ?assertMatch(#{<<"type">> := <<"custom_tool_call">>, <<"input">> := <<"P">>, <<"call_id">> := <<"c1">>}, C).
