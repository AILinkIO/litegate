# T16 通配路由缓存表 owner 修复与无空窗重建

优先级：P0 ｜ 设计：[D05 §1.1](../designs/D05-regressions-stability-perf.md) ｜ 状态：待评审 ｜ 依赖：无

## 背景

T06 引入的 `lg_route_wildcards` 由 `ensure_wc/0` 以 `catch ets:new` 惰性创建，
第一个调用者（通常是 cowboy 请求进程）成为 owner，请求结束表即销毁；启动期无人调用
`rebuild_wildcards/0`。重启后通配路由返回 `route_not_found`，生产环境基本不可用。
导入配置后也不重建；重建过程 `delete_all_objects` → `insert` 存在空窗。

## 目标

通配缓存由常驻进程持有、启动即就绪、任何写路由路径后都正确重建，且重建无空窗。

## 改动点

- `apps/lg_router/src/lg_routes.erl:101-133`
  - 删除 `ensure_wc/0`；表不存在时 `match_wildcard/1` 回退为直接扫 `lg_db:all(lg_route)`；
  - 表改 ordered_set，key = `{-PrefixLen, Prefix}`，首个匹配即返回，去掉 `tab2list` + keysort；
  - `rebuild_wildcards/0`：先 insert 新集合，再 `select_delete` 不在新集合中的旧条目。
- 新增 `apps/lg_router/src/lg_route_cache.erl`（gen_server，挂在 `lg_router_sup`），
  `init/1` 创建表并 `rebuild_wildcards()`；重建通过该进程串行执行（`gen_server:call`）。
- `apps/lg_router/src/lg_config_io.erl:105`、`lg_backup` 恢复路径：成功后调用 `rebuild_wildcards()`。

## 验收标准

- [ ] 跨进程测试：在 spawn 的临时进程中写路由并退出，另一进程匹配通配名仍命中；
- [ ] 重启 lg_router 应用后首个请求即命中通配路由；
- [ ] 重建期间并发 1000 次匹配无 not_found；
- [ ] 导入含通配路由的配置后立即可命中；
- [ ] `rebar3 eunit xref dialyzer` 全绿。

## 预估

~120 行（含测试），0.5 天。
