# T08 出站速率观测（自适应限流 Phase 1）

优先级：P1 ｜ 设计：[D03 §3.1、§4、§7](../designs/D03-adaptive-upstream-throttle.md) ｜ 状态：待开始 ｜ 依赖：无

## 背景

网关目前不观测自己对每个上游目标（凭证 × 模型）的发送速率，出现 429 风暴时
无法回答"打到多少 QPM 开始被限"。本任务只做**观测**，不拦截任何请求，
为 Phase 2（T09 AIMD 节流）提供数据与基础设施。适用于所有供应商与模型。

## 目标

新模块 `lg_out_rate`：按 `{CredentialId, UpstreamModel}` 的分钟分桶滑动窗口计数，
暴露 `rate/1`、`snapshot/0`，接入 Prometheus gauge 与控制台展示。

## 改动点

- 新增 `apps/lg_router/src/lg_out_rate.erl`
  - ETS `lg_out_rate_win`：`{{CId, Model}, Minute} → Count`，
    `ets:update_counter` 热路径 +1（模式对照 `lg_limiter.erl` 的 `?RATE` 表）；
  - 滑动窗口近似：`qpm = 上分钟 × (1 - 本分钟已过比例) + 本分钟`；
  - gen_server：60s 周期清扫 2 分钟前的桶；挂入 `lg_router_sup`；
  - API：`record/1`、`rate/1`、`snapshot/0`、`reset/1`、`reset/0`
    （allow/on_429/on_success 留给 T09，本任务先建 state 表结构）。
- `apps/lg_router/src/lg_router_attempt.erl`：真正发出上游请求处调用 `record(tkey(T))`
  （含回退链每个 attempt）。
- `apps/lg_core/src/lg_metrics.erl` 或 `lg_web_metrics.erl`：
  `register_gauge(litegate_out_qpm, …)` 从 `snapshot/0` 出数。
- 控制台（`web/src/features/` 路由或凭证页 + 对应 live API）：目标当前 QPM 列。

## 验收标准

- [ ] eunit：分钟桶计数、滑动窗口近似值（对照 `lg_limiter_tests` 测法）、清扫不删当前桶；
- [ ] 集成：mock 上游跑 N 个请求后 `rate/1` 正确；
- [ ] /metrics 出现 `litegate_out_qpm{cred,model}`；控制台可见；
- [ ] 热路径仅一次 `update_counter`，无进程调用（代码评审确认）；
- [ ] `rebar3 eunit xref dialyzer` 全绿。

## 预估

~180 行（含前端），1 天。
