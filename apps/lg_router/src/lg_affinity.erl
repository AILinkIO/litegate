%% @doc 会话粘性表（ETS）：一段对话留在最先回答它的上游目标上，以命中上游的提示词缓存。
%%
%% 表项：{{Route, SessionId}, #{target := {CredId, Model}, last_at, cache_read, sessions_at, decision}}
%% - target / last_at / cache_read：最近一次成功回答的目标、时刻与读到的缓存 token
%% - decision：本轮的规则判定，新的一轮时重新判定，同一轮内沿用
%% 闲置 30 分钟的表项每分钟清理一次。
%% 同表另存（键不与上面冲突）：{{turn, Route}, N} rotate 轮转计数；{{tokens, CredId}, Value, AtMs} 最近发出的 token
%% （1 小时半衰期，usage / pace 策略用）；{{intent, Hash}, Answer, ExpireAt} 意图判断缓存；
%% {{intent_flight, Hash}, Pid | {done, Result}, ExpireAt} 进行中的意图判断（相同判断合并，过期清扫）；
%% {{breaker, Name}, Fails, OpenUntil} 判断者熔断状态（条目数 = 判断者数，无需清扫）；
%% {{route_target_count, Route, Target}, N} 每个目标承载的会话数（rotate 策略用，T32）：会话表项的目标变化时增减，
%% 会话表项的写入都经 update_session/3 比较交换，计数与表项一一对应；sweep 删除闲置会话时扣减，并按实际表项校正。
-module(lg_affinity).
-behaviour(gen_server).

-export([start_link/0, get/2, put_target/4, put_decision/3, decision/2, load/2, clear/0, choose/5,
         next_turn/1, add_tokens/2, recent_tokens/1, intent_cached/1, intent_cache/3,
         intent_claim/2, intent_done/2, intent_release/1, intent_flight/1, breaker_check/3, breaker_result/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include_lib("lg_core/include/lg_core.hrl").

-define(TAB, ?MODULE).
-define(IDLE_MS, 30 * 60000).
-define(CACHE_WORTH, 1024).
-define(CACHE_COLD_MS, 5 * 60000).
-define(WINDOW_FULL, 98).
-define(HALF_LIFE_MS, 3600000).
-define(TOKEN_MAX_AGE_MS, 30 * 86400000).  %% 30 天
-define(COUNT(Route, Target), {route_target_count, Route, Target}).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec get(binary(), binary()) -> map() | undefined.
get(Route, Sid) ->
    case ets:lookup(?TAB, {Route, Sid}) of
        [{_, E}] -> E;
        [] -> undefined
    end.

%% @doc 记录成功回答的目标与读到的缓存 token。
-spec put_target(binary(), binary(), {binary(), binary()}, non_neg_integer()) -> ok.
put_target(Route, Sid, Target, CacheRead) ->
    Now = lg_time:now_ms(),
    update_session(Route, Sid, fun(Old) -> (old(Old, #{}))#{target => Target, last_at => Now, cache_read => CacheRead} end).

-spec put_decision(binary(), binary(), term()) -> ok.
put_decision(Route, Sid, Decision) ->
    Now = lg_time:now_ms(),
    update_session(Route, Sid, fun(Old) -> (old(Old, #{last_at => Now}))#{decision => Decision} end).

old(undefined, Default) -> Default;
old(E, _) -> E.

%% 会话表项的读改写：比较交换（新建用 insert_new，更新用 select_replace 精确匹配旧值），
%% 并发写同一会话时只有一方成功、另一方重读重试，目标计数随成功的那次更新增减
update_session(Route, Sid, F) ->
    K = {Route, Sid},
    case ets:lookup(?TAB, K) of
        [] ->
            New = F(undefined),
            case ets:insert_new(?TAB, {K, New}) of
                true -> retarget(Route, undefined, New);
                false -> update_session(Route, Sid, F)
            end;
        [{_, Old}] ->
            New = F(Old),
            case ets:select_replace(?TAB, [{{K, '$1'}, [{'=:=', '$1', {const, Old}}], [{{{const, K}, {const, New}}}]}]) of
                1 -> retarget(Route, Old, New);
                0 -> update_session(Route, Sid, F)
            end
    end.

%% 会话表项从 Old 变为 New（undefined = 不存在）：目标变化时旧目标 -1、新目标 +1
retarget(Route, Old, New) ->
    case {target_of(Old), target_of(New)} of
        {T, T} -> ok;
        {T0, T1} -> bump(Route, T0, -1), bump(Route, T1, 1)
    end.

target_of(#{target := T}) -> T;
target_of(_) -> undefined.

bump(_Route, undefined, _N) -> ok;
bump(Route, T, N) ->
    K = ?COUNT(Route, T),
    _ = ets:update_counter(?TAB, K, N, {K, 0}),
    ok.

-spec decision(binary(), binary()) -> term() | undefined.
decision(Route, Sid) ->
    case get(Route, Sid) of
        #{decision := D} -> D;
        _ -> undefined
    end.

%% @doc 给定目标各自承载的会话数（rotate 策略用；只含 > 0 的）。会话闲置 30 分钟后由 sweep 删除并扣减，
%% 即「最近 30 分钟」内的会话（清扫每分钟一次，最多晚 1 分钟）。按目标查计数，与会话总数无关（T32）。
-spec load(binary(), [term()]) -> #{term() => pos_integer()}.
load(Route, Targets) ->
    maps:from_list([{T, N} || T <- Targets, {_, N} <- ets:lookup(?TAB, ?COUNT(Route, T)), N > 0]).

%% @doc rotate 策略的轮转计数（每次调用 +1）。
-spec next_turn(binary()) -> non_neg_integer().
next_turn(Route) ->
    ets:update_counter(?TAB, {turn, Route}, 1, {{turn, Route}, 0}).

%% @doc 记录发往凭证的 token（输入 + 输出），按 1 小时半衰期衰减累计。
-spec add_tokens(binary(), non_neg_integer()) -> ok.
add_tokens(_CredId, 0) -> ok;
add_tokens(CredId, N) ->
    Now = lg_time:now_ms(),
    ets:insert(?TAB, {{tokens, CredId}, decayed(CredId, Now) + N, Now}),
    ok.

-spec recent_tokens(binary()) -> float().
recent_tokens(CredId) ->
    decayed(CredId, lg_time:now_ms()).

decayed(CredId, Now) ->
    case ets:lookup(?TAB, {tokens, CredId}) of
        [{_, V, At}] -> V * math:pow(0.5, (Now - At) / ?HALF_LIFE_MS);
        [] -> 0.0
    end.

-spec intent_cached(binary()) -> {ok, non_neg_integer()} | miss.
intent_cached(Hash) ->
    case ets:lookup(?TAB, {intent, Hash}) of
        [{_, A, Exp}] -> case Exp > lg_time:now_ms() of true -> {ok, A}; false -> miss end;
        [] -> miss
    end.

-spec intent_cache(binary(), non_neg_integer(), pos_integer()) -> ok.
intent_cache(Hash, Answer, TtlMs) ->
    ets:insert(?TAB, {{intent, Hash}, Answer, lg_time:now_ms() + TtlMs}),
    ok.

%% @doc 意图判断合并：本进程成为 Hash 的判断者返回 claimed；已有判断者在进行中返回 wait。
%% TtlMs 为判断最长耗时，超过后（或判断进程已退出）视为无人判断，可被接手。
-spec intent_claim(binary(), pos_integer()) -> claimed | wait.
intent_claim(Hash, TtlMs) ->
    New = {{intent_flight, Hash}, self(), lg_time:now_ms() + TtlMs},
    case ets:insert_new(?TAB, New) of
        true -> claimed;
        false ->
            case intent_flight(Hash) of
                running -> wait;
                _ -> ets:insert(?TAB, New), claimed      %% 上一次已结束或判断者已不在：接手
            end
    end.

%% @doc 判断结束：结果留 1 秒给等待者取走。
-spec intent_done(binary(), map()) -> ok.
intent_done(Hash, Result) ->
    ets:insert(?TAB, {{intent_flight, Hash}, {done, Result}, lg_time:now_ms() + 1000}),
    ok.

-spec intent_release(binary()) -> ok.
intent_release(Hash) ->
    ets:delete(?TAB, {intent_flight, Hash}),
    ok.

-spec intent_flight(binary()) -> running | {done, map()} | none.
intent_flight(Hash) ->
    Now = lg_time:now_ms(),
    case ets:lookup(?TAB, {intent_flight, Hash}) of
        [{_, {done, R}, Exp}] when Exp > Now -> {done, R};
        [{_, Pid, Exp}] when is_pid(Pid), Exp > Now ->
            case is_process_alive(Pid) of
                true -> running;
                false -> none
            end;
        _ -> none
    end.

%% @doc 判断者熔断：closed 照常调用；open 跳过；probe 半开，由本进程做这一次试探。
%% 连续失败 Threshold 次后打开 OpenMs；到期后只放行一个试探请求（同时把打开期顺延，其余请求继续跳过）。
-spec breaker_check(binary(), pos_integer(), pos_integer()) -> closed | open | probe.
breaker_check(Name, Threshold, OpenMs) ->
    K = {breaker, Name},
    Now = lg_time:now_ms(),
    case ets:lookup(?TAB, K) of
        [] -> closed;
        [{_, F, _}] when F < Threshold -> closed;
        [{_, _, Until}] when Now < Until -> open;
        [{_, F, _} = Old] ->
            case ets:select_replace(?TAB, [{Old, [], [{const, {K, F, Now + OpenMs}}]}]) of
                1 -> probe;
                _ -> open
            end
    end.

%% @doc 记录一次判断结果：成功清零；失败累计，达到阈值时（重新）打开。
-spec breaker_result(binary(), ok | error, pos_integer(), pos_integer()) -> ok.
breaker_result(Name, ok, _Threshold, _OpenMs) ->
    K = {breaker, Name},
    _ = ets:member(?TAB, K) andalso ets:delete(?TAB, K),
    ok;
breaker_result(Name, error, Threshold, OpenMs) ->
    K = {breaker, Name},
    case ets:update_counter(?TAB, K, {2, 1}, {K, 0, 0}) of
        F when F >= Threshold -> _ = ets:update_element(?TAB, K, {3, lg_time:now_ms() + OpenMs}), ok;
        _ -> ok
    end.

-spec clear() -> ok.
clear() ->
    true = ets:delete_all_objects(?TAB),
    ok.

%% @doc 按粘性调整尝试顺序：返回 {Plan1, hit | miss | {broken, Reason}}。
%% Mode：auto | session | off；NewTurn：这个请求是否开始新的一轮。
-spec choose([{binary(), map(), #lg_credential{}}], binary(), binary() | undefined, binary(), boolean()) ->
          {list(), hit | miss | {broken, binary()} | off}.
choose(Plan, _Route, _Sid, <<"off">>, _NewTurn) ->
    {Plan, off};
choose(Plan, _Route, undefined, _Mode, _NewTurn) ->
    {Plan, miss};
choose(Plan, Route, Sid, Mode, NewTurn) ->
    case get(Route, Sid) of
        #{target := Key} = E ->
            case lists:partition(fun({_, T, _}) -> tkey(T) =:= Key end, Plan) of
                {[], _} -> {Plan, {broken, <<"target_gone">>}};
                {[{_, _, Cred} | _] = Mine, Others} ->
                    case keep(Mode, NewTurn, E) andalso usable(Key, Cred) of
                        true -> {Mine ++ Others, hit};
                        false when Mode =:= <<"auto">>, NewTurn ->
                            case usable(Key, Cred) of
                                true -> {Plan, {broken, <<"cache_cold">>}};
                                false -> {Plan, {broken, unusable_reason(Key, Cred)}}
                            end;
                        false -> {Plan, {broken, unusable_reason(Key, Cred)}}
                    end
            end;
        _ ->
            {Plan, miss}
    end.

%% auto：一轮之内始终保留；新的一轮时上次读到的缓存足够多且不久前回答过才保留
keep(<<"session">>, _NewTurn, _E) -> true;
keep(_Auto, false, _E) -> true;
keep(_Auto, true, #{cache_read := CR, last_at := At}) ->
    CR >= ?CACHE_WORTH andalso lg_time:now_ms() - At < ?CACHE_COLD_MS;
keep(_, _, _) -> false.

usable(Key, Cred) ->
    unusable_reason(Key, Cred) =:= ok.

unusable_reason({CId, _} = Key, Cred) ->
    case lg_cooldown:cooling(Key) of
        true -> <<"cooling">>;
        false ->
            case window_full(CId) of
                true -> <<"plan_window_full">>;
                false ->
                    Max = lg_conc:max_of(Cred),
                    case lg_conc:full(CId, Max) andalso lg_conc:queued(CId) > 0 of
                        true -> <<"concurrency_full">>;
                        false -> ok
                    end
            end
    end.

%% 套餐任一窗口已用 ≥ 98%（未过重置时刻）
window_full(CId) ->
    case lg_plan:status(CId) of
        #{windows := Ws} ->
            Now = lg_time:now_ms(),
            lists:any(fun(#{used_pct := U, resets_at := R}) -> U >= ?WINDOW_FULL andalso (R =:= null orelse R > Now) end, Ws);
        _ -> false
    end.

tkey(#{credential := C, upstream_model := M}) -> {C, M}.

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    ?TAB = ets:new(?TAB, [named_table, public, {read_concurrency, true}, {write_concurrency, true}]),
    _ = erlang:send_after(60000, self(), sweep),
    {ok, #{}}.

handle_call(sweep, _From, S) ->
    sweep(),
    {reply, ok, S};
handle_call(_Req, _From, S) ->
    {reply, ok, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(sweep, S) ->
    sweep(),
    _ = erlang:send_after(60000, self(), sweep),
    {noreply, S};
handle_info(_Msg, S) ->
    {noreply, S}.

sweep() ->
    sweep_sessions(lg_time:now_ms() - ?IDLE_MS),
    reconcile(),
    _ = ets:select_delete(?TAB, [{{{intent, '_'}, '_', '$1'}, [{'<', '$1', lg_time:now_ms()}], [true]}]),
    _ = ets:select_delete(?TAB, [{{{intent_flight, '_'}, '_', '$1'}, [{'<', '$1', lg_time:now_ms()}], [true]}]),
    %% 清理 30 天前的 token 条目（半衰期 1 小时，30 天后值已趋近零，没有保留意义）
    TokenOld = lg_time:now_ms() - ?TOKEN_MAX_AGE_MS,
    _ = ets:select_delete(?TAB, [{{{tokens, '_'}, '_', '$1'}, [{'<', '$1', TokenOld}], [true]}]),
    %% {{turn, Route}, N} 有界（条目数 = 路由数），无需清扫
    ok.

%% 闲置会话逐条按原值删除（期间被更新的留到下一轮），删掉的扣减目标计数
sweep_sessions(Old) ->
    Idle = ets:select(?TAB, [{{'_', #{last_at => '$1'}}, [{'<', '$1', Old}], ['$_']}]),
    lists:foreach(fun({{Route, _} = K, E}) ->
                          case ets:select_delete(?TAB, [{{K, '$1'}, [{'=:=', '$1', {const, E}}], [true]}]) of
                              1 -> retarget(Route, E, undefined);
                              0 -> ok
                          end
                  end, Idle).

%% 计数校正：按实际会话表项重算，与计数不符的修正（防进程在交换表项与增减计数之间被杀导致的漂移）。
%% 重算前后各读一次计数，期间有变动的目标本轮跳过（下一轮再校正）；归零的计数删除。
reconcile() ->
    C1 = counts(),
    Actual = lists:foldl(fun(K, Acc) -> maps:update_with(K, fun(N) -> N + 1 end, 1, Acc) end, #{},
                         ets:select(?TAB, [{{{'$1', '_'}, #{target => '$2'}}, [], [{{'$1', '$2'}}]}])),
    C2 = counts(),
    _ = [bump(R, T, A - N1)
         || {R, T} = K <- lists:usort(maps:keys(C1) ++ maps:keys(Actual)),
            N1 <- [maps:get(K, C1, 0)], N1 =:= maps:get(K, C2, 0),
            A <- [maps:get(K, Actual, 0)], A =/= N1],
    _ = ets:select_delete(?TAB, [{{?COUNT('_', '_'), 0}, [], [true]}]),
    ok.

counts() ->
    maps:from_list(ets:select(?TAB, [{{?COUNT('$1', '$2'), '$3'}, [], [{{{{'$1', '$2'}}, '$3'}}]}])).
