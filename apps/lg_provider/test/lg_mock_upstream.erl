%% @doc 测试用模拟上游：cowboy 监听随机端口，按队列依次返回预设响应并记录请求。
%%
%% 响应形式：
%%   {json, Status, Headers, Body}     Body 为 map 或 binary
%%   {sse, Frames}                     200 + text/event-stream，逐帧发送
%%   {sse_slow, Frames, DelayMs}       每帧之间暂停 DelayMs
%%   {delay, Ms, Resp}                 先等待 Ms 再按 Resp 回复
%%   {raw, Status, ContentType, Body}  原样返回（如 HTML 页面）
-module(lg_mock_upstream).
-behaviour(cowboy_handler).

-export([start/0, stop/0, expect/1, requests/0, init/2]).

-define(TAB, ?MODULE).

start() ->
    {ok, _} = application:ensure_all_started(cowboy),
    Parent = self(),
    %% ets 表由独立进程持有，不随测试进程退出
    Owner = spawn(fun() ->
                          ?TAB = ets:new(?TAB, [named_table, public]),
                          Parent ! ready,
                          receive stop -> ok end
                  end),
    receive ready -> ok end,
    ets:insert(?TAB, [{responses, []}, {requests, []}, {owner, Owner}]),
    Dispatch = cowboy_router:compile([{'_', [{"/v1/live", ?MODULE, []},
                                              {"/v1/live/[...]", lg_mock_ws_upstream, []},
                                              {"/[...]", ?MODULE, []}]}]),
    {ok, _} = cowboy:start_clear(?MODULE, [{port, 0}],
                                 #{env => #{dispatch => Dispatch}, idle_timeout => 2000}),
    ranch:get_port(?MODULE).

stop() ->
    ok = cowboy:stop_listener(?MODULE),
    [{owner, Owner}] = ets:lookup(?TAB, owner),
    Owner ! stop.

expect(Resp) ->
    [{responses, L}] = ets:lookup(?TAB, responses),
    ets:insert(?TAB, {responses, L ++ [Resp]}).

%% 按到达顺序返回 [#{path, headers, body}]
requests() ->
    [{requests, L}] = ets:lookup(?TAB, requests),
    lists:reverse(L).

init(Req0, State) ->
    {ok, Body, Req} = cowboy_req:read_body(Req0),
    Decoded = try json:decode(Body) catch error:_ -> Body end,
    [{requests, Rs}] = ets:lookup(?TAB, requests),
    ets:insert(?TAB, {requests, [#{path => cowboy_req:path(Req),
                                    headers => cowboy_req:headers(Req),
                                    body => Decoded} | Rs]}),
    [{responses, [Resp | Rest]}] = ets:lookup(?TAB, responses),
    ets:insert(?TAB, {responses, Rest}),
    {ok, reply(Resp, Req), State}.

reply({delay, Ms, Resp}, Req) ->
    timer:sleep(Ms),
    reply(Resp, Req);
reply({raw, Status, CT, Body}, Req) ->
    cowboy_req:reply(Status, #{<<"content-type">> => CT}, Body, Req);
reply({json, Status, Headers, Body}, Req) ->
    B = case is_map(Body) of true -> json:encode(Body); false -> Body end,
    cowboy_req:reply(Status, maps:merge(#{<<"content-type">> => <<"application/json">>}, Headers),
                     B, Req);
reply({sse, Frames}, Req) ->
    reply({sse_slow, Frames, 0}, Req);
reply({sse_slow, Frames, Delay}, Req0) ->
    Req = cowboy_req:stream_reply(200, #{<<"content-type">> => <<"text/event-stream">>}, Req0),
    lists:foreach(fun(F) ->
                          cowboy_req:stream_body(F, nofin, Req),
                          Delay > 0 andalso timer:sleep(Delay)
                  end, Frames),
    cowboy_req:stream_body(<<>>, fin, Req),
    Req.
