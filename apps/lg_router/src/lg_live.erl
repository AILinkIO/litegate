%% @doc 实时事件流：网关正在做什么（控制台「路由视图」页）。
%%
%% - 事件用 OTP pg（scope lg_live_pg，组 events）广播给订阅者（控制台的 SSE 连接）；没有订阅者时只查一次组成员
%% - 订阅者邮箱积压超过 1000 条时丢弃新事件并计数（lg_live_dropped），订阅者在下一条事件里带上丢弃数，不拖慢网关
%% - 进行中的请求存在 lg_live_active；最近的请求数 / 改道数 / 错误数按 10 秒分桶存在 lg_live_stats，保留 30 分钟
%%
%% 事件（都带 request_id、route、ts）：request_start、decision、attempt_start、attempt_end、request_end
-module(lg_live).
-behaviour(gen_server).

-export([start_link/0, subscribe/0, unsubscribe/0, dropped/0,
         request_start/2, decision/2, attempt_start/2, attempt_end/2, request_end/2, state/0, state/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include_lib("lg_core/include/lg_core.hrl").

-define(SCOPE, lg_live_pg).
-define(GROUP, events).
-define(ACTIVE, lg_live_active).     %% {RequestId, Map}
-define(STATS, lg_live_stats).       %% {{Route, Client, KeyName, Bucket}, Requests, Reroutes, Errors}；另存 {{last, Route}, Narrative, Ts}
-define(DROPPED, lg_live_dropped).   %% {Pid, Count}
-define(BUCKET_MS, 10000).
-define(WINDOW_MS, 300000).
-define(KEEP_MS, 1800000).
-define(MAX_BACKLOG, 1000).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%====================================================================
%% 订阅
%%====================================================================

-spec subscribe() -> ok.
subscribe() ->
    ok = pg:join(?SCOPE, ?GROUP, self()).

-spec unsubscribe() -> ok.
unsubscribe() ->
    _ = pg:leave(?SCOPE, ?GROUP, self()),
    _ = ets:delete(?DROPPED, self()),
    ok.

%% @doc 调用进程（订阅者）自上次查询以来被丢弃的事件数，查询后清零。
-spec dropped() -> non_neg_integer().
dropped() ->
    case ets:take(?DROPPED, self()) of
        [{_, N}] -> N;
        [] -> 0
    end.

%%====================================================================
%% 事件
%%====================================================================

-spec request_start(binary() | undefined, map()) -> ok.
request_start(undefined, _) -> ok;
request_start(Id, Info) ->
    Now = lg_time:now_ms(),
    A = maps:merge(#{request_id => Id, started_at => Now, state => waiting}, Info),
    catch ets:insert(?ACTIVE, {Id, A}),
    publish(request_start, A).

%% @doc Info：route（解析后的路由）、candidates（plan_trace）、rule、routed_to、affinity。
-spec decision(binary() | undefined, map()) -> ok.
decision(undefined, _) -> ok;
decision(Id, Info) ->
    update(Id, maps:with([route], Info)),
    publish(decision, Info#{request_id => Id}).

-spec attempt_start(binary() | undefined, map()) -> ok.
attempt_start(undefined, _) -> ok;
attempt_start(Id, Info) ->
    update(Id, (maps:with([credential, upstream_model], Info))#{state => attempting}),
    publish(attempt_start, Info#{request_id => Id}).

-spec attempt_end(binary() | undefined, map()) -> ok.
attempt_end(undefined, _) -> ok;
attempt_end(Id, Info) ->
    case maps:get(ok, Info, false) of
        true -> ok;                                   %% 成功开流 / 返回：仍在回答（流式），等 request_end
        false -> update(Id, #{state => waiting})
    end,
    publish(attempt_end, Info#{request_id => Id}).

%% @doc Info：route、client、key_name、status、attempts、error、usage、cost、duration_ms、ttft_ms、narrative。
-spec request_end(binary() | undefined, map()) -> ok.
request_end(undefined, _) -> ok;
request_end(Id, Info) ->
    Active = case catch ets:take(?ACTIVE, Id) of
                 [{_, A}] -> A;
                 _ -> #{}
             end,
    Route = maps:get(route, Info, maps:get(route, Active, <<>>)),
    Client = maps:get(client, Info, maps:get(client, Active, null)),
    KeyName = maps:get(key_name, Info, maps:get(key_name, Active, null)),
    Bucket = lg_time:now_ms() div ?BUCKET_MS,
    Reroute = case maps:get(attempts, Info, 1) of N when is_integer(N), N > 1 -> 1; _ -> 0 end,
    Err = case maps:get(status, Info, 200) of S when S >= 400 -> 1; _ -> 0 end,
    K = {Route, Client, KeyName, Bucket},
    catch ets:update_counter(?STATS, K, [{2, 1}, {3, Reroute}, {4, Err}], {K, 0, 0, 0}),
    %% 每条路由最近一次请求的叙述（快照带上，页面打开时就有内容）
    case maps:get(narrative, Info, []) of
        [_ | _] = Lines -> catch ets:insert(?STATS, {{last, Route}, Lines, lg_time:now_ms()});
        _ -> ok
    end,
    publish(request_end, Info#{request_id => Id, route => Route, client => Client, key_name => KeyName}).

update(Id, Patch) ->
    case catch ets:lookup(?ACTIVE, Id) of
        [{_, A}] -> catch ets:insert(?ACTIVE, {Id, maps:merge(A, Patch)});
        _ -> ok
    end,
    ok.

publish(Type, Data) ->
    case catch pg:get_members(?SCOPE, ?GROUP) of
        [_ | _] = Pids ->
            Ev = #{type => Type, ts => lg_time:now_ms(), data => Data},
            lists:foreach(fun(P) ->
                                  case erlang:process_info(P, message_queue_len) of
                                      {message_queue_len, N} when N > ?MAX_BACKLOG ->
                                          catch ets:update_counter(?DROPPED, P, 1, {P, 0});
                                      undefined -> ok;
                                      _ -> P ! {lg_live, Ev}
                                  end
                          end, Pids);
        _ -> ok
    end,
    ok.

%%====================================================================
%% 快照
%%====================================================================

-spec state() -> map().
state() ->
    state(#{}).

%% @doc 快照：每条路由最近 5 分钟的计数与客户端、进行中的请求、每个目标的实时状态。
%% Opts：route => 只给出该路由的目标状态（不给时为最近最忙的路由）。
-spec state(map()) -> map().
state(Opts) ->
    Now = lg_time:now_ms(),
    From = (Now - ?WINDOW_MS) div ?BUCKET_MS,
    Rows = [R || {{_, _, _, B}, _, _, _} = R <- ets:tab2list(?STATS), B >= From],
    Active = [A || {_, A} <- ets:tab2list(?ACTIVE)],
    ByRoute = lists:foldl(
                fun({{Route, Client, KeyName, _}, Req, Rer, Err}, Acc) ->
                        R0 = maps:get(Route, Acc, #{route => Route, requests => 0, reroutes => 0, errors => 0, clients => #{}}),
                        Cs = maps:get(clients, R0),
                        CK = {Client, KeyName},
                        C0 = maps:get(CK, Cs, #{client => Client, key_name => KeyName, requests => 0}),
                        Acc#{Route => R0#{requests => maps:get(requests, R0) + Req,
                                          reroutes => maps:get(reroutes, R0) + Rer,
                                          errors => maps:get(errors, R0) + Err,
                                          clients => Cs#{CK => C0#{requests => maps:get(requests, C0) + Req}}}}
                end, #{}, Rows),
    %% 进行中的请求也算进路由与客户端（还没有计数时）
    ByRoute1 = lists:foldl(
                 fun(#{route := Route} = A, Acc) ->
                         R0 = maps:get(Route, Acc, #{route => Route, requests => 0, reroutes => 0, errors => 0, clients => #{}}),
                         Cs = maps:get(clients, R0),
                         CK = {maps:get(client, A, null), maps:get(key_name, A, null)},
                         C0 = maps:get(CK, Cs, #{client => element(1, CK), key_name => element(2, CK), requests => 0}),
                         Acc#{Route => R0#{clients => Cs#{CK => C0}}};
                    (_, Acc) -> Acc
                 end, ByRoute, Active),
    Routes = lists:reverse(lists:keysort(1, [{maps:get(requests, R), R#{clients => [C#{active => count_active(Active, R, C)}
                                                                                    || C <- maps:values(maps:get(clients, R))],
                                                                       active => length([x || #{route := Rt} <- Active, Rt =:= maps:get(route, R)])}}
                                             || R <- maps:values(ByRoute1)])),
    RouteList = [R || {_, R} <- Routes],
    Selected = case maps:get(route, Opts, undefined) of
                   %% 没有流量时取第一条配置的路由（与控制台路由列表的默认项一致）
                   undefined -> case RouteList of
                                    [#{route := R1} | _] -> R1;
                                    [] -> case lg_routes:list() of
                                              [#lg_route{name = R0} | _] -> R0;
                                              [] -> undefined
                                          end
                                end;
                   R2 -> R2
               end,
    #{routes => RouteList,
      active => Active,
      selected => Selected,
      targets => case Selected of
                     undefined -> [];
                     _ -> targets(Selected, Active)
                 end,
      last => case ets:lookup(?STATS, {last, Selected}) of
                  [{_, N, Ts}] -> #{route => Selected, narrative => N, ts => Ts};
                  [] -> null
              end,
      window_ms => ?WINDOW_MS}.

count_active(Active, #{route := Route}, #{client := C, key_name := K}) ->
    length([x || #{route := R} = A <- Active, R =:= Route, maps:get(client, A, null) =:= C,
                 maps:get(key_name, A, null) =:= K]).

%% 路由当前的候选顺序（含额度用尽的目标）与每个目标的实时状态
targets(RouteName, Active) ->
    case lg_routes:get(RouteName) of
        {ok, R} ->
            [begin
                 Key = {C#lg_credential.id, maps:get(upstream_model, T)},
                 Answering = length([x || #{state := attempting, credential := AC, upstream_model := AM} <- Active,
                                          {AC, AM} =:= Key]),
                 Max = lg_conc:max_of(C),
                 Cool = lg_cooldown:info(Key),
                 State = if
                             Answering > 0 -> answering;
                             Tier =:= exhausted -> exhausted;
                             Cool =/= undefined -> cooling;
                             true -> idle
                         end,
                 maps:merge(#{route => Rn, credential => C#lg_credential.id, credential_name => C#lg_credential.name,
                              upstream_model => maps:get(upstream_model, T), tier => Tier, state => State,
                              answering => Answering, cooldown => case Cool of undefined -> null; _ -> Cool end,
                              concurrency => case Max of
                                                 0 -> null;
                                                 _ -> #{inflight => lg_conc:inflight(C#lg_credential.id),
                                                        queued => lg_conc:queued(C#lg_credential.id), max => Max}
                                             end,
                              note => lg_strategy:note(C)},
                            maps:with([via], T))
             end || {Rn, T, C, Tier} <- lg_router:candidates(R)];
        not_found -> []
    end.

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    ?ACTIVE = ets:new(?ACTIVE, [named_table, public, {write_concurrency, true}, {read_concurrency, true}]),
    ?STATS = ets:new(?STATS, [named_table, public, {write_concurrency, true}]),
    ?DROPPED = ets:new(?DROPPED, [named_table, public, {write_concurrency, true}]),
    _ = erlang:send_after(60000, self(), prune),
    {ok, #{}}.

handle_call(_Req, _From, S) ->
    {reply, ok, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

%% 清理过期的计数与异常残留的进行中请求（超过上游超时仍未结束）
handle_info(prune, S) ->
    Now = lg_time:now_ms(),
    Old = (Now - ?KEEP_MS) div ?BUCKET_MS,
    _ = ets:select_delete(?STATS, [{{{'_', '_', '_', '$1'}, '_', '_', '_'}, [{'<', '$1', Old}], [true]}]),
    Stale = Now - lg_config:get(upstream_timeout_ms) - 60000,
    _ = [ets:delete(?ACTIVE, Id) || {Id, #{started_at := At}} <- ets:tab2list(?ACTIVE), At < Stale],
    _ = [ets:delete(?DROPPED, P) || {P, _} <- ets:tab2list(?DROPPED), not is_process_alive(P)],
    _ = erlang:send_after(60000, self(), prune),
    {noreply, S};
handle_info(_Msg, S) ->
    {noreply, S}.
