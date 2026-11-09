#!/usr/bin/env bash
# Phase 5A.10 release-script check on a disposable Postgres. Never reads .env files or talks
# to a hosted project.
#
#   1. The migration and every release file are sent the way the Supabase SQL Editor sends
#      them: rewritten by the Editor's "Run and enable RLS" logic
#      (support/studio_sql_editor_rewrite.mjs), then as ONE simple query. The rewrite must
#      flag nothing and change nothing (the migration enables RLS on its three tables itself);
#      nothing may follow COMMIT; no temp tables.
#   2. Boot a fresh container, apply every migration before 5A.10 (main, through 7B.5), and
#      seed a catalog in use plus organization requests and invoices (the 5A.10 integration
#      fixture without its Saved Items: 100,004 catalog products, 3,600 requests, 400 invoices)
#      and a count cadence policy that is OFF, as in production.
#   3. precheck; an induced failure just before COMMIT (must roll back completely, including
#      the pg_trgm extension); the migration (success, no output); postcheck; a second
#      application and a repeat precheck (both refused). Diff pre and post: only the documented
#      lines may differ; every catalog, product, request, invoice and cadence line is identical.
#
# Requires Docker, node and public.ecr.aws/supabase/postgres:17.6.1.167.
# Usage: supabase/tests/phase5a10_release_check.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
container="medspend_5a10_release_$$"
port="${MEDSPEND_5A10_RELEASE_PORT:-55715}"
work="$(mktemp -d)"
export PGPASSWORD=postgres PGHOST=127.0.0.1 PGPORT="$port" PGOPTIONS="-c client_min_messages=warning"
migration="20261107120000_phase5a10_staff_product_discovery.sql"
rewrite="$root/supabase/tests/support/studio_sql_editor_rewrite.mjs"
release="$root/supabase/release/phase5a10"

cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
cd "$root"

for file in "supabase/migrations/$migration" "$release"/*.sql; do
  [ -z "$(node "$rewrite" "$file" --tables)" ] || fail "the SQL Editor would append RLS statements to $file"
  cmp -s "$file" <(node "$rewrite" "$file") || fail "the SQL Editor would rewrite $file"
done
grep -qi "create[[:space:]]\+temp" "supabase/migrations/$migration" && fail "the 5A.10 migration creates temp tables"
python3 - "supabase/migrations/$migration" <<'PY' || fail "statements follow the final COMMIT"
import re, sys
text = open(sys.argv[1]).read()
tail = text[text.rindex("\nCOMMIT;") + len("\nCOMMIT;"):]
sys.exit(0 if re.sub(r"--[^\n]*", "", tail).strip() == "" else 1)
PY
echo "ok - the SQL Editor sends the 5A.10 migration and release files unchanged; nothing follows COMMIT"

docker run -d --name "$container" -e POSTGRES_PASSWORD=postgres -p "127.0.0.1:$port:5432" \
  public.ecr.aws/supabase/postgres:17.6.1.167 >/dev/null
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
python3 - supabase/tests/integration/phase5a10_discovery_fixture.sql "$work/seed.sql" <<'PY'
import sys
text = open(sys.argv[1]).read()
start = text.index("-- Staff 003 has 40 Saved Items")
end = text.index("ANALYZE;")
open(sys.argv[2], "w").write(text[:start] + text[end:])
PY
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f "$work/seed.sql" >/dev/null 2>&1 || fail "seed failed"
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -c "INSERT INTO public.inventory_count_policies (organization_id, enabled, interval_days)
  VALUES ('5a10c000-0000-4000-8000-000000000101', false, 30)" >/dev/null
# A budget and stocked inventory, so the organizations / memberships / budgets / inventory
# fingerprints hash real rows (none of them may change).
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -c "
  INSERT INTO public.organization_budgets (organization_id, name, period_start, period_end, amount)
  VALUES ('5a10c000-0000-4000-8000-000000000101', 'FY Supplies', date '2026-07-01', date '2027-06-30', 50000);
  INSERT INTO public.inventory_items (organization_id, sku, name, unit, quantity, active)
  SELECT '5a10c000-0000-4000-8000-000000000101', 'REL-' || n, 'Release Item ' || n, 'each', n, true FROM generate_series(1, 25) n;" >/dev/null

editor() { psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres -At -F ' | ' -c "$(node "$rewrite" "$1")"; }
readonly_editor() { PGOPTIONS="$PGOPTIONS -c default_transaction_read_only=on" editor "$@"; }
fingerprint() { readonly_editor "$release/fingerprint.sql"; }
expect_failure() {  # <label> <expected message> <command...>
  local label="$1" expected="$2"; shift 2
  if out="$("$@" 2>&1)"; then fail "$label unexpectedly succeeded"; fi
  echo "$out" | grep -qF "$expected" || fail "$label: unexpected error: $out"
  echo "ok - $label refused: $expected"
}
objects() { psql -X -U postgres -d postgres -Atc "SELECT (SELECT count(*) FROM pg_class WHERE relname IN ('staff_saved_products', 'catalog_vendor_product_search_documents', 'catalog_search_terms')) + (SELECT count(*) FROM pg_proc WHERE proname IN ('supply_request_product_search', 'catalog_search_text', 'get_staff_product_discovery', 'save_staff_product')) + (SELECT count(*) FROM pg_extension WHERE extname = 'pg_trgm')"; }

readonly_editor "$release/precheck.sql" > "$work/pre.txt"
cmp -s "$work/pre.txt" <(fingerprint) || fail "precheck output is not exactly the fingerprint"
for line in 'catalog_products hash' 'catalog_vendor_products hash' 'supply_requests hash' 'supply_request_items hash' 'invoice_items hash' \
  'organizations hash' 'organization_memberships hash' 'organization_budgets hash' 'inventory_items hash'; do
  grep -q "^rows | $line | [0-9a-f]\{32\}\$" "$work/pre.txt" || fail "$line was not fingerprinted"
done
grep -q '^rows | inventory_count_policies | 5a10c000-0000-4000-8000-000000000101 enabled=false interval=30$' "$work/pre.txt" || fail "cadence policy not reported"
echo "ok - precheck passed on the 7B.5 baseline with a 100,004-product catalog, request and invoice history, and cadence OFF"

python3 - "supabase/migrations/$migration" "$work/broken.sql" <<'PY'
import sys
text = open(sys.argv[1]).read()
marker = "\nCOMMIT;\n"
assert text.count(marker) == 1
open(sys.argv[2], "w").write(text.replace(marker, "\nDO $induced$ BEGIN RAISE EXCEPTION 'induced failure before COMMIT'; END $induced$;\nCOMMIT;\n"))
PY
expect_failure "induced failure before COMMIT" "induced failure before COMMIT" editor "$work/broken.sql"
[ "$(objects)" = "0" ] || fail "partial 5A.10 objects (or pg_trgm) survived the failed migration"
cmp -s "$work/pre.txt" <(fingerprint) || fail "the failed migration left changes behind"
readonly_editor "$release/precheck.sql" > "$work/pre_again.txt"
cmp -s "$work/pre.txt" "$work/pre_again.txt" || fail "precheck changed after the failed attempt"
echo "ok - induced failure rolled back completely (pg_trgm included); precheck passes again"

started=$(date +%s)
out="$(editor "supabase/migrations/$migration" 2>&1)" || fail "the migration failed: $out"
[ -z "$out" ] || fail "the migration printed output: $out"
echo "ok - migration (as the SQL Editor sends it) returned success with no output in $(( $(date +%s) - started ))s on 100,004 catalog products"

readonly_editor "$release/postcheck.sql" > "$work/post.txt"
cmp -s "$work/post.txt" <(fingerprint) || fail "postcheck output is not exactly the fingerprint"
echo "ok - postcheck passed"

expect_failure "second application" "Phase 5A.10 staff product discovery objects already exist unexpectedly" editor "supabase/migrations/$migration"
expect_failure "precheck after the migration" "precheck: Phase 5A.10 objects already exist" readonly_editor "$release/precheck.sql"
cmp -s "$work/post.txt" <(fingerprint) || fail "the refused reapplication changed something"

new_functions='catalog_search_edit_distance|catalog_search_text|catalog_search_token_pattern|get_staff_product_discovery|refresh_catalog_vendor_product_search_documents|remove_staff_saved_product|save_staff_product|search_supply_request_products_with_signals|staff_saved_product_identity_check|supply_request_product_history|supply_request_product_identities|supply_request_product_search|tg_catalog_products_search_document|tg_catalog_source_records_search_document|tg_catalog_vendor_products_search_document|tg_catalog_vendors_search_document|search_supply_request_products'
new_tables='catalog_search_terms|catalog_vendor_product_search_documents|staff_saved_products'
strip() { grep -v -E "^function \| ($new_functions) \| " "$1" \
  | grep -v -E "^overloads \| ($new_functions) \| " \
  | grep -v -E "^(table|policies|grants) \| ($new_tables) \| " \
  | grep -v -E "^index \| ($new_tables)_" \
  | grep -v -E '^trigger \| [a-z_]+\.[a-z_]+_search_document_(insert|update) \| ' \
  | grep -v -E '^extension \| pg_trgm \| ' \
  | grep -v -E "^rows \| ($new_tables) count \| " \
  | grep -v -E '^count \| public (functions|tables|indexes|triggers) \| '; }
diff <(strip "$work/pre.txt") <(strip "$work/post.txt") || fail "precheck/postcheck differ outside the documented lines"
delta() { echo $(( $(grep -F "count | public $1 |" "$work/post.txt" | awk -F' [|] ' '{print $3}') - $(grep -F "count | public $1 |" "$work/pre.txt" | awk -F' [|] ' '{print $3}') )); }
[ "$(delta functions)" = "16" ] && [ "$(delta tables)" = "3" ] && [ "$(delta indexes)" = "6" ] \
  && [ "$(delta policies)" = "0" ] && [ "$(delta triggers)" = "6" ] \
  || fail "unexpected object deltas: functions $(delta functions) tables $(delta tables) indexes $(delta indexes) policies $(delta policies) triggers $(delta triggers)"
grep -q '^rows | catalog_vendor_product_search_documents count | 100004$' "$work/post.txt" || fail "search documents were not backfilled for every catalog product"
grep -q '^function | post_reviewed_invoice | [0-9a-f]\{32\} ' "$work/pre.txt" || fail "post_reviewed_invoice was not fingerprinted"
for line in 'function | post_reviewed_invoice' 'rows | organizations hash' 'rows | organization_memberships hash' 'rows | organization_budgets hash' 'rows | inventory_items hash'; do
  [ "$(grep -F "$line |" "$work/pre.txt")" = "$(grep -F "$line |" "$work/post.txt")" ] || fail "$line changed"
done
echo "ok - post_reviewed_invoice, organizations, memberships, budgets and inventory items are identical before and after"
grep -q '^rows | staff_saved_products count | 0$' "$work/post.txt" || fail "Saved Items are not empty"
echo "ok - pre/post differ only in documented lines: +16 functions, 1 replaced, +3 tables (no client access), +6 indexes, +6 triggers, pg_trgm; no catalog, product, request, invoice or cadence line changed"
echo "--- documented pre/post differences"
diff "$work/pre.txt" "$work/post.txt" | grep -E "^[<>]" | grep -v -E '^[<>] (function|overloads) \| ' || true
echo "phase5a10_release_check: all checks passed"
