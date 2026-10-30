%% @doc 派生数据回填（T31 存储格式升级）。
%%
%% T31 只新增派生数据，原有键与值格式不变（旧版本仍可读写同一数据目录，见 lg_store_keys）：
%% - usage：每小时总量行与费用分解行（概览 / 预算启动只读这两类，不再逐行解码维度行）；
%% - idx：错误索引 $e（errors_only 走索引）；
%% - cache / responses：过期索引（清理按时间范围扫描，不再整表解码）。
%%
%% 新写入由写者同步维护派生数据；升级前（以及降级期间旧版本）写入的数据由本模块回填。
%% 标记行（usage cask 的 <<16#FF, 16#FF>>）记录尚未覆盖的范围：
%%   #{gen, alive, usage => none | {LoHour, HiHour}, errors => none | {LoKey, HiKey | undefined}（日志键区间 [Lo, Hi)），
%%     cache | responses => none | all | {FromS, ToS}（bitcask 写入时间戳，秒）}
%% - 写者启动时（init/2）把「上次存活 alive → 现在」并入未覆盖范围并递增 gen：旧版本只可能在这段时间里写过数据，
%%   降级后再升级也能补上；首次升级（无标记）时未覆盖范围为全部已有数据。alive 由写者每分钟刷新。
%% - 查询（ready/2）范围与未覆盖范围相交时走原有路径（逐行解码 / 全扫），结果与回填后一致。
%% - janitor 调 run/0 回填：读写都很轻的部分在本进程做，写入经写者（每次 ≤ 1000 个键或一个小时的用量行），
%%   进度随 gen 写回；写者重启过（gen 变了）则旧进度作废，按新的未覆盖范围重来。幂等，可中断续跑。
-module(lg_store_migrate).

-export([init/2, ready/2, gen/1, marker_ops/2, run/0]).

-define(BATCH, 1000).
-define(RETRIES, 3).

%%====================================================================
%% 写者调用
%%====================================================================

%% @doc 写者启动时更新标记（只在写者进程调用）。写失败只记录：标记仍是旧的 gen，janitor 回填照常。
-spec init(#{atom() => term()}, non_neg_integer()) -> ok.
init(#{usage := U} = Handles, Now) ->
    try marker(Handles, Now) of
        M ->
            case catch bitcask:put(U, lg_store_keys:usage_meta_key(), term_to_binary(M#{alive => Now})) of
                ok -> ok;
                Err -> lg_store_handles:write_error(usage, {migrate_marker, Err})
            end
    catch
        C:R -> lg_store_handles:write_error(usage, {migrate_marker, {C, R}})
    end.

marker(#{usage := U} = Handles, Now) ->
    case read(U) of
        #{gen := G, alive := A, usage := Us, errors := Es, cache := Cs, responses := Rs} ->
            #{gen => G + 1,
              usage => hull(Us, {lg_store_keys:hour(A), lg_store_keys:hour(Now)}),
              errors => hull_keys(Es, lg_store_keys:log_bounds(A, Now + 1)),
              cache => hull(Cs, {A div 1000, Now div 1000 + 1}),
              responses => hull(Rs, {A div 1000, Now div 1000 + 1})};
        _ ->
            %% 首次升级（或标记损坏）：已有的全部数据都未覆盖
            #{gen => 1,
              usage => case first_key(U, undefined, <<16#FF>>) of
                           none -> none;
                           <<H:32, _/binary>> -> {H, lg_store_keys:hour(Now)}
                       end,
              errors => case first_key(maps:get(logs, Handles), undefined, undefined) of
                            none -> none;
                            _ -> lg_store_keys:log_bounds(0, Now + 1)
                        end,
              cache => any_data(maps:get(cache, Handles)),
              responses => any_data(maps:get(responses, Handles))}
    end.

%% @doc 当前标记的 gen（无标记时 undefined）。
-spec gen(term()) -> non_neg_integer() | undefined.
gen(U) ->
    case read(U) of
        #{gen := G} -> G;
        _ -> undefined
    end.

%% @doc 更新标记字段的写操作（读-改-写；无标记时不写，查询保持走原有路径）。
-spec marker_ops(term(), map()) -> [{put, binary(), binary()}].
marker_ops(_U, Update) when map_size(Update) =:= 0 ->
    [];
marker_ops(U, Update) ->
    case read(U) of
        #{} = M -> [{put, lg_store_keys:usage_meta_key(), term_to_binary(maps:merge(M, Update))}];
        undefined -> []
    end.

%%====================================================================
%% 查询调用
%%====================================================================

%% @doc 派生数据是否已覆盖查询范围：usage 为 {FromHour, ToHour}（含两端），errors 为日志键区间 {Lo, Hi | undefined}。
-spec ready(usage | errors, tuple()) -> boolean().
ready(Field, Range) ->
    try read(lg_store_handles:handle(usage)) of
        #{Field := P} -> disjoint(Field, P, Range);
        _ -> false
    catch
        _:_ -> false
    end.

disjoint(_, none, _) -> true;
disjoint(usage, {Lo, Hi}, {A, B}) -> B < Lo orelse A > Hi;
disjoint(errors, {PLo, PHi}, {Lo, Hi}) -> le(Hi, PLo) orelse le(PHi, Lo);
disjoint(_, _, _) -> false.

%% 区间上界比较，undefined 为 +∞
le(undefined, _) -> false;
le(_, undefined) -> true;
le(X, Y) -> X =< Y.

%%====================================================================
%% janitor 调用：回填
%%====================================================================

%% @doc 回填全部未覆盖范围，返回各类处理量。
-spec run() -> map().
run() ->
    run(?RETRIES).

run(0) ->
    #{error => stale};
run(N) ->
    case read(h(usage)) of
        #{gen := Gen, usage := Us, errors := Es, cache := Cs, responses := Rs} ->
            try
                #{usage_hours => usage(Gen, Us),
                  logs => errors(Gen, Es, 0),
                  cache => sweep(Gen, cache, expires_at, Cs),
                  responses => sweep(Gen, responses, created_at, Rs)}
            catch
                throw:stale -> run(N - 1);
                throw:{failed, R} ->
                    logger:error("store migration failed: ~p", [R]),
                    #{error => failed}
            end;
        _ ->
            #{}
    end.

step(ok) -> ok;
step(stale) -> throw(stale);
step(Err) -> throw({failed, Err}).

%% 用量：从新到旧逐小时交给写者重算（重算与增量落盘都在写者里串行，结果精确）；空小时跳过
usage(_Gen, none) ->
    0;
usage(Gen, {Lo, Hi}) ->
    usage(Gen, Lo, Hi, 0).

usage(Gen, Lo, H, N) when H < Lo ->
    step(lg_store_writer:migrate(Gen, usage, [], #{usage => none})),
    N;
usage(Gen, Lo, H, N) ->
    case hour_empty(H) of
        true ->
            usage(Gen, Lo, H - 1, N);
        false ->
            Next = case H - 1 < Lo of true -> none; false -> {Lo, H - 1} end,
            step(lg_store_writer:migrate(Gen, usage, {usage_hour, H}, #{usage => Next})),
            usage(Gen, Lo, H - 1, N + 1)
    end.

hour_empty(H) ->
    U = h(usage),
    first_key(U, <<H:32>>, <<(H + 1):32>>) =:= none
        andalso bitcask:get(U, lg_store_keys:usage_total_key(H)) =:= not_found
        andalso bitcask:get(U, lg_store_keys:usage_cost_key(H)) =:= not_found.

%% 错误索引：按日志键顺序每 1000 条日志一批，解码找出错误日志，补写 $e 索引
errors(_Gen, none, N) ->
    N;
errors(Gen, {Lo, Hi}, N) ->
    Fun = fun(K, _V, _Ts, _Ord, {C, Acc}) when C =:= ?BATCH -> throw({more, K, Acc});
             (K, V, _Ts, _Ord, {C, Acc}) ->
                  case lg_store:is_error(binary_to_term(V)) of
                      true -> {C + 1, [{put, lg_store_keys:idx_key(e, <<>>, K), <<>>} | Acc]};
                      false -> {C + 1, Acc}
                  end
          end,
    {Ops, C, Next} = try bitcask:range_fold(h(logs), {Lo, Hi}, [], Fun, {0, []}) of
                         {error, R} -> throw({failed, R});
                         {C0, Acc} -> {Acc, C0, none}
                     catch
                         throw:{more, K, Acc} -> {Acc, ?BATCH, {K, Hi}}
                     end,
    step(lg_store_writer:migrate(Gen, idx, Ops, #{errors => Next})),
    errors(Gen, Next, N + C).

%% 过期索引：整表扫一遍，给窗口内写入的旧格式条目补写过期索引（过期删除仍由 janitor 按索引做）
sweep(_Gen, _Cask, _Field, none) ->
    0;
sweep(Gen, Cask, Field, Window) ->
    Fun = fun(K, V, Ts, _Ord, {Ops, C, N}) ->
                  case in_window(Window, Ts) andalso not expiry_entry(Field, K, V) of
                      false ->
                          {Ops, C, N};
                      true ->
                          Op = case binary_to_term(V) of
                                   #{Field := T} when is_integer(T) -> lg_store_keys:expiry_op(Field, T, K);
                                   _ -> {remove, K}  %% 缺时间字段（旧清理同样直接删除）
                               end,
                          case C + 1 >= ?BATCH of
                              true ->
                                  step(lg_store_writer:migrate(Gen, Cask, [Op | Ops], #{})),
                                  {[], 0, N + 1};
                              false ->
                                  {[Op | Ops], C + 1, N + 1}
                          end
                  end
          end,
    case bitcask:range_fold(h(Cask), {undefined, undefined}, [], Fun, {[], 0, 0}) of
        {error, R} ->
            throw({failed, R});
        {Ops, _, N} ->
            step(lg_store_writer:migrate(Gen, Cask, Ops, #{Cask => none})),
            N
    end.

in_window(all, _) -> true;
in_window({From, To}, Ts) -> Ts >= From andalso Ts =< To.

%% 键形如过期索引且值与之完全一致（主键恰好以 0 开头时据此区分）
expiry_entry(Field, <<0, T:64, _/binary>>, V) -> V =:= lg_store_keys:expiry_val(Field, T);
expiry_entry(_, _, _) -> false.

%%====================================================================
%% 内部函数
%%====================================================================

%% 标记缺失、读失败或损坏都按无标记处理（查询走原有路径；写者启动时重建为首次升级）
read(U) ->
    try bitcask:get(U, lg_store_keys:usage_meta_key()) of
        {ok, V} -> case binary_to_term(V) of #{} = M -> M; _ -> undefined end;
        _ -> undefined
    catch
        _:_ -> undefined
    end.

hull(none, R) -> R;
hull(all, _) -> all;
hull({A, B}, {C, D}) -> {min(A, C), max(B, D)}.

hull_keys(none, R) -> R;
hull_keys({L1, H1}, {L2, H2}) ->
    {min(L1, L2), case H1 =:= undefined orelse H2 =:= undefined of
                      true -> undefined;
                      false -> max(H1, H2)
                  end}.

any_data(H) ->
    case first_key(H, undefined, undefined) of
        none -> none;
        _ -> all
    end.

%% [Lo, Hi) 内的第一个键；拿到即 throw 中止扫描
first_key(H, Lo, Hi) ->
    Fun = fun(K, _, _, _, none) -> throw({first, K});
             (_, _, _, _, Acc) -> Acc
          end,
    try bitcask:range_fold(H, {Lo, Hi}, [], Fun, none) of
        _ -> none
    catch
        throw:{first, K} -> K
    end.

h(Cask) ->
    lg_store_handles:handle(Cask).
