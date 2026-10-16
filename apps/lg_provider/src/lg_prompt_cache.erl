%% @doc 自动提示缓存（凭证 options.prompt_cache = "auto"，仅 Anthropic 协议上游）。
%%
%% 客户端请求里没有任何 cache_control 时，在三处加 `cache_control: {type: ephemeral}`：
%% 系统提示的最后一块、工具定义的最后一个、最后一条用户消息的最后一个内容块（Anthropic 最多 4 个断点）。
%% 客户端已自带 cache_control（如 Claude Code）时原样不动。
-module(lg_prompt_cache).

-export([apply/1]).

-define(MARK, #{<<"type">> => <<"ephemeral">>}).

-spec apply(map()) -> map().
apply(Body) ->
    case has_marks(Body) of
        true -> Body;
        false -> last_user(tools(system(Body)))
    end.

has_marks(Body) ->
    Blocks = blocks(maps:get(<<"system">>, Body, null))
        ++ list(maps:get(<<"tools">>, Body, []))
        ++ lists:append([blocks(maps:get(<<"content">>, M, null)) || M <- list(maps:get(<<"messages">>, Body, []))]),
    lists:any(fun(B) -> is_map(B) andalso maps:is_key(<<"cache_control">>, B) end, Blocks).

system(#{<<"system">> := S} = Body) when is_binary(S), S =/= <<>> ->
    Body#{<<"system">> => [#{<<"type">> => <<"text">>, <<"text">> => S, <<"cache_control">> => ?MARK}]};
system(#{<<"system">> := [_ | _] = L} = Body) ->
    Body#{<<"system">> => mark_last(L)};
system(Body) ->
    Body.

tools(#{<<"tools">> := [_ | _] = L} = Body) -> Body#{<<"tools">> => mark_last(L)};
tools(Body) -> Body.

last_user(#{<<"messages">> := Msgs} = Body) when is_list(Msgs) ->
    case lists:splitwith(fun(M) -> maps:get(<<"role">>, M, null) =/= <<"user">> end, lists:reverse(Msgs)) of
        {After, [#{<<"content">> := C} = U | Before]} ->
            U1 = case C of
                     T when is_binary(T), T =/= <<>> ->
                         U#{<<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => T, <<"cache_control">> => ?MARK}]};
                     [_ | _] ->
                         U#{<<"content">> => mark_last(C)};
                     _ ->
                         U
                 end,
            Body#{<<"messages">> => lists:reverse(After ++ [U1 | Before])};
        _ ->
            Body
    end;
last_user(Body) ->
    Body.

%% 最后一个可缓存的块（thinking 块不能加 cache_control）
mark_last(L) ->
    {Tail, Head} = lists:splitwith(fun(B) -> not cacheable(B) end, lists:reverse(L)),
    case Head of
        [B | Rest] -> lists:reverse(Tail ++ [B#{<<"cache_control">> => ?MARK} | Rest]);
        [] -> L
    end.

cacheable(#{<<"type">> := T}) when T =:= <<"thinking">>; T =:= <<"redacted_thinking">> -> false;
cacheable(B) -> is_map(B).

blocks(L) when is_list(L) -> L;
blocks(_) -> [].

list(L) when is_list(L) -> L;
list(_) -> [].
