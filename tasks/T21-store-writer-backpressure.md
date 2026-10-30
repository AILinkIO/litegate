# T21 存储写者背压、写盘错误与句柄解耦

优先级：P1 ｜ 设计：[D05 §2.2](../designs/D05-regressions-stability-perf.md) ｜ 状态：待评审 ｜ 依赖：无

## 背景

`lg_store:record/3` 为 cast、无背压；写者进程内同步做 3 次 `put_batch_atomic` + 最多 200 次分词写检索索引。
写者跟不上时邮箱无界增长直至 OOM，且 flush/janitor 调用超时崩溃。写盘错误被吞掉（磁盘满静默丢数据），
`sync` 失败崩溃后 `terminate` 重放导致用量重复计数。写者重启期间 `cache_get`/`response_get` 抛 badarg → 500。

## 目标

写入路径内存有界、可观测降级；写盘错误可见；崩溃不重复计数；写者重启不影响请求热路径。

## 改动点

- `apps/lg_store/src/lg_store_writer.erl`
  - `init`：`process_flag(message_queue_data, off_heap)`；
  - 积压计数用 `atomics`（record 时 +1、处理时 -1），`record/3` 按 `store_queue_soft`/`store_queue_hard` 分级降级，
    计数 `litegate_store_degraded_total{level}`；
  - `:266-271` batch 错误：计数 `litegate_store_write_errors_total{cask}`，写入 health 状态；
  - usage/sessions 写盘前从 State 取出清空，失败回滚；`:131-136` terminate 用 try 包裹且只写未落盘部分；
  - `:222-226` 检索索引写入移至新进程 `lg_store_indexer`（有界队列，满则丢弃计数）。
- 新增 `lg_store_handles`（`lg_store_sup` 改 rest_for_one，handles 为第一个子进程）持有 cask 句柄，写者崩溃不 close。
- `apps/lg_router/src/lg_router.erl:433`、`apps/lg_web/src/lg_web_llm.erl:170`：读句柄失败按 miss 处理。
- `apps/lg_core`：新增配置 `store_queue_soft`（5000）、`store_queue_hard`（50000）。
- `/health`：写盘错误时 degraded。

## 验收标准

- [ ] 压测：meck 让 bitcask 每批延迟 200ms，2000 rps 写入 60s，写者内存有界、降级计数增长；
- [ ] 模拟 `bitcask:sync` 失败：重启后 usage 不重复；
- [ ] kill 写者期间 `cache_get` 返回 miss，无 500；
- [ ] 磁盘写错误时 `/health` 返回 degraded 且指标递增；
- [ ] `rebar3 eunit xref dialyzer` 全绿；docs/observability.md 更新指标与降级说明。

## 预估

~350 行（含测试），2 天。
