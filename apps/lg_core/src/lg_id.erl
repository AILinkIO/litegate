%% @doc ID 生成：前缀 + 时间有序的随机后缀，如 cred_01J...
-module(lg_id).

-export([new/1]).

-spec new(binary()) -> binary().
new(Prefix) ->
    %% 48 位毫秒时间 + 80 位随机数，base32 编码后按字典序即时间序
    Bin = <<(lg_time:now_ms()):48, (crypto:strong_rand_bytes(10))/binary>>,
    <<Prefix/binary, $_, (base32(Bin))/binary>>.

base32(Bin) ->
    << <<(alphabet(C))>> || <<C:5>> <= <<Bin/binary, 0:2>> >>.

%% Crockford base32（去掉 I L O U），ASCII 升序
alphabet(C) -> element(C + 1, {$0,$1,$2,$3,$4,$5,$6,$7,$8,$9,
                                $A,$B,$C,$D,$E,$F,$G,$H,$J,$K,$M,$N,$P,$Q,$R,$S,$T,$V,$W,$X,$Y,$Z}).
