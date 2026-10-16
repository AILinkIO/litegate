%% @doc 上游健康：按 {凭证, 上游模型} 统计最近 5 分钟的尝试结果，记录最近的错误；可选主动探活。
%%
%% - record/4 由 lg_router 在每次上游尝试后调用：ETS 按分钟分桶原子累加（成功、失败、总耗时、各错误类型）
%% - snapshot/0：路由表中配置的目标 + 最近出现过的目标（含通配代入的真实模型），附冷却剩余时间
%% - 主动探活：probe_interval_ms > 0 时周期性对每个启用的凭证请求模型列表（并行），结果单独记录，不影响冷却
-module(lg_health).
-behaviour(gen_server).

-include_lib("lg_core/include/lg_core.hrl").

-export([start_link/0, record/4, snapshot/0, probes/0, probe_now/0, probe_now/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(WIN, lg_health_win).      %% {{Target, Minute}, Ok, Err, SumMs, RateLimit, Server, Network, Timeout, Auth, Client, Internal, Credit, Quota, Unserved}
-define(LAST, lg_health_last).    %% {{Target, ok | error}, AtMs, Kind, Message}
-define(PROBE, lg_health_probe).  %% {CredId, AtMs, ok | Kind, Message, LatencyMs}
-define(WINDOW_MIN, 5).
-define(KINDS, [rate_limit, credit, quota, unserved, server, network, timeout, auth, client, internal]).

-type target() :: {binary(), binary()}.

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc 记录一次上游尝试。Outcome：ok 或错误类型；Message：错误消息（可无）。
-spec record(target(), ok | atom(), non_neg_integer(), binary() | undefined) -> ok.
record(T, Outcome, DurationMs, Message) ->
    Now = lg_time:now_ms(),
    Key = {T, Now div 60000},
    Incr = case Outcome of
               ok -> [{2, 1}, {4, DurationMs}];
               Kind -> [{3, 1}, {4, DurationMs}, {kind_pos(Kind), 1}]
           end,
    _ = catch ets:update_counter(?WIN, Key, Incr, list_to_tuple([Key | lists:duplicate(13, 0)])),
    _ = case Outcome of
            ok -> catch ets:insert(?LAST, {{T, ok}, Now, ok, undefined});
            _ -> catch ets:insert(?LAST, {{T, error}, Now, Outcome, Message})
        end,
    lg_alert:target_result(T, Outcome, Message).

%% @doc 每个目标的健康状况。
-spec snapshot() -> [map()].
snapshot() ->
    Now = lg_time:now_ms(),
    From = Now div 60000 - ?WINDOW_MIN + 1,
    Rows = [R || {{_, M}, _, _, _, _, _, _, _, _, _, _, _, _, _} = R <- ets:tab2list(?WIN), M >= From],
    Configured = [{C, M} || #lg_route{targets = Ts} <- lg_routes:list(),
                            #{credential := C, upstream_model := M} <- Ts, M =/= <<"*">>],
    Observed = [T || {{T, _}, _, _, _, _, _, _, _, _, _, _, _, _, _} <- Rows]
        ++ [T || {{T, _}, _, _, _} <- ets:tab2list(?LAST)],
    Creds = maps:from_list([{Id, C} || #lg_credential{id = Id} = C <- lg_credentials:list()]),
    [target_row(T, Rows, Creds, Now) || {C, _} = T <- lists:usort(Configured ++ Observed),
                                        maps:is_key(C, Creds)].

%% @doc 各凭证最近一次探活结果。
-spec probes() -> [map()].
probes() ->
    [#{credential => Id, at => At, result => R, message => M, latency_ms => L}
     || {Id, At, R, M, L} <- ets:tab2list(?PROBE)].

%% @doc 立即对全部启用的凭证探活（并行，最多等待超时时间）。
-spec probe_now() -> [map()].
probe_now() ->
    probe_now(all).

%% @doc 只探活指定的凭证。
-spec probe_now(all | [binary()]) -> [map()].
probe_now(Which) ->
    gen_server:call(?MODULE, {probe, Which}, 60000),
    probes().

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    _ = ets:new(?WIN, [named_table, public, {write_concurrency, true}]),
    _ = ets:new(?LAST, [named_table, public, {write_concurrency, true}]),
    _ = ets:new(?PROBE, [named_table, public]),
    erlang:send_after(60000, self(), sweep),
    schedule_probe(),
    {ok, #{}}.

handle_call({probe, Which}, _From, S) ->
    run_probes(Which),
    {reply, ok, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(sweep, S) ->
    Old = lg_time:now_ms() div 60000 - ?WINDOW_MIN,
    ets:select_delete(?WIN, [{{{'_', '$1'}, '_', '_', '_', '_', '_', '_', '_', '_', '_', '_', '_', '_', '_'},
                              [{'<', '$1', Old}], [true]}]),
    erlang:send_after(60000, self(), sweep),
    {noreply, S};
handle_info(probe, S) ->
    run_probes(all),
    schedule_probe(),
    {noreply, S};
%% 探活关闭时每分钟检查一次配置，开启后按间隔运行
handle_info(probe_check, S) ->
    schedule_probe(),
    {noreply, S};
handle_info(_Msg, S) ->
    {noreply, S}.

%%====================================================================
%% 内部函数
%%====================================================================

schedule_probe() ->
    case lg_config:get(probe_interval_ms) of
        N when is_integer(N), N > 0 -> _ = erlang:send_after(N, self(), probe), ok;
        _ -> _ = erlang:send_after(60000, self(), probe_check), ok
    end.

run_probes(Which) ->
    Timeout = lg_config:get(upstream_connect_timeout_ms),
    Creds = [C || #lg_credential{enabled = true, id = Id} = C <- lg_credentials:list(),
                  Which =:= all orelse lists:member(Id, Which)],
    Parent = self(),
    Refs = [begin
                Ref = make_ref(),
                spawn(fun() ->
                              T0 = lg_time:now_ms(),
                              R = catch lg_provider:probe(C, Timeout),
                              Parent ! {Ref, C#lg_credential.id, R, lg_time:now_ms() - T0}
                      end),
                Ref
            end || C <- Creds],
    Deadline = lg_time:now_ms() + Timeout + 5000,
    lists:foreach(fun(Ref) -> collect(Ref, Deadline) end, Refs).

collect(Ref, Deadline) ->
    receive
        {Ref, Id, R, Ms} ->
            {Result, Msg} = case R of
                                ok -> {ok, undefined};
                                {error, #{kind := K, message := M}} -> {K, M};
                                Other -> {internal, iolist_to_binary(io_lib:format("~0p", [Other]))}
                            end,
            ets:insert(?PROBE, {Id, lg_time:now_ms(), Result, Msg, Ms})
    after max(0, Deadline - lg_time:now_ms()) ->
        ok
    end.

target_row({C, M} = T, Rows, Creds, _Now) ->
    Mine = [R || {{T1, _}, _, _, _, _, _, _, _, _, _, _, _, _, _} = R <- Rows, T1 =:= T],
    Sum = fun(Pos) -> lists:sum([element(Pos, R) || R <- Mine]) end,
    Ok = Sum(2),
    Err = Sum(3),
    #lg_credential{name = CName, protocol = Proto} = Cred = maps:get(C, Creds),
    Errors = maps:filter(fun(_, V) -> V > 0 end,
                         maps:from_list([{K, Sum(kind_pos(K))} || K <- ?KINDS])),
    Base = #{credential => C, credential_name => CName, protocol => Proto, upstream_model => M,
             ok => Ok, errors => Err, error_kinds => Errors,
             success_rate => case Ok + Err of 0 -> null; N -> Ok / N end,
             avg_ms => case Ok + Err of 0 -> null; N2 -> round(Sum(4) / N2) end,
             cooldown_ms => lg_cooldown:remaining_ms(T),
             cooldown => cooldown_info(T),
             concurrency => case lg_conc:max_of(Cred) of
                                0 -> null;
                                Max -> #{inflight => lg_conc:inflight(C), queued => lg_conc:queued(C), max => Max}
                            end,
             plan_state => plan_state(Cred)},
    Base1 = case ets:lookup(?LAST, {T, error}) of
                [{_, At, K, Msg}] -> Base#{last_error => #{at => At, kind => K, message => Msg}};
                [] -> Base#{last_error => null}
            end,
    case ets:lookup(?LAST, {T, ok}) of
        [{_, At2, _, _}] -> Base1#{last_ok_at => At2};
        [] -> Base1#{last_ok_at => null}
    end.

cooldown_info(T) ->
    case lg_cooldown:info(T) of
        undefined -> null;
        #{} = I -> I
    end.

%% 套餐凭证的额度状态：normal | reserve | exhausted；非套餐凭证为 null
plan_state(Cred) ->
    case lg_plan:plan_of(Cred) of
        undefined -> null;
        _ ->
            case lg_plan:state(Cred#lg_credential.id) of
                {exhausted, _} -> exhausted;
                S -> S
            end
    end.

kind_pos(rate_limit) -> 5;
kind_pos(server) -> 6;
kind_pos(network) -> 7;
kind_pos(timeout) -> 8;
kind_pos(auth) -> 9;
kind_pos(client) -> 10;
kind_pos(credit) -> 12;
kind_pos(quota) -> 13;
kind_pos(unserved) -> 14;
kind_pos(_) -> 11.
