%% @doc 内置中间件 model_map：把客户端请求的模型名换成另一个（参考 New API 的 model_mapping）。
%% options：#{"mapping" => #{"请求的模型名" => "换成的模型名（路由名）"}}
-module(lg_mw_model_map).
-behaviour(lg_middleware).

-export([describe/0, validate/1, on_request/3]).

describe() ->
    #{title => <<"模型名映射"/utf8>>,
      description => <<"把客户端请求的模型名换成另一个路由名，例如让客户端写死的 gpt-4o 实际走 fast 路由"/utf8>>,
      options_example => #{<<"mapping">> => #{<<"gpt-4o">> => <<"fast">>}}}.

validate(#{<<"mapping">> := M}) when is_map(M) ->
    case lists:all(fun({K, V}) -> is_binary(K) andalso is_binary(V) andalso V =/= <<>> end, maps:to_list(M)) of
        true -> ok;
        false -> {error, <<"mapping must map model names to model names">>}
    end;
validate(_) ->
    {error, <<"options.mapping is required">>}.

on_request(#{<<"model">> := Model} = Body, _Ctx, #{<<"mapping">> := M}) ->
    case maps:find(Model, M) of
        {ok, To} -> {ok, Body#{<<"model">> => To}};
        error -> continue
    end;
on_request(_Body, _Ctx, _Opts) ->
    continue.
