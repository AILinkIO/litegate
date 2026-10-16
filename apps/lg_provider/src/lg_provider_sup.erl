-module(lg_provider_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    Children = [#{id => lg_http_pool,
                  start => {lg_http_pool, start_link, []}}],
    {ok, {SupFlags, Children}}.
