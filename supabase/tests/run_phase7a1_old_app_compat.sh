#!/usr/bin/env bash
# Runs tests/phase7a1-old-app-compat.test.ts twice against disposable local stacks (Postgres +
# PostgREST): first on a database migrated to main only (control), then on one with the Phase
# 7A.1 migration applied. Both runs replay the deployed application's exact inventory, posting,
# deletion and stocking calls; both must pass.
#
# Nothing here reads .env files or talks to a hosted project. Containers listen on 127.0.0.1
# only and are removed when the script exits.
#
# Usage: supabase/tests/run_phase7a1_old_app_compat.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
db_container="medspend_7a1_compat_db_$$"
rest_container="medspend_7a1_compat_rest_$$"
db_port="${MEDSPEND_7A1_COMPAT_DB_PORT:-55480}"
rest_port="${MEDSPEND_7A1_COMPAT_REST_PORT:-55481}"
jwt_secret="local-test-only-jwt-secret-not-used-anywhere-else"
target="20261021120000_phase7a1_location_aware_inventory.sql"
export PGPASSWORD=postgres PGHOST=127.0.0.1 PGPORT="$db_port" PGOPTIONS="-c client_min_messages=warning"

cleanup() { docker rm -f "$rest_container" "$db_container" >/dev/null 2>&1 || true; }
trap cleanup EXIT

run_stack() {
  local schema="$1"
  cleanup
  docker run -d --name "$db_container" -e POSTGRES_PASSWORD=postgres \
    -p "127.0.0.1:$db_port:5432" -p "127.0.0.1:$rest_port:3000" \
    public.ecr.aws/supabase/postgres:17.6.1.167 >/dev/null
  for _ in $(seq 1 60); do
    if psql -U supabase_admin -d postgres -Atc "select 1 from pg_roles where rolname = 'authenticator'" 2>/dev/null | grep -q 1; then break; fi
    sleep 2
  done
  sleep 5
  psql -q -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -f "$root/supabase/tests/integration/local_stack_setup.sql" >/dev/null
  for migration in "$root"/supabase/migrations/*.sql; do
    [[ "$(basename "$migration")" < "$target" ]] || continue
    psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f "$migration" >/dev/null
  done
  # Fixture history is written by main's own functions, before 7A.1, as in production.
  psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f "$root/supabase/tests/integration/phase7a1_backfill_fixture.sql" >/dev/null
  psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f "$root/supabase/tests/integration/phase7a1_old_app_compat_fixture.sql" >/dev/null
  if [ "$schema" = "7a1" ]; then
    psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f "$root/supabase/migrations/$target" >/dev/null
  fi
  docker run -d --name "$rest_container" --network "container:$db_container" \
    -e PGRST_DB_URI="postgres://authenticator:local-test-only@127.0.0.1:5432/postgres" \
    -e PGRST_DB_SCHEMAS=public -e PGRST_DB_ANON_ROLE=anon \
    -e PGRST_JWT_SECRET="$jwt_secret" -e PGRST_SERVER_PORT=3000 \
    public.ecr.aws/supabase/postgrest:v14.15 >/dev/null
  for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:$rest_port/" >/dev/null 2>&1; then break; fi
    sleep 1
  done
  (cd "$root" && MEDSPEND_ITEST_REST_URL="http://127.0.0.1:$rest_port" MEDSPEND_ITEST_JWT_SECRET="$jwt_secret" \
    MEDSPEND_7A1_COMPAT_SCHEMA="$schema" node --test tests/phase7a1-old-app-compat.test.ts)
}

echo "=== control: main schema"
run_stack main
echo "=== Phase 7A.1 applied"
run_stack 7a1
echo "run_phase7a1_old_app_compat: both runs passed"
