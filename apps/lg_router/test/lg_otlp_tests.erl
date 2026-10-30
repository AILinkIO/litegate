-module(lg_otlp_tests).

-include_lib("eunit/include/eunit.hrl").

parse_test() ->
    ?assertEqual({ok, <<"4bf92f3577b34da6a3ce929d0e0e4736">>, <<"00f067aa0ba902b7">>},
                 lg_otlp:parse_traceparent(<<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>)),
    ?assertEqual(error, lg_otlp:parse_traceparent(<<"01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>)),
    ?assertEqual(error, lg_otlp:parse_traceparent(<<"00-00000000000000000000000000000000-00f067aa0ba902b7-01">>)),
    ?assertEqual(error, lg_otlp:parse_traceparent(undefined)),
    ?assertEqual([{<<"authorization">>, <<"Basic abc==">>}, {<<"x-langfuse-ingestion-version">>, <<"4">>}],
                 lg_otlp:parse_headers(<<"Authorization=Basic%20abc==, x-langfuse-ingestion-version=4">>)),
    ?assertEqual([], lg_otlp:parse_headers(<<>>)).

%% T01：大 body span 字节封顶 — 超 50% 剥 body、超上限丢弃、flush 后 bytes 归零
byte_cap_test_() ->
    {foreach,
     fun() ->
             Dir = lg_core_test_util:start(),
             {ok, _} = application:ensure_all_started(lg_router),
             ok = lg_config:set(otlp_enabled, true),
             ok = lg_config:set(otlp_endpoint, <<"http://127.0.0.1:1">>),
             ok = lg_config:set(otlp_bodies, true),
             ok = lg_config:set(otlp_queue_max_bytes, 65536),  %% 64KB 便于测试
             Dir
     end,
     fun(Dir) ->
             ok = lg_config:set(otlp_bodies, false),
             ok = lg_config:set(otlp_enabled, false),
             lg_core_test_util:stop(Dir)
     end,
     [?_test(strip_at_threshold()),
      ?_test(drop_at_cap()),
      ?_test(bytes_zero_after_flush()),
      ?_test(no_bodies_no_strip())]}.

counter(Name) ->
    #{counters := Cs} = lg_metrics:snapshot(),
    lists:sum([V || {N, _, V} <- Cs, N =:= Name]).

%% 构造一个带大 body 的 span（submit → gen_server 处理）
big_log(BodyBytes) ->
    Big = binary:copy(<<"x">>, BodyBytes),
    Messages = #{request => #{<<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => Big}]},
                 response => Big},
    Log = #{id => <<>>, route => <<"t">>, model => <<"m">>, format => openai, stream => false,
            duration_ms => 1, status => 200},
    {Log, Messages, #{}}.

%% 端点不可达（127.0.0.1:1），flush 返回 {error, _}；这里只关心入队计数，不断言导出结果
submit({Log, Messages, Extra}) ->
    lg_otlp:submit(Log, Messages, Extra).

strip_at_threshold() ->
    Pid = whereis(lg_otlp),
    %% 40KB body：一个 span 约 40KB，占 64KB 上限的 62%（超过 50% 阈值）
    ok = submit(big_log(40960)),
    %% 等待 gen_server 处理（cast 异步）
    timer:sleep(50),
    ?assert(counter(litegate_otlp_stripped_total) >= 1),
    %% 剥离路径不能让进程崩溃（此前把 boolean 当整数累加，崩溃后连带 lg_router 退出）
    ?assertEqual(Pid, whereis(lg_otlp)),
    _ = lg_otlp:flush().

%% 队列状态（sys:get_state 排在此前投递的 cast 之后处理，返回时这些 span 已入队）
queue_state() ->
    #{len := Len, bytes := Bytes} = sys:get_state(lg_otlp),
    {Len, Bytes}.

drop_at_cap() ->
    %% 超 50% 阈值先剥 body；剥离后仍超上限才丢。上限 4KB 时剥离后的 span（约 2KB 固定开销）只能放下两条，
    %% 第三条起丢弃。端点不可达，定时导出失败也计入 dropped，所以只断言下限与队列不变量
    ok = lg_config:set(otlp_queue_max_bytes, 4096),
    _ = lg_otlp:flush(),
    Before = counter(litegate_otlp_dropped_total),
    [ok = submit(big_log(40960)) || _ <- lists:seq(1, 4)],
    {Len, Bytes} = queue_state(),
    ?assert(Len =< 2),
    ?assert(Bytes =< 4096),
    ?assert(counter(litegate_otlp_dropped_total) - Before >= 2),
    _ = lg_otlp:flush().

bytes_zero_after_flush() ->
    ok = submit(big_log(1024)),
    {Len0, Bytes0} = queue_state(),
    ?assert(Len0 >= 1 orelse Bytes0 =:= 0),        %% 期间可能刚好被定时导出取走
    _ = lg_otlp:flush(),
    %% flush（无论导出成败）后队列与字节计数归零
    ?assertEqual({0, 0}, queue_state()),
    %% 小 span 不剥离、不丢弃
    Stripped = counter(litegate_otlp_stripped_total),
    ok = submit(big_log(1024)),
    {Len1, _} = queue_state(),
    ?assert(Len1 =< 1),
    ?assertEqual(Stripped, counter(litegate_otlp_stripped_total)),
    _ = lg_otlp:flush().

no_bodies_no_strip() ->
    ok = lg_config:set(otlp_bodies, false),
    ok = submit(big_log(40960)),
    timer:sleep(50),
    ?assertEqual(0, counter(litegate_otlp_stripped_total)),
    _ = lg_otlp:flush().
