# T02 状态表周期清扫补齐（login_guard 为主）

优先级：P0 ｜ 设计：[D01 §2-3](../designs/D01-memory-safety.md) ｜ 状态：待开始 ｜ 依赖：无

## 背景

`lg_login_guard` 的 `{Username, PeerIp}` 条目只在同 Key 再次访问时惰性过期，
攻击者用随机用户名+IP 撞登录接口可使 ETS 表无界增长。另有三处低危清扫缺口：
`lg_affinity` tokens 条目、`lg_cooldown` 过期条目、mnesia `lg_session` 过期会话。

## 目标

所有长生命周期状态表都有周期清扫，消除无界增长点。

## 改动点

- `apps/lg_router/src/lg_login_guard.erl`：gen_server 增加 60s `sweep`，
  `ets:select_delete` 删除「窗口已过且不在冷却期」的条目（match spec 见 D01 §2）；
  表惰性创建场景 sweep 前判存在。
- `apps/lg_router/src/lg_affinity.erl`：现有 sweep 顺带删除 `{{tokens, CredId}, V, At}`
  中 `At` 超 30 天的条目；`{{turn, Route}, N}` 有界（=路由数），加注释说明不清扫的理由。
- `apps/lg_router/src/lg_cooldown.erl`：5min 低频 `select_delete`，
  删除 `Now > Until + 2*Duration` 的条目（不影响 streak 判定语义）。
- `apps/lg_web/src/`（lg_session 所在模块）：每日一次清理 `expires_at < now` 的会话行。

## 验收标准

- [ ] eunit：login_guard 造过期/冷却中/窗口内三类条目，sweep 后仅第一类被删；
- [ ] cooldown streak 语义回归：删除后再次失败的 streak 从 1 重新计（与现状惰性覆盖一致）；
- [ ] affinity/session 清扫各有测试覆盖；
- [ ] `rebar3 eunit xref dialyzer` 全绿。

## 预估

~100 行（含测试），0.5 天。
