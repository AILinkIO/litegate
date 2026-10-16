%% @doc 意图 ↔ System One 决策问题（TypeSafe System One 协议：百炼 decision-model-preview、本地 Laya）。
%%
%% 两种问法（路由选项 decision_style）：
%% - choice（默认）：一道多选题 intent，选项 i1..iN 加 other（以上都不是）；取选中项
%% - noul：每条意图各问一道是 / 否，问题 id 为 i1..iN；取「是」的概率最高的意图（本地 Laya 用这种）
%% 选项名用 ASCII 的 iN，回答只看概率与 id，不靠匹配中文选项名。概率不低于 MinProb 才算命中，否则为 0（都不是）。
-module(lg_decision).

-export([request/3, request/4, questions/2, parse/4, summary/1]).

%% @doc 判断请求体（不含 model）：state 为用户消息（截断到 MaxText 个字符，默认 4096）。
-spec request(noul | choice, [binary()], binary()) -> map().
request(Style, Intents, Text) ->
    request(Style, Intents, Text, 4096).

-spec request(noul | choice, [binary()], binary(), pos_integer()) -> map().
request(Style, Intents, Text, MaxText) ->
    #{<<"state">> => #{<<"message">> => clip(Text, MaxText)}, <<"questions">> => questions(Style, Intents)}.

%% @doc 意图 → 问题表。
-spec questions(noul | choice, [binary()]) -> map().
questions(noul, Intents) ->
    maps:from_list([{id(N), #{<<"type">> => <<"noul">>,
                              <<"instructions">> => <<"这条消息是否属于："/utf8, I/binary>>}}
                    || {N, I} <- lists:enumerate(Intents)]);
questions(choice, Intents) ->
    Criteria = maps:from_list([{id(N), I} || {N, I} <- lists:enumerate(Intents)]),
    #{<<"intent">> => #{<<"type">> => <<"choice">>,
                        <<"instructions">> => <<"这条消息属于哪一类？"/utf8>>,
                        <<"criteria">> => Criteria#{<<"other">> => <<"以上都不是"/utf8>>}}}.

%% @doc 解析回答：{ok, Answer, Reply}，Answer 为 1..N 或 0；Reply 为简短说明（日志用），
%% 如 noul "i2 0.91（0.30 / 0.91）"、choice "i2 0.91（i1 0.03 / i2 0.91 / other 0.06）"。
-spec parse(noul | choice, [binary()], iodata() | map(), number()) ->
          {ok, non_neg_integer(), binary()} | {error, binary()}.
parse(Style, Intents, Body, MinProb) when not is_map(Body) ->
    try json:decode(iolist_to_binary(Body)) of
        J -> parse(Style, Intents, J, MinProb)
    catch
        error:_ -> {error, <<"invalid JSON from decision model">>}
    end;
parse(noul, Intents, #{<<"answers">> := Answers}, MinProb) when is_map(Answers) ->
    Ps = [case Answers of
              #{K := #{<<"noul">> := P}} when is_number(P) -> P;
              _ -> missing
          end || N <- lists:seq(1, length(Intents)), K <- [id(N)]],
    case lists:member(missing, Ps) of
        true -> {error, <<"unexpected decision reply">>};
        false ->
            {Best, N} = lists:max([{P, N} || {N, P} <- lists:enumerate(Ps)]),
            Answer = if Best >= MinProb -> N; true -> 0 end,
            {ok, Answer, iolist_to_binary([id(N), " ", prob(Best), <<"（"/utf8>>,
                                           lists:join(" / ", [prob(P) || P <- Ps]), <<"）"/utf8>>])}
    end;
parse(choice, Intents, #{<<"answers">> := #{<<"intent">> := #{<<"choice">> := C} = A}}, MinProb) ->
    Probs = case maps:get(<<"probabilities">>, A, #{}) of M when is_map(M) -> M; _ -> #{} end,
    Ids = [id(N) || N <- lists:seq(1, length(Intents))] ++ [<<"other">>],
    P = maps:get(C, Probs, maps:get(<<"confidence">>, A, 1.0)),
    Answer = case index(C, Intents) of
                 N when N > 0, is_number(P), P >= MinProb -> N;
                 _ -> 0
             end,
    {ok, Answer, iolist_to_binary([C, " ", prob(P), <<"（"/utf8>>,
                                   lists:join(" / ", [[I, " ", prob(maps:get(I, Probs, 0))] || I <- Ids]),
                                   <<"）"/utf8>>])};
parse(_Style, _Intents, #{<<"error">> := #{<<"message">> := M}}, _MinProb) when is_binary(M) ->
    {error, M};
parse(_Style, _Intents, #{<<"message">> := M}, _MinProb) when is_binary(M) ->
    {error, M};
parse(_Style, _Intents, _, _MinProb) ->
    {error, <<"unexpected decision reply">>}.

%% @doc 一般 System One 回答的一行摘要（请求日志用）：
%% "department=billing(0.94); escalate=0.99; severity=2.25"，按问题 id 排序。
-spec summary(map()) -> binary().
summary(#{<<"answers">> := Answers}) when is_map(Answers) ->
    iolist_to_binary(lists:join("; ", [[K, "=", answer(A)] || {K, A} <- lists:sort(maps:to_list(Answers))]));
summary(_) ->
    <<>>.

%%====================================================================
%% 内部函数
%%====================================================================

answer(#{<<"choice">> := C} = A) when is_binary(C) ->
    case maps:get(<<"confidence">>, A, undefined) of
        P when is_number(P) -> [C, "(", prob(P), ")"];
        _ -> C
    end;
answer(#{<<"noul">> := P}) when is_number(P) -> prob(P);
answer(#{<<"score">> := S}) when is_number(S) -> prob(S);
answer(_) -> "?".

%% iN → N（越界或 other 为 0）
index(<<"i", Rest/binary>>, Intents) ->
    case string:to_integer(Rest) of
        {N, <<>>} when N >= 1, N =< length(Intents) -> N;
        _ -> 0
    end;
index(_, _) ->
    0.

clip(Text, Max) ->
    case string:slice(Text, 0, Max) of
        S when is_binary(S) -> S;
        S -> unicode:characters_to_binary(S)
    end.

id(N) -> <<"i", (integer_to_binary(N))/binary>>.

prob(P) -> float_to_binary(float(P), [{decimals, 2}]).
