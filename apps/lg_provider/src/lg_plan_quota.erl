%% @doc 订阅套餐额度查询适配器（MiniMax Token Plan、智谱 GLM Coding Plan）。
%%
%% 统一返回 #{level, windows := [#{name, used_pct, resets_at}]}：used_pct 为已用百分比（0–100），
%% resets_at 为该窗口重置时刻（毫秒时间戳）。查询主机取凭证 base_url 的主机。
%% - minimax：GET {scheme}://{host}/v1/token_plan/remains，取 model_name = general 的 5 小时与周窗口
%% - glm：GET {scheme}://{host}/api/monitor/usage/quota/limit（控制台所用接口），取 TOKENS_LIMIT 窗口
%% - kimi：Kimi Code 会员，GET {scheme}://{host}/coding/v1/usages；limits[] 为各时间窗口（如 300 分钟 = 5h），
%%   顶层 usage 为周窗口。字段参考 magpie（internal/provider/planquota.go readKimiCode），数字可能是字符串
-module(lg_plan_quota).

-include_lib("lg_core/include/lg_core.hrl").

-export([kinds/0, url/2, parse/2, fetch/3]).

-type kind() :: minimax | glm | kimi.
-type window() :: #{name := binary(), used_pct := number(), resets_at := non_neg_integer() | null}.
-type quota() :: #{level := binary() | null, windows := [window()]}.
-export_type([kind/0, window/0, quota/0]).

-spec kinds() -> [binary()].
kinds() -> [<<"minimax">>, <<"glm">>, <<"kimi">>].

-spec url(kind(), binary()) -> binary().
url(Kind, BaseUrl) ->
    #{scheme := S, host := H} = P = uri_string:parse(BaseUrl),
    Port = case P of #{port := N} -> [":", integer_to_binary(N)]; _ -> [] end,
    Path = case Kind of
               minimax -> <<"/v1/token_plan/remains">>;
               glm -> <<"/api/monitor/usage/quota/limit">>;
               kimi -> <<"/coding/v1/usages">>
           end,
    iolist_to_binary([S, "://", H, Port, Path]).

-spec parse(kind(), iodata()) -> {ok, quota()} | {error, binary()}.
parse(Kind, Body) ->
    try json:decode(iolist_to_binary(Body)) of
        J -> parse_json(Kind, J)
    catch
        error:_ -> {error, <<"invalid JSON">>}
    end.

%% @doc 查询额度。Cred 必须带 Key。
-spec fetch(kind(), #lg_credential{}, timeout()) -> {ok, quota()} | {error, binary()}.
fetch(Kind, #lg_credential{base_url = Base, api_key_enc = Enc}, Timeout) ->
    case Enc =/= undefined andalso lg_crypto:decrypt(Enc) of
        {ok, Key} ->
            H = [{<<"authorization">>, <<"Bearer ", Key/binary>>}, {<<"accept">>, <<"application/json">>}],
            case lg_http:request(<<"GET">>, url(Kind, Base), H, <<>>, Timeout, #{api => true}) of
                {ok, _, _, Body} -> parse(Kind, Body);
                {error, {http_error, S, _, B}} ->
                    {error, iolist_to_binary(["HTTP ", integer_to_binary(S), ": ", truncate(B)])};
                {error, R} ->
                    {error, iolist_to_binary(io_lib:format("~0p", [R]))}
            end;
        false -> {error, <<"credential has no API key">>};
        {error, _} -> {error, <<"credential key cannot be decrypted">>}
    end.

%%====================================================================
%% 内部函数
%%====================================================================

parse_json(minimax, #{<<"model_remains">> := L}) when is_list(L) ->
    case [M || #{<<"model_name">> := <<"general">>} = M <- L] ++ L of
        [M | _] ->
            W = [window(<<"5h">>, M, <<"current_interval_remaining_percent">>, <<"end_time">>),
                 window(<<"week">>, M, <<"current_weekly_remaining_percent">>, <<"weekly_end_time">>)],
            {ok, #{level => null, windows => [X || X <- W, X =/= skip]}};
        [] ->
            {error, <<"no quota entries">>}
    end;
parse_json(minimax, #{<<"base_resp">> := #{<<"status_msg">> := Msg}}) ->
    {error, Msg};
parse_json(glm, #{<<"success">> := true, <<"data">> := #{<<"limits">> := L} = D}) when is_list(L) ->
    W = [#{name => glm_name(Lim), used_pct => num(maps:get(<<"percentage">>, Lim, 0)),
           resets_at => maps:get(<<"nextResetTime">>, Lim, null)}
         || #{<<"type">> := <<"TOKENS_LIMIT">>} = Lim <- L],
    {ok, #{level => maps:get(<<"level">>, D, null), windows => W}};
parse_json(glm, #{<<"msg">> := Msg}) when is_binary(Msg) ->
    {error, Msg};
parse_json(kimi, #{} = J) when is_map_key(<<"usage">>, J); is_map_key(<<"limits">>, J) ->
    Limits = [kimi_window(kimi_name(maps:get(<<"window">>, L, #{})), maps:get(<<"detail">>, L, #{}))
              || L <- list(maps:get(<<"limits">>, J, [])), is_map(L)],
    Week = case maps:get(<<"usage">>, J, null) of
               U when is_map(U) -> [kimi_window(<<"week">>, U)];
               _ -> []
           end,
    {ok, #{level => null, windows => [W || W <- Limits ++ Week, W =/= skip]}};
parse_json(_, _) ->
    {error, <<"unexpected response">>}.

%% 窗口时长：{duration, timeUnit} → 5h / 1d / 30m
kimi_name(#{<<"duration">> := D0} = W) ->
    D = to_num(D0),
    Unit = maps:get(<<"timeUnit">>, W, <<>>),
    {N, U} = case {binary:match(Unit, <<"MINUTE">>), binary:match(Unit, <<"HOUR">>), binary:match(Unit, <<"DAY">>)} of
                 {{_, _}, _, _} when D rem 1440 =:= 0, D > 0 -> {D div 1440, <<"d">>};
                 {{_, _}, _, _} when D rem 60 =:= 0, D > 0 -> {D div 60, <<"h">>};
                 {{_, _}, _, _} -> {D, <<"m">>};
                 {_, {_, _}, _} -> {D, <<"h">>};
                 {_, _, {_, _}} -> {D, <<"d">>};
                 _ -> {D, <<"">>}
             end,
    <<(integer_to_binary(round(N)))/binary, U/binary>>;
kimi_name(_) ->
    <<"window">>.

%% 已用比例：used / limit（没有 used 时为 limit - remaining）；重置时刻取 resetTime / resetAt / reset_at / reset_time
kimi_window(Name, D) when is_map(D) ->
    Limit = to_num(maps:get(<<"limit">>, D, 0)),
    Used = case maps:find(<<"used">>, D) of
               {ok, U} -> to_num(U);
               error -> Limit - to_num(maps:get(<<"remaining">>, D, Limit))
           end,
    case Limit > 0 of
        true ->
            Reset = hd([T || K <- [<<"resetTime">>, <<"resetAt">>, <<"reset_at">>, <<"reset_time">>],
                             T <- [iso_ms(maps:get(K, D, null))], T =/= null] ++ [null]),
            #{name => Name, used_pct => num(Used / Limit * 100), resets_at => Reset};
        false -> skip
    end;
kimi_window(_, _) ->
    skip.

to_num(N) when is_number(N) -> N;
to_num(B) when is_binary(B) ->
    case string:to_float(B) of
        {F, <<>>} -> F;
        _ -> case string:to_integer(B) of {I, <<>>} -> I; _ -> 0 end
    end;
to_num(_) -> 0.

iso_ms(B) when is_binary(B), B =/= <<>> ->
    try calendar:rfc3339_to_system_time(binary_to_list(B), [{unit, millisecond}])
    catch _:_ -> null
    end;
iso_ms(_) -> null.

list(L) when is_list(L) -> L;
list(_) -> [].

window(Name, M, RemainKey, EndKey) ->
    case maps:get(RemainKey, M, null) of
        R when is_number(R) ->
            #{name => Name, used_pct => max(0, min(100, 100 - R)), resets_at => maps:get(EndKey, M, null)};
        _ ->
            skip
    end.

%% unit：3 = 小时，4 = 天，5 = 月，6 = 周（未知单位保留原值）
glm_name(Lim) ->
    N = integer_to_binary(maps:get(<<"number">>, Lim, 1)),
    U = case maps:get(<<"unit">>, Lim, 0) of
            3 -> <<"h">>;
            4 -> <<"d">>;
            5 -> <<"mo">>;
            6 -> <<"w">>;
            X -> <<"u", (integer_to_binary(X))/binary>>
        end,
    <<N/binary, U/binary>>.

num(N) when is_number(N) -> max(0, min(100, N));
num(_) -> 0.

truncate(B) when byte_size(B) > 200 -> <<(binary:part(B, 0, 200))/binary, "...">>;
truncate(B) -> B.
