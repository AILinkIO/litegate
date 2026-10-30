%% @doc T24：优雅关停排空（lg_web_drain）与 /health 的 mnesia 检查。
%%
%% 用独立的 cowboy listener 挂 lg_web_drain 与一个可控时长的慢 handler（本模块 init/2）。
-module(lg_web_drain_tests).

-include_lib("eunit/include/eunit.hrl").

-export([init/2]).

-define(REF, lg_web_drain_test_listener).

drain_test_() ->
    {setup,
     fun() ->
             Dir = lg_core_test_util:start(),
             {ok, _} = application:ensure_all_started(cowboy),
             {ok, _} = application:ensure_all_started(gun),
             Dir
     end,
     fun(Dir) ->
             _ = cowboy:stop_listener(?REF),
             lg_shutdown:end_drain(),
             lg_core_test_util:stop(Dir)
     end,
     fun(_) ->
             [{timeout, 10, ?_test(waits_for_inflight())},
              {timeout, 10, ?_test(respects_timeout())},
              ?_test(idle_connection_not_counted()),
              ?_test(crashed_connection_not_counted()),
              ?_test(health_reports_mnesia())]
     end}.

%% 慢 handler：/slow/<毫秒>
init(Req, slow) ->
    timer:sleep(binary_to_integer(cowboy_req:binding(ms, Req))),
    {ok, cowboy_req:reply(200, #{}, <<"done">>, Req), slow}.

start_listener() ->
    Dispatch = cowboy_router:compile([{'_', [{"/slow/:ms", ?MODULE, slow},
                                             {"/health", lg_web_health, #{}}]}]),
    {ok, _} = cowboy:start_clear(?REF, #{socket_opts => [{ip, {127, 0, 0, 1}}, {port, 0}]},
                                 #{env => #{dispatch => Dispatch},
                                   stream_handlers => [lg_web_drain, cowboy_stream_h]}),
    ranch:get_port(?REF).

stop_listener() ->
    ok = cowboy:stop_listener(?REF),
    lg_shutdown:end_drain().

%% 后台发请求，结果发回测试进程（连接被强杀时为 {error, _}）
async_get(Port, Path) ->
    Self = self(),
    spawn(fun() -> Self ! {reply, try get(Port, Path) catch C:R -> {error, {C, R}} end} end).

get(Port, Path) ->
    {ok, Conn} = gun:open("127.0.0.1", Port, #{retry => 0}),
    {ok, _} = gun:await_up(Conn, 5000),
    Ref = gun:get(Conn, Path),
    Res = case gun:await(Conn, Ref, 10000) of
              {response, fin, S, H} -> {S, H, <<>>};
              {response, nofin, S, H} -> {ok, B} = gun:await_body(Conn, Ref, 10000), {S, H, B}
          end,
    gun:close(Conn),
    Res.

wait_active(N) ->
    wait_active(N, 50).
wait_active(N, 0) ->
    ?assertEqual(N, lg_web_drain:active([?REF]));
wait_active(N, Tries) ->
    case lg_web_drain:active([?REF]) of
        N -> ok;
        _ -> timer:sleep(20), wait_active(N, Tries - 1)
    end.

%% 在途请求跑完 drain 才返回；响应带 connection: close；暂停后不再接受新连接
waits_for_inflight() ->
    Port = start_listener(),
    async_get(Port, "/slow/600"),
    wait_active(1),
    lg_shutdown:begin_drain(),
    T0 = erlang:monotonic_time(millisecond),
    ?assertEqual(ok, lg_web_drain:drain([?REF, no_such_listener], 5000)),
    ?assert(erlang:monotonic_time(millisecond) - T0 >= 300),
    receive {reply, {S, H, B}} ->
            ?assertEqual({200, <<"done">>}, {S, B}),
            ?assertEqual(<<"close">>, proplists:get_value(<<"connection">>, H))
    after 5000 -> error(no_reply)
    end,
    ?assertEqual(0, lg_web_drain:active([?REF])),
    {ok, Conn} = gun:open("127.0.0.1", Port, #{retry => 0}),
    ?assertMatch({error, _}, gun:await_up(Conn, 1000)),
    gun:close(Conn),
    stop_listener().

%% 超过 shutdown_drain_ms 时按时返回剩余数量，不无限等
respects_timeout() ->
    Port = start_listener(),
    async_get(Port, "/slow/3000"),
    wait_active(1),
    T0 = erlang:monotonic_time(millisecond),
    ?assertEqual({timeout, 1}, lg_web_drain:drain([?REF], 300)),
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    ?assert(Elapsed >= 300 andalso Elapsed < 1500),
    %% 在途请求仍可跑完（stop_listener 之前连接未被断开）
    receive {reply, {200, _, <<"done">>}} -> ok after 5000 -> error(no_reply) end,
    stop_listener().

%% 空闲 keep-alive 连接不计入在途请求，不拖慢排空
idle_connection_not_counted() ->
    Port = start_listener(),
    {ok, Conn} = gun:open("127.0.0.1", Port, #{retry => 0}),
    {ok, _} = gun:await_up(Conn, 5000),
    Ref = gun:get(Conn, "/slow/0"),
    {response, nofin, 200, _} = gun:await(Conn, Ref, 5000),
    {ok, <<"done">>} = gun:await_body(Conn, Ref, 5000),
    wait_active(0),
    ?assertEqual(ok, lg_web_drain:drain([?REF], 2000)),
    gun:close(Conn),
    stop_listener().

%% 连接进程崩溃（stream terminate 未执行）时计数随进程消失，不残留到关停
crashed_connection_not_counted() ->
    Port = start_listener(),
    async_get(Port, "/slow/3000"),
    wait_active(1),
    [Conn] = ranch:procs(?REF, connections),
    exit(Conn, kill),
    wait_active(0),
    ?assertEqual(ok, lg_web_drain:drain([?REF], 1000)),
    receive {reply, R} -> ?assertMatch({error, _}, R) after 5000 -> error(no_reply) end,
    stop_listener().

%% mnesia 运行时 200；停掉后 503（应用以 permanent 启动 mnesia，显式 stop 不会带走节点）
health_reports_mnesia() ->
    Port = start_listener(),
    ?assertMatch({200, _, <<"{\"status\":\"ok\"}">>}, get(Port, "/health")),
    stopped = mnesia:stop(),
    {S, _, B} = get(Port, "/health"),
    ?assertEqual(503, S),
    ?assertMatch(#{<<"status">> := <<"unavailable">>, <<"mnesia">> := <<"no">>}, json:decode(B)),
    stop_listener().
