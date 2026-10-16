# 开发

## 依赖

- Erlang/OTP 27 或更新版本、rebar3
- CMake、C++23 编译器和 ICU 头文件，用于编译 Bitcask NIF
- Node.js，用于构建控制台

## 构建和运行

```sh
rebar3 compile
cd web
npm install
npm run build
cd ..
rebar3 shell
```

控制台构建产物输出到 `apps/lg_web/priv/static`。打开 `http://localhost:4000/console`。

前端开发模式：

```sh
cd web
npm run dev
```

Vite 默认把 `/api` 和 `/v1` 代理到 `http://127.0.0.1:4000`，可以用 `LITEGATE_URL` 覆盖。

## 测试和检查

```sh
rebar3 eunit
rebar3 xref
rebar3 dialyzer
cd web
npm test
npm run lint
npm run build
```

发布脚本会生成包含 ERTS 的自包含发布包：

```sh
scripts/release.sh
```

## 项目结构

| 路径 | 用途 |
|---|---|
| `apps/` | Erlang 应用，每个目录对应一个子系统 |
| `web/` | React 控制台 |
| `docs/` | 用户、运维、架构和开发文档 |
| `deploy/` | systemd 和环境变量模板 |
| `scripts/` | 发布和兼容性测试工具 |
| `examples/` | 中间件示例 |

## 文档约定

行为变化必须同步更新文档。文档写当前行为和原因，不保留实现历史或任务状态。
只有面向不同读者或独立主题时才新增页面，并在 `README.md` 中链接。
