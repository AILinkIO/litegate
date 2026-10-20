%% @doc 上游调用门面：按客户端格式与凭证协议选择透传或转换。
%%
%% 客户端格式：openai（/v1/chat/completions）| anthropic（/v1/messages）
%% 上游协议：凭证的 protocol 字段
%%
%% 非流式：chat/3 返回客户端格式的完整响应体。
%% 流式：stream_open/3 在上游返回 2xx 响应头后返回句柄，之后反复 stream_next/1
%%       取客户端格式的 SSE 帧，直到 {done, Frames, Result}。
%%       开流前的失败（连接、4xx/5xx）以 {error, _} 返回，可由路由层回退重试；
%%       开流后的失败以错误帧写给客户端，不再回退。
-module(lg_provider).

-include_lib("lg_core/include/lg_core.hrl").

-export([chat/3, stream_open/3, stream_next/1, stream_abort/1, stream_set_idle/2, error_frame/2, upstream_request/3,
         embeddings/2, count_tokens/2, stream_output_started/1, probe/2, auth_headers/4,
         streamable/1]).

%% 供 lg_provider_stream 组合调用；不属于公共 provider API
-export([with_unfit_retry/2, with_beta_retry/2, sent_error/2, responses_passthrough/1, responses_url/1,
         responses_result/1, extra_body/2, endpoint/2, bin/1]).

-define(ANTHROPIC_VERSION, <<"2023-06-01">>).

-type format() :: openai | anthropic | responses.
-type target() :: #{credential := #lg_credential{},
                    upstream_model := binary(),
                    default_max_tokens => pos_integer() | undefined,
                    client_headers => [{binary(), binary()}],
                    loop_guard => boolean()}.
-type result() :: lg_stream:result().
-export_type([format/0, target/0, result/0]).

%%====================================================================
%% 非流式
%%====================================================================

%% @doc 该请求类型是否支持流式输出（T12）。
%% 目前仅 chat 走 SSE 管道；embeddings/images/speech 上游本身不支持流式，
%% 请求中的 stream:true 标记 stream_ignored 供控制台展示。
-spec streamable(atom()) -> boolean().
streamable(chat) -> true;
streamable(_) -> false.

-spec chat(format(), map(), target()) ->
          {ok, iodata(), result()} | {error, lg_llm_error:error()}.
chat(responses, Req, Target) ->
    case responses_passthrough(Target) of
        true -> with_unfit_retry(Target, fun(T) -> responses_native(Req#{<<"stream">> => false}, T) end);
        false -> responses_converted(Req, Target)
    end;
chat(Client, Req, Target) ->
    with_beta_retry(Target, fun(T) -> with_unfit_retry(T, fun(T2) -> chat_once(Client, Req, T2) end) end).

chat_once(Client, Req, Target) ->
    case upstream_request(Client, Req#{<<"stream">> => false}, Target) of
        {ok, #{url := Url, headers := H, body := B, upstream := Up} = U} ->
            Timeout = lg_config:get(upstream_timeout_ms),
            case lg_http:request(<<"POST">>, Url, H, B, Timeout, #{api => true}) of
                {ok, _Status, _RespH, RespBody} ->
                    respond(Client, Up, RespBody, lg_think:enabled(maps:get(credential, Target)),
                            maps:get(structured, U, undefined));
                {error, Reason} ->
                    {error, sent_error(Reason, maps:get(body_map, U))}
            end;
        {error, Reason} ->
            {error, lg_llm_error:classify(Reason)}
    end.

%% 上游返回错误时带上这次发出的请求体，供 with_unfit_retry/2 判断该学哪项限制
sent_error(Reason, Sent) ->
    (lg_llm_error:classify(Reason))#{sent => Sent}.

%% 上游以 400 / 422 拒绝、错误信息说明某参数不受支持时：记下（lg_unfit），按已知限制重新组装请求后重试；
%% 改写后可能暴露下一项限制（如关闭思考被拒后又遇到强制工具调用被拒），每次都学到新限制时最多连续重试 3 次
with_unfit_retry(Target, Fun) ->
    with_unfit_retry(Target, Fun, 3).

with_unfit_retry(#{credential := #lg_credential{id = CId}, upstream_model := Model} = Target, Fun, N) ->
    case Fun(Target) of
        {error, #{sent := Sent} = E} = Err when is_map(Sent), N > 0 ->
            case lg_unfit:learn(CId, Model, E, Sent) of
                {learned, _} -> with_unfit_retry(Target, Fun, N - 1);
                none -> drop_sent(Err)
            end;
        Other ->
            drop_sent(Other)
    end;
with_unfit_retry(Target, Fun, _N) ->
    drop_sent(Fun(Target)).

drop_sent({error, #{sent := _} = E}) -> {error, maps:remove(sent, E)};
drop_sent(Other) -> Other.

%% Anthropic 兼容上游不认识客户端带的 anthropic-beta（如 Claude Code 的新 beta）时返回 400：
%% 去掉 beta 头重试一次
with_beta_retry(#{client_headers := CH} = Target, Fun) ->
    case lists:keymember(<<"anthropic-beta">>, 1, CH) of
        false ->
            Fun(Target);
        true ->
            case Fun(Target) of
                {error, #{status := 400, upstream := #{body := Body}}} = Err when is_binary(Body) ->
                    case binary:match(string:lowercase(Body), <<"beta">>) of
                        nomatch -> Err;
                        _ -> Fun(Target#{client_headers => lists:keydelete(<<"anthropic-beta">>, 1, CH)})
                    end;
                Other ->
                    Other
            end
    end;
with_beta_retry(Target, Fun) ->
    Fun(Target).

respond(Client, Up, RespBody0, Split, Structured) ->
    try json:decode(RespBody0) of
        J00 when is_map(J00) ->
            %% 强制工具方式的结构化输出：还原成正文 JSON
            {J0, RespBody00} = case Structured of
                                   B when is_binary(B) -> J01 = lg_structured:response(J00, B), {J01, json:encode(J01)};
                                   _ -> {J00, RespBody0}
                               end,
            {J1, RespBody1} = case Split of
                                  true -> J10 = lg_think:split_response(J0), {J10, json:encode(J10)};
                                  false -> {J0, RespBody00}
                              end,
            %% OpenAI 协议上游的结构化输出：去掉偶尔出现的代码块（在拆分思考标签之后）
            {J, RespBody} = case Structured of
                                json ->
                                    case lg_structured:response(J1, json) of
                                        J1 -> {J1, RespBody1};
                                        J2 -> {J2, json:encode(J2)}
                                    end;
                                _ -> {J1, RespBody1}
                            end,
            Result = result_of(Up, J),
            Out = case {Client, Up} of
                      {Same, Same} -> RespBody;
                      {openai, anthropic} -> json:encode(lg_conv_resp:anthropic_to_openai(J));
                      {anthropic, openai} -> json:encode(lg_conv_resp:openai_to_anthropic(J))
                  end,
            {ok, Out, Result};
        _ ->
            {error, lg_llm_error:classify({bad_response, not_an_object})}
    catch
        error:_ ->
            {error, lg_llm_error:classify({bad_response, invalid_json})}
    end.

result_of(openai, J) ->
    {Text, Finish} = case maps:get(<<"choices">>, J, []) of
                         [#{<<"message">> := M} = C | _] ->
                             {text(maps:get(<<"content">>, M, null)),
                              maps:get(<<"finish_reason">>, C, null)};
                         _ -> {<<>>, null}
                     end,
    #{usage => lg_usage:from_openai(maps:get(<<"usage">>, J, null)),
      text => Text, finish_reason => Finish,
      model => bin(maps:get(<<"model">>, J, <<>>)), id => bin(maps:get(<<"id">>, J, <<>>)),
      error => undefined};
result_of(anthropic, J) ->
    Text = iolist_to_binary([T || #{<<"type">> := <<"text">>, <<"text">> := T}
                                      <- maps:get(<<"content">>, J, [])]),
    #{usage => lg_usage:from_anthropic(maps:get(<<"usage">>, J, null)),
      text => Text, finish_reason => maps:get(<<"stop_reason">>, J, null),
      model => bin(maps:get(<<"model">>, J, <<>>)), id => bin(maps:get(<<"id">>, J, <<>>)),
      error => undefined}.

%%====================================================================
%% Responses API
%%====================================================================

%% 上游原生支持 /responses：openai 协议且凭证 options.responses_api = true
responses_passthrough(#{credential := #lg_credential{protocol = openai, options = O}}) ->
    maps:get(responses_api, O, false) =:= true;
responses_passthrough(_) ->
    false.

%% 原生 Responses 地址：凭证 options.responses_base_url（与 Chat 不在同一基址时，如智谱 /api/v1），否则 base_url
responses_url(#lg_credential{base_url = Base, options = O}) ->
    <<(trim_slash(maps:get(responses_base_url, O, Base)))/binary, "/responses">>.

responses_native(Req, #{credential := Cred, upstream_model := Model} = Target) ->
    case auth_headers(openai, Cred, openai, Target) of
        {ok, H} ->
            Timeout = lg_config:get(upstream_timeout_ms),
            BodyMap = extra_body(Cred, lg_unfit:apply(openai, Cred#lg_credential.id, Model,
                                                      lg_quirks:apply(openai, Cred, Model, Req#{<<"model">> => Model}), false)),
            Body = json:encode(BodyMap),
            case lg_http:request(<<"POST">>, responses_url(Cred), H ++ Cred#lg_credential.headers, Body, Timeout, #{api => true}) of
                {ok, _, _, RespBody} ->
                    try json:decode(RespBody) of
                        J when is_map(J) -> {ok, RespBody, responses_result(J)};
                        _ -> {error, lg_llm_error:classify({bad_response, not_an_object})}
                    catch
                        error:_ -> {error, lg_llm_error:classify({bad_response, invalid_json})}
                    end;
                {error, R} ->
                    {error, sent_error(R, BodyMap)}
            end;
        {error, R} ->
            {error, lg_llm_error:classify(R)}
    end.

%% 转换：Responses → Chat（→ 由 chat/3 再转 Anthropic）→ Responses
responses_converted(Req, Target) ->
    case lg_conv_responses:request_to_chat(Req#{<<"stream">> => false}) of
        {ok, ChatReq} ->
            case chat(openai, ChatReq, Target) of
                {ok, ChatBody, Result} ->
                    Resp = lg_conv_responses:chat_to_response(
                             json:decode(iolist_to_binary(ChatBody)),
                             #{id => lg_conv_responses:new_id(<<"resp">>), request => Req}),
                    {ok, json:encode(Resp), Result#{response => Resp}};
                Err ->
                    Err
            end;
        {error, R} ->
            {error, lg_llm_error:classify(R)}
    end.

responses_result(Resp) ->
    Text = iolist_to_binary([T || #{<<"type">> := <<"message">>, <<"content">> := C} <- list(maps:get(<<"output">>, Resp, [])),
                                  #{<<"type">> := <<"output_text">>, <<"text">> := T} <- list(C)]),
    #{usage => lg_usage:from_responses(maps:get(<<"usage">>, Resp, null)),
      text => Text,
      finish_reason => case maps:get(<<"status">>, Resp, null) of
                           <<"incomplete">> -> <<"length">>;
                           <<"completed">> -> <<"stop">>;
                           _ -> null
                       end,
      model => bin(maps:get(<<"model">>, Resp, <<>>)), id => bin(maps:get(<<"id">>, Resp, <<>>)),
      error => undefined, response => Resp}.

list(L) when is_list(L) -> L;
list(_) -> [].

%%====================================================================
%% Embeddings / count_tokens（透传）
%%====================================================================

%% @doc POST {base}/embeddings（仅 openai 协议）：只替换 model，响应原样返回。
-spec embeddings(map(), target()) -> {ok, iodata(), result()} | {error, lg_llm_error:error()}.
embeddings(Req, #{credential := #lg_credential{protocol = openai, base_url = Base}} = Target) ->
    passthrough(<<(trim_slash(Base))/binary, "/embeddings">>, openai, Req, Target,
                fun(J) ->
                        U = maps:get(<<"usage">>, J, #{}),
                        In = case U of
                                 #{<<"prompt_tokens">> := N} when is_integer(N) -> N;
                                 #{<<"total_tokens">> := N} when is_integer(N) -> N;
                                 _ -> 0
                             end,
                        (lg_usage:zero())#{input => In}
                end);
embeddings(_Req, _Target) ->
    {error, lg_llm_error:classify({unsupported, <<"embeddings">>})}.

%% @doc POST .../v1/messages/count_tokens（仅 anthropic 协议）：不计费。
-spec count_tokens(map(), target()) -> {ok, iodata(), result()} | {error, lg_llm_error:error()}.
count_tokens(Req, #{credential := #lg_credential{protocol = anthropic, base_url = Base}} = Target) ->
    passthrough(<<(endpoint(anthropic, Base))/binary, "/count_tokens">>, anthropic, Req, Target,
                fun(_) -> lg_usage:zero() end);
count_tokens(_Req, _Target) ->
    {error, lg_llm_error:classify({unsupported, <<"count_tokens">>})}.

%% @doc 探活：GET 模型列表（openai：{base}/models；anthropic：.../v1/models），只关心能否鉴权成功。
-spec probe(#lg_credential{}, timeout()) -> ok | {error, lg_llm_error:error()}.
probe(#lg_credential{protocol = Proto, base_url = Base} = Cred, Timeout) ->
    Url = case Proto of
              openai -> <<(trim_slash(Base))/binary, "/models">>;
              anthropic -> binary:replace(endpoint(anthropic, Base), <<"/messages">>, <<"/models">>)
          end,
    case auth_headers(Proto, Cred, Proto, #{}) of
        {ok, H} ->
            case lg_http:request(<<"GET">>, Url, H ++ Cred#lg_credential.headers, <<>>, Timeout, #{api => true}) of
                {ok, _, _, _} -> ok;
                {error, R} -> {error, lg_llm_error:classify(R)}
            end;
        {error, R} ->
            {error, lg_llm_error:classify(R)}
    end.

passthrough(Url, Proto, Req, #{credential := Cred, upstream_model := Model} = Target, UsageOf) ->
    case auth_headers(Proto, Cred, Proto, Target) of
        {ok, H} ->
            Body = json:encode(Req#{<<"model">> => Model}),
            Timeout = lg_config:get(upstream_timeout_ms),
            case lg_http:request(<<"POST">>, Url, H ++ Cred#lg_credential.headers, Body, Timeout, #{api => true}) of
                {ok, _Status, _RespH, RespBody} ->
                    try json:decode(RespBody) of
                        J when is_map(J) ->
                            {ok, RespBody, #{usage => UsageOf(J), text => <<>>, finish_reason => null,
                                             model => bin(maps:get(<<"model">>, J, Model)),
                                             id => <<>>, error => undefined}};
                        _ ->
                            {error, lg_llm_error:classify({bad_response, not_an_object})}
                    catch
                        error:_ -> {error, lg_llm_error:classify({bad_response, invalid_json})}
                    end;
                {error, Reason} ->
                    {error, lg_llm_error:classify(Reason)}
            end;
        {error, Reason} ->
            {error, lg_llm_error:classify(Reason)}
    end.


%%====================================================================
%% 流式门面
%%====================================================================

stream_open(Client, Req, Target) -> lg_provider_stream:stream_open(Client, Req, Target).
stream_next(S) -> lg_provider_stream:stream_next(S).
stream_abort(S) -> lg_provider_stream:stream_abort(S).
stream_set_idle(S, F) -> lg_provider_stream:stream_set_idle(S, F).
stream_output_started(S) -> lg_provider_stream:stream_output_started(S).
error_frame(F, Msg) -> lg_provider_stream:error_frame(F, Msg).

%%====================================================================
%% 构造上游请求
%%====================================================================

%% @doc 按凭证协议生成上游 URL、请求头与请求体（导出供测试与调试）。
%% 返回 map 含 body_map / structured 附加键；spec 必须如实声明——
%% OTP 28.5 Dialyzer 对「契约未声明的额外键 + 调用图 fixpoint」会把 {ok, ...}
%% 分支整体坍缩成不可达（chat/stream 两处模式匹配误报 never match）。
-spec upstream_request(format(), map(), target()) ->
          {ok, #{url := binary(), headers := list(), body := iodata(), body_map := map(),
                 upstream := format(), structured := binary() | json | undefined}}
          | {error, term()}.
%% convert/4 的四个协议组合都有成功分支；不写 spec 时 Dialyzer 会把上游协议收窄成最后一个分支。
%% 实际错误域由各转换模块定义：无法表达的内容为 {unsupported, binary()}。
-spec convert(format(), openai | anthropic, map(), target()) ->
          {ok, map()} | {error, {unsupported, binary()}}.
upstream_request(Client, Req, #{credential := #lg_credential{protocol = Up} = Cred,
                                upstream_model := Model} = Target) ->
    case convert(Client, Up, Req, Target) of
        {ok, Body0} ->
            Body1 = case lg_think:enabled(Cred) of
                        true -> lg_think:pack_messages(Body0);
                        false -> Body0
                    end,
            Body2 = case {Up, Cred#lg_credential.options} of
                        {anthropic, #{prompt_cache := <<"auto">>}} -> lg_prompt_cache:apply(Body1);
                        _ -> Body1
                    end,
            {Body3, Structured} = lg_structured:apply(Up, Client, Body2, {Cred, Req, Model}),
            Body = extra_body(Cred, lg_unfit:apply(Up, Cred#lg_credential.id, Model,
                                                   lg_quirks:apply(Up, Cred, Model, Body3#{<<"model">> => Model}),
                                                   maps:get(<<"stream">>, Body3, false) =:= true)),
            case auth_headers(Up, Cred, Client, Target) of
                {ok, H} ->
                    {ok, #{url => endpoint(Up, Cred#lg_credential.base_url),
                           headers => H ++ Cred#lg_credential.headers,
                           body => json:encode(Body), body_map => Body,
                           upstream => Up, structured => Structured}};
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

%% 凭证 options.extra_body 合并进上游请求体；不能覆盖模型、消息、流式等网关管理的字段
-define(PROTECTED, [<<"model">>, <<"messages">>, <<"input">>, <<"stream">>, <<"stream_options">>]).
extra_body(#lg_credential{options = #{extra_body := Extra}}, Body) when is_map(Extra) ->
    maps:merge(Body, maps:without(?PROTECTED, Extra));
extra_body(_, Body) ->
    Body.

convert(openai, openai, Req, _T) ->
    {ok, ensure_openai_usage(Req)};
convert(anthropic, anthropic, Req, _T) ->
    {ok, Req};
convert(openai, anthropic, Req, T) ->
    lg_conv_req:openai_to_anthropic(Req, T);
convert(anthropic, openai, Req, T) ->
    lg_conv_req:anthropic_to_openai(Req, T).

%% 流式时总是请求 usage 块，用于计费（客户端没要时由 lg_stream 剥掉）
ensure_openai_usage(#{<<"stream">> := true} = Req) ->
    Opts = case maps:get(<<"stream_options">>, Req, null) of
               M when is_map(M) -> M;
               _ -> #{}
           end,
    Req#{<<"stream_options">> => Opts#{<<"include_usage">> => true}};
ensure_openai_usage(Req) ->
    maps:remove(<<"stream_options">>, Req).

endpoint(openai, Base) ->
    <<(trim_slash(Base))/binary, "/chat/completions">>;
endpoint(anthropic, Base) ->
    B = trim_slash(Base),
    %% models.dev 里 Anthropic 兼容供应商的 api 多数已带 /v1
    case binary:longest_common_suffix([B, <<"/v1">>]) of
        3 -> <<B/binary, "/messages">>;
        _ -> <<B/binary, "/v1/messages">>
    end.

auth_headers(Up, #lg_credential{api_key_enc = Enc}, Client, Target) ->
    case key(Enc) of
        {ok, Key} ->
            Base = [{<<"content-type">>, <<"application/json">>},
                    {<<"accept">>, <<"application/json, text/event-stream">>}],
            {ok, Base ++ auth(Up, Key) ++ protocol_headers(Up, Client, Target)};
        {error, _} = Err ->
            Err
    end.

key(undefined) -> {ok, undefined};
key(Enc) ->
    case lg_crypto:decrypt(Enc) of
        {ok, K} -> {ok, K};
        {error, R} -> {error, {credential_key, R}}
    end.

auth(_, undefined) -> [];
auth(openai, Key) -> [{<<"authorization">>, <<"Bearer ", Key/binary>>}];
auth(anthropic, Key) -> [{<<"x-api-key">>, Key}].

%% Anthropic 客户端的 anthropic-version / anthropic-beta 原样带给 Anthropic 上游
protocol_headers(anthropic, Client, Target) ->
    Passed = case Client of
                 anthropic -> [{K, V} || {K, V} <- maps:get(client_headers, Target, []),
                                         K =:= <<"anthropic-version">> orelse
                                             K =:= <<"anthropic-beta">>];
                 openai -> []
             end,
    case lists:keymember(<<"anthropic-version">>, 1, Passed) of
        true -> Passed;
        false -> [{<<"anthropic-version">>, ?ANTHROPIC_VERSION} | Passed]
    end;
protocol_headers(openai, _, _) ->
    [].

trim_slash(B) ->
    case binary:last(B) of
        $/ -> trim_slash(binary:part(B, 0, byte_size(B) - 1));
        _ -> B
    end.

text(T) when is_binary(T) -> T;
text(Parts) when is_list(Parts) -> iolist_to_binary([T || #{<<"text">> := T} <- Parts]);
text(_) -> <<>>.

bin(B) when is_binary(B) -> B;
bin(_) -> <<>>.
