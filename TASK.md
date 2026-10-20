# TASK.md — 优化与功能演进任务跟踪

设计文档在 [`designs/`](designs/)，任务拆分在 [`tasks/`](tasks/)。
来源：2026-10 全项目深度分析（功能 / 性能 / 原子与内存审计）+ 上游 429 自适应限流需求。

状态标记：`待开始` → `进行中` → `待评审` → `完成`（完成后在表中标注 PR/commit）。

## P0 — 内存安全与资源增长治理（设计：[D01](designs/D01-memory-safety.md)）

| ID | 任务 | 状态 | 依赖 | 预估 |
|---|---|---|---|---|
| [T01](tasks/T01-otlp-queue-byte-cap.md) | OTLP 队列按字节封顶（防 GB 级驻留） | 待开始 | — | 0.5 天 |
| [T02](tasks/T02-state-table-sweeps.md) | 状态表周期清扫补齐（login_guard 为主） | 待开始 | — | 0.5 天 |
| [T03](tasks/T03-mw-remote-atom-hardening.md) | mw_remote 动态原子硬化 | 待开始 | — | 0.5 小时 |

## P1 — 热路径性能（设计：[D02](designs/D02-hotpath-performance.md)）

| ID | 任务 | 状态 | 依赖 | 预估 |
|---|---|---|---|---|
| [T04](tasks/T04-config-get-cache.md) | lg_config:get/1 两级缓存 | 待开始 | — | 0.5 天 |
| [T05](tasks/T05-metrics-render-map.md) | lg_metrics render/snapshot 消除 O(n²) | 待开始 | — | 0.5 天 |
| [T06](tasks/T06-wildcard-route-cache.md) | 通配路由匹配预编译缓存 | 待开始 | — | 0.5 天 |
| [T07](tasks/T07-store-flush-scope.md) | lg_store 查询 flush 按范围拆分 | 待开始 | — | 0.5 天 |

## P1/P2 — 出站自适应限流，面向全部模型（设计：[D03](designs/D03-adaptive-upstream-throttle.md)）

背景：上游 429（如 Qwen3.8-Max）时现有机制只降权不限速，唯一候选仍持续撞墙。
方案：按 `{凭证, 模型}` 记录最近 1 分钟出站 QPM，429 触发 AIMD 反馈节流，
恢复后自动放开；对**所有供应商与模型**统一生效，非 Qwen 专属。

| ID | 任务 | 阶段 | 优先级 | 状态 | 依赖 | 预估 |
|---|---|---|---|---|---|---|
| [T08](tasks/T08-out-rate-observability.md) | 出站速率观测（窗口计数 + gauge + 控制台） | Phase 1 | P1 | 待开始 | — | 1 天 |
| [T09](tasks/T09-out-rate-aimd-throttle.md) | AIMD 节流 + attempt 接入 + cooldown 职责重划 | Phase 2 | P1 | 待开始 | T08 | 1.5-2 天 |
| [T11](tasks/T11-out-rate-queue-and-max-rpm.md) | 排队等待策略 + 凭证 max_rpm + 控制台徽标 | Phase 3 | P2 | 待开始 | T09 | 1-1.5 天 |

> 零代码缓解（立即可用）：给易 429 的凭证配 `max_concurrency`（lg_conc 自动排队），
> 并调大 `patience_ms` / `patience_rounds`。

## P1/P2 — 功能与安全（设计：[D04](designs/D04-features-and-security.md)）

| ID | 任务 | 优先级 | 状态 | 依赖 | 预估 |
|---|---|---|---|---|---|
| [T10](tasks/T10-console-auth-strict.md) | console_auth 严格模式（非 loopback 无鉴权拒绝启动） | P1 | 待开始 | — | 0.5 天 |
| [T12](tasks/T12-nonchat-stream-compat.md) | 非 chat 端点 stream:true 兼容 | P2 | 待开始 | — | 1 天 |
| [T13](tasks/T13-config-restart-flags-tls.md) | 配置"需重启"标注 + TLS 监听 | P2 | 待开始 | — | 1 天 |
| [T14](tasks/T14-text-hotpath-alloc.md) | token 估算与 SSE 规范化分配优化 | P2 | 待开始 | — | 1 天 |
| [T15](tasks/T15-multi-instance-quota-docs.md) | 多实例部署配额语义文档 | P2 | 待开始 | T09 | 0.5 天 |

## 建议实施顺序

```
第一批（P0，可并行）：T01 ∥ T02 ∥ T03
第二批（P1 性能，可并行）：T04 ∥ T05 ∥ T06 ∥ T07 ∥ T10
第三批（限流主线，串行）：T08 → T09 →（观察线上数据）→ T11 → T15
第四批（P2 功能，按需）：T12 ∥ T13 ∥ T14
```

## 通用完成标准（所有任务）

- `rebar3 eunit`、`rebar3 xref`、`rebar3 dialyzer` 全绿；涉及前端时 `npm test` 全绿；
- 行为变更同步更新 `docs/` 对应章节与 RELEASE NOTES（破坏性变更显著标注）；
- 新增 ETS 表必须有周期清扫或明确有界性说明（见 D01 审计结论）；
- 任务完成后更新本文件状态列。
