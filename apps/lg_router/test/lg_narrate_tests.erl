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

%%--------------------------------------------------------------------
%% 英文（lines/3）：每个分支一句

en(Log) -> [{T, X} || #{tone := T, text := X} <- lg_narrate:lines(Log, en, fun name/1)].

lang_arg_test() ->
    Log = #{route => <<"gpt">>, status => 200, cache_hit => true},
    %% lines/2 的第二个参数可以是语言，也可以是名称函数（中文）
    ?assertMatch([#{text := <<"A client requested gpt">>} | _], lg_narrate:lines(Log, en)),
    ?assertMatch([#{text := <<"客户端 请求了 gpt"/utf8>>} | _], lg_narrate:lines(Log, zh)),
    ?assertEqual(lg_narrate:lines(Log), lg_narrate:lines(Log, zh)),
    ?assertEqual(lg_narrate:lines(Log, fun name/1), lg_narrate:lines(Log, zh, fun name/1)),
    %% 未知语言按中文
    ?assertEqual(lg_narrate:lines(Log, zh), lg_narrate:lines(Log, fr)),
    ?assertEqual(<<"5h 80% resets 10-13 14:00 · recent 1200 tok"/utf8>>,
                 lg_narrate:note(<<"5h 80% 重置 10-13 14:00 · 近期 1200 tok"/utf8>>, en)),
    ?assertEqual(<<"5h 80%">>, lg_narrate:note(<<"5h 80%">>, zh)).

en_intent_rule_test() ->
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
       [{info, <<"Claude Code requested coder; candidates: minimax-a (MiniMax-M2.7), glm (glm-5.3)">>},
        {info, <<"Matched rule 3 (intent: “writing or fixing tests”); sending to strong first, "/utf8,
                 "with this route's own targets as fallback">>},
        {muted, <<"Asked judge which of “a quick question”, “writing or fixing tests” this turn belongs to; "/utf8,
                  "it answered “writing or fixing tests” (1.2 s)"/utf8>>},
        {ok, <<"minimax-a (MiniMax-M2.7) answered in 3.5 s, first token after 800 ms · 2.1k tokens · $0.0003"/utf8>>}],
       en(Log)).

en_fallback_affinity_test() ->
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
    ?assertEqual(
       [{info, <<"Codex requested gpt (requested model name claude-sonnet-4-5); candidates: minimax-a (m), glm (g)">>},
        {muted, <<"This session was last answered by minimax-a, but only 0 tokens were read from cache last time "
                  "(or more than 5 minutes have passed), so it isn't worth staying">>},
        {warn, <<"glm (g) has used up its plan quota (5h 100% resets 10-13 14:00); moved to the back">>},
        {warn, <<"minimax-a (m) was rate-limited: rate limit exceeded(RPM); trying the next one (attempt 2)">>},
        {ok, <<"glm (g) answered in 1.1 s · 2.0k tokens (2.0k cache read) · covered by plan (equivalent to $0.0020)"/utf8>>}],
       en(Log)).

en_affinity_test() ->
    Base = #{route => <<"gpt">>, affinity_prev => #{credential => <<"c1">>, cache_read => 1}},
    T = fun(A) -> [_, {muted, X}] = en(Base#{affinity => A}), X end,
    ?assertEqual(<<"This session was last answered by minimax-a (1 token read from cache last time); staying with it">>,
                 T(<<"hit">>)),
    ?assertEqual(<<"This session was last answered by minimax-a, but it is cooling down; choosing again in normal order">>,
                 T(<<"broken:cooling">>)),
    ?assertEqual(<<"This session was last answered by minimax-a, but its plan window is almost used up; "
                   "choosing again in normal order">>, T(<<"broken:plan_window_full">>)),
    ?assertEqual(<<"This session was last answered by minimax-a, but it is at its concurrency limit with requests queued; "
                   "choosing again in normal order">>, T(<<"broken:concurrency_full">>)),
    ?assertEqual(<<"This session was last answered by minimax-a, but it is no longer part of this route">>,
                 T(<<"broken:target_gone">>)),
    ?assertEqual(<<"This session was last answered by minimax-a, but stickiness was dropped (whatever)">>,
                 T(<<"broken:whatever">>)).

en_tiers_test() ->
    Tr = fun(Tier) -> #{credential => <<"c2">>, upstream_model => <<"g">>, tier => Tier, note => <<>>} end,
    Log = #{route => <<"r">>, plan_trace => [Tr(reserve), Tr(cold), Tr(cold_reserve), Tr(<<"odd">>)]},
    [{info, Head} | Rest] = en(Log),
    ?assertEqual(<<"A client requested r; candidates: glm (g), glm (g), glm (g), glm (g)">>, Head),
    ?assertEqual([{warn, <<"glm (g) has reached its plan reserve; moved to the back">>},
                  {warn, <<"glm (g) is cooling down; moved to the back">>},
                  {warn, <<"glm (g) is cooling down and has reached its plan reserve; moved to the back">>},
                  {warn, <<"glm (g) is in tier odd; moved to the back">>}], Rest),
    %% 超过 4 个候选
    [{info, Many} | _] = en(#{route => <<"r">>, plan_trace => [Tr(hot) || _ <- lists:seq(1, 6)]}),
    ?assertEqual(<<"A client requested r; candidates: glm (g), glm (g), glm (g), glm (g) and 2 more">>, Many).

en_rules_intents_test() ->
    %% 没有规则命中
    ?assertEqual([{info, <<"A client requested r">>}, {info, <<"No rule matched; using the route's own order">>},
                  {muted, <<"Asked the classifier which of “a” this turn belongs to; it answered none of them (40 ms)"/utf8>>}],
                 en(#{route => <<"r">>, rule => 0, intent => #{intents => [<<"a">>], answer => 0, ms => 40}})),
    %% 沿用判定、规则目标被跳过、意图判断失败
    Reused = #{route => <<"coder">>, client => <<"litegate">>, rule => 2, rule_reused => true,
               intent => #{error => <<"timeout">>, answer => 0, ms => 8000, intents => [<<"a">>], classifier => <<"j">>}},
    ?assertEqual([{info, <<"The gateway (intent classification) requested coder">>},
                  {info, <<"Reusing this conversation's earlier decision: rule 2, but the credentials the rule points to "
                           "were skipped">>},
                  {warn, <<"Intent classification failed (timeout); routing as usual this turn (classifier j)">>}],
                 en(Reused)),
    %% 本地判断失败后改问判断模型；同一条消息已判断过
    Local = #{route => <<"r">>, intent => #{local_error => <<"down">>, classifier => <<"judge">>, cached => true,
                                            intents => [<<"a">>, <<"b">>], answer => 1}},
    ?assertEqual([{info, <<"A client requested r">>},
                  {warn, <<"Local Laya failed to classify (down); asking judge instead">>},
                  {muted, <<"Already decided for the same message which of “a”, “b” this turn belongs to: “a”"/utf8>>}],
                 en(Local)),
    By = #{route => <<"r">>, intent => #{local_error => <<"bad">>, local_by => <<"tiny">>, classifier => <<"judge">>,
                                         error => <<"x">>}},
    ?assertMatch([_, {warn, <<"Decision model tiny failed to classify (bad); asking judge instead">>}, {warn, _}], en(By)),
    %% 嵌套路由
    Nested = #{route => <<"claude-*">>, status => 200,
               nested_rules => [#{route => <<"coder">>, rule => 2, routed_to => <<"strong">>,
                                  intent => #{intents => [<<"q">>, <<"code">>], answer => 2, ms => 900, classifier => <<"judge">>}}]},
    [{info, _}, {info, R}, {muted, I}] = en(Nested),
    ?assertEqual(<<"Nested route coder: Matched rule 2 (intent: “code”); sending to strong first, "/utf8,
                   "with this route's own targets as fallback">>, R),
    ?assertMatch(<<"Nested route coder: Asked judge which of", _/binary>>, I).

en_attempts_test() ->
    Log = #{route => <<"r">>, rounds => 2, patience_ms => 1500, queued_ms => 300,
            attempt_list => [#{credential => <<"c1">>, busy => true},
                             #{credential => <<"c2">>, upstream_model => <<"g">>, ok => false, kind => network,
                               message => <<"Upstream connection failed: {down,{shutdown,nxdomain}}">>},
                             #{credential => <<"c1">>, ok => false, kind => something_new},
                             #{credential => <<"c2">>, ok => true}],
            credential => <<"c2">>, duration_ms => 2000, plan => true},
    ?assertEqual(
       [{info, <<"A client requested r">>},
        {warn, <<"minimax-a is at its concurrency limit; skipped">>},
        {warn, <<"glm (g) hit a network error: Upstream host name could not be resolved; trying the next one (attempt 3)">>},
        {warn, <<"minimax-a failed (something_new); trying the next one (attempt 4)">>},
        {warn, <<"All candidates were busy; waited 1.5 s and retried the whole round (2 rounds in total)">>},
        {warn, <<"The credential was at its concurrency limit; queued for 300 ms">>},
        {ok, <<"glm answered in 2.0 s · covered by plan"/utf8>>}],
       en(Log)),
    ?assertMatch([_, {warn, <<"All candidates were busy; waited 900 ms and retried the whole round">>}],
                 en(#{route => <<"r">>, attempt_list => [], rounds => 1, patience_ms => 900})).

en_result_test() ->
    %% 响应缓存
    ?assertEqual([{info, <<"A client requested gpt">>},
                  {ok, <<"Served from the response cache without calling the upstream, saving $0.50">>}],
                 en(#{route => <<"gpt">>, status => 200, cache_hit => true, saved_usd => 0.5})),
    %% 上游失败：以上游为主语
    Err = #{route => <<"gpt">>, status => 503, client => <<"other">>,
            attempt_list => [#{credential => <<"c1">>, upstream_model => <<"m">>, ok => false, kind => server}],
            error => #{kind => server, message => <<"Upstream returned HTTP 503">>}},
    ?assertEqual([{info, <<"A client requested gpt">>},
                  {error, <<"minimax-a (m) returned a server error; the client received 503: Upstream returned HTTP 503">>}],
                 en(Err)),
    %% 网关自己拒绝（没有尝试）
    Gw = fun(K) -> [_, {error, X}] = en(#{route => <<"gpt">>, status => 404, error => #{kind => K}}), X end,
    ?assertEqual(<<"Model not found; the client received 404">>, Gw(route_not_found)),
    ?assertEqual(<<"Budget exceeded; the client received 404">>, Gw(budget_exceeded)),
    ?assertEqual(<<"No upstream available; the client received 404">>, Gw(no_available_target)),
    ?assertEqual(<<"Failed; the client received 404">>,
                 begin [_, {error, X}] = en(#{route => <<"gpt">>, status => 404, error => #{}}), X end),
    %% TLS 映射
    [_, {error, Tls}] = en(Err#{error := #{kind => network, message => <<"{tls_alert,{handshake_failure}}">>}}),
    ?assertEqual(<<"minimax-a (m) hit a network error; the client received 503: Upstream TLS handshake failed">>, Tls),
    %% 复读截断、脱敏、按量计费、没有上游模型名
    Ok = #{route => <<"gpt">>, status => 200, credential => <<"c1">>, duration_ms => 50, loop_detected => true,
           redacted => 3, cost => 1.5, usage => #{input => 1, output => 0}},
    ?assertEqual([{info, <<"A client requested gpt">>},
                  {info, <<"3 pieces of sensitive information in the request were sent upstream as placeholders "
                           "and restored in the reply">>},
                  {warn, <<"The output got stuck repeating itself; the gateway ended it early "
                           "(finish reason recorded as the length limit)">>},
                  {ok, <<"minimax-a answered in 50 ms · 1 token · $1.50"/utf8>>}],
                 en(Ok)),
    ?assertMatch([_, {info, <<"1 piece of sensitive information in the request was sent upstream as a placeholder "
                              "and restored in the reply">>}, _],
                 en(Ok#{redacted := 1, loop_detected := false})).

%% 英文输出里不应残留中文（除了日志里原样带入的字段）
en_no_cjk_test() ->
    Logs = [#{route => <<"r">>, rule => 0, intent => #{intents => [<<"a">>], answer => 0, ms => 1}},
            #{route => <<"r">>, client => <<"litegate">>, status => 502,
              attempt_list => [#{credential => <<"c1">>, ok => false, kind => K} || K <- kinds()],
              error => #{kind => timeout, message => <<"timeout">>}}],
    [?assertEqual(nomatch, re:run(X, "[\\x{4e00}-\\x{9fff}\\x{3000}-\\x{303f}\\x{ff00}-\\x{ffef}]", [unicode]))
     || L <- Logs, {_, X} <- en(L)].

kinds() ->
    [rate_limit, quota, credit, unserved, server, timeout, network, auth, client, concurrency, route_not_found,
     route_forbidden, rate_limited, budget_exceeded, plan_exhausted, middleware_rejected, no_available_target].
