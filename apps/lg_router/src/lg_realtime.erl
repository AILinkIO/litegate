%% @doc Realtime call registry：保存 WebRTC call id 与上游目标的短暂映射。
%%
%% POST /v1/live 由路由层选择上游；OpenAI 返回的 call id 用于后续
%% GET /v1/live/{call_id} WebSocket sideband。两侧不能直接使用上游 Location，
%% 因此这里记录选中的凭证与 Realtime 基址，默认保留 1 小时以支持重连。
-module(lg_realtime).
-behaviour(gen_server).

-export([start_link/0, put/2, get/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TTL_MS, 3600000).
-define(SWEEP_MS, 60000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec put(binary(), map()) -> ok.
put(CallId, Info) when is_binary(CallId), is_map(Info) ->
    gen_server:cast(?MODULE, {put, CallId, Info}).

-spec get(binary()) -> {ok, map()} | not_found.
get(CallId) ->
    try ets:lookup(?MODULE, CallId) of
        [{_, Info, _}] -> {ok, Info};
        [] -> not_found
    catch
        error:badarg -> not_found
    end.

init([]) ->
    ?MODULE = ets:new(?MODULE, [named_table, public, {read_concurrency, true}]),
    erlang:send_after(?SWEEP_MS, self(), sweep),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({put, CallId, Info}, State) ->
    ets:insert(?MODULE, {CallId, Info, lg_time:now_ms() + ?TTL_MS}),
    {noreply, State};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(sweep, State) ->
    Now = lg_time:now_ms(),
    ets:select_delete(?MODULE, [{{'$1', '_', '$2'}, [{'=<', '$2', {const, Now}}], [true]}]),
    erlang:send_after(?SWEEP_MS, self(), sweep),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.
