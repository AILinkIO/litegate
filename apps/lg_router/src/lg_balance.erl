%% @doc 按量付费 Key 的余额状态：定期查询配置了 options.balance 的凭证，结果缓存在 ETS。
%%
%% - 轮询间隔 balance_poll_interval_ms（默认 30 分钟，0 = 只在请求后与手动刷新时查询）
%% - touched/1：请求结束后调用，距上次查询超过 10 分钟则异步刷新
%% - 查询失败只记录错误，保留上次的余额
%% - 余额已知为 0 或以下：按「余额不足」冷却整个凭证（与上游返回余额不足同等对待）；读到余额恢复即解除
%% - 低于 options.balance.alert_below 时发 balance_low 告警（lg_alert）
-module(lg_balance).
-behaviour(gen_server).

-include_lib("lg_core/include/lg_core.hrl").

-export([start_link/0, status/1, all/0, refresh/1, touched/1, balance_of/1, validate/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, lg_balance_status).  %% {CredId, StatusMap}
-define(MIN_GAP_MS, 600000).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc 凭证的余额查询配置（options.balance），没有则 undefined。
-spec balance_of(#lg_credential{}) -> map() | undefined.
balance_of(#lg_credential{options = #{balance := #{<<"kind">> := _} = B}}) -> B;
balance_of(_) -> undefined.

%% @doc 校验 options.balance：#{kind := deepseek | moonshot | openrouter | newapi, alert_below => 数字 ≥ 0}。
-spec validate(term()) -> boolean().
validate(#{<<"kind">> := K} = B) ->
    lists:member(K, lg_balance_api:kinds())
        andalso maps:size(maps:without([<<"kind">>, <<"alert_below">>], B)) =:= 0
        andalso case maps:get(<<"alert_below">>, B, 0) of
                    N when is_number(N), N >= 0 -> true;
                    _ -> false
                end;
validate(_) ->
    false.

-spec status(binary()) -> map() | undefined.
status(CredId) ->
    case catch ets:lookup(?TAB, CredId) of
        [{_, S}] -> S;
        _ -> undefined
    end.

%% @doc 全部配置了余额查询的凭证（未查询过的也列出）。
-spec all() -> [map()].
all() ->
    [(case status(Id) of undefined -> #{amount => null, currency => null, details => [], fetched_at => null,
                                        error => null, checked_at => null};
                         S -> S end)#{credential => Id, credential_name => N, kind => maps:get(<<"kind">>, B),
                                      alert_below => maps:get(<<"alert_below">>, B, null)}
     || #lg_credential{id = Id, name = N} = C <- lg_credentials:list(), B <- [balance_of(C)], B =/= undefined].

%% @doc 立即刷新（同步）。
-spec refresh(all | [binary()]) -> ok.
refresh(Which) ->
    gen_server:call(?MODULE, {refresh, Which}, lg_config:get(upstream_connect_timeout_ms) + 10000).

%% @doc 请求结束后调用；配置了余额查询且距上次查询足够久时异步刷新。
-spec touched(binary()) -> ok.
touched(CredId) ->
    case status(CredId) of
        #{checked_at := At} when is_integer(At) ->
            case lg_time:now_ms() - At > ?MIN_GAP_MS of
                true -> gen_server:cast(?MODULE, {refresh, [CredId]});
                false -> ok
            end;
        _ -> ok
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

schedule() ->
    case lg_config:get(balance_poll_interval_ms) of
        N when is_integer(N), N > 0 -> _ = erlang:send_after(N, self(), poll), ok;
        _ -> _ = erlang:send_after(60000, self(), poll_check), ok
    end.

%% 并行查询，等待至连接超时 + 5 秒
run(Which) ->
    Timeout = lg_config:get(upstream_connect_timeout_ms),
    Creds = [{C, B} || #lg_credential{id = Id, enabled = true} = C <- lg_credentials:list(),
                       B <- [balance_of(C)], B =/= undefined,
                       Which =:= all orelse lists:member(Id, Which)],
    Known = [Id || #lg_credential{id = Id} = C <- lg_credentials:list(), balance_of(C) =/= undefined],
    [ets:delete(?TAB, Id) || {Id, _} <- ets:tab2list(?TAB), not lists:member(Id, Known)],
    Parent = self(),
    Refs = [begin
                Ref = make_ref(),
                Kind = binary_to_existing_atom(maps:get(<<"kind">>, B)),
                spawn(fun() -> Parent ! {Ref, catch lg_balance_api:fetch(Kind, C, Timeout)} end),
                {Ref, C, B}
            end || {C, B} <- Creds],
    Deadline = lg_time:now_ms() + Timeout + 5000,
    lists:foreach(fun(R) -> collect(R, Deadline) end, Refs).

collect({Ref, #lg_credential{id = Id, name = Name}, B}, Deadline) ->
    Now = lg_time:now_ms(),
    Prev = case status(Id) of
               undefined -> #{amount => null, currency => null, details => [], fetched_at => null};
               S -> S
           end,
    Base = Prev#{kind => maps:get(<<"kind">>, B), checked_at => Now},
    New = receive
              {Ref, {ok, #{amount := A, currency := Cur, details := D}}} ->
                  Base#{amount => A, currency => Cur, details => D, fetched_at => Now, error => null};
              {Ref, {error, Msg}} when is_binary(Msg) ->
                  Base#{error => Msg};
              {Ref, Other} ->
                  Base#{error => iolist_to_binary(io_lib:format("~0p", [Other]))}
          after max(0, Deadline - Now) ->
              Base#{error => <<"timeout">>}
          end,
    ets:insert(?TAB, {Id, New}),
    case maps:get(amount, New) of
        A2 when is_number(A2), A2 =< 0 ->
            lg_cooldown:mark({Id, <<>>}, #{kind => credit, retry_after_ms => undefined,
                                           message => <<"balance is empty">>});
        A2 when is_number(A2) ->
            lg_cooldown:recovered(Id, credit);
        _ -> ok
    end,
    lg_alert:balance_status(Id, Name, New#{alert_below => maps:get(<<"alert_below">>, B, null)}).
