# Integrations

English | [简体中文](../integrations.md)

## OpenAI-compatible clients

Point the client's base URL at the gateway and use a gateway API key:

```text
Base URL: http://localhost:4000/v1
API key:  lgk-...
```

Anthropic-compatible clients use the gateway's root URL — do not append `/v1` — and pass the gateway key in `x-api-key`.

## Claude Code

Set the following environment variables:

```sh
export ANTHROPIC_BASE_URL=http://127.0.0.1:4000
export ANTHROPIC_AUTH_TOKEN=lgk-...
unset ANTHROPIC_API_KEY
```

In the console, create a wildcard route named `claude-*`, or add route aliases for the model names Claude Code uses.
Route targets can use either Anthropic-protocol or OpenAI-protocol credentials; the gateway converts between protocols automatically.

Common optional settings:

| Environment variable | Purpose |
|---|---|
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | Route used by subagents and background tasks |
| `MAX_THINKING_TOKENS` | Enables thinking |

Give the API key a default tag such as `tool:claude-code` to track this client separately in usage and budgets.

## Codex CLI

Add a provider in `$CODEX_HOME/config.toml`:

```toml
model = "glm"
model_provider = "litegate"

[model_providers.litegate]
name = "LiteGate"
base_url = "http://127.0.0.1:4000/v1"
env_key = "LITEGATE_API_KEY"
wire_api = "responses"
```

Set `LITEGATE_API_KEY` before starting Codex. When the credential has `responses_api` enabled, Responses requests are passed through as is;
otherwise the gateway converts them to Chat Completions and maps reasoning content and tool data.
For MiniMax, Responses passthrough moves parallel tool-call results behind their corresponding calls and drops orphan results without a matching call.

## opencode

Configure LiteGate as an OpenAI-compatible provider. For OpenAI upstreams use OpenAI-compatible model entries;
for Anthropic upstreams use Anthropic model entries. Set the base URL to `http://127.0.0.1:4000/v1`
and use a gateway key as the API key.

## SDK smoke test

`scripts/compat/sdk_smoke.py` covers model listing, synchronous and streaming requests, tool calls, Responses, Messages and token counting
for both the OpenAI and Anthropic SDKs.

```sh
python3 -m venv /tmp/lg-venv
/tmp/lg-venv/bin/pip install openai anthropic
LITEGATE_URL=http://127.0.0.1:4000 \
LITEGATE_API_KEY=lgk-... \
OPENAI_ROUTE=<route-name> \
ANTHROPIC_ROUTE=<route-name> \
  /tmp/lg-venv/bin/python scripts/compat/sdk_smoke.py
```
