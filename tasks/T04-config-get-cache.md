# T04 lg_config:get/1 缓存

优先级：P1 ｜ 设计：[D02 §1](../designs/D02-hotpath-performance.md) ｜ 状态：待开始 ｜ 依赖：无

## 背景

`lg_config:get/1`（`lg_config.erl:97-102`）每次调用重建约 60 项的 `defaults/0` map，
再走 mnesia dirty_read 逐层解析。热路径（流式 keepalive 每 tick、limiter、patience
判定）高频调用，是全项目性价比最高的优化点。

## 目标

两级缓存：defaults 进 persistent_term；解析结果带版本号缓存，`set/unset` 时失效。
`get/1` 命中缓存时零 mnesia 访问。

## 改动点

- `apps/lg_core/src/lg_config.erl`
  - 启动时（或首次调用惰性）`persistent_term:put({lg_config, defaults}, defaults())`；
  - persistent_term 存 `{lg_config, version}` 与已解析值 map；
  - `get/1`：命中且版本一致直接返回；miss 走 `resolve/2` 后回填；
  - `set/2`/`unset/1`：写 mnesia 成功后移除对应缓存条目并 version+1；
  - `all/0` 同步走缓存路径。
- `apps/lg_core/src/lg_core_app.erl`：初始化 persistent_term（如采用启动时构建）。

## 验收标准

- [ ] 现有 config 相关 eunit 全绿；`set → get` 立即可见新值；`unset` 回落默认值；
- [ ] 环境变量/sys.config 层覆盖语义不变（对照 defaults 注释的四层优先级）；
- [ ] 微基准：10 万次 `get(keepalive_ms)` 耗时对比 ≥ 5x 提升（结果记录在 PR 描述）；
- [ ] `rebar3 eunit xref dialyzer` 全绿。

## 预估

~80 行，0.5 天。
