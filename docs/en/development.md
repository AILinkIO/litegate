# Development

English | [简体中文](../development.md)

## Requirements

- Erlang/OTP 27 or later, rebar3
- CMake, a C++23 compiler and ICU headers, for building the Bitcask NIF
- Node.js, for building the console

## Build and run

```sh
rebar3 compile
cd web
npm install
npm run build
cd ..
rebar3 shell
```

The console build output goes to `apps/lg_web/priv/static`. Open `http://localhost:4000/console`.

Frontend development mode:

```sh
cd web
npm run dev
```

By default Vite proxies `/api` and `/v1` to `http://127.0.0.1:4000`; override this with `LITEGATE_URL`.

## Tests and checks

```sh
rebar3 eunit
rebar3 xref
rebar3 dialyzer
cd web
npm test
npm run lint
npm run build
```

The release script produces a self-contained release package that includes ERTS:

```sh
scripts/release.sh
```

## Project layout

| Path | Purpose |
|---|---|
| `apps/` | Erlang applications, one directory per subsystem |
| `web/` | React console |
| `docs/` | User, operations, architecture and development docs |
| `deploy/` | systemd and environment variable templates |
| `scripts/` | Release and compatibility test tooling |
| `examples/` | Middleware examples |

## Documentation conventions

Behavior changes must be reflected in the docs. Docs describe current behavior and its rationale, not implementation history or task status.
Add a new page only for a different audience or a standalone topic, and link it from `README.md`.
Docs and the changelog are maintained in both languages: when editing `docs/*.md`, `README.md` or `CHANGELOG.md`, update the matching file under `docs/en/`, `README.en.md` and `CHANGELOG.en.md` as well.

Console UI strings use the Chinese source text as the key: `t('原文')` / `tk('原文')`, with English translations in `web/src/i18n/en/*.ts`; `npm test` checks for unwrapped Chinese and missing translations (see the notes at the top of `web/src/i18n/index.ts`).
