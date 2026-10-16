# 接入

## OpenAI 兼容客户端

把客户端基础地址指向网关，并使用网关 API Key：

```text
Base URL: http://localhost:4000/v1
API key:  lgk-...
```

Anthropic 兼容客户端使用网关根地址，不要额外追加 `/v1`，并用 `x-api-key` 传递网关 Key。

## Claude Code

设置以下环境变量：

```sh
export ANTHROPIC_BASE_URL=http://127.0.0.1:4000
export ANTHROPIC_AUTH_TOKEN=lgk-...
unset ANTHROPIC_API_KEY
```

在控制台创建名为 `claude-*` 的通配路由，或为 Claude Code 使用的模型名添加路由别名。
路由目标可以使用 Anthropic 协议凭证，也可以使用 OpenAI 协议凭证；网关会自动转换协议。

常用可选配置：

| 环境变量 | 用途 |
|---|---|
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | 子代理和后台任务使用的路由 |
| `MAX_THINKING_TOKENS` | 开启思考 |

给 API Key 设置默认标签，例如 `tool:claude-code`，可以在用量和预算中单独统计这个客户端。

## Codex CLI

在 `$CODEX_HOME/config.toml` 中添加 provider：

```toml
model = "glm"
model_provider = "litegate"

[model_providers.litegate]
name = "LiteGate"
base_url = "http://127.0.0.1:4000/v1"
env_key = "LITEGATE_API_KEY"
wire_api = "responses"
```

启动 Codex 前设置 `LITEGATE_API_KEY`。凭证开启 `responses_api` 时直接透传 Responses 请求；
否则网关把它转换为 Chat Completions，并映射推理内容和工具数据。

## opencode

把 LiteGate 配置为 OpenAI 兼容 provider。OpenAI 上游使用 OpenAI 兼容模型项，
Anthropic 上游使用 Anthropic 模型项。基础地址设为 `http://127.0.0.1:4000/v1`，
API Key 使用网关 Key。

## SDK 冒烟测试

`scripts/compat/sdk_smoke.py` 覆盖 OpenAI 和 Anthropic SDK 的模型列表、同步与流式请求、
工具调用、Responses、Messages 和 token 计数。

```sh
python3 -m venv /tmp/lg-venv
/tmp/lg-venv/bin/pip install openai anthropic
LITEGATE_URL=http://127.0.0.1:4000 \
LITEGATE_API_KEY=lgk-... \
OPENAI_ROUTE=<路由名> \
ANTHROPIC_ROUTE=<路由名> \
  /tmp/lg-venv/bin/python scripts/compat/sdk_smoke.py
```
