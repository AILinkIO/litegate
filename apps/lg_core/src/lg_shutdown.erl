%% @doc 关停标记：节点开始关停（lg_web 停止监听之前）时置位。
%%
%% 在途请求据此放弃整轮重试与换候选，尽快结束并记账——docker stop 默认只给 10 秒，
%% 超时即 SIGKILL，bitcask 写锁来不及释放。
-module(lg_shutdown).

-export([begin_drain/0, end_drain/0, draining/0]).

-spec begin_drain() -> ok.
begin_drain() ->
    persistent_term:put({?MODULE, draining}, true).

%% 监听已关闭、在途请求已结束后清除：同一 VM 里应用可能被重新启动（如测试）
-spec end_drain() -> ok.
end_drain() ->
    _ = persistent_term:erase({?MODULE, draining}),
    ok.

-spec draining() -> boolean().
draining() ->
    persistent_term:get({?MODULE, draining}, false).
