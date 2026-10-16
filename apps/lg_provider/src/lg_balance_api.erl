%% @doc 按量付费 Key 的余额查询适配器（纯函数 url/2、parse/2 便于测试，fetch/3 发请求）。
%%
%% 统一返回 #{amount := number(), currency := binary(), details := [#{currency, amount}]}：
%% amount / currency 为主余额（多币种时取第一个非零的），details 为各币种明细。
%% 接口与字段参考 magpie（internal/provider/balance.go），均为 GET + Authorization: Bearer <key>：
%% - deepseek：{scheme}://{host}/user/balance → balance_infos[].total_balance（字符串或数字）与 currency
%% - moonshot：{scheme}://{host}/v1/users/me/balance → data.available_balance（api.moonshot.cn 为人民币，.ai 为美元）
%% - openrouter：https://openrouter.ai/api/v1/credits → data.total_credits - data.total_usage（美元）
%% - newapi：{scheme}://{host}/api/usage/token（New API / One API 中转站，用 API Key）→ data.total_available / 500000（美元）
-module(lg_balance_api).

-include_lib("lg_core/include/lg_core.hrl").

-export([kinds/0, suggest/1, url/2, parse/3, fetch/3]).

-type kind() :: deepseek | moonshot | openrouter | newapi.
-type balance() :: #{amount := number(), currency := binary(), details := [#{currency := binary(), amount := number()}]}.
-export_type([kind/0, balance/0]).

-define(NEWAPI_UNIT, 500000).

-spec kinds() -> [binary()].
kinds() -> [<<"deepseek">>, <<"moonshot">>, <<"openrouter">>, <<"newapi">>].

%% @doc 按凭证地址建议余额查询类型（控制台创建凭证时提示）。
-spec suggest(binary()) -> binary() | null.
suggest(BaseUrl) ->
    case catch uri_string:parse(BaseUrl) of
        #{host := H} ->
            case string:lowercase(H) of
                <<"api.deepseek.com">> -> <<"deepseek">>;
                <<"api.moonshot.cn">> -> <<"moonshot">>;
                <<"api.moonshot.ai">> -> <<"moonshot">>;
                <<"openrouter.ai">> -> <<"openrouter">>;
                _ -> null
            end;
        _ -> null
    end.

-spec url(kind(), binary()) -> binary().
url(openrouter, _BaseUrl) ->
    <<"https://openrouter.ai/api/v1/credits">>;
url(Kind, BaseUrl) ->
    #{scheme := S, host := H} = P = uri_string:parse(BaseUrl),
    Port = case P of #{port := N} -> [":", integer_to_binary(N)]; _ -> [] end,
    Path = case Kind of
               deepseek -> <<"/user/balance">>;
               moonshot -> <<"/v1/users/me/balance">>;
               newapi -> <<"/api/usage/token">>
           end,
    iolist_to_binary([S, "://", H, Port, Path]).

%% @doc 解析响应体；BaseUrl 用于判断币种（Kimi 国内 / 国际）。
-spec parse(kind(), iodata(), binary()) -> {ok, balance()} | {error, binary()}.
parse(Kind, Body, BaseUrl) ->
    try json:decode(iolist_to_binary(Body)) of
        J -> parse_json(Kind, J, BaseUrl)
    catch
        error:_ -> {error, <<"invalid JSON">>}
    end.

parse_json(deepseek, #{<<"balance_infos">> := Infos}, _) when is_list(Infos) ->
    Details = [#{currency => maps:get(<<"currency">>, I, <<"CNY">>), amount => num(maps:get(<<"total_balance">>, I, 0))}
               || I <- Infos, is_map(I)],
    %% DeepSeek 返回的币种顺序会变：非零在前，再按币种排序
    Sorted = lists:sort(fun(#{amount := A, currency := CA}, #{amount := B, currency := CB}) ->
                                {A == 0, CA} =< {B == 0, CB}
                        end, Details),
    one(Sorted);
parse_json(moonshot, #{<<"data">> := #{<<"available_balance">> := B}}, BaseUrl) ->
    Cur = case binary:match(BaseUrl, <<"moonshot.cn">>) of nomatch -> <<"USD">>; _ -> <<"CNY">> end,
    one([#{currency => Cur, amount => num(B)}]);
parse_json(openrouter, #{<<"data">> := #{<<"total_credits">> := T} = D}, _) ->
    one([#{currency => <<"USD">>, amount => num(T) - num(maps:get(<<"total_usage">>, D, 0))}]);
parse_json(newapi, #{<<"data">> := #{<<"total_available">> := A}}, _) ->
    one([#{currency => <<"USD">>, amount => num(A) / ?NEWAPI_UNIT}]);
parse_json(_, #{<<"success">> := false, <<"message">> := M}, _) when is_binary(M) ->
    {error, M};
parse_json(_, #{<<"error">> := #{<<"message">> := M}}, _) when is_binary(M) ->
    {error, M};
parse_json(_, _, _) ->
    {error, <<"unexpected response">>}.

one([]) -> {error, <<"no balance entries">>};
one([#{amount := A, currency := C} | _] = Details) -> {ok, #{amount => A, currency => C, details => Details}}.

num(N) when is_number(N) -> N;
num(B) when is_binary(B) ->
    case string:to_float(B) of
        {F, <<>>} -> F;
        _ -> case string:to_integer(B) of {I, <<>>} -> I; _ -> 0 end
    end;
num(_) -> 0.

%% @doc 查询余额。Cred 必须带 Key。
-spec fetch(kind(), #lg_credential{}, timeout()) -> {ok, balance()} | {error, binary()}.
fetch(Kind, #lg_credential{base_url = Base, api_key_enc = Enc, headers = Extra}, Timeout) ->
    case Enc =/= undefined andalso lg_crypto:decrypt(Enc) of
        {ok, Key} ->
            H = [{<<"authorization">>, <<"Bearer ", Key/binary>>}, {<<"accept">>, <<"application/json">>} | Extra],
            case lg_http:request(<<"GET">>, url(Kind, Base), H, <<>>, Timeout, #{api => true}) of
                {ok, _, _, Body} -> parse(Kind, Body, Base);
                {error, {http_error, S, _, B}} ->
                    {error, iolist_to_binary(["HTTP ", integer_to_binary(S), ": ", truncate(B)])};
                {error, R} ->
                    {error, iolist_to_binary(io_lib:format("~0p", [R]))}
            end;
        false -> {error, <<"credential has no API key">>};
        {error, _} -> {error, <<"credential key cannot be decrypted">>}
    end.

truncate(B) when byte_size(B) > 200 -> <<(binary:part(B, 0, 200))/binary, "...">>;
truncate(B) -> B.
