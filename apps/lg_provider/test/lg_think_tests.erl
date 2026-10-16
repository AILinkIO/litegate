-module(lg_think_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("lg_core/include/lg_core.hrl").

split_text_test() ->
    ?assertEqual({<<"\nplan\n">>, <<"answer">>}, lg_think:split_text(<<"<think>\nplan\n</think>\n\nanswer">>)),
    ?assertEqual({<<>>, <<"plain">>}, lg_think:split_text(<<"plain">>)),
    %% 截断在思考块内
    ?assertEqual({<<"half">>, <<>>}, lg_think:split_text(<<"<think>half">>)),
    %% 看似标签开头但不是
    ?assertEqual({<<>>, <<"a <thin">>}, lg_think:split_text(<<"a <thin">>)),
    ?assertEqual({<<"x">>, <<"pre y">>}, lg_think:split_text(<<"pre <think>x</think> y">>)).

split_response_test() ->
    J = #{<<"choices">> => [#{<<"index">> => 0,
                              <<"message">> => #{<<"role">> => <<"assistant">>,
                                                 <<"content">> => <<"<think>r</think>\n\nhi">>}}]},
    ?assertMatch(#{<<"choices">> := [#{<<"message">> := #{<<"content">> := <<"hi">>, <<"reasoning_content">> := <<"r">>}}]},
                 lg_think:split_response(J)),
    Plain = #{<<"choices">> => [#{<<"message">> => #{<<"content">> => <<"hi">>}}]},
    ?assertEqual(Plain, lg_think:split_response(Plain)).

chunk(Text) -> #{<<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{<<"content">> => Text}}]}.

%% 标签跨分片
stream_test() ->
    Pieces = [<<"<th">>, <<"ink>ste">>, <<"p one</th">>, <<"ink>\n">>, <<"\nAns">>, <<"wer <b>">>],
    {Out, S} = lists:foldl(fun(P, {Acc, St}) ->
                                   {J, St1} = lg_think:feed_chunk(chunk(P), St),
                                   {[J | Acc], St1}
                           end, {[], lg_think:new()}, Pieces),
    Last = #{<<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{}, <<"finish_reason">> => <<"stop">>}]},
    {JL, _} = lg_think:feed_chunk(Last, S),
    Deltas = [D || #{<<"choices">> := [#{<<"delta">> := D}]} <- lists:reverse([JL | Out])],
    R = iolist_to_binary([V || #{<<"reasoning_content">> := V} <- Deltas]),
    C = iolist_to_binary([V || #{<<"content">> := V} <- Deltas]),
    ?assertEqual(<<"step one">>, R),
    ?assertEqual(<<"Answer <b>">>, C),
    %% 非内容 chunk（如用量）原样通过
    U = #{<<"choices">> => [], <<"usage">> => #{}},
    ?assertEqual({U, S}, lg_think:feed_chunk(U, S)).

pack_test() ->
    Req = #{<<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"q">>},
                               #{<<"role">> => <<"assistant">>, <<"content">> => null, <<"reasoning_content">> => <<"r">>,
                                 <<"tool_calls">> => []},
                               #{<<"role">> => <<"assistant">>, <<"content">> => <<"a">>}]},
    #{<<"messages">> := [_, A1, A2]} = lg_think:pack_messages(Req),
    ?assertEqual(<<"<think>r</think>\n\n">>, maps:get(<<"content">>, A1)),
    ?assertNot(maps:is_key(<<"reasoning_content">>, A1)),
    ?assertEqual(<<"a">>, maps:get(<<"content">>, A2)).

cred(Opts) ->
    #lg_credential{id = <<"c">>, name = <<"c">>, protocol = openai, base_url = <<"https://x.test/v1">>,
                   options = Opts}.

%% extra_body 合并（不覆盖受保护字段）、think_tags 请求侧还原
upstream_request_test() ->
    Cred = cred(#{extra_body => #{<<"reasoning_split">> => true, <<"model">> => <<"evil">>,
                                  <<"messages">> => []},
                  think_tags => <<"split">>}),
    Req = #{<<"model">> => <<"r">>,
            <<"messages">> => [#{<<"role">> => <<"assistant">>, <<"content">> => <<"a">>,
                                 <<"reasoning_content">> => <<"why">>}]},
    {ok, #{body := B}} = lg_provider:upstream_request(openai, Req, #{credential => Cred, upstream_model => <<"up">>}),
    J = json:decode(iolist_to_binary(B)),
    ?assertMatch(#{<<"model">> := <<"up">>, <<"reasoning_split">> := true,
                   <<"messages">> := [#{<<"content">> := <<"<think>why</think>\n\na">>}]}, J),
    %% Anthropic 客户端的 thinking 块 → reasoning_content（未开 split 时保留该字段）
    AReq = #{<<"model">> => <<"r">>, <<"max_tokens">> => 10,
             <<"messages">> => [#{<<"role">> => <<"assistant">>,
                                  <<"content">> => [#{<<"type">> => <<"thinking">>, <<"thinking">> => <<"t">>,
                                                      <<"signature">> => <<"s">>},
                                                    #{<<"type">> => <<"text">>, <<"text">> => <<"x">>}]}]},
    {ok, #{body := B2}} = lg_provider:upstream_request(anthropic, AReq,
                                                       #{credential => cred(#{}), upstream_model => <<"up">>}),
    ?assertMatch(#{<<"messages">> := [#{<<"role">> := <<"assistant">>, <<"content">> := <<"x">>,
                                        <<"reasoning_content">> := <<"t">>}]},
                 json:decode(iolist_to_binary(B2))),
    {ok, #{body := B3}} = lg_provider:upstream_request(anthropic, AReq,
                                                       #{credential => cred(#{think_tags => <<"split">>}),
                                                         upstream_model => <<"up">>}),
    ?assertMatch(#{<<"messages">> := [#{<<"content">> := <<"<think>t</think>\n\nx">>}]},
                 json:decode(iolist_to_binary(B3))).
