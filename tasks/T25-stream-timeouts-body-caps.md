# T25 流式超时分级与上游响应体上限

优先级：P1 ｜ 设计：[D05 §2.6](../designs/D05-regressions-stability-perf.md) ｜ 状态：待评审 ｜ 依赖：无（与 T28 共享 `sse_max_event_bytes`）

## 背景

块间空闲超时复用 300s 首包超时，流无总时长上限；非流式 `gun:await_body` 整体读入内存、无大小上限，
且超时按单条消息计算，慢速滴数据永不超时。

## 改动点

- `apps/lg_core/src/lg_config.erl`：新增 `stream_idle_timeout_ms`（120000）、`stream_max_ms`（1800000）、
  `upstream_max_body_bytes`（64MB）、`sse_max_event_bytes`（8MB）。
- `apps/lg_provider/src/lg_provider_stream.erl:85`、`lg_http.erl:351-352`：首包后切换到 idle 超时；
  记录流起始时间，超过 `stream_max_ms` 结束并返回上游超时错误。
- `apps/lg_provider/src/lg_http.erl:276, 303, 328`：替换 `gun:await_body` 为自写接收循环
  （累计字节 + 总截止时间），超限 `gun:cancel` + discard 连接，返回 `upstream_too_large`。
- 指标 `litegate_upstream_timeouts_total{phase=first_byte|idle|total}`。

## 验收标准

- [ ] mock 上游首包后停发：在 idle 超时处结束，日志 phase=idle；
- [ ] mock 上游持续发 ping：在 `stream_max_ms` 处结束；
- [ ] mock 返回 100MB 非流式响应：64MB 处中止，进程内存峰值 <80MB；
- [ ] `rebar3 eunit xref dialyzer` 全绿；docs/configuration.md 与 CHANGELOG 标注默认空闲超时变更。

## 预估

~180 行（含测试），1 天。
