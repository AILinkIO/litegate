%% @doc OTLP/HTTP（JSON）链路导出，兼容 Langfuse 的 OTel 接入。
%%
%% 一个请求一条 trace：父 span litegate.request；每次上游尝试一个子 span litegate.attempt（失败与回退的尝试也导出）；
%% 意图判断一个子 span litegate.intent。属性用 GenAI 语义约定（gen_ai.*），另带 Langfuse 专用属性
%% （langfuse.session.id、langfuse.user.id、langfuse.trace.tags、langfuse.observation.cost_details，费用只挂在成功的尝试上）。
%% 客户端带合法的 W3C traceparent（version 00）时接入其 trace。
%%
%% 运行参数：otlp_enabled、otlp_endpoint（基址，追加 /v1/traces）、otlp_headers（k=v 逗号分隔，值可百分号编码）、
%% otlp_bodies（是否带请求与回复内容，截断到 256KB）。
%% 攒批（≤ 1 秒或 100 个 span）发送，失败重试一次后丢弃；队列超过 10000 个 span 时丢弃新 span（litegate_otlp_dropped_total）。
-module(lg_otlp).
-behaviour(gen_server).

-export([start_link/0, submit/3, flush/0, test/0, spans/3, parse_traceparent/1, parse_headers/1, attrs/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include_lib("lg_core/include/lg_core.hrl").

-define(BATCH, 100).
-define(INTERVAL_MS, 1000).
-define(MAX_QUEUE, 10000).
-define(MAX_BODY, 262144).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc 投递一条请求日志（开启导出时）。Extra：traceparent、started_at、messages。
-spec submit(map(), map() | undefined, map()) -> ok.
submit(Log, Messages, Extra) ->
    case lg_config:get(otlp_enabled) =:= true andalso lg_config:get(otlp_endpoint) =/= <<>> of
        true ->
            Spans = try spans(Log, Messages, Extra)
                    catch C:R:St ->
                            logger:warning("otlp: building spans failed: ~p:~p ~p", [C, R, St]),
                            []
                    end,
            gen_server:cast(?MODULE, {spans, Spans});
        false ->
            ok
    end.

%% @doc 立即发送队列中的 span（测试用）。
-spec flush() -> ok | {error, term()}.
flush() ->
    gen_server:call(?MODULE, flush, 30000).

%% @doc 发送一个测试 span，同步返回结果。
-spec test() -> ok | {error, binary()}.
test() ->
    Now = erlang:system_time(nanosecond),
    Span = #{traceId => hex(crypto:strong_rand_bytes(16)), spanId => hex(crypto:strong_rand_bytes(8)),
             name => <<"litegate.test">>, kind => 1,
             startTimeUnixNano => integer_to_binary(Now - 1000000), endTimeUnixNano => integer_to_binary(Now),
             attributes => attrs(#{<<"litegate.test">> => true}), status => #{code => 1}},
    case send([Span]) of
        ok -> ok;
        {error, R} -> {error, iolist_to_binary(io_lib:format("~0p", [R]))}
    end.

%%====================================================================
%% span 构造
%%====================================================================

%% @doc 由请求日志构造 span 列表（父 span 在前）。
-spec spans(map(), map() | undefined, map()) -> [map()].
spans(Log, Messages, Extra) ->
    EndMs = maps:get(ended_at, Extra, lg_time:now_ms()),
    StartMs = maps:get(started_at, Extra, EndMs - maps:get(duration_ms, Log, 0)),
    {TraceId, ParentOfRoot} = case parse_traceparent(maps:get(traceparent, Extra, undefined)) of
                                  {ok, T, P} -> {T, P};
                                  error -> {hex(crypto:strong_rand_bytes(16)), undefined}
                              end,
    RootId = hex(crypto:strong_rand_bytes(8)),
    Status = maps:get(status, Log, 200),
    KeyName = key_name(maps:get(key_id, Log, undefined)),
    Bodies = lg_config:get(otlp_bodies) =:= true andalso Messages =/= undefined,
    RootAttrs = #{<<"litegate.request_id">> => maps:get(id, Log, <<>>),
                  <<"litegate.route">> => maps:get(route, Log, <<>>),
                  <<"litegate.model">> => maps:get(model, Log, <<>>),
                  <<"litegate.format">> => maps:get(format, Log, <<>>),
                  <<"litegate.client">> => maps:get(client, Log, undefined),
                  <<"litegate.stream">> => maps:get(stream, Log, false),
                  <<"litegate.cache_hit">> => maps:get(cache_hit, Log, false),
                  <<"http.response.status_code">> => Status,
                  <<"langfuse.trace.name">> => maps:get(route, Log, <<>>),
                  <<"langfuse.user.id">> => KeyName,
                  <<"langfuse.session.id">> => maps:get(session, Log, undefined),
                  <<"langfuse.trace.tags">> => maps:get(tags, Log, undefined),
                  <<"litegate.rule">> => maps:get(rule, Log, undefined),
                  <<"litegate.routed_to">> => maps:get(routed_to, Log, undefined),
                  <<"langfuse.trace.input">> => body_text(Bodies, request, Messages),
                  <<"langfuse.trace.output">> => body_text(Bodies, response, Messages)},
    Root = span(TraceId, RootId, ParentOfRoot, <<"litegate.request">>, 2, StartMs, EndMs, RootAttrs,
                status(Status, maps:get(error, Log, undefined))),
    Attempts = case maps:get(attempt_list, Log, []) of
                   L when is_list(L) -> L;
                   _ -> []
               end,
    N = length(Attempts),
    AttemptSpans = [attempt_span(TraceId, RootId, A, I =:= N andalso maps:get(ok, A, false), Log, Bodies, Messages)
                    || {I, A} <- lists:enumerate(Attempts)],
    IntentSpans = case maps:get(intent, Log, undefined) of
                      #{ms := Ms} = I when is_integer(Ms), Ms > 0 ->
                          [span(TraceId, hex(crypto:strong_rand_bytes(8)), RootId, <<"litegate.intent">>, 3,
                                StartMs, StartMs + Ms,
                                #{<<"litegate.intent.answer">> => maps:get(answer, I, undefined),
                                  <<"litegate.intent.error">> => maps:get(error, I, undefined)},
                                #{code => 0})];
                      _ -> []
                  end,
    [Root | IntentSpans ++ AttemptSpans].

attempt_span(TraceId, RootId, A, Final, Log, Bodies, Messages) ->
    Start = maps:get(started_at, A, 0),
    End = Start + maps:get(duration_ms, A, 0),
    Cred = maps:get(credential, A, <<>>),
    Base = #{<<"litegate.credential">> => Cred,
             <<"litegate.credential_name">> => cred_name(Cred),
             <<"litegate.route">> => maps:get(route, A, <<>>),
             <<"litegate.outcome">> => case A of
                                           #{busy := true} -> <<"busy">>;
                                           #{ok := true} -> <<"ok">>;
                                           _ -> maps:get(kind, A, <<"error">>)
                                       end,
             <<"gen_ai.system">> => gen_ai_system(Cred),
             <<"gen_ai.request.model">> => maps:get(model, Log, <<>>),
             <<"gen_ai.response.model">> => maps:get(upstream_model, A, <<>>)},
    Attrs = case Final of
                true -> maps:merge(Base, final_attrs(Log, Bodies, Messages));
                false -> Base
            end,
    St = case maps:get(ok, A, false) of
             true -> #{code => 1};
             false -> #{code => 2, message => maps:get(message, A, <<"attempt failed">>)}
         end,
    span(TraceId, hex(crypto:strong_rand_bytes(8)), RootId, <<"litegate.attempt">>, 3, Start, End, Attrs, St).

%% 最终成功的尝试：用量、首 token 时间、费用（Langfuse cost_details）、内容
final_attrs(Log, Bodies, Messages) ->
    U = maps:get(usage, Log, #{}),
    Cost = case maps:get(plan, Log, false) of
               true -> maps:get(plan_usd, Log, undefined);
               _ -> maps:get(cost, Log, undefined)
           end,
    Details = cost_details(maps:get(model_ref, Log, undefined), U, Cost),
    #{<<"gen_ai.usage.input_tokens">> => maps:get(input, U, undefined),
      <<"gen_ai.usage.output_tokens">> => maps:get(output, U, undefined),
      <<"gen_ai.usage.cache_read_input_tokens">> => maps:get(cache_read, U, undefined),
      <<"gen_ai.usage.cache_creation_input_tokens">> => maps:get(cache_write, U, undefined),
      <<"gen_ai.usage.reasoning_tokens">> => maps:get(reasoning, U, undefined),
      <<"gen_ai.response.finish_reasons">> => case maps:get(finish_reason, Log, undefined) of
                                                   F when is_binary(F) -> [F];
                                                   _ -> undefined
                                               end,
      <<"litegate.ttft_ms">> => maps:get(ttft_ms, Log, undefined),
      <<"langfuse.observation.type">> => <<"generation">>,
      <<"langfuse.observation.model.name">> => model_name(Log),
      <<"langfuse.observation.usage_details">> =>
          case U of
              #{input := I, output := O} -> json_text(#{input => I, output => O, total => I + O});
              _ -> undefined
          end,
      <<"langfuse.observation.cost_details">> => Details,
      <<"langfuse.observation.input">> => body_text(Bodies, request, Messages),
      <<"langfuse.observation.output">> => body_text(Bodies, response, Messages)}.

model_name(#{model_ref := {_, M}}) -> M;
model_name(Log) -> maps:get(upstream_model, Log, undefined).

%% 按目录定价拆分输入 / 输出费用（输入含缓存读写）；没有计费参考（价格未知，网关记为 0）时不发，由 Langfuse 自行计价
cost_details(undefined, _U, _Cost) ->
    undefined;
cost_details(Ref, U, Cost) when is_number(Cost), is_map(U), map_size(U) > 0 ->
    case lg_catalog:pricing(Ref) of
        {ok, #{input := PIn, output := POut, cache_read := PCR, cache_write := PCW}} ->
            In = (maps:get(input, U, 0) * PIn + maps:get(cache_read, U, 0) * PCR
                  + maps:get(cache_write, U, 0) * PCW) / 1.0e6,
            Out = maps:get(output, U, 0) * POut / 1.0e6,
            json_text(#{input => In, output => Out, total => Cost});
        _ ->
            json_text(#{total => Cost})
    end;
cost_details(_, _, _) ->
    undefined.

body_text(false, _, _) -> undefined;
body_text(true, request, #{request := R}) -> clip(iolist_to_binary(json:encode(R)));
body_text(true, response, #{response := R}) when is_binary(R) -> clip(R);
body_text(_, _, _) -> undefined.

clip(B) when byte_size(B) > ?MAX_BODY -> binary:part(B, 0, ?MAX_BODY);
clip(B) -> B.

json_text(M) -> iolist_to_binary(json:encode(M)).

status(Status, _Err) when Status < 400 -> #{code => 1};
status(_Status, #{message := M}) when is_binary(M) -> #{code => 2, message => M};
status(Status, _) -> #{code => 2, message => <<"HTTP ", (integer_to_binary(Status))/binary>>}.

span(TraceId, SpanId, Parent, Name, Kind, StartMs, EndMs, Attrs, Status) ->
    S = #{traceId => TraceId, spanId => SpanId, name => Name, kind => Kind,
          startTimeUnixNano => integer_to_binary(StartMs * 1000000),
          endTimeUnixNano => integer_to_binary(max(StartMs, EndMs) * 1000000),
          attributes => attrs(Attrs), status => Status},
    case Parent of
        undefined -> S;
        _ -> S#{parentSpanId => Parent}
    end.

attrs(M) ->
    [#{key => K, value => value(V)} || {K, V} <- lists:sort(maps:to_list(M)), V =/= undefined, V =/= null].

value(true) -> #{boolValue => true};
value(false) -> #{boolValue => false};
value(V) when is_integer(V) -> #{intValue => integer_to_binary(V)};
value(V) when is_float(V) -> #{doubleValue => V};
value(V) when is_binary(V) -> #{stringValue => V};
value(V) when is_atom(V) -> #{stringValue => atom_to_binary(V)};
value(L) when is_list(L) -> #{arrayValue => #{values => [value(X) || X <- L]}};
value(V) -> #{stringValue => iolist_to_binary(io_lib:format("~0p", [V]))}.

key_name(undefined) -> undefined;
key_name(Id) ->
    case catch lg_api_keys:get(Id) of
        {ok, #lg_api_key{name = N}} -> N;
        _ -> Id
    end.

cred_name(Id) ->
    case catch lg_credentials:get(Id) of
        {ok, #lg_credential{name = N}} -> N;
        _ -> undefined
    end.

gen_ai_system(Id) ->
    case catch lg_credentials:get(Id) of
        {ok, #lg_credential{provider = P}} when is_binary(P) -> P;
        {ok, #lg_credential{protocol = Proto}} -> atom_to_binary(Proto);
        _ -> undefined
    end.

%% @doc W3C traceparent（version 00）：{ok, TraceIdHex, ParentSpanIdHex} | error。
-spec parse_traceparent(term()) -> {ok, binary(), binary()} | error.
parse_traceparent(V) when is_binary(V) ->
    case re:run(string:lowercase(V), "^00-([0-9a-f]{32})-([0-9a-f]{16})-[0-9a-f]{2}$", [{capture, all_but_first, binary}]) of
        {match, [T, P]} when T =/= <<"00000000000000000000000000000000">>, P =/= <<"0000000000000000">> -> {ok, T, P};
        _ -> error
    end;
parse_traceparent(_) ->
    error.

%% @doc "k=v,k2=v%20x" → [{k, v}]（值百分号解码）。
-spec parse_headers(binary()) -> [{binary(), binary()}].
parse_headers(B) ->
    [{string:lowercase(string:trim(K)), uri_string:percent_decode(string:trim(V))}
     || P <- binary:split(B, <<",">>, [global]), [K, V] <- [binary:split(P, <<"=">>)], string:trim(K) =/= <<>>].

hex(B) -> binary:encode_hex(B, lowercase).

%%====================================================================
%% 发送
%%====================================================================

send(Spans) ->
    Endpoint = string:trim(lg_config:get(otlp_endpoint), trailing, "/"),
    Url = <<Endpoint/binary, "/v1/traces">>,
    Body = json:encode(#{resourceSpans =>
                             [#{resource => #{attributes => attrs(#{<<"service.name">> => <<"litegate">>})},
                                scopeSpans => [#{scope => #{name => <<"litegate">>}, spans => Spans}]}]}),
    H = [{<<"content-type">>, <<"application/json">>} | parse_headers(lg_config:get(otlp_headers))],
    case lg_http:request(<<"POST">>, Url, H, Body, 10000) of
        {ok, _, _, _} -> ok;
        {error, R} -> {error, R}
    end.

init([]) ->
    _ = erlang:send_after(?INTERVAL_MS, self(), tick),
    {ok, #{queue => [], len => 0}}.

handle_call(flush, _From, S) ->
    {Res, S1} = do_flush(S),
    {reply, Res, S1}.

handle_cast({spans, New}, #{len := Len} = S) when Len + length(New) > ?MAX_QUEUE ->
    lg_metrics:inc(litegate_otlp_dropped_total, [], length(New)),
    {noreply, S};
handle_cast({spans, New}, #{queue := Q, len := Len} = S) ->
    S1 = S#{queue => lists:reverse(New, Q), len => Len + length(New)},
    case Len + length(New) >= ?BATCH of
        true -> {_, S2} = do_flush(S1), {noreply, S2};
        false -> {noreply, S1}
    end.

handle_info(tick, S) ->
    {_, S1} = do_flush(S),
    _ = erlang:send_after(?INTERVAL_MS, self(), tick),
    {noreply, S1};
handle_info(_Msg, S) ->
    {noreply, S}.

do_flush(#{len := 0} = S) ->
    {ok, S};
do_flush(#{queue := Q, len := Len} = S) ->
    Spans = lists:reverse(Q),
    Res = case send(Spans) of
              ok -> ok;
              {error, _} -> send(Spans)          %% 重试一次
          end,
    case Res of
        ok -> lg_metrics:inc(litegate_otlp_exported_total, [], Len);
        {error, R} ->
            lg_metrics:inc(litegate_otlp_dropped_total, [], Len),
            logger:warning("otlp: export of ~b spans failed: ~0p", [Len, R])
    end,
    {Res, S#{queue => [], len => 0}}.
