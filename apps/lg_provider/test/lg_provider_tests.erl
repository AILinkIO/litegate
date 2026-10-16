%% @doc lg_provider 端到端测试：经模拟上游验证透传、转换、流式、错误与连接池。
-module(lg_provider_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("lg_core/include/lg_core.hrl").

provider_test_() ->
    {setup,
     fun() ->
             Dir = lg_core_test_util:start(),
             {ok, _} = application:ensure_all_started(lg_provider),
             Port = lg_mock_upstream:start(),
             {Dir, Port}
     end,
     fun({Dir, _}) ->
             lg_mock_upstream:stop(),
             application:stop(lg_provider),
             lg_core_test_util:stop(Dir)
     end,
     fun({_, Port}) ->
             [?_test(openai_passthrough(Port)),
              ?_test(user_agent(Port)),
              ?_test(openai_to_anthropic(Port)),
              ?_test(anthropic_to_openai_stream(Port)),
              ?_test(openai_stream_passthrough(Port)),
              ?_test(anthropic_headers_forwarded(Port)),
              ?_test(rate_limited(Port)),
              ?_test(stream_open_error(Port)),
              ?_test(pool_reuse_and_stale_retry(Port)),
              ?_test(stale_connection_retry()),
              ?_test(stream_abort(Port)),
              ?_test(connect_failure()),
              ?_test(embeddings(Port)),
              ?_test(responses_converted(Port)),
              ?_test(responses_passthrough(Port)),
             ?_test(count_tokens(Port)),
             ?_test(exit_signal_case(Port))]
     end}.

cred(Port, openai) ->
    #lg_credential{id = <<"c1">>, name = <<"oa">>, protocol = openai,
                   base_url = url(Port, "/openai/v1/"),
                   api_key_enc = lg_crypto:encrypt(<<"sk-oa">>),
                   headers = [{<<"x-extra">>, <<"1">>}]};
cred(Port, anthropic) ->
    #lg_credential{id = <<"c2">>, name = <<"an">>, protocol = anthropic,
                   base_url = url(Port, ""),
                   api_key_enc = lg_crypto:encrypt(<<"sk-an">>)}.

url(Port, Path) ->
    iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port), Path]).

target(Port, Proto) ->
    #{credential => cred(Port, Proto), upstream_model => <<"up-model">>}.

last_request() ->
    lists:last(lg_mock_upstream:requests()).

oa_completion() ->
    #{<<"id">> => <<"cc-1">>, <<"object">> => <<"chat.completion">>, <<"model">> => <<"up-model">>,
      <<"choices">> => [#{<<"index">> => 0, <<"finish_reason">> => <<"stop">>,
                          <<"message">> => #{<<"role">> => <<"assistant">>, <<"content">> => <<"pong">>}}],
      <<"usage">> => #{<<"prompt_tokens">> => 3, <<"completion_tokens">> => 1}}.

chat_req() ->
    #{<<"model">> => <<"public-name">>,
      <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"ping">>}]}.

collect(S) ->
    collect(S, []).
collect(S, Acc) ->
    case lg_provider:stream_next(S) of
        {frames, F, S1} -> collect(S1, [Acc, F]);
        {done, F, Result} -> {iolist_to_binary([Acc, F]), Result}
    end.

%%--------------------------------------------------------------------

openai_passthrough(Port) ->
    Raw = json:encode(oa_completion()),
    lg_mock_upstream:expect({json, 200, #{}, Raw}),
    {ok, Out, Result} = lg_provider:chat(openai, chat_req(), target(Port, openai)),
    ?assertEqual(iolist_to_binary(Raw), iolist_to_binary(Out)),
    ?assertMatch(#{text := <<"pong">>, usage := #{input := 3, output := 1}}, Result),
    #{path := Path, headers := H, body := B} = last_request(),
    ?assertEqual(<<"/openai/v1/chat/completions">>, Path),
    ?assertEqual(<<"Bearer sk-oa">>, maps:get(<<"authorization">>, H)),
    ?assertEqual(<<"1">>, maps:get(<<"x-extra">>, H)),
    ?assertMatch(#{<<"model">> := <<"up-model">>, <<"stream">> := false}, B).

%% 默认 User-Agent；凭证自定义头（任意大小写）优先；运行参数留空则不发送
user_agent(Port) ->
    UA = fun(Target) ->
                 lg_mock_upstream:expect({json, 200, #{}, json:encode(oa_completion())}),
                 {ok, _, _} = lg_provider:chat(openai, chat_req(), Target),
                 #{headers := H} = last_request(),
                 maps:get(<<"user-agent">>, H, none)
         end,
    T = target(Port, openai),
    ?assertEqual(<<"BeamAI LiteGate">>, UA(T)),
    #{credential := C} = T,
    ?assertEqual(<<"my-agent/1.0">>,
                 UA(T#{credential => C#lg_credential{headers = [{<<"User-Agent">>, <<"my-agent/1.0">>}]}})),
    ok = lg_config:set(user_agent, <<>>),
    try ?assertEqual(none, UA(T))
    after lg_config:unset(user_agent)
    end.

openai_to_anthropic(Port) ->
    lg_mock_upstream:expect(
      {json, 200, #{}, #{<<"id">> => <<"msg_1">>, <<"type">> => <<"message">>, <<"model">> => <<"up-model">>,
                         <<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"pong">>}],
                         <<"stop_reason">> => <<"end_turn">>,
                         <<"usage">> => #{<<"input_tokens">> => 4, <<"output_tokens">> => 2}}}),
    {ok, Out, Result} = lg_provider:chat(openai, chat_req(),
                                         (target(Port, anthropic))#{default_max_tokens => 1234}),
    ?assertMatch(#{<<"object">> := <<"chat.completion">>,
                   <<"choices">> := [#{<<"message">> := #{<<"content">> := <<"pong">>},
                                       <<"finish_reason">> := <<"stop">>}]},
                 json:decode(iolist_to_binary(Out))),
    ?assertMatch(#{usage := #{input := 4, output := 2}}, Result),
    #{path := Path, headers := H, body := B} = last_request(),
    ?assertEqual(<<"/v1/messages">>, Path),
    ?assertEqual(<<"sk-an">>, maps:get(<<"x-api-key">>, H)),
    ?assertEqual(<<"2023-06-01">>, maps:get(<<"anthropic-version">>, H)),
    ?assertNot(maps:is_key(<<"authorization">>, H)),
    ?assertMatch(#{<<"model">> := <<"up-model">>, <<"max_tokens">> := 1234}, B).

anthropic_to_openai_stream(Port) ->
    Chunks = [#{<<"id">> => <<"c">>, <<"model">> => <<"up-model">>,
                <<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{<<"content">> => <<"po">>}}]},
              #{<<"id">> => <<"c">>, <<"model">> => <<"up-model">>,
                <<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{<<"content">> => <<"ng">>},
                                    <<"finish_reason">> => <<"stop">>}]},
              #{<<"id">> => <<"c">>, <<"choices">> => [],
                <<"usage">> => #{<<"prompt_tokens">> => 5, <<"completion_tokens">> => 2}}],
    %% 故意把一帧拆到两个 TCP 块里
    Frames = [iolist_to_binary(lg_sse:encode(json:encode(C))) || C <- Chunks] ++ [lg_sse:done()],
    [F1 | Rest] = Frames,
    {A, B} = split_binary(F1, 10),
    lg_mock_upstream:expect({sse_slow, [A, B | Rest], 5}),
    Req = #{<<"model">> => <<"public">>, <<"max_tokens">> => 10, <<"stream">> => true,
            <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"ping">>}]},
    {ok, S} = lg_provider:stream_open(anthropic, Req, target(Port, openai)),
    {Out, Result} = collect(S),
    {Evs, <<>>} = lg_sse:parse(Out),
    ?assertEqual([<<"message_start">>, <<"content_block_start">>, <<"content_block_delta">>,
                  <<"content_block_delta">>, <<"content_block_stop">>, <<"message_delta">>,
                  <<"message_stop">>], [T || #{event := T} <- Evs]),
    ?assertMatch(#{text := <<"pong">>, finish_reason := <<"stop">>, usage := #{input := 5, output := 2}},
                 Result),
    #{body := UpBody} = last_request(),
    ?assertMatch(#{<<"stream">> := true, <<"stream_options">> := #{<<"include_usage">> := true},
                   <<"max_tokens">> := 10}, UpBody).

openai_stream_passthrough(Port) ->
    Frames = [iolist_to_binary(lg_sse:encode(json:encode(C))) || C <-
                 [#{<<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{<<"content">> => <<"x">>}}]},
                  #{<<"choices">> => [], <<"usage">> => #{<<"prompt_tokens">> => 1,
                                                          <<"completion_tokens">> => 1}}]]
             ++ [lg_sse:done()],
    lg_mock_upstream:expect({sse, Frames}),
    {ok, S} = lg_provider:stream_open(openai, (chat_req())#{<<"stream">> => true}, target(Port, openai)),
    {Out, Result} = collect(S),
    %% 客户端没要 usage：网关注入的 usage 块被剥掉，其余字节不变
    ?assertEqual(iolist_to_binary([hd(Frames), lg_sse:done()]), Out),
    ?assertMatch(#{usage := #{input := 1, output := 1}}, Result),
    #{body := UpBody} = last_request(),
    ?assertMatch(#{<<"stream_options">> := #{<<"include_usage">> := true}}, UpBody).

anthropic_headers_forwarded(Port) ->
    lg_mock_upstream:expect({json, 200, #{}, #{<<"content">> => [], <<"usage">> => #{}}}),
    T = (target(Port, anthropic))#{client_headers => [{<<"anthropic-beta">>, <<"b1">>},
                                                      {<<"anthropic-version">>, <<"2099-01-01">>},
                                                      {<<"x-other">>, <<"no">>}]},
    Req = #{<<"max_tokens">> => 5, <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"x">>}]},
    {ok, _, _} = lg_provider:chat(anthropic, Req, T),
    #{headers := H} = last_request(),
    ?assertEqual(<<"b1">>, maps:get(<<"anthropic-beta">>, H)),
    ?assertEqual(<<"2099-01-01">>, maps:get(<<"anthropic-version">>, H)),
    ?assertNot(maps:is_key(<<"x-other">>, H)).

rate_limited(Port) ->
    Body = json:encode(#{<<"error">> => #{<<"message">> => <<"slow down">>, <<"type">> => <<"rate_limit">>}}),
    lg_mock_upstream:expect({json, 429, #{<<"retry-after">> => <<"3">>}, Body}),
    {error, E} = lg_provider:chat(openai, chat_req(), target(Port, openai)),
    ?assertMatch(#{kind := rate_limit, status := 429, retryable := true, retry_after_ms := 3000,
                   message := <<"slow down">>}, E),
    %% 同协议：原样转发上游错误体；跨协议：按客户端格式重建
    ?assertEqual({429, iolist_to_binary(Body)},
                 (fun({S, B}) -> {S, iolist_to_binary(B)} end)(lg_llm_error:to_client(openai, true, E))),
    {429, AB} = lg_llm_error:to_client(anthropic, false, E),
    ?assertMatch(#{<<"type">> := <<"error">>,
                   <<"error">> := #{<<"type">> := <<"rate_limit_error">>, <<"message">> := <<"slow down">>}},
                 json:decode(iolist_to_binary(AB))).

stream_open_error(Port) ->
    lg_mock_upstream:expect({json, 500, #{}, <<"boom">>}),
    {error, E} = lg_provider:stream_open(openai, (chat_req())#{<<"stream">> => true},
                                         target(Port, openai)),
    ?assertMatch(#{kind := server, retryable := true, message := <<"boom">>,
                   upstream := #{status := 500, body := <<"boom">>}}, E).

pool_reuse_and_stale_retry(Port) ->
    lg_http_pool:stats(),  %% 确保之前的 checkin 已处理
    Key = {tcp, "127.0.0.1", Port},
    %% 连续请求复用同一条空闲连接
    [begin
         lg_mock_upstream:expect({json, 200, #{}, oa_completion()}),
         {ok, _, _} = lg_provider:chat(openai, chat_req(), target(Port, openai))
     end || _ <- [1, 2, 3]],
    ?assertEqual(1, maps:get(Key, lg_http_pool:stats())),
    %% 上游要求关闭连接：之后的请求无论拿到死连接还是新连接都应成功
    lg_mock_upstream:expect({json, 200, #{<<"connection">> => <<"close">>}, oa_completion()}),
    {ok, _, _} = lg_provider:chat(openai, chat_req(), target(Port, openai)),
    lg_mock_upstream:expect({json, 200, #{}, oa_completion()}),
    ?assertMatch({ok, _, _}, lg_provider:chat(openai, chat_req(), target(Port, openai))).

%% 原始 TCP 服务端：每条连接上的第 2 个请求到达时直接断开，
%% 模拟空闲连接恰好在复用时被对端关闭
stale_connection_retry() ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(L),
    Acceptor = spawn(fun() -> accept_loop(L) end),
    ok = gen_tcp:controlling_process(L, Acceptor),
    T = target(Port, openai),
    ?assertMatch({ok, _, _}, lg_provider:chat(openai, chat_req(), T)),
    lg_http_pool:stats(),
    ?assertEqual(1, maps:get({tcp, "127.0.0.1", Port}, lg_http_pool:stats())),
    %% 复用的连接被断开 → 自动换新连接重试成功
    ?assertMatch({ok, _, _}, lg_provider:chat(openai, chat_req(), T)),
    exit(Acceptor, kill),
    gen_tcp:close(L).

accept_loop(L) ->
    case gen_tcp:accept(L) of
        {ok, S} ->
            Pid = spawn(fun() -> receive go -> raw_conn(S, 1) end end),
            ok = gen_tcp:controlling_process(S, Pid),
            Pid ! go,
            accept_loop(L);
        {error, _} ->
            ok
    end.

raw_conn(S, N) ->
    case read_request(S, <<>>) of
        ok when N >= 2 ->
            gen_tcp:close(S);
        ok ->
            Body = json:encode(oa_completion()),
            gen_tcp:send(S, ["HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n",
                             "content-length: ", integer_to_list(iolist_size(Body)), "\r\n\r\n", Body]),
            raw_conn(S, N + 1);
        closed ->
            ok
    end.

read_request(S, Buf) ->
    case binary:split(Buf, <<"\r\n\r\n">>) of
        [Head, Rest] ->
            {match, [Len]} = re:run(Head, "content-length: *([0-9]+)",
                                    [caseless, {capture, all_but_first, binary}]),
            read_body(S, binary_to_integer(Len) - byte_size(Rest));
        [_] ->
            case gen_tcp:recv(S, 0) of
                {ok, Data} -> read_request(S, <<Buf/binary, Data/binary>>);
                {error, _} -> closed
            end
    end.

read_body(_S, N) when N =< 0 -> ok;
read_body(S, N) ->
    case gen_tcp:recv(S, 0) of
        {ok, Data} -> read_body(S, N - byte_size(Data));
        {error, _} -> closed
    end.

stream_abort(Port) ->
    Frame = iolist_to_binary(lg_sse:encode(json:encode(
              #{<<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{<<"content">> => <<"a">>}}]}))),
    lg_mock_upstream:expect({sse_slow, [Frame, Frame, Frame], 200}),
    {ok, S} = lg_provider:stream_open(openai, (chat_req())#{<<"stream">> => true}, target(Port, openai)),
    {frames, [_], S1} = lg_provider:stream_next(S),
    ?assertMatch(#{text := <<"a">>}, lg_provider:stream_abort(S1)).

responses_converted(Port) ->
    Req = #{<<"model">> => <<"pub">>, <<"instructions">> => <<"sys">>, <<"input">> => <<"ping">>},
    %% OpenAI 上游，非流式
    lg_mock_upstream:expect({json, 200, #{}, oa_completion()}),
    {ok, Out, #{response := Resp, usage := #{input := 3}}} = lg_provider:chat(responses, Req, target(Port, openai)),
    ?assertMatch(#{<<"object">> := <<"response">>,
                   <<"output">> := [#{<<"content">> := [#{<<"text">> := <<"pong">>}]}]},
                 json:decode(iolist_to_binary(Out))),
    ?assertMatch(#{<<"id">> := <<"resp_", _/binary>>}, Resp),
    #{path := P1, body := B1} = last_request(),
    ?assertEqual(<<"/openai/v1/chat/completions">>, P1),
    ?assertMatch(#{<<"messages">> := [#{<<"role">> := <<"system">>}, #{<<"content">> := <<"ping">>}]}, B1),
    %% Anthropic 上游，流式：Anthropic 事件 → Chat chunk → Responses 事件
    Ev = fun(T, M) -> iolist_to_binary(lg_sse:encode(T, json:encode(M#{<<"type">> => T}))) end,
    lg_mock_upstream:expect(
      {sse, [Ev(<<"message_start">>, #{<<"message">> => #{<<"id">> => <<"m1">>, <<"model">> => <<"claude">>,
                                                          <<"usage">> => #{<<"input_tokens">> => 7}}}),
             Ev(<<"content_block_start">>, #{<<"index">> => 0, <<"content_block">> => #{<<"type">> => <<"text">>, <<"text">> => <<>>}}),
             Ev(<<"content_block_delta">>, #{<<"index">> => 0, <<"delta">> => #{<<"type">> => <<"text_delta">>, <<"text">> => <<"po">>}}),
             Ev(<<"content_block_delta">>, #{<<"index">> => 0, <<"delta">> => #{<<"type">> => <<"text_delta">>, <<"text">> => <<"ng">>}}),
             Ev(<<"message_delta">>, #{<<"delta">> => #{<<"stop_reason">> => <<"end_turn">>}, <<"usage">> => #{<<"output_tokens">> => 2}}),
             Ev(<<"message_stop">>, #{})]}),
    {ok, S} = lg_provider:stream_open(responses, Req#{<<"stream">> => true}, target(Port, anthropic)),
    {Sse, Result} = collect(S),
    {Evs, <<>>} = lg_sse:parse(Sse),
    Types = [T || #{event := T} <- Evs],
    ?assertEqual(<<"response.created">>, hd(Types)),
    ?assertEqual(<<"response.completed">>, lists:last(Types)),
    ?assert(lists:member(<<"response.output_text.delta">>, Types)),
    #{<<"response">> := Final} = json:decode(maps:get(data, lists:last(Evs))),
    ?assertMatch(#{<<"status">> := <<"completed">>, <<"usage">> := #{<<"input_tokens">> := 7, <<"output_tokens">> := 2},
                   <<"output">> := [#{<<"content">> := [#{<<"text">> := <<"pong">>}]}]}, Final),
    ?assertMatch(#{text := <<"pong">>, usage := #{input := 7, output := 2}, response := #{<<"status">> := <<"completed">>}},
                 Result),
    #{path := P2} = last_request(),
    ?assertEqual(<<"/v1/messages">>, P2).

responses_passthrough(Port) ->
    T = target(Port, openai),
    Cred = maps:get(credential, T),
    PT = T#{credential => Cred#lg_credential{options = #{responses_api => true}}},
    Resp = #{<<"id">> => <<"resp_up">>, <<"object">> => <<"response">>, <<"status">> => <<"completed">>,
             <<"model">> => <<"up-model">>,
             <<"output">> => [#{<<"type">> => <<"message">>,
                                <<"content">> => [#{<<"type">> => <<"output_text">>, <<"text">> => <<"native">>}]}],
             <<"usage">> => #{<<"input_tokens">> => 4, <<"output_tokens">> => 1}},
    Raw = json:encode(Resp),
    lg_mock_upstream:expect({json, 200, #{}, Raw}),
    {ok, Out, Result} = lg_provider:chat(responses, #{<<"model">> => <<"pub">>, <<"input">> => <<"x">>,
                                                     <<"previous_response_id">> => <<"resp_prev">>}, PT),
    ?assertEqual(iolist_to_binary(Raw), iolist_to_binary(Out)),
    ?assertMatch(#{text := <<"native">>, usage := #{input := 4, output := 1}, response := #{<<"id">> := <<"resp_up">>}},
                 Result),
    #{path := Path, body := Body} = last_request(),
    ?assertEqual(<<"/openai/v1/responses">>, Path),
    ?assertMatch(#{<<"model">> := <<"up-model">>, <<"previous_response_id">> := <<"resp_prev">>}, Body),
    %% 流式透传：字节不变，用量取自 response.completed
    Frames = [iolist_to_binary(lg_sse:encode(Ty, json:encode(M#{<<"type">> => Ty}))) || {Ty, M} <-
                 [{<<"response.created">>, #{<<"response">> => Resp#{<<"status">> => <<"in_progress">>}}},
                  {<<"response.output_text.delta">>, #{<<"delta">> => <<"native">>}},
                  {<<"response.completed">>, #{<<"response">> => Resp}}]],
    lg_mock_upstream:expect({sse, Frames}),
    {ok, S} = lg_provider:stream_open(responses, #{<<"model">> => <<"pub">>, <<"input">> => <<"x">>}, PT),
    {Sse, SR} = collect(S),
    ?assertEqual(iolist_to_binary(Frames), Sse),
    ?assertMatch(#{text := <<"native">>, usage := #{input := 4}, response := #{<<"id">> := <<"resp_up">>}}, SR).

embeddings(Port) ->
    Resp = #{<<"object">> => <<"list">>, <<"model">> => <<"up-model">>,
             <<"data">> => [#{<<"object">> => <<"embedding">>, <<"index">> => 0,
                              <<"embedding">> => [0.1, 0.2]}],
             <<"usage">> => #{<<"prompt_tokens">> => 7, <<"total_tokens">> => 7}},
    Raw = json:encode(Resp),
    lg_mock_upstream:expect({json, 200, #{}, Raw}),
    {ok, Out, Result} = lg_provider:embeddings(#{<<"model">> => <<"pub">>, <<"input">> => <<"hello">>},
                                               target(Port, openai)),
    ?assertEqual(iolist_to_binary(Raw), iolist_to_binary(Out)),
    ?assertMatch(#{usage := #{input := 7, output := 0}}, Result),
    #{path := Path, headers := H, body := B} = last_request(),
    ?assertEqual(<<"/openai/v1/embeddings">>, Path),
    ?assertEqual(<<"Bearer sk-oa">>, maps:get(<<"authorization">>, H)),
    ?assertEqual(#{<<"model">> => <<"up-model">>, <<"input">> => <<"hello">>}, B),
    ?assertMatch({error, #{kind := client, status := 400}},
                 lg_provider:embeddings(#{<<"input">> => <<"x">>}, target(Port, anthropic))).

count_tokens(Port) ->
    lg_mock_upstream:expect({json, 200, #{}, #{<<"input_tokens">> => 12}}),
    {ok, Out, Result} = lg_provider:count_tokens(
                          #{<<"model">> => <<"pub">>,
                            <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"x">>}]},
                          target(Port, anthropic)),
    ?assertEqual(#{<<"input_tokens">> => 12}, json:decode(iolist_to_binary(Out))),
    ?assertMatch(#{usage := #{input := 0}}, Result),
    #{path := Path, headers := H} = last_request(),
    ?assertEqual(<<"/v1/messages/count_tokens">>, Path),
    ?assertEqual(<<"sk-an">>, maps:get(<<"x-api-key">>, H)),
    ?assertMatch({error, #{kind := client}},
                 lg_provider:count_tokens(#{}, target(Port, openai))).

connect_failure() ->
    {ok, L} = gen_tcp:listen(0, []),
    {ok, Port} = inet:port(L),
    gen_tcp:close(L),
    {error, E} = lg_provider:chat(openai, chat_req(), target(Port, openai)),
    ?assertMatch(#{kind := network, status := 502, retryable := true}, E).

%% 调用进程 trap_exit 时，退出信号能打断等待上游数据。放进同一 setup：
%% 两个顶层套件的 setup 会并发初始化全局 Mnesia/Ranch，测试节点里无法隔离。
exit_signal_case(Port) ->
    Frame = iolist_to_binary(lg_sse:encode(json:encode(
              #{<<"choices">> => [#{<<"index">> => 0,
                                   <<"delta">> => #{<<"content">> => <<"a">>}}]}))),
    lg_mock_upstream:expect({sse_slow, [Frame, Frame], 3000}),
    Parent = self(),
    Pid = spawn(fun() ->
                        process_flag(trap_exit, true),
                        {ok, S} = lg_provider:stream_open(
                                    openai, (chat_req())#{<<"stream">> => true},
                                    target(Port, openai)),
                        {frames, _, S1} = lg_provider:stream_next(S),
                        Parent ! opened,
                        Parent ! {res, lg_provider:stream_next(S1)}
                end),
    receive opened -> ok end,
    T0 = erlang:monotonic_time(millisecond),
    exit(Pid, shutdown),
    Res = receive {res, R} -> R after 2000 -> timeout end,
    ?assertMatch({exit, shutdown, #{text := <<"a">>}}, Res),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 1000).
