%% @doc 本地意图判断：调用 Laya（ggmlc 的 laya serve，TypeSafe System One 兼容 HTTP API）。
%%
%% 每条意图各问一道 noul（问法与解析见 lg_decision），不低于 laya_min_prob 才算命中。
%% 地址 laya_url 为空时不可用。
-module(lg_laya).

-export([classify/3, questions/1, parse/3]).

-define(MAX_TEXT, 800).   %% 多语言版上下文 1024 token，留出问题的位置

%% @doc 返回 {ok, Answer, Reply}：Answer 为 1..N 或 0（都不是 / 概率不足），Reply 为简短说明（日志用）。
-spec classify([binary()], binary(), timeout()) -> {ok, non_neg_integer(), binary()} | {error, binary()}.
classify(Intents, Text, Timeout) ->
    case lg_config:get(laya_url) of
        Url when is_binary(Url), Url =/= <<>> ->
            Body = json:encode(lg_decision:request(noul, Intents, Text, ?MAX_TEXT)),
            H = [{<<"content-type">>, <<"application/json">>}, {<<"accept">>, <<"application/json">>}],
            case lg_http:request(<<"POST">>, endpoint(Url), H, Body, Timeout, #{api => true}) of
                {ok, _, _, RB} -> parse(Intents, RB, lg_config:get(laya_min_prob));
                {error, {http_error, S, _, B}} ->
                    {error, iolist_to_binary(["HTTP ", integer_to_binary(S), ": ", string:slice(B, 0, 200)])};
                {error, R} ->
                    {error, iolist_to_binary(io_lib:format("~0p", [R]))}
            end;
        _ ->
            {error, <<"laya_url not set">>}
    end.

%% @doc 意图 → Laya 问题表：#{<<"i1">> => noul, ...}。
-spec questions([binary()]) -> map().
questions(Intents) ->
    lg_decision:questions(noul, Intents).

%% @doc 解析回答：各意图「是」的概率，取最高者，不低于 MinProb 命中。
-spec parse([binary()], iodata(), number()) -> {ok, non_neg_integer(), binary()} | {error, binary()}.
parse(Intents, Body, MinProb) ->
    lg_decision:parse(noul, Intents, Body, MinProb).

%%====================================================================
%% 内部函数
%%====================================================================

endpoint(Url) ->
    Base = string:trim(Url, trailing, "/"),
    <<Base/binary, "/v1/systemone">>.
