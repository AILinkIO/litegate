%% @doc 数据保留清理：删除过期的日志 / 对话 / 索引与小时用量汇总，然后按需 merge 回收空间。
%%
%% 启动后延迟 FIRST_RUN_MS 首次运行，之后每 24 小时一次；run/0 可手动触发（同一时间只跑一个）。
%% 删除交给 lg_store_writer（单写者），merge 在本进程执行（bitcask 的 merge 锁不阻塞写者）。
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
    {ok, #{}}.

handle_call(run, _From, S) ->
    {reply, cleanup(), S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(tick, S) ->
    _ = cleanup(),
    erlang:send_after(?DAY_MS, self(), tick),
    {noreply, S};
handle_info(_Msg, S) ->
    {noreply, S}.

%%====================================================================
%% 清理
%%====================================================================

cleanup() ->
    Start = lg_time:now_ms(),
    LogDays = lg_config:get(log_retention_days),
    UsageDays = lg_config:get(usage_retention_days),
    Stats0 = #{logs => 0, index => 0, usage => 0},
    Stats1 = case LogDays of
                 N when is_integer(N), N > 0 ->
                     Cutoff = Start - N * ?DAY_MS,
                     (purge_logs(Cutoff, Stats0))#{responses => purge_expired(responses, created_at, Cutoff),
                                                  sessions => purge_sessions(Cutoff),
                                                  alerts => purge_expired(alerts, created_at, Cutoff)};
                 _ -> Stats0
             end,
    Stats2 = case UsageDays of
                 M when is_integer(M), M > 0 -> purge_usage(Start - M * ?DAY_MS, Stats1);
                 _ -> Stats1
             end,
    Stats3 = Stats2#{cache => purge_expired(cache, expires_at, Start)},
    Merged = [C || C <- [logs, msgs, idx, usage, search, cache, responses, alerts, sessions], merge(C)],
    Result = Stats3#{merged => Merged, at => Start, duration_ms => lg_time:now_ms() - Start,
                     log_retention_days => LogDays, usage_retention_days => UsageDays},
    ok = lg_db:write(#lg_meta{key = store_janitor, value = Result}),
    maps:get(logs, Result) + maps:get(usage, Result) > 0 andalso
        logger:notice("store cleanup: ~p", [Result]),
    Result.

%% 日志键时间倒序：早于 Cutoff 的日志是键空间尾部 [Lo, +∞)
purge_logs(Cutoff, Stats) ->
    {Lo, _} = lg_store_keys:log_bounds(0, Cutoff),
    N = delete_range(logs, Lo, undefined, [logs, msgs, search]),
    Stats#{logs => N, index => purge_index(Lo, <<>>, 0)}.

%% 索引按维度前缀逐段处理：每个前缀只删其过期段，然后跳到下一个前缀
purge_index(ExpiredLo, Cursor, Acc) ->
    case first_key(idx, Cursor) of
        none ->
            Acc;
        Key ->
            Prefix = binary:part(Key, 0, byte_size(Key) - 12),
            End = <<Prefix/binary, (binary:copy(<<16#FF>>, 13))/binary>>,
            N = delete_range(idx, <<Prefix/binary, ExpiredLo/binary>>, End, [idx]),
            purge_index(ExpiredLo, End, Acc + N)
    end.

%% 按值中的时间字段清理（响应缓存按 expires_at 过期；Responses 会话按 created_at 保留期）。
%% 这类数据量不大，整表扫描。
purge_expired(Cask, Field, Cutoff) ->
    H = persistent_term:get({lg_store, Cask}),
    Keep = case Field of
               expires_at -> fun(T) -> T > Cutoff end;
               created_at -> fun(T) -> T >= Cutoff end
           end,
    Fun = fun(K, V, _Ts, _Ord, Acc) ->
                  case binary_to_term(V) of
                      #{Field := T} when is_integer(T) ->
                          case Keep(T) of true -> Acc; false -> [K | Acc] end;
                      _ -> [K | Acc]
                  end
          end,
    case bitcask:range_fold(H, {undefined, undefined}, [], Fun, []) of
        {error, R} -> logger:error("store cleanup ~p scan failed: ~p", [Cask, R]), 0;
        Keys -> ok = lg_store_writer:delete(Cask, Keys), length(Keys)
    end.

%% 会话按最近活动过期：最近活动键时间倒序，早于 Cutoff 的在尾部；同时删汇总
purge_sessions(Cutoff) ->
    H = persistent_term:get({lg_store, sessions}),
    {_, Lo} = lg_store_keys:recent_bounds(Cutoff, Cutoff + 1),
    Fun = fun(K, _V, _Ts, _Ord, Acc) -> [K | Acc] end,
    case bitcask:range_fold(H, {Lo, <<$b>>}, [], Fun, []) of
        {error, R} ->
            logger:error("store cleanup sessions scan failed: ~p", [R]),
            0;
        Keys ->
            ok = lg_store_writer:delete(sessions, Keys ++ [lg_store_keys:session_key(lg_store_keys:recent_sid(K)) || K <- Keys]),
            length(Keys)
    end.

purge_usage(Cutoff, Stats) ->
    Stats#{usage => delete_range(usage, <<0:32>>, <<(lg_store_keys:hour(Cutoff)):32>>, [usage])}.

%% 扫描 Scan 中 [Lo, Hi) 的键，分批从 Casks 删除
delete_range(Scan, Lo, Hi, Casks) ->
    H = persistent_term:get({lg_store, Scan}),
    Fun = fun(K, _V, _Ts, _Ord, {Batch, N}) when length(Batch) >= ?BATCH ->
                  remove(Casks, Batch),
                  {[K], N + 1};
             (K, _V, _Ts, _Ord, {Batch, N}) ->
                  {[K | Batch], N + 1}
          end,
    case bitcask:range_fold(H, {Lo, Hi}, [], Fun, {[], 0}) of
        {error, R} ->
            logger:error("store cleanup scan ~p failed: ~p", [Scan, R]),
            0;
        {Rest, N} ->
            remove(Casks, Rest),
            N
    end.

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
