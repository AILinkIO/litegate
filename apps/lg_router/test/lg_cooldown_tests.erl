%% @doc T19：lg_cooldown 启动即调度周期清扫（此前只在 handle_info(sweep) 里续期，首次从未调度）。
-module(lg_cooldown_tests).

-include_lib("eunit/include/eunit.hrl").

sweep_scheduled_test() ->
    Dir = lg_core_test_util:start(),
    try
        {ok, _} = application:ensure_all_started(lg_router),
        #{sweep := TRef} = sys:get_state(lg_cooldown),
        ?assert(is_integer(erlang:read_timer(TRef))),
        %% 处理一次 sweep 后重新调度
        lg_cooldown ! sweep,
        #{sweep := TRef2} = sys:get_state(lg_cooldown),
        ?assertNotEqual(TRef, TRef2),
        ?assert(is_integer(erlang:read_timer(TRef2)))
    after
        application:stop(lg_router),
        lg_core_test_util:stop(Dir)
    end.
