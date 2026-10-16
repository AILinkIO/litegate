-module(lg_stream_tests).

-include_lib("eunit/include/eunit.hrl").

%% 把 SSE 文本喂给处理器，返回输出文本与结果
run(Opts, Sse) ->
    {Evs, <<>>} = lg_sse:parse(Sse),
    {Frames, S} = lists:foldl(fun(E, {Acc, St}) ->
                                      {F, St1} = lg_stream:feed(E, St),
                                      {[Acc, F], St1}
                              end, {[], lg_stream:new(Opts)}, Evs),
    {Tail, Result} = lg_stream:finish(S),
    {iolist_to_binary([Frames, Tail]), Result}.

%% 解析输出为 JSON 列表（[DONE] 保留为原子）
decode(Out) ->
    {Evs, <<>>} = lg_sse:parse(Out),
    [case D of <<"[DONE]">> -> done; _ -> json:decode(D) end || #{data := D} <- Evs].

openai_sse() ->
    iolist_to_binary(
      [lg_sse:encode(json:encode(C)) || C <-
          [#{<<"id">> => <<"c1">>, <<"model">> => <<"gpt">>,
             <<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{<<"role">> => <<"assistant">>,
                                                                    <<"content">> => <<"He">>}}]},
           #{<<"id">> => <<"c1">>, <<"model">> => <<"gpt">>,
             <<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{<<"content">> => <<"llo">>}}]},
           #{<<"id">> => <<"c1">>, <<"model">> => <<"gpt">>,
             <<"choices">> => [#{<<"index">> => 0,
                                 <<"delta">> => #{<<"tool_calls">> =>
                                                      [#{<<"index">> => 0, <<"id">> => <<"call_1">>,
                                                         <<"function">> => #{<<"name">> => <<"f">>,
                                                                             <<"arguments">> => <<"{\"a\"">>}}]}}]},
           #{<<"id">> => <<"c1">>, <<"model">> => <<"gpt">>,
             <<"choices">> => [#{<<"index">> => 0,
                                 <<"delta">> => #{<<"tool_calls">> =>
                                                      [#{<<"index">> => 0,
                                                         <<"function">> => #{<<"arguments">> => <<":1}">>}}]}}]},
           #{<<"id">> => <<"c1">>, <<"model">> => <<"gpt">>,
             <<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{},
                                 <<"finish_reason">> => <<"tool_calls">>}]},
           #{<<"id">> => <<"c1">>, <<"model">> => <<"gpt">>, <<"choices">> => [],
             <<"usage">> => #{<<"prompt_tokens">> => 11, <<"completion_tokens">> => 9}}]]
      ++ [lg_sse:done()]).

anthropic_sse() ->
    iolist_to_binary(
      [lg_sse:encode(T, json:encode(E#{<<"type">> => T})) || {T, E} <-
          [{<<"message_start">>, #{<<"message">> => #{<<"id">> => <<"msg_1">>, <<"model">> => <<"claude">>,
                                                      <<"usage">> => #{<<"input_tokens">> => 20,
                                                                       <<"cache_read_input_tokens">> => 5,
                                                                       <<"output_tokens">> => 1}}}},
           {<<"ping">>, #{}},
           {<<"content_block_start">>, #{<<"index">> => 0,
                                         <<"content_block">> => #{<<"type">> => <<"thinking">>, <<"thinking">> => <<>>}}},
           {<<"content_block_delta">>, #{<<"index">> => 0,
                                         <<"delta">> => #{<<"type">> => <<"thinking_delta">>, <<"thinking">> => <<"hmm">>}}},
           {<<"content_block_stop">>, #{<<"index">> => 0}},
           {<<"content_block_start">>, #{<<"index">> => 1,
                                         <<"content_block">> => #{<<"type">> => <<"text">>, <<"text">> => <<>>}}},
           {<<"content_block_delta">>, #{<<"index">> => 1,
                                         <<"delta">> => #{<<"type">> => <<"text_delta">>, <<"text">> => <<"Hi">>}}},
           {<<"content_block_stop">>, #{<<"index">> => 1}},
           {<<"content_block_start">>, #{<<"index">> => 2,
                                         <<"content_block">> => #{<<"type">> => <<"tool_use">>, <<"id">> => <<"tu_1">>,
                                                                  <<"name">> => <<"f">>, <<"input">> => #{}}}},
           {<<"content_block_delta">>, #{<<"index">> => 2,
                                         <<"delta">> => #{<<"type">> => <<"input_json_delta">>,
                                                          <<"partial_json">> => <<"{}">>}}},
           {<<"content_block_stop">>, #{<<"index">> => 2}},
           {<<"message_delta">>, #{<<"delta">> => #{<<"stop_reason">> => <<"tool_use">>},
                                   <<"usage">> => #{<<"output_tokens">> => 30}}},
           {<<"message_stop">>, #{}}]]).

openai_passthrough_strips_injected_usage_test() ->
    Sse = openai_sse(),
    {Out, R} = run(#{client => openai, upstream => openai, strip_usage => true}, Sse),
    [_, _, _, _, _, done] = decode(Out),
    ?assertMatch(#{text := <<"Hello">>, finish_reason := <<"tool_calls">>, id := <<"c1">>,
                   usage := #{input := 11, output := 9}}, R),
    %% 客户端自己要了 usage：原样转发，字节不变
    {Out2, _} = run(#{client => openai, upstream => openai, include_usage => true}, Sse),
    ?assertEqual(Sse, Out2).

anthropic_passthrough_test() ->
    Sse = anthropic_sse(),
    {Out, R} = run(#{client => anthropic, upstream => anthropic}, Sse),
    ?assertEqual(Sse, Out),
    ?assertMatch(#{text := <<"Hi">>, finish_reason := <<"tool_use">>, model := <<"claude">>,
                   usage := #{input := 20, cache_read := 5, output := 30}}, R).

anthropic_to_openai_test() ->
    {Out, R} = run(#{client => openai, upstream => anthropic, include_usage => true}, anthropic_sse()),
    Chunks = decode(Out),
    ?assertEqual(done, lists:last(Chunks)),
    Deltas = [D || #{<<"choices">> := [#{<<"delta">> := D}]} <- Chunks],
    ?assertEqual([#{<<"role">> => <<"assistant">>, <<"content">> => <<>>},
                  #{<<"reasoning_content">> => <<"hmm">>},
                  #{<<"content">> => <<"Hi">>},
                  #{<<"tool_calls">> => [#{<<"index">> => 0, <<"id">> => <<"tu_1">>,
                                           <<"type">> => <<"function">>,
                                           <<"function">> => #{<<"name">> => <<"f">>,
                                                               <<"arguments">> => <<>>}}]},
                  #{<<"tool_calls">> => [#{<<"index">> => 0,
                                           <<"function">> => #{<<"arguments">> => <<"{}">>}}]},
                  #{}], Deltas),
    ?assertMatch([#{<<"finish_reason">> := <<"tool_calls">>}],
                 [C || #{<<"choices">> := [C = #{<<"finish_reason">> := F}]} <- Chunks, F =/= null]),
    [UsageChunk] = [C || #{<<"choices">> := [], <<"usage">> := _} = C <- Chunks],
    ?assertMatch(#{<<"id">> := <<"msg_1">>,
                   <<"usage">> := #{<<"prompt_tokens">> := 25, <<"completion_tokens">> := 30}}, UsageChunk),
    ?assertMatch(#{text := <<"Hi">>}, R).

openai_to_anthropic_test() ->
    {Out, R} = run(#{client => anthropic, upstream => openai}, openai_sse()),
    {Evs, <<>>} = lg_sse:parse(Out),
    Types = [T || #{event := T} <- Evs],
    ?assertEqual([<<"message_start">>,
                  <<"content_block_start">>, <<"content_block_delta">>, <<"content_block_delta">>,
                  <<"content_block_stop">>,
                  <<"content_block_start">>, <<"content_block_delta">>, <<"content_block_delta">>,
                  <<"content_block_stop">>,
                  <<"message_delta">>, <<"message_stop">>], Types),
    Payloads = [json:decode(D) || #{data := D} <- Evs],
    ?assertMatch(#{<<"message">> := #{<<"id">> := <<"c1">>, <<"model">> := <<"gpt">>}}, hd(Payloads)),
    ?assertMatch(#{<<"index">> := 1,
                   <<"content_block">> := #{<<"type">> := <<"tool_use">>, <<"id">> := <<"call_1">>,
                                            <<"name">> := <<"f">>}}, lists:nth(6, Payloads)),
    ?assertMatch(#{<<"delta">> := #{<<"partial_json">> := <<":1}">>}}, lists:nth(8, Payloads)),
    ?assertMatch(#{<<"delta">> := #{<<"stop_reason">> := <<"tool_use">>},
                   <<"usage">> := #{<<"input_tokens">> := 11, <<"output_tokens">> := 9}},
                 lists:nth(10, Payloads)),
    %% 每个 content_block_start 与 stop 的 index 匹配
    ?assertEqual([0, 1], [I || #{<<"type">> := <<"content_block_stop">>, <<"index">> := I} <- Payloads]),
    ?assertMatch(#{text := <<"Hello">>, usage := #{input := 11}}, R).

openai_to_anthropic_empty_stream_test() ->
    {Out, _} = run(#{client => anthropic, upstream => openai}, lg_sse:done()),
    {Evs, _} = lg_sse:parse(Out),
    ?assertEqual([<<"message_start">>, <<"message_delta">>, <<"message_stop">>],
                 [T || #{event := T} <- Evs]).

upstream_error_event_test() ->
    Sse = iolist_to_binary(lg_sse:encode(<<"error">>,
                                         json:encode(#{<<"type">> => <<"error">>,
                                                       <<"error">> => #{<<"type">> => <<"overloaded_error">>,
                                                                        <<"message">> => <<"busy">>}}))),
    {Out, R} = run(#{client => openai, upstream => anthropic}, Sse),
    ?assertMatch([#{<<"error">> := #{<<"message">> := <<"busy">>}}, done], decode(Out)),
    ?assertMatch(#{error := #{<<"type">> := <<"overloaded_error">>}}, R).

output_started_test() ->
    Feed = fun(Opts, Frames) ->
                   {Evs, _} = lg_sse:parse(iolist_to_binary(Frames)),
                   lists:foldl(fun(E, St) -> element(2, lg_stream:feed(E, St)) end, lg_stream:new(Opts), Evs)
           end,
    Chunk = fun(D) -> lg_sse:encode(json:encode(#{<<"choices">> => [#{<<"index">> => 0, <<"delta">> => D}]})) end,
    O = #{client => openai, upstream => openai},
    %% 只有角色 / 空内容：尚未输出
    ?assertNot(lg_stream:output_started(Feed(O, [Chunk(#{<<"role">> => <<"assistant">>, <<"content">> => <<>>})]))),
    ?assert(lg_stream:output_started(Feed(O, [Chunk(#{<<"content">> => <<"hi">>})]))),
    ?assert(lg_stream:output_started(Feed(O, [Chunk(#{<<"reasoning_content">> => <<"hmm">>})]))),
    ?assert(lg_stream:output_started(Feed(O, [Chunk(#{<<"tool_calls">> => [#{<<"index">> => 0}]})]))),
    A = #{client => openai, upstream => anthropic},
    Ev = fun(T, M) -> lg_sse:encode(T, json:encode(M#{<<"type">> => T})) end,
    Start = Ev(<<"message_start">>, #{<<"message">> => #{<<"id">> => <<"m">>}}),
    ?assertNot(lg_stream:output_started(Feed(A, [Start]))),
    ?assert(lg_stream:output_started(
              Feed(A, [Start, Ev(<<"content_block_delta">>,
                                 #{<<"index">> => 0, <<"delta">> => #{<<"type">> => <<"thinking_delta">>,
                                                                      <<"thinking">> => <<"x">>}})]))).

%% anthropic 同协议透传：message_start 之前的 ping 丢弃（百炼 Anthropic 接口实测），之后的 ping 照常转发
anthropic_leading_ping_test() ->
    Ev = fun(T, D) -> iolist_to_binary(lg_sse:encode(T, json:encode(D#{<<"type">> => T}))) end,
    Sse = iolist_to_binary([Ev(<<"ping">>, #{}),
                            Ev(<<"message_start">>, #{<<"message">> => #{<<"id">> => <<"m">>, <<"model">> => <<"q">>,
                                                                        <<"usage">> => #{<<"input_tokens">> => 3}}}),
                            Ev(<<"ping">>, #{}),
                            Ev(<<"message_delta">>, #{<<"delta">> => #{<<"stop_reason">> => <<"end_turn">>},
                                                      <<"usage">> => #{<<"output_tokens">> => 1}}),
                            Ev(<<"message_stop">>, #{})]),
    {Out, _} = run(#{client => anthropic, upstream => anthropic}, Sse),
    {Evs, <<>>} = lg_sse:parse(Out),
    ?assertEqual([<<"message_start">>, <<"ping">>, <<"message_delta">>, <<"message_stop">>], [E || #{event := E} <- Evs]).
