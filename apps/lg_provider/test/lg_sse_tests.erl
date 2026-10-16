-module(lg_sse_tests).

-include_lib("eunit/include/eunit.hrl").

basic_test() ->
    {Evs, Rest} = lg_sse:parse(<<"data: {\"a\":1}\n\nevent: ping\ndata: {}\n\ndata: part">>),
    ?assertMatch([#{event := undefined, data := <<"{\"a\":1}">>, raw := <<"data: {\"a\":1}\n\n">>},
                  #{event := <<"ping">>, data := <<"{}">>}], Evs),
    ?assertEqual(<<"data: part">>, Rest).

crlf_split_across_chunks_test() ->
    {[], R1} = lg_sse:parse(<<"data: x\r">>),
    {Evs, R2} = lg_sse:parse(<<R1/binary, "\n\r\ndata: y\r\n\r\n">>),
    ?assertMatch([#{data := <<"x">>}, #{data := <<"y">>}], Evs),
    ?assertEqual(<<>>, R2).

comments_and_multiline_test() ->
    {Evs, _} = lg_sse:parse(<<": keepalive\n\ndata: a\ndata: b\nid: 7\n\ndata:nospace\n\n">>),
    ?assertMatch([#{data := <<"a\nb">>}, #{data := <<"nospace">>}], Evs).

encode_test() ->
    ?assertEqual(<<"data: x\n\n">>, iolist_to_binary(lg_sse:encode(<<"x">>))),
    ?assertEqual(<<"event: e\ndata: x\n\n">>, iolist_to_binary(lg_sse:encode(<<"e">>, <<"x">>))).
