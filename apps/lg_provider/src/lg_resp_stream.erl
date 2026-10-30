%% @doc Responses API 流式事件。
%%
%% converted：输入 Chat Completions chunk（map），输出 response.* 事件帧：
%%   response.created → response.in_progress →
%%   思考：output_item.added(reasoning) → reasoning_text.delta… → reasoning_text.done → output_item.done
%%   文本：output_item.added(message) → content_part.added → output_text.delta… →
%%         output_text.done → content_part.done → output_item.done
%%   工具：output_item.added(function_call) → function_call_arguments.delta… →
%%         function_call_arguments.done → output_item.done
%%   custom 工具：output_item.added(custom_tool_call) → custom_tool_call_input.done → output_item.done
%%         （Chat 参数是 JSON {"input": ...}，分片无法直接转成 input 增量，结束时一次给出）
%%   → response.completed（截断时 response.incomplete，带完整 response 与 usage）
%%   新输出项开始前先关闭当前项；每个事件带递增的 sequence_number。
%% passthrough：上游原生 Responses 流，原样转发，从 response.completed 取用量与最终响应；
%%   丢弃部分上游（如智谱 GLM）附加的 `data: [DONE]`，Responses 协议没有这一帧。
-module(lg_resp_stream).

-export([new/1, feed/2, finish/2, result/1]).

-record(rs, {
    mode :: converted | passthrough,
    id :: binary(),
    req :: map(),
    model = <<>> :: binary(),
    seq = 0 :: non_neg_integer(),
    started = false :: boolean(),
    open = none :: none | {text, binary(), non_neg_integer(), iodata()}
                 | {reasoning, binary(), non_neg_integer(), iodata()}
                 | {tool, non_neg_integer(), map()},  %% {tool, Chat 工具下标, #{id, call_id, name, args, output_index}}
    tools = #{} :: map(),                              %% lg_conv_responses:tool_map/1
    done = [] :: [map()],                              %% 已完成的输出项（逆序）
    next = 0 :: non_neg_integer(),                     %% 下一个 output_index
    finish = null :: binary() | null,
    usage :: lg_usage:usage(),
    text = [] :: iodata(),
    final :: map() | undefined
}).

-spec new(#{mode := converted | passthrough, request := map(), id => binary()}) -> #rs{}.
new(#{mode := Mode, request := Req} = Opts) ->
    #rs{mode = Mode, req = Req, id = maps:get(id, Opts, lg_conv_responses:new_id(<<"resp">>)),
        model = maps:get(<<"model">>, Req, <<>>), usage = lg_usage:zero(),
        tools = lg_conv_responses:tool_map(Req)}.

%% @doc converted：Chat chunk map；passthrough：SSE 事件（lg_sse:event()）。
-spec feed(map(), #rs{}) -> {[iodata()], #rs{}}.
feed(#{data := <<"[DONE]">>}, #rs{mode = passthrough} = S) ->
    {[], S};
feed(#{raw := Raw, data := Data}, #rs{mode = passthrough} = S) ->
    S1 = try json:decode(Data) of
             #{<<"type">> := <<"response.output_text.delta">>, <<"delta">> := D} ->
                 S#rs{text = [S#rs.text, copy(D)]};
             #{<<"type">> := T, <<"response">> := R}
               when T =:= <<"response.completed">>; T =:= <<"response.incomplete">> ->
                 S#rs{final = R, usage = lg_usage:from_responses(maps:get(<<"usage">>, R, null)),
                      model = maps:get(<<"model">>, R, S#rs.model)};
             _ -> S
         catch
             error:_ -> S
         end,
    {[Raw], S1};
feed(Chunk, #rs{mode = converted} = S0) ->
    {Start, S1} = ensure_started(S0),
    S2 = case maps:get(<<"model">>, Chunk, null) of
             M when is_binary(M), M =/= <<>> -> S1#rs{model = M};
             _ -> S1
         end,
    S3 = case maps:get(<<"usage">>, Chunk, null) of
             U when is_map(U) -> S2#rs{usage = lg_usage:from_openai(U)};
             _ -> S2
         end,
    {Frames, S4} = case maps:get(<<"choices">>, Chunk, []) of
                       [#{<<"delta">> := D} = C | _] when is_map(D) ->
                           {F0, S3a} = reasoning_delta(maps:get(<<"reasoning_content">>, D, null), S3),
                           {F1a, Sa} = text_delta(maps:get(<<"content">>, D, null), S3a),
                           F1 = F0 ++ F1a,
                           {F2, Sb} = tool_deltas(list(maps:get(<<"tool_calls">>, D, [])), Sa),
                           Sc = case maps:get(<<"finish_reason">>, C, null) of
                                    F when is_binary(F) -> Sb#rs{finish = F};
                                    _ -> Sb
                                end,
                           {F1 ++ F2, Sc};
                       _ ->
                           {[], S3}
                   end,
    {Start ++ Frames, S4}.

%% @doc 结束：converted 关闭当前项并发送 response.completed；Usage 为第一级累计的用量（优先）。
-spec finish(lg_usage:usage() | undefined, #rs{}) -> {[iodata()], #rs{}}.
finish(_Usage, #rs{mode = passthrough} = S) ->
    {[], S};
finish(Usage, #rs{mode = converted} = S0) ->
    {Start, S1} = ensure_started(S0),
    {Close, S2} = close_open(S1),
    S3 = case Usage of undefined -> S2; _ -> S2#rs{usage = Usage} end,
    Resp = lg_conv_responses:response(S3#rs.id, S3#rs.req, S3#rs.model, lists:reverse(S3#rs.done),
                                      S3#rs.finish, S3#rs.usage),
    Type = case maps:get(<<"status">>, Resp) of
               <<"incomplete">> -> <<"response.incomplete">>;
               _ -> <<"response.completed">>
           end,
    {F, S4} = event(Type, #{<<"response">> => Resp}, S3),
    {Start ++ Close ++ [F], S4#rs{final = Resp}}.

%% @doc 最终的 Responses 对象与累计信息。
-spec result(#rs{}) -> #{response := map() | undefined, usage := lg_usage:usage(), text := binary()}.
result(#rs{final = F, usage = U, text = T}) ->
    #{response => F, usage => U, text => iolist_to_binary(T)}.

%%====================================================================
%% converted 内部
%%====================================================================

ensure_started(#rs{started = true} = S) ->
    {[], S};
ensure_started(#rs{id = Id, req = Req, model = M} = S) ->
    Resp = (lg_conv_responses:response(Id, Req, M, [], null, lg_usage:zero()))#{
             <<"status">> => <<"in_progress">>, <<"usage">> => null},
    {F1, S1} = event(<<"response.created">>, #{<<"response">> => Resp}, S#rs{started = true}),
    {F2, S2} = event(<<"response.in_progress">>, #{<<"response">> => Resp}, S1),
    {[F1, F2], S2}.

reasoning_delta(T, S0) when is_binary(T), T =/= <<>> ->
    {Open, S1} = case S0#rs.open of
                     {reasoning, _, _, _} -> {[], S0};
                     _ -> open_reasoning(S0)
                 end,
    {reasoning, ItemId, Idx, Acc} = S1#rs.open,
    {F, S2} = event(<<"response.reasoning_text.delta">>,
                    #{<<"item_id">> => ItemId, <<"output_index">> => Idx, <<"content_index">> => 0,
                      <<"delta">> => T}, S1),
    {Open ++ [F], S2#rs{open = {reasoning, ItemId, Idx, [Acc, binary:copy(T)]}}};
reasoning_delta(_, S) ->
    {[], S}.

open_reasoning(S0) ->
    {Close, S1} = close_open(S0),
    Id = lg_conv_responses:new_id(<<"rs">>),
    Idx = S1#rs.next,
    Item = (lg_conv_responses:reasoning_item(Id, <<>>, <<"in_progress">>))#{<<"content">> => []},
    {F, S2} = event(<<"response.output_item.added">>, #{<<"output_index">> => Idx, <<"item">> => Item}, S1),
    {Close ++ [F], S2#rs{open = {reasoning, Id, Idx, []}, next = Idx + 1}}.

text_delta(T, S0) when is_binary(T), T =/= <<>> ->
    {Open, S1} = case S0#rs.open of
                     {text, _, _, _} -> {[], S0};
                     _ -> open_text(S0)
                 end,
    {text, ItemId, Idx, Acc} = S1#rs.open,
    {F, S2} = event(<<"response.output_text.delta">>,
                    #{<<"item_id">> => ItemId, <<"output_index">> => Idx, <<"content_index">> => 0,
                      <<"delta">> => T}, S1),
    T1 = binary:copy(T),
    {Open ++ [F], S2#rs{open = {text, ItemId, Idx, [Acc, T1]}, text = [S2#rs.text, T1]}};
text_delta(_, S) ->
    {[], S}.

open_text(S0) ->
    {Close, S1} = close_open(S0),
    Id = lg_conv_responses:new_id(<<"msg">>),
    Idx = S1#rs.next,
    Item = (lg_conv_responses:message_item(Id, <<>>, <<"in_progress">>))#{<<"content">> => []},
    {F1, S2} = event(<<"response.output_item.added">>, #{<<"output_index">> => Idx, <<"item">> => Item}, S1),
    {F2, S3} = event(<<"response.content_part.added">>,
                     #{<<"item_id">> => Id, <<"output_index">> => Idx, <<"content_index">> => 0,
                       <<"part">> => #{<<"type">> => <<"output_text">>, <<"text">> => <<>>,
                                       <<"annotations">> => []}}, S2),
    {Close ++ [F1, F2], S3#rs{open = {text, Id, Idx, []}, next = Idx + 1}}.

tool_deltas(Calls, S) ->
    lists:foldl(fun(TC, {Acc, St}) ->
                        {F, St1} = tool_delta(TC, St),
                        {Acc ++ F, St1}
                end, {[], S}, Calls).

tool_delta(TC, S0) ->
    CI = maps:get(<<"index">>, TC, 0),
    Fn = maps:get(<<"function">>, TC, #{}),
    {Open, S1} = case S0#rs.open of
                     {tool, CI, _} -> {[], S0};
                     _ -> open_tool(CI, TC, S0)
                 end,
    {tool, CI, #{id := ItemId, args := Args, output_index := Idx} = T} = S1#rs.open,
    case maps:get(<<"arguments">>, Fn, <<>>) of
        A when is_binary(A), A =/= <<>> ->
            S2 = S1#rs{open = {tool, CI, T#{args => <<Args/binary, A/binary>>}}},
            case custom(T, S1) of
                true ->
                    {Open, S2};
                false ->
                    {F, S3} = event(<<"response.function_call_arguments.delta">>,
                                    #{<<"item_id">> => ItemId, <<"output_index">> => Idx, <<"delta">> => A}, S2),
                    {Open ++ [F], S3}
            end;
        _ ->
            {Open, S1}
    end.

custom(#{name := N}, #rs{tools = M}) ->
    case maps:get(N, M, undefined) of
        {custom, _} -> true;
        _ -> false
    end.

open_tool(CI, TC, S0) ->
    {Close, S1} = close_open(S0),
    Fn = maps:get(<<"function">>, TC, #{}),
    Idx = S1#rs.next,
    CallId = case maps:get(<<"id">>, TC, null) of
                 Id when is_binary(Id), Id =/= <<>> -> Id;
                 _ -> lg_conv_responses:new_id(<<"call">>)
             end,
    Name = maps:get(<<"name">>, Fn, <<>>),
    Item = lg_conv_responses:call_item(CallId, Name, <<>>, <<"in_progress">>, S1#rs.tools),
    {F, S2} = event(<<"response.output_item.added">>, #{<<"output_index">> => Idx, <<"item">> => Item}, S1),
    T = #{id => maps:get(<<"id">>, Item), call_id => CallId, name => Name, args => <<>>, output_index => Idx},
    {Close ++ [F], S2#rs{open = {tool, CI, T}, next = Idx + 1}}.

close_open(#rs{open = none} = S) ->
    {[], S};
close_open(#rs{open = {text, Id, Idx, Acc}} = S0) ->
    Text = iolist_to_binary(Acc),
    Part = #{<<"type">> => <<"output_text">>, <<"text">> => Text, <<"annotations">> => []},
    Item = lg_conv_responses:message_item(Id, Text, <<"completed">>),
    Base = #{<<"item_id">> => Id, <<"output_index">> => Idx, <<"content_index">> => 0},
    {F1, S1} = event(<<"response.output_text.done">>, Base#{<<"text">> => Text}, S0),
    {F2, S2} = event(<<"response.content_part.done">>, Base#{<<"part">> => Part}, S1),
    {F3, S3} = event(<<"response.output_item.done">>, #{<<"output_index">> => Idx, <<"item">> => Item}, S2),
    {[F1, F2, F3], S3#rs{open = none, done = [Item | S3#rs.done]}};
close_open(#rs{open = {reasoning, Id, Idx, Acc}} = S0) ->
    Text = iolist_to_binary(Acc),
    Item = lg_conv_responses:reasoning_item(Id, Text, <<"completed">>),
    {F1, S1} = event(<<"response.reasoning_text.done">>,
                     #{<<"item_id">> => Id, <<"output_index">> => Idx, <<"content_index">> => 0, <<"text">> => Text}, S0),
    {F2, S2} = event(<<"response.output_item.done">>, #{<<"output_index">> => Idx, <<"item">> => Item}, S1),
    {[F1, F2], S2#rs{open = none, done = [Item | S2#rs.done]}};
close_open(#rs{open = {tool, _, #{id := Id, call_id := CallId, name := Name, args := Args, output_index := Idx}},
               tools = Map} = S0) ->
    Item = (lg_conv_responses:call_item(CallId, Name, Args, <<"completed">>, Map))#{<<"id">> => Id},
    {F1, S1} = case Item of
                   #{<<"type">> := <<"custom_tool_call">>, <<"input">> := Input} ->
                       event(<<"response.custom_tool_call_input.done">>,
                             #{<<"item_id">> => Id, <<"output_index">> => Idx, <<"input">> => Input}, S0);
                   _ ->
                       event(<<"response.function_call_arguments.done">>,
                             #{<<"item_id">> => Id, <<"output_index">> => Idx, <<"arguments">> => Args}, S0)
               end,
    {F2, S2} = event(<<"response.output_item.done">>, #{<<"output_index">> => Idx, <<"item">> => Item}, S1),
    {[F1, F2], S2#rs{open = none, done = [Item | S2#rs.done]}}.

event(Type, Payload, #rs{seq = N} = S) ->
    {lg_sse:encode(Type, json:encode(Payload#{<<"type">> => Type, <<"sequence_number">> => N})),
     S#rs{seq = N + 1}}.

list(L) when is_list(L) -> L;
list(_) -> [].

%% 累积的增量拷贝出来：json:decode 返回的字符串是输入的 sub-binary，直接累积会钉住整块上游数据
copy(B) when is_binary(B) -> binary:copy(B);
copy(X) -> X.
