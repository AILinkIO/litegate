%% @doc 路由能力：展开路由能到达的上游目标（直连、嵌套路由、规则 use、回退），
%% 按模型目录（model_ref，或凭证关联的供应商 + 上游模型）查推理、上下文、最大输出、图片输入，
%% 并汇总出对所有上游都安全的取值。供控制台 Playground 自动填参数。
-module(lg_route_caps).

-include_lib("lg_core/include/lg_core.hrl").

-export([get/1, summary/1]).

-define(MAX_DEPTH, 4).

-type entry() :: #{credential := binary(), credential_name := binary(), upstream_model := binary(),
                   via := [binary()], known := boolean(), reasoning := boolean() | null,
                   context := pos_integer() | null, output := pos_integer() | null,
                   images := boolean() | null, locked_sampling := boolean()}.

%% @doc 按请求的模型名（路由名、别名或通配展开名）返回 #{route, targets, summary}。
-spec get(binary()) -> {ok, map()} | not_found.
get(Name) ->
    case lg_routes:match(Name) of
        {ok, #lg_route{name = RN} = R, Rest} ->
            Targets = dedup(walk(R, Rest, [], 0)),
            {ok, #{route => RN, targets => Targets, summary => summary(Targets)}};
        not_found ->
            not_found
    end.

%% @doc 汇总：推理、图片输入为 all | some | none | unknown（只看目录里查得到的上游）；
%% 上下文、最大输出取已知上游的最小值；任一上游锁定采样参数即视为锁定。
-spec summary([entry()]) -> map().
summary(Ts) ->
    Known = [T || #{known := true} = T <- Ts],
    Tri = fun(K) ->
                  case lists:usort([B || #{K := B} <- Known, is_boolean(B)]) of
                      [] -> unknown;
                      [true] -> all;
                      [false] -> none;
                      _ -> some
                  end
          end,
    Min = fun(K) -> case [V || #{K := V} <- Known, is_integer(V)] of [] -> null; Vs -> lists:min(Vs) end end,
    #{reasoning => Tri(reasoning),
      images => Tri(images),
      context => Min(context),
      output => Min(output),
      locked_sampling => lists:any(fun(#{locked_sampling := L}) -> L end, Ts),
      unknown => length(Ts) - length(Known)}.

%%====================================================================
%% 内部函数
%%====================================================================

%% 路由能到达的直连目标；Via 为经过的路由名（外层在前）
walk(_R, _Rest, _Via, Depth) when Depth > ?MAX_DEPTH ->
    [];
walk(#lg_route{name = Name, targets = Ts, fallbacks = Fbs, options = Opts}, Rest, Via0, Depth) ->
    case lists:member(Name, Via0) of
        true -> [];
        false ->
            Via = Via0 ++ [Name],
            Sub = fun(RN) -> case lg_routes:get(RN) of
                                 {ok, #lg_route{enabled = true} = R2} -> walk(R2, undefined, Via, Depth + 1);
                                 _ -> []
                             end
                  end,
            Direct = lists:append([direct(T, Rest, Via) || T <- Ts, maps:get(enabled, T, true)]),
            Nested = lists:append([Sub(RN) || #{route := RN} = T <- Ts, maps:get(enabled, T, true)]),
            Uses = lists:append([Sub(U) || #{<<"use">> := U} <- maps:get(rules, Opts, [])]),
            Direct ++ Nested ++ Uses ++ lists:append([Sub(F) || F <- Fbs])
    end.

direct(#{credential := CId, upstream_model := M0} = T, Rest, Via) ->
    case lg_credentials:get(CId) of
        {ok, #lg_credential{enabled = true, name = CName, provider = Prov}} ->
            M = case M0 of <<"*">> -> Rest; _ -> M0 end,
            case is_binary(M) of
                false -> [];
                true ->
                    Ref = case maps:get(model_ref, T, undefined) of
                              {_, _} = R when M0 =/= <<"*">> -> R;
                              _ when is_binary(Prov) -> {Prov, M};
                              _ -> undefined
                          end,
                    [entry(CId, CName, M, Via, info(Ref))]
            end;
        _ -> []
    end;
direct(_, _, _) ->
    [].

info(undefined) -> not_found;
info(Ref) -> lg_catalog:model(Ref).

entry(CId, CName, M, Via, Info) ->
    Base = #{credential => CId, credential_name => CName, upstream_model => M, via => Via,
             locked_sampling => lg_quirks:kimi_locked_sampling(M)},
    case Info of
        {ok, I} ->
            Limit = maps:get(<<"limit">>, I, #{}),
            In = case maps:get(<<"modalities">>, I, #{}) of
                     #{<<"input">> := L} when is_list(L) -> L;
                     _ -> null
                 end,
            Base#{known => true,
                  reasoning => bool(maps:get(<<"reasoning">>, I, null)),
                  context => pos(maps:get(<<"context">>, Limit, null)),
                  output => pos(maps:get(<<"output">>, Limit, null)),
                  images => case In of null -> null; _ -> lists:member(<<"image">>, In) end};
        not_found ->
            Base#{known => false, reasoning => null, context => null, output => null, images => null}
    end.

bool(B) when is_boolean(B) -> B;
bool(_) -> null.

pos(N) when is_integer(N), N > 0 -> N;
pos(_) -> null.

%% 同一 {凭证, 上游模型} 只保留第一次出现（离入口最近的路径）
dedup(Ts) ->
    {Out, _} = lists:foldl(fun(#{credential := C, upstream_model := M} = T, {Acc, Seen}) ->
                                   case sets:is_element({C, M}, Seen) of
                                       true -> {Acc, Seen};
                                       false -> {[T | Acc], sets:add_element({C, M}, Seen)}
                                   end
                           end, {[], sets:new()}, Ts),
    lists:reverse(Out).
