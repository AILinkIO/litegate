%% @doc models.dev 同步（L0）。
%%
%% 所有同步请求串行经过本进程，避免并发覆盖；catalog_sync_interval_ms > 0 时定时同步。
%% 每次同步在一个事务内整体替换 L0：写入新数据并删除上游已下架的供应商/模型。
%% L1 覆盖表永不触碰。最近一次同步结果记在 lg_meta 的 catalog_sync。
-module(lg_catalog_sync).
-behaviour(gen_server).

-include_lib("lg_core/include/lg_core.hrl").

-export([start_link/0, sync/0, sync/1, status/0, import/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(FETCH_TIMEOUT, 60000).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc 从配置的 catalog_url 同步。
-spec sync() -> {ok, map()} | {error, term()}.
sync() ->
    sync(lg_config:get(catalog_url)).

-spec sync(binary()) -> {ok, map()} | {error, term()}.
sync(Url) ->
    gen_server:call(?MODULE, {sync, Url}, ?FETCH_TIMEOUT * 2).

%% @doc 最近一次同步结果。
-spec status() -> map().
status() ->
    case lg_db:read(lg_meta, catalog_sync) of
        {ok, #lg_meta{value = V}} -> V;
        not_found -> #{status => never}
    end.

%% @doc 直接导入 models.dev 格式的 JSON（离线环境 / 测试）。
-spec import(binary()) -> {ok, map()} | {error, term()}.
import(Json) ->
    gen_server:call(?MODULE, {import, Json}, ?FETCH_TIMEOUT).

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    schedule(),
    {ok, #{}}.

handle_call({sync, Url}, _From, State) ->
    {reply, run(Url, fun() -> fetch(Url) end), State};
handle_call({import, Json}, _From, State) ->
    {reply, run(import, fun() -> {ok, Json} end), State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(periodic, State) ->
    _ = run(lg_config:get(catalog_url), fun() -> fetch(lg_config:get(catalog_url)) end),
    schedule(),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

%%====================================================================
%% 内部函数
%%====================================================================

schedule() ->
    case lg_config:get(catalog_sync_interval_ms) of
        N when is_integer(N), N > 0 ->
            _ = erlang:send_after(N, self(), periodic),
            ok;
        _ ->
            ok
    end.

run(Source, Fetch) ->
    Start = lg_time:now_ms(),
    Result = case Fetch() of
                 {ok, Body} -> apply_json(Body, Start);
                 {error, _} = Err -> Err
             end,
    Status = case Result of
                 {ok, Stats} ->
                     logger:notice("catalog synced from ~s: ~p", [src(Source), Stats]),
                     Stats#{status => ok};
                 {error, Reason} ->
                     logger:error("catalog sync from ~s failed: ~p", [src(Source), Reason]),
                     (status())#{status => error, error => iolist_to_binary(
                                                               io_lib:format("~0p", [Reason]))}
             end,
    ok = lg_db:write(#lg_meta{key = catalog_sync,
                              value = Status#{at => Start, source => src(Source),
                                              duration_ms => lg_time:now_ms() - Start}}),
    Result.

src(import) -> <<"import">>;
src(Url) -> Url.

fetch(Url) ->
    %% 系统没有 CA 证书时 cacerts_get/0 会崩溃，转成同步失败而不是让 gen_server 崩溃（接口 500）
    try tls_opts() of
        Tls ->
            UA = [{"user-agent", binary_to_list(U)} || U <- [lg_config:get(user_agent)], is_binary(U), U =/= <<>>],
            Req = {binary_to_list(Url), [{"accept", "application/json"} | UA]},
            HttpOpts = [{timeout, ?FETCH_TIMEOUT}, {connect_timeout, 10000}, {ssl, Tls}],
            case httpc:request(get, Req, HttpOpts, [{body_format, binary}]) of
                {ok, {{_, 200, _}, _Headers, Body}} -> {ok, Body};
                {ok, {{_, Code, _}, _Headers, _Body}} -> {error, {http_status, Code}};
                {error, Reason} -> {error, Reason}
            end
    catch
        _:_ -> {error, no_cacerts}
    end.

tls_opts() ->
    [{verify, verify_peer},
     {cacerts, public_key:cacerts_get()},
     {depth, 4},
     {customize_hostname_check,
      [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}].

apply_json(Body, Now) ->
    try json:decode(Body) of
        Data when is_map(Data) -> replace_l0(normalize(Data, Now));
        _ -> {error, not_an_object}
    catch
        error:Reason -> {error, {bad_json, Reason}}
    end.

%% models.dev：#{ProviderId => #{id, name, npm, api, env, doc, models => #{ModelId => Info}}}
normalize(Data, Now) ->
    maps:fold(
      fun(Pid, P, {Ps, Ms}) when is_map(P) ->
              Prov = #lg_catalog_provider{
                        id = Pid,
                        name = bin(maps:get(<<"name">>, P, Pid), Pid),
                        npm = bin(maps:get(<<"npm">>, P, undefined), undefined),
                        api = bin(maps:get(<<"api">>, P, undefined), undefined),
                        env = [E || E <- list(maps:get(<<"env">>, P, [])), is_binary(E)],
                        doc = bin(maps:get(<<"doc">>, P, undefined), undefined),
                        synced_at = Now},
              Models = [#lg_catalog_model{key = {Pid, Mid}, provider = Pid,
                                          info = maps:remove(<<"id">>, Info),
                                          synced_at = Now}
                        || {Mid, Info} <- maps:to_list(map(maps:get(<<"models">>, P, #{}))),
                           is_map(Info)],
              {[Prov | Ps], Models ++ Ms};
         (_, _, Acc) ->
              Acc
      end, {[], []}, Data).

replace_l0({Providers, Models}) when Providers =:= [] ->
    {error, {empty_catalog, length(Models)}};
replace_l0({Providers, Models}) ->
    NewP = sets:from_list([Id || #lg_catalog_provider{id = Id} <- Providers]),
    NewM = sets:from_list([K || #lg_catalog_model{key = K} <- Models]),
    %% 只写内容变化的记录，避免每次同步重写全部模型撑大 mnesia 日志
    ChangedP = [P || P <- Providers, changed(P)],
    ChangedM = [M || M <- Models, changed(M)],
    Tx = fun() ->
                 mnesia:write_lock_table(lg_catalog_provider),
                 mnesia:write_lock_table(lg_catalog_model),
                 StaleP = [K || K <- mnesia:all_keys(lg_catalog_provider),
                                not sets:is_element(K, NewP)],
                 StaleM = [K || K <- mnesia:all_keys(lg_catalog_model),
                                not sets:is_element(K, NewM)],
                 [mnesia:delete({lg_catalog_provider, K}) || K <- StaleP],
                 [mnesia:delete({lg_catalog_model, K}) || K <- StaleM],
                 [mnesia:write(P) || P <- ChangedP],
                 [mnesia:write(M) || M <- ChangedM],
                 #{providers => length(Providers), models => length(Models),
                   changed_providers => length(ChangedP), changed_models => length(ChangedM),
                   removed_providers => length(StaleP), removed_models => length(StaleM)}
         end,
    lg_db:transaction(Tx).

%% synced_at 表示该条最后一次内容变化的时间
changed(#lg_catalog_provider{id = Id} = New) ->
    case lg_db:read(lg_catalog_provider, Id) of
        {ok, Old} -> Old#lg_catalog_provider{synced_at = 0} =/= New#lg_catalog_provider{synced_at = 0};
        not_found -> true
    end;
changed(#lg_catalog_model{key = K, info = Info}) ->
    case lg_db:read(lg_catalog_model, K) of
        {ok, #lg_catalog_model{info = Info}} -> false;
        _ -> true
    end.

bin(V, _) when is_binary(V) -> V;
bin(_, Default) -> Default.

list(L) when is_list(L) -> L;
list(_) -> [].

map(M) when is_map(M) -> M;
map(_) -> #{}.
