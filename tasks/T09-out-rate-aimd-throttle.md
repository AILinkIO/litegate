# T09 AIMD 自适应节流（自适应限流 Phase 2）

优先级：P1 ｜ 设计：[D03 §3.2-3.5、§5](../designs/D03-adaptive-upstream-throttle.md) ｜ 状态：待开始 ｜ 依赖：T08

## 背景

上游 429 时现有机制只降权不拦截：冷却目标若是唯一候选仍会照常发出，
持续撞墙。本任务在 T08 的观测之上实现 AIMD 反馈节流，429 自动收紧、
恢复自动放开，对所有模型统一生效。

## 目标

1. `lg_out_rate` 增加 Cap 状态机：`allow/1`、`on_rate_limit/2`、`on_success/1`；
2. `lg_router_attempt` 接入：被节流的目标有其他候选时跳过（busy attempt），
   唯一候选时快速失败 429 + Retry-After（queue 等待策略属 T11）；
3. `lg_cooldown` 职责重划：无 Retry-After 的 rate_limit 不再 streak 翻倍。

## 改动点

- `apps/lg_router/src/lg_out_rate.erl`
  - state 表字段与 AIMD 控制律完全按 D03 §3.3（首犯 ×Factor、再犯减半、
    MinCap 保底、RA 硬暂停、RecoveryMs 回升、解除条件、24h 回收）；
  - 控制律写成纯函数（`step_429/2`、`step_ok/2`）便于 eunit。
- `apps/lg_router/src/lg_router_attempt.erl`
  - `attempt_plan/7` 并发检查前调用 `lg_out_rate:allow(tkey(T))`；
    节流且有候选 → skip（记 `busy => true`，复用 conc busy skip 同构逻辑）；
    唯一候选 → `{error, #{kind => rate_limit, status => 429, retryable => false,
    retry_after_ms => RetryMs, …}}`；
  - outcome 分支：`ok → on_success`、`rate_limit → on_rate_limit(TKey, RA)`。
- `apps/lg_router/src/lg_cooldown.erl`：`duration/3` 的 `rate_limit` 无 RA 分支
  在 `out_rate_enabled` 时固定 Base 不翻倍（D03 §3.4）。
- `apps/lg_core/src/lg_config.erl`：新增 `out_rate_enabled(true)`、
  `out_rate_factor(0.7)`、`out_rate_min_rpm(6)`、`out_rate_recovery_ms(120000)`。
- `apps/lg_core/src/lg_metrics.erl`：`litegate_out_throttled_total{cred,model}` counter。
- `apps/lg_router/src/lg_credentials.erl` 写路径：凭证更新时 `lg_out_rate:reset/1`。

## 验收标准

- [ ] eunit 纯函数：D03 §8 列出的 AIMD 全路径（首犯/再犯/保底/暂停/回升/解除/回收）；
- [ ] 集成（扩展 `lg_router_tests.erl`）：mock 上游 A 首答 429 次答 200，
      验证第二请求 skip 到候选 B；唯一候选时收到 429 + Retry-After；
- [ ] `out_rate_enabled=false` 时行为与现状一致（回归）；
- [ ] 被节流 attempt 进入 patience `busy_failure` 判定（全候选节流时整轮等待生效）；
- [ ] 文档：`docs/routing.md` 增补自适应节流一节；
- [ ] `rebar3 eunit xref dialyzer` 全绿。

## 预估

~300 行（含测试），1.5-2 天。
