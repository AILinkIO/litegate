# D04 功能增强与安全（P1 安全项 + P2 功能项 + 路线图）

状态：待实施 ｜ 对应任务：T10（P1）、T12、T13、T15（P2）；§5 为暂不排期的路线图

## 1. console_auth 严格模式（P1，安全）

现状：`console_auth` 默认 false；`http_bind` 非 loopback 且未开鉴权时仅打 warning，
控制台与管理 API（含凭证 Key 明文管理、中间件配置）对外裸奔。容器部署
`http_bind = 0.0.0.0` 极其常见，warning 极易被忽略。

设计：

- 启动检查：绑定地址非 loopback（含 `0.0.0.0`/`::`）且 `console_auth = false` 时，
  **默认拒绝启动**（`lg_web_app` 启动阶段报错并给出明确指引）。
- 新增配置 `allow_insecure_bind`（默认 false）：显式设为 true 才允许上述组合启动，
  并保留现有 warning。已有部署升级时若命中该组合会启动失败——这是有意的破坏性变更，
  RELEASE NOTES 与 `docs/deploy.md` 显著标注。
- `/health`、`/metrics`（如已单独暴露）与 `/v1` 网关路径不受影响，只约束
  `/console` 与 `/api` 管理面。

验收：eunit 覆盖四种组合（loopback/非 loopback × auth 开/关 × allow_insecure）；
文档更新。

## 2. 非 chat 端点的 stream:true 兼容（P2）

现状：`lg_web_llm:call_prepared` 只在 `Kind =:= chat` 时走流式路径；
OpenAI SDK 对 embeddings/images/speech 也接受 `stream: true`（部分端点会真流式，
部分回退整包），当前网关静默忽略该字段。

设计（按端点分级）：

- **透传优先**：请求体含 `stream: true` 且上游协议原生支持流式（OpenAI audio、
  images 部分实现）→ 走既有 `lg_stream`/SSE 管道原样透传，网关侧只做日志聚合
  （`lg_stream:result()` 已支持非文本 body 的字节记账）。
- **不支持流式的上游/端点**：保持整包 JSON 返回（与 OpenAI 官方对多数非 chat 端点的
  实际行为一致），但在响应日志 attempt 信息里记 `stream_ignored => true`，
  控制台请求详情可见，避免"配置了却没生效"的困惑。
- 改动集中在 `lg_web_llm` 的 Kind 分支与 `lg_provider` 各适配器的能力声明
  （协议元数据加 `streamable_kinds`）。

验收：对 mock 上游分别验证 chat/embeddings/audio 的 stream 行为；现有 e2e eunit 全绿。

## 3. 监听器与配置热更新、TLS（P2）

现状：仅 `cowboy:start_clear`（无 TLS）；`idle_timeout`、`max_body_bytes` 等监听器
参数只在启动时读一次，控制台在线修改后需重启才生效，与"运行参数在线改"的整体
体验不一致。

设计：

1. **配置项分级标注**：`lg_config:defaults/0` 每项附元数据 `#{restart => true|false}`；
   控制台设置页对 restart 项显示"需重启生效"徽标。低成本、先消除困惑。
2. **TLS 监听**：新增 `tls_enabled`、`tls_cert_file`、`tls_key_file`、`tls_port`
   配置；`lg_web_app` 按配置追加 `cowboy:start_tls` 监听器（可与 clear 并存）。
   证书文件变更通过重启监听器生效（cowboy `set_opts` 支持 SNI 证书热换，首版不做）。
3. **监听器参数热更**（可选后续）：`max_body_length`/`idle_timeout` 属
   `cowboy:set_opts` 可热改项，配置写入钩子里调用；首版仅做 1+2。

验收：TLS 监听 e2e（自签证书 + curl -k）；控制台徽标显示正确。

## 4. 多实例部署的配额语义（P2，文档先行）

现状：`lg_limiter`（入站 RPM/TPM/并发）、`lg_conc`、`lg_budget`、D03 的出站节流
全部是节点本地 ETS。多实例部署时全局配额 ≈ N × 配置值。

设计（分两步）：

1. **本任务只做文档**：`docs/deploy.md` 增加"多实例部署"章节，逐项列明哪些限额是
   per-node、横向扩容时应如何折算配置（如 3 实例则每节点配 1/3 RPM），
   并说明 bitcask 数据目录不可共享（每实例独立 data_dir）。
2. **全局配额（路线图，不排期）**：可选外部计数器后端（Redis 或 mnesia 分片表），
   `lg_limiter`/`lg_out_rate` 抽象出 backend behaviour；默认 local 后端不变。
   需求出现（真实多实例用户）后再设计。

## 5. 路线图（暂不排期，记录方向）

| 方向 | 说明 |
|---|---|
| 语义缓存 | `lg_cache` 现为精确键匹配；基于 embedding 相似度 + 阈值的语义命中，需引入向量检索（bitcask BM25 之上加向量索引或外接） |
| 金丝雀路由 | 现有 weighted 是逐请求随机；金丝雀需要按百分比分流 + 会话粘性 + 指标对比自动回滚 |
| 配置审计日志 | 控制台/API 对路由、凭证、设置的每次变更记录 who/when/diff，存 bitcask 新 cask |
| 请求镜像 | 影子流量复制到备用目标做 A/B 评测，只记指标不回响应 |
| 更多协议适配 | Gemini 原生、Ollama；OpenAI Realtime/Batch/Files、Anthropic Files 透传 |
| 按 Key 月度配额 | `lg_limit` 现有 rpm/tpm/parallel 维度上增加月度 token/费用配额（`lg_budget` 窗口扩展） |

## 6. 优先级汇总（与 TASK.md 对应）

- P1：T10（console_auth 严格模式）
- P2：T12（stream 兼容）、T13（配置分级 + TLS）、T15（多实例文档）
- 路线图：§5 各项，需求驱动再立项
