-module(lg_users_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("lg_core/include/lg_core.hrl").

users_test_() ->
    {foreach,
     fun() ->
             Dir = lg_core_test_util:start(),
             {ok, _} = application:ensure_all_started(lg_router),
             ok = lg_login_guard:reset(),
             Dir
     end,
     fun(Dir) -> lg_core_test_util:stop(Dir) end,
     [?_test(create_and_login()),
      ?_test(validation()),
      ?_test(sessions_revoked()),
      ?_test(login_rate_limit()),
      ?_test(ensure_admin())]}.

create_and_login() ->
    {ok, U} = lg_users:create(#{<<"username">> => <<"alice">>, <<"password">> => <<"password1">>}),
    ?assertEqual(user, U#lg_user.role),
    ?assertEqual({error, already_exists},
                 lg_users:create(#{<<"username">> => <<"alice">>, <<"password">> => <<"password2">>})),
    {ok, Token, U} = lg_users:login(<<"alice">>, <<"password1">>),
    ?assertMatch(<<"lgs-", _/binary>>, Token),
    ?assertEqual({ok, U}, lg_users:session(Token)),
    ?assertEqual({error, invalid_credentials}, lg_users:login(<<"alice">>, <<"wrong-pass">>)),
    ?assertEqual({error, invalid_credentials}, lg_users:login(<<"nobody">>, <<"password1">>)),
    ok = lg_users:logout(Token),
    ?assertEqual({error, invalid_session}, lg_users:session(Token)),
    ?assertNot(maps:is_key(<<"password_hash">>, lg_users:to_map(U))).

validation() ->
    ?assertEqual({error, {invalid, <<"password">>}},
                 lg_users:create(#{<<"username">> => <<"bob">>, <<"password">> => <<"short">>})),
    ?assertEqual({error, {invalid, <<"username">>}},
                 lg_users:create(#{<<"username">> => <<"b o b">>, <<"password">> => <<"password1">>})),
    ?assertEqual({error, {invalid, <<"role">>}},
                 lg_users:create(#{<<"username">> => <<"bob">>, <<"password">> => <<"password1">>,
                                   <<"role">> => <<"root">>})).

sessions_revoked() ->
    {ok, U} = lg_users:create(#{<<"username">> => <<"carol">>, <<"password">> => <<"password1">>}),
    {ok, T1, _} = lg_users:login(<<"carol">>, <<"password1">>),
    {ok, _} = lg_users:update(U#lg_user.id, #{<<"role">> => <<"admin">>}),
    ?assertMatch({ok, #lg_user{role = admin}}, lg_users:session(T1)),
    %% 改密码后旧会话失效
    {ok, _} = lg_users:update(U#lg_user.id, #{<<"password">> => <<"password2">>}),
    ?assertEqual({error, invalid_session}, lg_users:session(T1)),
    {ok, T2, _} = lg_users:login(<<"carol">>, <<"password2">>),
    {ok, _} = lg_users:update(U#lg_user.id, #{<<"enabled">> => false}),
    ?assertEqual({error, invalid_session}, lg_users:session(T2)),
    ?assertEqual({error, invalid_credentials}, lg_users:login(<<"carol">>, <<"password2">>)),
    %% 过期会话
    ok = lg_config:set(session_ttl_ms, -1),
    {ok, _} = lg_users:update(U#lg_user.id, #{<<"enabled">> => true}),
    {ok, T3, _} = lg_users:login(<<"carol">>, <<"password2">>),
    ?assertEqual({error, invalid_session}, lg_users:session(T3)),
    ok = lg_config:unset(session_ttl_ms).

login_rate_limit() ->
    Peer = {127, 0, 0, 1},
    {ok, _} = lg_users:create(#{<<"username">> => <<"dave">>, <<"password">> => <<"password1">>}),
    ?assertEqual({error, invalid_credentials}, lg_users:login(<<"dave">>, <<"wrong-pass">>, Peer)),
    ?assertEqual({error, invalid_credentials}, lg_users:login(<<"Dave">>, <<"wrong-pass">>, Peer)),
    %% 第 3 次失败建立冷却，下一次先拒绝，不再查用户或做 PBKDF2
    ?assertEqual({error, invalid_credentials}, lg_users:login(<<"DAVE">>, <<"wrong-pass">>, Peer)),
    ?assertMatch({error, {rate_limited, Retry}} when Retry >= 1,
                 lg_users:login(<<"dave">>, <<"password1">>, Peer)),
    %% 用户名大小写不产生新维度；换 IP 不受影响
    ?assertMatch({error, {rate_limited, _}},
                 lg_users:login(<<"DAVE">>, <<"password1">>, Peer)),
    [{_, _Count, _Since, Until}] = ets:lookup(lg_login_guard, {<<"dave">>, <<"127.0.0.1">>}),
    timer:sleep(max(1, Until - lg_time:now_ms()) + 2),
    ?assertMatch({ok, _, _}, lg_users:login(<<"dave">>, <<"password1">>, Peer)),
    %% 成功清零同一维度：还能连续失败两次才进入冷却
    ?assertEqual({error, invalid_credentials}, lg_users:login(<<"dave">>, <<"wrong-pass">>, Peer)),
    ?assertEqual({error, invalid_credentials}, lg_users:login(<<"dave">>, <<"wrong-pass">>, Peer)),
    ?assertMatch({ok, _, _}, lg_users:login(<<"dave">>, <<"password1">>, Peer)),
    %% 窗口过期后重新计数
    Now = lg_time:now_ms(),
    Key = {<<"dave">>, <<"127.0.0.1">>},
    ets:insert(lg_login_guard, {Key, 2, Now - 61000, 0}),
    ?assertEqual(ok, lg_login_guard:check(<<"dave">>, Peer)),
    ?assertEqual({error, invalid_credentials}, lg_users:login(<<"dave">>, <<"wrong-pass">>, Peer)),
    ?assertEqual({error, invalid_credentials}, lg_users:login(<<"dave">>, <<"wrong-pass">>, Peer)).

ensure_admin() ->
    os:putenv("LITEGATE_ADMIN_PASSWORD", "admin-secret"),
    ok = lg_users:ensure_admin(),
    os:unsetenv("LITEGATE_ADMIN_PASSWORD"),
    ?assertMatch({ok, _, #lg_user{role = admin}}, lg_users:login(<<"admin">>, <<"admin-secret">>)),
    %% 已有用户时不再创建
    ok = lg_users:ensure_admin(),
    ?assertEqual(1, length(lg_users:list())).
