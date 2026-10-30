%% @doc 分层配置读取。
%%
%% 优先级（高 → 低）：
%%   1. 运行参数  mnesia lg_setting 表，控制台可在线修改
%%   2. 环境变量  LITEGATE_<KEY 大写>，值按默认值的类型转换
%%   3. sys.config  lg_core 应用环境
%%   4. 默认值    defaults/0
%%
%% 只有 defaults/0 里声明过的 key 才能读写，避免拼错的 key 静默生效。
-module(lg_config).

-include("lg_core.hrl").

-export([get/1, set/2, unset/1, all/0, defaults/0, data_dir/0, restart_keys/0, invalidate_all/0]).

-define(PT_DEFAULTS, {?MODULE, defaults}).
-define(CACHE, lg_config_cache).          %% 表由 lg_config_cache 进程持有
-define(VER, {?MODULE, version}).         %% 缓存版本号（与 atom 配置键不冲突）

%% @doc 已知配置项及默认值。
-spec defaults() -> #{atom() => term()}.
defaults() ->
    #{
      data_dir => "data",
      %% HTTP 服务
      http_port => 4000,
      %% 控制台 / API 监听地址；单机默认只允许 loopback，容器部署需显式绑定 0.0.0.0
      http_bind => <<"127.0.0.1">>,
      max_body_bytes => 32 * 1024 * 1024,
      %% 监听器连接上限；关停时排空在途请求的最长等待（T24）
      http_max_connections => 16384,
      shutdown_drain_ms => 20000,
      %% models.dev 同步
      catalog_url => <<"https://models.dev/api.json">>,
      catalog_sync_interval_ms => 0,          %% 0 = 不自动同步
      %% 上游请求
      upstream_connect_timeout_ms => 10000,
      upstream_timeout_ms => 300000,
      %% 上游连接池：每个主机保留的空闲连接数上限（T29）
      upstream_pool_idle_max => 128,
      %% 流式：首包后块间最长空闲、整个流的最长时长；上游响应体与单个 SSE 事件的大小上限（T25）
      stream_idle_timeout_ms => 120000,
      stream_max_ms => 1800000,
      upstream_max_body_bytes => 64 * 1024 * 1024,
      sse_max_event_bytes => 8 * 1024 * 1024,
      %% 出站请求的 User-Agent（请求头里已有时不覆盖，如凭证自定义头），空为不发送
      user_agent => <<"BeamAI LiteGate">>,
      %% 路由：一次请求最多尝试的上游目标数（含回退），失败目标的默认冷却时长
      route_max_attempts => 3,
      route_cooldown_ms => 10000,
      probe_interval_ms => 0,          %% 上游主动探活间隔，0 = 关闭
      plan_poll_interval_ms => 300000, %% 订阅套餐额度轮询间隔，0 = 只在请求后与手动刷新时查询
      balance_poll_interval_ms => 1800000, %% 按量付费 Key 余额轮询间隔，0 = 只在请求后与手动刷新时查询
      %% 单凭证并发上限（凭证选项 max_concurrency）满时的排队：每个凭证最多排队数、最长等待
      queue_limit => 32,
      queue_wait_ms => 30000,
      %% 流式保活：开流前等待上游超过 stream_hold_ms 先向客户端发 200 与注释帧；开流后上游 keepalive_ms 无数据时写注释帧
      stream_hold_ms => 15000,
      %% 开流前等待总上限（含排队与候选回退）：超过后不再尝试新候选，以 504 结束；0 = 不限
      stream_hold_max_ms => 300000,
      %% 所有候选都繁忙（5xx / 超时 / 网络 / 短时限流）且客户端还没收到内容时，等待 patience_ms 后整轮再试，最多 patience_rounds 轮
      patience_ms => 2000,
      patience_rounds => 1,
      %% 流式复读检测：同一片段（≥ 8 字节）连续重复、或同一行在最近 2×N 行中出现 N 次即判定为复读并结束输出
      loop_repeat => 30,
      keepalive_ms => 15000,
      %% 敏感信息脱敏（Key / 路由选项 redact 开启）：自定义规则 JSON 数组 [{"name": …, "pattern": 正则}]；
      %% 额外启用的个人信息类别，逗号分隔：id_card, bank_card, phone
      redact_rules => <<>>,
      %% 中间件插件目录（*.beam 与 */ebin/*.beam），空为 <data_dir>/plugins
      middleware_plugin_dir => <<>>,
      redact_pii => <<>>,
      %% 规则路由：意图判断超时；时段条件（hours）使用的时区偏移（分钟，默认 UTC+8）
      intent_timeout_ms => 8000,
      %% 本地意图判断（路由选项 intent_engine = laya）：Laya 服务地址（空为不可用）、命中所需最低概率、超时
      %% 超时要短于 intent_timeout_ms，失败时还有时间改问后备判断模型
      laya_enabled => true,          %% 全局开关：关闭时选了 laya 的路由直接用后备判断路由
      laya_url => <<>>,
      laya_min_prob => 0.7,
      laya_timeout_ms => 2000,
      %% 决策模型意图判断（路由选项 intent_engine = systemone，如百炼 decision-model-preview）：命中所需最低概率、超时
      decision_min_prob => 0.7,
      decision_timeout_ms => 3000,
      timezone_offset_min => 480,
      %% OTLP/HTTP 链路导出（Langfuse：端点 https://<host>/api/public/otel，请求头 Authorization=Basic%20<base64(pk:sk)>）
      otlp_enabled => false,
      otlp_endpoint => <<>>,
      otlp_headers => <<>>,
      otlp_bodies => false,
      otlp_queue_max_bytes => 67108864,  %% 64MB
      %% OTLP 指标导出：复用 otlp_endpoint / otlp_headers，推到 /v1/metrics
      otlp_metrics_enabled => false,
      otlp_metrics_interval_ms => 60000,
      %% 出站自适应限流（T08/T09）：429 反馈 AIMD 节流，对所有模型统一生效
      out_rate_enabled => true,
      out_rate_factor => 0.7,
      out_rate_min_rpm => 6,
      out_rate_recovery_ms => 120000,
      out_rate_wait => queue,   %% queue（窗口滚动后放行）| fail（立即 429）
      %% 交互数据
      record_messages => true,
      %% 存储写入积压降级（T21）：写者队列超过 soft 丢弃对话与检索文档，超过 hard 只保留用量
      store_queue_soft => 5000,
      store_queue_hard => 50000,
      log_retention_days => 30,        %% 日志、对话、索引保留天数，0 = 永久
      usage_retention_days => 400,     %% 小时用量汇总保留天数，0 = 永久
      %% 配置自动备份：口令推荐用环境变量 LITEGATE_BACKUP_PASSPHRASE 设置（不落在 mnesia 里）
      backup_enabled => false,
      backup_interval_h => 24,         %% 备份间隔（小时）
      backup_keep => 14,               %% 保留份数，超出滚动删除
      backup_passphrase => <<>>,       %% 导出加密口令（≥ 8 字节），为空时备份报错
      %% 告警：同一事件在静默期内只通知一次
      alert_silence_ms => 30 * 60 * 1000,
      %% 上游恢复需持续健康这么久才发恢复通知，避免故障/恢复抖动刷屏（T27）
      alert_recover_ms => 60000,
      %% /metrics 抓取令牌，非空时要求 Authorization: Bearer <token>
      metrics_token => <<>>,
      %% 控制台登录：false（默认，单机）时控制台与管理 API 无需登录，访问者视为管理员
      console_auth => false,
      %% 非回环绑定且未开鉴权时默认拒绝启动；true 放行（破坏性变更，容器部署须显式设置）
      allow_insecure_bind => false,
      %% TLS 监听器（T13）：可与 clear 并存；启用时证书文件必须可读
      tls_enabled => false,
      tls_port => 443,
      tls_cert_file => <<>>,
      tls_key_file => <<>>,
      session_ttl_ms => 7 * 24 * 3600 * 1000
     }.

%% @doc 仅在启动时读取的配置项（T13：控制台显示"需重启生效"徽标）。
-spec restart_keys() -> [atom()].
restart_keys() ->
    [data_dir, http_port, http_bind, max_body_bytes, http_max_connections,
     tls_enabled, tls_port,
     tls_cert_file, tls_key_file].

%% 两级缓存：persistent_term 缓存 defaults（避免每次重建 ~60 项 map）+ ETS 缓存上两层的解析结果
%% （避免 mnesia dirty_read 与 os:getenv）。缓存条目为 {Key, {value, V}}（运行参数 / 环境变量层命中）
%% 或 {Key, lower}（两层都没有），lower 时实时读 sys.config 应用环境与默认值（均为一次 ETS / map 查找）。
%% 环境变量在首次读取时进入缓存，运行中修改需调用 invalidate_all/0。
%% 回填期间若有写入（版本号变化）则撤销回填，防止把刚失效的旧值写回（T18）
-spec get(atom()) -> term().
get(Key) ->
    case maps:find(Key, pterm_defaults()) of
        {ok, Default} ->
            Upper = try ets:lookup(?CACHE, Key) of
                        [{_, U}] -> U;
                        [] -> fill(Key, Default)
                    catch
                        error:badarg -> upper(Key, Default)  %% lg_core 未启动：不缓存
                    end,
            case Upper of
                {value, V} -> V;
                lower -> application:get_env(lg_core, Key, Default)
            end;
        error -> error({unknown_config, Key})
    end.

fill(Key, Default) ->
    Ver = version(),
    U = upper(Key, Default),
    true = ets:insert(?CACHE, {Key, U}),
    %% 写入方顺序是"写存储 → 版本 +1 → 删条目"：版本没变说明 upper 读到的不早于最近一次写入；
    %% 版本变了则本次回填可能是旧值，撤销（最多多一次 miss）
    version() =:= Ver orelse ets:delete(?CACHE, Key),
    U.

%% 运行参数层与环境变量层
upper(Key, Default) ->
    case runtime(Key) of
        {ok, V} -> {value, V};
        error ->
            case os_env(Key, Default) of
                {ok, V} -> {value, V};
                error -> lower
            end
    end.

version() ->
    case ets:lookup(?CACHE, ?VER) of
        [{_, N}] -> N;
        [] -> 0
    end.

%% @doc 清空全部已解析值缓存（配置导入 / 恢复、运行中修改环境变量后调用）。
-spec invalidate_all() -> ok.
invalidate_all() ->
    try
        _ = ets:update_counter(?CACHE, ?VER, 1, {?VER, 0}),
        _ = ets:select_delete(?CACHE, [{{'$1', '_'}, [{'=/=', '$1', {const, ?VER}}], [true]}]),
        ok
    catch
        error:badarg -> ok
    end.

%% @doc 写入运行参数层。
-spec set(atom(), term()) -> ok.
set(Key, Value) ->
    maps:is_key(Key, pterm_defaults()) orelse error({unknown_config, Key}),
    mnesia:dirty_write(#lg_setting{key = Key, value = Value, updated_at = lg_time:now_ms()}),
    invalidate(Key).

%% @doc 删除运行参数，回落到下层。
-spec unset(atom()) -> ok.
unset(Key) ->
    mnesia:dirty_delete(lg_setting, Key),
    invalidate(Key).

%% @doc 所有配置项的生效值及来源。
-spec all() -> [#{key := atom(), value := term(), source := runtime | env | app | default}].
all() ->
    Defs = pterm_defaults(),
    [begin
         {V, Src} = resolve(K, D),
         #{key => K, value => V, source => Src}
     end || {K, D} <- lists:sort(maps:to_list(Defs))].

%% @doc 数据根目录；mnesia 启动前就要用，不走运行参数层。
-spec data_dir() -> file:filename().
data_dir() ->
    case os_env(data_dir, "") of
        {ok, V} -> V;
        error -> application:get_env(lg_core, data_dir, "data")
    end.

%%====================================================================
%% 内部函数
%%====================================================================

resolve(K, D) ->
    case runtime(K) of
        {ok, V} -> {V, runtime};
        error ->
            case os_env(K, D) of
                {ok, V} -> {V, env};
                error ->
                    case application:get_env(lg_core, K) of
                        {ok, V} -> {V, app};
                        undefined -> {D, default}
                    end
            end
    end.

runtime(Key) ->
    try mnesia:dirty_read(lg_setting, Key) of
        [#lg_setting{value = V}] -> {ok, V};
        [] -> error
    catch
        exit:{aborted, _} -> error  %% mnesia 未就绪
    end.

os_env(Key, Default) ->
    Name = "LITEGATE_" ++ string:uppercase(atom_to_list(Key)),
    case os:getenv(Name) of
        false -> error;
        "" -> error;
        S -> {ok, convert(S, Default)}
    end.

convert(S, D) when is_integer(D) -> list_to_integer(S);
convert(S, D) when is_boolean(D) -> lists:member(string:lowercase(S), ["1", "true", "yes", "on"]);
convert(S, D) when is_binary(D) -> unicode:characters_to_binary(S);
convert(S, _) -> S.

%% 惰性初始化：首次调用时把 defaults() 写入 persistent_term（原子读，后续零开销）
pterm_defaults() ->
    case persistent_term:get(?PT_DEFAULTS, undefined) of
        undefined ->
            D = defaults(),
            persistent_term:put(?PT_DEFAULTS, D),
            D;
        D -> D
    end.

%% 只移除对应 key 的缓存条目；先递增版本，让并发中的回填自行撤销
invalidate(Key) ->
    try
        _ = ets:update_counter(?CACHE, ?VER, 1, {?VER, 0}),
        true = ets:delete(?CACHE, Key),
        ok
    catch
        error:badarg -> ok
    end.
