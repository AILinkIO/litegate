# TASK.md — 优化与功能演进任务跟踪

设计文档在 [`designs/`](designs/)，任务拆分在 [`tasks/`](tasks/)。
来源：2026-10 全项目深度分析（功能 / 性能 / 原子与内存审计）+ 上游 429 自适应限流需求；
2026-10-27 第二轮审查（回归缺陷 / 稳定度 / 流式与存储性能，见 D05）。

状态标记：`待开始` → `进行中` → `待评审` → `完成`（完成后在表中标注 PR/commit）。

## P0 — 内存安全与资源增长治理（设计：[D01](designs/D01-memory-safety.md)）

| ID | 任务 | 状态 | 依赖 | 预估 |
|---|---|---|---|---|
| [T01](tasks/T01-otlp-queue-byte-cap.md) | OTLP 队列按字节封顶（防 GB 级驻留） | 待评审 | — | 0.5 天 |
| [T02](tasks/T02-state-table-sweeps.md) | 状态表周期清扫补齐（login_guard 为主） | 待评审 | — | 0.5 天 |
| [T03](tasks/T03-mw-remote-atom-hardening.md) | mw_remote 动态原子硬化 | 待评审 | — | 0.5 小时 |

## P1 — 热路径性能（设计：[D02](designs/D02-hotpath-performance.md)）

| ID | 任务 | 状态 | 依赖 | 预估 |
|---|---|---|---|---|
| [T04](tasks/T04-config-get-cache.md) | lg_config:get/1 两级缓存 | 待评审 | — | 0.5 天 |
| [T05](tasks/T05-metrics-render-map.md) | lg_metrics render/snapshot 消除 O(n²) | 待评审 | — | 0.5 天 |
| [T06](tasks/T06-wildcard-route-cache.md) | 通配路由匹配预编译缓存 | 待评审 | — | 0.5 天 |
| [T07](tasks/T07-store-flush-scope.md) | lg_store 查询 flush 按范围拆分 | 待评审 | — | 0.5 天 |

## P1/P2 — 出站自适应限流，面向全部模型（设计：[D03](designs/D03-adaptive-upstream-throttle.md)）

背景：上游 429（如 Qwen3.8-Max）时现有机制只降权不限速，唯一候选仍持续撞墙。
方案：按 `{凭证, 模型}` 记录最近 1 分钟出站 QPM，429 触发 AIMD 反馈节流，
恢复后自动放开；对**所有供应商与模型**统一生效，非 Qwen 专属。

| ID | 任务 | 阶段 | 优先级 | 状态 | 依赖 | 预估 |
|---|---|---|---|---|---|---|
| [T08](tasks/T08-out-rate-observability.md) | 出站速率观测（窗口计数 + gauge + 控制台） | Phase 1 | P1 | 待评审 | — | 1 天 |
| [T09](tasks/T09-out-rate-aimd-throttle.md) | AIMD 节流 + attempt 接入 + cooldown 职责重划 | Phase 2 | P1 | 待评审 | T08 | 1.5-2 天 |
| [T11](tasks/T11-out-rate-queue-and-max-rpm.md) | 排队等待策略 + 凭证 max_rpm + 控制台徽标 | Phase 3 | P2 | 待评审 | T09 | 1-1.5 天 |

> 零代码缓解（立即可用）：给易 429 的凭证配 `max_concurrency`（lg_conc 自动排队），
> 并调大 `patience_ms` / `patience_rounds`。

## P1/P2 — 功能与安全（设计：[D04](designs/D04-features-and-security.md)）

| ID | 任务 | 优先级 | 状态 | 依赖 | 预估 |
|---|---|---|---|---|---|
| [T10](tasks/T10-console-auth-strict.md) | console_auth 严格模式（非 loopback 无鉴权拒绝启动） | P1 | 待评审 | — | 0.5 天 |
| [T12](tasks/T12-nonchat-stream-compat.md) | 非 chat 端点 stream:true 兼容 | P2 | 待评审 | — | 1 天 |
| [T13](tasks/T13-config-restart-flags-tls.md) | 配置"需重启"标注 + TLS 监听 | P2 | 待评审 | — | 1 天 |
| [T14](tasks/T14-text-hotpath-alloc.md) | token 估算与 SSE 规范化分配优化 | P2 | 待评审 | — | 1 天 |
| [T15](tasks/T15-multi-instance-quota-docs.md) | 多实例部署配额语义文档 | P2 | 待评审 | T09 | 0.5 天 |

## 建议实施顺序

```
第一批（P0，可并行）：T01 ∥ T02 ∥ T03
第二批（P1 性能，可并行）：T04 ∥ T05 ∥ T06 ∥ T07 ∥ T10
第三批（限流主线，串行）：T08 → T09 →（观察线上数据）→ T11 → T15
第四批（P2 功能，按需）：T12 ∥ T13 ∥ T14
```

## 第二轮（2026-10-27 审查，设计：[D05](designs/D05-regressions-stability-perf.md)）

> 背景：T06 / T02 / T04 / T09 / T11 的实现存在不生效或行为错误的缺陷（单进程 eunit 测不出 ETS owner
> 与跨进程失效问题），另有稳定度与流式/存储性能遗留项。行号基于 commit `98ad72b`。

### P0 — 回归缺陷修复（D05 §1）

| ID | 任务 | 状态 | 依赖 | 预估 |
|---|---|---|---|---|
| [T16](tasks/T16-wildcard-cache-owner.md) | 通配路由缓存表 owner 修复与无空窗重建（重启后通配路由 404） | 待评审 | — | 0.5 天 |
| [T17](tasks/T17-out-rate-fixes.md) | lg_out_rate 缺陷：sweep 清空窗口、reset 无效、首犯 Cap=6、并发减半、排队丢候选 | 待评审 | — | 1 天 |
| [T18](tasks/T18-config-cache-consistency.md) | lg_config 缓存：导入后不失效 + 回填丢失更新 | 待评审 | T16 | 0.5 天 |
| [T19](tasks/T19-cooldown-sweep-realtime-gun2.md) | cooldown 清扫未调度 + realtime 适配 gun 2.x 消息 | 待评审 | — | 0.5 天 |

### P1 — 稳定度（D05 §2）

| ID | 任务 | 状态 | 依赖 | 预估 |
|---|---|---|---|---|
| [T20](tasks/T20-client-disconnect-awareness.md) | 客户端断开感知（开流前等待 + 非流式记账） | 待评审 | — | 1 天 |
| [T21](tasks/T21-store-writer-backpressure.md) | 存储写者背压、写盘错误可见、防重放、句柄解耦 | 待评审 | — | 2 天 |
| [T22](tasks/T22-conc-waiters-limiter-ownership.md) | lg_conc 等待者 monitor/超时 + lg_limiter 释放归属 | 待评审 | — | 1 天 |
| [T23](tasks/T23-plan-balance-refresh-dedup.md) | 额度/余额刷新去重（防刷新风暴） | 待评审 | — | 1 天 |
| [T24](tasks/T24-runtime-shutdown-limits.md) | mnesia permanent、优雅关停排空、连接/文件句柄上限、vm.args | 待评审 | — | 1 天 |
| [T25](tasks/T25-stream-timeouts-body-caps.md) | 流式超时分级 + 上游响应体上限 | 待评审 | — | 1 天 |
| [T26](tasks/T26-schema-migration-idempotent.md) | schema 迁移幂等与节点名防护 | 待评审 | — | 1 天 |
| [T27](tasks/T27-classifier-breaker-alert-debounce.md) | 意图分类器熔断 + 告警防抖与队列上限 | 待评审 | — | 1.5 天 |

### P1/P2 — 性能（D05 §3）

| ID | 任务 | 优先级 | 状态 | 依赖 | 预估 |
|---|---|---|---|---|---|
| [T28](tasks/T28-stream-parse-quadratic.md) | 流式解析 O(n²)（SSE / lg_loop）与 sub-binary 驻留 | P1 | 待评审 | T25 | 1.5 天 |
| [T29](tasks/T29-backpressure-conn-pool.md) | gun flow 背压 + 连接池复用与消息残留 | P2 | 待评审 | — | 1.5 天 |
| [T30](tasks/T30-stream-single-decode.md) | 流式事件单次编解码 | P2 | 待评审 | T28 | 1 天 |
| [T31](tasks/T31-store-query-index-janitor.md) | 存储查询索引（错误/usage 类别）+ janitor 批量与范围删除 | P2 | 待评审 | T21 | 2.5 天 |
| [T32](tasks/T32-router-hotpath-misc.md) | 路由热路径杂项（rotate 计数、凭证复用、同步中间件、last 表清扫） | P2 | 待评审 | T17 | 1 天 |
| [T33](tasks/T33-low-priority-misc.md) | 低优先级杂项（备份、导出一致性、目录同步保护） | P2 | 待评审 | — | 0.5 天 |

### 第二轮建议实施顺序

```
第五批（P0，可并行，尽快发 1.1.1）：T16 ∥ T17 ∥ T19 → T18
第六批（P1 稳定度，可并行）：T20 ∥ T21 ∥ T22 ∥ T23 ∥ T24 ∥ T26
第七批（P1 流式）：T25 → T28；T27 可并行
第八批（P2 性能，按需）：T29 ∥ T31 ∥ T32 ∥ T33；T30 在 T28 之后
```

## 通用完成标准（所有任务）

- `rebar3 eunit`、`rebar3 xref`、`rebar3 dialyzer` 全绿；涉及前端时 `npm test` 全绿；
- 行为变更同步更新 `docs/` 对应章节与 RELEASE NOTES（破坏性变更显著标注）；
- 新增 ETS 表必须有周期清扫或明确有界性说明（见 D01 审计结论）；
- 涉及 ETS owner、缓存失效、定时清扫的改动必须有**跨进程**测试，并断言定时器确实被调度（D05 通用约束）；
- 任务完成后更新本文件状态列。
