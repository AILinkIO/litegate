%% @doc 上游参数兼容的自动学习。
%%
%% 上游以 400 / 422 拒绝请求、错误信息说明某个参数或用法不受支持时，记下 {凭证, 上游模型, 特性}（mnesia lg_unfit，
%% 重启后保留），改写请求后重试一次（lg_provider:with_unfit_retry/2）；之后发往该目标的请求在组装时直接按已知限制改写。
%% lg_quirks 中按模型名写死的规则是不用先失败一次的初始知识，这里处理其余情况。
%%
%% 特性（识别措辞均来自真实上游原文，且为小写匹配）：
%%   temperature       温度只能取默认值 / 已废弃              → 去掉 temperature
%%   top_p             同上                                    → 去掉 top_p
%%   thinking_off      思考不能关闭                            → 去掉关闭思考的参数（Anthropic thinking disabled、enable_thinking false、reasoning_effort none）
%%   enable_thinking_sync  非流式请求必须关闭思考（百炼）      → 非流式请求加 enable_thinking: false
%%   prefill           不接受以助手消息结尾                    → 去掉末尾的助手消息
%%   output_config     不支持 output_config / output_format     → 结构化输出改用强制工具（lg_structured 读这里）
%%   json_schema       不支持 response_format 的 json_schema    → 降为 json_object
%%   forced_tool       思考模式下不能强制调用某个工具          → tool_choice 改为 auto（结构化输出的强制工具方式靠工具描述引导）
%%   bare_reasoning    不接受 input 里的 reasoning 项（OpenAI 官方 / Azure：store=false 时 rs_ 项未存储，
%%                     "Item with id 'rs_…' not found"；中转站切上游后同理）→ 去掉 input 里的 reasoning 项
-module(lg_unfit).

-export([apply/5, learn/4, has/3, list/0, forget/1, forget_all/0, features/0, match/2]).
-export([retired_error/2, retire/3, retired/2, clear_retired/2]).

-include_lib("lg_core/include/lg_core.hrl").

-define(RETIRED_MS, 7 * 86400000).

-type feature() :: temperature | top_p | thinking_off | enable_thinking_sync | prefill | output_config | json_schema | forced_tool | bare_reasoning.
-type state_feature() :: feature() | retired.

-spec features() -> [feature()].
features() ->
    [temperature, top_p, thinking_off, enable_thinking_sync, prefill, output_config, json_schema, forced_tool, bare_reasoning].

%% 错误信息中的措辞 → 特性
-spec match(binary(), map()) -> [feature()].
match(Msg0, Sent) ->
    Msg = try string:lowercase(Msg0) catch _:_ -> Msg0 end,
    Has = fun(Words) -> lists:any(fun(W) -> binary:match(Msg, W) =/= nomatch end, Words) end,
    Candidates =
        [{temperature, Has([<<"temperature">>]) andalso Has([<<"deprecated">>, <<"only 1 is allowed">>, <<"not supported">>,
                                                            <<"unsupported">>, <<"does not support">>, <<"invalid temperature">>])},
         {top_p, Has([<<"top_p">>]) andalso Has([<<"deprecated">>, <<"not supported">>, <<"unsupported">>, <<"does not support">>,
                                                 <<"only 1 is allowed">>, <<"invalid top_p">>])},
         {thinking_off, Has([<<"always engages in thinking">>, <<"不可关闭"/utf8>>, <<"restricted to true">>,
                             <<"thinking cannot be disabled">>, <<"cannot disable thinking">>,
                             <<"始终思考"/utf8>>, <<"不支持关闭思考"/utf8>>])},
         {forced_tool, Has([<<"tool_choice">>]) andalso Has([<<"thinking">>, <<"思考"/utf8>>])},
         {enable_thinking_sync, Has([<<"enable_thinking must be set to false for non-streaming">>])},
         {prefill, Has([<<"prefill">>, <<"ending with a model turn">>, <<"ending with an assistant">>,
                        <<"final assistant content cannot end">>, <<"last message must be a user message">>])},
         {output_config, Has([<<"output_config">>, <<"output_format">>])},
         {json_schema, Has([<<"response_format">>, <<"json_schema">>]) andalso
                           Has([<<"unavailable">>, <<"not supported">>, <<"unsupported">>, <<"invalid">>, <<"does not support">>])},
         {bare_reasoning, (Has([<<"item with id">>]) orelse Has([<<"reasoning item">>]))
                          andalso Has([<<"not found">>, <<"unknown item">>, <<"no such item">>])}],
    [F || {F, true} <- Candidates, present(F, Sent)].

%% 只学这次请求里确实用到的特性（避免错误信息顺带提到别的参数时误学）
present(temperature, B) -> maps:is_key(<<"temperature">>, B);
present(top_p, B) -> maps:is_key(<<"top_p">>, B);
present(thinking_off, B) ->
    case B of
        #{<<"thinking">> := #{<<"type">> := <<"disabled">>}} -> true;
        #{<<"enable_thinking">> := false} -> true;
        #{<<"reasoning_effort">> := <<"none">>} -> true;
        _ -> false
    end;
present(enable_thinking_sync, B) -> maps:get(<<"stream">>, B, false) =/= true;
present(prefill, #{<<"messages">> := [_ | _] = Ms}) ->
    case lists:last(Ms) of
        #{<<"role">> := <<"assistant">>} -> true;
        _ -> false
    end;
present(prefill, _) -> false;
present(output_config, B) -> maps:is_key(<<"output_config">>, B);
present(json_schema, #{<<"response_format">> := #{<<"type">> := <<"json_schema">>}}) -> true;
present(json_schema, _) -> false;
present(forced_tool, #{<<"tool_choice">> := #{<<"type">> := T}}) -> T =:= <<"tool">> orelse T =:= <<"any">> orelse T =:= <<"function">>;
present(forced_tool, #{<<"tool_choice">> := <<"required">>}) -> true;
present(forced_tool, _) -> false;
present(bare_reasoning, #{<<"input">> := Items}) when is_list(Items) ->
    lists:any(fun(#{<<"type">> := T}) -> T =:= <<"reasoning">>; (_) -> false end, Items);
present(bare_reasoning, _) -> false.

%% @doc 上游返回错误后调用：学到新特性时返回 {learned, [Feature]}（调用方重试一次），否则 none。
-spec learn(binary(), binary(), lg_llm_error:error(), map()) -> {learned, [feature()]} | none.
learn(CredId, Model, #{status := S, message := Msg} = Err, Sent) when S =:= 400; S =:= 422 ->
    Text = case Err of
               #{upstream := #{body := B}} when is_binary(B) -> <<Msg/binary, " ", B/binary>>;
               _ -> Msg
           end,
    New = [F || F <- match(Text, Sent), not has(CredId, Model, F)],
    case New of
        [] -> none;
        _ ->
            Now = lg_time:now_ms(),
            Short = binary:part(Msg, 0, min(300, byte_size(Msg))),
            [ok = lg_db:write(#lg_unfit{key = {CredId, Model, F}, message = Short, learned_at = Now}) || F <- New],
            logger:notice("upstream ~s/~s: learned unsupported ~p (~ts)", [CredId, Model, New, Short]),
            {learned, New}
    end;
learn(_, _, _, _) ->
    none.

-spec has(binary(), binary(), state_feature()) -> boolean().
has(CredId, Model, F) ->
    case catch mnesia:dirty_read(lg_unfit, {CredId, Model, F}) of
        [_] -> true;
        _ -> false
    end.

%% @doc 按已知限制改写发往上游的请求体（已是上游协议）。Stream：是否流式请求。
-spec apply(openai | anthropic, binary(), binary(), map(), boolean()) -> map().
apply(Up, CredId, Model, Body, Stream) ->
    lists:foldl(fun(F, B) ->
                        case ?MODULE:has(CredId, Model, F) of
                            true -> rewrite(F, Up, B, Stream);
                            false -> B
                        end
                end, Body, [temperature, top_p, thinking_off, enable_thinking_sync, prefill, json_schema, forced_tool,
                            bare_reasoning]).

rewrite(temperature, _, B, _) -> maps:remove(<<"temperature">>, B);
rewrite(top_p, _, B, _) -> maps:remove(<<"top_p">>, B);
rewrite(thinking_off, _, B0, _) ->
    B1 = case B0 of
             #{<<"thinking">> := #{<<"type">> := <<"disabled">>}} -> maps:remove(<<"thinking">>, B0);
             _ -> B0
         end,
    B2 = case B1 of
             #{<<"enable_thinking">> := false} -> maps:remove(<<"enable_thinking">>, B1);
             _ -> B1
         end,
    case B2 of
        #{<<"reasoning_effort">> := <<"none">>} -> maps:remove(<<"reasoning_effort">>, B2);
        _ -> B2
    end;
rewrite(enable_thinking_sync, openai, B, false) -> B#{<<"enable_thinking">> => false};
rewrite(enable_thinking_sync, _, B, _) -> B;
rewrite(prefill, _, #{<<"messages">> := [_ | _] = Ms} = B, _) ->
    case lists:last(Ms) of
        #{<<"role">> := <<"assistant">>} -> B#{<<"messages">> => lists:droplast(Ms)};
        _ -> B
    end;
rewrite(json_schema, _, #{<<"response_format">> := #{<<"type">> := <<"json_schema">>}} = B, _) ->
    B#{<<"response_format">> => #{<<"type">> => <<"json_object">>}};
rewrite(forced_tool, anthropic, #{<<"tool_choice">> := _} = B, _) -> B#{<<"tool_choice">> => #{<<"type">> => <<"auto">>}};
rewrite(forced_tool, openai, #{<<"tool_choice">> := _} = B, _) -> B#{<<"tool_choice">> => <<"auto">>};
rewrite(bare_reasoning, _, #{<<"input">> := Items} = B, _) when is_list(Items) ->
    Keep = fun(#{<<"type">> := <<"reasoning">>}) -> false;
              (_) -> true
           end,
    B#{<<"input">> => lists:filter(Keep, Items)};
rewrite(_, _, B, _) -> B.

-spec list() -> [map()].
list() ->
    [#{credential => C, upstream_model => M, feature => F, message => Msg, learned_at => At}
     || #lg_unfit{key = {C, M, F}, message = Msg, learned_at = At} <- lg_db:all(lg_unfit)].

-spec forget({binary(), binary(), atom()}) -> ok.
forget(Key) ->
    lg_db:delete(lg_unfit, Key).

-spec forget_all() -> ok.
forget_all() ->
    {atomic, ok} = mnesia:clear_table(lg_unfit),
    ok.

%%====================================================================
%% 模型退役（对照 magpie Retire）
%%====================================================================

%% @doc 退役判定：410；或 400 / 404 / 422 且错误信息命中退役措辞。
%% 与 unserved 不同：退役是「曾经能用、官方撤了」（上游自己的模型列表往往还挂着）。
-spec retired_error(pos_integer(), binary()) -> boolean().
retired_error(Status, Msg) when Status =:= 400; Status =:= 404; Status =:= 422 ->
    T = try string:lowercase(Msg) catch _:_ -> Msg end,
    lists:any(fun(W) -> binary:match(T, W) =/= nomatch end,
              [<<"deprecated">>, <<"has been discontinued">>, <<"is being sunset">>,
               <<"模型已下架"/utf8>>, <<"已停止服务"/utf8>>, <<"已下线"/utf8>>]);
retired_error(410, _) ->
    true;
retired_error(_, _) ->
    false.

%% @doc 记为退役：从该 {凭证, 模型} 的尝试顺序剔除，一周后自动恢复。
-spec retire(binary(), binary(), binary()) -> ok | {error, term()}.
retire(CredId, Model, Msg) ->
    case has(CredId, Model, retired) of
        true ->
            ok;
        false ->
            Now = lg_time:now_ms(),
            Short = binary:part(Msg, 0, min(300, byte_size(Msg))),
            ok = lg_db:write(#lg_unfit{key = {CredId, Model, retired}, message = Short, learned_at = Now}),
            logger:notice("upstream ~s/~s: model retired (~ts), out of rotation for ~b days",
                          [CredId, Model, Short, ?RETIRED_MS div 86400000]),
            ok
    end.

%% @doc 该 {凭证, 模型} 是否已退役（一周内学到的算数）。过期记录惰性清除。
-spec retired(binary(), binary()) -> boolean().
retired(CredId, Model) ->
    case catch mnesia:dirty_read(lg_unfit, {CredId, Model, retired}) of
        [#lg_unfit{learned_at = At}] ->
            case lg_time:now_ms() - At < ?RETIRED_MS of
                true -> true;
                false -> lg_db:delete(lg_unfit, {CredId, Model, retired}), false
            end;
        _ ->
            false
    end.

%% @doc 请求成功：清除退役记录（上游又认这个模型了）。
-spec clear_retired(binary(), binary()) -> ok.
clear_retired(CredId, Model) ->
    lg_db:delete(lg_unfit, {CredId, Model, retired}).
