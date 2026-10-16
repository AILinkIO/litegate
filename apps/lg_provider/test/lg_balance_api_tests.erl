-module(lg_balance_api_tests).

-include_lib("eunit/include/eunit.hrl").

url_test() ->
    ?assertEqual(<<"https://api.deepseek.com/user/balance">>, lg_balance_api:url(deepseek, <<"https://api.deepseek.com/v1">>)),
    ?assertEqual(<<"https://api.moonshot.cn/v1/users/me/balance">>, lg_balance_api:url(moonshot, <<"https://api.moonshot.cn/v1">>)),
    ?assertEqual(<<"https://openrouter.ai/api/v1/credits">>, lg_balance_api:url(openrouter, <<"https://openrouter.ai/api/v1">>)),
    ?assertEqual(<<"http://relay.local:3000/api/usage/token">>, lg_balance_api:url(newapi, <<"http://relay.local:3000/v1">>)),
    ?assertEqual(<<"deepseek">>, lg_balance_api:suggest(<<"https://api.deepseek.com/anthropic">>)),
    ?assertEqual(<<"moonshot">>, lg_balance_api:suggest(<<"https://api.moonshot.ai/v1">>)),
    ?assertEqual(null, lg_balance_api:suggest(<<"https://api.minimax.cn/v1">>)).

parse_test() ->
    P = fun(K, J, B) -> lg_balance_api:parse(K, json:encode(J), B) end,
    %% DeepSeek：结构取自实测（2026-10-13），金额为字符串；多币种时非零在前
    ?assertMatch({ok, #{amount := 110.0, currency := <<"CNY">>}},
                 P(deepseek, #{<<"is_available">> => true,
                               <<"balance_infos">> => [#{<<"currency">> => <<"CNY">>, <<"total_balance">> => <<"110.00">>,
                                                         <<"granted_balance">> => <<"0.00">>, <<"topped_up_balance">> => <<"110.00">>}]},
                   <<"https://api.deepseek.com/v1">>)),
    {ok, #{amount := 3.5, currency := <<"USD">>, details := [_, _]}} =
        P(deepseek, #{<<"balance_infos">> => [#{<<"currency">> => <<"CNY">>, <<"total_balance">> => <<"0.00">>},
                                              #{<<"currency">> => <<"USD">>, <<"total_balance">> => 3.5}]}, <<>>),
    ?assertMatch({ok, #{amount := 49.58, currency := <<"CNY">>}},
                 P(moonshot, #{<<"code">> => 0, <<"data">> => #{<<"available_balance">> => 49.58}, <<"status">> => true},
                   <<"https://api.moonshot.cn/v1">>)),
    ?assertMatch({ok, #{currency := <<"USD">>}},
                 P(moonshot, #{<<"data">> => #{<<"available_balance">> => 1}}, <<"https://api.moonshot.ai/v1">>)),
    {ok, #{amount := OR}} = P(openrouter, #{<<"data">> => #{<<"total_credits">> => 20, <<"total_usage">> => 5.25}}, <<>>),
    ?assert(abs(OR - 14.75) < 1.0e-9),
    ?assertMatch({ok, #{amount := 2.0, currency := <<"USD">>}},
                 P(newapi, #{<<"code">> => true, <<"data">> => #{<<"total_available">> => 1000000}}, <<>>)),
    ?assertEqual({error, <<"invalid token">>}, P(newapi, #{<<"success">> => false, <<"message">> => <<"invalid token">>}, <<>>)),
    ?assertEqual({error, <<"no balance entries">>}, P(deepseek, #{<<"balance_infos">> => []}, <<>>)),
    ?assertEqual({error, <<"invalid JSON">>}, lg_balance_api:parse(deepseek, <<"<html>">>, <<>>)).
