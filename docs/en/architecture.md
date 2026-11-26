# Architecture

English | [简体中文](../architecture.md)

## Overview

LiteGate is an LLM API gateway built on Erlang/OTP. It exposes OpenAI- and Anthropic-compatible APIs,
maps requests onto configurable routes and upstream credentials, and records usage, cost, logs and routing decisions.

The console is mounted at `/console`. The gateway API lives under `/v1` and the admin API under `/api`; health checks and metrics are
`/health` and `/metrics` respectively.

## Technology choices

| Area | Choice |
|---|---|
| Runtime | Erlang/OTP 27 or later |
| Metadata | Mnesia disc tables |
| Request data | Bitcask with a C++23 NIF |
| HTTP server | Cowboy |
| Upstream HTTP | Gun |
| Console | React, TypeScript, Tailwind CSS, shadcn/ui, ECharts, Vite |

## Applications

| Application | Responsibility |
|---|---|
| `lg_core` | Configuration layers, Mnesia table creation and migrations, encryption, metrics, shared utilities |
| `lg_catalog` | Model catalog sync, user overrides, protocol inference, pricing lookup |
| `lg_provider` | Connection pool, SSE parsing, OpenAI and Anthropic adapters, protocol conversion |
| `lg_router` | Authentication, route resolution, attempt ordering, fallback, quotas, alerts, middleware |
| `lg_store` | Request logs, conversations, session summaries, hourly usage and data retention |
| `lg_web` | Gateway routes, admin API, account authentication, console assets |

## Request flow

```text
Cowboy
  -> API key authentication
  -> route resolution and rule evaluation
  -> build the upstream attempt order
  -> protocol adaptation and any needed conversion
  -> Gun request to the upstream
  -> streaming or non-streaming response
  -> record usage, logs and traces
```

Route resolution is constrained both by the API key's route allowlist and by the route's own access control. Candidate targets are first grouped by priority,
then ordered within each group by its strategy. A retryable failure moves on to the next candidate; once the client has received response content, there is no further fallback.

## Data model

Mnesia stores configuration and metadata. User overrides are merged on top of the synced model catalog at read time. Upstream credentials store
encrypted keys. Routes reference credentials and upstream model names rather than copying model catalog data.

Bitcask stores high-volume runtime data:

| Directory | Contents |
|---|---|
| `logs` | Request summaries and routing details |
| `msgs` | Redacted request and response messages |
| `idx` | Query indexes by API key, route and user |
| `usage` | Hourly usage and cost rollups |
| `sessions` | Aggregated session state |

Writes are batched by a single writer. Reads flush the relevant casks first, so query results include requests that just finished.

## Console

The console is a React single-page app whose build output is served by `lg_web`. It includes configuration pages for credentials, routes, API keys, users,
middleware and runtime parameters; operational pages for requests, usage, sessions, live routing, upstream health and alerts;
and a Playground for testing conversations and protocol conversion.

Accounts are either administrators or regular users. Regular users can manage only their own API keys and see only their own requests and usage.
