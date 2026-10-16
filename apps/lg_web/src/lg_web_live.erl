%% @doc 实时事件流（SSE）：GET /api/live/stream，控制台身份鉴权。
%%
%% 连接后先推一条 state（快照，可带 ?route= 选择路由），之后推 lg_live 的事件（event 为事件类型，data 为 JSON）；
%% 每 15 秒一条注释帧保活。订阅进程被丢弃过事件时，下一条事件的 data 带 dropped 计数。
-module(lg_web_live).
-behaviour(cowboy_loop).

-export([init/2, info/3, terminate/3]).

-define(KEEPALIVE_MS, 15000).

init(Req0, _State) ->
    case lg_api:console_admin(Req0) of
        {ok, _User} ->
            Route = case cowboy_req:match_qs([{route, [], undefined}], Req0) of
                        #{route := R} when is_binary(R), R =/= <<>> -> R;
                        _ -> undefined
                    end,
            Req = cowboy_req:stream_reply(200, #{<<"content-type">> => <<"text/event-stream">>,
                                                 <<"cache-control">> => <<"no-cache">>,
                                                 <<"x-accel-buffering">> => <<"no">>}, Req0),
            ok = lg_live:subscribe(),
            send(Req, <<"state">>, lg_live:state(opts(Route))),
            erlang:send_after(?KEEPALIVE_MS, self(), keepalive),
            {cowboy_loop, Req, #{route => Route}};
        {error, Status, Msg} ->
            Req = cowboy_req:reply(Status, #{<<"content-type">> => <<"application/json">>},
                                   json:encode(#{<<"error">> => #{<<"message">> => Msg}}), Req0),
            {ok, Req, #{}}
    end.

info({lg_live, #{type := Type, data := Data} = Ev}, Req, S) ->
    Payload = case lg_live:dropped() of
                  0 -> Data;
                  N -> Data#{dropped => N}
              end,
    send(Req, atom_to_binary(Type), Payload#{ts => maps:get(ts, Ev)}),
    {ok, Req, S};
info(keepalive, Req, S) ->
    cowboy_req:stream_body(<<": keepalive\n\n">>, nofin, Req),
    erlang:send_after(?KEEPALIVE_MS, self(), keepalive),
    {ok, Req, S};
info(_Msg, Req, S) ->
    {ok, Req, S}.

terminate(_Reason, _Req, _S) ->
    catch lg_live:unsubscribe(),
    ok.

opts(undefined) -> #{};
opts(R) -> #{route => R}.

send(Req, Event, Data) ->
    cowboy_req:stream_body(lg_sse:encode(Event, json:encode(clean(Data))), nofin, Req).

%% JSON 可编码：undefined → null，元组 → 列表
clean(M) when is_map(M) -> maps:map(fun(_, V) -> clean(V) end, M);
clean(L) when is_list(L) -> [clean(X) || X <- L];
clean(T) when is_tuple(T) -> [clean(X) || X <- tuple_to_list(T)];
clean(undefined) -> null;
clean(V) -> V.
