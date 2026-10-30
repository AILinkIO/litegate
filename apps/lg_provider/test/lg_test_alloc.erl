%% @doc 基准测试辅助：在独立进程中运行函数，测耗时与总分配量。
%%
%% 总分配按 GC 跟踪估算：每次 GC 前后（堆 + 老堆 + 进程引用的 refc binary）的差即回收量，
%% 累加得到运行期间分配后又释放的字节数（不含结束时仍存活的部分）。只用于宽松的数量级断言。
-module(lg_test_alloc).

-export([measure/1, binary_bytes/0]).

-spec measure(fun(() -> term())) -> {TimeUs :: non_neg_integer(), AllocBytes :: non_neg_integer()}.
measure(F) ->
    Parent = self(),
    {Pid, MRef} = spawn_monitor(fun() ->
                                        receive go -> ok end,
                                        {T, _} = timer:tc(F),
                                        Parent ! {self(), time, T}
                                end),
    1 = erlang:trace(Pid, true, [garbage_collection]),
    Pid ! go,
    gather(Pid, MRef, undefined, 0, undefined).

gather(Pid, MRef, Start, Acc, T) ->
    receive
        {trace, Pid, E, Info} when E =:= gc_minor_start; E =:= gc_major_start ->
            gather(Pid, MRef, Info, Acc, T);
        {trace, Pid, E, Info} when (E =:= gc_minor_end orelse E =:= gc_major_end), Start =/= undefined ->
            gather(Pid, MRef, undefined, Acc + max(0, total(Start) - total(Info)), T);
        {Pid, time, T1} ->
            gather(Pid, MRef, Start, Acc, T1);
        {'DOWN', MRef, _, _, normal} ->
            %% 跟踪消息可能晚于 DOWN 到达，再收一会儿
            receive {Pid, time, T1} -> drain(Pid, Start, Acc, T1) after 0 -> drain(Pid, Start, Acc, T) end;
        {'DOWN', MRef, _, _, Reason} ->
            error({measure_failed, Reason})
    end.

drain(Pid, Start, Acc, T) ->
    receive
        {trace, Pid, E, Info} when E =:= gc_minor_start; E =:= gc_major_start ->
            drain(Pid, Info, Acc, T);
        {trace, Pid, E, Info} when (E =:= gc_minor_end orelse E =:= gc_major_end), Start =/= undefined ->
            drain(Pid, undefined, Acc + max(0, total(Start) - total(Info)), T)
    after 100 ->
            {T, Acc}
    end.

total(Info) ->
    W = erlang:system_info(wordsize),
    lists:sum([proplists:get_value(K, Info, 0) || K <- [heap_size, old_heap_size, bin_vheap_size, bin_old_vheap_size]]) * W.

%% @doc 当前进程（完整 GC 后）引用的 refc binary 总字节数（同一 binary 只计一次）。
-spec binary_bytes() -> non_neg_integer().
binary_bytes() ->
    erlang:garbage_collect(),
    {binary, Bs} = process_info(self(), binary),
    lists:sum([S || {_, S, _} <- lists:ukeysort(1, Bs)]).
