%% @doc 流式复读检测：模型陷入重复输出时尽早结束这次输出，而不是一直跑到 max_tokens。
%%
%% 两条判据（只看正文与推理内容，不看工具调用参数）：
%%   周期重复：输出末尾一段 ≥ 8 字节、含文字（字母、数字或非 ASCII）的片段，连续重复 Repeat 次（运行参数 loop_repeat，默认 30）
%%   整行重复：最近 2×Repeat 个完整行中，同一行（去掉首尾空白后 ≥ 8 字节、含文字）出现 Repeat 次
%% 只有空白或标点的重复（分隔线、缩进、表格边框）不算。每追加 64 字节检查一次，只检查末尾 8KB。
-module(lg_loop).

-export([new/0, new/1, feed/2, looped/1]).

-define(DEFAULT_REPEAT, 30).

-define(MIN_UNIT, 8).
-define(MAX_UNIT, 256).
-define(TAIL, 8192).
-define(CHECK_EVERY, 64).

-record(lp, {
    repeat :: pos_integer(),
    tail = <<>> :: binary(),       %% 最近的输出（最多 ?TAIL 字节）
    pending = 0 :: non_neg_integer(),
    partial = <<>> :: binary(),    %% 还没换行的半行
    lines = [] :: [binary()],      %% 最近的完整行（新的在前，最多 2×Repeat）
    looped = false :: boolean()
}).

-opaque state() :: #lp{}.
-export_type([state/0]).

-spec new() -> state().
new() ->
    new(case catch lg_config:get(loop_repeat) of N when is_integer(N) -> N; _ -> ?DEFAULT_REPEAT end).

-spec new(pos_integer()) -> state().
new(Repeat) ->
    #lp{repeat = max(3, Repeat)}.

-spec looped(state() | undefined) -> boolean().
looped(#lp{looped = L}) -> L;
looped(_) -> false.

%% @doc 追加一段输出文字。
-spec feed(binary(), state()) -> state().
feed(_Text, #lp{looped = true} = S) ->
    S;
feed(<<>>, S) ->
    S;
feed(Text, #lp{tail = T0, pending = P, partial = Part, lines = Ls, repeat = R} = S) ->
    T1 = <<T0/binary, Text/binary>>,
    Tail = case byte_size(T1) > ?TAIL of
               true -> binary:part(T1, byte_size(T1) - ?TAIL, ?TAIL);
               false -> T1
           end,
    {NewLines, Partial} = split_lines(<<Part/binary, Text/binary>>),
    Lines = lists:sublist(lists:reverse(NewLines) ++ Ls, 2 * R),
    S1 = S#lp{tail = Tail, partial = Partial, lines = Lines, pending = P + byte_size(Text)},
    case S1#lp.pending >= ?CHECK_EVERY of
        true -> S1#lp{pending = 0, looped = periodic(Tail, R) orelse repeated_line(Lines, R)};
        false -> S1#lp{looped = NewLines =/= [] andalso repeated_line(Lines, R)}
    end.

split_lines(B) ->
    case binary:split(B, <<"\n">>, [global]) of
        [Only] -> {[], Only};
        Parts -> {lists:droplast(Parts), lists:last(Parts)}
    end.

%% 末尾是否由同一片段连续重复 R 次构成
periodic(Tail, R) ->
    Len = byte_size(Tail),
    lists:any(fun(P) -> P * R =< Len andalso repeats(Tail, Len, P, R) end, lists:seq(?MIN_UNIT, ?MAX_UNIT)).

repeats(Tail, Len, P, R) ->
    Unit = binary:part(Tail, Len - P, P),
    all_same(Tail, Len, P, Unit, R - 1) andalso wordy(Unit).

all_same(_Tail, _Len, _P, _Unit, 0) -> true;
all_same(Tail, Len, P, Unit, K) ->
    binary:part(Tail, Len - P * (K + 1), P) =:= Unit andalso all_same(Tail, Len, P, Unit, K - 1).

repeated_line(Lines, R) when length(Lines) >= R ->
    Counts = lists:foldl(fun(L, M) ->
                                 case wordy(L) andalso byte_size(L) >= ?MIN_UNIT of
                                     true -> maps:update_with(L, fun(N) -> N + 1 end, 1, M);
                                     false -> M
                                 end
                         end, #{}, [trim(L) || L <- Lines]),
    lists:any(fun(N) -> N >= R end, maps:values(Counts));
repeated_line(_, _) ->
    false.

trim(L) ->
    try string:trim(L) of
        T when is_binary(T) -> T;
        _ -> L
    catch _:_ -> L
    end.

%% 含字母、数字或非 ASCII 字符（中文等）
wordy(B) ->
    lists:any(fun(C) -> (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z)
                            orelse C >= 128 end, binary_to_list(B)).
