-module(lg_metrics_tests).

-include_lib("eunit/include/eunit.hrl").

metrics_test_() ->
    {foreach,
     fun() -> lg_core_test_util:start() end,
     fun(Dir) -> lg_core_test_util:stop(Dir) end,
     [?_test(counters()),
      ?_test(histogram()),
      ?_test(tracking()),
      ?_test(gauge_callbacks()),
      ?_test(snapshot())]}.

%% OTLP 导出用的结构化快照：计数器带 scale、直方图桶累计、gauge 含回调
snapshot() ->
    ok = lg_metrics:inc(litegate_requests_total, [{status, 200}], 2),
    ok = lg_metrics:inc(litegate_cost_usd_total, [{route, <<"gpt">>}], 1500000),
    ok = lg_metrics:observe(litegate_request_duration_seconds, [{route, <<"gpt">>}], 1500),
    #{counters := Cs, histograms := Hs, gauges := Gs} = lg_metrics:snapshot(),
    ?assert(lists:member({litegate_requests_total, [{status, <<"200">>}], 2}, Cs)),
    %% cost 按微美元 scale 成美元
    ?assert(lists:member({litegate_cost_usd_total, [{route, <<"gpt">>}], 1.5}, Cs)),
    {litegate_request_duration_seconds, _, #{count := Count, sum := Sum, buckets := Buckets}} =
        lists:keyfind(litegate_request_duration_seconds, 1, Hs),
    ?assertEqual(1, Count),
    ?assertEqual(1.5, Sum),
    %% 桶按累计值：1500ms 落进 2.5s 桶，+Inf 段在末尾
    {2.5, 1} = lists:keyfind(2.5, 1, Buckets),
    {inf, 1} = lists:keyfind(inf, 1, Buckets),
    ?assert(lists:any(fun({N, _, _}) -> N =:= litegate_active_streams end, Gs)).

text() ->
    iolist_to_binary(lg_metrics:render()).

has(Line) ->
    binary:match(text(), Line) =/= nomatch.

counters() ->
    ok = lg_metrics:inc(litegate_requests_total, [{status, 200}, {route, <<"gpt">>}, {format, openai}]),
    %% 标签顺序不同仍是同一序列
    ok = lg_metrics:inc(litegate_requests_total, [{route, <<"gpt">>}, {format, openai}, {status, 200}], 2),
    ?assert(has(<<"litegate_requests_total{format=\"openai\",route=\"gpt\",status=\"200\"} 3\n">>)),
    ?assert(has(<<"# TYPE litegate_requests_total counter\n">>)),
    %% 标签值转义
    ok = lg_metrics:inc(litegate_requests_total, [{route, <<"a\"b\\c">>}, {format, openai}, {status, 500}]),
    ?assert(has(<<"route=\"a\\\"b\\\\c\"">>)),
    %% 按 scale 导出：微美元 → 美元
    ok = lg_metrics:inc(litegate_cost_usd_total, [{route, <<"gpt">>}], 1500000),
    ?assert(has(<<"litegate_cost_usd_total{route=\"gpt\"} 1.5\n">>)),
    ?assert(has(<<"litegate_vm_processes ">>)).

histogram() ->
    L = [{route, <<"r">>}, {format, openai}],
    [ok = lg_metrics:observe(litegate_request_duration_seconds, L, Ms) || Ms <- [50, 300, 700, 400000]],
    T = text(),
    %% 桶为累计值：≤0.1s 1 个，≤0.5s 2 个，≤1s 3 个，+Inf 4 个
    Bucket = fun(Le) -> <<"litegate_request_duration_seconds_bucket{format=\"openai\",route=\"r\",le=\"",
                          Le/binary, "\"} ">> end,
    ?assertNotEqual(nomatch, binary:match(T, <<(Bucket(<<"0.1">>))/binary, "1\n">>)),
    ?assertNotEqual(nomatch, binary:match(T, <<(Bucket(<<"0.5">>))/binary, "2\n">>)),
    ?assertNotEqual(nomatch, binary:match(T, <<(Bucket(<<"1">>))/binary, "3\n">>)),
    ?assertNotEqual(nomatch, binary:match(T, <<(Bucket(<<"300">>))/binary, "3\n">>)),
    ?assertNotEqual(nomatch, binary:match(T, <<(Bucket(<<"+Inf">>))/binary, "4\n">>)),
    ?assertNotEqual(nomatch, binary:match(T, <<"litegate_request_duration_seconds_count{format=\"openai\",route=\"r\"} 4\n">>)),
    ?assertNotEqual(nomatch, binary:match(T, <<"litegate_request_duration_seconds_sum{format=\"openai\",route=\"r\"} 401.05\n">>)).

tracking() ->
    Parent = self(),
    Pids = [spawn(fun() -> lg_metrics:track(litegate_active_streams, self()), Parent ! ok,
                           receive stop -> ok end end) || _ <- [1, 2]],
    [receive ok -> ok end || _ <- Pids],
    wait(<<"litegate_active_streams 2\n">>),
    [P1, P2] = Pids,
    exit(P1, kill),
    wait(<<"litegate_active_streams 1\n">>),
    P2 ! stop,
    wait(<<"litegate_active_streams 0\n">>).

gauge_callbacks() ->
    ok = lg_metrics:register_gauge(test_gauge, <<"help">>, fun() -> [{[{host, <<"h">>}], 7}] end),
    ok = lg_metrics:register_gauge(broken_gauge, <<"help">>, fun() -> error(boom) end),
    ?assert(has(<<"test_gauge{host=\"h\"} 7\n">>)),
    %% 回调异常不影响整体输出
    ?assert(has(<<"# TYPE broken_gauge gauge\n">>)).

wait(Line) -> wait(Line, 100).
wait(Line, 0) -> ?assert(has(Line));
wait(Line, N) ->
    case has(Line) of
        true -> ok;
        false -> timer:sleep(10), wait(Line, N - 1)
    end.
