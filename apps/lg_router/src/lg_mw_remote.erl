%% @doc 内置中间件 remote：调用远程 Erlang 节点上的中间件模块（Erlang 分布式，erpc）。
%% options：#{"node" => "mw@127.0.0.1", "module" => "my_mw", "config" => 对象（作为第三个参数传过去）,
%%           "events" => false（是否转发流式事件，每个事件一次往返）, "timeout_ms" => 200}
%% 远程模块只需导出钩子函数（与 lg_middleware 相同的参数与返回值），不依赖 litegate。
%% 网关节点须以分布式模式运行、两端 cookie 相同；第一次调用时自动连接。出错（不可达、超时、远程崩溃）按中间件规则放行。
%% 注意：Erlang 分布式两端互有完全权限，只连接自己控制的节点。
-module(lg_mw_remote).
-behaviour(lg_middleware).

-export([describe/0, validate/1, hooks/1, timeout/1, on_request/3, on_event/3, on_response/3]).

-define(DEFAULT_TIMEOUT, 200).

describe() ->
    #{title => <<"远程节点"/utf8>>,
      description => <<"调用远程 Erlang 节点上的中间件模块（分布式 erpc）；节点独立部署、独立升级"/utf8>>,
      options_example => #{<<"node">> => <<"mw@127.0.0.1">>, <<"module">> => <<"my_mw">>, <<"config">> => #{},
                           <<"events">> => false, <<"timeout_ms">> => ?DEFAULT_TIMEOUT}}.

validate(#{<<"node">> := N, <<"module">> := M} = O) when is_binary(N), is_binary(M) ->
    Checks = [{re:run(N, "^[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+$") =/= nomatch, <<"node must look like name@host">>},
              {re:run(M, "^[a-z][A-Za-z0-9_]*$") =/= nomatch, <<"module must be an Erlang module name">>},
              {is_map(maps:get(<<"config">>, O, #{})), <<"config must be an object">>},
              {is_boolean(maps:get(<<"events">>, O, false)), <<"events must be true or false">>},
              {valid_timeout(maps:get(<<"timeout_ms">>, O, ?DEFAULT_TIMEOUT)), <<"timeout_ms must be 1..5000">>}],
    case [Msg || {false, Msg} <- Checks] of
        [] -> ok;
        [Msg | _] -> {error, Msg}
    end;
validate(_) ->
    {error, <<"options.node and options.module are required">>}.

valid_timeout(T) -> is_integer(T) andalso T > 0 andalso T =< 5000.

hooks(O) ->
    case maps:get(<<"events">>, O, false) of
        true -> [on_request, on_event, on_response];
        _ -> [on_request, on_response]
    end.

%% 网关这一侧的超时比 erpc 的多留一点，让 erpc 先超时并报出明确的原因
timeout(O) -> maps:get(<<"timeout_ms">>, O, ?DEFAULT_TIMEOUT) + 50.

on_request(Body, Ctx, O) -> call(on_request, Body, Ctx, O).
on_event(Ev, Ctx, O) -> call(on_event, Ev, Ctx, O).
on_response(Body, Ctx, O) -> call(on_response, Body, Ctx, O).

call(Hook, Arg, Ctx, O) ->
    case atoms(O) of
        {ok, Node, Mod} ->
            node() =:= nonode@nohost andalso error(gateway_not_distributed),
            Timeout = maps:get(<<"timeout_ms">>, O, ?DEFAULT_TIMEOUT),
            try erpc:call(Node, Mod, Hook, [Arg, Ctx, maps:get(<<"config">>, O, #{})], Timeout)
            catch
                %% 远程模块没导出这个钩子：视为不处理
                error:{exception, undef, [{Mod, Hook, _, _} | _]} -> continue
            end;
        {error, Reason} ->
            logger:warning("mw_remote: skipping hook ~p: ~0p", [Hook, Reason]),
            continue
    end.

%% binary_to_existing_atom：不存在的节点 / 模块名不创建原子（原子不可回收），返回明确错误
atoms(O) ->
    try
        {ok,
         binary_to_existing_atom(maps:get(<<"node">>, O), utf8),
         binary_to_existing_atom(maps:get(<<"module">>, O), utf8)}
    catch
        error:badarg ->
            {error, {unknown_node_or_module, maps:get(<<"node">>, O, <<>>), maps:get(<<"module">>, O, <<>>)}}
    end.
