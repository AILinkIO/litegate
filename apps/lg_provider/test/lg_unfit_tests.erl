-module(lg_unfit_tests).

-include_lib("eunit/include/eunit.hrl").

%% 错误原文：Kimi（实测）、Claude 4.7+ / 百炼 / GLM / Gemini / OpenCode Go（magpie 记录）
match_test() ->
    M = fun(Msg, Sent) -> lg_unfit:match(Msg, Sent) end,
    T = #{<<"temperature">> => 0},
    ?assertEqual([temperature], M(<<"invalid temperature: only 1 is allowed for this model">>, T)),
    ?assertEqual([temperature], M(<<"`temperature` is deprecated for this model.">>, T)),
    %% 请求里没带 temperature 时不学
    ?assertEqual([], M(<<"invalid temperature: only 1 is allowed for this model">>, #{})),
    ?assertEqual([enable_thinking_sync], M(<<"parameter.enable_thinking must be set to false for non-streaming calls">>, #{})),
    ?assertEqual([], M(<<"parameter.enable_thinking must be set to false for non-streaming calls">>, #{<<"stream">> => true})),
    Off = #{<<"thinking">> => #{<<"type">> => <<"disabled">>}},
    ?assertEqual([thinking_off], M(<<"该模型始终支持思考，不可关闭"/utf8>>, Off)),
    ?assertEqual([thinking_off], M(<<"The value of the enable_thinking parameter is restricted to True.">>, #{<<"enable_thinking">> => false})),
    Prefill = #{<<"messages">> => [#{<<"role">> => <<"user">>}, #{<<"role">> => <<"assistant">>, <<"content">> => <<"{">>}]},
    ?assertEqual([prefill], M(<<"This model does not support assistant message prefill">>, Prefill)),
    ?assertEqual([prefill], M(<<"Requests ending with a model turn are not supported">>, Prefill)),
    ?assertEqual([output_config], M(<<"output_config: Extra inputs are not permitted">>, #{<<"output_config">> => #{}})),
    RF = #{<<"response_format">> => #{<<"type">> => <<"json_schema">>}},
    ?assertEqual([json_schema], M(<<"This response_format type is unavailable now">>, RF)),
    %% 实测原文（2026-10-13）：glm-5.3 关闭思考；DeepSeek / 百炼 / Kimi 思考模式下强制工具
    ?assertEqual([thinking_off], M(<<"该模型始终思考，不支持关闭思考；请使用 low、high 或 max。"/utf8>>,
                                   #{<<"reasoning_effort">> => <<"none">>})),
    Forced = #{<<"tool_choice">> => #{<<"type">> => <<"tool">>, <<"name">> => <<"x">>}},
    ?assertEqual([forced_tool], M(<<"Thinking mode does not support this tool_choice">>, Forced)),
    ?assertEqual([forced_tool], M(<<"The tool_choice parameter does not support being set to required or object in thinking mode">>, Forced)),
    ?assertEqual([forced_tool], M(<<"tool_choice 'specified' is incompatible with thinking enabled">>, Forced)),
    ?assertEqual([], M(<<"tool_choice 'specified' is incompatible with thinking enabled">>, #{<<"tool_choice">> => <<"auto">>})),
    %% OpenAI 官方原文（store=false 时 rs_ 项未存储）与中转站措辞
    Rs = #{<<"input">> => [#{<<"type">> => <<"reasoning">>, <<"id">> => <<"rs_x">>},
                           #{<<"type">> => <<"message">>, <<"role">> => <<"user">>}]},
    ?assertEqual([bare_reasoning], M(<<"Item with id 'rs_x' not found. Items are not persisted when `store` is set to false.">>, Rs)),
    ?assertEqual([bare_reasoning], M(<<"reasoning item not found">>, Rs)),
    %% 请求里 input 没有 reasoning 项时不学
    ?assertEqual([], M(<<"Item with id 'rs_x' not found">>, #{<<"input">> => [#{<<"type">> => <<"message">>}]})),
    ?assertEqual([], M(<<"rate limit exceeded">>, T)).

apply_test() ->
    Body = #{<<"temperature">> => 0, <<"top_p">> => 0.5, <<"stream">> => false,
             <<"thinking">> => #{<<"type">> => <<"disabled">>},
             <<"response_format">> => #{<<"type">> => <<"json_schema">>, <<"json_schema">> => #{}},
             <<"messages">> => [#{<<"role">> => <<"user">>}, #{<<"role">> => <<"assistant">>}]},
    Fs = [temperature, thinking_off, enable_thinking_sync, prefill, json_schema],
    meck:new(lg_unfit, [passthrough]),
    meck:expect(lg_unfit, has, fun(_, _, F) -> lists:member(F, Fs) end),
    try
        R = lg_unfit:apply(openai, <<"c">>, <<"m">>, Body, false),
        ?assertNot(maps:is_key(<<"temperature">>, R)),
        ?assert(maps:is_key(<<"top_p">>, R)),
        ?assertNot(maps:is_key(<<"thinking">>, R)),
        ?assertEqual(false, maps:get(<<"enable_thinking">>, R)),
        ?assertEqual([#{<<"role">> => <<"user">>}], maps:get(<<"messages">>, R)),
        ?assertEqual(#{<<"type">> => <<"json_object">>}, maps:get(<<"response_format">>, R)),
        %% 流式请求不加 enable_thinking
        ?assertNot(maps:is_key(<<"enable_thinking">>, lg_unfit:apply(openai, <<"c">>, <<"m">>, Body#{<<"stream">> => true}, true)))
    after
        meck:unload(lg_unfit)
    end.

forced_tool_apply_test() ->
    meck:new(lg_unfit, [passthrough]),
    meck:expect(lg_unfit, has, fun(_, _, F) -> F =:= forced_tool end),
    try
        A = lg_unfit:apply(anthropic, <<"c">>, <<"m">>, #{<<"tool_choice">> => #{<<"type">> => <<"tool">>, <<"name">> => <<"x">>}}, false),
        ?assertEqual(#{<<"type">> => <<"auto">>}, maps:get(<<"tool_choice">>, A)),
        O = lg_unfit:apply(openai, <<"c">>, <<"m">>, #{<<"tool_choice">> => <<"required">>}, false),
        ?assertEqual(<<"auto">>, maps:get(<<"tool_choice">>, O)),
        ?assertEqual(#{}, lg_unfit:apply(openai, <<"c">>, <<"m">>, #{}, false))
    after
        meck:unload(lg_unfit)
    end.

bare_reasoning_apply_test() ->
    meck:new(lg_unfit, [passthrough]),
    meck:expect(lg_unfit, has, fun(_, _, F) -> F =:= bare_reasoning end),
    try
        In = #{<<"input">> => [#{<<"type">> => <<"reasoning">>, <<"id">> => <<"rs_a">>},
                               #{<<"type">> => <<"message">>, <<"role">> => <<"user">>, <<"content">> => <<"hi">>},
                               #{<<"type">> => <<"reasoning">>, <<"id">> => <<"rs_b">>}]},
        R = lg_unfit:apply(openai, <<"c">>, <<"m">>, In, true),
        ?assertEqual([#{<<"type">> => <<"message">>, <<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
                     maps:get(<<"input">>, R)),
        %% 非 Responses 体（messages）不受影响
        ?assertEqual(#{<<"messages">> => [#{<<"role">> => <<"user">>}]},
                     lg_unfit:apply(openai, <<"c">>, <<"m">>, #{<<"messages">> => [#{<<"role">> => <<"user">>}]}, false))
    after
        meck:unload(lg_unfit)
    end.
