%% @doc 网关 API Key：只存 SHA-256 哈希，明文仅在创建时返回一次。
-module(lg_api_keys).

-include_lib("lg_core/include/lg_core.hrl").

-export([create/1, authenticate/1, update/2, delete/1, get/1, list/0, list/1, to_map/1]).

-define(PREFIX, <<"lgk-">>).

%% @doc Params：name, user_id?, allowed_routes?（"all" | [Route]）, max_tokens?, expires_at?, tags?（默认请求标签）,
%% options?（扩展选项，见 lg_options:key_spec/0，部分更新）
-spec create(map()) -> {ok, binary(), #lg_api_key{}} | {error, term()}.
create(Params) ->
    Plain = lg_crypto:random_token(?PREFIX),
    Base = #lg_api_key{id = lg_id:new(<<"key">>), name = <<>>,
                       hash = lg_crypto:hash_token(Plain),
                       prefix = binary:part(Plain, 0, 12),
                       created_at = lg_time:now_ms()},
    case apply_params(Params, Base, create) of
        {ok, Rec} -> ok = lg_db:write(Rec), {ok, Plain, Rec};
        {error, _} = Err -> Err
    end.

-spec authenticate(binary()) -> {ok, #lg_api_key{}} | {error, invalid_key | disabled | expired}.
authenticate(Plain) when is_binary(Plain) ->
    case lg_db:index_read(lg_api_key, lg_crypto:hash_token(Plain), hash) of
        [#lg_api_key{enabled = false}] -> {error, disabled};
        [#lg_api_key{expires_at = Exp} = K] ->
            case Exp =:= undefined orelse Exp > lg_time:now_ms() of
                true -> {ok, K};
                false -> {error, expired}
            end;
        [] -> {error, invalid_key}
    end;
authenticate(_) ->
    {error, invalid_key}.

-spec update(binary(), map()) -> {ok, #lg_api_key{}} | {error, term()}.
update(Id, Params) ->
    case lg_db:read(lg_api_key, Id) of
        {ok, Old} ->
            case apply_params(Params, Old, update) of
                {ok, Rec} -> ok = lg_db:write(Rec), {ok, Rec};
                {error, _} = Err -> Err
            end;
        not_found ->
            {error, not_found}
    end.

-spec delete(binary()) -> ok.
delete(Id) ->
    ok = lg_limits:purge({key, Id}),
    lg_db:delete(lg_api_key, Id).

-spec get(binary()) -> {ok, #lg_api_key{}} | not_found.
get(Id) ->
    lg_db:read(lg_api_key, Id).

-spec list() -> [#lg_api_key{}].
list() ->
    lists:keysort(#lg_api_key.created_at, lg_db:all(lg_api_key)).

%% @doc 某用户的 Key。
-spec list(binary()) -> [#lg_api_key{}].
list(UserId) ->
    lists:keysort(#lg_api_key.created_at, lg_db:index_read(lg_api_key, UserId, user_id)).

-spec to_map(#lg_api_key{}) -> map().
to_map(#lg_api_key{id = Id, prefix = P, name = N, user_id = U, allowed_routes = A,
                   max_tokens = M, enabled = E, expires_at = X, tags = T, options = O, created_at = C}) ->
    #{<<"id">> => Id, <<"prefix">> => P, <<"name">> => N, <<"user_id">> => null_if(U),
      <<"allowed_routes">> => case A of all -> <<"all">>; L -> L end,
      <<"max_tokens">> => null_if(M), <<"enabled">> => E, <<"expires_at">> => null_if(X),
      <<"tags">> => T, <<"options">> => lg_options:to_json(O), <<"created_at">> => C}.

%%====================================================================
%% 内部函数
%%====================================================================

apply_params(P, Rec0, Mode) ->
    Steps = [{<<"name">>, required,
              fun(V, R) when is_binary(V), V =/= <<>> -> R#lg_api_key{name = V} end},
             {<<"user_id">>, optional,
              fun(null, R) -> R#lg_api_key{user_id = undefined};
                 (V, R) when is_binary(V) -> R#lg_api_key{user_id = V} end},
             {<<"allowed_routes">>, optional,
              fun(<<"all">>, R) -> R#lg_api_key{allowed_routes = all};
                 (L, R) when is_list(L) ->
                      true = lists:all(fun is_binary/1, L),
                      R#lg_api_key{allowed_routes = lists:usort(L)} end},
             {<<"max_tokens">>, optional,
              fun(null, R) -> R#lg_api_key{max_tokens = undefined};
                 (N, R) when is_integer(N), N > 0 -> R#lg_api_key{max_tokens = N} end},
             {<<"expires_at">>, optional,
              fun(null, R) -> R#lg_api_key{expires_at = undefined};
                 (N, R) when is_integer(N), N > 0 -> R#lg_api_key{expires_at = N} end},
             {<<"enabled">>, optional,
              fun(V, R) when is_boolean(V) -> R#lg_api_key{enabled = V} end},
             {<<"tags">>, optional,
              fun(L, R) when is_list(L) ->
                      Tags = lg_tags:normalize(L),
                      length(Tags) =:= length(lists:usort(L)) orelse error(invalid),
                      R#lg_api_key{tags = Tags} end},
             {<<"options">>, optional,
              fun(V, R) ->
                      case lg_options:merge(lg_options:key_spec(), V, R#lg_api_key.options) of
                          {ok, O} -> R#lg_api_key{options = O};
                          {error, _} -> error(invalid)
                      end end}],
    try
        {ok, lists:foldl(
               fun({K, Req, F}, R) ->
                       case maps:find(K, P) of
                           {ok, V} ->
                               try F(V, R) catch error:_ -> throw({invalid, K}) end;
                           error when Req =:= required, Mode =:= create ->
                               throw({missing, K});
                           error ->
                               R
                       end
               end, Rec0, Steps)}
    catch
        throw:{_, _} = E -> {error, E}
    end.

null_if(undefined) -> null;
null_if(V) -> V.
