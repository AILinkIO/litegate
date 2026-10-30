%% @doc 上游错误分类与客户端错误响应。
%%
%% 分类规则沿用 beamai_llm_error：429 限流、5xx 服务端错误、网络/超时可重试（可回退），
%% 401/403 鉴权与其余 4xx 不重试。另外细分出两类可回退的额度错误（冷却时长不同，见 lg_cooldown）：
%%   credit  余额不足（402、insufficient_quota、余额不足 …）
%%   quota   套餐 / 时间窗口额度用尽（usage limit、限额已用完 …），reset_at 为解析出的重置时刻
%% 上游响应体超限（too_large）记为 server 但不重试。
%% 5xx 一律是 server（中转站的「负载已达上限」说的是负载），只有上游明确的额度错误码才算 quota。
-module(lg_llm_error).

-export([classify/1, retryable/1, to_client/3, render/4]).
-export([reset_at/2]).

%% client_closed：客户端在网关拿到上游回复前断开（T20，网关内部产生，status 499，不回退）
-type kind() :: rate_limit | credit | quota | unserved | concurrency | server | auth | client | timeout | network | internal
              | client_closed.
-define(MAX_RESET_AHEAD_MS, 8 * 24 * 3600 * 1000).
-type error() :: #{kind := kind(),
                   status := pos_integer(),
                   message := binary(),
                   retryable := boolean(),
                   retry_after_ms := non_neg_integer() | undefined,
                   sent => map(),                       %% 内部学习用：本次已发给上游的请求体（离开 lg_provider 前移除）
                   reset_at => non_neg_integer() | undefined,
                   upstream := #{status := pos_integer(), headers := list(),
                                 body := binary()} | undefined}.
-export_type([error/0, kind/0]).

-spec classify(term()) -> error().
classify({http_error, Status, Headers, Body}) ->
    Kind = kind(Status, Body),
    Message = upstream_message(Body, Status),
    E = #{kind => Kind,
          status => Status,
          message => Message,
          retryable => lists:member(Kind, [rate_limit, credit, quota, unserved, server]),
          retry_after_ms => retry_after_ms(Headers),
          upstream => #{status => Status, headers => Headers, body => Body}},
    case Kind of
        quota -> E#{reset_at => reset_at(Body, lg_time:now_ms())};
        _ -> E
    end;
classify({not_api_reply, Body}) ->
    Snippet = case byte_size(Body) of
                  0 -> <<"(empty body)">>;
                  N when N > 200 -> <<(binary:part(Body, 0, 200))/binary, "...">>;
                  _ -> Body
              end,
    mk(server, 502, <<"Upstream returned a non-API response: ", (sanitize(Snippet))/binary>>, true);
classify(timeout) ->
    mk(timeout, 504, <<"Upstream timeout">>, true);
%% 开流后的分级超时（lg_http）：仍按 timeout 处理（可回退；开流后由错误帧结束）
classify({timeout, first_byte}) ->
    mk(timeout, 504, <<"Upstream timeout (no data after response headers)">>, true);
classify({timeout, idle}) ->
    mk(timeout, 504, <<"Upstream stream idle timeout (no data within stream_idle_timeout_ms)">>, true);
classify({timeout, total}) ->
    mk(timeout, 504, <<"Upstream timeout (exceeded the total time limit)">>, true);
%% 响应体 / SSE 事件超过上限：上游异常，换候选多半同样很大，不重试不回退（也不冷却）
classify({too_large, Max}) ->
    mk(server, 502, fmt("Upstream response too large (limit ~b bytes)", [Max]), false);
classify({connect_failed, R}) ->
    mk(network, 502, fmt("Upstream connection failed: ~0p", [R]), true);
classify({request_failed, R}) ->
    mk(network, 502, fmt("Upstream request failed: ~0p", [R]), true);
classify({bad_response, R}) ->
    mk(server, 502, fmt("Invalid upstream response: ~0p", [R]), true);
classify({unsupported, What}) ->
    mk(client, 400, fmt("Unsupported by target protocol: ~ts", [What]), false);
classify(Other) ->
    mk(internal, 500, fmt("~0p", [Other]), false).

-spec retryable(error()) -> boolean().
retryable(#{retryable := R}) -> R.

%% @doc 按客户端协议格式渲染错误，返回 {Status, JsonBody}。
%% SameProtocol 且为上游 4xx 时原样转发上游错误体（保留上游的错误码与参数信息）。
-spec to_client(openai | anthropic | responses, boolean(), error()) -> {pos_integer(), iodata()}.
to_client(_Format, true, #{kind := K, upstream := #{status := S, body := B}})
  when K =:= client; K =:= auth; K =:= rate_limit; K =:= credit; K =:= quota; K =:= unserved ->
    {S, B};
to_client(Format, _SameProtocol, #{kind := K, status := S, message := M}) ->
    {S, render(Format, S, type_of(Format, K, S), M)}.

-spec render(openai | anthropic | responses, pos_integer(), binary(), binary()) -> iodata().
render(responses, Status, Type, Message) ->
    render(openai, Status, Type, Message);
render(openai, _Status, Type, Message) ->
    json:encode(#{<<"error">> => #{<<"message">> => Message, <<"type">> => Type,
                                   <<"code">> => null, <<"param">> => null}});
render(anthropic, _Status, Type, Message) ->
    json:encode(#{<<"type">> => <<"error">>,
                  <<"error">> => #{<<"type">> => Type, <<"message">> => Message}}).

%%====================================================================
%% 内部函数
%%====================================================================

%%--------------------------------------------------------------------
%% 错误类型
%%--------------------------------------------------------------------

kind(Status, Body) ->
    %% 小写并去掉 JSON 冒号两侧空白，便于按错误码匹配
    Text = normalize(Body),
    if Status =:= 402 -> credit;
       Status >= 500 ->
           case has_any(Text, quota_codes()) of
               true -> quota;
               false -> server
           end;
       Status =:= 401; Status =:= 403 ->
           %% 部分上游以 403 表示余额不足 / 套餐用尽 / 该模型不可用（#1235）
           case {has_any(Text, credit_words()), has_any(Text, quota_words()), has_any(Text, unserved_words())} of
               {true, _, _} -> credit;
               {_, true, _} -> quota;
               {_, _, true} -> unserved;
               _ -> auth
           end;
       Status >= 400 ->
           case {has_any(Text, credit_words()), has_any(Text, quota_words() ++ quota_codes()), has_any(Text, unserved_words())} of
               {true, _, _} -> credit;
               {_, true, _} -> quota;
               {_, _, true} when Status =:= 400; Status =:= 404; Status =:= 422 -> unserved;
               _ when Status =:= 429 -> rate_limit;
               _ -> client
           end;
       true -> client
    end.

normalize(Body) ->
    Text = words_text(Body),
    try iolist_to_binary(re:replace(string:lowercase(Text), "\"\\s*:\\s*", "\":", [global, unicode]))
    catch _:_ -> iolist_to_binary(re:replace(Text, "\"\\s*:\\s*", "\":", [global]))
    end.

%% JSON 错误体常把非 ASCII 转义成 \uXXXX（Python 的 json.dumps 默认行为）：
%% 把解码结果附在原文之后，中文措辞与重置时刻才能被匹配（对照 magpie wordsOf）。
words_text(Body) ->
    case binary:match(Body, <<"\\u">>) of
        nomatch -> Body;
        _ -> <<Body/binary, $\n, (unescape_unicode(Body))/binary>>
    end.

unescape_unicode(B) ->
    Pair = "\\\\u([dD][89aAbB][0-9a-fA-F]{2})\\\\u([dD][cdefCDEF][0-9a-fA-F]{2})",
    One = "\\\\u([0-9a-fA-F]{4})",
    Step1 = try re:replace(B, Pair,
                           fun(_, [H, L]) -> cp((hex(H) - 16#D800) * 16#400 + (hex(L) - 16#DC00) + 16#10000) end,
                           [global, {return, binary}])
            catch _:_ -> B end,
    try re:replace(Step1, One, fun(_, [H]) -> cp(hex(H)) end, [global, {return, binary}])
    catch _:_ -> B end.

hex(B) ->
    binary_to_integer(B, 16).

cp(C) when is_integer(C), C >= 0, C =< 16#10FFFF, not (C >= 16#D800 andalso C =< 16#DFFF) ->
    unicode:characters_to_binary([C]);
cp(_) ->
    <<>>.

%% 匹配对象已转小写；错误措辞样本只使用真实上游返回的原文。
credit_words() ->
    [<<"insufficient_quota">>, <<"insufficient_balance">>, <<"insufficient balance">>,
     <<"credit balance is too low">>, <<"余额"/utf8>>, <<"欠费"/utf8>>, <<"充值"/utf8>>,
     <<"billing">>, <<"payment">>, <<"arrear">>, <<"overdue">>,
     %% MiniMax：1008 余额不足；GLM：1113 余额不足或无可用资源包
     <<"\"status_code\":1008">>, <<"\"code\":\"1113\"">>].

quota_words() ->
    [<<"usage limit">>, <<"usage_limit">>, <<"quota">>, <<"limit will reset">>,
     <<"out of budget">>, <<"budget exceeded">>, <<"budget exhausted">>,
     <<"exceeded your plan">>, <<"plan limit">>, <<"daily limit">>, <<"weekly limit">>, <<"monthly limit">>,
     <<"限额已用完"/utf8>>, <<"已用完"/utf8>>, <<"上限"/utf8>>, <<"额度"/utf8>>, <<"用量"/utf8>>,
     <<"套餐"/utf8>>, <<"配额"/utf8>>,
     %% GLM Coding Plan：1308 窗口用量上限、1310 周 / 月用量上限；MiniMax Token Plan：2056
     <<"\"code\":\"1308\"">>, <<"\"code\":\"1310\"">>, <<"\"code\":1308">>, <<"\"code\":1310">>,
     <<"\"status_code\":2056">>, <<"\"code\":2056">>].

%% 5xx 中只有这些明确的额度错误码才算 quota（「负载已达上限」等措辞是 server，不是 quota）；
%% `limit reached|` 是 Claude 官方订阅 "usage limit reached|<重置时间戳>" 的原文
quota_codes() ->
    [<<"usage_limit_reached">>, <<"resource_exhausted">>, <<"limit reached|">>].

%% 「该模型不可用」：套餐不含 / 已下架该模型，只冷却 {凭证, 模型}，凭证上的其他模型照常（magpie #1235）。
%% 只对 400 / 403 / 404 / 422 判定，且 credit / quota / 限流措辞优先。
unserved_words() ->
    [<<"model not found">>, <<"unknown model">>, <<"invalid model">>,
     <<"does not exist">>, <<"not available">>, <<"not entitled">>, <<"not enabled">>,
     <<"模型不存在"/utf8>>, <<"模型不可用"/utf8>>, <<"不支持的模型"/utf8>>, <<"无权限访问该模型"/utf8>>,
     <<"当前套餐不含"/utf8>>].

has_any(Text, Words) ->
    lists:any(fun(W) -> binary:match(Text, W) =/= nomatch end, Words).

%%--------------------------------------------------------------------
%% 重置时刻
%%--------------------------------------------------------------------

%% @doc 从额度错误体中解析重置时刻（毫秒）：先取字段 resets_at / reset_at / nextResetTime
%% （秒、毫秒或 ISO 8601），再取文本中「重置」「reset」紧邻的完整日期时间（带 UTC/GMT 偏移时按偏移，
%% 否则按 UTC+8）。只接受晚于 Now、且 8 天以内的时刻（重置时刻读错时不至于把凭证凉太久，对照 magpie longestQuota）。
-spec reset_at(binary(), non_neg_integer()) -> non_neg_integer() | undefined.
reset_at(Body, Now) ->
    Field = try json:decode(Body) of
                J -> find_field(J)
            catch error:_ -> undefined
            end,
    Candidates = [T || T <- [field_time(Field), text_time(Body)],
                       is_integer(T), T > Now, T =< Now + ?MAX_RESET_AHEAD_MS],
    case Candidates of
        [T | _] -> T;
        [] -> undefined
    end.

find_field(M) when is_map(M) ->
    Direct = [V || K <- [<<"resets_at">>, <<"reset_at">>, <<"nextResetTime">>, <<"next_reset_time">>,
                         <<"resetsAt">>, <<"resetAt">>],
                   V <- [maps:get(K, M, undefined)], V =/= undefined, V =/= null],
    case Direct of
        [V | _] -> V;
        [] -> first_defined([find_field(V) || V <- maps:values(M)])
    end;
find_field(L) when is_list(L) ->
    first_defined([find_field(V) || V <- L]);
find_field(_) ->
    undefined.

first_defined([]) -> undefined;
first_defined([undefined | R]) -> first_defined(R);
first_defined([V | _]) -> V.

field_time(N) when is_integer(N), N > 100000000000 -> N;          %% 毫秒
field_time(N) when is_integer(N), N > 1000000000 -> N * 1000;     %% 秒
field_time(N) when is_float(N) -> field_time(trunc(N));
field_time(B) when is_binary(B) ->
    case string:to_integer(B) of
        {N, <<>>} -> field_time(N);
        _ -> parse_datetime(B)
    end;
field_time(_) -> undefined.

%% 「重置」/「reset」前后 80 字节内的日期时间（在原文 + \u 解码文本上找，转义体也能命中）
text_time(Body) ->
    Text = words_text(Body),
    Lower = try string:lowercase(Text) catch _:_ -> Text end,
    Spots = [P || W <- [<<"重置"/utf8>>, <<"reset">>], {P, _} <- binary:matches(Lower, W)],
    first_defined([near_time(Text, P) || P <- Spots]).

near_time(Body, Pos) ->
    From = max(0, Pos - 80),
    Len = min(byte_size(Body) - From, 160 + (Pos - From)),
    parse_datetime(binary:part(Body, From, Len)).

parse_datetime(Text) ->
    Re = "(\\d{4})-(\\d{1,2})-(\\d{1,2})[T ](\\d{1,2}):(\\d{2})(?::(\\d{2}))?(?:\\.\\d+)?\\s*"
         "(Z|(?:UTC|GMT)?\\s*([+-])(\\d{1,2})(?::?(\\d{2}))?|(?:UTC|GMT)(?!\\s*[+-]))?",
    case catch re:run(Text, Re, [{capture, all, binary}]) of
        {match, [_, Y, Mo, D, H, Mi | Rest]} ->
            case offset_min(Rest) of
                undefined -> undefined;   %% 「UTC / GMT」后没有偏移：多半是被截断的文本，不当作默认 +8
                OffsetMin ->
                    S = case Rest of [Sec | _] when Sec =/= <<>> -> int(Sec); _ -> 0 end,
                    try
                        Secs = calendar:datetime_to_gregorian_seconds(
                                 {{int(Y), int(Mo), int(D)}, {int(H), int(Mi), S}})
                                - 62167219200 - OffsetMin * 60,
                        Secs * 1000
                    catch error:_ -> undefined
                    end
            end;
        _ ->
            undefined
    end.

%% Rest 形状 [Sec, Offset, Sign, OffH, OffM]（可选组不参与时为 <<>>）
offset_min([_, <<"Z">> | _]) -> 0;
offset_min([_, <<"UTC">> | _]) -> undefined;
offset_min([_, <<"GMT">> | _]) -> undefined;
offset_min([_, <<>> | _]) -> 8 * 60;
offset_min([_, _, <<S, _/binary>>, OH | More]) when S =:= $+; S =:= $- ->
    OM = case More of [X] when X =/= <<>> -> int(X); _ -> 0 end,
    (case S of $- -> -1; _ -> 1 end) * (int(OH) * 60 + OM);
offset_min(_) -> 8 * 60.

int(B) -> binary_to_integer(B).

%% 错误信息中的非 UTF-8 字节替换为 ?
sanitize(B) ->
    case unicode:characters_to_binary(B) of
        R when is_binary(R) -> R;
        {_, Good, Rest} -> <<Good/binary, (binary:copy(<<"?">>, min(byte_size(Rest), 8)))/binary>>
    end.

mk(Kind, Status, Message, Retryable) ->
    #{kind => Kind, status => Status, message => Message, retryable => Retryable,
      retry_after_ms => undefined, upstream => undefined}.

type_of(_, rate_limit, _) -> <<"rate_limit_error">>;
type_of(_, concurrency, _) -> <<"rate_limit_error">>;
type_of(openai, K, _) when K =:= credit; K =:= quota -> <<"insufficient_quota">>;
type_of(_, K, _) when K =:= credit; K =:= quota -> <<"rate_limit_error">>;
type_of(openai, unserved, _) -> <<"model_not_found">>;
type_of(_, unserved, _) -> <<"not_found_error">>;
type_of(_, auth, 403) -> <<"permission_error">>;
type_of(_, auth, _) -> <<"authentication_error">>;
type_of(_, client, 404) -> <<"not_found_error">>;
type_of(_, client, _) -> <<"invalid_request_error">>;
type_of(openai, timeout, _) -> <<"timeout">>;
type_of(anthropic, server, 529) -> <<"overloaded_error">>;
type_of(_, _, _) -> <<"api_error">>.

%% 两种协议的错误体都是 {"error": {"message": ...}}；取不到时用原文或状态码
upstream_message(Body, Status) ->
    try json:decode(Body) of
        #{<<"error">> := #{<<"message">> := M}} when is_binary(M) -> M;
        #{<<"error">> := M} when is_binary(M) -> M;
        #{<<"message">> := M} when is_binary(M) -> M;
        _ -> fallback_message(Body, Status)
    catch
        error:_ -> fallback_message(Body, Status)
    end.

fallback_message(<<>>, Status) -> fmt("Upstream returned HTTP ~b", [Status]);
fallback_message(Body, _) when byte_size(Body) =< 512 -> Body;
fallback_message(Body, _) -> <<(binary:part(Body, 0, 512))/binary, "...">>.

%% 仅支持整数秒形式的 Retry-After
retry_after_ms(Headers) ->
    case lists:keyfind(<<"retry-after">>, 1, Headers) of
        {_, V} ->
            case string:to_integer(string:trim(V)) of
                {N, <<>>} when N >= 0 -> N * 1000;
                _ -> undefined
            end;
        false ->
            undefined
    end.

fmt(F, A) ->
    unicode:characters_to_binary(io_lib:format(F, A)).
