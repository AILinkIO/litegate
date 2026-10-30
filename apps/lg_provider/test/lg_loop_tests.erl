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

%% 一次输入含多个换行：中间的完整行也计入整行判据
multi_line_feed_test() ->
    Line = <<"Let me write the test file now.\n">>,
    ?assert(run([binary:copy(Line, 5) || _ <- lists:seq(1, 8)])),
    ?assertNot(run([iolist_to_binary([io_lib:format("line ~b of output~n", [I]) || I <- lists:seq(K, K + 4)])
                    || K <- lists:seq(1, 200, 5)])).

%% 超过 1KB 的行按前 1KB 比较：整行复读照样识别
long_line_test() ->
    Long = iolist_to_binary([[integer_to_binary(I), $,] || I <- lists:seq(1, 600)]),
    ?assert(byte_size(Long) > 1024),
    ?assert(run(chunks(binary:copy(<<Long/binary, "\n">>, 31), 97))).

%% 单行长输出（结构化 JSON、压缩代码）：每段只处理自身，50KB / 1.5 万段总分配有界、耗时随长度线性
%% （改动前每段重新切分整个半行：50KB 约分配 54MB）
long_single_line_test_() ->
    {timeout, 60,
     fun() ->
             Input = fun(Bytes, N) ->
                             L = iolist_to_binary([io_lib:format("\"k~b\":~b,", [I, I * 7]) || I <- lists:seq(1, Bytes div 8)]),
                             B = binary:part(L, 0, Bytes),
                             Sz = max(1, Bytes div N),
                             [binary:copy(binary:part(B, I, min(Sz, Bytes - I))) || I <- lists:seq(0, Bytes - 1, Sz)]
                     end,
             D50 = Input(50000, 15000),
             {T50, Alloc} = lg_test_alloc:measure(fun() -> lg_loop:looped(lists:foldl(fun lg_loop:feed/2, lg_loop:new(30), D50)) end),
             D200 = Input(200000, 60000),
             {T200, _} = lg_test_alloc:measure(fun() -> lg_loop:looped(lists:foldl(fun lg_loop:feed/2, lg_loop:new(30), D200)) end),
             ?debugFmt("lg_loop 单行 50KB/1.5 万段：~b us，分配约 ~.1f MB；200KB/6 万段：~b us", [T50, Alloc / 1048576, T200]),
             ?assert(Alloc < 5 * 1024 * 1024),
             ?assert(T200 < 10 * T50 + 50000)
     end}.
