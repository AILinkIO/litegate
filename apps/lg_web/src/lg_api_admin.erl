%% @doc 管理端 API 资源 handler：模型目录、凭证、路由表、上游健康、告警、订阅套餐、
%% 已学限制、网关中间件、实时视图、余额、配置导入导出/备份、存储、OTLP、运行参数。
%% 这些路径仅 admin 可访问（路径鉴权由 lg_api:authorized/2 统一完成）。
%% 请求/响应助手（body/reply/err 等）留在 lg_api，本模块经 lg_api:X/... 调用。
-module(lg_api_admin).

-include_lib("lg_core/include/lg_core.hrl").

-export([handle/4]).

%% lg_api 的路由分发进入；命中时完成回复并返回 Req（或 throw），未命中返回 nomatch 由 lg_api 继续匹配（最终 404）
-spec handle(binary(), [binary()], term(), cowboy_req:req()) -> cowboy_req:req() | nomatch.
handle(Method, Path, User, Req) ->
    handle_(Method, Path, User, Req).

%% ---- 模型目录 ----
handle_(<<"GET">>, [<<"catalog">>, <<"providers">>], _U, Req) ->
    lg_api:reply(200, lg_catalog:providers(), Req);
handle_(<<"GET">>, [<<"catalog">>, <<"models">>], _U, Req) ->
    Q = cowboy_req:parse_qs(Req),
    Models = case lg_api:qs(<<"provider">>, Q) of
                 undefined -> lg_catalog:models();
                 P -> lg_catalog:models(P)
             end,
    Filtered = [M || M <- Models, match_model(M, Q)],
    lg_api:reply(200, lg_api:page(Filtered, Q), Req);
handle_(<<"GET">>, [<<"catalog">>, <<"models">>, P, M], _U, Req) ->
    case lg_catalog:model({P, M}) of
        {ok, Model} ->
            Overlay = case lg_catalog:overlay({P, M}) of {ok, O} -> O; not_found -> null end,
            lg_api:reply(200, Model#{<<"overlay">> => Overlay}, Req);
        not_found ->
            lg_api:not_found(Req)
    end;
handle_(<<"PUT">>, [<<"catalog">>, <<"models">>, P, M], _U, Req0) ->
    {Body, Req} = lg_api:body(Req0),
    case lg_catalog:put_overlay({P, M}, Body) of
        ok -> {ok, Model} = lg_catalog:model({P, M}), lg_api:reply(200, Model, Req);
        {error, R} -> lg_api:bad_request(R, Req)
    end;
handle_(<<"DELETE">>, [<<"catalog">>, <<"models">>, P, M], _U, Req) ->
    ok = lg_catalog:delete_overlay({P, M}),
    lg_api:reply(200, #{<<"ok">> => true}, Req);
handle_(<<"GET">>, [<<"catalog">>, <<"sync">>], _U, Req) ->
    lg_api:reply(200, lg_catalog_sync:status(), Req);
handle_(<<"POST">>, [<<"catalog">>, <<"sync">>], _U, Req) ->
    case lg_catalog_sync:sync() of
        {ok, Stats} -> lg_api:reply(200, Stats, Req);
        {error, R} -> lg_api:reply(502, lg_api:err(<<"sync_failed">>, lg_api:fmt(R)), Req)
    end;
%% 导入 models.dev 格式的 api.json（离线环境）：与同步一样整体替换同步数据（L0），覆盖与自定义模型不受影响
%% 先校验结构：每个顶层值都是带 models 对象的供应商，避免误传其他 JSON（如配置导出）清空目录
handle_(<<"POST">>, [<<"catalog">>, <<"import">>], _U, Req0) ->
    {Body, Req} = lg_api:body(Req0),
    IsProvider = fun(_, #{<<"models">> := M}) when is_map(M) -> true; (_, _) -> false end,
    case map_size(Body) > 0 andalso maps:size(maps:filter(IsProvider, Body)) =:= map_size(Body) of
        false ->
            lg_api:reply(400, lg_api:err(<<"invalid_request">>,
                           <<"Not a models.dev api.json: every top-level value must be a provider with a models object">>), Req);
        true ->
            case lg_catalog_sync:import(iolist_to_binary(json:encode(Body))) of
                {ok, Stats} -> lg_api:reply(200, Stats, Req);
                {error, R} -> lg_api:reply(400, lg_api:err(<<"invalid_request">>, lg_api:fmt(R)), Req)
            end
    end;

%% ---- 凭证 ----
handle_(<<"GET">>, [<<"credentials">>], _U, Req) ->
    Plans = maps:from_list([{maps:get(credential, P), P} || P <- lg_plan:all()]),
    Balances = maps:from_list([{maps:get(credential, B), B} || B <- lg_balance:all()]),
    lg_api:reply(200, [(lg_credentials:to_map(C))#{<<"plan_status">> => lg_api:clean(maps:get(Id, Plans, null)),
                                            <<"balance_status">> => lg_api:clean(maps:get(Id, Balances, null)),
                                            <<"balance_suggest">> => lg_balance_api:suggest(C#lg_credential.base_url)}
                || #lg_credential{id = Id} = C <- lg_credentials:list()], Req);
handle_(<<"POST">>, [<<"credentials">>], _U, Req0) ->
    {Body, Req} = lg_api:body(Req0),
    lg_api:result(lg_credentials:create(Body), fun lg_credentials:to_map/1, Req);
handle_(<<"POST">>, [<<"credentials">>, <<"from-provider">>], _U, Req0) ->
    {Body, Req} = lg_api:body(Req0),
    lg_api:result(lg_credentials:from_provider(maps:get(<<"provider">>, Body, <<>>),
                                        maps:get(<<"api_key">>, Body, undefined),
                                        maps:get(<<"name">>, Body, undefined)),
           fun lg_credentials:to_map/1, Req);
handle_(<<"GET">>, [<<"credentials">>, Id], _U, Req) ->
    lg_api:found(lg_credentials:get(Id), fun lg_credentials:to_map/1, Req);
handle_(<<"PUT">>, [<<"credentials">>, Id], _U, Req0) ->
    {Body, Req} = lg_api:body(Req0),
    lg_api:result(lg_credentials:update(Id, Body), fun lg_credentials:to_map/1, Req);
handle_(<<"DELETE">>, [<<"credentials">>, Id], _U, Req) ->
    lg_api:ok_result(lg_credentials:delete(Id), Req);

%% ---- 路由表 ----
handle_(<<"GET">>, [<<"routes">>], _U, Req) ->
    Limits = lg_limits:list_limits(),
    lg_api:reply(200, [(lg_routes:to_map(R))#{<<"limit">> => lg_limits:limit_fields({route, N}),
                                       <<"key_limits">> => lg_api:key_limits(N, Limits)}
                || #lg_route{name = N} = R <- lg_routes:list()], Req);
handle_(<<"POST">>, [<<"routes">>], _U, Req0) ->
    {Body, Req} = lg_api:body(Req0),
    lg_api:result(lg_routes:create(Body), fun lg_routes:to_map/1, Req);
handle_(<<"GET">>, [<<"routes">>, Name], _U, Req) ->
    lg_api:found(lg_routes:get(Name), fun lg_routes:to_map/1, Req);
%% 路由能到达的上游及其能力（Playground 自动填参数）；Name 可为路由名、别名或通配展开名
handle_(<<"GET">>, [<<"routes">>, Name, <<"capabilities">>], _U, Req) ->
    case lg_route_caps:get(Name) of
        {ok, Caps} -> lg_api:reply(200, Caps, Req);
        not_found -> lg_api:not_found(Req)
    end;
handle_(<<"PUT">>, [<<"routes">>, Name], _U, Req0) ->
    {Body, Req} = lg_api:body(Req0),
    lg_api:result(lg_routes:update(Name, Body), fun lg_routes:to_map/1, Req);
handle_(<<"DELETE">>, [<<"routes">>, Name], _U, Req) ->
    lg_api:ok_result(lg_routes:delete(Name), Req);

%% ---- 上游健康 ----
handle_(<<"GET">>, [<<"health">>], _U, Req) ->
    lg_api:reply(200, #{<<"targets">> => [lg_api:clean(T) || T <- lg_health:snapshot()],
                 <<"probes">> => [lg_api:clean(P) || P <- lg_health:probes()],
                 <<"probe_interval_ms">> => lg_config:get(probe_interval_ms)}, Req);
handle_(<<"POST">>, [<<"health">>, <<"reset">>], _U, Req0) ->
    {Body, Req} = lg_api:body(Req0),
    case {maps:get(<<"credential">>, Body, null), maps:get(<<"upstream_model">>, Body, null)} of
        {C, M} when is_binary(C), is_binary(M) -> ok = lg_cooldown:reset({C, M});
        {null, null} -> ok = lg_cooldown:clear();
        _ -> lg_api:bad_request({invalid, <<"credential/upstream_model">>}, Req)
    end,
    lg_api:reply(200, #{<<"ok">> => true}, Req);
%% 请求体可带 credentials: [Id] 只探活指定凭证
handle_(<<"POST">>, [<<"health">>, <<"probe">>], _U, Req0) ->
    {Body, Req} = lg_api:body(Req0),
    Which = case maps:get(<<"credentials">>, Body, null) of
                L when is_list(L) -> [X || X <- L, is_binary(X)];
                _ -> all
            end,
    lg_api:reply(200, [lg_api:clean(P) || P <- lg_health:probe_now(Which)], Req);

%% ---- 告警 ----
handle_(<<"GET">>, [<<"alerts">>, <<"channels">>], _U, Req) ->
    lg_api:reply(200, [lg_alerts:channel_to_map(C) || C <- lg_alerts:channels()], Req);
handle_(<<"POST">>, [<<"alerts">>, <<"channels">>], _U, Req0) ->
    {Body, Req} = lg_api:body(Req0),
    lg_api:result(lg_alerts:create_channel(Body), fun lg_alerts:channel_to_map/1, Req);
handle_(<<"PUT">>, [<<"alerts">>, <<"channels">>, Id], _U, Req0) ->
    {Body, Req} = lg_api:body(Req0),
    lg_api:result(lg_alerts:update_channel(Id, Body), fun lg_alerts:channel_to_map/1, Req);
handle_(<<"DELETE">>, [<<"alerts">>, <<"channels">>, Id], _U, Req) ->
    case lg_alerts:delete_channel(Id) of
        ok -> lg_api:reply(200, #{<<"ok">> => true}, Req);
        {error, not_found} -> lg_api:not_found(Req)
    end;
handle_(<<"POST">>, [<<"alerts">>, <<"channels">>, Id, <<"test">>], _U, Req) ->
    case lg_alert:test_channel(Id) of
        ok -> lg_api:reply(200, #{<<"ok">> => true}, Req);
        {error, not_found} -> lg_api:not_found(Req);
        {error, Msg} -> lg_api:reply(200, #{<<"ok">> => false, <<"error">> => Msg}, Req)
    end;
handle_(<<"GET">>, [<<"alerts">>, <<"rules">>], _U, Req) ->
    lg_api:reply(200, [lg_alerts:rule_to_map(R) || R <- lg_alerts:rules()], Req);
handle_(<<"POST">>, [<<"alerts">>, <<"rules">>], _U, Req0) ->
    {Body, Req} = lg_api:body(Req0),
    lg_api:result(lg_alerts:create_rule(Body), fun lg_alerts:rule_to_map/1, Req);
handle_(<<"PUT">>, [<<"alerts">>, <<"rules">>, Id], _U, Req0) ->
    {Body, Req} = lg_api:body(Req0),
    lg_api:result(lg_alerts:update_rule(Id, Body), fun lg_alerts:rule_to_map/1, Req);
handle_(<<"DELETE">>, [<<"alerts">>, <<"rules">>, Id], _U, Req) ->
    case lg_alerts:delete_rule(Id) of
        ok -> lg_api:reply(200, #{<<"ok">> => true}, Req);
        {error, not_found} -> lg_api:not_found(Req)
    end;
handle_(<<"GET">>, [<<"alerts">>, <<"history">>], _U, Req) ->
    Limit = case lg_api:int_qs(<<"limit">>, cowboy_req:parse_qs(Req)) of
                N when is_integer(N), N > 0 -> min(N, 500);
                _ -> 100
            end,
    lg_api:reply(200, [lg_api:clean(A) || A <- lg_alert:history(Limit)], Req);

%% ---- 订阅套餐额度 ----
handle_(<<"GET">>, [<<"plans">>], _U, Req) ->
    lg_api:reply(200, #{<<"plans">> => lg_api:clean(lg_plan:all()),
                 <<"poll_interval_ms">> => lg_config:get(plan_poll_interval_ms)}, Req);
%% 请求体可带 credentials: [Id] 只刷新指定凭证
handle_(<<"POST">>, [<<"plans">>, <<"refresh">>], _U, Req0) ->
    {Body, Req} = lg_api:body(Req0),
    Which = case maps:get(<<"credentials">>, Body, null) of
                L when is_list(L) -> [X || X <- L, is_binary(X)];
                _ -> all
            end,
    %% 超时仍在查询时返回当前状态（条目带 refreshing: true），结果稍后写入
    _ = lg_plan:refresh(Which),
    lg_api:reply(200, lg_api:clean(lg_plan:all()), Req);

%% ---- 上游参数兼容（已学到的限制） ----
handle_(<<"GET">>, [<<"unfit">>], _U, Req) ->
    Creds = maps:from_list([{Id, N} || #lg_credential{id = Id, name = N} <- lg_credentials:list()]),
    lg_api:reply(200, [(lg_api:clean(U))#{credential_name => maps:get(C, Creds, C)} || #{credential := C} = U <- lg_unfit:list()], Req);
%% 请求体带 credential、upstream_model、feature 时只清除这一条，否则全部清除
handle_(<<"POST">>, [<<"unfit">>, <<"forget">>], _U, Req0) ->
    {Body, Req} = lg_api:body(Req0),
    case Body of
        #{<<"credential">> := C, <<"upstream_model">> := M, <<"feature">> := F} when is_binary(C), is_binary(M), is_binary(F) ->
            [Feat] = [X || X <- lg_unfit:features(), atom_to_binary(X) =:= F] ++ [undefined],
            Feat =/= undefined orelse lg_api:bad_request({invalid, <<"feature">>}, Req),
            ok = lg_unfit:forget({C, M, Feat});
        _ ->
            ok = lg_unfit:forget_all()
    end,
    lg_api:reply(200, #{<<"ok">> => true}, Req);

%% ---- 网关中间件 ----
handle_(<<"GET">>, [<<"middleware">>], _U, Req) ->
    Stats = lg_middleware:stats(),
    Impls = lg_middleware:impls(),
    %% 实现不存在（插件被删掉）的条目标出 missing_impl，它们不在调用链里
    lg_api:reply(200, #{<<"items">> => [(lg_middlewares:to_map(M))#{<<"stats">> => lg_api:clean(maps:get(Id, Stats, null)),
                                                             <<"missing_impl">> => not maps:is_key(I, Impls),
                                                             <<"hooks">> => lg_middleware:hooks_for(I, O)}
                                 || #lg_middleware{id = Id, impl = I, options = O} = M <- lg_middlewares:list()],
                 <<"impls">> => lg_api:clean(lg_middleware:impl_info()),
                 <<"plugin_dir">> => list_to_binary(filename:absname(lg_middleware:plugin_dir()))}, Req);
handle_(<<"POST">>, [<<"middleware">>, <<"plugins">>, <<"rescan">>], _U, Req) ->
    lg_api:reply(200, lg_api:clean(lg_middleware:rescan()), Req);
%% 试运行：{impl, options, body, format} → 调用一次 on_request
handle_(<<"POST">>, [<<"middleware">>, <<"test">>], _U, Req0) ->
    {Body, Req} = lg_api:body(Req0),
    Impl = maps:get(<<"impl">>, Body, null),
    Opts = maps:get(<<"options">>, Body, #{}),
    Sample = maps:get(<<"body">>, Body, null),
    Format = case maps:get(<<"format">>, Body, <<"openai">>) of
                 <<"openai">> -> openai; <<"anthropic">> -> anthropic; <<"responses">> -> responses;
                 _ -> lg_api:bad_request({invalid, <<"format">>}, Req)
             end,
    (is_binary(Impl) andalso is_map(Opts) andalso is_map(Sample)) orelse lg_api:bad_request({missing, <<"impl, options, body">>}, Req),
    case lg_middleware:test(Impl, Opts, #{body => Sample, format => Format}) of
        {ok, #{result := R} = Out} -> lg_api:reply(200, (lg_api:clean(maps:remove(result, Out)))#{<<"result">> => test_result(R)}, Req);
        {error, E} -> lg_api:bad_request(E, Req)
    end;
handle_(<<"POST">>, [<<"middleware">>], _U, Req0) ->
    {Body, Req} = lg_api:body(Req0),
    lg_api:result(lg_middlewares:create(Body), fun lg_middlewares:to_map/1, Req);
handle_(<<"PUT">>, [<<"middleware">>, Id], _U, Req0) ->
    {Body, Req} = lg_api:body(Req0),
    lg_api:result(lg_middlewares:update(Id, Body), fun lg_middlewares:to_map/1, Req);
handle_(<<"DELETE">>, [<<"middleware">>, Id], _U, Req) ->
    case lg_middlewares:delete(Id) of
        ok -> lg_api:reply(200, #{<<"ok">> => true}, Req);
        {error, not_found} -> lg_api:not_found(Req)
    end;

%% ---- 实时路由视图 ----
handle_(<<"GET">>, [<<"live">>, <<"state">>], _U, Req) ->
    Opts = case cowboy_req:match_qs([{route, [], undefined}], Req) of
               #{route := R} when is_binary(R), R =/= <<>> -> #{route => R};
               _ -> #{}
           end,
    lg_api:reply(200, lg_api:clean(lg_live:state(Opts)), Req);

%% ---- 按量付费 Key 的余额 ----
handle_(<<"GET">>, [<<"balances">>], _U, Req) ->
    lg_api:reply(200, #{<<"balances">> => lg_api:clean(lg_balance:all()),
                 <<"poll_interval_ms">> => lg_config:get(balance_poll_interval_ms)}, Req);
%% 请求体可带 credentials: [Id] 只刷新指定凭证
handle_(<<"POST">>, [<<"balances">>, <<"refresh">>], _U, Req0) ->
    {Body, Req} = lg_api:body(Req0),
    Which = case maps:get(<<"credentials">>, Body, null) of
                L when is_list(L) -> [X || X <- L, is_binary(X)];
                _ -> all
            end,
    _ = lg_balance:refresh(Which),
    lg_api:reply(200, lg_api:clean(lg_balance:all()), Req);

%% ---- 配置导入导出 ----
handle_(<<"POST">>, [<<"config">>, <<"export">>], _U, Req0) ->
    {Body, Req} = lg_api:body(Req0),
    case lg_config_io:export(maps:get(<<"passphrase">>, Body, null)) of
        {ok, Data} ->
            Name = iolist_to_binary(["litegate-config-",
                                     calendar:system_time_to_rfc3339(lg_time:now_ms(), [{unit, millisecond}, {offset, "Z"}]),
                                     ".json"]),
            Req1 = cowboy_req:set_resp_header(<<"content-disposition">>,
                                              <<"attachment; filename=\"", (binary:replace(Name, <<":">>, <<"-">>, [global]))/binary, "\"">>,
                                              Req),
            lg_api:reply(200, Data, Req1);
        {error, R} ->
            lg_api:bad_request(R, Req)
    end;
handle_(<<"POST">>, [<<"config">>, <<"import">>], _U, Req0) ->
    {Body, Req} = lg_api:body(Req0),
    Mode = case maps:get(<<"mode">>, Body, <<"merge">>) of
               <<"merge">> -> merge;
               <<"replace">> -> replace;
               _ -> lg_api:bad_request({invalid, <<"mode">>}, Req)
           end,
    case lg_config_io:import(maps:get(<<"data">>, Body, null), maps:get(<<"passphrase">>, Body, null),
                             Mode, maps:get(<<"dry_run">>, Body, false) =:= true) of
        {ok, Stats} -> lg_api:reply(200, Stats, Req);
        {error, R} -> lg_api:bad_request(R, Req)
    end;

%% ---- 配置备份 ----
handle_(<<"GET">>, [<<"backups">>], _U, Req) ->
    lg_api:reply(200, #{<<"backups">> => lg_backup:list(), <<"status">> => lg_backup:status(),
                 <<"enabled">> => lg_config:get(backup_enabled)}, Req);
handle_(<<"POST">>, [<<"backups">>], _U, Req) ->
    case lg_backup:run() of
        {ok, Info} -> lg_api:reply(200, Info, Req);
        {error, R} -> lg_api:bad_request(R, Req)
    end;
handle_(<<"DELETE">>, [<<"backups">>, Name], _U, Req) ->
    case lg_backup:delete(Name) of
        ok -> lg_api:reply(200, #{<<"ok">> => true}, Req);
        {error, R} -> lg_api:bad_request(R, Req)
    end;

%% ---- 数据存储 ----
handle_(<<"GET">>, [<<"store">>], _U, Req) ->
    lg_api:reply(200, #{<<"casks">> => [lg_api:clean(C) || C <- lg_store:status()],
                 <<"cleanup">> => lg_api:clean(lg_store_janitor:status())}, Req);
handle_(<<"POST">>, [<<"store">>, <<"cleanup">>], _U, Req) ->
    lg_api:reply(200, lg_api:clean(lg_store_janitor:run()), Req);

%% ---- 链路导出 ----
handle_(<<"POST">>, [<<"otlp">>, <<"test">>], _U, Req) ->
    case lg_config:get(otlp_endpoint) of
        <<>> -> lg_api:reply(400, lg_api:err(<<"invalid_request">>, <<"Set otlp_endpoint first">>), Req);
        _ ->
            case lg_otlp:test() of
                ok -> lg_api:reply(200, #{<<"ok">> => true}, Req);
                {error, Msg} -> lg_api:reply(502, lg_api:err(<<"otlp_failed">>, Msg), Req)
            end
    end;
handle_(<<"POST">>, [<<"otlp">>, <<"test-metric">>], _U, Req) ->
    case lg_config:get(otlp_endpoint) of
        <<>> -> lg_api:reply(400, lg_api:err(<<"invalid_request">>, <<"Set otlp_endpoint first">>), Req);
        _ ->
            case lg_otlp_metrics:test() of
                ok -> lg_api:reply(200, #{<<"ok">> => true}, Req);
                {error, Msg} -> lg_api:reply(502, lg_api:err(<<"otlp_failed">>, Msg), Req)
            end
    end;

%% ---- 运行参数 ----
handle_(<<"GET">>, [<<"settings">>], _U, Req) ->
    lg_api:reply(200, [setting_out(S) || S <- lg_config:all()], Req);
handle_(<<"PUT">>, [<<"settings">>, K], _U, Req0) ->
    {Body, Req} = lg_api:body(Req0),
    Key = setting_key(K, Req),
    case maps:get(<<"value">>, Body, null) of
        null ->
            ok = lg_config:unset(Key);
        V ->
            Default = maps:get(Key, lg_config:defaults()),
            same_type(V, Default) orelse lg_api:bad_request({invalid, <<"value">>}, Req),
            case lg_redact:validate(Key, V) of
                ok -> ok;
                {error, Why} -> throw({reply, 400, lg_api:err(<<"invalid_request">>, Why), Req})
            end,
            %% 开启登录前必须已有可用的管理员，否则会把自己锁在外面
            Key =:= console_auth andalso V =:= true andalso not has_admin()
                andalso throw({reply, 400, lg_api:err(<<"invalid_request">>,
                                               <<"Create an enabled admin user before enabling console login">>), Req}),
            ok = lg_config:set(Key, V)
    end,
    [S] = [setting_out(X) || X = #{key := Key0} <- lg_config:all(), Key0 =:= Key],
    lg_api:reply(200, S, Req);
handle_(_, _, _, _) ->
    nomatch.

match_model(M, Q) ->
    (case lg_api:qs(<<"q">>, Q) of
         undefined -> true;
         Text ->
             T = string:lowercase(Text),
             lists:any(fun(F) ->
                               case maps:get(F, M, null) of
                                   V when is_binary(V) -> string:find(string:lowercase(V), T) =/= nomatch;
                                   _ -> false
                               end
                       end, [<<"id">>, <<"name">>, <<"provider">>, <<"family">>])
     end)
        andalso (case lg_api:qs(<<"source">>, Q) of
                     undefined -> true;
                     S -> maps:get(<<"source">>, M) =:= S
                 end).


%% 只读项：需要重启才生效
-define(READONLY, [data_dir, http_port]).

test_result(continue) -> #{<<"kind">> => <<"continue">>};
test_result(no_hook) -> #{<<"kind">> => <<"no_hook">>};
test_result({ok, B}) when is_map(B) -> #{<<"kind">> => <<"ok">>, <<"body">> => B};
test_result({ok, B, St}) when is_map(B) -> #{<<"kind">> => <<"ok">>, <<"body">> => B, <<"state">> => fmt_term(St)};
test_result({reject, S, M}) -> #{<<"kind">> => <<"reject">>, <<"status">> => S, <<"message">> => M};
test_result({error, E}) -> #{<<"kind">> => <<"error">>, <<"message">> => fmt_term(E)};
test_result(Other) -> #{<<"kind">> => <<"bad_return">>, <<"message">> => fmt_term(Other)}.

fmt_term(T) -> iolist_to_binary(io_lib:format("~0p", [T])).

setting_out(#{key := K, value := V, source := S}) ->
    #{<<"key">> => K, <<"value">> => printable(V), <<"source">> => S,
      <<"default">> => printable(maps:get(K, lg_config:defaults())),
      <<"editable">> => not lists:member(K, ?READONLY)}.

setting_key(K, Req) ->
    Known = [atom_to_binary(A) || A <- maps:keys(lg_config:defaults()),
                                  not lists:member(A, ?READONLY)],
    case lists:member(K, Known) of
        true -> binary_to_existing_atom(K);
        false -> lg_api:not_found(Req)
    end.

has_admin() ->
    lists:any(fun(#lg_user{role = R, enabled = E}) -> R =:= admin andalso E end, lg_users:list()).

same_type(V, D) when is_integer(D) -> is_integer(V);
same_type(V, D) when is_boolean(D) -> is_boolean(V);
same_type(V, D) when is_binary(D) -> is_binary(V);
same_type(_, _) -> false.

printable(V) when is_list(V) -> unicode:characters_to_binary(V);
printable(V) -> V.
