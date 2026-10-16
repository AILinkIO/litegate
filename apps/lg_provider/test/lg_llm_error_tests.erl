-module(lg_llm_error_tests).

-include_lib("eunit/include/eunit.hrl").

kind(Status, Body) ->
    maps:get(kind, lg_llm_error:classify({http_error, Status, [], Body})).

kinds_test() ->
    %% 普通限流、服务端错误、鉴权、客户端错误维持原分类
    ?assertEqual(rate_limit, kind(429, <<"{\"error\":{\"message\":\"Rate limit reached for requests\"}}">>)),
    ?assertEqual(server, kind(500, <<"{\"error\":{\"message\":\"internal\"}}">>)),
    ?assertEqual(auth, kind(401, <<"{\"error\":{\"message\":\"invalid api key\"}}">>)),
    ?assertEqual(client, kind(400, <<"{\"error\":{\"message\":\"bad\"}}">>)),
    %% 余额不足
    ?assertEqual(credit, kind(402, <<>>)),
    ?assertEqual(credit, kind(429, <<"{\"error\":{\"code\":\"insufficient_quota\",\"message\":\"You exceeded your current quota\"}}">>)),
    ?assertEqual(credit, kind(429, <<"{\"error\":{\"code\":\"1113\",\"message\":\"余额不足或无可用资源包,请充值。\"}}"/utf8>>)),
    ?assertEqual(credit, kind(400, <<"{\"base_resp\": {\"status_code\": 1008, \"status_msg\": \"insufficient balance\"}}">>)),
    %% 额度用尽（中英文、错误码，冒号两侧有空白也能识别）
    ?assertEqual(quota, kind(429, <<"{\"error\":{\"code\":\"1308\",\"message\":\"已达到 5 小时的使用上限。您的限额将在 2026-10-13 20:16:02 重置。\"}}"/utf8>>)),
    ?assertEqual(quota, kind(429, <<"{\"error\": {\"code\": 1310, \"message\": \"weekly\"}}">>)),
    ?assertEqual(quota, kind(429, <<"{\"error\":{\"message\":\"api key 7天限额已用完\",\"type\":\"rate_limit_exceeded\"}}"/utf8>>)),
    ?assertEqual(quota, kind(429, <<"{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"usage limit exceeded (2056)\"}}">>)),
    %% \uXXXX 转义体（Python json.dumps 默认）解码后中文措辞也能匹配
    ?assertEqual(credit, kind(429, <<"{\"error\":{\"message\":\"\\u4f59\\u989d\\u4e0d\\u8db3\"}}">>)),
    ?assertEqual(quota, kind(429, <<"{\"error\":{\"message\":\"\\u9650\\u989d\\u5df2\\u7528\\u5b8c\"}}">>)),
    %% 新增措辞：裸 quota / 配额 / 已用完；充值
    ?assertEqual(quota, kind(429, <<"{\"error\":{\"message\":\"Your quota has run out\"}}">>)),
    ?assertEqual(quota, kind(429, <<"配额已用完"/utf8>>)),
    ?assertEqual(credit, kind(429, <<"{\"error\":{\"message\":\"账户余额不足，请充值\"}}"/utf8>>)),
    %% 5xx：只认明确的额度错误码；「负载已达上限」仍是 server
    ?assertEqual(server, kind(500, <<"{\"error\":{\"message\":\"当前模型 gpt-5.5 负载已经达到上限，请稍后重试\"}}"/utf8>>)),
    ?assertEqual(quota, kind(503, <<"{\"error\":{\"status\":\"RESOURCE_EXHAUSTED\"}}">>)),
    %% Claude 官方订阅的 "usage limit reached|<重置时间戳>" 算额度
    ?assertEqual(quota, kind(503, <<"usage limit reached|1739466000">>)),
    %% 该模型不可用（unserved）：只冷却该模型，不冤枉整个凭证
    ?assertEqual(unserved, kind(403, <<"{\"error\":{\"message\":\"model is not available in the current token plan\"}}">>)),
    ?assertEqual(unserved, kind(404, <<"{\"error\":{\"message\":\"The model 'gpt-6' does not exist\"}}">>)),
    ?assertEqual(unserved, kind(400, <<"{\"error\":{\"message\":\"模型不存在或无权限访问\"}}"/utf8>>)),
    ?assertEqual(unserved, kind(422, <<"{\"error\":{\"message\":\"you are not entitled to this model\"}}">>)),
    %% 优先级：额度 / 限流措辞不被 unserved 抢走
    ?assertEqual(auth, kind(403, <<"{\"error\":{\"message\":\"invalid api key\"}}">>)),
    ?assertEqual(quota, kind(429, <<"{\"error\":{\"message\":\"model not available, quota exceeded\"}}">>)),
    ?assertEqual(rate_limit, kind(429, <<"{\"error\":{\"message\":\"model not found in this tier, slow down\"}}">>)),
    ?assertEqual(client, kind(409, <<"{\"error\":{\"message\":\"model not found conflict\"}}">>)),
    %% unserved 可回退
    U = lg_llm_error:classify({http_error, 403, [], <<"model is not available in the current token plan">>}),
    ?assert(lg_llm_error:retryable(U)),
    {403, Uo} = lg_llm_error:to_client(openai, false, U),
    ?assertMatch(#{<<"error">> := #{<<"type">> := <<"model_not_found">>}}, json:decode(iolist_to_binary(Uo))),
    %% 不是合法 UTF-8 的错误体也不崩溃
    ?assertEqual(rate_limit, kind(429, <<255, 254, "x">>)),
    %% 额度错误可回退；客户端格式
    E = lg_llm_error:classify({http_error, 429, [], <<"{\"error\":{\"message\":\"usage limit reached\"}}">>}),
    ?assert(lg_llm_error:retryable(E)),
    {429, Oa} = lg_llm_error:to_client(openai, false, E),
    ?assertMatch(#{<<"error">> := #{<<"type">> := <<"insufficient_quota">>}}, json:decode(iolist_to_binary(Oa))),
    {429, An} = lg_llm_error:to_client(anthropic, false, E),
    ?assertMatch(#{<<"error">> := #{<<"type">> := <<"rate_limit_error">>}}, json:decode(iolist_to_binary(An))).

ms(DateTime) ->
    (calendar:datetime_to_gregorian_seconds(DateTime) - 62167219200) * 1000.

reset_at_test() ->
    Now1 = ms({{2026, 10, 13}, {0, 0, 0}}),
    %% 文本中带偏移的日期时间
    ?assertEqual(ms({{2026, 10, 13}, {12, 16, 2}}),
                 lg_llm_error:reset_at(<<"{\"message\":\"将在 2026-10-13 20:16:02 UTC+8重置\"}"/utf8>>, Now1)),
    ?assertEqual(ms({{2026, 10, 13}, {4, 37, 53}}),
                 lg_llm_error:reset_at(<<"your usage will reset at 2026-10-13 12:37:53 UTC+8, upgrade">>, Now1)),
    ?assertEqual(ms({{2026, 10, 13}, {12, 0, 0}}),
                 lg_llm_error:reset_at(<<"limit will reset at 2026-10-13T12:00:00Z">>, Now1)),
    %% 无偏移按 UTC+8
    ?assertEqual(ms({{2026, 10, 13}, {6, 0, 0}}),
                 lg_llm_error:reset_at(<<"您的限额将在 2026-10-13 14:00:00 重置"/utf8>>, Now1)),
    %% 字段：秒、毫秒、ISO
    At = ms({{2026, 10, 14}, {0, 0, 0}}),
    ?assertEqual(At, lg_llm_error:reset_at(iolist_to_binary(json:encode(#{<<"error">> => #{<<"resets_at">> => At div 1000}})), Now1)),
    ?assertEqual(At, lg_llm_error:reset_at(iolist_to_binary(json:encode(#{<<"nextResetTime">> => At})), Now1)),
    ?assertEqual(At, lg_llm_error:reset_at(<<"{\"reset_at\":\"2026-10-14T00:00:00Z\"}">>, Now1)),
    %% 已过去的时刻、没有「重置」字样的日期都不算
    ?assertEqual(undefined, lg_llm_error:reset_at(<<"将在 2026-10-12 20:16:02 重置"/utf8>>, Now1)),
    ?assertEqual(undefined, lg_llm_error:reset_at(<<"created 2026-10-20 10:00:00">>, Now1)),
    %% 「UTC」后没有偏移（截断文本）不可信，不当默认 +8
    ?assertEqual(undefined, lg_llm_error:reset_at(<<"limit reached, resets at 2026-10-13 12:00:00 UTC">>, Now1)),
    %% 超过 8 天的重置时刻不接受（上限内正常解析）
    ?assertEqual(undefined, lg_llm_error:reset_at(<<"将在 2026-10-25 00:00:00 重置"/utf8>>, Now1)),
    ?assertEqual(ms({{2026, 10, 19}, {16, 0, 0}}),
                 lg_llm_error:reset_at(<<"将在 2026-10-20 00:00:00 重置"/utf8>>, Now1)),
    %% 转义体里的中文重置时间也能解析
    ?assertEqual(ms({{2026, 10, 13}, {12, 16, 2}}),
                 lg_llm_error:reset_at(<<"{\"message\":\"\\u5c06\\u5728 2026-10-13 20:16:02 UTC+8\\u91cd\\u7f6e\"}">>, Now1)),
    %% 分类时带上 reset_at；8 天上限外的时刻不采信
    #{kind := quota, reset_at := undefined} =
        lg_llm_error:classify({http_error, 429, [], <<"{\"error\":{\"message\":\"usage limit, will reset at 2099-01-01 00:00:00 UTC+0\"}}">>}).
