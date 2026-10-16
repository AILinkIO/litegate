%% @doc L2 凭证管理：上游协议、地址与加密 Key。
-module(lg_credentials).

-include_lib("lg_core/include/lg_core.hrl").

-export([create/1, from_provider/3, update/2, delete/1, get/1, list/0, to_map/1]).

%% @doc 创建凭证。Params：name, protocol, base_url, api_key?, headers?, provider?, options?, enabled?
-spec create(map()) -> {ok, #lg_credential{}} | {error, term()}.
create(Params) ->
    Now = lg_time:now_ms(),
    %% name / protocol / base_url 为占位值，create 模式下 apply_params 要求三者必填
    Base = #lg_credential{id = lg_id:new(<<"cred">>), name = <<>>, protocol = openai,
                          base_url = <<>>, created_at = Now, updated_at = Now},
    case apply_params(Params, Base, create) of
        {ok, Rec} -> ok = lg_db:write(Rec), plan_changed(undefined, Rec), {ok, Rec};
        {error, _} = Err -> Err
    end.

%% @doc 由 models.dev 供应商一键生成凭证（协议与 base_url 取自目录）。
-spec from_provider(binary(), binary() | undefined, binary() | undefined) ->
          {ok, #lg_credential{}} | {error, term()}.
from_provider(ProviderId, ApiKey, Name) ->
    case lg_catalog:protocol(ProviderId) of
        {ok, _Proto, undefined} ->
            {error, {no_base_url, ProviderId}};
        {ok, Proto, Url} ->
            create(#{<<"name">> => case Name of undefined -> ProviderId; _ -> Name end,
                     <<"protocol">> => atom_to_binary(Proto), <<"base_url">> => Url,
                     <<"api_key">> => ApiKey, <<"provider">> => ProviderId});
        unsupported ->
            {error, {unsupported_provider, ProviderId}}
    end.

%% @doc 部分更新；未给出 api_key 时保留原 Key，api_key 为 null 时清除。
-spec update(binary(), map()) -> {ok, #lg_credential{}} | {error, term()}.
update(Id, Params) ->
    case lg_db:read(lg_credential, Id) of
        {ok, Old} ->
            case apply_params(Params, Old, update) of
                {ok, Rec} ->
                    Rec1 = Rec#lg_credential{updated_at = lg_time:now_ms()},
                    ok = lg_db:write(Rec1),
                    plan_changed(Old, Rec1),
                    {ok, Rec1};
                {error, _} = Err ->
                    Err
            end;
        not_found ->
            {error, not_found}
    end.

%% @doc 被路由引用时拒绝删除。
-spec delete(binary()) -> ok | {error, term()}.
delete(Id) ->
    case [R || #lg_route{name = R, targets = Ts} <- lg_db:all(lg_route),
               lists:any(fun(#{credential := C}) -> C =:= Id; (_) -> false end, Ts)] of
        [] -> lg_db:delete(lg_credential, Id);
        Routes -> {error, {in_use, Routes}}
    end.

-spec get(binary()) -> {ok, #lg_credential{}} | not_found.
get(Id) ->
    lg_db:read(lg_credential, Id).

-spec list() -> [#lg_credential{}].
list() ->
    lists:keysort(#lg_credential.created_at, lg_db:all(lg_credential)).

%% @doc 对外展示（不含 Key，只给末 4 位提示）。
-spec to_map(#lg_credential{}) -> map().
to_map(#lg_credential{id = Id, name = N, protocol = P, base_url = U, api_key_enc = Enc,
                      headers = H, provider = Prov, options = O, enabled = E, created_at = C,
                      updated_at = Up}) ->
    #{<<"id">> => Id, <<"name">> => N, <<"protocol">> => atom_to_binary(P),
      <<"base_url">> => U, <<"api_key_hint">> => key_hint(Enc),
      <<"headers">> => maps:from_list(H),
      <<"provider">> => null_if_undefined(Prov), <<"options">> => lg_options:to_json(O),
      <<"enabled">> => E,
      <<"created_at">> => C, <<"updated_at">> => Up}.

%%====================================================================
%% 内部函数
%%====================================================================

apply_params(P, Rec0, Mode) ->
    try
        Rec1 = field(<<"name">>, P, Mode, Rec0,
                     fun(V) when is_binary(V), V =/= <<>> -> Rec0#lg_credential{name = V} end),
        Rec2 = field(<<"protocol">>, P, Mode, Rec1,
                     fun(<<"openai">>) -> Rec1#lg_credential{protocol = openai};
                        (<<"anthropic">>) -> Rec1#lg_credential{protocol = anthropic} end),
        Rec3 = field(<<"base_url">>, P, Mode, Rec2,
                     fun(V) when is_binary(V) ->
                             case uri_string:parse(V) of
                                 #{scheme := S, host := H} when (S =:= <<"http">> orelse S =:= <<"https">>),
                                                                 H =/= <<>> ->
                                     Rec2#lg_credential{base_url = V}
                             end
                     end),
        Rec4 = optional(<<"api_key">>, P, Rec3,
                        fun(null) -> Rec3#lg_credential{api_key_enc = undefined};
                           (<<>>) -> Rec3#lg_credential{api_key_enc = undefined};
                           (V) when is_binary(V) -> Rec3#lg_credential{api_key_enc = lg_crypto:encrypt(V)} end),
        Rec5 = optional(<<"headers">>, P, Rec4,
                        fun(M) when is_map(M) ->
                                Hs = [{string:lowercase(K), V} || {K, V} <- maps:to_list(M),
                                                                  is_binary(K), is_binary(V)],
                                Rec4#lg_credential{headers = Hs} end),
        Rec6 = optional(<<"provider">>, P, Rec5,
                        fun(null) -> Rec5#lg_credential{provider = undefined};
                           (V) when is_binary(V) -> Rec5#lg_credential{provider = V} end),
        Rec7 = optional(<<"enabled">>, P, Rec6,
                        fun(V) when is_boolean(V) -> Rec6#lg_credential{enabled = V} end),
        Rec8 = case maps:find(<<"options">>, P) of
                   {ok, O} ->
                       case lg_options:merge(lg_options:credential_spec(), O, Rec7#lg_credential.options) of
                           {ok, Opts} -> Rec7#lg_credential{options = Opts};
                           {error, E} -> throw(E)
                       end;
                   error -> Rec7
               end,
        {ok, Rec8}
    catch
        throw:{invalid, K} -> {error, {invalid, K}};
        throw:{missing, K} -> {error, {missing, K}}
    end.

%% 必填字段：create 时必须给出，update 时可省略
field(K, P, Mode, Rec, Fun) ->
    case maps:find(K, P) of
        {ok, V} -> safe(K, Fun, V);
        error when Mode =:= update -> Rec;
        error -> throw({missing, K})
    end.

optional(K, P, Rec, Fun) ->
    case maps:find(K, P) of
        {ok, V} -> safe(K, Fun, V);
        error -> Rec
    end.

safe(K, Fun, V) ->
    try Fun(V)
    catch error:_ -> throw({invalid, K})
    end.

%% 套餐配置、地址或 Key 变化后异步刷新额度状态（lg_plan 未运行时忽略）
plan_changed(Old, #lg_credential{id = Id} = New) ->
    Sig = fun(undefined) -> undefined;
             (#lg_credential{base_url = U, api_key_enc = K, enabled = E} = C) -> {lg_plan:plan_of(C), U, K, E}
          end,
    case lg_plan:plan_of(New) =/= undefined andalso Sig(Old) =/= Sig(New) of
        true -> gen_server:cast(lg_plan, {refresh, [Id]});
        false -> ok
    end,
    %% 余额查询同理
    BSig = fun(undefined) -> undefined;
              (#lg_credential{base_url = U, api_key_enc = K, enabled = E} = C) -> {lg_balance:balance_of(C), U, K, E}
           end,
    case lg_balance:balance_of(New) =/= undefined andalso BSig(Old) =/= BSig(New) of
        true -> gen_server:cast(lg_balance, {refresh, [Id]});
        false -> ok
    end.

key_hint(undefined) -> null;
key_hint(Enc) ->
    case lg_crypto:decrypt(Enc) of
        {ok, K} when byte_size(K) > 8 -> <<"...", (binary:part(K, byte_size(K), -4))/binary>>;
        {ok, _} -> <<"...">>;
        {error, _} -> <<"(undecryptable)">>
    end.

null_if_undefined(undefined) -> null;
null_if_undefined(V) -> V.
