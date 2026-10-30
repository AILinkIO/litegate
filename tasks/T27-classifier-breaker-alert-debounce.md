# T27 意图分类器熔断与告警防抖

优先级：P1 ｜ 设计：[D05 §2.8](../designs/D05-regressions-stability-perf.md) ｜ 状态：待评审 ｜ 依赖：无

## 背景

分类器故障时每个新会话请求额外等待 8～11s（无负缓存/熔断）；judge 超时被 kill 时费用丢失。
告警热路径每次失败都 cast 并全表查询规则、格式化文本；upstream_down 无静默期，抖动刷屏；
sender 邮箱无上限；`fails` 单调增长。

## 改动点

- `apps/lg_router/src/lg_rules.erl`（ask_route/ask_systemone/ask_llm）
  - `{classifier, Route}` 熔断：窗口内连续失败 ≥3 次 open 30s，期间走默认分支，计数 `litegate_classifier_skipped_total`；
  - 相同 CacheKey 并发请求 singleflight 合并。
- `apps/lg_router/src/lg_router.erl` `judge/5`：超时路径记日志并按已知用量计费（或改为协作式取消）。
- `apps/lg_router/src/lg_alert.erl:134-144`、`lg_alerts`
  - 规则缓存 persistent_term（规则写入时刷新），无匹配规则时调用方直接返回、不 cast；
  - 文本仅在确定发送时格式化；
  - `alert_silence_ms`（300000）、`alert_recover_ms`（持续健康才发恢复）；
  - sender 队列上限 1000，超出丢弃计数；`fails` 24h 无更新清扫。
- `apps/lg_router/src/lg_health.erl:40`：调用前判规则存在。

## 验收标准

- [ ] eunit：分类器 mock 持续超时，第 4 个请求起无额外延迟，30s 后半开重试；
- [ ] eunit：目标 10 次故障/恢复抖动只产生 1 对告警/恢复；
- [ ] 通道不可达时 sender 邮箱 ≤1000；
- [ ] `rebar3 eunit xref dialyzer` 全绿；docs/observability.md 更新告警参数。

## 预估

~220 行（含测试），1.5 天。
