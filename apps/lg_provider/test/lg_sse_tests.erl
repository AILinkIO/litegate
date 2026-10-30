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

%% 增量解析：按 Parts 逐块 feed，返回全部事件与剩余缓冲字节数
feed_all(Parts) ->
    {Evs, B} = lists:foldl(fun(P, {Acc, B0}) -> {E, B1} = lg_sse:feed(P, B0), {Acc ++ E, B1} end,
                           {[], lg_sse:new()}, Parts),
    {Evs, lg_sse:buffered(B)}.

%% 分隔符被切在各种位置（\r\n | \r\n、\r 在块尾、\n | \r\n 等）：任意切点两段 feed 与一次 parse 结果一致
split_anywhere_test() ->
    Inputs = [<<"data: x\r\n\r\ndata: y\r\n\r\n">>,
              <<"data: x\n\r\ndata: y\r\n\ndata: z\n\n">>,
              <<"event: e\r\ndata: a\r\ndata: b\r\n\r\n: ping\r\n\r\ndata: tail">>,
              <<"data: a\r\rb\n\ndata: c\r\n">>,
              <<"\n\n\n\ndata: q\n\n\n">>],
    lists:foreach(
      fun(In) ->
              {Expect, Rest} = lg_sse:parse(In),
              lists:foreach(
                fun(I) ->
                        <<A:I/binary, B/binary>> = In,
                        ?assertEqual({Expect, byte_size(Rest)}, feed_all([A, B]))
                end, lists:seq(0, byte_size(In))),
              %% 逐字节
              ?assertEqual({Expect, byte_size(Rest)}, feed_all([<<C>> || <<C>> <= In]))
      end, Inputs).

%% \r\n 被拆成 \r | \n，以及 \r\n\r\n 拆成 \r\n | \r\n
crlf_boundaries_test() ->
    ?assertMatch({[#{data := <<"x">>, raw := <<"data: x\n\n">>}], 0}, feed_all([<<"data: x\r">>, <<"\n\r">>, <<"\n">>])),
    ?assertMatch({[#{data := <<"x">>}], 0}, feed_all([<<"data: x\r\n">>, <<"\r\n">>])),
    ?assertMatch({[#{data := <<"x">>}], 0}, feed_all([<<"data: x\n">>, <<"\r">>, <<"\n">>])),
    %% 单独的 \r 不算换行
    ?assertMatch({[], 11}, feed_all([<<"data: x\r">>, <<"\r">>, <<"\n">>, <<"\r">>])),
    %% 已切出的事件不再计入缓冲
    ?assertMatch({[#{data := <<"a">>}], 7}, feed_all([<<"data: a\n\nda">>, <<"ta: b">>])).

%% 2MB 事件分块到达：耗时随块数近似线性（改动前每块整段拷贝并从头扫描，2000 块约为 200 块的 9 倍）
linear_chunks_test_() ->
    {timeout, 60,
     fun() ->
             Ev = iolist_to_binary([<<"event: response.completed\r\ndata: {\"x\":\"">>,
                                    binary:copy(<<"abcdefgh">>, 256 * 1024), <<"\"}\r\n\r\n">>]),
             T = fun(N) ->
                         Sz = (byte_size(Ev) + N - 1) div N,
                         Parts = [binary:copy(binary:part(Ev, I, min(Sz, byte_size(Ev) - I)))
                                  || I <- lists:seq(0, byte_size(Ev) - 1, Sz)],
                         lists:min([element(1, timer:tc(fun() -> {[_], 0} = feed_all(Parts) end)) || _ <- [1, 2, 3]])
                 end,
             T200 = T(200),
             T2000 = T(2000),
             ?debugFmt("2MB SSE 事件：200 块 ~b us，2000 块 ~b us", [T200, T2000]),
             ?assert(T2000 < 5 * T200 + 20000)
     end}.
