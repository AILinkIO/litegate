%% @doc 配置导入导出：凭证、路由、网关 Key、限额、预算、模型目录覆盖、运行参数、用户、告警渠道与规则。
%%
%% 上游 Key 与告警渠道地址 / 签名密钥用口令派生密钥（PBKDF2-HMAC-SHA256 + 随机盐，AES-256-GCM）重新加密，
%% 文件不含明文，且可导入到主密钥不同的机器。check 字段加密一个固定串，导入时用于校验口令。
%% 不导出：交互数据、登录会话、models.dev 目录。
%%
%% 导入在一个 mnesia 事务中完成：凭证 → 路由（先不含回退）→ 回退 → 其余；dry_run 走同一路径，
%% 最后 abort 返回统计，保证预览与实际导入的校验一致。
-module(lg_config_io).

-include_lib("lg_core/include/lg_core.hrl").

-export([export/1, import/4]).

-define(FORMAT, <<"litegate-config">>).
-define(VERSION, 1).
-define(ITER, 200000).
-define(AAD, <<"litegate-export">>).
-define(CHECK, <<"litegate-config-check">>).
-define(MIN_PASSPHRASE, 8).

-type mode() :: merge | replace.

%%====================================================================
%% 导出
%%====================================================================

-spec export(binary()) -> {ok, map()} | {error, term()}.
export(Pass) when is_binary(Pass), byte_size(Pass) >= ?MIN_PASSPHRASE ->
    Salt = crypto:strong_rand_bytes(16),
    Key = derive(Pass, Salt, ?ITER),
    try
        {ok, #{<<"format">> => ?FORMAT,
               <<"version">> => ?VERSION,
               <<"exported_at">> => lg_time:now_ms(),
               <<"kdf">> => #{<<"alg">> => <<"pbkdf2-sha256">>, <<"iter">> => ?ITER,
                              <<"salt">> => base64:encode(Salt)},
               <<"check">> => seal(Key, ?CHECK),
               <<"credentials">> => [credential_out(C, Key) || C <- lg_credentials:list()],
               <<"routes">> => [lg_routes:to_map(R) || R <- lg_routes:list()],
               <<"api_keys">> => [api_key_out(K) || K <- lg_api_keys:list()],
               <<"limits">> => [lg_limits:limit_to_map(L) || L <- lg_limits:list_limits()],
               <<"budgets">> => [lg_limits:budget_to_map(B) || B <- lg_limits:list_budgets()],
               <<"model_overlays">> => [overlay_out(O) || O <- lg_db:all(lg_model_overlay)],
               <<"settings">> => [#{<<"key">> => atom_to_binary(K), <<"value">> => V}
                                  || #lg_setting{key = K, value = V} <- lg_db:all(lg_setting)],
               <<"users">> => [user_out(U) || U <- lg_users:list()],
               <<"alert_channels">> => [channel_out(C, Key) || C <- lg_alerts:channels()],
               <<"alert_rules">> => [lg_alerts:rule_to_map(R) || R <- lg_alerts:rules()],
               <<"middleware">> => [lg_middlewares:to_map(M) || M <- lg_middlewares:list()]}}
    catch
        throw:{credential_key, Id} -> {error, {undecryptable_credential, Id}}
    end;
export(_) ->
    {error, {invalid, <<"passphrase">>}}.

credential_out(#lg_credential{id = Id, api_key_enc = Enc} = C, Key) ->
    Plain = case Enc of
                undefined -> null;
                _ -> case lg_crypto:decrypt(Enc) of
                         {ok, P} -> seal(Key, P);
                         {error, _} -> throw({credential_key, Id})
                     end
            end,
    (maps:remove(<<"api_key_hint">>, lg_credentials:to_map(C)))#{<<"api_key">> => Plain}.

channel_out(#lg_channel{id = Id, url_enc = U, secret_enc = S} = C, Key) ->
    Reseal = fun(undefined) -> null;
                (Enc) -> case lg_crypto:decrypt(Enc) of
                             {ok, P} -> seal(Key, P);
                             {error, _} -> throw({credential_key, Id})
                         end
             end,
    (maps:without([<<"url_hint">>, <<"has_secret">>], lg_alerts:channel_to_map(C)))#{
      <<"url">> => Reseal(U), <<"secret">> => Reseal(S)}.

api_key_out(#lg_api_key{hash = H} = K) ->
    (lg_api_keys:to_map(K))#{<<"hash">> => H}.

overlay_out(#lg_model_overlay{key = {P, M}, info = I, created_at = C, updated_at = U}) ->
    #{<<"provider">> => P, <<"model">> => M, <<"info">> => I, <<"created_at">> => C, <<"updated_at">> => U}.

user_out(#lg_user{password_hash = H} = U) ->
    (lg_users:to_map(U))#{<<"password_hash">> => H}.

%%====================================================================
%% 导入
%%====================================================================

%% @doc 导入配置。返回每类对象的 new / overwritten / deleted 数量（dry_run 时不写入）。
-spec import(map(), binary(), mode(), boolean()) -> {ok, map()} | {error, term()}.
import(#{<<"format">> := ?FORMAT, <<"version">> := ?VERSION,
         <<"kdf">> := #{<<"salt">> := Salt64, <<"iter">> := Iter}, <<"check">> := Check} = Data,
       Pass, Mode, DryRun) when is_binary(Pass), (Mode =:= merge orelse Mode =:= replace) ->
    Key = derive(Pass, base64:decode(Salt64), Iter),
    case open(Key, Check) of
        {ok, ?CHECK} ->
            Tx = fun() ->
                         Stats = apply_all(Data, Key, Mode),
                         case DryRun of
                             true -> mnesia:abort({dry_run, Stats});
                             false -> Stats
                         end
                 end,
            case lg_db:transaction(Tx) of
                {ok, Stats} -> lg_cooldown:clear(), ok = lg_middleware:reload(), {ok, Stats};
                {error, {dry_run, Stats}} -> {ok, Stats};
                {error, _} = Err -> Err
            end;
        _ ->
            {error, bad_passphrase}
    end;
import(#{<<"format">> := ?FORMAT, <<"version">> := V}, _, _, _) when V =/= ?VERSION ->
    {error, {unsupported_version, V}};
import(_, _, _, _) ->
    {error, invalid_format}.

apply_all(Data, Key, Mode) ->
    L = fun(K) -> case maps:get(K, Data, []) of X when is_list(X) -> X; _ -> mnesia:abort({invalid, K}) end end,
    Users = L(<<"users">>),
    %% 替换模式：清空配置表；导入数据没有用户时保留现有用户（避免开启登录的实例被锁在外面）
    Deleted = case Mode of
                  replace -> clear([lg_credential, lg_route, lg_route_alias, lg_api_key, lg_limit, lg_budget,
                                    lg_model_overlay, lg_setting, lg_channel, lg_alert_rule, lg_middleware]
                                   ++ [lg_user || Users =/= []]);
                  merge -> #{}
              end,
    Creds = put_all(lg_credential, [credential_in(C, Key) || C <- L(<<"credentials">>)]),
    RouteMaps = L(<<"routes">>),
    Routes = put_all(lg_route, [route_in(R, false) || R <- RouteMaps]),
    %% 所有路由写入后再补回退（回退可引用任意导入的路由）
    _ = [mnesia:write(route_in(R, true)) || R <- RouteMaps],
    ok = lg_routes:check_graph_tx(),
    Keys = put_all(lg_api_key, [api_key_in(K) || K <- L(<<"api_keys">>)]),
    Limits = put_all(lg_limit, [limit_in(X) || X <- L(<<"limits">>)]),
    Budgets = put_all(lg_budget, [budget_in(X) || X <- L(<<"budgets">>)]),
    Overlays = put_all(lg_model_overlay, [overlay_in(X) || X <- L(<<"model_overlays">>)]),
    Settings = put_all(lg_setting, [S || X <- L(<<"settings">>), S <- setting_in(X)]),
    UsersN = put_all(lg_user, [user_in(U) || U <- Users]),
    Channels = put_all(lg_channel, [channel_in(C, Key) || C <- L(<<"alert_channels">>)]),
    Rules = put_all(lg_alert_rule, [rule_in(R) || R <- L(<<"alert_rules">>)]),
    %% 旧版导出文件没有中间件这一项
    Mws = put_all(lg_middleware, [middleware_in(M) || M <- L(<<"middleware">>)]),
    maps:map(fun(T, S) -> S#{deleted => maps:get(T, Deleted, 0)} end,
             #{credentials => Creds, routes => Routes, api_keys => Keys, limits => Limits,
               budgets => Budgets, model_overlays => Overlays, settings => Settings, users => UsersN,
               alert_channels => Channels, alert_rules => Rules, middleware => Mws}).

clear(Tabs) ->
    maps:from_list([{name_of(T), begin
                                     Keys = mnesia:all_keys(T),
                                     [mnesia:delete({T, K}) || K <- Keys],
                                     length(Keys)
                                 end} || T <- Tabs]).

name_of(lg_credential) -> credentials;
name_of(lg_route) -> routes;
name_of(lg_route_alias) -> route_aliases;
name_of(lg_api_key) -> api_keys;
name_of(lg_limit) -> limits;
name_of(lg_budget) -> budgets;
name_of(lg_model_overlay) -> model_overlays;
name_of(lg_setting) -> settings;
name_of(lg_user) -> users;
name_of(lg_channel) -> alert_channels;
name_of(lg_alert_rule) -> alert_rules;
name_of(lg_middleware) -> middleware.

%% 写入并统计新增 / 覆盖
put_all(Tab, Recs) ->
    lists:foldl(fun(R, #{new := N, overwritten := O} = Acc) ->
                        Exists = mnesia:read(Tab, element(2, R)) =/= [],
                        ok = mnesia:write(R),
                        case Exists of
                            true -> Acc#{overwritten => O + 1};
                            false -> Acc#{new => N + 1}
                        end
                end, #{new => 0, overwritten => 0}, Recs).

credential_in(#{<<"id">> := Id, <<"name">> := N, <<"protocol">> := P, <<"base_url">> := U} = C, Key)
  when is_binary(Id), is_binary(N), is_binary(U) ->
    Enc = case maps:get(<<"api_key">>, C, null) of
              null -> undefined;
              Sealed -> case open(Key, Sealed) of
                            {ok, Plain} -> lg_crypto:encrypt(Plain);
                            error -> mnesia:abort({undecryptable_credential, Id})
                        end
          end,
    Opts = case lg_options:merge(lg_options:credential_spec(), maps:get(<<"options">>, C, #{}), #{}) of
               {ok, O} -> O;
               {error, E} -> mnesia:abort(E)
           end,
    #lg_credential{id = Id, name = N, protocol = protocol(P), base_url = U, api_key_enc = Enc,
                   headers = [{K, V} || K := V <- maps:get(<<"headers">>, C, #{}), is_binary(V)],
                   provider = undef(maps:get(<<"provider">>, C, null)), options = Opts,
                   enabled = maps:get(<<"enabled">>, C, true) =/= false,
                   created_at = int(maps:get(<<"created_at">>, C, 0)),
                   updated_at = int(maps:get(<<"updated_at">>, C, 0))};
credential_in(_, _) ->
    mnesia:abort({invalid, <<"credentials">>}).

%% WithFallbacks =:= false：第一遍不写回退，避免引用尚未导入的路由
route_in(#{<<"name">> := N} = R, WithFallbacks) when is_binary(N) ->
    P0 = maps:with([<<"targets">>, <<"access">>, <<"enabled">>, <<"options">>, <<"aliases">>], R),
    P = case WithFallbacks of
            true -> P0#{<<"fallbacks">> => maps:get(<<"fallbacks">>, R, [])};
            false -> P0
        end,
    %% 第一遍不检查嵌套目标引用（被引用的路由可能还没导入），第二遍完整校验
    lg_routes:build_tx(P, #lg_route{name = N, created_at = int(maps:get(<<"created_at">>, R, 0)),
                                    updated_at = int(maps:get(<<"updated_at">>, R, 0))},
                       #{check_refs => WithFallbacks});
route_in(_, _) ->
    mnesia:abort({invalid, <<"routes">>}).

api_key_in(#{<<"id">> := Id, <<"hash">> := H, <<"prefix">> := Pf, <<"name">> := N} = K)
  when is_binary(Id), is_binary(H), is_binary(N) ->
    #lg_api_key{id = Id, hash = H, prefix = Pf, name = N,
                user_id = undef(maps:get(<<"user_id">>, K, null)),
                allowed_routes = case maps:get(<<"allowed_routes">>, K, <<"all">>) of
                                     <<"all">> -> all;
                                     L when is_list(L) -> L
                                 end,
                max_tokens = undef(maps:get(<<"max_tokens">>, K, null)),
                enabled = maps:get(<<"enabled">>, K, true) =/= false,
                expires_at = undef(maps:get(<<"expires_at">>, K, null)),
                tags = lg_tags:normalize(maps:get(<<"tags">>, K, [])),
                options = case lg_options:merge(lg_options:key_spec(), maps:get(<<"options">>, K, #{}), #{}) of
                              {ok, O} -> O;
                              {error, _} -> mnesia:abort({invalid, <<"api_keys">>})
                          end,
                created_at = int(maps:get(<<"created_at">>, K, 0))};
api_key_in(_) ->
    mnesia:abort({invalid, <<"api_keys">>}).

limit_in(#{<<"scope">> := S} = L) ->
    #lg_limit{scope = scope(S), rpm = undef(maps:get(<<"rpm">>, L, null)),
              tpm = undef(maps:get(<<"tpm">>, L, null)),
              max_parallel = undef(maps:get(<<"max_parallel">>, L, null)),
              updated_at = int(maps:get(<<"updated_at">>, L, 0))};
limit_in(_) ->
    mnesia:abort({invalid, <<"limits">>}).

budget_in(#{<<"scope">> := S, <<"period">> := P, <<"max_usd">> := M} = B) when is_number(M) ->
    Period = case P of <<"day">> -> day; <<"week">> -> week; <<"month">> -> month;
                 _ -> mnesia:abort({invalid, <<"budgets">>}) end,
    #lg_budget{scope = scope(S), period = Period, max_usd = M,
               updated_at = int(maps:get(<<"updated_at">>, B, 0))};
budget_in(_) ->
    mnesia:abort({invalid, <<"budgets">>}).

overlay_in(#{<<"provider">> := P, <<"model">> := M, <<"info">> := I} = O)
  when is_binary(P), is_binary(M), is_map(I) ->
    #lg_model_overlay{key = {P, M}, provider = P, info = I,
                      created_at = int(maps:get(<<"created_at">>, O, 0)),
                      updated_at = int(maps:get(<<"updated_at">>, O, 0))};
overlay_in(_) ->
    mnesia:abort({invalid, <<"model_overlays">>}).

%% 只接受当前版本已知的运行参数（未知键跳过，便于跨版本迁移）
setting_in(#{<<"key">> := K, <<"value">> := V}) when is_binary(K) ->
    Known = [A || A <- maps:keys(lg_config:defaults()), atom_to_binary(A) =:= K],
    [#lg_setting{key = A, value = V, updated_at = lg_time:now_ms()} || A <- Known];
setting_in(_) ->
    [].

user_in(#{<<"id">> := Id, <<"username">> := N, <<"password_hash">> := H, <<"role">> := R} = U)
  when is_binary(Id), is_binary(N), is_binary(H) ->
    #lg_user{id = Id, username = N, password_hash = H,
             role = case R of <<"admin">> -> admin; _ -> user end,
             enabled = maps:get(<<"enabled">>, U, true) =/= false,
             created_at = int(maps:get(<<"created_at">>, U, 0))};
user_in(_) ->
    mnesia:abort({invalid, <<"users">>}).

channel_in(#{<<"id">> := Id, <<"name">> := N, <<"type">> := T, <<"url">> := U} = C, Key)
  when is_binary(Id), is_binary(N), is_binary(U) ->
    Open = fun(null) -> undefined;
              (Sealed) -> case open(Key, Sealed) of
                              {ok, Plain} -> lg_crypto:encrypt(Plain);
                              error -> mnesia:abort({undecryptable_credential, Id})
                          end
           end,
    Type = case T of
               <<"webhook">> -> webhook; <<"feishu">> -> feishu; <<"dingtalk">> -> dingtalk; <<"wecom">> -> wecom;
               _ -> mnesia:abort({invalid, <<"alert_channels">>})
           end,
    #lg_channel{id = Id, name = N, type = Type, url_enc = Open(U), secret_enc = Open(maps:get(<<"secret">>, C, null)),
                enabled = maps:get(<<"enabled">>, C, true) =/= false,
                created_at = int(maps:get(<<"created_at">>, C, 0)), updated_at = int(maps:get(<<"updated_at">>, C, 0))};
channel_in(_, _) ->
    mnesia:abort({invalid, <<"alert_channels">>}).

rule_in(#{<<"id">> := Id, <<"event">> := E} = R) when is_binary(Id) ->
    Event = case [X || X <- lg_alerts:events(), atom_to_binary(X) =:= E] of
                [X] -> X;
                [] -> mnesia:abort({invalid, <<"alert_rules">>})
            end,
    #lg_alert_rule{id = Id, event = Event, threshold = undef(maps:get(<<"threshold">>, R, null)),
                   channels = [C || C <- maps:get(<<"channels">>, R, []), is_binary(C)],
                   enabled = maps:get(<<"enabled">>, R, true) =/= false,
                   created_at = int(maps:get(<<"created_at">>, R, 0)), updated_at = int(maps:get(<<"updated_at">>, R, 0))};
rule_in(_) ->
    mnesia:abort({invalid, <<"alert_rules">>}).

middleware_in(#{<<"id">> := Id, <<"name">> := N, <<"impl">> := I} = M) when is_binary(Id), is_binary(N), is_binary(I) ->
    maps:is_key(I, lg_middleware:impls()) orelse mnesia:abort({invalid, <<"middleware">>}),
    #lg_middleware{id = Id, name = N, impl = I,
                   options = case maps:get(<<"options">>, M, #{}) of O when is_map(O) -> O; _ -> #{} end,
                   routes = case maps:get(<<"routes">>, M, <<"all">>) of
                                <<"all">> -> all;
                                Rs when is_list(Rs) -> [R || R <- Rs, is_binary(R)];
                                _ -> mnesia:abort({invalid, <<"middleware">>})
                            end,
                   position = case maps:get(<<"position">>, M, 0) of P when is_integer(P) -> P; _ -> 0 end,
                   enabled = maps:get(<<"enabled">>, M, true) =/= false,
                   created_at = int(maps:get(<<"created_at">>, M, 0)), updated_at = int(maps:get(<<"updated_at">>, M, 0))};
middleware_in(_) ->
    mnesia:abort({invalid, <<"middleware">>}).

scope(Map) ->
    case lg_limits:scope_from_map(Map) of
        {ok, S} -> S;
        {error, E} -> mnesia:abort(E)
    end.

protocol(<<"openai">>) -> openai;
protocol(<<"anthropic">>) -> anthropic;
protocol(_) -> mnesia:abort({invalid, <<"protocol">>}).

undef(null) -> undefined;
undef(V) -> V.

int(N) when is_integer(N) -> N;
int(_) -> 0.

%%====================================================================
%% 口令加密
%%====================================================================

derive(Pass, Salt, Iter) ->
    crypto:pbkdf2_hmac(sha256, Pass, Salt, Iter, 32).

seal(Key, Plain) ->
    IV = crypto:strong_rand_bytes(12),
    {C, Tag} = crypto:crypto_one_time_aead(aes_256_gcm, Key, IV, Plain, ?AAD, 16, true),
    base64:encode(<<IV/binary, Tag/binary, C/binary>>).

open(Key, Sealed) when is_binary(Sealed) ->
    try base64:decode(Sealed) of
        <<IV:12/binary, Tag:16/binary, C/binary>> ->
            case crypto:crypto_one_time_aead(aes_256_gcm, Key, IV, C, ?AAD, Tag, false) of
                error -> error;
                Plain -> {ok, Plain}
            end;
        _ -> error
    catch
        error:_ -> error
    end;
open(_, _) ->
    error.
