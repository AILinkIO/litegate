%% @doc 路由与上游错误的客户端响应映射：HTTP 状态、协议错误类型、消息与 Retry-After。
-module(lg_web_llm_error).

-include_lib("lg_core/include/lg_core.hrl").

-export([response/3, retry_after/1]).

%% {Status, Type, Message | {raw, Body}}
response(_F, route_not_found, Out) ->
    {404, <<"not_found_error">>,
     <<"The model `", (maps:get(model, Out, maps:get(route, Out)))/binary, "` does not exist">>};
response(_F, route_forbidden, Out) ->
    {403, <<"permission_error">>,
     <<"This API key cannot access model `", (maps:get(route, Out))/binary, "`">>};
response(_F, {rate_limited, Reason, Scope, _}, _Out) ->
    {429, <<"rate_limit_error">>,
     iolist_to_binary(["Rate limit exceeded (", atom_to_binary(Reason), ") for ", scope_text(Scope)])};
response(F, {budget_exceeded, Scope, _}, _Out) ->
    %% OpenAI 客户端识别 insufficient_quota
    Type = case F of openai -> <<"insufficient_quota">>; anthropic -> <<"rate_limit_error">> end,
    {429, Type, iolist_to_binary(["Budget exceeded for ", scope_text(Scope)])};
response(_F, {unsupported_operation, Op}, Out) ->
    {400, <<"invalid_request_error">>,
     <<"Model `", (maps:get(route, Out))/binary, "` does not support ", Op/binary>>};
response(F, {plan_exhausted, _}, _Out) ->
    Type = case F of openai -> <<"insufficient_quota">>; _ -> <<"rate_limit_error">> end,
    {429, Type, <<"Subscription plan quota exhausted for all upstreams of this model">>};
response(_F, {middleware_rejected, Status, Msg}, _Out) ->
    Type = case Status of
               401 -> <<"authentication_error">>;
               403 -> <<"permission_error">>;
               429 -> <<"rate_limit_error">>;
               S when S >= 500 -> <<"api_error">>;
               _ -> <<"invalid_request_error">>
           end,
    {Status, Type, Msg};
response(_F, no_available_target, _Out) ->
    {503, <<"api_error">>, <<"No available upstream for this model">>};
response(F, #{} = Err, Out) ->
    {Status, Body} = lg_llm_error:to_client(F, same_protocol(F, Out), Err),
    {Status, undefined, {raw, Body}}.

retry_after({rate_limited, _, _, Ms}) -> max(1, (Ms + 999) div 1000);
retry_after({plan_exhausted, ResetAt}) -> max(1, (ResetAt - lg_time:now_ms() + 999) div 1000);
retry_after({budget_exceeded, _, ResetAt}) -> max(1, (ResetAt - lg_time:now_ms() + 999) div 1000);
retry_after(#{retry_after_ms := Ms}) when is_integer(Ms) -> max(1, (Ms + 999) div 1000);
retry_after(_) -> undefined.

same_protocol(F, #{credential := CId}) ->
    case lg_credentials:get(CId) of
        {ok, #lg_credential{protocol = F}} -> true;
        _ -> false
    end;
same_protocol(_, _) ->
    false.

scope_text({key, _}) -> <<"this API key">>;
scope_text({user, _}) -> <<"this user">>;
scope_text({tag, T}) -> <<"tag `", T/binary, "`">>;
scope_text({route, R}) -> <<"model `", R/binary, "`">>;
scope_text({key_route, _, R}) -> <<"this API key on model `", R/binary, "`">>.
