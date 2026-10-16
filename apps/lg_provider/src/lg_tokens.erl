%% @doc 本地 token 估算（上游不支持 count_tokens 时使用）。
%%
%% 近似算法：CJK 字符（汉字、假名、谚文、全角符号）每字 1 token，其余按 UTF-8 字节约 4 字节 1 token；
%% 每条消息加 4 个结构开销，每个工具加 8 个；工具输入 / 定义按其 JSON 文本计算。
%% 只求量级正确（用于客户端显示上下文占用、触发压缩），不用于计费。
-module(lg_tokens).

-export([estimate/1, text/1]).

%% @doc Anthropic Messages 请求（count_tokens 请求体）的输入 token 估算。
-spec estimate(map()) -> non_neg_integer().
estimate(Req) ->
    System = text(content_text(maps:get(<<"system">>, Req, <<>>))),
    Msgs = [4 + text(content_text(maps:get(<<"content">>, M, <<>>))) || M <- list(maps:get(<<"messages">>, Req, []))],
    Tools = [8 + text(iolist_to_binary(json:encode(T))) || T <- list(maps:get(<<"tools">>, Req, []))],
    System + lists:sum(Msgs) + lists:sum(Tools).

%% @doc 一段文本的 token 估算。
-spec text(binary()) -> non_neg_integer().
text(Bin) when is_binary(Bin) ->
    case unicode:characters_to_list(Bin) of
        L when is_list(L) ->
            {Cjk, OtherBytes} = lists:foldl(fun(C, {N, B}) ->
                                                    case cjk(C) of
                                                        true -> {N + 1, B};
                                                        false -> {N, B + utf8_len(C)}
                                                    end
                                            end, {0, 0}, L),
            Cjk + (OtherBytes + 3) div 4;
        _ ->
            (byte_size(Bin) + 3) div 4
    end;
text(_) ->
    0.

%%====================================================================
%% 内部函数
%%====================================================================

%% 字符串或内容块列表 → 参与估算的文本
content_text(S) when is_binary(S) -> S;
content_text(Blocks) when is_list(Blocks) ->
    iolist_to_binary(lists:join(<<"\n">>, [block_text(B) || B <- Blocks]));
content_text(_) -> <<>>.

block_text(#{<<"type">> := <<"text">>, <<"text">> := T}) when is_binary(T) -> T;
block_text(#{<<"type">> := <<"thinking">>, <<"thinking">> := T}) when is_binary(T) -> T;
block_text(#{<<"type">> := <<"tool_use">>} = B) ->
    iolist_to_binary([maps:get(<<"name">>, B, <<>>), json:encode(maps:get(<<"input">>, B, #{}))]);
block_text(#{<<"type">> := <<"tool_result">>} = B) -> content_text(maps:get(<<"content">>, B, <<>>));
%% 图片 / 文档按固定开销（约 1500 token，对应常见截图）
block_text(#{<<"type">> := T}) when T =:= <<"image">>; T =:= <<"document">> -> binary:copy(<<"a">>, 6000);
block_text(_) -> <<>>.

cjk(C) ->
    (C >= 16#2E80 andalso C =< 16#9FFF) orelse (C >= 16#AC00 andalso C =< 16#D7AF)
        orelse (C >= 16#F900 andalso C =< 16#FAFF) orelse (C >= 16#FF00 andalso C =< 16#FFEF)
        orelse (C >= 16#20000 andalso C =< 16#2FA1F).

utf8_len(C) when C < 16#80 -> 1;
utf8_len(C) when C < 16#800 -> 2;
utf8_len(C) when C < 16#10000 -> 3;
utf8_len(_) -> 4.

list(L) when is_list(L) -> L;
list(_) -> [].
