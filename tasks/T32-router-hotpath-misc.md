# T32 路由热路径杂项（rotate 计数、凭证复用、同步中间件、last 表清扫）

优先级：P2 ｜ 设计：[D05 §3.5](../designs/D05-regressions-stability-perf.md) ｜ 状态：待评审 ｜ 依赖：T17（out_rate 同文件）

## 改动点

- `apps/lg_router/src/lg_affinity.erl:59-63`（`lg_strategy.erl:28` 调用）：rotate 策略去掉 `match_object` 全表扫描，
  维护 `{route_target_count, Route, Target}` 计数，`put_target` 换目标时增减，sweep 校正。
- `apps/lg_router/src/lg_out_rate.erl` `allow/1`：接收 plan 中已有凭证记录，避免每次 `lg_credentials:get`；`state_of` 只读一次。
- `apps/lg_router/src/lg_middleware.erl:236` `call_sync`：本地中间件在当前进程执行，`erlang:start_timer` 超时保护；
  仅 remote 类型使用独立进程。
- `lg_health` `?LAST` 表、`lg_live` `{last, Route}`：纳入周期 sweep（24h 无更新删除）。

## 验收标准

- [ ] 10 万会话下 rotate 单次选择 <50µs（基准）；计数在 sweep 后与实际一致；
- [ ] 同步中间件超时行为与改动前一致（现有 lg_mw 测试全绿）；
- [ ] last 表清扫有测试覆盖；
- [ ] `rebar3 eunit xref dialyzer` 全绿。

## 预估

~180 行（含测试），1 天。
