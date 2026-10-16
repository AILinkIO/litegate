-module(lg_catalog_tests).

-include_lib("eunit/include/eunit.hrl").

-define(HAIKU, {<<"anthropic">>, <<"claude-haiku-4-5">>}).

catalog_test_() ->
    {foreach,
     fun() ->
             Dir = lg_core_test_util:start(),
             {ok, _} = application:ensure_all_started(lg_catalog),
             Dir
     end,
     fun(Dir) ->
             application:stop(lg_catalog),
             lg_core_test_util:stop(Dir)
     end,
     [?_test(import_and_lookup()),
      ?_test(resync_removes_stale_and_skips_unchanged()),
      ?_test(overlay_override()),
      ?_test(overlay_custom_model()),
      ?_test(overlay_survives_sync()),
      ?_test(pricing_fallback()),
      ?_test(protocol()),
      ?_test(bad_input())]}.

fixture() ->
    #{<<"anthropic">> =>
          #{<<"id">> => <<"anthropic">>, <<"name">> => <<"Anthropic">>,
            <<"npm">> => <<"@ai-sdk/anthropic">>, <<"env">> => [<<"ANTHROPIC_API_KEY">>],
            <<"models">> =>
                #{<<"claude-haiku-4-5">> =>
                      #{<<"id">> => <<"claude-haiku-4-5">>, <<"name">> => <<"Claude Haiku 4.5">>,
                        <<"limit">> => #{<<"context">> => 200000, <<"output">> => 64000},
                        <<"cost">> => #{<<"input">> => 1, <<"output">> => 5,
                                        <<"cache_read">> => 0.1, <<"cache_write">> => 1.25}}}},
      <<"deepseek">> =>
          #{<<"id">> => <<"deepseek">>, <<"name">> => <<"DeepSeek">>,
            <<"npm">> => <<"@ai-sdk/openai-compatible">>, <<"api">> => <<"https://api.deepseek.com">>,
            <<"models">> =>
                #{<<"deepseek-chat">> =>
                      #{<<"name">> => <<"DeepSeek Chat">>,
                        <<"cost">> => #{<<"input">> => 0.27, <<"output">> => 1.1}},
                  <<"deepseek-old">> => #{<<"name">> => <<"Old">>}}},
      <<"bedrock">> =>
          #{<<"name">> => <<"Bedrock">>, <<"npm">> => <<"@ai-sdk/amazon-bedrock">>,
            <<"models">> => #{}}}.

import(Data) ->
    lg_catalog_sync:import(iolist_to_binary(json:encode(Data))).

import_and_lookup() ->
    {ok, Stats} = import(fixture()),
    ?assertMatch(#{providers := 3, models := 3, changed_models := 3}, Stats),
    {ok, M} = lg_catalog:model(?HAIKU),
    ?assertMatch(#{<<"name">> := <<"Claude Haiku 4.5">>, <<"source">> := <<"synced">>,
                   <<"provider">> := <<"anthropic">>, <<"id">> := <<"claude-haiku-4-5">>}, M),
    ?assertEqual(2, length(lg_catalog:models(<<"deepseek">>))),
    ?assertEqual(3, length(lg_catalog:models())),
    ?assertEqual([<<"anthropic">>, <<"bedrock">>, <<"deepseek">>],
                 [maps:get(<<"id">>, P) || P <- lg_catalog:providers()]),
    ?assertMatch(#{status := ok, models := 3, source := <<"import">>}, lg_catalog_sync:status()).

resync_removes_stale_and_skips_unchanged() ->
    {ok, _} = import(fixture()),
    F = fixture(),
    DS = maps:get(<<"deepseek">>, F),
    F2 = F#{<<"deepseek">> := DS#{<<"models">> := maps:remove(<<"deepseek-old">>,
                                                               maps:get(<<"models">>, DS))}},
    F3 = maps:remove(<<"bedrock">>, F2),
    {ok, Stats} = import(F3),
    ?assertMatch(#{changed_models := 0, changed_providers := 0,
                   removed_models := 1, removed_providers := 1}, Stats),
    ?assertEqual(not_found, lg_catalog:model({<<"deepseek">>, <<"deepseek-old">>})),
    ?assertEqual(not_found, lg_catalog:provider(<<"bedrock">>)).

overlay_override() ->
    {ok, _} = import(fixture()),
    ok = lg_catalog:put_overlay(?HAIKU, #{<<"cost">> => #{<<"input">> => 2,
                                                          <<"cache_write">> => null},
                                          <<"name">> => <<"Haiku (公司价)"/utf8>>}),
    {ok, M} = lg_catalog:model(?HAIKU),
    ?assertMatch(#{<<"source">> := <<"overridden">>, <<"name">> := <<"Haiku (公司价)"/utf8>>,
                   <<"limit">> := #{<<"context">> := 200000}}, M),
    Cost = maps:get(<<"cost">>, M),
    ?assertEqual(#{<<"input">> => 2, <<"output">> => 5, <<"cache_read">> => 0.1}, Cost),
    %% cache_write 被删除后回退为输入价
    ?assertMatch({ok, #{input := 2, cache_write := 2}}, lg_catalog:pricing(?HAIKU)),
    ok = lg_catalog:delete_overlay(?HAIKU),
    ?assertMatch({ok, #{<<"source">> := <<"synced">>}}, lg_catalog:model(?HAIKU)).

overlay_custom_model() ->
    {ok, _} = import(fixture()),
    Ref = {<<"my-vllm">>, <<"qwen3-32b">>},
    ok = lg_catalog:put_overlay(Ref, #{<<"name">> => <<"Qwen3 32B">>,
                                       <<"source">> => <<"ignored">>}),
    ?assertMatch({ok, #{<<"source">> := <<"custom">>, <<"name">> := <<"Qwen3 32B">>}},
                 lg_catalog:model(Ref)),
    ?assertEqual({ok, #{<<"name">> => <<"Qwen3 32B">>}}, lg_catalog:overlay(Ref)),
    ?assertMatch([#{<<"id">> := <<"my-vllm">>, <<"source">> := <<"custom">>}],
                 [P || P = #{<<"id">> := <<"my-vllm">>} <- lg_catalog:providers()]),
    ?assertEqual({error, {invalid_ref, {<<>>, <<"x">>}}},
                 lg_catalog:put_overlay({<<>>, <<"x">>}, #{})).

overlay_survives_sync() ->
    {ok, _} = import(fixture()),
    ok = lg_catalog:put_overlay(?HAIKU, #{<<"name">> => <<"Mine">>}),
    {ok, _} = import(maps:remove(<<"anthropic">>, fixture())),
    %% L0 下架后覆盖仍在，变成自定义模型
    ?assertMatch({ok, #{<<"source">> := <<"custom">>, <<"name">> := <<"Mine">>}},
                 lg_catalog:model(?HAIKU)).

pricing_fallback() ->
    {ok, _} = import(fixture()),
    ?assertEqual({ok, #{input => 0.27, output => 1.1, cache_read => 0.27, cache_write => 0.27, image => 0, tts => 0}},
                 lg_catalog:pricing({<<"deepseek">>, <<"deepseek-chat">>})),
    ?assertEqual({ok, #{input => 0, output => 0, cache_read => 0, cache_write => 0}},
                 lg_catalog:pricing({<<"deepseek">>, <<"deepseek-old">>})),
    ?assertEqual(not_found, lg_catalog:pricing({<<"x">>, <<"y">>})).

protocol() ->
    {ok, _} = import(fixture()),
    ?assertEqual({ok, anthropic, <<"https://api.anthropic.com">>},
                 lg_catalog:protocol(<<"anthropic">>)),
    ?assertEqual({ok, openai, <<"https://api.deepseek.com">>}, lg_catalog:protocol(<<"deepseek">>)),
    ?assertEqual(unsupported, lg_catalog:protocol(<<"bedrock">>)),
    ?assertEqual(unsupported, lg_catalog:protocol(<<"nope">>)),
    {ok, P} = lg_catalog:provider(<<"bedrock">>),
    ?assertMatch(#{<<"protocol">> := null, <<"api">> := null}, P).

bad_input() ->
    ?assertMatch({error, {bad_json, _}}, lg_catalog_sync:import(<<"{not json">>)),
    ?assertMatch({error, {empty_catalog, 0}}, import(#{})),
    ?assertMatch(#{status := error}, lg_catalog_sync:status()).
