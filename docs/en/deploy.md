# Single-host deployment (systemd)

English | [简体中文](../deploy.md)

## Build

The build machine needs: Erlang/OTP ≥ 27, rebar3, CMake, a C++23 compiler, `libicu-dev`, Node.js and git.

```sh
scripts/release.sh
# Output: _build/prod/rel/litegate/litegate-1.2.1.tar.gz (includes ERTS; Erlang need not be installed on the target)
```

The target machine must match the build machine's CPU architecture, glibc and libicu major version (the release contains native code for the bitcask NIF and ERTS),
and needs the runtime libraries installed: `libicu`, `libstdc++`, `openssl`, `ca-certificates` (system CA certificates are required to reach HTTPS upstreams).

## Installation

```sh
sudo useradd --system --home-dir /var/lib/litegate --shell /usr/sbin/nologin litegate
sudo mkdir -p /opt/litegate /etc/litegate
sudo tar -xzf litegate-1.2.1.tar.gz -C /opt/litegate

sudo cp deploy/litegate.env.example /etc/litegate/litegate.env
sudo chmod 600 /etc/litegate/litegate.env
# Edit /etc/litegate/litegate.env; setting LITEGATE_ENCRYPTION_KEY is recommended (openssl rand -base64 32)

sudo cp deploy/litegate.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now litegate
```

### Deployment modes

- **Local trial**: keep the default `LITEGATE_HTTP_BIND=127.0.0.1`, allowing access from this machine only. You can try it out without login first:
  open `http://127.0.0.1:4000/console` and finish the setup.
- **Internal service**: set `LITEGATE_HTTP_BIND` to the host's internal address, or temporarily to `0.0.0.0` with a firewall allowing only
  trusted subnets. Before exposing it beyond loopback, create an administrator on the "Users" page, then set the `console_auth` runtime parameter to true.
- **Public service**: login must be enabled with a strong initial password; prefer terminating TLS at a reverse proxy and restricting the sources that can reach `/console` and `/api`.
  Inside a container keep `LITEGATE_HTTP_BIND=0.0.0.0`, and let host port mapping, the firewall or the reverse proxy decide what is exposed.

## Operations

| Task | Command |
|---|---|
| Status / logs | `systemctl status litegate`, `journalctl -u litegate -f` |
| Attach to the running node | `sudo -u litegate env HOME=/var/lib/litegate ERL_EPMD_ADDRESS=127.0.0.1 /opt/litegate/bin/litegate remote_console` |
| Health check | `curl http://localhost:4000/health` |
| Metrics | `curl http://localhost:4000/metrics` (Bearer required when `metrics_token` is set) |

### Shutdown and resource limits

- On SIGTERM the listener is suspended first, and in-flight requests get up to `shutdown_drain_ms` (default 20s) to finish, during which HTTP/1.1 responses carry
  `connection: close`; then the listener is closed and storage does a final flush. systemd's `TimeoutStopSec` and compose's
  `stop_grace_period` must be at least 60s (already configured in `deploy/litegate.service` and `docker-compose.yml`).
- The file descriptor limit is 65536 (systemd `LimitNOFILE`, compose `ulimits.nofile`), matching `+Q 65536` in vm.args.
- mnesia runs as permanent: if mnesia exits on its own, the whole node exits and is restarted by systemd / docker;
  while mnesia is not running, `/health` returns 503.

## Backups

All state lives in `/var/lib/litegate`: `mnesia/` (configuration), `store/` (logs, usage, search), `secret.key` (the master key when
`LITEGATE_ENCRYPTION_KEY` is not set; if lost, stored upstream keys cannot be decrypted) and `.erlang.cookie`. Stop the service and copy the whole directory.

## Upgrading

```sh
sudo systemctl stop litegate
sudo rm -rf /opt/litegate && sudo mkdir /opt/litegate
sudo tar -xzf litegate-<new-version>.tar.gz -C /opt/litegate
sudo systemctl start litegate
```

mnesia schema upgrades run automatically at startup (`lg_schema`); the data directory needs no changes. Before upgrading, a backup is written automatically to
`<data_dir>/mnesia-backup-v<N>-<ts>.bup` (only once per version). Upgrade progress is recorded per table, so after a crash midway a restart picks up and finishes the job.

Derived storage data (hourly usage totals and cost breakdowns, the error log index, response cache / Responses expiry indexes) is backfilled automatically by the janitor
in the background after upgrading: it starts about 10 seconds after startup, recomputes historical usage hour by hour, decodes logs to fill the error index and scans the cache to fill the expiry index;
it can be interrupted and resumed, and may take several minutes on large datasets. Until backfill completes, the overview, `errors_only` queries and budget rebuilds use the original paths, with identical results.
Existing key and value formats are unchanged, so you can downgrade directly to the previous version (the new derived data is ignored); upgrading again after a downgrade automatically fills in data written during the downgrade.

### Upgrading to Bitcask 12

When upgrading from LiteGate `1.1.1` to a version that includes this change, the storage engine moves from Bitcask `6.6.0` to `12.0.1`. KV-only casks (logs, conversations, usage,
cache, etc.) work as is; only the full-text search derived index in `store/search` cannot be carried over past Bitcask `8.1.0`. After stopping the service,
move the search BM25 / checkpoint derived files out of the data directory as a backup; on startup they are rebuilt automatically from the retained raw search documents:

```sh
sudo systemctl stop litegate
backup=/var/lib/litegate/search-index-pre-12
sudo install -d -m 700 "$backup"
root=/var/lib/litegate/store/search
for name in bm25.ckpt bm25.ckpt.prev docmap.ckpt docmap.ckpt.prev index.manifest field.schema bm25_segments; do
    if [ -e "$root/$name" ]; then
        sudo mv "$root/$name" "$backup"/
    fi
done
sudo systemctl start litegate
```

Do not move or delete `*.bitcask.data`, `bitcask.meta`, `kv.oki.*` or the write lock file; they are the raw search documents,
the analyzer configuration and the KV index respectively. The rebuild touches only `store/search` and does not affect log or usage data; the first startup may take extra
CPU / time to rebuild BM25. If some derived files do not exist, just skip them. Delete the backup directory once search works correctly on the new version.

## Security notes

- The console requires no login by default (`console_auth = false`): anyone who can reach the HTTP port can manage upstream keys, routes and API keys.
  The service binds only `127.0.0.1` by default; when bound to a non-loopback address without login enabled, a security warning appears in the startup log and at the top of the console.
  If the port is exposed, enable login (first create an administrator on the "Users" page, then set the `console_auth` runtime parameter to true),
  or use a firewall / reverse proxy to restrict the sources that can reach `/console` and `/api`.
- The node name is fixed at `litegate@127.0.0.1` (mnesia data is bound to the node name, so hostname changes have no effect; `rebar3 shell` uses the same node name,
  and eunit uses `litegate_test@127.0.0.1`); the Erlang distribution port and epmd listen only on localhost, and the cookie is generated automatically at `$HOME/.erlang.cookie`.
- Opening an existing data directory under a different node name refuses to start (`node_name_mismatch`) and does not rewrite any data. If you really need to rename, stop the service and run:
  `erl -noshell -pa /opt/litegate/lib/*/ebin -name <new-name> -mnesia dir '"<data-dir>/mnesia"' -eval "ok = lg_schema:rename_node('<old-name>'), halt()."`;
  the original directory is kept as `mnesia.pre-rename-<timestamp>` and can be deleted once everything checks out.

## Multi-instance deployment

All limits and state are currently **node-local** (in a single node's memory); when scaling out horizontally, the global quota ≈ N × the configured value.

### Per-node state

| State | Module | Storage | Scaling behavior |
|---|---|---|---|
| Inbound RPM/TPM/concurrency | `lg_limiter` | ETS | Counted independently per node; global ≈ N × configured value |
| Upstream concurrency gate | `lg_conc` | ETS | Queued independently per node; actual upstream concurrency ≈ N × max_concurrency |
| Budget counters | `lg_budget` | ETS (in-memory accumulation) | Accumulated independently per node; reset on restart |
| Cooldown table | `lg_cooldown` | ETS | Independent per node (an upstream cooling down on one node does not affect others) |
| Session stickiness | `lg_affinity` | ETS | Independent per node (stickiness breaks if the load balancer has no affinity) |
| Outbound throttle Cap | `lg_out_rate` | ETS | Learned independently per node; the upstream actually sees ≈ N × Cap |
| Response cache | `lg_cache` | bitcask | Separate directory per node, not shared |
| Login rate limiting | `lg_login_guard` | ETS | Independent per node |
| Console sessions | `lg_session` | mnesia | Can be cluster-synced (mnesia config table); tokens are per node |

### Scaling configuration

For an N-instance deployment, configure each node's inbound rate limits at 1/N (otherwise the upstream actually sees N × the original value);
divide the upstream `max_concurrency` by N likewise. The outbound throttle Cap is learned independently per node and needs no manual scaling.

### Data directory

The bitcask `data_dir` **cannot be shared between nodes** (each instance needs its own directory on local disk).
mnesia config tables (routes, credentials, API keys, etc.) can be cluster-synced via `mnesia:change_config(+extra_db_nodes)`.

### Load balancer considerations

- Upstream session stickiness relies on the session ID between the client and the gateway (`X-LiteGate-Session`, etc.),
  so the front load balancer must apply session affinity on this header, otherwise stickiness breaks across nodes.
- WebSocket / SSE long-lived connections require the load balancer to support long connection timeouts (greater than `upstream_timeout_ms`).

### Global rate limiting (roadmap)

Cross-node global counting is on the roadmap (it needs an external counter backend such as Redis) and is not promised in the current version.
