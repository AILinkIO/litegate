%% @doc lg_config 已解析值缓存的 ETS 表 owner（T18）。
%%
%% 表随 lg_core 启停：应用重启（含测试里换数据目录）后缓存必然为空，不会读到上一轮的旧值。
%% 表在本进程 init 里创建，避免惰性建表时 owner 落在短命的请求进程上。
%% 读写都由调用方直接操作 ETS（public），本进程只负责持有表。
-module(lg_config_cache).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, lg_config_cache).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    ?TAB = ets:new(?TAB, [named_table, public, set, {read_concurrency, true}]),
    {ok, #{}}.

handle_call(_Req, _From, S) ->
    {reply, ok, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(_Msg, S) ->
    {noreply, S}.
