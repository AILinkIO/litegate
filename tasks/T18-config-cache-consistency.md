# T18 lg_config 缓存一致性（导入失效 + 丢失更新）

优先级：P0 ｜ 设计：[D05 §1.3](../designs/D05-regressions-stability-perf.md) ｜ 状态：待评审 ｜ 依赖：T16（导入后重建通配缓存）

## 背景

T04 的已解析值缓存是整张 map 存 persistent_term：miss 时用旧快照回填会覆盖并发 `set` 的失效，
旧值永久驻留；每次 miss 都 `persistent_term:put` 触发全局扫描。配置导入/恢复直接写 `lg_setting`，
不失效缓存，导入后需重启才生效。

## 目标

任何写配置路径之后 `get/1` 立即返回新值；并发读写下不出现旧值回写；miss 不触发全局扫描。

## 改动点

- `apps/lg_core/src/lg_config.erl:124-133, 218-220`
  - 已解析值缓存改为 ETS `lg_config_cache`（read_concurrency，由 lg_core 常驻进程在 init 创建）；
  - 版本号 `{'$ver', N}`：`set/unset/invalidate_all` 先递增版本再删条目，`get` miss 时 resolve 前后版本不一致则不回填；
  - 新增 `invalidate_all/0`；defaults 继续放 persistent_term。
- `apps/lg_router/src/lg_config_io.erl:105-106`：导入成功后调用 `lg_config:invalidate_all()`、
  `lg_routes:rebuild_wildcards()`、`lg_out_rate:reset()`。
- `lg_backup` 恢复路径同上。

## 验收标准

- [ ] 并发测试：1 个进程循环 `set(K, V_i)`、8 个进程循环 `get(K)` 10 秒，结束后 `get(K)` 等于最后写入值；
- [ ] 导入/恢复后 `get/1` 立即返回新值；
- [ ] miss 路径无 `persistent_term:put`（meck 断言）；
- [ ] `rebar3 eunit xref dialyzer` 全绿。

## 预估

~120 行（含测试），0.5 天。
