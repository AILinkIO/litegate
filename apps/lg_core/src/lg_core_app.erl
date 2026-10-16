-module(lg_core_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    case lg_crypto:init() of
        ok ->
            case lg_schema:init() of
                ok -> lg_core_sup:start_link();
                {error, Reason} -> {error, {schema, Reason}}
            end;
        {error, Reason} ->
            {error, {crypto, Reason}}
    end.

stop(_State) ->
    ok.
