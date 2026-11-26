# Observability

English | [简体中文](../observability.md)

## Request logs

Every gateway request records its status, protocol, route, credential, upstream model, client, latency, tokens, cost, routing attempts and errors.
The `x-request-id` response header returns the request ID. Message storage and data retention can be configured separately.

When the client disconnects before the gateway has the upstream reply (while queued for a concurrency slot, queued by outbound throttling, waiting for a full retry round, or waiting for upstream
response headers), the gateway stops waiting within about 1s, cancels the upstream request, releases the concurrency slot, tries no further candidates and does not count it toward target health; the log records
`status = 499`, `client_aborted = true`, `error.kind = client_closed`. A non-streaming request that disconnects after the upstream has replied but before the gateway replies
is likewise recorded as 499 and billed for actual usage. A streaming request that disconnects after the stream has started is still recorded as 200 + `client_aborted = true`.

The console can filter by time, route, API key, user, client and failure status. With message storage enabled,
the detail view shows the routing decision and the conversation.

## Usage and cost

Token usage is normalized into prompt, cache read, cache write, reasoning and output tokens, then rolled up hourly by API key, user, route,
credential, upstream model and tag. Prices come from the model catalog and can be overridden per model.

## Metrics

Prometheus metrics are exposed at `/metrics`. Once the `metrics_token` runtime parameter is set, scrapers must send a Bearer token.

Stability-related metrics:

| Metric | Description |
|---|---|
| `litegate_client_closed_total{route}` | Requests ended early because the client disconnected (499 before the stream starts, and aborts after it starts) |
| `litegate_upstream_timeouts_total{phase}` | Upstream timeouts and limit violations: `first_byte`, `idle`, `total`, `too_large` |
| `litegate_store_degraded_total{level}` | Storage backlog degradation: `soft`, `hard`; search index backlog drops are `index` |
| `litegate_store_write_errors_total{cask}` | Failed storage batch writes |
| `litegate_classifier_skipped_total{classifier}` | Intent classifications skipped while the classifier is tripped |
| `litegate_alert_dropped_total` | Notifications dropped because the alert send queue was full |
| `litegate_upstream_connections_total{result}` | Upstream connection checkouts: `reused` from the idle pool, `new` newly opened; reuse ratio = rate(reused) / rate(reused + new) |

OpenTelemetry metrics reuse the trace exporter's `otlp_endpoint` and `otlp_headers`, and are pushed to the
`/v1/metrics` path under that endpoint.

## Trace export

Set `otlp_endpoint`, set `otlp_headers` if authentication is required, then set `otlp_enabled` to true.
LiteGate exports one trace per request, with one child span per upstream attempt.

Common collectors:

| Collector | OTLP endpoint |
|---|---|
| Langfuse | `https://<host>/api/public/otel` |
| OpenTelemetry Collector | `http://localhost:4318` |

When the client sends a W3C `traceparent`, the request joins that trace. With `otlp_bodies` enabled,
request and response bodies are exported as well, truncated to the configured limit.

## Alerts and health

Alert rules can notify Feishu or DingTalk, with thresholds, silence periods, acknowledgement and recovery notifications. The health page summarizes recent upstream failures,
cooldown state, quota state and concurrency load.

upstream_down alerts are subject to the `alert_silence_ms` silence period, and a recovery notification is sent only after `alert_recover_ms` of continuous health;
a failure in the meantime counts as the same outage and does not alert again. The send queue is capped at 1000 entries, and notifications beyond that are recorded as `dropped` in the alert history.
The language of notification text is set by the `alert_language` setting (`zh` / `en`).
Events with no enabled rule are not evaluated at all.

`/health` provides a lightweight service health check:

| State | Response |
|---|---|
| Healthy | 200 `{"status":"ok"}` |
| Storage disk write errors in the last 5 minutes, or still failing consecutively | 200 `{"status":"degraded","store":{...}}` (the gateway keeps forwarding, but logs and conversations may be lost; failed usage and session rollup writes are kept and retried automatically) |
| mnesia not running | 503 `{"status":"unavailable","mnesia":"..."}` |

Request data is written to disk asynchronously by a single writer whose mailbox is off-heap; when the backlog exceeds `store_queue_soft` / `store_queue_hard`, it degrades in tiers,
and the search index is written by a separate process.
