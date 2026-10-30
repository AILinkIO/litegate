%% @doc 路由策略：决定同一优先级组内目标的顺序（之后仍按层排序、会话粘性再调整）。
%%
%%   weighted（默认）按权重无放回随机抽样
%%   order           按目标在路由中的顺序
%%   rotate          新会话分给最近 30 分钟承载会话最少的目标；同数时轮转
%%   usage           最满窗口的已用比例低的优先；同档按最近发出的 token 少的优先（1 小时半衰期）
%%   smart           套餐凭证：最满窗口 < 90% 的按最大窗口（最晚重置的窗口）先重置的优先（按小时比较，同小时看已用比例）；
%%                   顺序：< 90% → 90%–98% → 无额度信息的凭证（按权重）→ ≥ 98%
%%   pace            套餐凭证按「周窗口剩余比例 ÷ 距重置小时数」高的优先，相差 10% 以内按最近 token 少的优先；
%%                   无额度信息的凭证排在后面（按权重）
-module(lg_strategy).

-export([valid/1, order/3, note/1, windows/1]).

-include_lib("lg_core/include/lg_core.hrl").

-define(HOUR, 3600000).

-spec valid(term()) -> boolean().
valid(S) -> lists:member(S, [<<"weighted">>, <<"order">>, <<"rotate">>, <<"usage">>, <<"smart">>, <<"pace">>]).

%% @doc Items：[{Target, #lg_credential{}}]（同一优先级组，按路由中的顺序）。
-spec order(binary(), binary(), [{map(), #lg_credential{}}]) -> [{map(), #lg_credential{}}].
order(_, _Route, []) -> [];
order(_, _Route, [_] = Items) -> Items;
order(<<"order">>, _Route, Items) -> Items;
order(<<"rotate">>, Route, Items) ->
    Loads = lg_affinity:load(Route, [tkey(T) || {T, _} <- Items]),
    N = lg_affinity:next_turn(Route),
    {A, B} = lists:split(N rem length(Items), Items),
    sort_by(fun({T, _}) -> maps:get(tkey(T), Loads, 0) end, B ++ A);
order(<<"usage">>, _Route, Items) ->
    sort_by(fun({_, C}) -> {fullest(windows(C)), lg_affinity:recent_tokens(C#lg_credential.id)} end, Items);
order(<<"smart">>, _Route, Items) ->
    {Plan, Plain} = lists:partition(fun({_, C}) -> windows(C) =/= undefined end, Items),
    Keyed = [{smart_key(windows(C)), I} || {_, C} = I <- Plan],
    Sorted = [I || {_, I} <- lists:keysort(1, Keyed)],
    {Low, High} = lists:partition(fun({_, C}) -> fullest(windows(C)) < 98 end, Sorted),
    Low ++ weighted(Plain) ++ High;
order(<<"pace">>, _Route, Items) ->
    {Plan, Plain} = lists:partition(fun({_, C}) -> windows(C) =/= undefined end, Items),
    ByPace = lists:reverse(lists:keysort(1, [{pace(windows(C)), I} || {_, C} = I <- Plan])),
    bands(ByPace) ++ weighted(Plain);
order(_Weighted, _Route, Items) ->
    weighted(Items).

%% 稳定排序（键相同时保持原顺序）
sort_by(F, Items) ->
    [I || {_, _, I} <- lists:sort([{F(I), N, I} || {N, I} <- lists:enumerate(Items)])].

%% smart：先按已用比例分档（< 90、< 98、其余），再比各窗口的重置时刻（最晚重置的窗口优先比较，按小时取整），
%% 最后看已用比例
smart_key(Ws) ->
    Used = fullest(Ws),
    Band = if Used < 90 -> 0; Used < 98 -> 1; true -> 2 end,
    Resets = [case R of null -> infinity; _ -> R div ?HOUR end
              || #{resets_at := R} <- lists:reverse(lists:sort(fun by_reset/2, Ws))],
    {Band, Resets, Used}.

by_reset(#{resets_at := A}, #{resets_at := B}) ->
    reset_val(A) =< reset_val(B).

reset_val(null) -> infinity;
reset_val(R) -> R.

%% pace：周窗口（名称为 week 或以 w 结尾；没有时取最晚重置的窗口）剩余比例 ÷ 距重置小时数（至少 1）
pace([]) -> 0.0;
pace(Ws) ->
    W = case [X || #{name := N} = X <- Ws, is_week(N)] of
            [X | _] -> X;
            [] -> lists:last(lists:sort(fun by_reset/2, Ws))
        end,
    #{used_pct := U, resets_at := R} = W,
    Hours = case R of
                null -> 168;
                _ -> max(1, (R - lg_time:now_ms()) / ?HOUR)
            end,
    (100 - U) / Hours.

is_week(<<"week">>) -> true;
is_week(N) when is_binary(N), byte_size(N) > 0 -> binary:last(N) =:= $w;
is_week(_) -> false.

%% 与当前档首个目标的 pace 相差 10% 以内的视为同档，同档内按最近 token 少的优先
bands([]) -> [];
bands([{Top, _} | _] = L) ->
    {Band, Rest} = lists:splitwith(fun({P, _}) -> P >= Top * 0.9 end, L),
    sort_by(fun({_, C}) -> lg_affinity:recent_tokens(C#lg_credential.id) end, [I || {_, I} <- Band])
        ++ bands(Rest).

%% @doc 套餐凭证当前有效的窗口（未过重置时刻）；非套餐或尚无额度信息时 undefined。
-spec windows(#lg_credential{}) -> [map()] | undefined.
windows(#lg_credential{id = Id} = C) ->
    case lg_plan:plan_of(C) of
        undefined -> undefined;
        _ ->
            case lg_plan:status(Id) of
                #{windows := [_ | _] = Ws} ->
                    Now = lg_time:now_ms(),
                    [W || #{resets_at := R} = W <- Ws, R =:= null orelse R > Now];
                _ -> undefined
            end
    end.

fullest(undefined) -> 0;
fullest([]) -> 0;
fullest(Ws) -> lists:max([U || #{used_pct := U} <- Ws]).

%% @doc 路由决策记录里的说明：套餐窗口（已用比例与重置时刻）、最近 token。
-spec note(#lg_credential{}) -> binary().
note(#lg_credential{id = Id} = C) ->
    Win = case windows(C) of
              undefined -> [];
              Ws -> [iolist_to_binary([N, $\s, integer_to_binary(round(U)), $%,
                                       case R of null -> <<>>; _ -> [<<" 重置 "/utf8>>, hhmm(R)] end])
                     || #{name := N, used_pct := U, resets_at := R} <- Ws]
          end,
    Tok = case lg_affinity:recent_tokens(Id) of
              T when T >= 1 -> [iolist_to_binary([<<"近期 "/utf8>>, integer_to_binary(round(T)), <<" tok">>])];
              _ -> []
          end,
    iolist_to_binary(lists:join(<<" · "/utf8>>, Win ++ Tok)).

%% 按配置时区显示（timezone_offset_min，与规则时段判断的 local_minute/0 一致）
hhmm(Ms) ->
    Off = lg_config:get(timezone_offset_min) * 60,
    {{_, Mo, D}, {H, Mi, _}} = calendar:gregorian_seconds_to_datetime(Ms div 1000 + 62167219200 + Off),
    io_lib:format("~2..0b-~2..0b ~2..0b:~2..0b", [Mo, D, H, Mi]).

weighted([]) -> [];
weighted([X]) -> [X];
weighted(Items) ->
    Total = lists:sum([maps:get(weight, T, 1) || {T, _} <- Items]),
    Pick = pick(rand:uniform(Total), Items),
    [Pick | weighted(lists:delete(Pick, Items))].

pick(N, [{T, _} = I | Rest]) ->
    W = maps:get(weight, T, 1),
    case N =< W of
        true -> I;
        false -> pick(N - W, Rest)
    end.

tkey(#{route := R}) -> {route, R};
tkey(#{credential := C, upstream_model := M}) -> {C, M}.
