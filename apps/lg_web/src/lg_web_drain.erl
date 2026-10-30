%% @doc 优雅关停：在途请求计数（cowboy stream handler）与排空等待。
%%
%% 挂在 cowboy_stream_h 之前，每个请求（流）开始 +1、结束 -1，计数放在连接进程自己的进程字典里，
%% 排空时遍历 listener 的连接进程读取求和。空闲 keep-alive 连接计数为 0，不拖慢排空；
%% 连接进程崩溃（terminate/3 来不及执行）时计数随进程消失，不会残留。
%% 关停期间（lg_shutdown:draining/0）HTTP/1.1 响应附带 `connection: close`，
%% 客户端不再复用旧连接发新请求，计数才能归零。
-module(lg_web_drain).
-behaviour(cowboy_stream).

-export([init/3, data/4, info/3, terminate/3, early_error/5]).
-export([active/1, drain/2, await/2]).

-define(KEY, {?MODULE, streams}).
-define(POLL_MS, 100).

-record(state, {next :: any(), close :: boolean()}).

%%====================================================================
%% 排空
%%====================================================================

%% @doc 这些 listener 上正在处理的请求数
-spec active([ranch:ref()]) -> non_neg_integer().
active(Refs) ->
    lists:sum([streams(Pid) || Ref <- Refs, is_listener(Ref), Pid <- ranch:procs(Ref, connections)]).

streams(Pid) ->
    case erlang:process_info(Pid, {dictionary, ?KEY}) of
        {{dictionary, ?KEY}, N} when is_integer(N) -> N;
        _ -> 0   %% 已退出或尚无请求
    end.

%% @doc 暂停监听（不再 accept 新连接）后等待在途请求结束，最多 Timeout 毫秒。
%% 已建立的连接照常服务；随后由调用方 stop_listener 关闭剩余（空闲）连接。
-spec drain([ranch:ref()], non_neg_integer()) -> ok | {timeout, pos_integer()}.
drain(Refs, Timeout) ->
    _ = [ranch:suspend_listener(Ref) || Ref <- Refs, is_listener(Ref)],
    await(Refs, Timeout).

-spec await([ranch:ref()], non_neg_integer()) -> ok | {timeout, pos_integer()}.
await(Refs, Timeout) ->
    await_until(Refs, erlang:monotonic_time(millisecond) + Timeout).

await_until(Refs, Deadline) ->
    case active(Refs) of
        0 ->
            ok;
        N ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true ->
                    {timeout, N};
                false ->
                    timer:sleep(?POLL_MS),
                    await_until(Refs, Deadline)
            end
    end.

is_listener(Ref) ->
    try ranch:get_status(Ref) of
        _ -> true
    catch
        _:_ -> false
    end.

add(D) ->
    _ = put(?KEY, case get(?KEY) of undefined -> D; N -> N + D end),
    ok.

%%====================================================================
%% cowboy_stream 回调：透传给下一个 handler
%%====================================================================

init(StreamID, Req, Opts) ->
    {Commands, Next} = cowboy_stream:init(StreamID, Req, Opts),
    ok = add(1),
    %% HTTP/2 禁止 connection 头，只对 HTTP/1.x 生效（h2 关停由 cowboy 发 GOAWAY）
    Close = maps:get(version, Req, 'HTTP/1.1') =/= 'HTTP/2',
    {commands(Commands, Close), #state{next = Next, close = Close}}.

data(StreamID, IsFin, Data, S = #state{next = Next0, close = Close}) ->
    {Commands, Next} = cowboy_stream:data(StreamID, IsFin, Data, Next0),
    {commands(Commands, Close), S#state{next = Next}}.

info(StreamID, Info, S = #state{next = Next0, close = Close}) ->
    {Commands, Next} = cowboy_stream:info(StreamID, Info, Next0),
    {commands(Commands, Close), S#state{next = Next}}.

terminate(StreamID, Reason, #state{next = Next}) ->
    ok = add(-1),
    cowboy_stream:terminate(StreamID, Reason, Next).

early_error(StreamID, Reason, PartialReq, Resp, Opts) ->
    cowboy_stream:early_error(StreamID, Reason, PartialReq, Resp, Opts).

commands(Commands, true) ->
    case lg_shutdown:draining() of
        true -> [close_header(C) || C <- Commands];
        false -> Commands
    end;
commands(Commands, false) ->
    Commands.

close_header({response, Status, Headers, Body}) ->
    {response, Status, Headers#{<<"connection">> => <<"close">>}, Body};
close_header({headers, Status, Headers}) ->
    {headers, Status, Headers#{<<"connection">> => <<"close">>}};
close_header(Command) ->
    Command.
