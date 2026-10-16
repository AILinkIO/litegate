%% @doc 结构化输出（JSON Schema / JSON 对象）跨协议转换。
%%
%% 读取（统一为 #{kind := json_schema | json_object, name, schema, strict}）：
%%   OpenAI Chat `response_format`、Anthropic `output_config.format`（Responses 的 `text.format` 已由 lg_conv_responses 转为 response_format）
%% 写到上游：
%%   - OpenAI 协议：`response_format`
%%   - Anthropic 协议：
%%       native：`output_config.format`（Anthropic 官方接口）
%%       tool：  加一个与输出同名的工具并强制调用（tool_choice），回复时把工具参数还原成正文 JSON、stop_reason 还原为 end_turn；
%%               给不支持 output_config 的 Anthropic 兼容上游用（各家都支持工具调用）
%%     凭证选项 structured_output 为 native | tool；不设时 api.anthropic.com 用 native，其余用 tool。
%%     请求里本来就带其他工具时不强制（强制会让模型无法调用其他工具），改用 native。
%% 同协议 OpenAI 请求不改动。
%% OpenAI 协议上游偶尔仍把 JSON 包在 ```json 代码块里（MiniMax 实测，概率性）：非流式回复整段是一个代码块且内容是合法 JSON 时
%% 去掉代码块（apply 返回 json 标记，response/2 处理）。
-module(lg_structured).

-export([read/2, apply/4, mode/1, response/2, stream_event/2]).

-include_lib("lg_core/include/lg_core.hrl").

-define(DEFAULT_NAME, <<"structured_output">>).

-type spec() :: #{kind := json_schema | json_object, name := binary(), schema := map(), strict := boolean()}.
-export_type([spec/0]).

%% @doc 客户端请求里的结构化输出要求；没有时 none。
-spec read(openai | anthropic | responses, map()) -> spec() | none.
read(_, #{<<"response_format">> := #{<<"type">> := <<"json_schema">>, <<"json_schema">> := JS}}) when is_map(JS) ->
    #{kind => json_schema, name => name(maps:get(<<"name">>, JS, ?DEFAULT_NAME)),
      schema => maps:get(<<"schema">>, JS, #{<<"type">> => <<"object">>}), strict => maps:get(<<"strict">>, JS, false) =:= true};
read(_, #{<<"response_format">> := #{<<"type">> := <<"json_object">>}}) ->
    #{kind => json_object, name => ?DEFAULT_NAME, schema => #{<<"type">> => <<"object">>}, strict => false};
read(_, #{<<"output_config">> := #{<<"format">> := #{<<"type">> := <<"json_schema">>} = F}}) ->
    #{kind => json_schema, name => name(maps:get(<<"name">>, F, ?DEFAULT_NAME)),
      schema => maps:get(<<"schema">>, F, #{<<"type">> => <<"object">>}), strict => true};
read(_, _) ->
    none.

%% 工具名只能是 [a-zA-Z0-9_-]，最长 64
name(N) when is_binary(N), N =/= <<>> ->
    S = re:replace(N, "[^a-zA-Z0-9_-]", "_", [global, {return, binary}]),
    binary:part(S, 0, min(64, byte_size(S)));
name(_) ->
    ?DEFAULT_NAME.

%% @doc Anthropic 协议上游使用哪种方式。
-spec mode(#lg_credential{}) -> native | tool.
mode(#lg_credential{options = #{structured_output := <<"native">>}}) -> native;
mode(#lg_credential{options = #{structured_output := <<"tool">>}}) -> tool;
mode(#lg_credential{base_url = Base}) ->
    case catch uri_string:parse(Base) of
        #{host := <<"api.anthropic.com">>} -> native;
        _ -> tool
    end.

%% @doc 把结构化输出要求写进发往上游的请求体（已转换为上游协议）。
%% 返回 {Body, undefined | ToolName | json}：ToolName 表示用了强制工具方式，回复需要还原；json 表示 OpenAI 协议上游，
%% 回复只需去掉可能的代码块。
-spec apply(openai | anthropic, openai | anthropic | responses, map(), {#lg_credential{}, map()} | {#lg_credential{}, map(), binary() | undefined}) ->
          {map(), binary() | json | undefined}.
apply(Up, Client, Body, {Cred, Req}) ->
    apply(Up, Client, Body, {Cred, Req, undefined});
apply(Up, Client, Body, {Cred, Req, Model}) ->
    case read(Client, Req) of
        none -> {Body, undefined};
        Spec -> write(Up, same(Client, Up), Spec, Body, {Cred, Model})
    end.

same(openai, openai) -> true;
same(responses, openai) -> true;
same(anthropic, anthropic) -> true;
same(_, _) -> false.

%% OpenAI 上游：同协议原样；跨协议补上 response_format
write(openai, true, _Spec, Body, _CM) ->
    {Body, json};
write(openai, false, #{kind := json_object}, Body, _CM) ->
    {Body#{<<"response_format">> => #{<<"type">> => <<"json_object">>}}, json};
write(openai, false, #{name := N, schema := S, strict := St}, Body, _CM) ->
    {Body#{<<"response_format">> => #{<<"type">> => <<"json_schema">>,
                                      <<"json_schema">> => #{<<"name">> => N, <<"schema">> => S, <<"strict">> => St}}},
     json};
%% Anthropic 上游
write(anthropic, _Same, #{name := N, schema := S} = Spec, Body0, {Cred, Model}) ->
    Body = maps:remove(<<"output_config">>, Body0),
    OtherTools = maps:get(<<"tools">>, Body, []) =/= [],
    %% 已学到该上游不支持 output_config（lg_unfit）时总用强制工具
    Native = mode(Cred) =:= native andalso
        not (is_binary(Model) andalso lg_unfit:has(Cred#lg_credential.id, Model, output_config)),
    case Native orelse OtherTools of
        true ->
            Format = case Spec of
                         #{kind := json_object} -> #{<<"type">> => <<"json_schema">>, <<"schema">> => #{<<"type">> => <<"object">>}};
                         _ -> #{<<"type">> => <<"json_schema">>, <<"schema">> => S}
                     end,
            Cfg = maps:get(<<"output_config">>, Body0, #{}),
            {Body#{<<"output_config">> => (case is_map(Cfg) of true -> Cfg; false -> #{} end)#{<<"format">> => Format}}, undefined};
        false ->
            Tool = #{<<"name">> => N,
                     <<"description">> => <<"Respond with your final answer as the input of this tool. "
                                            "Call it exactly once; do not answer in plain text.">>,
                     <<"input_schema">> => object_schema(S)},
            %% 强制工具调用与扩展思考不能同时使用（Anthropic 规定）。只去掉 thinking 不够：DeepSeek、百炼、Kimi
            %% 默认开启思考，会拒绝「思考模式下的 tool_choice」，所以显式关闭；始终思考的模型拒绝关闭时由 lg_unfit
            %% 学到 thinking_off 与 forced_tool（改为 tool_choice auto，靠工具描述引导模型调用）
            {Body#{<<"tools">> => [Tool], <<"thinking">> => #{<<"type">> => <<"disabled">>},
                   <<"tool_choice">> => #{<<"type">> => <<"tool">>, <<"name">> => N}}, N}
    end.

%% 工具的 input_schema 必须是 object；顶层不是 object 时包一层 {result: ...}
object_schema(#{<<"type">> := <<"object">>} = S) -> S;
object_schema(S) -> #{<<"type">> => <<"object">>, <<"properties">> => #{<<"result">> => S}, <<"required">> => [<<"result">>]}.

%% @doc 非流式 Anthropic 回复：强制工具方式时把该工具调用还原成正文 JSON。
-spec response(map(), binary() | json | undefined) -> map().
response(J, undefined) ->
    J;
response(#{<<"choices">> := Cs} = J, json) when is_list(Cs) ->
    J#{<<"choices">> => [case C of
                             #{<<"message">> := #{<<"content">> := T} = M} when is_binary(T) ->
                                 C#{<<"message">> => M#{<<"content">> => unfence(T)}};
                             _ -> C
                         end || C <- Cs]};
response(J, json) ->
    J;
response(#{<<"content">> := Blocks} = J, Name) when is_list(Blocks) ->
    case [B || #{<<"type">> := <<"tool_use">>, <<"name">> := N} = B <- Blocks, N =:= Name] of
        [] -> J;
        _ ->
            Content = [case B of
                           #{<<"type">> := <<"tool_use">>, <<"name">> := Name} ->
                               #{<<"type">> => <<"text">>, <<"text">> => iolist_to_binary(json:encode(unwrap(maps:get(<<"input">>, B, #{}))))};
                           _ -> B
                       end || B <- Blocks],
            J#{<<"content">> => Content,
               <<"stop_reason">> => case maps:get(<<"stop_reason">>, J, null) of
                                        <<"tool_use">> -> <<"end_turn">>;
                                        R -> R
                                    end}
    end;
response(J, _) ->
    J.

%% 包过一层 {result: ...} 时还原；有的模型（MiniMax 实测）把参数再包成 {name, parameters}
unwrap(#{<<"result">> := R} = M) when map_size(M) =:= 1 -> R;
unwrap(#{<<"name">> := N, <<"parameters">> := P} = M) when map_size(M) =:= 2, is_binary(N), is_map(P) -> unwrap(P);
unwrap(M) -> M.

%% 整段是一个 ```json 代码块且内容是合法 JSON 时去掉代码块
unfence(T) ->
    case re:run(T, "^\\s*```(?:json)?[ \\t]*\\n(.*?)\\n?```\\s*$", [dotall, {capture, all_but_first, binary}, unicode]) of
        {match, [Inner]} ->
            try json:decode(Inner) of
                _ -> string:trim(Inner)
            catch _:_ -> T
            end;
        nomatch -> T
    end.

%% @doc 流式 Anthropic 事件：强制工具方式时，该工具的内容块改写为文本块（参数分片 → 文本分片），
%% stop_reason tool_use → end_turn。State：当前被改写的内容块 index 集合。
-spec stream_event({map(), [integer()]}, binary()) -> {map(), [integer()]}.
stream_event({#{data := D} = Ev, Idx}, Name) when is_binary(D) ->
    case catch json:decode(D) of
        #{<<"type">> := <<"content_block_start">>, <<"index">> := I,
          <<"content_block">> := #{<<"type">> := <<"tool_use">>, <<"name">> := Name}} = J ->
            {reencode(Ev, J#{<<"content_block">> => #{<<"type">> => <<"text">>, <<"text">> => <<>>}}), [I | Idx]};
        #{<<"type">> := <<"content_block_delta">>, <<"index">> := I,
          <<"delta">> := #{<<"type">> := <<"input_json_delta">>, <<"partial_json">> := P}} = J ->
            case lists:member(I, Idx) of
                true -> {reencode(Ev, J#{<<"delta">> => #{<<"type">> => <<"text_delta">>, <<"text">> => P}}), Idx};
                false -> {Ev, Idx}
            end;
        #{<<"type">> := <<"message_delta">>, <<"delta">> := #{<<"stop_reason">> := <<"tool_use">>} = Dl} = J when Idx =/= [] ->
            {reencode(Ev, J#{<<"delta">> => Dl#{<<"stop_reason">> => <<"end_turn">>}}), Idx};
        _ ->
            {Ev, Idx}
    end;
stream_event({Ev, Idx}, _Name) ->
    {Ev, Idx}.

reencode(#{event := E} = Ev, J) ->
    D = iolist_to_binary(json:encode(J)),
    Raw = case E of
              undefined -> lg_sse:encode(D);
              _ -> lg_sse:encode(E, D)
          end,
    Ev#{data => D, raw => iolist_to_binary(Raw)}.
