#!/usr/bin/env bash
# Runs tests/phase7b2-count-history-integration.test.ts against a disposable local stack
# (Postgres + PostgREST) with every migration applied, including Phase 7B.2: real signed
# JWTs for an owner, an admin, a staff member, a former member, another organization's
# owner and admin, a non-member and anon, through the same API the application uses.
#
# PostgREST runs with PGRST_DB_MAX_ROWS=1000, like a hosted project's default API row cap,
# and the fixture holds more than 1000 count sessions in one organization and a 1000-line
# count, so any read that silently depended on getting everything in one response would
# fail.
#
# Nothing here reads .env files or talks to a hosted project. Containers listen on 127.0.0.1
# only and are removed when the script exits.
#
# Usage: supabase/tests/run_phase7b2_count_history_integration.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
db_container="medspend_7b2_integration_db_$$"
rest_container="medspend_7b2_integration_rest_$$"
db_port="${MEDSPEND_7B2_INTEGRATION_DB_PORT:-55535}"
rest_port="${MEDSPEND_7B2_INTEGRATION_REST_PORT:-55536}"
jwt_secret="local-test-only-jwt-secret-not-used-anywhere-else"
export PGPASSWORD=postgres PGHOST=127.0.0.1 PGPORT="$db_port" PGOPTIONS="-c client_min_messages=warning"

cleanup() { docker rm -f "$rest_container" "$db_container" >/dev/null 2>&1 || true; }
trap cleanup EXIT

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
  psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f "$migration" >/dev/null
done
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f "$root/supabase/tests/integration/phase7b2_count_history_fixture.sql" >/dev/null
docker run -d --name "$rest_container" --network "container:$db_container" \
  -e PGRST_DB_URI="postgres://authenticator:local-test-only@127.0.0.1:5432/postgres" \
  -e PGRST_DB_SCHEMAS=public -e PGRST_DB_ANON_ROLE=anon \
  -e PGRST_JWT_SECRET="$jwt_secret" -e PGRST_SERVER_PORT=3000 \
  -e PGRST_DB_MAX_ROWS=1000 \
  public.ecr.aws/supabase/postgrest:v14.15 >/dev/null
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$rest_port/" >/dev/null 2>&1; then break; fi
  sleep 1
done
(cd "$root" && MEDSPEND_ITEST_REST_URL="http://127.0.0.1:$rest_port" MEDSPEND_ITEST_JWT_SECRET="$jwt_secret" \
  node --test tests/phase7b2-count-history-integration.test.ts)
echo "run_phase7b2_count_history_integration: passed"
