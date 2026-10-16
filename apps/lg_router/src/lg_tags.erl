%% @doc 请求标签：用于按项目 / 工具归因用量与预算。
%%
%% 来源（合并去重，按出现顺序保留前 8 个）：请求头 `X-LiteGate-Tags: a,b`、请求体 `metadata.tags`
%% （字符串按逗号拆分，或字符串列表；Anthropic 的 metadata 只允许 user_id，不取）、API Key 的默认标签。
%% 每个标签 ≤ 64 字符，只允许 [A-Za-z0-9_.:/-]，不合法的丢弃。
-module(lg_tags).

-export([normalize/1, from_header/1, from_body/2, merge/1]).

-define(MAX_TAGS, 8).
-define(MAX_LEN, 64).

%% @doc 过滤不合法的标签、去重，最多 8 个。
-spec normalize(term()) -> [binary()].
normalize(L) when is_list(L) ->
    take(dedup([T || T <- L, valid(T)]), ?MAX_TAGS);
normalize(_) ->
    [].

-spec from_header(binary() | undefined) -> [binary()].
from_header(H) when is_binary(H) -> split(H);
from_header(_) -> [].

%% @doc 请求体中的 metadata.tags（OpenAI Chat / Responses 格式）。
-spec from_body(openai | anthropic | responses, map()) -> [binary()].
from_body(anthropic, _) -> [];
from_body(_, #{<<"metadata">> := #{<<"tags">> := T}}) when is_binary(T) -> split(T);
from_body(_, #{<<"metadata">> := #{<<"tags">> := L}}) when is_list(L) -> [X || X <- L, is_binary(X)];
from_body(_, _) -> [].

%% @doc 合并多个来源。
-spec merge([[binary()]]) -> [binary()].
merge(Lists) ->
    normalize(lists:append(Lists)).

%%====================================================================
%% 内部函数
%%====================================================================

split(B) ->
    [string:trim(X) || X <- binary:split(B, <<",">>, [global])].

valid(T) when is_binary(T), T =/= <<>>, byte_size(T) =< ?MAX_LEN ->
    nomatch =:= re:run(T, <<"[^A-Za-z0-9_.:/-]">>);
valid(_) ->
    false.

dedup(L) ->
    lists:reverse(lists:foldl(fun(X, Acc) -> case lists:member(X, Acc) of true -> Acc; false -> [X | Acc] end end,
                              [], L)).

take(L, N) when length(L) =< N -> L;
take(L, N) -> lists:sublist(L, N).
