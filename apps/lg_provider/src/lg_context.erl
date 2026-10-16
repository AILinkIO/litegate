%% @doc 提示词构成：一次对话请求的上下文按来源估算 token（lg_tokens 的近似算法）。
%%
%% 分类：
%%   system   系统提示（Anthropic system、OpenAI system / developer 消息、Responses instructions）
%%   tools    工具定义，按工具列出
%%   history  最后一条助手消息（含工具调用）及之前的对话
%%   input    之后的内容：本轮用户输入或工具结果
%%   images   图片与文档（按固定开销计，不计入 history / input）
%% 只求量级正确，请求详情中与上游报告的输入 token 对照显示。
-module(lg_context).

-export([breakdown/2]).

-define(IMAGE_TOKENS, 1500).
-define(MSG_OVERHEAD, 4).
-define(TOOL_OVERHEAD, 8).
-define(MAX_TOOLS, 100).

-spec breakdown(openai | anthropic | responses, map()) -> map().
breakdown(F, Body) ->
    {System0, Msgs} = split_system(F, Body),
    {History, Input} = split_turn(F, Msgs),
    {SysT, SysI} = tokens(System0),
    {HisT, HisI} = msgs_tokens(History),
    {InT, InI} = msgs_tokens(Input),
    Tools = [#{name => tool_name(T), tokens => ?TOOL_OVERHEAD + lg_tokens:text(iolist_to_binary(json:encode(T)))}
             || T <- list(maps:get(<<"tools">>, Body, []))],
    ToolsT = lists:sum([N || #{tokens := N} <- Tools]),
    Images = SysI + HisI + InI,
    #{system => SysT, tools => ToolsT, history => HisT, input => InT, images => Images * ?IMAGE_TOKENS,
      total => SysT + ToolsT + HisT + InT + Images * ?IMAGE_TOKENS,
      messages => length(Msgs),
      tool_list => lists:sublist(lists:sort(fun(#{tokens := A}, #{tokens := B}) -> A >= B end, Tools), ?MAX_TOOLS)}.

%% 系统提示与对话消息
split_system(anthropic, Body) ->
    %% 消息中也可能有 role: system（Claude Code 新版在用户消息后附带环境说明）
    {Sys, Rest} = lists:partition(fun is_system/1, list(maps:get(<<"messages">>, Body, []))),
    {[maps:get(<<"system">>, Body, <<>>) | [maps:get(<<"content">>, M, <<>>) || M <- Sys]], Rest};
split_system(responses, Body) ->
    Items = case maps:get(<<"input">>, Body, []) of
                B when is_binary(B) -> [#{<<"role">> => <<"user">>, <<"content">> => B}];
                L -> list(L)
            end,
    {Sys, Rest} = lists:partition(fun is_system/1, Items),
    {[maps:get(<<"instructions">>, Body, <<>>) | [maps:get(<<"content">>, M, <<>>) || M <- Sys]], Rest};
split_system(_, Body) ->
    {Sys, Rest} = lists:partition(fun is_system/1, list(maps:get(<<"messages">>, Body, []))),
    {[maps:get(<<"content">>, M, <<>>) || M <- Sys], Rest}.

is_system(#{<<"role">> := R}) -> R =:= <<"system">> orelse R =:= <<"developer">>;
is_system(_) -> false.

%% 最后一条助手输出（Responses：助手消息、函数调用、推理项）之后为本轮输入
split_turn(F, Msgs) ->
    Idx = [I || {I, M} <- lists:enumerate(Msgs), assistant(F, M)],
    case Idx of
        [] -> {[], Msgs};
        _ -> lists:split(lists:last(Idx), Msgs)
    end.

assistant(_, #{<<"role">> := <<"assistant">>}) -> true;
assistant(responses, #{<<"type">> := T}) ->
    lists:member(T, [<<"function_call">>, <<"custom_tool_call">>, <<"reasoning">>, <<"local_shell_call">>,
                     <<"web_search_call">>, <<"computer_call">>]);
assistant(_, _) -> false.

msgs_tokens(Msgs) ->
    lists:foldl(fun(M, {T, I}) ->
                        {T1, I1} = tokens(M),
                        {T + T1 + ?MSG_OVERHEAD, I + I1}
                end, {0, 0}, Msgs).

%% {文字 token, 图片 / 文档个数}：遍历 JSON，取字符串值（跳过结构性字段与签名）
tokens(V) ->
    {Texts, Images} = walk(V, {[], 0}),
    {lg_tokens:text(iolist_to_binary(lists:join(<<"\n">>, Texts))), Images}.

walk(#{<<"type">> := T}, {Ts, I}) when T =:= <<"image">>; T =:= <<"image_url">>; T =:= <<"input_image">>;
                                       T =:= <<"document">>; T =:= <<"input_file">>; T =:= <<"file">> ->
    {Ts, I + 1};
walk(#{<<"type">> := <<"redacted_thinking">>}, Acc) ->
    Acc;
walk(M, Acc) when is_map(M) ->
    maps:fold(fun(K, V, A) ->
                      case lists:member(K, [<<"type">>, <<"role">>, <<"id">>, <<"call_id">>, <<"tool_use_id">>,
                                            <<"tool_call_id">>, <<"signature">>, <<"encrypted_content">>,
                                            <<"cache_control">>, <<"status">>]) of
                          true -> A;
                          false -> walk(V, A)
                      end
              end, Acc, M);
walk(L, Acc) when is_list(L) ->
    lists:foldl(fun walk/2, Acc, L);
walk(<<"data:", _/binary>>, {Ts, I}) ->
    {Ts, I + 1};
walk(B, {Ts, I}) when is_binary(B) ->
    {[B | Ts], I};
walk(_, Acc) ->
    Acc.

tool_name(#{<<"name">> := N}) when is_binary(N) -> N;
tool_name(#{<<"function">> := #{<<"name">> := N}}) when is_binary(N) -> N;
tool_name(#{<<"type">> := T}) when is_binary(T) -> T;
tool_name(_) -> <<"?">>.

list(L) when is_list(L) -> L;
list(_) -> [].
