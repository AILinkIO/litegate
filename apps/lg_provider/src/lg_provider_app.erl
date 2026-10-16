-module(lg_provider_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    lg_provider_sup:start_link().

stop(_State) ->
    ok.
