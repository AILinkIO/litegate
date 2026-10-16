-module(lg_otlp_metrics_tests).

-include_lib("eunit/include/eunit.hrl").

%% points/1 与 body/1 是纯函数：喂一个快照，核对 OTLP JSON 形状
points_test() ->
    Snapshot = #{counters => [{litegate_requests_total, [{status, 200}], 3}],
                 histograms => [{litegate_request_duration_seconds,
                                 [{route, <<"gpt">>}],
                                 #{count => 2, sum => 1.5,
                                   buckets => [{0.5, 0}, {1, 1}, {2.5, 2}, {inf, 2}]}}],
                 gauges => [{litegate_active_streams, [], 1}]},
    Points = lg_otlp_metrics:points(Snapshot),
    %% 计数器：CUMULATIVE 单调 sum，整数走 asInt（OTLP JSON 里 int64 是字符串）
    Sum = maps:get(sum, find(<<"litegate_requests_total">>, Points)),
    ?assertEqual(2, maps:get(aggregationTemporality, Sum)),
    ?assert(maps:get(isMonotonic, Sum)),
    [Dp] = maps:get(dataPoints, Sum),
    ?assertEqual(<<"3">>, maps:get(asInt, Dp)),
    ?assertMatch(#{attributes := [#{key := <<"status">>}]}, Dp),
    %% 直方图：bucketCounts 为字符串数组（含 +Inf 段），explicitBounds 不含 +Inf
    Hist = find(<<"litegate_request_duration_seconds">>, Points),
    [Hdp] = maps:get(dataPoints, maps:get(histogram, Hist)),
    ?assertEqual(<<"2">>, maps:get(count, Hdp)),
    ?assertEqual(1.5, maps:get(sum, Hdp)),
    ?assertEqual([<<"0">>, <<"1">>, <<"2">>, <<"2">>], maps:get(bucketCounts, Hdp)),
    ?assertEqual([0.5, 1, 2.5], maps:get(explicitBounds, Hdp)),
    %% gauge
    find(<<"litegate_active_streams">>, Points),
    %% body 是合法 JSON 的 resourceMetrics 结构
    #{<<"resourceMetrics">> := [#{<<"scopeMetrics">> := [#{<<"metrics">> := Metrics}]}]} =
        json:decode(iolist_to_binary(lg_otlp_metrics:body(Points))),
    ?assert(length(Metrics) =:= 3).

find(Name, Points) ->
    hd([M || M <- Points, maps:get(name, M, null) =:= Name]).

credentials_in_points_test() ->
    %% 凭证并发 / 排队 gauge（无凭证时不产生数据点）
    Snapshot = #{counters => [], histograms => [], gauges => []},
    ?assertEqual([], [P || #{name := <<"litegate.credential.", _/binary>>} = P <- lg_otlp_metrics:points(Snapshot)]).
