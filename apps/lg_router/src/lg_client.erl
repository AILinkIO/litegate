%% @doc 客户端工具识别（日志 client 字段、规则 tool 条件、实时路由页的「左边」）。
%%
%% 依次判断：
%%   1. X-LiteGate-Client（调用方自报，≤ 32 字符，限 [A-Za-z0-9_.-]）
%%   2. Claude Code：X-Claude-Code-Session-Id 或 User-Agent 以 claude-cli/ 开头
%%   3. Codex：originator 为 codex_*，或 User-Agent 含 codex
%%   4. opencode：User-Agent 含 opencode
%%   5. 官方 SDK：User-Agent 以 OpenAI/ 或 Anthropic/ 开头，或 X-Stainless-Lang 存在（按接口格式区分）
%%   6. 其他：other
-module(lg_client).

-export([detect/2, valid/1]).

-define(MAX_UA, 128).

%% @doc Headers：小写请求头 map；Format：客户端接口格式。返回 {Client, UserAgent 前 128 字节 | undefined}。
-spec detect(#{binary() => binary()}, atom()) -> {binary(), binary() | undefined}.
detect(Headers, Format) ->
    UA = maps:get(<<"user-agent">>, Headers, <<>>),
    LowUA = lower(UA),
    Own = maps:get(<<"x-litegate-client">>, Headers, undefined),
    Originator = lower(maps:get(<<"originator">>, Headers, <<>>)),
    Client = case valid(Own) of
                 true -> Own;
                 false ->
                     if
                         is_map_key(<<"x-claude-code-session-id">>, Headers) -> <<"claude-code">>;
                         true -> by_agent(LowUA, Originator, Headers, Format)
                     end
             end,
    {Client, clip(UA)}.

by_agent(UA, Originator, Headers, Format) ->
    Has = fun(S) -> binary:match(UA, S) =/= nomatch end,
    case {UA, Originator} of
        {<<"claude-cli/", _/binary>>, _} -> <<"claude-code">>;
        {_, <<"codex", _/binary>>} -> <<"codex">>;
        _ ->
            case {Has(<<"codex">>), Has(<<"opencode">>)} of
                {true, _} -> <<"codex">>;
                {_, true} -> <<"opencode">>;
                _ ->
                    Sdk = is_map_key(<<"x-stainless-lang">>, Headers),
                    case UA of
                        <<"openai/", _/binary>> -> <<"openai-sdk">>;
                        <<"anthropic/", _/binary>> -> <<"anthropic-sdk">>;
                        _ when Sdk, Format =:= anthropic -> <<"anthropic-sdk">>;
                        _ when Sdk -> <<"openai-sdk">>;
                        _ -> <<"other">>
                    end
            end
    end.

%% @doc 自报的客户端名是否合法。
-spec valid(term()) -> boolean().
valid(V) when is_binary(V), byte_size(V) > 0, byte_size(V) =< 32 ->
    re:run(V, "^[A-Za-z0-9_.-]+$") =/= nomatch;
valid(_) ->
    false.

lower(B) ->
    try string:lowercase(B) catch _:_ -> B end.

clip(<<>>) -> undefined;
clip(UA) when byte_size(UA) > ?MAX_UA -> binary:part(UA, 0, ?MAX_UA);
clip(UA) -> UA.
