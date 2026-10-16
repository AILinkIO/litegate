-module(lg_loop_tests).

-include_lib("eunit/include/eunit.hrl").

%% 按小分片喂入（模拟流式），返回是否判定为复读
run(Chunks) ->
    lg_loop:looped(lists:foldl(fun lg_loop:feed/2, lg_loop:new(30), Chunks)).

chunks(Bin, N) ->
    [binary:part(Bin, I, min(N, byte_size(Bin) - I)) || I <- lists:seq(0, byte_size(Bin) - 1, N)].

looping_test() ->
    %% magpie #1359：推理里循环「Now. Writing. Go. Let me write. OK.」
    ?assert(run(chunks(binary:copy(<<"Now. Writing. Go. Let me write. OK. ">>, 40), 7))),
    %% 中文短句循环
    ?assert(run(chunks(binary:copy(<<"现在开始写代码。"/utf8>>, 40), 5))),
    %% 整行重复（行之间不严格周期：偶尔多一个空格）
    Lines = iolist_to_binary([[<<"Let me write the test file now.">>, case I rem 7 of 0 -> <<" ">>; _ -> <<>> end, <<"\n">>]
                              || I <- lists:seq(1, 40)]),
    ?assert(run(chunks(Lines, 11))).

normal_test() ->
    %% 编号列表：每行不同
    List = iolist_to_binary([io_lib:format("~b. item number ~b with some detail~n", [I, I * 7]) || I <- lists:seq(1, 200)]),
    ?assertNot(run(chunks(List, 13))),
    %% 分隔线、表格边框、缩进：只有标点与空白
    ?assertNot(run(chunks(binary:copy(<<"----------------\n">>, 100), 9))),
    ?assertNot(run(chunks(binary:copy(<<"|----|----|----|\n">>, 100), 9))),
    ?assertNot(run(chunks(binary:copy(<<"        ">>, 300), 9))),
    %% 代码：结构相同但内容不同的块，以及重复的短行（< 8 字节，如 end）
    Code = iolist_to_binary([io_lib:format("    if x == ~b then~n        y(~b)~n    end~n", [I, I * 3]) || I <- lists:seq(1, 60)]),
    ?assertNot(run(chunks(Code, 17))),
    %% 重复不到 30 次
    ?assertNot(run(chunks(binary:copy(<<"Now. Writing. Go. ">>, 20), 7))).
