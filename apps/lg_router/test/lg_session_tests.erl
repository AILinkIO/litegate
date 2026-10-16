-module(lg_session_tests).

-include_lib("eunit/include/eunit.hrl").

id_test() ->
    Msgs = #{<<"model">> => <<"m">>, <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]},
    %% 请求头优先，按顺序
    ?assertEqual({<<"a">>, explicit},
                 lg_session:id(#{<<"x-litegate-session">> => <<"a">>, <<"x-claude-code-session-id">> => <<"b">>}, Msgs, <<"k">>)),
    ?assertEqual({<<"cc">>, explicit}, lg_session:id(#{<<"x-claude-code-session-id">> => <<"cc">>}, Msgs, <<"k">>)),
    ?assertEqual({<<"cx">>, explicit}, lg_session:id(#{<<"session-id">> => <<"cx">>}, Msgs, <<"k">>)),
    %% 请求体：prompt_cache_key；Claude Code metadata.user_id（JSON 字符串与旧版后缀）
    ?assertEqual({<<"pk">>, explicit}, lg_session:id(#{}, Msgs#{<<"prompt_cache_key">> => <<"pk">>}, <<"k">>)),
    UserId = <<"{\"device_id\":\"d\",\"account_uuid\":\"\",\"session_id\":\"3b31318a\"}">>,
    ?assertEqual({<<"3b31318a">>, explicit},
                 lg_session:id(#{}, Msgs#{<<"metadata">> => #{<<"user_id">> => UserId}}, <<"k">>)),
    ?assertEqual({<<"s1">>, explicit},
                 lg_session:id(#{}, Msgs#{<<"metadata">> => #{<<"user_id">> => <<"user_x_account__session_s1">>}}, <<"k">>)),
    %% 推导：同一会话的后续请求（追加了消息）得到同一个 id；Key、首条消息不同则不同
    {D1, derived} = lg_session:id(#{}, Msgs, <<"k">>),
    More = Msgs#{<<"messages">> => maps:get(<<"messages">>, Msgs) ++
                     [#{<<"role">> => <<"assistant">>, <<"content">> => <<"yo">>},
                      #{<<"role">> => <<"user">>, <<"content">> => <<"next">>}]},
    ?assertEqual({D1, derived}, lg_session:id(#{}, More, <<"k">>)),
    ?assertNotEqual({D1, derived}, lg_session:id(#{}, Msgs, <<"k2">>)),
    ?assertEqual(32, byte_size(D1)),
    %% Responses 的 instructions + input
    ?assertMatch({_, derived}, lg_session:id(#{}, #{<<"model">> => <<"m">>, <<"instructions">> => <<"sys">>,
                                                 <<"input">> => <<"hi">>}, <<"k">>)),
    ?assertEqual(undefined, lg_session:id(#{}, #{<<"model">> => <<"m">>}, <<"k">>)).

new_turn_test() ->
    U = #{<<"role">> => <<"user">>, <<"content">> => <<"hi">>},
    ?assert(lg_session:new_turn(openai, #{<<"messages">> => [U]})),
    ?assertNot(lg_session:new_turn(openai, #{<<"messages">> => [U, #{<<"role">> => <<"tool">>, <<"content">> => <<"r">>}]})),
    ?assertNot(lg_session:new_turn(anthropic, #{<<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> =>
                                                                      [#{<<"type">> => <<"tool_result">>, <<"tool_use_id">> => <<"t">>}]}]})),
    ?assert(lg_session:new_turn(anthropic, #{<<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> =>
                                                                   [#{<<"type">> => <<"image">>}, #{<<"type">> => <<"text">>, <<"text">> => <<"x">>}]}]})),
    %% 末尾的系统消息不影响判断（Claude Code 新版）
    Sys = #{<<"role">> => <<"system">>, <<"content">> => <<"env">>},
    ?assert(lg_session:new_turn(anthropic, #{<<"messages">> => [U, Sys]})),
    ?assertNot(lg_session:new_turn(anthropic, #{<<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> =>
                                                                      [#{<<"type">> => <<"tool_result">>}]}, Sys]})),
    ?assert(lg_session:new_turn(responses, #{<<"input">> => <<"hi">>})),
    ?assertNot(lg_session:new_turn(responses, #{<<"input">> => [#{<<"type">> => <<"function_call_output">>}]})),
    ?assert(lg_session:new_turn(responses, #{<<"input">> => [#{<<"type">> => <<"message">>, <<"role">> => <<"user">>}]})).

last_user_text_test() ->
    B = #{<<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"first">>},
                             #{<<"role">> => <<"user">>, <<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"写测试"/utf8>>}]}]},
    ?assertEqual(<<"写测试"/utf8>>, lg_session:last_user_text(B, 100)),
    %% 截断不切断 UTF-8 字符
    ?assertEqual(<<"写"/utf8>>, lg_session:last_user_text(B, 4)).
