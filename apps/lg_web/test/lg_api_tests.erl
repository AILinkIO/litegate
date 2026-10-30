%% @doc 管理 API 端到端测试。
-module(lg_api_tests).

-include_lib("eunit/include/eunit.hrl").

api_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(Ctx) ->
             [?_test(login_flow(Ctx)),
              ?_test(catalog(Ctx)),
              ?_test(credentials_routes_keys(Ctx)),
              ?_test(user_scoping(Ctx)),
              ?_test(users_self_protection(Ctx)),
              ?_test(settings(Ctx)),
              ?_test(logs_and_usage(Ctx)),
              ?_test(limits_and_budgets(Ctx)),
              ?_test(store(Ctx)),
              ?_test(health(Ctx)),
              ?_test(config_io(Ctx)),
              ?_test(alerts(Ctx)),
              ?_test(openapi(Ctx)),
              ?_test(console_static(Ctx)),
              ?_test(single_reply_keepalive(Ctx))]
     end}.

setup() ->
    Dir = lg_core_test_util:start(),
    application:set_env(lg_core, http_port, 0),
    %% 这组测试覆盖多用户模式；单机（免登录）模式见 no_auth_test_
    application:set_env(lg_core, console_auth, true),
    os:putenv("LITEGATE_ADMIN_PASSWORD", "admin-secret"),
    {ok, _} = application:ensure_all_started(lg_web),
    os:unsetenv("LITEGATE_ADMIN_PASSWORD"),
    Ctx = #{dir => Dir, port => ranch:get_port(lg_http_listener)},
    Ctx#{admin => login(Ctx, <<"admin">>, <<"admin-secret">>)}.

cleanup(#{dir := Dir}) ->
    [application:stop(A) || A <- [lg_web, lg_router, lg_provider, lg_catalog]],
    application:unset_env(lg_core, http_port),
    application:unset_env(lg_core, console_auth),
    lg_core_test_util:stop(Dir).

req(#{port := Port}, Method, Path, Headers, Body) ->
    {ok, Conn} = gun:open("127.0.0.1", Port, #{retry => 0}),
    {ok, _} = gun:await_up(Conn, 5000),
    Ref = gun:request(Conn, Method, Path, Headers, Body),
    Res = case gun:await(Conn, Ref, 10000) of
              {response, fin, S, H} -> {S, H, <<>>};
              {response, nofin, S, H} -> {ok, B} = gun:await_body(Conn, Ref, 10000), {S, H, B}
          end,
    gun:close(Conn),
    Res.

%% 管理端资源（lg_api_admin）与 lg_api 自身资源各回复一次：同一条 keep-alive 连接上连续请求都能拿到响应、
%% 连接进程不崩溃（此前 lg_api_admin 命中后仍落到 lg_api 的 404 兜底，重复回复让 cowboy 连接进程崩溃）
single_reply_keepalive(#{port := Port, admin := Token}) ->
    {ok, Conn} = gun:open("127.0.0.1", Port, #{retry => 0}),
    {ok, _} = gun:await_up(Conn, 5000),
    MRef = monitor(process, Conn),
    H = [{<<"authorization">>, <<"Bearer ", Token/binary>>}],
    Get = fun(Path) ->
                  Ref = gun:get(Conn, Path, H),
                  {response, _, S, _} = gun:await(Conn, Ref, 10000),
                  _ = gun:await_body(Conn, Ref, 10000),
                  S
          end,
    %% 管理端资源、本模块资源、未知路径，各两轮
    [?assertEqual([200, 200, 404], [Get(<<"/api/settings">>), Get(<<"/api/keys">>), Get(<<"/api/nope">>)])
     || _ <- [1, 2]],
    receive {gun_down, Conn, _, _, _} -> ?assert(false) after 100 -> ok end,
    demonitor(MRef, [flush]),
    gun:close(Conn).

%% 带 Bearer 会话 token 的 JSON 请求，返回 {Status, DecodedBody}
api(Ctx, Token, Method, Path) -> api(Ctx, Token, Method, Path, undefined).
api(Ctx, Token, Method, Path, Body) ->
    Auth = case Token of none -> []; _ -> [{<<"authorization">>, <<"Bearer ", Token/binary>>}] end,
    {Payload, CT} = case Body of
                        undefined -> {<<>>, []};
                        _ -> {json:encode(Body), [{<<"content-type">>, <<"application/json">>}]}
                    end,
    {S, _, B} = req(Ctx, Method, Path, Auth ++ CT, Payload),
    {S, case B of <<>> -> null; _ -> json:decode(B) end}.

login(Ctx, User, Pass) ->
    {200, #{<<"token">> := T}} = api(Ctx, none, <<"POST">>, <<"/api/auth/login">>,
                                     #{<<"username">> => User, <<"password">> => Pass}),
    T.

login_flow(Ctx) ->
    {S, H, B} = req(Ctx, <<"POST">>, <<"/api/auth/login">>, [{<<"content-type">>, <<"application/json">>}],
                    json:encode(#{<<"username">> => <<"admin">>, <<"password">> => <<"admin-secret">>})),
    ?assertEqual(200, S),
    ?assertMatch(#{<<"user">> := #{<<"username">> := <<"admin">>, <<"role">> := <<"admin">>}}, json:decode(B)),
    Cookie = proplists:get_value(<<"set-cookie">>, H),
    ?assertMatch({match, _}, re:run(Cookie, "lg_session=lgs-.*HttpOnly.*SameSite=Strict", [caseless])),
    %% cookie 鉴权
    [CookiePair | _] = binary:split(Cookie, <<";">>),
    {200, _, Me} = req(Ctx, <<"GET">>, <<"/api/auth/me">>, [{<<"cookie">>, CookiePair}], <<>>),
    ?assertMatch(#{<<"username">> := <<"admin">>}, json:decode(Me)),
    ?assertMatch({401, _}, api(Ctx, none, <<"GET">>, <<"/api/auth/me">>)),
    ?assertMatch({401, _}, api(Ctx, <<"lgs-bogus">>, <<"GET">>, <<"/api/auth/me">>)),
    ?assertMatch({401, #{<<"error">> := #{<<"code">> := <<"invalid_credentials">>}}},
                 api(Ctx, none, <<"POST">>, <<"/api/auth/login">>,
                     #{<<"username">> => <<"admin">>, <<"password">> => <<"nope">>})),
    %% 连续失败后返回 429 和 Retry-After；测试清零，避免影响后续登录
    Wrong = #{<<"username">> => <<"admin">>, <<"password">> => <<"nope">>},
    {401, _, _} = req(Ctx, <<"POST">>, <<"/api/auth/login">>,
                      [{<<"content-type">>, <<"application/json">>}], json:encode(Wrong)),
    {401, _, _} = req(Ctx, <<"POST">>, <<"/api/auth/login">>,
                      [{<<"content-type">>, <<"application/json">>}], json:encode(Wrong)),
    {429, H429, B429} = req(Ctx, <<"POST">>, <<"/api/auth/login">>,
                            [{<<"content-type">>, <<"application/json">>}], json:encode(Wrong)),
    ?assert(is_integer(binary_to_integer(proplists:get_value(<<"retry-after">>, H429, <<"0">>)))),
    ?assertMatch(#{<<"error">> := #{<<"code">> := <<"rate_limited">>}}, json:decode(B429)),
    ok = lg_login_guard:reset(),
    %% logout 使 token 失效
    T = login(Ctx, <<"admin">>, <<"admin-secret">>),
    {200, _} = api(Ctx, T, <<"POST">>, <<"/api/auth/logout">>),
    ?assertMatch({401, _}, api(Ctx, T, <<"GET">>, <<"/api/auth/me">>)).

catalog(#{admin := A} = Ctx) ->
    Fixture = #{<<"openai">> => #{<<"name">> => <<"OpenAI">>, <<"npm">> => <<"@ai-sdk/openai">>,
                                  <<"models">> => #{<<"gpt-4o">> => #{<<"name">> => <<"GPT-4o">>},
                                                    <<"gpt-4o-mini">> => #{<<"name">> => <<"GPT-4o mini">>},
                                                    <<"o3">> => #{<<"name">> => <<"o3">>}}},
                <<"openrouter">> => #{<<"name">> => <<"OpenRouter">>, <<"npm">> => <<"@openrouter/ai-sdk-provider">>,
                                      <<"models">> => #{<<"anthropic/claude-x">> => #{<<"name">> => <<"Claude X">>}}}},
    %% 不是 models.dev 格式（如配置导出文件）：拒绝，不动目录
    ?assertMatch({400, #{<<"error">> := #{<<"message">> := <<"Not a models.dev api.json", _/binary>>}}},
                 api(Ctx, A, <<"POST">>, <<"/api/catalog/import">>, #{<<"format">> => <<"litegate-config">>, <<"routes">> => []})),
    ?assertMatch({400, _}, api(Ctx, A, <<"POST">>, <<"/api/catalog/import">>, #{})),
    {200, #{<<"providers">> := 2, <<"models">> := 4}} = api(Ctx, A, <<"POST">>, <<"/api/catalog/import">>, Fixture),
    {200, Providers} = api(Ctx, A, <<"GET">>, <<"/api/catalog/providers">>),
    ?assertEqual([<<"openai">>, <<"openrouter">>], [maps:get(<<"id">>, P) || P <- Providers]),
    {200, #{<<"total">> := 4}} = api(Ctx, A, <<"GET">>, <<"/api/catalog/models">>),
    {200, #{<<"total">> := 2, <<"items">> := [_]}} =
        api(Ctx, A, <<"GET">>, <<"/api/catalog/models?provider=openai&q=GPT-4O&limit=1">>),
    %% 模型 id 含 /：路径段用 %2F 编码
    Path = <<"/api/catalog/models/openrouter/anthropic%2Fclaude-x">>,
    {200, #{<<"name">> := <<"Claude X">>, <<"overlay">> := null}} = api(Ctx, A, <<"GET">>, Path),
    {200, #{<<"name">> := <<"Mine">>, <<"source">> := <<"overridden">>}} =
        api(Ctx, A, <<"PUT">>, Path, #{<<"name">> => <<"Mine">>}),
    {200, #{<<"total">> := 1}} = api(Ctx, A, <<"GET">>, <<"/api/catalog/models?source=overridden">>),
    {200, _} = api(Ctx, A, <<"DELETE">>, Path),
    {200, #{<<"source">> := <<"synced">>}} = api(Ctx, A, <<"GET">>, Path),
    ?assertMatch({404, _}, api(Ctx, A, <<"GET">>, <<"/api/catalog/models/x/y">>)),
    {200, #{<<"status">> := <<"ok">>, <<"source">> := <<"import">>}} =
        api(Ctx, A, <<"GET">>, <<"/api/catalog/sync">>).

credentials_routes_keys(#{admin := A} = Ctx) ->
    {200, #{<<"id">> := C, <<"api_key_hint">> := <<"...cret">>}} =
        api(Ctx, A, <<"POST">>, <<"/api/credentials">>,
            #{<<"name">> => <<"oa">>, <<"protocol">> => <<"openai">>,
              <<"base_url">> => <<"https://api.openai.com/v1">>, <<"api_key">> => <<"sk-super-secret">>}),
    {200, #{<<"protocol">> := <<"openai">>, <<"base_url">> := <<"https://openrouter.ai/api/v1">>}} =
        api(Ctx, A, <<"POST">>, <<"/api/credentials/from-provider">>,
            #{<<"provider">> => <<"openrouter">>, <<"api_key">> => <<"k">>}),
    ?assertMatch({400, #{<<"error">> := #{<<"message">> := <<"Invalid field: base_url">>}}},
                 api(Ctx, A, <<"POST">>, <<"/api/credentials">>,
                     #{<<"name">> => <<"x">>, <<"protocol">> => <<"openai">>, <<"base_url">> => <<"nope">>})),
    {200, [_, _]} = api(Ctx, A, <<"GET">>, <<"/api/credentials">>),
    Route = #{<<"name">> => <<"team/gpt">>,
              <<"targets">> => [#{<<"credential">> => C, <<"upstream_model">> => <<"gpt-4o">>,
                                  <<"model_ref">> => [<<"openai">>, <<"gpt-4o">>]}]},
    {200, #{<<"name">> := <<"team/gpt">>}} = api(Ctx, A, <<"POST">>, <<"/api/routes">>, Route),
    %% 未知顶层字段（rules/classifier 应在 options 下）返回 400 并列出字段，不再静默丢弃
    ?assertMatch({400, #{<<"error">> := #{<<"message">> := <<"未知顶层字段: rules"/utf8, _/binary>>}}},
                 api(Ctx, A, <<"POST">>, <<"/api/routes">>, Route#{<<"name">> => <<"team/gpt2">>,
                                                                 <<"rules">> => []})),
    ?assertMatch({400, #{<<"error">> := #{<<"message">> := <<"未知顶层字段: classifier"/utf8, _/binary>>}}},
                 api(Ctx, A, <<"PUT">>, <<"/api/routes/team%2Fgpt">>, #{<<"enabled">> => true,
                                                                       <<"classifier">> => <<"x">>})),
    {200, #{<<"enabled">> := false}} =
        api(Ctx, A, <<"PUT">>, <<"/api/routes/team%2Fgpt">>, #{<<"enabled">> => false}),
    ?assertMatch({400, #{<<"error">> := #{<<"message">> := <<"In use by: team/gpt">>}}},
                 api(Ctx, A, <<"DELETE">>, <<"/api/credentials/", C/binary>>)),
    {200, #{<<"key">> := <<"lgk-", _/binary>> = Plain, <<"id">> := KId}} =
        api(Ctx, A, <<"POST">>, <<"/api/keys">>, #{<<"name">> => <<"ci">>}),
    {200, Keys} = api(Ctx, A, <<"GET">>, <<"/api/keys">>),
    ?assertNot(lists:any(fun(K) -> maps:is_key(<<"key">>, K) end, Keys)),
    ?assertMatch({ok, _}, lg_api_keys:authenticate(Plain)),
    {200, #{<<"max_tokens">> := 100}} =
        api(Ctx, A, <<"PUT">>, <<"/api/keys/", KId/binary>>, #{<<"max_tokens">> => 100}),
    {200, _} = api(Ctx, A, <<"DELETE">>, <<"/api/routes/team%2Fgpt">>),
    {200, _} = api(Ctx, A, <<"DELETE">>, <<"/api/credentials/", C/binary>>),
    ?assertMatch({404, _}, api(Ctx, A, <<"GET">>, <<"/api/routes/team%2Fgpt">>)),
    ?assertMatch({400, _, _}, req(Ctx, <<"POST">>, <<"/api/routes">>,
                               [{<<"authorization">>, <<"Bearer ", A/binary>>}], <<"{bad">>)).

user_scoping(#{admin := A} = Ctx) ->
    {200, #{<<"id">> := Uid}} = api(Ctx, A, <<"POST">>, <<"/api/users">>,
                                    #{<<"username">> => <<"dev">>, <<"password">> => <<"dev-password">>}),
    U = login(Ctx, <<"dev">>, <<"dev-password">>),
    ?assertMatch({403, _}, api(Ctx, U, <<"GET">>, <<"/api/credentials">>)),
    ?assertMatch({403, _}, api(Ctx, U, <<"GET">>, <<"/api/users">>)),
    %% user 创建的 Key 强制归属自己，且只能看到自己的
    {200, #{<<"id">> := Mine, <<"user_id">> := Uid}} =
        api(Ctx, U, <<"POST">>, <<"/api/keys">>, #{<<"name">> => <<"mine">>, <<"user_id">> => <<"other">>}),
    {200, [#{<<"id">> := Mine}]} = api(Ctx, U, <<"GET">>, <<"/api/keys">>),
    {200, #{<<"id">> := Others}} = api(Ctx, A, <<"POST">>, <<"/api/keys">>, #{<<"name">> => <<"admins">>}),
    ?assertMatch({404, _}, api(Ctx, U, <<"DELETE">>, <<"/api/keys/", Others/binary>>)),
    ?assertMatch({404, _}, api(Ctx, U, <<"PUT">>, <<"/api/keys/", Others/binary>>, #{<<"enabled">> => false})),
    {200, _} = api(Ctx, U, <<"DELETE">>, <<"/api/keys/", Mine/binary>>),
    {200, Overview} = api(Ctx, U, <<"GET">>, <<"/api/overview">>),
    ?assertNot(maps:is_key(<<"counts">>, Overview)),
    %% 修改自己的密码
    {200, _} = api(Ctx, U, <<"PUT">>, <<"/api/auth/password">>, #{<<"password">> => <<"new-password">>}),
    ?assertMatch({401, _}, api(Ctx, U, <<"GET">>, <<"/api/auth/me">>)),
    _ = login(Ctx, <<"dev">>, <<"new-password">>).

users_self_protection(#{admin := A} = Ctx) ->
    {200, #{<<"id">> := Me}} = api(Ctx, A, <<"GET">>, <<"/api/auth/me">>),
    ?assertMatch({400, _}, api(Ctx, A, <<"PUT">>, <<"/api/users/", Me/binary>>, #{<<"role">> => <<"user">>})),
    ?assertMatch({400, _}, api(Ctx, A, <<"PUT">>, <<"/api/users/", Me/binary>>, #{<<"enabled">> => false})),
    ?assertMatch({400, _}, api(Ctx, A, <<"DELETE">>, <<"/api/users/", Me/binary>>)).

settings(#{admin := A} = Ctx) ->
    {200, All} = api(Ctx, A, <<"GET">>, <<"/api/settings">>),
    [DataDir] = [S || #{<<"key">> := <<"data_dir">>} = S <- All],
    ?assertMatch(#{<<"editable">> := false}, DataDir),
    ?assert(is_binary(maps:get(<<"value">>, DataDir))),
    {200, #{<<"value">> := 5, <<"source">> := <<"runtime">>}} =
        api(Ctx, A, <<"PUT">>, <<"/api/settings/route_max_attempts">>, #{<<"value">> => 5}),
    ?assertEqual(5, lg_config:get(route_max_attempts)),
    ?assertMatch({400, _}, api(Ctx, A, <<"PUT">>, <<"/api/settings/route_max_attempts">>,
                               #{<<"value">> => <<"five">>})),
    {200, #{<<"value">> := 3, <<"source">> := <<"default">>}} =
        api(Ctx, A, <<"PUT">>, <<"/api/settings/route_max_attempts">>, #{<<"value">> => null}),
    ?assertMatch({404, _}, api(Ctx, A, <<"PUT">>, <<"/api/settings/http_port">>, #{<<"value">> => 1})),
    ?assertMatch({404, _}, api(Ctx, A, <<"PUT">>, <<"/api/settings/nope">>, #{<<"value">> => 1})).

logs_and_usage(#{admin := A} = Ctx) ->
    {ok, #{<<"id">> := Uid}} = {ok, hd([lg_users:to_map(X) || X <- lg_users:list(),
                                                              element(3, X) =:= <<"dev">>])},
    Mine = lg_store:new_id(),
    Other = lg_store:new_id(),
    Log = fun(Id, User) -> #{id => Id, route => <<"r">>, user_id => User, key_id => <<"k">>,
                             model_ref => {<<"p">>, <<"m">>}, status => 200,
                             usage => #{input => 1, output => 2, cache_read => 0, cache_write => 0},
                             cost => 0.25} end,
    ok = lg_store:record(Log(Mine, Uid), #{request => #{}, response => <<"hello">>}),
    ok = lg_store:flush(),
    ok = lg_store:record(Log(Other, <<"someone">>), undefined),
    {200, #{<<"items">> := Items}} = api(Ctx, A, <<"GET">>, <<"/api/logs?limit=10">>),
    ?assertEqual([Other, Mine], [maps:get(<<"id">>, I) || I <- Items]),
    ?assertMatch([#{<<"model_ref">> := [<<"p">>, <<"m">>]} | _], Items),
    {200, #{<<"messages">> := #{<<"response">> := <<"hello">>}}} =
        api(Ctx, A, <<"GET">>, <<"/api/logs/", Mine/binary>>),
    U = login(Ctx, <<"dev">>, <<"new-password">>),
    {200, #{<<"items">> := [#{<<"id">> := Mine}]}} = api(Ctx, U, <<"GET">>, <<"/api/logs">>),
    %% 全文检索：管理员可见全部，普通用户只命中自己的
    ok = lg_store:record(Log(lg_store:new_id(), <<"someone">>),
                         #{request => #{<<"messages">> => [#{<<"role">> => <<"user">>,
                                                             <<"content">> => <<"hello world">>}]},
                           response => <<"hi">>}),
    {200, #{<<"items">> := [#{<<"id">> := Mine, <<"score">> := _}, _], <<"next_cursor">> := null}} =
        api(Ctx, A, <<"GET">>, <<"/api/logs?q=hello">>),
    {200, #{<<"items">> := [#{<<"id">> := Mine}]}} = api(Ctx, U, <<"GET">>, <<"/api/logs?q=HELLO">>),
    ?assertMatch({404, _}, api(Ctx, U, <<"GET">>, <<"/api/logs/", Other/binary>>)),
    {200, [#{<<"requests">> := 3, <<"cost">> := 0.75}]} = api(Ctx, A, <<"GET">>, <<"/api/usage">>),
    {200, [#{<<"requests">> := 1}]} = api(Ctx, U, <<"GET">>, <<"/api/usage">>),
    {200, [_, _]} = api(Ctx, A, <<"GET">>, <<"/api/usage?group_by=user_id,day">>),
    ?assertMatch({400, _}, api(Ctx, A, <<"GET">>, <<"/api/usage?group_by=nope">>)),
    {200, #{<<"usage_24h">> := #{<<"requests">> := 3}, <<"counts">> := _}} =
        api(Ctx, A, <<"GET">>, <<"/api/overview">>).

alerts(#{admin := A} = Ctx) ->
    {400, #{<<"error">> := #{<<"message">> := <<"Missing field: url">>}}} =
        api(Ctx, A, <<"POST">>, <<"/api/alerts/channels">>, #{<<"name">> => <<"x">>, <<"type">> => <<"wecom">>}),
    {200, #{<<"id">> := Ch, <<"url_hint">> := Hint, <<"has_secret">> := true}} =
        api(Ctx, A, <<"POST">>, <<"/api/alerts/channels">>,
            #{<<"name">> => <<"feishu">>, <<"type">> => <<"feishu">>,
              <<"url">> => <<"http://127.0.0.1:1/open-apis/bot/v2/hook/abcd">>, <<"secret">> => <<"s">>}),
    ?assertEqual(<<"http://127.0.0.1/…abcd"/utf8>>, Hint),
    %% 地址不可达：测试结果 ok = false 并带错误
    {200, #{<<"ok">> := false, <<"error">> := _}} = api(Ctx, A, <<"POST">>, <<"/api/alerts/channels/", Ch/binary, "/test">>, #{}),
    {200, #{<<"id">> := R, <<"threshold">> := 3}} =
        api(Ctx, A, <<"POST">>, <<"/api/alerts/rules">>, #{<<"event">> => <<"upstream_down">>, <<"channels">> => [Ch]}),
    {200, #{<<"threshold">> := 5, <<"enabled">> := false}} =
        api(Ctx, A, <<"PUT">>, <<"/api/alerts/rules/", R/binary>>, #{<<"threshold">> => 5, <<"enabled">> => false}),
    {200, [#{<<"id">> := R}]} = api(Ctx, A, <<"GET">>, <<"/api/alerts/rules">>),
    {200, [#{<<"id">> := Ch}]} = api(Ctx, A, <<"GET">>, <<"/api/alerts/channels">>),
    {200, L} = api(Ctx, A, <<"GET">>, <<"/api/alerts/history?limit=5">>),
    ?assert(is_list(L)),
    {200, _} = api(Ctx, A, <<"DELETE">>, <<"/api/alerts/rules/", R/binary>>),
    {200, _} = api(Ctx, A, <<"DELETE">>, <<"/api/alerts/channels/", Ch/binary>>),
    {404, _} = api(Ctx, A, <<"DELETE">>, <<"/api/alerts/channels/", Ch/binary>>).

%% 接口文档与实现一致：lg_api 的每个 handle/route 子句、路由表中的 /v1 与 Playground 路径都要在文档中，文档也不能多出路径
openapi(Ctx) ->
    {200, _, B} = req(Ctx, <<"GET">>, <<"/api/openapi.json">>, [], <<>>),
    #{<<"openapi">> := <<"3.1.0">>, <<"paths">> := Paths} = json:decode(B),
    Documented = lists:usort([{string:uppercase(M), normalize(P)} || P := Ops <- Paths, M := _ <- Ops]),
    %% 管理端资源 handler 拆到 lg_api_admin，两处源码都要扫描
    Sources = [proplists:get_value(source, lg_api:module_info(compile)),
               proplists:get_value(source, lg_api_admin:module_info(compile))],
    Clauses = lists:append(
                [begin
                     {ok, Code} = file:read_file(Src),
                     {match, Cs} = re:run(Code, <<"^(?:handle_?|route)\\(<<\"([A-Z]+)\">>, \\[([^\\]]*)\\]">>,
                                          [global, multiline, {capture, all_but_first, binary}]),
                     Cs
                 end || Src <- Sources]),
    Api = [{M, <<"/api", (segments(Segs))/binary>>} || [M, Segs] <- Clauses],
    Web = [{<<"POST">>, P} || {P0, lg_web_llm, _} <- lg_web_routes:routes(), P <- [list_to_binary(P0)]]
        ++ [{<<"POST">>, <<"/v1/live">>}, {<<"GET">>, <<"/v1/live/{}">>},
            {<<"GET">>, <<"/v1/models">>}, {<<"GET">>, <<"/health">>}, {<<"GET">>, <<"/metrics">>}],
    ?assert(length(Api) > 50),
    ?assertEqual(19, length(Web)),
    Implemented = lists:usort(Api ++ Web),
    ?assertEqual([], Implemented -- Documented),
    ?assertEqual([], Documented -- Implemented).

%% [<<"a">>, Id, <<"b">>] → /a/{}/b
segments(<<>>) -> <<>>;
segments(Segs) ->
    iolist_to_binary([["/", case re:run(S, <<"^<<\"(.*)\">>$">>, [{capture, all_but_first, binary}]) of
                                {match, [Lit]} -> Lit;
                                nomatch -> <<"{}">>
                            end] || S <- binary:split(Segs, <<", ">>, [global])]).

normalize(P) -> re:replace(P, <<"\\{[^}]+\\}">>, <<"{}">>, [global, {return, binary}]).

console_static(Ctx) ->
    {302, H, _} = req(Ctx, <<"GET">>, <<"/">>, [], <<>>),
    ?assertEqual(<<"/console/">>, proplists:get_value(<<"location">>, H)),
    %% 前端已构建时返回 index.html；未构建时 404（两种都不应 500 或重定向循环）
    [begin
         {S, H2, _} = req(Ctx, <<"GET">>, P, [], <<>>),
         ?assert(S =:= 200 orelse S =:= 404),
         %% 入口页不缓存，升级后浏览器总能拿到新的资源引用
         S =:= 200 andalso ?assertEqual(<<"no-cache">>, proplists:get_value(<<"cache-control">>, H2))
     end || P <- [<<"/console">>, <<"/console/">>, <<"/console/routes/abc">>]].

limits_and_budgets(#{admin := A} = Ctx) ->
    {200, #{<<"id">> := C}} =
        api(Ctx, A, <<"POST">>, <<"/api/credentials">>,
            #{<<"name">> => <<"lim">>, <<"protocol">> => <<"openai">>, <<"base_url">> => <<"https://x.test/v1">>}),
    {200, _} = api(Ctx, A, <<"POST">>, <<"/api/routes">>,
                   #{<<"name">> => <<"limited">>,
                     <<"targets">> => [#{<<"credential">> => C, <<"upstream_model">> => <<"m">>}]}),
    {200, #{<<"id">> := K}} = api(Ctx, A, <<"POST">>, <<"/api/keys">>, #{<<"name">> => <<"lim-key">>}),
    KeyScope = #{<<"type">> => <<"key">>, <<"key_id">> => K},
    {200, #{<<"rpm">> := 60, <<"tpm">> := null}} =
        api(Ctx, A, <<"PUT">>, <<"/api/limits">>, #{<<"scope">> => KeyScope, <<"rpm">> => 60}),
    {200, _} = api(Ctx, A, <<"PUT">>, <<"/api/limits">>,
                   #{<<"scope">> => #{<<"type">> => <<"route">>, <<"route">> => <<"limited">>}, <<"tpm">> => 1000}),
    {200, _} = api(Ctx, A, <<"PUT">>, <<"/api/limits">>,
                   #{<<"scope">> => #{<<"type">> => <<"key_route">>, <<"key_id">> => K, <<"route">> => <<"limited">>},
                     <<"max_parallel">> => 2}),
    {200, #{<<"period">> := <<"week">>, <<"max_usd">> := 5, <<"spent_usd">> := +0.0}} =
        api(Ctx, A, <<"PUT">>, <<"/api/budgets">>,
            #{<<"scope">> => KeyScope, <<"period">> => <<"week">>, <<"max_usd">> => 5}),
    {200, Keys} = api(Ctx, A, <<"GET">>, <<"/api/keys">>),
    [#{<<"limit">> := #{<<"rpm">> := 60}, <<"budget">> := #{<<"max_usd">> := 5, <<"resets_at">> := _}}] =
        [X || #{<<"id">> := Id} = X <- Keys, Id =:= K],
    {200, Routes} = api(Ctx, A, <<"GET">>, <<"/api/routes">>),
    [#{<<"limit">> := #{<<"tpm">> := 1000}, <<"key_limits">> := [#{<<"key_id">> := K, <<"max_parallel">> := 2}]}] =
        [R || #{<<"name">> := <<"limited">>} = R <- Routes],
    {200, [_, _, _]} = api(Ctx, A, <<"GET">>, <<"/api/limits">>),
    ?assertMatch({400, _}, api(Ctx, A, <<"PUT">>, <<"/api/limits">>,
                               #{<<"scope">> => #{<<"type">> => <<"user">>, <<"user_id">> => <<"u">>}, <<"rpm">> => 1})),
    ?assertMatch({400, _}, api(Ctx, A, <<"PUT">>, <<"/api/budgets">>,
                               #{<<"scope">> => KeyScope, <<"max_usd">> => <<"lots">>})),
    ?assertMatch({400, _}, api(Ctx, A, <<"PUT">>, <<"/api/limits">>, #{<<"rpm">> => 1})),
    %% 用户预算出现在用户列表
    {200, #{<<"id">> := Me}} = api(Ctx, A, <<"GET">>, <<"/api/auth/me">>),
    {200, _} = api(Ctx, A, <<"PUT">>, <<"/api/budgets">>,
                   #{<<"scope">> => #{<<"type">> => <<"user">>, <<"user_id">> => Me}, <<"max_usd">> => 100}),
    {200, Users} = api(Ctx, A, <<"GET">>, <<"/api/users">>),
    [#{<<"budget">> := #{<<"period">> := <<"month">>}}] = [U || #{<<"id">> := Id} = U <- Users, Id =:= Me],
    %% 普通用户不能改限额
    U = login(Ctx, <<"dev">>, <<"new-password">>),
    ?assertMatch({403, _}, api(Ctx, U, <<"PUT">>, <<"/api/limits">>, #{<<"scope">> => KeyScope, <<"rpm">> => 1})),
    %% 删除 Key 时清理其限额与预算
    {200, _} = api(Ctx, A, <<"DELETE">>, <<"/api/keys/", K/binary>>),
    {200, [_]} = api(Ctx, A, <<"GET">>, <<"/api/limits">>),
    {200, _} = api(Ctx, A, <<"DELETE">>, <<"/api/routes/limited">>),
    {200, []} = api(Ctx, A, <<"GET">>, <<"/api/limits">>),
    {200, [_]} = api(Ctx, A, <<"GET">>, <<"/api/budgets">>).

store(#{admin := A} = Ctx) ->
    {200, #{<<"casks">> := Casks, <<"cleanup">> := _}} = api(Ctx, A, <<"GET">>, <<"/api/store">>),
    ?assertEqual([<<"logs">>, <<"msgs">>, <<"idx">>, <<"usage">>, <<"search">>, <<"cache">>, <<"responses">>, <<"alerts">>, <<"sessions">>],
                 [maps:get(<<"cask">>, C) || C <- Casks]),
    {200, #{<<"logs">> := 0, <<"merged">> := _}} = api(Ctx, A, <<"POST">>, <<"/api/store/cleanup">>),
    {200, #{<<"cleanup">> := #{<<"at">> := _}}} = api(Ctx, A, <<"GET">>, <<"/api/store">>),
    U = login(Ctx, <<"dev">>, <<"new-password">>),
    ?assertMatch({403, _}, api(Ctx, U, <<"POST">>, <<"/api/store/cleanup">>)).

%% 单机模式（默认）：无需登录，访问者视为管理员；不创建初始账号
no_auth_test_() ->
    {setup,
     fun() ->
             Dir = lg_core_test_util:start(),
             application:set_env(lg_core, http_port, 0),
             {ok, _} = application:ensure_all_started(lg_web),
             #{dir => Dir, port => ranch:get_port(lg_http_listener)}
     end,
     fun(#{dir := Dir}) ->
             [application:stop(A) || A <- [lg_web, lg_router, lg_provider, lg_catalog]],
             application:unset_env(lg_core, http_port),
             lg_core_test_util:stop(Dir)
     end,
     fun(Ctx) ->
             ?_test(begin
                        ?assertEqual([], lg_users:list()),
                        {200, Me} = api(Ctx, none, <<"GET">>, <<"/api/auth/me">>),
                        ?assertMatch(#{<<"role">> := <<"admin">>, <<"auth_enabled">> := false}, Me),
                        {200, _} = api(Ctx, none, <<"GET">>, <<"/api/credentials">>),
                        {200, #{<<"key">> := _}} = api(Ctx, none, <<"POST">>, <<"/api/keys">>,
                                                       #{<<"name">> => <<"local">>}),
                        ?assertMatch({400, _}, api(Ctx, none, <<"PUT">>, <<"/api/auth/password">>,
                                                   #{<<"password">> => <<"whatever1">>})),
                        %% 没有管理员账号时不能开启登录
                        ?assertMatch({400, #{<<"error">> := #{<<"message">> := <<"Create an enabled admin", _/binary>>}}},
                                     api(Ctx, none, <<"PUT">>, <<"/api/settings/console_auth">>,
                                         #{<<"value">> => true})),
                        {200, _} = api(Ctx, none, <<"POST">>, <<"/api/users">>,
                                       #{<<"username">> => <<"boss">>, <<"password">> => <<"boss-password">>,
                                         <<"role">> => <<"admin">>}),
                        {200, #{<<"value">> := true}} =
                            api(Ctx, none, <<"PUT">>, <<"/api/settings/console_auth">>, #{<<"value">> => true}),
                        %% 开启后需要登录
                        ?assertMatch({401, _}, api(Ctx, none, <<"GET">>, <<"/api/credentials">>)),
                        T = login(Ctx, <<"boss">>, <<"boss-password">>),
                        {200, #{<<"auth_enabled">> := true}} = api(Ctx, T, <<"GET">>, <<"/api/auth/me">>),
                        ok = lg_config:unset(console_auth)
                    end)
     end}.

health(#{admin := A} = Ctx) ->
    {ok, L} = gen_tcp:listen(0, []),
    {ok, Port} = inet:port(L),
    gen_tcp:close(L),
    {200, #{<<"id">> := C}} =
        api(Ctx, A, <<"POST">>, <<"/api/credentials">>,
            #{<<"name">> => <<"dead">>, <<"protocol">> => <<"openai">>,
              <<"base_url">> => iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port), "/v1"])}),
    ok = lg_health:record({C, <<"m">>}, timeout, 100, <<"slow">>),
    ok = lg_cooldown:mark({C, <<"m">>}, #{kind => timeout, retry_after_ms => 60000}),
    {200, #{<<"targets">> := Ts, <<"probe_interval_ms">> := 0}} = api(Ctx, A, <<"GET">>, <<"/api/health">>),
    [#{<<"errors">> := 1, <<"cooldown_ms">> := Cd}] = [T || #{<<"credential">> := Id} = T <- Ts, Id =:= C],
    ?assert(Cd > 0),
    {200, _} = api(Ctx, A, <<"POST">>, <<"/api/health/reset">>,
                   #{<<"credential">> => C, <<"upstream_model">> => <<"m">>}),
    ?assertEqual(0, lg_cooldown:remaining_ms({C, <<"m">>})),
    %% 只探活本测试的凭证（其他测试留下的凭证可能指向真实服务）
    {200, Probes} = api(Ctx, A, <<"POST">>, <<"/api/health/probe">>, #{<<"credentials">> => [C]}),
    ?assertMatch([#{<<"result">> := <<"network">>}], [P || #{<<"credential">> := Id} = P <- Probes, Id =:= C]),
    {200, _} = api(Ctx, A, <<"DELETE">>, <<"/api/credentials/", C/binary>>).

config_io(#{admin := A} = Ctx) ->
    {S, H, B} = req(Ctx, <<"POST">>, <<"/api/config/export">>,
                    [{<<"authorization">>, <<"Bearer ", A/binary>>}, {<<"content-type">>, <<"application/json">>}],
                    json:encode(#{<<"passphrase">> => <<"export-pass">>})),
    ?assertEqual(200, S),
    ?assertMatch(<<"attachment; filename=\"litegate-config-", _/binary>>,
                 proplists:get_value(<<"content-disposition">>, H)),
    Data = json:decode(B),
    ?assertMatch(#{<<"format">> := <<"litegate-config">>, <<"version">> := 1}, Data),
    ?assertMatch({400, #{<<"error">> := #{<<"message">> := <<"Invalid field: passphrase">>}}},
                 api(Ctx, A, <<"POST">>, <<"/api/config/export">>, #{<<"passphrase">> => <<"x">>})),
    {200, #{<<"routes">> := #{<<"overwritten">> := _}}} =
        api(Ctx, A, <<"POST">>, <<"/api/config/import">>,
            #{<<"passphrase">> => <<"export-pass">>, <<"mode">> => <<"merge">>, <<"dry_run">> => true,
              <<"data">> => Data}),
    ?assertMatch({400, #{<<"error">> := #{<<"message">> := <<"Wrong passphrase">>}}},
                 api(Ctx, A, <<"POST">>, <<"/api/config/import">>,
                     #{<<"passphrase">> => <<"nope-nope">>, <<"data">> => Data})).
