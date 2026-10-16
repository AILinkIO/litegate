%% @doc GET /v1/models：列出当前 Key 可调用的路由名。
%% 带 anthropic-version 头时返回 Anthropic 格式，否则 OpenAI 格式。
-module(lg_web_models).
-behaviour(cowboy_handler).

-include_lib("lg_core/include/lg_core.hrl").

-export([init/2]).

init(Req0, State) ->
    F = case cowboy_req:header(<<"anthropic-version">>, Req0) of
            undefined -> openai;
            _ -> anthropic
        end,
    Req = case lg_web_util:authenticate(Req0) of
              {ok, Key} ->
                  %% 通配路由展开出的名字没有对应的路由记录，创建时间记为 0
                  Routes = [case lg_routes:get(N) of
                                {ok, #lg_route{created_at = C}} -> {N, C};
                                not_found -> {N, 0}
                            end || N <- lg_router:models(Key)],
                  lg_web_util:json(200, render(F, Routes), Req0);
              {error, _} ->
                  lg_web_util:error_reply(F, 401, <<"authentication_error">>,
                                          <<"Invalid API key">>, Req0)
          end,
    {ok, Req, State}.

render(openai, Routes) ->
    #{<<"object">> => <<"list">>,
      <<"data">> => [#{<<"id">> => N, <<"object">> => <<"model">>,
                       <<"created">> => C div 1000, <<"owned_by">> => <<"litegate">>}
                     || {N, C} <- Routes]};
render(anthropic, Routes) ->
    Data = [#{<<"type">> => <<"model">>, <<"id">> => N, <<"display_name">> => N,
              <<"created_at">> => iso8601(C)}
            || {N, C} <- Routes],
    Ids = [maps:get(<<"id">>, D) || D <- Data],
    #{<<"data">> => Data, <<"has_more">> => false,
      <<"first_id">> => case Ids of [] -> null; _ -> hd(Ids) end,
      <<"last_id">> => case Ids of [] -> null; _ -> lists:last(Ids) end}.

iso8601(Ms) ->
    list_to_binary(calendar:system_time_to_rfc3339(Ms, [{unit, millisecond}, {offset, "Z"}])).
