%% @doc 代理端点：/v1/chat/completions（OpenAI）、/v1/messages（Anthropic）、
%% /v1/embeddings（OpenAI）、/v1/messages/count_tokens（Anthropic）、/v1/images/generations、/v1/audio/speech（OpenAI）、/v1/systemone（System One 决策）。
%% /v1/responses（OpenAI Responses API，format = responses）。
%% 路由状态中的 kind 区分 chat | embeddings | count_tokens | images | speech。
%%
%% 流式请求在上游返回 2xx 响应头之后才向客户端发 200，开流前的失败仍可回退并返回正常错误码。
%% 流式处理进程 trap_exit：客户端断开时 cowboy 发来 shutdown，中止上游并照常记账。
%%
%% /api/playground/*（source = playground）：控制台管理员身份代替网关 Key，使用内置 Key `playground`
%% （不受路由访问列表约束），日志 source = playground；响应头附带命中的上游与尝试次数。
-module(lg_web_llm).
-behaviour(cowboy_handler).

-include_lib("lg_core/include/lg_core.hrl").

-export([init/2]).

init(Req00, #{format := F} = State) ->
    Id = lg_store:new_id(),
    Req0 = cowboy_req:set_resp_header(<<"x-request-id">>, Id, Req00),
    Req = case cowboy_req:method(Req0) of
              <<"POST">> -> handle(F, maps:get(kind, State, chat), maps:get(source, State, gateway), Req0);
              _ -> lg_web_util:error_reply(F, 405, <<"invalid_request_error">>,
                                           <<"Method not allowed">>, Req0)
          end,
    {ok, Req, State}.

handle(F, Kind, playground, Req0) ->
    case lg_api:console_admin(Req0) of
        {ok, #lg_user{id = UserId}} ->
            Key = #lg_api_key{id = ?LG_PLAYGROUND_KEY, hash = <<>>, prefix = <<"playground">>,
                              name = <<"Playground">>, user_id = UserId, created_at = 0},
            body(F, Kind, Key, Req0);
        {error, Status, Msg} ->
            lg_web_util:error_reply(F, Status, <<"authentication_error">>, Msg, Req0)
    end;
handle(F, Kind, gateway, Req0) ->
    case lg_web_util:authenticate(Req0) of
        {ok, Key} ->
            body(F, Kind, Key, Req0);
        {error, Reason} ->
            lg_web_util:error_reply(F, 401, <<"authentication_error">>, auth_message(Reason), Req0)
    end.

body(F, Kind, Key, Req0) ->
    case lg_web_util:read_json(Req0) of
        {ok, Body, Req} ->
            call(F, Kind, Body, Key, Req);
        {error, too_large, Req} ->
            lg_web_util:error_reply(F, 413, <<"invalid_request_error">>,
                                    <<"Request body too large">>, Req);
        {error, invalid_json, Req} ->
            lg_web_util:error_reply(F, 400, <<"invalid_request_error">>,
                                    <<"Request body must be a JSON object">>, Req)
    end.

call(F, Kind, #{<<"model">> := Model} = Body00, Key, Req) when is_binary(Model) ->
    %% 请求标签：请求头 + 请求体 metadata.tags + Key 默认标签；metadata.tags 不转发给上游
    Tags = lg_tags:merge([lg_tags:from_header(cowboy_req:header(<<"x-litegate-tags">>, Req)),
                          lg_tags:from_body(F, Body00), Key#lg_api_key.tags]),
    Body0 = strip_tags(Body00),
    Ctx00 = #{key => Key, client_headers => client_headers(Req), kind => Kind,
              id => cowboy_req:resp_header(<<"x-request-id">>, Req),
              no_cache => no_cache(Req), tags => Tags,
              traceparent => cowboy_req:header(<<"traceparent">>, Req)},
    {Client, UA} = lg_client:detect(cowboy_req:headers(Req), F),
    Ctx01 = Ctx00#{client => Client, user_agent => UA},
    %% 会话标识与轮次（会话粘性、规则路由用），只对对话请求
    Ctx0 = case Kind of
               chat ->
                   case lg_session:id(cowboy_req:headers(Req), Body0, Key#lg_api_key.id) of
                       {Sid, Src} -> Ctx01#{session => Sid, session_source => Src,
                                            new_turn => lg_session:new_turn(F, Body0)};
                       undefined -> Ctx01#{new_turn => lg_session:new_turn(F, Body0)}
                   end;
               _ -> Ctx01
           end,
    Kind =:= count_tokens orelse
        lg_live:request_start(maps:get(id, Ctx0, undefined),
                              #{route => Model, client => Client, key_name => Key#lg_api_key.name,
                                stream => maps:get(<<"stream">>, Body0, false) =:= true,
                                session => maps:get(session, Ctx0, null), format => F}),
    %% 中间件 on_request（按客户端请求解析出的路由生效；count_tokens 与 systemone 不是对话，不经过中间件）
    {MwRoute, RouteOpts} = case lg_routes:match(Model) of
                               {ok, #lg_route{name = RN, options = RO}, _} -> {RN, RO};
                               _ -> {Model, #{}}
                           end,
    Run0 = case Kind of
               count_tokens -> none;
               systemone -> none;
               _ -> lg_middleware:begin_run(MwRoute, #{route => MwRoute, model => Model, format => F, kind => Kind,
                                                      stream => maps:get(<<"stream">>, Body0, false) =:= true,
                                                      client => Client, key_name => Key#lg_api_key.name, tags => Tags,
                                                      session => maps:get(session, Ctx0, undefined)})
           end,
    case lg_middleware:request(Run0, Body0) of
        {reject, RS, RMsg, _} ->
            Out = #{route => MwRoute, model => Model, key_id => Key#lg_api_key.id, user_id => Key#lg_api_key.user_id,
                    tags => Tags, started_at => lg_time:now_ms(), attempts => []},
            fail(Ctx0, F, maps:get(<<"stream">>, Body0, false) =:= true, Body0, {middleware_rejected, RS, RMsg}, Out, Req);
        {ok, Body0m, Run} ->
            Redact = (Kind =:= chat orelse Kind =:= count_tokens) andalso
                (maps:get(redact, Key#lg_api_key.options, false) orelse maps:get(redact, RouteOpts, false)),
            call_prepared(F, Kind, Model, Body0m, Ctx0#{mw => Run, redact => Redact}, Req)
    end;
call(F, _Kind, _Body, _Key, Req) ->
    lg_web_util:error_reply(F, 400, <<"invalid_request_error">>, <<"Missing field: model">>, Req).

call_prepared(F, Kind, Model, Body0, Ctx0, Req) ->
    case prepare(F, Body0, Ctx0) of
        {ok, Body1, Ctx1} ->
            {Body, Ctx} = redact(F, Body1, Ctx1),
            WantStream = maps:get(<<"stream">>, Body, false) =:= true,
            case lg_provider:streamable(Kind) andalso WantStream of
                true -> stream(F, Body, Ctx, Req);
                false when WantStream ->
                    %% T12：非 chat 端点 stream:true 被忽略，整包返回（OpenAI SDK 兼容性）
                    sync(F, Body, Ctx#{stream_ignored => true}, Req);
                false ->
                    sync(F, Body, Ctx, Req)
            end;
        {error, Msg} ->
            lg_live:request_end(maps:get(id, Ctx0, undefined), #{route => Model, status => 400}),
            lg_web_util:error_reply(F, 400, <<"invalid_request_error">>, Msg, Req)
    end.

%% 敏感信息脱敏：发往上游与写入日志的都是脱敏后的请求体；回复写给客户端前还原。
%% Ctx 中 redact => 占位符 → 原值（没有命中时不设），original => 脱敏前的请求体（保存 Responses 会话用）
redact(F, Body, #{redact := true} = Ctx) ->
    case lg_redact:scan(Body) of
        {_, Map} when map_size(Map) =:= 0 -> {Body, maps:remove(redact, Ctx)};
        {Body1, Map} ->
            lg_metrics:inc(litegate_redactions_total, [], map_size(Map)),
            {Body1, Ctx#{redact => Map, original => Body, redact_stream => lg_redact:stream_new(F, Map)}}
    end;
redact(_F, Body, Ctx) ->
    {Body, maps:remove(redact, Ctx)}.

unredact(#{redact := Map}, Resp) ->
    Bin = iolist_to_binary(Resp),
    case binary:match(Bin, <<"[[LG_SECRET_">>) of
        nomatch -> Bin;
        _ ->
            case catch json:decode(Bin) of
                J when is_map(J) -> iolist_to_binary(json:encode(lg_redact:restore_json(J, Map)));
                _ -> Bin
            end
    end;
unredact(_Ctx, Resp) ->
    Resp.

unredact_frames(#{redact_stream := St} = Ctx, Frames) ->
    {Out, St1} = lg_redact:stream_frames(Frames, St),
    {Out, Ctx#{redact_stream => St1}};
unredact_frames(Ctx, Frames) ->
    {Frames, Ctx}.

strip_tags(#{<<"metadata">> := #{<<"tags">> := _} = M} = Body) ->
    case maps:remove(<<"tags">>, M) of
        Empty when map_size(Empty) =:= 0 -> maps:remove(<<"metadata">>, Body);
        M1 -> Body#{<<"metadata">> => M1}
    end;
strip_tags(Body) ->
    Body.

%% Responses API 的 previous_response_id：在本地展开历史输入项，去掉 previous_response_id 再转发。
%% 透传模式同样本地展开（部分上游如 MiniMax 的 /v1/responses 无状态，会忽略 previous_response_id），
%% 并优先发往上次的目标；旧版本保存的透传会话没有历史项，只能原样转发由上游处理。
prepare(responses, #{<<"previous_response_id">> := Prev} = Body, Ctx) when is_binary(Prev) ->
    case lg_store:response_get(Prev) of
        {ok, #{input := In, output := Out} = S} ->
            Items = lg_conv_responses:input_items(Body),
            Ctx1 = case S of
                       #{mode := passthrough, credential := C, upstream_model := M} -> Ctx#{prefer => {C, M}};
                       _ -> Ctx
                   end,
            {ok, (maps:remove(<<"previous_response_id">>, Body))#{<<"input">> => In ++ Out ++ Items}, Ctx1};
        {ok, #{mode := passthrough, credential := C, upstream_model := M}} ->
            {ok, Body, Ctx#{prefer => {C, M}}};
        not_found ->
            {error, <<"Previous response `", Prev/binary, "` not found">>}
    end;
prepare(_F, Body, Ctx) ->
    {ok, Body, Ctx}.

sync(F, Body, #{kind := Kind} = Ctx, Req) ->
    Res = case Kind of
              chat -> lg_router:chat(F, Body, Ctx);
              embeddings -> lg_router:embeddings(Body, Ctx);
              images -> lg_router:images(Body, Ctx);
              speech -> lg_router:speech(Body, Ctx);
              systemone -> lg_router:systemone(Body, Ctx);
              count_tokens -> lg_router:count_tokens(Body, Ctx)
          end,
    case Res of
        {ok, Resp0, Out} ->
            Resp = case Kind of
                       speech -> Resp0;
                       %% 决策回答不是对话：不经响应中间件；model 换回客户端请求的路由名
                       systemone -> systemone_response(Resp0, maps:get(<<"model">>, Body));
                       _ -> mw_response(Ctx, unredact(Ctx, Resp0))
                   end,
            lg_web_llm_log:record(Ctx, F, false, Body, Out, 200),
            Req0 = case maps:get(estimated, Out, false) of
                       true -> cowboy_req:set_resp_header(<<"x-litegate-estimated">>, <<"true">>, Req);
                       false -> Req
                   end,
            Req1 = case maps:get(cache_hit, Out, false) of
                       true -> cowboy_req:set_resp_header(<<"x-litegate-cache">>, <<"hit">>, playground_headers(Ctx, Out, Req0));
                       false -> playground_headers(Ctx, Out, Req0)
                   end,
            case Kind of
                speech ->
                    CT = maps:get(content_type, maps:get(result, Out, #{}), <<"audio/mpeg">>),
                    cowboy_req:reply(200, #{<<"content-type">> => CT}, Resp, Req1);
                _ ->
                    lg_web_util:raw_json(200, Resp, Req1)
            end;
        {error, Err, Out} ->
            fail(Ctx, F, false, Body, Err, Out, Req)
    end.

%% 上游 System One 响应体的 model 换成客户端请求的路由名（与对话接口一致）
systemone_response(Resp, Model) ->
    try json:decode(iolist_to_binary(Resp)) of
        #{} = J -> json:encode(J#{<<"model">> => Model});
        _ -> Resp
    catch
        error:_ -> Resp
    end.

%% 开流前保活：上游（或排队）超过 stream_hold_ms 仍未开流时先发 200 与注释帧，之后每 10 秒一帧，
%% 总时长超过 stream_hold_max_ms 后路由层不再尝试新候选、以 504 结束；
%% 已发 200 后所有候选都失败则以客户端格式的错误帧结束。开流后上游 keepalive_ms 无数据时写注释帧。
stream(F, Body, Ctx, Req0) ->
    process_flag(trap_exit, true),
    Started = lg_time:now_ms(),
    put(lg_hold, #{req => Req0, sent => undefined, last => 0, started => Started}),
    Res = lg_router:stream_open(F, Body, Ctx#{idle => fun hold_tick/0, hold_started => Started}),
    #{sent := Sent} = erase(lg_hold),
    case Res of
        {ok, S, Out} ->
            lg_metrics:track(litegate_active_streams, self()),
            Req = case Sent of
                      undefined -> cowboy_req:stream_reply(200, sse_headers(), playground_headers(Ctx, Out, Req0));
                      R -> R
                  end,
            S1 = lg_provider:stream_set_idle(S, fun() -> cowboy_req:stream_body(<<": keepalive\n\n">>, nofin, Req) end),
            pump(S1, {Ctx, F, Body, Out, undefined}, Req);
        {error, Err, Out} when Sent =/= undefined ->
            {Status, _Type, Msg} = lg_web_llm_error:response(F, Err, Out),
            lg_web_llm_log:record(Ctx, F, true, Body, Out#{error => Err}, Status),
            Text = case Msg of
                       {raw, _} -> maps:get(message, Err, <<"Upstream error">>);
                       M -> M
                   end,
            cowboy_req:stream_body(lg_provider:error_frame(F, Text), fin, Sent),
            Sent;
        {error, Err, Out} ->
            fail(Ctx, F, true, Body, Err, Out, Req0)
    end.

sse_headers() ->
    #{<<"content-type">> => <<"text/event-stream">>, <<"cache-control">> => <<"no-cache">>,
      <<"x-accel-buffering">> => <<"no">>}.

hold_tick() ->
    #{req := Req0, sent := Sent, last := Last, started := Started} = H = get(lg_hold),
    Now = lg_time:now_ms(),
    case Sent of
        undefined ->
            case Now - Started >= lg_config:get(stream_hold_ms) of
                true ->
                    Req = cowboy_req:stream_reply(200, sse_headers(), Req0),
                    cowboy_req:stream_body(<<": litegate waiting\n\n">>, nofin, Req),
                    put(lg_hold, H#{sent => Req, last => Now});
                false -> ok
            end;
        Req when Now - Last >= 10000 ->
            cowboy_req:stream_body(<<": litegate waiting\n\n">>, nofin, Req),
            put(lg_hold, H#{last => Now});
        _ -> ok
    end.

%% Ttft：写出首个实际内容时距请求开始的毫秒数（尚未出现时为 undefined）
pump(S, {Ctx, F, Body, Out, Ttft}, Req) ->
    case lg_provider:stream_next(S) of
        {frames, Frames0, S1} ->
            {Frames1, Ctx1} = unredact_frames(Ctx, Frames0),
            Frames = mw_frames(Ctx1, Frames1),
            send(Frames, nofin, Req),
            pump(S1, {Ctx1, F, Body, Out, ttft(Ttft, Frames, S1, Out)}, Req);
        {done, Frames0, Result} ->
            {Frames1, Ctx1} = unredact_frames(Ctx, Frames0),
            Frames = mw_frames(Ctx1, Frames1),
            send(Frames, fin, Req),
            lg_metrics:untrack(litegate_active_streams, self()),
            Final = lg_router:finalize(Out, Result),
            lg_web_llm_log:record(Ctx, F, true, Body, with_ttft(Final, Ttft), 200),
            Req;
        {exit, Reason, Result} ->
            Final = (lg_router:finalize(Out, Result))#{client_aborted => true},
            lg_web_llm_log:record(Ctx, F, true, Body, with_ttft(Final, Ttft), 200),
            %% 节点关停时连接进程被 ranch kill，链接传来 killed；已记账，按 shutdown 退出免得刷崩溃报告
            exit(case Reason of killed -> shutdown; _ -> Reason end)
    end.

ttft(undefined, [_ | _], S, Out) ->
    case lg_provider:stream_output_started(S) of
        true -> lg_time:now_ms() - maps:get(started_at, Out);
        false -> undefined
    end;
ttft(Ttft, _Frames, _S, _Out) ->
    Ttft.

%% 没有任何输出（如只有工具调用结束块）时以总耗时计
with_ttft(Out, undefined) -> Out#{ttft_ms => maps:get(duration_ms, Out)};
with_ttft(Out, T) -> Out#{ttft_ms => T}.

fail(Ctx, F, Stream, Body, Err, Out, Req00) ->
    {Status, Type, Msg} = lg_web_llm_error:response(F, Err, Out),
    lg_web_llm_log:record(Ctx, F, Stream, Body, Out#{error => Err}, Status),
    Req0 = playground_headers(Ctx, Out, Req00),
    Req = case lg_web_llm_error:retry_after(Err) of
              undefined -> Req0;
              Secs -> cowboy_req:set_resp_header(<<"retry-after">>, integer_to_binary(Secs), Req0)
          end,
    case Msg of
        {raw, Raw} -> lg_web_util:raw_json(Status, Raw, Req);
        _ -> lg_web_util:error_reply(F, Status, Type, Msg, Req)
    end.

%% Playground：响应头带上命中的上游（凭证名 / 上游模型）与尝试次数
playground_headers(#{key := #lg_api_key{id = ?LG_PLAYGROUND_KEY}}, Out, Req0) ->
    Req = cowboy_req:set_resp_header(<<"x-litegate-attempts">>,
                                     integer_to_binary(length(maps:get(attempts, Out, []))), Req0),
    case Out of
        #{credential := C, upstream_model := M} ->
            Name = case lg_credentials:get(C) of
                       {ok, #lg_credential{name = N}} -> N;
                       not_found -> C
                   end,
            %% 头部值只允许 ASCII：凭证名做百分号编码
            cowboy_req:set_resp_header(<<"x-litegate-target">>,
                                       uri_string:quote(<<Name/binary, " / ", M/binary>>), Req);
        _ ->
            Req
    end;
playground_headers(_Ctx, _Out, Req) ->
    Req.

%% 中间件 on_event：只有调用链里有 on_event 时才解析与重新编码流式帧
mw_frames(#{mw := Run}, Frames) when Frames =/= [] ->
    case lg_middleware:has(Run, on_event) of
        false -> Frames;
        true ->
            {Evs, _} = lg_sse:parse(iolist_to_binary(Frames)),
            [case catch json:decode(D) of
                 J when is_map(J), D =/= <<"[DONE]">> ->
                     case lg_middleware:event(Run, #{event => E, data => J}) of
                         {ok, #{data := J1} = Ev1} ->
                             Data = json:encode(J1),
                             case maps:get(event, Ev1, E) of
                                 undefined -> lg_sse:encode(Data);
                                 E1 -> lg_sse:encode(E1, Data)
                             end;
                         drop -> []
                     end;
                 _ -> Raw
             end || #{event := E, data := D, raw := Raw} <- Evs]
    end;
mw_frames(_Ctx, Frames) ->
    Frames.

%% 中间件 on_response：入口已挂上运行态；只有调用链里有 on_response 时才解码与重新编码
mw_response(#{mw := Run}, Resp) ->
    case lg_middleware:has(Run, on_response) of
        false -> Resp;
        true ->
            case catch json:decode(iolist_to_binary(Resp)) of
                J when is_map(J) -> json:encode(lg_middleware:response(Run, J));
                _ -> Resp
            end
    end.

send([], nofin, _Req) -> ok;
send(Frames, IsFin, Req) -> cowboy_req:stream_body(Frames, IsFin, Req).

auth_message(missing_key) -> <<"Missing API key">>;
auth_message(invalid_key) -> <<"Invalid API key">>;
auth_message(disabled) -> <<"API key is disabled">>;
auth_message(expired) -> <<"API key has expired">>.

no_cache(Req) ->
    case cowboy_req:header(<<"cache-control">>, Req) of
        undefined -> false;
        V -> binary:match(string:lowercase(V), [<<"no-cache">>, <<"no-store">>]) =/= nomatch
    end.

%% Anthropic 客户端的版本与 beta 头需要带给上游
client_headers(Req) ->
    [{K, V} || {K, V} <- maps:to_list(cowboy_req:headers(Req)),
               K =:= <<"anthropic-version">> orelse K =:= <<"anthropic-beta">>].

%%====================================================================
%% 记账
%%====================================================================
