# 客户端兼容性测试

需要一个运行中的 LiteGate、一个网关 API Key（`lgk-…`）和可用的路由。
以下配置覆盖同协议与跨协议场景。

## SDK 冒烟测试

```sh
python3 -m venv /tmp/lg-venv && /tmp/lg-venv/bin/pip install openai anthropic
LITEGATE_URL=http://127.0.0.1:4000 LITEGATE_API_KEY=lgk-... \
  OPENAI_ROUTE=glm ANTHROPIC_ROUTE=glm /tmp/lg-venv/bin/python scripts/compat/sdk_smoke.py
```

覆盖 OpenAI SDK（模型列表、Chat 同步 / 流式 / 工具往返、Responses 同步 / 流式）与
Anthropic SDK（Messages 同步 / 流式 / 工具往返、count_tokens），任一失败退出码为 1。

## Claude Code

```sh
export ANTHROPIC_BASE_URL=http://127.0.0.1:4000
export ANTHROPIC_AUTH_TOKEN=lgk-...
unset ANTHROPIC_API_KEY
# 方式一：直接指定路由
claude --model glm
# 方式二：不指定模型，建一个 `claude-*` 通配路由（或给路由加别名，如 claude-sonnet-4-5）接住 Claude Code 默认的模型名
```

- 子代理与后台任务使用小模型，可用 `ANTHROPIC_DEFAULT_HAIKU_MODEL=<路由>` 指定
- 开启思考：`MAX_THINKING_TOKENS=4000`
- 上游不支持 count_tokens 时网关本地估算（响应头 `x-litegate-estimated: true`）

## Codex CLI

`$CODEX_HOME/config.toml`（默认 `~/.codex/config.toml`）：

```toml
model = "glm"
model_provider = "litegate"

[model_providers.litegate]
name = "LiteGate"
base_url = "http://127.0.0.1:4000/v1"
env_key = "LITEGATE_API_KEY"
wire_api = "responses"
```

```sh
LITEGATE_API_KEY=lgk-... codex exec -s workspace-write "..." < /dev/null
```

- `codex exec` 会从标准输入读取附加内容，非交互运行时要重定向 `< /dev/null`，否则一直等待
- `CODEX_HOME` 不能放在 `/tmp` 下，否则 Codex 不创建 `apply_patch` 等辅助程序
- 路由的上游是 OpenAI Chat 协议时网关转换 Responses（含 reasoning 项、custom / namespace 工具）；
  凭证开启 `responses_api` 时直接转发给上游原生 `/responses`

## opencode

`$XDG_CONFIG_HOME/opencode/opencode.json`：

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "litegate": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "LiteGate",
      "options": { "baseURL": "http://127.0.0.1:4000/v1", "apiKey": "lgk-..." },
      "models": { "glm": { "name": "GLM via LiteGate" } }
    },
    "litegate-anthropic": {
      "npm": "@ai-sdk/anthropic",
      "name": "LiteGate Anthropic",
      "options": { "baseURL": "http://127.0.0.1:4000/v1", "apiKey": "lgk-..." },
      "models": { "mm": { "name": "MiniMax via LiteGate" } }
    }
  }
}
```

```sh
opencode run -m litegate/glm "..."
```
