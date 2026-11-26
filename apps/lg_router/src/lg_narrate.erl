%% @doc 决策叙述：把一次请求的结构化路由记录写成几行话（实时路由页、日志详情），中文或英文。
%%
%% 输入是请求日志（lg_web_llm:record 写入的字段），输出 [#{tone, text}]，tone 为
%% info（经过）、muted（旁注：意图判断、粘性）、warn（降级、失败后改道）、ok（完成）、error（客户端收到错误）。
%% 原因文字全部来自日志里已有的字段：client、plan_trace（层与套餐说明）、rule / routed_to / intent、
%% affinity / affinity_prev、attempt_list、status / usage / cost / error。
%%
%% 语言：zh（默认）、en。两种语言语序不同，每句按语言分别组织，而不是逐段翻译拼接。
-module(lg_narrate).

-export([lines/1, lines/2, lines/3, note/2, lang/1]).

-include_lib("lg_core/include/lg_core.hrl").

-define(MAX_CANDIDATES, 4).
-define(MAX_MESSAGE, 80).

-type lang() :: zh | en.
-type line() :: #{tone := info | muted | warn | ok | error, text := binary()}.
-export_type([lang/0]).

-spec lines(map()) -> [line()].
lines(Log) ->
    lines(Log, zh, fun cred_name/1).

%% @doc 第二个参数为语言（zh | en），或凭证 id → 显示名的函数（中文，测试时可注入）。
-spec lines(map(), lang() | fun((binary()) -> binary())) -> [line()].
lines(Log, Name) when is_function(Name, 1) ->
    lines(Log, zh, Name);
lines(Log, Lang) ->
    lines(Log, lang(Lang), fun cred_name/1).

%% @doc Name：凭证 id → 显示名（测试时可注入）。
-spec lines(map(), lang(), fun((binary()) -> binary())) -> [line()].
lines(Log, Lang0, Name) ->
    L = lang(Lang0),
    lists:append([request(L, Log, Name), rule(L, Log), intent(L, Log), nested(L, Log), affinity(L, Log, Name),
                  tiers(L, Log, Name), attempts(L, Log, Name), result(L, Log, Name)]).

%% @doc 规范化语言：en 之外一律 zh。
-spec lang(term()) -> lang().
lang(en) -> en;
lang(_) -> zh.

%% @doc 套餐说明（lg_strategy:note/1 生成的中文短语，如「5h 80% 重置 10-13 14:00 · 近期 1200 tok」）按语言显示。
-spec note(binary(), lang()) -> binary().
note(N, en) when is_binary(N) ->
    N1 = binary:replace(N, <<" 重置 "/utf8>>, <<" resets ">>, [global]),
    binary:replace(N1, <<"近期 "/utf8>>, <<"recent ">>, [global]);
note(N, _) ->
    N.

%%--------------------------------------------------------------------

request(L, #{route := Route} = Log, Name) ->
    Who = client_name(L, maps:get(client, Log, undefined)),
    Model = case maps:get(model, Log, Route) of
                Route -> <<>>;
                M when L =:= en -> [<<" (requested model name ">>, M, <<")">>];
                M -> [<<"（请求的模型名 "/utf8>>, M, <<"）"/utf8>>]
            end,
    Cands = case maps:get(plan_trace, Log, undefined) of
                [_, _ | _] = Tr ->
                    Shown = [target(L, C, Name) || C <- lists:sublist(Tr, ?MAX_CANDIDATES)],
                    Extra = length(Tr) - ?MAX_CANDIDATES,
                    case L of
                        en ->
                            More = case Extra of
                                       N when N > 0 -> [<<" and ">>, integer_to_binary(N), <<" more">>];
                                       _ -> []
                                   end,
                            [<<"; candidates: ">>, lists:join(<<", ">>, Shown), More];
                        zh ->
                            More = case Extra of
                                       N when N > 0 -> [<<" 等 "/utf8>>, integer_to_binary(length(Tr)), <<" 个"/utf8>>];
                                       _ -> []
                                   end,
                            [<<"：候选 "/utf8>>, lists:join(<<"、"/utf8>>, Shown), More]
                    end;
                _ -> []
            end,
    case L of
        en -> [line(info, [Who, <<" requested ">>, Route, Model, Cands])];
        zh -> [line(info, [Who, <<" 请求了 "/utf8>>, Route, Model, Cands])]
    end;
request(_, _, _) ->
    [].

rule(L, #{rule := 0} = Log) ->
    case maps:is_key(intent, Log) of
        true when L =:= en -> [line(info, <<"No rule matched; using the route's own order">>)];
        true -> [line(info, <<"没有规则命中，按路由本身的顺序"/utf8>>)];
        false -> []
    end;
rule(en, #{rule := N} = Log) when is_integer(N), N > 0 ->
    Why = case maps:get(intent, Log, undefined) of
              #{answer := A, intents := Is} when A > 0, A =< length(Is) ->
                  [<<" (intent: “"/utf8>>, lists:nth(A, Is), <<"”)"/utf8>>];
              _ -> []
          end,
    Head = case maps:get(rule_reused, Log, false) of
               true -> [<<"Reusing this conversation's earlier decision: rule ">>, integer_to_binary(N)];
               false -> [<<"Matched rule ">>, integer_to_binary(N)]
           end,
    Action = case maps:get(routed_to, Log, undefined) of
                 undefined -> <<", but the credentials the rule points to were skipped">>;
                 To -> [<<"; sending to ">>, To, <<" first, with this route's own targets as fallback">>]
             end,
    [line(info, [Head, Why, Action])];
rule(zh, #{rule := N} = Log) when is_integer(N), N > 0 ->
    Why = case maps:get(intent, Log, undefined) of
              #{answer := A, intents := Is} when A > 0, A =< length(Is) ->
                  [<<"（意图是“"/utf8>>, lists:nth(A, Is), <<"”）"/utf8>>];
              _ -> []
          end,
    Head = case maps:get(rule_reused, Log, false) of
               true -> [<<"这一轮沿用之前的判定：规则 "/utf8>>, integer_to_binary(N)];
               false -> [<<"命中规则 "/utf8>>, integer_to_binary(N)]
           end,
    Action = case maps:get(routed_to, Log, undefined) of
                 undefined -> <<"，跳过了规则指定的凭证"/utf8>>;
                 To -> [<<"，先发给 "/utf8>>, To, <<"；本路由的目标排在后面，失败时接手"/utf8>>]
             end,
    [line(info, [Head, Why, Action])];
rule(_, _) ->
    [].

intent(L, #{intent := #{local_error := E, classifier := C} = I} = Log) ->
    Text = case {L, maps:get(local_by, I, undefined)} of
               {en, undefined} -> [<<"Local Laya failed to classify (">>, E, <<"); asking ">>, C, <<" instead">>];
               {en, R} -> [<<"Decision model ">>, R, <<" failed to classify (">>, E, <<"); asking ">>, C, <<" instead">>];
               {zh, undefined} -> [<<"本地 Laya 判断失败（"/utf8>>, E, <<"），改问 "/utf8>>, C];
               {zh, R} -> [<<"决策模型 "/utf8>>, R, <<" 判断失败（"/utf8>>, E, <<"），改问 "/utf8>>, C]
           end,
    [line(warn, Text) | intent(L, Log#{intent := maps:without([local_error, local_by], I)})];
intent(en, #{intent := #{cached := true, intents := Is, answer := A}}) ->
    [line(muted, [<<"Already decided for the same message which of ">>, quoted(en, Is),
                  <<" this turn belongs to: ">>, answer_text(en, A, Is)])];
intent(zh, #{intent := #{cached := true, intents := Is, answer := A}}) ->
    [line(muted, [<<"这一轮属于"/utf8>>, quoted(zh, Is), <<"中的哪一个，同一条消息之前已判断过："/utf8>>, answer_text(zh, A, Is)])];
intent(en, #{intent := #{error := E} = I}) ->
    [line(warn, [<<"Intent classification failed (">>, E, <<"); routing as usual this turn">>, by(en, I)])];
intent(zh, #{intent := #{error := E} = I}) ->
    [line(warn, [<<"意图判断失败（"/utf8>>, E, <<"），本轮照常路由"/utf8>>, by(zh, I)])];
intent(en, #{intent := #{intents := Is, answer := A, ms := Ms} = I}) ->
    [line(muted, [<<"Asked ">>, maps:get(classifier, I, <<"the classifier">>), <<" which of ">>, quoted(en, Is),
                  <<" this turn belongs to; it answered ">>, answer_text(en, A, Is), <<" (">>, secs(en, Ms), <<")">>])];
intent(zh, #{intent := #{intents := Is, answer := A, ms := Ms} = I}) ->
    [line(muted, [<<"问 "/utf8>>, maps:get(classifier, I, <<"判断模型"/utf8>>), <<" 这一轮属于"/utf8>>, quoted(zh, Is),
                  <<"中的哪一个，它说"/utf8>>, answer_text(zh, A, Is), <<"（"/utf8>>, secs(zh, Ms), <<"）"/utf8>>])];
intent(_, _) ->
    [].

by(en, #{classifier := C}) -> [<<" (classifier ">>, C, <<")">>];
by(zh, #{classifier := C}) -> [<<"（判断模型 "/utf8>>, C, <<"）"/utf8>>];
by(_, _) -> [].

quoted(en, Is) -> lists:join(<<", ">>, [[<<"“"/utf8>>, I, <<"”"/utf8>>] || I <- Is]);
quoted(zh, Is) -> [[<<"“"/utf8>>, I, <<"”"/utf8>>] || I <- Is].

answer_text(_, A, Is) when A > 0, A =< length(Is) -> [<<"“"/utf8>>, lists:nth(A, Is), <<"”"/utf8>>];
answer_text(en, _, _) -> <<"none of them">>;
answer_text(zh, _, _) -> <<"都不是"/utf8>>.

%% 嵌套路由自己的规则判定：与顶层规则同样的写法，前面标出是哪条嵌套路由
nested(L, #{nested_rules := Ns}) when is_list(Ns) ->
    Prefix = fun(R) -> case L of
                           en -> <<"Nested route ", R/binary, ": ">>;
                           zh -> <<"嵌套路由 "/utf8, R/binary, " ">>
                       end
             end,
    lists:append([[Ln#{text := <<(Prefix(R))/binary, T/binary>>} || #{text := T} = Ln <- rule(L, N) ++ intent(L, N)]
                  || #{route := R} = N <- Ns]);
nested(_, _) ->
    [].

affinity(en, #{affinity := <<"hit">>, affinity_prev := #{credential := C} = P}, Name) ->
    [line(muted, [<<"This session was last answered by ">>, Name(C), cache_note(en, P), <<"; staying with it">>])];
affinity(zh, #{affinity := <<"hit">>, affinity_prev := #{credential := C} = P}, Name) ->
    [line(muted, [<<"这个会话上次由 "/utf8>>, Name(C), <<" 回答"/utf8>>, cache_note(zh, P), <<"，继续留在它上面"/utf8>>])];
affinity(en, #{affinity := <<"broken:", Why/binary>>, affinity_prev := #{credential := C} = P}, Name) ->
    Reason = case Why of
                 <<"cache_cold">> ->
                     [<<", but only ">>, tokens_n(en, maps:get(cache_read, P, 0)),
                      <<" were read from cache last time (or more than 5 minutes have passed), so it isn't worth staying">>];
                 <<"cooling">> -> <<", but it is cooling down; choosing again in normal order">>;
                 <<"plan_window_full">> -> <<", but its plan window is almost used up; choosing again in normal order">>;
                 <<"concurrency_full">> ->
                     <<", but it is at its concurrency limit with requests queued; choosing again in normal order">>;
                 <<"target_gone">> -> <<", but it is no longer part of this route">>;
                 _ -> [<<", but stickiness was dropped (">>, Why, <<")">>]
             end,
    [line(muted, [<<"This session was last answered by ">>, Name(C), Reason])];
affinity(zh, #{affinity := <<"broken:", Why/binary>>, affinity_prev := #{credential := C} = P}, Name) ->
    Reason = case Why of
                 <<"cache_cold">> ->
                     [<<"，但上次只从缓存读了 "/utf8>>, tokens(maps:get(cache_read, P, 0)),
                      <<" token（或已超过 5 分钟），不值得为此留下"/utf8>>];
                 <<"cooling">> -> <<"，但它正在冷却，按正常顺序重新选择"/utf8>>;
                 <<"plan_window_full">> -> <<"，但它的套餐窗口快用完了，按正常顺序重新选择"/utf8>>;
                 <<"concurrency_full">> -> <<"，但它并发已满且有排队，按正常顺序重新选择"/utf8>>;
                 <<"target_gone">> -> <<"，但它已不在这条路由里"/utf8>>;
                 _ -> [<<"，但放弃了粘性（"/utf8>>, Why, <<"）"/utf8>>]
             end,
    [line(muted, [<<"这个会话上次由 "/utf8>>, Name(C), <<" 回答"/utf8>>, Reason])];
affinity(_, _, _) ->
    [].

cache_note(en, #{cache_read := N}) when N > 0 -> [<<" (">>, tokens_n(en, N), <<" read from cache last time)">>];
cache_note(zh, #{cache_read := N}) when N > 0 -> [<<"（上次读到 "/utf8>>, tokens(N), <<" token 缓存）"/utf8>>];
cache_note(_, _) -> [].

%% 不在正常层的候选：额度用尽、保留、冷却
tiers(L, #{plan_trace := Tr}, Name) when is_list(Tr) ->
    [case L of
         en -> line(warn, [target(en, C, Name), <<" ">>, tier_text(en, T), note_text(en, C), <<"; moved to the back">>]);
         zh -> line(warn, [target(zh, C, Name), tier_text(zh, T), note_text(zh, C), <<"，排到后面"/utf8>>])
     end
     || #{tier := T} = C <- Tr, tier_key(T) =/= <<"hot">>];
tiers(_, _, _) ->
    [].

tier_text(en, T) ->
    case tier_key(T) of
        <<"reserve">> -> <<"has reached its plan reserve">>;
        <<"cold">> -> <<"is cooling down">>;
        <<"cold_reserve">> -> <<"is cooling down and has reached its plan reserve">>;
        <<"exhausted">> -> <<"has used up its plan quota">>;
        Other -> [<<"is in tier ">>, Other]
    end;
tier_text(zh, T) ->
    case tier_key(T) of
        <<"reserve">> -> <<"套餐额度进入保留"/utf8>>;
        <<"cold">> -> <<"冷却中"/utf8>>;
        <<"cold_reserve">> -> <<"冷却中且套餐额度进入保留"/utf8>>;
        <<"exhausted">> -> <<"套餐额度用尽"/utf8>>;
        Other -> Other
    end.

tier_key(T) when is_atom(T) -> atom_to_binary(T);
tier_key(T) -> T.

note_text(en, #{note := N}) when is_binary(N), N =/= <<>> -> [<<" (">>, note(N, en), <<")">>];
note_text(zh, #{note := N}) when is_binary(N), N =/= <<>> -> [<<"（"/utf8>>, N, <<"）"/utf8>>];
note_text(_, _) -> [].

attempts(L, #{attempt_list := As} = Log, Name) when is_list(As) ->
    N = length(As),
    Ok = lists:any(fun(A) -> maps:get(ok, A, false) end, As),
    lists:append(
      [case A of
           #{busy := true} when L =:= en -> [line(warn, [target(en, A, Name), <<" is at its concurrency limit; skipped">>])];
           #{busy := true} -> [line(warn, [target(zh, A, Name), <<"并发已满，跳过"/utf8>>])];
           #{ok := true} -> [];
           _ when I =:= N, not Ok -> [];      %% 最后一次失败由结果行说明
           _ when L =:= en ->
               [line(warn, [target(en, A, Name), <<" ">>, kind_text(en, maps:get(kind, A, undefined)),
                            message(en, maps:get(message, A, undefined)), <<"; trying the next one (attempt ">>,
                            integer_to_binary(I + 1), <<")">>])];
           _ ->
               [line(warn, [target(zh, A, Name), kind_text(zh, maps:get(kind, A, undefined)),
                            message(zh, maps:get(message, A, undefined)), <<"，改用下一个（第 "/utf8>>,
                            integer_to_binary(I + 1), <<" 次尝试）"/utf8>>])]
       end || {I, A} <- lists:enumerate(As)]) ++ rounds(L, Log) ++ queued(L, Log);
attempts(L, Log, _) ->
    queued(L, Log).

rounds(en, #{rounds := N, patience_ms := Ms}) when is_integer(N), N > 0 ->
    [line(warn, [<<"All candidates were busy; waited ">>, secs(en, Ms), <<" and retried the whole round">>,
                 case N of 1 -> []; _ -> [<<" (">>, integer_to_binary(N), <<" rounds in total)">>] end])];
rounds(zh, #{rounds := N, patience_ms := Ms}) when is_integer(N), N > 0 ->
    [line(warn, [<<"所有候选都繁忙，等待 "/utf8>>, secs(zh, Ms), <<"后整轮再试"/utf8>>,
                 case N of 1 -> []; _ -> [<<"（共 "/utf8>>, integer_to_binary(N), <<" 轮）"/utf8>>] end])];
rounds(_, _) ->
    [].

queued(en, #{queued_ms := Q}) when is_integer(Q), Q > 0 ->
    [line(warn, [<<"The credential was at its concurrency limit; queued for ">>, secs(en, Q)])];
queued(zh, #{queued_ms := Q}) when is_integer(Q), Q > 0 ->
    [line(warn, [<<"凭证并发已满，排队 "/utf8>>, secs(zh, Q)])];
queued(_, _) ->
    [].

result(L, #{cache_hit := true} = Log, _Name) ->
    case L of
        en -> [line(ok, [<<"Served from the response cache without calling the upstream">>, saved(en, Log)])];
        zh -> [line(ok, [<<"命中响应缓存，没有访问上游"/utf8>>, saved(zh, Log)])]
    end;
result(L, #{error := E, status := S} = Log, Name) when E =/= undefined ->
    Last = case maps:get(attempt_list, Log, []) of
               [_ | _] = As -> [target(L, lists:last(As), Name)];
               _ -> []
           end,
    Msg = case E of
              #{message := M} when is_binary(M) -> [colon(L), clip(humanize(L, M))];
              _ -> []
          end,
    K = case E of
            #{kind := K0} -> K0;
            _ -> undefined
        end,
    case L of
        en ->
            %% 有尝试记录时以上游为主语（“X timed out”），否则是网关自己的结论（“Model not found”）
            Head = case Last of
                       [] -> kind_head(K);
                       _ -> [Last, <<" ">>, kind_text(en, K)]
                   end,
            [line(error, [Head, <<"; the client received ">>, integer_to_binary(S), Msg])];
        zh ->
            [line(error, [Last, kind_text(zh, K), <<"，客户端收到 "/utf8>>, integer_to_binary(S), Msg])]
    end;
result(L, #{credential := C} = Log, Name) ->
    Usage = case maps:get(usage, Log, undefined) of
                #{input := I, output := O} = U ->
                    Total = I + O + maps:get(cache_read, U, 0) + maps:get(cache_write, U, 0),
                    case {L, maps:get(cache_read, U, 0)} of
                        {en, 0} -> [<<" · "/utf8>>, tokens_n(en, Total)];
                        {en, CR} -> [<<" · "/utf8>>, tokens_n(en, Total), <<" (">>, tokens(CR), <<" cache read)">>];
                        {zh, 0} -> [<<" · "/utf8>>, tokens(Total), <<" token"/utf8>>];
                        {zh, CR} -> [<<" · "/utf8>>, tokens(Total), <<" token"/utf8>>,
                                     <<"（缓存读 "/utf8>>, tokens(CR), <<"）"/utf8>>]
                    end;
                _ -> []
            end,
    Cost = case {L, Log} of
               {en, #{plan := true, plan_usd := P}} when is_number(P), P > 0 ->
                   [<<" · covered by plan (equivalent to "/utf8>>, usd(P), <<")">>];
               {en, #{plan := true}} -> <<" · covered by plan"/utf8>>;
               {zh, #{plan := true, plan_usd := P}} when is_number(P), P > 0 ->
                   [<<" · 套餐内（等价 "/utf8>>, usd(P), <<"）"/utf8>>];
               {zh, #{plan := true}} -> <<" · 套餐内"/utf8>>;
               {_, #{cost := X}} when is_number(X), X > 0 -> [<<" · "/utf8>>, usd(X)];
               _ -> []
           end,
    Ttft = case Log of
               #{stream := true, ttft_ms := T} when is_integer(T), L =:= en -> [<<", first token after ">>, secs(en, T)];
               #{stream := true, ttft_ms := T} when is_integer(T) -> [<<"，首 token "/utf8>>, secs(zh, T)];
               _ -> []
           end,
    Loop = case maps:get(loop_detected, Log, false) of
               true when L =:= en ->
                   [line(warn, <<"The output got stuck repeating itself; the gateway ended it early "
                                 "(finish reason recorded as the length limit)">>)];
               true -> [line(warn, <<"输出陷入复读，网关提前结束（结束原因记为长度上限）"/utf8>>)];
               false -> []
           end,
    Redacted = case maps:get(redacted, Log, undefined) of
                   1 when L =:= en ->
                       [line(info, <<"1 piece of sensitive information in the request was sent upstream as a placeholder "
                                     "and restored in the reply">>)];
                   R when is_integer(R), R > 0, L =:= en ->
                       [line(info, [integer_to_binary(R), <<" pieces of sensitive information in the request were sent "
                                                            "upstream as placeholders and restored in the reply">>])];
                   R when is_integer(R), R > 0 ->
                       [line(info, [<<"请求中 "/utf8>>, integer_to_binary(R),
                                    <<" 处敏感信息以占位符发往上游，回复中已还原"/utf8>>])];
                   _ -> []
               end,
    Done = case L of
               en ->
                   Who = case maps:get(upstream_model, Log, <<>>) of
                             <<>> -> Name(C);
                             M -> [Name(C), <<" (">>, M, <<")">>]
                         end,
                   line(ok, [Who, <<" answered in ">>, secs(en, maps:get(duration_ms, Log, 0)), Ttft, Usage, Cost]);
               zh ->
                   line(ok, [Name(C), <<"（"/utf8>>, maps:get(upstream_model, Log, <<>>), <<"）用 "/utf8>>,
                             secs(zh, maps:get(duration_ms, Log, 0)), <<"完成回答"/utf8>>, Ttft, Usage, Cost])
           end,
    Redacted ++ Loop ++ [Done];
result(_, _, _) ->
    [].

saved(en, #{saved_usd := S}) when is_number(S), S > 0 -> [<<", saving ">>, usd(S)];
saved(zh, #{saved_usd := S}) when is_number(S), S > 0 -> [<<"，节省 "/utf8>>, usd(S)];
saved(_, _) -> [].

%%--------------------------------------------------------------------

%% 中文版末尾带空格或全角括号，后面直接接谓语；英文版不带尾随空格，由调用方加
target(L, #{credential := C} = T, Name) ->
    case {L, maps:get(upstream_model, T, undefined)} of
        {en, undefined} -> Name(C);
        {en, M} -> [Name(C), <<" (">>, M, <<")">>];
        {zh, undefined} -> [Name(C), <<" ">>];
        {zh, M} -> [Name(C), <<"（"/utf8>>, M, <<"）"/utf8>>]
    end.

%% 以上游 / 凭证为主语的谓语（英文）或紧跟名称的说明（中文）
kind_text(en, K) ->
    case to_bin(K) of
        <<"rate_limit">> -> <<"was rate-limited">>;
        <<"quota">> -> <<"ran out of quota">>;
        <<"credit">> -> <<"has insufficient balance">>;
        <<"unserved">> -> <<"is not allowed to use this model">>;
        <<"server">> -> <<"returned a server error">>;
        <<"timeout">> -> <<"timed out">>;
        <<"network">> -> <<"hit a network error">>;
        <<"auth">> -> <<"failed authentication">>;
        <<"client">> -> <<"rejected the request">>;
        <<"concurrency">> -> <<"was at its concurrency limit and the queue timed out">>;
        <<"route_not_found">> -> <<"reported that the model does not exist">>;
        <<"route_forbidden">> -> <<"denied access">>;
        <<"rate_limited">> -> <<"hit the gateway rate limit">>;
        <<"budget_exceeded">> -> <<"exceeded the budget">>;
        <<"plan_exhausted">> -> <<"found every plan quota used up">>;
        <<"middleware_rejected">> -> <<"was rejected by middleware">>;
        <<"no_available_target">> -> <<"had no upstream available">>;
        <<"undefined">> -> <<"failed">>;
        Other -> [<<"failed (">>, Other, <<")">>]
    end;
kind_text(zh, K) ->
    case to_bin(K) of
        <<"rate_limit">> -> <<"被限流"/utf8>>;
        <<"quota">> -> <<"额度用尽"/utf8>>;
        <<"credit">> -> <<"余额不足"/utf8>>;
        <<"unserved">> -> <<"该凭证无权使用此模型"/utf8>>;
        <<"server">> -> <<"返回服务端错误"/utf8>>;
        <<"timeout">> -> <<"超时"/utf8>>;
        <<"network">> -> <<"网络错误"/utf8>>;
        <<"auth">> -> <<"鉴权失败"/utf8>>;
        <<"client">> -> <<"拒绝了请求"/utf8>>;
        <<"concurrency">> -> <<"并发已满且排队超时"/utf8>>;
        <<"route_not_found">> -> <<"模型不存在"/utf8>>;
        <<"route_forbidden">> -> <<"无权访问"/utf8>>;
        <<"rate_limited">> -> <<"触发网关限流"/utf8>>;
        <<"budget_exceeded">> -> <<"超出预算"/utf8>>;
        <<"plan_exhausted">> -> <<"所有套餐额度用尽"/utf8>>;
        <<"middleware_rejected">> -> <<"被中间件拒绝"/utf8>>;
        <<"no_available_target">> -> <<"没有可用的上游"/utf8>>;
        <<"undefined">> -> <<"失败"/utf8>>;
        Other -> Other
    end.

%% 没有上游可作主语时（网关自己拒绝 / 没有尝试）的英文句首
kind_head(K) ->
    case to_bin(K) of
        <<"rate_limit">> -> <<"Rate-limited">>;
        <<"quota">> -> <<"Quota used up">>;
        <<"credit">> -> <<"Insufficient balance">>;
        <<"unserved">> -> <<"No credential may use this model">>;
        <<"server">> -> <<"Server error">>;
        <<"timeout">> -> <<"Timed out">>;
        <<"network">> -> <<"Network error">>;
        <<"auth">> -> <<"Authentication failed">>;
        <<"client">> -> <<"Request rejected">>;
        <<"concurrency">> -> <<"Concurrency limit reached and the queue timed out">>;
        <<"route_not_found">> -> <<"Model not found">>;
        <<"route_forbidden">> -> <<"Access denied">>;
        <<"rate_limited">> -> <<"Gateway rate limit hit">>;
        <<"budget_exceeded">> -> <<"Budget exceeded">>;
        <<"plan_exhausted">> -> <<"All plan quotas used up">>;
        <<"middleware_rejected">> -> <<"Rejected by middleware">>;
        <<"no_available_target">> -> <<"No upstream available">>;
        <<"undefined">> -> <<"Failed">>;
        Other -> Other
    end.

colon(en) -> <<": ">>;
colon(zh) -> <<"："/utf8>>.

message(L, M) when is_binary(M), M =/= <<>> -> [colon(L), clip(humanize(L, M))];
message(_, _) -> [].

%% 连接类错误的原始 Erlang 原因（如 {down,{shutdown,nxdomain}}）透出到界面不友好，
%% 映射成一句人话；原文仍保留在结构化日志的 message 字段里供排查
humanize(L, M) ->
    Lower = string:lowercase(M),
    Rules = [{<<"nxdomain">>, <<"上游域名无法解析"/utf8>>, <<"Upstream host name could not be resolved">>},
             {<<"econnrefused">>, <<"上游拒绝连接"/utf8>>, <<"Upstream refused the connection">>},
             {<<"econnreset">>, <<"上游重置了连接"/utf8>>, <<"Upstream reset the connection">>},
             {<<"closed">>, <<"连接被上游关闭"/utf8>>, <<"Connection closed by upstream">>},
             {<<"timeout">>, <<"连接超时"/utf8>>, <<"Connection timed out">>}],
    case [pick(L, Zh, En) || {W, Zh, En} <- Rules, binary:match(Lower, W) =/= nomatch] of
        [T | _] -> T;
        [] ->
            Ssl = binary:match(Lower, <<"ssl">>) =/= nomatch orelse
                  binary:match(Lower, <<"tls">>) =/= nomatch orelse
                  binary:match(Lower, <<"certificate">>) =/= nomatch,
            case Ssl of
                true -> pick(L, <<"上游 TLS 握手失败"/utf8>>, <<"Upstream TLS handshake failed">>);
                false -> M
            end
    end.

pick(en, _, En) -> En;
pick(zh, Zh, _) -> Zh.

clip(M) ->
    case string:slice(M, 0, ?MAX_MESSAGE) of
        M -> M;
        S when is_binary(S) -> <<S/binary, "…"/utf8>>;
        _ -> <<>>
    end.

client_name(en, undefined) -> <<"A client">>;
client_name(zh, undefined) -> <<"客户端"/utf8>>;
client_name(_, <<"claude-code">>) -> <<"Claude Code">>;
client_name(_, <<"codex">>) -> <<"Codex">>;
client_name(_, <<"opencode">>) -> <<"opencode">>;
client_name(_, <<"openai-sdk">>) -> <<"OpenAI SDK">>;
client_name(_, <<"anthropic-sdk">>) -> <<"Anthropic SDK">>;
client_name(en, <<"litegate">>) -> <<"The gateway (intent classification)">>;
client_name(zh, <<"litegate">>) -> <<"网关（意图判断）"/utf8>>;
client_name(L, <<"other">>) -> client_name(L, undefined);
client_name(_, C) -> C.

cred_name(Id) ->
    case catch lg_credentials:get(Id) of
        {ok, #lg_credential{name = N}} -> N;
        _ -> Id
    end.

secs(en, Ms) when Ms < 1000 -> [integer_to_binary(Ms), <<" ms">>];
secs(en, Ms) -> [float_to_binary(Ms / 1000, [{decimals, 1}]), <<" s">>];
secs(zh, Ms) when Ms < 1000 -> [integer_to_binary(Ms), <<" 毫秒"/utf8>>];
secs(zh, Ms) -> [float_to_binary(Ms / 1000, [{decimals, 1}]), <<" 秒"/utf8>>].

tokens(N) when N >= 1000000 -> [float_to_binary(N / 1000000, [{decimals, 1}]), <<"M">>];
tokens(N) when N >= 1000 -> [float_to_binary(N / 1000, [{decimals, 1}]), <<"k">>];
tokens(N) -> integer_to_binary(round(N)).

%% 英文带单位与单复数：「1 token」「0 tokens」「2.1k tokens」
tokens_n(en, N) when N == 1 -> <<"1 token">>;
tokens_n(en, N) -> [tokens(N), <<" tokens">>].

usd(X) when X < 0.01 -> [<<"$">>, float_to_binary(float(X), [{decimals, 4}])];
usd(X) -> [<<"$">>, float_to_binary(float(X), [{decimals, 2}])].

to_bin(A) when is_atom(A) -> atom_to_binary(A);
to_bin(B) when is_binary(B) -> B;
to_bin(_) -> <<"undefined">>.

line(Tone, Text) ->
    #{tone => Tone, text => unicode:characters_to_binary(Text)}.
