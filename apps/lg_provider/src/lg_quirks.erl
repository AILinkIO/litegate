%% @doc 按上游修补请求体（各家对标准请求的额外要求）。在 lg_provider:upstream_request/3 组装好请求体后调用。
%%
%% DeepSeek（主机或模型名含 deepseek，含经百炼等平台调用的 deepseek 模型）：思考模式下，带工具调用的助手轮次
%% 必须回传思考内容，否则 400：
%%   - Anthropic：「The `content[].thinking` in the thinking mode must be passed back to the API」
%%     → 缺思考块的 tool_use 轮次补一个空白思考块；redacted_thinking 换成普通思考块（DeepSeek 不接受）
%%   - OpenAI Chat：「The `reasoning_content` in the thinking mode must be passed back to the API」
%%     → 缺 reasoning_content 的 tool_calls 轮次补一个空格
%% 对话中途换过上游、或客户端没有回传思考内容时会触发（参考 magpie 的 withThinkingOnToolTurns / withReasoningOnToolTurns）。
%%
%% Kimi（kimi-for-coding、k3、kimi-k3、kimi-k2.5 及以后）：采样参数锁定，带 temperature / top_p 时 400
%% 「invalid temperature: only 1 is allowed for this model」（实测，2026-10-13）→ 去掉这两个字段
%% （网关自己的意图判断请求带 temperature 0，客户端也可能带）。参考 magpie 的 kimiLockedSampling。
%%
%% 工具定义（JSON Schema）：
%%   Kimi：带 enum / const 却没有 type 的节点 400「not a valid moonshot flavored json schema … type is not defined」
%%         → 按枚举值补上 type（参考 magpie 的 kimiToolEnumTypes）
%%   DeepSeek：pattern 里的 \0 被拒「is not a 'regex'」→ 改写为 \u0000（参考 magpie 的 deepseekToolPatterns）
%%
%% 智谱 GLM（open.bigmodel.cn、api.z.ai 或 glm 模型，OpenAI 协议）：response_format 的 json_schema 被静默忽略，回复是
%% ```json 代码块（实测，2026-10-13）；json_object 则返回纯 JSON → 改为 json_object，并把 schema 写进系统提示
-module(lg_quirks).

-export([apply/4, deepseek/2, kimi_locked_sampling/1]).

-include_lib("lg_core/include/lg_core.hrl").

-define(BLANK, <<" ">>).

-spec apply(openai | anthropic, #lg_credential{}, binary(), map()) -> map().
apply(Up, #lg_credential{base_url = Base}, Model, Body0) ->
    Body = case deepseek(Base, Model) of
               true -> deepseek_tool_turns(Up, Body0);
               false -> Body0
           end,
    Body1 = case kimi_locked_sampling(Model) of
                true -> maps:without([<<"temperature">>, <<"top_p">>], Body);
                false -> Body
            end,
    Body2 = case kimi(Base, Model) of
                true -> map_tool_schemas(fun kimi_enum_types/1, Body1);
                false -> Body1
            end,
    Body3 = case deepseek(Base, Model) of
                true -> map_tool_schemas(fun deepseek_patterns/1, Body2);
                false -> Body2
            end,
    case Up =:= openai andalso zhipu(Base, Model) of
        true -> zhipu_json_schema(Body3);
        false -> Body3
    end.

zhipu(Base, Model) ->
    Host = case catch uri_string:parse(Base) of
               #{host := H} -> string:lowercase(H);
               _ -> <<>>
           end,
    lists:member(Host, [<<"open.bigmodel.cn">>, <<"api.z.ai">>])
        orelse (is_binary(Model) andalso re:run(string:lowercase(Model), "^glm") =/= nomatch).

zhipu_json_schema(#{<<"response_format">> := #{<<"type">> := <<"json_schema">>, <<"json_schema">> := JS},
                    <<"messages">> := Ms} = Body) when is_list(Ms) ->
    Schema = iolist_to_binary(json:encode(maps:get(<<"schema">>, JS, #{}))),
    Note = <<"Respond with a single JSON object that conforms to this JSON Schema, with no other text:\n", Schema/binary>>,
    Ms1 = case Ms of
              [#{<<"role">> := <<"system">>, <<"content">> := C} = Sys | Rest] when is_binary(C) ->
                  [Sys#{<<"content">> => <<C/binary, "\n\n", Note/binary>>} | Rest];
              _ ->
                  [#{<<"role">> => <<"system">>, <<"content">> => Note} | Ms]
          end,
    Body#{<<"response_format">> => #{<<"type">> => <<"json_object">>}, <<"messages">> => Ms1};
zhipu_json_schema(Body) ->
    Body.

kimi(Base, Model) ->
    Host = case catch uri_string:parse(Base) of
               #{host := H} -> string:lowercase(H);
               _ -> <<>>
           end,
    lists:member(Host, [<<"api.moonshot.ai">>, <<"api.moonshot.cn">>, <<"api.kimi.com">>, <<"api.kimi.ai">>])
        orelse (is_binary(Model) andalso re:run(string:lowercase(Model), "^(kimi|k3|moonshot)") =/= nomatch).

%% 对请求里每个工具的参数 schema 应用 F（OpenAI tools[].function.parameters、Anthropic tools[].input_schema）
map_tool_schemas(F, #{<<"tools">> := Tools} = Body) when is_list(Tools) ->
    Body#{<<"tools">> => [tool_schema(F, T) || T <- Tools]};
map_tool_schemas(_F, Body) ->
    Body.

tool_schema(F, #{<<"function">> := #{<<"parameters">> := P} = Fn} = T) when is_map(P) ->
    T#{<<"function">> => Fn#{<<"parameters">> => walk(F, P)}};
tool_schema(F, #{<<"input_schema">> := P} = T) when is_map(P) ->
    T#{<<"input_schema">> => walk(F, P)};
tool_schema(F, #{<<"parameters">> := P} = T) when is_map(P) ->   %% Responses 的扁平 function 工具
    T#{<<"parameters">> => walk(F, P)};
tool_schema(_F, T) ->
    T.

walk(F, M) when is_map(M) -> F(maps:map(fun(_, V) -> walk(F, V) end, M));
walk(F, L) when is_list(L) -> [walk(F, X) || X <- L];
walk(_F, V) -> V.

kimi_enum_types(#{<<"type">> := _} = N) -> N;
kimi_enum_types(#{<<"enum">> := [_ | _] = Vs} = N) -> N#{<<"type">> => value_type(Vs)};
kimi_enum_types(#{<<"const">> := V} = N) -> N#{<<"type">> => value_type([V])};
kimi_enum_types(N) -> N.

value_type(Vs) ->
    case lists:usort([json_type(V) || V <- Vs]) of
        [T] -> T;
        _ -> <<"string">>
    end.

json_type(V) when is_binary(V) -> <<"string">>;
json_type(V) when is_integer(V) -> <<"integer">>;
json_type(V) when is_float(V) -> <<"number">>;
json_type(V) when is_boolean(V) -> <<"boolean">>;
json_type(_) -> <<"string">>.

deepseek_patterns(#{<<"pattern">> := P} = N) when is_binary(P) ->
    N#{<<"pattern">> => binary:replace(P, <<"\\0">>, <<"\\u0000">>, [global])};
deepseek_patterns(N) -> N.

%% @doc 采样参数被锁定的 Kimi 模型。
-spec kimi_locked_sampling(binary()) -> boolean().
kimi_locked_sampling(Model) when is_binary(Model) ->
    re:run(string:lowercase(Model), "^(kimi-for-coding|k3|kimi-k[3-9]|kimi-k2\\.[5-9])") =/= nomatch;
kimi_locked_sampling(_) ->
    false.

%% @doc 上游是否为 DeepSeek（主机或模型名含 deepseek）。
-spec deepseek(binary(), binary()) -> boolean().
deepseek(Base, Model) ->
    Has = fun(B) -> is_binary(B) andalso binary:match(string:lowercase(B), <<"deepseek">>) =/= nomatch end,
    Host = case catch uri_string:parse(Base) of
               #{host := H} -> H;
               _ -> <<>>
           end,
    Has(Host) orelse Has(Model).

deepseek_tool_turns(anthropic, #{<<"messages">> := Ms} = Body) when is_list(Ms) ->
    Body#{<<"messages">> => [anthropic_turn(M) || M <- Ms]};
deepseek_tool_turns(openai, #{<<"messages">> := Ms} = Body) when is_list(Ms) ->
    Body#{<<"messages">> => [openai_turn(M) || M <- Ms]};
deepseek_tool_turns(_, Body) ->
    Body.

anthropic_turn(#{<<"role">> := <<"assistant">>, <<"content">> := Blocks} = M) when is_list(Blocks) ->
    B1 = [case B of
              #{<<"type">> := <<"redacted_thinking">>} -> #{<<"type">> => <<"thinking">>, <<"thinking">> => ?BLANK};
              _ -> B
          end || B <- Blocks],
    HasTool = lists:any(fun(#{<<"type">> := <<"tool_use">>}) -> true; (_) -> false end, B1),
    HasThinking = lists:any(fun(#{<<"type">> := <<"thinking">>}) -> true; (_) -> false end, B1),
    case HasTool andalso not HasThinking of
        true -> M#{<<"content">> => [#{<<"type">> => <<"thinking">>, <<"thinking">> => ?BLANK} | B1]};
        false -> M#{<<"content">> => B1}
    end;
anthropic_turn(M) ->
    M.

openai_turn(#{<<"role">> := <<"assistant">>, <<"tool_calls">> := [_ | _]} = M) ->
    case maps:get(<<"reasoning_content">>, M, null) of
        R when is_binary(R), R =/= <<>> -> M;
        _ -> M#{<<"reasoning_content">> => ?BLANK}
    end;
openai_turn(M) ->
    M.
