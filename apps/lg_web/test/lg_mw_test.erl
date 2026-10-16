%% @doc 测试用中间件：options.mode 决定行为。
-module(lg_mw_test).
-behaviour(lg_middleware).

-export([describe/0, on_request/3, on_event/3, on_response/3]).

describe() ->
    #{title => <<"test">>, description => <<"test">>, options_example => #{}}.

on_request(_Body, _Ctx, #{<<"mode">> := <<"reject">>}) -> {reject, 403, <<"blocked by middleware">>};
on_request(_Body, _Ctx, #{<<"mode">> := <<"crash">>}) -> error(boom);
on_request(_Body, _Ctx, #{<<"mode">> := <<"slow">>}) -> timer:sleep(1000), {reject, 403, <<"too late">>};
on_request(Body, _Ctx, _O) -> {ok, Body, #{seen => maps:get(<<"model">>, Body)}}.

%% OpenAI 流式：正文改成大写；state 来自 on_request
on_event(#{data := #{<<"choices">> := [#{<<"delta">> := #{<<"content">> := C} = D} = Ch]} = J} = Ev, #{state := #{seen := _}}, _O)
  when is_binary(C) ->
    {ok, Ev#{data => J#{<<"choices">> => [Ch#{<<"delta">> => D#{<<"content">> => string:uppercase(C)}}]}}};
on_event(_Ev, _Ctx, #{<<"mode">> := <<"event_crash">>}) -> error(boom);
on_event(_Ev, _Ctx, _O) -> continue.

on_response(Body, #{state := #{seen := M}}, _O) -> {ok, Body#{<<"x_mw_seen">> => M}};
on_response(_Body, _Ctx, _O) -> continue.
