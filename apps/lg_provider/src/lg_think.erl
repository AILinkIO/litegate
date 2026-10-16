%% @doc 思考标签拆分：部分 OpenAI 兼容上游（如 MiniMax）把思考过程以 `<think>…</think>` 写在 content 里。
%% 凭证 options.think_tags = <<"split">> 时：
%% - 响应：思考部分移到 `reasoning_content`，content 只留正文（思考块后的前导空白去掉）；
%%   流式逐分片处理，标签跨分片也能识别
%% - 请求：助手消息的 `reasoning_content` 还原为 content 前的 `<think>…</think>`，保持上游要求的思考链回传
-module(lg_think).

-include_lib("lg_core/include/lg_core.hrl").

-export([enabled/1, split_text/1, split_response/1, new/0, feed_chunk/2, pack_messages/1]).

-define(OPEN, <<"<think>">>).
-define(CLOSE, <<"</think>">>).

-record(st, {
    in = false :: boolean(),     %% 正处于思考块内
    pend = <<>> :: binary(),     %% 可能是标签开头的尾部，等下一片再判断
    trim = false :: boolean()    %% 刚结束思考块，去掉正文的前导空白
}).
-opaque state() :: #st{}.
-export_type([state/0]).

-spec enabled(#lg_credential{}) -> boolean().
enabled(#lg_credential{protocol = openai, options = #{think_tags := <<"split">>}}) -> true;
enabled(_) -> false.

%% @doc 完整文本 → {思考, 正文}。未闭合的思考块（被截断）其后全部算思考。
-spec split_text(binary()) -> {binary(), binary()}.
split_text(Text) ->
    {R, C, #st{pend = P, in = In}} = step(Text, #st{}),
    case In of
        true -> {iolist_to_binary([R, P]), C};
        false -> {R, iolist_to_binary([C, P])}
    end.

%% @doc 非流式 Chat Completions 响应：拆分每个 choice 的 message.content。
-spec split_response(map()) -> map().
split_response(#{<<"choices">> := Choices} = J) when is_list(Choices) ->
    J#{<<"choices">> => [split_choice(C) || C <- Choices]};
split_response(J) ->
    J.

split_choice(#{<<"message">> := #{<<"content">> := Text} = M} = C) when is_binary(Text) ->
    case split_text(Text) of
        {<<>>, _} -> C;
        {R, Content} -> C#{<<"message">> => M#{<<"content">> => Content,
                                               <<"reasoning_content">> => join_reasoning(M, R)}}
    end;
split_choice(C) ->
    C.

join_reasoning(M, R) ->
    case maps:get(<<"reasoning_content">>, M, null) of
        Prev when is_binary(Prev), Prev =/= <<>> -> <<Prev/binary, R/binary>>;
        _ -> R
    end.

-spec new() -> state().
new() -> #st{}.

%% @doc 流式 chunk：拆分 choices[0].delta.content；带 finish_reason 的 chunk 输出暂存的尾部。
-spec feed_chunk(map(), state()) -> {map(), state()}.
feed_chunk(#{<<"choices">> := [#{<<"delta">> := D} = C | More]} = J, S0) when is_map(D) ->
    Text = case maps:get(<<"content">>, D, null) of T when is_binary(T) -> T; _ -> <<>> end,
    {R0, C0, S1} = step(Text, S0),
    {R, Content, S2} = case maps:get(<<"finish_reason">>, C, null) of
                           F when is_binary(F) -> flush(R0, C0, S1);
                           _ -> {R0, C0, S1}
                       end,
    D1 = maps:remove(<<"content">>, D),
    D2 = case Content of <<>> -> D1; _ -> D1#{<<"content">> => Content} end,
    D3 = case R of <<>> -> D2; _ -> D2#{<<"reasoning_content">> => join_reasoning(D, R)} end,
    %% 原本有 content 键但拆分后为空时保留空串，避免客户端把该 chunk 视为缺字段
    D4 = case maps:is_key(<<"content">>, D) andalso not maps:is_key(<<"content">>, D3)
             andalso not maps:is_key(<<"reasoning_content">>, D3) of
             true -> D3#{<<"content">> => <<>>};
             false -> D3
         end,
    {J#{<<"choices">> => [C#{<<"delta">> => D4} | More]}, S2};
feed_chunk(J, S) ->
    {J, S}.

flush(R, C, #st{pend = <<>>} = S) -> {R, C, S};
flush(R, C, #st{in = true, pend = P} = S) -> {<<R/binary, P/binary>>, C, S#st{pend = <<>>}};
flush(R, C, #st{pend = P} = S) -> {R, <<C/binary, P/binary>>, S#st{pend = <<>>}}.

%% @doc 请求消息：助手消息的 reasoning_content → content 前的 <think> 块。
-spec pack_messages(map()) -> map().
pack_messages(#{<<"messages">> := Msgs} = Req) when is_list(Msgs) ->
    Req#{<<"messages">> => [pack(M) || M <- Msgs]};
pack_messages(Req) ->
    Req.

pack(#{<<"role">> := <<"assistant">>, <<"reasoning_content">> := R} = M) when is_binary(R), R =/= <<>> ->
    Content = case maps:get(<<"content">>, M, null) of
                  T when is_binary(T) -> T;
                  _ -> <<>>
              end,
    (maps:remove(<<"reasoning_content">>, M))#{<<"content">> => <<?OPEN/binary, R/binary, ?CLOSE/binary, "\n\n",
                                                                 Content/binary>>};
pack(M) ->
    maps:remove(<<"reasoning_content">>, M).

%%====================================================================
%% 内部函数
%%====================================================================

%% 处理一段文本：返回 {思考, 正文, 新状态}
step(Text, #st{pend = P} = S) ->
    scan(<<P/binary, Text/binary>>, S#st{pend = <<>>}, [], []).

scan(<<>>, S, R, C) ->
    {iolist_to_binary(lists:reverse(R)), iolist_to_binary(lists:reverse(C)), S};
scan(Buf, #st{in = false} = S, R, C) ->
    case binary:match(Buf, ?OPEN) of
        {Pos, Len} ->
            {C1, S1} = content(binary:part(Buf, 0, Pos), S),
            scan(binary:part(Buf, Pos + Len, byte_size(Buf) - Pos - Len), S1#st{in = true}, R, [C1 | C]);
        nomatch ->
            {Emit, Keep} = hold(Buf, ?OPEN),
            {C1, S1} = content(Emit, S),
            scan(<<>>, S1#st{pend = Keep}, R, [C1 | C])
    end;
scan(Buf, #st{in = true} = S, R, C) ->
    case binary:match(Buf, ?CLOSE) of
        {Pos, Len} ->
            scan(binary:part(Buf, Pos + Len, byte_size(Buf) - Pos - Len), S#st{in = false, trim = true},
                 [binary:part(Buf, 0, Pos) | R], C);
        nomatch ->
            {Emit, Keep} = hold(Buf, ?CLOSE),
            scan(<<>>, S#st{pend = Keep}, [Emit | R], C)
    end.

%% 正文：思考块刚结束时去掉前导空白
content(Text, #st{trim = true} = S) ->
    case string:trim(Text, leading) of
        <<>> -> {<<>>, S};
        T -> {T, S#st{trim = false}}
    end;
content(Text, S) ->
    {Text, S}.

%% 尾部若是标签的前缀（如 "<thi"），先留着等下一片
hold(Buf, Tag) ->
    Max = min(byte_size(Buf), byte_size(Tag) - 1),
    case [N || N <- lists:seq(Max, 1, -1),
               binary:part(Buf, byte_size(Buf) - N, N) =:= binary:part(Tag, 0, N)] of
        [N | _] -> {binary:part(Buf, 0, byte_size(Buf) - N), binary:part(Buf, byte_size(Buf) - N, N)};
        [] -> {Buf, <<>>}
    end.
