%% 远程节点中间件示例：运行在你自己的 Erlang 节点上，网关通过分布式 erpc 调用。
%% 不依赖 litegate：参数与返回值都是普通 Erlang 项（JSON 为 binary 键的 map）。
%%
%%   on_request：最后一条用户消息含 config 里的任一关键词时拒绝；否则在请求体里加一个 metadata 标记
%%   on_event：把流式正文里的 "foo" 换成 "bar"（只演示 OpenAI 格式）
%%   on_response：在非流式回复里附加一个字段，说明经过了远程中间件
-module(demo_mw).

-export([on_request/3, on_event/3, on_response/3]).

on_request(Body, Ctx, Config) ->
    Words = maps:get(<<"block">>, Config, []),
    Text = last_user_text(Body),
    case [W || W <- Words, binary:match(Text, W) =/= nomatch] of
        [W | _] -> {reject, 400, <<"blocked by remote middleware: ", W/binary>>};
        [] -> {ok, Body, #{seen_at => erlang:system_time(millisecond), route => maps:get(route, Ctx)}}
    end.

on_event(#{data := #{<<"choices">> := [#{<<"delta">> := #{<<"content">> := C} = D} = Ch | Rest]} = J} = Ev, _Ctx, _Config)
  when is_binary(C) ->
    {ok, Ev#{data => J#{<<"choices">> => [Ch#{<<"delta">> => D#{<<"content">> => binary:replace(C, <<"foo">>, <<"bar">>, [global])}} | Rest]}}};
on_event(_Ev, _Ctx, _Config) ->
    continue.

on_response(Body, #{state := #{seen_at := At}}, _Config) ->
    {ok, Body#{<<"x_remote_middleware">> => #{<<"node">> => atom_to_binary(node()), <<"seen_at">> => At}}};
on_response(_Body, _Ctx, _Config) ->
    continue.

last_user_text(#{<<"messages">> := Ms}) when is_list(Ms) ->
    case [M || #{<<"role">> := <<"user">>} = M <- Ms] of
        [] -> <<>>;
        Us -> text(maps:get(<<"content">>, lists:last(Us), <<>>))
    end;
last_user_text(#{<<"input">> := In}) when is_binary(In) -> In;
last_user_text(_) -> <<>>.

text(T) when is_binary(T) -> T;
text(L) when is_list(L) -> iolist_to_binary([T || #{<<"text">> := T} <- L, is_binary(T)]);
text(_) -> <<>>.
