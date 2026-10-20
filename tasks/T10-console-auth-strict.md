# T10 console_auth 严格模式

优先级：P1（安全） ｜ 设计：[D04 §1](../designs/D04-features-and-security.md) ｜ 状态：待开始 ｜ 依赖：无

## 背景

`console_auth` 默认 false，`http_bind` 非 loopback 时仅打 warning。容器部署绑
0.0.0.0 极常见，管理面（凭证明文、中间件配置）存在裸奔风险。

## 目标

非 loopback 绑定 + 未开鉴权 → 默认拒绝启动；显式 `allow_insecure_bind=true` 才放行。

## 改动点

- `apps/lg_core/src/lg_config.erl`：defaults 增加 `allow_insecure_bind(false)`。
- `apps/lg_web/src/lg_web_app.erl`（监听器启动处）：绑定地址判定
  （loopback：`127.0.0.0/8`、`::1`）+ 组合检查，不满足时启动失败并输出指引日志。
- `docs/deploy.md`、`docs/configuration.md`、RELEASE NOTES：标注破坏性变更与迁移方式。

## 验收标准

- [ ] eunit：四种组合（loopback/非 loopback × auth 开/关）+ allow_insecure 逃生门；
- [ ] `/health`、`/metrics`、`/v1` 不受影响（只约束 console/api 管理面的启动条件）；
- [ ] 文档更新完毕。

## 预估

~60 行，0.5 天。
