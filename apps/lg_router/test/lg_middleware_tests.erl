%% @doc 中间件运行时：实现的发现、插件目录（加载、热替换、冲突、删除）、远程节点（peer）、试运行。
-module(lg_middleware_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("lg_core/include/lg_core.hrl").

middleware_test_() ->
    {foreach,
     fun() ->
             %% 远程节点用例需要分布式；在 mnesia 启动之前打开（中途改节点名会让 mnesia 卡住）
             ensure_distributed(),
             Dir = lg_core_test_util:start(),
             Plugins = filename:join(Dir, "plugins"),
             ok = filelib:ensure_path(Plugins),
             {ok, _} = application:ensure_all_started(lg_router),
             #{dir => Dir, plugins => Plugins}
     end,
     fun(#{dir := Dir}) ->
             application:stop(lg_router),
             [begin code:purge(M), code:delete(M), code:purge(M) end || M <- [mw_plug, mw_lib, lg_mw_model_map_dup]],
             lg_core_test_util:stop(Dir)
     end,
     [fun(C) -> ?_test(builtins(C)) end,
      fun(C) -> {timeout, 30, ?_test(plugins(C))} end,
      fun(C) -> {timeout, 60, ?_test(remote(C))} end,
      fun(C) -> ?_test(dry_run(C)) end]}.

ensure_distributed() ->
    case node() of
        nonode@nohost ->
            _ = os:cmd("epmd -daemon"),
            {ok, _} = net_kernel:start(list_to_atom("lg_mw_test_" ++ os:getpid()), #{name_domain => shortnames}),
            ok;
        _ -> ok
    end.

builtins(_) ->
    Info = lg_middleware:impl_info(),
    Names = [N || #{impl := N} <- Info],
    [?assert(lists:member(N, Names)) || N <- [<<"model_map">>, <<"system_prompt">>, <<"word_guard">>, <<"param_override">>, <<"remote">>]],
    ?assert(lists:all(fun(#{source := S}) -> S =:= builtin end, Info)),
    %% hooks/1：word_guard 的 mask 模式只启用事件与响应点位
    {ok, _} = lg_middlewares:create(#{<<"name">> => <<"wg">>, <<"impl">> => <<"word_guard">>,
                                      <<"options">> => #{<<"words">> => [<<"x">>], <<"mode">> => <<"mask">>}}),
    Run = lg_middleware:begin_run(<<"any">>, #{}),
    ?assertNot(lg_middleware:has(Run, on_request)),
    ?assert(lg_middleware:has(Run, on_event)),
    ?assert(lg_middleware:has(Run, on_response)).

%% 写一个插件模块的源码并编译到插件目录
plugin(Dir, Mod, Body) ->
    Src = filename:join(Dir, atom_to_list(Mod) ++ ".erl"),
    ok = file:write_file(Src, Body),
    {ok, Mod} = compile:file(Src, [{outdir, Dir}, report_errors]),
    ok = file:delete(Src).

plug_src(Reply) ->
    ["-module(mw_plug).\n-behaviour(lg_middleware).\n-export([describe/0, on_request/3]).\n"
     "describe() -> #{name => <<\"plug\">>, title => <<\"p\">>, description => <<\"d\">>, options_example => #{}}.\n"
     "on_request(_B, _C, _O) -> {reject, 403, <<\"", Reply, "\">>}.\n"].

plugins(#{plugins := Dir}) ->
    ok = lg_config:set(middleware_plugin_dir, list_to_binary(Dir)),
    plugin(Dir, mw_plug, plug_src("v1")),
    %% 不是中间件实现的辅助模块
    plugin(Dir, mw_lib, "-module(mw_lib).\n-export([f/0]).\nf() -> 1.\n"),
    %% 实现名与内置冲突
    plugin(Dir, lg_mw_model_map_dup, "-module(lg_mw_model_map_dup).\n-behaviour(lg_middleware).\n-export([describe/0]).\n"
                                     "describe() -> #{name => <<\"model_map\">>, title => <<\"x\">>, description => <<\"x\">>, options_example => #{}}.\n"),
    #{files := Files} = lg_middleware:rescan(),
    St = maps:from_list([{M, R} || #{module := M, result := R} <- Files]),
    ?assertMatch(#{status := loaded, impl := <<"plug">>}, maps:get(mw_plug, St)),
    ?assertMatch(#{status := library}, maps:get(mw_lib, St)),
    ?assertMatch(#{status := error}, maps:get(lg_mw_model_map_dup, St)),
    ?assertMatch([#{source := plugin}], [I || #{impl := <<"plug">>} = I <- lg_middleware:impl_info()]),
    %% 内置的 model_map 没被覆盖
    ?assertEqual(lg_mw_model_map, maps:get(<<"model_map">>, lg_middleware:impls())),
    {ok, #lg_middleware{}} = lg_middlewares:create(#{<<"name">> => <<"p">>, <<"impl">> => <<"plug">>}),
    Req = fun() -> lg_middleware:request(lg_middleware:begin_run(<<"r">>, #{}), #{}) end,
    ?assertMatch({reject, 403, <<"v1">>, _}, Req()),
    %% 改了重新编译、再扫描：热替换
    plugin(Dir, mw_plug, plug_src("v2")),
    _ = lg_middleware:rescan(),
    ?assertMatch({reject, 403, <<"v2">>, _}, Req()),
    %% 插件删掉：条目不进调用链（请求照常通过）
    ok = file:delete(filename:join(Dir, "mw_plug.beam")),
    _ = lg_middleware:rescan(),
    ?assertNot(maps:is_key(<<"plug">>, lg_middleware:impls())),
    ?assertMatch({ok, #{}, _}, Req()).

%% 远程节点：peer 启动一个节点，加载示例模块 demo_mw（examples/middleware/remote）
remote(_) ->
    {ok, Peer, Node} = peer:start(#{name => peer:random_name(lg_mw_remote), args => ["-setcookie", atom_to_list(erlang:get_cookie())]}),
    try
        Src = filename:join([code:lib_dir(lg_router), "..", "..", "..", "..", "examples", "middleware", "remote", "src", "demo_mw.erl"]),
        {ok, demo_mw, Bin} = compile:file(Src, [binary, report_errors]),
        {module, demo_mw} = erpc:call(Node, code, load_binary, [demo_mw, "demo_mw.erl", Bin]),
        Opts = #{<<"node">> => atom_to_binary(Node), <<"module">> => <<"demo_mw">>,
                 <<"config">> => #{<<"block">> => [<<"forbidden">>]}, <<"events">> => true},
        ?assertEqual(ok, lg_mw_remote:validate(Opts)),
        ?assertMatch({error, _}, lg_mw_remote:validate(Opts#{<<"node">> => <<"no-at-sign">>})),
        {ok, _} = lg_middlewares:create(#{<<"name">> => <<"rm">>, <<"impl">> => <<"remote">>, <<"options">> => Opts}),
        Body = fun(T) -> #{<<"model">> => <<"m">>, <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => T}]} end,
        Run0 = lg_middleware:begin_run(<<"r">>, #{route => <<"r">>, format => openai}),
        ?assert(lg_middleware:has(Run0, on_event)),
        ?assertMatch({reject, 400, <<"blocked by remote middleware: forbidden">>, _}, lg_middleware:request(Run0, Body(<<"a forbidden thing">>))),
        {ok, _, Run} = lg_middleware:request(Run0, Body(<<"hello">>)),
        %% state 从远程 on_request 带到 on_response
        ?assertMatch(#{<<"x_remote_middleware">> := #{<<"node">> := _}}, lg_middleware:response(Run, #{})),
        Ev = #{event => undefined, data => #{<<"choices">> => [#{<<"delta">> => #{<<"content">> => <<"foo!">>}}]}},
        {ok, Ev1} = lg_middleware:event(Run, Ev),
        ?assertEqual(<<"bar!">>, lg_mw:event_text(Ev1, openai)),
        %% events 关掉：事件点位不启用
        [#lg_middleware{id = Id}] = lg_middlewares:list(),
        {ok, _} = lg_middlewares:update(Id, #{<<"options">> => Opts#{<<"events">> => false}}),
        ?assertNot(lg_middleware:has(lg_middleware:begin_run(<<"r">>, #{}), on_event)),
        %% 节点停掉：放行并计入失败
        peer:stop(Peer),
        ?assertMatch({ok, _, _}, lg_middleware:request(lg_middleware:begin_run(<<"r">>, #{route => <<"r">>, format => openai}), Body(<<"forbidden">>))),
        #{Id := #{failures := F, last_error := #{hook := on_request}}} = lg_middleware:stats(),
        ?assert(F >= 1)
    after
        catch peer:stop(Peer)
    end.

dry_run(_) ->
    Body = #{<<"model">> => <<"m">>, <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"say BAD">>}]},
    ?assertMatch({ok, #{result := {reject, 400, _}}},
                 lg_middleware:test(<<"word_guard">>, #{<<"words">> => [<<"bad">>]}, #{body => Body, format => openai})),
    {ok, #{result := {ok, B}, us := Us}} = lg_middleware:test(<<"system_prompt">>, #{<<"text">> => <<"t">>}, #{body => Body, format => openai}),
    ?assert(is_integer(Us)),
    ?assertMatch(#{<<"messages">> := [#{<<"role">> := <<"system">>} | _]}, B),
    %% mask 模式没有请求点位
    ?assertMatch({ok, #{result := no_hook}},
                 lg_middleware:test(<<"word_guard">>, #{<<"words">> => [<<"x">>], <<"mode">> => <<"mask">>}, #{body => Body, format => openai})),
    ?assertMatch({error, _}, lg_middleware:test(<<"nope">>, #{}, #{body => Body, format => openai})).
