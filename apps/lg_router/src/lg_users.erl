%% @doc 控制台账号与登录会话。
%%
%% 角色：admin 管理全部配置；user 只能管理自己的 API Key、查看自己的日志与用量。
%% 会话 token 只存 SHA-256 哈希，有效期 session_ttl_ms。
-module(lg_users).

-include_lib("lg_core/include/lg_core.hrl").

-export([create/1, update/2, delete/1, get/1, list/0, to_map/1,
         login/2, login/3, session/1, logout/1, ensure_admin/0]).

-define(MIN_PASSWORD, 8).

%% @doc Params：username, password, role?（"admin" | "user"）
-spec create(map()) -> {ok, #lg_user{}} | {error, term()}.
create(#{<<"username">> := U, <<"password">> := P} = Params) when is_binary(U), is_binary(P) ->
    case {valid_username(U), valid_password(P), role(maps:get(<<"role">>, Params, <<"user">>))} of
        {false, _, _} -> {error, {invalid, <<"username">>}};
        {_, false, _} -> {error, {invalid, <<"password">>}};
        {_, _, error} -> {error, {invalid, <<"role">>}};
        {true, true, {ok, Role}} ->
            Rec = #lg_user{id = lg_id:new(<<"user">>), username = U,
                           password_hash = lg_crypto:hash_password(P), role = Role,
                           created_at = lg_time:now_ms()},
            Tx = fun() ->
                         case mnesia:index_read(lg_user, U, username) of
                             [] -> mnesia:write(Rec);
                             _ -> mnesia:abort(already_exists)
                         end
                 end,
            case lg_db:transaction(Tx) of
                {ok, ok} -> {ok, Rec};
                {error, _} = Err -> Err
            end
    end;
create(_) ->
    {error, {missing, <<"username/password">>}}.

%% @doc 可改 password / role / enabled。改密码或禁用时清除该用户的会话。
-spec update(binary(), map()) -> {ok, #lg_user{}} | {error, term()}.
update(Id, Params) ->
    case lg_db:read(lg_user, Id) of
        {ok, U0} ->
            try
                U1 = case maps:find(<<"password">>, Params) of
                         {ok, P} when is_binary(P) ->
                             valid_password(P) orelse throw({invalid, <<"password">>}),
                             U0#lg_user{password_hash = lg_crypto:hash_password(P)};
                         {ok, _} -> throw({invalid, <<"password">>});
                         error -> U0
                     end,
                U2 = case maps:find(<<"role">>, Params) of
                         {ok, R} ->
                             case role(R) of
                                 {ok, Role} -> U1#lg_user{role = Role};
                                 error -> throw({invalid, <<"role">>})
                             end;
                         error -> U1
                     end,
                U3 = case maps:find(<<"enabled">>, Params) of
                         {ok, E} when is_boolean(E) -> U2#lg_user{enabled = E};
                         {ok, _} -> throw({invalid, <<"enabled">>});
                         error -> U2
                     end,
                ok = lg_db:write(U3),
                (U3#lg_user.password_hash =/= U0#lg_user.password_hash
                 orelse not U3#lg_user.enabled) andalso drop_sessions(Id),
                {ok, U3}
            catch
                throw:{invalid, _} = Invalid -> {error, Invalid}
            end;
        not_found ->
            {error, not_found}
    end.

-spec delete(binary()) -> ok.
delete(Id) ->
    drop_sessions(Id),
    ok = lg_limits:purge({user, Id}),
    lg_db:delete(lg_user, Id).

-spec get(binary()) -> {ok, #lg_user{}} | not_found.
get(Id) ->
    lg_db:read(lg_user, Id).

-spec list() -> [#lg_user{}].
list() ->
    lists:keysort(#lg_user.created_at, lg_db:all(lg_user)).

-spec to_map(#lg_user{}) -> map().
to_map(#lg_user{id = Id, username = U, role = R, enabled = E, created_at = C}) ->
    #{<<"id">> => Id, <<"username">> => U, <<"role">> => atom_to_binary(R),
      <<"enabled">> => E, <<"created_at">> => C}.

%%====================================================================
%% 会话
%%====================================================================

-spec login(binary(), binary()) -> {ok, binary(), #lg_user{}} | {error, invalid_credentials}.
login(Username, Password) ->
    login(Username, Password, undefined).

%% Peer 是 inet:ip_address()；测试或内部调用可传 undefined 跳过登录限流。
-spec login(binary(), binary(), inet:ip_address() | undefined) ->
          {ok, binary(), #lg_user{}} | {error, invalid_credentials | {rate_limited, pos_integer()}}.
login(Username, Password, Peer) when is_binary(Username), is_binary(Password) ->
    case lg_login_guard:check(Username, Peer) of
        {error, RetryAfterS} -> {error, {rate_limited, RetryAfterS}};
        ok -> guarded_login(Username, Password, Peer)
    end;
login(_, _, _) ->
    {error, invalid_credentials}.

guarded_login(Username, Password, Peer) ->
    case lg_db:index_read(lg_user, Username, username) of
        [#lg_user{enabled = true, password_hash = H} = U] ->
            case lg_crypto:verify_password(Password, H) of
                true ->
                    ok = lg_login_guard:success(Username, Peer),
                    Token = lg_crypto:random_token(<<"lgs-">>),
                    ok = lg_db:write(#lg_session{hash = lg_crypto:hash_token(Token),
                                                 user_id = U#lg_user.id,
                                                 expires_at = lg_time:now_ms()
                                                     + lg_config:get(session_ttl_ms)}),
                    {ok, Token, U};
                false ->
                    ok = lg_login_guard:failure(Username, Peer),
                    {error, invalid_credentials}
            end;
        _ ->
            %% 用户不存在也做一次哈希，避免通过响应时间探测用户名
            _ = lg_crypto:verify_password(Password, dummy_hash()),
            ok = lg_login_guard:failure(Username, Peer),
            {error, invalid_credentials}
    end.

-spec session(binary()) -> {ok, #lg_user{}} | {error, invalid_session}.
session(Token) when is_binary(Token) ->
    Hash = lg_crypto:hash_token(Token),
    case lg_db:read(lg_session, Hash) of
        {ok, #lg_session{user_id = Uid, expires_at = Exp}} ->
            case Exp > lg_time:now_ms() of
                true ->
                    case lg_db:read(lg_user, Uid) of
                        {ok, #lg_user{enabled = true} = U} -> {ok, U};
                        _ -> {error, invalid_session}
                    end;
                false ->
                    lg_db:delete(lg_session, Hash),
                    {error, invalid_session}
            end;
        not_found ->
            {error, invalid_session}
    end;
session(_) ->
    {error, invalid_session}.

-spec logout(binary()) -> ok.
logout(Token) ->
    lg_db:delete(lg_session, lg_crypto:hash_token(Token)).

%% @doc 没有任何用户时创建管理员 admin：密码取 LITEGATE_ADMIN_PASSWORD，未设置则随机生成并写日志。
-spec ensure_admin() -> ok.
ensure_admin() ->
    case lg_db:all(lg_user) of
        [] ->
            {Password, Generated} = case os:getenv("LITEGATE_ADMIN_PASSWORD") of
                                        V when is_list(V), length(V) >= ?MIN_PASSWORD ->
                                            {list_to_binary(V), false};
                                        _ ->
                                            {binary:part(lg_crypto:random_token(<<>>), 0, 16), true}
                                    end,
            {ok, _} = create(#{<<"username">> => <<"admin">>, <<"password">> => Password,
                               <<"role">> => <<"admin">>}),
            case Generated of
                true -> logger:notice("created initial admin user: admin / ~s  (change it after login)",
                                      [Password]);
                false -> logger:notice("created initial admin user: admin")
            end;
        _ ->
            ok
    end.

%%====================================================================
%% 内部函数
%%====================================================================

drop_sessions(UserId) ->
    [lg_db:delete(lg_session, H)
     || #lg_session{hash = H} <- lg_db:index_read(lg_session, UserId, user_id)],
    true.

valid_username(U) ->
    re:run(U, "^[A-Za-z0-9_.@-]{2,64}$") =/= nomatch.

valid_password(P) ->
    byte_size(P) >= ?MIN_PASSWORD andalso byte_size(P) =< 256.

role(<<"admin">>) -> {ok, admin};
role(<<"user">>) -> {ok, user};
role(_) -> error.

dummy_hash() ->
    case persistent_term:get({?MODULE, dummy}, undefined) of
        undefined ->
            H = lg_crypto:hash_password(<<"dummy-password">>),
            persistent_term:put({?MODULE, dummy}, H),
            H;
        H ->
            H
    end.
