%% @doc 非流式响应体转换：Anthropic Message ↔ OpenAI Chat Completion。
-module(lg_conv_resp).

-export([anthropic_to_openai/1, openai_to_anthropic/1,
         finish_a2o/1, finish_o2a/1]).

%% @doc Anthropic Message → OpenAI chat.completion。
%% thinking 块放入 reasoning_content（DeepSeek 等使用的扩展字段）。
-spec anthropic_to_openai(map()) -> map().
anthropic_to_openai(Resp) ->
    Blocks = maps:get(<<"content">>, Resp, []),
    Text = iolist_to_binary([T || #{<<"type">> := <<"text">>, <<"text">> := T} <- Blocks]),
    Thinking = iolist_to_binary([T || #{<<"type">> := <<"thinking">>, <<"thinking">> := T} <- Blocks]),
    Calls = [#{<<"id">> => Id, <<"type">> => <<"function">>,
               <<"function">> => #{<<"name">> => Name,
                                   <<"arguments">> => iolist_to_binary(json:encode(Input))}}
             || #{<<"type">> := <<"tool_use">>, <<"id">> := Id, <<"name">> := Name,
                  <<"input">> := Input} <- Blocks],
    Msg0 = #{<<"role">> => <<"assistant">>,
             <<"content">> => case Text of <<>> when Calls =/= [] -> null; _ -> Text end},
    Msg1 = case Calls of [] -> Msg0; _ -> Msg0#{<<"tool_calls">> => Calls} end,
    Msg = case Thinking of <<>> -> Msg1; _ -> Msg1#{<<"reasoning_content">> => Thinking} end,
    #{<<"id">> => maps:get(<<"id">>, Resp, <<>>),
      <<"object">> => <<"chat.completion">>,
      <<"created">> => erlang:system_time(second),
      <<"model">> => maps:get(<<"model">>, Resp, <<>>),
      <<"choices">> => [#{<<"index">> => 0, <<"message">> => Msg,
                          <<"finish_reason">> => finish_a2o(maps:get(<<"stop_reason">>, Resp, null)),
                          <<"logprobs">> => null}],
      <<"usage">> => lg_usage:to_openai(lg_usage:from_anthropic(maps:get(<<"usage">>, Resp, #{})))}.

%% @doc OpenAI chat.completion → Anthropic Message（取第一个 choice）。
-spec openai_to_anthropic(map()) -> map().
openai_to_anthropic(Resp) ->
    {Msg, Finish} = case maps:get(<<"choices">>, Resp, []) of
                        [C | _] -> {maps:get(<<"message">>, C, #{}),
                                    maps:get(<<"finish_reason">>, C, null)};
                        [] -> {#{}, null}
                    end,
    Thinking = case maps:get(<<"reasoning_content">>, Msg, null) of
                   R when is_binary(R), R =/= <<>> ->
                       [#{<<"type">> => <<"thinking">>, <<"thinking">> => R,
                          <<"signature">> => <<>>}];
                   _ -> []
               end,
    Text = case maps:get(<<"content">>, Msg, null) of
               T when is_binary(T), T =/= <<>> -> [#{<<"type">> => <<"text">>, <<"text">> => T}];
               _ -> []
           end,
    Tools = [#{<<"type">> => <<"tool_use">>, <<"id">> => maps:get(<<"id">>, C, <<>>),
               <<"name">> => maps:get(<<"name">>, F, <<>>),
               <<"input">> => decode_args(maps:get(<<"arguments">>, F, <<>>))}
             || #{<<"function">> := F} = C <- list(maps:get(<<"tool_calls">>, Msg, []))],
    #{<<"id">> => maps:get(<<"id">>, Resp, <<>>),
      <<"type">> => <<"message">>,
      <<"role">> => <<"assistant">>,
      <<"model">> => maps:get(<<"model">>, Resp, <<>>),
      <<"content">> => Thinking ++ Text ++ Tools,
      <<"stop_reason">> => finish_o2a(Finish),
      <<"stop_sequence">> => null,
      <<"usage">> => lg_usage:to_anthropic(lg_usage:from_openai(maps:get(<<"usage">>, Resp, null)))}.

-spec finish_a2o(binary() | null) -> binary() | null.
finish_a2o(<<"end_turn">>) -> <<"stop">>;
finish_a2o(<<"stop_sequence">>) -> <<"stop">>;
finish_a2o(<<"pause_turn">>) -> <<"stop">>;
finish_a2o(<<"max_tokens">>) -> <<"length">>;
finish_a2o(<<"tool_use">>) -> <<"tool_calls">>;
finish_a2o(<<"refusal">>) -> <<"content_filter">>;
finish_a2o(null) -> null;
finish_a2o(_) -> <<"stop">>.

-spec finish_o2a(binary() | null) -> binary() | null.
finish_o2a(<<"stop">>) -> <<"end_turn">>;
finish_o2a(<<"length">>) -> <<"max_tokens">>;
finish_o2a(<<"tool_calls">>) -> <<"tool_use">>;
finish_o2a(<<"function_call">>) -> <<"tool_use">>;
finish_o2a(<<"content_filter">>) -> <<"refusal">>;
finish_o2a(null) -> null;
finish_o2a(_) -> <<"end_turn">>.

decode_args(<<>>) -> #{};
decode_args(A) when is_binary(A) ->
    try json:decode(A) of
        M when is_map(M) -> M;
        _ -> #{}
    catch
        error:_ -> #{}
    end;
decode_args(_) -> #{}.

list(L) when is_list(L) -> L;
list(_) -> [].
