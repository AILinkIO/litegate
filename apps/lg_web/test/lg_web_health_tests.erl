-module(lg_web_health_tests).

-include_lib("eunit/include/eunit.hrl").

%% 存储写盘错误时 /health 返回 degraded（仍为 200）；mnesia 须在运行（未运行时 503，见 lg_web_drain_tests）
degraded_test() ->
    Dir = lg_core_test_util:start(),
    ok = meck:new(lg_store, [passthrough]),
    ok = meck:new(lg_web_util, [passthrough]),
    try
        ok = meck:expect(lg_web_util, json, fun(Status, Body, _Req) -> {Status, Body} end),
        ok = meck:expect(lg_store, health, fun() -> ok end),
        ?assertMatch({ok, {200, #{<<"status">> := <<"ok">>}}, st}, lg_web_health:init(req, st)),
        Info = #{last_write_error_ms => 1, consecutive_errors => 2, backlog => 0},
        ok = meck:expect(lg_store, health, fun() -> {degraded, Info} end),
        ?assertMatch({ok, {200, #{<<"status">> := <<"degraded">>, <<"store">> := Info}}, st},
                     lg_web_health:init(req, st)),
        %% 能编码为 JSON
        ?assert(is_binary(iolist_to_binary(json:encode(#{<<"store">> => Info}))))
    after
        meck:unload([lg_store, lg_web_util]),
        lg_core_test_util:stop(Dir)
    end.
