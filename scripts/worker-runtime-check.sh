#!/usr/bin/env bash
# Builds the production Worker (vite build -> .output/server, what Workers Builds deploys) and
# evaluates it in the Cloudflare Workers runtime (workerd via Miniflare). See
# scripts/worker-runtime-check.mjs for the checks.
#
# Miniflare (with its pinned workerd) is installed into a cache directory outside the repository,
# never into package.json. Nothing here reads .env files or talks to a hosted service.
#
# Usage: scripts/worker-runtime-check.sh [--no-build] [--packet file.pdf] [--ranges 1-1,4-5]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
miniflare_version="4.20260730.0"
cache="${MEDSPEND_MINIFLARE_CACHE:-${TMPDIR:-/tmp}/medspend-miniflare-$miniflare_version}"

build=1
pass=()
for arg in "$@"; do
  if [ "$arg" = "--no-build" ]; then build=0; else pass+=("$arg"); fi
done

if [ ! -f "$cache/node_modules/miniflare/package.json" ]; then
  mkdir -p "$cache"
  npm install --prefix "$cache" --no-save --no-audit --no-fund --silent "miniflare@$miniflare_version" >/dev/null
fi

cd "$root"
if [ "$build" = 1 ]; then
  # vite build regenerates src/routeTree.gen.ts; keep the committed one.
  cp src/routeTree.gen.ts "$cache/routeTree.gen.ts.keep"
  trap 'cp "$cache/routeTree.gen.ts.keep" "$root/src/routeTree.gen.ts"' EXIT
  npx vite build >/dev/null
fi

MEDSPEND_MINIFLARE="$cache/node_modules/miniflare" node scripts/worker-runtime-check.mjs "${pass[@]+"${pass[@]}"}"
