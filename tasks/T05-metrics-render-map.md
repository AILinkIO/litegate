# T05 lg_metrics render/snapshot 消除 O(n²)

优先级：P1 ｜ 设计：[D02 §2](../designs/D02-hotpath-performance.md) ｜ 状态：待开始 ｜ 依赖：无

## 背景

`lg_metrics.erl:104-200`：`render/0` 与 `snapshot/0` 对每个 series 的每个统计键/
直方图桶在整份 `ets:tab2list` 结果上做 `lists:keyfind`（L184-185、L199-200），
指标基数大时一次 /metrics 抓取为数十万次列表遍历。

## 目标

渲染前一次性转 map，查找 O(1)；纯内部重构，输出逐字节不变。

## 改动点

- `apps/lg_core/src/lg_metrics.erl`
  - `render/0`、`snapshot/0`、`hist_series/*`：`Rows` → `RowMap = maps:from_list(Rows)`；
  - `Get`/`GetB` 闭包改 `maps:get(Key, RowMap, 0)`。

## 验收标准

- [ ] 先补快照 eunit：固定一组指标下 `render/0` 输出与改造前逐字节一致；
- [ ] `snapshot/0` 结构（counters/histograms/gauges）与 OTLP 导出回归
      （`lg_otlp_metrics_tests`）全绿；
- [ ] 造 5000 行指标对比 render 耗时（PR 描述记录）；
- [ ] `rebar3 eunit xref dialyzer` 全绿。

## 预估

~40 行，0.5 天（大半在快照测试）。
