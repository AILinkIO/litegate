%% @doc 交互数据：请求日志、对话内容、用量汇总（bitcask）。
%%
%% 写：record/2 异步投递给 lg_store_writer。
%% 读：任意进程直接读 bitcask（句柄由 lg_store_handles 持有，放在 persistent_term）。
-module(lg_store).

-export([new_id/0, record/2, flush/0,
         flush/1,
         log/1, logs/1, search/1, messages/1, usage/1, usage_costs/2, status/0, sessions/1, session/1,
         cache_get/1, cache_put/3, response_get/1, response_put/2, alert_put/1, alerts/1,
         health/0, is_error/1]).

-define(DEFAULT_LIMIT, 50).
-define(MAX_LIMIT, 500).
-define(DATA_URI_KEEP, 1024).
-define(SEARCH_TEXT_MAX, 32768).
-define(SEARCH_DEFAULT, 50).
-define(SEARCH_MAX, 200).

-type log() :: #{id := binary(), ts := non_neg_integer(), atom() => term()}.
-export_type([log/0]).

%%====================================================================
%% 写
%%====================================================================

%% @doc 请求开始时分配日志 id（同时决定日志时间戳）。
-spec new_id() -> binary().
new_id() ->
    lg_store_keys:id(lg_store_keys:new_log_key()).

%% @doc 记录一次请求。Log 至少含 id；Messages 为 undefined 或 #{request, response}。
%% Log 中可用字段：format, stream, route, key_id, user_id, credential, upstream_model,
%% model_ref, status, error, usage, cost, duration_ms, attempts, finish_reason, client_aborted,
%% ttft_ms, cache_hit, saved_usd, plan, plan_usd
-spec record(log(), map() | undefined) -> ok.
record(#{id := Id} = Log0, Messages) ->
    {ok, Key} = lg_store_keys:from_id(Id),
    Ts = lg_store_keys:ts_ms(Key),
    Log = Log0#{ts => Ts},
    Tags = [T || T <- maps:get(tags, Log, []), is_binary(T), T =/= <<>>, byte_size(T) < 256],
    Clients = [C || C <- [maps:get(client, Log, undefined)], is_binary(C), C =/= <<>>, byte_size(C) < 256],
    IdxKeys = [lg_store_keys:idx_key(T, V, Key)
               || {T, F} <- [{k, key_id}, {r, route}, {u, user_id}, {s, session}],
                  V <- [maps:get(F, Log, undefined)], is_binary(V), V =/= <<>>, byte_size(V) < 256]
        ++ [lg_store_keys:idx_key(t, T, Key) || T <- Tags]
        ++ [lg_store_keys:idx_key(c, C, Key) || C <- Clients]
        ++ [lg_store_keys:idx_key(e, <<>>, Key) || is_error(Log)],
    Record = Messages =/= undefined andalso lg_config:get(record_messages),
    Msgs = case Record of
               true -> term_to_binary(strip_data_uris(Messages), [{compressed, 6}]);
               false -> undefined
           end,
    Doc = case Record of
              true -> search_doc(Log, Messages);
              false -> undefined
          end,
    Dims = {maps:get(key_id, Log, undefined), maps:get(user_id, Log, undefined),
            maps:get(route, Log, undefined), maps:get(credential, Log, undefined),
            maps:get(upstream_model, Log, undefined)},
    Hour = lg_store_keys:hour(Ts),
    case maps:get(session, Log, undefined) of
        Sid when is_binary(Sid), Sid =/= <<>>, byte_size(Sid) < 256 ->
            lg_store_writer:session(Sid, session_delta(Log));
        _ -> ok
    end,
    lg_store_writer:record({Key, IdxKeys, term_to_binary(Log), Msgs, Doc},
                           [{Hour, Dims} | [{Hour, {tag, T}} || T <- Tags] ++ [{Hour, {client, C}} || C <- Clients]],
                           usage_delta(Log)).

%% @doc 是否计入错误索引（$e）：status ≥ 400 或 error 非空。是 errors_only 条件（error 非空）的超集。
-spec is_error(map()) -> boolean().
is_error(Log) ->
    maps:get(error, Log, undefined) =/= undefined
        orelse case maps:get(status, Log, undefined) of
                   S when is_integer(S) -> S >= 400;
                   _ -> false
               end.

-spec flush() -> ok.
flush() ->
    lg_store_writer:flush().

%% @doc 按范围落盘（logs = 日志 + 会话批次，all = 另做用量合并）。
-spec flush(logs | all) -> ok.
flush(Scope) ->
    lg_store_writer:flush(Scope).

usage_delta(Log) ->
    U = maps:get(usage, Log, #{}),
    Duration = maps:get(duration_ms, Log, 0),
    Base = #{requests => 1,
             errors => case maps:get(error, Log, undefined) of undefined -> 0; _ -> 1 end,
             input => maps:get(input, U, 0), output => maps:get(output, U, 0),
             cache_read => maps:get(cache_read, U, 0), cache_write => maps:get(cache_write, U, 0),
             cost => float(maps:get(cost, Log, 0.0)),
             duration_ms => Duration,
             {lat, bucket(Duration)} => 1,
             cache_hits => case maps:get(cache_hit, Log, false) of true -> 1; _ -> 0 end,
             saved_usd => float(maps:get(saved_usd, Log, 0.0)),
             images => maps:get(images, U, 0), chars => maps:get(chars, U, 0),
             plan_requests => case maps:get(plan, Log, false) of true -> 1; _ -> 0 end,
             plan_usd => float(maps:get(plan_usd, Log, 0.0))},
    %% TTFT 只统计流式请求（非流式的 TTFT 即总耗时，混入会拉偏）
    case {maps:get(stream, Log, false), maps:get(ttft_ms, Log, undefined)} of
        {true, T} when is_integer(T) -> Base#{streams => 1, {ttft, bucket(T)} => 1};
        _ -> Base
    end.

%% 会话汇总的增量（lg_store_writer:merge_session/2 合并）
session_delta(#{ts := Ts} = Log) ->
    U = maps:get(usage, Log, #{}),
    Base = #{first_ts => Ts, last_ts => Ts, requests => 1,
             errors => case maps:get(error, Log, undefined) of undefined -> 0; _ -> 1 end,
             turns => case maps:get(new_turn, Log, false) of true -> 1; _ -> 0 end,
             input => maps:get(input, U, 0), output => maps:get(output, U, 0),
             cache_read => maps:get(cache_read, U, 0), cache_write => maps:get(cache_write, U, 0),
             cost => float(maps:get(cost, Log, 0.0)), plan_usd => float(maps:get(plan_usd, Log, 0.0)),
             duration_ms => maps:get(duration_ms, Log, 0),
             routes => [R || R <- [maps:get(route, Log, undefined)], is_binary(R)],
             models => [M || M <- [maps:get(upstream_model, Log, undefined)], is_binary(M)]},
    maps:merge(Base, maps:filter(fun(_, V) -> V =/= undefined end,
                                 maps:with([client, key_id, user_id, session_source], Log))).

%% 延迟直方图桶上界（毫秒），最后一个桶为开放区间
-define(LAT_BOUNDS, [250, 500, 1000, 2000, 5000, 10000, 30000, 60000, 120000]).

bucket(Ms) ->
    length(lists:takewhile(fun(B) -> Ms > B end, ?LAT_BOUNDS)).

%% 用桶计数估算分位数（桶内线性插值；落在开放桶时取其下界）
percentile(Row, Kind, Q) ->
    Counts = [maps:get({Kind, I}, Row, 0) || I <- lists:seq(0, length(?LAT_BOUNDS))],
    case lists:sum(Counts) of
        0 -> null;
        Total -> interpolate(Counts, [0 | ?LAT_BOUNDS], Q * Total, 0)
    end.

interpolate([C | _], [Lo | Bounds], Target, Cum) when Cum + C >= Target, C > 0 ->
    case Bounds of
        [Hi | _] -> round(Lo + (Hi - Lo) * (Target - Cum) / C);
        [] -> Lo
    end;
interpolate([C | Cs], [_ | Bounds], Target, Cum) ->
    interpolate(Cs, Bounds, Target, Cum + C).

%% 汇总行：去掉原始桶计数，换成分位数估算
with_percentiles(Row) ->
    Clean = maps:filter(fun(K, _) -> not is_tuple(K) end, Row),
    Clean#{p50_ms => percentile(Row, lat, 0.5), p95_ms => percentile(Row, lat, 0.95),
           ttft_p50_ms => percentile(Row, ttft, 0.5), ttft_p95_ms => percentile(Row, ttft, 0.95)}.

%% 检索文档：最后一条用户消息 + 回复（多轮对话的历史消息在每次请求中重复，不重复索引）。
%% 统一小写：BM25 分词区分大小写。
search_doc(Log, #{request := Req} = Messages) ->
    UserText = case [M || #{<<"role">> := <<"user">>} = M <- list(maps:get(<<"messages">>, Req, []))] of
                   [] -> <<>>;
                   Users -> text_of(maps:get(<<"content">>, lists:last(Users), <<>>))
               end,
    Text = iolist_to_binary([UserText, <<"\n">>, maps:get(response, Messages, <<>>)]),
    case string:trim(Text) of
        <<>> ->
            undefined;
        _ ->
            Meta = maps:filter(fun(_, V) -> V =/= undefined end,
                               #{<<"ts">> => maps:get(ts, Log),
                                 <<"route">> => maps:get(route, Log, undefined),
                                 <<"key_id">> => maps:get(key_id, Log, undefined),
                                 <<"user_id">> => maps:get(user_id, Log, undefined),
                                 <<"status">> => maps:get(status, Log, undefined)}),
            #{text => truncate(string:lowercase(Text), ?SEARCH_TEXT_MAX),
              meta => bitcask:encode_meta(Meta)}
    end;
search_doc(_Log, _) ->
    undefined.

text_of(T) when is_binary(T) -> T;
text_of(Parts) when is_list(Parts) ->
    iolist_to_binary(lists:join(<<"\n">>, [T || #{<<"text">> := T} <- Parts, is_binary(T)]));
text_of(_) -> <<>>.

%% 按字节截断，并去掉被截断的不完整 UTF-8 尾部
truncate(B, Max) when byte_size(B) =< Max -> B;
truncate(B, Max) ->
    Part = binary:part(B, 0, Max),
    case unicode:characters_to_binary(Part) of
        {incomplete, Good, _} -> Good;
        {error, Good, _} -> Good;
        Good -> Good
    end.

list(L) when is_list(L) -> L;
list(_) -> [].

%% 图片等 base64 内容不入库，只留长度
strip_data_uris(<<"data:", _/binary>> = B) when byte_size(B) > ?DATA_URI_KEEP ->
    [Meta | _] = binary:split(B, <<",">>),
    <<Meta/binary, ",[omitted ", (integer_to_binary(byte_size(B)))/binary, " bytes]">>;
strip_data_uris(M) when is_map(M) ->
    maps:map(fun(_, V) -> strip_data_uris(V) end, M);
strip_data_uris(L) when is_list(L) ->
    [strip_data_uris(X) || X <- L];
strip_data_uris(V) ->
    V.

%%====================================================================
%% 读
%%====================================================================

-spec log(binary()) -> {ok, log()} | not_found.
log(Id) ->
    case lg_store_keys:from_id(Id) of
        {ok, Key} ->
            case bitcask:get(h(logs), Key) of
                {ok, V} -> {ok, binary_to_term(V)};
                not_found -> not_found
            end;
        error ->
            not_found
    end.

-spec messages(binary()) -> {ok, map()} | not_found.
messages(Id) ->
    case lg_store_keys:from_id(Id) of
        {ok, Key} ->
            case bitcask:get(h(msgs), Key) of
                {ok, V} -> {ok, binary_to_term(V)};
                not_found -> not_found
            end;
        error ->
            not_found
    end.

%% @doc 分页查询日志（新→旧）。
%% Q：from/to（毫秒，[from, to)，默认不限）、key_id / route / user_id（至多一个用索引，
%%    其余作过滤）、errors_only（优先用错误索引；错误索引尚未回填覆盖查询范围时退回原有路径）、
%%    limit（默认 50，上限 500）、cursor（上一页返回的 next_cursor）
-spec logs(map()) -> #{items := [log()], next_cursor := binary() | null}.
logs(Q) ->
    flush(logs),
    Now = lg_time:now_ms(),
    To = maps:get(to, Q, Now + 1),
    From = maps:get(from, Q, 0),
    Limit = max(1, min(maps:get(limit, Q, ?DEFAULT_LIMIT), ?MAX_LIMIT)),
    Filters = [{F, V} || F <- [session, tag, client, key_id, route, user_id], V <- [maps:get(F, Q, undefined)],
                         is_binary(V)],
    Keep = fun(Log) ->
                   lists:all(fun({tag, V}) -> lists:member(V, maps:get(tags, Log, []));
                                ({F, V}) -> maps:get(F, Log, undefined) =:= V end, Filters)
                       andalso (not maps:get(errors_only, Q, false)
                                orelse maps:get(error, Log, undefined) =/= undefined)
           end,
    Cursor = case maps:get(cursor, Q, undefined) of
                 undefined -> undefined;
                 C -> case lg_store_keys:from_id(C) of {ok, K} -> K; error -> undefined end
             end,
    ErrIdx = maps:get(errors_only, Q, false) =:= true
        andalso lg_store_migrate:ready(errors, lg_store_keys:log_bounds(From, To)),
    {Items, More} = case Filters of
                        _ when ErrIdx -> scan_idx(e, <<>>, From, To, Cursor, Limit, Keep);
                        [{F, V} | _] -> scan_idx(idx_type(F), V, From, To, Cursor, Limit, Keep);
                        [] -> scan_logs(From, To, Cursor, Limit, Keep)
                    end,
    #{items => Items,
      next_cursor => case More of
                         true -> maps:get(id, lists:last(Items));
                         false -> null
                     end}.

scan_logs(From, To, Cursor, Limit, Keep) ->
    {Lo0, Hi} = lg_store_keys:log_bounds(From, To),
    Lo = after_cursor(Lo0, Cursor),
    collect(h(logs), Lo, Hi, Limit,
            fun(_K, V) ->
                    Log = binary_to_term(V),
                    case Keep(Log) of true -> {ok, Log}; false -> skip end
            end).

scan_idx(Type, Dim, From, To, Cursor, Limit, Keep) ->
    {Lo0, Hi} = lg_store_keys:idx_bounds(Type, Dim, From, To),
    Prefix = binary:part(Lo0, 0, byte_size(Lo0) - 12),
    Lo = case Cursor of
             undefined -> Lo0;
             _ -> max(Lo0, <<Prefix/binary, Cursor/binary, 0>>)
         end,
    Logs = h(logs),
    collect(h(idx), Lo, Hi, Limit,
            fun(K, _V) ->
                    LogKey = binary:part(K, byte_size(K), -12),
                    case bitcask:get(Logs, LogKey) of
                        {ok, V} ->
                            Log = binary_to_term(V),
                            case Keep(Log) of true -> {ok, Log}; false -> skip end;
                        not_found ->
                            skip  %% 索引先于日志写入，可能短暂悬空
                    end
            end).

after_cursor(Lo, undefined) -> Lo;
after_cursor(Lo, Cursor) -> max(Lo, <<Cursor/binary, 0>>).

%% 扫到 Limit + 1 条即停，多出的一条用来判断是否还有下一页
collect(H, Lo, Hi, Limit, Map) ->
    Fun = fun(K, V, _Ts, _Ord, {N, Acc}) ->
                  case Map(K, V) of
                      {ok, Item} when N =:= Limit -> throw({done, Acc, true, Item});
                      {ok, Item} -> {N + 1, [Item | Acc]};
                      skip -> {N, Acc}
                  end
          end,
    try bitcask:range_fold(H, {Lo, Hi}, [], Fun, {0, []}) of
        {error, R} -> error({store_range, R});
        {_, Acc} -> {lists:reverse(Acc), false}
    catch
        throw:{done, Acc, More, _} -> {lists:reverse(Acc), More}
    end.

%% @doc 会话汇总。
-spec session(binary()) -> {ok, map()} | not_found.
session(Sid) ->
    flush(logs),
    case bitcask:get(h(sessions), lg_store_keys:session_key(Sid)) of
        {ok, V} -> {ok, binary_to_term(V)};
        not_found -> not_found
    end.

%% @doc 按最近活动分页列出会话（新→旧）。
%% Q：from/to（最近活动时间，毫秒）、key_id / user_id / client（过滤）、limit、cursor（上一页的 next_cursor）
-spec sessions(map()) -> #{items := [map()], next_cursor := binary() | null}.
sessions(Q) ->
    flush(logs),
    Now = lg_time:now_ms(),
    {Lo0, Hi} = lg_store_keys:recent_bounds(maps:get(from, Q, 0), maps:get(to, Q, Now + 1)),
    Lo = case maps:get(cursor, Q, undefined) of
             C when is_binary(C) ->
                 try max(Lo0, <<(binary:decode_hex(C))/binary, 0>>) catch error:_ -> Lo0 end;
             _ -> Lo0
         end,
    Limit = max(1, min(maps:get(limit, Q, ?DEFAULT_LIMIT), ?MAX_LIMIT)),
    Filters = [{F, V} || F <- [key_id, user_id, client], V <- [maps:get(F, Q, undefined)], is_binary(V)],
    H = h(sessions),
    Fun = fun(K, _V, _Ts, _Ord, {N, Acc}) ->
                  case bitcask:get(H, lg_store_keys:session_key(lg_store_keys:recent_sid(K))) of
                      {ok, V} ->
                          S = binary_to_term(V),
                          case lists:all(fun({F, X}) -> maps:get(F, S, undefined) =:= X end, Filters) of
                              true when N =:= Limit -> throw({done, Acc, true});
                              true -> {N + 1, [{K, S} | Acc]};
                              false -> {N, Acc}
                          end;
                      not_found -> {N, Acc}
                  end
          end,
    {Items, More} = try bitcask:range_fold(H, {Lo, Hi}, [], Fun, {0, []}) of
                        {error, R} -> error({store_range, R});
                        {_, Acc} -> {lists:reverse(Acc), false}
                    catch
                        throw:{done, Acc, M} -> {lists:reverse(Acc), M}
                    end,
    #{items => [S || {_, S} <- Items],
      next_cursor => case More of
                         true -> binary:encode_hex(element(1, lists:last(Items)), lowercase);
                         false -> null
                     end}.

%% @doc 对话全文检索（BM25，按相关度排序，不分页）。
%% Q：q（必填）、from/to（毫秒）、key_id / route / user_id、limit（默认 50，上限 200）
%% 返回的每条日志附带 score。
-spec search(map()) -> #{items := [log()], next_cursor := null}.
search(#{q := Query} = Q) ->
    flush(logs),
    lg_store_indexer:sync(),
    Limit = max(1, min(maps:get(limit, Q, ?SEARCH_DEFAULT), ?SEARCH_MAX)),
    Filter = [#{key => atom_to_binary(F), op => eq, value => V}
              || F <- [key_id, route, user_id], V <- [maps:get(F, Q, undefined)], is_binary(V)]
        ++ [#{key => <<"ts">>, op => gte, value => V} || V <- [maps:get(from, Q, undefined)], is_integer(V)]
        ++ [#{key => <<"ts">>, op => lte, value => V - 1} || V <- [maps:get(to, Q, undefined)], is_integer(V)],
    Terms = string:lowercase(Query),
    Res = case Filter of
              [] -> bitcask:search_text(h(search), Terms, Limit);
              _ -> bitcask:search_text(h(search), Terms, Limit, Filter)
          end,
    Hits = case Res of
               {ok, L} -> L;
               {error, R} -> error({store_search, R})
           end,
    Logs = h(logs),
    Items = [(binary_to_term(V))#{score => Score}
             || {Key, _Ord, Score} <- Hits, {ok, V} <- [bitcask:get(Logs, Key)]],
    #{items => Items, next_cursor => null}.

%% @doc 用量汇总。
%% Q：from/to（毫秒，按小时对齐）、group_by（[hour | day | key_id | user_id | route | credential | model | tag | client]）、
%%    key_id / user_id / route / tag（过滤）。按标签分组或过滤时统计标签行（一个请求计入它的每个标签），
%%    此时 key_id / user_id / route 过滤不适用。无过滤且只按 hour / day 分组（概览）时只读每小时总量行
%% 返回每组一行：维度字段 + requests, errors, input, output, cache_read, cache_write, cost, duration_ms
-spec usage(map()) -> [map()].
usage(Q) ->
    flush(),
    Now = lg_time:now_ms(),
    To = maps:get(to, Q, Now + 1),
    From = maps:get(from, Q, To - 24 * 3600000),
    GroupBy = maps:get(group_by, Q, []),
    Filters = [{F, V} || F <- [key_id, user_id, route, tag, client], V <- [maps:get(F, Q, undefined)],
                         is_binary(V)],
    case Filters =:= [] andalso lists:all(fun(G) -> G =:= hour orelse G =:= day end, GroupBy)
        andalso lg_store_migrate:ready(usage, {lg_store_keys:hour(From), lg_store_keys:hour(To - 1)}) of
        true -> usage_totals(From, To, GroupBy);
        false -> usage_rows(From, To, GroupBy, Filters)
    end.

%% 每小时总量行：解码行数 = 小时数
usage_totals(From, To, GroupBy) ->
    Fun = fun(<<16#FF, 0, Hour:32>>, V, _Ts, _Ord, Acc) ->
                  Counters = binary_to_term(V),
                  maps:update_with(group_key(GroupBy, #{hour => Hour}), fun(Old) -> add(Old, Counters) end,
                                   Counters, Acc)
          end,
    groups(bitcask:range_fold(h(usage), lg_store_keys:usage_kind_bounds(total, From, To), [], Fun, #{})).

%% 维度 / 标签 / 客户端行
usage_rows(From, To, GroupBy, Filters) ->
    %% 按标签（或客户端）分组或筛选时只看标签行（客户端行），否则只看维度行（这两种行都是维度行的重复计数）；
    %% 标签与客户端同时出现时以标签为准
    Side = case {lists:member(tag, GroupBy) orelse lists:keymember(tag, 1, Filters),
                 lists:member(client, GroupBy) orelse lists:keymember(client, 1, Filters)} of
               {true, _} -> tag;
               {false, true} -> client;
               _ -> none
           end,
    Fun = fun(<<Hour:32, DimsBin/binary>>, V, _Ts, _Ord, Acc) ->
                  Row = case binary_to_term(DimsBin) of
                            {tag, T} when Side =:= tag -> #{hour => Hour, tag => T};
                            {client, C} when Side =:= client -> #{hour => Hour, client => C};
                            {tag, _} -> skip;
                            {client, _} -> skip;
                            {_, _, _, _, _} when Side =/= none -> skip;
                            {KeyId, UserId, Route, Cred, Model} ->
                                #{hour => Hour, key_id => KeyId, user_id => UserId, route => Route,
                                  credential => Cred, model => Model}
                        end,
                  case Row =/= skip andalso
                      lists:all(fun({F, Val}) -> maps:get(F, Row, undefined) =:= Val end, Filters) of
                      true ->
                          G = group_key(GroupBy, Row),
                          Counters = binary_to_term(V),
                          maps:update_with(G, fun(Old) -> add(Old, Counters) end, Counters, Acc);
                      false ->
                          Acc
                  end
          end,
    groups(bitcask:range_fold(h(usage), lg_store_keys:usage_bounds(From, To), [], Fun, #{})).

groups({error, R}) ->
    error({store_range, R});
groups(Groups) ->
    lists:sort([maps:merge(maps:from_list(G), with_percentiles(C)) || G := C <- Groups]).

%% @doc 每小时按 key / 用户 / 标签的费用（预算启动重建用）：[{HourMs, #{{key, K} | {user, U} | {tag, T} => Cost}}]，
%% 只含费用 > 0 的项，按小时升序。费用分解行已覆盖时每小时只读一行，否则按维度行与标签行汇总。
-spec usage_costs(non_neg_integer(), non_neg_integer()) -> [{non_neg_integer(), #{tuple() => float()}}].
usage_costs(From, To) ->
    flush(),
    case lg_store_migrate:ready(usage, {lg_store_keys:hour(From), lg_store_keys:hour(To - 1)}) of
        true ->
            Fun = fun(<<16#FF, 1, Hour:32>>, V, _Ts, _Ord, Acc) -> [{Hour * 3600000, binary_to_term(V)} | Acc] end,
            case bitcask:range_fold(h(usage), lg_store_keys:usage_kind_bounds(cost, From, To), [], Fun, []) of
                {error, R} -> error({store_range, R});
                L -> lists:reverse(L)
            end;
        false ->
            Q = #{from => From, to => To},
            Rows = [{H, S, C} || #{hour := H, key_id := K, user_id := U, cost := C} <- usage(Q#{group_by => [hour, key_id, user_id]}),
                                 S <- [{key, K} || is_binary(K)] ++ [{user, U} || is_binary(U)]]
                ++ [{H, {tag, T}, C} || #{hour := H, tag := T, cost := C} <- usage(Q#{group_by => [hour, tag]}),
                                        is_binary(T)],
            ByHour = lists:foldl(fun({H, S, C}, Acc) when C > 0 ->
                                         maps:update_with(H, fun(M) -> add(M, #{S => C}) end, #{S => C}, Acc);
                                    (_, Acc) ->
                                         Acc
                                 end, #{}, Rows),
            lists:sort(maps:to_list(ByHour))
    end.

%% @doc 各 cask 的键数、磁盘占用与是否需要 merge。
-spec status() -> [#{cask := atom(), keys := non_neg_integer(), bytes := non_neg_integer(),
                     needs_merge := boolean()}].
status() ->
    Root = persistent_term:get({lg_store, root}),
    [begin
         H = h(C),
         {Keys, _} = bitcask:status(H),
         Dir = filename:join(Root, atom_to_list(C)),
         Bytes = lists:sum([filelib:file_size(F) || F <- filelib:wildcard(filename:join(Dir, "*"))]),
         #{cask => C, keys => Keys, bytes => Bytes, needs_merge => bitcask:needs_merge(H) =/= false}
     end || C <- [logs, msgs, idx, usage, search, cache, responses, alerts, sessions]].

%% @doc 读取响应缓存（过期视为未命中，由保留清理删除）。请求热路径调用：句柄不可用
%% （存储正在重启 / 未启动）或读失败时按未命中处理，不抛异常。
-spec cache_get(binary()) -> {ok, map()} | miss.
cache_get(Key) ->
    case safe_get(cache, Key) of
        {ok, V} ->
            case binary_to_term(V) of
                #{expires_at := Exp} = Entry -> case Exp > lg_time:now_ms() of
                                                    true -> {ok, Entry};
                                                    false -> miss
                                                end;
                _ -> miss
            end;
        _ ->
            miss
    end.

%% @doc 写入响应缓存（异步），TtlS 秒后过期；同批写过期索引（清理按时间范围扫描）。
-spec cache_put(binary(), pos_integer(), map()) -> ok.
cache_put(Key, TtlS, Entry) ->
    Exp = lg_time:now_ms() + TtlS * 1000,
    lg_store_writer:put(cache, Key, term_to_binary(Entry#{expires_at => Exp}),
                        [lg_store_keys:expiry_op(expires_at, Exp, Key)]).

%% @doc 读取 Responses API 会话记录（previous_response_id 展开用）；句柄不可用时按未找到处理。
-spec response_get(binary()) -> {ok, map()} | not_found.
response_get(Id) when is_binary(Id) ->
    case safe_get(responses, Id) of
        {ok, V} -> {ok, binary_to_term(V)};
        _ -> not_found
    end;
response_get(_) ->
    not_found.

%% @doc 保存 Responses API 会话记录（异步）；按 log_retention_days 清理。
-spec response_put(binary(), map()) -> ok.
response_put(Id, Rec) ->
    Now = lg_time:now_ms(),
    lg_store_writer:put(responses, Id, term_to_binary(Rec#{created_at => Now}),
                        [lg_store_keys:expiry_op(created_at, Now, Id)]).

%% @doc 保存告警通知记录（异步）；Alert 需含 id（alert_put 前由调用方生成，更新发送结果时复用）与 ts。
%% 键为 <<Ts:64, Id>>，按时间有序；按 log_retention_days 清理。
-spec alert_put(#{id := binary(), ts := non_neg_integer(), _ => _}) -> ok.
alert_put(#{id := Id, ts := Ts} = Alert) ->
    lg_store_writer:put(alerts, <<Ts:64, Id/binary>>, term_to_binary(Alert#{created_at => Ts})).

%% @doc 最近的告警通知记录（新 → 旧）。
%% 键按时间升序而 bitcask 不支持反向迭代：从最近一天起按 8 倍扩大窗口，直到窗口内够 Limit 条或更早已无记录；
%% 只解码最新的 Limit 条（及与第 Limit 条同毫秒的记录）。
-spec alerts(pos_integer()) -> [map()].
alerts(Limit) ->
    flush(logs),
    recent_alerts(h(alerts), Limit, lg_time:now_ms(), 86400000).

recent_alerts(H, Limit, Now, Window) ->
    Lo = max(0, Now - Window),
    Fun = fun(K, V, _Ts, _Ord, Acc) -> [{K, V} | Acc] end,
    case bitcask:range_fold(H, {<<Lo:64>>, undefined}, [], Fun, []) of
        {error, _} ->
            [];
        KVs ->
            case length(KVs) >= Limit orelse Lo =:= 0 orelse not any_key(H, undefined, <<Lo:64>>) of
                true -> newest_alerts(KVs, Limit);
                false -> recent_alerts(H, Limit, Now, Window * 8)
            end
    end.

%% KVs 新 → 旧（按键）；同一毫秒内按产生顺序（seq 单调递增）
newest_alerts(KVs, Limit) ->
    Top = case lists:split(min(Limit, length(KVs)), KVs) of
              {[], _} -> [];
              {Head, Rest} ->
                  {<<Ts:64, _/binary>>, _} = lists:last(Head),
                  Head ++ lists:takewhile(fun({<<T:64, _/binary>>, _}) -> T =:= Ts end, Rest)
          end,
    L = [binary_to_term(V) || {_, V} <- Top],
    lists:sublist(lists:sort(fun(A, B) -> {maps:get(ts, A, 0), maps:get(seq, A, 0)} >=
                                          {maps:get(ts, B, 0), maps:get(seq, B, 0)} end, L), Limit).

%% [Lo, Hi) 内是否有键（拿到第一个即中止扫描）
any_key(H, Lo, Hi) ->
    %% 第二个子句只为让回调有正常返回路径
    Fun = fun(_, _, _, _, false) -> throw(found);
             (_, _, _, _, Acc) -> Acc
          end,
    try bitcask:range_fold(H, {Lo, Hi}, [], Fun, false) of
        _ -> false
    catch
        throw:found -> true
    end.

group_key(GroupBy, Row) ->
    [case D of
         hour -> {hour, maps:get(hour, Row) * 3600000};
         day -> {day, (maps:get(hour, Row) div 24) * 86400000};
         _ -> {D, maps:get(D, Row, undefined)}
     end || D <- GroupBy].

add(A, B) ->
    maps:merge_with(fun(_, X, Y) -> X + Y end, A, B).

idx_type(tag) -> t;
idx_type(client) -> c;
idx_type(key_id) -> k;
idx_type(route) -> r;
idx_type(user_id) -> u;
idx_type(session) -> s.

%% @doc 存储写入健康：近期有写盘错误时为 degraded（/health 使用）。
-spec health() -> ok | {degraded, map()}.
health() ->
    lg_store_handles:health().

h(Cask) ->
    lg_store_handles:handle(Cask).

%% 热路径读：句柄缺失（badarg，存储重启中）或读失败都不抛出
safe_get(Cask, Key) ->
    try bitcask:get(h(Cask), Key) of
        {ok, V} -> {ok, V};
        _ -> not_found
    catch
        _:_ -> not_found
    end.
