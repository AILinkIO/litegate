# 更新日志

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循语义化版本。
版本号以 `rebar.config` 的 release 为准，控制台侧栏与 `GET /api/version` 显示同一版本与 git commit。

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
