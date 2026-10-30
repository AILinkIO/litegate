# 配置

## 配置分层

生效值按以下优先级读取：

1. Mnesia 中的运行参数，可在控制台修改。
2. `LITEGATE_<参数名>` 环境变量。
3. `sys.config` 应用环境。
4. 代码默认值。

只有 `lg_config` 声明过的参数可以读写，避免拼错的参数静默失效。

运行参数与环境变量两层的解析结果缓存在内存中：控制台修改、配置导入都会立即失效对应缓存；
环境变量只在首次读取时生效，修改后需重启。

## 核心参数

| 参数 | 环境变量 | 默认值 | 说明 |
|---|---|---|---|
| HTTP 端口 | `LITEGATE_HTTP_PORT` | `4000` | 网关和控制台监听端口 |
| HTTP 绑定地址 | `LITEGATE_HTTP_BIND` | `127.0.0.1` | 容器或反向代理场景可设为 `0.0.0.0` |
| 数据目录 | `LITEGATE_DATA_DIR` | `data` | Mnesia 和 Bitcask 的存储根目录 |
| 控制台登录 | `LITEGATE_CONSOLE_AUTH` | `false` | 是否要求控制台账号登录 |
| 初始管理员密码 | `LITEGATE_ADMIN_PASSWORD` | 随机生成 | 开启登录且没有账号时用于创建 admin |
| 加密主密钥 | `LITEGATE_ENCRYPTION_KEY` | `data/secret.key` | Base64 编码的 32 字节 AES-GCM 主密钥 |

其余参数、默认值、校验规则和说明见控制台的「运行参数」页。

### 超时、上限与关停

| 参数 | 默认值 | 说明 |
|---|---|---|
| `upstream_timeout_ms` | `300000` | 等上游响应头 / 流式首块数据的超时；非流式读响应体从发出请求起按此截止 |
| `stream_idle_timeout_ms` | `120000` | 流式收到首块数据后，块间空闲超过该值即结束（504，phase=idle）；上游 ping 注释帧也算数据 |
| `stream_max_ms` | `1800000` | 流的总时长上限（从开流起算），超过后即使上游仍在发数据也以错误帧结束（phase=total） |
| `upstream_max_body_bytes` | `67108864` | 非流式上游响应体上限，超过即中止读取、丢弃连接，返回 502 且不回退（phase=too_large） |
| `sse_max_event_bytes` | `8388608` | 单个未结束 SSE 事件的缓冲上限，超过即中止上游，以错误帧结束（phase=too_large） |
| `upstream_pool_idle_max` | `128` | 每个上游主机（协议 + 主机 + 端口）在连接池中保留的空闲连接上限，超出的连接归还时异步关闭；高峰并发高时调大可减少下一波的重新握手 |
| `http_max_connections` | `16384` | 每个监听器的连接上限（需重启） |
| `shutdown_drain_ms` | `20000` | 关停时等待在途请求完成的最长时间 |
| `store_queue_soft` / `store_queue_hard` | `5000` / `50000` | 存储写者积压降级阈值：超过 soft 丢弃对话、检索文档与响应缓存，超过 hard 只保留用量 |
| `alert_silence_ms` | `1800000` | 同一事件静默期内只通知一次；upstream_down 按目标 + 规则计算，静默期内再次故障既不告警也不发恢复 |
| `alert_recover_ms` | `60000` | 上游恢复后持续这么久没有再失败才发恢复通知 |

监听器空闲超时固定为 `upstream_timeout_ms + 60s`（发送数据也会重置计时），不单独配置：HTTP/1.1 请求之间的
keep-alive 空闲由 cowboy 的 `request_timeout`（5s）管理，HTTP/2 的空闲计时是整条连接级别的，必须高于上游超时。

## 安全

- 默认只绑定 loopback，适合本机使用。
- 暴露到 localhost 以外前，先创建管理员，并把 `console_auth` 设为 true。
- 公网部署优先由反向代理终止 TLS，并限制 `/console` 和 `/api` 的访问来源。
- 优先通过环境变量注入 `LITEGATE_ENCRYPTION_KEY` 和 `LITEGATE_BACKUP_PASSPHRASE`，
  避免这些口令落在数据库里。
- 加密主密钥丢失后，已保存的上游凭证将无法解密。

## 数据和备份

数据目录包含 Mnesia 配置、Bitcask 运行数据，以及未设置环境主密钥时自动生成的加密密钥。
做完整备份前先停止服务，然后复制整个目录。

可以在控制台开启配置自动备份。备份会按固定间隔写入配置的备份目录，使用口令加密，
并按保留份数滚动清理。

### 安全绑定（1.1.0 破坏性变更）

非回环绑定地址（如 `0.0.0.0`）且 `console_auth` 为 `false` 时，网关**拒绝启动**，
防止管理 API（凭证明文、中间件配置）在无鉴权状态下暴露到网络。

迁移方式（三选一）：
1. 启用控制台登录：设 `LITEGATE_CONSOLE_AUTH=true`，首次启动用 `LITEGATE_ADMIN_PASSWORD` 创建管理员。
2. 改绑回环地址：设 `LITEGATE_HTTP_BIND=127.0.0.1`（反向代理/隧道转发到网关）。
3. 明确接受风险：设 `LITEGATE_ALLOW_INSECURE_BIND=true`（仅限受信任的隔离网络）。

`/health`、`/metrics`（带 token）与 `/v1`（API Key 鉴权）不受此约束，只影响管理面启动条件。
