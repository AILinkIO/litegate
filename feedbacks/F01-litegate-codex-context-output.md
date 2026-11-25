# F01 LiteGate：Codex 无 call_id 的 function_call_output 转换失败

日期：2026-11-26 ｜ 优先级：P0 ｜ 状态：待评审（T34 已实现兼容）

## 现象

Codex 请求经 LiteGate 转换到 Chat Completions 时返回：

```json
{
  "error": {
    "code": null,
    "message": "Unsupported by target protocol: input item function_call_output",
    "param": null,
    "type": "invalid_request_error"
  }
}
```

## 复现请求项

Codex 内部 `agent.goal_objective` 上下文输出使用了 `function_call_output` 类型，但没有 `call_id`：

```json
{
  "type": "function_call_output",
  "id": "fco_...",
  "name": "goal_objective",
  "namespace": "agent",
  "output": "完成W开头的任务"
}
```

## 影响

该 item 会进入后续会话历史；只要路由目标需要 Responses → Chat 转换，
同一 Codex 会话会持续失败。

## 定位

- `lg_conv_responses` 只处理带 `call_id` 的工具输出。
- 无 `call_id` 时落入通用 unsupported 分支。
- 错误外壳与文案均由 `lg_llm_error` 渲染，可确认不是上游原始错误。

## 预期

LiteGate 应识别这种 Codex 内部上下文输出，并以 Chat 兼容消息保留其内容，
而不是拒绝整个请求。
