# T01 OTLP 队列按字节封顶

优先级：P0 ｜ 设计：[D01 §1](../designs/D01-memory-safety.md) ｜ 状态：待开始 ｜ 依赖：无

## 背景

`lg_otlp` 队列上限是 10000 个 **span**（`?MAX_QUEUE`，`lg_otlp.erl:21,285`），
而 `otlp_bodies=true` 时每个 span 可携带 2×256KB 的请求/响应体，
导出端点慢或不可达时最坏可驻留 ~5GB 内存。

## 目标

队列改按**字节**封顶，超限先降级（剥 body）再丢弃，消除 OTLP 内存风险。

## 改动点

- `apps/lg_router/src/lg_otlp.erl`
  - span 构造处计算 `size`（body 字节数 + ~2KB 固定开销估算），随队列条目保存；
  - state 增加 `bytes` 计数，入队/发送/丢弃/重试路径同步增减；
  - 双层上限：新配置 `otlp_queue_max_bytes`（默认 64MB）+ 保留条数上限；
  - 超 50% 字节上限：新 span 剥 body（`body_text → undefined`），计
    `litegate_otlp_stripped_total`；超上限：丢 span（现有 dropped 计数器）。
- `apps/lg_core/src/lg_config.erl`：`defaults/0` 增加 `otlp_queue_max_bytes`。
- `apps/lg_core/src/lg_metrics.erl`：注册 `litegate_otlp_stripped_total` counter。

## 验收标准

- [ ] eunit：大 body span 灌队列，验证 50% 剥 body、上限丢 span、两计数器计数正确；
- [ ] 发送成功后 `bytes` 归零；重试路径不重复计数；
- [ ] `otlp_bodies=false` 时行为与现状一致；
- [ ] `rebar3 eunit xref dialyzer` 全绿。

## 预估

~120 行（含测试），0.5 天。
