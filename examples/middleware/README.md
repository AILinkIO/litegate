# 中间件示例

中间件就是导出钩子函数的 Erlang 模块：

```erlang
on_request(Body, Ctx, Config)  -> continue | {ok, Body} | {ok, Body, State} | {reject, Status, Message}
on_event(Event, Ctx, Config)   -> continue | {ok, Event} | drop          % Event = #{event, data}
on_response(Body, Ctx, Config) -> continue | {ok, Body}
```

`Ctx` 含 `route`、`model`、`format`（openai / anthropic / responses）、`stream`、`client`、`key_name`、`tags`、`session`
与本请求内的 `state`（`on_request` 返回的第三项）。出错、超时（同步钩子默认 250ms）时网关原样放行并计数。

## 插件（运行在网关节点里）：`plugin/`

插件模块声明 `-behaviour(lg_middleware)` 并导出 `describe/0`（可选 `validate/1`、`hooks/1`），编译后放进插件目录：

```sh
erlc -o /var/lib/litegate/plugins plugin/mw_block_models.erl
```

插件目录是运行参数 `middleware_plugin_dir`，默认 `<data_dir>/plugins`；也可以放整个编译好的应用（`<目录>/<应用>/ebin/*.beam`）。
然后在控制台「中间件」页点「重新扫描插件」，新建中间件时选择实现 `block_models`。改了插件重新编译、再扫描即可热替换。

网关里的辅助模块 `lg_mw` 可以直接调用（`lg_mw:last_user_text/2`、`lg_mw:add_system/4`、`lg_mw:event_text/2` 等，按 `Ctx` 的格式处理三种接口）。

## 远程节点（运行在你自己的节点上）：`remote/`

不需要把代码放进网关：在自己的 Erlang 节点上运行模块，网关用实现 `remote` 通过分布式调用它。

```sh
cd remote
erlc -o ebin src/demo_mw.erl        # 先 mkdir ebin
# cookie 与网关节点相同（网关发布包取 $HOME/.erlang.cookie，或在 vm.args 里设置 -setcookie）
erl -name mw@127.0.0.1 -setcookie "$(cat ~/.erlang.cookie)" -pa ebin -noshell
```

控制台新建中间件，实现选「远程节点」，配置：

```json
{"node": "mw@127.0.0.1", "module": "demo_mw", "config": {"block": ["forbidden"]}, "events": true, "timeout_ms": 200}
```

`events` 为 true 时每个流式事件都会发到远程节点（一次网络往返），只在需要改写流式输出时打开。保存后可以用「测试」检查连通性。

安全：Erlang 分布式的两端互相拥有完全权限，只连接自己控制的节点。发布包的分布式端口只监听 127.0.0.1；
跨主机时需要修改 `vm.args` 的 `-kernel inet_dist_use_interface`，并建议使用 TLS 分布式（`-proto_dist inet_tls`）。
