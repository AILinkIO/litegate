-module(lg_structured_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("lg_core/include/lg_core.hrl").

-define(SCHEMA, #{<<"type">> => <<"object">>, <<"properties">> => #{<<"city">> => #{<<"type">> => <<"string">>}},
                  <<"required">> => [<<"city">>]}).

cred(Base, Opts) -> #lg_credential{id = <<"c">>, name = <<"c">>, protocol = anthropic, base_url = Base, options = Opts}.

read_test() ->
    S = ?SCHEMA,
    RF = #{<<"response_format">> => #{<<"type">> => <<"json_schema">>,
                                      <<"json_schema">> => #{<<"name">> => <<"weather info">>, <<"schema">> => ?SCHEMA, <<"strict">> => true}}},
    ?assertEqual(#{kind => json_schema, name => <<"weather_info">>, schema => ?SCHEMA, strict => true}, lg_structured:read(openai, RF)),
    ?assertMatch(#{kind := json_object}, lg_structured:read(openai, #{<<"response_format">> => #{<<"type">> => <<"json_object">>}})),
    ?assertEqual(none, lg_structured:read(openai, #{<<"response_format">> => #{<<"type">> => <<"text">>}})),
    ?assertMatch(#{kind := json_schema, schema := S},
                 lg_structured:read(anthropic, #{<<"output_config">> => #{<<"format">> => #{<<"type">> => <<"json_schema">>,
                                                                                           <<"schema">> => ?SCHEMA}}})).

write_test() ->
    S = ?SCHEMA,
    RF = #{<<"response_format">> => #{<<"type">> => <<"json_schema">>, <<"json_schema">> => #{<<"name">> => <<"w">>, <<"schema">> => ?SCHEMA}}},
    Compat = cred(<<"https://api.minimax.cn/anthropic">>, #{}),
    Official = cred(<<"https://api.anthropic.com">>, #{}),
    %% 兼容上游：强制工具
    {B1, <<"w">>} = lg_structured:apply(anthropic, openai, #{<<"messages">> => [], <<"thinking">> => #{}}, {Compat, RF}),
    ?assertMatch(#{<<"tools">> := [#{<<"name">> := <<"w">>, <<"input_schema">> := S}],
                   <<"tool_choice">> := #{<<"type">> := <<"tool">>, <<"name">> := <<"w">>}}, B1),
    ?assertEqual(#{<<"type">> => <<"disabled">>}, maps:get(<<"thinking">>, B1)),
    %% 官方接口：output_config
    {B2, undefined} = lg_structured:apply(anthropic, openai, #{<<"messages">> => []}, {Official, RF}),
    ?assertMatch(#{<<"output_config">> := #{<<"format">> := #{<<"type">> := <<"json_schema">>, <<"schema">> := S}}}, B2),
    %% 凭证选项强制 native；请求里已有其他工具时也用 native
    {_, undefined} = lg_structured:apply(anthropic, openai, #{}, {cred(<<"https://x">>, #{structured_output => <<"native">>}), RF}),
    {B3, undefined} = lg_structured:apply(anthropic, openai, #{<<"tools">> => [#{<<"name">> => <<"t">>}]}, {Compat, RF}),
    ?assertMatch(#{<<"output_config">> := _}, B3),
    %% OpenAI 上游：Anthropic 客户端的 output_config 转成 response_format；同协议不动
    OC = #{<<"output_config">> => #{<<"format">> => #{<<"type">> => <<"json_schema">>, <<"schema">> => ?SCHEMA}}},
    {B4, json} = lg_structured:apply(openai, anthropic, #{}, {Compat, OC}),
    ?assertMatch(#{<<"response_format">> := #{<<"type">> := <<"json_schema">>, <<"json_schema">> := #{<<"schema">> := S}}}, B4),
    ?assertEqual({#{}, json}, lg_structured:apply(openai, openai, #{}, {Compat, RF})),
    %% 顶层不是 object 的 schema 包一层 result
    Arr = #{<<"response_format">> => #{<<"type">> => <<"json_schema">>,
                                       <<"json_schema">> => #{<<"name">> => <<"l">>, <<"schema">> => #{<<"type">> => <<"array">>}}}},
    {B5, <<"l">>} = lg_structured:apply(anthropic, openai, #{}, {Compat, Arr}),
    ?assertMatch(#{<<"tools">> := [#{<<"input_schema">> := #{<<"properties">> := #{<<"result">> := _}}}]}, B5).

response_test() ->
    J = #{<<"stop_reason">> => <<"tool_use">>,
          <<"content">> => [#{<<"type">> => <<"thinking">>, <<"thinking">> => <<"t">>},
                            #{<<"type">> => <<"tool_use">>, <<"name">> => <<"w">>, <<"id">> => <<"x">>,
                              <<"input">> => #{<<"city">> => <<"上海"/utf8>>}}]},
    #{<<"stop_reason">> := <<"end_turn">>, <<"content">> := [_, #{<<"type">> := <<"text">>, <<"text">> := T}]} =
        lg_structured:response(J, <<"w">>),
    ?assertEqual(#{<<"city">> => <<"上海"/utf8>>}, json:decode(T)),
    %% 包过 result 的还原
    J2 = J#{<<"content">> => [#{<<"type">> => <<"tool_use">>, <<"name">> => <<"w">>, <<"input">> => #{<<"result">> => [1, 2]}}]},
    #{<<"content">> := [#{<<"text">> := T2}]} = lg_structured:response(J2, <<"w">>),
    ?assertEqual([1, 2], json:decode(T2)),
    ?assertEqual(J, lg_structured:response(J, undefined)).

%% OpenAI 协议上游：回复整段是 ```json 代码块时去掉
unfence_test() ->
    R = fun(T) -> #{<<"choices">> := [#{<<"message">> := #{<<"content">> := C}}]} =
                      lg_structured:response(#{<<"choices">> => [#{<<"message">> => #{<<"content">> => T}}]}, json),
                  C end,
    ?assertEqual(<<"{\"a\":1}">>, R(<<"```json\n{\"a\":1}\n```">>)),
    ?assertEqual(<<"{\"a\":1}">>, R(<<"```\n{\"a\":1}```">>)),
    ?assertEqual(<<"{\"a\":1}">>, R(<<"{\"a\":1}">>)),
    %% 代码块外还有文字、或内容不是 JSON：不动
    ?assertEqual(<<"see:\n```json\n{\"a\":1}\n```">>, R(<<"see:\n```json\n{\"a\":1}\n```">>)),
    ?assertEqual(<<"```json\n{a:1}\n```">>, R(<<"```json\n{a:1}\n```">>)).

%% 强制工具的参数被包成 {name, parameters}（MiniMax 实测）
tool_args_wrapped_test() ->
    J = #{<<"content">> => [#{<<"type">> => <<"tool_use">>, <<"name">> => <<"w">>,
                              <<"input">> => #{<<"name">> => <<"w">>, <<"parameters">> => #{<<"city">> => <<"x">>}}}],
          <<"stop_reason">> => <<"tool_use">>},
    #{<<"content">> := [#{<<"text">> := T}]} = lg_structured:response(J, <<"w">>),
    ?assertEqual(#{<<"city">> => <<"x">>}, json:decode(T)).
