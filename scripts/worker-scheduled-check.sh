#!/usr/bin/env bash
# Phase 6C.3 Worker scheduled-handler check: builds the production Worker (vite build ->
# .output/server), boots a disposable Postgres + PostgREST with every migration and a small
# fixture, and fires the BUILT Worker's scheduled() in workerd (Miniflare) with fake/local
# bindings and a fake email sink. See scripts/worker-scheduled-check.mjs for the checks.
#
# Nothing here reads .env files, talks to a hosted project or contacts an email provider.
# Miniflare is installed into a cache directory outside the repository (as in
# scripts/worker-runtime-check.sh). Requires Docker.
#
# Usage: scripts/worker-scheduled-check.sh [--no-build]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
miniflare_version="4.20260730.0"
cache="${MEDSPEND_MINIFLARE_CACHE:-${TMPDIR:-/tmp}/medspend-miniflare-$miniflare_version}"
db_container="medspend_6c3_sched_db_$$"
rest_container="medspend_6c3_sched_rest_$$"
db_port="${MEDSPEND_SCHED_DB_PORT:-55915}"
rest_port="${MEDSPEND_SCHED_REST_PORT:-55916}"
jwt_secret="local-test-only-jwt-secret-not-used-anywhere-else"
export PGPASSWORD=postgres PGHOST=127.0.0.1 PGPORT="$db_port" PGOPTIONS="-c client_min_messages=warning"

build=1
[ "${1:-}" = "--no-build" ] && build=0

cleanup() { docker rm -f "$rest_container" "$db_container" >/dev/null 2>&1 || true; }
trap cleanup EXIT

if [ ! -f "$cache/node_modules/miniflare/package.json" ]; then
  mkdir -p "$cache"
  npm install --prefix "$cache" --no-save --no-audit --no-fund --silent "miniflare@$miniflare_version" >/dev/null
fi

cd "$root"
if [ "$build" = 1 ]; then
  # vite build regenerates src/routeTree.gen.ts; keep the committed one.
  cp src/routeTree.gen.ts "$cache/routeTree.gen.ts.keep"
  trap 'cp "$cache/routeTree.gen.ts.keep" "$root/src/routeTree.gen.ts"; cleanup' EXIT
  npx vite build >/dev/null
fi

docker run -d --name "$db_container" -e POSTGRES_PASSWORD=postgres \
  -p "127.0.0.1:$db_port:5432" -p "127.0.0.1:$rest_port:3000" \
  public.ecr.aws/supabase/postgres:17.6.1.167 >/dev/null
for _ in $(seq 1 60); do
  if psql -U supabase_admin -d postgres -Atc "select 1 from pg_roles where rolname = 'authenticator'" 2>/dev/null | grep -q 1; then break; fi
  sleep 2
done
sleep 5
psql -q -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -f supabase/tests/integration/local_stack_setup.sql >/dev/null
for migration in supabase/migrations/*.sql; do
  psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f "$migration" >/dev/null
done
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f supabase/tests/integration/phase6c3_notifications_fixture.sql >/dev/null
# Sending ON for the fixture organization (local only), digests off; one submission and one
# approval with an internal note waiting to be delivered.
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<'SQL'
UPDATE auth.users SET raw_user_meta_data = '{"full_name": "Runtime Staff"}' WHERE id = '6c3e0000-0000-4000-8000-000000000003';
UPDATE public.profiles SET full_name = 'Runtime Staff' WHERE id = '6c3e0000-0000-4000-8000-000000000003';
SELECT public.set_organization_notification_sending('6c3e0000-0000-4000-8000-000000000101', true);
UPDATE public.organization_notification_settings SET digest_enabled = false WHERE organization_id = '6c3e0000-0000-4000-8000-000000000101';
SELECT set_config('request.jwt.claim.sub', '6c3e0000-0000-4000-8000-000000000003', false);
SELECT set_config('phase6c3.request', public.submit_supply_request('6c3e0000-0000-4000-8000-000000000101', 'reorder', NULL, NULL, NULL,
  '[{"freeTextItem": "Runtime tape", "quantity": 2}]'::jsonb)::text, false);
SELECT set_config('request.jwt.claim.sub', '6c3e0000-0000-4000-8000-000000000001', false);
SELECT public.decide_supply_request('6c3e0000-0000-4000-8000-000000000101', current_setting('phase6c3.request')::uuid, 'approved',
  'Approved', 'RUNTIME-INTERNAL note', (SELECT updated_at FROM public.supply_requests WHERE id = current_setting('phase6c3.request')::uuid));
SQL

docker run -d --name "$rest_container" --network "container:$db_container" \
  -e PGRST_DB_URI="postgres://authenticator:local-test-only@127.0.0.1:5432/postgres" \
  -e PGRST_DB_SCHEMAS=public -e PGRST_DB_ANON_ROLE=anon \
  -e PGRST_JWT_SECRET="$jwt_secret" -e PGRST_SERVER_PORT=3000 \
  public.ecr.aws/supabase/postgrest:v14.15 >/dev/null
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$rest_port/" >/dev/null 2>&1; then break; fi
  sleep 1
done

MEDSPEND_MINIFLARE="$cache/node_modules/miniflare" MEDSPEND_REST_URL="http://127.0.0.1:$rest_port" \
MEDSPEND_JWT_SECRET="$jwt_secret" MEDSPEND_DB_PORT="$db_port" \
  node scripts/worker-scheduled-check.mjs
