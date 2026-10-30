%% @doc 数据保留清理：删除过期的日志 / 对话 / 索引与小时用量汇总，然后按需 merge 回收空间。
%%
%% 启动后延迟 FIRST_RUN_MS 首次运行，之后每 24 小时一次；run/0 可手动触发（同一时间只跑一个）。
%% 删除交给 lg_store_writer（单写者），每次调用 ≤ BATCH 个键（跨索引前缀累积），不长时间独占写者；
%% merge 在本进程执行（bitcask 的 merge 锁不阻塞写者）。
%% 派生数据回填（lg_store_migrate）在启动后 janitor_migrate_ms（默认 10s）先跑一次，每次清理前再跑一次。
%% 最近一次结果记在 lg_meta 的 store_janitor。
-module(lg_store_janitor).
-behaviour(gen_server).

-include_lib("lg_core/include/lg_core.hrl").

-export([start_link/0, run/0, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(DAY_MS, 86400000).
-define(BATCH, 1000).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc 立即运行一次清理，返回统计。
-spec run() -> map().
run() ->
    gen_server:call(?MODULE, run, infinity).

-spec status() -> map() | null.
status() ->
    case lg_db:read(lg_meta, store_janitor) of
        {ok, #lg_meta{value = V}} -> V;
        not_found -> null
    end.

init([]) ->
    First = application:get_env(lg_store, janitor_first_run_ms, 5 * 60000),
    erlang:send_after(First, self(), tick),
    erlang:send_after(application:get_env(lg_store, janitor_migrate_ms, 10000), self(), migrate),
    {ok, #{}}.

handle_call(run, _From, S) ->
    {reply, cleanup(), S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(tick, S) ->
    _ = cleanup(),
    erlang:send_after(?DAY_MS, self(), tick),
    {noreply, S};
handle_info(migrate, S) ->
    _ = migrate(),
    {noreply, S};
handle_info(_Msg, S) ->
    {noreply, S}.

%%====================================================================
%% 清理
%%====================================================================

migrate() ->
    try lg_store_migrate:run()
    catch C:R:St ->
            logger:error("store migration crashed: ~p:~p ~p", [C, R, St]),
            #{error => crashed}
    end.

cleanup() ->
    Migration = migrate(),
    Start = lg_time:now_ms(),
    LogDays = lg_config:get(log_retention_days),
    UsageDays = lg_config:get(usage_retention_days),
    Stats0 = #{logs => 0, index => 0, usage => 0},
    Stats1 = case LogDays of
                 N when is_integer(N), N > 0 ->
                     Cutoff = Start - N * ?DAY_MS,
                     (purge_logs(Cutoff, Stats0))#{responses => purge_expired(responses, created_at, Cutoff),
                                                  sessions => purge_sessions(Cutoff),
                                                  alerts => purge_alerts(Cutoff)};
                 _ -> Stats0
             end,
    Stats2 = case UsageDays of
                 M when is_integer(M), M > 0 -> purge_usage(Start - M * ?DAY_MS, Stats1);
                 _ -> Stats1
             end,
    Stats3 = Stats2#{cache => purge_expired(cache, expires_at, Start)},
    Merged = [C || C <- [logs, msgs, idx, usage, search, cache, responses, alerts, sessions], merge(C)],
    Result = Stats3#{merged => Merged, at => Start, duration_ms => lg_time:now_ms() - Start, migration => Migration,
                     log_retention_days => LogDays, usage_retention_days => UsageDays},
    ok = lg_db:write(#lg_meta{key = store_janitor, value = Result}),
    maps:get(logs, Result) + maps:get(usage, Result) > 0 andalso
        logger:notice("store cleanup: ~p", [Result]),
    Result.

%% 日志键时间倒序：早于 Cutoff 的日志是键空间尾部 [Lo, +∞)
purge_logs(Cutoff, Stats) ->
    {Lo, _} = lg_store_keys:log_bounds(0, Cutoff),
    N = delete_range(logs, Lo, undefined, [logs, msgs, search]),
    Stats#{logs => N, index => purge_index(Lo)}.

%% 索引按维度前缀逐段处理：每个前缀只删其过期段，然后跳到下一个前缀；待删键跨前缀累积成批
purge_index(ExpiredLo) ->
    purge_index(ExpiredLo, <<>>, batch([idx])).

purge_index(ExpiredLo, Cursor, B) ->
    case first_key(idx, Cursor) of
        none ->
            done(B);
        Key ->
            Prefix = binary:part(Key, 0, byte_size(Key) - 12),
            End = <<Prefix/binary, (binary:copy(<<16#FF>>, 13))/binary>>,
            purge_index(ExpiredLo, End, scan_into(idx, <<Prefix/binary, ExpiredLo/binary>>, End, B))
    end.

%% 按值中的时间字段清理（响应缓存按 expires_at 过期；Responses 会话按 created_at 保留期）。
%% 只扫过期索引中早于 Cutoff 的段；主记录仍在且时间字段确已过期才删（同一键可能已重写成更晚的过期时间），
%% 索引键一律删除。未建过期索引的旧条目由 lg_store_migrate 回填索引后照此清理。
purge_expired(Cask, Field, Cutoff) ->
    H = persistent_term:get({lg_store, Cask}),
    Expired = case Field of
                  expires_at -> fun(T) -> T =< Cutoff end;
                  created_at -> fun(T) -> T < Cutoff end
              end,
    Hi = case Field of
             expires_at -> Cutoff + 1;
             created_at -> Cutoff
         end,
    Fun = fun(<<0, T:64, Key/binary>> = K, V, _Ts, _Ord, {B, N}) ->
                  case V =:= lg_store_keys:expiry_val(Field, T) of
                      false ->
                          {B, N};  %% 主键恰好落进索引范围
                      true ->
                          Main = case bitcask:get(H, Key) of
                                     {ok, MV} ->
                                         case binary_to_term(MV) of
                                             #{Field := T2} when is_integer(T2) -> Expired(T2);
                                             _ -> true
                                         end;
                                     _ ->
                                         false
                                 end,
                          case Main of
                              true -> {add(Key, add(K, B)), N + 1};
                              false -> {add(K, B), N}
                          end
                  end;
             (_K, _V, _Ts, _Ord, Acc) ->
                  Acc
          end,
    case bitcask:range_fold(H, lg_store_keys:expiry_bounds(Hi), [], Fun, {batch([Cask]), 0}) of
        {error, R} -> logger:error("store cleanup ~p scan failed: ~p", [Cask, R]), 0;
        {B, N} -> done(B), N
    end.

%% 告警键 <<Ts:64, Id>> 按时间有序：早于 Cutoff 的是键空间头部
purge_alerts(Cutoff) ->
    delete_range(alerts, undefined, <<Cutoff:64>>, [alerts]).

%% 会话按最近活动过期：最近活动键时间倒序，早于 Cutoff 的在尾部；同时删汇总
purge_sessions(Cutoff) ->
    H = persistent_term:get({lg_store, sessions}),
    {_, Lo} = lg_store_keys:recent_bounds(Cutoff, Cutoff + 1),
    Fun = fun(K, _V, _Ts, _Ord, {B, N}) ->
                  {add(lg_store_keys:session_key(lg_store_keys:recent_sid(K)), add(K, B)), N + 1}
          end,
    case bitcask:range_fold(H, {Lo, <<$b>>}, [], Fun, {batch([sessions]), 0}) of
        {error, R} ->
            logger:error("store cleanup sessions scan failed: ~p", [R]),
            0;
        {B, N} ->
            done(B),
            N
    end.

%% 维度行之外另删同一时段的派生行（总量 / 费用分解，见 lg_store_keys）；统计只计维度行
purge_usage(Cutoff, Stats) ->
    CutHour = lg_store_keys:hour(Cutoff),
    N = delete_range(usage, <<0:32>>, <<CutHour:32>>, [usage]),
    _ = [delete_range(usage, <<16#FF, Kind, 0:32>>, <<16#FF, Kind, CutHour:32>>, [usage]) || Kind <- [0, 1]],
    Stats#{usage => N}.

%% 扫描 Scan 中 [Lo, Hi) 的键，分批从 Casks 删除
delete_range(Scan, Lo, Hi, Casks) ->
    B = scan_into(Scan, Lo, Hi, batch(Casks)),
    done(B).

scan_into(Scan, Lo, Hi, B0) ->
    H = persistent_term:get({lg_store, Scan}),
    case bitcask:range_fold(H, {Lo, Hi}, [], fun(K, _V, _Ts, _Ord, B) -> add(K, B) end, B0) of
        {error, R} ->
            logger:error("store cleanup scan ~p failed: ~p", [Scan, R]),
            B0;
        B ->
            B
    end.

%% 删除批：{Casks, 待删键, 批内键数, 累计键数}；满 BATCH 即交给写者（每个 cask 一次调用）
batch(Casks) ->
    {Casks, [], 0, 0}.

add(K, {Casks, Keys, N, Total}) when N + 1 >= ?BATCH ->
    remove(Casks, [K | Keys]),
    {Casks, [], 0, Total + 1};
add(K, {Casks, Keys, N, Total}) ->
    {Casks, [K | Keys], N + 1, Total + 1}.

%% 删掉剩余的键，返回累计键数
done({Casks, Keys, _, Total}) ->
    remove(Casks, Keys),
    Total.

remove(Casks, Keys) ->
    [ok = lg_store_writer:delete(C, Keys) || C <- Casks],
    ok.

first_key(Cask, From) ->
    H = persistent_term:get({lg_store, Cask}),
    Lo = case From of <<>> -> undefined; _ -> From end,
    %% 拿到第一个键即 throw 中止扫描（第二个子句只为让回调有正常返回路径）
    Fun = fun(K, _, _, _, none) -> throw({first, K});
             (_, _, _, _, Acc) -> Acc
          end,
    try bitcask:range_fold(H, {Lo, undefined}, [], Fun, none) of
        _ -> none
    catch
        throw:{first, K} -> K
    end.

merge(Cask) ->
    H = persistent_term:get({lg_store, Cask}),
    case bitcask:needs_merge(H) of
        {true, Which} ->
            Dir = filename:join(persistent_term:get({lg_store, root}), atom_to_list(Cask)),
            case bitcask:merge(Dir, [], Which) of
                ok -> true;
                Err -> logger:warning("store merge ~p failed: ~p", [Cask, Err]), false
            end;
        false ->
            false
    end.
