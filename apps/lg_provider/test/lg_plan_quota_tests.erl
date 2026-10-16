-module(lg_plan_quota_tests).

-include_lib("eunit/include/eunit.hrl").

url_test() ->
    ?assertEqual(<<"https://api.minimax.cn/v1/token_plan/remains">>,
                 lg_plan_quota:url(minimax, <<"https://api.minimax.cn/anthropic">>)),
    ?assertEqual(<<"https://open.bigmodel.cn/api/monitor/usage/quota/limit">>,
                 lg_plan_quota:url(glm, <<"https://open.bigmodel.cn/api/coding/paas/v4">>)),
    ?assertEqual(<<"http://127.0.0.1:8080/v1/token_plan/remains">>,
                 lg_plan_quota:url(minimax, <<"http://127.0.0.1:8080/v1">>)).

%% 真实响应（MiniMax Token Plan，2026-09）
minimax_test() ->
    Body = json:encode(#{<<"model_remains">> =>
                             [#{<<"model_name">> => <<"video">>, <<"current_interval_remaining_percent">> => 10,
                                <<"end_time">> => 2},
                              #{<<"model_name">> => <<"general">>, <<"start_time">> => 1790215200000,
                                <<"end_time">> => 1790233200000, <<"current_interval_remaining_percent">> => 71,
                                <<"current_weekly_remaining_percent">> => 100, <<"weekly_end_time">> => 1790524800000,
                                <<"current_interval_status">> => 1, <<"current_weekly_status">> => 3}]}),
    ?assertEqual({ok, #{level => null,
                        windows => [#{name => <<"5h">>, used_pct => 29, resets_at => 1790233200000},
                                    #{name => <<"week">>, used_pct => 0, resets_at => 1790524800000}]}},
                 lg_plan_quota:parse(minimax, Body)),
    ?assertEqual({error, <<"invalid api key">>},
                 lg_plan_quota:parse(minimax, json:encode(#{<<"base_resp">> => #{<<"status_code">> => 1004,
                                                                                  <<"status_msg">> => <<"invalid api key">>}}))),
    ?assertEqual({error, <<"invalid JSON">>}, lg_plan_quota:parse(minimax, <<"<html>">>)).

%% 真实响应（智谱 GLM Coding Plan，2026-09）：TIME_LIMIT 是 MCP 工具月度次数，不计入
glm_test() ->
    Body = json:encode(#{<<"code">> => 200, <<"success">> => true,
                         <<"data">> => #{<<"level">> => <<"pro">>,
                                         <<"limits">> => [#{<<"type">> => <<"TIME_LIMIT">>, <<"unit">> => 5, <<"number">> => 1,
                                                            <<"percentage">> => 0, <<"nextResetTime">> => 1791339490999},
                                                          #{<<"type">> => <<"TOKENS_LIMIT">>, <<"unit">> => 3, <<"number">> => 5,
                                                            <<"percentage">> => 1, <<"nextResetTime">> => 1790241956075}]}}),
    ?assertEqual({ok, #{level => <<"pro">>,
                        windows => [#{name => <<"5h">>, used_pct => 1, resets_at => 1790241956075}]}},
                 lg_plan_quota:parse(glm, Body)),
    ?assertEqual({error, <<"令牌已过期"/utf8>>},
                 lg_plan_quota:parse(glm, json:encode(#{<<"code">> => 401, <<"msg">> => <<"令牌已过期"/utf8>>,
                                                        <<"success">> => false}))).

%% Kimi Code 会员：样本取自 magpie 的解析代码注释（limits 为时间窗口，顶层 usage 为周窗口；数字可能是字符串）
kimi_test() ->
    ?assertEqual(<<"https://api.kimi.com/coding/v1/usages">>, lg_plan_quota:url(kimi, <<"https://api.kimi.com/coding/v1">>)),
    Body = json:encode(#{<<"usage">> => #{<<"limit">> => <<"100">>, <<"used">> => <<"12">>,
                                          <<"resetTime">> => <<"2026-09-30T05:24:18.44Z">>},
                         <<"limits">> => [#{<<"window">> => #{<<"duration">> => 300, <<"timeUnit">> => <<"TIME_UNIT_MINUTE">>},
                                            <<"detail">> => #{<<"limit">> => <<"100">>, <<"remaining">> => <<"88">>,
                                                              <<"resetTime">> => <<"2026-09-30T01:00:00Z">>}}]}),
    {ok, #{windows := [W5, Week]}} = lg_plan_quota:parse(kimi, Body),
    ?assertMatch(#{name := <<"5h">>, resets_at := R} when is_integer(R), W5),
    ?assert(abs(maps:get(used_pct, W5) - 12) < 1.0e-9),
    ?assertMatch(#{name := <<"week">>}, Week),
    ?assert(abs(maps:get(used_pct, Week) - 12) < 1.0e-9),
    ?assert(lists:member(<<"kimi">>, lg_plan_quota:kinds())).
