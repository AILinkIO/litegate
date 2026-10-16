-module(lg_web_health).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req, State) ->
    {ok, lg_web_util:json(200, #{<<"status">> => <<"ok">>}, Req), State}.
