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

strip_at_threshold() ->
    %% 40KB body：一个 span 约 40KB，占 64KB 上限的 62%（超过 50% 阈值）
    ok = lg_otlp:submit(big_log(40960)),
    %% 等待 gen_server 处理（cast 异步）
    timer:sleep(50),
    ?assert(counter(litegate_otlp_stripped_total) >= 1),
    ok = lg_otlp:flush().

drop_at_cap() ->
    %% 每条 40KB body，两条 80KB > 64KB 上限 → 第二条应被丢
    ok = lg_otlp:submit(big_log(40960)),
    timer:sleep(50),
    ok = lg_otlp:submit(big_log(40960)),
    timer:sleep(50),
    ?assert(counter(litegate_otlp_dropped_total) >= 1),
    ok = lg_otlp:flush().

bytes_zero_after_flush() ->
    ok = lg_otlp:submit(big_log(1024)),
    timer:sleep(50),
    ?assertEqual(0, counter(litegate_otlp_dropped_total)),
    ok = lg_otlp:flush(),
    %% flush 后队列和 bytes 归零（内部 state 验证通过 queue 空推断）
    ok = lg_otlp:submit(big_log(1024)),
    timer:sleep(50),
    ?assertEqual(0, counter(litegate_otlp_dropped_total)).

no_bodies_no_strip() ->
    ok = lg_config:set(otlp_bodies, false),
    ok = lg_otlp:submit(big_log(40960)),
    timer:sleep(50),
    ?assertEqual(0, counter(litegate_otlp_stripped_total)),
    ok = lg_otlp:flush().
