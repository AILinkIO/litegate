-module(lg_quirks_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("lg_core/include/lg_core.hrl").

cred(Base) -> #lg_credential{id = <<"c">>, name = <<"c">>, protocol = openai, base_url = Base}.

deepseek_test() ->
    ?assert(lg_quirks:deepseek(<<"https://api.deepseek.com/anthropic">>, <<"deepseek-v4-flash">>)),
    ?assert(lg_quirks:deepseek(<<"https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1">>, <<"deepseek-v4-pro">>)),
    ?assertNot(lg_quirks:deepseek(<<"https://api.minimax.cn/v1">>, <<"MiniMax-M2.7">>)).

anthropic_tool_turns_test() ->
    Use = #{<<"type">> => <<"tool_use">>, <<"id">> => <<"t1">>, <<"name">> => <<"f">>, <<"input">> => #{}},
    Body = #{<<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>},
                                #{<<"role">> => <<"assistant">>, <<"content">> => [Use]},
                                #{<<"role">> => <<"assistant">>, <<"content">> => [#{<<"type">> => <<"redacted_thinking">>, <<"data">> => <<"x">>}, Use]},
                                #{<<"role">> => <<"assistant">>, <<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"ok">>}]}]},
    #{<<"messages">> := [_, A1, A2, A3]} = lg_quirks:apply(anthropic, cred(<<"https://api.deepseek.com/anthropic">>), <<"m">>, Body),
    ?assertMatch(#{<<"content">> := [#{<<"type">> := <<"thinking">>, <<"thinking">> := <<" ">>}, #{<<"type">> := <<"tool_use">>}]}, A1),
    ?assertMatch(#{<<"content">> := [#{<<"type">> := <<"thinking">>}, #{<<"type">> := <<"tool_use">>}]}, A2),
    %% 没有工具调用的轮次不动
    ?assertMatch(#{<<"content">> := [#{<<"type">> := <<"text">>}]}, A3),
    %% 非 DeepSeek 上游不修改
    ?assertEqual(Body, lg_quirks:apply(anthropic, cred(<<"https://api.minimax.cn/anthropic">>), <<"MiniMax-M2.7">>, Body)).

openai_tool_turns_test() ->
    Call = #{<<"role">> => <<"assistant">>, <<"content">> => null,
             <<"tool_calls">> => [#{<<"id">> => <<"c1">>, <<"type">> => <<"function">>,
                                    <<"function">> => #{<<"name">> => <<"f">>, <<"arguments">> => <<"{}">>}}]},
    Kept = Call#{<<"reasoning_content">> => <<"thought">>},
    #{<<"messages">> := [A1, A2]} =
        lg_quirks:apply(openai, cred(<<"https://api.deepseek.com/v1">>), <<"deepseek-v4-flash">>, #{<<"messages">> => [Call, Kept]}),
    ?assertEqual(<<" ">>, maps:get(<<"reasoning_content">>, A1)),
    ?assertEqual(<<"thought">>, maps:get(<<"reasoning_content">>, A2)).

kimi_sampling_test() ->
    [?assert(lg_quirks:kimi_locked_sampling(M)) || M <- [<<"kimi-for-coding">>, <<"kimi-for-coding-highspeed">>, <<"k3">>,
                                                       <<"kimi-k3">>, <<"kimi-k2.5">>, <<"kimi-k2.7-code-highspeed">>]],
    [?assertNot(lg_quirks:kimi_locked_sampling(M)) || M <- [<<"kimi-k2-0905">>, <<"moonshot-v1-8k">>, <<"glm-5.3">>]],
    Body = #{<<"messages">> => [], <<"temperature">> => 0, <<"top_p">> => 0.9, <<"max_tokens">> => 8},
    ?assertEqual(#{<<"messages">> => [], <<"max_tokens">> => 8},
                 lg_quirks:apply(openai, cred(<<"https://api.kimi.com/coding/v1">>), <<"kimi-for-coding">>, Body)),
    ?assertEqual(Body, lg_quirks:apply(openai, cred(<<"https://api.minimax.cn/v1">>), <<"MiniMax-M2.7">>, Body)).

tool_schema_test() ->
    Params = #{<<"type">> => <<"object">>,
               <<"properties">> => #{<<"unit">> => #{<<"enum">> => [<<"c">>, <<"f">>]},
                                     <<"n">> => #{<<"const">> => 3},
                                     <<"code">> => #{<<"type">> => <<"string">>, <<"pattern">> => <<"^[^\\0]+$">>}}},
    Oa = #{<<"tools">> => [#{<<"type">> => <<"function">>, <<"function">> => #{<<"name">> => <<"f">>, <<"parameters">> => Params}}]},
    #{<<"tools">> := [#{<<"function">> := #{<<"parameters">> := #{<<"properties">> := K}}}]} =
        lg_quirks:apply(openai, cred(<<"https://api.kimi.com/coding/v1">>), <<"kimi-for-coding">>, Oa),
    ?assertMatch(#{<<"unit">> := #{<<"type">> := <<"string">>}, <<"n">> := #{<<"type">> := <<"integer">>}}, K),
    An = #{<<"tools">> => [#{<<"name">> => <<"f">>, <<"input_schema">> => Params}]},
    #{<<"tools">> := [#{<<"input_schema">> := #{<<"properties">> := #{<<"code">> := #{<<"pattern">> := P}}}}]} =
        lg_quirks:apply(anthropic, cred(<<"https://api.deepseek.com/anthropic">>), <<"deepseek-v4-flash">>, An),
    ?assertEqual(<<"^[^\\u0000]+$">>, P),
    %% 其他上游不改
    ?assertEqual(Oa, lg_quirks:apply(openai, cred(<<"https://api.minimax.cn/v1">>), <<"MiniMax-M2.7">>, Oa)).

%% MiniMax Responses：并行工具调用必须每个 result 紧跟对应 call；孤立 result 会返回 2013。
minimax_responses_tools_test() ->
    Call = fun(Id) -> #{<<"type">> => <<"function_call">>, <<"call_id">> => Id,
                        <<"name">> => <<"f">>, <<"arguments">> => <<"{}">>} end,
    Output = fun(Id) -> #{<<"type">> => <<"function_call_output">>, <<"call_id">> => Id,
                          <<"output">> => <<"ok">>} end,
    Message = #{<<"type">> => <<"message">>, <<"role">> => <<"user">>, <<"content">> => <<"hi">>},
    Reasoning = #{<<"type">> => <<"reasoning">>, <<"id">> => <<"rs">>, <<"summary">> => []},
    Body = #{<<"input">> => [Message, Reasoning, Call(<<"c1">>), Call(<<"c2">>),
                              Output(<<"c1">>), Output(<<"c2">>), Output(<<"lost">>)]},
    Expected = [Message, Reasoning, Call(<<"c1">>), Output(<<"c1">>),
                Call(<<"c2">>), Output(<<"c2">>)],
    #{<<"input">> := Expected} =
        lg_quirks:apply(openai, cred(<<"https://api.minimax.cn/v1">>), <<"MiniMax-M2.7">>, Body),
    %% 其他 Responses 上游保持 OpenAI 兼容排序
    ?assertEqual(Body, lg_quirks:apply(openai, cred(<<"https://api.openai.com/v1">>), <<"gpt">>, Body)).

%% 智谱 GLM 忽略 json_schema：改为 json_object，schema 写进系统提示
zhipu_json_schema_test() ->
    RF = #{<<"type">> => <<"json_schema">>, <<"json_schema">> => #{<<"name">> => <<"c">>, <<"schema">> => #{<<"type">> => <<"object">>}}},
    B = #{<<"response_format">> => RF, <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]},
    #{<<"response_format">> := F, <<"messages">> := [#{<<"role">> := <<"system">>, <<"content">> := Sys}, _]} =
        lg_quirks:apply(openai, cred(<<"https://open.bigmodel.cn/api/paas/v4">>), <<"glm-5.3">>, B),
    ?assertEqual(#{<<"type">> => <<"json_object">>}, F),
    ?assertNotEqual(nomatch, binary:match(Sys, <<"{\"type\":\"object\"}">>)),
    %% 已有系统提示：追加
    B2 = B#{<<"messages">> => [#{<<"role">> => <<"system">>, <<"content">> => <<"be brief">>} | maps:get(<<"messages">>, B)]},
    #{<<"messages">> := [#{<<"content">> := <<"be brief", _/binary>>}, _]} =
        lg_quirks:apply(openai, cred(<<"https://open.bigmodel.cn/api/paas/v4">>), <<"glm-5.3">>, B2),
    %% 其他上游不改
    ?assertEqual(B, lg_quirks:apply(openai, cred(<<"https://api.minimax.cn/v1">>), <<"MiniMax-M2.7">>, B)).
