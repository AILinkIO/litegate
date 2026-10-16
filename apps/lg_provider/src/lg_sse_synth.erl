%% @doc 把上游的非流式响应体合成为该上游协议的 SSE 流（上游忽略 stream: true、直接返回 JSON 时使用），
%% 合成结果交给 lg_stream 照常处理（同协议透传或跨协议转换）。
-module(lg_sse_synth).

-export([sse/2, error_body/1]).

%% @doc 响应体是否为业务错误：ok | {error, Status} | {minimax, Code}。
%% OpenAI / Anthropic 风格的 error 对象按其中的状态码（没有时 502）；MiniMax 的 base_resp.status_code ≠ 0 返回错误码，
%% 由调用方按 lg_media:minimax_error/2 映射。
-spec error_body(map()) -> ok | {error, pos_integer()} | {minimax, integer()}.
error_body(#{<<"base_resp">> := #{<<"status_code">> := C}}) when is_integer(C), C =/= 0 ->
    {minimax, C};
error_body(#{<<"error">> := E}) when E =/= null ->
    Status = case E of
                 #{<<"code">> := N} when is_integer(N), N >= 400, N < 600 -> N;
                 #{<<"status">> := N} when is_integer(N), N >= 400, N < 600 -> N;
                 _ -> 502
             end,
    {error, Status};
error_body(_) ->
    ok.

-spec sse(openai | anthropic, map()) -> binary().
sse(openai, J) ->
    Id = maps:get(<<"id">>, J, <<"chatcmpl-synth">>),
    Model = maps:get(<<"model">>, J, <<>>),
    Base = #{<<"id">> => Id, <<"object">> => <<"chat.completion.chunk">>, <<"model">> => Model,
             <<"created">> => maps:get(<<"created">>, J, erlang:system_time(second))},
    {Msg, Finish} = case maps:get(<<"choices">>, J, []) of
                        [#{<<"message">> := M} = C | _] -> {M, maps:get(<<"finish_reason">>, C, <<"stop">>)};
                        _ -> {#{}, <<"stop">>}
                    end,
    Delta0 = maps:with([<<"content">>, <<"reasoning_content">>], Msg),
    Delta1 = case maps:get(<<"tool_calls">>, Msg, []) of
                 Calls when is_list(Calls), Calls =/= [] ->
                     Delta0#{<<"tool_calls">> => [C#{<<"index">> => I} || {I, C} <- lists:enumerate(0, Calls)]};
                 _ -> Delta0
             end,
    Delta = Delta1#{<<"role">> => <<"assistant">>},
    Chunks = [Base#{<<"choices">> => [#{<<"index">> => 0, <<"delta">> => Delta, <<"finish_reason">> => null}]},
              Base#{<<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{}, <<"finish_reason">> => Finish}]}]
             ++ case maps:get(<<"usage">>, J, null) of
                    null -> [];
                    U -> [Base#{<<"choices">> => [], <<"usage">> => U}]
                end,
    iolist_to_binary([[lg_sse:encode(json:encode(C)) || C <- Chunks], lg_sse:done()]);
sse(anthropic, J) ->
    Blocks = maps:get(<<"content">>, J, []),
    Usage = maps:get(<<"usage">>, J, #{}),
    Start = (maps:without([<<"content">>, <<"stop_reason">>, <<"stop_sequence">>], J))#{
              <<"content">> => [], <<"stop_reason">> => null, <<"stop_sequence">> => null,
              <<"usage">> => Usage#{<<"output_tokens">> => 0}},
    Ev = fun(Type, Data) -> lg_sse:encode(Type, json:encode(Data#{<<"type">> => Type})) end,
    BlockEvents = [block_events(I, B, Ev) || {I, B} <- lists:enumerate(0, Blocks)],
    iolist_to_binary(
      [Ev(<<"message_start">>, #{<<"message">> => Start}),
       BlockEvents,
       Ev(<<"message_delta">>, #{<<"delta">> => #{<<"stop_reason">> => maps:get(<<"stop_reason">>, J, <<"end_turn">>),
                                                   <<"stop_sequence">> => maps:get(<<"stop_sequence">>, J, null)},
                                 <<"usage">> => #{<<"output_tokens">> => maps:get(<<"output_tokens">>, Usage, 0)}}),
       Ev(<<"message_stop">>, #{})]).

block_events(I, #{<<"type">> := <<"text">>} = B, Ev) ->
    [Ev(<<"content_block_start">>, #{<<"index">> => I, <<"content_block">> => #{<<"type">> => <<"text">>, <<"text">> => <<>>}}),
     Ev(<<"content_block_delta">>, #{<<"index">> => I, <<"delta">> => #{<<"type">> => <<"text_delta">>,
                                                                        <<"text">> => maps:get(<<"text">>, B, <<>>)}}),
     Ev(<<"content_block_stop">>, #{<<"index">> => I})];
block_events(I, #{<<"type">> := <<"thinking">>} = B, Ev) ->
    [Ev(<<"content_block_start">>, #{<<"index">> => I, <<"content_block">> => #{<<"type">> => <<"thinking">>,
                                                                                 <<"thinking">> => <<>>}}),
     Ev(<<"content_block_delta">>, #{<<"index">> => I, <<"delta">> => #{<<"type">> => <<"thinking_delta">>,
                                                                        <<"thinking">> => maps:get(<<"thinking">>, B, <<>>)}}),
     case maps:get(<<"signature">>, B, undefined) of
         Sig when is_binary(Sig) ->
             Ev(<<"content_block_delta">>, #{<<"index">> => I, <<"delta">> => #{<<"type">> => <<"signature_delta">>,
                                                                                <<"signature">> => Sig}});
         _ -> []
     end,
     Ev(<<"content_block_stop">>, #{<<"index">> => I})];
block_events(I, #{<<"type">> := <<"tool_use">>} = B, Ev) ->
    [Ev(<<"content_block_start">>, #{<<"index">> => I, <<"content_block">> => B#{<<"input">> => #{}}}),
     Ev(<<"content_block_delta">>, #{<<"index">> => I, <<"delta">> => #{<<"type">> => <<"input_json_delta">>,
                                                                        <<"partial_json">> => json:encode(maps:get(<<"input">>, B, #{}))}}),
     Ev(<<"content_block_stop">>, #{<<"index">> => I})];
block_events(I, B, Ev) ->
    [Ev(<<"content_block_start">>, #{<<"index">> => I, <<"content_block">> => B}),
     Ev(<<"content_block_stop">>, #{<<"index">> => I})].
