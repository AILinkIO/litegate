%% @doc 控制台管理 API：/api/...（JSON）。
%%
%% 鉴权：运行参数 console_auth 为 false（默认，单机模式）时无需登录，访问者视为本地管理员；
%% 为 true 时使用登录会话 token，放在 cookie lg_session（HttpOnly，SameSite=Strict）或 Authorization: Bearer。
%% 角色：admin 可访问全部；user 只能访问 /api/auth/*、自己的 /api/keys、/api/logs、/api/usage。
-module(lg_api).
-behaviour(cowboy_handler).

-include_lib("lg_core/include/lg_core.hrl").

-export([init/2, console_admin/1]).
-export([body/1, reply/3, result/3, ok_result/2, found/3, not_found/1, bad_request/2,
         err/2, qs/2, int_qs/2, page/2, default/2, group/2, clean/1, fmt/1]).
-export([key_limits/2]).

-define(COOKIE, <<"lg_session">>).
%% 未启用登录时的本地管理员身份（不落库）
-define(LOCAL_ADMIN, <<"local">>).

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    Path = cowboy_req:path_info(Req0),
    Req = try
              route(Method, Path, Req0)
          catch
              throw:{reply, Status, Body, R} ->
                  reply(Status, Body, R);
              Class:Reason:Stack ->
                  logger:error("api ~s /api/~ts crashed: ~p:~p~n~p",
                               [Method, lists:join("/", Path), Class, Reason, Stack]),
                  reply(500, err(<<"internal_error">>, <<"Internal server error">>), Req0)
          end,
    {ok, Req, State}.

%%====================================================================
%% 路由
%%====================================================================

%% ---- 登录 ----
route(<<"POST">>, [<<"auth">>, <<"login">>], Req0) ->
    {Body, Req} = body(Req0),
    {PeerIp, _Port} = cowboy_req:peer(Req),
    case lg_users:login(maps:get(<<"username">>, Body, null), maps:get(<<"password">>, Body, null), PeerIp) of
        {ok, Token, User} ->
            Ttl = lg_config:get(session_ttl_ms) div 1000,
            Req1 = cowboy_req:set_resp_cookie(?COOKIE, Token, Req,
                                              #{http_only => true, same_site => strict,
                                                path => <<"/">>, max_age => Ttl}),
            reply(200, #{<<"user">> => lg_users:to_map(User), <<"token">> => Token}, Req1);
        {error, {rate_limited, RetryAfterS}} ->
            Headers = #{<<"retry-after">> => integer_to_binary(RetryAfterS)},
            cowboy_req:reply(429, Headers,
                             json:encode(err(<<"rate_limited">>,
                                             iolist_to_binary(
                                               io_lib:format("Too many attempts; retry after ~b seconds",
                                                             [RetryAfterS])))),
                             Req);
        {error, _} ->
            reply(401, err(<<"invalid_credentials">>, <<"Invalid username or password">>), Req)
    end;
route(<<"POST">>, [<<"auth">>, <<"logout">>], Req) ->
    case token(Req) of
        undefined -> ok;
        T -> lg_users:logout(T)
    end,
    Req1 = cowboy_req:set_resp_cookie(?COOKIE, <<>>, Req, #{path => <<"/">>, max_age => 0}),
    reply(200, #{<<"ok">> => true}, Req1);
%% ---- 接口文档（不涉密，无需登录）----
route(<<"GET">>, [<<"openapi.json">>], Req) ->
    case file:read_file(filename:join(code:priv_dir(lg_web), "openapi.json")) of
        {ok, Doc} -> cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>}, Doc, Req);
        {error, _} -> not_found(Req)
    end;
route(Method, Path, Req) ->
    User = authenticate(Req),
    authorized(User, Path) orelse throw({reply, 403, err(<<"forbidden">>, <<"Admin only">>), Req}),
    %% 管理端资源在 lg_api_admin；未命中返回 ok，落到本模块的 handle/4
    %% 未命中管理端资源时返回 ok；命中资源已在内部完成 reply / throw
    _ = lg_api_admin:handle(Method, Path, User, Req),
    handle(Method, Path, User, Req).

authorized(#lg_user{role = admin}, _) -> true;
authorized(_, [<<"auth">> | _]) -> true;
authorized(_, [<<"keys">> | _]) -> true;
authorized(_, [<<"logs">> | _]) -> true;
authorized(_, [<<"sessions">> | _]) -> true;
authorized(_, [<<"usage">>]) -> true;
authorized(_, [<<"overview">>]) -> true;
authorized(_, _) -> false.

%% ---- 当前用户 ----
handle(<<"GET">>, [<<"auth">>, <<"me">>], User, Req) ->
    reply(200, (lg_users:to_map(User))#{<<"auth_enabled">> => lg_config:get(console_auth),
                                        <<"insecure_exposed">> => insecure_exposed()}, Req);
handle(<<"PUT">>, [<<"auth">>, <<"password">>], #lg_user{id = ?LOCAL_ADMIN}, Req) ->
    throw({reply, 400, err(<<"invalid_request">>, <<"Console login is disabled">>), Req});
handle(<<"PUT">>, [<<"auth">>, <<"password">>], #lg_user{id = Id}, Req0) ->
    {Body, Req} = body(Req0),
    result(lg_users:update(Id, maps:with([<<"password">>], Body)), fun lg_users:to_map/1, Req);

%% ---- 概览 ----
handle(<<"GET">>, [<<"overview">>], User, Req) ->
    Now = lg_time:now_ms(),
    Scope = scope(User, #{}),
    Day = lg_store:usage(Scope#{from => Now - 86400000, to => Now + 1}),
    Base = #{<<"usage_24h">> => case Day of [T] -> T; [] -> #{} end,
             %% 按小时返回，由前端按浏览器时区汇总成天（服务端的 day 分组是 UTC）
             <<"hourly">> => lg_store:usage(Scope#{from => Now - 15 * 86400000, to => Now + 1,
                                                   group_by => [hour]})},
    Extra = case User#lg_user.role of
                admin -> #{<<"counts">> => #{<<"routes">> => length(lg_routes:list()),
                                             <<"credentials">> => length(lg_credentials:list()),
                                             <<"keys">> => length(lg_api_keys:list()),
                                             <<"catalog_models">> => mnesia:table_info(lg_catalog_model, size)},
                           <<"catalog_sync">> => lg_catalog_sync:status()};
                user -> #{}
            end,
    reply(200, maps:merge(Base, Extra), Req);

%% ---- 网关 Key（user 只能管理自己的）----
handle(<<"GET">>, [<<"keys">>], User, Req) ->
    Keys = case User of
               #lg_user{role = admin} -> lg_api_keys:list();
               #lg_user{id = Id} -> lg_api_keys:list(Id)
           end,
    reply(200, [key_out(K) || K <- Keys], Req);
handle(<<"POST">>, [<<"keys">>], User, Req0) ->
    {Body0, Req} = body(Req0),
    Body = case User of
               #lg_user{role = admin} -> Body0;
               #lg_user{id = Id} -> Body0#{<<"user_id">> => Id}
           end,
    case lg_api_keys:create(Body) of
        {ok, Plain, K} -> reply(200, (key_out(K))#{<<"key">> => Plain}, Req);
        {error, R} -> bad_request(R, Req)
    end;
handle(<<"PUT">>, [<<"keys">>, Id], User, Req0) ->
    own_key(Id, User, Req0),
    {Body0, Req} = body(Req0),
    Body = case User of
               #lg_user{role = admin} -> Body0;
               _ -> maps:without([<<"user_id">>], Body0)
           end,
    result(lg_api_keys:update(Id, Body), fun key_out/1, Req);
handle(<<"DELETE">>, [<<"keys">>, Id], User, Req) ->
    own_key(Id, User, Req),
    ok = lg_api_keys:delete(Id),
    reply(200, #{<<"ok">> => true}, Req);

%% ---- 用户 ----
handle(<<"GET">>, [<<"users">>], _U, Req) ->
    reply(200, [(lg_users:to_map(U))#{<<"budget">> => lg_limits:budget_status({user, Id})}
                || #lg_user{id = Id} = U <- lg_users:list()], Req);
handle(<<"POST">>, [<<"users">>], _U, Req0) ->
    {Body, Req} = body(Req0),
    result(lg_users:create(Body), fun lg_users:to_map/1, Req);
handle(<<"PUT">>, [<<"users">>, Id], #lg_user{id = Me}, Req0) ->
    {Body, Req} = body(Req0),
    %% 防止管理员把自己锁在门外
    Id =:= Me andalso (maps:get(<<"enabled">>, Body, true) =:= false
                       orelse maps:get(<<"role">>, Body, <<"admin">>) =/= <<"admin">>)
        andalso throw({reply, 400, err(<<"invalid_request">>, <<"Cannot demote or disable yourself">>), Req}),
    result(lg_users:update(Id, Body), fun lg_users:to_map/1, Req);
handle(<<"DELETE">>, [<<"users">>, Id], #lg_user{id = Me}, Req) ->
    Id =:= Me andalso throw({reply, 400, err(<<"invalid_request">>, <<"Cannot delete yourself">>), Req}),
    ok = lg_users:delete(Id),
    reply(200, #{<<"ok">> => true}, Req);

%% ---- 限额与预算 ----
handle(<<"GET">>, [<<"limits">>], _U, Req) ->
    reply(200, [lg_limits:limit_to_map(L) || L <- lg_limits:list_limits()], Req);
handle(<<"PUT">>, [<<"limits">>], _U, Req0) ->
    {Body, Req} = body(Req0),
    Scope = scope(maps:get(<<"scope">>, Body, null), [key, route, key_route], Req),
    case lg_limits:set_limit(Scope, Body) of
        {ok, deleted} -> reply(200, #{<<"deleted">> => true}, Req);
        {ok, L} -> reply(200, lg_limits:limit_to_map(L), Req);
        {error, R} -> bad_request(R, Req)
    end;
handle(<<"GET">>, [<<"budgets">>], _U, Req) ->
    reply(200, [(lg_limits:budget_to_map(B))#{<<"status">> => lg_limits:budget_status(S)}
                || #lg_budget{scope = S} = B <- lg_limits:list_budgets()], Req);
handle(<<"PUT">>, [<<"budgets">>], _U, Req0) ->
    {Body, Req} = body(Req0),
    Scope = scope(maps:get(<<"scope">>, Body, null), [key, user, tag], Req),
    case lg_limits:set_budget(Scope, Body) of
        {ok, deleted} -> reply(200, #{<<"deleted">> => true}, Req);
        {ok, _} -> reply(200, lg_limits:budget_status(Scope), Req);
        {error, R} -> bad_request(R, Req)
    end;

%% ---- 请求日志 ----
handle(<<"GET">>, [<<"logs">>], User, Req) ->
    Q = cowboy_req:parse_qs(Req),
    Query = maps:filter(fun(_, V) -> V =/= undefined end,
                        #{from => int_qs(<<"from">>, Q), to => int_qs(<<"to">>, Q),
                          limit => int_qs(<<"limit">>, Q), cursor => qs(<<"cursor">>, Q),
                          key_id => qs(<<"key_id">>, Q), route => qs(<<"route">>, Q),
                          user_id => qs(<<"user_id">>, Q), tag => qs(<<"tag">>, Q), client => qs(<<"client">>, Q),
                          session => qs(<<"session">>, Q),
                          errors_only => case qs(<<"errors_only">>, Q) of
                                             <<"true">> -> true;
                                             _ -> undefined
                                         end}),
    %% 带 q 时走全文检索（按相关度排序，不分页）
    #{items := Items, next_cursor := Next} =
        case qs(<<"q">>, Q) of
            undefined -> lg_store:logs(scope(User, Query));
            Text -> lg_store:search(scope(User, Query#{q => Text}))
        end,
    reply(200, #{<<"items">> => [clean(L) || L <- Items], <<"next_cursor">> => Next}, Req);
handle(<<"GET">>, [<<"logs">>, Id], User, Req) ->
    case lg_store:log(Id) of
        {ok, Log} ->
            visible(Log, User) orelse not_found(Req),
            Msgs = case lg_store:messages(Id) of {ok, M} -> clean(M); not_found -> null end,
            Narrative = try lg_narrate:lines(Log)
                        catch C:R:St ->
                                logger:warning("narrate ~s failed: ~p:~p ~p", [Id, C, R, St]),
                                []
                        end,
            reply(200, (clean(Log))#{messages => Msgs, narrative => Narrative}, Req);
        not_found ->
            not_found(Req)
    end;

%% ---- 会话 ----
handle(<<"GET">>, [<<"sessions">>], User, Req) ->
    Q = cowboy_req:parse_qs(Req),
    Query = maps:filter(fun(_, V) -> V =/= undefined end,
                        #{from => int_qs(<<"from">>, Q), to => int_qs(<<"to">>, Q),
                          limit => int_qs(<<"limit">>, Q), cursor => qs(<<"cursor">>, Q),
                          key_id => qs(<<"key_id">>, Q), user_id => qs(<<"user_id">>, Q), client => qs(<<"client">>, Q)}),
    #{items := Items, next_cursor := Next} = lg_store:sessions(scope(User, Query)),
    reply(200, #{<<"items">> => [clean(S) || S <- Items], <<"next_cursor">> => Next}, Req);
handle(<<"GET">>, [<<"sessions">>, Sid], User, Req) ->
    case lg_store:session(Sid) of
        {ok, S} ->
            visible(S, User) orelse not_found(Req),
            #{items := Logs, next_cursor := Next} = lg_store:logs(scope(User, #{session => Sid, limit => 500})),
            Narrate = fun(L) -> try lg_narrate:lines(L) catch _:_ -> [] end end,
            reply(200, (clean(S))#{<<"logs">> => [(clean(L))#{narrative => Narrate(L)} || L <- lists:reverse(Logs)],
                                   <<"truncated">> => Next =/= null}, Req);
        not_found ->
            not_found(Req)
    end;

%% ---- 用量 ----
handle(<<"GET">>, [<<"usage">>], User, Req) ->
    Q = cowboy_req:parse_qs(Req),
    GroupBy = case qs(<<"group_by">>, Q) of
                  undefined -> [];
                  G -> [group(X, Req) || X <- binary:split(G, <<",">>, [global]), X =/= <<>>]
              end,
    Query = maps:filter(fun(_, V) -> V =/= undefined end,
                        #{from => int_qs(<<"from">>, Q), to => int_qs(<<"to">>, Q),
                          key_id => qs(<<"key_id">>, Q), route => qs(<<"route">>, Q),
                          user_id => qs(<<"user_id">>, Q), tag => qs(<<"tag">>, Q), client => qs(<<"client">>, Q),
                          group_by => GroupBy}),
    reply(200, [clean(R) || R <- lg_store:usage(scope(User, Query))], Req);

handle(_Method, _Path, _U, Req) ->
    not_found(Req).

key_out(#lg_api_key{id = Id} = K) ->
    (lg_api_keys:to_map(K))#{<<"limit">> => lg_limits:limit_fields({key, Id}),
                             <<"budget">> => lg_limits:budget_status({key, Id})}.

%% 路由上按 Key 的例外限额
key_limits(Route, Limits) ->
    [(maps:with([<<"rpm">>, <<"tpm">>, <<"max_parallel">>], lg_limits:limit_to_map(L)))#{<<"key_id">> => K}
     || #lg_limit{scope = {key_route, K, R}} = L <- Limits, R =:= Route].

scope(Map, Allowed, Req) when is_map(Map) ->
    case lg_limits:scope_from_map(Map) of
        {ok, S} ->
            lists:member(element(1, S), Allowed) orelse bad_request({invalid, <<"scope">>}, Req),
            S;
        {error, R} ->
            bad_request(R, Req)
    end;
scope(_, _, Req) ->
    bad_request({missing, <<"scope">>}, Req).

%%====================================================================
%% 鉴权与权限
%%====================================================================

%% @doc 控制台管理员身份（Playground 用）：{ok, User} | {error, Status, Message}。
-spec console_admin(cowboy_req:req()) -> {ok, #lg_user{}} | {error, 401 | 403, binary()}.
console_admin(Req) ->
    try authenticate(Req) of
        #lg_user{role = admin} = U -> {ok, U};
        _ -> {error, 403, <<"Admin only">>}
    catch
        throw:{reply, S, #{<<"error">> := #{<<"message">> := M}}, _} -> {error, S, M}
    end.

authenticate(Req) ->
    case lg_config:get(console_auth) of
        false ->
            #lg_user{id = ?LOCAL_ADMIN, username = <<"admin">>, password_hash = <<>>,
                     role = admin, created_at = 0};
        true ->
            session_user(Req)
    end.

session_user(Req) ->
    case token(Req) of
        undefined ->
            throw({reply, 401, err(<<"unauthorized">>, <<"Login required">>), Req});
        T ->
            case lg_users:session(T) of
                {ok, U} -> U;
                {error, _} -> throw({reply, 401, err(<<"unauthorized">>, <<"Session expired">>), Req})
            end
    end.

token(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer lgs-", _/binary>> = H -> binary:part(H, 7, byte_size(H) - 7);
        _ ->
            case lists:keyfind(?COOKIE, 1, cowboy_req:parse_cookies(Req)) of
                {_, T} when T =/= <<>> -> T;
                _ -> undefined
            end
    end.

%% 免登录管理面是否绑定在非 loopback 地址；反代场景还需结合部署层的真实来源限制
insecure_exposed() ->
    lg_config:get(console_auth) =:= false andalso not loopback(bind(lg_config:get(http_bind))).

bind(Value) when is_binary(Value); is_list(Value) ->
    {ok, Ip} = inet:parse_address(binary_to_list(Value)),
    Ip;
bind(Ip) when is_tuple(Ip) -> Ip.

loopback({127, _, _, _}) -> true;
loopback({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
loopback(_) -> false.

%% 非管理员查询自动限定为自己的数据
scope(#lg_user{role = admin}, Q) -> Q;
scope(#lg_user{id = Id}, Q) -> Q#{user_id => Id}.

visible(_, #lg_user{role = admin}) -> true;
visible(Log, #lg_user{id = Id}) -> maps:get(user_id, Log, undefined) =:= Id.

own_key(_Id, #lg_user{role = admin}, _Req) ->
    ok;
own_key(Id, #lg_user{id = Uid}, Req) ->
    case lg_api_keys:get(Id) of
        {ok, #lg_api_key{user_id = Uid}} -> ok;
        _ -> not_found(Req)
    end.

%%====================================================================
%% 辅助
%%====================================================================

body(Req0) ->
    case lg_web_util:read_json(Req0) of
        {ok, Body, Req} -> {Body, Req};
        {error, _, Req} -> throw({reply, 400, err(<<"invalid_request">>, <<"Invalid JSON body">>), Req})
    end.

reply(Status, Body, Req) ->
    lg_web_util:json(Status, Body, Req).

result({ok, Rec}, ToMap, Req) -> reply(200, ToMap(Rec), Req);
result({error, not_found}, _, Req) -> not_found(Req);
result({error, R}, _, Req) -> bad_request(R, Req).

ok_result(ok, Req) -> reply(200, #{<<"ok">> => true}, Req);
ok_result({error, R}, Req) -> bad_request(R, Req).

found({ok, Rec}, ToMap, Req) -> reply(200, ToMap(Rec), Req);
found(not_found, _, Req) -> not_found(Req).

-spec not_found(cowboy_req:req()) -> no_return().
not_found(Req) ->
    throw({reply, 404, err(<<"not_found">>, <<"Not found">>), Req}).

-spec bad_request(term(), cowboy_req:req()) -> no_return().
bad_request(Reason, Req) ->
    throw({reply, 400, err(<<"invalid_request">>, describe(Reason)), Req}).

err(Code, Msg) ->
    #{<<"error">> => #{<<"code">> => Code, <<"message">> => Msg}}.

describe({unknown_fields, L}) ->
    iolist_to_binary([<<"未知顶层字段: "/utf8>>, lists:join(<<", ">>, L),
                      <<"（rules/classifier 等扩展配置放在 options 下）"/utf8>>]);
describe({missing, K}) -> <<"Missing field: ", K/binary>>;
describe({invalid, K}) -> <<"Invalid field: ", K/binary>>;
describe({in_use, By}) -> <<"In use by: ", (iolist_to_binary(lists:join(<<", ">>, By)))/binary>>;
describe({unknown_credential, C}) -> <<"Unknown credential: ", C/binary>>;
describe({unknown_route, R}) -> <<"Unknown route: ", R/binary>>;
describe({disabled_route, R}) -> <<"Route is disabled: ", R/binary>>;
describe(invalid_name) -> <<"Invalid file name">>;
describe(not_found) -> <<"Not found">>;
describe(already_exists) -> <<"Already exists">>;
describe({alias_conflict, A}) -> <<"Alias already used by a route or another alias: ", A/binary>>;
describe({unsupported_provider, P}) -> <<"Provider protocol not supported: ", P/binary>>;
describe({no_base_url, P}) -> <<"Provider has no base URL: ", P/binary>>;
describe({invalid_ref, _}) -> <<"Invalid model reference">>;
describe(bad_passphrase) -> <<"Wrong passphrase">>;
describe(invalid_format) -> <<"Not a LiteGate config file">>;
describe({unsupported_version, V}) -> <<"Unsupported config version: ", (fmt(V))/binary>>;
describe({undecryptable_credential, Id}) -> <<"Cannot decrypt the API key of credential ", Id/binary>>;
describe(R) -> fmt(R).

fmt(R) -> unicode:characters_to_binary(io_lib:format("~0p", [R])).

qs(K, Q) ->
    case lists:keyfind(K, 1, Q) of
        {_, V} when is_binary(V), V =/= <<>> -> V;
        _ -> undefined
    end.

int_qs(K, Q) ->
    case qs(K, Q) of
        undefined -> undefined;
        V -> try binary_to_integer(V) catch error:_ -> undefined end
    end.

page(Items, Q) ->
    Offset = max(0, default(int_qs(<<"offset">>, Q), 0)),
    Limit = min(max(1, default(int_qs(<<"limit">>, Q), 50)), 500),
    #{<<"total">> => length(Items),
      <<"items">> => lists:sublist(Items, Offset + 1, Limit)}.

default(undefined, D) -> D;
default(V, _) -> V.

group(<<"hour">>, _) -> hour;
group(<<"day">>, _) -> day;
group(<<"key_id">>, _) -> key_id;
group(<<"user_id">>, _) -> user_id;
group(<<"route">>, _) -> route;
group(<<"credential">>, _) -> credential;
group(<<"model">>, _) -> model;
group(<<"tag">>, _) -> tag;
group(<<"client">>, _) -> client;
group(G, Req) -> bad_request({invalid, <<"group_by: ", G/binary>>}, Req).

%% 存储里的 Erlang 项转 JSON：元组转数组，undefined 转 null
clean(M) when is_map(M) -> maps:map(fun(_, V) -> clean(V) end, M);
clean(L) when is_list(L) -> [clean(X) || X <- L];
clean(T) when is_tuple(T) -> [clean(X) || X <- tuple_to_list(T)];
clean(undefined) -> null;
clean(V) -> V.
