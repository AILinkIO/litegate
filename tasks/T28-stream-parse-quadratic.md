# T28 流式解析 O(n²) 与 sub-binary 驻留治理

优先级：P1 ｜ 设计：[D05 §3.1](../designs/D05-regressions-stability-perf.md) ｜ 状态：待评审 ｜ 依赖：T25（共享 `sse_max_event_bytes`）

## 背景

SSE 缓冲每块整段拷贝并从头扫描；复读检测（默认开启）每 token 重新 split 整个半行；
`json:decode` 返回的 delta 是输入 sub-binary，累积文本钉住整块原始数据（10 万 token 单流约 30MB）。

## 改动点

- `apps/lg_provider/src/lg_provider_stream.erl:149`、`lg_sse.erl:16-17, 38-45`
  - 缓冲改 iolist + 已扫描偏移，只在“上次尾部 3 字节 + 新数据”中找分隔符；
  - `\r` 规范化只作用于单个已切出的事件；
  - 超过 `sse_max_event_bytes` 以上游错误结束。
- `apps/lg_provider/src/lg_loop.erl:49-56`：只 split 新 Text，无 `\n` 时直接追加，Partial 截断到 1KB；tail 降低拷贝频率。
- `apps/lg_provider/src/lg_stream.erl:384, 405`、`lg_resp_stream.erl:335, 415, 436`：累积处 `binary:copy/1`，
  或累积 iolist 每 64KB 合并一次。

## 验收标准

- [ ] 基准：2MB 事件分 200 块到达，解析耗时与块数近似线性（附前后对比）；
- [ ] 基准：50KB 单行输出（1.5 万 delta）lg_loop 总分配 <5MB；
- [ ] 10 万 token 流结束前处理进程 `process_info(binary)` 引用总量 <2MB；
- [ ] 现有 `lg_stream_tests`、`lg_provider_tests` 全绿；跨块分隔符（`\r\n` 被拆开）有用例；
- [ ] `rebar3 eunit xref dialyzer` 全绿。

## 预估

~200 行（含测试与基准），1.5 天。
