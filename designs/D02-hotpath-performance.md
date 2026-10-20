# D02 热路径性能优化（P1，附 P2 尾项）

状态：待实施 ｜ 对应任务：T04、T05、T06、T07（P1），T14（P2 附录）

## 1. lg_config:get/1 每次重建 defaults 大 map

现状（`apps/lg_core/src/lg_config.erl:97-102`）：每次 `get/1` 都
`maps:find(Key, defaults())` —— `defaults/0` 是约 60 项的字面量 map，
**每次调用整体重新构造**，之后还要走 `resolve/2`（mnesia dirty_read + 环境变量 + app env）。
热路径调用点：流式 keepalive 每 tick（`stream_hold_ms`/`keepalive_ms`）、
`lg_limiter` 每请求多次、`attempt_rounds` 的 patience 判定等。

设计（两级缓存）：

1. **defaults 缓存**：`lg_core_app` 启动时 `persistent_term:put({lg_config, defaults}, defaults())`；
   `get/1` 直接读 persistent_term。defaults 是编译期字面量，运行期不变，无失效问题。
2. **解析值缓存（可选，第二步做）**：persistent_term 存
   `{lg_config, version}` 计数器与 `{lg_config, resolved}` map；
   `set/2`、`unset/1` 成功时 version+1 并移除对应 key 的缓存条目；
   `get/1` 命中缓存直接返回，miss 才走 `resolve/2` 并回填。
   环境变量与 sys.config 层运行期不变，mnesia 层的变更全部经过本模块 `set/unset`，
   因此 version 失效是完备的（控制台/API 改配置只有这一个写入口）。

验收：

- 现有 `lg_config` 相关 eunit 全绿；`set → get` 立即可见；
- 微基准（`timer:tc` 循环 10 万次 `get(keepalive_ms)`）对比优化前后，预期 ≥ 5x。

## 2. lg_metrics render/snapshot 的 O(n²)

现状（`apps/lg_core/src/lg_metrics.erl:104-200`）：`render/0` 与 `snapshot/0` 先
`ets:tab2list(?TAB)` 得 Rows，再对**每个 series 的每个统计键/直方图桶**做
`lists:keyfind({Name, L, K}, 1, Rows)`（L184-185、L199-200）。
Rows 上千行、series×桶上百个时，一次 /metrics 抓取是数十万次列表遍历。

设计：进入渲染前一次性 `RowMap = maps:from_list([{K, V} || {K, V} <- Rows])`，
`Get`/`GetB` 闭包改 `maps:get(Key, RowMap, 0)`。`hist_series` 同样传 RowMap。
纯内部重构，无行为变化。

验收：eunit 输出与改造前逐字节一致（先写快照测试再改）；行数 5000 时 render 耗时对比。

## 3. 通配路由匹配预编译

现状（`apps/lg_router/src/lg_routes.erl:92-101`）：`match_wildcard/1` 对
`lg_db:all(lg_route)` **全表逐条**做前缀匹配；每个未命中精确名的请求都执行一次。
路由表大 + 高 QPS 时是每请求 O(routes) 的 mnesia 读放大。

设计：

1. ETS 缓存表 `lg_route_wildcards`：`[{PrefixLen, Prefix, RouteName}]`，按 PrefixLen 降序
   （匹配语义 = 最长前缀优先，与现有 `keysort` 结果一致）。
2. 构建：`rebuild/0` 从 `lg_db:all(lg_route)` 过滤 `is_wildcard/1` 生成；
   启动时（`lg_router` 监督树或首次调用惰性）构建一次。
3. 失效：`lg_routes:create/1`、`update/2`、`delete/1`、`write/1` 是路由的全部写入口
   （控制台经 `lg_api_admin` 调用），写成功后 `rebuild/0`。写频率极低，全量重建即可。
4. `match_wildcard/1` 改为顺序扫缓存表（通常 0~几条通配路由），命中即 `lg_routes:get/1`
   取完整记录（该记录本身走 mnesia dirty_read，与现状一致）。

一致性说明：缓存是进程外 ETS，`rebuild` 与并发读之间允许毫秒级窗口读到旧表——
与现状（dirty_read 本身无事务语义）一致，可接受。

验收：eunit 覆盖最长前缀优先、`*` 全匹配、写后立即可见；`lg_router_tests` 全绿。

## 4. lg_store 查询前 flush 精细化

现状（`apps/lg_store/src/lg_store.erl:222,300,310,350,377,478`）：logs / sessions /
search / usage 每个查询入口都先 `flush()`，而 `flush()` = 同步 call 到 writer 做
`flush_usage(flush_logs(S))`（`lg_store_writer.erl:90-91`）。
空闲时两者都已短路（L201-206），但：

- 查 **logs/sessions/search** 并不需要合并 usage 内存计数（`flush_usage` 是对小时用量
  汇总 cask 的读-改-写），流量高峰期每次列表查询都白付一次 usage 合并；
- 有待写批次时，任何查询都串行等待完整 batch 落盘（read-your-writes 需要，保留）。

设计：

1. writer 增加 `flush(scope)`：`scope = logs | all`；`logs` 只执行
   `flush_logs/1`（含 sessions，因为会话汇总与列表查询同属交互数据）。
2. `lg_store` 各查询入口按需选择：logs/sessions/search/messages → `flush(logs)`；
   usage/cost 类 → `flush(all)`。
3. `lg_store:flush/0` 公开接口保持 `all` 语义不变（停机路径依赖它）。

验收：eunit 验证写日志后 `flush(logs)` 即可查到、usage 查询前合并仍正确；
`lg_store` 现有测试全绿。

## 附录（P2）：T14 —— 每请求文本处理开销

1. **token 估算**（`lg_tokens:estimate`、`lg_limiter:text_tokens`）：
   `unicode:characters_to_list/1` 把整段文本展开成 list（每请求全文两次大分配）。
   CJK 判定改为在 binary 上按 UTF-8 前导字节扫描（`binary:bin_to_list` 分段或直接
   逐码点 `decode_utf8` 状态机），避免建全量 list；估算精度允许 ±5% 不变语义。
2. **SSE 规范化**（`lg_sse:normalize`）：对含 `\r` 的 chunk 做 `binary:replace`
   全量复制。先 `binary:match(B, <<"\r">>)` 探测，无 `\r`（绝大多数上游）走零拷贝分支。

验收：现有 `lg_sse`/token 相关 eunit 全绿；构造 1MB 文本对比分配量
（`recon_alloc` 或 `erlang:memory/0` 差值，定性即可）。
