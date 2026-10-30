%% @doc T19：realtime 会话按 gun 2.x 的消息格式感知上游断开。
-module(lg_web_realtime_tests).

-include_lib("eunit/include/eunit.hrl").

upstream_down_stops_session_test_() ->
    Conn = spawn(fun() -> receive stop -> ok end end),
    MRef = make_ref(),
    St = #{conn => Conn, ref => make_ref(), mref => MRef},
    Other = spawn(fun() -> ok end),
    [?_assertMatch({stop, _}, lg_web_realtime:websocket_info({gun_down, Conn, http, closed, []}, St)),
     ?_assertMatch({stop, _}, lg_web_realtime:websocket_info({gun_error, Conn, make_ref(), closed}, St)),
     ?_assertMatch({stop, _}, lg_web_realtime:websocket_info({gun_error, Conn, closed}, St)),
     ?_assertMatch({stop, _}, lg_web_realtime:websocket_info({'DOWN', MRef, process, Conn, normal}, St)),
     %% 其他连接的消息不影响本会话
     ?_assertMatch({ok, _}, lg_web_realtime:websocket_info({gun_down, Other, http, closed, []}, St))].
