# T20 客户端断开感知（开流前等待 + 非流式记账）

优先级：P1 ｜ 设计：[D05 §2.1](../designs/D05-regressions-stability-perf.md) ｜ 状态：待评审 ｜ 依赖：无

## 背景

流式请求只有开流后的 `recv_loop` 处理 `'EXIT'`；排队（lg_conc、out_rate wait）、patience sleep、
首包前 `gun:await` 期间客户端断开不被察觉，网关等满 300s 并继续回退，占名额、上游照常计费。
非流式 `sync/4` 未 trap_exit，客户端断开时请求日志与预算扣费丢失。

## 目标

客户端断开后 ≤1s 内停止等待、取消上游、释放名额，并照常记日志（499）与计费。

## 改动点

- `apps/lg_web/src/lg_web_llm.erl:267` `hold_tick/0`：增加
  `receive {'EXIT', _, R} -> throw({client_exit, R}) after 0 -> ok end`。
- `apps/lg_web/src/lg_web_llm.erl:186` `sync/4`：开启 trap_exit，传入 Idle，`after` 中保证 `lg_web_llm_log:record` 与 `lg_router:done`。
- `apps/lg_provider/src/lg_http.erl:441` await_loop：分段 `gun:await`（≤250ms）并调用 Idle。
- `apps/lg_router/src/lg_router_attempt.erl` patience_wait：`timer:sleep` 改分段 sleep + Idle。
- `apps/lg_router/src/lg_out_rate.erl` `wait/3`、`lg_conc:await_grant`：确认每轮调用 Idle。
- `apps/lg_router/src/lg_router.erl` `stream_open`/sync 路径：捕获 `{client_exit, _}`，cancel 上游流、
  释放名额、以 `status = 499`（`client_closed`）记日志并调用 `done`。

## 验收标准

- [ ] 集成测试：lg_conc 排队期间杀掉客户端，1s 内名额释放、日志记 499；
- [ ] 首包前断开：上游 gun 流被 cancel（meck 断言），不再尝试后续候选；
- [ ] 非流式断开：请求日志存在、预算已扣；
- [ ] `rebar3 eunit xref dialyzer` 全绿；docs/observability.md 补充 499 语义。

## 预估

~180 行（含测试），1 天。
