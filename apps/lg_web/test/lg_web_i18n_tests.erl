%% @doc 控制台多语言：Accept-Language 解析、实时视图按语言选叙述、英文接口文档与中文版结构一致。
-module(lg_web_i18n_tests).

-include_lib("eunit/include/eunit.hrl").

-define(CJK, "[\\x{3000}-\\x{303f}\\x{4e00}-\\x{9fff}\\x{ff00}-\\x{ffef}]").

parse_lang_test() ->
    ?assertEqual(en, lg_api:parse_lang(<<"en">>)),
    ?assertEqual(en, lg_api:parse_lang(<<"en-US,en;q=0.9,zh-CN;q=0.8">>)),
    ?assertEqual(en, lg_api:parse_lang(<<" EN-gb ">>)),
    ?assertEqual(zh, lg_api:parse_lang(<<"zh-CN">>)),
    ?assertEqual(zh, lg_api:parse_lang(<<"zh-CN,zh;q=0.9,en;q=0.8">>)),
    ?assertEqual(zh, lg_api:parse_lang(<<"fr">>)),
    ?assertEqual(zh, lg_api:parse_lang(<<>>)),
    ?assertEqual(zh, lg_api:parse_lang(undefined)).

%% 查询参数 lang 优先于 Accept-Language；都没有时为中文
lang_from_req_test() ->
    Req = fun(Qs, H) -> #{qs => Qs, headers => H} end,
    ?assertEqual(zh, lg_api:lang(Req(<<>>, #{}))),
    ?assertEqual(en, lg_api:lang(Req(<<>>, #{<<"accept-language">> => <<"en">>}))),
    ?assertEqual(zh, lg_api:lang(Req(<<>>, #{<<"accept-language">> => <<"zh-CN">>}))),
    ?assertEqual(en, lg_api:lang(Req(<<"lang=en">>, #{<<"accept-language">> => <<"zh-CN">>}))),
    ?assertEqual(zh, lg_api:lang(Req(<<"route=x&lang=zh">>, #{<<"accept-language">> => <<"en">>}))),
    %% 空的 lang 参数视为没带
    ?assertEqual(en, lg_api:lang(Req(<<"lang=">>, #{<<"accept-language">> => <<"en">>}))).

localize_live_test() ->
    Zh = [#{tone => info, text => <<"中文"/utf8>>}],
    En = [#{tone => info, text => <<"English">>}],
    Ev = #{route => <<"r">>, narrative => Zh, narrative_en => En},
    ?assertEqual(#{route => <<"r">>, narrative => En}, lg_api:localize_live(Ev, en)),
    ?assertEqual(#{route => <<"r">>, narrative => Zh}, lg_api:localize_live(Ev, zh)),
    %% 没有英文版时保留中文
    ?assertEqual(#{narrative => Zh}, lg_api:localize_live(#{narrative => Zh}, en)),
    %% 其它事件原样
    ?assertEqual(#{request_id => <<"x">>}, lg_api:localize_live(#{request_id => <<"x">>}, en)),
    State = #{routes => [], active => [], selected => <<"r">>, window_ms => 1,
              targets => [#{credential => <<"c">>, note => <<"5h 80% 重置 10-13 14:00 · 近期 9 tok"/utf8>>},
                          #{credential => <<"d">>}],
              last => #{route => <<"r">>, narrative => Zh, narrative_en => En, ts => 1}},
    #{targets := [#{note := N}, #{credential := <<"d">>}], last := Last} = lg_api:localize_live(State, en),
    ?assertEqual(<<"5h 80% resets 10-13 14:00 · recent 9 tok"/utf8>>, N),
    ?assertEqual(#{route => <<"r">>, narrative => En, ts => 1}, Last),
    #{targets := [#{note := NZh} | _], last := LastZh} = lg_api:localize_live(State, zh),
    ?assertEqual(<<"5h 80% 重置 10-13 14:00 · 近期 9 tok"/utf8>>, NZh),
    ?assertEqual(#{route => <<"r">>, narrative => Zh, ts => 1}, LastZh),
    ?assertMatch(#{last := null}, lg_api:localize_live(State#{last := null}, en)).

%%--------------------------------------------------------------------
%% 接口文档：openapi.en.json 与 openapi.json 键结构完全一致，只有含中文的字符串换成英文；英文版不含中日韩字符

doc(File) ->
    {ok, B} = file:read_file(filename:join(code:priv_dir(lg_web), File)),
    {B, json:decode(B)}.

openapi_en_test() ->
    {_, Zh} = doc("openapi.json"),
    {EnBin, En} = doc("openapi.en.json"),
    ?assertEqual(nomatch, re:run(EnBin, ?CJK, [unicode])),
    ?assertEqual([], same_shape(Zh, En, [])),
    %% 分组名改名一致：顶层 tags 与各操作 tags 里，同一个中文分组名总是译成同一个英文名，不同的中文名不会译成同一个
    Pairs = lists:usort(lists:zip(tag_names(Zh), tag_names(En))),
    ?assertEqual(length(Pairs), length(lists:usort([Z || {Z, _} <- Pairs]))),
    ?assertEqual(length(Pairs), length(lists:usort([E || {_, E} <- Pairs]))).

%% 每个操作的分组都在顶层 tags 里声明过（控制台接口文档页只渲染已声明的分组，未声明的操作会看不到）
openapi_tags_declared_test() ->
    [begin
         {_, Doc} = doc(F),
         Declared = [N || #{<<"name">> := N} <- maps:get(<<"tags">>, Doc)],
         Undeclared = [{F, Method, Path, T}
                       || {Path, Ops} <- maps:to_list(maps:get(<<"paths">>, Doc)),
                          {Method, #{<<"tags">> := Ts}} <- maps:to_list(Ops),
                          T <- Ts, not lists:member(T, Declared)],
         ?assertEqual([], Undeclared)
     end || F <- ["openapi.json", "openapi.en.json"]].

%% 文档里出现的全部分组名（顶层 tags，再按路径、方法排序的各操作 tags），顺序在两份文档间一致
tag_names(Doc) ->
    [N || #{<<"name">> := N} <- maps:get(<<"tags">>, Doc)] ++
        [T || {_, Ops} <- lists:sort(maps:to_list(maps:get(<<"paths">>, Doc))),
              {_, #{<<"tags">> := Ts}} <- lists:sort(maps:to_list(Ops)), T <- Ts].

%% 返回差异列表（路径 + 原因），空表示一致
same_shape(A, B, Path) when is_map(A), is_map(B) ->
    case lists:sort(maps:keys(A)) =:= lists:sort(maps:keys(B)) of
        true -> lists:append([same_shape(V, maps:get(K, B), [K | Path]) || K := V <- A]);
        false -> [{lists:reverse(Path), keys, maps:keys(A) -- maps:keys(B), maps:keys(B) -- maps:keys(A)}]
    end;
same_shape(A, B, Path) when is_list(A), is_list(B), length(A) =:= length(B) ->
    lists:append([same_shape(X, Y, [I | Path]) || {I, X, Y} <- lists:zip3(lists:seq(0, length(A) - 1), A, B)]);
same_shape(A, B, Path) when is_binary(A), is_binary(B) ->
    case re:run(A, ?CJK, [unicode]) of
        nomatch when A =:= B -> [];
        nomatch -> [{lists:reverse(Path), changed_non_cjk, A, B}];   %% 没有中文的字符串（路径、示例值等）必须原样
        _ when B =:= <<>> -> [{lists:reverse(Path), empty_translation}];
        _ -> []
    end;
same_shape(A, A, _) -> [];
same_shape(A, B, Path) -> [{lists:reverse(Path), differs, A, B}].
