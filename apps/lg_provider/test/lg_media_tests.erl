-module(lg_media_tests).

-include_lib("eunit/include/eunit.hrl").

aspect_ratio_test() ->
    ?assertEqual(<<"1:1">>, lg_media:aspect_ratio(<<"1024x1024">>)),
    ?assertEqual(<<"16:9">>, lg_media:aspect_ratio(<<"1792x1024">>)),
    ?assertEqual(<<"2:3">>, lg_media:aspect_ratio(<<"1024x1536">>)),
    ?assertEqual(<<"9:16">>, lg_media:aspect_ratio(<<"720x1280">>)),
    ?assertEqual(<<"1:1">>, lg_media:aspect_ratio(<<"auto">>)),
    ?assertEqual(<<"1:1">>, lg_media:aspect_ratio(null)).

cost_test() ->
    U = (lg_usage:zero())#{images => 3, chars => 500000},
    P = #{input => 1, output => 2, cache_read => 0, cache_write => 0, image => 0.04, tts => 10},
    ?assertEqual(0.04 * 3 + 5.0, lg_usage:cost(U, P)),
    %% 旧定价（无 image / tts）照常计算
    ?assertEqual(0.0, lg_usage:cost(U, #{input => 1, output => 2, cache_read => 0, cache_write => 0})).
