# T12 非 chat 端点 stream:true 兼容

优先级：P2 ｜ 设计：[D04 §2](../designs/D04-features-and-security.md) ｜ 状态：待开始 ｜ 依赖：无

## 背景

`lg_web_llm:call_prepared` 只在 `Kind =:= chat` 时走流式路径，
embeddings/images/speech 请求中的 `stream: true` 被静默忽略，
与 OpenAI SDK 行为不完全兼容。

## 目标

上游原生支持流式的非 chat 端点走既有 SSE 管道透传；不支持的保持整包返回，
但在 attempt 信息中记 `stream_ignored => true` 供控制台展示。

## 改动点

- `apps/lg_provider/src/lg_provider.erl`（协议元数据）：各协议/Kind 声明
  `streamable_kinds`。
- `apps/lg_web/src/lg_web_llm.erl`：Kind 分支按能力声明决定走流式或整包；
  整包路径写 `stream_ignored` 标记进请求日志。
- `apps/lg_provider/src/lg_stream.erl`：确认非文本 body（音频/图片 base64）的
  流式记账（字节数）正确，必要时补齐。
- 控制台请求详情展示 `stream_ignored`。

## 验收标准

- [ ] mock 上游 eunit：chat/embeddings/audio 各自 stream 行为符合设计；
- [ ] 现有 responses/转换路径回归全绿；
- [ ] `rebar3 eunit xref dialyzer` 全绿。

## 预估

~150 行，1 天。
