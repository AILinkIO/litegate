%% @doc 中间件辅助函数：按 Ctx 的 format（openai / anthropic / responses）读写三种接口格式里的消息与正文。
%% 内置中间件与插件共用；远程节点上的中间件不依赖它（需要时可以把这个模块一起部署过去）。
-module(lg_mw).

-export([messages/2, last_user_text/2, add_system/4,
         event_text/2, set_event_text/3,
         response_text/2, set_response_text/3]).

-type format() :: openai | anthropic | responses.

fmt(#{format := F}) -> F;
fmt(F) when is_atom(F) -> F.

%%====================================================================
%% 请求
%%====================================================================

%% @doc 对话消息（Responses 为 input 中带 role 的项；input 是字符串时视为一条用户消息）。
-spec messages(map(), map() | format()) -> [map()].
messages(#{<<"input">> := In}, Ctx) when is_binary(In) ->
    responses = fmt(Ctx),
    [#{<<"role">> => <<"user">>, <<"content">> => In}];
messages(Body, Ctx) ->
    Key = case fmt(Ctx) of responses -> <<"input">>; _ -> <<"messages">> end,
    [M || M <- list(maps:get(Key, Body, [])), is_map(M), maps:is_key(<<"role">>, M)].

%% @doc 最后一条用户消息的文字（内容块中的文字拼接，忽略工具结果与图片）。
-spec last_user_text(map(), map() | format()) -> binary().
last_user_text(Body, Ctx) ->
    case [M || #{<<"role">> := <<"user">>} = M <- messages(Body, Ctx)] of
        [] -> <<>>;
        Us -> text(maps:get(<<"content">>, lists:last(Us), <<>>))
    end.

%% @doc 追加（append）或前置（prepend）一段系统提示。
-spec add_system(map(), map() | format(), binary(), append | prepend) -> map().
add_system(Body, Ctx, T, Pos) ->
    case fmt(Ctx) of
        anthropic ->
            Blocks = case maps:get(<<"system">>, Body, []) of
                         S when is_binary(S), S =/= <<>> -> [#{<<"type">> => <<"text">>, <<"text">> => S}];
                         L when is_list(L) -> L;
                         _ -> []
                     end,
            New = [#{<<"type">> => <<"text">>, <<"text">> => T}],
            Body#{<<"system">> => case Pos of prepend -> New ++ Blocks; append -> Blocks ++ New end};
        responses ->
            Ins = case maps:get(<<"instructions">>, Body, null) of
                      S when is_binary(S), S =/= <<>> ->
                          case Pos of prepend -> <<T/binary, "\n\n", S/binary>>; append -> <<S/binary, "\n\n", T/binary>> end;
                      _ -> T
                  end,
            Body#{<<"instructions">> => Ins};
        openai ->
            Ms = list(maps:get(<<"messages">>, Body, [])),
            Sys = #{<<"role">> => <<"system">>, <<"content">> => T},
            case Pos of
                prepend -> Body#{<<"messages">> => [Sys | Ms]};
                append ->
                    %% 放在已有的系统消息之后（没有时放在最前）
                    {Lead, Rest} = lists:splitwith(fun(#{<<"role">> := R}) -> R =:= <<"system">> orelse R =:= <<"developer">>;
                                                      (_) -> false end, Ms),
                    Body#{<<"messages">> => Lead ++ [Sys | Rest]}
            end
    end.

%%====================================================================
%% 流式事件（Event = #{event, data}，data 为解码后的 JSON）
%%====================================================================

%% @doc 事件里的正文增量；不是正文增量的事件返回 undefined。
-spec event_text(map(), map() | format()) -> binary() | undefined.
event_text(#{data := D}, Ctx) ->
    case {fmt(Ctx), D} of
        {openai, #{<<"choices">> := [#{<<"delta">> := #{<<"content">> := T}} | _]}} when is_binary(T) -> T;
        {anthropic, #{<<"type">> := <<"content_block_delta">>, <<"delta">> := #{<<"type">> := <<"text_delta">>, <<"text">> := T}}} -> T;
        {responses, #{<<"type">> := <<"response.output_text.delta">>, <<"delta">> := T}} when is_binary(T) -> T;
        _ -> undefined
    end;
event_text(_, _) ->
    undefined.

%% @doc 替换事件里的正文增量（不是正文增量的事件原样返回）。
-spec set_event_text(map(), map() | format(), binary()) -> map().
set_event_text(#{data := D} = Ev, Ctx, T) ->
    case {fmt(Ctx), D} of
        {openai, #{<<"choices">> := [#{<<"delta">> := #{<<"content">> := C} = Dl} = Ch | Rest]}} when is_binary(C) ->
            Ev#{data => D#{<<"choices">> => [Ch#{<<"delta">> => Dl#{<<"content">> => T}} | Rest]}};
        {anthropic, #{<<"type">> := <<"content_block_delta">>, <<"delta">> := #{<<"type">> := <<"text_delta">>} = Dl}} ->
            Ev#{data => D#{<<"delta">> => Dl#{<<"text">> => T}}};
        {responses, #{<<"type">> := <<"response.output_text.delta">>}} ->
            Ev#{data => D#{<<"delta">> => T}};
        _ -> Ev
    end;
set_event_text(Ev, _, _) ->
    Ev.

%%====================================================================
%% 非流式回复
%%====================================================================

%% @doc 回复正文（多段拼接）。
-spec response_text(map(), map() | format()) -> binary().
response_text(Body, Ctx) ->
    case fmt(Ctx) of
        openai ->
            case Body of
                #{<<"choices">> := [#{<<"message">> := #{<<"content">> := T}} | _]} when is_binary(T) -> T;
                _ -> <<>>
            end;
        anthropic -> text(maps:get(<<"content">>, Body, []));
        responses ->
            iolist_to_binary([T || #{<<"type">> := <<"message">>, <<"content">> := C} <- list(maps:get(<<"output">>, Body, [])),
                                   #{<<"type">> := <<"output_text">>, <<"text">> := T} <- list(C)])
    end.

%% @doc 用函数改写回复正文的每一段（F :: fun((binary()) -> binary())），也可以直接给新文本（只替换第一段，其余清空）。
-spec set_response_text(map(), map() | format(), binary() | fun((binary()) -> binary())) -> map().
set_response_text(Body, Ctx, T) when is_binary(T) ->
    {B, _} = map_texts(Body, fmt(Ctx), fun(_, true) -> T; (_, false) -> <<>> end),
    B;
set_response_text(Body, Ctx, F) when is_function(F, 1) ->
    {B, _} = map_texts(Body, fmt(Ctx), fun(X, _) -> F(X) end),
    B.

%% F(Text, IsFirst)
map_texts(#{<<"choices">> := Cs} = Body, openai, F) when is_list(Cs) ->
    {Cs1, _} = lists:mapfoldl(fun(#{<<"message">> := #{<<"content">> := T} = M} = C, First) when is_binary(T) ->
                                      {C#{<<"message">> => M#{<<"content">> => F(T, First)}}, false};
                                 (C, First) -> {C, First}
                              end, true, Cs),
    {Body#{<<"choices">> => Cs1}, ok};
map_texts(#{<<"content">> := Bs} = Body, anthropic, F) when is_list(Bs) ->
    {Bs1, _} = lists:mapfoldl(fun(#{<<"type">> := <<"text">>, <<"text">> := T} = B, First) -> {B#{<<"text">> => F(T, First)}, false};
                                 (B, First) -> {B, First}
                              end, true, Bs),
    {Body#{<<"content">> => Bs1}, ok};
map_texts(#{<<"output">> := Os} = Body, responses, F) when is_list(Os) ->
    {Os1, _} = lists:mapfoldl(
                 fun(#{<<"type">> := <<"message">>, <<"content">> := Cs} = O, First0) when is_list(Cs) ->
                         {Cs1, First1} = lists:mapfoldl(fun(#{<<"type">> := <<"output_text">>, <<"text">> := T} = C, First) ->
                                                                {C#{<<"text">> => F(T, First)}, false};
                                                           (C, First) -> {C, First}
                                                        end, First0, Cs),
                         {O#{<<"content">> => Cs1}, First1};
                    (O, First) -> {O, First}
                 end, true, Os),
    %% output_text 是 SDK 方便字段，同步改写
    Body1 = Body#{<<"output">> => Os1},
    {case Body1 of
         #{<<"output_text">> := OT} when is_binary(OT) -> Body1#{<<"output_text">> => F(OT, true)};
         _ -> Body1
     end, ok};
map_texts(Body, _, _) ->
    {Body, ok}.

%%====================================================================

text(T) when is_binary(T) -> T;
text(L) when is_list(L) ->
    iolist_to_binary(lists:join(<<"\n">>, [T || #{<<"type">> := Ty, <<"text">> := T} <- L, is_binary(T),
                                                 Ty =:= <<"text">> orelse Ty =:= <<"input_text">> orelse Ty =:= <<"output_text">>]));
text(_) -> <<>>.

list(L) when is_list(L) -> L;
list(_) -> [].
