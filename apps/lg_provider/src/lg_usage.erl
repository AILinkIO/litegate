%% @doc 用量归一化与计费。
%%
%% 归一化结构（互不重叠，便于分项计价）：
%%   input       未命中缓存的输入 token
%%   cache_read  缓存命中的输入 token
%%   cache_write 写入缓存的输入 token
%%   output      输出 token（含 reasoning）
%%   reasoning   其中的推理 token（仅统计，不单独计价）
%%
%% OpenAI 语义：prompt_tokens 包含缓存部分，需减去；
%% Anthropic 语义：input_tokens 不含缓存部分，各项直接相加。
-module(lg_usage).

-export([zero/0, from_openai/1, from_anthropic/1, from_responses/1, merge_anthropic/2,
         to_openai/1, to_anthropic/1, total/1, cost/2]).

-type usage() :: #{input := non_neg_integer(), output := non_neg_integer(),
                   cache_read := non_neg_integer(), cache_write := non_neg_integer(),
                   reasoning := non_neg_integer(),
                   images => non_neg_integer(),     %% 图片生成张数
                   chars => non_neg_integer()}.     %% 语音合成字符数
-export_type([usage/0]).

-spec zero() -> usage().
zero() ->
    #{input => 0, output => 0, cache_read => 0, cache_write => 0, reasoning => 0}.

-spec from_openai(map() | null) -> usage().
from_openai(U) when is_map(U) ->
    Prompt = int(U, <<"prompt_tokens">>),
    PD = obj(U, <<"prompt_tokens_details">>),
    %% DeepSeek 用 prompt_cache_hit_tokens，其余 OpenAI 兼容实现用 cached_tokens
    Cached = max(int(PD, <<"cached_tokens">>), int(U, <<"prompt_cache_hit_tokens">>)),
    Written = int(PD, <<"cache_write_tokens">>),
    #{input => max(Prompt - Cached - Written, 0),
      output => int(U, <<"completion_tokens">>),
      cache_read => Cached,
      cache_write => Written,
      reasoning => int(obj(U, <<"completion_tokens_details">>), <<"reasoning_tokens">>)};
from_openai(_) ->
    zero().

-spec from_anthropic(map() | null) -> usage().
from_anthropic(U) when is_map(U) ->
    #{input => int(U, <<"input_tokens">>),
      output => int(U, <<"output_tokens">>),
      cache_read => int(U, <<"cache_read_input_tokens">>),
      cache_write => int(U, <<"cache_creation_input_tokens">>),
      reasoning => 0};
from_anthropic(_) ->
    zero().

%% @doc Responses API：input_tokens 含缓存命中部分（与 OpenAI Chat 语义相同）。
-spec from_responses(map() | null) -> usage().
from_responses(U) when is_map(U) ->
    In = int(U, <<"input_tokens">>),
    Cached = int(obj(U, <<"input_tokens_details">>), <<"cached_tokens">>),
    #{input => max(In - Cached, 0),
      output => int(U, <<"output_tokens">>),
      cache_read => Cached,
      cache_write => 0,
      reasoning => int(obj(U, <<"output_tokens_details">>), <<"reasoning_tokens">>)};
from_responses(_) ->
    zero().

%% @doc 流式：message_start 的 usage 与 message_delta 的 usage 合并（后者非空字段覆盖前者）。
-spec merge_anthropic(map(), map() | null) -> map().
merge_anthropic(Acc, U) when is_map(U) ->
    maps:merge(Acc, maps:filter(fun(_, V) -> V =/= null end, U));
merge_anthropic(Acc, _) ->
    Acc.

-spec to_openai(usage()) -> map().
to_openai(#{input := In, output := Out, cache_read := CR, cache_write := CW,
            reasoning := R}) ->
    Prompt = In + CR + CW,
    #{<<"prompt_tokens">> => Prompt,
      <<"completion_tokens">> => Out,
      <<"total_tokens">> => Prompt + Out,
      <<"prompt_tokens_details">> => #{<<"cached_tokens">> => CR},
      <<"completion_tokens_details">> => #{<<"reasoning_tokens">> => R}}.

-spec to_anthropic(usage()) -> map().
to_anthropic(#{input := In, output := Out, cache_read := CR, cache_write := CW}) ->
    #{<<"input_tokens">> => In,
      <<"output_tokens">> => Out,
      <<"cache_read_input_tokens">> => CR,
      <<"cache_creation_input_tokens">> => CW}.

-spec total(usage()) -> non_neg_integer().
total(#{input := In, output := Out, cache_read := CR, cache_write := CW}) ->
    In + Out + CR + CW.

%% @doc 按每百万 token 价格计算美元费用。
-spec cost(usage(), #{input := number(), output := number(),
                      cache_read := number(), cache_write := number()}) -> float().
cost(#{input := In, output := Out, cache_read := CR, cache_write := CW} = U,
     #{input := PIn, output := POut, cache_read := PCR, cache_write := PCW} = P) ->
    %% token 与语音字符按每百万计价，图片按张计价
    (In * PIn + Out * POut + CR * PCR + CW * PCW + maps:get(chars, U, 0) * maps:get(tts, P, 0)) / 1.0e6
        + maps:get(images, U, 0) * maps:get(image, P, 0).

int(M, K) ->
    case maps:get(K, M, 0) of
        N when is_integer(N), N >= 0 -> N;
        _ -> 0
    end.

obj(M, K) ->
    case maps:get(K, M, #{}) of
        O when is_map(O) -> O;
        _ -> #{}
    end.
