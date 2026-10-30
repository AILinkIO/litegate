# T22 lg_conc 等待者清理与 lg_limiter 释放归属

优先级：P1 ｜ 设计：[D05 §2.3](../designs/D05-regressions-stability-perf.md) ｜ 状态：待评审 ｜ 依赖：无

## 背景

- `lg_conc` 取消后返回 `granted` 时执行无 `after` 的 receive，lg_conc 重启后等待者永久阻塞；
- 等待者未 monitor，断开客户端占满 `queue_limit`，新请求立即 full，affinity 误判 concurrency_full；
- `gen_server:call` 默认 5s 超时会崩溃调用方；
- `lg_limiter`（plausible）：release 不校验归属、占槽与建 monitor 间存在泄漏窗口。

## 改动点

- `apps/lg_router/src/lg_conc.erl`
  - `:92-118` 入队时 `monitor(process, Pid)`，队列条目保存 MRef；`'DOWN'` 时移除并刷新 ETS 计数；cancel 时 demonitor；
  - `:57-60` `granted -> receive {lg_conc_granted, Ref} -> ok after 1000 -> release, timeout end`；
  - 对外 API 的 `gen_server:call` 包 catch，异常视为 busy。
- `apps/lg_router/src/lg_limiter.erl:252-257, 319-320`
  - release 仅释放 `maps:find(Pid)` 中实际持有的 scope；
  - 占槽前先建立 monitor（gen_server 内完成或调用方先 call 注册）。

## 验收标准

- [ ] eunit：排队进程被 kill 后队列长度 -1、ETS queued 计数同步；
- [ ] eunit：kill lg_conc 后所有等待者 ≤1.5s 返回 timeout；
- [ ] eunit：重复 `done/1` 计数不为负；占槽后立即 kill 进程，槽被回收；
- [ ] `rebar3 eunit xref dialyzer` 全绿。

## 预估

~150 行（含测试），1 天。
