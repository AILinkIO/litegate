# D06 Codex 内部上下文输出的 Responses 兼容转换（P0）

状态：待评审 ｜ 对应任务：[T34](../tasks/T34-codex-context-outputs.md) ｜ 来源反馈：F01/F02

## 背景

Codex 0.172.0 的内部上下文机制会发送无 `call_id` 的
`function_call_output`，例如 `agent.goal_objective`。该 item 不是普通工具结果，
但它与普通工具结果共用 `type`。LiteGate 的 Responses → Chat 转换目前只接受
带 `call_id` 的输出，导致受影响会话持续 400。

## 目标

- 兼容 Codex 当前 wire format。
- 保留上下文内容，不静默丢弃。
- 不改变带 `call_id` 的正常工具结果转换。
- 继续拒绝既无 `call_id` 也无法识别为上下文输出的未知 item。

## 分类

| 条件 | 语义 | 转换 |
|---|---|---|
| `function_call_output` + `call_id` | 正常工具结果 | `role=tool` |
| `function_call_output`，无 `call_id`，有 `name` | Codex 上下文输出 | 上下文消息 |
| 其他输出项缺少必要关联字段 | 协议错误 | 保持 unsupported |

`custom_tool_call_output` 仍要求 `call_id`；当前观察到的 Codex 内部上下文
只出现在 `function_call_output`。

## Chat 表示

命名空间沿用 LiteGate 现有 `namespace__name` 展开规则：

```text
agent__goal_objective
```

转换为用户角色中的显式上下文块：

```text
<context_tool_output name="agent__goal_objective">
完成W开头的任务
</context_tool_output>
```

选择 `role=user` 的原因：

1. 所有 OpenAI-compatible Chat 上游均可接受；
2. 不依赖上游认识某个未注册 function；
3. 不需要伪造 assistant `tool_calls` 和 `call_id`；
4. 显式标签避免模型把内部输出误读成用户自然语言指令。

如果紧邻前序消息本身就是 Codex 内部上下文用户消息，实现可选择追加到该
消息；第一版先生成独立消息，降低转换器的状态复杂度。

## 实现要点

1. 正常输出分支继续优先匹配 `call_id`。
2. 新增无 `call_id` 但有 `name` 的 `function_call_output` 分支。
3. 抽出共享的 `output_text/1`，统一字符串、content parts 和结构化 JSON 的序列化。
4. `namespace` 为空或缺失时只使用 `name`。
5. 未知输出项保持现有 `{unsupported, <<"input item ", Type/binary>>}` 语义。

## 验收

- [x] `agent.goal_objective` 示例转换为独立上下文消息。
- [x] 带 `call_id` 的现有转换行为不变。
- [x] 无 `call_id` 且无 `name` 的 `function_call_output` 仍然拒绝。
- [x] `rebar3 eunit --module=lg_conv_responses_tests` 通过。
- [x] `rebar3 eunit`、`rebar3 xref`、`rebar3 dialyzer` 通过。
