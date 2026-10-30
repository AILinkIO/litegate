%% @doc T29：上游链路背压与连接池（flow 窗口、空闲上限与复用计数、长生命周期进程邮箱、POST 不重发）。
%%
%% 自带一个 cowboy 处理器充当上游（按路径决定行为），不经 lg_mock_upstream 的响应队列：
%% 后者的出队不是原子的，不适合并发请求。
-module(lg_http_pool_tests).
-behaviour(cowboy_handler).

-include_lib("eunit/include/eunit.hrl").

-export([init/2]).

-define(CHUNK, 16000).
-define(CHUNKS, 200).

pool_test_() ->
    {setup,
     fun() ->
             Dir = lg_core_test_util:start(),
             {ok, _} = application:ensure_all_started(lg_provider),
             {ok, _} = application:ensure_all_started(cowboy),
             Dispatch = cowboy_router:compile([{'_', [{"/[...]", ?MODULE, []}]}]),
             {ok, _} = cowboy:start_clear(?MODULE, [{port, 0}], #{env => #{dispatch => Dispatch}}),
             {Dir, ranch:get_port(?MODULE)}
     end,
     fun({Dir, _}) ->
             ok = cowboy:stop_listener(?MODULE),
             application:stop(lg_provider),
             lg_core_test_util:stop(Dir)
     end,
     fun({_, Port}) ->
             [?_test(slow_consumer_bounded_mailbox(Port)),
              {timeout, 60, ?_test(two_waves_reuse(Port))},
              {timeout, 60, ?_test(failing_requests_leave_empty_mailbox(Port))},
              ?_test(post_not_resent_after_received())]
     end}.

%%====================================================================
%% 上游处理器
%%====================================================================

init(Req0, State) ->
    {ok, _, Req1} = cowboy_req:read_body(Req0),
    {ok, reply(cowboy_req:path(Req1), Req1), State}.

reply(<<"/ok">>, Req) ->
    timer:sleep(200),   %% 让同一波请求在服务端重叠，逼出并发连接
    json(200, #{}, Req);
reply(<<"/fail">>, Req) ->
    json(500, #{}, Req);
reply(<<"/fail_close">>, Req) ->
    json(500, #{<<"connection">> => <<"close">>}, Req);
reply(<<"/slow">>, Req) ->
    timer:sleep(300),
    json(200, #{}, Req);
reply(<<"/sse">>, Req0) ->
    Req = cowboy_req:stream_reply(200, #{<<"content-type">> => <<"text/event-stream">>}, Req0),
    Chunk = <<"data: ", (binary:copy(<<"x">>, ?CHUNK - 8))/binary, "\n\n">>,
    %% 网关中途断开时 stream_body 会失败，忽略即可
    _ = catch [cowboy_req:stream_body(Chunk, nofin, Req) || _ <- lists:seq(1, ?CHUNKS)],
    _ = catch cowboy_req:stream_body(<<>>, fin, Req),
    Req.

json(Status, Headers, Req) ->
    cowboy_req:reply(Status, Headers#{<<"content-type">> => <<"application/json">>}, <<"{\"ok\":true}">>, Req).

url(Port, Path) ->
    iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port), Path]).

%%====================================================================
%% 用例
%%====================================================================

%% 快上游 + 慢消费者：邮箱里本流的 gun_data 不超过 flow 窗口（8）+ 1，之后照常读完并归还连接。
%% +1：gun 处理 update_flow 时若 socket 消息已到它的邮箱但还没处理，会再 setopts({active, once})
%% 一次，多读一个包（额度短暂变为 -1，之后自行抵消），不随时间累积
slow_consumer_bounded_mailbox(Port) ->
    {ok, 200, _, S0} = lg_http:stream_open(<<"POST">>, url(Port, "/sse"), [], <<>>, 5000),
    {Max, Bytes, S} = lists:foldl(fun(_, {M, B, St}) ->
                                          timer:sleep(10),
                                          M1 = max(M, queued_data(maps:get(ref, St))),
                                          {data, D, St1} = lg_http:stream_recv(St, 5000),
                                          {M1, B + byte_size(D), St1}
                                  end, {0, 0, S0}, lists:seq(1, 30)),
    ?assert(Max >= 1),
    ?assertMatch(N when N =< 9, Max),
    ?assertEqual(?CHUNK * ?CHUNKS, Bytes + drain(S)).

queued_data(Ref) ->
    {messages, Ms} = process_info(self(), messages),
    length([M || {gun_data, _, R, _, _} = M <- Ms, R =:= Ref]).

drain(S) ->
    case lg_http:stream_recv(S, 5000) of
        {data, D, S1} -> byte_size(D) + drain(S1);
        {fin, D} -> byte_size(D)
    end.

%% 同主机 200 并发两波：第一波结束后保留 upstream_pool_idle_max（128）条空闲连接，
%% 第二波至少 128 条复用、新建不超过 72 条
two_waves_reuse(Port) ->
    Url = url(Port, "/ok"),
    Key = {tcp, "127.0.0.1", Port},
    wave(Url, 200),
    lg_http_pool:stats(),   %% 确保 checkin 已处理
    ?assertEqual(128, maps:get(Key, lg_http_pool:stats())),
    {Reused0, New0} = conn_counts(),
    wave(Url, 200),
    {Reused1, New1} = conn_counts(),
    ?assert(Reused1 - Reused0 >= 128),
    ?assert(New1 - New0 =< 72),
    lg_http_pool:stats(),
    ?assertEqual(128, maps:get(Key, lg_http_pool:stats())).

wave(Url, N) ->
    Pids = [spawn_monitor(fun() -> exit({res, lg_http:request(<<"POST">>, Url, [], <<"{}">>, 10000)}) end)
            || _ <- lists:seq(1, N)],
    [receive {'DOWN', MRef, process, Pid, R} -> ?assertMatch({res, {ok, 200, _, _}}, R) end
     || {Pid, MRef} <- Pids],
    ok.

conn_counts() ->
    #{counters := Cs} = lg_metrics:snapshot(),
    Sum = fun(Kind) -> lists:sum([N || {litegate_upstream_connections_total, [{result, K}], N} <- Cs,
                                       K =:= Kind]) end,
    {Sum(<<"reused">>), Sum(<<"new">>)}.

%% 长生命周期进程（如 lg_otlp、lg_notify）连续 100 次失败请求后邮箱为空：
%% 5xx（含 connection: close 后的 gun_down）、对端读完请求即断开、首包超时、连接被拒
failing_requests_leave_empty_mailbox(Port) ->
    {CloserPort, Closer} = raw_server(fun(S) -> _ = read_request(S), gen_tcp:close(S) end),
    {ok, L} = gen_tcp:listen(0, []),
    {ok, Refused} = inet:port(L),
    gen_tcp:close(L),
    Self = self(),
    {Pid, MRef} =
        spawn_monitor(fun() ->
            Calls = [fun() -> lg_http:request(<<"POST">>, url(Port, "/fail_close"), [], <<"{}">>, 5000) end,
                     fun() -> lg_http:request(<<"POST">>, url(Port, "/fail"), [], <<"{}">>, 5000) end,
                     fun() -> lg_http:request(<<"POST">>, url(CloserPort, "/x"), [], <<"{}">>, 5000) end,
                     fun() -> lg_http:request(<<"POST">>, url(Port, "/slow"), [], <<"{}">>, 50) end,
                     fun() -> lg_http:request(<<"POST">>, url(Refused, "/x"), [], <<"{}">>, 5000) end],
            Res = [(lists:nth(I rem 5 + 1, Calls))() || I <- lists:seq(1, 100)],
            timer:sleep(500),   %% 等可能迟到的消息（如 /slow 被丢弃后的响应）
            {messages, Ms} = process_info(self(), messages),
            Self ! {done, self(), Res, Ms}
        end),
    receive
        {done, Pid, Res, Ms} ->
            ?assertEqual([], [R || R <- Res, element(1, R) =/= error]),
            ?assertEqual([], Ms)
    after 50000 ->
        error(timeout)
    end,
    receive {'DOWN', MRef, process, Pid, _} -> ok end,
    exit(Closer, kill).

%% 复用连接上请求已被上游收下、超过重发窗口后才断开：不重发 POST，以 request_failed 返回
post_not_resent_after_received() ->
    Self = self(),
    {Port, Server} = raw_server(fun(S) -> held_conn(S, Self, 1) end),
    Url = url(Port, "/v1/chat/completions"),
    ?assertMatch({ok, 200, _, _}, lg_http:request(<<"POST">>, Url, [], <<"{}">>, 5000)),
    lg_http_pool:stats(),
    ?assertEqual(1, maps:get({tcp, "127.0.0.1", Port}, lg_http_pool:stats())),
    ?assertMatch({error, {request_failed, _}}, lg_http:request(<<"POST">>, Url, [], <<"{}">>, 5000)),
    timer:sleep(100),
    ?assertEqual(2, count_requests(0)),
    exit(Server, kill).

%% 每条连接上第 1 个请求正常回复，第 2 个请求收下后 200ms 断开（不回任何字节）
held_conn(S, Parent, N) ->
    case read_request(S) of
        ok ->
            Parent ! got_request,
            case N of
                1 ->
                    Body = <<"{}">>,
                    gen_tcp:send(S, ["HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n",
                                     "content-length: ", integer_to_list(byte_size(Body)), "\r\n\r\n", Body]),
                    held_conn(S, Parent, 2);
                _ ->
                    timer:sleep(200),
                    gen_tcp:close(S)
            end;
        closed ->
            ok
    end.

count_requests(N) ->
    receive got_request -> count_requests(N + 1) after 0 -> N end.

%% 原始 TCP 服务端：每条连接交给 ConnFun 处理
raw_server(ConnFun) ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(L),
    Acceptor = spawn(fun() -> accept_loop(L, ConnFun) end),
    ok = gen_tcp:controlling_process(L, Acceptor),
    {Port, Acceptor}.

accept_loop(L, ConnFun) ->
    case gen_tcp:accept(L) of
        {ok, S} ->
            Pid = spawn(fun() -> receive go -> ConnFun(S) end end),
            ok = gen_tcp:controlling_process(S, Pid),
            Pid ! go,
            accept_loop(L, ConnFun);
        {error, _} ->
            ok
    end.

read_request(S) ->
    read_request(S, <<>>).

read_request(S, Buf) ->
    case binary:split(Buf, <<"\r\n\r\n">>) of
        [Head, Rest] ->
            case re:run(Head, "content-length: *([0-9]+)", [caseless, {capture, all_but_first, binary}]) of
                {match, [Len]} -> read_body(S, binary_to_integer(Len) - byte_size(Rest));
                nomatch -> ok
            end;
        [_] ->
            case gen_tcp:recv(S, 0) of
                {ok, Data} -> read_request(S, <<Buf/binary, Data/binary>>);
                {error, _} -> closed
            end
    end.

read_body(_S, N) when N =< 0 -> ok;
read_body(S, N) ->
    case gen_tcp:recv(S, 0) of
        {ok, Data} -> read_body(S, N - byte_size(Data));
        {error, _} -> closed
    end.
