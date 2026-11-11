#!/usr/bin/env bash
# Runs tests/phase6c3-request-notifications-integration.test.ts (Phase 6C.3 request
# notifications and digests) against a disposable local stack: a fresh Postgres container with
# every migration applied, plus PostgREST in front of it. The test submits and decides requests
# through the same RPCs the app's server functions call (supabase-js with signed user JWTs), and
# runs the real notification cycle (src/notifications/worker.ts + supabase-store.ts) with a
# locally signed service-role JWT and the in-memory fake email provider.
#
# Nothing here reads .env files, talks to a hosted project or contacts an email provider. Both
# containers listen on 127.0.0.1 only and are removed when the script exits.
#
# Requires Docker. Images:
#   public.ecr.aws/supabase/postgres:17.6.1.167
#   public.ecr.aws/supabase/postgrest:v14.15
#
# Usage: supabase/tests/run_phase6c3_notifications_integration.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
db_container="medspend_6c3_itest_db_$$"
rest_container="medspend_6c3_itest_rest_$$"
db_port="${MEDSPEND_ITEST_DB_PORT:-55905}"
rest_port="${MEDSPEND_ITEST_REST_PORT:-55906}"
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
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f "$root/supabase/tests/integration/phase6c3_notifications_fixture.sql" >/dev/null

docker run -d --name "$rest_container" --network "container:$db_container" \
  -e PGRST_DB_URI="postgres://authenticator:local-test-only@127.0.0.1:5432/postgres" \
  -e PGRST_DB_SCHEMAS=public -e PGRST_DB_ANON_ROLE=anon \
  -e PGRST_JWT_SECRET="$jwt_secret" -e PGRST_SERVER_PORT=3000 \
  public.ecr.aws/supabase/postgrest:v14.15 >/dev/null
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$rest_port/" >/dev/null 2>&1; then break; fi
  sleep 1
done

cd "$root"
MEDSPEND_ITEST_REST_URL="http://127.0.0.1:$rest_port" MEDSPEND_ITEST_JWT_SECRET="$jwt_secret" \
MEDSPEND_ITEST_DB_PORT="$db_port" \
  node --test tests/phase6c3-request-notifications-integration.test.ts
