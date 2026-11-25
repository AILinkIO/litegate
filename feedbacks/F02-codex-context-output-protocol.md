# F02 Codex：内部上下文输出与 Responses 工具结果共用类型

日期：2026-11-26 ｜ 优先级：P1 ｜ 状态：建议反馈上游

## 问题

Codex 会发送类似下面的 item：

```json
{
  "type": "function_call_output",
  "id": "fco_...",
  "name": "goal_objective",
  "namespace": "agent",
  "output": "..."
}
```

OpenAI Responses API 的 `function_call_output` 通常应通过 `call_id`
关联前一个 `function_call`。该 item 缺少 `call_id`，但携带 `name` / `namespace`，
语义更接近内部上下文，而不是真实工具调用结果。

## 影响

严格校验或协议转换的网关无法可靠区分：

1. 与前序 `function_call` 配对的正常工具结果；
2. Codex harness 注入的内部上下文输出。

## 建议

为内部上下文引入独立 item 类型，例如：

```json
{
  "type": "context_tool_output",
  "name": "goal_objective",
  "namespace": "agent",
  "output": "..."
}
```

如果必须保持旧版本兼容，也应携带合成 `call_id` 并同时输出匹配的
`function_call`。网关侧仍应对旧格式做兼容处理。
