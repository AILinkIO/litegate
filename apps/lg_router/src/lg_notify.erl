%% @doc 告警通知渠道：按类型渲染消息并发送。
%%
%% - webhook：POST JSON {event, level, title, text, ts, data}
%% - feishu：群机器人文本消息；有密钥时带 timestamp + sign（HmacSHA256(key = "ts\nsecret", "")）
%% - dingtalk：群机器人文本消息；有密钥时 URL 追加 timestamp（毫秒）与 sign（HmacSHA256(secret, "ts\nsecret")）
%% - wecom：企业微信群机器人文本消息
%% 机器人接口出错时多返回 200 + 错误码（feishu code、dingtalk / wecom errcode），也算发送失败。
-module(lg_notify).

-include_lib("lg_core/include/lg_core.hrl").

-export([render/4, send/2]).

-type message() :: #{event := atom(), level := info | warning | critical, title := binary(), text := binary(),
                     ts := non_neg_integer(), data => map()}.
-export_type([message/0]).

%% @doc 渲染请求：{Url, Body}（Now 为毫秒时间戳，签名用）。
-spec render(atom(), binary(), binary() | undefined, message()) -> {binary(), iodata()}.
render(webhook, Url, _Secret, #{event := E, level := L, title := T, text := X, ts := Ts} = M) ->
    {Url, json:encode(#{<<"event">> => E, <<"level">> => L, <<"title">> => T, <<"text">> => X,
                        <<"ts">> => Ts, <<"data">> => maps:get(data, M, #{})})};
render(feishu, Url, Secret, M) ->
    Body = #{<<"msg_type">> => <<"text">>, <<"content">> => #{<<"text">> => plain(M)}},
    Signed = case Secret of
                 S when is_binary(S), S =/= <<>> ->
                     Ts = integer_to_binary(maps:get(ts, M) div 1000),
                     Sign = base64:encode(crypto:mac(hmac, sha256, <<Ts/binary, "\n", S/binary>>, <<>>)),
                     Body#{<<"timestamp">> => Ts, <<"sign">> => Sign};
                 _ -> Body
             end,
    {Url, json:encode(Signed)};
render(dingtalk, Url, Secret, M) ->
    Body = json:encode(#{<<"msgtype">> => <<"text">>, <<"text">> => #{<<"content">> => plain(M)}}),
    case Secret of
        S when is_binary(S), S =/= <<>> ->
            Ts = integer_to_binary(maps:get(ts, M)),
            Sign = base64:encode(crypto:mac(hmac, sha256, S, <<Ts/binary, "\n", S/binary>>)),
            Sep = case binary:match(Url, <<"?">>) of nomatch -> <<"?">>; _ -> <<"&">> end,
            {<<Url/binary, Sep/binary, "timestamp=", Ts/binary, "&sign=", (uri_string:quote(Sign))/binary>>, Body};
        _ ->
            {Url, Body}
    end;
render(wecom, Url, _Secret, M) ->
    {Url, json:encode(#{<<"msgtype">> => <<"text">>, <<"text">> => #{<<"content">> => plain(M)}})}.

%% @doc 发送到渠道（同步）。
-spec send(#lg_channel{}, message()) -> ok | {error, binary()}.
send(#lg_channel{type = Type, url_enc = UrlEnc, secret_enc = SecEnc}, Msg) ->
    case {decrypt(UrlEnc), decrypt(SecEnc)} of
        {{ok, Url}, {ok, Secret}} ->
            {ReqUrl, Body} = render(Type, Url, Secret, Msg),
            H = [{<<"content-type">>, <<"application/json; charset=utf-8">>}],
            case lg_http:request(<<"POST">>, ReqUrl, H, Body, 10000) of
                {ok, _, _, Resp} -> check(Type, Resp);
                {error, {http_error, S, _, B}} ->
                    {error, iolist_to_binary(["HTTP ", integer_to_binary(S), ": ", truncate(B)])};
                {error, R} ->
                    {error, iolist_to_binary(io_lib:format("~0p", [R]))}
            end;
        _ ->
            {error, <<"channel secret cannot be decrypted">>}
    end.

%%====================================================================
%% 内部函数
%%====================================================================

plain(#{title := T, text := X}) ->
    <<"[LiteGate] ", T/binary, "\n", X/binary>>.

check(webhook, _Resp) ->
    ok;
check(Type, Resp) ->
    Key = case Type of feishu -> <<"code">>; _ -> <<"errcode">> end,
    try json:decode(Resp) of
        #{Key := 0} -> ok;
        #{<<"StatusCode">> := 0} -> ok;                    %% 飞书旧版返回
        #{Key := C} = J -> {error, iolist_to_binary(io_lib:format("~p: ~ts", [C, msg(J)]))};
        _ -> ok
    catch
        error:_ -> ok
    end.

msg(J) ->
    case maps:get(<<"msg">>, J, maps:get(<<"errmsg">>, J, <<>>)) of
        B when is_binary(B) -> B;
        _ -> <<>>
    end.

decrypt(undefined) -> {ok, undefined};
decrypt(Enc) -> lg_crypto:decrypt(Enc).

truncate(B) when byte_size(B) > 200 -> <<(binary:part(B, 0, 200))/binary, "...">>;
truncate(B) -> B.
