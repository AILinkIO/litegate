%% @doc HTTP 辅助：JSON 响应、请求体读取、网关 Key 鉴权。
-module(lg_web_util).

-include_lib("lg_core/include/lg_core.hrl").

-export([json/3, raw_json/3, read_json/1, authenticate/1, error_reply/5]).

-spec json(pos_integer(), term(), cowboy_req:req()) -> cowboy_req:req().
json(Status, Term, Req) ->
    raw_json(Status, json:encode(Term), Req).

-spec raw_json(pos_integer(), iodata(), cowboy_req:req()) -> cowboy_req:req().
raw_json(Status, Body, Req) ->
    cowboy_req:reply(Status, #{<<"content-type">> => <<"application/json">>}, Body, Req).

%% @doc 读取并解析 JSON 对象请求体（上限 max_body_bytes）。
-spec read_json(cowboy_req:req()) ->
          {ok, map(), cowboy_req:req()} | {error, too_large | invalid_json, cowboy_req:req()}.
read_json(Req0) ->
    Max = lg_config:get(max_body_bytes),
    case read_body(Req0, [], 0, Max) of
        {ok, Body, Req} ->
            try json:decode(Body) of
                M when is_map(M) -> {ok, M, Req};
                _ -> {error, invalid_json, Req}
            catch
                error:_ -> {error, invalid_json, Req}
            end;
        {error, _, _} = Err ->
            Err
    end.

read_body(Req0, Acc, Size, Max) ->
    case cowboy_req:read_body(Req0, #{length => 1024 * 1024, period => 15000}) of
        {_, Data, Req} when Size + byte_size(Data) > Max ->
            {error, too_large, Req};
        {ok, Data, Req} ->
            {ok, iolist_to_binary([Acc, Data]), Req};
        {more, Data, Req} ->
            read_body(Req, [Acc, Data], Size + byte_size(Data), Max)
    end.

%% @doc 网关 Key：Authorization: Bearer <key> 或 x-api-key: <key>（Anthropic SDK）。
-spec authenticate(cowboy_req:req()) ->
          {ok, #lg_api_key{}} | {error, missing_key | invalid_key | disabled | expired}.
authenticate(Req) ->
    Key = case cowboy_req:header(<<"authorization">>, Req) of
              <<"Bearer ", K/binary>> -> string:trim(K);
              <<"bearer ", K/binary>> -> string:trim(K);
              _ -> cowboy_req:header(<<"x-api-key">>, Req)
          end,
    case Key of
        undefined -> {error, missing_key};
        <<>> -> {error, missing_key};
        _ -> lg_api_keys:authenticate(Key)
    end.

%% @doc 按客户端协议格式返回错误。
-spec error_reply(openai | anthropic, pos_integer(), binary(), binary(), cowboy_req:req()) ->
          cowboy_req:req().
error_reply(Format, Status, Type, Message, Req) ->
    raw_json(Status, lg_llm_error:render(Format, Status, Type, Message), Req).
