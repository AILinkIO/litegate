-module(lg_redact_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SK, <<"sk-abcdefghijklmnopqrstuvwxyz0123">>).
-define(GH, <<"ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef1234">>).

rules(Pii) ->
    persistent_term:erase({lg_redact, rules}),
    meck_config(#{redact_rules => <<"[{\"name\":\"corp\",\"pattern\":\"corp-[0-9]{6}\"}]">>, redact_pii => Pii}),
    R = lg_redact:rules(),
    meck:unload(lg_config),
    persistent_term:erase({lg_redact, rules}),
    R.

meck_config(M) ->
    meck:new(lg_config, [passthrough]),
    meck:expect(lg_config, get, fun(K) -> maps:get(K, M) end).

scan_test() ->
    R = rules(<<>>),
    Body = #{<<"model">> => <<"m">>,
             <<"messages">> => [#{<<"role">> => <<"user">>,
                                  <<"content">> => <<"key ", ?SK/binary, " and ", ?GH/binary, " again ", ?SK/binary,
                                                     " corp-123456 phone 13812345678">>}]},
    {B, Map} = lg_redact:scan(Body, R),
    [#{<<"content">> := C}] = maps:get(<<"messages">>, B),
    ?assertEqual(<<"key [[LG_SECRET_1]] and [[LG_SECRET_2]] again [[LG_SECRET_1]] [[LG_SECRET_3]] phone 13812345678">>,
                 C),
    ?assertEqual(?SK, maps:get(<<"[[LG_SECRET_1]]">>, Map)),
    ?assertEqual(3, map_size(Map)),
    ?assertEqual(<<"m">>, maps:get(<<"model">>, B)).

pii_test() ->
    R = rules(<<"phone,bank_card">>),
    {B, _} = lg_redact:scan(<<"tel 13812345678 card 4111111111111111 bad 4111111111111112">>, R),
    ?assertEqual(<<"tel [[LG_SECRET_1]] card [[LG_SECRET_2]] bad 4111111111111112">>, B).

signed_content_untouched_test() ->
    R = rules(<<>>),
    Thinking = #{<<"type">> => <<"thinking">>, <<"thinking">> => <<"uses ", ?SK/binary>>, <<"signature">> => <<"sig">>},
    Body = #{<<"messages">> => [#{<<"role">> => <<"assistant">>,
                                  <<"content">> => [Thinking, #{<<"type">> => <<"text">>, <<"text">> => ?SK}]}],
             <<"input">> => [#{<<"type">> => <<"reasoning">>, <<"encrypted_content">> => ?SK}],
             <<"image">> => <<"data:image/png;base64,", ?SK/binary>>},
    {B, _} = lg_redact:scan(Body, R),
    [#{<<"content">> := [T1, T2]}] = maps:get(<<"messages">>, B),
    ?assertEqual(Thinking, T1),
    ?assertEqual(<<"[[LG_SECRET_1]]">>, maps:get(<<"text">>, T2)),
    ?assertEqual([#{<<"type">> => <<"reasoning">>, <<"encrypted_content">> => ?SK}], maps:get(<<"input">>, B)),
    ?assertEqual(maps:get(<<"image">>, Body), maps:get(<<"image">>, B)).

restore_json_test() ->
    Map = #{<<"[[LG_SECRET_1]]">> => <<"a\"b\nc">>},
    J = #{<<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"x [[LG_SECRET_1]]">>},
                            #{<<"type">> => <<"thinking">>, <<"thinking">> => <<"[[LG_SECRET_1]]">>}],
          <<"tool_calls">> => [#{<<"function">> => #{<<"arguments">> => <<"{\"k\":\"[[LG_SECRET_1]]\"}">>}}]},
    #{<<"content">> := [#{<<"text">> := T}, Th], <<"tool_calls">> := [#{<<"function">> := #{<<"arguments">> := A}}]} =
        lg_redact:restore_json(J, Map),
    ?assertEqual(<<"x a\"b\nc">>, T),
    ?assertEqual(<<"[[LG_SECRET_1]]">>, maps:get(<<"thinking">>, Th)),
    ?assertEqual(#{<<"k">> => <<"a\"b\nc">>}, json:decode(A)).

%% 把一段文字按任意位置切开，逐片经过流式还原，拼起来应等于整体还原
openai_stream_split_test() ->
    Map = #{<<"[[LG_SECRET_1]]">> => ?SK, <<"[[LG_SECRET_12]]">> => ?GH},
    Text = <<"a [[LG_SECRET_1]] b [[LG_SECRET_12]] c [[ not [[LG_SECRET_ x [">>,
    Want = <<"a ", ?SK/binary, " b ", ?GH/binary, " c [[ not [[LG_SECRET_ x [">>,
    [begin
         Parts = split_every(Text, N),
         Frames = [chunk(#{<<"content">> => P}, null) || P <- Parts] ++ [chunk(#{}, <<"stop">>), <<"data: [DONE]\n\n">>],
         ?assertEqual(Want, collect_openai(Frames, Map))
     end || N <- lists:seq(1, 20)].

openai_stream_tail_flushed_on_done_test() ->
    Map = #{<<"[[LG_SECRET_1]]">> => ?SK},
    Frames = [chunk(#{<<"content">> => <<"end [[LG_SEC">>}, null), <<"data: [DONE]\n\n">>],
    ?assertEqual(<<"end [[LG_SEC">>, collect_openai(Frames, Map)).

openai_tool_arguments_test() ->
    Map = #{<<"[[LG_SECRET_1]]">> => <<"line1\nline2">>},
    Parts = [<<"{\"k\":\"[[LG_">>, <<"SECRET_1]]\"}">>],
    Frames = [chunk(#{<<"tool_calls">> => [#{<<"index">> => 0, <<"function">> => #{<<"arguments">> => P}}]}, null)
              || P <- Parts] ++ [chunk(#{}, <<"tool_calls">>)],
    {Out, _} = lists:mapfoldl(fun(F, S) -> lg_redact:stream_frames(F, S) end, lg_redact:stream_new(openai, Map), Frames),
    Args = iolist_to_binary([A || J <- events(Out), #{<<"choices">> := [#{<<"delta">> := #{<<"tool_calls">> := TCs}}]} <- [J],
                                  #{<<"function">> := #{<<"arguments">> := A}} <- TCs]),
    ?assertEqual(#{<<"k">> => <<"line1\nline2">>}, json:decode(Args)).

anthropic_stream_test() ->
    Map = #{<<"[[LG_SECRET_1]]">> => ?SK},
    Ev = fun(J) -> lg_sse:encode(maps:get(<<"type">>, J), json:encode(J)) end,
    Frames = [Ev(#{<<"type">> => <<"content_block_start">>, <<"index">> => 0,
                   <<"content_block">> => #{<<"type">> => <<"thinking">>, <<"thinking">> => <<>>}}),
              Ev(#{<<"type">> => <<"content_block_delta">>, <<"index">> => 0,
                   <<"delta">> => #{<<"type">> => <<"thinking_delta">>, <<"thinking">> => <<"[[LG_SECRET_1]]">>}}),
              Ev(#{<<"type">> => <<"content_block_stop">>, <<"index">> => 0}),
              Ev(#{<<"type">> => <<"content_block_start">>, <<"index">> => 1,
                   <<"content_block">> => #{<<"type">> => <<"text">>, <<"text">> => <<>>}}),
              Ev(#{<<"type">> => <<"content_block_delta">>, <<"index">> => 1,
                   <<"delta">> => #{<<"type">> => <<"text_delta">>, <<"text">> => <<"key [[LG_SECRET">>}}),
              Ev(#{<<"type">> => <<"content_block_delta">>, <<"index">> => 1,
                   <<"delta">> => #{<<"type">> => <<"text_delta">>, <<"text">> => <<"_1]] tail [[">>}}),
              Ev(#{<<"type">> => <<"content_block_stop">>, <<"index">> => 1})],
    {Out, _} = lists:mapfoldl(fun(F, S) -> lg_redact:stream_frames(F, S) end, lg_redact:stream_new(anthropic, Map), Frames),
    Js = events(Out),
    Text = iolist_to_binary([T || #{<<"delta">> := #{<<"type">> := <<"text_delta">>, <<"text">> := T}} <- Js]),
    Think = iolist_to_binary([T || #{<<"delta">> := #{<<"type">> := <<"thinking_delta">>, <<"thinking">> := T}} <- Js]),
    ?assertEqual(<<"key ", ?SK/binary, " tail [[">>, Text),
    ?assertEqual(<<"[[LG_SECRET_1]]">>, Think),
    %% 补发的分片在 content_block_stop 之前
    ?assertMatch(#{<<"type">> := <<"content_block_stop">>, <<"index">> := 1}, lists:last(Js)).

responses_stream_test() ->
    Map = #{<<"[[LG_SECRET_1]]">> => ?SK},
    Ev = fun(J) -> lg_sse:encode(maps:get(<<"type">>, J), json:encode(J)) end,
    D = fun(T) -> Ev(#{<<"type">> => <<"response.output_text.delta">>, <<"item_id">> => <<"m1">>,
                       <<"output_index">> => 0, <<"content_index">> => 0, <<"delta">> => T}) end,
    Frames = [D(<<"a [[LG_">>), D(<<"SECRET_1]] [[LG">>),
              Ev(#{<<"type">> => <<"response.output_text.done">>, <<"item_id">> => <<"m1">>, <<"output_index">> => 0,
                   <<"content_index">> => 0, <<"text">> => <<"a [[LG_SECRET_1]] [[LG">>})],
    {Out, _} = lists:mapfoldl(fun(F, S) -> lg_redact:stream_frames(F, S) end, lg_redact:stream_new(responses, Map), Frames),
    Js = events(Out),
    Deltas = iolist_to_binary([T || #{<<"type">> := <<"response.output_text.delta">>, <<"delta">> := T} <- Js]),
    ?assertEqual(<<"a ", ?SK/binary, " [[LG">>, Deltas),
    ?assertMatch(#{<<"type">> := <<"response.output_text.done">>}, lists:last(Js)),
    ?assertEqual(<<"a ", ?SK/binary, " [[LG">>, maps:get(<<"text">>, lists:last(Js))).

no_placeholder_passthrough_test() ->
    Map = #{<<"[[LG_SECRET_1]]">> => ?SK},
    F = chunk(#{<<"content">> => <<"plain text">>}, null),
    {Out, _} = lg_redact:stream_frames(F, lg_redact:stream_new(openai, Map)),
    ?assertEqual(iolist_to_binary(F), iolist_to_binary(Out)).

validate_test() ->
    ?assertEqual(ok, lg_redact:validate(redact_rules, <<"[{\"name\":\"a\",\"pattern\":\"x+\"}]">>)),
    ?assertMatch({error, _}, lg_redact:validate(redact_rules, <<"[{\"name\":\"a\",\"pattern\":\"(\"}]">>)),
    ?assertMatch({error, _}, lg_redact:validate(redact_rules, <<"{}">>)),
    ?assertEqual(ok, lg_redact:validate(redact_pii, <<"phone, id_card">>)),
    ?assertMatch({error, _}, lg_redact:validate(redact_pii, <<"email">>)).

%%--------------------------------------------------------------------

chunk(Delta, Finish) ->
    lg_sse:encode(json:encode(#{<<"id">> => <<"c">>, <<"choices">> => [#{<<"index">> => 0, <<"delta">> => Delta,
                                                                        <<"finish_reason">> => Finish}]})).

split_every(B, N) when byte_size(B) =< N -> [B];
split_every(B, N) -> <<H:N/binary, T/binary>> = B, [H | split_every(T, N)].

collect_openai(Frames, Map) ->
    {Out, _} = lists:mapfoldl(fun(F, S) -> lg_redact:stream_frames(F, S) end, lg_redact:stream_new(openai, Map), Frames),
    iolist_to_binary([C || #{<<"choices">> := Cs} <- events(Out), #{<<"delta">> := #{<<"content">> := C}} <- Cs]).

events(Out) ->
    {Evs, _} = lg_sse:parse(iolist_to_binary(Out)),
    [J || #{data := D} <- Evs, D =/= <<"[DONE]">>, J <- [json:decode(D)]].
