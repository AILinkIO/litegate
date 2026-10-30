%% @doc Prometheus 指标（自实现，无外部依赖）。
%%
%% - 计数器：inc/2,3，ETS update_counter 原子累加（浮点值由调用方换算成整数，如微美元）
%% - 直方图：observe/3，按指标定义的桶累加 bucket / sum / count
%% - 进程计量：track/2 + untrack/2，本进程监控被跟踪进程，崩溃也会自动移除（不会只增不减）
%% - 回调计量：register_gauge/3，抓取时调用（如连接池空闲数，由其他应用在启动时注册）
%%
%% 指标元信息（类型、说明、直方图桶、数值缩放）集中在 defs/0。
-module(lg_metrics).
-behaviour(gen_server).

-export([start_link/0, inc/2, inc/3, observe/3, track/2, untrack/2,
         register_gauge/3, render/0, snapshot/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, lg_metrics).
-define(TRACK, lg_metrics_track).    %% {{Name, Pid}, MonitorRef}（bag 语义用 Pid 区分）
-define(GAUGES, {?MODULE, gauges}).

-type labels() :: [{atom(), binary() | atom() | integer()}].
-export_type([labels/0]).

%% {类型, 说明, 选项}；scale：存储整数 / scale = 导出值
defs() ->
    #{litegate_requests_total =>
          {counter, <<"Proxy requests by route, endpoint format and HTTP status">>, #{}},
      litegate_request_duration_seconds =>
          {histogram, <<"Proxy request duration">>,
           #{buckets => [0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300], scale => 1000}},
      litegate_ttft_seconds =>
          {histogram, <<"Streaming time to first output token">>,
           #{buckets => [0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60], scale => 1000}},
      litegate_upstream_attempts_total =>
          {counter, <<"Upstream attempts by credential and outcome">>, #{}},
      litegate_tokens_total =>
          {counter, <<"Tokens by route and type (input, output, cache_read, cache_write)">>, #{}},
      litegate_cost_usd_total =>
          {counter, <<"Cost in USD by route">>, #{scale => 1000000}},
      litegate_cache_requests_total =>
          {counter, <<"Response cache lookups by route and result (hit, miss)">>, #{}},
      litegate_rate_limited_total =>
          {counter, <<"Requests rejected by rate limits or budgets">>, #{}},
      litegate_active_streams =>
          {gauge, <<"Streaming responses in progress">>, #{}},
      litegate_redactions_total =>
          {counter, <<"Secret values replaced with placeholders before forwarding upstream">>, #{}},
      litegate_otlp_exported_total =>
          {counter, <<"Spans exported over OTLP">>, #{}},
      litegate_otlp_dropped_total =>
          {counter, <<"Spans dropped by the OTLP exporter (queue full or export failed)">>, #{}},
      litegate_otlp_stripped_total =>
          {counter, <<"Spans stripped of body content by the OTLP exporter (queue above 50% byte cap)">>, #{}},
      litegate_out_throttled_total =>
          {counter, <<"Requests throttled by the adaptive outbound rate limiter">>, #{}},
      litegate_store_degraded_total =>
          {counter, <<"Store writes degraded under backlog (level: soft drops messages, search docs and cache; hard keeps usage only; index drops search batches)">>, #{}},
      litegate_store_write_errors_total =>
          {counter, <<"Store batch write errors by cask">>, #{}},
      litegate_upstream_timeouts_total =>
          {counter, <<"Upstream timeouts and size limits by phase (first_byte, idle, total, too_large)">>, #{}},
      litegate_client_closed_total =>
          {counter, <<"Requests ended because the client disconnected before completion">>, #{}},
      litegate_classifier_skipped_total =>
          {counter, <<"Intent classification skipped because the classifier circuit breaker is open">>, #{}},
      litegate_upstream_connections_total =>
          {counter, <<"Upstream connection checkouts by result (reused from pool, new)">>, #{}},
      litegate_alert_dropped_total =>
          {counter, <<"Alert notifications dropped because the sender queue is full">>, #{}}}.

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec inc(atom(), labels()) -> ok.
inc(Name, Labels) ->
    inc(Name, Labels, 1).

-spec inc(atom(), labels(), integer()) -> ok.
inc(_Name, _Labels, 0) ->
    ok;
inc(Name, Labels, N) ->
    Key = {Name, norm(Labels)},
    _ = catch ets:update_counter(?TAB, Key, N, {Key, 0}),
    ok.

%% @doc 直方图观测；Value 为已按 scale 换算的整数（如毫秒）。
-spec observe(atom(), labels(), non_neg_integer()) -> ok.
observe(Name, Labels, Value) ->
    {histogram, _, #{buckets := Buckets} = Opts} = maps:get(Name, defs()),
    Scale = maps:get(scale, Opts, 1),
    L = norm(Labels),
    Le = case [B || B <- Buckets, Value =< B * Scale] of
             [First | _] -> First;
             [] -> inf
         end,
    _ = [catch ets:update_counter(?TAB, K, 1, {K, 0})
         || K <- [{Name, L, bucket, Le}, {Name, L, count}]],
    _ = catch ets:update_counter(?TAB, {Name, L, sum}, Value, {{Name, L, sum}, 0}),
    ok.

%% @doc 把当前进程计入计量 Name（进程退出时自动移除）。
-spec track(atom(), pid()) -> ok.
track(Name, Pid) ->
    gen_server:cast(?MODULE, {track, Name, Pid}).

-spec untrack(atom(), pid()) -> ok.
untrack(Name, Pid) ->
    gen_server:cast(?MODULE, {untrack, Name, Pid}).

%% @doc 注册抓取时计算的计量：Fun() -> [{Labels, Value}]。
-spec register_gauge(atom(), binary(), fun(() -> [{labels(), number()}])) -> ok.
register_gauge(Name, Help, Fun) ->
    persistent_term:put(?GAUGES, (gauge_callbacks())#{Name => {Help, Fun}}).

%% @doc Prometheus 文本格式。
-spec render() -> iodata().
render() ->
    Rows = ets:tab2list(?TAB),
    RowMap = maps:from_list(Rows),
    Defs = defs(),
    Static = [render_metric(Name, Def, RowMap) || Name := Def <- Defs, Name =/= litegate_active_streams],
    Tracked = [header(litegate_active_streams, gauge, element(2, maps:get(litegate_active_streams, Defs))),
               sample(litegate_active_streams, [], ets:info(?TRACK, size))],
    Callbacks = [begin
                     Samples = try Fun() catch _:_ -> [] end,
                     [header(Name, gauge, Help) | [sample(Name, norm(L), V) || {L, V} <- Samples]]
                 end || Name := {Help, Fun} <- gauge_callbacks()],
    [Static, Tracked, Callbacks, vm()].

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    _ = ets:new(?TAB, [named_table, public, {write_concurrency, true}, {read_concurrency, true}]),
    _ = ets:new(?TRACK, [named_table, protected]),
    {ok, #{}}.

handle_call(_Req, _From, S) ->
    {reply, ok, S}.

handle_cast({track, Name, Pid}, S) ->
    case ets:member(?TRACK, {Name, Pid}) of
        true -> ok;
        false -> ets:insert(?TRACK, {{Name, Pid}, monitor(process, Pid)})
    end,
    {noreply, S};
handle_cast({untrack, Name, Pid}, S) ->
    case ets:take(?TRACK, {Name, Pid}) of
        [{_, Ref}] -> demonitor(Ref, [flush]);
        [] -> ok
    end,
    {noreply, S}.

handle_info({'DOWN', Ref, process, Pid, _}, S) ->
    ets:match_delete(?TRACK, {{'_', Pid}, Ref}),
    {noreply, S};
handle_info(_Msg, S) ->
    {noreply, S}.

%%====================================================================
%% 渲染
%%====================================================================

%% @doc 指标当前值（OTLP 导出用），值已按 defs 的 scale 换算：
%% #{counters => [{Name, Labels, Value}],
%%   histograms => [{Name, Labels, #{count => N, sum => S, buckets => [{Bound, Cumulative}]}}],
%%   gauges => [{Name, Labels, Value}]}（track 计量 + 回调 gauge）
-spec snapshot() -> map().
snapshot() ->
    Rows = ets:tab2list(?TAB),
    RowMap = maps:from_list(Rows),
    Defs = defs(),
    Counters = [{N, L, scale(V, scale_of(Defs, N))}
                || {{N, L}, V} <- Rows, is_map_key(N, Defs), is_counter(maps:get(N, Defs))],
    Hist = lists:append([hist_series(Name, Def, RowMap)
                         || {Name, {histogram, _, _} = Def} <- maps:to_list(Defs)]),
    Gauges = [{litegate_active_streams, [], ets:info(?TRACK, size)}]
             ++ lists:append(
                  [begin
                       Samples = try Fun() catch _:_ -> [] end,
                       [{Name, L, V} || {L, V} <- Samples]
                   end || {Name, {_, Fun}} <- maps:to_list(gauge_callbacks())]),
    #{counters => Counters, histograms => Hist, gauges => Gauges}.

is_counter({counter, _, _}) -> true;
is_counter(_) -> false.

scale_of(Defs, N) ->
    case Defs of
        #{N := {_, _, #{scale := S}}} -> S;
        _ -> 1
    end.
hist_series(Name, {histogram, _, #{buckets := Buckets} = Opts}, RowMap) ->
    Scale = maps:get(scale, Opts, 1),
    Series = lists:usort([L || {{N, L, count}, _} <- maps:to_list(RowMap), N =:= Name]),
    [{Name, L, hist_point(Name, L, Buckets, Scale, RowMap)} || L <- Series].

hist_point(Name, L, Buckets, Scale, RowMap) ->
    Get = fun(K) -> maps:get({Name, L, K}, RowMap, 0) end,
    GetB = fun(Le) -> maps:get({Name, L, bucket, Le}, RowMap, 0) end,
    {BucketsC, _} = lists:mapfoldl(fun(Le, Acc) -> Acc1 = Acc + GetB(Le), {{Le, Acc1}, Acc1} end, 0,
                                   Buckets ++ [inf]),
    #{count => Get(count), sum => scale(Get(sum), Scale), buckets => BucketsC}.

render_metric(Name, {counter, Help, Opts}, RowMap) ->
    Scale = maps:get(scale, Opts, 1),
    [header(Name, counter, Help) |
     [sample(Name, L, scale(V, Scale)) || {{N, L}, V} <- maps:to_list(RowMap), N =:= Name]];
render_metric(Name, {histogram, Help, #{buckets := Buckets} = Opts}, RowMap) ->
    Scale = maps:get(scale, Opts, 1),
    Series = lists:usort([L || {{N, L, count}, _} <- maps:to_list(RowMap), N =:= Name]),
    [header(Name, histogram, Help) |
     [begin
          Get = fun(K) -> maps:get({Name, L, K}, RowMap, 0) end,
          GetB = fun(Le) -> maps:get({Name, L, bucket, Le}, RowMap, 0) end,
          %% 桶按累计值导出
          {Lines, _} = lists:mapfoldl(
                         fun(Le, Acc) ->
                                 Acc1 = Acc + GetB(Le),
                                 {sample(<<(atom_to_binary(Name))/binary, "_bucket">>,
                                         L ++ [{le, le(Le)}], Acc1), Acc1}
                         end, 0, Buckets ++ [inf]),
          [Lines,
           sample(<<(atom_to_binary(Name))/binary, "_sum">>, L, scale(Get(sum), Scale)),
           sample(<<(atom_to_binary(Name))/binary, "_count">>, L, Get(count))]
      end || L <- Series]].

vm() ->
    Mem = erlang:memory(),
    [header(litegate_vm_memory_bytes, gauge, <<"BEAM memory by type">>),
     [sample(litegate_vm_memory_bytes, [{type, atom_to_binary(T)}], proplists:get_value(T, Mem))
      || T <- [total, processes, binary, ets, atom, code]],
     header(litegate_vm_processes, gauge, <<"BEAM process count">>),
     sample(litegate_vm_processes, [], erlang:system_info(process_count)),
     header(litegate_vm_run_queue, gauge, <<"Total run queue length">>),
     sample(litegate_vm_run_queue, [], erlang:statistics(total_run_queue_lengths_all))].

header(Name, Type, Help) ->
    N = to_bin(Name),
    [<<"# HELP ">>, N, $\s, Help, $\n, <<"# TYPE ">>, N, $\s, atom_to_binary(Type), $\n].

sample(Name, [], V) ->
    [to_bin(Name), $\s, num(V), $\n];
sample(Name, Labels, V) ->
    Ls = lists:join($,, [[atom_to_binary(K), <<"=\"">>, escape(to_bin(Val)), $"] || {K, Val} <- Labels]),
    [to_bin(Name), ${, Ls, $}, $\s, num(V), $\n].

scale(V, 1) -> V;
scale(V, S) -> V / S.

le(inf) -> <<"+Inf">>;
le(B) -> num(B).

num(V) when is_integer(V) -> integer_to_binary(V);
num(V) when is_float(V) -> float_to_binary(V, [short]).

escape(B) ->
    binary:replace(binary:replace(binary:replace(B, <<"\\">>, <<"\\\\">>, [global]),
                                  <<"\"">>, <<"\\\"">>, [global]),
                   <<"\n">>, <<"\\n">>, [global]).

%% 标签按键排序，值统一为 binary，保证同一序列只有一个 ETS 键
norm(Labels) ->
    lists:keysort(1, [{K, to_bin(V)} || {K, V} <- Labels]).

to_bin(V) when is_binary(V) -> V;
to_bin(V) when is_atom(V) -> atom_to_binary(V);
to_bin(V) when is_integer(V) -> integer_to_binary(V);
to_bin(V) when is_list(V) -> unicode:characters_to_binary(V).

gauge_callbacks() ->
    persistent_term:get(?GAUGES, #{}).
