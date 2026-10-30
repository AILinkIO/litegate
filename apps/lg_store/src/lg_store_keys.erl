%% @doc 交互数据键编码。
%%
%% 日志键 12 字节：<<(MAX - TsUs):64, Seq:32>>。时间戳取反后升序扫描即新→旧，便于分页。
%% 日志 id 为日志键的十六进制（24 字符）。
%% 索引键：<<Type:8, Len:8, Dim:Len/binary, LogKey:12/binary>>，Type 为 $k（key_id）/ $r（route）/ $u（user_id）/ $t（标签）/ $c（客户端）
%% / $s（会话）/ $e（错误，Dim 为空：status ≥ 400 或 error 非空的日志）。
%% 会话（sessions cask）：<<$s, Sid/binary>> → 会话汇总；<<$a, (MAX - LastMs):64, Sid/binary>> → <<>>（按最近活动新→旧）。
%% 用量键：<<Hour:32, (term_to_binary(Dims))/binary>>，Hour 为 Unix 小时数；Dims 为
%% {KeyId, UserId, Route, Credential, Model}，或标签行 {tag, Tag}、客户端行 {client, Client}。
%% 派生行（T31，与上面的行同在 usage cask；term_to_binary 首字节恒为 131，而 Hour 远小于 16#FF000000，
%% 两类键互不重叠，旧版本的小时范围扫描也碰不到）：<<16#FF, 0, Hour:32>> → 该小时全部维度行之和；
%% <<16#FF, 1, Hour:32>> → 费用分解 #{{key, K} | {user, U} | {tag, T} => Cost}；<<16#FF, 16#FF>> → 回填标记（lg_store_migrate）。
%% 过期索引（cache / responses cask）：<<0, Ts:64, Key/binary>> → term_to_binary(#{Field => Ts})，Field 为 expires_at /
%% created_at；值固定可校验，主键恰好落进该范围时据此区分。
-module(lg_store_keys).

-export([new_log_key/0, log_key/2, id/1, from_id/1, ts_ms/1,
         log_bounds/2, idx_key/3, idx_bounds/4, usage_key/2, usage_bounds/2, hour/1,
         usage_total_key/1, usage_cost_key/1, usage_kind_bounds/3, usage_meta_key/0,
         expiry_op/3, expiry_val/2, expiry_bounds/1,
         session_key/1, recent_key/2, recent_bounds/2, recent_sid/1]).

-define(MAX, 16#FFFFFFFFFFFFFFFF).

-spec new_log_key() -> binary().
new_log_key() ->
    log_key(lg_time:now_us(), erlang:unique_integer([positive, monotonic]) band 16#FFFFFFFF).

-spec log_key(non_neg_integer(), non_neg_integer()) -> binary().
log_key(TsUs, Seq) ->
    <<(?MAX - TsUs):64, Seq:32>>.

-spec id(binary()) -> binary().
id(Key) ->
    binary:encode_hex(Key, lowercase).

-spec from_id(binary()) -> {ok, binary()} | error.
from_id(Id) when byte_size(Id) =:= 24 ->
    try {ok, binary:decode_hex(Id)} catch error:_ -> error end;
from_id(_) ->
    error.

%% @doc 日志键对应的毫秒时间戳。
-spec ts_ms(binary()) -> non_neg_integer().
ts_ms(<<Inv:64, _:32>>) ->
    (?MAX - Inv) div 1000.

%% @doc 时间区间 [FromMs, ToMs) 对应的日志键范围（新→旧）。
-spec log_bounds(non_neg_integer(), non_neg_integer()) -> {binary(), binary() | undefined}.
log_bounds(FromMs, ToMs) ->
    Lo = <<(?MAX - ToMs * 1000 + 1):64, 0:32>>,
    Hi = case FromMs of
             0 -> undefined;
             _ -> <<(?MAX - FromMs * 1000 + 1):64, 0:32>>
         end,
    {Lo, Hi}.

-spec idx_key(k | r | u | t | c | s | e, binary(), binary()) -> binary().
idx_key(Type, Dim, LogKey) ->
    <<(type(Type)), (byte_size(Dim)):8, Dim/binary, LogKey/binary>>.

%% @doc 某维度在时间区间内的索引键范围。
-spec idx_bounds(k | r | u | t | c | s | e, binary(), non_neg_integer(), non_neg_integer()) -> {binary(), binary()}.
idx_bounds(Type, Dim, FromMs, ToMs) ->
    Prefix = <<(type(Type)), (byte_size(Dim)):8, Dim/binary>>,
    {Lo, Hi} = log_bounds(FromMs, ToMs),
    HiKey = case Hi of
                undefined -> <<Prefix/binary, 16#FF:8, 16#FFFFFFFFFFFFFFFF:64, 16#FFFFFFFF:32>>;
                _ -> <<Prefix/binary, Hi/binary>>
            end,
    {<<Prefix/binary, Lo/binary>>, HiKey}.

-spec usage_key(non_neg_integer(), tuple()) -> binary().
usage_key(Hour, Dims) ->
    <<Hour:32, (term_to_binary(Dims))/binary>>.

%% @doc 覆盖 [FromMs, ToMs) 的小时范围（只含维度 / 标签 / 客户端行，上界不越过派生行）。
-spec usage_bounds(non_neg_integer(), non_neg_integer()) -> {binary(), binary()}.
usage_bounds(FromMs, ToMs) ->
    {min(<<(hour(FromMs)):32>>, <<16#FF>>), min(<<(hour(ToMs - 1) + 1):32>>, <<16#FF>>)}.

-spec usage_total_key(non_neg_integer()) -> binary().
usage_total_key(Hour) ->
    <<16#FF, 0, Hour:32>>.

-spec usage_cost_key(non_neg_integer()) -> binary().
usage_cost_key(Hour) ->
    <<16#FF, 1, Hour:32>>.

%% @doc 覆盖 [FromMs, ToMs) 的总量行（total）或费用分解行（cost）范围。
-spec usage_kind_bounds(total | cost, non_neg_integer(), non_neg_integer()) -> {binary(), binary()}.
usage_kind_bounds(Kind, FromMs, ToMs) ->
    K = case Kind of total -> 0; cost -> 1 end,
    {<<16#FF, K, (hour(FromMs)):32>>, <<16#FF, K, (hour(ToMs - 1) + 1):32>>}.

-spec usage_meta_key() -> binary().
usage_meta_key() ->
    <<16#FF, 16#FF>>.

%% @doc 过期索引写操作（与主键同批原子写入）。
-spec expiry_op(expires_at | created_at, non_neg_integer(), binary()) -> {put, binary(), binary()}.
expiry_op(Field, Ts, Key) ->
    {put, <<0, Ts:64, Key/binary>>, expiry_val(Field, Ts)}.

-spec expiry_val(expires_at | created_at, non_neg_integer()) -> binary().
expiry_val(Field, Ts) ->
    term_to_binary(#{Field => Ts}).

%% @doc 时间早于 Ms 的过期索引键范围。
-spec expiry_bounds(non_neg_integer()) -> {binary(), binary()}.
expiry_bounds(Ms) ->
    {<<0>>, <<0, Ms:64>>}.

-spec hour(non_neg_integer()) -> non_neg_integer().
hour(Ms) ->
    Ms div 3600000.

type(k) -> $k;
type(r) -> $r;
type(u) -> $u;
type(t) -> $t;
type(c) -> $c;
type(s) -> $s;
type(e) -> $e.

-spec session_key(binary()) -> binary().
session_key(Sid) ->
    <<$s, Sid/binary>>.

-spec recent_key(non_neg_integer(), binary()) -> binary().
recent_key(LastMs, Sid) ->
    <<$a, (?MAX - LastMs):64, Sid/binary>>.

-spec recent_sid(binary()) -> binary().
recent_sid(<<$a, _:64, Sid/binary>>) ->
    Sid.

%% @doc 最近活动在 [FromMs, ToMs) 的会话的最近活动键范围（新→旧）。
-spec recent_bounds(non_neg_integer(), non_neg_integer()) -> {binary(), binary()}.
recent_bounds(FromMs, ToMs) ->
    Hi = case FromMs of
             0 -> <<$b>>;
             _ -> <<$a, (?MAX - FromMs + 1):64>>
         end,
    {<<$a, (?MAX - ToMs + 1):64>>, Hi}.
