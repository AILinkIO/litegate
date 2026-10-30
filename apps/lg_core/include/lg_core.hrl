%% LiteGate 元数据记录定义（mnesia 表结构）
%%
%% 配置分层：
%%   L0 lg_catalog_provider / lg_catalog_model  models.dev 同步，只读参考
%%   L1 lg_model_overlay                        用户新增/覆盖，同步永不触碰
%%   L2 lg_credential                           上游连接与凭证
%%   L3 lg_route                                对外宣告的模型（唯一入口）
%% 访问控制：lg_user / lg_api_key / lg_session
%% 运行参数：lg_setting；内部元信息：lg_meta

-ifndef(LG_CORE_HRL).
-define(LG_CORE_HRL, true).

-type lg_ts() :: non_neg_integer().            %% 毫秒时间戳
-type lg_model_ref() :: {binary(), binary()}.  %% {ProviderId, ModelId}

%% ---- L0：models.dev 参考目录 ----
-record(lg_catalog_provider, {
    id           :: binary(),
    name         :: binary(),
    npm          :: binary() | undefined,   %% 决定协议适配器
    api          :: binary() | undefined,   %% 默认 base_url
    env = []     :: [binary()],
    doc          :: binary() | undefined,
    synced_at    :: lg_ts()
}).

-record(lg_catalog_model, {
    key          :: lg_model_ref(),
    provider     :: binary(),               %% 二级索引
    info = #{}   :: map(),                  %% 规范化后的模型属性（name/limit/cost/modalities...）
    synced_at    :: lg_ts()
}).

%% ---- L1：用户覆盖 ----
-record(lg_model_overlay, {
    key          :: lg_model_ref(),
    provider     :: binary(),               %% 二级索引
    info = #{}   :: map(),                  %% 与 L0 info 同结构，按字段覆盖；无对应 L0 则为自定义模型
    created_at   :: lg_ts(),
    updated_at   :: lg_ts()
}).

%% ---- L2：凭证 ----
-record(lg_credential, {
    id           :: binary(),
    name         :: binary(),
    protocol     :: openai | anthropic,
    base_url     :: binary(),
    api_key_enc  :: binary() | undefined,   %% lg_crypto:encrypt/1 密文
    headers = [] :: [{binary(), binary()}], %% 额外请求头
    provider     :: binary() | undefined,   %% 关联的 L0/L1 供应商 id，用于定价查询
    options = #{} :: map(),                 %% 扩展选项（v2）：responses_api => boolean()
    enabled = true :: boolean(),
    created_at   :: lg_ts(),
    updated_at   :: lg_ts()
}).

%% ---- L3：路由表 ----
%% 路由成员有两类：直连上游目标，或嵌套引用另一条非通配路由
-type lg_direct_target() :: #{credential := binary(),
                              upstream_model := binary(),
                              model_ref => lg_model_ref(),
                              weight => pos_integer(),      %% 同优先级内按权重随机，默认 1
                              priority => non_neg_integer(),%% 越小越先尝试，默认 0
                              enabled => boolean()}.
-type lg_nested_target() :: #{route := binary(),
                              weight => pos_integer(),
                              priority => non_neg_integer(),
                              enabled => boolean()}.
-type lg_route_target() :: lg_direct_target() | lg_nested_target().

-record(lg_route, {
    name         :: binary(),               %% 对外模型名
    targets = [] :: [lg_route_target()],
    fallbacks = [] :: [binary()],           %% 回退的路由名，按顺序
    access = all :: all | [binary()],       %% 允许调用的网关 Key id
    options = #{} :: map(),                 %% 扩展选项（v2）：cache_ttl_s => non_neg_integer()
    enabled = true :: boolean(),
    created_at   :: lg_ts(),
    updated_at   :: lg_ts()
}).

%% 路由别名：客户端请求的精确模型名 → 路由（如编码工具的默认模型名），全局唯一
-record(lg_route_alias, {
    alias        :: binary(),
    route        :: binary()                %% 二级索引
}).

%% 网关中间件：按顺序在请求、流式事件、响应三个点位上运行
-record(lg_middleware, {
    id           :: binary(),
    name         :: binary(),
    impl         :: binary(),                %% 实现：内置名（model_map、system_prompt …），将来 lua
    options = #{} :: map(),                  %% 传给实现的配置（JSON 对象）
    routes = all :: all | [binary()],        %% 作用的路由（客户端请求解析出的路由名）
    position = 0 :: integer(),               %% 越小越先运行
    enabled = true :: boolean(),
    created_at   :: lg_ts(),
    updated_at   :: lg_ts()
}).

%% 上游参数兼容：某凭证 + 上游模型不支持的特性，由上游 400 的错误信息学到
-record(lg_unfit, {
    key          :: {binary(), binary(), atom()},   %% {CredentialId, UpstreamModel, Feature}
    message      :: binary(),                        %% 学到时上游的错误信息（截断）
    learned_at   :: lg_ts()
}).

%% ---- 访问控制 ----
-record(lg_user, {
    id           :: binary(),
    username     :: binary(),               %% 二级索引
    password_hash :: binary(),
    role = user  :: admin | user,
    enabled = true :: boolean(),
    created_at   :: lg_ts()
}).

-record(lg_api_key, {
    id           :: binary(),
    hash         :: binary(),               %% 二级索引，lg_crypto:hash_token/1
    prefix       :: binary(),               %% 展示用前缀
    name         :: binary(),
    user_id      :: binary() | undefined,   %% 二级索引
    allowed_routes = all :: all | [binary()],
    max_tokens   :: pos_integer() | undefined,
    enabled = true :: boolean(),
    expires_at   :: lg_ts() | undefined,
    tags = []    :: [binary()],             %% 默认请求标签（v3）
    options = #{} :: map(),                 %% 扩展选项（v4）：redact => boolean()
    created_at   :: lg_ts()
}).

%% 控制台 Playground 使用的内置 Key id（不落库，不受路由访问列表约束）
-define(LG_PLAYGROUND_KEY, <<"playground">>).

-record(lg_session, {
    hash         :: binary(),               %% 登录 token 哈希
    user_id      :: binary(),
    expires_at   :: lg_ts()
}).

%% ---- 流量控制 ----
-type lg_limit_scope() :: {key, binary()} | {route, binary()} | {key_route, binary(), binary()}.
-type lg_budget_scope() :: {key, binary()} | {user, binary()} | {tag, binary()}.

-record(lg_limit, {
    scope        :: lg_limit_scope(),
    rpm          :: pos_integer() | undefined,   %% 每分钟请求数
    tpm          :: pos_integer() | undefined,   %% 每分钟 token 数（输入 + 输出）
    max_parallel :: pos_integer() | undefined,   %% 同时进行的请求数
    updated_at   :: lg_ts()
}).

-record(lg_budget, {
    scope        :: lg_budget_scope(),
    period       :: day | week | month,          %% UTC 自然周期
    max_usd      :: number(),
    updated_at   :: lg_ts()
}).

%% ---- 告警 ----
-record(lg_channel, {
    id           :: binary(),
    name         :: binary(),
    type         :: webhook | feishu | dingtalk | wecom,
    url_enc      :: binary(),                 %% 机器人地址含令牌，加密存储
    secret_enc   :: binary() | undefined,     %% 飞书 / 钉钉签名密钥
    enabled = true :: boolean(),
    created_at   :: lg_ts(),
    updated_at   :: lg_ts()
}).

-type lg_alert_event() :: budget | upstream_down | plan_quota | catalog_sync_failed | balance_low
                          | login_brute_force.

-record(lg_alert_rule, {
    id           :: binary(),
    event        :: lg_alert_event(),
    threshold    :: number() | undefined,     %% budget / plan_quota：百分比；upstream_down：连续失败次数
    channels = [] :: [binary()],
    enabled = true :: boolean(),
    created_at   :: lg_ts(),
    updated_at   :: lg_ts()
}).

%% ---- 运行参数与元信息 ----
-record(lg_setting, {
    key          :: atom(),
    value        :: term(),
    updated_at   :: lg_ts()
}).

-record(lg_meta, {
    key          :: atom() | {schema_step, atom(), non_neg_integer()},  %% 后者为迁移进度（lg_schema）
    value        :: term()
}).

-endif.
