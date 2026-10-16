%% @doc 中间件辅助模块 lg_mw 与内置模块 word_guard、param_override。
-module(lg_mw_tests).

-include_lib("eunit/include/eunit.hrl").

oa() -> #{<<"model">> => <<"m">>, <<"messages">> => [#{<<"role">> => <<"system">>, <<"content">> => <<"sys">>},
                                                     #{<<"role">> => <<"user">>, <<"content">> => <<"first">>},
                                                     #{<<"role">> => <<"assistant">>, <<"content">> => <<"ok">>},
                                                     #{<<"role">> => <<"user">>, <<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"Hello Bad Word">>}]}]}.
an() -> #{<<"model">> => <<"m">>, <<"system">> => <<"sys">>, <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]}.
rs() -> #{<<"model">> => <<"m">>, <<"instructions">> => <<"sys">>, <<"input">> => [#{<<"role">> => <<"user">>, <<"content">> => [#{<<"type">> => <<"input_text">>, <<"text">> => <<"yo">>}]}]}.

last_user_text_test() ->
    ?assertEqual(<<"Hello Bad Word">>, lg_mw:last_user_text(oa(), #{format => openai})),
    ?assertEqual(<<"hi">>, lg_mw:last_user_text(an(), #{format => anthropic})),
    ?assertEqual(<<"yo">>, lg_mw:last_user_text(rs(), #{format => responses})),
    ?assertEqual(<<"plain">>, lg_mw:last_user_text(#{<<"input">> => <<"plain">>}, #{format => responses})),
    ?assertEqual(<<>>, lg_mw:last_user_text(#{}, #{format => openai})).

add_system_test() ->
    #{<<"messages">> := [S1, S2 | _]} = lg_mw:add_system(oa(), openai, <<"more">>, append),
    ?assertEqual({<<"sys">>, <<"more">>}, {maps:get(<<"content">>, S1), maps:get(<<"content">>, S2)}),
    #{<<"messages">> := [P | _]} = lg_mw:add_system(oa(), openai, <<"first!">>, prepend),
    ?assertEqual(<<"first!">>, maps:get(<<"content">>, P)),
    ?assertMatch(#{<<"system">> := [#{<<"text">> := <<"sys">>}, #{<<"text">> := <<"more">>}]}, lg_mw:add_system(an(), anthropic, <<"more">>, append)),
    ?assertMatch(#{<<"instructions">> := <<"more\n\nsys">>}, lg_mw:add_system(rs(), responses, <<"more">>, prepend)).

event_text_test() ->
    Oa = #{event => undefined, data => #{<<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{<<"content">> => <<"abc">>}}]}},
    An = #{event => <<"content_block_delta">>, data => #{<<"type">> => <<"content_block_delta">>, <<"index">> => 0,
                                                       <<"delta">> => #{<<"type">> => <<"text_delta">>, <<"text">> => <<"abc">>}}},
    Rs = #{event => <<"response.output_text.delta">>, data => #{<<"type">> => <<"response.output_text.delta">>, <<"delta">> => <<"abc">>}},
    [begin
         ?assertEqual(<<"abc">>, lg_mw:event_text(E, F)),
         ?assertEqual(<<"xyz">>, lg_mw:event_text(lg_mw:set_event_text(E, F, <<"xyz">>), F))
     end || {E, F} <- [{Oa, openai}, {An, anthropic}, {Rs, responses}]],
    %% 不是正文增量
    Think = #{event => <<"content_block_delta">>, data => #{<<"type">> => <<"content_block_delta">>,
                                                          <<"delta">> => #{<<"type">> => <<"thinking_delta">>, <<"thinking">> => <<"t">>}}},
    ?assertEqual(undefined, lg_mw:event_text(Think, anthropic)),
    ?assertEqual(Think, lg_mw:set_event_text(Think, anthropic, <<"x">>)).

response_text_test() ->
    Oa = #{<<"choices">> => [#{<<"message">> => #{<<"role">> => <<"assistant">>, <<"content">> => <<"one">>}}]},
    An = #{<<"content">> => [#{<<"type">> => <<"thinking">>, <<"thinking">> => <<"t">>}, #{<<"type">> => <<"text">>, <<"text">> => <<"one">>}]},
    Rs = #{<<"output">> => [#{<<"type">> => <<"message">>, <<"content">> => [#{<<"type">> => <<"output_text">>, <<"text">> => <<"one">>}]}],
           <<"output_text">> => <<"one">>},
    Up = fun(T) -> string:uppercase(T) end,
    [begin
         ?assertEqual(<<"one">>, lg_mw:response_text(B, F)),
         ?assertEqual(<<"ONE">>, lg_mw:response_text(lg_mw:set_response_text(B, F, Up), F)),
         ?assertEqual(<<"new">>, lg_mw:response_text(lg_mw:set_response_text(B, F, <<"new">>), F))
     end || {B, F} <- [{Oa, openai}, {An, anthropic}, {Rs, responses}]],
    ?assertMatch(#{<<"output_text">> := <<"ONE">>}, lg_mw:set_response_text(Rs, responses, Up)).

word_guard_test() ->
    Reject = #{<<"words">> => [<<"bad word">>]},
    ?assertEqual(ok, lg_mw_word_guard:validate(Reject)),
    ?assertMatch({error, _}, lg_mw_word_guard:validate(#{<<"words">> => []})),
    ?assertMatch({error, _}, lg_mw_word_guard:validate(#{<<"words">> => [<<"x">>], <<"mode">> => <<"nope">>})),
    ?assertEqual([on_request], lg_mw_word_guard:hooks(Reject)),
    %% 大小写不敏感，只看最后一条用户消息
    ?assertMatch({reject, 400, _}, lg_mw_word_guard:on_request(oa(), #{format => openai}, Reject)),
    ?assertEqual(continue, lg_mw_word_guard:on_request(an(), #{format => anthropic}, Reject)),
    Mask = #{<<"words">> => [<<"secret">>, <<"a.b">>], <<"mode">> => <<"mask">>},
    ?assertEqual([on_event, on_response], lg_mw_word_guard:hooks(Mask)),
    Ev = #{event => undefined, data => #{<<"choices">> => [#{<<"delta">> => #{<<"content">> => <<"my SECRET and a.b, not axb"/utf8>>}}]}},
    {ok, Ev1} = lg_mw_word_guard:on_event(Ev, #{format => openai}, Mask),
    ?assertEqual(<<"my *** and ***, not axb">>, lg_mw:event_text(Ev1, openai)),
    ?assertEqual(continue, lg_mw_word_guard:on_event(lg_mw:set_event_text(Ev, openai, <<"clean">>), #{format => openai}, Mask)),
    Resp = #{<<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"the secret is 中文secret"/utf8>>}]},
    {ok, R1} = lg_mw_word_guard:on_response(Resp, #{format => anthropic}, Mask),
    ?assertEqual(<<"the *** is 中文***"/utf8>>, lg_mw:response_text(R1, anthropic)).

param_override_test() ->
    O = #{<<"set">> => #{<<"max_tokens">> => 100}, <<"unset">> => [<<"temperature">>]},
    ?assertEqual(ok, lg_mw_param_override:validate(O)),
    ?assertMatch({error, _}, lg_mw_param_override:validate(#{})),
    ?assertMatch({error, <<"cannot change model">>}, lg_mw_param_override:validate(#{<<"set">> => #{<<"model">> => <<"x">>}})),
    ?assertMatch({error, _}, lg_mw_param_override:validate(O#{<<"formats">> => [<<"gemini">>]})),
    {ok, B} = lg_mw_param_override:on_request((oa())#{<<"temperature">> => 0.5, <<"max_tokens">> => 9000}, #{format => openai}, O),
    ?assertEqual(100, maps:get(<<"max_tokens">>, B)),
    ?assertNot(maps:is_key(<<"temperature">>, B)),
    %% 只对指定格式生效
    ?assertEqual(continue, lg_mw_param_override:on_request(an(), #{format => anthropic}, O#{<<"formats">> => [<<"openai">>]})).
