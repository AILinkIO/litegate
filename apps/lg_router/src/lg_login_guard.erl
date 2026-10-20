%% @doc 控制台登录失败限流：用户名 + 来源 IP 维度的短期失败计数与指数冷却。
%%
%% 只在单节点内存中记录（重启即清空），避免持久化来源 IP；成功登录清零。
-module(lg_login_guard).

-behaviour(gen_server).

-export([start_link/0, check/2, failure/2, success/2, reset/0, sweep/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, ?MODULE).
-define(WINDOW_MS, 60000).
-define(THRESHOLD, 3).
-define(BASE_COOLDOWN_MS, 1000).
-define(MAX_COOLDOWN_MS, 15 * 60000).
-define(SWEEP_MS, 60000).
-define(DAY_MS, 86400000).

%% @doc 冷却期内拒绝登录；返回剩余秒数（至少 1 秒）。
-spec check(binary(), inet:ip_address() | undefined) -> ok | {error, pos_integer()}.
check(_Username, undefined) ->
    ok;
check(Username, PeerIp) ->
    ensure(),
    Key = key(Username, PeerIp),
    Now = lg_time:now_ms(),
    case ets:lookup(?TAB, Key) of
        [{_, _Count, _Since, Until}] when Until > Now ->
            {error, retry_after(Until - Now)};
        [{_, _Count, Since, _Until}] when Now >= Since + ?WINDOW_MS ->
            true = ets:delete(?TAB, Key),
            ok;
        _ ->
            ok
    end.

%% @doc 记录失败；进入冷却时上报 login_brute_force。
-spec failure(binary(), inet:ip_address() | undefined) -> ok.
failure(_Username, undefined) ->
    ok;
failure(Username, PeerIp) ->
    ensure(),
    Key = key(Username, PeerIp),
    Now = lg_time:now_ms(),
    Count0 = case expired(ets:lookup(?TAB, Key), Now) of
                 true -> 0;
                 false -> count(ets:lookup(?TAB, Key))
             end,
    Count = Count0 + 1,
    Cooldown = case Count >= ?THRESHOLD of
                   true -> min(?BASE_COOLDOWN_MS bsl (Count - ?THRESHOLD), ?MAX_COOLDOWN_MS);
                   false -> 0
               end,
    true = ets:insert(?TAB, {Key, Count, Now, Now + Cooldown}),
    Cooldown > 0 andalso lg_alert:login_brute_force(normalize(Username), PeerIp, Count),
    ok.

%% @doc 成功登录清空该维度。
-spec success(binary(), inet:ip_address() | undefined) -> ok.
success(_Username, undefined) ->
    ok;
success(Username, PeerIp) ->
    ensure(),
    true = ets:delete(?TAB, key(Username, PeerIp)),
    ok.

%% @doc 清空全部状态（测试用）。
-spec reset() -> ok.
reset() ->
    ensure(),
    true = ets:delete_all_objects(?TAB),
    ok.

ensure() ->
    _ = catch ets:new(?TAB, [named_table, public, {write_concurrency, true},
                             {read_concurrency, true}]),
    ok.

%% ETS 由 supervisor 持有的进程创建，避免登录请求进程结束后表被回收
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    _ = ets:new(?TAB, [named_table, public, {write_concurrency, true},
                       {read_concurrency, true}]),
    _ = erlang:send_after(?SWEEP_MS, self(), sweep),
    {ok, #{last_session_sweep => 0}}.

handle_call(reset, _From, State) ->
    true = ets:delete_all_objects(?TAB),
    {reply, ok, State};
handle_call(_Call, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(sweep, #{last_session_sweep := LastSessionSweep} = State) ->
    sweep(),
    %% 每日一次顺带清理 mnesia 过期会话（T02）
    Now = lg_time:now_ms(),
    State1 = case Now - LastSessionSweep >= ?DAY_MS of
                 true ->
                     _ = catch lg_users:sweep_expired_sessions(),
                     State#{last_session_sweep => Now};
                 false ->
                     State
             end,
    _ = erlang:send_after(?SWEEP_MS, self(), sweep),
    {noreply, State1};
handle_info(_Info, State) ->
    {noreply, State}.

%% 清除「窗口已过且不在冷却期」的条目：攻击者用随机用户名+IP 撞登录接口不会再使表无界增长
sweep() ->
    Now = lg_time:now_ms(),
    ets:select_delete(?TAB,
        [{{'_', '_', '$1', '$2'},
          [{'andalso',
            {'>=', Now, {'+', '$1', ?WINDOW_MS}},
            {'=<', '$2', Now}}],
          [true]}]),
    ok.

expired([], _Now) -> true;
expired([{_, _Count, Since, _Until}], Now) -> Now >= Since + ?WINDOW_MS.

count([{_, Count, _Since, _Until}]) -> Count;
count([]) -> 0.

%% 用户名大小写不影响限流，避免用 Admin/admin 绕开同一账号的冷却
key(Username, PeerIp) ->
    {normalize(Username), peer_key(PeerIp)}.

normalize(Username) when is_binary(Username) ->
    Lower = string:lowercase(Username),
    iolist_to_binary(unicode:characters_to_list(Lower));
normalize(Username) -> Username.

peer_key(PeerIp) -> unicode:characters_to_binary(inet:ntoa(PeerIp)).

retry_after(Ms) -> max(1, (Ms + 999) div 1000).
