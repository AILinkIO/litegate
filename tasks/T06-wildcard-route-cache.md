# T06 通配路由匹配预编译缓存

优先级：P1 ｜ 设计：[D02 §3](../designs/D02-hotpath-performance.md) ｜ 状态：待开始 ｜ 依赖：无

## 背景

`lg_routes:match_wildcard/1`（`lg_routes.erl:92-101`）对 `lg_db:all(lg_route)`
全表逐条前缀匹配，每个未命中精确路由名的请求都执行一次，路由表大时是每请求
O(routes) 的 mnesia 读放大。

## 目标

通配前缀表预编译进 ETS，写路由时全量重建；匹配从全表扫描降为 0~几条的短扫。

## 改动点

- `apps/lg_router/src/lg_routes.erl`
  - 新 ETS 表 `lg_route_wildcards`：`[{PrefixLen, Prefix, RouteName}]` 按 PrefixLen 降序；
  - `rebuild_wildcards/0`：从 `lg_db:all(lg_route)` 过滤 `is_wildcard/1` 构建；
    启动时构建一次 + 首次匹配惰性兜底；
  - `create/1`、`update/2`、`delete/1`（内部 `write/1`）成功后调用 rebuild；
  - `match_wildcard/1` 改扫缓存表，命中后 `get/1` 取完整记录。

## 验收标准

- [ ] eunit：最长前缀优先、`*` 全匹配、通配+精确混合、写后立即可见、删路由后失效；
- [ ] `lg_router_tests` / `lg_rules_tests` 回归全绿；
- [ ] xref 无未引用告警；`rebar3 eunit xref dialyzer` 全绿。

## 预估

~70 行，0.5 天。
