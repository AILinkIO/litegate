%% @doc 多模态端点的上游适配：图片生成（/v1/images/generations）、语音合成（/v1/audio/speech）。
%%
%% 凭证 options.media_api 选择上游格式（默认 openai）：
%% - openai：OpenAI 兼容，透传到 {base}/images/generations（如 GLM cogview）
%% - minimax：MiniMax 私有格式 {base}/image_generation；size 换算为最接近的 aspect_ratio，
%%   response_format url / b64_json ↔ url / base64，响应 data.image_urls / image_base64 转回 OpenAI 格式
%% 用量：images = 生成张数（按目录定价 cost.image 计费）。
%%
%% 语音合成（返回音频二进制）：
%% - openai：透传到 {base}/audio/speech（如 GLM glm-tts），content-type 取上游响应头
%% - minimax：转换为 {base}/t2a_v2（voice_setting.voice_id / speed，audio_setting.format），
%%   响应 data.audio 为十六进制，解码为二进制；OpenAI 预置音色名（alloy 等）换成 MiniMax 默认音色
%% 用量：chars = 输入字符数（按 cost.tts 每百万字符计费）。
%%
%% 结构化决策（TypeSafe System One，如百炼 decision-model-preview、本地 Laya）：
%% 透传到 {base}/systemone（百炼 base 为 .../compatible-mode/v1，Laya 为 http://host:port/v1），
%% 只换 model；响应原样返回。用量：input = usage.input_tokens（不生成文本，没有输出 token）。
-module(lg_media).

-include_lib("lg_core/include/lg_core.hrl").

-export([minimax_error/2, images/2, speech/2, systemone/2, media_api/1, aspect_ratio/1]).

-define(OPENAI_VOICES, [<<"alloy">>, <<"ash">>, <<"ballad">>, <<"coral">>, <<"echo">>, <<"fable">>, <<"onyx">>,
                        <<"nova">>, <<"sage">>, <<"shimmer">>, <<"verse">>]).
-define(MINIMAX_DEFAULT_VOICE, <<"male-qn-qingse">>).

-define(RATIOS, [{<<"1:1">>, 1.0}, {<<"16:9">>, 16 / 9}, {<<"4:3">>, 4 / 3}, {<<"3:2">>, 3 / 2},
                 {<<"2:3">>, 2 / 3}, {<<"3:4">>, 3 / 4}, {<<"9:16">>, 9 / 16}, {<<"21:9">>, 21 / 9}]).

-spec media_api(#lg_credential{}) -> openai | minimax.
media_api(#lg_credential{options = #{media_api := <<"minimax">>}}) -> minimax;
media_api(_) -> openai.

%% @doc 图片生成。返回 OpenAI 格式的响应体与结果（usage.images = 张数）。
-spec images(map(), lg_provider:target()) -> {ok, iodata(), lg_provider:result()} | {error, lg_llm_error:error()}.
images(Req, #{credential := #lg_credential{protocol = openai, base_url = Base} = Cred} = Target) ->
    case media_api(Cred) of
        openai ->
            post(url(Base, <<"/images/generations">>), Req, Target, fun(J) -> {J, count(maps:get(<<"data">>, J, []))} end);
        minimax ->
            Format = case maps:get(<<"response_format">>, Req, <<"url">>) of
                         <<"b64_json">> -> <<"base64">>;
                         _ -> <<"url">>
                     end,
            Body = maps:filter(fun(_, V) -> V =/= null end,
                               #{<<"prompt">> => maps:get(<<"prompt">>, Req, <<>>),
                                 <<"n">> => maps:get(<<"n">>, Req, 1),
                                 <<"aspect_ratio">> => aspect_ratio(maps:get(<<"size">>, Req, null)),
                                 <<"response_format">> => Format}),
            post(url(Base, <<"/image_generation">>), Body, Target,
                 fun(J) -> minimax_images(J, Format) end)
    end;
images(_Req, _Target) ->
    {error, lg_llm_error:classify({unsupported, <<"images">>})}.

%% @doc 语音合成。返回音频二进制与结果（result 带 content_type，usage.chars = 输入字符数）。
-spec speech(map(), lg_provider:target()) -> {ok, binary(), lg_provider:result()} | {error, lg_llm_error:error()}.
speech(Req, #{credential := #lg_credential{protocol = openai, base_url = Base} = Cred,
              upstream_model := Model} = Target) ->
    Input = case maps:get(<<"input">>, Req, <<>>) of I when is_binary(I) -> I; _ -> <<>> end,
    Chars = string:length(Input),
    Format = case maps:get(<<"response_format">>, Req, null) of F when is_binary(F) -> F; _ -> <<"mp3">> end,
    case lg_provider:auth_headers(openai, Cred, openai, Target) of
        {ok, H0} ->
            H = H0 ++ Cred#lg_credential.headers,
            Timeout = lg_config:get(upstream_timeout_ms),
            Result = fun(CT) -> #{usage => (lg_usage:zero())#{chars => Chars}, text => <<>>, finish_reason => null,
                                  model => Model, id => <<>>, error => undefined, content_type => CT} end,
            case media_api(Cred) of
                openai ->
                    Body = json:encode(Req#{<<"model">> => Model}),
                    case lg_http:request(<<"POST">>, url(Base, <<"/audio/speech">>), H, Body, Timeout, #{api => true}) of
                        {ok, _, RespH, Audio} ->
                            CT = case lists:keyfind(<<"content-type">>, 1, RespH) of
                                     {_, V} -> V;
                                     false -> content_type(Format)
                                 end,
                            {ok, Audio, Result(CT)};
                        {error, R} ->
                            {error, lg_llm_error:classify(R)}
                    end;
                minimax ->
                    Voice = case maps:get(<<"voice">>, Req, null) of
                                V when is_binary(V), V =/= <<>> ->
                                    case lists:member(V, ?OPENAI_VOICES) of
                                        true -> ?MINIMAX_DEFAULT_VOICE;
                                        false -> V
                                    end;
                                _ -> ?MINIMAX_DEFAULT_VOICE
                            end,
                    Speed = case maps:get(<<"speed">>, Req, null) of S when is_number(S) -> S; _ -> 1 end,
                    MFormat = case Format of
                                  F2 when F2 =:= <<"wav">>; F2 =:= <<"flac">>; F2 =:= <<"pcm">> -> F2;
                                  _ -> <<"mp3">>
                              end,
                    Body = json:encode(#{<<"model">> => Model, <<"text">> => Input, <<"stream">> => false,
                                         <<"voice_setting">> => #{<<"voice_id">> => Voice, <<"speed">> => Speed},
                                         <<"audio_setting">> => #{<<"format">> => MFormat}}),
                    case lg_http:request(<<"POST">>, url(Base, <<"/t2a_v2">>), H, Body, Timeout, #{api => true}) of
                        {ok, _, _, RespBody} ->
                            try json:decode(RespBody) of
                                #{<<"base_resp">> := #{<<"status_code">> := C} = BR} when C =/= 0 ->
                                    {error, minimax_error(C, maps:get(<<"status_msg">>, BR, <<>>))};
                                #{<<"data">> := #{<<"audio">> := Hex}} when is_binary(Hex), Hex =/= <<>> ->
                                    {ok, binary:decode_hex(Hex), Result(content_type(MFormat))};
                                _ ->
                                    {error, lg_llm_error:classify({bad_response, no_audio})}
                            catch
                                error:_ -> {error, lg_llm_error:classify({bad_response, invalid_json})}
                            end;
                        {error, R} ->
                            {error, lg_llm_error:classify(R)}
                    end
            end;
        {error, R} ->
            {error, lg_llm_error:classify(R)}
    end;
speech(_Req, _Target) ->
    {error, lg_llm_error:classify({unsupported, <<"speech">>})}.

content_type(<<"wav">>) -> <<"audio/wav">>;
content_type(<<"flac">>) -> <<"audio/flac">>;
content_type(<<"pcm">>) -> <<"audio/pcm">>;
content_type(<<"opus">>) -> <<"audio/opus">>;
content_type(<<"aac">>) -> <<"audio/aac">>;
content_type(_) -> <<"audio/mpeg">>.

%% @doc OpenAI size（"1024x1536"）→ 最接近的 MiniMax aspect_ratio；无法解析时 1:1。
-spec aspect_ratio(term()) -> binary().
aspect_ratio(Size) when is_binary(Size) ->
    case binary:split(Size, <<"x">>) of
        [W, H] ->
            try binary_to_integer(W) / binary_to_integer(H) of
                R -> element(1, hd(lists:sort(fun({_, A}, {_, B}) -> abs(A - R) =< abs(B - R) end, ?RATIOS)))
            catch _:_ -> <<"1:1">>
            end;
        _ -> <<"1:1">>
    end;
aspect_ratio(_) ->
    <<"1:1">>.

%%====================================================================
%% 内部函数
%%====================================================================

%% MiniMax 业务错误在 200 响应里：base_resp.status_code ≠ 0
minimax_images(#{<<"base_resp">> := #{<<"status_code">> := C} = BR}, _Format) when C =/= 0 ->
    {error, minimax_error(C, maps:get(<<"status_msg">>, BR, <<>>))};
minimax_images(J, Format) ->
    D = maps:get(<<"data">>, J, #{}),
    Items = case Format of
                <<"base64">> -> [#{<<"b64_json">> => B} || B <- list(maps:get(<<"image_base64">>, D, []))];
                _ -> [#{<<"url">> => U} || U <- list(maps:get(<<"image_urls">>, D, []))]
            end,
    {#{<<"created">> => erlang:system_time(second), <<"data">> => Items}, length(Items)}.

%% @doc System One 决策：透传请求体（model 换为上游模型），返回上游响应体与结果
%% （usage.input = 输入 token，text = 回答摘要）。
-spec systemone(map(), lg_provider:target()) -> {ok, binary(), lg_provider:result()} | {error, lg_llm_error:error()}.
systemone(Req, #{credential := #lg_credential{protocol = openai, base_url = Base} = Cred,
                 upstream_model := Model} = Target) ->
    case lg_provider:auth_headers(openai, Cred, openai, Target) of
        {ok, H} ->
            Body = json:encode(Req#{<<"model">> => Model}),
            Timeout = lg_config:get(upstream_timeout_ms),
            case lg_http:request(<<"POST">>, url(Base, <<"/systemone">>), H ++ Cred#lg_credential.headers,
                                 Body, Timeout, #{api => true}) of
                {ok, _, _, RespBody} ->
                    try json:decode(RespBody) of
                        #{<<"answers">> := A} = J when is_map(A) ->
                            Usage = case J of
                                        #{<<"usage">> := #{<<"input_tokens">> := N}} when is_integer(N) -> N;
                                        _ -> 0
                                    end,
                            {ok, RespBody,
                             #{usage => (lg_usage:zero())#{input => Usage}, text => lg_decision:summary(J),
                               finish_reason => null, model => Model,
                               id => case maps:get(<<"request_id">>, J, <<>>) of I when is_binary(I) -> I; _ -> <<>> end,
                               error => undefined}};
                        _ ->
                            {error, lg_llm_error:classify({bad_response, no_answers})}
                    catch
                        error:_ -> {error, lg_llm_error:classify({bad_response, invalid_json})}
                    end;
                {error, R} ->
                    {error, lg_llm_error:classify(R)}
            end;
        {error, R} ->
            {error, lg_llm_error:classify(R)}
    end;
systemone(_Req, _Target) ->
    {error, lg_llm_error:classify({unsupported, <<"systemone">>})}.

minimax_error(Code, Msg) ->
    Status = case Code of
                 1004 -> 401;          %% 鉴权失败
                 1008 -> 402;          %% 余额不足
                 1002 -> 429;          %% 限流
                 1039 -> 429;          %% token 限制
                 2056 -> 429;          %% Token Plan 额度用尽
                 2013 -> 400;          %% 参数错误
                 1026 -> 400;          %% 内容敏感
                 _ -> 502
             end,
    Body = json:encode(#{<<"error">> => #{<<"message">> => Msg, <<"code">> => Code}}),
    lg_llm_error:classify({http_error, Status, [], iolist_to_binary(Body)}).

%% POST JSON 并把上游响应转换为 {OpenAI 格式响应, 张数}
post(Url, Body0, #{credential := Cred, upstream_model := Model} = Target, Convert) ->
    case lg_provider:auth_headers(openai, Cred, openai, Target) of
        {ok, H} ->
            Body = json:encode(Body0#{<<"model">> => Model}),
            Timeout = lg_config:get(upstream_timeout_ms),
            case lg_http:request(<<"POST">>, Url, H ++ Cred#lg_credential.headers, Body, Timeout, #{api => true}) of
                {ok, _, _, RespBody} ->
                    try json:decode(RespBody) of
                        J when is_map(J) ->
                            case Convert(J) of
                                {error, _} = Err ->
                                    Err;
                                {Out, N} ->
                                    {ok, json:encode(Out),
                                     #{usage => (lg_usage:zero())#{images => N}, text => urls(Out),
                                       finish_reason => null, model => Model, id => <<>>, error => undefined}}
                            end;
                        _ ->
                            {error, lg_llm_error:classify({bad_response, not_an_object})}
                    catch
                        error:_ -> {error, lg_llm_error:classify({bad_response, invalid_json})}
                    end;
                {error, R} ->
                    {error, lg_llm_error:classify(R)}
            end;
        {error, R} ->
            {error, lg_llm_error:classify(R)}
    end.

%% 日志里记录图片地址（base64 只记占位）
urls(#{<<"data">> := D}) when is_list(D) ->
    iolist_to_binary(lists:join(<<"\n">>, [case I of
                                               #{<<"url">> := U} when is_binary(U) -> U;
                                               _ -> <<"[base64 image]">>
                                           end || I <- D]));
urls(_) ->
    <<>>.

count(L) when is_list(L) -> length(L);
count(_) -> 0.

url(Base, Path) ->
    B = case binary:last(Base) of $/ -> binary:part(Base, 0, byte_size(Base) - 1); _ -> Base end,
    <<B/binary, Path/binary>>.

list(L) when is_list(L) -> L;
list(_) -> [].
