%% @doc 流式响应处理：逐个 SSE 事件输入，输出客户端格式的 SSE 帧，同时累计用量与文本。
%%
%% 四种组合：
%%   openai → openai        原样转发（剥掉网关为计费注入的 usage 块）
%%   anthropic → anthropic  原样转发
%%   anthropic → openai     message_start/content_block_*/message_delta → chat.completion.chunk
%%   openai → anthropic     chunk → message_start/content_block_*/message_delta/message_stop
%%
%% 用法：S0 = new(Opts)，{Frames, S1} = feed(Event, S0) ...，{Frames, Result} = finish(Sn)。
%% 调用方已解码事件时用 feed_decoded/3（每个上游事件只解码一次）；map_output/1 让 openai 客户端的输出
%% 改为 Chat chunk map（不编码，供 Responses 转换的第二级直接消费），[DONE] 帧不输出。
-module(lg_stream).

-export([looped/1, new/1, feed/2, feed_decoded/3, map_output/1, finish/1, output_started/1]).

-type format() :: openai | anthropic.
-type opts() :: #{client := format(), upstream := format(),
                  include_usage => boolean(),   %% 客户端要求 stream_options.include_usage
                  strip_usage => boolean(),     %% usage 块是网关注入的，不转发给客户端
                  loop_guard => boolean()}.     %% 复读检测开关（默认关）
-type result() :: #{usage := lg_usage:usage(), text := binary(),
                    finish_reason := binary() | null, model := binary(), id := binary(),
                    error := map() | undefined}.
%% 同协议透传时转发的原始帧；{encode, Event} 表示事件已被改写（think 拆分 / 结构化输出），按解码后的 map 重新编码
-type raw() :: binary() | {encode, binary() | undefined}.
-export_type([opts/0, result/0, raw/0]).

-record(st, {
    client :: format(),
    upstream :: format(),
    include_usage = false :: boolean(),
    strip_usage = false :: boolean(),
    id = <<>> :: binary(),
    model = <<>> :: binary(),
    created = 0 :: integer(),
    text = [] :: iodata(),
    output = false :: boolean(),            %% 已出现首个实际输出（文本 / 推理 / 工具调用）
    finish = null :: binary() | null,
    usage_oa = null :: map() | null,        %% OpenAI 上游的 usage
    usage_an = #{} :: map(),                %% Anthropic 上游的累计 usage
    error :: map() | undefined,
    %% anthropic → openai：内容块 index → OpenAI tool_calls index
    tool_idx = #{} :: #{integer() => non_neg_integer()},
    %% openai → anthropic：当前打开的内容块与下一个块 index
    started = false :: boolean(),
    block = none :: none | text | thinking | {tool, non_neg_integer()},
    next_block = 0 :: non_neg_integer(),
    %% 复读检测：loop 为 lg_loop 状态；an_open 为 Anthropic 同协议透传时尚未关闭的内容块
    loop :: lg_loop:state() | undefined,
    an_open = none :: none | integer(),
    out = frames :: frames | map            %% map：openai 客户端输出 Chat chunk map 而非 SSE 帧
}).

-spec new(opts()) -> #st{}.
new(#{client := C, upstream := U} = Opts) ->
    #st{client = C, upstream = U,
        include_usage = maps:get(include_usage, Opts, false),
        strip_usage = maps:get(strip_usage, Opts, false),
        created = erlang:system_time(second),
        loop = case maps:get(loop_guard, Opts, false) of
                   true -> lg_loop:new();
                   false -> undefined
               end}.

%% @doc 是否已判定为复读（调用方随后结束上游流并调用 finish/1）。
-spec looped(#st{}) -> boolean().
looped(#st{loop = L}) -> lg_loop:looped(L).

%% @doc openai 客户端的输出改为 Chat chunk map（见模块说明）。
-spec map_output(#st{}) -> #st{}.
map_output(#st{client = openai} = S) -> S#st{out = map}.

-spec feed(lg_sse:event(), #st{}) -> {[iodata() | map()], #st{}}.
feed(#{data := Data, raw := Raw}, S) ->
    %% 结束帧（[DONE]）统一由 finish/1 产生；非 JSON 事件忽略
    J = case Data of
            undefined -> undefined;
            <<"[DONE]">> -> undefined;
            _ -> try json:decode(Data) catch error:_ -> undefined end
        end,
    feed_decoded(Raw, J, S).

%% @doc 已解码的事件：Raw 为同协议透传时转发的帧，J 为解码后的 data（[DONE]、无 data、非 JSON 时为 undefined）。
-spec feed_decoded(raw(), term(), #st{}) -> {[iodata() | map()], #st{}}.
feed_decoded(Raw, J, #st{loop = L} = S) when L =/= undefined ->
    case lg_loop:looped(L) of
        true -> {[], S};
        false -> feed1(Raw, J, S)
    end;
feed_decoded(Raw, J, S) ->
    feed1(Raw, J, S).

feed1(Raw, J, S) when is_map(J) -> handle(J, Raw, S);
feed1(_Raw, _J, S) -> {[], S}.

-spec finish(#st{}) -> {[iodata() | map()], result()}.
%% 判定为复读后结束：按客户端格式补齐结束帧，结束原因为长度上限
finish(#st{loop = L} = S0) when L =/= undefined ->
    case lg_loop:looped(L) of
        true -> finish_looped(S0#st{loop = undefined});
        false -> finish(S0#st{loop = undefined})
    end;
finish(#st{client = openai, upstream = openai} = S) ->
    {done(S), result(S)};
finish(#st{client = anthropic, upstream = anthropic} = S) ->
    {[], result(S)};
finish(#st{client = openai, upstream = anthropic, include_usage = Inc} = S) ->
    UsageFrame = case Inc of
                     true -> [chunk(S, [], #{<<"usage">> => lg_usage:to_openai(usage(S))})];
                     false -> []
                 end,
    {UsageFrame ++ done(S), result(S)};
finish(#st{client = anthropic, upstream = openai} = S0) ->
    {Start, S1} = ensure_started(S0),
    {Close, S2} = close_block(S1),
    Usage = lg_usage:to_anthropic(usage(S2)),
    Delta = event(<<"message_delta">>,
                  #{<<"delta">> => #{<<"stop_reason">> => lg_conv_resp:finish_o2a(S2#st.finish),
                                     <<"stop_sequence">> => null},
                    <<"usage">> => Usage}),
    Stop = event(<<"message_stop">>, #{}),
    {Start ++ Close ++ [Delta, Stop], result(S2)}.

finish_looped(#st{client = openai} = S0) ->
    S = S0#st{finish = <<"length">>},
    Stop = chunk(S, [#{<<"index">> => 0, <<"delta">> => #{}, <<"finish_reason">> => <<"length">>}]),
    {Tail, R} = finish(S),
    {[Stop | Tail], R#{loop_detected => true}};
finish_looped(#st{client = anthropic, upstream = anthropic, an_open = Open} = S0) ->
    S = S0#st{finish = <<"max_tokens">>},
    Close = case Open of
                none -> [];
                I -> [event(<<"content_block_stop">>, #{<<"index">> => I})]
            end,
    Delta = event(<<"message_delta">>,
                  #{<<"delta">> => #{<<"stop_reason">> => <<"max_tokens">>, <<"stop_sequence">> => null},
                    <<"usage">> => #{<<"output_tokens">> => maps:get(output, usage(S), 0)}}),
    {Close ++ [Delta, event(<<"message_stop">>, #{})], (result(S))#{loop_detected => true}};
finish_looped(#st{client = anthropic} = S) ->
    {Frames, R} = finish(S#st{finish = <<"length">>}),
    {Frames, R#{loop_detected => true}}.

%%====================================================================
%% 各组合的事件处理
%%====================================================================

%% openai → openai：原样转发
handle(J, Raw, #st{client = openai, upstream = openai} = S0) ->
    S = acc_openai(J, S0),
    Frames = case J of
                 #{<<"choices">> := [], <<"usage">> := U} when is_map(U), S#st.strip_usage -> [];
                 _ when S#st.out =:= map -> [J];
                 _ -> [raw(Raw, J)]
             end,
    {Frames, S};

%% anthropic → anthropic：原样转发。message_start 之前的 ping 丢弃（百炼 Anthropic 接口实测会先发 ping，
%% 官方接口总是先发 message_start，部分客户端依赖这个顺序）
handle(#{<<"type">> := <<"ping">>}, _Raw, #st{client = anthropic, upstream = anthropic, started = false} = S) ->
    {[], S};
handle(J, Raw, #st{client = anthropic, upstream = anthropic} = S) ->
    Started = S#st.started orelse maps:get(<<"type">>, J, undefined) =:= <<"message_start">>,
    Open = case J of
               #{<<"type">> := <<"content_block_start">>, <<"index">> := I} -> I;
               #{<<"type">> := <<"content_block_stop">>} -> none;
               _ -> S#st.an_open
           end,
    {[raw(Raw, J)], acc_anthropic(J, S#st{started = Started, an_open = Open})};

%% anthropic → openai
handle(#{<<"type">> := <<"message_start">>} = J, _Raw, #st{client = openai} = S0) ->
    S = acc_anthropic(J, S0),
    {[chunk(S, [delta(#{<<"role">> => <<"assistant">>, <<"content">> => <<>>})])], S};
handle(#{<<"type">> := <<"content_block_start">>, <<"index">> := I,
         <<"content_block">> := #{<<"type">> := <<"tool_use">>} = B}, _Raw,
       #st{client = openai, tool_idx = TI} = S) ->
    N = maps:size(TI),
    Call = #{<<"index">> => N, <<"id">> => maps:get(<<"id">>, B, <<>>),
             <<"type">> => <<"function">>,
             <<"function">> => #{<<"name">> => maps:get(<<"name">>, B, <<>>),
                                 <<"arguments">> => <<>>}},
    {[chunk(S, [delta(#{<<"tool_calls">> => [Call]})])], S#st{tool_idx = TI#{I => N}}};
handle(#{<<"type">> := <<"content_block_delta">>, <<"index">> := I, <<"delta">> := D} = J, _Raw,
       #st{client = openai, tool_idx = TI} = S0) ->
    S = acc_anthropic(J, S0),
    case D of
        #{<<"type">> := <<"text_delta">>, <<"text">> := T} ->
            {[chunk(S, [delta(#{<<"content">> => T})])], S};
        #{<<"type">> := <<"thinking_delta">>, <<"thinking">> := T} ->
            {[chunk(S, [delta(#{<<"reasoning_content">> => T})])], S};
        #{<<"type">> := <<"input_json_delta">>, <<"partial_json">> := P} when is_map_key(I, TI) ->
            Call = #{<<"index">> => maps:get(I, TI),
                     <<"function">> => #{<<"arguments">> => P}},
            {[chunk(S, [delta(#{<<"tool_calls">> => [Call]})])], S};
        _ ->
            {[], S}
    end;
handle(#{<<"type">> := <<"message_delta">>} = J, _Raw, #st{client = openai} = S0) ->
    S = acc_anthropic(J, S0),
    Choice = #{<<"index">> => 0, <<"delta">> => #{},
               <<"finish_reason">> => lg_conv_resp:finish_a2o(S#st.finish)},
    {[chunk(S, [Choice])], S};
handle(#{<<"type">> := <<"error">>, <<"error">> := E}, _Raw, #st{client = openai} = S) ->
    {[data_frame(S, #{<<"error">> => E})], S#st{error = E}};
handle(_J, _Raw, #st{client = openai, upstream = anthropic} = S) ->
    {[], S};

%% openai → anthropic
handle(#{<<"error">> := E}, _Raw, #st{client = anthropic} = S) when is_map(E) ->
    Err = #{<<"type">> => <<"api_error">>,
            <<"message">> => maps:get(<<"message">>, E, <<"upstream error">>)},
    {[event(<<"error">>, #{<<"error">> => Err})], S#st{error = E}};
handle(J, _Raw, #st{client = anthropic} = S0) ->
    S1 = acc_openai(J, S0),
    {Start, S2} = ensure_started(S1),
    Delta = case maps:get(<<"choices">>, J, []) of
                [#{<<"delta">> := D} | _] when is_map(D) -> D;
                _ -> #{}
            end,
    {Frames, S3} = o2a_delta(Delta, S2),
    {Start ++ Frames, S3}.

o2a_delta(D, S0) ->
    {F1, S1} = case maps:get(<<"reasoning_content">>, D, null) of
                   R when is_binary(R), R =/= <<>> ->
                       block_delta(thinking, #{<<"type">> => <<"thinking_delta">>,
                                               <<"thinking">> => R}, S0);
                   _ -> {[], S0}
               end,
    {F2, S2} = case maps:get(<<"content">>, D, null) of
                   T when is_binary(T), T =/= <<>> ->
                       block_delta(text, #{<<"type">> => <<"text_delta">>, <<"text">> => T}, S1);
                   _ -> {[], S1}
               end,
    {F3, S3} = lists:foldl(fun(TC, {Acc, S}) ->
                                   {F, S4} = o2a_tool(TC, S),
                                   {Acc ++ F, S4}
                           end, {[], S2}, list(maps:get(<<"tool_calls">>, D, []))),
    {F1 ++ F2 ++ F3, S3}.

o2a_tool(TC, #st{block = Block} = S0) ->
    OIdx = maps:get(<<"index">>, TC, 0),
    Fn = maps:get(<<"function">>, TC, #{}),
    {Open, S1} = case {Block, maps:get(<<"id">>, TC, null)} of
                     {{tool, OIdx}, _} ->
                         {[], S0};
                     {_, _} ->
                         Start = #{<<"type">> => <<"tool_use">>,
                                   <<"id">> => id_or(maps:get(<<"id">>, TC, null), OIdx),
                                   <<"name">> => maps:get(<<"name">>, Fn, <<>>),
                                   <<"input">> => #{}},
                         open_block({tool, OIdx}, Start, S0)
                 end,
    case maps:get(<<"arguments">>, Fn, <<>>) of
        A when is_binary(A), A =/= <<>> ->
            {Open ++ [event(<<"content_block_delta">>,
                            #{<<"index">> => S1#st.next_block - 1,
                              <<"delta">> => #{<<"type">> => <<"input_json_delta">>,
                                               <<"partial_json">> => A}})], S1};
        _ ->
            {Open, S1}
    end.

%% 写入 text / thinking 块，必要时先关闭当前块再打开新块
block_delta(Kind, Delta, #st{block = Kind} = S) ->
    {[event(<<"content_block_delta">>, #{<<"index">> => S#st.next_block - 1,
                                          <<"delta">> => Delta})], S};
block_delta(Kind, Delta, S0) ->
    Start = case Kind of
                text -> #{<<"type">> => <<"text">>, <<"text">> => <<>>};
                thinking -> #{<<"type">> => <<"thinking">>, <<"thinking">> => <<>>}
            end,
    {Open, S1} = open_block(Kind, Start, S0),
    {Frames, S2} = block_delta(Kind, Delta, S1),
    {Open ++ Frames, S2}.

open_block(Kind, StartBlock, S0) ->
    {Close, S1} = close_block(S0),
    Idx = S1#st.next_block,
    Start = event(<<"content_block_start">>, #{<<"index">> => Idx,
                                               <<"content_block">> => StartBlock}),
    {Close ++ [Start], S1#st{block = Kind, next_block = Idx + 1}}.

close_block(#st{block = none} = S) ->
    {[], S};
close_block(#st{next_block = N} = S) ->
    {[event(<<"content_block_stop">>, #{<<"index">> => N - 1})], S#st{block = none}}.

ensure_started(#st{started = true} = S) ->
    {[], S};
ensure_started(S) ->
    Msg = #{<<"id">> => S#st.id, <<"type">> => <<"message">>, <<"role">> => <<"assistant">>,
            <<"model">> => S#st.model, <<"content">> => [],
            <<"stop_reason">> => null, <<"stop_sequence">> => null,
            <<"usage">> => #{<<"input_tokens">> => 0, <<"output_tokens">> => 0}},
    {[event(<<"message_start">>, #{<<"message">> => Msg})], S#st{started = true}}.

%%====================================================================
%% 累计（用量、文本、结束原因）
%%====================================================================

%% 累积文本处 binary:copy：json:decode 返回的字符串是输入的 sub-binary，直接累积会钉住整块上游数据
acc_openai(J, S) ->
    S1 = S#st{id = keep(S#st.id, maps:get(<<"id">>, J, null)),
              model = keep(S#st.model, maps:get(<<"model">>, J, null))},
    S2 = case maps:get(<<"usage">>, J, null) of
             U when is_map(U) -> S1#st{usage_oa = U};
             _ -> S1
         end,
    case maps:get(<<"choices">>, J, []) of
        [C | _] when is_map(C) ->
            D = maps:get(<<"delta">>, C, #{}),
            S3a = case is_map(D) andalso maps:get(<<"content">>, D, null) of
                      T when is_binary(T) -> loop_feed(T, S2#st{text = [S2#st.text, binary:copy(T)]});
                      _ -> S2
                  end,
            S3 = case is_map(D) andalso maps:get(<<"reasoning_content">>, D, null) of
                     RT when is_binary(RT) -> loop_feed(RT, S3a);
                     _ -> S3a
                 end,
            S3o = S3#st{output = S3#st.output orelse delta_has_output(D)},
            case maps:get(<<"finish_reason">>, C, null) of
                F when is_binary(F) -> S3o#st{finish = F};
                _ -> S3o
            end;
        _ ->
            S2
    end.

acc_anthropic(#{<<"type">> := <<"message_start">>, <<"message">> := M}, S) ->
    S#st{id = maps:get(<<"id">>, M, <<>>), model = maps:get(<<"model">>, M, <<>>),
         usage_an = lg_usage:merge_anthropic(S#st.usage_an, maps:get(<<"usage">>, M, null))};
acc_anthropic(#{<<"type">> := <<"content_block_delta">>,
                <<"delta">> := #{<<"type">> := <<"text_delta">>, <<"text">> := T}}, S) ->
    loop_feed(T, S#st{text = [S#st.text, binary:copy(T)], output = S#st.output orelse T =/= <<>>});
acc_anthropic(#{<<"type">> := <<"content_block_delta">>,
                <<"delta">> := #{<<"type">> := <<"thinking_delta">>, <<"thinking">> := T}}, S) when is_binary(T) ->
    loop_feed(T, S#st{output = true});
acc_anthropic(#{<<"type">> := <<"content_block_delta">>}, S) ->
    %% thinking_delta / input_json_delta 等也算首个输出
    S#st{output = true};
acc_anthropic(#{<<"type">> := <<"message_delta">>} = J, S) ->
    Finish = case maps:get(<<"delta">>, J, #{}) of
                 #{<<"stop_reason">> := R} when is_binary(R) -> R;
                 _ -> S#st.finish
             end,
    S#st{finish = Finish,
         usage_an = lg_usage:merge_anthropic(S#st.usage_an, maps:get(<<"usage">>, J, null))};
acc_anthropic(#{<<"type">> := <<"error">>, <<"error">> := E}, S) ->
    S#st{error = E};
acc_anthropic(_, S) ->
    S.

loop_feed(_T, #st{loop = undefined} = S) -> S;
loop_feed(T, #st{loop = L} = S) -> S#st{loop = lg_loop:feed(T, L)}.

%% @doc 是否已出现首个实际输出（用于 TTFT；只含角色的首块、message_start 不算）。
-spec output_started(#st{}) -> boolean().
output_started(#st{output = O}) -> O.

delta_has_output(D) when is_map(D) ->
    lists:any(fun(K) ->
                      case maps:get(K, D, null) of
                          V when is_binary(V) -> V =/= <<>>;
                          L when is_list(L) -> L =/= [];
                          _ -> false
                      end
              end, [<<"content">>, <<"reasoning_content">>, <<"tool_calls">>]);
delta_has_output(_) ->
    false.

usage(#st{upstream = openai, usage_oa = U}) -> lg_usage:from_openai(U);
usage(#st{upstream = anthropic, usage_an = U}) -> lg_usage:from_anthropic(U).

result(S) ->
    #{usage => usage(S), text => iolist_to_binary(S#st.text),
      finish_reason => S#st.finish, model => S#st.model, id => S#st.id,
      error => S#st.error}.

%%====================================================================
%% 帧构造
%%====================================================================

chunk(S, Choices) ->
    chunk(S, Choices, #{}).

chunk(#st{id = Id, model = Model, created = Created} = S, Choices, Extra) ->
    data_frame(S, Extra#{<<"id">> => Id, <<"object">> => <<"chat.completion.chunk">>,
                         <<"created">> => Created, <<"model">> => Model,
                         <<"choices">> => Choices}).

%% openai 客户端的 data-only 帧（map 输出时直接给 map）
data_frame(#st{out = map}, M) -> M;
data_frame(_S, M) -> lg_sse:encode(json:encode(M)).

done(#st{out = map}) -> [];
done(_S) -> [lg_sse:done()].

%% 透传帧：事件被改写过时按 map 重新编码（与原先逐级改写 raw 的字节一致）
raw(Raw, _J) when is_binary(Raw) -> Raw;
raw({encode, undefined}, J) -> iolist_to_binary(lg_sse:encode(json:encode(J)));
raw({encode, E}, J) -> iolist_to_binary(lg_sse:encode(E, json:encode(J))).

delta(D) ->
    #{<<"index">> => 0, <<"delta">> => D, <<"finish_reason">> => null}.

event(Type, Payload) ->
    lg_sse:encode(Type, json:encode(Payload#{<<"type">> => Type})).

keep(Old, New) when is_binary(New), New =/= <<>>, Old =:= <<>> -> binary:copy(New);
keep(Old, _) -> Old.

id_or(Id, _) when is_binary(Id), Id =/= <<>> -> Id;
id_or(_, Idx) -> <<"toolu_", (integer_to_binary(Idx))/binary>>.

list(L) when is_list(L) -> L;
list(_) -> [].
