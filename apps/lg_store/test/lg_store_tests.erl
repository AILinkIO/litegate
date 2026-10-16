-module(lg_store_tests).

-include_lib("eunit/include/eunit.hrl").

store_test_() ->
    {foreach,
     fun() ->
             Dir = lg_core_test_util:start(),
             {ok, _} = application:ensure_all_started(lg_store),
             Dir
     end,
     fun(Dir) ->
             application:stop(lg_store),
             lg_core_test_util:stop(Dir)
     end,
     [?_test(record_and_read()),
      ?_test(pagination()),
      ?_test(filters_and_time_range()),
      ?_test(usage_rollup()),
      ?_test(messages_toggle()),
      ?_test(persist_across_restart()),
      ?_test(search()),
      ?_test(latency_percentiles()),
      ?_test(cache_expiry()),
      ?_test(sessions())]}.

-define(H, 3600000).
-define(BASE, 1790000000000).  %% 某个整点附近的毫秒时间戳

%% 指定时间戳（毫秒）的日志 id
id_at(Ms, Seq) ->
    lg_store_keys:id(lg_store_keys:log_key(Ms * 1000, Seq)).

log(Id, Extra) ->
    maps:merge(#{id => Id, format => openai, route => <<"gpt">>, key_id => <<"k1">>,
                 user_id => <<"u1">>, credential => <<"c1">>, upstream_model => <<"up">>,
                 status => 200, usage => #{input => 10, output => 5, cache_read => 2, cache_write => 0},
                 cost => 0.5, duration_ms => 100}, Extra).

record_and_read() ->
    Id = lg_store:new_id(),
    Big = <<"data:image/png;base64,", (binary:copy(<<"A">>, 5000))/binary>>,
    ok = lg_store:record(log(Id, #{}),
                         #{request => #{<<"messages">> => [#{<<"content">> => [#{<<"image_url">> => #{<<"url">> => Big}}]}]},
                           response => <<"hi">>}),
    ok = lg_store:flush(),
    {ok, L} = lg_store:log(Id),
    ?assertMatch(#{id := Id, route := <<"gpt">>, cost := 0.5}, L),
    ?assert(abs(maps:get(ts, L) - lg_time:now_ms()) < 5000),
    {ok, #{request := Req, response := <<"hi">>}} = lg_store:messages(Id),
    [#{<<"content">> := [#{<<"image_url">> := #{<<"url">> := Url}}]}] = maps:get(<<"messages">>, Req),
    ?assertEqual(<<"data:image/png;base64,[omitted 5022 bytes]">>, Url),
    ?assertEqual(not_found, lg_store:log(<<"nothex">>)),
    ?assertEqual(not_found, lg_store:log(lg_store:new_id())).

pagination() ->
    Ids = [id_at(?BASE + I * 1000, I) || I <- lists:seq(1, 5)],
    [ok = lg_store:record(log(Id, #{}), undefined) || Id <- Ids],
    #{items := P1, next_cursor := C1} = lg_store:logs(#{limit => 2}),
    #{items := P2, next_cursor := C2} = lg_store:logs(#{limit => 2, cursor => C1}),
    #{items := P3, next_cursor := C3} = lg_store:logs(#{limit => 2, cursor => C2}),
    Got = [maps:get(id, L) || L <- P1 ++ P2 ++ P3],
    ?assertEqual(lists:reverse(Ids), Got),
    ?assertNotEqual(null, C2),
    ?assertEqual(null, C3),
    %% 恰好整页时不应给出 next_cursor
    #{items := All, next_cursor := null} = lg_store:logs(#{limit => 5}),
    ?assertEqual(5, length(All)).

filters_and_time_range() ->
    A = id_at(?BASE, 1),
    B = id_at(?BASE + ?H, 2),
    C = id_at(?BASE + 2 * ?H, 3),
    ok = lg_store:record(log(A, #{key_id => <<"k1">>, route => <<"gpt">>}), undefined),
    ok = lg_store:record(log(B, #{key_id => <<"k2">>, route => <<"gpt">>,
                                  error => #{kind => server}}), undefined),
    ok = lg_store:record(log(C, #{key_id => <<"k1">>, route => <<"claude">>}), undefined),
    Ids = fun(Q) -> [maps:get(id, L) || L <- maps:get(items, lg_store:logs(Q))] end,
    ?assertEqual([C, A], Ids(#{key_id => <<"k1">>})),
    ?assertEqual([B, A], Ids(#{route => <<"gpt">>})),
    %% 索引 + 额外过滤
    ?assertEqual([A], Ids(#{route => <<"gpt">>, key_id => <<"k1">>})),
    ?assertEqual([B], Ids(#{errors_only => true})),
    ?assertEqual([B], Ids(#{from => ?BASE + 1, to => ?BASE + 2 * ?H})),
    ?assertEqual([C], Ids(#{key_id => <<"k1">>, from => ?BASE + 1})),
    %% 索引分页
    #{items := [_], next_cursor := Cur} = lg_store:logs(#{key_id => <<"k1">>, limit => 1}),
    ?assertEqual([A], Ids(#{key_id => <<"k1">>, limit => 1, cursor => Cur})),
    ?assertEqual([], Ids(#{key_id => <<"nobody">>})).

usage_rollup() ->
    Rec = fun(Ms, Seq, Extra) -> ok = lg_store:record(log(id_at(Ms, Seq), Extra), undefined) end,
    Rec(?BASE, 1, #{}),
    Rec(?BASE + 10, 2, #{route => <<"claude">>, cost => 1.0}),
    Rec(?BASE + ?H, 3, #{error => #{kind => timeout}, usage => #{}}),
    Rec(?BASE + ?H, 4, #{key_id => <<"k2">>}),
    Q = #{from => ?BASE - ?H, to => ?BASE + 3 * ?H},
    [Total] = lg_store:usage(Q),
    ?assertMatch(#{requests := 4, errors := 1, input := 30, output := 15, cache_read := 6,
                   duration_ms := 400}, Total),
    ?assertEqual(2.5, maps:get(cost, Total)),
    ByRoute = lg_store:usage(Q#{group_by => [route]}),
    ?assertMatch([#{route := <<"claude">>, requests := 1}, #{route := <<"gpt">>, requests := 3}], ByRoute),
    ByHour = lg_store:usage(Q#{group_by => [hour]}),
    ?assertEqual([2, 2], [maps:get(requests, R) || R <- ByHour]),
    ?assertMatch([#{requests := 1}], lg_store:usage(Q#{key_id => <<"k2">>})),
    %% 时间窗外
    ?assertEqual([], lg_store:usage(#{from => ?BASE + 5 * ?H, to => ?BASE + 6 * ?H})),
    %% 多次 flush 之间继续累加
    Rec(?BASE + 20, 5, #{}),
    [#{requests := 5}] = lg_store:usage(Q).

messages_toggle() ->
    ok = lg_config:set(record_messages, false),
    Id = lg_store:new_id(),
    ok = lg_store:record(log(Id, #{}), #{request => #{}, response => <<"x">>}),
    ok = lg_store:flush(),
    ?assertMatch({ok, _}, lg_store:log(Id)),
    ?assertEqual(not_found, lg_store:messages(Id)),
    ok = lg_config:unset(record_messages).

persist_across_restart() ->
    Id = lg_store:new_id(),
    ok = lg_store:record(log(Id, #{}), undefined),
    ok = application:stop(lg_store),
    {ok, _} = application:ensure_all_started(lg_store),
    ?assertMatch({ok, #{id := Id}}, lg_store:log(Id)),
    ?assertMatch([#{requests := 1}], lg_store:usage(#{})).

chat_msgs(User, Reply) ->
    #{request => #{<<"messages">> => [#{<<"role">> => <<"system">>, <<"content">> => <<"sys prompt">>},
                                      #{<<"role">> => <<"user">>, <<"content">> => <<"旧问题"/utf8>>},
                                      #{<<"role">> => <<"assistant">>, <<"content">> => <<"旧回答"/utf8>>},
                                      #{<<"role">> => <<"user">>, <<"content">> => User}]},
      response => Reply}.

search() ->
    A = id_at(?BASE, 1),
    B = id_at(?BASE + ?H, 2),
    C = id_at(?BASE + 2 * ?H, 3),
    ok = lg_store:record(log(A, #{key_id => <<"k1">>}),
                         chat_msgs(<<"如何用 Erlang 实现分布式网关？"/utf8>>, <<"可以使用 OTP。"/utf8>>)),
    ok = lg_store:record(log(B, #{key_id => <<"k2">>, route => <<"claude">>}),
                         chat_msgs([#{<<"type">> => <<"text">>, <<"text">> => <<"网关限流怎么做"/utf8>>}],
                                   <<"用令牌桶。"/utf8>>)),
    ok = lg_store:record(log(C, #{key_id => <<"k1">>}), chat_msgs(<<"天气如何"/utf8>>, <<"晴天"/utf8>>)),
    Ids = fun(Q) -> [maps:get(id, L) || L <- maps:get(items, lg_store:search(Q))] end,
    ?assertEqual(lists:sort([A, B]), lists:sort(Ids(#{q => <<"网关"/utf8>>}))),
    %% 大小写不敏感；回复内容也可检索；只索引最后一条用户消息（旧问题不在索引里）
    ?assertEqual([A], Ids(#{q => <<"ERLANG">>})),
    ?assertEqual([B], Ids(#{q => <<"令牌桶"/utf8>>})),
    ?assertEqual([], Ids(#{q => <<"旧问题"/utf8>>})),
    %% 过滤
    ?assertEqual([A], Ids(#{q => <<"网关"/utf8>>, key_id => <<"k1">>})),
    ?assertEqual([B], Ids(#{q => <<"网关"/utf8>>, route => <<"claude">>})),
    ?assertEqual([B], Ids(#{q => <<"网关"/utf8>>, from => ?BASE + 1})),
    ?assertEqual([A], Ids(#{q => <<"网关"/utf8>>, to => ?BASE + ?H})),
    [#{score := Score} | _] = maps:get(items, lg_store:search(#{q => <<"网关"/utf8>>})),
    ?assert(is_float(Score)),
    ?assertEqual([], Ids(#{q => <<"不存在的词"/utf8>>})),
    %% 关闭记录内容时不建索引
    ok = lg_config:set(record_messages, false),
    D = id_at(?BASE + 3 * ?H, 4),
    ok = lg_store:record(log(D, #{}), chat_msgs(<<"网关"/utf8>>, <<>>)),
    ?assertEqual(2, length(Ids(#{q => <<"网关"/utf8>>}))),
    ok = lg_config:unset(record_messages),
    %% 清理后检索不到
    {ok, KeyA} = lg_store_keys:from_id(A),
    ok = lg_store_writer:delete(search, [KeyA]),
    ?assertEqual([B], Ids(#{q => <<"网关"/utf8>>})).

latency_percentiles() ->
    %% 10 个非流式请求：耗时 100..1000ms；2 个流式请求：TTFT 300ms / 3000ms
    [ok = lg_store:record(log(id_at(?BASE + I, I), #{duration_ms => I * 100}), undefined) || I <- lists:seq(1, 10)],
    %% 流式请求放在下一个小时，便于单独查询不含流式的时段（用量按小时汇总）
    ok = lg_store:record(log(id_at(?BASE + ?H, 20), #{stream => true, duration_ms => 5000, ttft_ms => 300}), undefined),
    ok = lg_store:record(log(id_at(?BASE + ?H + 1, 21), #{stream => true, duration_ms => 8000, ttft_ms => 3000}), undefined),
    [Row] = lg_store:usage(#{from => ?BASE - ?H, to => ?BASE + 2 * ?H}),
    ?assertMatch(#{requests := 12, streams := 2}, Row),
    ?assertNot(lists:any(fun is_tuple/1, maps:keys(Row))),
    %% 12 个样本：桶 ≤250(2) ≤500(3) ≤1000(5) ≤5000(1) ≤10000(1)；P50 落在 500..1000 桶
    P50 = maps:get(p50_ms, Row),
    ?assert(P50 > 500 andalso P50 =< 1000),
    ?assert(maps:get(p95_ms, Row) > 2000),
    %% TTFT 只来自两个流式请求
    ?assert(maps:get(ttft_p50_ms, Row) =< 500),
    ?assert(maps:get(ttft_p95_ms, Row) > 2000),
    %% 无流式请求时 TTFT 分位数为 null
    [Row2] = lg_store:usage(#{from => ?BASE - ?H, to => lg_store_keys:hour(?BASE + ?H) * ?H}),
    ?assertMatch(#{ttft_p50_ms := null, p50_ms := P} when is_integer(P), Row2).

cache_expiry() ->
    ok = lg_store:cache_put(<<"k1">>, 60, #{body => <<"b">>}),
    ok = lg_store:cache_put(<<"k2">>, 1, #{body => <<"old">>}),
    ok = lg_store:flush(),
    timer:sleep(50),
    ?assertMatch({ok, #{body := <<"b">>}}, lg_store:cache_get(<<"k1">>)),
    ?assertEqual(miss, lg_store:cache_get(<<"nope">>)),
    timer:sleep(1100),
    ?assertEqual(miss, lg_store:cache_get(<<"k2">>)),
    %% 清理删除过期条目
    #{cache := 1} = lg_store_janitor:run(),
    ?assertMatch({ok, _}, lg_store:cache_get(<<"k1">>)).

%% 会话汇总：按最近活动排序、分页、过滤；会话索引列出会话内的请求
sessions() ->
    S = fun(Ms, Seq, Sid, Extra) -> ok = lg_store:record(log(id_at(Ms, Seq), Extra#{session => Sid}), undefined) end,
    S(?BASE, 1, <<"s1">>, #{new_turn => true, client => <<"claude-code">>, route => <<"a">>}),
    S(?BASE + 1000, 2, <<"s2">>, #{new_turn => true, key_id => <<"k2">>}),
    S(?BASE + 2000, 3, <<"s1">>, #{route => <<"b">>, upstream_model => <<"up2">>, error => #{kind => server}}),
    S(?BASE + 3000, 4, <<"s1">>, #{new_turn => true, route => <<"a">>}),
    ok = lg_store:record(log(id_at(?BASE + 4000, 5), #{}), undefined),
    {ok, S1} = lg_store:session(<<"s1">>),
    ?assertMatch(#{id := <<"s1">>, first_ts := ?BASE, last_ts := 1790000003000, requests := 3, turns := 2, errors := 1,
                   input := 30, output := 15, cache_read := 6, routes := [<<"a">>, <<"b">>], models := [<<"up">>, <<"up2">>],
                   client := <<"claude-code">>, key_id := <<"k1">>}, S1),
    ?assert(abs(maps:get(cost, S1) - 1.5) < 1.0e-9),
    ?assertEqual(not_found, lg_store:session(<<"nope">>)),
    Sids = fun(Q) -> [maps:get(id, X) || X <- maps:get(items, lg_store:sessions(Q))] end,
    ?assertEqual([<<"s1">>, <<"s2">>], Sids(#{})),
    ?assertEqual([<<"s2">>], Sids(#{key_id => <<"k2">>})),
    ?assertEqual([<<"s2">>], Sids(#{to => ?BASE + 2000})),
    ?assertEqual([<<"s1">>], Sids(#{from => ?BASE + 2000})),
    #{items := [_], next_cursor := C} = lg_store:sessions(#{limit => 1}),
    ?assertMatch(#{items := [#{id := <<"s2">>}], next_cursor := null}, lg_store:sessions(#{limit => 1, cursor => C})),
    %% 最近活动键只保留一条
    S(?BASE + 5000, 6, <<"s2">>, #{}),
    ?assertEqual([<<"s2">>, <<"s1">>], Sids(#{})),
    #{items := Logs} = lg_store:logs(#{session => <<"s1">>}),
    ?assertEqual([id_at(?BASE + 3000, 4), id_at(?BASE + 2000, 3), id_at(?BASE, 1)], [maps:get(id, L) || L <- Logs]).
