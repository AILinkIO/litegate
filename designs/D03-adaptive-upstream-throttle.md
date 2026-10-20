# D03 出站自适应限流（Adaptive Upstream Throttle）—— 面向全部模型

状态：待实施 ｜ 对应任务：T08（Phase 1）、T09（Phase 2）、T11（Phase 3）

## 1. 问题陈述

上游（如 DashScope/Qwen、OpenAI、Anthropic 等，**不限任何供应商与模型**）普遍同时施加
两类限制：RPM/TPM 窗口限制与并发限制。当网关发送速率超过上游窗口配额时收到 429。

现有机制的空白：

| 机制 | 位置 | 局限 |
|---|---|---|
| `lg_cooldown` | `lg_cooldown.erl:41-66` | 只"降权"：冷却目标排到尝试顺序末尾（`lg_router_plan.erl:220-228`），是唯一候选时**仍会照常发出**，继续撞 429 |
| patience 整轮重试 | `lg_router_attempt.erl:41-62` | 缓解尾延迟，不降低发送速率 |
| `lg_conc` max_concurrency | `lg_conc.erl` | 只管并发维度，且是管理员静态配置，不会随 429 自适应 |
| `lg_limiter` | `lg_limiter.erl` | **入站**限流（按网关 Key/路由 scope），与上游健康无关 |

结果：单凭证/少凭证路由遇到 429 风暴时，网关以客户端速率持续打上游，每请求白付一个
429 往返 + patience 等待，最终仍把 429 交给客户端；上游窗口始终无法恢复。

**目标**：为每个上游目标维护出站速率观测与反馈式节流，429 时自动收紧、恢复后自动放开，
把"撞墙"变成"整形"（rate shaping），对所有协议/供应商/模型统一生效。

**非目标**：不做跨节点全局限流（与项目现有 per-node 语义一致，见 D04 §4）；
不替代 `lg_conc`（并发维度）与 `lg_cooldown`（硬故障熔断）。

## 2. 核心概念

- **目标（target key）**：`{CredentialId, UpstreamModel}`，即现有 `lg_router_plan:tkey/1`。
  这是上游计配额的自然粒度；同一凭证不同模型、同一模型不同凭证互不影响。
- **出站 QPM**：该目标最近 1 分钟**发起**的上游请求数（流式请求计发起时刻一次；
  在途时长属并发维度，由 `lg_conc` 管）。
- **学习上限 Cap**：AIMD 反馈得出的每分钟允许发起数。初始无 Cap（不限），
  首次 429 后才 clamp —— 冷启动无需预知任何供应商阈值。

## 3. 架构

新模块 `lg_out_rate`（`apps/lg_router/src/`，gen_server + 两张 public ETS，
挂入 `lg_router_sup`）。热路径读写全走 ETS 原子操作，gen_server 只负责周期清扫与
状态回收，无单点串行。

```
lg_router_attempt ──dispatch前──▶ lg_out_rate:allow(TKey)   → ok | {throttle, RetryMs}
       │                              （ETS 读计数+Cap，无进程调用）
       ├──真正发出──▶ lg_out_rate:record(TKey)                （update_counter +1）
       ├──成功──────▶ lg_out_rate:on_success(TKey)
       └──429───────▶ lg_out_rate:on_rate_limit(TKey, RetryAfterMs)
```

### 3.1 ETS 表

```
lg_out_rate_win   : {{CId, Model}, Minute}  → Count        %% 分钟桶，update_counter
lg_out_rate_state : {CId, Model} → #{cap        => pos_integer() | undefined,
                                     paused_until => integer() | undefined,  %% 429 硬暂停
                                     streak     => non_neg_integer(),        %% 连续 429 次数
                                     ok_since   => integer() | undefined,    %% 最近一次 429 时刻
                                     updated_at => integer()}
```

滑动窗口速率复用 `lg_limiter` 的成熟近似（`lg_limiter.erl:2-5`）：
`qpm = 上分钟计数 × (1 - 本分钟已过比例) + 本分钟计数`。
清扫：60s 周期删除 2 分钟前的桶；state 表删除 `updated_at` 超过 24h 且无 Cap 的条目。

### 3.2 API

```erlang
-export([record/1, allow/1, rate/1, on_success/1, on_rate_limit/2,
         info/1, snapshot/0, reset/1, reset/0]).

%% allow/1 返回值：
%%   ok                    —— 可发送
%%   {throttle, RetryMs}   —— 本分钟已达 Cap（或硬暂停中），RetryMs 为预计可发送时刻
```

`allow/1` 判定顺序：
1. `paused_until > Now` → `{throttle, paused_until - Now}`；
2. `cap =/= undefined` 且本分钟滑动 qpm ≥ cap → `{throttle, 窗口滚动剩余 ms}`；
3. 凭证配置了静态 `max_rpm`（见 §6）且 qpm ≥ min(max_rpm, cap) → 同上；
4. 否则 `ok`。

### 3.3 AIMD 控制律

**下调（on_rate_limit/2）**：

```
有 Retry-After：paused_until = Now + RA            %% 上游明说何时回来，硬暂停最准
无 Retry-After：
    Observed = 最近 1 分钟滑动 qpm（record 已计入本次）
    streak == 1 → cap = max(MinCap, Observed × Factor)      %% 首犯：降到实测速率的 70%
    streak >  1 → cap = max(MinCap, cap × 0.5)              %% 再犯：减半
```

**回升（on_success/1，仅在 cap =/= undefined 时）**：

```
Now - ok_since ≥ RecoveryMs（默认 120s 无 429）：
    cap = cap + max(1, cap × 0.1)          %% 加性/乘性回升，每成功请求至多触发一次
    cap ≥ Observed × 1.5 或持续 RecoveryMs×4 无 429 且 cap 超过历史健康峰值：
        cap = undefined, streak = 0        %% 完全解除限制，回到初始态
```

参数（全部进 `lg_config:defaults/0`，控制台可调）：

| 配置键 | 默认 | 说明 |
|---|---|---|
| `out_rate_enabled` | `true` | 总开关；关闭时 `allow/1` 恒 ok、`record/1` 仍计数（观测不受影响） |
| `out_rate_factor` | `0.7` | 首犯下调系数 |
| `out_rate_min_rpm` | `6` | Cap 下限，防饿死（每分钟至少放行 6 个探测请求） |
| `out_rate_recovery_ms` | `120000` | 无 429 多久开始回升 |

### 3.4 与现有机制的职责重划（关键）

- **`lg_cooldown`**：保留 quota / credit / auth / 5xx / 网络类错误的熔断降权；
  `rate_limit` 类改为——**有 Retry-After 时维持现状**（冷却到 RA 时刻），
  **无 Retry-After 且 `out_rate_enabled` 时不再 streak 翻倍**（固定 `route_cooldown_ms`，
  速率整形交给 AIMD，避免 30min 冷却 + 节流双重惩罚导致恢复过慢）。
  改动点：`lg_cooldown.erl:60`（`rate_limit -> Grow(Base, 30*?MIN)` 分支加条件）。
- **patience 整轮重试**：不动。节流导致的 skip 记 `busy => true` attempt，
  天然进入 `busy_failure/1` 判定（`lg_router_attempt.erl:64-68`），
  全部候选被节流时会走 patience 等待——这正是期望行为。
- **`lg_conc`**：正交。执行顺序：先 `allow/1`（速率）后 `acquire`（并发），
  被节流的请求不占并发名额。

### 3.5 执行点（lg_router_attempt）

`attempt_plan/7`（`lg_router_attempt.erl:84-113`）在现有并发检查旁增加：

```
lg_out_rate:allow(tkey(T)) == {throttle, RetryMs} 时：
    Rest 中存在未被节流/未满并发的候选 → 跳过（记 busy attempt，不 mark cooldown，
        与现有 conc busy skip 完全同构，L92-97）
    唯一候选（Phase 3，T11）：
        策略 queue  → 等待 min(RetryMs, queue_wait_ms)，复用 lg_conc:wait 的
                      等待+idle 保活帧模式，到点重查 allow/1
        策略 fail   → 立即 {error, #{kind => rate_limit, status => 429,
                      retryable => false, retry_after_ms => RetryMs,
                      message => <<"Upstream target throttled by adaptive rate limiter">>}}
                      （客户端收到 429 + Retry-After，交给 SDK 退避）
    Phase 2 先实现 fail 策略（零等待、行为简单），queue 策略由 out_rate_wait 配置切换。
```

真正发出上游请求处调用 `record/1`；结果分支（`attempt_held` 的 outcome 处理，
`lg_router_attempt.erl:155-163`）：`ok → on_success`、`rate_limit → on_rate_limit(TKey, RA)`。

## 4. 观测

- 计数器：`litegate_out_throttled_total{cred,model}`（allow 拒绝次数，含 skip 与 fail）；
  `litegate_out_rate_limited_by_upstream_total` 复用现有 429 统计口径。
- Gauge（`lg_metrics:register_gauge`）：每目标当前滑动 qpm、cap（undefined 报 -1 或不报）、
  paused 剩余。
- 控制台：路由/凭证页显示目标当前 QPM 与节流状态徽标（"节流中 cap=N/min"）；
  数据来自 `lg_out_rate:snapshot/0`，经既有 live API 通道。
- 日志：Cap 首次建立、减半、解除各打一条 `logger:notice`（低频事件，不会刷屏）。

## 5. 边界情况

1. **误判为窗口限流的账号级 429**（欠费/风控）：AIMD 会压到 MinCap 但不会归零；
   credit/quota 分类错误仍由 `lg_cooldown`/`lg_plan`/`lg_balance` 兜底熔断。
2. **长流式请求**：只在发起时计 1 次；在途占用由 `lg_conc` 覆盖，两者不重复计数。
3. **多节点部署**：每节点独立学习各自 Cap，上游实际承受 ≈ N × Cap，可能轻微超配额。
   与项目现有全部限流语义一致（per-node），文档标注；全局化属 D04 §4 路线。
4. **凭证换 Key/换 base_url**：Cap 挂在 `{CId, Model}` 上，凭证配置更新时
   （`lg_credentials` 写路径）调用 `reset/1` 清除学习状态。
5. **MinCap 探测请求仍 429**：streak 持续增长、cap 钉在 MinCap，paused/窗口机制保证
   每分钟最多 MinCap 次探测——这就是稳态，上游窗口恢复后首个成功请求触发回升。
6. **嵌套路由/回退链**：每个 attempt 独立按自己的 tkey 判定，跳过后自然落到下一候选，
   无级联影响。

## 6. 凭证静态选项（Phase 3）

`lg_options:credential_spec/0`（`lg_options.erl:30-40`）增加：

```erlang
<<"max_rpm">> => {max_rpm, non_neg_integer}
```

语义：该凭证所有模型的静态每分钟发起上限（供应商明示配额时直接填）。
生效值 = `min(max_rpm, learned cap)`；`0`/未配置 = 仅用学习值。
控制台凭证对话框加输入项（与 max_concurrency 同排）。

## 7. 分期与任务映射

| Phase | 任务 | 内容 | 价值 |
|---|---|---|---|
| 1 | T08 | `lg_out_rate` 窗口计数 + `rate/1`/`snapshot/0` + gauge + 控制台展示（**只观测不拦截**） | 量化各模型真实 429 阈值，为静态 max_rpm 提供数据 |
| 2 | T09 | AIMD 状态机 + `allow/1` + attempt_plan 接入（skip + fail 策略）+ cooldown 职责重划 + eunit | 消除撞墙浪费，429 风暴自愈 |
| 3 | T11 | queue 等待策略（idle 保活）+ 凭证 `max_rpm` 选项 + 控制台状态/徽标 + 文档 | 唯一候选场景体验最优；明示配额直接配置 |

## 8. 测试计划

- **纯函数单测**（`lg_out_rate_tests.erl`）：AIMD 状态转移全路径——首犯 ×0.7、
  再犯减半、MinCap 下限、RA 硬暂停、RecoveryMs 回升、解除条件、24h state 回收、
  分钟桶滑动窗口近似值（对照 `lg_limiter_tests` 的既有测法）。
- **集成**（扩展 `lg_router_tests.erl`）：mock 上游首答 429 次答 200，验证
  第二请求被 skip 到候选 B / 唯一候选时按策略 fail 或 queue；`out_rate_enabled=false`
  时行为与现状逐字节一致。
- **回归**：`rebar3 eunit && rebar3 xref && rebar3 dialyzer` 全绿。
