%% @doc 网关中间件运行时。
%%
%% 三个钩子点位（都在网关入口这一侧，看到的是客户端格式的内容；发往上游前的脱敏、协议转换在其后）：
%%   on_request(Body, Ctx, Opts)  请求体解析之后、路由之前 → continue | {ok, Body} | {ok, Body, State} | {reject, Status, Message}
%%   on_event(Event, Ctx, Opts)   流式输出写给客户端之前，Event = #{event, data}（data 为解码后的 JSON 对象）
%%                                → continue | {ok, Event} | drop
%%   on_response(Body, Ctx, Opts) 非流式回复（JSON）写给客户端之前 → continue | {ok, Body}
%% Ctx：route、model、format、stream、client、key_name、tags、session，以及该中间件在本请求内的 state（on_request 返回的）。
%%
%% 实现是一个导出上述可选回调的 Erlang 模块（行为 lg_middleware），在 impls/0 中按名称登记：随网关发布的内置模块，
%% 或控制台里写的 Erlang 源码（运行时编译加载）。配置在 mnesia lg_middleware 表（lg_middlewares 管理），按 position 顺序、按路由生效。
%%
%% 出错放行：钩子抛错、返回无法识别的值、超时（on_request / on_response 250ms，在独立进程中运行；on_event 在当前进程运行，
%% 只计时不打断，超过 50ms 记为慢调用）时原样放行，计数并保留最近一次错误。没有启用任何中间件时不增加开销。
-module(lg_middleware).
-behaviour(gen_server).

-export([start_link/0, impls/0, impl_info/0, hooks_for/2, reload/0, rescan/0, plugin_dir/0, chain/1, begin_run/2, has/2,
         request/2, event/2, response/2, stats/0, test/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include_lib("lg_core/include/lg_core.hrl").

-callback on_request(map(), map(), map()) -> continue | {ok, map()} | {ok, map(), term()} | {reject, pos_integer(), binary()}.
-callback on_event(map(), map(), map()) -> continue | {ok, map()} | drop.
-callback on_response(map(), map(), map()) -> continue | {ok, map()}.
-callback describe() -> #{title := binary(), description := binary(), options_example := map(), name => binary()}.
%% 按配置决定启用哪些钩子（默认为模块导出的钩子）；同步钩子（on_request / on_response）的超时
-callback hooks(map()) -> [on_request | on_event | on_response].
-callback timeout(map()) -> pos_integer().
-optional_callbacks([on_request/3, on_event/3, on_response/3, hooks/1, timeout/1]).

-define(CHAIN, lg_mw_chain).   %% {chain, [Entry]}；Entry = #{id, name, mod, options, routes, hooks, timeout}
-define(STATS, lg_mw_stats).   %% {Id, Calls, Failures, Slow, TotalUs} 与 {{last_error, Id}, At, Hook, Message}
-define(SYNC_TIMEOUT_MS, 250).
-define(EVENT_SLOW_US, 50000).

-type run() :: #{chain := [map()], ctx := map(), states := map()}.
-export_type([run/0]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc 已登记的实现：名称 → 模块。按行为发现（声明了 -behaviour(lg_middleware) 的模块）：
%% lg_router 应用里的内置模块、插件目录里加载的模块（rescan/0），以及应用环境 lg_router.middleware_impls（#{名称 => 模块}，测试用）。
-spec impls() -> #{binary() => module()}.
impls() ->
    maps:from_list([{N, M} || {N, M, _} <- registry()]).

%% {名称, 模块, 来源}；来源为 builtin | {plugin, 文件} | env
registry() ->
    Builtin = case application:get_key(lg_router, modules) of
                  {ok, Ms} -> [{M, builtin} || M <- Ms, M =/= ?MODULE];
                  undefined -> []
              end,
    Plugins = [{M, {plugin, F}} || {M, F} <- persistent_term:get({?MODULE, plugins}, [])],
    Found = [{impl_name(M), M, Src} || {M, Src} <- Builtin ++ Plugins, is_impl(M)],
    %% 同名时内置优先（插件不能覆盖内置实现）
    Dedup = lists:foldl(fun({N, _, _} = E, Acc) ->
                                case lists:keymember(N, 1, Acc) of true -> Acc; false -> Acc ++ [E] end
                        end, [], Found),
    Env = [{N, M, env} || {N, M} <- maps:to_list(application:get_env(lg_router, middleware_impls, #{}))],
    Env ++ [E || {N, _, _} = E <- Dedup, not lists:keymember(N, 1, Env)].

is_impl(M) ->
    _ = code:ensure_loaded(M),
    erlang:function_exported(M, describe, 0) andalso
        lists:member(?MODULE, lists:append([B || {behaviour, B} <- attrs(M)] ++ [B || {behavior, B} <- attrs(M)])).

attrs(M) ->
    try M:module_info(attributes) catch _:_ -> [] end.

impl_name(M) ->
    case catch M:describe() of
        #{name := N} when is_binary(N) -> N;
        _ ->
            case atom_to_binary(M) of
                <<"lg_mw_", Rest/binary>> -> Rest;
                B -> B
            end
    end.

%% @doc 实现的说明（控制台列出可选实现）：标题、说明、配置示例、默认点位与来源。
-spec impl_info() -> [map()].
impl_info() ->
    [(M:describe())#{impl => N, hooks => exported_hooks(M),
                     source => case Src of builtin -> builtin; env -> builtin; {plugin, _} -> plugin end,
                     file => case Src of {plugin, F} -> list_to_binary(F); _ -> null end}
     || {N, M, Src} <- lists:keysort(1, registry())].

exported_hooks(M) ->
    [H || H <- [on_request, on_event, on_response], erlang:function_exported(M, H, 3)].

%% @doc 某个中间件条目（实现 + 配置）实际启用的钩子；实现不存在时为 []。
-spec hooks_for(binary(), map()) -> [on_request | on_event | on_response].
hooks_for(Impl, O) ->
    case maps:find(Impl, impls()) of
        {ok, M} -> _ = code:ensure_loaded(M), entry_hooks(M, O);
        error -> []
    end.

%% 某个条目实际启用的钩子：实现可按配置决定（hooks/1），否则为导出的钩子
entry_hooks(M, O) ->
    case erlang:function_exported(M, hooks, 1) of
        true -> try [H || H <- M:hooks(O), lists:member(H, exported_hooks(M))] catch _:_ -> exported_hooks(M) end;
        false -> exported_hooks(M)
    end.

entry_timeout(M, O) ->
    case erlang:function_exported(M, timeout, 1) of
        true -> try M:timeout(O) catch _:_ -> ?SYNC_TIMEOUT_MS end;
        false -> ?SYNC_TIMEOUT_MS
    end.

%% @doc 插件目录：运行参数 middleware_plugin_dir，空时为 <data_dir>/plugins。
-spec plugin_dir() -> file:filename().
plugin_dir() ->
    case lg_config:get(middleware_plugin_dir) of
        D when is_binary(D), D =/= <<>> -> binary_to_list(D);
        _ -> filename:join(lg_config:data_dir(), "plugins")
    end.

%% @doc 重新扫描插件目录：加载 *.beam 与 */ebin/*.beam（改过的模块热替换），重建调用链。
%% 返回每个文件的结果：loaded（是中间件实现）、library（加载了，但不是实现，如插件的辅助模块）、或 {error, 原因}。
-spec rescan() -> #{dir := binary(), files := [map()]}.
rescan() ->
    gen_server:call(?MODULE, rescan, 60000).

do_rescan() ->
    Dir = plugin_dir(),
    Beams = lists:sort(filelib:wildcard(filename:join(Dir, "*.beam")) ++ filelib:wildcard(filename:join([Dir, "*", "ebin", "*.beam"]))),
    _ = [code:add_patha(E) || E <- lists:usort([filename:dirname(B) || B <- Beams]), filename:basename(E) =:= "ebin"],
    Builtin = case application:get_key(lg_router, modules) of {ok, Ms} -> Ms; undefined -> [] end,
    Results =
        [begin
             Mod = list_to_atom(filename:basename(B, ".beam")),
             R = case lists:member(Mod, Builtin) orelse code:which(Mod) =:= preloaded of
                     true -> {error, <<"与网关自带模块同名"/utf8>>};
                     false ->
                         _ = code:soft_purge(Mod),
                         case code:load_abs(filename:rootname(B)) of
                             {module, Mod} ->
                                 case is_impl(Mod) of
                                     true ->
                                         N = impl_name(Mod),
                                         case lists:keyfind(N, 1, [{impl_name(M), M} || M <- Builtin, is_impl(M)]) of
                                             false -> {loaded, N};
                                             _ -> {error, <<"实现名与内置实现冲突："/utf8, N/binary>>}
                                         end;
                                     false -> library
                                 end;
                             {error, Why} -> {error, iolist_to_binary(io_lib:format("~p", [Why]))}
                         end
                 end,
             {Mod, B, R}
         end || B <- Beams],
    persistent_term:put({?MODULE, plugins}, [{M, F} || {M, F, {loaded, _}} <- Results]),
    build(),
    #{dir => list_to_binary(filename:absname(Dir)),
      files => [#{module => M, file => list_to_binary(F),
                  result => case R of {loaded, N} -> #{status => loaded, impl => N};
                                      library -> #{status => library};
                                      {error, E} -> #{status => error, message => E} end}
                || {M, F, R} <- Results]}.

%% @doc 配置变化后重建调用链缓存。
-spec reload() -> ok.
reload() ->
    gen_server:call(?MODULE, reload).

%% @doc 某路由生效的中间件（按 position 顺序）。没有启用任何中间件时返回 []。
-spec chain(binary()) -> [map()].
chain(Route) ->
    case catch ets:lookup(?CHAIN, chain) of
        [{_, []}] -> [];
        [{_, All}] -> [E || #{routes := Rs} = E <- All, Rs =:= all orelse lists:member(Route, Rs)];
        _ -> []
    end.

%% @doc 开始一次请求的中间件运行；没有中间件时返回 none（各点位直接跳过）。
-spec begin_run(binary(), map()) -> run() | none.
begin_run(Route, Ctx) ->
    case chain(Route) of
        [] -> none;
        Chain -> #{chain => Chain, ctx => Ctx, states => #{}}
    end.

%% @doc 运行中是否有实现了某钩子的中间件（没有时调用方跳过解析 / 编码）。
-spec has(run() | none, on_request | on_event | on_response) -> boolean().
has(none, _) -> false;
has(#{chain := Chain}, Hook) -> lists:any(fun(#{hooks := Hs}) -> lists:member(Hook, Hs) end, Chain).

%% @doc on_request：{ok, Body, Run} | {reject, Status, Message, Run}。
-spec request(run() | none, map()) -> {ok, map(), run() | none} | {reject, pos_integer(), binary(), run() | none}.
request(none, Body) ->
    {ok, Body, none};
request(#{chain := Chain} = Run, Body0) ->
    request(Chain, Body0, Run).

request([], Body, Run) ->
    {ok, Body, Run};
request([#{id := Id, mod := M, options := O, hooks := Hs} = E | Rest], Body, #{ctx := Ctx, states := Sts} = Run) ->
    case lists:member(on_request, Hs) of
        false -> request(Rest, Body, Run);
        true ->
            case call_sync(E, on_request, fun() -> M:on_request(Body, Ctx#{state => maps:get(Id, Sts, undefined)}, O) end) of
                {ok, B} when is_map(B) -> request(Rest, B, Run);
                {ok, B, St} when is_map(B) -> request(Rest, B, Run#{states => Sts#{Id => St}});
                {reject, S, Msg} when is_integer(S), S >= 400, S < 600, is_binary(Msg) -> {reject, S, Msg, Run};
                continue -> request(Rest, Body, Run);
                Other -> failed(E, on_request, {bad_return, Other}), request(Rest, Body, Run)
            end
    end.

%% @doc on_event：Event = #{event, data}（data 为 JSON 对象）→ {ok, Event} | drop。
-spec event(run() | none, map()) -> {ok, map()} | drop.
event(none, Ev) ->
    {ok, Ev};
event(#{chain := Chain, ctx := Ctx, states := Sts}, Ev0) ->
    lists:foldl(
      fun(_, drop) -> drop;
         (#{id := Id, mod := M, options := O, hooks := Hs} = E, {ok, Ev}) ->
              case lists:member(on_event, Hs) of
                  false -> {ok, Ev};
                  true ->
                      T0 = erlang:monotonic_time(microsecond),
                      R = try M:on_event(Ev, Ctx#{state => maps:get(Id, Sts, undefined)}, O)
                          catch C:Why -> {crashed, C, Why}
                          end,
                      Us = erlang:monotonic_time(microsecond) - T0,
                      count(Id, Us, Us > ?EVENT_SLOW_US),
                      case R of
                          {ok, Ev1} when is_map(Ev1) -> {ok, Ev1};
                          drop -> drop;
                          continue -> {ok, Ev};
                          Other -> failed(E, on_event, Other), {ok, Ev}
                      end
              end
      end, {ok, Ev0}, Chain).

%% @doc on_response：非流式回复体（JSON 对象）。
-spec response(run() | none, map()) -> map().
response(none, Body) ->
    Body;
response(#{chain := Chain, ctx := Ctx, states := Sts}, Body0) ->
    lists:foldl(
      fun(#{id := Id, mod := M, hooks := Hs} = E, Body) ->
              case lists:member(on_response, Hs) of
                  false -> Body;
                  true ->
                      O = maps:get(options, E),
                      case call_sync(E, on_response, fun() -> M:on_response(Body, Ctx#{state => maps:get(Id, Sts, undefined)}, O) end) of
                          {ok, B} when is_map(B) -> B;
                          continue -> Body;
                          Other -> failed(E, on_response, {bad_return, Other}), Body
                      end
              end
      end, Body0, Chain).

%% 在独立进程中运行，超时或崩溃时放行
call_sync(#{id := Id} = E, Hook, F) ->
    Timeout = maps:get(timeout, E, ?SYNC_TIMEOUT_MS),
    Parent = self(),
    Ref = make_ref(),
    T0 = erlang:monotonic_time(microsecond),
    {Pid, MRef} = spawn_monitor(fun() -> Parent ! {Ref, try F() catch C:Why -> {crashed, C, Why} end} end),
    R = receive
            {Ref, Res} -> erlang:demonitor(MRef, [flush]), Res;
            {'DOWN', MRef, process, Pid, Why} -> {crashed, exit, Why}
        after Timeout ->
            exit(Pid, kill),
            erlang:demonitor(MRef, [flush]),
            receive {Ref, _} -> ok after 0 -> ok end,
            timeout
        end,
    count(Id, erlang:monotonic_time(microsecond) - T0, R =:= timeout),
    case R of
        {crashed, _, _} -> failed(E, Hook, R), continue;
        timeout -> failed(E, Hook, timeout), continue;
        _ -> R
    end.

count(Id, Us, Slow) ->
    catch ets:update_counter(?STATS, Id, [{2, 1}, {4, case Slow of true -> 1; false -> 0 end}, {5, Us}],
                             {Id, 0, 0, 0, 0}),
    ok.

failed(#{id := Id, name := N}, Hook, Why) ->
    catch ets:update_counter(?STATS, Id, [{3, 1}], {Id, 0, 0, 0, 0}),
    Msg = iolist_to_binary(io_lib:format("~0p", [Why])),
    catch ets:insert(?STATS, {{last_error, Id}, lg_time:now_ms(), Hook, binary:part(Msg, 0, min(500, byte_size(Msg)))}),
    logger:warning("middleware ~ts ~s failed (passed through): ~ts", [N, Hook, Msg]),
    ok.

%% @doc 每个中间件的调用统计：#{Id => #{calls, failures, slow, avg_us, last_error}}。
-spec stats() -> #{binary() => map()}.
stats() ->
    maps:from_list(
      [{Id, #{calls => C, failures => F, slow => Sl, avg_us => case C of 0 -> 0; _ -> T div C end,
              last_error => case ets:lookup(?STATS, {last_error, Id}) of
                                [{_, At, Hook, Msg}] -> #{at => At, hook => Hook, message => Msg};
                                [] -> null
                            end}}
       || {Id, C, F, Sl, T} <- ets:tab2list(?STATS), is_binary(Id)]).

%%====================================================================
%% gen_server（持有缓存与统计表）
%%====================================================================

init([]) ->
    ?CHAIN = ets:new(?CHAIN, [named_table, public, {read_concurrency, true}]),
    ?STATS = ets:new(?STATS, [named_table, public, {write_concurrency, true}]),
    %% 启动时加载插件目录（同时建好调用链）
    Report = do_rescan(),
    [logger:warning("middleware plugin ~ts: ~ts", [F, maps:get(message, R)])
     || #{file := F, result := #{status := error} = R} <- maps:get(files, Report)],
    {ok, #{}}.

handle_call(reload, _From, S) ->
    build(),
    {reply, ok, S};
handle_call(rescan, _From, S) ->
    {reply, do_rescan(), S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(_Msg, S) ->
    {noreply, S}.

build() ->
    Impls = impls(),
    %% 实现不存在（插件被删掉）的条目不进调用链
    All = lists:keysort(1, [{P, N, entry(Id, N, maps:get(I, Impls), O, Rs)}
                            || #lg_middleware{id = Id, name = N, impl = I, options = O, routes = Rs, position = P,
                                              enabled = true} <- lg_db:all(lg_middleware),
                               maps:is_key(I, Impls)]),
    Chain = [E || {_, _, E} <- All],
    ets:insert(?CHAIN, {chain, Chain}),
    ok.

entry(Id, N, M, O, Rs) ->
    _ = code:ensure_loaded(M),
    #{id => Id, name => N, mod => M, options => O, routes => Rs, hooks => entry_hooks(M, O), timeout => entry_timeout(M, O)}.

%% @doc 试运行：用实现与配置对一个示例请求体调用一次 on_request（不经过路由、不访问上游，不计入统计）。
%% 返回 #{result => continue | {ok, Body} | {ok, Body, State} | {reject, S, M} | {error, 原因}, us => 耗时}。
-spec test(binary(), map(), map()) -> {ok, map()} | {error, term()}.
test(Impl, Options, #{body := Body} = Ctx0) ->
    case maps:find(Impl, impls()) of
        error -> {error, {invalid, <<"impl">>}};
        {ok, M} ->
            E = entry(<<"test">>, <<"test">>, M, Options, all),
            Ctx = maps:merge(#{route => <<"test">>, model => maps:get(<<"model">>, Body, null), stream => false,
                               client => null, key_name => null, tags => [], session => null, state => undefined},
                             maps:remove(body, Ctx0)),
            case lists:member(on_request, maps:get(hooks, E)) of
                false -> {ok, #{result => no_hook, us => 0}};
                true ->
                    Parent = self(),
                    Ref = make_ref(),
                    T0 = erlang:monotonic_time(microsecond),
                    {Pid, MRef} = spawn_monitor(fun() ->
                                                        Parent ! {Ref, try M:on_request(Body, Ctx, Options)
                                                                       catch C:Why:St -> {error, {C, Why, lists:sublist(St, 3)}} end}
                                                end),
                    R = receive
                            {Ref, Res} -> erlang:demonitor(MRef, [flush]), Res;
                            {'DOWN', MRef, process, Pid, Why} -> {error, {exit, Why}}
                        after maps:get(timeout, E) ->
                            exit(Pid, kill),
                            erlang:demonitor(MRef, [flush]),
                            {error, timeout}
                        end,
                    {ok, #{result => R, us => erlang:monotonic_time(microsecond) - T0, timeout_ms => maps:get(timeout, E)}}
            end
    end.
