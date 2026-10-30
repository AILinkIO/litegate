# T23 额度/余额刷新去重（防刷新风暴）

优先级：P1 ｜ 设计：[D05 §2.4](../designs/D05-regressions-stability-perf.md) ｜ 状态：待评审 ｜ 依赖：无

## 背景

`lg_plan` 的 `checked_at` 在 fetch 完成后才写入，期间每个请求都 cast refresh；每条 cast 串行执行完整 `run`
（含网络 I/O 与两遍 `lg_credentials:list()`）；`lg_router_attempt` 遇 quota/credit 错误无条件 cast lg_balance。
高 QPS 下刷新消息堆积、串行打上游额度接口，控制台“立即刷新”超时。

## 改动点

- `apps/lg_router/src/lg_plan.erl:85-94, 138-140`
  - `refresh_after/2`：cast 前 `ets:insert_new(?TAB, {{refreshing, CredId}, Now})`，失败跳过；
  - handle_cast 内再判一次 `checked_at` 间隔；
  - fetch 改在 per-credential worker 进程执行，完成后 cast 结果并删除 refreshing 标记（含失败与超时）；
  - `refresh/1`（控制台）等待 worker 结果，超时返回 `{ok, refreshing}`。
- `apps/lg_router/src/lg_balance.erl:62-70`：同样的去重与 worker 化。
- `apps/lg_router/src/lg_router_attempt.erl:205`：调用前检查 refreshing 标记。

## 验收标准

- [ ] eunit：1000 次并发 `touched/1`，上游额度接口（meck）只被调用 1 次；
- [ ] fetch 卡住时 `status/1` 与 `state/1` 不阻塞；worker 崩溃后标记被清除；
- [ ] `rebar3 eunit xref dialyzer` 全绿。

## 预估

~150 行（含测试），1 天。
