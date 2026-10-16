-module(lg_narrate_tests).

-include_lib("eunit/include/eunit.hrl").

name(<<"c1">>) -> <<"minimax-a">>;
name(<<"c2">>) -> <<"glm">>;
name(Id) -> Id.

texts(Log) -> [{T, X} || #{tone := T, text := X} <- lg_narrate:lines(Log, fun name/1)].

intent_rule_test() ->
    Log = #{route => <<"coder">>, model => <<"coder">>, client => <<"claude-code">>, status => 200, stream => true,
            rule => 3, routed_to => <<"strong">>,
            intent => #{intents => [<<"a quick question">>, <<"writing or fixing tests">>], answer => 2, ms => 1234,
                        classifier => <<"judge">>},
            plan_trace => [#{route => <<"strong">>, credential => <<"c1">>, upstream_model => <<"MiniMax-M2.7">>, tier => hot, note => <<>>},
                           #{route => <<"coder">>, credential => <<"c2">>, upstream_model => <<"glm-5.3">>, tier => hot, note => <<>>}],
            attempt_list => [#{credential => <<"c1">>, upstream_model => <<"MiniMax-M2.7">>, ok => true, duration_ms => 3400}],
            credential => <<"c1">>, upstream_model => <<"MiniMax-M2.7">>, duration_ms => 3456, ttft_ms => 800,
            usage => #{input => 1500, output => 600, cache_read => 0, cache_write => 0}, cost => 0.00031},
    ?assertEqual(
       [{info, <<"Claude Code 请求了 coder：候选 minimax-a（MiniMax-M2.7）、glm（glm-5.3）"/utf8>>},
        {info, <<"命中规则 3（意图是“writing or fixing tests”），先发给 strong；本路由的目标排在后面，失败时接手"/utf8>>},
        {muted, <<"问 judge 这一轮属于“a quick question”“writing or fixing tests”中的哪一个，它说“writing or fixing tests”（1.2 秒）"/utf8>>},
        {ok, <<"minimax-a（MiniMax-M2.7）用 3.5 秒完成回答，首 token 800 毫秒 · 2.1k token · $0.0003"/utf8>>}],
       texts(Log)).

fallback_affinity_test() ->
    Log = #{route => <<"gpt">>, model => <<"claude-sonnet-4-5">>, client => <<"codex">>, status => 200,
            affinity => <<"broken:cache_cold">>,
            affinity_prev => #{credential => <<"c1">>, upstream_model => <<"m">>, cache_read => 0},
            plan_trace => [#{route => <<"gpt">>, credential => <<"c1">>, upstream_model => <<"m">>, tier => hot, note => <<>>},
                           #{route => <<"gpt">>, credential => <<"c2">>, upstream_model => <<"g">>, tier => exhausted,
                             note => <<"5h 100% 重置 10-13 14:00"/utf8>>}],
            attempt_list => [#{credential => <<"c1">>, upstream_model => <<"m">>, ok => false, kind => rate_limit,
                               message => <<"rate limit exceeded(RPM)">>, duration_ms => 120},
                             #{credential => <<"c2">>, upstream_model => <<"g">>, ok => true, duration_ms => 900}],
            credential => <<"c2">>, upstream_model => <<"g">>, duration_ms => 1100, plan => true, plan_usd => 0.002,
            usage => #{input => 10, output => 5, cache_read => 2000, cache_write => 0}},
    [{info, L1}, {muted, L2}, {warn, L3}, {warn, L4}, {ok, L5}] = texts(Log),
    ?assertEqual(<<"Codex 请求了 gpt（请求的模型名 claude-sonnet-4-5）：候选 minimax-a（m）、glm（g）"/utf8>>, L1),
    ?assertMatch(<<"这个会话上次由 minimax-a 回答，但上次只从缓存读了 0 token"/utf8, _/binary>>, L2),
    ?assertEqual(<<"glm（g）套餐额度用尽（5h 100% 重置 10-13 14:00），排到后面"/utf8>>, L3),
    ?assertEqual(<<"minimax-a（m）被限流：rate limit exceeded(RPM)，改用下一个（第 2 次尝试）"/utf8>>, L4),
    ?assertEqual(<<"glm（g）用 1.1 秒完成回答 · 2.0k token（缓存读 2.0k） · 套餐内（等价 $0.0020）"/utf8>>, L5).

error_and_cache_test() ->
    Err = #{route => <<"gpt">>, status => 503, client => <<"other">>,
            attempt_list => [#{credential => <<"c1">>, upstream_model => <<"m">>, ok => false, kind => server,
                               message => binary:copy(<<"x">>, 200), duration_ms => 10}],
            error => #{kind => server, message => <<"Upstream returned HTTP 503">>}},
    [{info, _}, {error, E}] = texts(Err),
    ?assertEqual(<<"minimax-a（m）返回服务端错误，客户端收到 503：Upstream returned HTTP 503"/utf8>>, E),
    Hit = #{route => <<"gpt">>, status => 200, cache_hit => true, saved_usd => 0.5},
    ?assertMatch([{info, _}, {ok, <<"命中响应缓存，没有访问上游，节省 $0.50"/utf8>>}], texts(Hit)),
    %% 同一轮沿用判定、意图判断失败
    Reused = #{route => <<"coder">>, rule => 2, rule_reused => true, routed_to => <<"cheap">>,
               intent => #{error => <<"timeout">>, answer => 0, ms => 8000, intents => [<<"a">>], classifier => <<"j">>}},
    [{info, _}, {info, R}, {warn, I}] = texts(Reused),
    ?assertMatch(<<"这一轮沿用之前的判定：规则 2，先发给 cheap"/utf8, _/binary>>, R),
    ?assertEqual(<<"意图判断失败（timeout），本轮照常路由（判断模型 j）"/utf8>>, I).

nested_rules_test() ->
    Log = #{route => <<"claude-*">>, status => 200,
            nested_rules => [#{route => <<"coder">>, rule => 2, routed_to => <<"strong">>,
                               intent => #{intents => [<<"q">>, <<"code">>], answer => 2, ms => 900, classifier => <<"judge">>}}]},
    [{info, _}, {info, R}, {muted, I}] = texts(Log),
    ?assertEqual(<<"嵌套路由 coder 命中规则 2（意图是“code”），先发给 strong；本路由的目标排在后面，失败时接手"/utf8>>, R),
    ?assertMatch(<<"嵌套路由 coder 问 judge 这一轮属于"/utf8, _/binary>>, I).

%% 连接类错误的原始 Erlang 原因映射成一句中文（原文仍留在结构化日志里供排查）
network_error_test() ->
    Err = fun(Msg) ->
                  #{route => <<"gpt">>, status => 502, client => <<"other">>,
                    attempt_list => [#{credential => <<"c1">>, upstream_model => <<"m">>, ok => false, kind => network,
                                       message => Msg, duration_ms => 10}],
                    error => #{kind => network, message => Msg}}
          end,
    [{info, _}, {error, E}] = texts(Err(<<"Upstream connection failed: {down,{shutdown,nxdomain}}">>)),
    ?assertEqual(<<"minimax-a（m）网络错误，客户端收到 502：上游域名无法解析"/utf8>>, E),
    Cases = [{<<"Upstream connection failed: econnrefused">>, <<"上游拒绝连接"/utf8>>},
             {<<"Upstream connection failed: {error,econnreset}">>, <<"上游重置了连接"/utf8>>},
             {<<"Upstream connection failed: {error,closed}">>, <<"连接被上游关闭"/utf8>>},
             {<<"Upstream request failed: timeout">>, <<"连接超时"/utf8>>},
             {<<"Upstream connection failed: {tls_alert,{handshake_failure}}">>, <<"上游 TLS 握手失败"/utf8>>}],
    [begin
         [{info, _}, {error, X}] = texts(Err(M)),
         ?assertEqual(<<"minimax-a（m）网络错误，客户端收到 502："/utf8, T/binary>>, X)
     end || {M, T} <- Cases],
    %% 未识别的错误原文保留
    [{info, _}, {error, Raw}] = texts(Err(<<"Upstream connection failed: enetunreach">>)),
    ?assertEqual(<<"minimax-a（m）网络错误，客户端收到 502：Upstream connection failed: enetunreach"/utf8>>, Raw),
    %% 尝试记录里的同样映射
    Log2 = #{route => <<"gpt">>, status => 200,
             attempt_list => [#{credential => <<"c1">>, upstream_model => <<"m">>, ok => false, kind => network,
                                message => <<"Upstream connection failed: {down,{shutdown,nxdomain}}">>, duration_ms => 10},
                              #{credential => <<"c2">>, upstream_model => <<"g">>, ok => true, duration_ms => 900}],
             credential => <<"c2">>, upstream_model => <<"g">>, duration_ms => 1000,
             usage => #{input => 10, output => 5, cache_read => 0, cache_write => 0}},
    [{info, _}, {warn, W}, {ok, _}] = texts(Log2),
    ?assertEqual(<<"minimax-a（m）网络错误：上游域名无法解析，改用下一个（第 2 次尝试）"/utf8>>, W).
