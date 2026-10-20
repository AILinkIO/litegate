%% @doc 会话粘性表（ETS）：一段对话留在最先回答它的上游目标上，以命中上游的提示词缓存。
%%
%% 表项：{{Route, SessionId}, #{target := {CredId, Model}, last_at, cache_read, sessions_at, decision}}
%% - target / last_at / cache_read：最近一次成功回答的目标、时刻与读到的缓存 token
%% - decision：本轮的规则判定，新的一轮时重新判定，同一轮内沿用
%% 闲置 30 分钟的表项每分钟清理一次。
%% 同表另存（键不与上面冲突）：{{turn, Route}, N} rotate 轮转计数；{{tokens, CredId}, Value, AtMs} 最近发出的 token
%% （1 小时半衰期，usage / pace 策略用）；{{intent, Hash}, Answer, ExpireAt} 意图判断缓存。
-module(lg_affinity).
-behaviour(gen_server).

-export([start_link/0, get/2, put_target/4, put_decision/3, decision/2, load/2, clear/0, choose/5,
         next_turn/1, add_tokens/2, recent_tokens/1, intent_cached/1, intent_cache/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include_lib("lg_core/include/lg_core.hrl").

-define(TAB, ?MODULE).
-define(IDLE_MS, 30 * 60000).
-define(CACHE_WORTH, 1024).
-define(CACHE_COLD_MS, 5 * 60000).
-define(WINDOW_FULL, 98).
-define(HALF_LIFE_MS, 3600000).
-define(TOKEN_MAX_AGE_MS, 30 * 86400000).  %% 30 天

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
    Old = case get(Route, Sid) of undefined -> #{}; E -> E end,
    ets:insert(?TAB, {{Route, Sid}, Old#{target => Target, last_at => lg_time:now_ms(), cache_read => CacheRead}}),
    ok.

-spec put_decision(binary(), binary(), term()) -> ok.
put_decision(Route, Sid, Decision) ->
    Old = case get(Route, Sid) of undefined -> #{last_at => lg_time:now_ms()}; E -> E end,
    ets:insert(?TAB, {{Route, Sid}, Old#{decision => Decision}}),
    ok.

-spec decision(binary(), binary()) -> term() | undefined.
decision(Route, Sid) ->
    case get(Route, Sid) of
        #{decision := D} -> D;
        _ -> undefined
    end.

%% @doc 最近 WithinMs 内每个目标承载的会话数（rotate 策略用）。
-spec load(binary(), non_neg_integer()) -> #{{binary(), binary()} => pos_integer()}.
load(Route, WithinMs) ->
    From = lg_time:now_ms() - WithinMs,
    lists:foldl(fun({_, #{target := T, last_at := At}}, Acc) when At >= From -> maps:update_with(T, fun(N) -> N + 1 end, 1, Acc);
                   (_, Acc) -> Acc
                end, #{}, ets:match_object(?TAB, {{Route, '_'}, '_'})).

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

handle_call(_Req, _From, S) ->
    {reply, ok, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(sweep, S) ->
    Old = lg_time:now_ms() - ?IDLE_MS,
    _ = ets:select_delete(?TAB, [{{'_', #{last_at => '$1'}}, [{'<', '$1', Old}], [true]}]),
    _ = ets:select_delete(?TAB, [{{{intent, '_'}, '_', '$1'}, [{'<', '$1', lg_time:now_ms()}], [true]}]),
    %% 清理 30 天前的 token 条目（半衰期 1 小时，30 天后值已趋近零，没有保留意义）
    TokenOld = lg_time:now_ms() - ?TOKEN_MAX_AGE_MS,
    _ = ets:select_delete(?TAB, [{{{tokens, '_'}, '_', '$1'}, [{'<', '$1', TokenOld}], [true]}]),
    %% {{turn, Route}, N} 有界（条目数 = 路由数），无需清扫
    _ = erlang:send_after(60000, self(), sweep),
    {noreply, S};
handle_info(_Msg, S) ->
    {noreply, S}.
