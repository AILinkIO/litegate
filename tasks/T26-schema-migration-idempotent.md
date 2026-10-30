# T26 schema 迁移幂等与节点名防护

优先级：P1 ｜ 设计：[D05 §2.7](../designs/D05-regressions-stability-perf.md) ｜ 状态：待评审 ｜ 依赖：无

## 背景

迁移每表单独事务、版本号最后才写；中途崩溃后重启会对已转换元组套用旧 pattern 触发 function_clause，
节点永远起不来。节点名不匹配时可能静默新建 disc schema（plausible）；开发 shell 与 release 节点名不一致。

## 改动点

- `apps/lg_core/src/lg_schema.erl:136-143, 157-180`
  - transform fun 按元组大小/形状识别已转换记录并原样返回；
  - 每表完成后写 `{schema_step, Table, Version}` 进度，重启跳过已完成表；
  - 迁移前复制 mnesia 目录为 `Mnesia.<node>.pre-v<N>`。
- `apps/lg_core/src/lg_schema.erl:77-90`：`schema.DAT` 存在但 `storage_type` 为 ram_copies 时拒绝启动，
  提示 `lg_schema:rename_node/1`。
- `rebar.config`：`dist_node` 改为 `{name, 'litegate@127.0.0.1'}`，修正注释。

## 验收标准

- [ ] eunit：注入“第一张表转换后崩溃”，重启后迁移完成、所有记录为新格式；
- [ ] eunit：已是新版本的数据再跑迁移无变化；
- [ ] 以不同节点名启动已有数据目录时报明确错误，原文件未被改写；
- [ ] `rebar3 eunit xref dialyzer` 全绿；docs/deploy.md 补充节点名与迁移备份说明。

## 预估

~150 行（含测试），1 天。
