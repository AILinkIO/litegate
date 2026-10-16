%% @doc 增量 SSE 解析与编码。
%%
%% parse/1 返回完整事件与剩余缓冲；每个事件保留原始字节（raw，已统一为 \n 换行），
%% 同协议透传时直接转发 raw，无需重新编码。
-module(lg_sse).

-export([parse/1, encode/1, encode/2, done/0]).

-type event() :: #{event := binary() | undefined,
                   data := binary() | undefined,
                   raw := binary()}.
-export_type([event/0]).

%% @doc 解析缓冲区中所有完整事件（以空行结束）。
-spec parse(binary()) -> {[event()], Rest :: binary()}.
parse(Buffer) ->
    split(normalize(Buffer), []).

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

%% \r\n → \n；末尾孤立的 \r 可能是被切开的 \r\n，保留到下次
normalize(Bin) ->
    case binary:match(Bin, <<"\r">>) of
        nomatch -> Bin;
        _ -> binary:replace(Bin, <<"\r\n">>, <<"\n">>, [global])
    end.

split(Buf, Acc) ->
    case binary:split(Buf, <<"\n\n">>) of
        [Block, Rest] ->
            Acc1 = case parse_block(Block) of
                       skip -> Acc;
                       Ev -> [Ev | Acc]
                   end,
            split(Rest, Acc1);
        [_] ->
            {lists:reverse(Acc), Buf}
    end.

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
