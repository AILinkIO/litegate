# T30 流式事件单次编解码

优先级：P2 ｜ 设计：[D05 §3.3](../designs/D05-regressions-stability-perf.md) ｜ 状态：待评审 ｜ 依赖：T28（同一组文件，建议之后做）

## 背景

Responses 转换模式下每个事件最多 4 次 decode、3 次 encode（stage2 经 Chat 帧中转再 parse；
think 拆分与结构化输出各自再 decode）。

## 改动点

- `apps/lg_provider/src/lg_stream.erl`：新增内部接口返回 Chat chunk map（不 encode）。
- `apps/lg_provider/src/lg_provider_stream.erl:200-212`（stage2）、`:258-263`（think）：
  在同一已解码 map 上链式处理，出口 encode 一次。
- `apps/lg_provider/src/lg_structured.erl:165`：接收 map 而非 binary。

## 验收标准

- [ ] meck 计数：Responses 转换 + think + structured 全开时每事件 `json:decode` 调用 =1；
- [ ] 输出与改动前逐字节一致（录制回放用例）；
- [ ] 基准吞吐对比写入 PR；
- [ ] `rebar3 eunit xref dialyzer` 全绿。

## 预估

~150 行（含测试），1 天。
