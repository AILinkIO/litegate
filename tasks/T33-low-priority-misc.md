# T33 低优先级杂项（备份、导出一致性、目录同步保护）

优先级：P2 ｜ 设计：[D05 §3.6](../designs/D05-regressions-stability-perf.md) ｜ 状态：待评审 ｜ 依赖：无

## 改动点

- `apps/lg_router/src/lg_backup.erl:107-111`：`ensure_dir`/`rename` 失败返回错误并记日志，不崩溃 gen_server；
  文件名加毫秒或序号避免同秒覆盖。
- `apps/lg_router/src/lg_config_io.erl` `export`：在只读事务中读取所有表，保证同一时刻快照。
- `apps/lg_catalog/src/lg_catalog_sync.erl:51, 73`
  - 每次调度时重读 `catalog_sync_interval_ms`（0 → N 运行时生效）；
  - 本次同步将删除的 L0 模型比例 >30% 时中止并告警（防 models.dev 返回残缺 JSON）。
- 路线图（不在本任务实现）：bitcask 在线一致性快照备份，记录到 D04 §5。

## 验收标准

- [ ] eunit：备份目录不可写时 gen_server 存活并返回错误；同秒两次备份生成两个文件；
- [ ] eunit：模拟 models.dev 返回 10% 数据时同步中止、现有模型保留；
- [ ] 运行时修改同步间隔后下一轮按新间隔调度；
- [ ] `rebar3 eunit xref dialyzer` 全绿。

## 预估

~100 行（含测试），0.5 天。
