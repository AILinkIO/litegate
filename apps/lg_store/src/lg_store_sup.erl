-module(lg_store_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% rest_for_one：句柄持有者在最前，写者 / 检索索引 / 清理崩溃重启都不会关闭句柄；
%% 句柄持有者自身重启时其后进程一并重启（拿新句柄）
init([]) ->
    SupFlags = #{strategy => rest_for_one, intensity => 5, period => 10},
    Children = [#{id => lg_store_handles, start => {lg_store_handles, start_link, []},
                  shutdown => 10000},
                #{id => lg_store_indexer, start => {lg_store_indexer, start_link, []},
                  shutdown => 5000},
                #{id => lg_store_writer, start => {lg_store_writer, start_link, []},
                  shutdown => 30000},
                #{id => lg_store_janitor, start => {lg_store_janitor, start_link, []},
                  shutdown => 5000}],
    {ok, {SupFlags, Children}}.
