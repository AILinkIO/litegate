%% @doc 通配路由前缀缓存的 ETS 表 owner（T16）。
%%
%% 表在 init 里创建并立即从路由表全量构建，进程常驻于 lg_router_sup：
%% 重启后首个请求即可命中通配路由，表也不会随某个请求进程退出而销毁。
%% 重建经本进程串行执行（先插入新条目、再删除失效条目），重建过程中读者始终能看到完整集合。
%%
%% 表结构（ordered_set）：{{-PrefixLen, Prefix}, RouteName}，前缀最长的排在最前。
-module(lg_route_cache).
-behaviour(gen_server).

-include_lib("lg_core/include/lg_core.hrl").

-export([start_link/0, rebuild/0, wildcards/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, lg_route_wildcards).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc 从路由表重建缓存；进程未运行（lg_router 未启动）时为空操作，读者会回退到直接扫描路由表。
-spec rebuild() -> ok.
rebuild() ->
    try gen_server:call(?MODULE, rebuild, 30000)
    catch exit:{noproc, _} -> ok
    end.

%% @doc 通配路由列表，前缀最长的在前：[{PrefixLen, Prefix, RouteName}]。
%% 缓存不可用时直接扫描路由表。
-spec wildcards() -> [{non_neg_integer(), binary(), binary()}].
wildcards() ->
    try ets:tab2list(?TAB) of
        Rows -> [{-NegLen, P, RN} || {{NegLen, P}, RN} <- Rows]
    catch
        error:badarg -> [{-NegLen, P, RN} || {{NegLen, P}, RN} <- lists:sort(scan())]
    end.

init([]) ->
    ?TAB = ets:new(?TAB, [named_table, protected, ordered_set, {read_concurrency, true}]),
    ok = do_rebuild(),
    {ok, #{}}.

handle_call(rebuild, _From, S) ->
    {reply, do_rebuild(), S};
handle_call(_Req, _From, S) ->
    {reply, ok, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(_Msg, S) ->
    {noreply, S}.

do_rebuild() ->
    New = scan(),
    true = ets:insert(?TAB, New),
    Keep = maps:from_list([{K, true} || {K, _} <- New]),
    _ = [ets:delete(?TAB, K) || K <- ets:select(?TAB, [{{'$1', '_'}, [], ['$1']}]),
                                not maps:is_key(K, Keep)],
    ok.

scan() ->
    [{{-byte_size(P), P}, N}
     || #lg_route{name = N} <- lg_db:all(lg_route),
        lg_routes:is_wildcard(N),
        P <- [lg_routes:wildcard_prefix(N)]].
