# 单机部署（systemd）

## 构建

构建机需要：Erlang/OTP ≥ 27、rebar3、CMake、C++23 编译器、`libicu-dev`、Node.js、git。

```sh
scripts/release.sh
# 产物：_build/prod/rel/litegate/litegate-1.1.0.tar.gz（含 ERTS，目标机无需安装 Erlang）
```

目标机需与构建机的 CPU 架构、glibc、libicu 大版本一致（release 内含 bitcask NIF 与 ERTS 的本机代码），
并安装运行时库：`libicu`、`libstdc++`、`openssl`、`ca-certificates`（访问 HTTPS 上游需要系统 CA 证书）。

## 安装

```sh
sudo useradd --system --home-dir /var/lib/litegate --shell /usr/sbin/nologin litegate
sudo mkdir -p /opt/litegate /etc/litegate
sudo tar -xzf litegate-1.1.0.tar.gz -C /opt/litegate

sudo cp deploy/litegate.env.example /etc/litegate/litegate.env
sudo chmod 600 /etc/litegate/litegate.env
# 编辑 /etc/litegate/litegate.env，建议设置 LITEGATE_ENCRYPTION_KEY（openssl rand -base64 32）

sudo cp deploy/litegate.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now litegate
```

### 部署形态

- **本机体验**：保持默认 `LITEGATE_HTTP_BIND=127.0.0.1`，只允许本机访问。可以先免登录快速试用，
  打开 `http://127.0.0.1:4000/console` 完成配置。
- **内网服务**：把 `LITEGATE_HTTP_BIND` 设为主机的内网地址，或临时设为 `0.0.0.0` 后用防火墙只放行
  可信网段。暴露到非 loopback 前先在「用户」页创建管理员，再把运行参数 `console_auth` 设为 true。
- **公网服务**：必须开启登录并使用强初始口令；优先由反向代理终止 TLS，并限制 `/console` 与 `/api`
  的来源。容器内保持 `LITEGATE_HTTP_BIND=0.0.0.0`，由宿主机端口映射、防火墙或反代决定对外暴露面。

## 运维

| 操作 | 命令 |
|---|---|
| 状态 / 日志 | `systemctl status litegate`、`journalctl -u litegate -f` |
| 连接运行中的节点 | `sudo -u litegate env HOME=/var/lib/litegate ERL_EPMD_ADDRESS=127.0.0.1 /opt/litegate/bin/litegate remote_console` |
| 健康检查 | `curl http://localhost:4000/health` |
| 指标 | `curl http://localhost:4000/metrics`（设置了 `metrics_token` 时需 Bearer） |

### 关停与资源上限

- 收到 SIGTERM 后先暂停监听，最多等 `shutdown_drain_ms`（默认 20s）让在途请求完成，期间 HTTP/1.1 响应带
  `connection: close`；随后关闭监听，存储最后 flush。systemd 的 `TimeoutStopSec` 与 compose 的
  `stop_grace_period` 需不小于 60s（已在 `deploy/litegate.service`、`docker-compose.yml` 中配置）。
- 文件句柄上限 65536（systemd `LimitNOFILE`、compose `ulimits.nofile`），与 vm.args 的 `+Q 65536` 对齐。
- mnesia 以 permanent 方式运行：mnesia 自行退出时整个节点退出，由 systemd / docker 拉起；
  mnesia 未运行时 `/health` 返回 503。

## 备份

整个 `/var/lib/litegate` 即全部状态：`mnesia/`（配置）、`store/`（日志、用量、检索）、`secret.key`（未设置
`LITEGATE_ENCRYPTION_KEY` 时的主密钥，丢失后无法解密已存的上游 Key）、`.erlang.cookie`。停服后整目录复制即可。

## 升级

```sh
sudo systemctl stop litegate
sudo rm -rf /opt/litegate && sudo mkdir /opt/litegate
sudo tar -xzf litegate-<新版本>.tar.gz -C /opt/litegate
sudo systemctl start litegate
```

mnesia 表结构升级在启动时自动执行（`lg_schema`）；数据目录无需改动。升级前自动备份到
`<data_dir>/mnesia-backup-v<N>-<ts>.bup`（每个版本只备份一次）。升级按表记录进度，中途崩溃后重启会继续完成。

存储派生数据（每小时用量总量与费用分解、错误日志索引、响应缓存 / Responses 过期索引）在升级后由 janitor
在后台自动回填：启动约 10 秒后开始，逐小时重算历史用量、解码日志补错误索引、扫描缓存补过期索引，可中断续跑，
数据量大时可能持续数分钟；回填完成前概览、`errors_only` 查询与预算重建走原有路径，结果不变。原有键与值格式
不变，可直接降级回上一版本（新增的派生数据会被忽略）；降级后再升级会自动补上降级期间写入的数据。

## 安全须知

- 控制台默认免登录（`console_auth = false`）：任何能访问 HTTP 端口的人都可以管理上游 Key、路由与 API Key。
  服务默认只绑定 `127.0.0.1`；绑定非 loopback 地址且未开启登录时，启动日志和控制台顶部会出现安全提示。
  端口对外开放时，请开启登录（先在「用户」页创建管理员，再把运行参数 `console_auth` 设为 true），
  或用防火墙 / 反向代理限制 `/console` 与 `/api` 的访问来源。
- 节点名固定为 `litegate@127.0.0.1`（mnesia 数据与节点名绑定，主机名变化不影响；`rebar3 shell` 使用同一节点名，
  eunit 使用 `litegate_test@127.0.0.1`）；Erlang 分布式端口与 epmd 只监听本机，cookie 自动生成在 `$HOME/.erlang.cookie`。
- 以其他节点名打开已有数据目录时拒绝启动（`node_name_mismatch`），不会改写数据。确需改名时停服后执行：
  `erl -noshell -pa /opt/litegate/lib/*/ebin -name <新名> -mnesia dir '"<数据目录>/mnesia"' -eval "ok = lg_schema:rename_node('<旧名>'), halt()."`，
  原目录保留为 `mnesia.pre-rename-<时间戳>`，确认无误后可删除。

## 多实例部署

当前所有限额与状态均为**节点本地**（单节点内存），横向扩容时全局配额 ≈ N × 配置值。

### Per-node 状态清单

| 状态 | 模块 | 存储位置 | 扩容行为 |
|---|---|---|---|
| 入站 RPM/TPM/并发 | `lg_limiter` | ETS | 每节点独立计数，全局 ≈ N × 配置值 |
| 上游并发闸 | `lg_conc` | ETS | 每节点独立排队，上游实际并发 ≈ N × max_concurrency |
| 预算计数 | `lg_budget` | ETS（内存累加） | 每节点独立累计，重启清零 |
| 冷却表 | `lg_cooldown` | ETS | 每节点独立（同一上游在一节点冷却不影响其他节点） |
| 会话粘性 | `lg_affinity` | ETS | 每节点独立（负载均衡无亲和时粘性失效） |
| 出站节流 Cap | `lg_out_rate` | ETS | 每节点独立学习，上游实际承受 ≈ N × Cap |
| 响应缓存 | `lg_cache` | bitcask | 每节点独立目录，不共享 |
| 登录限流 | `lg_login_guard` | ETS | 每节点独立 |
| 控制台会话 | `lg_session` | mnesia | 可集群同步（mnesia 配置表）；每节点独立 token |

### 配置折算指引

N 实例部署时，每节点入站限流建议配 1/N（防止上游实际承受 N × 原值）；
上游 `max_concurrency` 同理除以 N。出站节流 Cap 每节点独立学习，无需手动折算。

### 数据目录

bitcask `data_dir` **不可多节点共享**（每实例独立目录 + 本地磁盘）。
mnesia 配置表（路由、凭证、API Key 等）可通过 `mnesia:change_config(+extra_db_nodes)` 集群同步。

### 负载均衡注意事项

- 上游会话粘性依赖网关到客户端的会话 ID（`X-LiteGate-Session` 等），
  前置 LB 需按此 header 做 session affinity，否则跨节点粘性失效。
- WebSocket / SSE 长连接需 LB 支持长连接超时（大于 `upstream_timeout_ms`）。

### 全局限流（路线图）

跨节点全局计数属路线图（需外部计数器后端如 Redis），当前版本不承诺。
