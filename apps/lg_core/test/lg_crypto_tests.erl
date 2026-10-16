-module(lg_crypto_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

crypto_test_() ->
    {setup, fun lg_core_test_util:start/0, fun lg_core_test_util:stop/1,
     fun(Dir) ->
         [?_test(roundtrip()),
          ?_test(random_iv()),
          ?_test(tampered()),
          ?_test(malformed()),
          ?_test(key_file_persisted(Dir)),
          ?_test(password()),
          ?_test(token())]
     end}.

roundtrip() ->
    Plain = <<"sk-test-密钥"/utf8>>,
    Enc = lg_crypto:encrypt(Plain),
    ?assertMatch(<<"v1:", _/binary>>, Enc),
    ?assertEqual({ok, Plain}, lg_crypto:decrypt(Enc)).

random_iv() ->
    ?assertNotEqual(lg_crypto:encrypt(<<"x">>), lg_crypto:encrypt(<<"x">>)).

tampered() ->
    <<"v1:", B64/binary>> = lg_crypto:encrypt(<<"secret">>),
    Raw = base64:decode(B64),
    Last = binary:last(Raw),
    Bad = <<(binary:part(Raw, 0, byte_size(Raw) - 1))/binary, (Last bxor 1)>>,
    ?assertEqual({error, decrypt_failed},
                 lg_crypto:decrypt(<<"v1:", (base64:encode(Bad))/binary>>)).

malformed() ->
    ?assertEqual({error, unsupported_format}, lg_crypto:decrypt(<<"plain">>)),
    ?assertEqual({error, malformed}, lg_crypto:decrypt(<<"v1:!!!">>)),
    ?assertEqual({error, malformed}, lg_crypto:decrypt(<<"v1:", (base64:encode(<<"short">>))/binary>>)).

key_file_persisted(Dir) ->
    Path = filename:join(Dir, "secret.key"),
    {ok, Data} = file:read_file(Path),
    ?assertEqual(32, byte_size(base64:decode(Data))),
    {ok, #file_info{mode = Mode}} = file:read_file_info(Path),
    ?assertEqual(8#600, Mode band 8#777).

password() ->
    H = lg_crypto:hash_password(<<"hunter2">>),
    ?assertMatch(<<"pbkdf2-sha256$", _/binary>>, H),
    ?assert(lg_crypto:verify_password(<<"hunter2">>, H)),
    ?assertNot(lg_crypto:verify_password(<<"hunter3">>, H)),
    ?assertNot(lg_crypto:verify_password(<<"hunter2">>, <<"garbage">>)).

token() ->
    T = lg_crypto:random_token(<<"lgk-">>),
    ?assertMatch(<<"lgk-", _/binary>>, T),
    ?assertEqual(64, byte_size(lg_crypto:hash_token(T))),
    ?assertEqual(lg_crypto:hash_token(T), lg_crypto:hash_token(T)).
