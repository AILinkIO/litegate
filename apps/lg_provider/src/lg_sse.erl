%% @doc 增量 SSE 解析与编码。
%%
%% parse/1 返回完整事件与剩余缓冲；每个事件保留原始字节（raw，已统一为 \n 换行），
%% 同协议透传时直接转发 raw，无需重新编码。
%% 流式读取用 new/0 + feed/2：缓冲为块列表，每块只在“上一块末尾 2 字节 + 新块”中找事件分隔符，
%% 找到后才合并出完整事件；\r 规范化只作用于切出的单个事件。总耗时与数据量线性（不随块数平方增长）。
-module(lg_sse).

-export([parse/1, new/0, feed/2, buffered/1, encode/1, encode/2, done/0]).

-type event() :: #{event := binary() | undefined,
                   data := binary() | undefined,
                   raw := binary()}.
-export_type([event/0]).

%% 未结束的事件：已到达的块（新的在前）、总字节数、末尾 ≤2 字节（与下一块拼接查找跨块分隔符）
-record(buf, {
    chunks = [] :: [binary()],
    size = 0 :: non_neg_integer(),
    tail = <<>> :: binary()
}).
-opaque buffer() :: #buf{}.
-export_type([buffer/0]).

%% @doc 解析缓冲区中所有完整事件（以空行结束）。
-spec parse(binary()) -> {[event()], Rest :: binary()}.
parse(Buffer) ->
    case feed(Buffer, new()) of
        {Evs, #buf{chunks = []}} -> {Evs, <<>>};
        {Evs, #buf{chunks = [Rest]}} -> {Evs, Rest}
    end.

-spec new() -> buffer().
new() ->
    #buf{}.

%% @doc 追加一块数据，返回其中新完成的事件与新缓冲。
-spec feed(binary(), buffer()) -> {[event()], buffer()}.
feed(<<>>, B) ->
    {[], B};
feed(Data, #buf{chunks = Cs, size = Size, tail = Tail} = B) ->
    %% 跨块分隔符只可能从缓冲末尾 2 字节开始，拼上新块开头 2 字节即可判断；其余只扫新块
    Edge = <<Tail/binary, (binary:part(Data, 0, min(2, byte_size(Data))))/binary>>,
    case next_delim(Edge, 0) =:= nomatch andalso next_delim(Data, 0) =:= nomatch of
        true ->
            Tail1 = case byte_size(Data) >= 2 of
                        true -> last2(Data);
                        false -> last2(<<Tail/binary, Data/binary>>)
                    end,
            {[], B#buf{chunks = [Data | Cs], size = Size + byte_size(Data), tail = Tail1}};
        false ->
            %% 有完整事件：合并缓冲（只在此时拷贝），从缓冲末尾 2 字节处开始切分
            Full = case Cs of
                       [] -> Data;
                       _ -> iolist_to_binary(lists:reverse(Cs, [Data]))
                   end,
            split(Full, 0, Size - byte_size(Tail), [])
    end.

%% @doc 未结束事件已缓冲的字节数（sse_max_event_bytes 上限检查）。
-spec buffered(buffer()) -> non_neg_integer().
buffered(#buf{size = Size}) ->
    Size.

%% @doc 编码 data-only 事件（OpenAI 风格）。
-spec encode(iodata()) -> iodata().
encode(Data) ->
    [<<"data: ">>, Data, <<"\n\n">>].

%% @doc 编码带事件名的事件（Anthropic 风格）。
-spec encode(binary(), iodata()) -> iodata().
encode(Event, Data) ->
    [<<"event: ">>, Event, <<"\ndata: ">>, Data, <<"\n\n">>].

-spec done() -> binary().
done() ->
    <<"data: [DONE]\n\n">>.

%%====================================================================
%% 内部函数
%%====================================================================

%% 事件分隔符：规范化（\r\n → \n）后的空行，即原始字节中的 \n\n、\n\r\n、\r\n\n、\r\n\r\n
%% （单独的 \r 不算换行）。返回从 From 起第一个分隔符结束位置（含分隔符）。
next_delim(Bin, From) ->
    Len = byte_size(Bin),
    case binary:match(Bin, <<"\n">>, [{scope, {From, Len - From}}]) of
        nomatch -> nomatch;
        {P, 1} ->
            case Bin of
                <<_:P/binary, "\n\n", _/binary>> -> P + 2;
                <<_:P/binary, "\n\r\n", _/binary>> -> P + 3;
                _ -> next_delim(Bin, P + 1)
            end
    end.

%% 从 Full 的 Start 处（此前已扫描过）开始切出所有完整事件；Pos 为当前事件起点
split(Full, Pos, Start, Acc) ->
    case next_delim(Full, Start) of
        nomatch ->
            %% 剩余半个事件只在新块范围内，拷贝出来，不钉住整个合并缓冲
            Rest = binary:copy(binary:part(Full, Pos, byte_size(Full) - Pos)),
            {lists:reverse(Acc), #buf{chunks = [Rest || Rest =/= <<>>], size = byte_size(Rest), tail = last2(Rest)}};
        End ->
            Acc1 = case parse_block(normalize(binary:part(Full, Pos, End - Pos))) of
                       skip -> Acc;
                       Ev -> [Ev | Acc]
                   end,
            split(Full, End, End, Acc1)
    end.

%% 单个事件（含结尾分隔符）：\r\n → \n，去掉结尾空行
normalize(Bin) ->
    B = case binary:match(Bin, <<"\r">>) of
            nomatch -> Bin;
            _ -> binary:replace(Bin, <<"\r\n">>, <<"\n">>, [global])
        end,
    binary:part(B, 0, byte_size(B) - 2).

last2(B) when byte_size(B) =< 2 -> binary:copy(B);
last2(B) -> binary:copy(binary:part(B, byte_size(B) - 2, 2)).

parse_block(<<>>) ->
    skip;
parse_block(Block) ->
    Fields = lists:foldl(fun field/2, #{event => undefined, data => undefined},
                         binary:split(Block, <<"\n">>, [global])),
    case Fields of
        #{event := undefined, data := undefined} -> skip;  %% 仅注释（如心跳 ": ping"）
        _ -> Fields#{raw => <<Block/binary, "\n\n">>}
    end.

field(<<":", _/binary>>, Acc) ->
    Acc;
field(Line, Acc) ->
    {Name, Value} = case binary:split(Line, <<":">>) of
                        [N, <<" ", V/binary>>] -> {N, V};
                        [N, V] -> {N, V};
                        [N] -> {N, <<>>}
                    end,
    case Name of
        <<"event">> -> Acc#{event => Value};
        <<"data">> ->
            case maps:get(data, Acc) of
                undefined -> Acc#{data => Value};
                Prev -> Acc#{data => <<Prev/binary, "\n", Value/binary>>}
            end;
        _ -> Acc  %% id / retry 等网关不需要
    end.
