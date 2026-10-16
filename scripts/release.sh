#!/usr/bin/env bash
# 构建生产发布包：前端 → rebar3 prod release（含 ERTS）→ tar.gz
# 产物：_build/prod/rel/litegate/litegate-<版本>.tar.gz
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> 构建控制台前端"
(cd web && npm ci && npm run build)

echo "==> 构建 release"
rebar3 as prod tar

ls -1 _build/prod/rel/litegate/*.tar.gz
