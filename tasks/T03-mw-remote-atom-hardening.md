# T03 mw_remote 动态原子硬化

优先级：P0 ｜ 设计：[D01 §4](../designs/D01-memory-safety.md) ｜ 状态：待开始 ｜ 依赖：无

## 背景

`lg_mw_remote.erl:49-50` 对管理员配置的 node/module 使用 `binary_to_atom/1`，
是全项目仅有的两处动态原子生成之一（原子不可回收，理论注入面）。

## 目标

改为 `binary_to_existing_atom/2`，配置了不存在的节点/模块时返回明确错误而非创建原子。

## 改动点

- `apps/lg_router/src/lg_mw_remote.erl`：两处 `binary_to_atom` 改
  `binary_to_existing_atom(B, utf8)`，捕获 `error:badarg` 返回
  `{error, {unknown_node_or_module, B}}`；调用方（中间件加载路径）记 warning 并跳过。

## 验收标准

- [ ] eunit：不存在的 module/node 配置返回错误且不创建原子
      （`erlang:system_info(atom_count)` 前后不变）；
- [ ] 合法配置（本节点 + 已加载模块）行为不变；`lg_mw_tests` 全绿。

## 预估

~30 行，0.5 小时级，可与 T01/T02 同批提交。
