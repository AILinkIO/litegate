%% @doc 模型目录：L0（models.dev 同步）与 L1（用户覆盖）的合并视图。
%%
%% 模型属性沿用 models.dev 的 JSON 结构（binary 键），例如
%%   #{<<"name">>, <<"limit">> => #{<<"context">>, <<"output">>},
%%     <<"cost">> => #{<<"input">>, <<"output">>, <<"cache_read">>, <<"cache_write">>}, ...}
%% L1 按字段深度合并到 L0 之上，值为 null 表示删除该字段。
%% 合并结果附加 <<"provider">>、<<"id">>、<<"source">>（synced | overridden | custom）。
-module(lg_catalog).

-include_lib("lg_core/include/lg_core.hrl").

-export([providers/0, provider/1, protocol/1,
         models/0, models/1, model/1, pricing/1,
         put_overlay/2, delete_overlay/1, overlay/1,
         deep_merge/2]).

-type model_ref() :: lg_model_ref().
-export_type([model_ref/0]).

%%====================================================================
%% 供应商
%%====================================================================

%% @doc 所有供应商：L0 ∪ 只出现在 L1 中的自定义供应商。
-spec providers() -> [map()].
providers() ->
    L0 = [provider_map(P) || P <- lg_db:all(lg_catalog_provider)],
    Known = sets:from_list([Id || #{<<"id">> := Id} <- L0]),
    Custom = lists:usort([P || #lg_model_overlay{provider = P} <- lg_db:all(lg_model_overlay),
                               not sets:is_element(P, Known)]),
    lists:sort(fun(A, B) -> maps:get(<<"id">>, A) =< maps:get(<<"id">>, B) end,
               L0 ++ [#{<<"id">> => P, <<"name">> => P, <<"source">> => <<"custom">>}
                      || P <- Custom]).

-spec provider(binary()) -> {ok, map()} | not_found.
provider(Id) ->
    case lg_db:read(lg_catalog_provider, Id) of
        {ok, P} -> {ok, provider_map(P)};
        not_found -> not_found
    end.

%% @doc 由 models.dev 的 npm 字段推断协议与默认 base_url。
-spec protocol(binary()) -> {ok, openai | anthropic, binary() | undefined} | unsupported.
protocol(ProviderId) ->
    case lg_db:read(lg_catalog_provider, ProviderId) of
        {ok, #lg_catalog_provider{npm = Npm, api = Api}} ->
            case lg_catalog_protocol:from_npm(Npm) of
                {ok, Proto, DefaultUrl} -> {ok, Proto, first_defined(Api, DefaultUrl)};
                unsupported -> unsupported
            end;
        not_found ->
            unsupported
    end.

%%====================================================================
%% 模型
%%====================================================================

-spec models() -> [map()].
models() ->
    merge_all(lg_db:all(lg_catalog_model), lg_db:all(lg_model_overlay)).

%% @doc 某供应商下的合并模型列表。
-spec models(binary()) -> [map()].
models(Provider) ->
    merge_all(lg_db:index_read(lg_catalog_model, Provider, provider),
              lg_db:index_read(lg_model_overlay, Provider, provider)).

-spec model(model_ref()) -> {ok, map()} | not_found.
model({P, M} = Ref) ->
    case {lg_db:read(lg_catalog_model, Ref), lg_db:read(lg_model_overlay, Ref)} of
        {not_found, not_found} -> not_found;
        {Base, Over} -> {ok, merged(P, M, info(Base), info(Over), source(Base, Over))}
    end.

%% @doc 每百万 token 的美元价格；缓存价缺省回退为输入价。
-spec pricing(model_ref()) ->
          {ok, #{input := number(), output := number(),
                 cache_read := number(), cache_write := number()}} | not_found.
pricing(Ref) ->
    case model(Ref) of
        {ok, #{<<"cost">> := Cost}} when is_map(Cost) ->
            In = num(maps:get(<<"input">>, Cost, 0)),
            {ok, #{input => In,
                   output => num(maps:get(<<"output">>, Cost, 0)),
                   cache_read => num(maps:get(<<"cache_read">>, Cost, In)),
                   cache_write => num(maps:get(<<"cache_write">>, Cost, In)),
                   image => num(maps:get(<<"image">>, Cost, 0)),      %% 每张图片美元
                   tts => num(maps:get(<<"tts">>, Cost, 0))}};        %% 每百万字符美元
        {ok, _} ->
            {ok, #{input => 0, output => 0, cache_read => 0, cache_write => 0}};
        not_found ->
            not_found
    end.

%%====================================================================
%% L1 用户覆盖
%%====================================================================

%% @doc 新增自定义模型或覆盖 L0 字段（整体替换该条覆盖）。
-spec put_overlay(model_ref(), map()) -> ok | {error, term()}.
put_overlay({P, M} = Ref, Info) when is_binary(P), P =/= <<>>,
                                    is_binary(M), M =/= <<>>, is_map(Info) ->
    Now = lg_time:now_ms(),
    Clean = maps:without([<<"id">>, <<"provider">>, <<"source">>], Info),
    Tx = fun() ->
                 Created = case mnesia:read(lg_model_overlay, Ref) of
                               [#lg_model_overlay{created_at = C}] -> C;
                               [] -> Now
                           end,
                 mnesia:write(#lg_model_overlay{key = Ref, provider = P, info = Clean,
                                                created_at = Created, updated_at = Now})
         end,
    case lg_db:transaction(Tx) of
        {ok, ok} -> ok;
        {error, _} = Err -> Err
    end;
put_overlay(Ref, _Info) ->
    {error, {invalid_ref, Ref}}.

-spec delete_overlay(model_ref()) -> ok.
delete_overlay(Ref) ->
    lg_db:delete(lg_model_overlay, Ref).

%% @doc 原始覆盖内容（编辑表单用）。
-spec overlay(model_ref()) -> {ok, map()} | not_found.
overlay(Ref) ->
    case lg_db:read(lg_model_overlay, Ref) of
        {ok, #lg_model_overlay{info = I}} -> {ok, I};
        not_found -> not_found
    end.

%% @doc 深度合并：Over 的值覆盖 Base，嵌套 map 递归合并，null 删除键。
-spec deep_merge(map(), map()) -> map().
deep_merge(Base, Over) ->
    maps:fold(
      fun(K, null, Acc) -> maps:remove(K, Acc);
         (K, V, Acc) when is_map(V) ->
              case maps:get(K, Acc, undefined) of
                  B when is_map(B) -> Acc#{K => deep_merge(B, V)};
                  _ -> Acc#{K => deep_merge(#{}, V)}
              end;
         (K, V, Acc) -> Acc#{K => V}
      end, Base, Over).

%%====================================================================
%% 内部函数
%%====================================================================

merge_all(Base, Over) ->
    BaseMap = maps:from_list([{K, R} || R = #lg_catalog_model{key = K} <- Base]),
    OverMap = maps:from_list([{K, R} || R = #lg_model_overlay{key = K} <- Over]),
    Keys = lists:usort(maps:keys(BaseMap) ++ maps:keys(OverMap)),
    [begin
         B = found(maps:find(K, BaseMap)),
         O = found(maps:find(K, OverMap)),
         merged(P, M, info(B), info(O), source(B, O))
     end || {P, M} = K <- Keys].

found({ok, R}) -> {ok, R};
found(error) -> not_found.

merged(P, M, BaseInfo, OverInfo, Source) ->
    (deep_merge(BaseInfo, OverInfo))#{<<"provider">> => P, <<"id">> => M,
                                      <<"source">> => Source}.

info({ok, #lg_catalog_model{info = I}}) -> I;
info({ok, #lg_model_overlay{info = I}}) -> I;
info(not_found) -> #{}.

source({ok, _}, not_found) -> <<"synced">>;
source({ok, _}, {ok, _}) -> <<"overridden">>;
source(not_found, {ok, _}) -> <<"custom">>.

provider_map(#lg_catalog_provider{id = Id, name = N, npm = Npm, api = Api,
                                  env = Env, doc = Doc, synced_at = At}) ->
    Proto = case lg_catalog_protocol:from_npm(Npm) of
                {ok, P, _} -> atom_to_binary(P);
                unsupported -> null
            end,
    #{<<"id">> => Id, <<"name">> => N, <<"npm">> => nullable(Npm),
      <<"api">> => nullable(Api), <<"env">> => Env, <<"doc">> => nullable(Doc),
      <<"protocol">> => Proto, <<"synced_at">> => At, <<"source">> => <<"synced">>}.

nullable(undefined) -> null;
nullable(V) -> V.

first_defined(undefined, B) -> B;
first_defined(A, _) -> A.

num(N) when is_number(N) -> N;
num(_) -> 0.
