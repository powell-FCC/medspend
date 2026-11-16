#!/usr/bin/env bash
# Runs tests/phase7d-replenishment-integration.test.ts against a disposable local stack
# (Postgres + PostgREST) with every migration applied, including Phase 7D: real signed JWTs for
# an owner, an admin, a staff member, another organization's owner, a non-member and anon,
# through the same API the application uses. The fixture is the agreed large shape: 2,000
# items x 20 storage locations (40,000 rules), 200,000 count lines. Then records the query
# plans of the replenishment reads at that scale and fails on a pathological shape: the
# last-count lookup must be an index probe run once per returned row, never a scan of count
# history, and the rule calculation must not loop per rule.
#
# PostgREST runs with PGRST_DB_MAX_ROWS=1000, like a hosted project's default API row cap.
#
# Nothing here reads .env files or talks to a hosted project. Containers listen on 127.0.0.1
# only and are removed when the script exits.
#
# Usage: supabase/tests/run_phase7d_replenishment_integration.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
db_container="medspend_7d_integration_db_$$"
rest_container="medspend_7d_integration_rest_$$"
db_port="${MEDSPEND_7D_INTEGRATION_DB_PORT:-55775}"
rest_port="${MEDSPEND_7D_INTEGRATION_REST_PORT:-55776}"
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
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f "$root/supabase/tests/integration/phase7d_replenishment_fixture.sql" >/dev/null
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
  node --test tests/phase7d-replenishment-integration.test.ts)

# Query plans at this scale, as the RPCs run them (as the admin).
plan() {
  PGOPTIONS="-c client_min_messages=log" psql -X -U supabase_admin -d postgres -At 2>&1 <<SQL
LOAD 'auto_explain';
SET auto_explain.log_min_duration = 0;
SET auto_explain.log_analyze = on;
SET auto_explain.log_nested_statements = on;
SET auto_explain.log_level = 'log';
SELECT set_config('request.jwt.claim.sub', '7d1c0000-0000-4000-8000-000000000002', false);
$1
SQL
}
attention="$(plan "SELECT count(*) FROM public.list_inventory_replenishment('7d1c0000-0000-4000-8000-000000000101', 'attention', NULL, 100);")"
echo "$attention" | grep -q "Index Only Scan using inventory_count_lines_item_location_idx on inventory_count_lines" \
  || { echo "$attention"; fail "the last-count lookup is not an index probe of inventory_count_lines_item_location_idx"; }
echo "$attention" | grep "inventory_count_lines_item_location_idx" | grep -q "loops=100)" \
  || { echo "$attention"; fail "the last-count lookup does not run once per returned row (100)"; }
if echo "$attention" | grep -q "Seq Scan on inventory_count_lines"; then echo "$attention"; fail "replenishment scans count history"; fi
# One pass over rules and balances: a repeated sequential scan of either (loops > 1) is a
# per-rule rescan. Primary-key probes inside the single statement are fine.
if echo "$attention" | grep -E "Seq Scan on inventory_(replenishment_rules|location_balances)" | grep -qvE "loops=1\)"; then
  echo "$attention"; fail "the rule calculation rescans rules or balances"
fi
top="$(echo "$attention" | grep -E "duration: [0-9.]+ ms" | tail -1 | grep -oE "[0-9.]+ ms" | cut -d' ' -f1)"
awk -v ms="${top:-99999}" 'BEGIN { exit !(ms < 3000) }' || fail "the attention page took ${top:-?} ms at 40,000 rules (budget 3000 ms)"
summary="$(plan "SELECT public.get_inventory_replenishment_summary('7d1c0000-0000-4000-8000-000000000101') IS NOT NULL;")"
if echo "$summary" | grep -q "inventory_count_lines"; then echo "$summary"; fail "the summary reads count history"; fi
for label in attention summary; do
  echo "plan: $label top-level $(echo "${!label}" | grep -oE "duration: [0-9.]+ ms" | tail -1)"
done
echo "$attention" | grep -E "inventory_count_lines_item_location_idx|Seq Scan on inventory_replenishment_rules" | sed -E 's/^.*->  //; s/\(cost=[^)]*\) //' | sort | uniq -c | sed 's/^/plan: /'
echo "run_phase7d_replenishment_integration: passed"
