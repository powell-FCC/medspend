#!/usr/bin/env bash
# Phase 6C.4 release-script check on a disposable Postgres. Never reads .env files or talks
# to a hosted project.
#
#   1. The migration and every release file are sent the way the Supabase SQL Editor sends
#      them: rewritten by the Editor's "Run and enable RLS" logic
#      (support/studio_sql_editor_rewrite.mjs), then as ONE simple query. The rewrite must
#      flag nothing and change nothing (the migration enables RLS on its two tables itself);
#      nothing may follow COMMIT; no temp tables.
#   2. Boot a fresh container, apply every migration before 6C.4 (main, through 5A.10), and
#      seed invoice history: uploads, reviewed and posted invoices with lines, inventory,
#      price history, a budget, and a count cadence policy that is OFF, as in production.
#   3. precheck; an induced failure just before COMMIT (must roll back completely); the
#      migration (success, no output); postcheck; a second application and a repeat precheck
#      (both refused). Diff pre and post: only the documented lines may differ; every invoice,
#      inventory, price, request, budget and organization line is identical.
#
# Requires Docker, node and public.ecr.aws/supabase/postgres:17.6.1.167.
# Usage: supabase/tests/phase6c4_release_check.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
container="medspend_6c4_release_$$"
port="${MEDSPEND_6C4_RELEASE_PORT:-55815}"
work="$(mktemp -d)"
export PGPASSWORD=postgres PGHOST=127.0.0.1 PGPORT="$port" PGOPTIONS="-c client_min_messages=warning"
migration="20261109120000_phase6c4_batch_invoice_intake.sql"
rewrite="$root/supabase/tests/support/studio_sql_editor_rewrite.mjs"
release="$root/supabase/release/phase6c4"

cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
cd "$root"

for file in "supabase/migrations/$migration" "$release"/*.sql; do
  [ -z "$(node "$rewrite" "$file" --tables)" ] || fail "the SQL Editor would append RLS statements to $file"
  cmp -s "$file" <(node "$rewrite" "$file") || fail "the SQL Editor would rewrite $file"
done
grep -qi "create[[:space:]]\+temp" "supabase/migrations/$migration" && fail "the 6C.4 migration creates temp tables"
python3 - "supabase/migrations/$migration" <<'PY' || fail "statements follow the final COMMIT"
import re, sys
text = open(sys.argv[1]).read()
tail = text[text.rindex("\nCOMMIT;") + len("\nCOMMIT;"):]
sys.exit(0 if re.sub(r"--[^\n]*", "", tail).strip() == "" else 1)
PY
echo "ok - the SQL Editor sends the 6C.4 migration and release files unchanged; nothing follows COMMIT"

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
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f supabase/tests/integration/phase6c4_batch_intake_fixture.sql >/dev/null
# Invoice history: 40 uploads with reviewed drafts and lines (10 of them posted with inventory
# and price history), a budget, stock, and cadence OFF.
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres <<'SQL' >/dev/null
INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type)
SELECT ('6c4f0000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, '6c4e0000-0000-4000-8000-000000000101', '6c4e0000-0000-4000-8000-000000000001',
  '6c4e0000-0000-4000-8000-000000000101/' || ('6c4f0000-0000-4000-8000-' || lpad(n::text, 12, '0')) || '.pdf', 'Invoice ' || n || '.pdf', 1000 + n, 'application/pdf'
FROM generate_series(1, 40) n;
INSERT INTO public.invoices (id, organization_id, source_file_id, vendor_name, vendor_id, invoice_number, invoice_date, processing_status, invoice_total, total_amount, total)
SELECT ('6c4f1000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, '6c4e0000-0000-4000-8000-000000000101', ('6c4f0000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
  'Henry Schein', '6c4e0000-0000-4000-8000-000000000301', (50000000 + n)::text, date '2026-01-01' + n, 'review_required', 10 * n, 10 * n, 10 * n
FROM generate_series(1, 40) n;
INSERT INTO public.invoice_items (organization_id, invoice_id, line_number, sku, description, quantity, unit_of_measure, unit_price, total_price)
SELECT '6c4e0000-0000-4000-8000-000000000101', ('6c4f1000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, l, '900-' || lpad((n * 10 + l)::text, 4, '0'),
  'Release supply ' || n || '-' || l, l, 'EA', 5, 5 * l
FROM generate_series(1, 40) n, generate_series(1, 3) l;
INSERT INTO public.organization_budgets (organization_id, name, period_start, period_end, amount)
VALUES ('6c4e0000-0000-4000-8000-000000000101', 'FY Supplies', date '2026-07-01', date '2027-06-30', 50000);
INSERT INTO public.inventory_items (organization_id, sku, name, unit, quantity, active)
SELECT '6c4e0000-0000-4000-8000-000000000101', 'REL-' || n, 'Release Item ' || n, 'each', n, true FROM generate_series(1, 25) n;
INSERT INTO public.inventory_count_policies (organization_id, enabled, interval_days) VALUES ('6c4e0000-0000-4000-8000-000000000101', false, 30);
SQL
# Post ten of them through the real posting function (products created from their lines).
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres <<'SQL' >/dev/null
SELECT set_config('request.jwt.claim.sub', '6c4e0000-0000-4000-8000-000000000001', false);
DO $post$
DECLARE _item record; _product jsonb;
BEGIN
  FOR _item IN SELECT item.id, invoice.source_file_id FROM public.invoice_items item JOIN public.invoices invoice ON invoice.id = item.invoice_id
               WHERE invoice.invoice_number::int BETWEEN 50000001 AND 50000010 ORDER BY item.id LOOP
    _product := public.create_product_from_invoice_item('6c4e0000-0000-4000-8000-000000000101', _item.source_file_id, _item.id);
    PERFORM public.confirm_invoice_item_product('6c4e0000-0000-4000-8000-000000000101', _item.source_file_id, _item.id, (_product->>'productId')::uuid, true);
  END LOOP;
  PERFORM public.post_reviewed_invoice('6c4e0000-0000-4000-8000-000000000101', ('6c4f0000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid)
  FROM generate_series(1, 10) n;
END
$post$;
SQL

editor() { psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres -At -F ' | ' -c "$(node "$rewrite" "$1")"; }
readonly_editor() { PGOPTIONS="$PGOPTIONS -c default_transaction_read_only=on" editor "$@"; }
fingerprint() { readonly_editor "$release/fingerprint.sql"; }
expect_failure() {  # <label> <expected message> <command...>
  local label="$1" expected="$2"; shift 2
  if out="$("$@" 2>&1)"; then fail "$label unexpectedly succeeded"; fi
  echo "$out" | grep -qF "$expected" || fail "$label: unexpected error: $out"
  echo "ok - $label refused: $expected"
}
objects() { psql -X -U postgres -d postgres -Atc "SELECT (SELECT count(*) FROM pg_class WHERE relname IN ('invoice_upload_batches', 'invoice_upload_batch_segments')) + (SELECT count(*) FROM pg_proc WHERE proname IN ('create_invoice_upload_batch', 'register_invoice_batch_segment', 'invoice_batch_name_key', 'get_invoice_source_provenance'))"; }

readonly_editor "$release/precheck.sql" > "$work/pre.txt"
cmp -s "$work/pre.txt" <(fingerprint) || fail "precheck output is not exactly the fingerprint"
for line in 'vendor_invoices hash' 'invoices hash' 'invoice_items hash' 'inventory_items hash' 'inventory_adjustments hash' 'inventory_price_history hash' \
  'organizations hash' 'organization_memberships hash' 'organization_budgets hash' 'products hash'; do
  grep -q "^rows | $line | [0-9a-f]\{32\}\$" "$work/pre.txt" || fail "$line was not fingerprinted"
done
grep -q '^rows | inventory_count_policies | 6c4e0000-0000-4000-8000-000000000101 enabled=false interval=30$' "$work/pre.txt" || fail "cadence policy not reported"
[ "$(psql -X -U postgres -d postgres -Atc "SELECT count(*) FROM public.inventory_price_history")" -gt 0 ] || fail "seed posted nothing"
echo "ok - precheck passed on the 5A.10 baseline with invoice history (40 uploads, 10 posted) and cadence OFF"

python3 - "supabase/migrations/$migration" "$work/broken.sql" <<'PY'
import sys
text = open(sys.argv[1]).read()
marker = "\nCOMMIT;\n"
assert text.count(marker) == 1
open(sys.argv[2], "w").write(text.replace(marker, "\nDO $induced$ BEGIN RAISE EXCEPTION 'induced failure before COMMIT'; END $induced$;\nCOMMIT;\n"))
PY
expect_failure "induced failure before COMMIT" "induced failure before COMMIT" editor "$work/broken.sql"
[ "$(objects)" = "0" ] || fail "partial 6C.4 objects survived the failed migration"
cmp -s "$work/pre.txt" <(fingerprint) || fail "the failed migration left changes behind"
readonly_editor "$release/precheck.sql" > "$work/pre_again.txt"
cmp -s "$work/pre.txt" "$work/pre_again.txt" || fail "precheck changed after the failed attempt"
echo "ok - induced failure rolled back completely; precheck passes again"

out="$(editor "supabase/migrations/$migration" 2>&1)" || fail "the migration failed: $out"
[ -z "$out" ] || fail "the migration printed output: $out"
echo "ok - migration (as the SQL Editor sends it) returned success with no output"

readonly_editor "$release/postcheck.sql" > "$work/post.txt"
cmp -s "$work/post.txt" <(fingerprint) || fail "postcheck output is not exactly the fingerprint"
echo "ok - postcheck passed"

expect_failure "second application" "Phase 6C.4 batch intake objects already exist unexpectedly" editor "supabase/migrations/$migration"
expect_failure "precheck after the migration" "precheck: Phase 6C.4 objects already exist" readonly_editor "$release/precheck.sql"
cmp -s "$work/post.txt" <(fingerprint) || fail "the refused reapplication changed something"

new_functions='create_invoice_upload_batch|fail_invoice_batch_segment|get_invoice_source_provenance|get_invoice_upload_batch|invoice_batch_identity_key|invoice_batch_name_key|list_invoice_upload_batches|register_invoice_batch_segment|release_invoice_batch_segment'
new_tables='invoice_upload_batches|invoice_upload_batch_segments'
strip() { grep -v -E "^(function|overloads) \| ($new_functions) \| " "$1" \
  | grep -v -E "^(table|policies|grants) \| ($new_tables) \| " \
  | grep -v -E "^index \| ($new_tables)_" \
  | grep -v -E '^index \| invoice_upload_batch' \
  | grep -v -E '^trigger \| invoice_upload_batch_segments\.invoice_upload_batch_segments_updated_at \| ' \
  | grep -v -E "^rows \| ($new_tables) count \| " \
  | grep -v -E '^count \| public (functions|tables|indexes|triggers) \| '; }
diff <(strip "$work/pre.txt") <(strip "$work/post.txt") || fail "precheck/postcheck differ outside the documented lines"
delta() { echo $(( $(grep -F "count | public $1 |" "$work/post.txt" | awk -F' [|] ' '{print $3}') - $(grep -F "count | public $1 |" "$work/pre.txt" | awk -F' [|] ' '{print $3}') )); }
[ "$(delta functions)" = "9" ] && [ "$(delta tables)" = "2" ] && [ "$(delta indexes)" = "10" ] \
  && [ "$(delta policies)" = "0" ] && [ "$(delta triggers)" = "1" ] \
  || fail "unexpected object deltas: functions $(delta functions) tables $(delta tables) indexes $(delta indexes) policies $(delta policies) triggers $(delta triggers)"
for line in 'function | post_reviewed_invoice' 'function | delete_invoice_permanently' 'function | seed_structured_invoice_draft' \
  'function | match_invoice_item_to_catalog_listing' 'function | search_invoice_line_catalog_listings' 'function | search_supply_request_products' \
  'rows | invoices hash' 'rows | invoice_items hash' 'rows | vendor_invoices hash' 'rows | inventory_price_history hash' 'rows | inventory_items hash' \
  'storage | bucket vendor-invoices'; do
  [ "$(grep -F "$line |" "$work/pre.txt")" = "$(grep -F "$line |" "$work/post.txt")" ] || fail "$line changed"
done
grep -q '^rows | invoice_upload_batches count | 0$' "$work/post.txt" || fail "packets are not empty"
echo "ok - pre/post differ only in documented lines: +9 functions, +2 tables (no client access), +10 indexes, +1 trigger; no invoice, inventory, price, storage or posting line changed"
echo "--- documented pre/post differences"
diff "$work/pre.txt" "$work/post.txt" | grep -E "^[<>]" | grep -v -E '^[<>] (function|overloads|index) \| ' || true
echo "phase6c4_release_check: all checks passed"
