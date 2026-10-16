%% @doc 内置中间件 word_guard：敏感词。
%% options：#{"words" => [词], "mode" => "reject"（默认，最后一条用户消息含敏感词时拒绝）| "mask"（回复里的词替换成 ***）,
%%           "message" => 拒绝时的提示（可选）}
%% mask 处理非流式回复与流式正文增量；流式按分片处理，词恰好被切在两个分片之间时不会被替换。
%% 匹配不区分英文大小写。
-module(lg_mw_word_guard).
-behaviour(lg_middleware).

-export([describe/0, validate/1, hooks/1, on_request/3, on_event/3, on_response/3]).

describe() ->
    #{title => <<"敏感词"/utf8>>,
      description => <<"请求含敏感词时拒绝，或把回复里的敏感词替换成 ***"/utf8>>,
      options_example => #{<<"words">> => [<<"示例敏感词"/utf8>>], <<"mode">> => <<"reject">>}}.

validate(#{<<"words">> := [_ | _] = Ws} = O) ->
    case lists:all(fun(W) -> is_binary(W) andalso W =/= <<>> end, Ws) of
        false -> {error, <<"words must be non-empty strings">>};
        true ->
            case maps:get(<<"mode">>, O, <<"reject">>) of
                M when M =:= <<"reject">>; M =:= <<"mask">> -> ok;
                _ -> {error, <<"mode must be reject or mask">>}
            end
    end;
validate(_) ->
    {error, <<"options.words is required (non-empty list)">>}.

%% reject 只需要请求点位；mask 只需要事件与响应点位（不让无关的流式事件被解析）
hooks(O) ->
    case maps:get(<<"mode">>, O, <<"reject">>) of
        <<"mask">> -> [on_event, on_response];
        _ -> [on_request]
    end.

on_request(Body, Ctx, #{<<"words">> := Ws} = O) ->
    case maps:get(<<"mode">>, O, <<"reject">>) of
        <<"reject">> ->
            Text = lg_mw:last_user_text(Body, Ctx),
            case hit(Text, Ws) of
                true -> {reject, 400, maps:get(<<"message">>, O, <<"Request contains blocked content">>)};
                false -> continue
            end;
        _ -> continue
    end.

on_event(Ev, Ctx, #{<<"words">> := Ws}) ->
    case lg_mw:event_text(Ev, Ctx) of
        T when is_binary(T), T =/= <<>> ->
            case mask(T, Ws) of
                T -> continue;
                T1 -> {ok, lg_mw:set_event_text(Ev, Ctx, T1)}
            end;
        _ -> continue
    end.

on_response(Body, Ctx, #{<<"words">> := Ws}) ->
    {ok, lg_mw:set_response_text(Body, Ctx, fun(T) -> mask(T, Ws) end)}.

hit(Text, Ws) ->
    L = lower(Text),
    lists:any(fun(W) -> binary:match(L, lower(W)) =/= nomatch end, Ws).

mask(Text, Ws) ->
    lists:foldl(fun(W, T) ->
                        Re = <<"(?i)", (re_escape(W))/binary>>,
                        re:replace(T, Re, <<"***">>, [global, unicode, {return, binary}])
                end, Text, Ws).

re_escape(W) ->
    re:replace(W, <<"[\\\\^$.|?*+()\\[\\]{}]">>, <<"\\\\&">>, [global, unicode, {return, binary}]).

lower(B) ->
    case string:lowercase(B) of
        L when is_binary(L) -> L;
        _ -> B
    end.
