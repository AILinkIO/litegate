%% @doc 内置中间件 system_prompt：给请求追加一段系统提示（三种接口格式都支持）。
%% options：#{"text" => 追加的系统提示, "position" => "append"（默认，放在已有系统提示之后）| "prepend"}
-module(lg_mw_system_prompt).
-behaviour(lg_middleware).

-export([describe/0, validate/1, on_request/3]).

describe() ->
    #{title => <<"追加系统提示"/utf8>>,
      description => <<"给每个请求追加一段系统提示，例如统一要求用中文回答"/utf8>>,
      options_example => #{<<"text">> => <<"请始终用简体中文回答。"/utf8>>, <<"position">> => <<"append">>}}.

validate(#{<<"text">> := T} = O) when is_binary(T), T =/= <<>> ->
    case maps:get(<<"position">>, O, <<"append">>) of
        P when P =:= <<"append">>; P =:= <<"prepend">> -> ok;
        _ -> {error, <<"position must be append or prepend">>}
    end;
validate(_) ->
    {error, <<"options.text is required">>}.

on_request(Body, Ctx, #{<<"text">> := T} = O) ->
    Pos = case maps:get(<<"position">>, O, <<"append">>) of <<"prepend">> -> prepend; _ -> append end,
    {ok, lg_mw:add_system(Body, Ctx, T, Pos)};
on_request(_Body, _Ctx, _Opts) ->
    continue.
