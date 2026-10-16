-module(lg_tokens_tests).

-include_lib("eunit/include/eunit.hrl").

text_test() ->
    ?assertEqual(0, lg_tokens:text(<<>>)),
    ?assertEqual(3, lg_tokens:text(<<"hello world!">>)),          %% 12 字节 / 4
    ?assertEqual(4, lg_tokens:text(<<"你好世界"/utf8>>)),          %% 每个汉字 1
    ?assertEqual(3, lg_tokens:text(<<"你好 hi!"/utf8>>)).          %% 2 个汉字 + 4 字节 / 4

estimate_test() ->
    Req = #{<<"system">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"abcdabcd">>}],
            <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"你好"/utf8>>},
                               #{<<"role">> => <<"assistant">>,
                                 <<"content">> => [#{<<"type">> => <<"tool_use">>, <<"name">> => <<"f">>,
                                                     <<"input">> => #{}}]}],
            <<"tools">> => [#{<<"name">> => <<"f">>}]},
    %% system 2 + (4 + 2) + (4 + len("f{}")→1) + (8 + len(json)/4)
    N = lg_tokens:estimate(Req),
    ?assert(N >= 20 andalso N =< 30),
    ?assertEqual(0, lg_tokens:estimate(#{})).
