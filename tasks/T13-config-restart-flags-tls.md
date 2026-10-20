# T13 配置分级标注与 TLS 监听

优先级：P2 ｜ 设计：[D04 §3](../designs/D04-features-and-security.md) ｜ 状态：待开始 ｜ 依赖：无

## 背景

监听器参数（idle_timeout、max_body_bytes 等）只在启动时读取，控制台在线修改后
需重启才生效但无任何提示；且仅支持 `cowboy:start_clear`，无 TLS。

## 目标

1. 配置项元数据标注 `restart => true|false`，控制台设置页显示"需重启生效"徽标；
2. 支持 TLS 监听器（可与 clear 并存）。

## 改动点

- `apps/lg_core/src/lg_config.erl`：defaults 附带元数据（可用伴生函数
  `restart_keys/0` 避免改 defaults 结构）；`all/0` 或管理 API 透出。
- `apps/lg_web/src/lg_api_admin.erl` + `web/src/features/settings/`：徽标展示。
- `apps/lg_core/src/lg_config.erl`：`tls_enabled(false)`、`tls_port`、
  `tls_cert_file`、`tls_key_file`。
- `apps/lg_web/src/lg_web_app.erl`：按配置追加 `cowboy:start_tls`；
  证书文件缺失/不可读时启动失败并给出明确日志。
- `docs/deploy.md`、`docs/configuration.md` 更新（TLS 终止 vs 前置反代两种拓扑）。

## 验收标准

- [ ] eunit：restart_keys 覆盖全部仅启动时读取的项（对照 lg_web_app 实际读取清单）；
- [ ] TLS e2e：自签证书起监听，`curl -k https://…/health` 通过；
- [ ] tls_enabled=false 时行为与现状一致；
- [ ] 控制台徽标正确；文档更新。

## 预估

~150 行（含前端），1 天。
