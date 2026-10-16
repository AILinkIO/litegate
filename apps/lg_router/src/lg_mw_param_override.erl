%% @doc 内置中间件 param_override：设置或删除请求字段。
%% options：#{"set" => 对象（浅合并覆盖到请求体）, "unset" => [字段名], "formats" => [openai | anthropic | responses]（可选，只对这些接口格式生效）}
%% 不能改 model、messages、input（换模型请用 model_map）。
-module(lg_mw_param_override).
-behaviour(lg_middleware).

-export([describe/0, validate/1, on_request/3]).

-define(PROTECTED, [<<"model">>, <<"messages">>, <<"input">>]).

describe() ->
    #{title => <<"请求参数改写"/utf8>>,
      description => <<"给请求设置或删除字段，例如统一限制 max_tokens、去掉 temperature"/utf8>>,
      options_example => #{<<"set">> => #{<<"max_tokens">> => 4096}, <<"unset">> => [<<"temperature">>]}}.

validate(O) when is_map(O) ->
    Set = maps:get(<<"set">>, O, #{}),
    Unset = maps:get(<<"unset">>, O, []),
    Formats = maps:get(<<"formats">>, O, [<<"openai">>, <<"anthropic">>, <<"responses">>]),
    if
        not is_map(Set) -> {error, <<"set must be an object">>};
        not is_list(Unset) -> {error, <<"unset must be a list of field names">>};
        map_size(Set) =:= 0, Unset =:= [] -> {error, <<"set or unset is required">>};
        not is_list(Formats) -> {error, <<"formats must be a list">>};
        true ->
            Touched = maps:keys(Set) ++ Unset,
            case [F || F <- Touched, lists:member(F, ?PROTECTED)] of
                [] ->
                    case [F || F <- Formats, not lists:member(F, [<<"openai">>, <<"anthropic">>, <<"responses">>])] of
                        [] -> ok;
                        [Bad | _] -> {error, <<"unknown format: ", Bad/binary>>}
                    end;
                [F | _] -> {error, <<"cannot change ", F/binary>>}
            end
    end;
validate(_) ->
    {error, <<"options must be an object">>}.

on_request(Body, #{format := F}, O) ->
    Formats = maps:get(<<"formats">>, O, all),
    case Formats =:= all orelse lists:member(atom_to_binary(F), Formats) of
        false -> continue;
        true -> {ok, maps:without(maps:get(<<"unset">>, O, []), maps:merge(Body, maps:get(<<"set">>, O, #{})))}
    end.
