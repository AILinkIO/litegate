# T31 存储查询索引与 janitor 成本优化

优先级：P2 ｜ 设计：[D05 §3.4](../designs/D05-regressions-stability-perf.md) ｜ 状态：待评审 ｜ 依赖：T21（写者结构调整）

## 背景

`errors_only` 无索引需全扫 logs；usage 查询逐行解码混合行，概览页每次扫 15 天，`lg_budget:init` 启动扫一个月；
`alerts/1` 全量 fold 再排序；janitor 每次 delete 都 flush+fsync、逐前缀调用写者、`length/1` 导致 O(n²)，
cache/responses 过期清理整表解码并一次性删除，易超时反复重跑。

## 改动点

- `apps/lg_store/src/lg_store.erl:235-247`：新增 `$e` 错误索引（status ≥400 或 error 非空），`errors_only` 优先走索引。
- `apps/lg_store/src/lg_store.erl:382-424`、`lg_store_writer`：usage 键加类别字节 `<<Hour:32, Kind:8, …>>`，
  写入时维护每小时总量行（Kind=0）；概览与 `lg_budget.erl:77` 只读总量行。**存储格式变更**：
  janitor 首次运行时重写近 31 天 usage，旧格式兼容读取一个版本。
- `apps/lg_store/src/lg_store.erl:483-491`：`alerts/1` 反向迭代取最近 N 条。
- `apps/lg_store/src/lg_store_janitor.erl:88-97, 137-156`：跨前缀累积 1000 键再调用写者；计数器代替 `length`。
- `apps/lg_store/src/lg_store_writer.erl:99-102`：`delete` 仅 Cask=usage 时 flush_usage。
- `apps/lg_store/src/lg_store_janitor.erl:101-117`：cache/responses 新写入键加 `<<ExpireTs:64, …>>` 前缀，
  过期清理改范围扫描 + 每批 1000 删除；旧键兼容一个保留周期。

## 验收标准

- [ ] 100 万条日志、0.1% 错误：`errors_only` 首页 <50ms；
- [ ] 概览页 15 天查询解码行数 = 小时数（360）；
- [ ] janitor 删除 100 万键期间写者 `message_queue_len` 峰值 <1000，无超时；
- [ ] 旧格式数据升级后查询结果与升级前一致（迁移测试）；
- [ ] `rebar3 eunit xref dialyzer` 全绿；CHANGELOG 标注存储格式变更与回滚注意事项。

## 预估

~400 行（含迁移与测试），2.5 天。
