#!/usr/bin/env bash
# Phase 7E API integration and benchmark. Boots a disposable Postgres (every migration plus
# supabase/tests/integration/phase7e_spend_fixture.sql: 50,000 documents / 250,000 lines in the
# organization under test, 1,000,000 lines in all) and PostgREST, runs
# tests/phase7e-spend-integration.test.ts through the app's data layer with signed JWTs, then
# checks the summary plan at work_mem 4MB. Never reads .env files or talks to a hosted project.
#
# Requires Docker, public.ecr.aws/supabase/postgres:17.6.1.167 and
# public.ecr.aws/supabase/postgrest:v14.15.
# Usage: supabase/tests/run_phase7e_spend_integration.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
db_container="medspend_7e_integration_db_$$"
rest_container="medspend_7e_integration_rest_$$"
db_port="${MEDSPEND_7E_INTEGRATION_DB_PORT:-55815}"
rest_port="${MEDSPEND_7E_INTEGRATION_REST_PORT:-55816}"
jwt_secret="local-test-only-jwt-secret-not-used-anywhere-else"
export PGPASSWORD=postgres PGHOST=127.0.0.1 PGPORT="$db_port" PGOPTIONS="-c client_min_messages=warning"
fail() { echo "FAIL: $*" >&2; exit 1; }

cleanup() { docker rm -f "$rest_container" "$db_container" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --log-opt max-size=10m --log-opt max-file=1 --name "$db_container" -e POSTGRES_PASSWORD=postgres \
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
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f "$root/supabase/tests/integration/phase7e_spend_fixture.sql" >/dev/null
[ "$(psql -At -U postgres -d postgres -c 'SHOW work_mem')" = "4MB" ] || fail "expected the default work_mem of 4MB"
[ "$(psql -At -U postgres -d postgres -c 'SELECT count(*) FROM public.invoice_items')" = "1000000" ] || fail "fixture size"

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
  node --test tests/phase7e-spend-integration.test.ts)

# Timings come from the API run above. Here the plan is checked for disk use only (per-node timing
# under auto_explain inflates a plan with many small index probes several-fold).
plan="$(PGOPTIONS="-c client_min_messages=log" psql -X -U supabase_admin -d postgres -At 2>&1 <<SQL
LOAD 'auto_explain';
SET auto_explain.log_min_duration = 0;
SET auto_explain.log_analyze = on;
SET auto_explain.log_timing = off;
SET auto_explain.log_buffers = on;
SET auto_explain.log_nested_statements = on;
SELECT set_config('request.jwt.claim.sub', '7e1c0000-0000-4000-8000-000000000001', false);
SELECT public.get_financial_spend_summary('7e1c0000-0000-4000-8000-000000000101') IS NOT NULL;
SQL
)"
spill="$(echo "$plan" | grep -oE "temp read=[0-9]+ written=[0-9]+" | awk -F'[= ]' '{ if ($5 > max) max = $5 } END { print max + 0 }')"
[ "$spill" -le 2048 ] || fail "the summary spills ${spill} blocks to disk (budget 2048 = 16 MB)"
echo "plan: summary largest temp write ${spill} blocks (budget 2048)"
echo "run_phase7e_spend_integration: passed"
