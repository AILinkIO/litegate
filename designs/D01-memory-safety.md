# D01 内存安全与资源增长治理（P0）

状态：待实施 ｜ 对应任务：T01、T02、T03

## 背景

全项目审计结论：请求路径无动态原子生成（模型名、metrics label 全程 binary），
多数 ETS 表有周期清扫，monitor 释放槽位无泄漏。但存在以下真实的无界/高风险增长点。

## 1. OTLP 队列按条数封顶 → 改按字节封顶（最严重）

现状（`apps/lg_router/src/lg_otlp.erl`）：

- `?MAX_QUEUE = 10000`，`handle_cast({spans, New}, …)` 只比较 **span 条数**（L285-289）。
- `otlp_bodies = true` 时每个 span 携带请求/响应体，`clip/1` 截断上限 256KB（L187-193）。
- 最坏情况：10000 × 2 × 256KB ≈ **5GB** 驻留内存（导出端点慢或不可达时队列堆满）。

设计：

1. span 入队时估算大小并随队列条目保存：
   `size = 固定开销估算(≈2KB, 属性/名称/时间戳) + Σ body 字节数`。
   body 在 `body_text/3` 生成处即已知大小，避免入队后再次遍历。
2. gen_server state 增加 `bytes` 计数，入队 `+Size`、发送/丢弃时扣减。
3. 双层上限：
   - `otlp_queue_max_bytes`（新配置项，默认 `64 * 1024 * 1024`）；
   - 保留条数上限 `?MAX_QUEUE` 作为小 span 场景的兜底。
4. 超限时的降级顺序（尽量保链路完整）：
   a. 队列字节 > 50% 上限：新 span **丢弃 bodies**（只留元数据），记
      `litegate_otlp_stripped_total`；
   b. 仍超上限：丢弃新 span（现有 `litegate_otlp_dropped_total` 行为不变）。
5. `handle_info` 导出失败重试路径同样按字节扣减，防止重入队时计数漂移。

验收：

- eunit：构造大 body span 灌入队列，验证 50% 阈值剥 body、上限丢 span、两个计数器正确；
- 发送成功后 `bytes` 归零；
- `otlp_bodies = false` 时行为与现状一致。

## 2. lg_login_guard 无周期清扫（可被攻击者撑大）

现状（`apps/lg_router/src/lg_login_guard.erl`）：

- 条目 `{Key, Count, Since, Until}`，Key = `{Username, PeerIp}`（L52）。
- 过期只在**同 Key 再次 check 时**惰性删除（L25-30）；`success/2` 删单条。
- 攻击者用随机 username × 随机 IP 撞 `/console` 登录接口，可让该表无界增长
  （每行小，但速率不受限，且本身就是暴力破解资源消耗攻击面）。

设计：

1. gen_server 增加 60s 周期 `handle_info(sweep, …)`：
   ```erlang
   Now = lg_time:now_ms(),
   MS = [{{'$1','$2','$3','$4'},
          [{=<, {'+','$3', ?WINDOW_MS}, Now}, {=<, '$4', Now}],
          [true]}],
   ets:select_delete(?TAB, MS)
   ```
   即：窗口已过 **且** 不在冷却期的条目才删（冷却中的保留，维持惩罚语义）。
2. 表由 `ensure/0` 惰性创建的场景下，sweep 前先 `ets:info(?TAB, name)` 判存在。

验收：eunit 造过期/冷却中/窗口内三类条目，sweep 后仅第一类被删。

## 3. 其余状态表清扫补齐（低风险，顺带做）

| 表 | 现状 | 处理 |
|---|---|---|
| `lg_affinity` `{{tokens, CredId}, V, At}` | 现有 sweep 只匹配带 `last_at` 的 session 条目，tokens 永不清 | 同一 sweep 里删除 `At` 超过 30 天的条目 |
| `lg_affinity` `{{turn, Route}, N}` | 永不删 | 有界（= 路由数），仅在路由删除时无对应清理——接受现状，代码注释说明 |
| `lg_cooldown` | 过期条目不主动删，仅 mark/succeeded 覆盖 | 低频（5min）`select_delete`：`Now > Until + 2*Dur` 的条目（此时已不影响 streak 判定，删除无语义损失） |
| `lg_session`（mnesia 控制台会话） | 过期只在访问时惰性清 | 每日一次事务清理 `expires_at < now` 的行 |

## 4. mw_remote 原子硬化

现状：`apps/lg_router/src/lg_mw_remote.erl:49-50` 对管理员配置的 node/module 用
`binary_to_atom/1`。来源可信、实际有界，但这是全项目仅有的两处动态原子生成之一。

设计：改 `binary_to_existing_atom(B, utf8)`，捕获 `error:badarg` 后返回明确的
配置错误（`{error, {unknown_node_or_module, B}}`），由中间件加载路径记日志并跳过
该中间件。合法目标（已连接节点、已加载模块）原子必然已存在，无误伤。
插件目录扫描的 `list_to_atom(filename:basename…)` 受文件系统约束，维持现状。

验收：eunit 覆盖不存在原子时的错误返回；现有 `lg_mw_tests` 全绿。

## 影响面

- 仅 `lg_router`（otlp/login_guard/affinity/cooldown/mw_remote）、`lg_web`（session 清理）、
  `lg_core`（新配置项 `otlp_queue_max_bytes`）。
- 无 API/存储格式变更，无迁移。
