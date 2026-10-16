-module(lg_tags_tests).

-include_lib("eunit/include/eunit.hrl").

normalize_test() ->
    ?assertEqual([<<"a">>, <<"proj:x/y-1.2">>], lg_tags:normalize([<<"a">>, <<"proj:x/y-1.2">>, <<"a">>])),
    %% 非法字符、空、超长丢弃
    ?assertEqual([<<"ok">>], lg_tags:normalize([<<"bad tag">>, <<>>, binary:copy(<<"x">>, 65), <<"ok">>, 3])),
    %% 最多 8 个
    ?assertEqual(8, length(lg_tags:normalize([integer_to_binary(N) || N <- lists:seq(1, 20)]))),
    ?assertEqual([], lg_tags:normalize(<<"x">>)).

sources_test() ->
    ?assertEqual([<<"a">>, <<"b">>], lg_tags:from_header(<<" a , b">>)),
    ?assertEqual([], lg_tags:from_header(undefined)),
    ?assertEqual([<<"x">>, <<"y">>], lg_tags:from_body(openai, #{<<"metadata">> => #{<<"tags">> => <<"x,y">>}})),
    ?assertEqual([<<"z">>], lg_tags:from_body(responses, #{<<"metadata">> => #{<<"tags">> => [<<"z">>, 1]}})),
    ?assertEqual([], lg_tags:from_body(anthropic, #{<<"metadata">> => #{<<"tags">> => <<"x">>}})),
    ?assertEqual([<<"h">>, <<"b">>, <<"k">>], lg_tags:merge([[<<"h">>], [<<"b">>, <<"h">>], [<<"k">>]])).
