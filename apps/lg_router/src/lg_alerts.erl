%% @doc 告警渠道与规则的配置（mnesia lg_channel / lg_alert_rule）。
%%
%% 渠道：name, type（webhook | feishu | dingtalk | wecom）, url（含令牌，加密存储，展示时只给主机与末 4 位）,
%%       secret（飞书 / 钉钉签名密钥，可选，加密存储）, enabled
%% 规则：event, threshold（缺省按事件取默认值）, channels（渠道 id 列表）, enabled
-module(lg_alerts).

-include_lib("lg_core/include/lg_core.hrl").

-export([create_channel/1, update_channel/2, delete_channel/1, channel/1, channels/0, channel_to_map/1,
         create_rule/1, update_rule/2, delete_rule/1, rules/0, rules/1, rule_to_map/1,
         default_threshold/1, events/0]).


-spec events() -> [lg_alert_event()].
events() -> [budget, upstream_down, plan_quota, catalog_sync_failed, balance_low, login_brute_force].

%% budget / plan_quota：已用百分比；upstream_down：连续失败次数
-spec default_threshold(lg_alert_event()) -> number() | undefined.
default_threshold(budget) -> 80;
default_threshold(plan_quota) -> 90;
default_threshold(upstream_down) -> 3;
default_threshold(catalog_sync_failed) -> undefined;
%% 余额告警线在凭证上设置（options.balance.alert_below），规则只选通知渠道
%% 余额告警线在凭证上设置（options.balance.alert_below）；
%% login_brute_force 的计数与冷却由 lg_login_guard 控制，规则只选通知渠道
default_threshold(balance_low) -> undefined;
default_threshold(login_brute_force) -> undefined.

%%====================================================================
%% 渠道
%%====================================================================

-spec create_channel(map()) -> {ok, #lg_channel{}} | {error, term()}.
create_channel(P) ->
    Now = lg_time:now_ms(),
    Base = #lg_channel{id = lg_id:new(<<"ch">>), name = <<>>, type = webhook, url_enc = <<>>,
                       created_at = Now, updated_at = Now},
    case apply_channel(P, Base, create) of
        {ok, C} -> ok = lg_db:write(C), {ok, C};
        Err -> Err
    end.

-spec update_channel(binary(), map()) -> {ok, #lg_channel{}} | {error, term()}.
update_channel(Id, P) ->
    case lg_db:read(lg_channel, Id) of
        {ok, Old} ->
            case apply_channel(P, Old, update) of
                {ok, C} -> C1 = C#lg_channel{updated_at = lg_time:now_ms()}, ok = lg_db:write(C1), {ok, C1};
                Err -> Err
            end;
        not_found ->
            {error, not_found}
    end.

%% @doc 删除渠道，同时从规则中移除。
-spec delete_channel(binary()) -> ok | {error, not_found}.
delete_channel(Id) ->
    case lg_db:read(lg_channel, Id) of
        {ok, _} ->
            [ok = lg_db:write(R#lg_alert_rule{channels = lists:delete(Id, Cs)})
             || #lg_alert_rule{channels = Cs} = R <- lg_db:all(lg_alert_rule), lists:member(Id, Cs)],
            lg_db:delete(lg_channel, Id);
        not_found ->
            {error, not_found}
    end.

-spec channel(binary()) -> {ok, #lg_channel{}} | not_found.
channel(Id) -> lg_db:read(lg_channel, Id).

-spec channels() -> [#lg_channel{}].
channels() -> lists:keysort(#lg_channel.created_at, lg_db:all(lg_channel)).

-spec channel_to_map(#lg_channel{}) -> map().
channel_to_map(#lg_channel{id = Id, name = N, type = T, url_enc = U, secret_enc = S, enabled = E,
                           created_at = C, updated_at = Up}) ->
    #{<<"id">> => Id, <<"name">> => N, <<"type">> => atom_to_binary(T), <<"url_hint">> => url_hint(U),
      <<"has_secret">> => S =/= undefined, <<"enabled">> => E, <<"created_at">> => C, <<"updated_at">> => Up}.

apply_channel(P, C0, Mode) ->
    try
        C1 = field(<<"name">>, P, Mode, C0, fun(V) when is_binary(V), V =/= <<>> -> C0#lg_channel{name = V} end),
        C2 = field(<<"type">>, P, Mode, C1,
                   fun(V) -> C1#lg_channel{type = channel_type(V)} end),
        C3 = field(<<"url">>, P, Mode, C2,
                   fun(V) when is_binary(V) ->
                           #{scheme := S, host := H} = uri_string:parse(V),
                           true = (S =:= <<"http">> orelse S =:= <<"https">>) andalso H =/= <<>>,
                           C2#lg_channel{url_enc = lg_crypto:encrypt(V)}
                   end),
        C4 = optional(<<"secret">>, P, C3,
                      fun(null) -> C3#lg_channel{secret_enc = undefined};
                         (<<>>) -> C3#lg_channel{secret_enc = undefined};
                         (V) when is_binary(V) -> C3#lg_channel{secret_enc = lg_crypto:encrypt(V)} end),
        C5 = optional(<<"enabled">>, P, C4, fun(V) when is_boolean(V) -> C4#lg_channel{enabled = V} end),
        {ok, C5}
    catch
        throw:{invalid, K} -> {error, {invalid, K}};
        throw:{missing, K} -> {error, {missing, K}}
    end.

channel_type(<<"webhook">>) -> webhook;
channel_type(<<"feishu">>) -> feishu;
channel_type(<<"dingtalk">>) -> dingtalk;
channel_type(<<"wecom">>) -> wecom.

url_hint(Enc) ->
    case lg_crypto:decrypt(Enc) of
        {ok, U} ->
            case uri_string:parse(U) of
                #{scheme := S, host := H} when byte_size(U) > 4 ->
                    <<S/binary, "://", H/binary, "/…"/utf8, (binary:part(U, byte_size(U), -4))/binary>>;
                _ -> <<"…"/utf8>>
            end;
        _ -> <<"(undecryptable)">>
    end.

%%====================================================================
%% 规则
%%====================================================================

-spec create_rule(map()) -> {ok, #lg_alert_rule{}} | {error, term()}.
create_rule(P) ->
    Now = lg_time:now_ms(),
    Base = #lg_alert_rule{id = lg_id:new(<<"rule">>), event = budget, created_at = Now, updated_at = Now},
    case apply_rule(P, Base, create) of
        {ok, R} -> ok = lg_db:write(R), {ok, R};
        Err -> Err
    end.

-spec update_rule(binary(), map()) -> {ok, #lg_alert_rule{}} | {error, term()}.
update_rule(Id, P) ->
    case lg_db:read(lg_alert_rule, Id) of
        {ok, Old} ->
            case apply_rule(P, Old, update) of
                {ok, R} -> R1 = R#lg_alert_rule{updated_at = lg_time:now_ms()}, ok = lg_db:write(R1), {ok, R1};
                Err -> Err
            end;
        not_found ->
            {error, not_found}
    end.

-spec delete_rule(binary()) -> ok | {error, not_found}.
delete_rule(Id) ->
    case lg_db:read(lg_alert_rule, Id) of
        {ok, _} -> lg_db:delete(lg_alert_rule, Id);
        not_found -> {error, not_found}
    end.

-spec rules() -> [#lg_alert_rule{}].
rules() -> lists:keysort(#lg_alert_rule.created_at, lg_db:all(lg_alert_rule)).

%% @doc 某事件的启用规则。
-spec rules(lg_alert_event()) -> [#lg_alert_rule{}].
rules(Event) -> [R || #lg_alert_rule{event = E, enabled = true} = R <- rules(), E =:= Event].

-spec rule_to_map(#lg_alert_rule{}) -> map().
rule_to_map(#lg_alert_rule{id = Id, event = E, threshold = T, channels = Cs, enabled = En,
                           created_at = C, updated_at = U}) ->
    #{<<"id">> => Id, <<"event">> => atom_to_binary(E), <<"threshold">> => null_if_undefined(T),
      <<"channels">> => Cs, <<"enabled">> => En, <<"created_at">> => C, <<"updated_at">> => U}.

apply_rule(P, R0, Mode) ->
    try
        R1 = field(<<"event">>, P, Mode, R0,
                   fun(V) ->
                           [E] = [X || X <- events(), atom_to_binary(X) =:= V],
                           R0#lg_alert_rule{event = E, threshold = default_threshold(E)}
                   end),
        R2 = optional(<<"threshold">>, P, R1,
                      fun(null) -> R1#lg_alert_rule{threshold = default_threshold(R1#lg_alert_rule.event)};
                         (V) when is_number(V), V > 0 -> R1#lg_alert_rule{threshold = V} end),
        R3 = optional(<<"channels">>, P, R2,
                      fun(L) when is_list(L) ->
                              true = lists:all(fun(C) -> is_binary(C) andalso channel(C) =/= not_found end, L),
                              R2#lg_alert_rule{channels = lists:usort(L)}
                      end),
        R4 = optional(<<"enabled">>, P, R3, fun(V) when is_boolean(V) -> R3#lg_alert_rule{enabled = V} end),
        {ok, R4}
    catch
        throw:{invalid, K} -> {error, {invalid, K}};
        throw:{missing, K} -> {error, {missing, K}}
    end.

%%====================================================================
%% 公共
%%====================================================================

field(K, P, Mode, Rec, Fun) ->
    case maps:find(K, P) of
        {ok, V} -> safe(K, Fun, V);
        error when Mode =:= update -> Rec;
        error -> throw({missing, K})
    end.

optional(K, P, Rec, Fun) ->
    case maps:find(K, P) of
        {ok, V} -> safe(K, Fun, V);
        error -> Rec
    end.

safe(K, Fun, V) ->
    try Fun(V)
    catch error:_ -> throw({invalid, K})
    end.

null_if_undefined(undefined) -> null;
null_if_undefined(V) -> V.
