# T19 cooldown 清扫调度 + realtime 适配 gun 2.x 消息

优先级：P0 ｜ 设计：[D05 §1.4](../designs/D05-regressions-stability-perf.md) ｜ 状态：待评审 ｜ 依赖：无

## 背景

- `lg_cooldown:init/1` 未调度首次 sweep，`handle_info(sweep)` 只自我续期，T02 的冷却清扫从未运行。
- `lg_web_realtime` 按 gun 1.x 的 6 元组匹配 `gun_down`（gun 2.1 为 5 元组），且缺少流级 4 元组
  `gun_error`，对 Conn 无 monitor；上游断开后 WebSocket 会话成为僵尸。
- realtime 的 `gun:open` 未传 `tls_opts`（plausible：无 cacerts/SNI/主机名校验）。

## 改动点

- `apps/lg_router/src/lg_cooldown.erl:160`：`init/1` 中 `erlang:send_after(?SWEEP_MS, self(), sweep)`。
- `apps/lg_web/src/lg_web_realtime.erl`
  - `:200` 改为 `{gun_down, Conn, _Proto, _Reason, _Killed}`；
  - `:202` 旁新增 `{gun_error, Conn, _StreamRef, Reason}`；
  - `websocket_init` 中 `monitor(process, Conn)`，`{'DOWN', _, process, Conn, _}` → `{stop, State}`；
  - `:148` `gun:open` 复用 `lg_http_pool:tls_opts/1`（需导出）。
- 全仓检查其他 gun 消息匹配是否按 2.x 格式（`grep -rn 'gun_down\|gun_error'`）。

## 验收标准

- [ ] eunit：lg_cooldown 启动后存在 sweep 定时器，过期条目在一个周期后被删除；
- [ ] eunit（meck gun）：发送 5 元组 `gun_down` 与 4 元组 `gun_error` 后 realtime 进程终止；Conn 进程退出后同样终止；
- [ ] realtime 连接 TLS 上游时握手带 SNI 并校验证书；
- [ ] `rebar3 eunit xref dialyzer` 全绿。

## 预估

~60 行（含测试），0.5 天。
