# 可观测性

## 请求日志

每个网关请求都会记录状态、协议、路由、凭证、上游模型、客户端、耗时、token、费用、路由尝试和错误。
响应头 `x-request-id` 返回请求 ID。消息写入和数据保留可以分别配置。

控制台支持按时间、路由、API Key、用户、客户端和失败状态过滤。开启消息存储后，
详情视图会显示路由决策和对话内容。

## 用量和费用

token 用量会归一化成提示、缓存读、缓存写、推理和输出 token，再按小时汇总到 API Key、用户、路由、
凭证、上游模型和标签。价格来自模型目录，也可以按模型覆盖。

## 指标

Prometheus 指标暴露在 `/metrics`。设置运行参数 `metrics_token` 后，抓取端需要携带 Bearer token。

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

`/health` 提供轻量服务健康检查。
