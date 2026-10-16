%% @doc 会话标识与轮次判断（纯函数）。
%%
%% 会话标识依次取：
%%   1. 请求头 X-LiteGate-Session、x-session-affinity（Pi / omp）
%%   2. 编码工具自带：Claude Code 的 X-Claude-Code-Session-Id；Codex 的 session-id
%%   3. 请求体：prompt_cache_key（Codex、OpenAI SDK）；metadata.user_id 中的 session_id
%%      （Claude Code：JSON 字符串；旧版本为 `..._session_<id>` 后缀）
%%   4. 都没有时：sha256(Key id ‖ 模型名 ‖ 系统提示前 2KB ‖ 第一条用户消息前 2KB) 的前 16 字节（十六进制）
-module(lg_session).

-export([id/3, new_turn/2, last_user_text/2, as_messages/1]).

-define(MAX_ID, 128).
-define(PREFIX, 2048).

%% @doc 返回 {Id, explicit | derived}；没有可用于推导的内容时 undefined。
-spec id(#{binary() => binary()}, map(), binary()) -> {binary(), explicit | derived} | undefined.
id(Headers, Body, KeyId) ->
    FromHeader = [V || H <- [<<"x-litegate-session">>, <<"x-session-affinity">>, <<"x-claude-code-session-id">>,
                             <<"session-id">>, <<"session_id">>],
                       V <- [maps:get(H, Headers, undefined)], usable(V)],
    case FromHeader of
        [V | _] -> {clip(V), explicit};
        [] ->
            case from_body(Body) of
                undefined -> derived(Body, KeyId);
                V -> {clip(V), explicit}
            end
    end.

from_body(#{<<"prompt_cache_key">> := V}) when is_binary(V), V =/= <<>> -> V;
from_body(#{<<"metadata">> := #{<<"user_id">> := U}}) when is_binary(U) ->
    case try json:decode(U) catch error:_ -> undefined end of
        #{<<"session_id">> := S} when is_binary(S), S =/= <<>> -> S;
        _ ->
            case binary:split(U, <<"_session_">>) of
                [_, S] when S =/= <<>> -> S;
                _ -> undefined
            end
    end;
from_body(_) -> undefined.

derived(Body, KeyId) ->
    System = prefix(system_text(Body)),
    First = prefix(first_user_text(Body)),
    case System =:= <<>> andalso First =:= <<>> of
        true -> undefined;
        false ->
            Model = case maps:get(<<"model">>, Body, <<>>) of M when is_binary(M) -> M; _ -> <<>> end,
            H = crypto:hash(sha256, [KeyId, 0, Model, 0, System, 0, First]),
            {binary:encode_hex(binary:part(H, 0, 16), lowercase), derived}
    end.

usable(V) -> is_binary(V) andalso V =/= <<>>.

clip(V) when byte_size(V) > ?MAX_ID -> binary:part(V, 0, ?MAX_ID);
clip(V) -> V.

prefix(B) when byte_size(B) > ?PREFIX -> binary:part(B, 0, ?PREFIX);
prefix(B) -> B.

%% 系统提示：Anthropic system、Responses instructions、OpenAI 的 system / developer 消息
system_text(#{<<"system">> := S}) -> text(S);
system_text(#{<<"instructions">> := S}) -> text(S);
system_text(#{<<"messages">> := Ms}) when is_list(Ms) ->
    iolist_to_binary([text(maps:get(<<"content">>, M, <<>>)) || #{<<"role">> := R} = M <- Ms,
                                                                 R =:= <<"system">> orelse R =:= <<"developer">>]);
system_text(_) -> <<>>.

first_user_text(Body) ->
    case [M || M <- messages(Body), is_map(M), maps:get(<<"role">>, M, undefined) =:= <<"user">>] of
        [M | _] -> text(maps:get(<<"content">>, M, <<>>));
        [] -> <<>>
    end.

%% Chat / Messages 的 messages；Responses 的 input（字符串视为一条用户消息）
messages(#{<<"messages">> := Ms}) when is_list(Ms) -> Ms;
messages(#{<<"input">> := In}) when is_binary(In) -> [#{<<"role">> => <<"user">>, <<"content">> => In}];
messages(#{<<"input">> := In}) when is_list(In) ->
    [case I of
         #{<<"type">> := <<"message">>} -> I;
         #{<<"role">> := _} -> I;
         _ -> I#{<<"role">> => maps:get(<<"type">>, I, <<"item">>)}
     end || I <- In, is_map(I)];
messages(_) -> [].

text(B) when is_binary(B) -> B;
text(L) when is_list(L) ->
    iolist_to_binary([T || P <- L, T <- [part_text(P)], T =/= <<>>]);
text(_) -> <<>>.

part_text(#{<<"text">> := T}) when is_binary(T) -> T;
part_text(B) when is_binary(B) -> B;
part_text(_) -> <<>>.

%% @doc 统一成 #{system, messages}（token 估算、图片检测用）：Responses 的 instructions / input 转过来。
-spec as_messages(map()) -> map().
as_messages(#{<<"messages">> := _} = Req) -> Req;
as_messages(Req) ->
    #{<<"system">> => system_text(Req), <<"messages">> => messages(Req), <<"tools">> => maps:get(<<"tools">>, Req, [])}.

%% @doc 这个请求是否开始新的一轮：最后一条消息是用户发言（文字或图片），而不是工具结果。
-spec new_turn(openai | anthropic | responses, map()) -> boolean().
new_turn(responses, #{<<"input">> := In}) when is_binary(In) -> true;
new_turn(responses, #{<<"input">> := In}) when is_list(In), In =/= [] ->
    case lists:last(In) of
        #{<<"type">> := T} when T =:= <<"function_call_output">>; T =:= <<"custom_tool_call_output">> -> false;
        #{<<"role">> := <<"user">>} -> true;
        #{<<"type">> := <<"message">>, <<"role">> := R} -> R =:= <<"user">>;
        _ -> false
    end;
new_turn(_, #{<<"messages">> := Ms}) when is_list(Ms), Ms =/= [] ->
    %% 末尾的系统消息不算（Claude Code 新版在用户消息之后附带 role: system 的环境说明）
    case lists:dropwhile(fun(#{<<"role">> := R}) -> R =:= <<"system">> orelse R =:= <<"developer">>;
                            (_) -> false
                         end, lists:reverse(Ms)) of
        [] -> true;
        [Last | _] -> user_turn(Last)
    end;
new_turn(_, _) -> true.

user_turn(Last) ->
    case Last of
        #{<<"role">> := <<"user">>, <<"content">> := C} when is_list(C) ->
            not lists:any(fun(#{<<"type">> := <<"tool_result">>}) -> true; (_) -> false end, C);
        #{<<"role">> := <<"user">>} -> true;
        _ -> false
    end.

%% @doc 最后一条用户消息的文字（意图判断用），最多 MaxBytes 字节。
-spec last_user_text(map(), pos_integer()) -> binary().
last_user_text(Body, MaxBytes) ->
    Users = [M || M <- messages(Body), is_map(M), maps:get(<<"role">>, M, undefined) =:= <<"user">>],
    T = case Users of
            [] -> <<>>;
            _ -> text(maps:get(<<"content">>, lists:last(Users), <<>>))
        end,
    case byte_size(T) > MaxBytes of
        true -> utf8_prefix(T, MaxBytes);
        false -> T
    end.

%% 截断到 MaxBytes 以内且不切断 UTF-8 字符
utf8_prefix(B, N) ->
    P = binary:part(B, 0, N),
    case unicode:characters_to_binary(P) of
        R when is_binary(R) -> R;
        {incomplete, R, _} -> R;
        {error, R, _} -> R
    end.
