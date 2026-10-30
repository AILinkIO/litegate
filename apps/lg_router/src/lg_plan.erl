%% @doc 订阅套餐额度状态：定期查询配置了 options.plan 的凭证，结果缓存在 ETS。
%%
%% - 轮询间隔 plan_poll_interval_ms（默认 5 分钟，0 = 只在请求后与手动刷新时查询）
%% - touched/1：请求结束后调用，距上次查询超过 1 分钟则异步刷新（额度跟着用量走）
%% - 查询失败只记录错误，保留上次的窗口数据
%% - 查询在每凭证一个的 worker 进程里执行（同时最多一个），本进程只调度与写结果，不被网络 I/O 阻塞；
%%   ETS 中的 {refreshing, CredId} 标记去重：请求路径上的刷新在标记已存在时直接跳过
%% - state/1：路由用，normal | reserve | {exhausted, ResetsAt}
-module(lg_plan).
-behaviour(gen_server).

-include_lib("lg_core/include/lg_core.hrl").

-export([start_link/0, status/1, all/0, refresh/1, touched/1, quota_error/1, exhausted/1, state/1, plan_of/1, validate/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, lg_plan_status).  %% {CredId, StatusMap} | {{refreshing, CredId}, StartedAt}
-define(MIN_GAP_MS, 60000).
-define(ERROR_GAP_MS, 10000).
-define(EXHAUSTED_GAP_MS, 2000).

-type status() :: #{kind := binary(), reserve_pct := 0..100, level := binary() | null,
                    windows := [lg_plan_quota:window()],
                    fetched_at := non_neg_integer() | null, error := binary() | null,
                    checked_at := non_neg_integer()}.

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc 凭证的套餐配置（options.plan），没有则 undefined。
-spec plan_of(#lg_credential{}) -> map() | undefined.
plan_of(#lg_credential{options = #{plan := #{<<"kind">> := _} = P}}) -> P;
plan_of(_) -> undefined.

%% @doc 校验 options.plan 输入：#{kind := minimax | glm, reserve_pct => 0..100,
%% window_caps => #{窗口名 => 0..100}}（按窗口的使用上限，超过即进入保留层）。
-spec validate(term()) -> boolean().
validate(#{<<"kind">> := K} = P) ->
    Pct = fun(R) -> is_integer(R) andalso R >= 0 andalso R =< 100 end,
    lists:member(K, lg_plan_quota:kinds())
        andalso maps:size(maps:without([<<"kind">>, <<"reserve_pct">>, <<"window_caps">>], P)) =:= 0
        andalso Pct(maps:get(<<"reserve_pct">>, P, 0))
        andalso case maps:get(<<"window_caps">>, P, #{}) of
                    Caps when is_map(Caps) -> lists:all(fun({N, V}) -> is_binary(N) andalso Pct(V) end, maps:to_list(Caps));
                    _ -> false
                end;
validate(_) ->
    false.

-spec status(binary()) -> status() | undefined.
status(CredId) ->
    case catch ets:lookup(?TAB, CredId) of
        [{_, S}] -> S;
        _ -> undefined
    end.

%% @doc 全部套餐凭证的状态（未查询过的也列出）；refreshing 表示查询进行中。
-spec all() -> [map()].
all() ->
    [(case status(Id) of undefined -> #{}; S -> S end)#{credential => Id, credential_name => N,
                                                        kind => maps:get(<<"kind">>, P),
                                                        reserve_pct => maps:get(<<"reserve_pct">>, P, 0),
                                                        state => state_json(state(Id)),
                                                        refreshing => refreshing(Id)}
     || #lg_credential{id = Id, name = N} = C <- lg_credentials:list(), P <- [plan_of(C)], P =/= undefined].

%% @doc 立即刷新：等待对应 worker 完成（进行中的查询结束后再查一次，保证读到点击之后的数据）；
%% 超过连接超时 + 10 秒仍未完成则返回 {ok, refreshing}，结果稍后写入。
-spec refresh(all | [binary()]) -> ok | {ok, refreshing}.
refresh(Which) ->
    try gen_server:call(?MODULE, {refresh, Which}, lg_config:get(upstream_connect_timeout_ms) + 10000)
    catch exit:{timeout, _} -> {ok, refreshing}
    end.

refreshing(CredId) ->
    case catch ets:member(?TAB, {refreshing, CredId}) of
        true -> true;
        _ -> false
    end.

%% @doc 请求结束后调用；是套餐凭证且距上次查询足够久时异步刷新。
-spec touched(binary()) -> ok.
touched(CredId) ->
    refresh_after(CredId, ?MIN_GAP_MS).

%% @doc 套餐凭证被上游限流：额度可能刚用尽，距上次查询超过 10 秒即刷新。
-spec quota_error(binary()) -> ok.
quota_error(CredId) ->
    refresh_after(CredId, ?ERROR_GAP_MS).

%% @doc 套餐凭证返回额度用尽 / 余额不足：立即刷新（2 秒内去重），以便读到重置时刻。
-spec exhausted(binary()) -> ok.
exhausted(CredId) ->
    refresh_after(CredId, ?EXHAUSTED_GAP_MS).

%% 已在刷新（标记存在）则跳过；标记由本进程在 worker 结束（成功、失败、超时、崩溃）后删除
refresh_after(CredId, Gap) ->
    case status(CredId) of
        #{checked_at := At} ->
            Now = lg_time:now_ms(),
            case Now - At > Gap andalso (catch ets:insert_new(?TAB, {{refreshing, CredId}, Now})) =:= true of
                true -> gen_server:cast(?MODULE, {refresh_after, CredId, Gap});
                false -> ok
            end;
        undefined ->
            ok
    end.

%% @doc 路由用的额度状态：任一窗口用尽 → exhausted（到最晚的重置时刻），
%% 任一窗口 used_pct ≥ 100 - reserve_pct（reserve_pct > 0）或超过该窗口的 window_caps → reserve。
-spec state(binary()) -> normal | reserve | {exhausted, non_neg_integer() | null}.
state(CredId) ->
    case status(CredId) of
        #{windows := Ws, reserve_pct := Reserve} = St ->
            Now = lg_time:now_ms(),
            Live = [W || #{resets_at := R} = W <- Ws, R =:= null orelse R > Now],
            case [R || #{used_pct := U, resets_at := R} <- Live, U >= 100] of
                [_ | _] = Rs ->
                    {exhausted, case [R || R <- Rs, is_integer(R)] of [] -> null; Ts -> lists:max(Ts) end};
                [] ->
                    Caps = maps:get(window_caps, St, #{}),
                    Over = fun(#{name := N, used_pct := U}) ->
                                   (Reserve > 0 andalso U >= 100 - Reserve)
                                       orelse case maps:find(N, Caps) of
                                                  {ok, Cap} -> U >= Cap;
                                                  error -> false
                                              end
                           end,
                    case lists:any(Over, Live) of
                        true -> reserve;
                        false -> normal
                    end
            end;
        _ ->
            normal
    end.

%%====================================================================
%% gen_server
%%====================================================================

%% State：workers => #{CredId => Worker}，calls => #{From => 尚未完成的凭证数}
%% Worker：#{pid, mref, timer, cred, plan, waiters => [From]（本轮结束时通知），
%%          again => [From] | false（进行中又被手动 / 配置变更触发：结束后再查一轮）}
init([]) ->
    _ = ets:new(?TAB, [named_table, public, {read_concurrency, true}]),
    self() ! poll,
    {ok, #{workers => #{}, calls => #{}}}.

%% 控制台刷新：全部目标结束后才回复
handle_call({refresh, Which}, From, S) ->
    {Ids, S1} = start(Which, {force, From}, S),
    case Ids of
        [] -> {reply, ok, S1};
        _ -> {noreply, S1#{calls => (maps:get(calls, S1))#{From => length(Ids)}}}
    end.

%% 请求路径（refresh_after）：调用方已放置标记；排队期间可能已被别的消息刷新过，再判一次间隔
handle_cast({refresh_after, Id, Gap}, #{workers := Ws} = S) ->
    Due = case status(Id) of
              #{checked_at := At} -> lg_time:now_ms() - At > Gap;
              undefined -> false
          end,
    S1 = case Due andalso not maps:is_key(Id, Ws) of
             true -> element(2, start([Id], plain, S));
             false -> S
         end,
    settle(Id, S1),
    {noreply, S1};
%% 配置变更（lg_credentials）：进行中的查询可能用的是旧配置，结束后再查一轮
handle_cast({refresh, Which}, S) ->
    {noreply, element(2, start(Which, {force, undefined}, S))}.

handle_info(poll, S) ->
    {_, S1} = start(all, plain, S),
    schedule(),
    {noreply, S1};
handle_info(poll_check, S) ->
    schedule(),
    {noreply, S};
handle_info({fetched, Pid, Res}, S) ->
    {noreply, case worker_by(pid, Pid, S) of
                  {ok, Id, MRef} -> erlang:demonitor(MRef, [flush]), done(Id, Res, S);
                  error -> S
              end};
%% worker 没送回结果就退出（被 kill 等）
handle_info({'DOWN', MRef, process, _, Reason}, S) ->
    {noreply, case worker_by(mref, MRef, S) of
                  {ok, Id, _} -> done(Id, {worker_down, Reason}, S);
                  error -> S
              end};
handle_info({fetch_timeout, Id, MRef}, #{workers := Ws} = S) ->
    {noreply, case maps:find(Id, Ws) of
                  {ok, #{mref := MRef, pid := Pid}} ->
                      erlang:demonitor(MRef, [flush]),
                      exit(Pid, kill),
                      done(Id, timeout, S);
                  _ -> S
              end};
handle_info(_Msg, S) ->
    {noreply, S}.

%%====================================================================
%% 内部函数
%%====================================================================

schedule() ->
    case lg_config:get(plan_poll_interval_ms) of
        N when is_integer(N), N > 0 -> _ = erlang:send_after(N, self(), poll), ok;
        _ -> _ = erlang:send_after(60000, self(), poll_check), ok
    end.

%% 为目标凭证启动 worker，返回需要等待的凭证。Mode：plain（进行中则跳过）| {force, From | undefined}
start(Which, Mode, #{workers := Ws0} = S) ->
    All = lg_credentials:list(),
    Known = [Id || #lg_credential{id = Id} = C <- All, plan_of(C) =/= undefined],
    %% 已不再是套餐凭证的状态清掉
    [ets:delete(?TAB, Id) || {Id, _} <- ets:tab2list(?TAB), is_binary(Id), not lists:member(Id, Known)],
    Creds = [{C, P} || #lg_credential{id = Id, enabled = true} = C <- All,
                       P <- [plan_of(C)], P =/= undefined,
                       Which =:= all orelse lists:member(Id, Which)],
    Waiters = case Mode of {force, From} when From =/= undefined -> [From]; _ -> [] end,
    Ws = lists:foldl(
           fun({#lg_credential{id = Id} = C, P}, Acc) ->
                   case {maps:find(Id, Acc), Mode} of
                       {error, _} ->
                           Acc#{Id => spawn_worker(C, P, Waiters)};
                       {{ok, W}, plain} ->
                           Acc#{Id => W#{waiters => maps:get(waiters, W) ++ Waiters}};
                       {{ok, #{again := Again} = W}, {force, _}} ->
                           Acc#{Id => W#{again => case Again of false -> Waiters; _ -> Again ++ Waiters end}}
                   end
           end, Ws0, Creds),
    {[Id || {#lg_credential{id = Id}, _} <- Creds], S#{workers => Ws}}.

spawn_worker(#lg_credential{id = Id} = C, P, Waiters) ->
    Timeout = lg_config:get(upstream_connect_timeout_ms),
    Kind = binary_to_existing_atom(maps:get(<<"kind">>, P)),
    ets:insert(?TAB, {{refreshing, Id}, lg_time:now_ms()}),
    Srv = self(),
    {Pid, MRef} = spawn_monitor(fun() -> Srv ! {fetched, self(), catch lg_plan_quota:fetch(Kind, C, Timeout)} end),
    Timer = erlang:send_after(Timeout + 5000, self(), {fetch_timeout, Id, MRef}),
    #{pid => Pid, mref => MRef, timer => Timer, cred => C, plan => P, waiters => Waiters, again => false}.

worker_by(Key, V, #{workers := Ws}) ->
    case [{Id, M} || {Id, #{mref := M} = W} <- maps:to_list(Ws), maps:get(Key, W) =:= V] of
        [{Id, M}] -> {ok, Id, M};
        [] -> error
    end.

%% worker 结束：写结果、通知等待者；需要再查一轮则重新启动，否则清除标记
done(Id, Res, #{workers := Ws, calls := Calls} = S) ->
    #{timer := Timer, cred := C, plan := P, waiters := Waiters, again := Again} = maps:get(Id, Ws),
    _ = erlang:cancel_timer(Timer),
    collect(C, P, Res),
    S1 = S#{workers => maps:remove(Id, Ws), calls => lists:foldl(fun notify/2, Calls, Waiters)},
    S2 = case Again of
             false -> S1;
             Next -> rerun(Id, Next, S1)
         end,
    settle(Id, S2),
    S2.

%% 再查一轮（重新读取凭证配置）；Next 是等这一轮结果的控制台调用
rerun(Id, Next, S) ->
    {_, #{workers := Ws, calls := Calls} = S1} = start([Id], {force, undefined}, S),
    case maps:find(Id, Ws) of
        {ok, W} -> S1#{workers => Ws#{Id => W#{waiters => Next}}};
        %% 凭证已停用或不再是套餐凭证
        error -> S1#{calls => lists:foldl(fun notify/2, Calls, Next)}
    end.

notify(From, Calls) ->
    case maps:find(From, Calls) of
        {ok, 1} -> gen_server:reply(From, ok), maps:remove(From, Calls);
        {ok, N} -> Calls#{From => N - 1};
        error -> Calls
    end.

%% 没有 worker 在跑时清除刷新标记
settle(Id, #{workers := Ws}) ->
    case maps:is_key(Id, Ws) of
        true -> ok;
        false -> ets:delete(?TAB, {refreshing, Id}), ok
    end.

collect(#lg_credential{id = Id, name = Name}, P, Res) ->
    Now = lg_time:now_ms(),
    Prev = case status(Id) of
               undefined -> #{windows => [], level => null, fetched_at => null};
               S -> S
           end,
    Base = Prev#{kind => maps:get(<<"kind">>, P), reserve_pct => maps:get(<<"reserve_pct">>, P, 0),
                 window_caps => maps:get(<<"window_caps">>, P, #{}), checked_at => Now},
    New = case Res of
              {ok, #{windows := W, level := L}} ->
                  Base#{windows => W, level => L, fetched_at => Now, error => null};
              {error, Msg} when is_binary(Msg) ->
                  Base#{error => Msg};
              timeout ->
                  Base#{error => <<"timeout">>};
              Other ->
                  Base#{error => iolist_to_binary(io_lib:format("~0p", [Other]))}
          end,
    ets:insert(?TAB, {Id, New}),
    %% 额度已恢复（没有用满的窗口）：解除因额度用尽的凭证冷却
    case state(Id) of
        {exhausted, _} -> ok;
        _ -> lg_cooldown:recovered(Id)
    end,
    lg_alert:plan_status(Id, Name, New).

state_json(normal) -> <<"normal">>;
state_json(reserve) -> <<"reserve">>;
state_json({exhausted, _}) -> <<"exhausted">>.
