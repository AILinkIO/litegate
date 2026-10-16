-module(lg_web_app).
-behaviour(application).

-export([start/2, prep_stop/1, stop/1]).

-define(LISTENER, lg_http_listener).

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
    case cowboy:start_clear(?LISTENER, TransOpts, Opts) of
        {ok, _} ->
            logger:notice("LiteGate listening on port ~b", [ranch:get_port(?LISTENER)]),
            insecure_warning(Bind),
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
    lg_shutdown:end_drain().

bind(Value) when is_binary(Value); is_list(Value) ->
    case inet:parse_address(binary_to_list(Value)) of
        {ok, Ip} -> Ip;
        {error, _} -> error({invalid_config, {http_bind, Value}})
    end;
bind(Ip) when is_tuple(Ip) -> Ip.

insecure_warning(Bind) ->
    case lg_config:get(console_auth) =:= false andalso not loopback(Bind) of
        true -> logger:warning("console auth is disabled and HTTP is bound to a non-loopback address");
        false -> ok
    end.

loopback({127, _, _, _}) -> true;
loopback({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
loopback(_) -> false.
