%% @doc 加密与哈希。
%%
%% - 上游 Key：AES-256-GCM，密文格式 `v1:` ++ base64(IV:12 | Tag:16 | CipherText)
%% - 网关 Key / 登录 token：SHA-256 十六进制哈希（高熵随机值，无需加盐）
%% - 控制台密码：PBKDF2-HMAC-SHA256，`pbkdf2-sha256$Iter$Salt$Hash`（base64）
%%
%% 主密钥来源：环境变量 LITEGATE_ENCRYPTION_KEY（base64 编码的 32 字节）；
%% 未设置时使用 `data_dir/secret.key`，不存在则生成（权限 0600）。
%% 主密钥丢失将无法解密已存的上游 Key。
-module(lg_crypto).

-export([init/0,
         encrypt/1, decrypt/1,
         hash_token/1, random_token/1,
         hash_password/1, verify_password/2]).

-define(KEY_PT, {?MODULE, master_key}).
-define(AAD, <<"litegate">>).
-define(PBKDF2_ITER, 210000).

%% @doc 加载主密钥到 persistent_term，lg_core 启动时调用。
-spec init() -> ok | {error, term()}.
init() ->
    case load_key() of
        {ok, Key} -> persistent_term:put(?KEY_PT, Key);
        {error, _} = Err -> Err
    end.

-spec encrypt(binary()) -> binary().
encrypt(Plain) when is_binary(Plain) ->
    IV = crypto:strong_rand_bytes(12),
    {Cipher, Tag} = crypto:crypto_one_time_aead(aes_256_gcm, master_key(), IV,
                                                Plain, ?AAD, 16, true),
    <<"v1:", (base64:encode(<<IV/binary, Tag/binary, Cipher/binary>>))/binary>>.

-spec decrypt(binary()) -> {ok, binary()} | {error, term()}.
decrypt(<<"v1:", Enc/binary>>) ->
    try base64:decode(Enc) of
        <<IV:12/binary, Tag:16/binary, Cipher/binary>> ->
            case crypto:crypto_one_time_aead(aes_256_gcm, master_key(), IV,
                                             Cipher, ?AAD, Tag, false) of
                error -> {error, decrypt_failed};
                Plain -> {ok, Plain}
            end;
        _ ->
            {error, malformed}
    catch
        error:_ -> {error, malformed}
    end;
decrypt(_) ->
    {error, unsupported_format}.

-spec hash_token(binary()) -> binary().
hash_token(Token) ->
    binary:encode_hex(crypto:hash(sha256, Token), lowercase).

%% @doc 生成带前缀的随机 token，如 random_token(<<"lgk-">>)。
-spec random_token(binary()) -> binary().
random_token(Prefix) ->
    Rand = base64:encode(crypto:strong_rand_bytes(24), #{mode => urlsafe, padding => false}),
    <<Prefix/binary, Rand/binary>>.

-spec hash_password(binary()) -> binary().
hash_password(Password) ->
    Salt = crypto:strong_rand_bytes(16),
    Hash = pbkdf2(Password, Salt, ?PBKDF2_ITER),
    iolist_to_binary(["pbkdf2-sha256$", integer_to_binary(?PBKDF2_ITER), $$,
                      base64:encode(Salt), $$, base64:encode(Hash)]).

-spec verify_password(binary(), binary()) -> boolean().
verify_password(Password, Stored) ->
    try binary:split(Stored, <<"$">>, [global]) of
        [<<"pbkdf2-sha256">>, Iter, Salt, Hash] ->
            Expected = base64:decode(Hash),
            Actual = pbkdf2(Password, base64:decode(Salt), binary_to_integer(Iter)),
            crypto:hash_equals(Expected, Actual);
        _ ->
            false
    catch
        error:_ -> false
    end.

%%====================================================================
%% 内部函数
%%====================================================================

pbkdf2(Password, Salt, Iter) ->
    crypto:pbkdf2_hmac(sha256, Password, Salt, Iter, 32).

master_key() ->
    persistent_term:get(?KEY_PT).

load_key() ->
    case os:getenv("LITEGATE_ENCRYPTION_KEY") of
        V when V =:= false; V =:= "" -> load_key_file();
        V -> decode_key(list_to_binary(V), env)
    end.

load_key_file() ->
    Path = filename:join(lg_config:data_dir(), "secret.key"),
    case file:read_file(Path) of
        {ok, Data} ->
            decode_key(string:trim(Data), Path);
        {error, enoent} ->
            ok = filelib:ensure_dir(Path),
            Key = crypto:strong_rand_bytes(32),
            ok = file:write_file(Path, base64:encode(Key)),
            ok = file:change_mode(Path, 8#600),
            logger:warning("generated new master key at ~s; back it up, or set "
                           "LITEGATE_ENCRYPTION_KEY in production", [Path]),
            {ok, Key};
        {error, Reason} ->
            {error, {master_key, Path, Reason}}
    end.

decode_key(B64, Source) ->
    try base64:decode(B64) of
        <<Key:32/binary>> -> {ok, Key};
        _ -> {error, {master_key, Source, bad_length}}
    catch
        error:_ -> {error, {master_key, Source, bad_base64}}
    end.
