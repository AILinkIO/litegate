# 单机部署（systemd）

## 构建

构建机需要：Erlang/OTP ≥ 27、rebar3、CMake、C++23 编译器、`libicu-dev`、Node.js、git。

```sh
scripts/release.sh
# 产物：_build/prod/rel/litegate/litegate-0.1.0.tar.gz（含 ERTS，目标机无需安装 Erlang）
```

目标机需与构建机的 CPU 架构、glibc、libicu 大版本一致（release 内含 bitcask NIF 与 ERTS 的本机代码），
并安装运行时库：`libicu`、`libstdc++`、`openssl`、`ca-certificates`（访问 HTTPS 上游需要系统 CA 证书）。

## 安装

```sh
sudo useradd --system --home-dir /var/lib/litegate --shell /usr/sbin/nologin litegate
sudo mkdir -p /opt/litegate /etc/litegate
sudo tar -xzf litegate-0.1.0.tar.gz -C /opt/litegate

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

mnesia 表结构升级在启动时自动执行（`lg_schema`）；数据目录无需改动。

## 安全须知

- 控制台默认免登录（`console_auth = false`）：任何能访问 HTTP 端口的人都可以管理上游 Key、路由与 API Key。
  服务默认只绑定 `127.0.0.1`；绑定非 loopback 地址且未开启登录时，启动日志和控制台顶部会出现安全提示。
  端口对外开放时，请开启登录（先在「用户」页创建管理员，再把运行参数 `console_auth` 设为 true），
  或用防火墙 / 反向代理限制 `/console` 与 `/api` 的访问来源。
- 节点名固定为 `litegate@127.0.0.1`（mnesia 数据与节点名绑定，主机名变化不影响）；Erlang 分布式端口与 epmd
  只监听本机，cookie 自动生成在 `$HOME/.erlang.cookie`。
