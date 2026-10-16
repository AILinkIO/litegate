%% @doc 敏感信息脱敏：发往上游前把密钥类内容换成占位符，回复中出现占位符时换回原值，客户端无感知。
%%
%% 识别：
%%   内置密钥：sk-…（OpenAI / Anthropic / DeepSeek / Kimi 等）、GitHub 令牌、AWS 访问密钥、Slack 令牌、Google API Key、
%%             LiteGate 网关 Key（lgk-…）、JWT、PEM 私钥
%%   自定义规则：运行参数 redact_rules（JSON 数组 [{"name", "pattern"}]，pattern 为正则）
%%   个人信息（默认关闭）：运行参数 redact_pii 逗号分隔，可选 id_card（中国居民身份证）、bank_card（Luhn 校验通过的 16–19 位卡号）、phone（中国大陆手机号）
%% 占位符 [[LG_SECRET_N]]，同一请求内同一个值用同一个占位符。
%% 不改动：上游签名过的内容（Anthropic thinking / redacted_thinking 块、Responses 的 encrypted_content）与 data: 开头的内联文件。
%% 思考块的文字也不还原：思考块带签名，客户端下一轮原样发回时必须与上游生成的一致，所以客户端看到的思考里保留占位符。
%% 工具调用参数（arguments、partial_json）本身是 JSON 文本，还原时按 JSON 字符串转义原值。
-module(lg_redact).

-export([scan/1, scan/2, restore/2, restore/3, restore_json/2, rules/0, validate/2]).
-export([stream_new/2, stream_frames/2, stream_finish/1]).

-define(PREFIX, <<"[[LG_SECRET_">>).
-define(SKIP_KEYS, [<<"signature">>, <<"encrypted_content">>, <<"data">>]).

-type mapping() :: #{binary() => binary()}.   %% 占位符 → 原值
-export_type([mapping/0]).

%%====================================================================
%% 规则
%%====================================================================

%% @doc 生效的规则：[{名称, 编译后的正则, 校验函数 | undefined}]，按运行参数缓存。
-spec rules() -> [{binary(), re:mp(), fun((binary()) -> boolean()) | undefined}].
rules() ->
    Key = {catch lg_config:get(redact_rules), catch lg_config:get(redact_pii)},
    case persistent_term:get({?MODULE, rules}, undefined) of
        {Key, Rules} -> Rules;
        _ ->
            Rules = build(Key),
            persistent_term:put({?MODULE, rules}, {Key, Rules}),
            Rules
    end.

build({Custom, Pii}) ->
    Builtin = [{<<"private_key">>, "-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----"},
               {<<"api_key">>, "\\bsk-[A-Za-z0-9_-]{20,}"},
               {<<"litegate_key">>, "\\blgk-[A-Za-z0-9_-]{16,}"},
               {<<"github_token">>, "\\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{22,})"},
               {<<"aws_access_key">>, "\\b(?:AKIA|ASIA)[0-9A-Z]{16}\\b"},
               {<<"slack_token">>, "\\bxox[abprs]-[A-Za-z0-9-]{10,}"},
               {<<"google_api_key">>, "\\bAIza[0-9A-Za-z_-]{35}"},
               {<<"jwt">>, "\\beyJ[A-Za-z0-9_-]{10,}\\.eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}"}],
    PiiRules = [R || {N, _, _} = R <- [{<<"id_card">>, "\\b[1-9]\\d{5}(?:19|20)\\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\\d|3[01])\\d{3}[\\dXx]\\b", undefined},
                                       {<<"bank_card">>, "\\b[1-9]\\d{15,18}\\b", fun luhn/1},
                                       {<<"phone">>, "(?<!\\d)1[3-9]\\d{9}(?!\\d)", undefined}],
                                lists:member(N, pii_list(Pii))],
    Comp = fun(P) -> {ok, Re} = re:compile(P, [unicode]), Re end,
    [{N, Comp(P), undefined} || {N, P} <- Builtin]
        ++ [{N, Comp(P), V} || {N, P, V} <- PiiRules]
        ++ custom(Custom).

pii_list(B) when is_binary(B) -> [string:trim(X) || X <- binary:split(B, <<",">>, [global]), string:trim(X) =/= <<>>];
pii_list(_) -> [].

custom(B) when is_binary(B), B =/= <<>> ->
    try json:decode(B) of
        L when is_list(L) ->
            [{N, Re, undefined} || #{<<"name">> := N, <<"pattern">> := P} <- L, is_binary(P),
                                   {ok, Re} <- [re:compile(P, [unicode])]];
        _ -> []
    catch _:_ -> []
    end;
custom(_) -> [].

-define(PII, [<<"id_card">>, <<"bank_card">>, <<"phone">>]).

%% @doc 运行参数 redact_rules / redact_pii 的校验（其余 key 一律 ok）。
-spec validate(atom(), term()) -> ok | {error, binary()}.
validate(redact_rules, <<>>) -> ok;
validate(redact_rules, B) when is_binary(B) ->
    try json:decode(B) of
        L when is_list(L) ->
            Bad = [X || X <- L, not valid_rule(X)],
            case Bad of
                [] -> ok;
                _ -> {error, <<"Each rule must be {\"name\": string, \"pattern\": valid regex}">>}
            end;
        _ -> {error, <<"redact_rules must be a JSON array">>}
    catch _:_ -> {error, <<"redact_rules must be a JSON array">>}
    end;
validate(redact_pii, B) when is_binary(B) ->
    case [X || X <- pii_list(B), not lists:member(X, ?PII)] of
        [] -> ok;
        [X | _] -> {error, <<"Unknown PII category: ", X/binary, " (id_card, bank_card, phone)">>}
    end;
validate(_, _) -> ok.

valid_rule(#{<<"name">> := N, <<"pattern">> := P}) when is_binary(N), N =/= <<>>, is_binary(P), P =/= <<>> ->
    element(1, re:compile(P, [unicode])) =:= ok;
valid_rule(_) -> false.

luhn(Digits) ->
    Ds = lists:reverse([D - $0 || D <- binary_to_list(Digits)]),
    {Sum, _} = lists:foldl(fun(D, {Acc, Odd}) ->
                                   V = case Odd of
                                           true -> D;
                                           false -> case D * 2 of X when X > 9 -> X - 9; X -> X end
                                       end,
                                   {Acc + V, not Odd}
                           end, {0, true}, Ds),
    Sum rem 10 =:= 0.

%%====================================================================
%% 脱敏
%%====================================================================

%% @doc 脱敏请求体（JSON map）：{新请求体, 占位符 → 原值}。
-spec scan(map()) -> {map(), mapping()}.
scan(Body) ->
    scan(Body, rules()).

-spec scan(term(), list()) -> {term(), mapping()}.
scan(Body, Rules) ->
    {B, {_, Map}} = walk(Body, Rules, {#{}, #{}}),
    {B, Map}.

%% Acc = {原值 → 占位符, 占位符 → 原值}
walk(M, Rules, Acc) when is_map(M) ->
    case M of
        #{<<"type">> := T} when T =:= <<"thinking">>; T =:= <<"redacted_thinking">> -> {M, Acc};
        _ ->
            maps:fold(fun(K, V, {Out, A}) ->
                              case lists:member(K, ?SKIP_KEYS) of
                                  true -> {Out#{K => V}, A};
                                  false -> {V1, A1} = walk(V, Rules, A), {Out#{K => V1}, A1}
                              end
                      end, {#{}, Acc}, M)
    end;
walk(L, Rules, Acc) when is_list(L) ->
    lists:mapfoldl(fun(X, A) -> walk(X, Rules, A) end, Acc, L);
walk(<<"data:", _/binary>> = B, _Rules, Acc) ->
    {B, Acc};
walk(B, Rules, Acc) when is_binary(B) ->
    replace(B, Rules, Acc);
walk(V, _Rules, Acc) ->
    {V, Acc}.

%% 所有规则的命中按出现位置排序，重叠时取先出现的（同位置取更长的）；占位符按出现顺序编号
replace(Text, Rules, Acc) ->
    Hits = lists:append([[{Pos, -Len} || [{Pos, Len}] <- Ms,
                                         Check =:= undefined orelse Check(binary:part(Text, Pos, Len))]
                         || {_Name, Re, Check} <- Rules,
                            {match, Ms} <- [re:run(Text, Re, [global, {capture, first, index}])]]),
    case Hits of
        [] -> {Text, Acc};
        _ ->
            {Parts, Acc1, Last} =
                lists:foldl(fun({Pos, _}, {_, _, From} = St) when Pos < From -> St;
                               ({Pos, NegLen}, {Ps, A, From}) ->
                                    {Ph, A1} = placeholder(binary:part(Text, Pos, -NegLen), A),
                                    {[Ph, binary:part(Text, From, Pos - From) | Ps], A1, Pos - NegLen}
                            end, {[], Acc, 0}, lists:sort(Hits)),
            {iolist_to_binary(lists:reverse([binary:part(Text, Last, byte_size(Text) - Last) | Parts])), Acc1}
    end.

placeholder(V, {Fwd, Rev} = A) ->
    case maps:find(V, Fwd) of
        {ok, Ph} -> {Ph, A};
        error ->
            Ph = <<?PREFIX/binary, (integer_to_binary(map_size(Fwd) + 1))/binary, "]]">>,
            {Ph, {Fwd#{V => Ph}, Rev#{Ph => V}}}
    end.

%%====================================================================
%% 还原
%%====================================================================

%% @doc 在一段文字里把占位符换回原值。
-spec restore(binary(), mapping()) -> binary().
restore(Text, Map) ->
    restore(Text, Map, plain).

%% json：文字处在 JSON 字符串里（工具参数），原值按 JSON 转义后再放回
-spec restore(binary(), mapping(), plain | json) -> binary().
restore(Text, Map, _) when map_size(Map) =:= 0 -> Text;
restore(Text, Map, Mode) ->
    case binary:match(Text, ?PREFIX) of
        nomatch -> Text;
        _ -> maps:fold(fun(Ph, V, T) -> binary:replace(T, Ph, escape(V, Mode), [global]) end, Text, Map)
    end.

escape(V, plain) -> V;
escape(V, json) ->
    Q = iolist_to_binary(json:encode(V)),
    binary:part(Q, 1, byte_size(Q) - 2).

%% @doc 在解码后的 JSON 里把所有字符串中的占位符换回原值（非流式回复、流式中的完整对象）。
-spec restore_json(term(), mapping()) -> term().
restore_json(J, Map) when map_size(Map) =:= 0 -> J;
restore_json(J, Map) -> rj(J, Map, plain).

rj(#{<<"type">> := T} = M, _Map, _) when T =:= <<"thinking">>; T =:= <<"redacted_thinking">> -> M;
rj(M, Map, _) when is_map(M) ->
    maps:map(fun(K, V) when K =:= <<"arguments">>; K =:= <<"partial_json">> -> rj(V, Map, json);
                (K, V) -> case lists:member(K, ?SKIP_KEYS) of
                              true -> V;
                              false -> rj(V, Map, plain)
                          end
             end, M);
rj(L, Map, Mode) when is_list(L) -> [rj(X, Map, Mode) || X <- L];
rj(B, Map, Mode) when is_binary(B) -> restore(B, Map, Mode);
rj(V, _, _) -> V.

%%====================================================================
%% 流式还原
%%====================================================================
%% 占位符可能被切在两个分片之间：每个字段（正文、推理、某个工具调用的参数……）各自暂存「可能是占位符开头」的尾巴，
%% 下一片拼上再还原；字段结束（finish_reason、content_block_stop、*.done）时把暂存的部分补发出去。

-record(rs, {
    format :: openai | anthropic | responses,
    map :: mapping(),
    carry = #{} :: #{term() => binary()},
    blocks = #{} :: #{integer() => text | json | skip}   %% Anthropic：内容块类型
}).

-type stream() :: #rs{}.

-spec stream_new(openai | anthropic | responses, mapping()) -> stream().
stream_new(F, Map) ->
    #rs{format = F, map = Map}.

%% @doc 处理一批写给客户端的 SSE 帧（客户端格式）。
-spec stream_frames(iodata(), stream()) -> {iodata(), stream()}.
stream_frames(Frames, #rs{map = Map} = S) when map_size(Map) =:= 0 ->
    {Frames, S};
stream_frames(Frames, #rs{carry = C} = S) ->
    Bin = iolist_to_binary(Frames),
    case binary:match(Bin, <<"[">>) =:= nomatch andalso lists:all(fun(V) -> V =:= <<>> end, maps:values(C)) of
        true -> {Bin, S};
        false ->
            {Evs, _} = lg_sse:parse(Bin),
            {Out, S1} = lists:mapfoldl(fun event/2, S, Evs),
            {Out, S1}
    end.

%% @doc 流结束：返回还没补发的尾巴（一般为空）。
-spec stream_finish(stream()) -> iodata().
stream_finish(#rs{format = openai, carry = C} = S) ->
    Choices = lists:usort([I || {I, _} <- maps:keys(C)] ++ [I || {I, _, _} <- maps:keys(C)]),
    [encode(undefined, #{<<"choices">> => [#{<<"index">> => I, <<"delta">> => D}]})
     || I <- Choices, D <- [element(1, oa_flush(I, #{}, S))], map_size(D) > 0];
stream_finish(_) ->
    [].

event(#{data := <<"[DONE]">>, raw := Raw}, #rs{format = openai} = S) ->
    {[stream_finish(S), Raw], S#rs{carry = #{}}};
event(#{event := E, data := D, raw := Raw}, S) ->
    case catch json:decode(D) of
        J when is_map(J) ->
            {Js, S1} = ev(S#rs.format, J, S),
            {[encode(E, X) || X <- Js], S1};
        _ ->
            {Raw, S}
    end.

encode(undefined, J) -> lg_sse:encode(iolist_to_binary(json:encode(J)));
encode(E, J) -> lg_sse:encode(E, iolist_to_binary(json:encode(J))).

%% ---- OpenAI Chat：choices[].delta.content / reasoning_content / tool_calls[].function.arguments
ev(openai, #{<<"choices">> := Cs} = J, S0) when is_list(Cs) ->
    {Cs1, S} = lists:mapfoldl(fun oa_choice/2, S0, Cs),
    {[restore_json(J#{<<"choices">> => Cs1}, S#rs.map)], S};
%% ---- Anthropic
ev(anthropic, #{<<"type">> := <<"content_block_start">>, <<"index">> := I, <<"content_block">> := B} = J, S) ->
    Kind = case B of
               #{<<"type">> := <<"text">>} -> text;
               #{<<"type">> := T} when T =:= <<"tool_use">>; T =:= <<"server_tool_use">> -> json;
               _ -> skip
           end,
    {[restore_json(J, S#rs.map)], S#rs{blocks = (S#rs.blocks)#{I => Kind}}};
ev(anthropic, #{<<"type">> := <<"content_block_delta">>, <<"index">> := I,
                <<"delta">> := #{<<"type">> := <<"text_delta">>, <<"text">> := T} = D} = J, S) ->
    {T1, S1} = text({I}, T, plain, S),
    {[J#{<<"delta">> => D#{<<"text">> => T1}}], S1};
ev(anthropic, #{<<"type">> := <<"content_block_delta">>, <<"index">> := I,
                <<"delta">> := #{<<"type">> := <<"input_json_delta">>, <<"partial_json">> := T} = D} = J, S) ->
    {T1, S1} = text({I}, T, json, S),
    {[J#{<<"delta">> => D#{<<"partial_json">> => T1}}], S1};
ev(anthropic, #{<<"type">> := <<"content_block_delta">>} = J, S) ->
    {[J], S};
ev(anthropic, #{<<"type">> := <<"content_block_stop">>, <<"index">> := I} = J, #rs{carry = C} = S) ->
    case maps:take({I}, C) of
        {Tail, C1} when Tail =/= <<>> ->
            Delta = case maps:get(I, S#rs.blocks, text) of
                        json -> #{<<"type">> => <<"input_json_delta">>, <<"partial_json">> => Tail};
                        _ -> #{<<"type">> => <<"text_delta">>, <<"text">> => Tail}
                    end,
            {[#{<<"type">> => <<"content_block_delta">>, <<"index">> => I, <<"delta">> => Delta}, J], S#rs{carry = C1}};
        _ ->
            {[J], S#rs{carry = maps:remove({I}, C)}}
    end;
%% ---- Responses：*.delta 分片，对应的 *.done 前补发暂存部分
ev(responses, #{<<"type">> := T, <<"delta">> := D} = J, S) when is_binary(D) ->
    case binary:longest_common_suffix([T, <<".delta">>]) of
        6 ->
            {D1, S1} = text(resp_field(T, J), D, resp_mode(T), S),
            {[J#{<<"delta">> => D1}], S1};
        _ ->
            {[restore_json(J, S#rs.map)], S}
    end;
ev(responses, #{<<"type">> := T} = J, #rs{carry = C} = S) ->
    case binary:longest_common_suffix([T, <<".done">>]) of
        5 ->
            DT = <<(binary:part(T, 0, byte_size(T) - 5))/binary, ".delta">>,
            F = resp_field(DT, J),
            case maps:take(F, C) of
                {Tail, C1} when Tail =/= <<>> ->
                    Ev = (maps:with([<<"item_id">>, <<"output_index">>, <<"content_index">>, <<"summary_index">>,
                                     <<"sequence_number">>], J))#{<<"type">> => DT, <<"delta">> => Tail},
                    {[Ev, restore_json(J, S#rs.map)], S#rs{carry = C1}};
                _ ->
                    {[restore_json(J, S#rs.map)], S#rs{carry = maps:remove(F, C)}}
            end;
        _ ->
            {[restore_json(J, S#rs.map)], S}
    end;
ev(_, J, S) ->
    {[restore_json(J, S#rs.map)], S}.

resp_field(T, J) ->
    {T, maps:with([<<"item_id">>, <<"output_index">>, <<"content_index">>, <<"summary_index">>], J)}.

resp_mode(T) ->
    case binary:match(T, <<"arguments">>) of
        nomatch -> plain;
        _ -> json
    end.

oa_choice(#{<<"index">> := I} = Ch, S0) ->
    Delta0 = maps:get(<<"delta">>, Ch, #{}),
    {Delta1, S1} =
        case is_map(Delta0) of
            false -> {Delta0, S0};
            true ->
                {D1, Sa} = lists:foldl(
                             fun(K, {D, Sx}) ->
                                     case D of
                                         #{K := T} when is_binary(T) ->
                                             {T1, Sy} = text({I, K}, T, plain, Sx),
                                             {D#{K => T1}, Sy};
                                         _ -> {D, Sx}
                                     end
                             end, {Delta0, S0}, [<<"content">>, <<"reasoning_content">>]),
                case D1 of
                    #{<<"tool_calls">> := TCs} when is_list(TCs) ->
                        {TCs1, Sb} = lists:mapfoldl(
                                       fun(#{<<"index">> := J, <<"function">> := #{<<"arguments">> := A} = Fn} = TC, Sx)
                                             when is_binary(A) ->
                                               {A1, Sy} = text({I, tool, J}, A, json, Sx),
                                               {TC#{<<"function">> => Fn#{<<"arguments">> => A1}}, Sy};
                                          (TC, Sx) -> {TC, Sx}
                                       end, Sa, TCs),
                        {D1#{<<"tool_calls">> => TCs1}, Sb};
                    _ -> {D1, Sa}
                end
        end,
    case maps:get(<<"finish_reason">>, Ch, null) of
        null -> {Ch#{<<"delta">> => Delta1}, S1};
        _ when is_map(Delta1) ->
            {Delta2, S2} = oa_flush(I, Delta1, S1),
            {Ch#{<<"delta">> => Delta2}, S2};
        _ -> {Ch, S1}
    end;
oa_choice(Ch, S) ->
    {Ch, S}.

%% 选项 I 结束：把暂存的尾巴拼进 delta
oa_flush(I, Delta0, #rs{carry = C} = S) ->
    Mine = [K || K <- maps:keys(C), element(1, K) =:= I],
    Delta = lists:foldl(
              fun({_, K} = Key, D) ->
                      case maps:get(Key, C) of
                          <<>> -> D;
                          Tail -> D#{K => <<(case D of #{K := X} when is_binary(X) -> X; _ -> <<>> end)/binary, Tail/binary>>}
                      end;
                 ({_, tool, J} = Key, D) ->
                      case maps:get(Key, C) of
                          <<>> -> D;
                          Tail ->
                              TCs = maps:get(<<"tool_calls">>, D, []),
                              TCs1 = case [X || #{<<"index">> := Jx} = X <- TCs, Jx =:= J] of
                                         [] -> TCs ++ [#{<<"index">> => J, <<"function">> => #{<<"arguments">> => Tail}}];
                                         _ -> [case X of
                                                   #{<<"index">> := J, <<"function">> := Fn} ->
                                                       X#{<<"function">> => Fn#{<<"arguments">> => <<(maps:get(<<"arguments">>, Fn, <<>>))/binary, Tail/binary>>}};
                                                   _ -> X
                                               end || X <- TCs]
                                     end,
                              D#{<<"tool_calls">> => TCs1}
                      end
              end, Delta0, Mine),
    {Delta, S#rs{carry = maps:without(Mine, C)}}.

%% 字段的一个分片：拼上暂存部分、还原、留下可能是占位符开头的尾巴
text(Field, Text, Mode, #rs{map = Map, carry = C} = S) ->
    Full = <<(maps:get(Field, C, <<>>))/binary, Text/binary>>,
    {Out, Keep} = split_tail(restore(Full, Map, Mode)),
    {Out, S#rs{carry = C#{Field => Keep}}}.

%% 末尾若是占位符前缀的一部分（如 "[["、"[[LG_SEC"、"[[LG_SECRET_12"、"[[LG_SECRET_12]"），留到下一片
split_tail(B) ->
    Max = byte_size(?PREFIX) + 12,
    From = max(0, byte_size(B) - Max),
    case binary:matches(B, <<"[[">>, [{scope, {From, byte_size(B) - From}}]) ++ last_bracket(B) of
        [] -> {B, <<>>};
        Ms ->
            Starts = lists:usort([P || {P, _} <- Ms]),
            case [P || P <- Starts, possible_prefix(binary:part(B, P, byte_size(B) - P))] of
                [P | _] -> {binary:part(B, 0, P), binary:part(B, P, byte_size(B) - P)};
                [] -> {B, <<>>}
            end
    end.

%% 单独一个 "[" 在末尾
last_bracket(B) when byte_size(B) > 0 ->
    case binary:last(B) of
        $[ -> [{byte_size(B) - 1, 1}];
        _ -> []
    end;
last_bracket(_) -> [].

possible_prefix(Tail) ->
    P = ?PREFIX,
    case byte_size(Tail) =< byte_size(P) of
        true -> binary:part(P, 0, byte_size(Tail)) =:= Tail;
        false ->
            case binary:part(Tail, 0, byte_size(P)) =:= P of
                true ->
                    Rest = binary:part(Tail, byte_size(P), byte_size(Tail) - byte_size(P)),
                    %% 数字，可能还差结尾的 "]]"
                    re:run(Rest, "^\\d{0,9}\\]?$") =/= nomatch;
                false -> false
            end
    end.
