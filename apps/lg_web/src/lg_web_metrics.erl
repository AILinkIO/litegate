%% @doc GET /metrics（Prometheus 文本格式）。运行参数 metrics_token 非空时要求 Bearer 令牌。
-module(lg_web_metrics).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Req = case authorized(Req0) of
              true ->
                  cowboy_req:reply(200, #{<<"content-type">> => <<"text/plain; version=0.0.4; charset=utf-8">>},
                                   lg_metrics:render(), Req0);
              false ->
                  cowboy_req:reply(401, #{<<"www-authenticate">> => <<"Bearer">>}, <<"unauthorized\n">>, Req0)
          end,
    {ok, Req, State}.

authorized(Req) ->
    case lg_config:get(metrics_token) of
        <<>> ->
            true;
        Token ->
            case cowboy_req:header(<<"authorization">>, Req) of
                <<"Bearer ", Given/binary>> -> crypto:hash_equals(crypto:hash(sha256, Given),
                                                                  crypto:hash(sha256, Token));
                _ -> false
            end
    end.
