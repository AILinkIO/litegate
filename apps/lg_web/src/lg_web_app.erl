-module(lg_web_app).
-behaviour(application).

-export([start/2, prep_stop/1, stop/1]).

-define(LISTENER, lg_http_listener).
-define(TLS_LISTENER, lg_https_listener).

start(_StartType, _StartArgs) ->
    %% 仅在启用控制台登录时创建初始管理员（单机模式无需账号）
    ok = case lg_config:get(console_auth) of
             true -> lg_users:ensure_admin();
             false -> ok
         end,
    Port = lg_config:get(http_port),
    Bind = bind(lg_config:get(http_bind)),
    Dispatch = cowboy_router:compile([{'_', lg_web_routes:routes()}]),
    %% idle_timeout 须大于上游超时，否则长时间等待上游的非流式请求会被 cowboy 断开。
    %% 关停：cowboy 收到 shutdown 后停止接收新请求、让在途请求继续，ranch 等 shutdown 毫秒后 kill 连接。
    %% 连接只挂一个 conns_sup——ranch 逐个关闭 conns_sup、各等 shutdown 毫秒，多个 conns_sup 的等待会累加，
    %% 超过 docker stop 的 10 秒宽限被 SIGKILL。
    Opts = #{env => #{dispatch => Dispatch},
             idle_timeout => lg_config:get(upstream_timeout_ms) + 60000},
    TransOpts = #{socket_opts => [{ip, Bind}, {port, Port}],
                  num_conns_sups => 1, shutdown => 5000},
    %% T10：非回环绑定 + 未开鉴权 + 未显式放行 → 拒绝启动（防管理面裸奔）
    ok = check_bind_security(Bind),
    case cowboy:start_clear(?LISTENER, TransOpts, Opts) of
        {ok, _} ->
            logger:notice("LiteGate listening on port ~b", [ranch:get_port(?LISTENER)]),
            maybe_start_tls(Bind, Opts),
            lg_web_sup:start_link();
        {error, Reason} ->
            {error, {listen, Port, Reason}}
    end.

%% 先置关停标记，在途请求不再重试 / 换候选，随后 stop/1 关闭监听
prep_stop(State) ->
    lg_shutdown:begin_drain(),
    State.

stop(_State) ->
    _ = cowboy:stop_listener(?LISTENER),
    _ = cowboy:stop_listener(?TLS_LISTENER),
    lg_shutdown:end_drain().

%% T13：TLS 监听器（可与 clear 并存）
maybe_start_tls(Bind, Opts) ->
    case lg_config:get(tls_enabled) of
        true ->
            Port = lg_config:get(tls_port),
            Cert = lg_config:get(tls_cert_file),
            Key = lg_config:get(tls_key_file),
            Cert =/= <<>> andalso Key =/= <<>>
                orelse erlang:error({tls_config_missing, <<"tls_cert_file and tls_key_file are required">>}),
            filelib:is_file(Cert) orelse erlang:error({tls_cert_not_found, Cert}),
            filelib:is_file(Key) orelse erlang:error({tls_key_not_found, Key}),
            TransOpts = #{socket_opts => [{ip, Bind}, {port, Port},
                                          {certfile, binary_to_list(Cert)},
                                          {keyfile, binary_to_list(Key)}],
                          num_conns_sups => 1, shutdown => 5000},
            case cowboy:start_tls(?TLS_LISTENER, TransOpts, Opts) of
                {ok, _} ->
                    logger:notice("LiteGate TLS listening on port ~b", [Port]),
                    ok;
                {error, Reason} ->
                    erlang:error({tls_listen, Port, Reason})
            end;
        false ->
            ok
    end.

bind(Value) when is_binary(Value); is_list(Value) ->
    case inet:parse_address(binary_to_list(Value)) of
        {ok, Ip} -> Ip;
        {error, _} -> error({invalid_config, {http_bind, Value}})
    end;
bind(Ip) when is_tuple(Ip) -> Ip.

%% 非回环地址 + console_auth 关 + 未设 allow_insecure_bind → 启动失败并给出迁移指引
check_bind_security(Bind) ->
    case lg_config:get(console_auth) =:= false andalso not loopback(Bind) of
        true ->
            case lg_config:get(allow_insecure_bind) of
                true ->
                    logger:warning("console auth is disabled and HTTP is bound to a non-loopback address (allow_insecure_bind=true)"),
                    ok;
                false ->
                    logger:error(
                      "Refusing to start: HTTP is bound to a non-loopback address (~s) "
                      "but console_auth is disabled. Either enable console_auth (set to true "
                      "and create an admin user), bind to 127.0.0.1, or explicitly set "
                      "allow_insecure_bind=true to accept the risk.",
                      [inet:ntoa(Bind)]),
                    erlang:error({insecure_bind, Bind})
            end;
        false ->
            ok
    end.

loopback({127, _, _, _}) -> true;
loopback({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
loopback(_) -> false.
