# T34 Codex 内部上下文输出兼容转换

优先级：P0 ｜ 设计：[D06](../designs/D06-codex-context-outputs.md) ｜ 状态：待评审 ｜ 依赖：— ｜ 来源：[F01](../feedbacks/F01-litegate-codex-context-output.md)

## 改动点

- `apps/lg_provider/src/lg_conv_responses.erl`：
  - 正常工具输出继续要求 `call_id`；
  - 新增无 `call_id` 但有 `name` 的 Codex 上下文输出分支；
  - 转换为带 `<context_tool_output>` 标签的 Chat 用户消息；
  - 抽取共享 output 序列化 helper。
- `apps/lg_provider/test/lg_conv_responses_tests.erl`：
  - 覆盖 `agent.goal_objective`；
  - 回归正常 `call_id` 输出；
  - 回归未知 output 仍 unsupported。
- `apps/lg_router/test/lg_middleware_tests.erl`：
  - 测试 teardown 恢复 `nonode@nohost`，避免分布式节点名污染后续 mnesia schema 测试。

## 验收标准

- [x] Codex goal 上下文输出不再导致 `Unsupported by target protocol`。
- [x] 正常工具结果仍转换为 `role=tool`。
- [x] 缺少 `call_id` 和 `name` 的未知输出仍被拒绝。
- [x] `rebar3 eunit --module=lg_conv_responses_tests` 全绿。
- [x] `rebar3 eunit`、`rebar3 xref`、`rebar3 dialyzer` 全绿。

## 预估

~80 行（含文档与测试），2 小时。
