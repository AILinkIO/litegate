%% @doc OpenAI Realtime WebRTC：POST /v1/live 创建 call，
%% GET /v1/live/{call_id} 为 sideband WebSocket 反向代理。
-module(lg_web_realtime).
-behaviour(cowboy_websocket).

-include_lib("lg_core/include/lg_core.hrl").

-export([init/2, websocket_init/1]).
-export([websocket_handle/2, websocket_info/2, terminate/3]).

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> -> create(Req0, State);
        <<"GET">> -> sideband(Req0, State);
        _ ->
            Req = lg_web_util:error_reply(openai, 405, <<"invalid_request_error">>,
                                          <<"Method not allowed">>, Req0),
            {ok, Req, State}
    end.

%%--------------------------------------------------------------------
%% 创建 Realtime call
%%--------------------------------------------------------------------

create(Req0, State) ->
    case lg_web_util:authenticate(Req0) of
        {ok, Key} ->
            case lg_web_util:read_raw(Req0) of
                {ok, Body, Req} -> create(Body, Key, Req, State);
                {error, too_large, Req} ->
                    Req1 = lg_web_util:error_reply(openai, 413, <<"invalid_request_error">>,
                                                   <<"Request body too large">>, Req),
                    {ok, Req1, State}
            end;
        _ ->
            Req = lg_web_util:error_reply(openai, 401, <<"authentication_error">>,
                                          <<"Invalid API key">>, Req0),
            {ok, Req, State}
    end.

create(Body, Key, Req0, State) ->
    CT = cowboy_req:header(<<"content-type">>, Req0, <<>>),
    case session(Body, CT) of
        {ok, #{<<"model">> := Model} = Session} when is_binary(Model) ->
            Id = lg_store:new_id(),
            Req = cowboy_req:set_resp_header(<<"x-request-id">>, Id, Req0),
            {Client, UA} = lg_client:detect(cowboy_req:headers(Req), openai),
            Ctx = #{key => Key, id => Id, kind => live, client => Client, user_agent => UA,
                    traceparent => cowboy_req:header(<<"traceparent">>, Req)},
            lg_live:request_start(Id, #{route => Model, client => Client,
                                        key_name => Key#lg_api_key.name, stream => true,
                                        format => live}),
            Res = lg_router:live(#{<<"model">> => Model, <<"body">> => Body,
                                   <<"content_type">> => CT}, Ctx),
            reply(Res, Session, Ctx, Req, State);
        {ok, _} ->
            bad_request(<<"Missing field: model">>, Req0, State);
        {error, Msg} ->
            bad_request(Msg, Req0, State)
    end.

reply({ok, Resp, Out}, Session, #{key := Key} = Ctx, Req0, State) ->
    CallId = maps:get(call_id, Resp),
    CId = maps:get(credential, Out),
    Base = case lg_credentials:get(CId) of
               {ok, #lg_credential{options = O, base_url = B}} ->
                   trim(maps:get(live_base_url, O, B));
               not_found -> maps:get(live_base, Resp)
           end,
    ok = lg_realtime:put(CallId, #{key => Key#lg_api_key.id, credential => CId,
                                   base => Base}),
    lg_web_llm_log:record(Ctx, openai, false, Session, Out, maps:get(status, Resp, 200)),
    CT = case lists:keyfind(<<"content-type">>, 1, maps:get(headers, Resp, [])) of
             {_, V} -> V;
             false -> <<"application/sdp">>
         end,
    Req = cowboy_req:reply(maps:get(status, Resp, 200),
                           #{<<"content-type">> => CT,
                             <<"location">> => <<"/v1/live/", CallId/binary>>},
                           maps:get(body, Resp, <<>>), Req0),
    {ok, Req, State};
reply({error, Err, Out}, _Session, Ctx, Req, State) ->
    {Status, _Type, Msg} = lg_web_llm_error:response(openai, Err, Out),
    Out1 = Out#{error => Err},
    lg_web_llm_log:record(Ctx, openai, false, #{}, Out1, Status),
    Req1 = case lg_web_llm_error:retry_after(Err) of
               undefined -> Req;
               S -> cowboy_req:set_resp_header(<<"retry-after">>, integer_to_binary(S), Req)
           end,
    Req2 = lg_web_util:error_reply(openai, Status, error_type(Status), message(Msg), Req1),
    {ok, Req2, State}.

%%--------------------------------------------------------------------
%% Sideband WebSocket
%%--------------------------------------------------------------------

sideband(Req0, State) ->
    case lg_web_util:authenticate(Req0) of
        {ok, #lg_api_key{id = KeyId}} ->
            case cowboy_req:path_info(Req0) of
                [CallId] when byte_size(CallId) > 0 ->
                    case lg_realtime:get(CallId) of
                        {ok, #{key := KeyId} = Info} ->
                            connect(CallId, Info, Req0, State);
                        {ok, _} ->
                            Req = lg_web_util:error_reply(openai, 404, <<"not_found_error">>,
                                                          <<"Realtime call not found">>, Req0),
                            {ok, Req, State};
                        not_found ->
                            Req = lg_web_util:error_reply(openai, 404, <<"not_found_error">>,
                                                          <<"Realtime call not found">>, Req0),
                            {ok, Req, State}
                    end;
                _ ->
                    Req = lg_web_util:error_reply(openai, 404, <<"not_found_error">>,
                                                  <<"Realtime call not found">>, Req0),
                    {ok, Req, State}
            end;
        _ ->
            Req = lg_web_util:error_reply(openai, 401, <<"authentication_error">>,
                                          <<"Invalid API key">>, Req0),
            {ok, Req, State}
    end.

connect(CallId, #{credential := CId, base := Base}, Req, _State) ->
    {cowboy_websocket, Req, #{call_id => CallId, credential => CId, base => Base}}.

websocket_init(#{call_id := CallId, credential := CId, base := Base} = State) ->
    case lg_credentials:get(CId) of
        {ok, #lg_credential{} = Cred} ->
            case upstream_ws(CallId, Base, Cred) of
                {ok, Conn, Ref} ->
                    %% gun 进程以 retry => 0 打开：上游断开后进程退出，monitor 兜底（T19）
                    MRef = monitor(process, Conn),
                    {ok, State#{conn => Conn, ref => Ref, mref => MRef}};
                {error, _} -> {stop, State}
            end;
        not_found ->
            {stop, State}
    end.

upstream_ws(CallId, Base, Cred) ->
    #{scheme := Scheme, host := Host} = U = uri_string:parse(Base),
    {Transport, Port} = case string:lowercase(Scheme) of
                            <<"https">> -> {tls, maps:get(port, U, 443)};
                            <<"http">> -> {tcp, maps:get(port, U, 80)}
                        end,
    Path0 = maps:get(path, U, <<>>),
    Path1 = case Path0 of <<>> -> <<>>; _ -> trim(Path0) end,
    Path = <<$/, Path1/binary, "/live/", CallId/binary>>,
    %% 与连接池同一套选项：HTTP/1.1（WebSocket 升级）+ TLS 证书与主机名校验、SNI
    case lg_http_pool:conn_opts(Transport, binary_to_list(Host)) of
        {ok, Opts} -> upstream_ws_open(Host, Port, Opts, Path, Cred);
        {error, _} = Err -> Err
    end.

upstream_ws_open(Host, Port, Opts, Path, Cred) ->
    case gun:open(binary_to_list(Host), Port, Opts) of
        {ok, Conn} ->
            case gun:await_up(Conn, lg_config:get(upstream_connect_timeout_ms)) of
                {ok, _} ->
                    case lg_provider:auth_headers(openai, Cred, openai, #{}) of
                        {ok, AuthH} ->
                            Headers = lists:keydelete(<<"content-type">>, 1,
                                                      lists:keydelete(<<"accept">>, 1, AuthH))
                                      ++ Cred#lg_credential.headers,
                            Ref = gun:ws_upgrade(Conn, Path, Headers),
                            receive
                                {gun_upgrade, Conn, _, _, _} ->
                                    {ok, Conn, Ref};
                                {gun_ws_upgrade, Conn, ok, _} ->
                                    {ok, Conn, Ref};
                                {gun_ws_upgrade, Conn, error, _, _} ->
                                    gun:close(Conn),
                                    {error, ws_upgrade_failed};
                                {gun_response, Conn, _, _, Status, _} ->
                                    gun:close(Conn),
                                    {error, {ws_upgrade_failed, Status}};
                                {gun_error, Conn, _, Reason} ->
                                    gun:close(Conn),
                                    {error, Reason};
                                {gun_down, Conn, _, Reason, _} ->
                                    gun:close(Conn),
                                    {error, Reason}
                            after lg_config:get(upstream_connect_timeout_ms) ->
                                gun:close(Conn),
                                {error, ws_upgrade_timeout}
                            end;
                        {error, _} = Err ->
                            gun:close(Conn),
                            Err
                    end;
                {error, Reason} ->
                    gun:close(Conn),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

websocket_handle(Frame, #{conn := Conn, ref := Ref} = State) ->
    gun:ws_send(Conn, Ref, Frame),
    {ok, State};
websocket_handle(_Frame, State) ->
    {ok, State}.

websocket_info({gun_ws, Conn, _, Frame}, #{conn := Conn} = State) ->
    case Frame of
        {close, _, _} -> {stop, State};
        _ -> {reply, Frame, State}
    end;
websocket_info({gun_ws_upgrade, Conn, _, _}, #{conn := Conn} = State) ->
    {ok, State};
%% gun 2.x：gun_down 为 5 元组；gun_error 有连接级（3 元组）与流级（4 元组）两种
websocket_info({gun_down, Conn, _Proto, _Reason, _Killed}, #{conn := Conn} = State) ->
    {stop, State};
websocket_info({gun_error, Conn, _Reason}, #{conn := Conn} = State) ->
    {stop, State};
websocket_info({gun_error, Conn, _StreamRef, _Reason}, #{conn := Conn} = State) ->
    {stop, State};
websocket_info({'DOWN', MRef, process, _, _}, #{mref := MRef} = State) ->
    {stop, State};
websocket_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _Req, #{conn := Conn}) ->
    gun:close(Conn);
terminate(_Reason, _Req, _State) ->
    ok.

%%--------------------------------------------------------------------

session(Body, CT) ->
    case re:run(CT, <<"boundary=([^;]+)">>, [{capture, all_but_first, binary}]) of
        {match, [Boundary]} ->
            case [Part || Seg <- binary:split(Body, <<"--", Boundary/binary>>, [global]),
                          Part <- [part(Seg)],
                          Part =/= undefined,
                          maps:get(name, Part) =:= <<"session">>] of
                [#{content := Content}] ->
                    try json:decode(Content) of
                        M when is_map(M) -> {ok, M};
                        _ -> {error, <<"Invalid session JSON">>}
                    catch
                        error:_ -> {error, <<"Invalid session JSON">>}
                    end;
                _ -> {error, <<"Missing multipart field: session">>}
            end;
        _ ->
            {error, <<"Content-Type must be multipart/form-data">>}
    end.

part(Seg) ->
    case binary:split(Seg, <<"\r\n\r\n">>) of
        [Head, Content0] ->
            case re:run(Head, <<"name=\"([^\"]+)\"">>, [{capture, all_but_first, binary}]) of
                {match, [Name]} ->
                    Content = re:replace(Content0, <<"\r\n$">>, <<>>, [{return, binary}]),
                    #{name => Name, content => Content};
                nomatch ->
                    undefined
            end;
        _ ->
            undefined
    end.

bad_request(Msg, Req, State) ->
    Req1 = lg_web_util:error_reply(openai, 400, <<"invalid_request_error">>, Msg, Req),
    {ok, Req1, State}.

error_type(Status) when Status >= 500 -> <<"api_error">>;
error_type(429) -> <<"rate_limit_error">>;
error_type(_) -> <<"invalid_request_error">>.

message({raw, Body}) -> Body;
message(Msg) -> Msg.

trim(<<$/, Rest/binary>>) -> trim(Rest);
trim(Bin) when byte_size(Bin) > 0 ->
    case binary:at(Bin, byte_size(Bin) - 1) of
        $/ -> binary:part(Bin, 0, byte_size(Bin) - 1);
        _ -> Bin
    end;
trim(Bin) -> Bin.
