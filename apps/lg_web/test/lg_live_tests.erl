%% @doc 真实上游联调：同一套用例依次跑各家同时提供 OpenAI / Anthropic / Responses 接口的上游。
%%
%% 只在 LITEGATE_LIVE_TESTS=1 时运行，且只跑设置了 Key 的上游（否则为空测试集，避免每次单元测试联网计费）：
%%   LITEGATE_LIVE_TESTS=1 rebar3 eunit --module lg_live_tests
%% - MiniMax：MINIMAX_API_KEY，入口 https://api.minimax.cn（LITEGATE_LIVE_MINIMAX_BASE 可改），模型 MiniMax-M2.7
%% - 智谱 GLM Coding Plan：ZHIPU_API_KEY（或 GLM_API_KEY），模型 glm-5.3-flash（图片 cogview-4、语音 glm-tts）
%% - 智谱按量 API：同一个 Key，模型 glm-5.3
%% - DeepSeek：DEEPSEEK_API_KEY，模型 deepseek-v4-flash（另测余额查询）
%% - 阿里云百炼 Token Plan（北京）：DASHSCOPE_API_KEY，模型 qwen3.8-flash
%% - Kimi Code 会员订阅：KIMI_API_KEY，模型 kimi-for-coding（只有 coding 入口：api.kimi.com/coding）
%% 用例按上游能力启用：Responses 透传、套餐额度、图片、语音、余额只在配置了对应能力的上游上运行
%%
%% 可选：
%%   LITEGATE_LIVE_SUITE=m6   只跑路由稳健性、规则路由、链路导出用例
%%   LITEGATE_LIVE_SUITE=m8   只跑结构化输出、脱敏、上游参数兼容用例
%%   LITEGATE_LIVE_SKIP="glm:图片,glm:语音"   跳过某上游名称中含该片段的用例（逗号分隔），如只测 glm-5.3-flash 时
%%   LITEGATE_LIVE_PROVIDERS="deepseek,dashscope"   只跑这些上游
%%   LITEGATE_LIVE_CASES="Responses,count_tokens"   只跑名称含这些片段的用例
-module(lg_live_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("lg_core/include/lg_core.hrl").

-define(T, 120).

live_test_() ->
    case os:getenv("LITEGATE_LIVE_TESTS") of
        "1" ->
            Cases = case os:getenv("LITEGATE_LIVE_SUITE") of
                        "m6" -> m6_cases();
                        "m8" -> m8_cases();
                        _ -> cases() ++ m6_cases() ++ m8_cases()
                    end,
            [{P, {setup, fun() -> setup(Cfg) end, fun cleanup/1,
                  fun(Ctx) ->
                          [{timeout, ?T, {P ++ ": " ++ Name, ?_test(F(Ctx))}} || {Name, F} <- Cases,
                                                                                 supported(Cfg, F), selected(Name),
                                                                                 not skipped(P, Name)]
                  end}}
             || {P, Cfg} <- providers()];
        _ ->
            []
    end.

%% 用例需要的上游能力：没有配置的上游跳过该用例
supported(Cfg, F) ->
    Needs = case erlang:fun_info(F, name) of
                {name, responses_passthrough} -> [responses];
                {name, responses_passthrough_tools} -> [responses];
                {name, plan_quota} -> [plan];
                {name, images} -> [image];
                {name, speech} -> [tts];
                {name, balance} -> [balance];
                _ -> []
            end,
    lists:all(fun(K) -> maps:is_key(K, Cfg) end, Needs).

%% LITEGATE_LIVE_CASES：只跑名称含任一片段的用例（逗号分隔）
selected(Name) ->
    case string:lexemes(os:getenv("LITEGATE_LIVE_CASES", ""), ",") of
        [] -> true;
        Frags -> lists:any(fun(F) -> string:find(Name, F) =/= nomatch end, Frags)
    end.

skipped(Provider, Name) ->
    Rules = [string:split(R, ":") || R <- string:lexemes(os:getenv("LITEGATE_LIVE_SKIP", ""), ",")],
    lists:any(fun([P, Frag]) -> P =:= Provider andalso string:find(Name, Frag) =/= nomatch;
                 (_) -> false
              end, Rules).

%% 各上游的三类入口：openai（chat/completions）、anthropic（messages）、responses（原生 /responses）
providers() ->
    MM = list_to_binary(os:getenv("LITEGATE_LIVE_MINIMAX_BASE", "https://api.minimax.cn")),
    All = [{"minimax", "MINIMAX_API_KEY",
            #{model => <<"MiniMax-M2.7">>, signature => true, plan => <<"minimax">>,
              oa_options => #{<<"think_tags">> => <<"split">>},
              image => #{base => <<MM/binary, "/v1">>, model => <<"image-01">>, media_api => <<"minimax">>},
              tts => #{model => <<"speech-2.8-hd">>, voice => <<"male-qn-qingse">>, format => <<"mp3">>},
              openai => <<MM/binary, "/v1">>, anthropic => <<MM/binary, "/anthropic">>,
              responses => <<MM/binary, "/v1">>}},
           %% DeepSeek 按量付费 API
           {"deepseek", "DEEPSEEK_API_KEY",
            #{model => <<"deepseek-v4-flash">>, signature => false, balance => <<"deepseek">>,
              openai => <<"https://api.deepseek.com/v1">>, anthropic => <<"https://api.deepseek.com/anthropic">>,
              responses => <<"https://api.deepseek.com/v1">>}},
           %% 阿里云百炼 Token Plan（北京）：没有额度查询接口
           {"dashscope", "DASHSCOPE_API_KEY",
            #{model => <<"qwen3.8-flash">>, signature => false,
              openai => <<"https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1">>,
              anthropic => <<"https://token-plan.cn-beijing.maas.aliyuncs.com/apps/anthropic">>,
              responses => <<"https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1">>}},
           %% 智谱按量 API（与 Coding Plan 同一个 Key）
           {"zhipu-api", ["ZHIPU_API_KEY", "GLM_API_KEY"],
            #{model => <<"glm-5.3">>, signature => false,
              openai => <<"https://open.bigmodel.cn/api/paas/v4">>,
              anthropic => <<"https://open.bigmodel.cn/api/anthropic">>,
              responses => <<"https://open.bigmodel.cn/api/v1">>}},
           %% Kimi Code 会员订阅：只能用 coding 入口（Chat、Messages、原生 Responses 都有）
           {"kimi-code", "KIMI_API_KEY",
            #{model => <<"kimi-for-coding">>, signature => true, plan => <<"kimi">>, any_model => true,
              openai => <<"https://api.kimi.com/coding/v1">>, anthropic => <<"https://api.kimi.com/coding">>,
              responses => <<"https://api.kimi.com/coding/v1">>}},
           {"glm", ["ZHIPU_API_KEY", "GLM_API_KEY"],
            #{model => <<"glm-5.3-flash">>, signature => false, plan => <<"glm">>,
              image => #{base => <<"https://open.bigmodel.cn/api/paas/v4">>, model => <<"cogview-4">>, media_api => <<"openai">>},
              tts => #{model => <<"glm-tts">>, voice => <<"tongtong">>, format => <<"wav">>},
              openai => <<"https://open.bigmodel.cn/api/coding/paas/v4">>,
              anthropic => <<"https://open.bigmodel.cn/api/anthropic">>,
              responses => <<"https://open.bigmodel.cn/api/v1">>}}],
    Only = string:lexemes(os:getenv("LITEGATE_LIVE_PROVIDERS", ""), ","),
    [{P, Cfg#{key => list_to_binary(K)}} || {P, Env, Cfg} <- All, K <- [env_key(Env)], K =/= "",
                                           Only =:= [] orelse lists:member(P, Only)].

env_key([C | _] = Env) when is_list(C) ->
    hd([V || E <- Env, V <- [os:getenv(E, "")], V =/= ""] ++ [""]);
env_key(Env) ->
    os:getenv(Env, "").

cases() ->
    [{"openai → openai 同步/流式", fun openai_same/1},
     {"anthropic → anthropic 同步/流式（thinking 签名）", fun anthropic_same/1},
     {"openai → anthropic 跨协议", fun openai_to_anthropic/1},
     {"anthropic → openai 跨协议", fun anthropic_to_openai/1},
     {"工具调用多轮（openai 客户端 → anthropic 上游）", fun tools_cross/1},
     {"工具调用多轮 + thinking 回传（anthropic 同协议）", fun tools_thinking_anthropic/1},
     {"工具调用多轮 + 思考链回传（anthropic 客户端 → openai 上游）", fun tools_thinking_cross/1},
     {"Responses API 转换（两种上游）与 previous_response_id", fun responses/1},
     {"Responses API 透传（上游原生 /v1/responses）", fun responses_passthrough/1},
     {"Responses 透传：工具调用多轮（含推理项回传，同步与流式）", fun responses_passthrough_tools/1},
     {"count_tokens", fun count_tokens/1},
     {"订阅套餐额度查询", fun plan_quota/1},
     {"按量付费余额查询", fun balance/1},
     {"图片生成", fun images/1},
     {"语音合成", fun speech/1},
     {"别名与请求标签", fun alias_tags/1},
     {"TLS 连接复用", fun connection_reuse/1}].

setup(#{key := Key, model := Model} = Cfg) ->
    Dir = lg_core_test_util:start(),
    application:set_env(lg_core, http_port, 0),
    {ok, _} = application:ensure_all_started(lg_web),
    Cred = fun(Name, Proto, Base, Opts) ->
                   {ok, #lg_credential{id = Id}} =
                       lg_credentials:create(#{<<"name">> => Name, <<"protocol">> => Proto,
                                               <<"base_url">> => Base, <<"api_key">> => Key,
                                               <<"options">> => Opts}),
                   [#{<<"credential">> => Id, <<"upstream_model">> => Model}]
           end,
    #{openai := OA, anthropic := AN} = Cfg,
    OaOpts0 = maps:get(oa_options, Cfg, #{}),
    OaOpts1 = case maps:find(plan, Cfg) of
                  {ok, Plan} -> OaOpts0#{<<"plan">> => #{<<"kind">> => Plan}};
                  error -> OaOpts0
              end,
    OaOpts = case maps:find(balance, Cfg) of
                 {ok, Bal} -> OaOpts1#{<<"balance">> => #{<<"kind">> => Bal}};
                 error -> OaOpts1
             end,
    [#{<<"credential">> := OACred} | _] = OAT = Cred(<<"openai">>, <<"openai">>, OA, OaOpts),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"oa">>, <<"targets">> => OAT,
                                 <<"aliases">> => [<<"claude-sonnet-4-5">>]}),
    {ok, _} = lg_routes:create(#{<<"name">> => <<"an">>,
                                 <<"targets">> => Cred(<<"anthropic">>, <<"anthropic">>, AN, #{})}),
    case maps:find(responses, Cfg) of
        {ok, RS} ->
            {ok, _} = lg_routes:create(#{<<"name">> => <<"rs">>,
                                         <<"targets">> => Cred(<<"responses">>, <<"openai">>, RS,
                                                               #{<<"responses_api">> => true})});
        error -> ok
    end,
    case Cfg of
        #{image := #{base := IB, model := IM, media_api := MA}} ->
            {ok, #lg_credential{id = IC}} =
                lg_credentials:create(#{<<"name">> => <<"image">>, <<"protocol">> => <<"openai">>, <<"base_url">> => IB,
                                        <<"api_key">> => Key, <<"options">> => #{<<"media_api">> => MA}}),
            {ok, _} = lg_routes:create(#{<<"name">> => <<"img">>,
                                         <<"targets">> => [#{<<"credential">> => IC, <<"upstream_model">> => IM}]}),
            case Cfg of
                #{tts := #{model := TM}} ->
                    {ok, _} = lg_routes:create(#{<<"name">> => <<"tts">>,
                                                 <<"targets">> => [#{<<"credential">> => IC, <<"upstream_model">> => TM}]});
                _ -> ok
            end;
        _ -> ok
    end,
    {ok, GK, _} = lg_api_keys:create(#{<<"name">> => <<"live">>}),
    #{dir => Dir, port => ranch:get_port(lg_http_listener), key => GK, host => OA, plan_cred => OACred,
      tts => maps:get(tts, Cfg, undefined),
      signature => maps:get(signature, Cfg), cfg => Cfg}.

cleanup(#{dir := Dir}) ->
    application:unset_env(lg_core, http_port),
    lg_core_test_util:stop(Dir).

%%====================================================================
%% HTTP 辅助
%%====================================================================

post(#{port := Port, key := K}, Path, Body) ->
    post(#{port => Port, key => K}, Path, Body, []).
post(#{port := Port, key := K}, Path, Body, Extra) ->
    {ok, Conn} = gun:open("127.0.0.1", Port, #{retry => 0}),
    {ok, _} = gun:await_up(Conn, 5000),
    H = [{<<"content-type">>, <<"application/json">>}, {<<"authorization">>, <<"Bearer ", K/binary>>},
         {<<"anthropic-version">>, <<"2023-06-01">>} | Extra],
    Ref = gun:post(Conn, Path, H, json:encode(Body)),
    Res = case gun:await(Conn, Ref, 110000) of
              {response, fin, S, RH} -> {S, RH, <<>>};
              {response, nofin, S, RH} -> {ok, B} = gun:await_body(Conn, Ref, 110000), {S, RH, B};
              {error, R} -> error({http_error, Path, R})
          end,
    gun:close(Conn),
    Res.

ok_json(Ctx, Path, Body) ->
    {S, H, B} = post(Ctx, Path, Body),
    S =:= 200 orelse io:format(user, "~n~ts -> ~b ~ts~n", [Path, S, B]),
    ?assertEqual({200, <<>>}, {S, case S of 200 -> <<>>; _ -> B end}),
    {json:decode(B), H}.

ok_sse(Ctx, Path, Body) ->
    {S, H, B} = post(Ctx, Path, Body#{<<"stream">> => true}),
    ?assertEqual({200, <<>>}, {S, case S of 200 -> <<>>; _ -> B end}),
    {Evs, _} = lg_sse:parse(B),
    {Evs, H}.

log(H) ->
    Id = proplists:get_value(<<"x-request-id">>, H),
    wait_log(Id, 100).

wait_log(Id, 0) -> error({log_not_found, Id});
wait_log(Id, N) ->
    lg_store:flush(),
    case lg_store:log(Id) of
        {ok, L} -> L;
        not_found -> timer:sleep(20), wait_log(Id, N - 1)
    end.

oa_chat(Model, Text) ->
    #{<<"model">> => Model, <<"max_tokens">> => 1024,
      <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => Text}]}.

an_chat(Model, Text) ->
    #{<<"model">> => Model, <<"max_tokens">> => 1024,
      <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => Text}]}.

%% OpenAI 流：拼接 delta.content / reasoning_content
oa_stream_text(Evs) ->
    iolist_to_binary([C || #{data := D} <- Evs, D =/= <<"[DONE]">>,
                           #{<<"choices">> := [#{<<"delta">> := #{<<"content">> := C}} | _]} <- [json:decode(D)],
                           is_binary(C)]).

an_stream_text(Evs) ->
    iolist_to_binary([T || #{event := <<"content_block_delta">>, data := D} <- Evs,
                           #{<<"delta">> := #{<<"type">> := <<"text_delta">>, <<"text">> := T}} <- [json:decode(D)]]).

%% 输入按「未命中缓存的部分」记，整段提示都命中缓存时为 0（Kimi Code 实测），所以与缓存读写合计判断
usage_ok(#{usage := #{input := I, output := O} = U}) ->
    ?assert(I + maps:get(cache_read, U, 0) + maps:get(cache_write, U, 0) > 0 andalso O > 0).

%%====================================================================
%% 用例
%%====================================================================

openai_same(Ctx) ->
    {#{<<"choices">> := [#{<<"message">> := #{<<"content">> := C}}]}, H} =
        ok_json(Ctx, <<"/v1/chat/completions">>, oa_chat(<<"oa">>, <<"用一个词回答：天空是什么颜色？"/utf8>>)),
    ?assert(byte_size(C) > 0),
    ?assertEqual(nomatch, binary:match(C, <<"<think>">>)),
    usage_ok(log(H)),
    {Evs, H2} = ok_sse(Ctx, <<"/v1/chat/completions">>, oa_chat(<<"oa">>, <<"数到三"/utf8>>)),
    ?assertEqual(<<"[DONE]">>, maps:get(data, lists:last(Evs))),
    ?assert(byte_size(oa_stream_text(Evs)) > 0),
    L = log(H2),
    usage_ok(L),
    ?assert(maps:get(ttft_ms, L) =< maps:get(duration_ms, L)).

anthropic_same(Ctx) ->
    {#{<<"type">> := <<"message">>, <<"content">> := Blocks}, H} =
        ok_json(Ctx, <<"/v1/messages">>, an_chat(<<"an">>, <<"用一个词回答：草是什么颜色？"/utf8>>)),
    Types = [T || #{<<"type">> := T} <- Blocks],
    ?assert(lists:member(<<"text">>, Types)),
    %% 带签名的 thinking 块（MiniMax）：同协议透传必须原样保留
    [?assert(byte_size(maps:get(<<"signature">>, B)) > 0)
     || maps:get(signature, Ctx), #{<<"type">> := <<"thinking">>} = B <- Blocks],
    usage_ok(log(H)),
    {Evs, H2} = ok_sse(Ctx, <<"/v1/messages">>, an_chat(<<"an">>, <<"数到三"/utf8>>)),
    Events = [E || #{event := E} <- Evs],
    ?assertEqual(<<"message_start">>, hd(Events)),
    ?assertEqual(<<"message_stop">>, lists:last(Events)),
    ?assert(byte_size(an_stream_text(Evs)) > 0),
    usage_ok(log(H2)).

openai_to_anthropic(Ctx) ->
    %% OpenAI 客户端调用 Anthropic 上游
    {#{<<"object">> := <<"chat.completion">>,
       <<"choices">> := [#{<<"message">> := Msg, <<"finish_reason">> := F}]}, H} =
        ok_json(Ctx, <<"/v1/chat/completions">>, oa_chat(<<"an">>, <<"用一个词回答：雪是什么颜色？"/utf8>>)),
    ?assert(byte_size(maps:get(<<"content">>, Msg)) > 0),
    ?assertEqual(<<"stop">>, F),
    %% thinking 转成 reasoning_content
    ?assert(is_binary(maps:get(<<"reasoning_content">>, Msg, <<>>))),
    usage_ok(log(H)),
    {Evs, H2} = ok_sse(Ctx, <<"/v1/chat/completions">>,
                       (oa_chat(<<"an">>, <<"数到三"/utf8>>))#{<<"stream_options">> => #{<<"include_usage">> => true}}),
    ?assert(byte_size(oa_stream_text(Evs)) > 0),
    [UsageChunk] = [J || #{data := D} <- Evs, D =/= <<"[DONE]">>, #{<<"choices">> := [], <<"usage">> := _} = J <- [json:decode(D)]],
    ?assert(maps:get(<<"completion_tokens">>, maps:get(<<"usage">>, UsageChunk)) > 0),
    usage_ok(log(H2)).

anthropic_to_openai(Ctx) ->
    {#{<<"type">> := <<"message">>, <<"content">> := Blocks, <<"stop_reason">> := R}, H} =
        ok_json(Ctx, <<"/v1/messages">>, an_chat(<<"oa">>, <<"用一个词回答：炭是什么颜色？"/utf8>>)),
    ?assertMatch([_ | _], [T || #{<<"type">> := <<"text">>, <<"text">> := T} <- Blocks]),
    ?assertEqual(<<"end_turn">>, R),
    usage_ok(log(H)),
    {Evs, H2} = ok_sse(Ctx, <<"/v1/messages">>, an_chat(<<"oa">>, <<"数到三"/utf8>>)),
    Events = [E || #{event := E} <- Evs],
    ?assertEqual([<<"message_start">>], lists:sublist(Events, 1)),
    ?assertEqual(<<"message_stop">>, lists:last(Events)),
    ?assert(byte_size(an_stream_text(Evs)) > 0),
    usage_ok(log(H2)).

weather_tool_oa() ->
    #{<<"type">> => <<"function">>,
      <<"function">> => #{<<"name">> => <<"get_weather">>,
                          <<"description">> => <<"查询城市当前天气"/utf8>>,
                          <<"parameters">> => #{<<"type">> => <<"object">>,
                                                <<"properties">> => #{<<"city">> => #{<<"type">> => <<"string">>}},
                                                <<"required">> => [<<"city">>]}}}.

tools_cross(Ctx) ->
    model_retry("tools_cross", fun() -> tools_cross_once(Ctx) end).

tools_cross_once(Ctx) ->
    Q = #{<<"role">> => <<"user">>, <<"content">> => <<"北京现在天气怎么样？请调用工具查询。"/utf8>>},
    Req = #{<<"model">> => <<"an">>, <<"max_tokens">> => 1024, <<"tools">> => [weather_tool_oa()],
            <<"messages">> => [Q]},
    {#{<<"choices">> := [#{<<"finish_reason">> := <<"tool_calls">>, <<"message">> := Msg}]}, _} =
        ok_json(Ctx, <<"/v1/chat/completions">>, Req),
    [#{<<"id">> := CallId, <<"function">> := #{<<"name">> := <<"get_weather">>, <<"arguments">> := Args}}] =
        maps:get(<<"tool_calls">>, Msg),
    ?assertMatch(#{<<"city">> := _}, json:decode(Args)),
    %% 回传工具结果，得到最终回答
    Req2 = Req#{<<"messages">> => [Q, maps:remove(<<"reasoning_content">>, Msg),
                                   #{<<"role">> => <<"tool">>, <<"tool_call_id">> => CallId,
                                     <<"content">> => <<"晴，25 摄氏度"/utf8>>}]},
    {#{<<"choices">> := [#{<<"message">> := #{<<"content">> := Final}}]}, _} =
        ok_json(Ctx, <<"/v1/chat/completions">>, Req2),
    ?assertNotEqual(nomatch, binary:match(Final, [<<"25">>, <<"晴"/utf8>>])),
    %% 流式工具调用：参数分片拼接后为合法 JSON
    {Evs, _} = ok_sse(Ctx, <<"/v1/chat/completions">>, Req),
    ArgsStream = iolist_to_binary(
                   [A || #{data := D} <- Evs, D =/= <<"[DONE]">>,
                         #{<<"choices">> := [#{<<"delta">> := #{<<"tool_calls">> := TCs}} | _]} <- [json:decode(D)],
                         #{<<"function">> := #{<<"arguments">> := A}} <- TCs]),
    ?assertMatch(#{<<"city">> := _}, json:decode(ArgsStream)).

tools_thinking_anthropic(Ctx) ->
    tools_thinking(Ctx, <<"an">>).

%% OpenAI 协议上游的思考（reasoning_content 或拆分出的 <think>）以 thinking 块给客户端，回传时还原给上游
tools_thinking_cross(Ctx) ->
    tools_thinking(Ctx, <<"oa">>).

tools_thinking(Ctx, Route) ->
    model_retry("tools_thinking", fun() -> tools_thinking_once(Ctx, Route) end).

tools_thinking_once(Ctx, Route) ->
    Tool = #{<<"name">> => <<"get_weather">>, <<"description">> => <<"查询城市当前天气"/utf8>>,
             <<"input_schema">> => #{<<"type">> => <<"object">>,
                                     <<"properties">> => #{<<"city">> => #{<<"type">> => <<"string">>}},
                                     <<"required">> => [<<"city">>]}},
    Q = #{<<"role">> => <<"user">>, <<"content">> => <<"上海现在天气怎么样？请调用工具查询。"/utf8>>},
    Req = #{<<"model">> => Route, <<"max_tokens">> => 1024, <<"tools">> => [Tool], <<"messages">> => [Q]},
    {#{<<"stop_reason">> := <<"tool_use">>, <<"content">> := Blocks}, _} = ok_json(Ctx, <<"/v1/messages">>, Req),
    %% 思考不应混进正文
    [?assertEqual(nomatch, binary:match(T, <<"<think>">>)) || #{<<"type">> := <<"text">>, <<"text">> := T} <- Blocks],
    ?assertMatch([_ | _], [B || #{<<"type">> := <<"thinking">>} = B <- Blocks]),
    [#{<<"input">> := #{<<"city">> := _}} | _] = [B || #{<<"type">> := <<"tool_use">>} = B <- Blocks],
    %% 原样回传助手内容（含 thinking 块）与工具结果；模型偶尔会再调一次工具，最多续 3 轮
    Final = tool_rounds(Ctx, Req, [Q], Blocks, 3),
    Text = iolist_to_binary([T || #{<<"type">> := <<"text">>, <<"text">> := T} <- Final]),
    ?assertNotEqual(nomatch, binary:match(Text, [<<"22">>, <<"多云"/utf8>>])).

tool_rounds(_Ctx, _Req, _Msgs, _Blocks, 0) ->
    error(too_many_tool_rounds);
tool_rounds(Ctx, Req, Msgs0, Blocks, N) ->
    Results = [#{<<"type">> => <<"tool_result">>, <<"tool_use_id">> => Id,
                 <<"content">> => <<"多云，22 摄氏度"/utf8>>} || #{<<"type">> := <<"tool_use">>, <<"id">> := Id} <- Blocks],
    Msgs = Msgs0 ++ [#{<<"role">> => <<"assistant">>, <<"content">> => Blocks},
                     #{<<"role">> => <<"user">>, <<"content">> => Results}],
    case ok_json(Ctx, <<"/v1/messages">>, Req#{<<"messages">> => Msgs}) of
        {#{<<"stop_reason">> := <<"end_turn">>, <<"content">> := Final}, _} -> Final;
        {#{<<"stop_reason">> := <<"tool_use">>, <<"content">> := More}, _} -> tool_rounds(Ctx, Req, Msgs, More, N - 1)
    end.

responses(Ctx) ->
    lists:foreach(
      fun(Route) ->
              Req = #{<<"model">> => Route, <<"instructions">> => <<"简短回答"/utf8>>,
                      <<"input">> => <<"记住这个数字：42。只回答“好”。"/utf8>>, <<"max_output_tokens">> => 1024},
              {#{<<"id">> := Id, <<"status">> := <<"completed">>, <<"output">> := Out,
                 <<"usage">> := #{<<"input_tokens">> := In}}, H} = ok_json(Ctx, <<"/v1/responses">>, Req),
              ?assert(In > 0),
              ?assertMatch([_ | _], [T || #{<<"type">> := <<"message">>, <<"content">> := C} <- Out,
                                          #{<<"type">> := <<"output_text">>, <<"text">> := T} <- C]),
              ?assertMatch(#{format := responses}, log(H)),
              timer:sleep(200),
              %% previous_response_id：模型应记得上一轮的数字
              {#{<<"output">> := Out2}, _} =
                  ok_json(Ctx, <<"/v1/responses">>,
                          #{<<"model">> => Route, <<"previous_response_id">> => Id, <<"max_output_tokens">> => 1024,
                            <<"input">> => <<"刚才让你记住的数字是多少？只回答数字。"/utf8>>}),
              Text = iolist_to_binary([T || #{<<"type">> := <<"message">>, <<"content">> := C} <- Out2,
                                            #{<<"type">> := <<"output_text">>, <<"text">> := T} <- C]),
              ?assertNotEqual(nomatch, binary:match(Text, <<"42">>)),
              %% 流式
              {Evs, _} = ok_sse(Ctx, <<"/v1/responses">>, Req),
              Types = [E || #{event := E} <- Evs],
              ?assertEqual(<<"response.created">>, hd(Types)),
              ?assertEqual(<<"response.completed">>, lists:last(Types)),
              #{<<"response">> := #{<<"usage">> := #{<<"output_tokens">> := OT}}} =
                  json:decode(maps:get(data, lists:last(Evs))),
              ?assert(OT > 0)
      end, [<<"oa">>, <<"an">>]).

output_text(Out) ->
    iolist_to_binary([T || #{<<"type">> := <<"message">>, <<"content">> := C} <- Out,
                           #{<<"type">> := <<"output_text">>, <<"text">> := T} <- C]).

%% 依赖模型输出（是否调用工具、能否复述上一轮内容）的用例：模型偶尔不照做，失败时重试一次并打印出来
model_retry(Name, F) ->
    try F()
    catch error:Reason ->
            io:format(user, "~n[retry] ~ts: first attempt failed: ~0p~n", [Name, Reason]),
            F()
    end.

responses_passthrough(Ctx) ->
    model_retry("responses_passthrough", fun() -> responses_passthrough_once(Ctx) end).

responses_passthrough_once(Ctx) ->
    Req = #{<<"model">> => <<"rs">>, <<"max_output_tokens">> => 1024,
            <<"input">> => <<"记住这个数字：73。只回答“好”。"/utf8>>},
    {#{<<"id">> := Id, <<"status">> := <<"completed">>, <<"output">> := Out}, H} =
        ok_json(Ctx, <<"/v1/responses">>, Req),
    ?assert(byte_size(output_text(Out)) > 0),
    L = log(H),
    usage_ok(L),
    ?assertMatch(#{format := responses}, L),
    %% 透传会话：previous_response_id 原样转发，由上游持有上下文
    timer:sleep(200),
    {#{<<"output">> := Out2}, _} =
        ok_json(Ctx, <<"/v1/responses">>,
                #{<<"model">> => <<"rs">>, <<"previous_response_id">> => Id, <<"max_output_tokens">> => 1024,
                  <<"input">> => <<"刚才让你记住的数字是多少？只回答数字。"/utf8>>}),
    nomatch =:= binary:match(output_text(Out2), <<"73">>)
        andalso io:format(user, "~n[responses passthrough] second turn: ~ts~n", [output_text(Out2)]),
    ?assertNotEqual(nomatch, binary:match(output_text(Out2), <<"73">>)),
    {Evs, H2} = ok_sse(Ctx, <<"/v1/responses">>, Req),
    ?assertEqual(<<"response.completed">>, maps:get(event, lists:last(Evs))),
    usage_ok(log(H2)).

%% Codex 式的无状态多轮：store false，每轮把上一轮的全部输出项（含 reasoning）与工具结果放进 input
responses_passthrough_tools(Ctx) ->
    model_retry("responses_passthrough_tools", fun() -> responses_passthrough_tools_once(Ctx) end).

responses_passthrough_tools_once(Ctx) ->
    Tool = #{<<"type">> => <<"function">>, <<"name">> => <<"get_weather">>,
             <<"description">> => <<"查询城市当前天气"/utf8>>,
             <<"parameters">> => #{<<"type">> => <<"object">>, <<"properties">> => #{<<"city">> => #{<<"type">> => <<"string">>}},
                                   <<"required">> => [<<"city">>]}},
    Q = #{<<"type">> => <<"message">>, <<"role">> => <<"user">>,
          <<"content">> => [#{<<"type">> => <<"input_text">>, <<"text">> => <<"北京现在天气怎么样？请调用工具查询。"/utf8>>}]},
    Base = #{<<"model">> => <<"rs">>, <<"tools">> => [Tool], <<"store">> => false, <<"max_output_tokens">> => 2048,
             <<"include">> => [<<"reasoning.encrypted_content">>]},
    {#{<<"output">> := Out1}, H1} = ok_json(Ctx, <<"/v1/responses">>, Base#{<<"input">> => [Q]}),
    Calls = [C || #{<<"type">> := <<"function_call">>} = C <- Out1],
    Calls =:= [] andalso io:format(user, "~n[responses tools] no tool call, output: ~ts~n", [output_text(Out1)]),
    ?assertMatch([#{<<"name">> := <<"get_weather">>, <<"call_id">> := _, <<"arguments">> := _} | _], Calls),
    io:format(user, "~n[responses tools] output item types: ~p~n", [[T || #{<<"type">> := T} <- Out1]]),
    ?assertMatch(#{format := responses}, log(H1)),
    Results = [#{<<"type">> => <<"function_call_output">>, <<"call_id">> => Id, <<"output">> => <<"晴，25 摄氏度"/utf8>>}
               || #{<<"call_id">> := Id} <- Calls],
    %% 输出项原样回传（去掉服务端生成的状态字段由上游决定是否接受，这里按 Codex 的做法原样带回）
    Input2 = [Q | Out1] ++ Results,
    {#{<<"output">> := Out2}, _} = ok_json(Ctx, <<"/v1/responses">>, Base#{<<"input">> => Input2}),
    ?assertNotEqual(nomatch, binary:match(output_text(Out2), [<<"25">>, <<"晴"/utf8>>])),
    %% 流式：参数分片拼接后为合法 JSON，结束事件带完整输出
    {Evs, _} = ok_sse(Ctx, <<"/v1/responses">>, Base#{<<"input">> => [Q]}),
    #{<<"response">> := #{<<"output">> := SOut}} = json:decode(maps:get(data, lists:last(Evs))),
    [#{<<"arguments">> := Args} | _] = [C || #{<<"type">> := <<"function_call">>} = C <- SOut],
    ?assertMatch(#{<<"city">> := _}, json:decode(Args)).

balance(#{plan_cred := Id}) ->
    ok = lg_balance:refresh([Id]),
    [#{amount := A, currency := Cur, error := Err}] = [B || #{credential := C} = B <- lg_balance:all(), C =:= Id],
    ?assertEqual(null, Err),
    ?assert(is_number(A)),
    ?assert(lists:member(Cur, [<<"CNY">>, <<"USD">>])),
    io:format(user, "~n[balance] currency ~ts, amount is a number~n", [Cur]).

count_tokens(Ctx) ->
    {S, _, B} = post(Ctx, <<"/v1/messages/count_tokens">>,
                     #{<<"model">> => <<"an">>,
                       <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hello world">>}]}),
    case S of
        200 -> ?assertMatch(#{<<"input_tokens">> := N} when N > 0, json:decode(B));
        %% 上游不支持时如实转发其错误（不应是网关自身的 5xx）
        _ -> ?assert(S >= 400 andalso S < 500)
    end.

plan_quota(#{plan_cred := Id}) ->
    ok = lg_plan:refresh([Id]),
    [#{error := Err, windows := Ws, state := State}] = lg_plan:all(),
    ?assertEqual(null, Err),
    ?assertMatch([_ | _], Ws),
    [?assert(is_number(U) andalso U >= 0 andalso U =< 100 andalso is_integer(R) andalso R > lg_time:now_ms())
     || #{used_pct := U, resets_at := R} <- Ws],
    ?assert(lists:member(State, [<<"normal">>, <<"reserve">>, <<"exhausted">>])).

images(Ctx) ->
    {#{<<"data">> := [#{<<"url">> := Url}]}, H} =
        ok_json(Ctx, <<"/v1/images/generations">>,
                #{<<"model">> => <<"img">>, <<"prompt">> => <<"一只橙色的猫坐在窗台上，水彩风格"/utf8>>,
                  <<"n">> => 1, <<"size">> => <<"1024x1024">>}),
    ?assertMatch(<<"http", _/binary>>, Url),
    ?assertMatch(#{format := images, usage := #{images := 1}}, log(H)).

speech(#{tts := #{voice := V, format := F}} = Ctx) ->
    {S, H, Audio} = post(Ctx, <<"/v1/audio/speech">>,
                         #{<<"model">> => <<"tts">>, <<"input">> => <<"你好，欢迎使用网关。"/utf8>>, <<"voice">> => V,
                           <<"response_format">> => F}),
    ?assertEqual(200, S),
    ?assertMatch(<<"audio/", _/binary>>, proplists:get_value(<<"content-type">>, H)),
    ?assert(byte_size(Audio) > 1000),
    case F of
        <<"wav">> -> ?assertMatch(<<"RIFF", _/binary>>, Audio);
        _ -> ok
    end,
    ?assertMatch(#{format := speech, usage := #{chars := 10}}, log(H)).

%% 客户端用别名请求；请求头标签 + metadata 标签记入日志与按标签用量
alias_tags(Ctx) ->
    {S, H, B} = post(Ctx, <<"/v1/chat/completions">>,
                     (oa_chat(<<"claude-sonnet-4-5">>, <<"用一个词回答：海是什么颜色？"/utf8>>))#{
                       <<"metadata">> => #{<<"tags">> => <<"proj:live">>}},
                     [{<<"x-litegate-tags">>, <<"tool:eunit">>}]),
    ?assertEqual({200, <<>>}, {S, case S of 200 -> <<>>; _ -> B end}),
    ?assertMatch(#{route := <<"oa">>, model := <<"claude-sonnet-4-5">>, tags := [<<"tool:eunit">>, <<"proj:live">>]}, log(H)),
    Rows = lg_store:usage(#{from => lg_time:now_ms() - 3600000, to => lg_time:now_ms() + 1000, group_by => [tag]}),
    ?assertMatch([#{requests := 1}], [R || #{tag := <<"proj:live">>} = R <- Rows]).

connection_reuse(#{host := Base} = Ctx) ->
    #{host := Host} = uri_string:parse(Base),
    Before = lg_http_pool:stats(),
    [ok_json(Ctx, <<"/v1/chat/completions">>, oa_chat(<<"oa">>, <<"hi">>)) || _ <- [1, 2, 3]],
    After = lg_http_pool:stats(),
    Key = {tls, binary_to_list(Host), 443},
    ?assert(maps:get(Key, After, 0) >= 1),
    ?assert(maps:get(Key, After, 0) =< maps:get(Key, Before, 0) + 1).

%%====================================================================
%% 路由稳健性、规则路由、链路导出
%%====================================================================

%%====================================================================
%% 结构化输出、脱敏与上游参数兼容
%%====================================================================

m8_cases() ->
    [{"结构化输出（openai 客户端 json_schema → 两种上游，同步与流式）", fun m8_structured_openai/1},
     {"结构化输出（anthropic 客户端 output_config → 两种上游，同步与流式）", fun m8_structured_anthropic/1},
     {"脱敏（上游收到占位符，客户端收到原值）", fun m8_redact/1},
     {"上游参数兼容（采集错误原文，学到后重试成功）", fun m8_unfit/1}].

city_schema() ->
    #{<<"type">> => <<"object">>,
      <<"properties">> => #{<<"city">> => #{<<"type">> => <<"string">>}, <<"country">> => #{<<"type">> => <<"string">>}},
      <<"required">> => [<<"city">>, <<"country">>], <<"additionalProperties">> => false}.

-define(CAPITAL, <<"法国的首都是哪座城市？只用 JSON 回答，city 与 country 用中文。"/utf8>>).

%% 回复正文必须是符合 schema 的 JSON 对象
city_ok(Text) ->
    J = try json:decode(string:trim(Text))
        catch _:_ -> error({not_json, Text})
        end,
    ?assertMatch(#{<<"city">> := C, <<"country">> := _} when is_binary(C), J),
    ?assertNotEqual(nomatch, binary:match(maps:get(<<"city">>, J), <<"巴黎"/utf8>>)).

m8_structured_openai(Ctx) ->
    RF = #{<<"type">> => <<"json_schema">>,
           <<"json_schema">> => #{<<"name">> => <<"capital">>, <<"strict">> => true, <<"schema">> => city_schema()}},
    [model_retry("structured_openai " ++ binary_to_list(R), fun() ->
         Req = (oa_chat(R, ?CAPITAL))#{<<"response_format">> => RF, <<"max_tokens">> => 2048},
         {#{<<"choices">> := [#{<<"message">> := #{<<"content">> := C}, <<"finish_reason">> := F}]}, H} =
             ok_json(Ctx, <<"/v1/chat/completions">>, Req),
         io:format(user, "~n[structured] openai → ~s: ~ts (~ts)~n", [R, C, F]),
         city_ok(C),
         ?assertEqual(<<"stop">>, F),
         usage_ok(log(H)),
         {Evs, _} = ok_sse(Ctx, <<"/v1/chat/completions">>, Req),
         city_ok(oa_stream_text(Evs))
     end) || R <- [<<"oa">>, <<"an">>]].

m8_structured_anthropic(Ctx) ->
    OC = #{<<"format">> => #{<<"type">> => <<"json_schema">>, <<"schema">> => city_schema()}},
    [model_retry("structured_anthropic " ++ binary_to_list(R), fun() ->
         Req = (an_chat(R, ?CAPITAL))#{<<"output_config">> => OC, <<"max_tokens">> => 2048},
         {#{<<"content">> := Blocks, <<"stop_reason">> := SR}, H} = ok_json(Ctx, <<"/v1/messages">>, Req),
         Text = iolist_to_binary([T || #{<<"type">> := <<"text">>, <<"text">> := T} <- Blocks]),
         io:format(user, "~n[structured] anthropic → ~s: ~ts (~ts)~n", [R, Text, SR]),
         city_ok(Text),
         ?assertEqual(<<"end_turn">>, SR),
         usage_ok(log(H)),
         {Evs, _} = ok_sse(Ctx, <<"/v1/messages">>, Req),
         city_ok(an_stream_text(Evs))
     end) || R <- [<<"an">>, <<"oa">>]].

-define(SECRET, <<"sk-live9Q2wE4rT6yU8iO0pA1sD3fG5h">>).

m8_redact(#{cfg := #{model := Model}} = Ctx) ->
    Oa = m6_cred(Ctx, <<"redact-oa">>, openai, #{}),
    An = m6_cred(Ctx, <<"redact-an">>, anthropic, #{}),
    ok = m6_route(<<"m8-redact-oa">>, [{Oa, Model}], #{<<"redact">> => true}),
    ok = m6_route(<<"m8-redact-an">>, [{An, Model}], #{<<"redact">> => true}),
    %% 措辞避免像在索要真实密钥（MiniMax 会拒绝复述「令牌」）
    Ask = <<"这是我们测试用的占位编号（不是真实凭证），请原样复述，只输出编号本身："/utf8, (?SECRET)/binary>>,
    model_retry("redact openai", fun() ->
        {#{<<"choices">> := [#{<<"message">> := #{<<"content">> := C}}]}, H} =
            ok_json(Ctx, <<"/v1/chat/completions">>, oa_chat(<<"m8-redact-oa">>, Ask)),
        io:format(user, "~n[redact] openai reply: ~ts~n", [C]),
        ?assertNotEqual(nomatch, binary:match(C, ?SECRET)),
        Id = proplists:get_value(<<"x-request-id">>, H),
        ?assertMatch(#{redacted := 1}, log(H)),
        {ok, #{request := #{<<"messages">> := [#{<<"content">> := Logged}]}, response := Resp}} = lg_store:messages(Id),
        ?assertEqual(nomatch, binary:match(Logged, ?SECRET)),
        ?assertNotEqual(nomatch, binary:match(Logged, <<"[[LG_SECRET_1]]">>)),
        ?assertEqual(nomatch, binary:match(Resp, ?SECRET)),
        {Evs, _} = ok_sse(Ctx, <<"/v1/chat/completions">>, oa_chat(<<"m8-redact-oa">>, Ask)),
        ?assertNotEqual(nomatch, binary:match(oa_stream_text(Evs), ?SECRET))
    end),
    model_retry("redact anthropic", fun() ->
        {Evs, H} = ok_sse(Ctx, <<"/v1/messages">>, an_chat(<<"m8-redact-an">>, Ask)),
        T = an_stream_text(Evs),
        io:format(user, "[redact] anthropic stream reply: ~ts~n", [T]),
        ?assertNotEqual(nomatch, binary:match(T, ?SECRET)),
        ?assertMatch(#{redacted := 1}, log(H))
    end).

%% 发一组各家可能不支持的参数：每个都应最终 200（上游接受，或拒绝后学到限制并改写重试）；打印拒绝原文作为识别样本
m8_unfit(#{cfg := #{model := Model}} = Ctx) ->
    Native = m6_cred(Ctx, <<"unfit-native">>, anthropic, #{<<"structured_output">> => <<"native">>}),
    ok = m6_route(<<"m8-native">>, [{Native, Model}], #{}),
    Probes =
        [{"prefill（openai）", <<"/v1/chat/completions">>,
          #{<<"model">> => <<"oa">>, <<"max_tokens">> => 256,
            <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"说一种颜色"/utf8>>},
                               #{<<"role">> => <<"assistant">>, <<"content">> => <<"这种颜色是"/utf8>>}]}},
         {"prefill（anthropic）", <<"/v1/messages">>,
          #{<<"model">> => <<"an">>, <<"max_tokens">> => 256,
            <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"说一种颜色"/utf8>>},
                               #{<<"role">> => <<"assistant">>, <<"content">> => <<"这种颜色是"/utf8>>}]}},
         {"temperature + top_p（openai）", <<"/v1/chat/completions">>,
          (oa_chat(<<"oa">>, <<"hi">>))#{<<"temperature">> => 0.3, <<"top_p">> => 0.5}},
         {"temperature + top_p（anthropic）", <<"/v1/messages">>,
          (an_chat(<<"an">>, <<"hi">>))#{<<"temperature">> => 0.3, <<"top_p">> => 0.5}},
         {"thinking disabled（anthropic）", <<"/v1/messages">>,
          (an_chat(<<"an">>, <<"hi">>))#{<<"thinking">> => #{<<"type">> => <<"disabled">>}}},
         {"reasoning_effort none（openai）", <<"/v1/chat/completions">>,
          (oa_chat(<<"oa">>, <<"hi">>))#{<<"reasoning_effort">> => <<"none">>}},
         {"output_config 原生（anthropic）", <<"/v1/messages">>,
          (an_chat(<<"m8-native">>, ?CAPITAL))#{<<"max_tokens">> => 2048,
              <<"output_config">> => #{<<"format">> => #{<<"type">> => <<"json_schema">>, <<"schema">> => city_schema()}}}}],
    Results =
        [begin
             Before = length(lg_unfit:list()),
             {S, _H, B} = post(Ctx, Path, Body),
             New = lists:nthtail(Before, lists:keysort(1, [{At, M, F, Msg} || #{learned_at := At, upstream_model := M, feature := F,
                                                                                message := Msg} <- lg_unfit:list()])),
             {Name, S, [{F, Msg} || {_, _, F, Msg} <- New], case S of 200 -> <<>>; _ -> binary:part(B, 0, min(300, byte_size(B))) end}
         end || {Name, Path, Body} <- Probes],
    io:format(user, "~n[unfit] ~ts~n", [lists:join(<<"\n[unfit] "/utf8>>,
        [io_lib:format("~ts -> ~b~ts~ts", [N, S,
                                           [io_lib:format(<<" | 学到 ~s：~ts"/utf8>>, [F, Msg]) || {F, Msg} <- Learned],
                                           case Err of <<>> -> ""; _ -> [" | ", Err] end])
         || {N, S, Learned, Err} <- Results])]),
    ?assertEqual([], [{N, S, Err} || {N, S, _, Err} <- Results, S =/= 200]).

m6_cases() ->
    [{"错误分类（真实错误体）", fun m6_errors/1},
     {"会话粘性（两个凭证，一轮内与跨轮）", fun m6_affinity/1},
     {"凭证并发上限与排队", fun m6_concurrency/1},
     {"规则与意图路由", fun m6_rules/1},
     {"OTLP 导出", fun m6_otlp/1}].

m6_cred(#{cfg := #{key := Key} = Cfg}, Name, Proto, Opts) ->
    Base = maps:get(Proto, Cfg),
    {ok, #lg_credential{id = Id}} =
        lg_credentials:create(#{<<"name">> => Name, <<"protocol">> => atom_to_binary(Proto), <<"base_url">> => Base,
                                <<"api_key">> => Key, <<"options">> => Opts}),
    Id.

m6_route(Name, Targets, Opts) ->
    _ = lg_routes:delete(Name),
    {ok, _} = lg_routes:create(#{<<"name">> => Name, <<"options">> => Opts,
                                 <<"targets">> => [#{<<"credential">> => C, <<"upstream_model">> => M} || {C, M} <- Targets]}),
    ok.

%% 真实错误体：错误的 Key（鉴权）与不存在的模型；打印原文作为样本，并检查分类
m6_errors(#{cfg := #{model := Model} = Cfg} = Ctx) ->
    {ok, #lg_credential{id = Bad}} =
        lg_credentials:create(#{<<"name">> => <<"bad-key">>, <<"protocol">> => <<"openai">>,
                                <<"base_url">> => maps:get(openai, Cfg), <<"api_key">> => <<"sk-invalid-0000000000">>}),
    Good = m6_cred(Ctx, <<"err-good">>, openai, #{}),
    ok = m6_route(<<"m6-auth">>, [{Bad, Model}], #{}),
    {S1, _, B1} = post(Ctx, <<"/v1/chat/completions">>, oa_chat(<<"m6-auth">>, <<"hi">>)),
    io:format(user, "~n[sample] invalid key -> ~b ~ts~n", [S1, B1]),
    ?assert(S1 =:= 401 orelse S1 =:= 403),
    ?assertMatch(#{kind := auth}, lg_cooldown:info({Bad, Model})),
    ok = m6_route(<<"m6-model">>, [{Good, <<"no-such-model-xyz">>}], #{}),
    {S2, _, B2} = post(Ctx, <<"/v1/chat/completions">>, oa_chat(<<"m6-model">>, <<"hi">>)),
    io:format(user, "[sample] unknown model -> ~b ~ts~n", [S2, binary:part(B2, 0, min(300, byte_size(B2)))]),
    %% Kimi Code 接受任意模型名（都按 kimi-for-coding 回答），其余上游返回 4xx
    case maps:get(any_model, Cfg, false) of
        true -> ?assertEqual(200, S2);
        false -> ?assert(S2 >= 400)
    end,
    lg_cooldown:clear().

long_system() ->
    %% 约 2.5K token 的系统提示，用于触发上游提示词缓存
    iolist_to_binary([[<<"You are a meticulous assistant. Rule ">>, integer_to_binary(N),
                       <<": always answer briefly and precisely, never invent facts, and keep the user's language. ">>]
                      || N <- lists:seq(1, 120)]).

%% 两个凭证（同一个 Key）按权重随机；同一会话：一轮之内（工具结果）必定留在原凭证；
%% 新的一轮：读到的缓存 ≥ 1024 时保留，否则放弃（上游不报告缓存时如此）
m6_affinity(#{cfg := #{model := Model}} = Ctx) ->
    A = m6_cred(Ctx, <<"aff-a">>, anthropic, #{<<"prompt_cache">> => <<"auto">>}),
    B = m6_cred(Ctx, <<"aff-b">>, anthropic, #{<<"prompt_cache">> => <<"auto">>}),
    ok = m6_route(<<"m6-sticky">>, [{A, Model}, {B, Model}], #{}),
    Sess = [{<<"x-litegate-session">>, iolist_to_binary([<<"live-">>, integer_to_binary(erlang:unique_integer([positive]))])}],
    Tool = #{<<"name">> => <<"get_weather">>, <<"description">> => <<"查询城市当前天气"/utf8>>,
             <<"input_schema">> => #{<<"type">> => <<"object">>, <<"properties">> => #{<<"city">> => #{<<"type">> => <<"string">>}}}},
    Q = #{<<"role">> => <<"user">>, <<"content">> => <<"用一句话介绍杭州。"/utf8>>},
    Req = #{<<"model">> => <<"m6-sticky">>, <<"max_tokens">> => 512, <<"system">> => long_system(),
            <<"tools">> => [Tool], <<"messages">> => [Q]},
    Call = fun(R) ->
                   {S, H, Body} = post(Ctx, <<"/v1/messages">>, R, Sess),
                   S =:= 200 orelse io:format(user, "~n~ts~n", [Body]),
                   ?assertEqual(200, S),
                   log(H)
           end,
    L1 = Call(Req),
    ?assertMatch(#{affinity := <<"miss">>}, L1),
    First = maps:get(credential, L1),
    %% 同一轮：伪造一次工具调用与结果
    ToolTurn = Req#{<<"messages">> => [Q,
        #{<<"role">> => <<"assistant">>, <<"content">> => [#{<<"type">> => <<"tool_use">>, <<"id">> => <<"toolu_live1">>,
                                                            <<"name">> => <<"get_weather">>, <<"input">> => #{<<"city">> => <<"杭州"/utf8>>}}]},
        #{<<"role">> => <<"user">>, <<"content">> => [#{<<"type">> => <<"tool_result">>, <<"tool_use_id">> => <<"toolu_live1">>,
                                                        <<"content">> => <<"晴"/utf8>>}]}]},
    L2 = Call(ToolTurn),
    ?assertMatch(#{affinity := <<"hit">>}, L2),
    ?assertEqual(First, maps:get(credential, L2)),
    %% 新的一轮
    L3 = Call(Req#{<<"messages">> => [Q, #{<<"role">> => <<"assistant">>, <<"content">> => <<"杭州是浙江省会。"/utf8>>},
                                    #{<<"role">> => <<"user">>, <<"content">> => <<"再说一句西湖。"/utf8>>}]}),
    CR2 = maps:get(cache_read, maps:get(usage, L2)),
    io:format(user, "~n[affinity] cache_read: ~p / ~p / ~p, new turn -> ~ts~n",
              [maps:get(cache_read, maps:get(usage, L1)), CR2, maps:get(cache_read, maps:get(usage, L3)),
               maps:get(affinity, L3)]),
    case CR2 >= 1024 of
        true -> ?assertEqual({<<"hit">>, First}, {maps:get(affinity, L3), maps:get(credential, L3)});
        false -> ?assertEqual(<<"broken:cache_cold">>, maps:get(affinity, L3))
    end.

%% 并发上限 1：3 个并发流式请求全部成功，后两个排队
m6_concurrency(#{cfg := #{model := Model}} = Ctx) ->
    %% 推理模型单次可能十几秒，排队上限放宽，避免因上游慢而超时
    application:set_env(lg_core, queue_wait_ms, 100000),
    C = m6_cred(Ctx, <<"conc-1">>, openai, #{<<"max_concurrency">> => 1}),
    ok = m6_route(<<"m6-conc">>, [{C, Model}], #{}),
    Self = self(),
    [spawn(fun() ->
                   {S, H, _} = post(Ctx, <<"/v1/chat/completions">>,
                                    (oa_chat(<<"m6-conc">>, <<"用一个词回答：天空是什么颜色？"/utf8>>))#{<<"stream">> => true}),
                   Self ! {done, S, H}
           end) || _ <- [1, 2, 3]],
    Logs = [receive {done, S, H} -> ?assertEqual(200, S), log(H) after 110000 -> error(timeout) end || _ <- [1, 2, 3]],
    Queued = [Q || #{queued_ms := Q} <- Logs],
    io:format(user, "~n[concurrency] queued_ms: ~p, duration_ms: ~p, errors: ~p~n",
              [Queued, [D || #{duration_ms := D} <- Logs], [maps:get(error, L, none) || L <- Logs]]),
    %% 开流前排队超过 stream_hold_ms 时 HTTP 状态已是 200，以日志判断是否成功
    application:unset_env(lg_core, queue_wait_ms),
    [?assertEqual(none, maps:get(error, L, none)) || L <- Logs],
    ?assert(length(Queued) >= 1),
    ?assertEqual(0, lg_conc:inflight(C)).

%% 规则与意图路由：判断模型用本上游的 OpenAI 入口；写测试 → strong，随口一问 → cheap；长上下文直接走 long
m6_rules(#{cfg := #{model := Model}} = Ctx) ->
    J = m6_cred(Ctx, <<"judge">>, openai, #{}),
    ok = m6_route(<<"m6-judge">>, [{J, Model}], #{}),
    ok = m6_route(<<"m6-strong">>, [{m6_cred(Ctx, <<"strong">>, anthropic, #{}), Model}], #{}),
    ok = m6_route(<<"m6-cheap">>, [{m6_cred(Ctx, <<"cheap">>, openai, #{}), Model}], #{}),
    ok = m6_route(<<"m6-long">>, [{m6_cred(Ctx, <<"long">>, openai, #{}), Model}], #{}),
    Rules = [#{<<"when">> => #{<<"min_tokens">> => 3000}, <<"use">> => <<"m6-long">>},
             #{<<"when">> => #{<<"intent">> => <<"a quick question or explanation, with no code to write or change">>},
               <<"use">> => <<"m6-cheap">>},
             #{<<"when">> => #{<<"intent">> => <<"writing or fixing tests">>}, <<"use">> => <<"m6-strong">>}],
    ok = m6_route(<<"m6-coder">>, [{m6_cred(Ctx, <<"coder">>, openai, #{}), Model}],
                  #{<<"rules">> => Rules, <<"classifier">> => <<"m6-judge">>}),
    Ask = fun(Text) ->
                  {S, H, B} = post(Ctx, <<"/v1/chat/completions">>, oa_chat(<<"m6-coder">>, Text)),
                  S =:= 200 orelse io:format(user, "~n~ts~n", [B]),
                  ?assertEqual(200, S),
                  L = log(H),
                  io:format(user, "~n[rules] ~ts -> rule ~p, ~p, intent ~p~n",
                            [binary:part(Text, 0, min(30, byte_size(Text))), maps:get(rule, L, none),
                             maps:get(routed_to, L, none), maps:get(intent, L, none)]),
                  L
          end,
    ?assertMatch(#{routed_to := <<"m6-strong">>},
                 Ask(<<"给这个 Python 函数写 pytest 单元测试，覆盖负数和零：def add(a, b): return a + b"/utf8>>)),
    ?assertMatch(#{routed_to := <<"m6-cheap">>}, Ask(<<"HTTP 状态码 404 是什么意思？"/utf8>>)),
    ?assertMatch(#{routed_to := <<"m6-long">>, rule := 1},
                 Ask(iolist_to_binary([binary:copy(<<"这是一段很长的背景材料。"/utf8>>, 400), <<"请总结一句。"/utf8>>]))),
    %% 判断调用单独记日志
    #{items := Judged} = lg_store:logs(#{tag => <<"litegate:intent">>, limit => 10}),
    ?assert(length(Judged) >= 2).

%% OTLP：本地 mock 收集器收到父 span 与尝试 span，成功的尝试带用量
m6_otlp(Ctx) ->
    Port = lg_mock_upstream:start(),
    try
        application:set_env(lg_core, otlp_enabled, true),
        application:set_env(lg_core, otlp_endpoint, iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port)])),
        {_, H} = ok_json(Ctx, <<"/v1/chat/completions">>, oa_chat(<<"oa">>, <<"用一个词回答：草是什么颜色？"/utf8>>)),
        _ = log(H),
        lg_mock_upstream:expect({json, 200, #{}, #{}}),
        ok = lg_otlp:flush(),
        [#{body := #{<<"resourceSpans">> := [#{<<"scopeSpans">> := [#{<<"spans">> := Spans}]}]}}] = lg_mock_upstream:requests(),
        [Root | Attempts] = Spans,
        ?assertMatch(#{<<"name">> := <<"litegate.request">>}, Root),
        Ok = lists:last(Attempts),
        ?assert(lists:any(fun(#{<<"key">> := K}) -> K =:= <<"gen_ai.usage.input_tokens">> end, maps:get(<<"attributes">>, Ok)))
    after
        application:unset_env(lg_core, otlp_enabled),
        application:unset_env(lg_core, otlp_endpoint),
        lg_mock_upstream:stop()
    end.
