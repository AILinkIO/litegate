%% @doc OpenAI Responses API ↔ Chat Completions（JSON map，binary 键）。
%%
%% 请求：instructions → system 消息；input（字符串或输入项）→ messages；扁平 tools → function tools；
%%       max_output_tokens → max_tokens；reasoning.effort → reasoning_effort；text.format → response_format。
%%       custom 工具（自由文本输入，如 Codex 的 apply_patch）→ 带单个字符串参数 input 的函数；
%%       namespace 工具组（如 Codex 的 multi_agent_v1）→ 展开为 `命名空间__工具名` 的函数；
%%       其余内置工具（web_search 等）无 Chat 对应物，丢弃。
%%       输入中的 reasoning 项挂到其后的 assistant 消息上作为 reasoning_content（思考链回传）。
%% 响应：Chat 的 reasoning_content / message / tool_calls → Responses 的 output 项
%%       （reasoning、message、function_call / custom_tool_call，按 tool_map/1 还原工具名）。
-module(lg_conv_responses).

-export([request_to_chat/1, chat_to_response/2, input_items/1, output_items/1,
         chat_messages/1, new_id/1, usage_out/1, response/6, message_item/3, function_call_item/5,
         tool_map/1, call_item/5, reasoning_item/3]).

-define(NS_SEP, <<"__">>).

%%====================================================================
%% 请求
%%====================================================================

-spec request_to_chat(map()) -> {ok, map()} | {error, term()}.
request_to_chat(Req) ->
    try
        System = case maps:get(<<"instructions">>, Req, null) of
                     I when is_binary(I), I =/= <<>> -> [#{<<"role">> => <<"system">>, <<"content">> => I}];
                     _ -> []
                 end,
        Chat0 = #{<<"model">> => maps:get(<<"model">>, Req, <<>>),
                  <<"messages">> => System ++ chat_messages(input_items(Req))},
        {ok, lists:foldl(fun(F, C) -> F(Req, C) end, Chat0,
                         [fun tools/2, fun tool_choice/2, fun sampling/2, fun format/2, fun stream/2])}
    catch
        throw:{unsupported, _} = E -> {error, E}
    end.

%% @doc 规范化的输入项列表（字符串 input 视为一条用户消息）。
-spec input_items(map()) -> [map()].
input_items(Req) ->
    case maps:get(<<"input">>, Req, []) of
        S when is_binary(S) -> [#{<<"type">> => <<"message">>, <<"role">> => <<"user">>, <<"content">> => S}];
        L when is_list(L) -> [item(I) || I <- L];
        _ -> []
    end.

%% 没有 type 但有 role 的项视为消息
item(#{<<"type">> := _} = I) -> I;
item(#{<<"role">> := _} = I) -> I#{<<"type">> => <<"message">>};
item(_) -> throw({unsupported, <<"input item">>}).

%% @doc 输入项 → Chat 消息。连续的 function_call 合并进同一条 assistant 消息。
-spec chat_messages([map()]) -> [map()].
chat_messages(Items) ->
    [M || M <- lists:reverse(lists:foldl(fun to_msg/2, [], Items)), is_map(M)].

to_msg(#{<<"type">> := <<"message">>, <<"role">> := Role, <<"content">> := C}, Acc0) ->
    R = case Role of <<"developer">> -> <<"system">>; _ -> Role end,
    {Reasoning, Acc} = case R of
                           <<"assistant">> -> take_reasoning(Acc0);
                           _ -> {<<>>, Acc0}
                       end,
    [with_reasoning(#{<<"role">> => R, <<"content">> => content(R, C)}, Reasoning) | Acc];
to_msg(#{<<"type">> := <<"function_call">>, <<"call_id">> := Id, <<"name">> := N} = F, Acc) ->
    Name = case maps:get(<<"namespace">>, F, null) of
               Ns when is_binary(Ns), Ns =/= <<>> -> <<Ns/binary, ?NS_SEP/binary, N/binary>>;
               _ -> N
           end,
    add_call(Id, Name, maps:get(<<"arguments">>, F, <<"{}">>), Acc);
to_msg(#{<<"type">> := <<"custom_tool_call">>, <<"call_id">> := Id, <<"name">> := N} = F, Acc) ->
    add_call(Id, N, iolist_to_binary(json:encode(#{<<"input">> => maps:get(<<"input">>, F, <<>>)})), Acc);
to_msg(#{<<"type">> := T, <<"call_id">> := Id} = O, Acc)
  when T =:= <<"function_call_output">>; T =:= <<"custom_tool_call_output">> ->
    Out = case maps:get(<<"output">>, O, <<>>) of
              B when is_binary(B) -> B;
              Parts when is_list(Parts) -> iolist_to_binary([X || #{<<"text">> := X} <- Parts]);
              Other -> iolist_to_binary(json:encode(Other))
          end,
    [#{<<"role">> => <<"tool">>, <<"tool_call_id">> => Id, <<"content">> => Out} | Acc];
%% reasoning 项：暂存，挂到其后的 assistant 消息上
to_msg(#{<<"type">> := <<"reasoning">>} = R, Acc) ->
    Text = iolist_to_binary([X || #{<<"text">> := X} <- list(maps:get(<<"content">>, R, []))
                                                         ++ list(maps:get(<<"summary">>, R, [])), is_binary(X)]),
    case Text of
        <<>> -> Acc;
        _ -> [{reasoning, Text} | Acc]
    end;
to_msg(#{<<"type">> := T}, _Acc) ->
    throw({unsupported, <<"input item ", T/binary>>}).

%% 连续的 function_call 合并进同一条 assistant 消息
add_call(Id, Name, Args, Acc0) ->
    Call = #{<<"id">> => Id, <<"type">> => <<"function">>,
             <<"function">> => #{<<"name">> => Name, <<"arguments">> => Args}},
    case Acc0 of
        [#{<<"role">> := <<"assistant">>} = Prev | Rest] ->
            [Prev#{<<"tool_calls">> => maps:get(<<"tool_calls">>, Prev, []) ++ [Call]} | Rest];
        _ ->
            {Reasoning, Acc} = take_reasoning(Acc0),
            [with_reasoning(#{<<"role">> => <<"assistant">>, <<"content">> => null, <<"tool_calls">> => [Call]},
                            Reasoning) | Acc]
    end.

take_reasoning([{reasoning, T} | Rest]) -> {T, Rest};
take_reasoning(Acc) -> {<<>>, Acc}.

with_reasoning(M, <<>>) -> M;
with_reasoning(M, R) -> M#{<<"reasoning_content">> => R}.

content(_Role, C) when is_binary(C) -> C;
content(Role, Parts) when is_list(Parts) ->
    Conv = [part(P) || P <- Parts],
    %% assistant 历史与纯文本输入折叠成字符串，兼容更多 OpenAI 兼容上游
    case Role =:= <<"assistant">> orelse lists:all(fun(#{<<"type">> := T}) -> T =:= <<"text">> end, Conv) of
        true -> iolist_to_binary([T || #{<<"text">> := T} <- Conv]);
        false -> Conv
    end.

part(#{<<"type">> := T, <<"text">> := X}) when T =:= <<"input_text">>; T =:= <<"output_text">>; T =:= <<"text">> ->
    #{<<"type">> => <<"text">>, <<"text">> => X};
part(#{<<"type">> := <<"refusal">>, <<"refusal">> := X}) ->
    #{<<"type">> => <<"text">>, <<"text">> => X};
part(#{<<"type">> := <<"input_image">>} = P) ->
    Url = case maps:get(<<"image_url">>, P, null) of
              U when is_binary(U) -> U;
              _ -> throw({unsupported, <<"input_image without image_url">>})
          end,
    Img = maps:filter(fun(_, V) -> V =/= null end,
                      #{<<"url">> => Url, <<"detail">> => maps:get(<<"detail">>, P, null)}),
    #{<<"type">> => <<"image_url">>, <<"image_url">> => Img};
part(#{<<"type">> := <<"input_file">>, <<"file_data">> := D} = P) ->
    File = maps:filter(fun(_, V) -> V =/= null end,
                       #{<<"file_data">> => D, <<"filename">> => maps:get(<<"filename">>, P, null)}),
    #{<<"type">> => <<"file">>, <<"file">> => File};
part(#{<<"type">> := T}) ->
    throw({unsupported, <<"content part ", T/binary>>}).

tools(Req, C) ->
    case lists:append([chat_tools(T) || T <- list(maps:get(<<"tools">>, Req, []))]) of
        [] -> C;
        Tools -> C#{<<"tools">> => Tools}
    end.

chat_tools(#{<<"type">> := <<"function">>, <<"name">> := N} = T) ->
    [chat_function(N, T)];
chat_tools(#{<<"type">> := <<"namespace">>, <<"name">> := Ns, <<"tools">> := Ts}) when is_list(Ts) ->
    [chat_function(<<Ns/binary, ?NS_SEP/binary, N/binary>>, T)
     || #{<<"type">> := <<"function">>, <<"name">> := N} = T <- Ts];
chat_tools(#{<<"type">> := <<"custom">>, <<"name">> := N} = T) ->
    Hint = case maps:get(<<"format">>, T, null) of
               #{<<"type">> := <<"grammar">>, <<"definition">> := D} when is_binary(D) ->
                   <<"\n\nThe input must follow this grammar:\n", D/binary>>;
               _ -> <<>>
           end,
    Desc = case maps:get(<<"description">>, T, null) of
               B when is_binary(B) -> B;
               _ -> <<>>
           end,
    [#{<<"type">> => <<"function">>,
       <<"function">> => #{<<"name">> => N,
                           <<"description">> => <<Desc/binary, Hint/binary>>,
                           <<"parameters">> => #{<<"type">> => <<"object">>,
                                                 <<"properties">> => #{<<"input">> => #{<<"type">> => <<"string">>,
                                                                                         <<"description">> => <<"The raw tool input">>}},
                                                 <<"required">> => [<<"input">>]}}}];
chat_tools(_) ->
    [].

chat_function(Name, T) ->
    #{<<"type">> => <<"function">>,
      <<"function">> => maps:filter(fun(_, V) -> V =/= null end,
                                    #{<<"name">> => Name,
                                      <<"description">> => maps:get(<<"description">>, T, null),
                                      <<"parameters">> => maps:get(<<"parameters">>, T, null),
                                      <<"strict">> => maps:get(<<"strict">>, T, null)})}.

%% @doc Chat 工具名 → 原始工具：{custom, Name} | {namespace, Ns, Name}（普通函数不在映射中）。
-spec tool_map(map()) -> #{binary() => {custom, binary()} | {namespace, binary(), binary()}}.
tool_map(Req) ->
    maps:from_list(lists:append(
      [case T of
           #{<<"type">> := <<"custom">>, <<"name">> := N} -> [{N, {custom, N}}];
           #{<<"type">> := <<"namespace">>, <<"name">> := Ns, <<"tools">> := Ts} when is_list(Ts) ->
               [{<<Ns/binary, ?NS_SEP/binary, N/binary>>, {namespace, Ns, N}} || #{<<"name">> := N} <- Ts];
           _ -> []
       end || T <- list(maps:get(<<"tools">>, Req, []))])).

%% @doc 一次工具调用的输出项：custom 工具 → custom_tool_call（input 取参数中的 input），
%% 命名空间工具 → function_call 带 namespace，其余 → function_call。
-spec call_item(binary(), binary(), binary(), binary(), map()) -> map().
call_item(CallId, ChatName, Args, Status, ToolMap) ->
    Id = new_id(<<"fc">>),
    case maps:get(ChatName, ToolMap, undefined) of
        {custom, N} ->
            Input = try json:decode(Args) of
                        #{<<"input">> := I} when is_binary(I) -> I;
                        _ -> Args
                    catch error:_ -> Args
                    end,
            #{<<"type">> => <<"custom_tool_call">>, <<"id">> => Id, <<"call_id">> => CallId,
              <<"name">> => N, <<"input">> => Input, <<"status">> => Status};
        {namespace, Ns, N} ->
            (function_call_item(Id, CallId, N, Args, Status))#{<<"namespace">> => Ns};
        undefined ->
            function_call_item(Id, CallId, ChatName, Args, Status)
    end.

-spec reasoning_item(binary(), binary(), binary()) -> map().
reasoning_item(Id, Text, Status) ->
    #{<<"type">> => <<"reasoning">>, <<"id">> => Id, <<"status">> => Status, <<"summary">> => [],
      <<"content">> => [#{<<"type">> => <<"reasoning_text">>, <<"text">> => Text}], <<"encrypted_content">> => null}.

tool_choice(Req, #{<<"tools">> := _} = C) ->
    C1 = case maps:get(<<"tool_choice">>, Req, null) of
             S when S =:= <<"auto">>; S =:= <<"none">>; S =:= <<"required">> -> C#{<<"tool_choice">> => S};
             #{<<"type">> := <<"function">>, <<"name">> := N} ->
                 C#{<<"tool_choice">> => #{<<"type">> => <<"function">>, <<"function">> => #{<<"name">> => N}}};
             _ -> C
         end,
    case maps:get(<<"parallel_tool_calls">>, Req, null) of
        B when is_boolean(B) -> C1#{<<"parallel_tool_calls">> => B};
        _ -> C1
    end;
tool_choice(_Req, C) ->
    C.

sampling(Req, C) ->
    C1 = lists:foldl(fun(K, Acc) ->
                             case maps:get(K, Req, null) of
                                 null -> Acc;
                                 V -> Acc#{K => V}
                             end
                     end, C, [<<"temperature">>, <<"top_p">>, <<"user">>]),
    C2 = case maps:get(<<"max_output_tokens">>, Req, null) of
             N when is_integer(N) -> C1#{<<"max_tokens">> => N};
             _ -> C1
         end,
    case maps:get(<<"reasoning">>, Req, null) of
        #{<<"effort">> := E} when is_binary(E) -> C2#{<<"reasoning_effort">> => E};
        _ -> C2
    end.

format(Req, C) ->
    case maps:get(<<"text">>, Req, null) of
        #{<<"format">> := #{<<"type">> := <<"json_schema">>} = F} ->
            Schema = maps:filter(fun(_, V) -> V =/= null end,
                                 #{<<"name">> => maps:get(<<"name">>, F, <<"response">>),
                                   <<"schema">> => maps:get(<<"schema">>, F, null),
                                   <<"strict">> => maps:get(<<"strict">>, F, null)}),
            C#{<<"response_format">> => #{<<"type">> => <<"json_schema">>, <<"json_schema">> => Schema}};
        #{<<"format">> := #{<<"type">> := <<"json_object">>}} ->
            C#{<<"response_format">> => #{<<"type">> => <<"json_object">>}};
        _ ->
            C
    end.

stream(Req, C) ->
    case maps:get(<<"stream">>, Req, false) of
        true -> C#{<<"stream">> => true, <<"stream_options">> => #{<<"include_usage">> => true}};
        _ -> C
    end.

%%====================================================================
%% 响应
%%====================================================================

%% @doc Chat Completion → Responses 对象。Meta：#{id => resp_..., request => 原请求}。
-spec chat_to_response(map(), map()) -> map().
chat_to_response(Chat, #{id := Id, request := Req}) ->
    {Msg, Finish} = case maps:get(<<"choices">>, Chat, []) of
                        [C | _] -> {maps:get(<<"message">>, C, #{}), maps:get(<<"finish_reason">>, C, null)};
                        [] -> {#{}, null}
                    end,
    Text = case maps:get(<<"content">>, Msg, null) of
               T when is_binary(T) -> T;
               _ -> <<>>
           end,
    Reasoning = case maps:get(<<"reasoning_content">>, Msg, null) of
                    R when is_binary(R), R =/= <<>> -> [reasoning_item(new_id(<<"rs">>), R, <<"completed">>)];
                    _ -> []
                end,
    MsgItems = case Text of
                   <<>> -> [];
                   _ -> [message_item(new_id(<<"msg">>), Text, <<"completed">>)]
               end,
    Map = tool_map(Req),
    Calls = [call_item(maps:get(<<"id">>, TC, new_id(<<"call">>)), maps:get(<<"name">>, F, <<>>),
                       maps:get(<<"arguments">>, F, <<>>), <<"completed">>, Map)
             || #{<<"function">> := F} = TC <- list(maps:get(<<"tool_calls">>, Msg, []))],
    response(Id, Req, maps:get(<<"model">>, Chat, maps:get(<<"model">>, Req, <<>>)),
             Reasoning ++ MsgItems ++ Calls, Finish, lg_usage:from_openai(maps:get(<<"usage">>, Chat, null))).

%% @doc 组装 Responses 对象（非流式转换与流式结束时共用）。
-spec response(binary(), map(), binary(), [map()], binary() | null, lg_usage:usage()) -> map().
response(Id, Req, Model, Output, Finish, Usage) ->
    {Status, Incomplete} = case Finish of
                               <<"length">> -> {<<"incomplete">>, #{<<"reason">> => <<"max_output_tokens">>}};
                               _ -> {<<"completed">>, null}
                           end,
    #{<<"id">> => Id,
      <<"object">> => <<"response">>,
      <<"created_at">> => erlang:system_time(second),
      <<"status">> => Status,
      <<"incomplete_details">> => Incomplete,
      <<"error">> => null,
      <<"model">> => Model,
      <<"output">> => Output,
      <<"usage">> => usage_out(Usage),
      <<"instructions">> => maps:get(<<"instructions">>, Req, null),
      <<"previous_response_id">> => maps:get(<<"previous_response_id">>, Req, null),
      <<"store">> => maps:get(<<"store">>, Req, true),
      <<"temperature">> => maps:get(<<"temperature">>, Req, null),
      <<"top_p">> => maps:get(<<"top_p">>, Req, null),
      <<"max_output_tokens">> => maps:get(<<"max_output_tokens">>, Req, null),
      <<"tools">> => maps:get(<<"tools">>, Req, []),
      <<"tool_choice">> => maps:get(<<"tool_choice">>, Req, <<"auto">>),
      <<"parallel_tool_calls">> => maps:get(<<"parallel_tool_calls">>, Req, true),
      <<"text">> => maps:get(<<"text">>, Req, #{<<"format">> => #{<<"type">> => <<"text">>}}),
      <<"reasoning">> => maps:get(<<"reasoning">>, Req, null),
      <<"metadata">> => maps:get(<<"metadata">>, Req, #{})}.

-spec usage_out(lg_usage:usage()) -> map().
usage_out(#{input := In, output := Out, cache_read := CR, cache_write := CW, reasoning := R}) ->
    Input = In + CR + CW,
    #{<<"input_tokens">> => Input,
      <<"input_tokens_details">> => #{<<"cached_tokens">> => CR},
      <<"output_tokens">> => Out,
      <<"output_tokens_details">> => #{<<"reasoning_tokens">> => R},
      <<"total_tokens">> => Input + Out}.

%% @doc Responses 对象的输出项（用于保存会话历史）。
-spec output_items(map()) -> [map()].
output_items(Resp) ->
    list(maps:get(<<"output">>, Resp, [])).

-spec message_item(binary(), binary(), binary()) -> map().
message_item(Id, Text, Status) ->
    #{<<"type">> => <<"message">>, <<"id">> => Id, <<"status">> => Status, <<"role">> => <<"assistant">>,
      <<"content">> => [#{<<"type">> => <<"output_text">>, <<"text">> => Text, <<"annotations">> => []}]}.

-spec function_call_item(binary(), binary(), binary(), binary(), binary()) -> map().
function_call_item(Id, CallId, Name, Args, Status) ->
    #{<<"type">> => <<"function_call">>, <<"id">> => Id, <<"call_id">> => CallId,
      <<"name">> => Name, <<"arguments">> => Args, <<"status">> => Status}.

-spec new_id(binary()) -> binary().
new_id(Prefix) ->
    <<Prefix/binary, "_", (binary:encode_hex(crypto:strong_rand_bytes(12), lowercase))/binary>>.

list(L) when is_list(L) -> L;
list(_) -> [].
