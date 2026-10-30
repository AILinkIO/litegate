# T29 链路背压与上游连接池改进

优先级：P2 ｜ 设计：[D05 §3.2](../designs/D05-regressions-stability-perf.md) ｜ 状态：待评审 ｜ 依赖：无

## 背景

gun 未开 flow，慢客户端 + 快上游时邮箱膨胀（plausible）；连接池只用 HTTP/1.1、空闲上限写死 32，
checkin 同步调 `gun:info`、池进程内同步 `gun:close`（plausible），高峰后大量重新握手；
先 flush 后 close 导致迟到 gun 消息残留在长生命周期进程邮箱；复用连接失败时可能重复发送已被处理的 POST。

## 改动点

- `apps/lg_provider/src/lg_http_pool.erl`
  - `:161` gun opts 增加 `http_opts => #{flow => 8}`；
  - `:192-198` checkin 改 `cast({checkin, HostKey, Conn})`，不再调用 gun；`gun:close` 异步执行；
  - `:17` 空闲上限改配置 `upstream_pool_idle_max`（128）；新增复用率指标。
- `apps/lg_web/src/lg_web_llm.erl:291` 及流式转发路径：每成功 `stream_body` 一块后 `gun:update_flow(Conn, Ref, 1)`。
- `apps/lg_provider/src/lg_http.erl:398-400, 460-462`：先 `gun:close` 再 `gun:flush(Conn)`。
- `apps/lg_provider/src/lg_http.erl:411-413, 465`：重发仅限写请求阶段失败（未见任何响应迹象且发出 <50ms）。
- （后续阶段）凭证选项 `protocols` 支持 h2。

## 验收标准

- [ ] 先在本地确认 gun 2.1 flow 与 cowboy 2.13 `stream_body` 的实际行为，结论写入 PR；
- [ ] 慢客户端（1KB/s）+ 快上游：处理进程 `message_queue_len` ≤ flow 窗口；
- [ ] 同主机 200 并发两波：第二波新建连接数 ≤72；
- [ ] lg_otlp 连续 100 次导出失败后进程邮箱为空；
- [ ] `rebar3 eunit xref dialyzer` 全绿。

## 预估

~200 行（含测试），1.5 天。
