%% 中间件插件示例：拒绝请求某些模型名。
%%
%% 编译并放进插件目录（运行参数 middleware_plugin_dir，默认 <data_dir>/plugins），然后在控制台
%% 「中间件 › 重新扫描插件」，即可在「新建中间件」里选择实现 block_models：
%%   erlc -o /var/lib/litegate/plugins mw_block_models.erl
%% 网关里有行为 lg_middleware 时会检查回调；单独编译时没有它也能编译（只是一条警告）。
-module(mw_block_models).
-behaviour(lg_middleware).

-export([describe/0, validate/1, on_request/3]).

describe() ->
    #{name => <<"block_models">>,
      title => <<"禁用模型名"/utf8>>,
      description => <<"请求的模型名在列表中时拒绝"/utf8>>,
      options_example => #{<<"models">> => [<<"gpt-4o">>], <<"message">> => <<"This model is not allowed">>}}.

validate(#{<<"models">> := Ms}) when is_list(Ms) -> ok;
validate(_) -> {error, <<"options.models must be a list">>}.

on_request(#{<<"model">> := M}, _Ctx, #{<<"models">> := Ms} = O) ->
    case lists:member(M, Ms) of
        true -> {reject, 403, maps:get(<<"message">>, O, <<"This model is not allowed">>)};
        false -> continue
    end;
on_request(_Body, _Ctx, _O) ->
    continue.
