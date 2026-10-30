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
    %% idle_timeout：HTTP/1.1 只在有在途请求时计时（收发均重置，reset_idle_timeout_on_send），
    %% 请求之间的 keep-alive 空闲由 request_timeout（默认 5s）管；HTTP/2 为整条连接的收发空闲。
    %% 非流式请求等上游期间连接上没有收发，所以必须高于上游超时（HTTP/2 不支持按请求放宽）。
    %% lg_web_drain 统计在途请求，关停时 prep_stop/1 据此排空。
    %% 关停：cowboy 收到 shutdown 后停止接收新请求、让在途请求继续，ranch 等 shutdown 毫秒后 kill 连接。
    %% 连接只挂一个 conns_sup——ranch 逐个关闭 conns_sup、各等 shutdown 毫秒，多个 conns_sup 的等待会累加。
    Opts = #{env => #{dispatch => Dispatch},
             stream_handlers => [lg_web_drain, cowboy_stream_h],
             idle_timeout => lg_config:get(upstream_timeout_ms) + 60000,
             reset_idle_timeout_on_send => true},
    TransOpts = #{socket_opts => [{ip, Bind}, {port, Port}],
                  max_connections => lg_config:get(http_max_connections),
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

%% 优雅关停（T24）：先置关停标记，在途请求不再重试 / 换候选、响应带 connection: close；
%% 暂停监听不再接新连接，等在途请求结束（最多 shutdown_drain_ms），随后 stop/1 关闭监听
%% 与剩余空闲连接。之后才轮到 lg_store 停止，写者 terminate 完成最终 flush。
%% 宽限期：排空 20s + 每个 listener 最多 5s，小于 compose stop_grace_period / systemd TimeoutStopSec 的 60s。
prep_stop(State) ->
    lg_shutdown:begin_drain(),
    Timeout = lg_config:get(shutdown_drain_ms),
    logger:notice("draining HTTP listeners: ~b request(s) in flight, waiting up to ~b ms",
                  [lg_web_drain:active([?LISTENER, ?TLS_LISTENER]), Timeout]),
    case lg_web_drain:drain([?LISTENER, ?TLS_LISTENER], Timeout) of
        ok -> logger:notice("HTTP drain complete");
        {timeout, N} -> logger:warning("HTTP drain timed out with ~b request(s) still in flight", [N])
    end,
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
                          max_connections => lg_config:get(http_max_connections),
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
