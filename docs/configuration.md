# 配置

## 配置分层

生效值按以下优先级读取：

1. Mnesia 中的运行参数，可在控制台修改。
2. `LITEGATE_<参数名>` 环境变量。
3. `sys.config` 应用环境。
4. 代码默认值。

只有 `lg_config` 声明过的参数可以读写，避免拼错的参数静默失效。

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
