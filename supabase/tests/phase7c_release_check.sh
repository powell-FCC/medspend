#!/usr/bin/env bash
# Phase 7C release-script check on a disposable Postgres. Never reads .env files or talks to a
# hosted project.
#
#   1. The migration and every release file are sent the way the Supabase SQL Editor sends them:
#      rewritten by the Editor's "Run and enable RLS" logic (support/studio_sql_editor_rewrite.mjs),
#      then as ONE simple query. The rewrite must flag nothing and change nothing (the migration
#      enables RLS on its table itself); nothing may follow COMMIT; no temp tables.
#   2. Boot a fresh container (logs capped), apply every migration before 7C (main 8448f4c,
#      through 7C.0), and seed: the 6C.4, 5A.10, 7B.2 and 6C.3 fixtures plus requests through the
#      real lifecycle, including one left ordered (in flight across the release) and one received
#      through the 7C.0 receive path (no receipt), a storage location, stock, a budget and invoices.
#   3. precheck; an induced failure just before COMMIT (must roll back completely); the migration
#      (success, no output); postcheck; a second application and a repeat precheck (both refused).
#      Diff pre and post: only the documented lines may differ.
#   4. After the release: the destination-less calls an app loaded before the deploy makes are
#      refused with the refresh message; the generic transition cannot receive; the in-flight
#      ordered request is received with a destination (one receipt, inventory and invoices
#      unchanged); the request received before the release completes without a receipt.
#
# Requires Docker, node and public.ecr.aws/supabase/postgres:17.6.1.167.
# Usage: supabase/tests/phase7c_release_check.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
container="medspend_7c_release_$$"
port="${MEDSPEND_7C_RELEASE_PORT:-55685}"
work="$(mktemp -d)"
export PGPASSWORD=postgres PGHOST=127.0.0.1 PGPORT="$port" PGOPTIONS="-c client_min_messages=warning"
migration="20261112140000_phase7c_receiving_destination.sql"
rewrite="$root/supabase/tests/support/studio_sql_editor_rewrite.mjs"
release="$root/supabase/release/phase7c"

cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
cd "$root"

for file in "supabase/migrations/$migration" "$release"/*.sql; do
  [ -z "$(node "$rewrite" "$file" --tables)" ] || fail "the SQL Editor would append RLS statements to $file"
  cmp -s "$file" <(node "$rewrite" "$file") || fail "the SQL Editor would rewrite $file"
done
grep -qi "create[[:space:]]\+temp" "supabase/migrations/$migration" && fail "the 7C migration creates temp tables"
python3 - "supabase/migrations/$migration" <<'PY' || fail "statements follow the final COMMIT"
import re, sys
text = open(sys.argv[1]).read()
tail = text[text.rindex("\nCOMMIT;") + len("\nCOMMIT;"):]
sys.exit(0 if re.sub(r"--[^\n]*", "", tail).strip() == "" else 1)
PY
echo "ok - the SQL Editor sends the 7C migration and release files unchanged; nothing follows COMMIT"

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
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f supabase/tests/integration/phase6c4_batch_intake_fixture.sql >/dev/null
PGOPTIONS="-c client_min_messages=error" psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f supabase/tests/integration/phase5a10_discovery_fixture.sql >/dev/null
PGOPTIONS="-c client_min_messages=error" psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f supabase/tests/integration/phase7b2_count_history_fixture.sql >/dev/null
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f supabase/tests/integration/phase6c3_notifications_fixture.sql >/dev/null
org=6c3e0000-0000-4000-8000-000000000101
# Requests through the real lifecycle (one in flight as ordered, one received through the 7C.0
# path), a storage location, stock in Unassigned, a budget and invoices.
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
INSERT INTO public.inventory_locations (id, organization_id, name, kind, active)
VALUES ('7c3f0000-0000-4000-8000-000000000301', '$org', 'First Team ATR', 'storage', true);
INSERT INTO public.inventory_items (id, organization_id, name, unit, quantity, active)
VALUES ('7c3f0000-0000-4000-8000-000000000401', '$org', 'Release Tape', 'roll', 0, true);
SELECT set_config('request.jwt.claim.sub', '6c3e0000-0000-4000-8000-000000000001', false);
SELECT public.adjust_inventory_location_quantity('$org', '7c3f0000-0000-4000-8000-000000000401',
  (SELECT id FROM public.inventory_locations WHERE organization_id = '$org' AND kind = 'unassigned'), 9, 'Correction');
SELECT set_config('request.jwt.claim.sub', '6c3e0000-0000-4000-8000-000000000003', false);
SELECT set_config('release.r' || n, public.submit_supply_request('$org', 'reorder', NULL, NULL, 'Release ' || n,
  jsonb_build_array(jsonb_build_object('freeTextItem', 'Release line ' || n, 'quantity', n)))::text, false)
FROM generate_series(1, 4) n;
SELECT set_config('request.jwt.claim.sub', '6c3e0000-0000-4000-8000-000000000002', false);
SELECT public.decide_supply_request('$org', current_setting('release.r1')::uuid, 'approved', 'ok', 'internal',
  (SELECT updated_at FROM public.supply_requests WHERE id = current_setting('release.r1')::uuid));
SELECT public.decide_supply_request('$org', current_setting('release.r2')::uuid, 'denied', 'no', NULL,
  (SELECT updated_at FROM public.supply_requests WHERE id = current_setting('release.r2')::uuid));
SELECT public.decide_supply_request('$org', current_setting('release.r3')::uuid, 'approved', NULL, NULL,
  (SELECT updated_at FROM public.supply_requests WHERE id = current_setting('release.r3')::uuid));
SELECT public.transition_supply_request('$org', current_setting('release.r1')::uuid, 'ordered', NULL, 'Ordered');
SELECT public.transition_supply_request('$org', current_setting('release.r3')::uuid, 'ordered');
SELECT public.receive_supply_request('$org', current_setting('release.r3')::uuid);
INSERT INTO public.organization_budgets (organization_id, name, period_start, period_end, amount)
VALUES ('$org', 'FY Supplies', date '2026-07-01', date '2027-06-30', 50000);
INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type)
SELECT ('7c3f0000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, '6c4e0000-0000-4000-8000-000000000101', '6c4e0000-0000-4000-8000-000000000001',
  '6c4e0000-0000-4000-8000-000000000101/7c3f-' || n || '.pdf', 'Invoice ' || n || '.pdf', 1000 + n, 'application/pdf'
FROM generate_series(1, 3) n;
INSERT INTO public.invoices (organization_id, source_file_id, vendor_name, invoice_number, invoice_date, processing_status, invoice_total)
SELECT '6c4e0000-0000-4000-8000-000000000101', ('7c3f0000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, 'Henry Schein',
  (70000000 + n)::text, date '2026-01-01' + n, 'review_required', 10 * n
FROM generate_series(1, 3) n;
SQL
q() { psql -X -U postgres -d postgres -Atc "$1"; }
r1="$(q "SELECT id FROM public.supply_requests WHERE organization_id = '$org' AND status = 'ordered' ORDER BY created_at, id LIMIT 1")"
r3="$(q "SELECT id FROM public.supply_requests WHERE organization_id = '$org' AND status = 'received' ORDER BY created_at, id LIMIT 1")"
[ -n "$r1" ] && [ -n "$r3" ] || fail "the seed did not leave an ordered and a received request"

editor() { psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres -At -F ' | ' -c "$(node "$rewrite" "$1")"; }
readonly_editor() { PGOPTIONS="$PGOPTIONS -c default_transaction_read_only=on" editor "$@"; }
fingerprint() { readonly_editor "$release/fingerprint.sql"; }
expect_failure() {  # <label> <expected message> <command...>
  local label="$1" expected="$2"; shift 2
  if out="$("$@" 2>&1)"; then fail "$label unexpectedly succeeded"; fi
  echo "$out" | grep -qF "$expected" || fail "$label: unexpected error: $out"
  echo "ok - $label refused: $expected"
}
objects() { q "SELECT (SELECT count(*) FROM pg_class WHERE relname = 'supply_request_receipts') + (SELECT count(*) FROM pg_proc WHERE proname IN ('list_receiving_destinations', 'list_supply_request_receipts', 'guard_supply_request_receipt_immutable')) + (SELECT count(*) FROM pg_trigger WHERE tgname = 'supply_request_receipts_immutable') + (CASE WHEN to_regprocedure('public.apply_supply_request_receipt(uuid, uuid, uuid, text, text, text)') IS NULL THEN 0 ELSE 1 END)"; }

readonly_editor "$release/precheck.sql" > "$work/pre.txt"
cmp -s "$work/pre.txt" <(fingerprint) || fail "precheck output is not exactly the fingerprint"
for line in 'supply_requests hash' 'supply_request_updates hash' 'supply_request_items hash' 'supply_request_commitments hash' \
  'notification_events hash' 'organizations hash' 'organization_memberships hash' 'invoices hash' 'inventory_items hash' \
  'inventory_locations hash' 'inventory_location_balances hash' 'inventory_adjustments hash'; do
  grep -q "^rows | $line | [0-9a-f]\{32\}\$" "$work/pre.txt" || fail "$line was not fingerprinted"
done
grep -q '^count | public functions | 171$' "$work/pre.txt" && grep -q '^count | public tables | 52$' "$work/pre.txt" \
  && grep -q '^count | public indexes | 194$' "$work/pre.txt" && grep -q '^count | public triggers | 83$' "$work/pre.txt" \
  || fail "pre counts are not the 7C.0 production baseline"
echo "ok - precheck passed on the 7C.0 baseline (171/52/194/58/83) with requests in flight, receipts, stock and invoices"

python3 - "supabase/migrations/$migration" "$work/broken.sql" <<'PY'
import sys
text = open(sys.argv[1]).read()
marker = "\nCOMMIT;\n"
assert text.count(marker) == 1
open(sys.argv[2], "w").write(text.replace(marker, "\nDO $induced$ BEGIN RAISE EXCEPTION 'induced failure before COMMIT'; END $induced$;\nCOMMIT;\n"))
PY
expect_failure "induced failure before COMMIT" "induced failure before COMMIT" editor "$work/broken.sql"
[ "$(objects)" = "0" ] || fail "partial 7C objects survived the failed migration"
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
node supabase/tests/support/phase7c_release_generate.mjs --pre "$work/pre.txt" --post "$work/post.txt" --check >/dev/null \
  || fail "precheck.sql / postcheck.sql are not what the generator produces from fingerprint.sql on this database"
echo "ok - precheck.sql and postcheck.sql are exactly what the generator produces from fingerprint.sql"

expect_failure "second application" "Phase 7C receiving destination objects already exist unexpectedly" editor "supabase/migrations/$migration"
expect_failure "precheck after the migration" "precheck: Phase 7C objects already exist" readonly_editor "$release/precheck.sql"
cmp -s "$work/post.txt" <(fingerprint) || fail "the refused reapplication changed something"

new_functions='guard_supply_request_receipt_immutable|list_receiving_destinations|list_supply_request_receipts|apply_supply_request_receipt|receive_supply_request|receive_and_complete_supply_request|transition_supply_request'
strip() { grep -v -E "^(function|overloads) \| ($new_functions) \| " "$1" \
  | grep -v -E "^(table|policies|grants) \| supply_request_receipts \| " \
  | grep -v -E "^index \| supply_request_receipts" \
  | grep -v -E "^constraint \| supply_request_receipts\." \
  | grep -v -E '^trigger \| supply_request_receipts\.supply_request_receipts_immutable \| ' \
  | grep -v -E "^rows \| supply_request_receipts count \| " \
  | grep -v -E '^count \| public (functions|tables|indexes|triggers) \| '; }
diff <(strip "$work/pre.txt") <(strip "$work/post.txt") || fail "precheck/postcheck differ outside the documented lines"
delta() { echo $(( $(grep -F "count | public $1 |" "$work/post.txt" | awk -F' [|] ' '{print $3}') - $(grep -F "count | public $1 |" "$work/pre.txt" | awk -F' [|] ' '{print $3}') )); }
[ "$(delta functions)" = "3" ] && [ "$(delta tables)" = "1" ] && [ "$(delta indexes)" = "5" ] \
  && [ "$(delta policies)" = "0" ] && [ "$(delta triggers)" = "1" ] \
  || fail "unexpected object deltas: functions $(delta functions) tables $(delta tables) indexes $(delta indexes) policies $(delta policies) triggers $(delta triggers)"
for prefix in 'function | decide_supply_request' 'function | apply_supply_request_transition' 'function | approve_and_order_supply_request' \
  'function | post_reviewed_invoice' 'function | delete_invoice_permanently' 'function | move_inventory_stock' 'function | apply_inventory_location_delta' \
  'function | capture_supply_request_decision_notification' 'function | notification_approver_digest_content' 'function | is_org_admin' \
  'table | supply_requests' 'table | supply_request_updates' 'table | inventory_locations' 'table | inventory_items' \
  'rows | supply_requests hash' 'rows | supply_request_updates hash' 'rows | inventory_items hash' 'rows | inventory_location_balances hash' \
  'rows | inventory_adjustments hash' 'rows | inventory_transfers hash' 'rows | invoices hash' 'rows | notification_events hash'; do
  before="$(grep -F "$prefix |" "$work/pre.txt")"
  [ -n "$before" ] || fail "$prefix is not fingerprinted"
  if echo "$before" | grep -q ' | absent$'; then fail "$prefix is absent before the migration"; fi
  [ "$before" = "$(grep -F "$prefix |" "$work/post.txt")" ] || fail "$prefix changed"
done
grep -q '^rows | supply_request_receipts count | 0$' "$work/post.txt" || fail "the migration wrote receipts"
echo "ok - pre/post differ only in documented lines: +3 functions, 4 changed functions, +1 table (no client access), +5 indexes, +1 trigger; no request, history, notification, inventory or invoice row changed"

# After the release.
admin_sql() { psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres -At -c "SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub', '6c3e0000-0000-4000-8000-000000000002', false); $1"; }
expect_failure "Mark Received from an app loaded before the deploy" "Refresh SportSpend and choose a receiving destination" admin_sql "SELECT public.receive_supply_request('$org', '$r1')"
expect_failure "the generic transition to received" "Use the receiving action to choose a receiving destination" admin_sql "SELECT public.transition_supply_request('$org', '$r1', 'received')"
dest="$(admin_sql "SELECT id FROM public.list_receiving_destinations('$org') WHERE name = 'First Team ATR'" | tail -1)"
[ -n "$dest" ] || fail "the storage location is not offered as a destination"
admin_sql "SELECT public.receive_supply_request('$org', '$r1', 'Arrived', NULL, '$dest')" >/dev/null
[ "$(q "SELECT count(*) || ':' || string_agg(destination_name_snapshot || '/' || destination_kind, ',') FROM public.supply_request_receipts WHERE supply_request_id = '$r1'")" = "1:First Team ATR/storage" ] \
  || fail "the in-flight request did not get exactly one receipt"
fingerprint > "$work/after.txt"
for line in 'inventory_items hash' 'inventory_location_balances hash' 'inventory_adjustments hash' 'inventory_transfers hash' 'invoices hash' 'supply_request_commitments hash'; do
  [ "$(grep -F "rows | $line |" "$work/post.txt")" = "$(grep -F "rows | $line |" "$work/after.txt")" ] || fail "receiving changed $line"
done
admin_sql "SELECT public.transition_supply_request('$org', '$r3', 'completed')" >/dev/null
[ "$(q "SELECT status FROM public.supply_requests WHERE id = '$r3'")" = "completed" ] && [ "$(q "SELECT count(*) FROM public.supply_request_receipts WHERE supply_request_id = '$r3'")" = "0" ] \
  || fail "the request received before the release did not complete without a receipt"
echo "ok - after the release: old calls refused with the refresh message, generic receipt closed, the in-flight request received with one receipt and no inventory, invoice or commitment change, the pre-release receipt completed"
echo "--- documented pre/post differences"
diff "$work/pre.txt" "$work/post.txt" | grep -E "^[<>]" | grep -v -E '^[<>] (function|overloads|index|constraint) \| ' || true
echo "phase7c_release_check: all checks passed"
