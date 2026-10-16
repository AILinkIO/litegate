-module(lg_store_janitor_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DAY, 86400000).

janitor_test_() ->
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
     [{timeout, 60, ?_test(purge_old_logs_and_usage())},
      ?_test(retention_disabled()),
      ?_test(status())]}.

id_at(Ms, Seq) ->
    lg_store_keys:id(lg_store_keys:log_key(Ms * 1000, Seq)).

log(Id, Key) ->
    #{id => Id, route => <<"r">>, key_id => Key, user_id => <<"u">>, cost => 0.1,
      usage => #{input => 1, output => 1, cache_read => 0, cache_write => 0}}.

purge_old_logs_and_usage() ->
    Now = lg_time:now_ms(),
    Old = [id_at(Now - 40 * ?DAY + I, I) || I <- lists:seq(1, 2500)],
    Recent = [id_at(Now - ?DAY + I, 10000 + I) || I <- lists:seq(1, 3)],
    Msg = #{request => #{}, response => <<"x">>},
    [ok = lg_store:record(log(Id, <<"k-old">>), Msg) || Id <- Old],
    [ok = lg_store:record(log(Id, <<"k-new">>), Msg) || Id <- Recent],
    %% 很早的用量（500 天前）只能通过直接记日志的方式产生小时汇总
    ok = lg_store:record(log(id_at(Now - 500 * ?DAY, 1), <<"k-ancient">>), undefined),
    %% 会话按最近活动过期
    ok = lg_store:record((log(id_at(Now - 40 * ?DAY, 90001), <<"k-old">>))#{session => <<"old-s">>}, undefined),
    ok = lg_store:record((log(id_at(Now - 40 * ?DAY, 90002), <<"k-old">>))#{session => <<"live-s">>}, undefined),
    ok = lg_store:record((log(id_at(Now - ?DAY, 90003), <<"k-new">>))#{session => <<"live-s">>}, undefined),
    ok = lg_store:flush(),
    ?assertEqual(3, length(lg_store:usage(#{from => 0, to => Now + 1, group_by => [key_id]}))),

    Stats = lg_store_janitor:run(),
    %% 2500 条旧日志 + 1 条 500 天前的日志
    ?assertMatch(#{logs := 2503, index := 7511, sessions := 1, log_retention_days := 30, usage_retention_days := 400}, Stats),
    ?assertEqual(not_found, lg_store:session(<<"old-s">>)),
    ?assertMatch({ok, #{requests := 2}}, lg_store:session(<<"live-s">>)),
    ?assertMatch(#{items := [#{id := <<"live-s">>}]}, lg_store:sessions(#{})),
    ?assert(maps:get(usage, Stats) >= 1),

    ?assertEqual(not_found, lg_store:log(hd(Old))),
    ?assertEqual(not_found, lg_store:messages(hd(Old))),
    %% 检索索引同步清理：旧日志的内容 "x" 不再命中，新日志仍在
    ?assertEqual(3, length(maps:get(items, lg_store:search(#{q => <<"x">>, limit => 200})))),
    ?assertMatch({ok, _}, lg_store:log(hd(Recent))),
    ?assertMatch({ok, _}, lg_store:messages(hd(Recent))),
    #{items := Items} = lg_store:logs(#{limit => 100}),
    ?assertEqual(lists:reverse(Recent) ++ [id_at(Now - ?DAY, 90003)], [maps:get(id, L) || L <- Items]),
    ?assertMatch(#{items := []}, lg_store:logs(#{key_id => <<"k-old">>})),
    ?assertMatch(#{items := [_, _, _, _]}, lg_store:logs(#{key_id => <<"k-new">>})),
    ?assertMatch(#{items := [_, _, _, _]}, lg_store:logs(#{user_id => <<"u">>})),
    %% 500 天前的小时汇总被删；40 天前的仍在（用量保留 400 天）
    Keys = [maps:get(key_id, R) || R <- lg_store:usage(#{from => 0, to => Now + 1, group_by => [key_id]})],
    ?assertEqual([<<"k-new">>, <<"k-old">>], lists:sort(Keys)),
    ?assertMatch(#{logs := 2503, at := _}, lg_store_janitor:status()),
    %% 再跑一次无事可做
    ?assertMatch(#{logs := 0, index := 0, usage := 0, sessions := 0}, lg_store_janitor:run()).

retention_disabled() ->
    ok = lg_config:set(log_retention_days, 0),
    ok = lg_config:set(usage_retention_days, 0),
    Id = id_at(lg_time:now_ms() - 1000 * ?DAY, 1),
    ok = lg_store:record(log(Id, <<"k">>), undefined),
    ok = lg_store:flush(),
    ?assertMatch(#{logs := 0, usage := 0}, lg_store_janitor:run()),
    ?assertMatch({ok, _}, lg_store:log(Id)),
    ok = lg_config:unset(log_retention_days),
    ok = lg_config:unset(usage_retention_days).

status() ->
    ok = lg_store:record(log(lg_store:new_id(), <<"k">>), undefined),
    ok = lg_store:flush(),
    S = lg_store:status(),
    ?assertEqual([logs, msgs, idx, usage, search, cache, responses, alerts, sessions], [maps:get(cask, C) || C <- S]),
    [#{keys := 1, bytes := B} | _] = S,
    ?assert(B > 0).
