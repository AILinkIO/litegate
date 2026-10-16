-module(lg_prompt_cache_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, #{<<"type">> => <<"ephemeral">>}).

auto_test() ->
    Body = #{<<"system">> => <<"sys">>,
             <<"tools">> => [#{<<"name">> => <<"a">>}, #{<<"name">> => <<"b">>}],
             <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"q1">>},
                                #{<<"role">> => <<"assistant">>, <<"content">> => <<"a1">>},
                                #{<<"role">> => <<"user">>,
                                  <<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"q2">>},
                                                    #{<<"type">> => <<"thinking">>, <<"thinking">> => <<"t">>}]}]},
    #{<<"system">> := [#{<<"text">> := <<"sys">>, <<"cache_control">> := #{<<"type">> := <<"ephemeral">>}}],
      <<"tools">> := [A, #{<<"name">> := <<"b">>, <<"cache_control">> := #{<<"type">> := <<"ephemeral">>}}],
      <<"messages">> := [U1, _, #{<<"content">> := [#{<<"text">> := <<"q2">>, <<"cache_control">> := #{<<"type">> := <<"ephemeral">>}},
                                                     #{<<"type">> := <<"thinking">>} = Th]}]} = lg_prompt_cache:apply(Body),
    ?assertNot(maps:is_key(<<"cache_control">>, A)),
    ?assertNot(maps:is_key(<<"cache_control">>, Th)),
    ?assertEqual(<<"q1">>, maps:get(<<"content">>, U1)).

client_marks_kept_test() ->
    Body = #{<<"system">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"s">>, <<"cache_control">> => ?M}],
             <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"q">>}]},
    ?assertEqual(Body, lg_prompt_cache:apply(Body)),
    ?assertEqual(#{}, lg_prompt_cache:apply(#{})).
