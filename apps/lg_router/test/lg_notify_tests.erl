-module(lg_notify_tests).

-include_lib("eunit/include/eunit.hrl").

msg() ->
    #{event => budget, level => warning, title => <<"T">>, text => <<"X">>, ts => 1700000000123, data => #{a => 1}}.

webhook_test() ->
    {Url, B} = lg_notify:render(webhook, <<"https://h.test/x">>, undefined, msg()),
    ?assertEqual(<<"https://h.test/x">>, Url),
    ?assertMatch(#{<<"event">> := <<"budget">>, <<"level">> := <<"warning">>, <<"title">> := <<"T">>,
                   <<"data">> := #{<<"a">> := 1}}, json:decode(iolist_to_binary(B))).

feishu_test() ->
    {_, B0} = lg_notify:render(feishu, <<"https://open.feishu.cn/hook/abc">>, undefined, msg()),
    ?assertEqual(#{<<"msg_type">> => <<"text">>, <<"content">> => #{<<"text">> => <<"[LiteGate] T\nX">>}},
                 json:decode(iolist_to_binary(B0))),
    {_, B} = lg_notify:render(feishu, <<"https://open.feishu.cn/hook/abc">>, <<"sec">>, msg()),
    #{<<"timestamp">> := <<"1700000000">>, <<"sign">> := Sign} = json:decode(iolist_to_binary(B)),
    ?assertEqual(base64:encode(crypto:mac(hmac, sha256, <<"1700000000\nsec">>, <<>>)), Sign).

dingtalk_test() ->
    {Url, B} = lg_notify:render(dingtalk, <<"https://oapi.dingtalk.com/robot/send?access_token=t">>, <<"sec">>, msg()),
    Sign = base64:encode(crypto:mac(hmac, sha256, <<"sec">>, <<"1700000000123\nsec">>)),
    ?assertEqual(<<"https://oapi.dingtalk.com/robot/send?access_token=t&timestamp=1700000000123&sign=",
                   (uri_string:quote(Sign))/binary>>, Url),
    ?assertMatch(#{<<"msgtype">> := <<"text">>, <<"text">> := #{<<"content">> := <<"[LiteGate] T\nX">>}},
                 json:decode(iolist_to_binary(B))).

wecom_test() ->
    {Url, B} = lg_notify:render(wecom, <<"https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=k">>, undefined, msg()),
    ?assertEqual(<<"https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=k">>, Url),
    ?assertMatch(#{<<"msgtype">> := <<"text">>}, json:decode(iolist_to_binary(B))).
