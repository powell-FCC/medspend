#!/usr/bin/env bash
# Phase 7F.1A search no-regression and benchmark. Boots its own disposable Postgres, loads
# the real Henry Schein v28 catalog from the untracked dry-run artifacts (9,059 listings),
# links an FC Cincinnati-shaped organization to it, and copies the database: one copy stays
# on main's schema, the other gets the 7F.1A migration. Then:
#   1. a battery of real queries must return byte-identical rows on both copies;
#   2. both copies are timed at 9,059 listings, then with synthetic listings of three
#      catalog vendors the organization does NOT use added to reach ~25k and ~100k;
#   3. on the 7F.1A copy, the organization's results at 25k/100k must equal its results
#      at 9,059 (other catalogs never leak in), while main's copy shows the leak;
#   4. query plans of the scoped global_hits step are printed (auto_explain).
# Never reads .env files or talks to a hosted project.
#
# Requires Docker and public.ecr.aws/supabase/postgres:17.6.1.167.
# Usage: supabase/tests/phase7f1a_search_benchmark.sh <henry_schein_v28_artifact_dir>
set -euo pipefail

artifacts="${1:?usage: $0 <outputs/catalog/henry-schein/v28 directory>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
container="medspend_7f1a_bench_$$"
port="${MEDSPEND_7F1A_BENCH_PORT:-55925}"
work="$(mktemp -d)"
export PGPASSWORD=postgres PGHOST=127.0.0.1 PGPORT="$port" PGOPTIONS="-c client_min_messages=warning"
migration="20261125120000_phase7f1a_core_catalog_foundation.sql"
runs="${MEDSPEND_7F1A_BENCH_RUNS:-5}"
cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
cd "$root"

docker run -d --log-opt max-size=10m --log-opt max-file=1 --name "$container" -e POSTGRES_PASSWORD=postgres \
  -p "127.0.0.1:$port:5432" public.ecr.aws/supabase/postgres:17.6.1.167 >/dev/null
for _ in $(seq 1 60); do
  if psql -U supabase_admin -d postgres -Atc "select 1 from pg_roles where rolname = 'authenticator'" 2>/dev/null | grep -q 1; then break; fi
  sleep 2
done
sleep 5
psql -q -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -f supabase/tests/integration/local_stack_setup.sql >/dev/null
for file in supabase/migrations/*.sql; do
  [[ "$(basename "$file")" < "$migration" ]] || continue
  psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f "$file" >/dev/null
done
python3 supabase/tests/support/phase7f1a_henry_schein_fixture.py "$artifacts" > "$work/hs.sql"
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f "$work/hs.sql" >/dev/null

org=7f1ab000-0000-4000-8000-000000000101
staff=7f1ab000-0000-4000-8000-000000000003
other_org=7f1ab000-0000-4000-8000-000000000102
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
VALUES ('$staff', 'authenticated', 'authenticated', 'bench7f1a@example.invalid', '', now(), '{}', '{}', now(), now()),
       ('7f1ab000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'bench7f1a-owner@example.invalid', '', now(), '{}', '{}', now(), now());
INSERT INTO public.organizations (id, name, created_by) VALUES
  ('$org', 'Benchmark FC', '7f1ab000-0000-4000-8000-000000000001'),
  ('$other_org', 'Benchmark Unlinked', '7f1ab000-0000-4000-8000-000000000001');
INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES
  ('$org', '7f1ab000-0000-4000-8000-000000000001', 'owner', true), ('$org', '$staff', 'staff', true),
  ('$other_org', '$staff', 'staff', true);
INSERT INTO public.vendors (organization_id, name, active, catalog_vendor_id)
SELECT '$org', 'Henry Schein', true, id FROM public.catalog_vendors WHERE normalized_name = 'henry schein';
SQL
counts="$(psql -U postgres -d postgres -Atc "select (select count(*) from catalog_vendor_products)||'/'||(select count(*) from catalog_vendor_product_search_documents)||'/'||(select count(*) from catalog_source_records)")"
echo "loaded Henry Schein: listings/search documents/source records = $counts"

psql -q -U supabase_admin -d template1 -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'postgres' AND pid <> pg_backend_pid()" >/dev/null
psql -q -U supabase_admin -d template1 -c "CREATE DATABASE bench_after TEMPLATE postgres OWNER postgres" >/dev/null
psql -q -v ON_ERROR_STOP=1 -U postgres -d bench_after -f "supabase/migrations/$migration" >/dev/null
echo "copies: postgres = main schema, bench_after = main + 7F.1A"

queries=(
  "tape" "athletic tape" "kinesiology tape" "prewrap" "underwrap" "cohesive" "elastic bandage"
  "gauze" "gauze 4x4" "nitrile gloves" "nitrile gloves large" "gloves xl" "ice bag" "cold pack"
  "alcohol prep" "scissors" "shears" "2 inch" "1/2" "needle" "syringe" "heel cup" "ankle brace"
  "blister" "moleskin" "foam" "splint" "thermometer" "bandge" "kinesology" "gauz"
  "128-5853" "1285853" "128-58" "398-0144" "735-0022" "100-0145" "white" "sterile" "case"
)
printf '%s\n' "${queries[@]}" > "$work/queries.txt"

snapshot() { # database organization file
  local database="$1" organization="$2" target="$3"
  : > "$target"
  while IFS= read -r query; do
    psql -q -v ON_ERROR_STOP=1 -U postgres -d "$database" -At \
      -c "SELECT set_config('request.jwt.claim.sub', '$staff', false)" \
      -c "SET ROLE authenticated" \
      -c "SELECT '$query' AS q, s::text FROM public.search_supply_request_products_with_signals('$organization', \$q\$$query\$q\$, 50) WITH ORDINALITY s" >> "$target"
  done < "$work/queries.txt"
}

timing() { # database organization -> "p50 p95 max" in ms over every query x runs
  local database="$1" organization="$2"
  psql -q -v ON_ERROR_STOP=1 -U postgres -d "$database" -At <<SQL
SELECT set_config('request.jwt.claim.sub', '$staff', false);
SET ROLE authenticated;
DO \$\$
DECLARE _q text; _i integer; _t timestamptz; _times numeric[] := '{}';
BEGIN
  FOREACH _q IN ARRAY string_to_array(\$q\$$(paste -sd '|' "$work/queries.txt")\$q\$, '|') LOOP
    PERFORM count(*) FROM public.search_supply_request_products_with_signals('$organization', _q, 50); -- warm
    FOR _i IN 1 .. $runs LOOP
      _t := clock_timestamp();
      PERFORM count(*) FROM public.search_supply_request_products_with_signals('$organization', _q, 50);
      _times := _times || (extract(epoch FROM clock_timestamp() - _t) * 1000)::numeric;
    END LOOP;
  END LOOP;
  RAISE WARNING 'TIMING % % %',
    round((SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY t) FROM unnest(_times) t)::numeric, 1),
    round((SELECT percentile_cont(0.95) WITHIN GROUP (ORDER BY t) FROM unnest(_times) t)::numeric, 1),
    round((SELECT max(t) FROM unnest(_times) t)::numeric, 1);
END
\$\$;
SQL
}
measure() { timing "$1" "$2" 2>&1 | grep -o 'TIMING.*' | sed 's/TIMING //'; }

add_synthetic() { # database first last
  psql -q -v ON_ERROR_STOP=1 -U postgres -d "$1" >/dev/null <<SQL
INSERT INTO public.catalog_vendors (id, name, normalized_name, active)
SELECT ('7f1ab000-0000-4000-8000-0000000002' || lpad(v::text, 2, '0'))::uuid,
  (ARRAY['Distributor North', 'Distributor South', 'Brand Direct'])[v], 'x' || v, true
FROM generate_series(1, 3) v
ON CONFLICT DO NOTHING;
INSERT INTO public.catalog_products (id, name, normalized_name, description, manufacturer, active, verification_status)
SELECT ('7f1ab001-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
  (ARRAY['Pro', 'Elite', 'Classic', 'Ultra', 'Team', 'Clinic', 'Trainer', 'Field', 'Premium', 'Basic', 'Flex', 'Sport', 'Active'])[1 + n % 13]
  || ' ' || (ARRAY['Athletic Tape', 'Elastic Bandage', 'Nitrile Exam Gloves', 'Cold Pack', 'Gauze Sponge', 'Prewrap', 'Heel Cup',
     'Ankle Brace', 'Kinesiology Tape', 'Alcohol Prep Pad', 'Cohesive Wrap', 'Underwrap', 'Trauma Shears', 'Moleskin', 'Splint',
     'Creatine Monohydrate', 'Whey Isolate', 'Electrolyte Mix', 'Ice Bag', 'Foam Roller'])[1 + (n / 13) % 20],
  'x',
  (ARRAY['1"', '2"', '3"', 'Small', 'Medium', 'Large', 'X-Large', '1/2"', '10 yd', '4" x 4"', 'One Size', 'White', 'Beige'])[1 + n % 13],
  (ARRAY['Acme Health', 'Rivera Labs', 'Brightline', 'Kestrel Medical'])[1 + n % 4],
  true, 'verified'
FROM generate_series($2, $3) n;
INSERT INTO public.catalog_vendor_products (id, catalog_product_id, catalog_vendor_id, vendor_sku, normalized_vendor_sku,
  manufacturer_sku, package_quantity, package_unit, package_status, active, discontinued, verification_status)
SELECT ('7f1ab002-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, ('7f1ab001-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
  ('7f1ab000-0000-4000-8000-0000000002' || lpad((1 + n % 3)::text, 2, '0'))::uuid,
  -- Some synthetic SKUs collide with Henry Schein's format on purpose.
  CASE WHEN n % 10 = 0 THEN lpad((100 + (n / 10) % 900)::text, 3, '0') || '-' || lpad(((n / 10) / 900)::text, 4, '0')
       ELSE (ARRAY['DN', 'DS', 'BD'])[1 + n % 3] || '-' || lpad(n::text, 6, '0') END,
  'x', CASE WHEN n % 3 = 0 THEN 'M' || lpad((n * 7)::text, 8, '0') END,
  (ARRAY[1, 6, 12, 24])[1 + n % 4], (ARRAY['each', 'roll', 'box', 'case'])[1 + n % 4], 'verified', true, false, 'verified'
FROM generate_series($2, $3) n;
SQL
}

plans() { # database
  psql -q -U postgres -d "$1" <<SQL 2>&1 | grep -E "global_hits|scoped_listing|catalog_vendor_product_search_documents|One-Time Filter|Execution Time" | awk 'NR <= 80'
LOAD 'auto_explain';
SET auto_explain.log_min_duration = 0;
SET auto_explain.log_analyze = on;
SET auto_explain.log_nested_statements = on;
SET auto_explain.log_level = warning;
SELECT set_config('request.jwt.claim.sub', '$staff', false);
SET ROLE authenticated;
SELECT count(*) FROM public.search_supply_request_products_with_signals('$org', 'athletic tape', 50);
SQL
}

# 1. Identical rows at the real Henry Schein size.
snapshot postgres "$org" "$work/main_9k.txt"
snapshot bench_after "$org" "$work/after_9k.txt"
rows="$(wc -l < "$work/main_9k.txt" | tr -d ' ')"
[ "$rows" -gt 500 ] || fail "the query battery returned only $rows rows"
cmp -s "$work/main_9k.txt" "$work/after_9k.txt" || { diff "$work/main_9k.txt" "$work/after_9k.txt" | head -20; fail "Henry Schein results changed"; }
echo "ok - ${#queries[@]} queries, $rows result rows: identical on main and 7F.1A (Henry Schein, linked organization)"
snapshot bench_after "$other_org" "$work/after_unlinked.txt"
[ "$(grep -c 'global_catalog' "$work/after_unlinked.txt" || true)" = 0 ] || fail "an unlinked organization still sees the global catalog"
echo "ok - an organization with no linked catalog vendor gets no global listings on 7F.1A"

echo "timing p50 p95 max (ms), ${#queries[@]} queries x $runs runs:"
echo "  9,059   main   $(measure postgres "$org")"
echo "  9,059   7F.1A  $(measure bench_after "$org")"
echo "  9,059   7F.1A unlinked org  $(measure bench_after "$other_org")"

for step in "1 16000 25k" "16001 91000 100k"; do
  set -- $step
  add_synthetic postgres "$1" "$2"
  add_synthetic bench_after "$1" "$2"
  total="$(psql -U postgres -d bench_after -Atc 'select count(*) from catalog_vendor_products')"
  snapshot bench_after "$org" "$work/after_$3.txt"
  cmp -s "$work/after_9k.txt" "$work/after_$3.txt" || { diff "$work/after_9k.txt" "$work/after_$3.txt" | head; fail "other catalogs leaked into the linked organization's results at $3"; }
  snapshot postgres "$org" "$work/main_$3.txt"
  leaked="$(diff "$work/main_9k.txt" "$work/main_$3.txt" | grep -c '^>' || true)"
  echo "ok - $total listings: 7F.1A results identical to the 9,059 baseline; main's unscoped search changed $leaked rows"
  echo "  $total  main   $(measure postgres "$org")"
  echo "  $total  7F.1A  $(measure bench_after "$org")"
  echo "  $total  7F.1A unlinked org  $(measure bench_after "$other_org")"
done

echo "plan of the scoped search at $total listings ('athletic tape'):"
plans bench_after
