# Configuration

English | [简体中文](../configuration.md)

## Configuration layers

Effective values are read in the following order of precedence:

1. Runtime parameters in Mnesia, editable from the console.
2. `LITEGATE_<parameter name>` environment variables.
3. `sys.config` application environment.
4. Defaults in code.

Only parameters declared in `lg_config` can be read or written, so a misspelled parameter never silently does nothing.

Resolved values from the runtime-parameter and environment-variable layers are cached in memory: console edits and configuration imports invalidate the corresponding
cache entries immediately, while environment variables are read only on first access and require a restart after changing.

## Core parameters

| Parameter | Environment variable | Default | Description |
|---|---|---|---|
| HTTP port | `LITEGATE_HTTP_PORT` | `4000` | Listening port for the gateway and console |
| HTTP bind address | `LITEGATE_HTTP_BIND` | `127.0.0.1` | Can be set to `0.0.0.0` in containers or behind a reverse proxy |
| Data directory | `LITEGATE_DATA_DIR` | `data` | Storage root for Mnesia and Bitcask |
| Console login | `LITEGATE_CONSOLE_AUTH` | `false` | Whether the console requires an account login |
| Initial admin password | `LITEGATE_ADMIN_PASSWORD` | Randomly generated | Used to create admin when login is enabled and no accounts exist |
| Encryption master key | `LITEGATE_ENCRYPTION_KEY` | `data/secret.key` | Base64-encoded 32-byte AES-GCM master key |

For the remaining parameters, their defaults, validation rules and descriptions, see the console's "Runtime parameters" page.

### Timeouts, limits and shutdown

| Parameter | Default | Description |
|---|---|---|
| `upstream_timeout_ms` | `300000` | Timeout waiting for upstream response headers / the first streaming chunk; for non-streaming responses, the body read has this deadline from when the request is sent |
| `stream_idle_timeout_ms` | `120000` | After the first streaming chunk, the stream ends if the gap between chunks exceeds this value (504, phase=idle); upstream ping comment frames count as data |
| `stream_max_ms` | `1800000` | Total stream duration limit (from stream start); once exceeded, the stream ends with an error frame even if the upstream is still sending (phase=total) |
| `upstream_max_body_bytes` | `67108864` | Limit on non-streaming upstream response bodies; once exceeded, reading stops, the connection is discarded and 502 is returned without fallback (phase=too_large) |
| `sse_max_event_bytes` | `8388608` | Buffer limit for a single unfinished SSE event; once exceeded, the upstream is aborted and the stream ends with an error frame (phase=too_large) |
| `upstream_pool_idle_max` | `128` | Maximum idle connections kept in the pool per upstream host (scheme + host + port); extra connections are closed asynchronously when returned; raise it under high peak concurrency to avoid re-handshaking on the next wave |
| `http_max_connections` | `16384` | Connection limit per listener (restart required) |
| `shutdown_drain_ms` | `20000` | Maximum time to wait for in-flight requests to finish on shutdown |
| `store_queue_soft` / `store_queue_hard` | `5000` / `50000` | Storage writer backlog thresholds for degradation: above soft, conversations, search documents and the response cache are dropped; above hard, only usage is kept |
| `alert_silence_ms` | `1800000` | Within the silence period the same event is notified only once; upstream_down is keyed by target + rule, and a repeat failure within the period sends neither an alert nor a recovery |
| `alert_recover_ms` | `60000` | A recovery notification is sent only after the upstream has gone this long without failing again |
| `alert_language` | `zh` | Language of alert notification titles and bodies: `zh` or `en`, independent of the console UI language |

The listener idle timeout is fixed at `upstream_timeout_ms + 60s` (sending data also resets it) and is not configurable on its own: idle keep-alive time between
HTTP/1.1 requests is governed by cowboy's `request_timeout` (5s), while HTTP/2 idle timing is per connection and must exceed the upstream timeout.

## Security

- By default only loopback is bound, which suits local use.
- Before exposing the gateway beyond localhost, create an administrator first and set `console_auth` to true.
- For public deployments, prefer terminating TLS at a reverse proxy and restricting the sources allowed to reach `/console` and `/api`.
- Prefer injecting `LITEGATE_ENCRYPTION_KEY` and `LITEGATE_BACKUP_PASSPHRASE` via environment variables,
  so these secrets never land in the database.
- If the encryption master key is lost, stored upstream credentials can no longer be decrypted.

## Data and backups

The data directory contains the Mnesia configuration, Bitcask runtime data, and the encryption key generated automatically when no master key is set in the environment.
For a full backup, stop the service first, then copy the whole directory.

Automatic configuration backups can be enabled in the console. Backups are written to the configured backup directory at a fixed interval, encrypted with a passphrase,
and rotated according to the number of copies to keep.

### Secure binding (1.1.0 breaking change)

With a non-loopback bind address (such as `0.0.0.0`) and `console_auth` set to `false`, the gateway **refuses to start**,
preventing the admin API (plaintext credentials, middleware configuration) from being exposed to the network without authentication.

Migration options (pick one):
1. Enable console login: set `LITEGATE_CONSOLE_AUTH=true`, and on first start create the administrator with `LITEGATE_ADMIN_PASSWORD`.
2. Bind to a loopback address: set `LITEGATE_HTTP_BIND=127.0.0.1` (with a reverse proxy / tunnel forwarding to the gateway).
3. Explicitly accept the risk: set `LITEGATE_ALLOW_INSECURE_BIND=true` (trusted, isolated networks only).

`/health`, `/metrics` (with token) and `/v1` (API key authentication) are not affected by this check; it only governs whether the admin plane can start.
