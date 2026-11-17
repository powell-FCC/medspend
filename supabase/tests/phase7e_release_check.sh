#!/usr/bin/env bash
# Phase 7E release check: proves the release files and the migration behave in the Supabase SQL
# Editor exactly as README.md says, on a seeded copy of the 7D production shape (an
# FC Cincinnati-like organization with a "Tape" budget, posted invoices and order confirmations
# with no currency recorded, one dated only by its posting day, a draft, requests with
# commitments, source files). Boots its own disposable Postgres. Never reads .env files or talks
# to a hosted project.
#
# Requires Docker and public.ecr.aws/supabase/postgres:17.6.1.167.
# Usage: supabase/tests/phase7e_release_check.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
container="medspend_7e_release_$$"
port="${MEDSPEND_7E_RELEASE_PORT:-55825}"
work="$(mktemp -d)"
export PGPASSWORD=postgres PGHOST=127.0.0.1 PGPORT="$port" PGOPTIONS="-c client_min_messages=warning"
migration="20261117120000_phase7e_budget_analytics.sql"
rewrite="$root/supabase/tests/support/studio_sql_editor_rewrite.mjs"
release="$root/supabase/release/phase7e"

cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
cd "$root"

for file in "supabase/migrations/$migration" "$release"/*.sql; do
  [ -z "$(node "$rewrite" "$file" --tables)" ] || fail "the SQL Editor would append RLS statements to $file"
  cmp -s "$file" <(node "$rewrite" "$file") || fail "the SQL Editor would rewrite $file"
done
grep -qi "create[[:space:]]\+temp" "supabase/migrations/$migration" && fail "the 7E migration creates temp tables"
python3 - "supabase/migrations/$migration" <<'PY2'
import re, sys
text = open(sys.argv[1]).read()
tail = text[text.rindex("\nCOMMIT;") + len("\nCOMMIT;"):]
sys.exit(0 if re.sub(r"--[^\n]*", "", tail).strip() == "" else 1)
PY2
echo "ok - the SQL Editor sends the 7E migration and release files unchanged; nothing follows COMMIT"

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

# Hosted Supabase lets signed-in users reach storage.objects through its policies; the local stub
# needs the same table privileges so the policies (not a missing grant) decide.
psql -q -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -c "GRANT SELECT, DELETE ON storage.objects TO authenticated" >/dev/null

org=7e3f0000-0000-4000-8000-000000000101
owner=7e3f0000-0000-4000-8000-000000000001
admin=7e3f0000-0000-4000-8000-000000000002
staff=7e3f0000-0000-4000-8000-000000000003
vendor=7e3f0000-0000-4000-8000-000000000301
device=7e3f0000-0000-4000-8000-000000000401
gauze=7e3f0000-0000-4000-8000-000000000402
budget=7e3f0000-0000-4000-8000-000000000901
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT u, 'authenticated', 'authenticated', 'release-' || right(u::text, 3) || '@example.invalid', '', now(), '{}', '{}', now(), now()
FROM unnest(ARRAY['$owner', '$admin', '$staff']::uuid[]) u;
INSERT INTO public.organizations (id, name, created_by) VALUES ('$org', 'Release FC', '$owner');
INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES
  ('$org', '$owner', 'owner', true), ('$org', '$admin', 'admin', true), ('$org', '$staff', 'staff', true);
INSERT INTO public.vendors (id, organization_id, name, active) VALUES ('$vendor', '$org', 'Henry Schein', true);
INSERT INTO public.products (id, organization_id, name, approved, active, staff_requestable) VALUES
  ('$device', '$org', 'Hivamat Deep Oscillation Unit', true, true, true), ('$gauze', '$org', 'Gauze', true, true, true);
INSERT INTO public.organization_budgets (id, organization_id, name, period_start, period_end, amount, active)
VALUES ('$budget', '$org', 'Tape', '2026-01-01', '2026-12-31', 50000, true);
INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type)
SELECT ('7e3f0000-0000-4000-8000-00000000a00' || n)::uuid, '$org', '$owner', '$org/doc-' || n || '.pdf', 'doc-' || n || '.pdf', 1000, 'application/pdf'
FROM generate_series(1, 5) n;
INSERT INTO storage.objects (bucket_id, name) SELECT 'vendor-invoices', '$org/doc-' || n || '.pdf' FROM generate_series(1, 5) n;
-- Posted before 7E (written directly, as the 7D posting function wrote them; no guards yet).
INSERT INTO public.invoices (id, organization_id, source_file_id, vendor_id, vendor_name, document_type, invoice_number, order_number,
  invoice_date, posted_at, processing_status, currency_code, subtotal, tax_amount, shipping_amount, invoice_total, total_amount, total) VALUES
  ('7e3f0000-0000-4000-8000-00000000b001', '$org', '7e3f0000-0000-4000-8000-00000000a001', '$vendor', 'Henry Schein', 'INVOICE', '50902751', NULL,
    '2026-01-02', '2026-11-10 15:00+00', 'completed', NULL, 17850, 1204.88, NULL, 19054.88, 19054.88, 19054.88),
  ('7e3f0000-0000-4000-8000-00000000b002', '$org', '7e3f0000-0000-4000-8000-00000000a002', '$vendor', 'Henry Schein', 'INVOICE', '51706237', NULL,
    '2026-01-07', '2026-11-10 15:01+00', 'completed', NULL, 310, 23.70, NULL, 333.70, 333.70, 333.70),
  ('7e3f0000-0000-4000-8000-00000000b003', '$org', '7e3f0000-0000-4000-8000-00000000a003', '$vendor', 'Henry Schein', 'ORDER_CONFIRMATION', NULL, 'OC-1',
    NULL, '2026-10-12 18:00+00', 'completed', NULL, 150, 12.40, 3.95, 166.35, 166.35, 166.35);
INSERT INTO public.invoice_items (invoice_id, organization_id, line_number, description, quantity, unit_of_measure, unit_price, total_price, product_id) VALUES
  ('7e3f0000-0000-4000-8000-00000000b001', '$org', 1, 'Hivamat', 1, 'ea', 17850, 17850, '$device'),
  ('7e3f0000-0000-4000-8000-00000000b002', '$org', 1, 'Gauze', 6, 'bx', 51.6667, 310, '$gauze'),
  ('7e3f0000-0000-4000-8000-00000000b003', '$org', 1, 'Gauze', 3, 'BX', 50, 150, '$gauze');
-- A draft (document 4) and an unprocessed upload (document 5).
INSERT INTO public.invoices (id, organization_id, source_file_id, vendor_id, vendor_name, document_type, invoice_number, invoice_date, processing_status, invoice_total, total_amount, total)
VALUES ('7e3f0000-0000-4000-8000-00000000b004', '$org', '7e3f0000-0000-4000-8000-00000000a004', '$vendor', 'Henry Schein', 'INVOICE', 'DRAFT-4', '2026-11-01', 'review_required', 40, 40, 40);
INSERT INTO public.invoice_items (invoice_id, organization_id, line_number, description, quantity, unit_of_measure, unit_price, total_price, product_id)
VALUES ('7e3f0000-0000-4000-8000-00000000b004', '$org', 1, 'Gauze', 4, 'bx', 10, 40, '$gauze');
INSERT INTO public.supply_requests (id, organization_id, requested_by, request_type, quantity, notes, status) VALUES
  ('7e3f0000-0000-4000-8000-00000000c001', '$org', '$staff', 'reorder', 1, 'ordered', 'ordered'),
  ('7e3f0000-0000-4000-8000-00000000c002', '$org', '$staff', 'reorder', 1, 'completed', 'completed');
INSERT INTO public.supply_request_commitments (organization_id, supply_request_id, amount, total_item_count, priced_item_count, pricing_status, status, committed_at) VALUES
  ('$org', '7e3f0000-0000-4000-8000-00000000c001', 36.78, 3, 1, 'partially_priced', 'active', '2026-11-03 19:00+00'),
  ('$org', '7e3f0000-0000-4000-8000-00000000c002', 0, 1, 0, 'unpriced', 'active', '2026-11-03 19:00+00');
SQL
q() { psql -X -U postgres -d postgres -Atc "$1"; }
editor() { psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres -At -F ' | ' -c "$(node "$rewrite" "$1")"; }
readonly_editor() { PGOPTIONS="$PGOPTIONS -c default_transaction_read_only=on" editor "$@"; }
fingerprint() { readonly_editor "$release/fingerprint.sql"; }
expect_failure() {  # <label> <expected message> <command...>
  local label="$1" expected="$2"; shift 2
  if out="$("$@" 2>&1)"; then fail "$label unexpectedly succeeded"; fi
  echo "$out" | grep -qF "$expected" || fail "$label: unexpected error: $out"
  echo "ok - $label refused: $expected"
}
as_user() {  # <user> <sql> : prints only the statement's own result
  psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres -At \
    -c "SET ROLE authenticated" -c "DO 'BEGIN PERFORM set_config(''request.jwt.claim.sub'', ''$1'', false); END'" -c "$2"
}
objects() { q "SELECT (SELECT count(*) FROM pg_class WHERE relname = 'financial_document_removals') + (SELECT count(*) FROM pg_proc WHERE proname LIKE '%financial%' AND pronamespace = 'public'::regnamespace) + (SELECT count(*) FROM pg_trigger WHERE tgname IN ('invoices_posted_guard', 'invoice_items_posted_guard', 'organization_budgets_no_overlap'))"; }

# The app loaded before the release, as it reads budgets today.
as_user "$owner" "SELECT to_jsonb(s) FROM public.get_budget_summary('$org', '$budget') s" > "$work/old_summary.json"
as_user "$owner" "SELECT public.get_budget_purchasing_overview('$org')" > "$work/old_overview.json"

readonly_editor "$release/precheck.sql" > "$work/pre.txt"
cmp -s "$work/pre.txt" <(fingerprint) || fail "precheck output is not exactly the fingerprint"
grep -q '^count | public functions | 182$' "$work/pre.txt" && grep -q '^count | public tables | 54$' "$work/pre.txt" \
  && grep -q '^count | public indexes | 203$' "$work/pre.txt" && grep -q '^count | public triggers | 85$' "$work/pre.txt" \
  && grep -q '^count | public policies | 58$' "$work/pre.txt" || fail "pre counts are not the 7D production baseline"
grep -q "^budget | $budget | Tape | 2026-01-01..2026-12-31 | amount=50000 | actual=19554.93 | documents=3\$" "$work/pre.txt" \
  || fail "the Tape budget line is not the expected pre-7E figure: $(grep "^budget" "$work/pre.txt")"
echo "ok - precheck passed on the 7D baseline (182/54/203/58/85); Tape actual 19554.93 from 3 documents"

python3 - "supabase/migrations/$migration" "$work/broken.sql" <<'PY2'
import sys
text = open(sys.argv[1]).read()
marker = "\nCOMMIT;\n"
assert text.count(marker) == 1
open(sys.argv[2], "w").write(text.replace(marker, "\nDO $induced$ BEGIN RAISE EXCEPTION 'induced failure before COMMIT'; END $induced$;\nCOMMIT;\n"))
PY2
expect_failure "induced failure before COMMIT" "induced failure before COMMIT" editor "$work/broken.sql"
[ "$(objects)" = "0" ] || fail "partial 7E objects survived the failed migration"
cmp -s "$work/pre.txt" <(fingerprint) || fail "the failed migration left changes behind"
echo "ok - induced failure rolled back completely; the fingerprint is unchanged"

out="$(editor "supabase/migrations/$migration" 2>&1)" || fail "the migration failed: $out"
[ -z "$out" ] || fail "the migration printed output: $out"
echo "ok - migration (as the SQL Editor sends it) returned success with no output"

readonly_editor "$release/postcheck.sql" > "$work/post.txt"
cmp -s "$work/post.txt" <(fingerprint) || fail "postcheck output is not exactly the fingerprint"
echo "ok - postcheck passed (including 7E Spent = pre-7E actual for every active budget)"
node supabase/tests/support/phase7e_release_generate.mjs --pre "$work/pre.txt" --post "$work/post.txt" --check >/dev/null \
  || fail "precheck.sql / postcheck.sql are not what the generator produces from fingerprint.sql on this database"
echo "ok - precheck.sql and postcheck.sql are exactly what the generator produces from fingerprint.sql"

expect_failure "second application" "Phase 7E budget analytics objects already exist unexpectedly" editor "supabase/migrations/$migration"
expect_failure "precheck after the migration" "precheck: Phase 7E objects already exist" readonly_editor "$release/precheck.sql"
cmp -s "$work/post.txt" <(fingerprint) || fail "the refused reapplication changed something"

new_functions='tg_financial_document_removals_append_only|financial_currency_basis|financial_context_is|tg_guard_organization_budget_overlap|tg_guard_posted_invoice|tg_guard_posted_invoice_item|delete_invoice_internal|financial_spend_rows|financial_spend_line_rows|financial_commitment_rows|remove_posted_financial_document|vendor_invoice_storage_deletable|financial_possible_duplicate_ids|financial_outside_budget_ids|financial_assert_range|financial_assert_access|get_financial_spend_summary|get_financial_spend_series|list_financial_vendor_spend|list_financial_product_spend|list_financial_commitments|financial_spend_row_json|list_financial_spend_documents|get_financial_document_detail|list_financial_product_lines|list_financial_document_removals'
changed_functions='post_reviewed_invoice|delete_invoice_permanently|get_budget_summary|get_supply_request_budget_impact|get_budget_purchasing_overview|get_budget_lineage|get_price_intelligence_overview|get_product_price_intelligence'
strip() { grep -v -E "^(function|overloads) \| ($new_functions|$changed_functions) \| " "$1" \
  | grep -v -E "^(table|policies|grants) \| financial_document_removals \| " \
  | grep -v -E "^index \| (financial_document_removals_|invoices_org_posted_spend_idx)" \
  | grep -v -E "^constraint \| financial_document_removals\." \
  | grep -v -E '^trigger \| (financial_document_removals\.financial_document_removals_append_only|invoices\.invoices_posted_guard|invoice_items\.invoice_items_posted_guard|organization_budgets\.organization_budgets_no_overlap) \| ' \
  | grep -v -E '^storage policy \| vendor_invoices_storage_owner_delete \| ' \
  | grep -v -E "^rows \| financial_document_removals count \| " \
  | grep -v -E '^count \| public (functions|tables|indexes|triggers) \| '; }
diff <(strip "$work/pre.txt") <(strip "$work/post.txt") || fail "precheck/postcheck differ outside the documented lines"
delta() { echo $(( $(grep -F "count | public $1 |" "$work/post.txt" | awk -F' [|] ' '{print $3}') - $(grep -F "count | public $1 |" "$work/pre.txt" | awk -F' [|] ' '{print $3}') )); }
[ "$(delta functions)" = "26" ] && [ "$(delta tables)" = "1" ] && [ "$(delta indexes)" = "4" ] \
  && [ "$(delta policies)" = "0" ] && [ "$(delta triggers)" = "4" ] \
  || fail "unexpected object deltas: functions $(delta functions) tables $(delta tables) indexes $(delta indexes) policies $(delta policies) triggers $(delta triggers)"
grep -q '^rows | financial_document_removals count | 0$' "$work/post.txt" || fail "the migration wrote removal records"
for line in 'invoices hash' 'invoice_items hash' 'vendor_invoices hash' 'organization_budgets hash' 'supply_request_commitments hash' 'inventory_items hash'; do
  [ "$(grep -F "rows | $line |" "$work/pre.txt")" = "$(grep -F "rows | $line |" "$work/post.txt")" ] || fail "$line changed"
done
echo "ok - pre/post differ only in documented lines: +26 functions, 8 changed, +1 table (no client access), +4 indexes, +4 triggers, the storage delete policy; no invoice, line, budget, commitment or inventory row changed"

# Compatibility window: the app loaded before the deploy keeps working.
as_user "$owner" "SELECT to_jsonb(s) FROM public.get_budget_summary('$org', '$budget') s" > "$work/new_summary.json"
cmp -s "$work/old_summary.json" "$work/new_summary.json" || fail "get_budget_summary changed: $(cat "$work/old_summary.json") -> $(cat "$work/new_summary.json")"
as_user "$owner" "SELECT public.get_budget_purchasing_overview('$org')" > "$work/new_overview.json"
python3 - "$work/old_overview.json" "$work/new_overview.json" <<'PY2'
import json, sys
old, new = (json.load(open(p)) for p in sys.argv[1:3])
# Same keys everywhere (old clients parse strictly); a null may become a string (order
# confirmations now show their order number in recent purchases), never the reverse.
def shape(v):
    if isinstance(v, dict): return {k: shape(x) for k, x in v.items()}
    if isinstance(v, list): return [shape(v[0])] if v else []
    return "scalar"
assert shape(old) == shape(new), (shape(old), shape(new))
assert old["budgets"] == new["budgets"], "budget figures moved"
PY2
expect_failure "old-app delete of a posted document" "Posted documents must be removed with a recorded reason." \
  as_user "$owner" "SELECT public.delete_invoice_permanently('$org', '7e3f0000-0000-4000-8000-00000000a001')"
as_user "$owner" "SELECT public.delete_invoice_permanently('$org', '7e3f0000-0000-4000-8000-00000000a005')" >/dev/null \
  || fail "deleting an unprocessed upload failed"
[ "$(as_user "$owner" "WITH d AS (DELETE FROM storage.objects WHERE name = '$org/doc-1.pdf' RETURNING 1) SELECT count(*) FROM d")" = "0" ] \
  || fail "a posted document's source file was deletable"
[ "$(as_user "$owner" "WITH d AS (DELETE FROM storage.objects WHERE name = '$org/doc-5.pdf' RETURNING 1) SELECT count(*) FROM d")" = "1" ] \
  || fail "a deleted upload's source file could not be removed"
expect_failure "direct edit of a posted invoice" "Posted documents can't be changed" \
  as_user "$owner" "UPDATE public.invoices SET invoice_total = 1 WHERE id = '7e3f0000-0000-4000-8000-00000000b001'"
as_user "$owner" "SELECT public.post_reviewed_invoice('$org', '7e3f0000-0000-4000-8000-00000000a004')" >/dev/null || fail "old-app posting failed"
echo "ok - compatibility: budget summary and overview identical in shape and figures; posting and draft deletes work; posted documents cannot be deleted, edited or lose their source file"

# The new Spend reads on the FC-like data.
as_user "$admin" "SELECT public.get_financial_spend_summary('$org', NULL, '2026-11-16')" > "$work/spend.json"
python3 - "$work/spend.json" <<'PY2'
import json, sys
s = json.load(open(sys.argv[1]))
assert s["scope"]["budgetName"] == "Tape" and s["spent"] == 19594.93, s["spent"]
assert s["remaining"] == 30405.07, s["remaining"]
assert s["commitments"]["open"]["count"] == 1 and s["commitments"]["open"]["pricedAmount"] == 36.78
assert s["commitments"]["receivedNotSettled"]["count"] == 1
assert s["coverage"]["datedByPosting"]["count"] == 1 and s["coverage"]["orderConfirmations"]["count"] == 1
assert s["coverage"]["legacyNoCurrency"]["count"] == 4
assert s["viewerIsOwner"] is False
PY2
expect_failure "staff Spend read" "Forbidden" as_user "$staff" "SELECT public.get_financial_spend_summary('$org')"
posted_at="$(q "SELECT posted_at FROM public.invoices WHERE id = '7e3f0000-0000-4000-8000-00000000b004'")"
as_user "$owner" "SELECT public.remove_posted_financial_document('$org', '7e3f0000-0000-4000-8000-00000000a004', '$posted_at', 'DRAFT-4', 'Release check removal of a test posting')" >/dev/null \
  || fail "the owner could not remove a posted document"
[ "$(q "SELECT count(*) FROM public.financial_document_removals")" = "1" ] || fail "no removal record"
[ "$(as_user "$owner" "WITH d AS (DELETE FROM storage.objects WHERE name = '$org/doc-4.pdf' RETURNING 1) SELECT count(*) FROM d")" = "0" ] \
  || fail "the removed document's source file was deletable"
echo "ok - Spend summary on FC-like data (admin): Spent 19594.93, Remaining 30405.07, 1 open (36.78) and 1 received commitment; owner removal recorded, source file kept; staff refused"
echo "phase7e_release_check: all checks passed"
