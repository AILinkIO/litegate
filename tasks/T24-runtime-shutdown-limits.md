# T24 mnesia 运行模式、优雅关停与资源上限

优先级：P1 ｜ 设计：[D05 §2.5](../designs/D05-regressions-stability-perf.md) ｜ 状态：待评审 ｜ 依赖：无

## 背景

mnesia 以 temporary 启动，退出后节点存活但持续 500 且不会被拉起；关停时两个 listener 串行等待用满
docker 默认 10s 宽限期，写者来不及 flush；compose 无 `stop_grace_period`/`ulimits`；
ranch 默认 1024 连接上限、360s idle；vm.args 含无效参数。

## 改动点

- `apps/lg_core/src/lg_schema.erl:20`：`application:ensure_all_started(mnesia, permanent)`。
- `/health`：增加 `mnesia:system_info(is_running)` 检查，非 yes 返回 503。
- `apps/lg_web/src/lg_web_app.erl`
  - 新增 `prep_stop/1`：`ranch:suspend_listener` 全部 listener → 轮询连接/活跃流至 0 或 `shutdown_drain_ms`（默认 20000）；
  - `:22-25` TransOpts 增加 `max_connections => lg_config:get(http_max_connections)`（默认 16384）；
    ~~keep-alive `idle_timeout` 改用 `http_idle_timeout_ms`~~（已撤销，原因见 D05 §2.5 第 4 点）。
- `apps/lg_core/src/lg_config.erl`：新增上述配置项，`http_max_connections` 加入 `restart_keys/0`。
- `docker-compose.yml`：`stop_grace_period: 60s`、`ulimits: {nofile: {soft: 65536, hard: 65536}}`。
- `deploy/litegate.service`：确认 `TimeoutStopSec=60`、`LimitNOFILE=65536`。
- `config/vm.args`：删除 `+K true`、`+A 30`；增加 `+sbwt none +sbwtdcpu none +sbwtdio none`、`+Q 65536`
  （`+SDio` 视 bitcask NIF 是否走 dirty IO 再定，先确认）。

## 验收标准

- [ ] `docker compose stop` 期间持续流式请求：在途请求全部完成且有日志，最后批次用量已落盘；
- [ ] 手动 `application:stop(mnesia)` 后节点退出（systemd/docker 拉起），`/health` 在退出前返回 503；
- [ ] 容器内 `ulimit -n` = 65536；2000 并发长连接无 EMFILE；
- [ ] `rebar3 eunit xref dialyzer` 全绿；docs/deploy.md 与 docs/configuration.md 同步。

## 预估

~150 行 + 配置，1 天。
