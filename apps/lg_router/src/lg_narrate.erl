%% @doc 决策叙述：把一次请求的结构化路由记录写成几行中文（实时路由页、日志详情）。
%%
%% 输入是请求日志（lg_web_llm:record 写入的字段），输出 [#{tone, text}]，tone 为
%% info（经过）、muted（旁注：意图判断、粘性）、warn（降级、失败后改道）、ok（完成）、error（客户端收到错误）。
%% 原因文字全部来自日志里已有的字段：client、plan_trace（层与套餐说明）、rule / routed_to / intent、
%% affinity / affinity_prev、attempt_list、status / usage / cost / error。
-module(lg_narrate).

-export([lines/1, lines/2]).

-include_lib("lg_core/include/lg_core.hrl").

-define(MAX_CANDIDATES, 4).
-define(MAX_MESSAGE, 80).

-type line() :: #{tone := info | muted | warn | ok | error, text := binary()}.

-spec lines(map()) -> [line()].
lines(Log) ->
    lines(Log, fun cred_name/1).

%% @doc Name：凭证 id → 显示名（测试时可注入）。
-spec lines(map(), fun((binary()) -> binary())) -> [line()].
lines(Log, Name) ->
    lists:append([request(Log, Name), rule(Log), intent(Log), nested(Log), affinity(Log, Name), tiers(Log, Name),
                  attempts(Log, Name), result(Log, Name)]).

%%--------------------------------------------------------------------

request(#{route := Route} = Log, Name) ->
    Who = client_name(maps:get(client, Log, undefined)),
    Model = case maps:get(model, Log, Route) of
                Route -> <<>>;
                M -> [<<"（请求的模型名 "/utf8>>, M, <<"）"/utf8>>]
            end,
    Cands = case maps:get(plan_trace, Log, undefined) of
                [_, _ | _] = Tr ->
                    Shown = lists:sublist(Tr, ?MAX_CANDIDATES),
                    More = case length(Tr) - ?MAX_CANDIDATES of
                               N when N > 0 -> [<<" 等 "/utf8>>, integer_to_binary(length(Tr)), <<" 个"/utf8>>];
                               _ -> []
                           end,
                    [<<"：候选 "/utf8>>, lists:join(<<"、"/utf8>>, [target(C, Name) || C <- Shown]), More];
                _ -> []
            end,
    [line(info, [Who, <<" 请求了 "/utf8>>, Route, Model, Cands])];
request(_, _) ->
    [].

rule(#{rule := 0} = Log) ->
    case maps:is_key(intent, Log) of
        true -> [line(info, <<"没有规则命中，按路由本身的顺序"/utf8>>)];
        false -> []
    end;
rule(#{rule := N} = Log) when is_integer(N), N > 0 ->
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
rule(_) ->
    [].

intent(#{intent := #{local_error := E, classifier := C} = I} = Log) ->
    Who = case maps:get(local_by, I, undefined) of
              undefined -> <<"本地 Laya"/utf8>>;
              R -> [<<"决策模型 "/utf8>>, R]
          end,
    [line(warn, [Who, <<" 判断失败（"/utf8>>, E, <<"），改问 "/utf8>>, C])
     | intent(Log#{intent := maps:without([local_error, local_by], I)})];
intent(#{intent := #{cached := true, intents := Is, answer := A}}) ->
    [line(muted, [<<"这一轮属于"/utf8>>, quoted(Is), <<"中的哪一个，同一条消息之前已判断过："/utf8>>, answer_text(A, Is)])];
intent(#{intent := #{error := E} = I}) ->
    [line(warn, [<<"意图判断失败（"/utf8>>, E, <<"），本轮照常路由"/utf8>>, by(I)])];
intent(#{intent := #{intents := Is, answer := A, ms := Ms} = I}) ->
    [line(muted, [<<"问 "/utf8>>, maps:get(classifier, I, <<"判断模型"/utf8>>), <<" 这一轮属于"/utf8>>, quoted(Is),
                  <<"中的哪一个，它说"/utf8>>, answer_text(A, Is), <<"（"/utf8>>, secs(Ms), <<"）"/utf8>>])];
intent(_) ->
    [].

by(#{classifier := C}) -> [<<"（判断模型 "/utf8>>, C, <<"）"/utf8>>];
by(_) -> [].

quoted(Is) -> lists:join(<<""/utf8>>, [[<<"“"/utf8>>, I, <<"”"/utf8>>] || I <- Is]).

answer_text(A, Is) when A > 0, A =< length(Is) -> [<<"“"/utf8>>, lists:nth(A, Is), <<"”"/utf8>>];
answer_text(_, _) -> <<"都不是"/utf8>>.

%% 嵌套路由自己的规则判定：与顶层规则同样的写法，前面标出是哪条嵌套路由
nested(#{nested_rules := Ns}) when is_list(Ns) ->
    lists:append([[L#{text := <<"嵌套路由 "/utf8, R/binary, " "/utf8, T/binary>>} || #{text := T} = L <- rule(N) ++ intent(N)]
                  || #{route := R} = N <- Ns]);
nested(_) ->
    [].

affinity(#{affinity := <<"hit">>, affinity_prev := #{credential := C} = P}, Name) ->
    [line(muted, [<<"这个会话上次由 "/utf8>>, Name(C), <<" 回答"/utf8>>, cache_note(P), <<"，继续留在它上面"/utf8>>])];
affinity(#{affinity := <<"broken:", Why/binary>>, affinity_prev := #{credential := C} = P}, Name) ->
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
affinity(_, _) ->
    [].

cache_note(#{cache_read := N}) when N > 0 -> [<<"（上次读到 "/utf8>>, tokens(N), <<" token 缓存）"/utf8>>];
cache_note(_) -> [].

%% 不在正常层的候选：额度用尽、保留、冷却
tiers(#{plan_trace := Tr}, Name) when is_list(Tr) ->
    [line(warn, [target(C, Name), tier_text(T), note(C), <<"，排到后面"/utf8>>])
     || #{tier := T} = C <- Tr, tier_key(T) =/= <<"hot">>];
tiers(_, _) ->
    [].

tier_text(T) ->
    case tier_key(T) of
        <<"reserve">> -> <<"套餐额度进入保留"/utf8>>;
        <<"cold">> -> <<"冷却中"/utf8>>;
        <<"cold_reserve">> -> <<"冷却中且套餐额度进入保留"/utf8>>;
        <<"exhausted">> -> <<"套餐额度用尽"/utf8>>;
        Other -> Other
    end.

tier_key(T) when is_atom(T) -> atom_to_binary(T);
tier_key(T) -> T.

note(#{note := N}) when is_binary(N), N =/= <<>> -> [<<"（"/utf8>>, N, <<"）"/utf8>>];
note(_) -> [].

attempts(#{attempt_list := As} = Log, Name) when is_list(As) ->
    N = length(As),
    Ok = lists:any(fun(A) -> maps:get(ok, A, false) end, As),
    lists:append(
      [case A of
           #{busy := true} -> [line(warn, [target(A, Name), <<"并发已满，跳过"/utf8>>])];
           #{ok := true} -> [];
           _ when I =:= N, not Ok -> [];      %% 最后一次失败由结果行说明
           _ ->
               [line(warn, [target(A, Name), kind_text(maps:get(kind, A, undefined)),
                            message(maps:get(message, A, undefined)), <<"，改用下一个（第 "/utf8>>,
                            integer_to_binary(I + 1), <<" 次尝试）"/utf8>>])]
       end || {I, A} <- lists:enumerate(As)]) ++ rounds(Log) ++ queued(Log);
attempts(Log, _) ->
    queued(Log).

rounds(#{rounds := N, patience_ms := Ms}) when is_integer(N), N > 0 ->
    [line(warn, [<<"所有候选都繁忙，等待 "/utf8>>, secs(Ms), <<"后整轮再试"/utf8>>,
                 case N of 1 -> []; _ -> [<<"（共 "/utf8>>, integer_to_binary(N), <<" 轮）"/utf8>>] end])];
rounds(_) ->
    [].

queued(#{queued_ms := Q}) when is_integer(Q), Q > 0 ->
    [line(warn, [<<"凭证并发已满，排队 "/utf8>>, secs(Q)])];
queued(_) ->
    [].

result(#{cache_hit := true} = Log, _Name) ->
    [line(ok, [<<"命中响应缓存，没有访问上游"/utf8>>, saved(Log)])];
result(#{error := E, status := S} = Log, Name) when E =/= undefined ->
    Last = case maps:get(attempt_list, Log, []) of
               [_ | _] = As -> [target(lists:last(As), Name)];
               _ -> []
           end,
    Msg = case E of
              #{message := M} when is_binary(M) -> [<<"："/utf8>>, clip(humanize(M))];
              _ -> []
          end,
    Kind = case E of
               #{kind := K} -> kind_text(K);
               _ -> <<"失败"/utf8>>
           end,
    [line(error, [Last, Kind, <<"，客户端收到 "/utf8>>, integer_to_binary(S), Msg])];
result(#{credential := C} = Log, Name) ->
    Usage = case maps:get(usage, Log, undefined) of
                #{input := I, output := O} = U ->
                    [<<" · "/utf8>>, tokens(I + O + maps:get(cache_read, U, 0) + maps:get(cache_write, U, 0)), <<" token"/utf8>>,
                     case maps:get(cache_read, U, 0) of
                         0 -> [];
                         CR -> [<<"（缓存读 "/utf8>>, tokens(CR), <<"）"/utf8>>]
                     end];
                _ -> []
            end,
    Cost = case Log of
               #{plan := true, plan_usd := P} when is_number(P), P > 0 -> [<<" · 套餐内（等价 "/utf8>>, usd(P), <<"）"/utf8>>];
               #{plan := true} -> <<" · 套餐内"/utf8>>;
               #{cost := X} when is_number(X), X > 0 -> [<<" · "/utf8>>, usd(X)];
               _ -> []
           end,
    Ttft = case Log of
               #{stream := true, ttft_ms := T} when is_integer(T) -> [<<"，首 token "/utf8>>, secs(T)];
               _ -> []
           end,
    Loop = case maps:get(loop_detected, Log, false) of
               true -> [line(warn, <<"输出陷入复读，网关提前结束（结束原因记为长度上限）"/utf8>>)];
               false -> []
           end,
    Redacted = case maps:get(redacted, Log, undefined) of
                   R when is_integer(R), R > 0 ->
                       [line(info, [<<"请求中 "/utf8>>, integer_to_binary(R),
                                    <<" 处敏感信息以占位符发往上游，回复中已还原"/utf8>>])];
                   _ -> []
               end,
    Redacted ++ Loop ++ [line(ok, [Name(C), <<"（"/utf8>>, maps:get(upstream_model, Log, <<>>), <<"）用 "/utf8>>,
               secs(maps:get(duration_ms, Log, 0)), <<"完成回答"/utf8>>, Ttft, Usage, Cost])];
result(_, _) ->
    [].

saved(#{saved_usd := S}) when is_number(S), S > 0 -> [<<"，节省 "/utf8>>, usd(S)];
saved(_) -> [].

%%--------------------------------------------------------------------

target(#{credential := C} = T, Name) ->
    case maps:get(upstream_model, T, undefined) of
        undefined -> [Name(C), <<" ">>];
        M -> [Name(C), <<"（"/utf8>>, M, <<"）"/utf8>>]
    end.

kind_text(K) ->
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

message(M) when is_binary(M), M =/= <<>> -> [<<"："/utf8>>, clip(humanize(M))];
message(_) -> [].

%% 连接类错误的原始 Erlang 原因（如 {down,{shutdown,nxdomain}}）透出到中文界面不友好，
%% 映射成一句人格化描述；原文仍保留在结构化日志的 message 字段里供排查
humanize(M) ->
    Lower = string:lowercase(M),
    Rules = [{<<"nxdomain">>, <<"上游域名无法解析"/utf8>>},
             {<<"econnrefused">>, <<"上游拒绝连接"/utf8>>},
             {<<"econnreset">>, <<"上游重置了连接"/utf8>>},
             {<<"closed">>, <<"连接被上游关闭"/utf8>>},
             {<<"timeout">>, <<"连接超时"/utf8>>}],
    case [T || {W, T} <- Rules, binary:match(Lower, W) =/= nomatch] of
        [T | _] -> T;
        [] ->
            Ssl = binary:match(Lower, <<"ssl">>) =/= nomatch orelse
                  binary:match(Lower, <<"tls">>) =/= nomatch orelse
                  binary:match(Lower, <<"certificate">>) =/= nomatch,
            case Ssl of
                true -> <<"上游 TLS 握手失败"/utf8>>;
                false -> M
            end
    end.

clip(M) ->
    case string:slice(M, 0, ?MAX_MESSAGE) of
        M -> M;
        S when is_binary(S) -> <<S/binary, "…"/utf8>>;
        _ -> <<>>
    end.

client_name(undefined) -> <<"客户端"/utf8>>;
client_name(<<"claude-code">>) -> <<"Claude Code">>;
client_name(<<"codex">>) -> <<"Codex">>;
client_name(<<"opencode">>) -> <<"opencode">>;
client_name(<<"openai-sdk">>) -> <<"OpenAI SDK">>;
client_name(<<"anthropic-sdk">>) -> <<"Anthropic SDK">>;
client_name(<<"litegate">>) -> <<"网关（意图判断）"/utf8>>;
client_name(<<"other">>) -> <<"客户端"/utf8>>;
client_name(C) -> C.

cred_name(Id) ->
    case catch lg_credentials:get(Id) of
        {ok, #lg_credential{name = N}} -> N;
        _ -> Id
    end.

secs(Ms) when Ms < 1000 -> [integer_to_binary(Ms), <<" 毫秒"/utf8>>];
secs(Ms) -> [float_to_binary(Ms / 1000, [{decimals, 1}]), <<" 秒"/utf8>>].

tokens(N) when N >= 1000000 -> [float_to_binary(N / 1000000, [{decimals, 1}]), <<"M">>];
tokens(N) when N >= 1000 -> [float_to_binary(N / 1000, [{decimals, 1}]), <<"k">>];
tokens(N) -> integer_to_binary(round(N)).

usd(X) when X < 0.01 -> [<<"$">>, float_to_binary(float(X), [{decimals, 4}])];
usd(X) -> [<<"$">>, float_to_binary(float(X), [{decimals, 2}])].

to_bin(A) when is_atom(A) -> atom_to_binary(A);
to_bin(B) when is_binary(B) -> B;
to_bin(_) -> <<"undefined">>.

line(Tone, Text) ->
    #{tone => Tone, text => unicode:characters_to_binary(Text)}.
