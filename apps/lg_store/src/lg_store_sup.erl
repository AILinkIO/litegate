-module(lg_store_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    Children = [#{id => lg_store_writer, start => {lg_store_writer, start_link, []},
                  shutdown => 30000},
                #{id => lg_store_janitor, start => {lg_store_janitor, start_link, []},
                  shutdown => 5000}],
    {ok, {SupFlags, Children}}.
