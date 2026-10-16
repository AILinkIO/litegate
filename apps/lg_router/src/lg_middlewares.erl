%% @doc 网关中间件配置（mnesia lg_middleware）：增删改查，修改后重建 lg_middleware 的调用链缓存。
%%
%% 参数（JSON）：name、impl（lg_middleware:impls/0 中的名称）、options（JSON 对象，由实现解释）、
%% routes（"all" | [路由名]）、position（整数，越小越先运行）、enabled
-module(lg_middlewares).

-include_lib("lg_core/include/lg_core.hrl").

-export([create/1, update/2, delete/1, get/1, list/0, to_map/1]).

-spec create(map()) -> {ok, #lg_middleware{}} | {error, term()}.
create(P) ->
    Now = lg_time:now_ms(),
    Base = #lg_middleware{id = lg_id:new(<<"mw">>), name = <<>>, impl = <<>>, created_at = Now, updated_at = Now},
    save(P, Base, create).

-spec update(binary(), map()) -> {ok, #lg_middleware{}} | {error, term()}.
update(Id, P) ->
    case ?MODULE:get(Id) of
        {ok, M} -> save(maps:without([<<"impl">>], P), M#lg_middleware{updated_at = lg_time:now_ms()}, update);
        not_found -> {error, not_found}
    end.

-spec delete(binary()) -> ok | {error, not_found}.
delete(Id) ->
    case ?MODULE:get(Id) of
        {ok, _} ->
            ok = lg_db:delete(lg_middleware, Id),
            lg_middleware:reload();
        not_found -> {error, not_found}
    end.

-spec get(binary()) -> {ok, #lg_middleware{}} | not_found.
get(Id) ->
    lg_db:read(lg_middleware, Id).

-spec list() -> [#lg_middleware{}].
list() ->
    lists:sort(fun(#lg_middleware{position = A, name = NA}, #lg_middleware{position = B, name = NB}) -> {A, NA} =< {B, NB} end,
               lg_db:all(lg_middleware)).

-spec to_map(#lg_middleware{}) -> map().
to_map(#lg_middleware{id = Id, name = N, impl = I, options = O, routes = Rs, position = P, enabled = E,
                      created_at = C, updated_at = U}) ->
    #{<<"id">> => Id, <<"name">> => N, <<"impl">> => I, <<"options">> => O,
      <<"routes">> => case Rs of all -> <<"all">>; L -> L end,
      <<"position">> => P, <<"enabled">> => E, <<"created_at">> => C, <<"updated_at">> => U}.

save(P, M0, Mode) ->
    try
        M1 = field(<<"name">>, P, Mode, M0, fun(V) when is_binary(V), V =/= <<>>, byte_size(V) =< 64 -> M0#lg_middleware{name = V} end),
        M2 = field(<<"impl">>, P, Mode, M1,
                   fun(V) when is_binary(V) ->
                           maps:is_key(V, lg_middleware:impls()) orelse throw({invalid, <<"impl">>}),
                           M1#lg_middleware{impl = V}
                   end),
        M3 = optional(<<"options">>, P, M2, fun(V) when is_map(V) -> M2#lg_middleware{options = V} end),
        M4 = optional(<<"routes">>, P, M3,
                      fun(<<"all">>) -> M3#lg_middleware{routes = all};
                         (L) when is_list(L) ->
                              lists:all(fun is_binary/1, L) orelse throw({invalid, <<"routes">>}),
                              M3#lg_middleware{routes = lists:usort(L)}
                      end),
        M5 = optional(<<"position">>, P, M4, fun(V) when is_integer(V) -> M4#lg_middleware{position = V} end),
        M6 = optional(<<"enabled">>, P, M5, fun(V) when is_boolean(V) -> M5#lg_middleware{enabled = V} end),
        %% 让实现校验自己的配置（可选回调 validate/1）
        Mod = maps:get(M6#lg_middleware.impl, lg_middleware:impls()),
        _ = code:ensure_loaded(Mod),
        case erlang:function_exported(Mod, validate, 1) andalso Mod:validate(M6#lg_middleware.options) of
            {error, Why} when is_binary(Why) -> throw({invalid_options, Why});
            _ -> ok
        end,
        ok = lg_db:write(M6),
        ok = lg_middleware:reload(),
        {ok, M6}
    catch
        throw:{invalid, _} = E -> {error, E};
        throw:{missing, _} = E -> {error, E};
        throw:{invalid_options, _} = E -> {error, E}
    end.

field(K, P, Mode, M, F) ->
    case maps:find(K, P) of
        {ok, V} -> try F(V) catch error:function_clause -> throw({invalid, K}) end;
        error when Mode =:= create -> throw({missing, K});
        error -> M
    end.

optional(K, P, M, F) ->
    case maps:find(K, P) of
        {ok, V} -> try F(V) catch error:function_clause -> throw({invalid, K}) end;
        error -> M
    end.
