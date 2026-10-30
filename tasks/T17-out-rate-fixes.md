# T17 出站节流 lg_out_rate 缺陷修复

优先级：P0 ｜ 设计：[D05 §1.2](../designs/D05-regressions-stability-perf.md) ｜ 状态：待评审 ｜ 依赖：无

## 背景

T08/T09/T11 实现存在多处缺陷：sweep 每分钟清空全部窗口、`reset_credential` 匹配不到任何对象、
首次 429 将 Cap 压到 `out_rate_min_rpm`（6）、并发 429 重复减半、Retry-After 后永不建 Cap、
排队者窗口滚动时集体放行，以及排队成功后丢弃后续候选。

## 目标

出站节流行为符合 D03 设计意图：窗口计数准确、Cap 起点基于实际观测速率、
每个窗口最多收紧一次、放行不超 Cap、回退链路完整。

## 改动点

- `apps/lg_router/src/lg_out_rate.erl`
  - `:272` sweep match spec 改为 `[{{{'_', '$1'}, '_'}, [{'<', '$1', Old}], [true]}]`；
  - `:240-241` reset_credential 改为 `{{{CId,'_'},'_'},'_'}` 与 `{{CId,'_'},'_','_','_','_','_'}`；
  - `on_rate_limit/2`：进入 `step_429` 前写入 `observed => rate(Key)` 并持久化；
  - STATE 增加 `last_cut_at`，距上次下调不足 `max(1000, RecoveryMs div 10)` ms 不再减半（表结构变更需同步 `state_of`/insert）；
  - `step_429` Retry-After 分支：`cap = undefined` 时同时建立首犯 Cap；
  - `allow/1` 放行时原子预占（`update_counter +1`，超 Cap 回滚 -1），`record/1` 识别已预占不重复计数；
  - `step_ok/2` 解除条件改为不依赖被每次回升重置的 `ok_since`（见 D05 §1.2 第 7 点）。
- `apps/lg_router/src/lg_router_attempt.erl:140`：`attempt_plan_conc([{RouteName, T, Cred} | Rest], …)`。

## 验收标准

- [ ] eunit：sweep 后当前与上一分钟桶保留、更早桶删除；
- [ ] eunit：reset_credential 后该凭证在 WIN/STATE 中条目数为 0，其他凭证不受影响；
- [ ] eunit：observed=100 RPM 时首次 429 后 Cap = round(100 × factor)；
- [ ] eunit：1 秒内 10 个并发 429 只减半一次；先 RA 后无 RA 的 429 序列能建立 Cap；
- [ ] 并发测试：Cap=10 时 50 个排队者窗口滚动后放行数 ≤10；
- [ ] 集成测试：排队成功后该目标 5xx，请求回退到下一候选；
- [ ] `rebar3 eunit xref dialyzer` 全绿。

## 预估

~200 行（含测试），1 天。
