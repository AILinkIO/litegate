%% @doc 限流：RPM / TPM / 并发（单节点，ETS）。
%%
%% - RPM / TPM：按分钟分桶的滑动窗口近似：
%%     rate = 上一分钟计数 × (1 - 本分钟已过比例) + 本分钟计数
%% - TPM 在请求前按估算 token 预扣，结束后 release/2 按实际用量补差
%% - 并发：先原子 +1，超出上限立即回滚；本进程监控持有槽位的请求进程，
%%   release/2 或进程退出时归还（请求进程崩溃不会泄漏槽位）
%%
%% 检查与计数之间 RPM / TPM 允许并发下的少量超出；并发数是精确的。
-module(lg_limiter).
-behaviour(gen_server).

-include_lib("lg_core/include/lg_core.hrl").

-export([start_link/0, acquire/2, release/2, estimate_tokens/1, rate/2, parallel/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(RATE, lg_limiter_rate).     %% {{Scope, rpm | tpm, Minute}, Count}
-define(SLOTS, lg_limiter_slots).   %% {Scope, InUse}
-define(SWEEP_MS, 60000).

-type reason() :: rpm | tpm | parallel.
-opaque ticket() :: #{minute := integer(), est := non_neg_integer(),
                      tpm := [lg_limit_scope()], slots := [lg_limit_scope()]}.
-export_type([ticket/0, reason/0]).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc 按限额检查并占用；全部通过才计数。
-spec acquire([#lg_limit{}], non_neg_integer()) ->
          {ok, ticket()} | {error, {rate_limited, reason(), lg_limit_scope(), RetryAfterMs :: pos_integer()}}.
acquire(Limits, EstTokens) ->
    Now = lg_time:now_ms(),
    Minute = Now div 60000,
    case check_rates(Limits, EstTokens, Now) of
        ok ->
            case take_slots([L || #lg_limit{max_parallel = P} = L <- Limits, P =/= undefined], []) of
                {ok, Slots} ->
                    _ = [bump({S, rpm, Minute}, 1) || #lg_limit{scope = S, rpm = R} <- Limits, R =/= undefined],
                    Tpm = [S || #lg_limit{scope = S, tpm = T} <- Limits, T =/= undefined],
                    _ = [bump({S, tpm, Minute}, EstTokens) || S <- Tpm],
                    Slots =/= [] andalso gen_server:cast(?MODULE, {hold, self(), Slots}),
                    {ok, #{minute => Minute, est => EstTokens, tpm => Tpm, slots => Slots}};
                {error, Scope} ->
                    {error, {rate_limited, parallel, Scope, 1000}}
            end;
        {error, _} = Err ->
            Err
    end.

%% @doc 请求结束：归还槽位，TPM 按实际 token 补差。
-spec release(ticket(), non_neg_integer()) -> ok.
release(#{minute := M, est := Est, tpm := Tpm, slots := Slots}, Actual) ->
    Delta = Actual - Est,
    _ = Delta =/= 0 andalso [bump({S, tpm, M}, Delta) || S <- Tpm],
    case Slots of
        [] -> ok;
        _ -> gen_server:cast(?MODULE, {release, self(), Slots})
    end.

%% @doc 请求输入 token 粗估：CJK 字符按 1 token，其余按 4 字符 1 token。
%% System One 决策请求（state / questions 可为任意 JSON）按序列化后的文本估算。
-spec estimate_tokens(map()) -> non_neg_integer().
estimate_tokens(Req) ->
    Texts = [T || K <- [<<"system">>, <<"messages">>, <<"input">>, <<"prompt">>],
                  T <- texts(maps:get(K, Req, null))]
        ++ [json_text(V) || K <- [<<"state">>, <<"questions">>], {ok, V} <- [maps:find(K, Req)]],
    lists:sum([text_tokens(T) || T <- Texts]).

json_text(B) when is_binary(B) -> B;
json_text(V) -> iolist_to_binary(json:encode(V)).

%% @doc 当前滑动窗口计数（测试与控制台展示用）。
-spec rate(lg_limit_scope(), rpm | tpm) -> float().
rate(Scope, Metric) ->
    rate(Scope, Metric, lg_time:now_ms()).

-spec parallel(lg_limit_scope()) -> non_neg_integer().
parallel(Scope) ->
    case ets:lookup(?SLOTS, Scope) of
        [{_, N}] -> N;
        [] -> 0
    end.

%%====================================================================
%% gen_server：持有 ETS，监控占用槽位的进程
%%====================================================================

init([]) ->
    _ = ets:new(?RATE, [named_table, public, {write_concurrency, true}, {read_concurrency, true}]),
    _ = ets:new(?SLOTS, [named_table, public, {write_concurrency, true}]),
    erlang:send_after(?SWEEP_MS, self(), sweep),
    {ok, #{}}.

handle_call(_Req, _From, S) ->
    {reply, ok, S}.

%% S：#{Pid => {MonitorRef, [Scope]}}，同一进程可多次占用（列表按出现次数计）
handle_cast({hold, Pid, Scopes}, S) ->
    case maps:find(Pid, S) of
        {ok, {Ref, Held}} -> {noreply, S#{Pid => {Ref, Held ++ Scopes}}};
        error -> {noreply, S#{Pid => {monitor(process, Pid), Scopes}}}
    end;
handle_cast({release, Pid, Scopes}, S) ->
    free(Scopes),
    case maps:find(Pid, S) of
        {ok, {Ref, Held}} ->
            case Held -- Scopes of
                [] -> demonitor(Ref, [flush]), {noreply, maps:remove(Pid, S)};
                Rest -> {noreply, S#{Pid => {Ref, Rest}}}
            end;
        error ->
            {noreply, S}
    end.

handle_info({'DOWN', _Ref, process, Pid, _}, S) ->
    case maps:take(Pid, S) of
        {{_, Held}, S1} -> free(Held), {noreply, S1};
        error -> {noreply, S}
    end;
handle_info(sweep, S) ->
    Old = lg_time:now_ms() div 60000 - 2,
    ets:select_delete(?RATE, [{{{'_', '_', '$1'}, '_'}, [{'<', '$1', Old}], [true]}]),
    erlang:send_after(?SWEEP_MS, self(), sweep),
    {noreply, S};
handle_info(_Msg, S) ->
    {noreply, S}.

%%====================================================================
%% 内部函数
%%====================================================================

check_rates([], _Est, _Now) ->
    ok;
check_rates([#lg_limit{scope = S, rpm = Rpm, tpm = Tpm} | Rest], Est, Now) ->
    RetryAfter = 60000 - Now rem 60000,
    RpmOk = Rpm =:= undefined orelse rate(S, rpm, Now) + 1 =< Rpm,
    %% 单个请求估算就超过 TPM 时，窗口为空也放行，避免永远无法调用
    TpmOk = Tpm =:= undefined orelse
        (fun(Cur) -> Cur + Est =< Tpm orelse Cur < 1 end)(rate(S, tpm, Now)),
    if
        not RpmOk -> {error, {rate_limited, rpm, S, RetryAfter}};
        not TpmOk -> {error, {rate_limited, tpm, S, RetryAfter}};
        true -> check_rates(Rest, Est, Now)
    end.

rate(Scope, Metric, Now) ->
    Minute = Now div 60000,
    Elapsed = (Now rem 60000) / 60000,
    count({Scope, Metric, Minute - 1}) * (1 - Elapsed) + count({Scope, Metric, Minute}).

count(Key) ->
    case ets:lookup(?RATE, Key) of
        [{_, N}] -> N;
        [] -> 0
    end.

text_tokens(Text) ->
    %% CJK 统一表意文字、假名、谚文按每字 1 token
    Cjk = length([C || C <- unicode:characters_to_list(Text),
                       (C >= 16#3040 andalso C =< 16#9FFF) orelse (C >= 16#AC00 andalso C =< 16#D7AF)
                       orelse (C >= 16#F900 andalso C =< 16#FAFF)]),
    Cjk + (string:length(Text) - Cjk + 3) div 4.

bump(Key, N) ->
    ets:update_counter(?RATE, Key, N, {Key, 0}).

take_slots([], Acc) ->
    {ok, Acc};
take_slots([#lg_limit{scope = S, max_parallel = Max} | Rest], Acc) ->
    case ets:update_counter(?SLOTS, S, 1, {S, 0}) of
        N when N =< Max ->
            take_slots(Rest, [S | Acc]);
        _ ->
            free([S | Acc]),
            {error, S}
    end.

free(Scopes) ->
    _ = [ets:update_counter(?SLOTS, S, {2, -1, 0, 0}) || S <- Scopes],
    ok.

texts(B) when is_binary(B) -> [B];
texts(L) when is_list(L) -> lists:flatmap(fun texts/1, L);
texts(#{<<"content">> := C}) -> texts(C);
texts(#{<<"text">> := T}) when is_binary(T) -> [T];
texts(_) -> [].
