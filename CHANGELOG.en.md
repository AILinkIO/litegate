# Changelog

English | [简体中文](CHANGELOG.md)

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow Semantic Versioning.
The release version in `rebar.config` is authoritative; the console sidebar and `GET /api/version` show the same version and git commit.

## 1.3.2 — 2026-11-26

### Added

- **Console UI i18n**: the console is available in Chinese and English. Switch languages from the button in the top bar or on
  the login page; the choice is stored in the browser and defaults to the browser language. The request decision narrative and
  the API docs page follow the UI language (sent to the backend as `Accept-Language`).
- **Alert notification language**: new setting `alert_language` (`zh` | `en`, default `zh`) selects the language of alert
  notification titles and bodies, independent of the UI language. It is a drop-down on the Settings page and applies to new
  notifications immediately.
- **English documentation**: `README.en.md`, `CHANGELOG.en.md` and `docs/en/`, with a language switch at the top of every page.

### Fixed

- **`POST /api/otlp/test-metric` missing from the API docs page**: its tag ("链路导出") was not declared at the top level of
  openapi.json, and the console only renders declared tags. It now belongs to "Settings & storage" (alongside
  `POST /api/otlp/test`), and a test checks that every tag is declared.

## 1.3.1 — 2026-11-26

### Fixed

- **Codex goal sessions kept failing with 400 through the Responses → Chat conversion**: Codex's internal context outputs (such as
  `agent.goal_objective`) use a `function_call_output` without a `call_id`, which the old converter rejected as
  `Unsupported by target protocol`. They are now converted into a user context message wrapped in a `<context_tool_output>` tag;
  normal tool results that carry a `call_id` behave as before. Regression tests are in `lg_conv_responses_tests`.

## 1.3.0 — 2026-11-25

### Changed

- **Storage engine**: Bitcask `13.1.2` → `13.2.0` (MINOR). Upstream only touched the graph layer in this release (graph storage layout 2:
  block directories of large groups moved out into a B+ tree, and new graph stores default to layout 2). This project uses only the KV and
  search interfaces, not the graph layer; the KV and search interfaces, the NIF, the embedded libbitcask (still 13.1.2) and the on-disk format
  are all unchanged, so existing data is used as is and no adaptation code is needed.
- If your machine already fetched dependencies at 13.1.2, run `rebar3 upgrade bitcask` after changing the tag (or `rebar3 unlock bitcask` and
  delete `_build/default/lib/bitcask`) before compiling.

### Fixed

- **Response bodies were cut off after 15 seconds when the upstream replied with `Connection: close`**, failing with
  `Upstream request failed: {closed,normal}` (502). After receiving response headers with `connection: close`, gun enters the closing state
  and closes the connection normally once the default 15-second `closing_timeout` expires, taking down any stream still receiving data
  (LLM SSE streams, slow non-streaming bodies). Upstream connections now set `closing_timeout` to `infinity`, so request duration is bounded only
  by the gateway's own tiered timeouts (`upstream_timeout_ms` / `stream_idle_timeout_ms` / `stream_max_ms`). Regression test:
  `lg_http_pool_tests:connection_close_stream_outlives_closing_timeout` (16-second pause between two frames).

## 1.2.2 — 2026-11-25

### Changed

- **Storage engine**: Bitcask `13.1.1` → `13.1.2` (PATCH). Upstream only bumped the embedded libbitcask from 13.1.1 to 13.1.2;
  the library sources, Erlang/NIF sources, C API and on-disk format are unchanged on both sides, so existing data is used as is and no
  adaptation code is needed.
- If your machine already fetched dependencies at 13.1.1, run `rebar3 upgrade bitcask` after changing the tag (or `rebar3 unlock bitcask` and
  delete `_build/default/lib/bitcask`) before compiling; rebar3 does not re-fetch an existing checkout on its own.

## 1.2.1 — 2026-11-24

### Changed

- **Storage engine**: Bitcask upgraded from `12.0.1` to `13.1.1`. The on-disk format is unchanged; KV data and the `store/search` index are
  used as is without rebuilding; the NIF must be recompiled. Following upstream's umbrella layout, the dependency is now declared as
  `{bitcask, {git_subdir, "https://github.com/DavidAlphaFox/bitcask.git", {tag, "13.1.1"}, "apps/bitcask"}}`
  (rebar3 3.14+; fetching uses a sparse checkout, so the build machine needs git 2.25+).
- **Do not stop at 13.1.0**: that tag does not build as a `git_subdir` dependency. `apps/bitcask/third_party` is a symlink to the repository
  root's `third_party/`, which dangles in a sparse checkout containing only `apps/bitcask`, and the old hook initialized the submodule at
  `apps/bitcask/third_party/libbitcask`, so the NIF failed to build (`pathspec ... did not match`).
  13.1.1 only fixes that hook (it resolves the submodule by physical path and adds `/third_party/` to the sparse set when the link dangles);
  the Erlang/NIF sources, C API and on-disk format are identical to 13.1.0, so no adaptation code is needed.
- If your machine fetched dependencies at 13.1.0: rebar3 does not re-fetch an existing checkout after the tag changes, so run
  `rebar3 unlock bitcask` and delete `_build/default/lib/bitcask` before `rebar3 compile`.
- Upstream behavior changes in this range do not affect this project: `range` / `range_fold` now read a snapshot taken at the start
  (the cleanup task deleting while scanning, migration paging and hourly aggregation do not rely on seeing their own writes mid-iteration).
- Fixed along with upstream: deleting an existing key inside an atomic batch and then reopening would make 12.0.x truncate the data file
  (losing the delete and every later write); cleanup tasks delete many keys, and that risk is gone after the upgrade.
- **Container image**: all three build stages now use Debian trixie (glibc 2.41) as the base image; the frontend moves from `node:22-bookworm-slim`
  to `node:24-trixie-slim` (Vite 8 builds without warnings; the two Vite notices also appear under Node 22 and were not introduced here).

## 1.2.0 — 2026-11-20

### Fixed

- **MiniMax Responses tool calls**: OpenAI orders parallel tool calls as "all calls → all outputs", while
  MiniMax requires each result to immediately follow its call, otherwise it returns 2013
  "invalid params, tool call result does not follow tool call". Before passing the request through, results are moved behind their
  matching call by `call_id`, and orphan results without a matching call are dropped.

### Changed

- **Storage engine**: Bitcask upgraded from `6.6.0` to `12.0.1`. KV data and the raw log / configuration formats need no migration;
  the NIF and native libraries must be recompiled (the release package already includes them). Past `8.1.0`, old search checkpoints and
  sealed BM25 indexes cannot be carried over losslessly, so rebuild the `store/search` index before upgrading as described in the
  deployment docs. The raw search documents are kept, so historical logs remain searchable after the rebuild.

## 1.1.1 — 2026-10-30

P0 regression fixes, P1 stability hardening and P2 performance work from the second review round ([D05](designs/D05-regressions-stability-perf.md), T16–T33),
plus a fix for the collapsed console sidebar.

### Fixed

- **Wildcard routes returned 404 after restart**: the wildcard prefix cache is now owned by the long-lived `lg_route_cache` process and built at startup,
  instead of being destroyed when the first request process exits; rebuilds insert before deleting, leaving no gap; a name exactly equal to a prefix (such as `or/`)
  once again falls through to a shorter wildcard (since 1.1.0 it was wrongly matched with an empty remainder).
- **Outbound adaptive rate limiting**: sweeps no longer clear every rate window each minute; updating a credential correctly clears its learned state;
  the Cap on the first 429 is measured rate × `out_rate_factor` (1.1.0 always used `out_rate_min_rpm`);
  a wave of concurrent 429s lowers the Cap only once; a 429 with Retry-After also establishes a Cap; when a cap is in place, admission reserves capacity immediately,
  so queued requests are not all released together when the window rolls over; the cap lifts automatically after 4×`out_rate_recovery_ms` without a 429;
  learned state not updated for 24h is reclaimed; remaining fallback candidates are kept after a successful queue wait.
- **Configuration cache**: runtime parameters take effect immediately after importing / restoring configuration (previously a restart was needed); fixed stale values
  being written back to the cache under concurrent reads and writes; the cache now starts and stops with lg_core, and `sys.config` application env is no longer cached.
- **Cooldown table sweep never ran**: `lg_cooldown` now schedules the first sweep at startup.
- **realtime (`/v1/live`)**: upstream disconnects are recognized using the gun 2.x message format and end the session (previously the session hung);
  upstream WebSocket connections verify the TLS certificate and hostname and send SNI.
- **OTLP exporter crash**: when the queue crossed the 50% byte threshold and request bodies were stripped, a miscount crashed the process;
  repeated crashes made the lg_router application exit and the node stop.

### Stability

- **Client disconnect detection**: when the client disconnects while queued, waiting for a full retry round, waiting for upstream response headers, or during a
  non-streaming request, the upstream request is cancelled within about 1s, the concurrency slot is released and fallback stops; the request log records 499
  (`client_closed`), and usage already incurred is still billed; non-streaming requests no longer lose their log and budget accounting on disconnect.
  New metric `litegate_client_closed_total`.
- **Storage write backpressure and disk write errors**: the writer's mailbox moved off-heap and degrades in tiers by backlog (`store_queue_soft` / `store_queue_hard`,
  counted by `litegate_store_degraded_total`), and the search index moved to its own process; disk write errors are counted by `litegate_store_write_errors_total`
  and make `/health` report degraded (previously they were silently lost); a failed write or writer crash no longer double-counts usage / sessions; cask handles are
  now held by `lg_store_handles`, so the response cache and Responses reads no longer return 500 while the writer restarts.
- **Concurrency queue and rate-limit slots**: clients that disconnect while queued are removed from the queue immediately and no longer fill up `queue_limit`; when the
  concurrency control process restarts, queued requests return immediately; a busy or unavailable process is treated as busy instead of crashing; rate-limit
  concurrency slots return only what is actually held, so being killed at the moment of acquiring a slot no longer leaks it.
- **Deduplicated quota / balance refresh**: at most one query per credential is in flight, and queries run in a separate worker, so refresh messages no longer pile up
  under high QPS; the console's "Refresh now" returns the current state on timeout (with a `refreshing` flag) instead of an error.
- **Tiered streaming timeouts and limits (behavior change)**: the idle timeout between chunks after the first byte **changes from reusing `upstream_timeout_ms` (300s) to
  `stream_idle_timeout_ms`, default 120s**; a new total stream duration limit `stream_max_ms` (default 30 minutes); non-streaming response bodies
  are now received with a limit (`upstream_max_body_bytes`, default 64MB, with a deadline measured from when the request is sent), and a single SSE event is capped at
  `sse_max_event_bytes` (default 8MB). New metric `litegate_upstream_timeouts_total{phase}`.
- **Runtime and deployment**: mnesia now starts as permanent, and `/health` returns 503 when mnesia is not running; on shutdown the listener is suspended and in-flight
  requests are allowed to finish (`shutdown_drain_ms`); new `http_max_connections`; compose adds `stop_grace_period: 60s` and nofile 65536;
  vm.args drops the ineffective `+K` / `+A` and adds `+sbwt none +sbwtdcpu none +sbwtdio none` and `+Q 65536`.
- **Schema migrations**: migrations are re-entrant (progress recorded per table, already converted records recognized), and each version is backed up only once; a node
  name that does not match the data directory now refuses to start instead of silently rewriting logs; `lg_schema:rename_node/1` was rewritten into a working offline rename;
  the `rebar3 shell` node name is now `litegate@127.0.0.1`, matching the release.
- **Intent classifier circuit breaker**: after 3 consecutive failures the classifier is tripped for 30 seconds (`litegate_classifier_skipped_total`), and identical concurrent
  classifications are coalesced; a classification timeout no longer loses the log and cost.
- **Alert debouncing**: rules are cached, so the hot path costs nothing when no rules exist; upstream_down recovery requires `alert_recover_ms` of continuous health and is subject to the
  `alert_silence_ms` silence period, so flapping no longer floods notifications; the send queue is capped at 1000 entries (`litegate_alert_dropped_total`);
  consecutive failure counters are cleared automatically after 24h without updates.

### Performance

- **Incremental SSE parsing**: event delimiters are searched only in newly arrived chunks, and `\r` normalization applies to a single event; parsing an MB-scale event
  arriving in 2000 chunks dropped from about 200ms to about 1ms, with time roughly linear in the number of chunks.
- **Repetition detection**: only new text is processed, and partial lines are truncated to 1KB; memory allocation for a single 50KB line of output dropped from about 54MB to about 2.5MB.
- **Streaming text accumulation**: deltas are copied instead of pinning the upstream's raw chunks; process binary references for a 100k-token stream dropped from about 3.4MB to under 20KB.
- **Single decode per streaming event**: Responses conversion, think splitting and structured output share the same decoded event, cutting decodes per event from up to 3–4 to 1.
- **Upstream backpressure and connection pool**: streaming upstreams enable gun flow control (window of 8 messages), so with slow clients backpressure propagates over TCP to the
  upstream and the handler's mailbox no longer grows without bound; the pool process no longer calls gun when connections are returned, and over-limit / expired connections are closed
  asynchronously; per-host idle limit `upstream_pool_idle_max` (default 128, previously a fixed 32); new `litegate_upstream_connections_total{result}`.
- **Storage queries**: `errors_only` uses the error index (first page over 50k logs dropped from about 125ms to 0.5ms); the overview and budget startup read only the hourly total /
  cost breakdown rows (decoded rows for a 15-day overview dropped from 14400 to 360); the alert list reads only the most recent time window.
- **janitor**: deletes are batched at ≤1000 keys and merged across index prefixes, and deleting non-usage data no longer flushes usage; the response cache and Responses records
  are cleaned in batches by time range over the expiry index, instead of decoding the whole table and deleting in one big batch.
- **rotate strategy**: session counts are maintained per target, so a single selection with 100k sessions dropped from about 60ms to about 1µs.
- Outbound rate-limit decisions reuse the credential record from the attempt plan; built-in middleware (including remote) runs inside the request process and no longer copies the request body
  (plugins still run in a separate process and can be interrupted on timeout).

### Storage format (backward compatible)

- Only derived data is added: `0xFF`-prefixed rows in the usage cask (hourly totals, cost breakdown, backfill markers), the `$e` error index in the idx cask, and
  expiry indexes in the cache / responses casks; existing key and value formats are unchanged. After upgrading, the janitor backfills automatically in the background, and queries use the
  original paths until backfill completes, with identical results. You can downgrade directly to the previous version; upgrading again after a downgrade automatically fills in data written
  during the downgrade. See [Deployment](docs/en/deploy.md#upgrading).

### Fixed (continued)

- When discarding an upstream connection, it is closed first and its mailbox is cleaned per connection (including `gun_down`) only after the connection process exits, so long-lived processes
  such as lg_otlp and lg_notify no longer accumulate stale messages.
- After a reused connection fails, the request is resent only when it can be determined that the upstream did not process it (the gun process has exited, or the connection dropped within 50ms
  of sending), avoiding duplicate POSTs and double billing.
- Entries in the health page's "Recent results" and the live view's "Recent route narrative" that have not been updated for more than 24 hours are now cleaned up.
- Configuration backup: an unwritable directory or a failed write or rename now returns an error instead of crashing the process; file names have millisecond precision, so multiple backups
  within the same second no longer overwrite each other.
- Configuration export reads all tables in a read-only transaction (a point-in-time snapshot with respect to transactional writes).
- **Duplicate replies from the admin API**: resources handled by `lg_api_admin` (credentials, routes, runtime parameters, etc.) still fell through to `lg_api`'s 404 fallback after replying and
  replied a second time; cowboy crashed the connection process over the duplicate reply, failing subsequent requests on the keep-alive connection. Matching now continues only on a miss.
- Model catalog: changing `catalog_sync_interval_ms` at runtime takes effect on the next round (including enabling it from 0); a network sync that would delete 30% or more of the existing
  models is aborted and recorded as a sync failure (triggering the `catalog_sync_failed` alert); manual imports are not subject to this limit.
- **User entry at the bottom of the sidebar**: with the sidebar collapsed, the avatar icon was squashed by flex; added `shrink-0` to keep it a full rounded square.
- **Sidebar version overflow**: in the collapsed state the version string (`v<version> · <commit>`) wrapped and overflowed the sidebar; it is no longer rendered when collapsed.

## 1.1.0 — 2026-10-21

Memory safety and hot-path performance work, outbound adaptive rate limiting, console login with tighter secure defaults, and Docker Compose deployment.

### Added

- **Outbound adaptive rate limiting** (applies uniformly to all providers and models): records outbound QPM over the last minute per `{credential, model}`;
  when the upstream returns 429, AIMD feedback lowers the send rate — multiplied by `out_rate_factor` on the first offense, halved on repeats, never below
  `out_rate_min_rpm` — and it recovers automatically per `out_rate_recovery_ms` once the window stops hitting the wall.
  Parameters: `out_rate_enabled`, `out_rate_factor`, `out_rate_min_rpm`, `out_rate_recovery_ms`.
- **Throttle wait policy**: `out_rate_wait = queue` (default; wait for the rate window to roll over, then proceed) or `fail` (return 429 immediately);
  credential options gain a static limit `max_rpm`, and the effective limit is the smaller of the learned Cap and `max_rpm`.
- **Outbound rate visibility**: the console's "Upstream health" page shows each credential's outbound RPM along with cooldown and throttle state,
  the "Dashboard" gains a 429 throttling card, and Prometheus exposes `litegate_out_qpm` and `litegate_out_throttled_total`.
- **`stream: true` compatibility for non-chat endpoints**: non-streaming endpoints such as embeddings and rerank ignore the stream flag and respond synchronously,
  with the request log recording `stream_ignored`, instead of silently hanging.
- **TLS listener**: `tls_enabled`, `tls_port`, `tls_cert_file`, `tls_key_file`; HTTPS and plaintext listeners can be enabled at the same time.
- **"Restart required" labels**: parameters read only at startup (data directory, listen address and port, maximum request body, TLS settings)
  are marked as requiring a restart on the console's runtime parameters page.
- **Console version display**: the bottom of the sidebar shows `v<version> · <commit>`, `GET /api/version` returns the version and commit,
  and Docker and release builds inject it via `GIT_SHA`.
- **Docker Compose deployment**: new `docker-compose.yml` and `deploy/litegate.env` template,
  image tag defaults to `litegate:1.1.0`, and state is fixed at `/data` inside the container.
- **Multi-instance deployment docs**: `docs/deploy.md` explains that quotas, concurrency, cooldowns, stickiness and throttle Caps are all node-local, and how to scale them.

### Changed

- **Breaking: non-loopback binds refuse to start by default**. When HTTP binds a non-loopback address, `console_auth = false`
  and nothing explicitly allows it, the gateway fails to start with migration guidance: enable console login, bind to a loopback address,
  or set `allow_insecure_bind = true` to explicitly accept the risk. See [Configuration](docs/en/configuration.md).
- **OTLP queue capped by bytes**: new `otlp_queue_max_bytes` (default 64MB); when the queue reaches the threshold, request bodies are stripped first,
  and beyond the limit the oldest entries are dropped, so traces no longer pile up in memory indefinitely when the exporter endpoint is unreachable.
- Cooldown (`lg_cooldown`) now handles only failure backoff, and rate limits are left to outbound throttling; an upstream 429 no longer merely lowers the weight.
- Version unified to 1.1.0 (release, every `*.app.src`, OpenAPI and the console display agree).

### Performance

- Two-level cache for `lg_config:get/1` (defaults in persistent_term plus a resolved-value cache), so hot-path reads touch Mnesia zero times.
- `lg_metrics` rendering and snapshots switched to Rows → RowMap, eliminating O(n²) scans over label combinations.
- Wildcard route matches are precompiled into an ETS cache and fully rebuilt after route writes.
- `lg_store` query flushes are split by scope (`logs` / `all`), so the two kinds of writes no longer block each other.
- Token estimation scans the binary code point by code point, eliminating the `characters_to_list` allocation for large strings.

### Fixed

- Periodic sweeps added for the `login_guard`, `cooldown`, `affinity` and `session` state tables, so long-running processes no longer grow monotonically.
- `mw_remote` dynamic atoms now use `binary_to_existing_atom`, preventing remote middleware configuration from polluting the atom table.

## 1.0.0 — 2026-10-16

Initial implementation (in-project version 0.1.0).

- LLM API gateway compatible with the OpenAI and Anthropic API formats, with streaming and non-streaming forwarding.
- Multi-credential routing, priority groups and failover, six same-priority strategies, route aliases and wildcard matching.
- Rule-based routing (rewrite, inject, block), session stickiness and upstream affinity.
- Quota control, budgets and rate limiting (inbound RPM/TPM/concurrency, upstream concurrency gate, plan quotas).
- Request logs, sessions, usage and billing statistics, Prometheus metrics, OTLP trace export and alerts.
- React admin console: model catalog, credentials, routes, API keys, integration guide, runtime parameters and users.
- systemd and Docker deployment scripts, Mnesia/Bitcask persistence and automatic configuration backups.
