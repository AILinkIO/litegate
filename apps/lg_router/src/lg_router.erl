%% @doc 路由：鉴权 → 解析路由 → 生成尝试顺序 → 依次调用上游，失败冷却并回退。
%%
%% 尝试顺序：本路由启用的目标按 priority 升序分组，组内按 weight 随机；
%% 冷却中的目标排到最后（仍作为最后手段）；之后依次展开回退路由（只展开一层）。
%% 至多尝试 route_max_attempts 个目标。
%%
%% 回退条件：可重试错误（429 / 5xx / 网络 / 超时）或鉴权错误（该凭证 Key 有问题，换一个）；
%% 其余 4xx 说明请求本身有问题，直接返回。
%%
%% 流量控制：解析路由后先查预算，再按 Key / 路由 / Key×路由限额占用（回退不重复计数）。
%% 请求结束（成功、失败、中止）后调用方必须调用 done/1 归还并发槽位、补差 TPM、累计花费。
-module(lg_router).

-include_lib("lg_core/include/lg_core.hrl").

-define(MAX_NESTING, 3).

-export([classify/4, judge_systemone/4, systemone_request/1, candidates/1, models/1, resolve/2, plan/1, plan/2, plan/3, chat/3, stream_open/3, embeddings/2, count_tokens/2, images/2, speech/2, live/2, systemone/2,
         finalize/2, done/1, default_max_tokens/1]).

-type ctx() :: #{key := #lg_api_key{}, client_headers => [{binary(), binary()}],
                 id => binary(), kind => chat | embeddings | count_tokens | images | speech | live | systemone,
                 no_cache => boolean(),
                 client => binary(), user_agent => binary() | undefined,
                 traceparent => binary() | undefined,
                 mw => none | map(),                 %% 中间件运行态（lg_middleware:run()）
                 redact => boolean() | map(),        %% 请求阶段是开关；命中脱敏后是占位符 → 原值
                 original => map(), redact_stream => map(),
                 session_source => derived | explicit,
                 prefer => {binary(), binary()},      %% 优先尝试的 {凭证, 上游模型}
                 session => binary(),                  %% 会话标识（lg_session）
                 new_turn => boolean(),                %% 对话请求：是否开始新的一轮
                 idle => fun(() -> term()),            %% 流式：等待上游 / 排队时的回调（写保活帧）
                 hold_started => non_neg_integer(),    %% 流式：请求开始时刻（与 stream_hold_max_ms 配合设开流上限）
                 tags => [binary()]}.                 %% 请求标签（lg_tags 已规范化）
-type outcome() :: #{route := binary(),
                     model := binary(),              %% 客户端请求的模型名
                     key_id := binary(),
                     user_id := binary() | undefined,
                     tags := [binary()],
                     started_at := non_neg_integer(),
                     attempts := [map()],
                     credential => binary(),
                     upstream_model => binary(),
                     model_ref => lg_model_ref(),
                     result => lg_stream:result(),
                     cost => float(),
                     duration_ms => non_neg_integer(),
                     ticket => lg_limiter:ticket(),
                     error => error_reason(),        %% 调用方记账时附加
                     client_aborted => boolean(),
                     cache_hit => boolean(),
                     saved_usd => float(),
                     plan => true,                   %% 由订阅套餐凭证完成
                     estimated => true,              %% count_tokens 为本地估算
                     plan_usd => float(),            %% 套餐等价花费（按定价计算，未实际扣费）
                     ttft_ms => non_neg_integer()}.   %% 流式首个实际输出的时间（调用方附加）
-type error_reason() :: lg_llm_error:error()
                      | route_not_found | route_forbidden | no_available_target
                      | {plan_exhausted, non_neg_integer()}     %% 全部目标套餐额度用尽，到该时刻恢复
                      | {unsupported_operation, binary()}
                      | {middleware_rejected, pos_integer(), binary()}
                      | {rate_limited, lg_limiter:reason(), lg_limit_scope(), pos_integer()}
                      | {budget_exceeded, lg_budget_scope(), integer()}.
-export_type([ctx/0, outcome/0, error_reason/0]).


%%====================================================================
%% 路由计划门面
%%====================================================================

%% @doc Key 可调用的模型名（/v1/models）。
models(Key) -> lg_router_plan:models(Key).

%% @doc 解析请求的模型名；详见 lg_router_plan:resolve/2。
resolve(Key, Name) -> lg_router_plan:resolve(Key, Name).

%% @doc 生成尝试列表；详见 lg_router_plan:plan/4。
plan(Route) -> lg_router_plan:plan(Route).
plan(Route, Protocols) -> lg_router_plan:plan(Route, Protocols).
plan(Route, Protocols, Rest) -> lg_router_plan:plan(Route, Protocols, Rest).

%% @doc 路由当前的候选顺序；详见 lg_router_plan:candidates/1。
candidates(Route) -> lg_router_plan:candidates(Route).

%%====================================================================
%% 调用
%%====================================================================

-spec chat(lg_provider:format(), map(), ctx()) ->
          {ok, iodata(), outcome()} | {error, error_reason(), outcome()}.
chat(Client, Req, Ctx) ->
    run(Client, Req, Ctx, fun lg_provider:chat/3, #{cache => chat}).

%% @doc OpenAI embeddings：只使用 openai 协议的目标；计入限额、预算与计费。
-spec embeddings(map(), ctx()) -> {ok, iodata(), outcome()} | {error, error_reason(), outcome()}.
embeddings(Req, Ctx) ->
    run(openai, Req, Ctx, fun(_C, R, T) -> lg_provider:embeddings(R, T) end,
        #{protocols => [openai], clamp => false, op => <<"embeddings">>, cache => embeddings}).

%% @doc 图片生成：只使用 openai 协议的目标（凭证 media_api 决定上游格式）；计入限额、预算与计费（按张）。
-spec images(map(), ctx()) -> {ok, iodata(), outcome()} | {error, error_reason(), outcome()}.
images(Req, Ctx) ->
    run(openai, Req, Ctx, fun(_C, R, T) -> lg_media:images(R, T) end,
        #{protocols => [openai], clamp => false, op => <<"images">>}).

%% @doc 语音合成：只使用 openai 协议的目标；计入限额、预算与计费（按字符）。返回音频二进制。
-spec speech(map(), ctx()) -> {ok, iodata(), outcome()} | {error, error_reason(), outcome()}.
speech(Req, Ctx) ->
    run(openai, Req, Ctx, fun(_C, R, T) -> lg_media:speech(R, T) end,
        #{protocols => [openai], clamp => false, op => <<"speech">>}).

%% @doc 结构化决策（TypeSafe System One）：只使用 openai 协议的目标，透传到 {base}/systemone；
%% 计入限额、预算与计费（按输入 token）。
-spec systemone(map(), ctx()) -> {ok, iodata(), outcome()} | {error, error_reason(), outcome()}.
systemone(Req, Ctx) ->
    run(openai, Req, Ctx, fun(_C, R, T) -> lg_media:systemone(R, T) end,
        #{protocols => [openai], clamp => false, op => <<"systemone">>}).

%% @doc OpenAI Realtime WebRTC call：只使用开启原生 Responses API 的 OpenAI 目标；
%% 原始 multipart 请求透传，只替换 session.model。
-spec live(map(), ctx()) -> {ok, map(), outcome()} | {error, error_reason(), outcome()}.
live(Req, Ctx) ->
    run(openai, Req, Ctx, fun(_C, R, T) -> lg_provider:live(R, T) end,
        #{protocols => [openai], native_api => true, clamp => false, op => <<"live">>}).

%% @doc Anthropic count_tokens：只使用 anthropic 协议的目标；不占限额、不计费。
%% 路由没有 Anthropic 协议目标，或上游不支持该接口（404 / 405 / 501）时本地估算（outcome 带 estimated）。
-spec count_tokens(map(), ctx()) -> {ok, iodata(), outcome()} | {error, error_reason(), outcome()}.
count_tokens(Req, Ctx) ->
    case run(anthropic, Req, Ctx, fun(_C, R, T) -> lg_provider:count_tokens(R, T) end,
             #{protocols => [anthropic], admit => false, clamp => false, op => <<"count_tokens">>}) of
        {error, Reason, Out} ->
            case estimable(Reason) of
                true -> estimated(Req, Out);
                false -> {error, Reason, Out}
            end;
        {ok, Body, Out} = Ok ->
            %% 上游对非空请求返回 0（智谱按量 API 实测）：视为不可用，改用本地估算
            case catch json:decode(iolist_to_binary(Body)) of
                #{<<"input_tokens">> := 0} when Req =/= #{} -> estimated(Req, Out);
                _ -> Ok
            end
    end.

estimated(Req, Out) ->
    {ok, json:encode(#{<<"input_tokens">> => lg_tokens:estimate(Req)}), Out#{estimated => true}}.

estimable({unsupported_operation, _}) -> true;
estimable(#{status := S}) when S =:= 404; S =:= 405; S =:= 501 -> true;
estimable(_) -> false.

%% 原生 API（当前为 Realtime /v1/live）：要求凭证显式开启 responses_api，
%% 避免把实时请求发给仅兼容 Chat Completions 的上游。
native_targets(Plan, false) ->
    Plan;
native_targets(Plan, true) ->
    [P || {_, _, #lg_credential{options = O}} = P <- Plan,
          maps:get(responses_api, O, false) =:= true].

%% @doc 开流：上游返回 2xx 响应头之前的失败都会回退。
-spec stream_open(lg_provider:format(), map(), ctx()) ->
          {ok, term(), outcome()} | {error, error_reason(), outcome()}.
stream_open(Client, Req, Ctx) ->
    run(Client, Req, Ctx, fun(C, R, T) ->
                                  case lg_provider:stream_open(C, R, T) of
                                      {ok, S} -> {ok, S, undefined};
                                      Err -> Err
                                  end
                          end, #{}).

%% Opts：protocols（all | [协议]）、admit（是否占限额 / 查预算，默认 true）、
%%       clamp（是否按 Key 收紧 max_tokens，默认 true）、op（不支持时的操作名）、
%%       cache（chat | embeddings：该类请求可用响应缓存；流式与 count_tokens 不设）
run(Client, Req, #{key := Key} = Ctx, Call, Opts) ->
    Name = route_name(Req),
    Tags = maps:get(tags, Ctx, []),
    Out00 = #{route => Name, model => Name, key_id => Key#lg_api_key.id, user_id => Key#lg_api_key.user_id,
              tags => Tags, started_at => lg_time:now_ms(), attempts => []},
    Out0 = case maps:find(session, Ctx) of
               {ok, Sid} -> Out00#{session => Sid};
               error -> Out00
           end,
    Protocols = maps:get(protocols, Opts, all),
    case resolve(Key, Name) of
        {ok, #lg_route{name = RouteName} = Route, Rest} ->
            %% 限额、统计按路由（通配时为通配路由名）计算；model 记录客户端请求的名字
            Out0r = Out0#{route => RouteName},
            Admit = case maps:get(admit, Opts, true) of
                        true -> admit(Key, Tags, RouteName, Req);
                        false -> {ok, none}
                    end,
            case Admit of
                {ok, Ticket} ->
                    Out1 = case Ticket of none -> Out0r; _ -> Out0r#{ticket => Ticket} end,
                    Req1 = case maps:get(clamp, Opts, true) of
                               true -> clamp_max_tokens(Client, Req, Key);
                               false -> Req
                           end,
                    %% 规则路由（只对对话请求）：命中 use 时先发给那条路由，原路由接在后面；skip 时按凭证 id 或路由名去掉指定目标
                    Decision = case maps:is_key(new_turn, Ctx) of
                                   true -> lg_rules:decide(Route, Client, Req1, Ctx);
                                   false -> none
                               end,
                    PlanEnv = case maps:is_key(new_turn, Ctx) of
                                  true -> #{rules => {Client, Req1, Ctx}};
                                  false -> #{}
                              end,
                    put(lg_nested_rules, []),
                    {RulePlan, Out1d0} = apply_rule(Decision, Route, Protocols, Rest, PlanEnv, Out1),
                    Out1d = case erase(lg_nested_rules) of
                                [_ | _] = NR -> Out1d0#{nested_rules => [E || {_, E} <- NR]};
                                _ -> Out1d0
                            end,
                    case RulePlan of
                        [] ->
                            %% 有可用目标但协议都不支持该操作 → 400；根本没有可用目标 → 503
                            Reason = case Protocols =/= all andalso lg_router_plan:plan(Route, all, Rest) =/= [] of
                                         true -> {unsupported_operation, maps:get(op, Opts, <<>>)};
                                         false ->
                                             case lg_router_plan:exhausted_until(Route, Protocols, Rest) of
                                                 {ok, At} -> {plan_exhausted, At};
                                                 none -> no_available_target
                                             end
                                     end,
                            {error, Reason, Out1d};
                        Plan0 ->
                            %% 新的一轮命中 use 规则时，规则优先于会话粘性
                            {Plan1, Out2} = case Decision of
                                                #{rule := #{<<"use">> := _}} when map_get(new_turn, Ctx) ->
                                                    {Plan0, Out1d};
                                                _ -> sticky(Plan0, Route, Ctx, Out1d)
                                            end,
                            Plan0x = native_targets(Plan1, maps:get(native_api, Opts, false)),
                            Plan = prefer(Plan0x, maps:get(prefer, Ctx, undefined)),
                            Out3 = Out2#{plan_trace => trace(Plan)},
                            lg_live:decision(maps:get(id, Ctx, undefined),
                                             maps:filter(fun(_, V) -> V =/= undefined end,
                                                         #{route => RouteName, candidates => maps:get(plan_trace, Out3),
                                                           rule => maps:get(rule, Out3, undefined),
                                                           routed_to => maps:get(routed_to, Out3, undefined),
                                                           affinity => affinity_bin(maps:get(affinity, Out3, undefined))})),
                            CtxA = Ctx#{loop_guard => maps:get(loop_guard, Route#lg_route.options, true) =/= false},
                            cached(Route, Client, Req1, CtxA, Opts, Out3,
                                   fun() -> lg_router_attempt:attempt_rounds(Plan, Client, Req1, CtxA, Call, Out3, 0) end)
                    end;
                {error, Reason} ->
                    {error, Reason, Out0r}
            end;
        {error, Reason} ->
            {error, Reason, Out0}
    end.

apply_rule(none, Route, Protocols, Rest, Env, Out) ->
    {lg_router_plan:plan(Route, Protocols, Rest, Env), Out};
apply_rule(D, #lg_route{name = Self} = Route, Protocols, Rest, Env, Out) ->
    Base = lg_router_plan:plan(Route, Protocols, Rest, Env),
    Out1 = Out#{rule => maps:get(index, D, 0), rule_reused => maps:get(reused, D, false)},
    Out2 = case maps:find(intent, D) of
               {ok, I} -> Out1#{intent => I};
               error -> Out1
           end,
    case maps:get(rule, D, undefined) of
        #{<<"use">> := Use} when Use =/= Self ->
            case lg_routes:get(Use) of
                {ok, #lg_route{enabled = true} = R2} ->
                    Combined = lists:sublist(lg_router_plan:dedup(lg_router_plan:plan(R2, Protocols, Rest, Env) ++ Base), lg_config:get(route_max_attempts)),
                    {Combined, Out2#{routed_to => Use}};
                _ ->
                    {Base, Out2}
            end;
        #{<<"skip">> := Skip} ->
            %% skip 列表里可以是凭证 id，也可以是嵌套路由名（按目标所属路由名整体跳过）
            case [P || {N, _, #lg_credential{id = C}} = P <- Base,
                       not lists:member(C, Skip), not lists:member(N, Skip)] of
                [] -> {Base, Out2};          %% 全部被跳过时仍按原顺序，不让请求失败
                Kept -> {Kept, Out2}
            end;
        _ ->
            {Base, Out2}
    end.

%% @doc 意图判断：经网关自身调用判断模型路由（不检查 Key 的路由白名单与限额，花费计入该 Key 的预算），
%% 单独记一条日志（标签 litegate:intent）。超时返回 {error, <<"timeout">>}。
-spec classify(binary(), #{binary() => binary()}, ctx(), pos_integer()) -> {ok, binary()} | {error, binary()}.
classify(Name, #{<<"system">> := Sys, <<"user">> := User}, Ctx, Timeout) ->
    Req = #{<<"model">> => Name, <<"stream">> => false, <<"max_tokens">> => 1024, <<"temperature">> => 0,
            <<"messages">> => [#{<<"role">> => <<"system">>, <<"content">> => Sys},
                               #{<<"role">> => <<"user">>, <<"content">> => User}]},
    judge(chat, Name, Req, Ctx, Timeout).

%% @doc 意图判断（决策模型）：经网关自身调用 System One 路由，返回上游响应体；其余同 classify/4。
%% Body 为 #{state, questions}（见 lg_decision:request）。
-spec judge_systemone(binary(), map(), ctx(), pos_integer()) -> {ok, binary()} | {error, binary()}.
judge_systemone(Name, Body, Ctx, Timeout) ->
    judge(systemone, Name, Body#{<<"model">> => Name}, Ctx, Timeout).

judge(Kind, Name, Req, #{key := Key}, Timeout) ->
    case lg_routes:get(Name) of
        {ok, #lg_route{enabled = true} = R} ->
            Parent = self(),
            Ref = make_ref(),
            {Pid, MRef} = spawn_monitor(fun() -> Parent ! {Ref, classify_run(Kind, R, Req, Key)} end),
            receive
                {Ref, Res} ->
                    erlang:demonitor(MRef, [flush]),
                    Res;
                {'DOWN', MRef, process, Pid, _} ->
                    {error, <<"classifier crashed">>}
            after Timeout ->
                exit(Pid, kill),
                erlang:demonitor(MRef, [flush]),
                receive {Ref, _} -> ok after 0 -> ok end,
                {error, <<"timeout">>}
            end;
        _ ->
            {error, <<"classifier route not found">>}
    end.

classify_run(Kind, #lg_route{name = Name} = R, Req, Key) ->
    {Format, Protocols, Call} = case Kind of
                                    chat -> {openai, all, fun lg_provider:chat/3};
                                    systemone -> {systemone, [openai], fun(_C, Rq, T) -> lg_media:systemone(Rq, T) end}
                                end,
    Out0 = #{route => Name, model => Name, key_id => Key#lg_api_key.id, user_id => Key#lg_api_key.user_id,
             tags => [<<"litegate:intent">>], started_at => lg_time:now_ms(), attempts => []},
    {Res, Out} = case plan(R, Protocols) of
                     [] -> {{error, no_available_target}, Out0};
                     Plan ->
                         case lg_router_attempt:attempt(Plan, openai, Req, #{key => Key}, Call, Out0) of
                             {ok, Body, O} -> {{ok, Body}, O};
                             {error, E, O} -> {{error, E}, O}
                         end
                 end,
    Result = maps:get(result, Out, #{}),
    Status = case Res of
                 {ok, _} -> 200;
                 {error, #{status := S}} -> S;
                 {error, _} -> 503
             end,
    Log = maps:filter(fun(_, V) -> V =/= undefined end,
                      #{id => lg_store:new_id(), format => Format, stream => false, status => Status, source => gateway,
                        route => Name, model => Name, key_id => Key#lg_api_key.id, user_id => Key#lg_api_key.user_id,
                        attempts => length(maps:get(attempts, Out)), attempt_list => maps:get(attempts, Out),
                        duration_ms => lg_time:now_ms() - maps:get(started_at, Out),
                        credential => maps:get(credential, Out, undefined),
                        upstream_model => maps:get(upstream_model, Out, undefined),
                        model_ref => maps:get(model_ref, Out, undefined),
                        usage => maps:get(usage, Result, undefined), cost => maps:get(cost, Out, undefined),
                        plan => maps:get(plan, Out, undefined), plan_usd => maps:get(plan_usd, Out, undefined),
                        finish_reason => maps:get(finish_reason, Result, undefined),
                        tags => [<<"litegate:intent">>], client => <<"litegate">>,
                        error => case Res of
                                     {error, #{kind := K, message := M}} -> #{kind => K, message => M};
                                     {error, Other} -> #{kind => Other};
                                     {ok, _} -> undefined
                                 end}),
    Msgs = #{request => case Kind of
                            chat -> maps:with([<<"messages">>], Req);
                            systemone -> systemone_request(Req)
                        end,
             response => maps:get(text, Result, <<>>)},
    ok = lg_store:record(Log, Msgs),
    lg_otlp:submit(Log, Msgs, #{started_at => maps:get(started_at, Out)}),
    ok = done(Out),
    case Res of
        {ok, RespBody} when Kind =:= systemone -> {ok, iolist_to_binary(RespBody)};
        {ok, _} -> {ok, maps:get(text, Result, <<>>)};
        {error, #{message := Msg}} -> {error, Msg};
        {error, Other2} -> {error, iolist_to_binary(io_lib:format("~0p", [Other2]))}
    end.

%% @doc System One 请求在日志里的消息形式：state 作为用户消息（非文本时序列化为 JSON），附带问题表。
-spec systemone_request(map()) -> map().
systemone_request(Req) ->
    State = case maps:get(<<"state">>, Req, <<>>) of
                B when is_binary(B) -> B;
                #{<<"message">> := M} = St when is_binary(M), map_size(St) =:= 1 -> M;
                Other -> iolist_to_binary(json:encode(Other))
            end,
    #{<<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => State}],
      <<"questions">> => maps:get(<<"questions">>, Req, #{})}.

affinity_bin(undefined) -> undefined;
affinity_bin({broken, Why}) -> <<"broken:", Why/binary>>;
affinity_bin(A) when is_atom(A) -> atom_to_binary(A).

%% 路由决策记录：最终尝试顺序中每个候选的层与说明（套餐窗口、近期 token）
trace(Plan) ->
    [maps:merge(#{route => R, credential => C#lg_credential.id, upstream_model => maps:get(upstream_model, T),
                  tier => lg_router_plan:tier(T, C), note => lg_strategy:note(C)}, maps:with([via], T)) || {R, T, C} <- Plan].

%% 会话粘性（只对对话请求：Ctx 带 new_turn）
sticky(Plan, #lg_route{name = RouteName, options = Opts}, #{new_turn := NewTurn} = Ctx, Out) ->
    Mode = maps:get(affinity, Opts, <<"auto">>),
    Sid = maps:get(session, Ctx, undefined),
    Prev = case Sid of
               undefined -> undefined;
               _ -> lg_affinity:get(RouteName, Sid)
           end,
    {Plan1, Aff} = lg_affinity:choose(Plan, RouteName, Sid, Mode, NewTurn),
    Out1 = case Prev of
               #{target := {PC, PM}} = P ->
                   Out#{affinity_prev => #{credential => PC, upstream_model => PM, cache_read => maps:get(cache_read, P, 0)}};
               _ -> Out
           end,
    {Plan1, Out1#{affinity => Aff}};
sticky(Plan, _Route, _Ctx, Out) ->
    {Plan, Out}.


%% 指定目标优先（Responses 透传会话：上一次响应所在的上游持有会话状态）
prefer(Plan, undefined) ->
    Plan;
prefer(Plan, Key) ->
    {First, Rest} = lists:partition(fun({_, T, _}) -> lg_router_plan:tkey(T) =:= Key end, Plan),
    First ++ Rest.

%%====================================================================
%% 响应缓存
%%====================================================================

%% 路由 options.cache_ttl_s > 0 且请求类型可缓存时先查缓存；未命中则调用上游并缓存成功的结果。
%% 命中不访问上游：用量与费用记为 0，saved_usd 记录本应花费。客户端 cache-control: no-cache 跳过。
cached(#lg_route{options = Opts0}, Client, Req, Ctx, Opts, Out, Upstream) ->
    Ttl = maps:get(cache_ttl_s, Opts0, 0),
    Kind = maps:get(cache, Opts, undefined),
    case Kind =/= undefined andalso Ttl > 0 andalso not maps:get(no_cache, Ctx, false) of
        false ->
            Upstream();
        true ->
            Key = cache_key(maps:get(route, Out), Kind, Client, Req),
            case lg_store:cache_get(Key) of
                {ok, Entry} ->
                    lg_metrics:inc(litegate_cache_requests_total, [{route, maps:get(route, Out)}, {result, hit}]),
                    {ok, maps:get(body, Entry), hit_outcome(Out, Entry)};
                miss ->
                    lg_metrics:inc(litegate_cache_requests_total, [{route, maps:get(route, Out)}, {result, miss}]),
                    Res = Upstream(),
                    case Res of
                        {ok, Body, #{result := R} = Out1} ->
                            cacheable(R) andalso
                                lg_store:cache_put(Key, Ttl, #{body => iolist_to_binary(Body), result => R,
                                                               cost => maps:get(cost, Out1, 0.0),
                                                               credential => maps:get(credential, Out1, undefined),
                                                               upstream_model => maps:get(upstream_model, Out1, undefined)}),
                            Res;
                        _ ->
                            Res
                    end
            end
    end.

%% 只缓存正常结束的结果（截断、工具调用等也算正常；错误、中止不缓存）
cacheable(#{error := undefined, finish_reason := F}) ->
    lists:member(F, [null, <<"stop">>, <<"length">>, <<"end_turn">>, <<"max_tokens">>,
                     <<"stop_sequence">>, <<"tool_calls">>, <<"tool_use">>]);
cacheable(_) ->
    false.

hit_outcome(Out, #{result := R, cost := Cost} = Entry) ->
    Out1 = Out#{cache_hit => true, saved_usd => Cost, cost => 0.0,
                result => R#{usage => lg_usage:zero()},
                duration_ms => lg_time:now_ms() - maps:get(started_at, Out)},
    maps:merge(Out1, maps:filter(fun(K, V) -> V =/= undefined andalso
                                              (K =:= credential orelse K =:= upstream_model) end, Entry)).

%% 规范化：去掉不影响输出的字段；确定性编码保证同一请求得到同一个键
cache_key(Route, Kind, Client, Req) ->
    Canon = maps:without([<<"stream">>, <<"stream_options">>, <<"user">>, <<"metadata">>, <<"store">>], Req),
    crypto:hash(sha256, term_to_binary({Route, Kind, Client, Canon}, [deterministic])).

admit(#lg_api_key{id = KeyId} = Key, Tags, Route, Req) ->
    case lg_budget:check(Key, Tags) of
        ok -> lg_limiter:acquire(lg_limits:limits_for(KeyId, Route), lg_limiter:estimate_tokens(Req));
        {error, _} = Err -> Err
    end.

%% @doc 请求结束的收尾：归还限流占用并累计预算花费。每个请求恰好调用一次。
-spec done(outcome()) -> ok.
done(Out0) ->
    %% 兜底：仍持有的并发名额（正常情况下已在上游返回或 finalize 时释放）
    Out = lg_router_attempt:release_conc(Out0),
    Usage = maps:get(usage, maps:get(result, Out, #{}), lg_usage:zero()),
    case maps:find(ticket, Out) of
        {ok, T} -> lg_limiter:release(T, lg_usage:total(Usage));
        error -> ok
    end,
    lg_budget:add(maps:get(key_id, Out), maps:get(user_id, Out), maps:get(tags, Out, []), maps:get(cost, Out, 0.0)).


%% @doc 记录上游结果并按目录定价计费。
-spec finalize(map(), lg_stream:result()) -> map().
finalize(Out, Result) -> lg_router_attempt:finalize(Out, Result).

%%====================================================================
%% 请求调整
%%====================================================================

route_name(#{<<"model">> := M}) when is_binary(M) -> M;
route_name(_) -> <<>>.

%% Key 设了单次 max_tokens 上限时收紧（没给则补上限值）
clamp_max_tokens(_Client, Req, #lg_api_key{max_tokens = undefined}) ->
    Req;
clamp_max_tokens(openai, Req, #lg_api_key{max_tokens = Cap}) ->
    case {maps:get(<<"max_completion_tokens">>, Req, null), maps:get(<<"max_tokens">>, Req, null)} of
        {N, _} when is_integer(N) -> Req#{<<"max_completion_tokens">> => min(N, Cap)};
        {_, N} when is_integer(N) -> Req#{<<"max_tokens">> => min(N, Cap)};
        _ -> Req#{<<"max_tokens">> => Cap}
    end;
clamp_max_tokens(responses, Req, #lg_api_key{max_tokens = Cap}) ->
    case maps:get(<<"max_output_tokens">>, Req, null) of
        N when is_integer(N) -> Req#{<<"max_output_tokens">> => min(N, Cap)};
        _ -> Req#{<<"max_output_tokens">> => Cap}
    end;
clamp_max_tokens(anthropic, Req, #lg_api_key{max_tokens = Cap}) ->
    case maps:get(<<"max_tokens">>, Req, null) of
        N when is_integer(N) -> Req#{<<"max_tokens">> => min(N, Cap)};
        _ -> Req#{<<"max_tokens">> => Cap}
    end.

%% OpenAI 请求转 Anthropic 时 max_tokens 必填：取目录中模型的输出上限（封顶 16384）
default_max_tokens(#{model_ref := Ref}) ->
    case lg_catalog:model(Ref) of
        {ok, #{<<"limit">> := #{<<"output">> := N}}} when is_integer(N), N > 0 -> min(N, 16384);
        _ -> 4096
    end;
default_max_tokens(_) ->
    4096.
