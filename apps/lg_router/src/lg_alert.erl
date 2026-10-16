%% @doc 告警：接收各处上报的事件，按规则判定、去重后异步发送到渠道，记录通知历史（lg_store alerts）。
%%
%% 事件来源：
%% - upstream_down：lg_health:record/4 每次上游尝试后上报；目标连续失败（不含请求错误 client）达到阈值时告警一次，
%%   随后第一次成功时发恢复通知
%% - budget：lg_budget:add/3 累计花费后上报；本期已用比例达到阈值时每个周期告警一次
%% - plan_quota：lg_plan 查询额度后上报；窗口已用比例达到阈值时每个窗口周期告警一次（用尽为 critical），
%%   已告警的窗口重置后发恢复通知
%% - catalog_sync_failed：每分钟检查 lg_meta 的 catalog_sync，出现新的失败时告警（静默期内不重复）
%% 发送由一个独立的发送进程按产生顺序依次进行（恢复通知不会先于告警到达），每个渠道失败重试 3 次
%% （1s、2s 间隔）；发送结果写回通知记录。
-module(lg_alert).
-behaviour(gen_server).

-include_lib("lg_core/include/lg_core.hrl").

-export([start_link/0, target_result/3, budget/4, plan_status/3, balance_status/3,
         login_brute_force/3, test_channel/1, history/1, flush/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(CHECK_MS, 60000).

-record(st, {
    fired = #{} :: #{term() => non_neg_integer()},        %% 去重键 → 发送时间
    fails = #{} :: #{term() => non_neg_integer()},        %% 目标 → 连续失败次数
    down = #{} :: #{{term(), binary()} => binary()},      %% {目标, 规则} → 最近错误（已告警、待恢复）
    plan = #{} :: #{{binary(), binary(), binary()} => true}, %% {凭证, 窗口, 规则} → 已告警、待恢复
    low = #{} :: #{{binary(), binary()} => true},          %% {凭证, 规则} → 余额已告警、待恢复
    catalog_at = 0 :: non_neg_integer(),                  %% 已处理的最近一次目录同步失败时间
    sender :: pid() | undefined
}).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc 一次上游尝试的结果（lg_health 调用）。
-spec target_result({binary(), binary()}, ok | atom(), binary() | undefined) -> ok.
target_result(Target, Outcome, Msg) ->
    gen_server:cast(?MODULE, {target, Target, Outcome, Msg}).

%% @doc 某作用域预算的本期花费（lg_budget 调用）。
-spec budget(lg_budget_scope(), day | week | month, float(), number()) -> ok.
budget(Scope, Period, Spent, Max) ->
    gen_server:cast(?MODULE, {budget, Scope, Period, Spent, Max}).

%% @doc 套餐凭证的最新额度状态（lg_plan 调用）。
-spec plan_status(binary(), binary(), map()) -> ok.
plan_status(CredId, Name, Status) ->
    gen_server:cast(?MODULE, {plan, CredId, Name, Status}).

%% @doc 按量付费凭证的最新余额（lg_balance 调用）；Status 带 amount、currency、alert_below。
-spec balance_status(binary(), binary(), map()) -> ok.
balance_status(CredId, Name, Status) ->
    gen_server:cast(?MODULE, {balance, CredId, Name, Status}).

%% @doc 登录冷却被触发时上报（lg_login_guard 调用）。
-spec login_brute_force(binary(), inet:ip_address(), pos_integer()) -> ok.
login_brute_force(Username, PeerIp, Failures) ->
    gen_server:cast(?MODULE, {login_brute_force, Username, PeerIp, Failures}).

%% @doc 向渠道发送测试消息（同步，不重试，不记录）。
-spec test_channel(binary()) -> ok | {error, binary() | not_found}.
test_channel(Id) ->
    case lg_alerts:channel(Id) of
        {ok, C} ->
            lg_notify:send(C, #{event => test, level => info, title => <<"测试消息"/utf8>>,
                                text => <<"LiteGate 告警渠道配置正确。"/utf8>>, ts => lg_time:now_ms()});
        not_found ->
            {error, not_found}
    end.

-spec history(pos_integer()) -> [map()].
history(Limit) ->
    lg_store:alerts(Limit).

%% @doc 等待已投递的事件处理完（测试用）。
-spec flush() -> ok.
flush() ->
    gen_server:call(?MODULE, flush).

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    erlang:send_after(?CHECK_MS, self(), check),
    Sender = spawn_link(fun sender_loop/0),
    put(sender, Sender),
    %% 启动前已有的同步失败不再告警
    At = case lg_db:read(lg_meta, catalog_sync) of
             {ok, #lg_meta{value = #{at := T}}} -> T;
             _ -> 0
         end,
    {ok, #st{catalog_at = At, sender = Sender}}.

%% 等发送进程处理完已排队的通知
handle_call(flush, _From, #st{sender = P} = S) ->
    Ref = make_ref(),
    P ! {flush, self(), Ref},
    receive {Ref, done} -> ok after 30000 -> ok end,
    {reply, ok, S}.

handle_cast({target, T, Outcome, Msg}, S) ->
    {noreply, on_target(T, Outcome, Msg, S)};
handle_cast({budget, Scope, Period, Spent, Max}, S) ->
    {noreply, on_budget(Scope, Period, Spent, Max, S)};
handle_cast({plan, CredId, Name, Status}, S) ->
    {noreply, on_plan(CredId, Name, Status, S)};
handle_cast({balance, CredId, Name, Status}, S) ->
    {noreply, on_balance(CredId, Name, Status, S)};
handle_cast({login_brute_force, Username, PeerIp, Failures}, S) ->
    {noreply, on_login_brute_force(Username, PeerIp, Failures, S)}.

handle_info(check, S) ->
    erlang:send_after(?CHECK_MS, self(), check),
    {noreply, prune(check_catalog(S))};
handle_info(_Msg, S) ->
    {noreply, S}.

%%====================================================================
%% 事件判定
%%====================================================================

%% 请求本身的错误（4xx）不算上游故障
on_target(_T, client, _Msg, S) ->
    S;
on_target(T, ok, _Msg, #st{fails = F, down = D} = S) ->
    Recovered = [R || {{T1, R}, _} <- maps:to_list(D), T1 =:= T],
    _ = [notify(upstream_down, info, <<"上游已恢复："/utf8, (target_name(T))/binary>>,
                <<"目标恢复正常响应。"/utf8>>, target_data(T), channels_of(R))
         || R <- Recovered],
    S#st{fails = maps:remove(T, F), down = maps:without([{T, R} || R <- Recovered], D)};
on_target(T, Kind, Msg, #st{fails = F, down = D} = S) ->
    N = maps:get(T, F, 0) + 1,
    New = [R || #lg_alert_rule{id = Id, threshold = Th} = R <- lg_alerts:rules(upstream_down),
                N >= Th, not maps:is_key({T, Id}, D)],
    Text = unicode:characters_to_binary(io_lib:format("连续失败 ~b 次，最近错误：~ts ~ts",
                                          [N, Kind, case Msg of undefined -> <<>>; _ -> Msg end])),
    _ = [notify(upstream_down, critical, <<"上游故障："/utf8, (target_name(T))/binary>>, Text,
                (target_data(T))#{failures => N, kind => Kind}, channels_of(R#lg_alert_rule.id))
         || R <- New],
    S#st{fails = F#{T => N},
         down = maps:merge(D, maps:from_list([{{T, Id}, Text} || #lg_alert_rule{id = Id} <- New]))}.

on_budget(Scope, Period, Spent, Max, #st{fired = Fired} = S) when Max > 0 ->
    Pct = Spent / Max * 100,
    PStart = lg_budget:period_start(Period, lg_time:now_ms()),
    Hit = [R || #lg_alert_rule{id = Id, threshold = Th} = R <- lg_alerts:rules(budget),
                Pct >= Th, not maps:is_key({budget, Scope, PStart, Id}, Fired)],
    _ = [notify(budget, case Pct >= 100 of true -> critical; false -> warning end,
                <<"预算告警："/utf8, (scope_name(Scope))/binary>>,
                unicode:characters_to_binary(io_lib:format("本~ts已用 $~.4f / $~.2f（~.1f%），达到阈值 ~p%",
                                               [period_name(Period), float(Spent), float(Max), Pct, Th])),
                #{scope => scope_json(Scope), period => Period, spent_usd => Spent, max_usd => Max},
                [C || C <- Cs])
         || #lg_alert_rule{threshold = Th, channels = Cs} <- Hit],
    Now = lg_time:now_ms(),
    S#st{fired = maps:merge(Fired, maps:from_list([{{budget, Scope, PStart, Id}, Now}
                                                   || #lg_alert_rule{id = Id} <- Hit]))};
on_budget(_Scope, _Period, _Spent, _Max, S) ->
    S.

on_plan(CredId, Name, #{windows := Ws}, #st{fired = Fired, plan = P} = S) ->
    Now = lg_time:now_ms(),
    Rules = lg_alerts:rules(plan_quota),
    %% 达到阈值：每个窗口周期（按重置时刻区分）每条规则一次
    Hit = [{R, W} || #lg_alert_rule{id = Id, threshold = Th} = R <- Rules,
                     #{name := WN, used_pct := U, resets_at := At} = W <- Ws,
                     U >= Th, not maps:is_key({plan, CredId, WN, At, Id}, Fired)],
    _ = [notify(plan_quota, case U >= 100 of true -> critical; false -> warning end,
                <<"套餐额度"/utf8, (case U >= 100 of true -> <<"用尽："/utf8>>; false -> <<"告警："/utf8>> end)/binary,
                  Name/binary>>,
                unicode:characters_to_binary(io_lib:format("~ts 窗口已用 ~p%（阈值 ~p%），~ts 重置",
                                               [WN, U, Th, fmt_time(At)])),
                #{credential => CredId, window => WN, used_pct => U, resets_at => At}, Cs)
         || {#lg_alert_rule{threshold = Th, channels = Cs}, #{name := WN, used_pct := U, resets_at := At}} <- Hit],
    P1 = maps:merge(P, maps:from_list([{{CredId, WN, Id}, true}
                                       || {#lg_alert_rule{id = Id}, #{name := WN}} <- Hit])),
    %% 已告警的窗口回落到阈值以下（窗口已重置）：恢复通知
    Recovered = [{K, R} || {CId, WN, Id} = K <- maps:keys(P1), CId =:= CredId,
                           #lg_alert_rule{id = Id1, threshold = Th} = R <- Rules, Id1 =:= Id,
                           [U || #{name := WN1, used_pct := U} <- Ws, WN1 =:= WN, U < Th] =/= []],
    _ = [notify(plan_quota, info, <<"套餐额度已恢复："/utf8, Name/binary>>,
                <<WN/binary, " 窗口已重置"/utf8>>, #{credential => CredId, window => WN}, Cs)
         || {{_, WN, _}, #lg_alert_rule{channels = Cs}} <- Recovered],
    S#st{fired = maps:merge(Fired, maps:from_list([{{plan, CredId, WN, At, Id}, Now}
                                                   || {#lg_alert_rule{id = Id}, #{name := WN, resets_at := At}} <- Hit])),
         plan = maps:without([K || {K, _} <- Recovered], P1)};
on_plan(_CredId, _Name, _Status, S) ->
    S.

%% 余额低于凭证的告警线：每条规则通知一次，回到告警线以上时发恢复通知
on_balance(CredId, Name, #{amount := A, currency := Cur, alert_below := Below}, #st{low = Low} = S)
  when is_number(A), is_number(Below) ->
    Rules = lg_alerts:rules(balance_low),
    Amount = unicode:characters_to_binary(io_lib:format("~.2f ~ts", [float(A), Cur])),
    case A < Below of
        true ->
            New = [R || #lg_alert_rule{id = Id} = R <- Rules, not maps:is_key({CredId, Id}, Low)],
            _ = [notify(balance_low, case A =< 0 of true -> critical; false -> warning end,
                        <<"余额不足："/utf8, Name/binary>>,
                        unicode:characters_to_binary(io_lib:format("当前余额 ~ts，低于告警线 ~p", [Amount, Below])),
                        #{credential => CredId, amount => A, currency => Cur, alert_below => Below}, Cs)
                 || #lg_alert_rule{channels = Cs} <- New],
            S#st{low = maps:merge(Low, maps:from_list([{{CredId, Id}, true} || #lg_alert_rule{id = Id} <- New]))};
        false ->
            Recovered = [R || #lg_alert_rule{id = Id} = R <- Rules, maps:is_key({CredId, Id}, Low)],
            _ = [notify(balance_low, info, <<"余额已恢复："/utf8, Name/binary>>,
                        <<"当前余额 "/utf8, Amount/binary>>, #{credential => CredId, amount => A, currency => Cur}, Cs)
                 || #lg_alert_rule{channels = Cs} <- Recovered],
            S#st{low = maps:without([{CredId, Id} || #lg_alert_rule{id = Id} <- Recovered], Low)}
    end;
on_balance(_CredId, _Name, _Status, S) ->
    S.

on_login_brute_force(Username, PeerIp, Failures, S) ->
    Peer = unicode:characters_to_binary(inet:ntoa(PeerIp)),
    Text = unicode:characters_to_binary(
             io_lib:format("来源 ~ts 的账号 ~ts 连续失败 ~b 次，已进入临时冷却。", [Peer, Username, Failures])),
    _ = [notify(login_brute_force, warning, <<"控制台登录疑似爆破"/utf8>>, Text,
                #{username => Username, peer => Peer, failures => Failures}, Cs)
         || #lg_alert_rule{channels = Cs} <- lg_alerts:rules(login_brute_force)],
    S.

check_catalog(#st{catalog_at = Last, fired = Fired} = S) ->
    case lg_db:read(lg_meta, catalog_sync) of
        {ok, #lg_meta{value = #{status := error, at := At} = V}} when At > Last ->
            Silence = lg_config:get(alert_silence_ms),
            Now = lg_time:now_ms(),
            case Now - maps:get(catalog, Fired, 0) >= Silence of
                true ->
                    _ = [notify(catalog_sync_failed, warning, <<"模型目录同步失败"/utf8>>,
                                maps:get(error, V, <<>>), #{source => maps:get(source, V, null)}, Cs)
                         || #lg_alert_rule{channels = Cs} <- lg_alerts:rules(catalog_sync_failed)],
                    S#st{catalog_at = At, fired = Fired#{catalog => Now}};
                false ->
                    S#st{catalog_at = At}
            end;
        _ ->
            S
    end.

%% 去重记录只保留 40 天（预算月周期）
prune(#st{fired = F} = S) ->
    Cutoff = lg_time:now_ms() - 40 * 86400000,
    S#st{fired = maps:filter(fun(_, T) -> T >= Cutoff end, F)}.

%%====================================================================
%% 发送
%%====================================================================

channels_of(RuleId) ->
    case lg_db:read(lg_alert_rule, RuleId) of
        {ok, #lg_alert_rule{channels = Cs}} -> Cs;
        not_found -> []
    end.

notify(_Event, _Level, _Title, _Text, _Data, []) ->
    ok;
notify(Event, Level, Title, Text, Data, ChannelIds) ->
    Channels = [C || Id <- ChannelIds, {ok, #lg_channel{enabled = true} = C} <- [lg_alerts:channel(Id)]],
    Now = lg_time:now_ms(),
    Msg = #{event => Event, level => Level, title => Title, text => Text, ts => Now, data => Data},
    Rec = Msg#{id => lg_id:new(<<"alert">>), seq => erlang:unique_integer([monotonic, positive]),
               deliveries => [#{channel => Id, channel_name => N, status => pending} || #lg_channel{id = Id, name = N} <- Channels]},
    ok = lg_store:alert_put(Rec),
    logger:warning("alert ~s: ~ts ~ts", [Event, Title, Text]),
    get(sender) ! {send, Rec, Channels, Msg},
    ok.

sender_loop() ->
    receive
        {send, Rec, Channels, Msg} ->
            Ds = [deliver(C, Msg, 3) || C <- Channels],
            ok = lg_store:alert_put(Rec#{deliveries => Ds});
        {flush, From, Ref} ->
            From ! {Ref, done}
    end,
    sender_loop().

deliver(#lg_channel{id = Id, name = N} = C, Msg, Tries) ->
    case catch lg_notify:send(C, Msg) of
        ok ->
            #{channel => Id, channel_name => N, status => ok};
        Err when Tries > 1 ->
            timer:sleep((4 - Tries) * 1000),
            logger:notice("alert delivery to ~s failed (~p), retrying", [Id, Err]),
            deliver(C, Msg, Tries - 1);
        Err ->
            #{channel => Id, channel_name => N, status => error,
              error => case Err of {error, B} when is_binary(B) -> B; _ -> iolist_to_binary(io_lib:format("~0p", [Err])) end}
    end.

%%====================================================================
%% 文案
%%====================================================================

target_name({C, M}) ->
    Name = case lg_credentials:get(C) of
               {ok, #lg_credential{name = N}} -> N;
               not_found -> C
           end,
    <<Name/binary, " / ", M/binary>>.

target_data({C, M}) -> #{credential => C, upstream_model => M}.

scope_name({key, Id}) ->
    case lg_api_keys:get(Id) of
        {ok, #lg_api_key{name = N}} -> <<"API Key "/utf8, N/binary>>;
        _ -> <<"API Key ", Id/binary>>
    end;
scope_name({tag, T}) ->
    <<"标签 "/utf8, T/binary>>;
scope_name({user, Id}) ->
    case lg_users:get(Id) of
        {ok, #lg_user{username = N}} -> <<"用户 "/utf8, N/binary>>;
        _ -> <<"用户 "/utf8, Id/binary>>
    end.

scope_json({T, Id}) -> #{type => T, id => Id}.

period_name(day) -> <<"日"/utf8>>;
period_name(week) -> <<"周"/utf8>>;
period_name(month) -> <<"月"/utf8>>.

fmt_time(null) -> <<"未知时间"/utf8>>;
fmt_time(Ms) ->
    {{Y, Mo, D}, {H, Mi, _}} = calendar:system_time_to_local_time(Ms div 1000, second),
    iolist_to_binary(io_lib:format("~4..0b-~2..0b-~2..0b ~2..0b:~2..0b", [Y, Mo, D, H, Mi])).
