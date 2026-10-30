# D05 回归修复、稳定度加固与流式/存储性能（P0–P2）

状态：待实施 ｜ 对应任务：T16–T33

## 背景

v1.1.0 之后的第二轮全项目审查（2026-10-27，覆盖 lg_provider / lg_web / lg_router /
lg_store / lg_core / lg_catalog 与部署配置）。结论分三类：

1. **上一轮修复引入或遗漏的功能性缺陷**（§1）：通配路由缓存、出站节流、冷却清扫、
   配置缓存均存在“看起来做了、实际不生效或行为错误”的问题。eunit 全在单进程内运行，
   测不出 ETS owner 与跨进程失效类问题——这是本轮回归的共同根因。
2. **稳定度**（§2）：客户端断开感知、单写者背压、排队等待者泄漏、刷新风暴、
   mnesia 运行模式、优雅关停、流式超时与上限、迁移幂等。
3. **性能**（§3）：流式解析的 O(n²) 与 sub-binary 驻留、链路无背压、连接池复用率、
   重复编解码、存储查询全扫描、janitor 成本。

标注说明：行号基于 commit `98ad72b`；“plausible”表示依赖 gun / cowboy / bitcask NIF
内部行为、未在本仓库内直接验证，实施前需先确认。

## 通用约束（本设计新增）

- **ETS 表必须由常驻 gen_server 在 `init/1` 创建**，禁止 `catch ets:new` 惰性创建
  （owner 不确定，随请求进程退出而销毁）。
- **跨进程语义必须有跨进程测试**：涉及 ETS owner、persistent_term 缓存失效、
  定时清扫的改动，测试需在独立进程中触发写入/读取，并断言定时器确实被调度。
- **对外部消息的模式匹配以 rebar.lock 锁定版本为准**（gun 2.1.0：`gun_down` 为 5 元组，
  流级 `gun_error` 为 4 元组）。

---

## 1. 功能性缺陷修复（P0）

### 1.1 通配路由缓存表 owner 错误（T16）

现状（`apps/lg_router/src/lg_routes.erl:101-133`）：

- `lg_route_wildcards` 由 `ensure_wc/0` 以 `catch ets:new(...)` 惰性创建，
  **第一个调用者成为 owner**；全仓无启动期调用 `rebuild_wildcards/0`。
- 重启后第一个未精确命中的请求在 cowboy 请求进程里建出**空表**，返回 `route_not_found`；
  请求进程结束表即被销毁，下一个请求重复此过程。控制台改路由时同样在请求进程内重建，
  结束即销毁。→ **生产环境通配路由基本不可用**。
- `lg_config_io:import` 直接 `mnesia:write` 路由，导入后不重建。
- `rebuild_wildcards/0` 先 `delete_all_objects` 再 `insert`，中间存在空窗（并发请求 404）。

设计：

1. 由 `lg_router_sup` 下的常驻进程持有该表（新增 `lg_route_cache` gen_server，
   或并入现有常驻进程），`init/1` 中 `ets:new` 并立即 `rebuild_wildcards()`。
2. 删除 `ensure_wc/0`；`match_wildcard/1` 在表不存在时（启动竞态）回退为直接扫描
   `lg_db:all(lg_route)`，不再建表。
3. 重建无空窗：计算新集合 → `ets:insert` 新条目 → `select_delete` 删除不在新集合中的旧条目；
   或双表 + `persistent_term` 指针切换。
4. 重建入口：路由增删改（现有 3 处）+ `lg_config_io:import` 成功后 + 备份恢复后。
5. `match_wildcard/1` 中 `ets:tab2list` 改为按前缀长度降序预排序存储（ordered_set，
   key = `{-PrefixLen, Prefix}`），首个匹配即返回。

验收：跨进程测试——在临时进程中写路由并退出，另一进程请求通配名仍命中；
重启 `lg_router` 应用后首请求即命中；重建期间并发 1000 次匹配无 not_found。

### 1.2 出站节流 lg_out_rate 的四处缺陷（T17）

现状（`apps/lg_router/src/lg_out_rate.erl`，WIN 对象为 `{{{CId, Model}, Minute}, N}`，
STATE 对象为 6 元组 `{Key, Cap, Paused, Streak, OkSince, At}`）：

| # | 位置 | 缺陷 | 后果 |
|---|---|---|---|
| a | `:272` sweep | match head `{{'_','_'},'$1'}` 中 `$1` 绑定到计数 N 而非分钟 | 每 60s 清空全部窗口（含当前分钟），`rate/1` 归零，实际速率可达 Cap 的约 2 倍 |
| b | `:240-241` reset_credential | WIN 模式 `{{CId,'_'},'_'}`、STATE 模式 `{CId,'_'}` 均与对象形状不符 | 凭证更新后学习状态与暂停不清除 |
| c | `:197-203` step_429 首犯 | `state_of/1` 返回的 map 无 `observed`，Observed 恒为 1 → Cap0 = `out_rate_min_rpm`（6） | 一次偶发 429 即限到 6 RPM；按 +10%/2min 回升到 600 RPM 约 96 分钟 |
| d | `:192-208` | 并发 N 个 429 各自减半；先收到带 Retry-After 的 429 后 streak=1、cap=undefined，后续无 RA 的 429 落入兜底分支，永不建 Cap | 过度收紧或永不收紧 |
| e | `allow/1` + `wait/3` | 判断不占额，queue 等待者每 500ms 轮询，窗口滚动时集体放行 | 新的突发，立刻再撞 429 |
| f | `lg_router_attempt.erl:140` | 排队成功后调用 `attempt_plan_conc([{RouteName,T,Cred}], …)`，丢弃 `Rest` | 该目标再失败即直接报错，不再回退 |

设计：

1. sweep：`[{{{'_', '$1'}, '_'}, [{'<', '$1', Old}], [true]}]`。
2. reset_credential：`{{{CId,'_'},'_'},'_'}` 与 `{{CId,'_'},'_','_','_','_','_'}`。
3. `on_rate_limit/2` 在进入 `step_429` 前以 `rate(Key)` 写入 `observed`，并持久化到 STATE。
4. 减半按时间去重：STATE 增加 `last_cut_at`，距上次下调不足 `max(1000, RecoveryMs div 10)` ms 跳过。
5. Retry-After 分支：若 `cap = undefined`，同时按 §3 首犯规则建立 Cap。
6. 放行原子预占：`allow/1` 通过时对当前分钟桶 `update_counter(+1)`，
   若超过 Cap 则 `-1` 并返回 throttle；`record/1` 不再重复计数（或 allow 返回 token，
   record 时识别已预占）。
7. 解除条件改为“Cap ≥ max(observed × 1.5, max_rpm) 或 Cap 已连续 N 次回升且期间无 429”，
   避免因 `ok_since` 每次回升被重置而永远到不了解除分支。
8. attempt：`attempt_plan_conc([{RouteName, T, Cred} | Rest], …)`。

验收：纯函数 eunit 覆盖 a–e 各场景；集成测试模拟 1 次 429 后 Cap ≈ observed × factor；
sweep 后当前分钟桶仍在；reset_credential 后 STATE/WIN 中该凭证条目为 0。

### 1.3 lg_config 缓存失效缺口与丢失更新（T18）

现状：

- `apps/lg_router/src/lg_config_io.erl:105-106`：导入/恢复事务直接写删 `lg_setting`，
  成功后只调用 `lg_cooldown:clear()` 与 `lg_middleware:reload()`，**未失效 PT_CACHE**。
  控制台 `lg_config:all/0` 不走缓存（显示新值），`get/1` 返回旧值直到重启。
- `apps/lg_core/src/lg_config.erl:127-133`：miss 时读取整张 map 快照 → resolve →
  `persistent_term:put(?PT_CACHE, Cache#{Key => V})`。与并发 `set/invalidate` 交错时
  把刚失效的旧值写回，且无 TTL，永久驻留。
- 每次 miss 都 `persistent_term:put`，触发全局 literal 扫描；`set` 后并发请求同时 miss 形成惊群。

设计：

1. 已解析值缓存改为 ETS（`lg_config_cache`，`read_concurrency`，由 lg_core 常驻进程 owner），
   每 key 一行；`get` miss 时 `ets:insert`，`invalidate` 时 `ets:delete`。defaults 仍放 persistent_term。
2. 丢失更新防护：表内保存全局版本号 `{'$ver', N}`；`set/unset/invalidate_all` 先 `update_counter`
   版本再删除条目；`get` miss 在 resolve 前后各读一次版本，不一致则不回填（直接返回 V）。
3. 新增 `lg_config:invalidate_all/0`；`lg_config_io:import`、`lg_backup` 恢复成功后调用，
   同时调用 `lg_routes:rebuild_wildcards()`（T16）与 `lg_out_rate:reset()`。

验收：并发测试——一个进程循环 `set(K, V_i)`，多个进程循环 `get(K)`，结束后 `get(K)` 必为最后写入值；
导入后 `get/1` 立即返回新值；dialyzer 通过。

### 1.4 其余小缺陷（T19）

- **lg_cooldown 清扫从未调度**：`apps/lg_router/src/lg_cooldown.erl:160` `init/1` 缺少首次
  `erlang:send_after(?SWEEP_MS, self(), sweep)`，`handle_info(sweep)` 只自我续期。T02 实际未生效。
- **realtime 收不到 gun 2.x 消息**：`apps/lg_web/src/lg_web_realtime.erl:200` 匹配 6 元组
  `gun_down`（gun 1.x 格式），gun 2.1 为 `{gun_down, Conn, Proto, Reason, KilledStreams}`；
  `:202` 只匹配 3 元组 `gun_error`，缺 4 元组流级错误；对 Conn 无 monitor。
  上游断开后 WebSocket 会话成为僵尸（客户端 ping 保活永不断开，`ws_send` 静默丢弃）。
- **realtime TLS 无校验配置**（plausible）：`:148` `gun:open` 只设 `transport => tls`，
  未传 `tls_opts`（cacerts / SNI / 主机名校验）。

设计：补首次调度；改 5 元组 + 补 4 元组 `gun_error`；`websocket_init` 中
`monitor(process, Conn)`，`'DOWN'` 时 `{stop, State}`；导出 `lg_http_pool:tls_opts/1` 复用。

验收：测试断言 cooldown 进程启动后存在 sweep 定时器（`erlang:read_timer` 或 meck 计时）；
realtime 用 meck 发送 gun 2.x 格式 `gun_down` 后进程终止。

---

## 2. 稳定度（P1）

### 2.1 客户端断开感知（T20）

现状：

- 流式：`apps/lg_web/src/lg_web_llm.erl:235-241` `stream/4` 开启 `trap_exit`，但只有开流后的
  `recv_loop` 匹配 `'EXIT'`。开流前的等待——`gun:await`（`lg_http.erl:441` await_loop）、
  `lg_conc:await_grant`、`lg_router_attempt:patience_wait` 的 `timer:sleep`、`lg_out_rate:wait`——
  都不检查。客户端排队中或首包前取消后，网关仍等满 `upstream_timeout_ms`（300s）并继续回退，
  占用并发名额，上游照常计费。
- 非流式：`lg_web_llm.erl:186` `sync/4` 未 trap_exit，客户端断开时进程被直接 shutdown，
  `lg_web_llm_log:record` 与 `lg_router:done` 不执行 → 无请求日志、`lg_budget:add` 不扣费。

设计：

1. `hold_tick/0`（每 250ms 被 Idle 回调）内增加
   `receive {'EXIT', _, R} -> throw({client_exit, R}) after 0 -> ok end`。
2. 所有开流前等待点统一调用 Idle：`await_loop` 改为分段 `gun:await`（≤250ms）+ Idle；
   patience 的 `timer:sleep` 改为分段 sleep + Idle。
3. `lg_router:stream_open` / `sync` 捕获 `{client_exit, _}`：取消上游流、释放名额，
   以 `status = 499 client_closed` 记日志并调用 `done`（已产生的上游用量照常计费）。
4. `sync/4` 同样开启 `trap_exit` 并使用 Idle，`after` 中保证日志与预算记账。

验收：集成测试——在 lg_conc 排队期间杀掉客户端连接，1s 内名额释放、日志记 499；
首包前断开时上游 gun 流被 cancel（meck 断言）。

### 2.2 存储单写者背压与写盘错误（T21）

现状（`apps/lg_store/src/lg_store_writer.erl`）：

- `record/3` 为 cast（`:45-46`），无背压。每批最多 200 条（`BATCH_MAX`），每批在写者进程内
  做 3 次 `put_batch_atomic` + 最多 200 次 BM25 + jieba 分词写入（`:222-226`，每文档 ≤32KB）。
- 写者跟不上时邮箱无界增长；消息携带日志与压缩对话 binary；邮箱在堆上，GC 扫整个队列，
  积压越多越慢，最终 OOM。积压期间 `flush/1`（30s 超时）、janitor `delete`（60s）超时崩溃调用方。
- `batch/2` 遇 `{error, R}` 只记日志返回 ok（`:266-271`），磁盘满时日志与用量静默丢失、无指标。
- `ok = bitcask:sync(H)` 失败崩溃时 usage 已写入，`terminate`（`:131-136`）拿到的是回调前的 State
  并再次合并 delta → **重复计数**；`flush(all)` 中 sessions 同理。
- `terminate` erase `persistent_term` 句柄并 close；期间 `h(cache)` 抛 badarg，
  `cache_get`（`lg_router.erl:433`）、`response_get`（`lg_web_llm.erl:170`）无保护 → 500。
  正在 fold 的读者句柄被 close 可能导致 NIF use-after-close（plausible）。

设计：

1. 写者 `init` 中 `process_flag(message_queue_data, off_heap)`。
2. 分级降级：`record/3` 读取 `process_info(Writer, message_queue_len)`（或写者维护的
   `atomics` 积压计数，更便宜）：
   - > `store_queue_soft`（默认 5000）：丢弃对话与检索文档，只保留日志与用量；
   - > `store_queue_hard`（默认 50000）：丢弃日志明细，只保留用量增量；
   - 计数 `litegate_store_degraded_total{level}`。
3. 检索索引拆到独立进程 `lg_store_indexer`（自身有界队列，满则丢弃并计数），写者只投递。
4. 写盘错误：计数 `litegate_store_write_errors_total{cask}`，最近错误时间进入 `/health`
   （degraded）；连续失败超过阈值触发告警。
5. 防重放：写盘前先把 usage/sessions 从 State 取出并清空，写失败时回滚到 State 再抛出；
   `terminate` 用 try 包裹，只写尚未落盘的部分。
6. 句柄 owner 与写者解耦：新增 `lg_store_handles` 进程（rest_for_one 的第一个子进程）
   打开并持有所有 cask，写者崩溃不 close 句柄；读端 `cache_get` / `response_get` 加 try，
   异常按 miss 处理。

验收：压测 2000 rps 写入 + 人为放慢 bitcask（meck 延迟）时内存有界、降级计数增长；
模拟 `sync` 失败后 usage 不重复；写者 kill 期间 cache_get 返回 miss 而非 500。

### 2.3 并发排队与限流归属（T22）

现状：

- `apps/lg_router/src/lg_conc.erl:57-60`：等待超时后 `cancel` 若发现自己已不在队列，
  返回 `granted` 并执行**无 `after` 的 `receive`**；lg_conc 重启后状态为空，
  所有等待者都会走到这里永久阻塞。
- `:92-118`：等待者未被 monitor（仅 holder 被 monitor），断开的客户端条目留在队列直至有名额释放；
  慢上游占满名额时，死等待者填满 `queue_limit=32`，新请求立即 `full`，
  lg_affinity 因 `queued > 0` 误判会话 `concurrency_full`。
- `gen_server:call` 默认 5s 超时，lg_conc 忙时调用方崩溃。
- `apps/lg_router/src/lg_limiter.erl:252-257, 319-320`（plausible）：`release` 不校验调用进程是否持有，
  重复 `done/1` 会多减计数；`take_slots` 先 `update_counter` 占槽、后 cast `hold` 建 monitor，
  间隙内进程被 kill 则槽永久泄漏。

设计：

1. 入队时 `monitor(process, Pid)` 并存入队列条目；`'DOWN'` 时从队列移除并刷新 ETS 计数。
2. cancel 返回 `granted` 后的 `receive` 加 `after 1000`，超时立即 `release` 并按 timeout 处理。
3. 所有对 lg_conc 的 `gen_server:call` 包 `catch`，异常视为 busy（跳过候选），不崩溃调用方。
4. lg_conc 重启时在 `init` 中 `ets:delete_all_objects` 并依靠 holder 重新 acquire 的语义；
   文档写明重启会短暂放宽并发上限。
5. lg_limiter：`release` 只释放 `maps:find(Pid)` 中确实持有的 scope；
   占槽改为 gen_server 内先 monitor 再 `update_counter`，或在调用方进程先建立 monitor 关系后再占槽。

验收：测试——排队中的进程被 kill 后队列长度 -1；kill lg_conc 后等待者在 ≤1.5s 内返回；
重复 `done/1` 不导致计数为负。

### 2.4 额度/余额刷新风暴（T23）

现状：`apps/lg_router/src/lg_plan.erl:85-94, 138-140`、`lg_balance.erl:62-70`、
`lg_router_attempt.erl:205`。`checked_at` 在 fetch 完成后才写入，期间每个请求的
`touched/exhausted` 都再 cast 一次 refresh；`handle_cast` 每次跑完整 `run`
（最长 connect timeout + 5s）并两遍 `lg_credentials:list()`；quota/credit 错误无条件 cast lg_balance。
100 rps 下一次刷新期间约 500 条 cast 排队，串行打上游额度接口，
控制台“立即刷新”的 `gen_server:call` 超时。

设计：

1. cast 前在 ETS 中 `ets:insert_new({refreshing, CredId})`，失败即跳过；fetch 完成（成功或失败）后删除。
2. handle_cast 内再次检查 `checked_at` 间隔（防止已排队的重复消息）。
3. fetch 在独立 worker 进程中执行（每凭证同时最多一个），gen_server 只做调度与结果写入，
   不被网络 I/O 阻塞；控制台 `refresh/1` 改为等待对应 worker 结果，超时返回“刷新中”。

验收：模拟 1000 次并发 `touched/1`，上游额度接口只被调用 1 次；刷新期间 `status/1` 不阻塞。

### 2.5 运行时与部署：mnesia 模式、优雅关停、资源上限（T24）

现状：

- `apps/lg_core/src/lg_schema.erl:20`：`application:ensure_all_started(mnesia)` 默认 temporary；
  mnesia 退出（磁盘满、log 写失败）后节点存活但鉴权、路由持续 500，systemd / docker 不重启。
- `apps/lg_web/src/lg_web_app.erl:42-45`：`stop/1` 依次停 clear 与 TLS listener，每个最多等 5s，
  合计 10s = docker 默认宽限期；之后 lg_store 才 flush，超时被 SIGKILL，丢失 pending 日志与
  ≤5s 的用量汇总。cowboy 连接进程被 shutdown 时在途请求不经过 `lg_store:record`（plausible）。
- `docker-compose.yml`：无 `stop_grace_period`、无 `ulimits`。新版 Docker 默认 soft nofile 可能为 1024
  （plausible），每请求占 2 个 socket，几百并发即 EMFILE。
- `lg_web_app.erl:22-25`：TransOpts 未设 `max_connections`（ranch 默认 1024），
  `idle_timeout` 360s，长流 + 空闲 keep-alive 易顶满。
- `config/vm.args`：`+K true`（OTP 21 起无效）、`+A 30`（对 NIF/dirty IO 基本无作用）。

设计：

1. mnesia 改 `ensure_all_started(mnesia, permanent)`；`/health` 增加 `mnesia:system_info(is_running)` 检查。
2. 优雅关停：在 `lg_web_app:prep_stop/1` 中 `ranch:suspend_listener` 所有 listener →
   轮询 `ranch:procs(Ref, connections)` / 活跃流计数直到 0 或 `shutdown_drain_ms`（默认 20000）→
   再 stop listener；lg_store 写者 `terminate` 完成最终 flush。
3. compose：`stop_grace_period: 60s`、`ulimits: {nofile: {soft: 65536, hard: 65536}}`；
   与 systemd `TimeoutStopSec=60`、`LimitNOFILE=65536` 对齐。
4. 新增配置 `http_max_connections`（默认 16384，需重启）。
   ~~`idle_timeout` 拆分为 `http_idle_timeout_ms`~~（实施时撤销：核实 cowboy 2.13 后，HTTP/1.1 请求之间的
   keep-alive 空闲由 `request_timeout`（5s）管理，`idle_timeout` 只在有在途请求时计时；HTTP/2 的空闲计时是整条
   连接级别、不支持按请求放宽，缩短会断开长时间等待上游的非流式请求。监听器空闲超时维持 `upstream_timeout_ms + 60s`，
   并开启 `reset_idle_timeout_on_send`。）
5. vm.args：删除 `+K`/`+A`；增加 `+sbwt none +sbwtdcpu none +sbwtdio none`（容器共享 CPU）、
   `+Q 65536`；是否调 `+SDio` 视 bitcask NIF 是否使用 dirty IO 决定（先确认）。

验收：`docker compose stop` 期间持续发送流式请求，在途请求全部完成并有日志；
kill mnesia 后 `/health` 返回 503；容器内 `ulimit -n` 为 65536。

### 2.6 流式超时与响应体上限（T25）

现状：

- `apps/lg_provider/src/lg_provider_stream.erl:85`、`lg_http.erl:351-352`：块间空闲超时复用首包超时
  `upstream_timeout_ms`（300s），且无流总时长上限；上游卡住时每次停顿占 5 分钟连接与名额，
  只发 ping 不出内容的流可无限挂起。
- `lg_http.erl:276, 303, 328`：三处 `gun:await_body` 整体读入内存，无大小上限；
  Timeout 为单条消息超时而非总时长，上游慢速滴数据不会超时。
- SSE 缓冲无上限（见 §3.1）。

设计：

1. 新配置：`stream_idle_timeout_ms`（默认 120000，块间空闲）、`stream_max_ms`（默认 1800000，流总时长）、
   `upstream_max_body_bytes`（默认 64MB）、`sse_max_event_bytes`（默认 8MB）。
2. 首包超时保持 `upstream_timeout_ms`；首包后切换到 idle 超时；ping/注释事件不刷新“内容进展”计时
   （另设 `stream_no_content_ms`，可选）。
3. 自写非流式接收循环：累加字节数，超限 `gun:cancel` + discard 连接并返回 `upstream_too_large`；
   总时长截止为 `upstream_timeout_ms`。
4. 超时/超限均以可区分的错误类型记日志与指标（`litegate_upstream_timeouts_total{phase}`）。

验收：mock 上游——首包后停发 → idle 超时触发；持续 ping → `stream_max_ms` 触发；
返回 100MB 响应 → 64MB 处中止且内存峰值有界。

### 2.7 schema 迁移幂等（T26）

现状：`apps/lg_core/src/lg_schema.erl:136-143, 157-180`。每个 `transform_table` 单独事务，
版本号在全部步骤后才 `dirty_write`。若 v1→v2 在 lg_route 转完、lg_credential 未转时崩溃，
重启后对已转换元组再次套用旧 pattern → `function_clause`，transform 中止，节点永远起不来。
另：`:77-90` 在 `schema.DAT` 已存在但节点名不匹配、`storage_type` 返回 ram_copies 时
可能就地重建 disc schema（plausible）；开发 shell（`{sname, litegate}`）与 release
（`litegate@127.0.0.1`）节点名不一致，注释称一致。

设计：

1. transform fun 按记录元组大小/形状判断是否已是新格式，已转换则原样返回。
2. 每张表迁移完成后记录 `{schema_step, Table, Version}` 进度；重启时跳过已完成表。
3. 迁移前自动备份 mnesia 目录（`Mnesia.<node>.pre-v<N>`）。
4. `schema.DAT` 存在而节点名不匹配时拒绝启动，提示使用 `lg_schema:rename_node/1`。
5. `rebar.config` 的 `dist_node` 改为 `{name, 'litegate@127.0.0.1'}`，与 vm.args 一致。

验收：注入“迁移一半崩溃”，重启后迁移完成且数据正确；改节点名启动时报明确错误而非静默新建库。

### 2.8 分类器熔断与告警防抖（T27）

现状：

- `lg_rules.erl` `ask_route/ask_systemone/ask_llm`：失败不缓存、无熔断；systemone 3s + classifier 8s，
  嵌套路由每层各判一次。判断模型故障时每个新会话请求额外 8～11s。
- `lg_router:judge/5` 超时直接 kill 判断进程，该次判断费用不计预算、无日志。
- `lg_alert.erl:134-144`、`lg_health.erl:40`：每次失败尝试都 cast，每次 cast 执行
  `lg_alerts:rules/1`（全表 `dirty_select` + keysort）与 `io_lib:format`，无规则时亦然；
  upstream_down 无静默期，故障/恢复抖动时成对刷屏；sender 串行发送、失败 sleep 1～2s、邮箱无上限；
  `fails` 仅成功时清除，通配模型名下单调增长。

设计：

1. 分类器熔断：`{classifier, Route}` 维度失败计数，窗口内连续失败 ≥3 次进入 open 30s，
   期间直接走默认分支并计数 `litegate_classifier_skipped_total`；相同 CacheKey 的并发请求合并（singleflight）。
2. judge 超时前先尝试从被杀进程收集用量（或改为 `gun:cancel` 后由判断进程自行记账退出）。
3. 告警规则缓存于 persistent_term（规则写入时刷新）；无匹配规则时 cast 前即返回；
   文本仅在确定发送时格式化。
4. `alert_silence_ms`（默认 300000）：同一目标告警后静默期内不再发告警/恢复；
   恢复需持续健康 `alert_recover_ms` 才发送。
5. sender 队列上限（默认 1000），超出丢弃并计数；`fails` 定期清扫（24h 无更新删除）。

验收：分类器 mock 持续超时时，第 4 个请求起无额外延迟；目标 10 次抖动只产生 1 对告警/恢复；
sender 邮箱在通道不可达时有界。

---

## 3. 性能（P1–P2）

### 3.1 流式解析的 O(n²) 与 sub-binary 驻留（T28）

现状：

- **SSE 缓冲**：`lg_provider_stream.erl:149` 每块 `<<Buf/binary, Data/binary>>`，Rest 是 sub-binary，
  无法走追加优化，每次整段拷贝；`lg_sse.erl:16-17, 38-45` 的 normalize 与 split 每次从头扫描，
  含 `\r` 时还全局 replace。Responses 透传时 `response.completed` 事件可达 MB 级、分几十上百块到达，
  拷贝与扫描量为平方级；缓冲无上限。
- **复读检测**（默认开启，`lg_provider_stream.erl:89`）：`lg_loop.erl:49-56` 每个 token
  对 `<<Part/binary, Text/binary>>` 整体 split，无换行时 Partial 无限增长；tail 每 token 拷贝 ≤8KB。
  单行长输出（结构化 JSON、压缩代码）50KB / 1.5 万 delta 累计约 375MB 扫描拷贝。
- **sub-binary 驻留**：OTP 28 `json:decode` 返回的字符串是输入的 `binary_part`。
  `lg_stream.erl:384, 405`、`lg_resp_stream.erl:335, 415, 436` 累积 delta 时每个 delta
  钉住整块原始数据；10 万 token 输出单流约占 30MB（实际文本约 400KB），乘以并发流数。

设计：

1. SSE：缓冲改为 iolist + 已扫描偏移，只在“上次尾部 3 字节 + 新数据”中查找事件分隔符
   （`\n\n` / `\r\n\r\n` / `\r\r`），找到后再 `iolist_to_binary` 取出完整事件；
   `\r` 规范化只作用于单个事件。超过 `sse_max_event_bytes`（T25）按上游错误结束。
2. lg_loop：只 split 新 Text；无 `\n` 时直接追加 Partial 并截断到 1KB（超长行对整行重复判据无意义）；
   tail 改为环形或按需截取（每 N 个 token 合并一次）。
3. 累积文本处 `binary:copy/1`，或累积为 iolist、每 64KB `iolist_to_binary` 合并一次。

验收：基准——2MB 事件分 200 块到达，解析耗时与块数近似线性；50KB 单行输出 lg_loop 总分配 <5MB；
10 万 token 流结束前进程 `binary` 内存 <2MB。

### 3.2 链路背压与上游连接池（T29）

现状：

- `lg_http_pool.erl:161` gun active 模式未开 `flow`，上游数据直接灌入处理进程；
  cowboy `stream_body` 若等待 `data_ack`（plausible），处理进程阻塞时 `gun_data` 在邮箱堆积，
  每次选择性接收扫描大邮箱退化为 O(n²)。
- `lg_http_pool.erl:17, 103, 161, 192-198`：只用 HTTP/1.1（`protocols => [http]`），每主机空闲连接上限写死 32；
  checkin 时池进程执行 `gun:info`（gun 2.x 为 `sys:get_state`，同步调用 gun 进程，plausible）；
  `gun:close` 在池进程内同步经过 `gun_conns_sup`（plausible）。同主机并发 200 路结束后 168 条连接被关，
  下一波全部重新 TLS 握手，TTFT +100～300ms；池进程被拖住时 checkout 默认 5s 超时调用方 exit。
- `lg_http.erl:398-400, 460-462`：先 `gun:flush(Ref)` 再 discard 关连接，两步间到达的
  `gun_data/gun_response` 残留在调用方邮箱；连接断开时发给 owner 的 `gun_down` 从不消费。
  在 lg_otlp、lg_notify 等长生命周期 gen_server 中调用 `lg_http:request` 时脏消息逐渐累积。
- `lg_http.erl:411-413, 465`：复用连接失败后，只要未收到响应头就重发 POST（含上游已收到并处理中的情况），
  可能被重复计费。

设计：

1. gun `http_opts => #{flow => 8}`（以 SSE 块计），处理进程每成功 `cowboy_req:stream_body`
   一块后 `gun:update_flow(Conn, Ref, 1)`，背压传回上游 TCP。
2. checkin 改为 `cast({checkin, HostKey, Conn})`，池进程不再调用 gun；`gun:close` 改为异步
   （spawn 或由调用方执行）。
3. 空闲上限配置化 `upstream_pool_idle_max`（默认 128）；按主机统计复用率指标
   `litegate_upstream_conn_reuse_ratio`。
4. HTTP/2：对支持 h2 的上游（配置 `protocols` 选项，默认关闭）开启多路复用，作为后续阶段。
5. 关闭顺序：先 `gun:close(Conn)` 再 `gun:flush(Conn)`（按连接刷，含 `gun_down`）。
6. 重发判定：仅当写请求阶段失败（`closed`/`noproc` 且未收到任何响应迹象、发出后 <50ms）才重试。

验收：慢客户端（每秒读 1KB）+ 快上游时处理进程邮箱长度 ≤ flow 窗口；
同主机 200 并发两波，第二波新建连接数 ≤ 72；长生命周期进程连续 100 次失败请求后邮箱为空。

### 3.3 流式事件单次编解码（T30）

现状：`lg_provider_stream.erl:200-212`（stage2）、`:258-263`（think 拆分）、`lg_structured.erl:165`。
Responses 转换模式下每个事件：decode 上游 → encode Chat 帧 → `iolist_to_binary` 再 parse →
再 decode → encode Responses 事件；开启 think 拆分或结构化输出再多 1～2 次 decode。
热路径每事件最多 4 次 decode、3 次 encode。

设计：lg_stream 增加返回 Chat chunk map 的内部接口（`convert_map/2`），stage2、think、structured
在同一个已解码 map 上链式处理，只在出口 encode 一次。

验收：基准——Responses 转换 + think 开启时每事件 `json:decode` 调用次数 =1；吞吐提升记录在 PR。

### 3.4 存储查询与 janitor（T31）

现状：

- `lg_store.erl:235-247`：`errors_only` 等非首个过滤条件只能逐条 Keep 过滤，错误稀少时
  翻一页要扫完整个 logs cask 并逐条 `binary_to_term`。
- `lg_store.erl:382-424`：usage 解码时间范围内所有行；标签行、客户端行、维度行混在同一小时前缀下。
  概览页（`lg_api.erl:108`）每次扫 15 天；`lg_budget:init`（`lg_budget.erl:77`）启动扫一个月，阻塞启动。
- `lg_store.erl:483-491`：`alerts/1` 全量 fold 再排序（键本身按时间有序）。
- `lg_store_janitor.erl:88-97, 137-156`：每次 `delete` 强制 `flush_usage(flush_logs)`，usage 非空时 fsync；
  `purge_index` 按前缀逐个调用写者，会话前缀 `$s` 每会话一个，每天数万次同步调用 + fsync 占住写者；
  `length(Batch) >= ?BATCH` 每键计算一次（O(n²)）。
- `lg_store_janitor.erl:101-117`：每天对 cache 与 responses 全量 `range_fold`，逐条解码完整值，
  过期键收集为单个列表一次交给写者 `put_batch_atomic`；数据量大时写者被长时间独占、
  60s 超时导致 janitor 反复崩溃重跑。

设计：

1. 新增 `$e` 错误索引维度（写入时 status ≥400 或 error 非空时建索引）；`errors_only` 优先走该索引。
2. usage 键加类别字节 `<<Hour:32, Kind:8, …>>`，查询按 Kind 范围取；写入时额外维护每小时总量行
   （Kind=0），概览与 budget init 只读总量行。（存储格式变更，需迁移：janitor 首次运行时重写近 31 天）
3. `alerts/1` 反向迭代取最近 N 条。
4. janitor：跨前缀累积到 1000 键再统一调用写者；`delete` 仅 Cask=usage 时 flush_usage；计数器代替 `length`。
5. cache / responses 键加时间前缀 `<<ExpireTs:64, …>>`（新写入），过期清理改范围扫描 + 分批（每批 1000）删除；
   旧键格式兼容一个保留周期后移除。

验收：100 万条日志、0.1% 错误时 `errors_only` 首页 <50ms；概览页 15 天查询解码行数 = 小时数；
janitor 删除 100 万键期间写者 `message_queue_len` 峰值 <1000。

### 3.5 路由热路径杂项（T32）

- `lg_affinity.erl:59-63`（`lg_strategy.erl:28` 调用）：rotate 策略 `ets:match_object(?TAB, {{Route,'_'},'_'})`
  在 set 表上部分绑定键 → 全表扫描并拷贝匹配条目；10 万会话时每请求额外数毫秒。
  → 维护 `{route_target_count, Route, Target}` 计数（`put_target` 换目标时增减，sweep 时校正）。
- `lg_out_rate:allow/1`：每次尝试 `lg_credentials:get` 一次 + `state_of` 两次 → 改为传入 plan 中已有的凭证记录，
  state 只读一次。
- `lg_middleware.erl:236` `call_sync`：每个同步中间件把整个请求体（可能数 MB）拷入新进程再拷回 →
  在当前进程运行，用 `erlang:start_timer` + 超时 `exit` 保护（或仅对 remote 类型使用独立进程）。
- `lg_health` `?LAST` 表、`lg_live` `{last, Route}` 条目不清理，通配模型名下无界 → 纳入周期 sweep（24h 无更新删除）。

验收：10 万会话下 rotate 策略单次选择 <50µs；新增 sweep 有测试。

### 3.6 低优先级杂项（T33）

- `lg_backup.erl:107-111`：`ok = filelib:ensure_dir/file:rename` 失败崩溃 gen_server 并计入 sup 重启强度；
  文件名精确到秒，同秒两次运行互相覆盖 → 错误返回 + 文件名加毫秒/序号。
- `lg_config_io:export`：非事务读取，各表非同一时刻快照 → 用 `mnesia:activity(transaction, …)` 只读事务。
- `lg_catalog_sync.erl:51, 73`：`schedule()` 只在 init 读一次配置，运行时修改 `catalog_sync_interval_ms` 不生效；
  models.dev 返回残缺 JSON 时会删掉大部分 L0 模型 → 每次调度重读配置；删除比例超过 30% 时中止同步并告警。
- bitcask 数据无在线一致性备份，文档要求停服复制 → 路线图项：janitor 中基于 merge 后 hint 文件的只读快照。

---

## 影响面

- 代码：全部 6 个应用；新增常驻进程 `lg_route_cache`、`lg_store_handles`、`lg_store_indexer`（命名以实现为准）。
- 新配置项：`store_queue_soft`、`store_queue_hard`、`stream_idle_timeout_ms`、`stream_max_ms`、
  `upstream_max_body_bytes`、`sse_max_event_bytes`、`shutdown_drain_ms`、`http_max_connections`（需重启）、
  `upstream_pool_idle_max`、`alert_silence_ms`、`alert_recover_ms`。
- 新指标：`litegate_store_degraded_total`、`litegate_store_write_errors_total`、`litegate_upstream_timeouts_total`、
  `litegate_upstream_conn_reuse_ratio`、`litegate_classifier_skipped_total`。
- 存储格式变更：仅 T31（usage 类别字节、cache/responses 时间前缀），需迁移与兼容期。
- 行为变更（需写入 CHANGELOG）：客户端断开记 499；流式默认 120s 空闲超时（原 300s）；
  写者积压时降级丢弃对话/检索；mnesia 退出时节点退出（由 systemd/docker 拉起）。
