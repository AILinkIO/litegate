%% @doc 规则路由与意图路由（路由选项 rules / classifier）。
%%
%% rules：有序列表，从上往下第一条命中的生效：
%%   #{<<"when">> => #{min_tokens, max_tokens, images, thinking, client, tool, tags, hours, intent}, <<"use">> => 路由名}
%%   （client 为接口格式 openai / anthropic / responses；tool 为 lg_client 识别出的客户端工具，如 claude-code、codex）
%%   #{<<"when">> => ..., <<"skip">> => [凭证 id | 嵌套路由名]}
%% 新的一轮（最后一条消息是用户发言）重新判定；同一轮的后续请求沿用本会话这一轮的判定（存于 lg_affinity）。
%%
%% 意图：先收集「除意图外其他条件都满足」的规则的意图，遇到第一条不带意图且命中的规则就停止（不调用判断模型）；
%% 有意图时调用 classifier 路由：回答开头的整数（允许空白 / 标点装饰前缀）1..n 对应意图，0 / 无数字 / 越界视为不命中。
%% 路由选项 intent_engine = laya 时先问本地 Laya（lg_laya），失败再问 classifier 路由（有配置时）；
%% intent_engine = systemone 时先问决策模型路由 decision_route（System One，问法 decision_style 见 lg_decision），
%% 失败或超时（decision_timeout_ms）再问 classifier 路由。
%% 判断结果按 {消息, 意图列表} 缓存 10 分钟；超时（intent_timeout_ms）或失败时本轮不按意图命中，不影响请求。
-module(lg_rules).

-export([valid_rules/1, valid_classifier/1, decide/4, matches/4, parse_answer/2, prompt/2]).

-include_lib("lg_core/include/lg_core.hrl").

-define(MAX_RULES, 16).
-define(INTENT_TTL_MS, 600000).
-define(MAX_TEXT, 4096).

%%====================================================================
%% 校验
%%====================================================================

-spec valid_rules(term()) -> boolean().
valid_rules(L) when is_list(L), length(L) =< ?MAX_RULES ->
    lists:all(fun valid_rule/1, L);
valid_rules(_) ->
    false.

valid_rule(#{} = R) ->
    Keys = maps:keys(R) -- [<<"when">>, <<"use">>, <<"skip">>],
    Action = case R of
                 #{<<"use">> := _, <<"skip">> := _} -> false;   %% 动作二选一
                 #{<<"use">> := U} -> is_binary(U) andalso U =/= <<>>;
                 #{<<"skip">> := S} -> is_list(S) andalso S =/= [] andalso lists:all(fun is_binary/1, S);
                 _ -> false
             end,
    Keys =:= [] andalso Action andalso valid_when(maps:get(<<"when">>, R, #{}));
valid_rule(_) ->
    false.

valid_when(W) when is_map(W) ->
    lists:all(fun({K, V}) -> valid_cond(K, V) end, maps:to_list(W));
valid_when(_) ->
    false.

valid_cond(K, V) when K =:= <<"min_tokens">>; K =:= <<"max_tokens">> -> is_integer(V) andalso V >= 0;
valid_cond(K, V) when K =:= <<"images">>; K =:= <<"thinking">> -> is_boolean(V);
valid_cond(<<"client">>, V) ->
    is_list(V) andalso V =/= [] andalso lists:all(fun(C) -> lists:member(C, [<<"openai">>, <<"anthropic">>, <<"responses">>]) end, V);
valid_cond(<<"tool">>, V) -> is_list(V) andalso V =/= [] andalso lists:all(fun lg_client:valid/1, V);
valid_cond(<<"tags">>, V) -> is_list(V) andalso V =/= [] andalso lists:all(fun is_binary/1, V);
valid_cond(<<"hours">>, V) -> parse_hours(V) =/= error;
valid_cond(<<"intent">>, V) -> is_binary(V) andalso byte_size(V) > 0 andalso byte_size(V) =< 500;
valid_cond(_, _) -> false.

-spec valid_classifier(term()) -> boolean().
%% 仅校验形状（非空 binary）；指向的路由是否存在且启用由 lg_routes:build 保存时校验。
valid_classifier(V) -> is_binary(V) andalso V =/= <<>>.

%% "09:00-18:00" → {540, 1080}（分钟）；跨午夜如 "22:00-06:00" 也可以。
%% 结束界允许 24:00（排他，即 "00:00-24:00" 表示全天）；起始不允许 24 点，分钟必须 < 60。
parse_hours(V) when is_binary(V) ->
    case re:run(V, hours_re(), [{capture, all_but_first, binary}]) of
        {match, [H1, M1, H2, M2]} ->
            [A, B, C, D] = [binary_to_integer(X) || X <- [H1, M1, H2, M2]],
            End = C * 60 + D,
            case A < 24 andalso C =< 24 andalso B < 60 andalso D < 60
                andalso (C < 24 orelse D =:= 0) of
                true -> {A * 60 + B, End};
                false -> error
            end;
        _ -> error
    end;
parse_hours(_) ->
    error.

%%====================================================================
%% 判定
%%====================================================================

%% @doc 判定本轮命中的规则：none | #{index := N, rule := Rule, intent => #{answer, ms, error}}。
%% Ctx 需带 new_turn；会话标识 session 可无（无会话时每个请求都重新判定）。
-spec decide(#lg_route{}, lg_provider:format(), map(), map()) -> none | map().
decide(#lg_route{options = #{rules := [_ | _] = Rules} = Opts, name = Route}, Client, Req, #{new_turn := NewTurn} = Ctx) ->
    Sid = maps:get(session, Ctx, undefined),
    Reuse = case {NewTurn, Sid} of
                {false, S} when S =/= undefined -> lg_affinity:decision(Route, S);
                _ -> undefined
            end,
    case Reuse of
        {decided, none} -> none;
        {decided, D} -> D#{reused => true};
        _ ->
            D = evaluate(Rules, {maps:get(intent_engine, Opts, <<"llm">>), maps:get(classifier, Opts, undefined),
                                 decision(Opts)},
                         Client, Req, Ctx),
            case Sid of
                undefined -> ok;
                _ -> lg_affinity:put_decision(Route, Sid, {decided, D})
            end,
            D
    end;
decide(_Route, _Client, _Req, _Ctx) ->
    none.

%% 决策模型判断的 {路由, 问法}（默认单选，与判断模型的问法一致）；未配置路由时为 undefined
decision(#{decision_route := R} = Opts) ->
    {R, case maps:get(decision_style, Opts, <<"choice">>) of <<"noul">> -> noul; _ -> choice end};
decision(_) ->
    undefined.

evaluate(Rules, {Engine, Classifier, Decision}, Client, Req, Ctx) ->
    Facts = facts(Client, Req, Ctx),
    Indexed = lists:enumerate(Rules),
    %% 每条规则（不含意图）只判定一次，意图收集与命中挑选共用结果：
    %% 避免 hours 跨分钟边界时两遍判定不一致，也省去重复 token 估算。
    Matched = lists:zipwith(fun({N, R}, M) -> {N, R, M} end, Indexed,
                            [matches(maps:remove(<<"intent">>, maps:get(<<"when">>, R, #{})),
                                     Facts, Client, Ctx) || R <- Rules]),
    %% 收集意图：其他条件都满足的规则；遇到第一条不带意图且命中的规则停止
    {Intents, _} = lists:foldl(
                     fun(_, {Acc, stop}) -> {Acc, stop};
                        ({_, _, false}, {Acc, go}) -> {Acc, go};
                        ({_, R, true}, {Acc, go}) ->
                             case maps:find(<<"intent">>, maps:get(<<"when">>, R, #{})) of
                                 {ok, I} -> {add_intent(I, Acc), go};
                                 error -> {Acc, stop}
                             end
                     end, {[], go}, Matched),
    IntentResult = case Intents of
                       [] -> undefined;
                       _ when Engine =:= <<"systemone">>, Decision =/= undefined ->
                           (ask_systemone(Decision, Classifier, Intents, Req, Ctx))#{intents => Intents};
                       _ when Classifier =:= undefined, Engine =/= <<"laya">> -> #{error => <<"no classifier">>};
                       _ -> (ask(Engine, Classifier, Intents, Req, Ctx))#{intents => Intents}
                   end,
    Answer = case IntentResult of
                 #{answer := N} when N > 0 -> lists:nth(N, Intents);
                 _ -> undefined
             end,
    Hit = [{N, R} || {N, R, M} <- Matched, M, intent_ok(maps:get(<<"when">>, R, #{}), Answer)],
    Base = case IntentResult of
               undefined -> #{};
               _ -> #{intent => IntentResult}
           end,
    case Hit of
        [{Idx, Rule} | _] -> Base#{index => Idx, rule => Rule};
        [] when Base =:= #{} -> none;
        [] -> Base#{index => 0}
    end.

%% 只有大小写不同的意图视为同一个
add_intent(I, Acc) ->
    case lists:any(fun(X) -> string:lowercase(X) =:= string:lowercase(I) end, Acc) of
        true -> Acc;
        false -> Acc ++ [I]
    end.

intent_ok(W, Answer) ->
    case maps:find(<<"intent">>, W) of
        error -> true;
        {ok, _} when Answer =:= undefined -> false;
        {ok, I} -> string:lowercase(I) =:= string:lowercase(Answer)
    end.

facts(Client, Req, _Ctx) ->
    %% tokens 用进程字典记忆化：同一请求里多条 min/max 规则只估算一次
    #{tokens => memo(fun() -> lg_tokens:estimate(lg_session:as_messages(Req)) end),
      images => has_images(Req),
      thinking => thinking(Client, Req)}.

memo(F) ->
    Key = make_ref(),
    fun() -> case get(Key) of
                 undefined -> V = F(), put(Key, V), V;
                 V -> V
             end
    end.

%% @doc 条件（不含意图）是否全部满足。
-spec matches(map(), map(), lg_provider:format(), map()) -> boolean().
matches(W, Facts, Client, Ctx) ->
    lists:all(fun({K, V}) -> cond_ok(K, V, Facts, Client, Ctx) end, maps:to_list(W)).

cond_ok(<<"min_tokens">>, N, #{tokens := T}, _, _) -> T() >= N;
cond_ok(<<"max_tokens">>, N, #{tokens := T}, _, _) -> T() =< N;
cond_ok(<<"images">>, B, #{images := I}, _, _) -> I =:= B;
cond_ok(<<"thinking">>, B, #{thinking := T}, _, _) -> T =:= B;
cond_ok(<<"client">>, L, _, Client, _) -> lists:member(atom_to_binary(Client), L);
cond_ok(<<"tool">>, L, _, _, Ctx) -> lists:member(maps:get(client, Ctx, <<"other">>), L);
cond_ok(<<"tags">>, L, _, _, Ctx) -> lists:any(fun(T) -> lists:member(T, L) end, maps:get(tags, Ctx, []));
cond_ok(<<"hours">>, V, _, _, _) -> in_hours(parse_hours(V), local_minute());
cond_ok(_, _, _, _, _) -> false.

in_hours({From, To}, M) when From =< To -> M >= From andalso M < To;
in_hours({From, To}, M) -> M >= From orelse M < To;
in_hours(error, _) -> false.

local_minute() ->
    Secs = erlang:system_time(second) + lg_config:get(timezone_offset_min) * 60,
    (Secs rem 86400) div 60.

has_images(Req) ->
    Parts = [P || M <- maps:get(<<"messages">>, lg_session:as_messages(Req), []), is_map(M),
                  P <- case maps:get(<<"content">>, M, <<>>) of L when is_list(L) -> L; _ -> [] end, is_map(P)],
    lists:any(fun(#{<<"type">> := T}) -> lists:member(T, [<<"image">>, <<"image_url">>, <<"input_image">>]);
                 (_) -> false
              end, Parts).

thinking(anthropic, #{<<"thinking">> := #{<<"type">> := T}}) -> T =/= <<"disabled">>;
thinking(openai, #{<<"reasoning_effort">> := E}) -> E =/= <<"none">> andalso E =/= null;
thinking(responses, #{<<"reasoning">> := #{<<"effort">> := E}}) -> E =/= <<"none">> andalso E =/= null;
thinking(responses, #{<<"reasoning">> := R}) when is_map(R) -> true;
thinking(_, _) -> false.

%%====================================================================
%% 意图判断
%%====================================================================

-spec prompt([binary()], binary()) -> map().
prompt(Intents, Text) ->
    Kinds = [[integer_to_binary(N), <<". ">>, I, $\n] || {N, I} <- lists:enumerate(Intents)],
    #{<<"system">> => <<"You route a user's message to an AI assistant by what it asks for. "
                        "Given numbered kinds of request and the user's message, answer with the number of the kind "
                        "the message is, or 0 if it is none of them. Answer with the number only.">>,
      <<"user">> => iolist_to_binary([<<"Kinds of request:\n">>, Kinds, <<"\nMessage:\n">>, Text])}.

%% @doc 回答开头（允许空白、标点、Markdown 装饰等非文字前缀）的整数；1..N 之外为 0。
%% 正文后置的数字视为叙述内容不作数（如 "kind #2"、"The answer is 2"），避免散文数字误命中。
%% 先去掉 <think>…</think> 思考块（部分上游把思考写在正文里，如 MiniMax 的 OpenAI 接口；未闭合的思考块视为回答不完整）。
-spec parse_answer(binary(), pos_integer()) -> non_neg_integer().
parse_answer(Text0, N) ->
    Text = strip_think(Text0),
    case re:run(Text, answer_re(), [{capture, [1], binary}]) of
        {match, [D]} ->
            case binary_to_integer(D) of
                X when X >= 1, X =< N -> X;
                _ -> 0
            end;
        nomatch -> 0
    end.

strip_think(T) ->
    T1 = re:replace(T, think_re(), <<>>, [global, {return, binary}]),
    case binary:match(T1, <<"<think>">>) of
        {P, _} -> binary:part(T1, 0, P);
        nomatch -> T1
    end.

think_re() ->
    cached_re(think_re, "<think>.*?</think>", [unicode, dotall]).

%% ^\W*(\d+)：开头只允许非文字字符（空白、标点、符号；unicode + ucp 下汉字等一律算文字），
%% 随后必须是整数——即回答须以数字开头。
answer_re() ->
    cached_re(answer_re, "^\\W*(\\d+)", [unicode, ucp]).

hours_re() ->
    cached_re(hours_re, "^(\\d{1,2}):(\\d{2})-(\\d{1,2}):(\\d{2})$", []).

%% 预编译正则在模块属性里做不了（re:compile 是运行时调用），用 persistent_term 缓存一次。
%% 注意：编译好的 MP 调用时不能再带 unicode 等编译期选项，编码在 re:compile 时给定。
cached_re(Name, Pattern, Opts) ->
    Key = {?MODULE, Name},
    case persistent_term:get(Key, undefined) of
        undefined ->
            {ok, MP} = re:compile(Pattern, Opts),
            persistent_term:put(Key, MP),
            MP;
        MP -> MP
    end.

%% 结果带 classifier：实际给出答案的判断者（laya 或路由名）；Laya 失败后改问路由时带 local_error。
%% 运行参数 laya_enabled 关闭时：有后备路由就直接问它，没有则本轮照常路由
ask(<<"laya">>, Classifier, Intents, Req, Ctx) ->
    case lg_config:get(laya_enabled) of
        false when Classifier =/= undefined -> ask(<<"llm">>, Classifier, Intents, Req, Ctx);
        false -> #{answer => 0, ms => 0, error => <<"laya disabled">>, classifier => <<"laya">>};
        _ -> ask_laya(Classifier, Intents, Req, Ctx)
    end;
ask(Engine, Classifier, Intents, Req, Ctx) ->
    ask_route(Engine, Classifier, Intents, Req, Ctx).

ask_laya(Classifier, Intents, Req, Ctx) ->
    Text = lg_session:last_user_text(Req, ?MAX_TEXT),
    CacheKey = crypto:hash(sha256, term_to_binary({laya, Intents, Text})),
    case lg_affinity:intent_cached(CacheKey) of
        {ok, Answer} ->
            #{answer => Answer, ms => 0, cached => true, classifier => <<"laya">>};
        miss ->
            T0 = lg_time:now_ms(),
            case lg_laya:classify(Intents, Text, lg_config:get(laya_timeout_ms)) of
                {ok, Answer, Reply} ->
                    lg_affinity:intent_cache(CacheKey, Answer, ?INTENT_TTL_MS),
                    #{answer => Answer, ms => lg_time:now_ms() - T0, reply => Reply, classifier => <<"laya">>};
                {error, Why} when Classifier =:= undefined ->
                    #{answer => 0, ms => lg_time:now_ms() - T0, error => Why, classifier => <<"laya">>};
                {error, Why} ->
                    R = ask_llm(Classifier, Intents, Text, Ctx),
                    R#{local_error => Why, ms => lg_time:now_ms() - T0}
            end
    end.

%% 决策模型（System One）判断：经网关调用 decision_route 路由（单独记日志、计费），
%% 失败、超时或回答不合法时改问 classifier 路由（有配置时），结果带 local_error。
ask_systemone({Route, Style}, Classifier, Intents, Req, Ctx) ->
    Text = lg_session:last_user_text(Req, ?MAX_TEXT),
    CacheKey = crypto:hash(sha256, term_to_binary({systemone, Route, Style, Intents, Text})),
    case lg_affinity:intent_cached(CacheKey) of
        {ok, Answer} ->
            #{answer => Answer, ms => 0, cached => true, classifier => Route};
        miss ->
            T0 = lg_time:now_ms(),
            Res = case lg_router:judge_systemone(Route, lg_decision:request(Style, Intents, Text), Ctx,
                                                 lg_config:get(decision_timeout_ms)) of
                      {ok, Body} -> lg_decision:parse(Style, Intents, Body, lg_config:get(decision_min_prob));
                      {error, _} = E -> E
                  end,
            case Res of
                {ok, Answer, Reply} ->
                    lg_affinity:intent_cache(CacheKey, Answer, ?INTENT_TTL_MS),
                    #{answer => Answer, ms => lg_time:now_ms() - T0, reply => Reply, classifier => Route};
                {error, Why} when Classifier =:= undefined ->
                    #{answer => 0, ms => lg_time:now_ms() - T0, error => Why, classifier => Route};
                {error, Why} ->
                    R = ask_llm(Classifier, Intents, Text, Ctx),
                    R#{local_error => Why, local_by => Route, ms => lg_time:now_ms() - T0}
            end
    end.

ask_route(_Engine, Classifier, Intents, Req, Ctx) ->
    Text = lg_session:last_user_text(Req, ?MAX_TEXT),
    CacheKey = crypto:hash(sha256, term_to_binary({Classifier, Intents, Text})),
    case lg_affinity:intent_cached(CacheKey) of
        {ok, Answer} ->
            #{answer => Answer, ms => 0, cached => true, classifier => Classifier};
        miss ->
            R = ask_llm(Classifier, Intents, Text, Ctx),
            case R of
                #{error := _} -> ok;
                #{answer := Answer} -> lg_affinity:intent_cache(CacheKey, Answer, ?INTENT_TTL_MS)
            end,
            R
    end.

ask_llm(Classifier, Intents, Text, Ctx) ->
    T0 = lg_time:now_ms(),
    Res = lg_router:classify(Classifier, prompt(Intents, Text), Ctx, lg_config:get(intent_timeout_ms)),
    Ms = lg_time:now_ms() - T0,
    case Res of
        {ok, Reply} ->
            #{answer => parse_answer(Reply, length(Intents)), ms => Ms, reply => trim(strip_think(Reply)),
              classifier => Classifier};
        {error, Why} ->
            #{answer => 0, ms => Ms, error => Why, classifier => Classifier}
    end.

trim(B) ->
    case string:slice(B, 0, 60) of
        S when is_binary(S) -> S;
        _ -> <<>>
    end.
