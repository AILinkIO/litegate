# T07 lg_store 查询 flush 按范围拆分

优先级：P1 ｜ 设计：[D02 §4](../designs/D02-hotpath-performance.md) ｜ 状态：待开始 ｜ 依赖：无

## 背景

`lg_store` 的 logs/sessions/search 查询入口都先 `flush()`
（`lg_store.erl:222,300,310,350,377,478`），而 writer 的 flush 固定执行
`flush_usage(flush_logs(S))`（`lg_store_writer.erl:90-91`）。查日志并不需要合并
usage 内存计数，高峰期每次列表查询白付一次小时用量读-改-写。

## 目标

flush 支持范围参数；交互数据查询只等日志批次，用量查询才做全量 flush。

## 改动点

- `apps/lg_store/src/lg_store_writer.erl`：`flush/1`（`logs | all`），
  `handle_call({flush, Scope}, …)` 分别执行 `flush_logs/1` 或两者。
- `apps/lg_store/src/lg_store.erl`：`flush/0` 保持 `all` 语义（停机路径）；
  各查询入口改 `flush(logs)`（logs/sessions/search/messages）或
  `flush(all)`（usage/cost 类）。

## 验收标准

- [ ] eunit：写日志后立即 `flush(logs)` 查询可见；usage 记录后 `flush(all)` 汇总正确；
- [ ] 现有 `lg_store` 测试与保留策略（retention）回归全绿；
- [ ] `rebar3 eunit xref dialyzer` 全绿。

## 预估

~50 行，0.5 天。
