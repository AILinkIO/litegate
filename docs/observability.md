# 可观测性

## 请求日志

每个网关请求都会记录状态、协议、路由、凭证、上游模型、客户端、耗时、token、费用、路由尝试和错误。
响应头 `x-request-id` 返回请求 ID。消息写入和数据保留可以分别配置。

客户端在网关拿到上游回复前断开（排队等并发名额、出站节流排队、整轮重试等待、等上游响应头期间）时，
网关在约 1s 内停止等待、取消上游请求、释放并发名额，不再尝试后续候选，也不计入目标健康；日志记
`status = 499`、`client_aborted = true`、`error.kind = client_closed`。非流式请求在上游已回复、网关回复前断开，
同样记 499 并按实际用量计费。开流后断开的流式请求仍记 200 + `client_aborted = true`。

控制台支持按时间、路由、API Key、用户、客户端和失败状态过滤。开启消息存储后，
详情视图会显示路由决策和对话内容。

## 用量和费用

token 用量会归一化成提示、缓存读、缓存写、推理和输出 token，再按小时汇总到 API Key、用户、路由、
凭证、上游模型和标签。价格来自模型目录，也可以按模型覆盖。

## 指标

Prometheus 指标暴露在 `/metrics`。设置运行参数 `metrics_token` 后，抓取端需要携带 Bearer token。

稳定性相关指标：

| 指标 | 说明 |
|---|---|
| `litegate_client_closed_total{route}` | 因客户端断开而提前结束的请求（开流前 499 与开流后中止） |
| `litegate_upstream_timeouts_total{phase}` | 上游超时与超限：`first_byte`、`idle`、`total`、`too_large` |
| `litegate_store_degraded_total{level}` | 存储积压降级：`soft`、`hard`，检索索引积压丢弃为 `index` |
| `litegate_store_write_errors_total{cask}` | 存储批写失败 |
| `litegate_classifier_skipped_total{classifier}` | 判断者熔断期间跳过的意图判断 |
| `litegate_alert_dropped_total` | 告警发送队列满而丢弃的通知 |
| `litegate_upstream_connections_total{result}` | 上游连接借出：`reused` 来自空闲池，`new` 为新建；复用率 = rate(reused) / rate(reused + new) |

OpenTelemetry 指标复用链路导出的 `otlp_endpoint` 和 `otlp_headers`，并推送到该端点下的
`/v1/metrics` 路径。

## 链路导出

设置 `otlp_endpoint`，需要认证时设置 `otlp_headers`，再把 `otlp_enabled` 设为 true。
LiteGate 会在每个请求导出一条 trace，每个上游尝试导出一个子 span。

常见收集器：

| 收集器 | OTLP endpoint |
|---|---|
| Langfuse | `https://<host>/api/public/otel` |
| OpenTelemetry Collector | `http://localhost:4318` |

客户端携带 W3C `traceparent` 时会接入同一个 trace。开启 `otlp_bodies` 后，
请求和回复内容也会导出，并截断到配置上限。

## 告警和健康

告警规则可以通知飞书或钉钉，支持阈值、静默期、确认和恢复通知。健康页汇总最近的上游失败、
冷却状态、额度状态和并发负载。

upstream_down 告警受 `alert_silence_ms` 静默期约束，恢复通知需持续健康 `alert_recover_ms` 才发送，
期间再次失败视为仍在故障、不重复告警。发送队列上限 1000 条，超出的通知在告警历史中记为 `dropped`。
某事件没有启用的规则时不做任何判定。

`/health` 提供轻量服务健康检查：

| 状态 | 返回 |
|---|---|
| 正常 | 200 `{"status":"ok"}` |
| 最近 5 分钟有存储写盘错误或仍在连续失败 | 200 `{"status":"degraded","store":{...}}`（网关照常转发，日志与对话可能丢失；用量与会话汇总写失败时保留并自动重试） |
| mnesia 未运行 | 503 `{"status":"unavailable","mnesia":"..."}` |

请求数据由单写者异步落盘，写者邮箱在堆外；积压超过 `store_queue_soft` / `store_queue_hard` 时分级降级，
检索索引由独立进程写入。
