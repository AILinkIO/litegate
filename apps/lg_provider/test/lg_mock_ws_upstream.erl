%% @doc Realtime sideband 测试上游：升级成功后回显一个文本帧。
-module(lg_mock_ws_upstream).
-behaviour(cowboy_websocket).

-export([init/2]).
-export([websocket_handle/2, websocket_info/2]).

init(Req, State) ->
    {cowboy_websocket, Req, State}.

websocket_handle({text, Data}, State) ->
    {reply, {text, Data}, State};
websocket_handle(_Frame, State) ->
    {ok, State}.

websocket_info(_Info, State) ->
    {ok, State}.
