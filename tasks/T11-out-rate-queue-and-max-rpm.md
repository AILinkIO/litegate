# T11 节流排队策略与凭证 max_rpm（自适应限流 Phase 3）

优先级：P2 ｜ 设计：[D03 §3.5、§6](../designs/D03-adaptive-upstream-throttle.md) ｜ 状态：待开始 ｜ 依赖：T09

## 背景

Phase 2 中唯一候选被节流时快速失败 429。对多数客户端，短暂等待窗口滚动后放行
体验更好；另外供应商明示配额（如"Qwen3.8-Max 1200 RPM"）应支持直接静态配置。

## 目标

1. 唯一候选被节流时可配置为**排队等待**（`out_rate_wait = queue | fail`，默认 queue）；
2. 凭证选项 `max_rpm` 静态上限，与学习 Cap 取 min；
3. 控制台显示节流状态徽标（"节流中 cap=N/min"、"暂停至 mm:ss"）。

## 改动点

- `apps/lg_router/src/lg_out_rate.erl`：`wait/3`（Key, RetryMs, IdleCb）——
  复用 `lg_conc:wait` 的分段 sleep + idle 保活帧模式，上限 `queue_wait_ms`，
  到点重查 `allow/1`；支持 `lg_shutdown:draining()` 提前退出。
- `apps/lg_router/src/lg_router_attempt.erl`：唯一候选分支按 `out_rate_wait` 选择
  queue/fail；queue 超时后按 fail 路径返回 429。
- `apps/lg_core/src/lg_config.erl`：`out_rate_wait(queue)`。
- `apps/lg_router/src/lg_options.erl`：credential_spec 增加
  `<<"max_rpm">> => {max_rpm, non_neg_integer}`；`lg_out_rate:allow/1` 计入 min 逻辑。
- `web/src/features/credentials/`：对话框加 max_rpm 输入（与 max_concurrency 同排）、
  列表加徽标；live API 透出 `snapshot/0` 的 cap/paused 状态。
- `docs/routing.md`、`docs/configuration.md` 更新。

## 验收标准

- [ ] eunit：queue 等待到窗口滚动后放行、超时 fail、draining 提前退出；
      max_rpm 与学习 Cap 取 min；
- [ ] 流式请求排队期间客户端持续收到保活帧（集成测试）；
- [ ] 控制台徽标与 API 输出一致；
- [ ] `rebar3 eunit xref dialyzer`、`npm test` 全绿。

## 预估

~250 行（含前端），1-1.5 天。
