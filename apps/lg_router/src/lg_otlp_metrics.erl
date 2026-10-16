%% @doc OTLP/HTTP（JSON）指标导出：周期性把 /metrics 同源的指标推到收集器的 /v1/metrics。
%%
%% 数据取自 lg_metrics:snapshot/0（计数器、直方图、track 与回调 gauge），另加凭证并发与排队 gauge
%% （litegate.credential.inflight / litegate.credential.queued）。计数器与直方图为 CUMULATIVE。
%% 推送失败只记日志不重试：同值累计推送每个周期重发，丢失不产生数据缺口（与 trace 的重试策略不同）。
%%
%% 运行参数：otlp_metrics_enabled（默认 false）、otlp_metrics_interval_ms（默认 60000）、
%% 复用 otlp_endpoint / otlp_headers。「参数」页的「发送测试 metric」走 test/0。
-module(lg_otlp_metrics).
-behaviour(gen_server).

-include_lib("lg_core/include/lg_core.hrl").

-export([start_link/0, run/0, test/0, points/1, body/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(DEFAULT_INTERVAL, 60000).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc 立即推送一次（配置了 otlp_endpoint 时），返回 {ok, 指标数} | {error, term()}。
-spec run() -> {ok, non_neg_integer()} | skipped | {error, term()}.
run() ->
    gen_server:call(?MODULE, run, 30000).

%% @doc 发送一个测试数据点，同步返回结果（控制台「发送测试 metric」）。
-spec test() -> ok | {error, binary()}.
test() ->
    case send(body(test_points())) of
        ok -> ok;
        {error, R} -> {error, iolist_to_binary(io_lib:format("~0p", [R]))}
    end.

%%====================================================================
%% 数据点构造（纯函数，可测）
%%====================================================================

%% @doc 由 lg_metrics:snapshot/0 的结果与凭证并发状态构造 OTLP metrics 项列表。
-spec points(map()) -> [map()].
points(#{counters := Cs, histograms := Hs, gauges := Gs}) ->
    Nano = erlang:system_time(nanosecond),
    Sums = [#{name => to_bin(N),
              sum => #{dataPoints => [dp(L, V, Nano)], aggregationTemporality => 2, isMonotonic => true}}
            || {N, L, V} <- Cs, is_number(V)],
    Hists = [#{name => to_bin(N),
               histogram => #{dataPoints => [hdp(L, H, Nano)], aggregationTemporality => 2}}
             || {N, L, H} <- Hs],
    Gauges = [#{name => to_bin(N), gauge => #{dataPoints => [dp(L, V, Nano)]}}
              || {N, L, V} <- Gs, is_number(V)]
             ++ conc_gauges(Nano),
    Sums ++ Hists ++ Gauges.

conc_gauges(Nano) ->
    try
        [#{name => <<"litegate.credential.", (atom_to_binary(F))/binary>>,
           gauge => #{dataPoints => [dp([{credential, Id}], V, Nano)]}}
         || #lg_credential{id = Id} <- lg_credentials:list(),
            {V, F} <- [{lg_conc:inflight(Id), inflight}, {lg_conc:queued(Id), queued}]]
    catch
        _:_ -> []
    end.

dp(Labels, V, Nano) when is_integer(V) ->
    #{attributes => lattr(Labels), asInt => integer_to_binary(V), timeUnixNano => integer_to_binary(Nano)};
dp(Labels, V, Nano) ->
    #{attributes => lattr(Labels), asDouble => V, timeUnixNano => integer_to_binary(Nano)}.

hdp(Labels, #{count := Count, sum := Sum, buckets := Buckets}, Nano) ->
    Finite = [{B, C} || {B, C} <- Buckets, B =/= inf],
    Inf = case lists:keyfind(inf, 1, Buckets) of {_, C} -> C; false -> 0 end,
    #{attributes => lattr(Labels), timeUnixNano => integer_to_binary(Nano),
      count => integer_to_binary(Count), sum => Sum,
      bucketCounts => [integer_to_binary(C) || {_, C} <- Finite] ++ [integer_to_binary(Inf)],
      explicitBounds => [B || {B, _} <- Finite]}.

lattr(Labels) ->
    lg_otlp:attrs(maps:from_list([{atom_to_binary(K), V} || {K, V} <- Labels])).

to_bin(N) when is_atom(N) -> atom_to_binary(N);
to_bin(N) when is_binary(N) -> N.

test_points() ->
    [#{name => <<"litegate.otlp.test">>,
       gauge => #{dataPoints => [dp([], 1, erlang:system_time(nanosecond))]}}].

%%====================================================================
%% 发送
%%====================================================================

body(Points) ->
    json:encode(#{resourceMetrics =>
                      [#{resource => #{attributes => lg_otlp:attrs(#{<<"service.name">> => <<"litegate">>})},
                         scopeMetrics => [#{scope => #{name => <<"litegate">>}, metrics => Points}]}]}).

send(Body) ->
    Endpoint = string:trim(lg_config:get(otlp_endpoint), trailing, "/"),
    Url = <<Endpoint/binary, "/v1/metrics">>,
    H = [{<<"content-type">>, <<"application/json">>} | lg_otlp:parse_headers(lg_config:get(otlp_headers))],
    case lg_http:request(<<"POST">>, Url, H, Body, 10000) of
        {ok, _, _, _} -> ok;
        {error, R} -> {error, R}
    end.

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    _ = erlang:send_after(interval(), self(), tick),
    {ok, #{}}.

handle_call(run, _From, S) ->
    {reply, push(), S};
handle_call(_Req, _From, S) ->
    {reply, ok, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(tick, S) ->
    _ = due() andalso push(),
    _ = erlang:send_after(interval(), self(), tick),
    {noreply, S};
handle_info(_Msg, S) ->
    {noreply, S}.

interval() ->
    max(5000, lg_config:get(otlp_metrics_interval_ms)).

due() ->
    lg_config:get(otlp_metrics_enabled) =:= true
        andalso lg_config:get(otlp_endpoint) =/= <<>>
        andalso lg_config:get(otlp_metrics_interval_ms) > 0.

push() ->
    Points = points(lg_metrics:snapshot()),
    case send(body(Points)) of
        ok -> {ok, length(Points)};
        {error, R} ->
            logger:warning("otlp metrics: export of ~b metrics failed: ~0p", [length(Points), R]),
            {error, R}
    end.
