-module(lg_router_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    lg_router_sup:start_link().

stop(_State) ->
    ok.
