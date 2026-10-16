-module(lg_web_redirect).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req, #{to := To} = State) ->
    {ok, cowboy_req:reply(302, #{<<"location">> => To}, Req), State}.
