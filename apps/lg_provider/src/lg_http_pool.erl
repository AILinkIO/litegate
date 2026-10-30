%% @doc gun 空闲连接池（按 {传输层, 主机, 端口} 分组）。
%%
%% 与 beamai_http_pool 的区别（网关场景）：
%% - 池进程不做 TLS 握手：没有空闲连接时由调用方自己 gun:open + await_up，
%%   避免慢握手阻塞所有请求
%% - 不限制活跃连接数（上游并发由路由层的限流控制），只限制每个主机保留的空闲连接数
%% - 借出期间连接的 owner 是调用方：调用方进程退出时 gun 连接随之关闭，不会泄漏
%%
%% 所有权流转：checkin 时调用方 set_owner 给池；checkout 时池 set_owner 给调用方。
%% 连接以 retry => 0 打开，对端关闭空闲连接后 gun 进程退出，池通过 monitor 清理。
%%
%% 池进程不调用 gun 的同步接口（T29）：主机键由调用方随 checkin 传入；超出空闲上限 / 过期的连接
%% 交给临时进程 gun:close（经 gun_conns_sup 同步终止），不拖住 checkout。
%% 每个主机的空闲上限为运行参数 upstream_pool_idle_max；checkout 结果计入
%% litegate_upstream_connections_total{result = reused | new}（复用率在 Prometheus 侧计算）。
-module(lg_http_pool).
-behaviour(gen_server).

-export([start_link/0, checkout/1, checkout_fresh/1, checkin/2, discard/1, stats/0, conn_opts/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(IDLE_TIMEOUT, 60000).
-define(SWEEP_INTERVAL, 15000).
-define(HANDOFF_TIMEOUT, 5000).   %% checkin / discard 时与 gun 进程同步的等待上限

-type host_key() :: {tcp | tls, string(), inet:port_number()}.

-record(state, {
    idle = #{} :: #{host_key() => [{pid(), integer()}]},   %% {Conn, 归还时间}，头部最新
    mons = #{} :: #{pid() => {host_key(), reference()}}
}).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc 取一条到 Url 所在主机的已连接 gun 连接，调用方成为 owner。
%% Reused =:= true 表示来自空闲池，可能已被对端关闭，调用方可据此重试一次。
-spec checkout(binary()) -> {ok, pid(), Reused :: boolean()} | {error, term()}.
checkout(Url) ->
    case host_key(Url) of
        {ok, Key} ->
            case gen_server:call(?MODULE, {checkout, Key, self()}) of
                {ok, Conn} -> counted({ok, Conn, true});
                empty -> counted(open_fresh(Key))
            end;
        {error, _} = Err ->
            Err
    end.

%% @doc 不经过空闲池，直接新建连接。
-spec checkout_fresh(binary()) -> {ok, pid(), false} | {error, term()}.
checkout_fresh(Url) ->
    case host_key(Url) of
        {ok, Key} -> counted(open_fresh(Key));
        {error, _} = Err -> Err
    end.

%% @doc 归还连接（请求已完整结束时由调用方调用；Url 为本次请求的地址，用于算主机键）。
%%
%% set_owner 是异步 cast：随后与 gun 进程做一次同步往返（sys:get_state），往返返回时
%% 交接前它发给本进程的消息都已到达。往返失败说明连接已断（retry => 0 时 gun 发出 gun_down 后
%% 即退出，如上游回 connection: close），此时按 discard 清掉这些消息、不归还，
%% 免得 gun_down 残留在 lg_otlp、lg_notify 等长生命周期进程的邮箱里。
-spec checkin(pid(), binary()) -> ok.
checkin(Conn, Url) ->
    case {whereis(?MODULE), host_key(Url)} of
        {Pool, {ok, Key}} when is_pid(Pool) ->
            ok = gun:set_owner(Conn, Pool),
            try sys:get_state(Conn, ?HANDOFF_TIMEOUT) of
                _ -> gen_server:cast(Pool, {checkin, Key, Conn})
            catch
                exit:_ -> discard(Conn)
            end;
        _ ->
            discard(Conn)
    end.

%% @doc 丢弃连接（请求中途失败或流未读完时调用），并清掉该连接发给本进程的全部消息。
%%
%% 先关再清：monitor 的 'DOWN' 排在 gun 进程发给本进程的所有消息之后，等到它再按连接 flush，
%% 关闭前后迟到的 gun_response / gun_data / gun_error / gun_down 都不会残留在调用方邮箱。
-spec discard(pid()) -> ok.
discard(Conn) ->
    MRef = monitor(process, Conn),
    _ = gun:close(Conn),
    receive
        {'DOWN', MRef, process, Conn, _} -> ok
    after ?HANDOFF_TIMEOUT ->
        demonitor(MRef, [flush])
    end,
    gun:flush(Conn).

-spec stats() -> #{host_key() => non_neg_integer()}.
stats() ->
    gen_server:call(?MODULE, stats).

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    erlang:send_after(?SWEEP_INTERVAL, self(), sweep),
    lg_metrics:register_gauge(
      litegate_http_pool_idle_connections, <<"Idle upstream connections by host">>,
      fun() -> [{[{host, iolist_to_binary([atom_to_binary(T), "://", H, ":", integer_to_binary(P)])}], N}
                || {T, H, P} := N <- stats()] end),
    {ok, #state{}}.

handle_call({checkout, Key, Caller}, _From, #state{idle = Idle} = S) ->
    case maps:get(Key, Idle, []) of
        [] ->
            {reply, empty, S};
        [{Conn, _} | Rest] ->
            S1 = forget(Conn, S#state{idle = put_list(Key, Rest, Idle)}),
            ok = gun:set_owner(Conn, Caller),
            {reply, {ok, Conn}, S1}
    end;
handle_call(stats, _From, #state{idle = Idle} = S) ->
    {reply, maps:map(fun(_, L) -> length(L) end, Idle), S}.

handle_cast({checkin, Key, Conn}, #state{idle = Idle, mons = Mons} = S) ->
    List = maps:get(Key, Idle, []),
    case length(List) >= lg_config:get(upstream_pool_idle_max) of
        true ->
            close_async(Conn),
            {noreply, S};
        false ->
            Ref = monitor(process, Conn),
            {noreply, S#state{idle = Idle#{Key => [{Conn, now_ms()} | List]},
                              mons = Mons#{Conn => {Key, Ref}}}}
    end.

handle_info({'DOWN', _Ref, process, Conn, _Reason}, S) ->
    {noreply, remove(Conn, S)};
handle_info(sweep, #state{idle = Idle} = S) ->
    Deadline = now_ms() - ?IDLE_TIMEOUT,
    Expired = [C || {_, L} <- maps:to_list(Idle), {C, T} <- L, T < Deadline],
    S1 = lists:foldl(fun(C, Acc) -> close_async(C), remove(C, Acc) end, S, Expired),
    erlang:send_after(?SWEEP_INTERVAL, self(), sweep),
    {noreply, S1};
handle_info(_Msg, S) ->
    %% 空闲连接的 gun_up / gun_down / gun_error 发给 owner（池），无需处理
    {noreply, S}.

%% 池进程持有的连接（空闲、无流）直接终止即可，池邮箱里的迟到消息由 handle_info 兜底丢弃
close_async(Conn) ->
    _ = spawn(gun, close, [Conn]),
    ok.

counted({ok, _, Reused} = Ok) ->
    lg_metrics:inc(litegate_upstream_connections_total, [{result, case Reused of true -> reused; false -> new end}]),
    Ok;
counted(Err) ->
    Err.

%%====================================================================
%% 内部函数
%%====================================================================

open_fresh({Transport, Host, Port}) ->
    case conn_opts(Transport, Host) of
        {ok, Opts} -> open_fresh(Host, Port, Opts);
        {error, _} = E -> E
    end.

open_fresh(Host, Port, Opts) ->
    Timeout = maps:get(connect_timeout, Opts),
    case gun:open(Host, Port, Opts) of
        {ok, Conn} ->
            case gun:await_up(Conn, Timeout) of
                {ok, _Proto} ->
                    {ok, Conn, false};
                {error, Reason} ->
                    discard(Conn),
                    {error, {connect_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {connect_failed, Reason}}
    end.

%% @doc gun:open 选项（HTTP/1.1；TLS 时校验证书与主机名并带 SNI）。realtime 的 WebSocket 连接同样使用。
%% 系统没有 CA 证书时 public_key:cacerts_get/0 会崩溃（OTP 28 conv_error_reason 的 function_clause），
%% 转成连接失败，避免把调用方进程一起带崩；明文 http 不需要证书
-spec conn_opts(tcp | tls, string()) -> {ok, map()} | {error, term()}.
conn_opts(Transport, Host) ->
    Base = #{transport => Transport,
             protocols => [http],
             connect_timeout => lg_config:get(upstream_connect_timeout_ms),
             retry => 0},
    case Transport of
        tcp -> {ok, Base};
        tls ->
            try {ok, Base#{tls_opts => tls_opts(Host)}}
            catch _:_ -> {error, {connect_failed, no_cacerts}}
            end
    end.

tls_opts(Host) ->
    [{verify, verify_peer},
     {cacerts, public_key:cacerts_get()},
     {server_name_indication, Host},
     {customize_hostname_check,
      [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}].

-spec host_key(binary()) -> {ok, host_key()} | {error, term()}.
host_key(Url) ->
    case uri_string:parse(Url) of
        #{scheme := Scheme, host := Host} = U when Host =/= <<>> ->
            case string:lowercase(Scheme) of
                <<"https">> -> {ok, {tls, binary_to_list(Host), maps:get(port, U, 443)}};
                <<"http">> -> {ok, {tcp, binary_to_list(Host), maps:get(port, U, 80)}};
                _ -> {error, {bad_url, Url}}
            end;
        _ ->
            {error, {bad_url, Url}}
    end.

forget(Conn, #state{mons = Mons} = S) ->
    case maps:take(Conn, Mons) of
        {{_Key, Ref}, Mons1} ->
            demonitor(Ref, [flush]),
            S#state{mons = Mons1};
        error ->
            S
    end.

remove(Conn, #state{idle = Idle, mons = Mons} = S) ->
    case maps:take(Conn, Mons) of
        {{Key, Ref}, Mons1} ->
            demonitor(Ref, [flush]),
            List = lists:keydelete(Conn, 1, maps:get(Key, Idle, [])),
            S#state{idle = put_list(Key, List, Idle), mons = Mons1};
        error ->
            S
    end.

put_list(Key, [], Idle) -> maps:remove(Key, Idle);
put_list(Key, L, Idle) -> Idle#{Key => L}.

now_ms() -> erlang:monotonic_time(millisecond).
