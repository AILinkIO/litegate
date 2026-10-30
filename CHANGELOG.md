# 更新日志

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循语义化版本。
版本号以 `rebar.config` 的 release 为准，控制台侧栏与 `GET /api/version` 显示同一版本与 git commit。

## 未发布

第二轮审查的 P0 回归修复、P1 稳定度加固与 P2 性能优化（[D05](designs/D05-regressions-stability-perf.md)，T16–T33）。

### 修复

- **通配路由重启后 404**：通配前缀缓存改由常驻进程 `lg_route_cache` 持有并在启动时构建，
  不再随首个请求进程退出而销毁；重建先插入后删除，无空窗；名称恰好等于前缀（如 `or/`）时
  恢复为落到更短的通配（1.1.0 起误匹配为剩余部分为空）。
- **出站自适应限流**：清扫不再每分钟清空全部速率窗口；凭证更新后正确清除该凭证的学习状态；
  首次 429 的 Cap 按实测速率 × `out_rate_factor` 计算（1.1.0 恒为 `out_rate_min_rpm`）；
  同一波并发 429 只下调一次；带 Retry-After 的 429 同时建立 Cap；有上限时放行即预占，
  排队者不会在窗口滚动时一起放行；无 429 持续 4×`out_rate_recovery_ms` 后自动解除；
  学习状态 24h 无更新回收；排队等待成功后保留后续回退候选。
- **配置缓存**：导入 / 恢复配置后运行参数立即生效（此前需重启）；修复并发读写时旧值回写缓存；
  缓存随 lg_core 启停，`sys.config` 应用环境不再缓存。
- **冷却表清扫从未运行**：`lg_cooldown` 启动时调度首次清扫。
- **realtime（`/v1/live`）**：按 gun 2.x 消息格式识别上游断开并结束会话（此前会话挂起）；
  上游 WebSocket 连接校验 TLS 证书与主机名并带 SNI。
- **OTLP 导出进程崩溃**：队列超过 50% 字节阈值剥离请求体时计数出错导致进程崩溃，
  反复崩溃会使 lg_router 应用退出、节点停机。

### 稳定度

- **客户端断开感知**：排队、整轮重试等待、等上游响应头期间以及非流式请求中客户端断开，约 1s 内取消上游、
  释放并发名额并停止回退；请求日志记 499（`client_closed`），已产生的用量照常计费；非流式请求不再因断开
  丢失日志与预算记账。新增指标 `litegate_client_closed_total`。
- **存储写入背压与写盘错误**：写者邮箱移到堆外并按积压分级降级（`store_queue_soft` / `store_queue_hard`，
  计数 `litegate_store_degraded_total`），检索索引拆到独立进程；写盘错误计数 `litegate_store_write_errors_total`
  并使 `/health` 返回 degraded（此前静默丢失）；写失败或写者崩溃不再重复计入用量 / 会话；cask 句柄改由
  `lg_store_handles` 持有，写者重启期间响应缓存与 Responses 读取不再 500。
- **并发排队与限流槽位**：排队中断开的客户端立即移出队列，不再占满 `queue_limit`；并发控制进程重启时排队者
  立即返回；进程忙或不可用时按 busy 处理不再崩溃；限流并发槽位只归还实际持有的部分，占槽瞬间被 kill 不再泄漏。
- **额度 / 余额刷新去重**：每个凭证最多一个查询在进行，查询在独立 worker 中执行，高 QPS 下不再堆积刷新消息；
  控制台「立即刷新」超时返回当前状态（带 `refreshing` 标记），不再报错。
- **流式超时分级与上限（行为变更）**：首包后块间空闲超时由沿用 `upstream_timeout_ms`（300s）**改为
  `stream_idle_timeout_ms`，默认 120s**；新增流总时长上限 `stream_max_ms`（默认 30 分钟）；非流式响应体
  改为有上限的接收（`upstream_max_body_bytes`，默认 64MB，按发出请求后的总时长截止），SSE 单事件上限
  `sse_max_event_bytes`（默认 8MB）。新增指标 `litegate_upstream_timeouts_total{phase}`。
- **运行时与部署**：mnesia 改为 permanent 启动，`/health` 在 mnesia 未运行时返回 503；关停时暂停监听并等在途
  请求完成（`shutdown_drain_ms`）；新增 `http_max_connections`；compose 增加 `stop_grace_period: 60s` 与 nofile 65536；
  vm.args 删除无效的 `+K` / `+A`，增加 `+sbwt none +sbwtdcpu none +sbwtdio none` 与 `+Q 65536`。
- **schema 迁移**：迁移可重入（按表记录进度、识别已转换的记录），每个版本只备份一次；节点名与数据目录不符时
  拒绝启动，不再静默改写日志；`lg_schema:rename_node/1` 重写为可用的离线改名；`rebar3 shell` 节点名改为
  `litegate@127.0.0.1`，与 release 一致。
- **意图判断熔断**：判断者连续失败 3 次熔断 30 秒（`litegate_classifier_skipped_total`），相同判断并发合并；
  判断超时不再丢失日志与费用。
- **告警防抖**：规则缓存，无规则时热路径零开销；upstream_down 恢复需持续健康 `alert_recover_ms`，并受
  `alert_silence_ms` 静默期约束，抖动不再刷屏；发送队列上限 1000 条（`litegate_alert_dropped_total`）；
  连续失败计数 24h 无更新自动清理。

### 性能

- **SSE 增量解析**：只在新到的数据块中查找事件分隔符，`\r` 规范化只作用于单个事件；MB 级事件分 2000 块
  到达时解析从约 200ms 降到约 1ms，耗时与块数近似线性。
- **复读检测**：只处理新增文本，半行截到 1KB；单行 50KB 输出的内存分配从约 54MB 降到约 2.5MB。
- **流式文本累积**：拷贝 delta，不再钉住上游原始数据块；10 万 token 流的进程 binary 引用从约 3.4MB 降到 20KB 以内。
- **流式事件单次解码**：Responses 转换、think 拆分、结构化输出共用同一个已解码事件，每事件解码从最多 3～4 次降为 1 次。
- **上游背压与连接池**：流式上游开启 gun flow 控制（窗口 8 条），慢客户端时背压经 TCP 传回上游，处理进程邮箱
  不再无限增长；归还连接时池进程不再调用 gun，超限 / 过期连接异步关闭；每主机空闲上限 `upstream_pool_idle_max`
  （默认 128，原为固定 32）；新增 `litegate_upstream_connections_total{result}`。
- **存储查询**：`errors_only` 走错误索引（5 万条日志首页从约 125ms 降到 0.5ms）；概览与预算启动只读每小时总量 /
  费用分解行（15 天概览解码行数从 14400 降到 360）；告警列表只读最近时间窗口。
- **janitor**：删除每批 ≤1000 键并跨索引前缀合并，删除非 usage 数据时不再 flush 用量；响应缓存与 Responses 记录
  按过期索引的时间范围分批清理，不再整表解码后一次性大批删除。
- **rotate 策略**：按目标维护会话计数，10 万会话时单次选择从约 60ms 降到约 1µs。
- 出站限流判定复用尝试计划中的凭证记录；内置中间件（含 remote）在请求进程内运行，不再拷贝请求体
  （插件仍在独立进程中运行，超时可被打断）。

### 存储格式（向后兼容）

- 只新增派生数据：usage cask 的 `0xFF` 前缀行（每小时总量、费用分解、回填标记）、idx cask 的 `$e` 错误索引、
  cache / responses cask 的过期索引；原有键与值格式不变。升级后 janitor 在后台自动回填，回填完成前查询走原有路径，
  结果不变。可直接降级回上一版本；降级后再升级会自动补上降级期间写入的数据。详见 [部署](docs/deploy.md#升级)。

### 修复（续）

- 丢弃上游连接时先关闭、等连接进程退出后再按连接清理邮箱（含 `gun_down`），lg_otlp、lg_notify 等长生命周期进程
  不再累积残留消息。
- 复用连接失败后只在可判定请求未被上游处理时重发（gun 进程已退出，或发出后 50ms 内断开），避免重复发送 POST、重复计费。
- 健康页「最近结果」与实时视图「路由最近叙述」超过 24 小时未更新的条目会被清理。
- 配置备份：目录不可写、写入或改名失败时返回错误，不再导致进程崩溃；文件名精确到毫秒，同一秒内多次备份不再互相覆盖。
- 配置导出在只读事务中读取各表（对事务性写入是同一时刻的快照）。
- **管理 API 重复回复**：`lg_api_admin` 处理的资源（凭证、路由、运行参数等）回复后仍会落到 `lg_api` 的 404 兜底再回复一次，
  cowboy 因重复回复让连接进程崩溃，keep-alive 连接上的后续请求随之失败；现在只有未命中时才继续匹配。
- 模型目录：运行时修改 `catalog_sync_interval_ms` 下一轮即生效（包括从 0 开启）；从网络同步时若要删除 30% 以上现有
  模型则中止并记为同步失败（触发 `catalog_sync_failed` 告警），手动导入不受此限。

## 1.1.0 — 2026-10-21

内存安全与热路径性能治理，出站自适应限流，控制台登录与安全默认值收紧，Docker Compose 部署。

### 新增

- **出站自适应限流**（对所有供应商与模型统一生效）：按 `{凭证, 模型}` 记录最近一分钟出站 QPM，
  上游返回 429 时以 AIMD 反馈降低发送速率——首犯乘以 `out_rate_factor`、再犯减半、不低于
  `out_rate_min_rpm`，窗口内不再撞墙则按 `out_rate_recovery_ms` 自动回升。
  参数：`out_rate_enabled`、`out_rate_factor`、`out_rate_min_rpm`、`out_rate_recovery_ms`。
- **节流等待策略**：`out_rate_wait = queue`（默认，等待速率窗口滚动后放行）或 `fail`（立即返回 429）；
  凭证选项新增静态上限 `max_rpm`，生效上限取学习 Cap 与 `max_rpm` 的较小值。
- **出站速率观测**：控制台「上游健康」页显示每个凭证的出站 RPM 与冷却、节流状态，
  「仪表盘」新增 429 节流卡片，Prometheus 暴露 `litegate_out_qpm` 与 `litegate_out_throttled_total`。
- **非 chat 端点的 `stream: true` 兼容**：嵌入、重排等非流式端点忽略流式标记并按同步返回，
  请求日志记 `stream_ignored`，不再静默挂起。
- **TLS 监听**：`tls_enabled`、`tls_port`、`tls_cert_file`、`tls_key_file`；HTTPS 与明文监听可同时启用。
- **配置「需重启」标注**：只在启动时读取的参数（数据目录、监听地址与端口、最大请求体、TLS 相关）
  在控制台运行参数页标记为需重启生效。
- **控制台版本显示**：侧栏底部显示 `v<版本> · <commit>`，`GET /api/version` 返回版本与 commit，
  Docker 与 release 构建通过 `GIT_SHA` 注入。
- **Docker Compose 部署**：新增 `docker-compose.yml` 与 `deploy/litegate.env` 模板，
  镜像标签默认 `litegate:1.1.0`，状态固定在容器内 `/data`。
- **多实例部署文档**：`docs/deploy.md` 说明配额、并发、冷却、粘性、节流 Cap 均为节点本地的语义与折算方式。

### 变更

- **破坏性：非回环绑定默认拒绝启动**。HTTP 绑定非 loopback 地址、`console_auth = false`
  且未显式放行时网关启动失败并给出迁移指引：开启控制台登录、改绑回环地址，
  或设置 `allow_insecure_bind = true` 明确接受风险。详见 [配置](docs/configuration.md)。
- **OTLP 队列按字节封顶**：新增 `otlp_queue_max_bytes`（默认 64MB），队列达到阈值先剥离请求体，
  超限丢弃最旧条目，避免导出端不可达时链路在内存里无限堆积。
- 冷却（`lg_cooldown`）只负责失败退避，速率上限交给出站节流；上游 429 不再只降权。
- 版本号统一到 1.1.0（release、各 `*.app.src`、OpenAPI 与控制台显示一致）。

### 性能

- `lg_config:get/1` 两级缓存（persistent_term 存默认值 + 已解析值缓存），热路径读取零 Mnesia 访问。
- `lg_metrics` 渲染与快照改为 Rows → RowMap，消除按标签组合的 O(n²) 扫描。
- 通配路由匹配结果预编译进 ETS 缓存，路由写入后全量重建。
- `lg_store` 查询 flush 按范围拆分（`logs` / `all`），两类写出不互相阻塞。
- token 估算改为 binary 逐码点扫描，消除大字符串的 `characters_to_list` 分配。

### 修复

- `login_guard`、`cooldown`、`affinity`、`session` 状态表补齐周期清扫，长跑进程不再单调增长。
- `mw_remote` 动态原子改用 `binary_to_existing_atom`，避免远程中间件配置污染原子表。

## 1.0.0 — 2026-10-16

初始实现（工程内版本号 0.1.0）。

- 兼容 OpenAI 与 Anthropic 接口格式的 LLM API 网关，流式与非流式转发。
- 多凭证路由、优先级分组与失败回退，六种同优先级策略，路由别名与通配匹配。
- 规则路由（改写、注入、拦截）、会话粘性与上游亲和。
- 额度控制、预算与限流（入站 RPM/TPM/并发、上游并发闸、套餐额度）。
- 请求日志、会话、用量计费统计，Prometheus 指标、OTLP 链路导出与告警。
- React 管理控制台：模型目录、凭证、路由、API Key、接入指南、运行参数与用户。
- systemd 与 Docker 部署脚本，Mnesia/Bitcask 持久化与配置自动备份。
