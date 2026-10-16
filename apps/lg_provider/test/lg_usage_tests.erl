-module(lg_usage_tests).

-include_lib("eunit/include/eunit.hrl").

openai_test() ->
    U = lg_usage:from_openai(#{<<"prompt_tokens">> => 100, <<"completion_tokens">> => 20,
                               <<"prompt_tokens_details">> => #{<<"cached_tokens">> => 30},
                               <<"completion_tokens_details">> => #{<<"reasoning_tokens">> => 5}}),
    ?assertEqual(#{input => 70, output => 20, cache_read => 30, cache_write => 0, reasoning => 5}, U),
    ?assertMatch(#{<<"prompt_tokens">> := 100, <<"total_tokens">> := 120}, lg_usage:to_openai(U)).

deepseek_test() ->
    ?assertMatch(#{input := 60, cache_read := 40},
                 lg_usage:from_openai(#{<<"prompt_tokens">> => 100,
                                        <<"prompt_cache_hit_tokens">> => 40,
                                        <<"completion_tokens">> => 1})).

anthropic_merge_test() ->
    A = lg_usage:merge_anthropic(#{}, #{<<"input_tokens">> => 10, <<"output_tokens">> => 1,
                                        <<"cache_read_input_tokens">> => 50,
                                        <<"cache_creation_input_tokens">> => null}),
    B = lg_usage:merge_anthropic(A, #{<<"output_tokens">> => 42}),
    U = lg_usage:from_anthropic(B),
    ?assertEqual(#{input => 10, output => 42, cache_read => 50, cache_write => 0, reasoning => 0}, U),
    ?assertEqual(102, lg_usage:total(U)),
    %% Anthropic → OpenAI 语义：prompt 含缓存
    ?assertMatch(#{<<"prompt_tokens">> := 60,
                   <<"prompt_tokens_details">> := #{<<"cached_tokens">> := 50}},
                 lg_usage:to_openai(U)).

cost_test() ->
    U = #{input => 1000000, output => 500000, cache_read => 2000000, cache_write => 0, reasoning => 0},
    P = #{input => 1, output => 5, cache_read => 0.1, cache_write => 1.25},
    ?assertEqual(3.7, lg_usage:cost(U, P)),
    ?assertEqual(lg_usage:zero(), lg_usage:from_openai(null)).
