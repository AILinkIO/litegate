%% @doc 请求体转换：OpenAI Chat Completions ↔ Anthropic Messages（JSON map，binary 键）。
%%
%% 未识别的顶层参数丢弃（两边参数语义不同，透传会被上游拒绝）；
%% 无法表达的内容（如 OpenAI 音频输入转 Anthropic）返回 {error, {unsupported, What}}。
-module(lg_conv_req).

-export([openai_to_anthropic/2, anthropic_to_openai/2]).

-define(DEFAULT_MAX_TOKENS, 4096).

%%====================================================================
%% OpenAI → Anthropic
%%====================================================================

-spec openai_to_anthropic(map(), map()) -> {ok, map()} | {error, term()}.
openai_to_anthropic(Req, Opts) ->
    try
        Msgs = maps:get(<<"messages">>, Req, []),
        {System, Rest} = lists:partition(fun is_system/1, Msgs),
        Body0 = #{<<"messages">> => merge_roles([o2a_message(M) || M <- Rest]),
                  <<"max_tokens">> => max_tokens(Req, Opts)},
        Body1 = case system_blocks(System) of
                    [] -> Body0;
                    Blocks -> Body0#{<<"system">> => Blocks}
                end,
        {ok, lists:foldl(fun(F, B) -> F(Req, B) end, Body1,
                         [fun o2a_sampling/2, fun o2a_stop/2, fun o2a_stream/2,
                          fun o2a_tools/2, fun o2a_tool_choice/2, fun o2a_user/2,
                          fun o2a_reasoning/2])}
    catch
        throw:{unsupported, _} = E -> {error, E}
    end.

is_system(#{<<"role">> := R}) -> R =:= <<"system">> orelse R =:= <<"developer">>;
is_system(_) -> false.

system_blocks(Msgs) ->
    [#{<<"type">> => <<"text">>, <<"text">> => T}
     || M <- Msgs, T <- text_parts(maps:get(<<"content">>, M, <<>>)), T =/= <<>>].

max_tokens(Req, Opts) ->
    case first([<<"max_completion_tokens">>, <<"max_tokens">>], Req) of
        N when is_integer(N), N > 0 -> N;
        _ -> maps:get(default_max_tokens, Opts, ?DEFAULT_MAX_TOKENS)
    end.

o2a_message(#{<<"role">> := <<"user">>} = M) ->
    #{<<"role">> => <<"user">>, <<"content">> => o2a_content(maps:get(<<"content">>, M, <<>>))};
o2a_message(#{<<"role">> := <<"assistant">>} = M) ->
    Text = [#{<<"type">> => <<"text">>, <<"text">> => T}
            || T <- text_parts(maps:get(<<"content">>, M, null)), T =/= <<>>],
    Tools = [#{<<"type">> => <<"tool_use">>,
               <<"id">> => maps:get(<<"id">>, C),
               <<"name">> => maps:get(<<"name">>, F),
               <<"input">> => decode_args(maps:get(<<"arguments">>, F, <<"{}">>))}
             || #{<<"function">> := F} = C <- list(maps:get(<<"tool_calls">>, M, []))],
    #{<<"role">> => <<"assistant">>, <<"content">> => Text ++ Tools};
o2a_message(#{<<"role">> := <<"tool">>} = M) ->
    #{<<"role">> => <<"user">>,
      <<"content">> => [#{<<"type">> => <<"tool_result">>,
                          <<"tool_use_id">> => maps:get(<<"tool_call_id">>, M, <<>>),
                          <<"content">> => o2a_tool_result(maps:get(<<"content">>, M, <<>>))}]};
o2a_message(#{<<"role">> := R}) ->
    throw({unsupported, <<"message role ", R/binary>>}).

o2a_content(Text) when is_binary(Text) ->
    [#{<<"type">> => <<"text">>, <<"text">> => Text}];
o2a_content(Parts) when is_list(Parts) ->
    [o2a_part(P) || P <- Parts];
o2a_content(null) ->
    [].

o2a_part(#{<<"type">> := <<"text">>, <<"text">> := T}) ->
    #{<<"type">> => <<"text">>, <<"text">> => T};
o2a_part(#{<<"type">> := <<"image_url">>, <<"image_url">> := Img}) ->
    Url = case Img of #{<<"url">> := U} -> U; U when is_binary(U) -> U end,
    #{<<"type">> => <<"image">>, <<"source">> => media_source(Url)};
o2a_part(#{<<"type">> := <<"file">>, <<"file">> := #{<<"file_data">> := Data}}) ->
    #{<<"type">> => <<"document">>, <<"source">> => media_source(Data)};
o2a_part(#{<<"type">> := T}) ->
    throw({unsupported, <<"content part ", T/binary>>}).

%% tool 消息内容：字符串或 text 部件列表
o2a_tool_result(Text) when is_binary(Text) -> Text;
o2a_tool_result(Parts) when is_list(Parts) -> [o2a_part(P) || P <- Parts];
o2a_tool_result(_) -> <<>>.

media_source(<<"data:", Rest/binary>>) ->
    case binary:split(Rest, <<",">>) of
        [Meta, Data] ->
            MediaType = hd(binary:split(Meta, <<";">>)),
            #{<<"type">> => <<"base64">>, <<"media_type">> => MediaType, <<"data">> => Data};
        _ ->
            throw({unsupported, <<"malformed data URI">>})
    end;
media_source(Url) ->
    #{<<"type">> => <<"url">>, <<"url">> => Url}.

o2a_sampling(Req, B) ->
    B1 = case maps:get(<<"temperature">>, Req, null) of
             T when is_number(T) -> B#{<<"temperature">> => min(T, 1.0)};  %% Anthropic 上限 1
             _ -> B
         end,
    copy([<<"top_p">>, <<"top_k">>], Req, B1).

o2a_stop(Req, B) ->
    case maps:get(<<"stop">>, Req, null) of
        S when is_binary(S) -> B#{<<"stop_sequences">> => [S]};
        [_ | _] = L -> B#{<<"stop_sequences">> => L};
        _ -> B
    end.

o2a_stream(Req, B) ->
    case maps:get(<<"stream">>, Req, false) of
        true -> B#{<<"stream">> => true};
        _ -> B
    end.

o2a_tools(Req, B) ->
    case [o2a_tool(T) || T <- list(maps:get(<<"tools">>, Req, []))] of
        [] -> B;
        Tools -> B#{<<"tools">> => Tools}
    end.

o2a_tool(#{<<"type">> := <<"function">>, <<"function">> := F}) ->
    T = #{<<"name">> => maps:get(<<"name">>, F),
          <<"input_schema">> => maps:get(<<"parameters">>, F,
                                         #{<<"type">> => <<"object">>,
                                           <<"properties">> => #{}})},
    case maps:get(<<"description">>, F, null) of
        D when is_binary(D) -> T#{<<"description">> => D};
        _ -> T
    end;
o2a_tool(#{<<"type">> := Type}) ->
    throw({unsupported, <<"tool type ", Type/binary>>}).

o2a_tool_choice(Req, B) ->
    Choice = case maps:get(<<"tool_choice">>, Req, null) of
                 <<"auto">> -> #{<<"type">> => <<"auto">>};
                 <<"required">> -> #{<<"type">> => <<"any">>};
                 <<"none">> -> #{<<"type">> => <<"none">>};
                 #{<<"function">> := #{<<"name">> := N}} -> #{<<"type">> => <<"tool">>,
                                                              <<"name">> => N};
                 _ -> undefined
             end,
    Choice1 = case {maps:get(<<"parallel_tool_calls">>, Req, null), Choice} of
                  {false, undefined} -> #{<<"type">> => <<"auto">>,
                                          <<"disable_parallel_tool_use">> => true};
                  {false, #{<<"type">> := T} = C} when T =/= <<"none">> ->
                      C#{<<"disable_parallel_tool_use">> => true};
                  _ -> Choice
              end,
    case Choice1 of
        undefined -> B;
        _ when is_map_key(<<"tools">>, B) -> B#{<<"tool_choice">> => Choice1};
        _ -> B
    end.

o2a_user(Req, B) ->
    case maps:get(<<"user">>, Req, null) of
        U when is_binary(U) -> B#{<<"metadata">> => #{<<"user_id">> => U}};
        _ -> B
    end.

%% reasoning_effort → extended thinking 预算（须小于 max_tokens）
o2a_reasoning(Req, #{<<"max_tokens">> := Max} = B) ->
    Budget = case maps:get(<<"reasoning_effort">>, Req, null) of
                 <<"minimal">> -> 1024;
                 <<"low">> -> 2048;
                 <<"medium">> -> 8192;
                 <<"high">> -> 24576;
                 _ -> undefined
             end,
    case Budget of
        undefined ->
            B;
        _ ->
            B1 = maps:remove(<<"top_k">>, maps:remove(<<"temperature">>, B)),
            MaxTokens = max(Max, Budget + 1024),
            B1#{<<"max_tokens">> => MaxTokens,
                <<"thinking">> => #{<<"type">> => <<"enabled">>,
                                    <<"budget_tokens">> => Budget}}
    end.

%% Anthropic 要求 user/assistant 交替：合并相邻同角色消息，tool_result 块排在最前
merge_roles(Msgs) ->
    lists:reverse(lists:foldl(
      fun(#{<<"role">> := R, <<"content">> := C}, [#{<<"role">> := R, <<"content">> := Prev} | Acc]) ->
              [#{<<"role">> => R, <<"content">> => order_blocks(Prev ++ C)} | Acc];
         (M, Acc) ->
              [M | Acc]
      end, [], Msgs)).

order_blocks(Blocks) ->
    {Results, Other} = lists:partition(
                         fun(#{<<"type">> := T}) -> T =:= <<"tool_result">> end, Blocks),
    Results ++ Other.

%%====================================================================
%% Anthropic → OpenAI
%%====================================================================

-spec anthropic_to_openai(map(), map()) -> {ok, map()} | {error, term()}.
anthropic_to_openai(Req, _Opts) ->
    try
        System = case maps:get(<<"system">>, Req, null) of
                     S when is_binary(S), S =/= <<>> ->
                         [#{<<"role">> => <<"system">>, <<"content">> => S}];
                     [_ | _] = Blocks ->
                         [#{<<"role">> => <<"system">>,
                            <<"content">> => join([T || #{<<"text">> := T} <- Blocks])}];
                     _ ->
                         []
                 end,
        Msgs = lists:flatmap(fun a2o_message/1, maps:get(<<"messages">>, Req, [])),
        Body0 = #{<<"messages">> => System ++ Msgs},
        Body1 = case maps:get(<<"max_tokens">>, Req, null) of
                    N when is_integer(N) -> Body0#{<<"max_tokens">> => N};
                    _ -> Body0
                end,
        {ok, lists:foldl(fun(F, B) -> F(Req, B) end, Body1,
                         [fun a2o_sampling/2, fun a2o_stop/2, fun a2o_stream/2,
                          fun a2o_tools/2, fun a2o_tool_choice/2, fun a2o_user/2])}
    catch
        throw:{unsupported, _} = E -> {error, E}
    end.

a2o_message(#{<<"role">> := Role, <<"content">> := Text}) when is_binary(Text) ->
    [#{<<"role">> => Role, <<"content">> => Text}];
a2o_message(#{<<"role">> := <<"user">>, <<"content">> := Blocks}) ->
    %% tool_result 拆成独立的 tool 消息，放在该轮用户内容之前
    {Results, Other} = lists:partition(
                         fun(#{<<"type">> := T}) -> T =:= <<"tool_result">> end, Blocks),
    Tools = [#{<<"role">> => <<"tool">>,
               <<"tool_call_id">> => maps:get(<<"tool_use_id">>, R),
               <<"content">> => a2o_tool_result(maps:get(<<"content">>, R, <<>>))}
             || R <- Results],
    User = case [P || B <- Other, P <- a2o_part(B)] of
               [] -> [];
               Parts -> [#{<<"role">> => <<"user">>, <<"content">> => Parts}]
           end,
    Tools ++ User;
a2o_message(#{<<"role">> := <<"assistant">>, <<"content">> := Blocks}) ->
    Text = join([T || #{<<"type">> := <<"text">>, <<"text">> := T} <- Blocks]),
    Calls = [#{<<"id">> => Id, <<"type">> => <<"function">>,
               <<"function">> => #{<<"name">> => Name,
                                   <<"arguments">> => iolist_to_binary(json:encode(Input))}}
             || #{<<"type">> := <<"tool_use">>, <<"id">> := Id, <<"name">> := Name,
                  <<"input">> := Input} <- Blocks],
    %% thinking 块回传为 reasoning_content（DeepSeek、GLM 等使用的扩展字段；多轮工具调用要求保留思考链）
    Thinking = join([T || #{<<"type">> := <<"thinking">>, <<"thinking">> := T} <- Blocks]),
    Msg0 = #{<<"role">> => <<"assistant">>,
             <<"content">> => case Text of <<>> when Calls =/= [] -> null; _ -> Text end},
    Msg = case Thinking of <<>> -> Msg0; _ -> Msg0#{<<"reasoning_content">> => Thinking} end,
    [case Calls of [] -> Msg; _ -> Msg#{<<"tool_calls">> => Calls} end];
%% 消息列表中的 system 消息（Claude Code 会在对话中插入）→ OpenAI system 消息
a2o_message(#{<<"role">> := <<"system">>, <<"content">> := Blocks}) when is_list(Blocks) ->
    [#{<<"role">> => <<"system">>,
       <<"content">> => join([T || #{<<"type">> := <<"text">>, <<"text">> := T} <- Blocks])}];
a2o_message(#{<<"role">> := R}) ->
    throw({unsupported, <<"message role ", R/binary>>}).

a2o_part(#{<<"type">> := <<"text">>, <<"text">> := T}) ->
    [#{<<"type">> => <<"text">>, <<"text">> => T}];
a2o_part(#{<<"type">> := <<"image">>, <<"source">> := Src}) ->
    [#{<<"type">> => <<"image_url">>, <<"image_url">> => #{<<"url">> => source_url(Src)}}];
a2o_part(#{<<"type">> := <<"document">>, <<"source">> := #{<<"type">> := <<"base64">>} = Src}) ->
    [#{<<"type">> => <<"file">>, <<"file">> => #{<<"file_data">> => source_url(Src)}}];
a2o_part(#{<<"type">> := T}) when T =:= <<"thinking">>; T =:= <<"redacted_thinking">> ->
    [];
a2o_part(#{<<"type">> := T}) ->
    throw({unsupported, <<"content block ", T/binary>>}).

a2o_tool_result(Text) when is_binary(Text) -> Text;
a2o_tool_result(Blocks) when is_list(Blocks) ->
    join([T || #{<<"type">> := <<"text">>, <<"text">> := T} <- Blocks]);
a2o_tool_result(_) -> <<>>.

source_url(#{<<"type">> := <<"base64">>, <<"media_type">> := MT, <<"data">> := D}) ->
    <<"data:", MT/binary, ";base64,", D/binary>>;
source_url(#{<<"type">> := <<"url">>, <<"url">> := U}) ->
    U;
source_url(#{<<"type">> := T}) ->
    throw({unsupported, <<"media source ", T/binary>>}).

a2o_sampling(Req, B) ->
    copy([<<"temperature">>, <<"top_p">>], Req, B).

a2o_stop(Req, B) ->
    case maps:get(<<"stop_sequences">>, Req, null) of
        [_ | _] = L -> B#{<<"stop">> => L};
        _ -> B
    end.

a2o_stream(Req, B) ->
    case maps:get(<<"stream">>, Req, false) of
        true -> B#{<<"stream">> => true,
                   <<"stream_options">> => #{<<"include_usage">> => true}};
        _ -> B
    end.

a2o_tools(Req, B) ->
    Tools = [#{<<"type">> => <<"function">>,
               <<"function">> => maps:filter(fun(_, V) -> V =/= undefined end,
                                             #{<<"name">> => maps:get(<<"name">>, T),
                                               <<"description">> => maps:get(<<"description">>, T, undefined),
                                               <<"parameters">> => maps:get(<<"input_schema">>, T, undefined)})}
             || T <- list(maps:get(<<"tools">>, Req, [])),
                %% 服务端工具（web_search 等）带 type 字段，OpenAI 无对应物
                not is_map_key(<<"type">>, T) orelse maps:get(<<"type">>, T) =:= <<"custom">>],
    case Tools of
        [] -> B;
        _ -> B#{<<"tools">> => Tools}
    end.

a2o_tool_choice(Req, B) ->
    case maps:get(<<"tool_choice">>, Req, null) of
        #{<<"type">> := T} = C when is_map_key(<<"tools">>, B) ->
            Choice = case T of
                         <<"auto">> -> <<"auto">>;
                         <<"any">> -> <<"required">>;
                         <<"none">> -> <<"none">>;
                         <<"tool">> -> #{<<"type">> => <<"function">>,
                                         <<"function">> => #{<<"name">> => maps:get(<<"name">>, C)}}
                     end,
            B1 = B#{<<"tool_choice">> => Choice},
            case maps:get(<<"disable_parallel_tool_use">>, C, false) of
                true -> B1#{<<"parallel_tool_calls">> => false};
                _ -> B1
            end;
        _ ->
            B
    end.

a2o_user(Req, B) ->
    case maps:get(<<"metadata">>, Req, null) of
        #{<<"user_id">> := U} when is_binary(U) -> B#{<<"user">> => U};
        _ -> B
    end.

%%====================================================================
%% 公共
%%====================================================================

text_parts(T) when is_binary(T) -> [T];
text_parts(Parts) when is_list(Parts) ->
    [T || #{<<"type">> := <<"text">>, <<"text">> := T} <- Parts];
text_parts(_) -> [].

decode_args(<<>>) -> #{};
decode_args(Args) when is_binary(Args) ->
    try json:decode(Args) of
        M when is_map(M) -> M;
        _ -> #{}
    catch
        error:_ -> #{}
    end;
decode_args(M) when is_map(M) -> M;
decode_args(_) -> #{}.

copy(Keys, From, To) ->
    lists:foldl(fun(K, Acc) ->
                        case maps:get(K, From, null) of
                            null -> Acc;
                            V -> Acc#{K => V}
                        end
                end, To, Keys).

first([K | Ks], M) ->
    case maps:get(K, M, null) of
        null -> first(Ks, M);
        V -> V
    end;
first([], _) -> null.

join(Texts) -> iolist_to_binary(lists:join(<<"\n">>, Texts)).

list(L) when is_list(L) -> L;
list(_) -> [].
