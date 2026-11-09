#!/usr/bin/env bash
# Runs tests/phase5a10-discovery-integration.test.ts against a disposable local stack
# (Postgres + PostgREST) with every migration applied, including Phase 5A.10: real signed
# JWTs for an owner, an admin, two staff members, another organization's owner, a former
# member, a non-member and anon, through the same API the application uses. The fixture adds
# 100,000 synthetic catalog products and 3,600 organization requests. Then records the query
# plans (auto_explain) of the four search shapes and fails if a token search is not a trigram
# index probe of the search documents.
#
# PostgREST runs with PGRST_DB_MAX_ROWS=1000, like a hosted project's default API row cap.
#
# Nothing here reads .env files or talks to a hosted project. Containers listen on 127.0.0.1
# only and are removed when the script exits.
#
# Usage: supabase/tests/run_phase5a10_discovery_integration.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
db_container="medspend_5a10_integration_db_$$"
rest_container="medspend_5a10_integration_rest_$$"
db_port="${MEDSPEND_5A10_INTEGRATION_DB_PORT:-55705}"
rest_port="${MEDSPEND_5A10_INTEGRATION_REST_PORT:-55706}"
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
started=$(date +%s)
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f "$root/supabase/tests/integration/phase5a10_discovery_fixture.sql" >/dev/null
echo "fixture: $(psql -U postgres -d postgres -Atc "select count(*) from public.catalog_vendor_product_search_documents") search documents, $(psql -U postgres -d postgres -Atc "select count(*) from public.catalog_search_terms") vocabulary terms, built in $(( $(date +%s) - started ))s"
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
  node --test tests/phase5a10-discovery-integration.test.ts)

# Query plans at this scale (100,000 catalog products), as the RPC runs them, for staff 003
# (40 Saved Items, organization history of 3,600 requests): a product-name search, an exact
# SKU, a typo, and a saved/history-boosted search. Each runs twice; the second (warm) plan is
# kept. A token search must probe catalog_vendor_product_search_documents_trgm_idx and never
# scan the search documents.
plans="$(PGOPTIONS="-c client_min_messages=log" psql -X -U supabase_admin -d postgres -At 2>&1 <<'SQL'
SELECT set_config('request.jwt.claim.sub', '5a10c000-0000-4000-8000-000000000003', false);
LOAD 'auto_explain';
SET auto_explain.log_min_duration = 0;
SET auto_explain.log_analyze = on;
SET auto_explain.log_nested_statements = on;
SET auto_explain.log_timing = off;
SELECT count(*) FROM public.search_supply_request_products_with_signals('5a10c000-0000-4000-8000-000000000101', 'elite ankle brace', 20);
SELECT 'PLAN-NAME' ;
SELECT count(*) FROM public.search_supply_request_products_with_signals('5a10c000-0000-4000-8000-000000000101', 'elite ankle brace', 20);
SELECT 'PLAN-SKU' ;
SELECT count(*) FROM public.search_supply_request_products_with_signals('5a10c000-0000-4000-8000-000000000101', 'SS-004244', 20);
SELECT 'PLAN-TYPO' ;
SELECT count(*) FROM public.search_supply_request_products_with_signals('5a10c000-0000-4000-8000-000000000101', 'kinesiolgy tape', 20);
SELECT 'PLAN-BOOSTED' ;
SELECT count(*) FROM public.search_supply_request_products_with_signals('5a10c000-0000-4000-8000-000000000101', 'nitrile gloves', 20);
SELECT 'PLAN-END' ;
SQL
)"
section() { echo "$plans" | awk -v start="PLAN-$1" -v stop="PLAN-$2" '$0 ~ start {on=1; next} $0 ~ stop {on=0} on'; }
for pair in "NAME SKU" "SKU TYPO" "TYPO BOOSTED" "BOOSTED END"; do
  set -- $pair
  plan="$(section "$1" "$2")"
  main="$(echo "$plan" | awk '/CTE global_hits/,/CTE scored/')"
  if [ "$1" != "SKU" ]; then
    echo "$main" | grep -q "catalog_vendor_product_search_documents_trgm_idx" || { echo "$plan"; echo "FAIL: $1 search does not probe the trigram index"; exit 1; }
  fi
  if echo "$main" | grep -q "Seq Scan on catalog_vendor_product_search_documents"; then echo "$plan"; echo "FAIL: $1 search scans the search documents"; exit 1; fi
  echo "plan $1: $(echo "$main" | grep -oE '(Bitmap Index Scan on [a-z_]+|Index Scan using [a-z_]+|Index Only Scan using [a-z_]+|Seq Scan on [a-z_]+)' | sort | uniq -c | tr -s ' ' | tr '\n' ';')"
done

# Warm execution times (psql \timing, same session, third run of each).
psql -X -U postgres -d postgres -At <<'SQL' | grep -E '^(Time|q:)' | paste - - | sed 's/^/timing: /'
SELECT set_config('request.jwt.claim.sub', '5a10c000-0000-4000-8000-000000000003', false) \g /dev/null
\timing on
SELECT 'q: elite ankle brace' \g /dev/null
SELECT count(*) FROM public.search_supply_request_products_with_signals('5a10c000-0000-4000-8000-000000000101', 'elite ankle brace', 20) \g /dev/null
SELECT count(*) FROM public.search_supply_request_products_with_signals('5a10c000-0000-4000-8000-000000000101', 'elite ankle brace', 20) \g /dev/null
SELECT 'q: elite ankle brace';
SELECT count(*) FROM public.search_supply_request_products_with_signals('5a10c000-0000-4000-8000-000000000101', 'elite ankle brace', 20) \g /dev/null
SELECT 'q: SS-004244';
SELECT count(*) FROM public.search_supply_request_products_with_signals('5a10c000-0000-4000-8000-000000000101', 'SS-004244', 20) \g /dev/null
SELECT 'q: kinesiolgy tape';
SELECT count(*) FROM public.search_supply_request_products_with_signals('5a10c000-0000-4000-8000-000000000101', 'kinesiolgy tape', 20) \g /dev/null
SELECT 'q: nitrile gloves';
SELECT count(*) FROM public.search_supply_request_products_with_signals('5a10c000-0000-4000-8000-000000000101', 'nitrile gloves', 20) \g /dev/null
SELECT 'q: tape';
SELECT count(*) FROM public.search_supply_request_products_with_signals('5a10c000-0000-4000-8000-000000000101', 'tape', 20) \g /dev/null
SELECT 'q: discovery';
SELECT count(*) FROM public.get_staff_product_discovery('5a10c000-0000-4000-8000-000000000101', 6) \g /dev/null
SQL
echo "run_phase5a10_discovery_integration: passed"
