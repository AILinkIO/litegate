%% @doc 路由 / 凭证的扩展选项（记录中的 options 字段）：按规格校验 JSON 输入。
%%
%% 规格：#{<<"json_key">> => {atom_key, Type}}，Type 为 boolean | non_neg_integer | {custom, fun((term()) -> boolean())}。
%% 输入中值为 null 表示删除该选项；未知键拒绝；与已有选项合并（部分更新）。
-module(lg_options).

-export([merge/3, to_json/1, route_spec/0, credential_spec/0, key_spec/0]).

-spec route_spec() -> map().
route_spec() ->
    #{<<"cache_ttl_s">> => {cache_ttl_s, non_neg_integer},
      <<"loop_guard">> => {loop_guard, boolean},
      <<"redact">> => {redact, boolean},
      <<"strategy">> => {strategy, {custom, fun lg_strategy:valid/1}},
      <<"rules">> => {rules, {custom, fun lg_rules:valid_rules/1}},
      <<"classifier">> => {classifier, {custom, fun lg_rules:valid_classifier/1}},
      <<"intent_engine">> => {intent_engine, {custom, fun(V) -> lists:member(V, [<<"llm">>, <<"laya">>, <<"systemone">>]) end}},
      %% intent_engine = systemone：决策模型（System One）路由与问法（choice 一道单选题，默认 / noul 每条意图一道是非题）
      <<"decision_route">> => {decision_route, {custom, fun lg_rules:valid_classifier/1}},
      <<"decision_style">> => {decision_style, {custom, fun(V) -> V =:= <<"noul">> orelse V =:= <<"choice">> end}},
      <<"affinity">> => {affinity, {custom, fun(V) -> lists:member(V, [<<"auto">>, <<"session">>, <<"off">>]) end}}}.

%% 网关 Key 的选项
-spec key_spec() -> map().
key_spec() ->
    #{<<"redact">> => {redact, boolean}}.

-spec credential_spec() -> map().
credential_spec() ->
    #{<<"responses_api">> => {responses_api, boolean},
      <<"responses_base_url">> => {responses_base_url, {custom, fun http_url/1}},
      <<"max_concurrency">> => {max_concurrency, non_neg_integer},
      <<"structured_output">> => {structured_output, {custom, fun(V) -> V =:= <<"native">> orelse V =:= <<"tool">> end}},
      <<"plan">> => {plan, {custom, fun lg_plan:validate/1}},
      <<"balance">> => {balance, {custom, fun lg_balance:validate/1}},
      <<"extra_body">> => {extra_body, {custom, fun is_map/1}},
      <<"think_tags">> => {think_tags, {custom, fun(V) -> V =:= <<"split">> end}},
      <<"prompt_cache">> => {prompt_cache, {custom, fun(V) -> V =:= <<"auto">> end}},
      <<"media_api">> => {media_api, {custom, fun(V) -> V =:= <<"openai">> orelse V =:= <<"minimax">> end}}}.

-spec merge(map(), term(), map()) -> {ok, map()} | {error, {invalid, binary()}}.
merge(Spec, Input, Existing) when is_map(Input) ->
    try
        {ok, maps:fold(
               fun(K, V, Acc) ->
                       case maps:find(K, Spec) of
                           {ok, {Atom, _}} when V =:= null -> maps:remove(Atom, Acc);
                           {ok, {Atom, Type}} ->
                               valid(Type, V) orelse throw({invalid, <<"options.", K/binary>>}),
                               Acc#{Atom => V};
                           error ->
                               throw({invalid, <<"options.", K/binary>>})
                       end
               end, Existing, Input)}
    catch
        throw:{invalid, _} = E -> {error, E}
    end;
merge(_Spec, _Input, _Existing) ->
    {error, {invalid, <<"options">>}}.

-spec to_json(map()) -> map().
to_json(Options) ->
    maps:from_list([{atom_to_binary(K), V} || K := V <- Options]).

%% http(s) 地址，带主机
http_url(V) when is_binary(V) ->
    case uri_string:parse(V) of
        #{scheme := S, host := H} when (S =:= <<"http">> orelse S =:= <<"https">>), H =/= <<>> -> true;
        _ -> false
    end;
http_url(_) ->
    false.

valid(boolean, V) -> is_boolean(V);
valid(non_neg_integer, V) -> is_integer(V) andalso V >= 0;
valid({custom, F}, V) -> F(V).
