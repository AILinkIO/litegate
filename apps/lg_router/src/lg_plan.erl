%% @doc 订阅套餐额度状态：定期查询配置了 options.plan 的凭证，结果缓存在 ETS。
%%
%% - 轮询间隔 plan_poll_interval_ms（默认 5 分钟，0 = 只在请求后与手动刷新时查询）
%% - touched/1：请求结束后调用，距上次查询超过 1 分钟则异步刷新（额度跟着用量走）
%% - 查询失败只记录错误，保留上次的窗口数据
%% - state/1：路由用，normal | reserve | {exhausted, ResetsAt}
-module(lg_plan).
-behaviour(gen_server).

-include_lib("lg_core/include/lg_core.hrl").

-export([start_link/0, status/1, all/0, refresh/1, touched/1, quota_error/1, exhausted/1, state/1, plan_of/1, validate/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, lg_plan_status).  %% {CredId, StatusMap}
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

%% @doc 全部套餐凭证的状态（未查询过的也列出）。
-spec all() -> [map()].
all() ->
    [(case status(Id) of undefined -> #{}; S -> S end)#{credential => Id, credential_name => N,
                                                        kind => maps:get(<<"kind">>, P),
                                                        reserve_pct => maps:get(<<"reserve_pct">>, P, 0),
                                                        state => state_json(state(Id))}
     || #lg_credential{id = Id, name = N} = C <- lg_credentials:list(), P <- [plan_of(C)], P =/= undefined].

%% @doc 立即刷新（同步，最多等待连接超时 + 5 秒）。
-spec refresh(all | [binary()]) -> ok.
refresh(Which) ->
    gen_server:call(?MODULE, {refresh, Which}, lg_config:get(upstream_connect_timeout_ms) + 10000).

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

refresh_after(CredId, Gap) ->
    case status(CredId) of
        #{checked_at := At} ->
            case lg_time:now_ms() - At > Gap of
                true -> gen_server:cast(?MODULE, {refresh, [CredId]});
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

init([]) ->
    _ = ets:new(?TAB, [named_table, public, {read_concurrency, true}]),
    self() ! poll,
    {ok, #{}}.

handle_call({refresh, Which}, _From, S) ->
    run(Which),
    {reply, ok, S}.

handle_cast({refresh, Which}, S) ->
    run(Which),
    {noreply, S}.

handle_info(poll, S) ->
    run(all),
    schedule(),
    {noreply, S};
handle_info(poll_check, S) ->
    schedule(),
    {noreply, S};
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

run(Which) ->
    Timeout = lg_config:get(upstream_connect_timeout_ms),
    Creds = [{C, P} || #lg_credential{id = Id, enabled = true} = C <- lg_credentials:list(),
                       P <- [plan_of(C)], P =/= undefined,
                       Which =:= all orelse lists:member(Id, Which)],
    Known = [Id || #lg_credential{id = Id} = C <- lg_credentials:list(), plan_of(C) =/= undefined],
    %% 已不再是套餐凭证的状态清掉
    [ets:delete(?TAB, Id) || {Id, _} <- ets:tab2list(?TAB), not lists:member(Id, Known)],
    Parent = self(),
    Refs = [begin
                Ref = make_ref(),
                Kind = binary_to_existing_atom(maps:get(<<"kind">>, P)),
                spawn(fun() -> Parent ! {Ref, catch lg_plan_quota:fetch(Kind, C, Timeout)} end),
                {Ref, C, P}
            end || {C, P} <- Creds],
    Deadline = lg_time:now_ms() + Timeout + 5000,
    lists:foreach(fun(R) -> collect(R, Deadline) end, Refs).

collect({Ref, #lg_credential{id = Id, name = Name}, P}, Deadline) ->
    Now = lg_time:now_ms(),
    Prev = case status(Id) of
               undefined -> #{windows => [], level => null, fetched_at => null};
               S -> S
           end,
    Base = Prev#{kind => maps:get(<<"kind">>, P), reserve_pct => maps:get(<<"reserve_pct">>, P, 0),
                 window_caps => maps:get(<<"window_caps">>, P, #{}), checked_at => Now},
    New = receive
              {Ref, {ok, #{windows := W, level := L}}} ->
                  Base#{windows => W, level => L, fetched_at => Now, error => null};
              {Ref, {error, Msg}} when is_binary(Msg) ->
                  Base#{error => Msg};
              {Ref, Other} ->
                  Base#{error => iolist_to_binary(io_lib:format("~0p", [Other]))}
          after max(0, Deadline - Now) ->
              Base#{error => <<"timeout">>}
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
