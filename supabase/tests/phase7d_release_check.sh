#!/usr/bin/env bash
# Phase 7D release-script check on a disposable Postgres. Never reads .env files or talks to a
# hosted project.
#
#   1. The migration and every release file are sent the way the Supabase SQL Editor sends them:
#      rewritten by the Editor's "Run and enable RLS" logic (support/studio_sql_editor_rewrite.mjs),
#      then as ONE simple query. The rewrite must flag nothing and change nothing (the migration
#      enables RLS on its table itself); nothing may follow COMMIT; no temp tables.
#   2. Boot a fresh container (logs capped), apply every migration before 7D (main a4c9d81,
#      through 7C), and seed: the 6C.4, 5A.10, 7B.2 and 6C.3 fixtures, storage locations, stock
#      moved between them (existing transfers), a request received to a location (a 7C receipt),
#      one left ordered, a budget and invoices.
#   3. precheck; an induced failure just before COMMIT (must roll back completely); the migration
#      (success, no output); postcheck; a second application and a repeat precheck (both refused).
#      Diff pre and post: only the documented lines may differ.
#   4. After the release: a Move Stock call from an app loaded before the deploy (six named
#      arguments) still works and is recorded as manual; existing transfers are manual; inventory,
#      requests, receipts, commitments, invoices and notifications are unchanged by the release;
#      an owner can create a rule and the calculation reads it, still without touching stock.
#
# Requires Docker, node and public.ecr.aws/supabase/postgres:17.6.1.167.
# Usage: supabase/tests/phase7d_release_check.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
container="medspend_7d_release_$$"
port="${MEDSPEND_7D_RELEASE_PORT:-55785}"
work="$(mktemp -d)"
export PGPASSWORD=postgres PGHOST=127.0.0.1 PGPORT="$port" PGOPTIONS="-c client_min_messages=warning"
migration="20261113120000_phase7d_inventory_replenishment.sql"
rewrite="$root/supabase/tests/support/studio_sql_editor_rewrite.mjs"
release="$root/supabase/release/phase7d"

cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
cd "$root"

for file in "supabase/migrations/$migration" "$release"/*.sql; do
  [ -z "$(node "$rewrite" "$file" --tables)" ] || fail "the SQL Editor would append RLS statements to $file"
  cmp -s "$file" <(node "$rewrite" "$file") || fail "the SQL Editor would rewrite $file"
done
grep -qi "create[[:space:]]\+temp" "supabase/migrations/$migration" && fail "the 7D migration creates temp tables"
python3 - "supabase/migrations/$migration" <<'PY2'
import re, sys
text = open(sys.argv[1]).read()
tail = text[text.rindex("\nCOMMIT;") + len("\nCOMMIT;"):]
sys.exit(0 if re.sub(r"--[^\n]*", "", tail).strip() == "" else 1)
PY2
echo "ok - the SQL Editor sends the 7D migration and release files unchanged; nothing follows COMMIT"

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
# Requests through the real lifecycle (one in flight as ordered, one received to First Team ATR
# through the 7C path), two storage locations with stock moved between them, a budget and
# invoices.
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
INSERT INTO public.inventory_locations (id, organization_id, name, kind, active) VALUES
  ('7d3f0000-0000-4000-8000-000000000301', '$org', 'First Team ATR', 'storage', true),
  ('7d3f0000-0000-4000-8000-000000000302', '$org', 'FCC2 ATR', 'storage', true);
INSERT INTO public.inventory_items (id, organization_id, name, unit, quantity, active)
VALUES ('7d3f0000-0000-4000-8000-000000000401', '$org', 'Release Tape', 'roll', 0, true);
SELECT set_config('request.jwt.claim.sub', '6c3e0000-0000-4000-8000-000000000001', false);
SELECT public.adjust_inventory_location_quantity('$org', '7d3f0000-0000-4000-8000-000000000401',
  (SELECT id FROM public.inventory_locations WHERE organization_id = '$org' AND kind = 'unassigned'), 9, 'Correction');
SELECT public.move_inventory_stock('$org', '7d3f0000-0000-4000-8000-000000000401',
  (SELECT id FROM public.inventory_locations WHERE organization_id = '$org' AND kind = 'unassigned'),
  '7d3f0000-0000-4000-8000-000000000301', 3, 'release-move-1');
SELECT public.move_inventory_stock('$org', '7d3f0000-0000-4000-8000-000000000401',
  '7d3f0000-0000-4000-8000-000000000301', '7d3f0000-0000-4000-8000-000000000302', 1, 'release-move-2');
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
SELECT public.receive_supply_request('$org', current_setting('release.r3')::uuid, 'Arrived', NULL,
  '7d3f0000-0000-4000-8000-000000000301');
INSERT INTO public.organization_budgets (organization_id, name, period_start, period_end, amount)
VALUES ('$org', 'FY Supplies', date '2026-07-01', date '2027-06-30', 50000);
INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type)
SELECT ('7d3f0000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, '6c4e0000-0000-4000-8000-000000000101', '6c4e0000-0000-4000-8000-000000000001',
  '6c4e0000-0000-4000-8000-000000000101/7d3f-' || n || '.pdf', 'Invoice ' || n || '.pdf', 1000 + n, 'application/pdf'
FROM generate_series(1, 3) n;
INSERT INTO public.invoices (organization_id, source_file_id, vendor_name, invoice_number, invoice_date, processing_status, invoice_total)
SELECT '6c4e0000-0000-4000-8000-000000000101', ('7d3f0000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, 'Henry Schein',
  (71000000 + n)::text, date '2026-01-01' + n, 'review_required', 10 * n
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
objects() { q "SELECT (SELECT count(*) FROM pg_class WHERE relname = 'inventory_replenishment_rules') + (SELECT count(*) FROM pg_proc WHERE proname IN ('tg_guard_inventory_replenishment_rule', 'inventory_replenishment_rule_json', 'set_inventory_replenishment_rule', 'set_inventory_replenishment_rule_enabled', 'inventory_replenishment_rows', 'list_inventory_replenishment', 'get_inventory_replenishment_summary', 'list_inventory_location_replenishment_rules')) + (SELECT count(*) FROM information_schema.columns WHERE table_name = 'inventory_transfers' AND column_name = 'source') + (CASE WHEN to_regprocedure('public.move_inventory_stock(uuid, uuid, uuid, uuid, numeric, text)') IS NULL THEN 1 ELSE 0 END)"; }

[ "$(q "SELECT count(*) FROM public.inventory_transfers WHERE idempotency_key LIKE 'release-move-%'")" = "2" ] || fail "the seed did not record two transfers"
[ "$(q "SELECT count(*) FROM public.supply_request_receipts")" = "1" ] || fail "the seed did not record a 7C receipt"

readonly_editor "$release/precheck.sql" > "$work/pre.txt"
cmp -s "$work/pre.txt" <(fingerprint) || fail "precheck output is not exactly the fingerprint"
for line in 'inventory_items hash' 'inventory_location_balances hash' 'inventory_adjustments hash' 'inventory_transfers hash (without source)' \
  'supply_requests hash' 'supply_request_items hash' 'supply_request_receipts hash' 'supply_request_commitments hash' \
  'notification_events hash' 'inventory_count_sessions hash' 'invoices hash'; do
  grep -q "^rows | $line | [0-9a-f]\{32\}\$" "$work/pre.txt" || fail "$line was not fingerprinted"
done
grep -q '^count | public functions | 174$' "$work/pre.txt" && grep -q '^count | public tables | 53$' "$work/pre.txt" \
  && grep -q '^count | public indexes | 199$' "$work/pre.txt" && grep -q '^count | public triggers | 84$' "$work/pre.txt" \
  && grep -q '^count | public policies | 58$' "$work/pre.txt" \
  || fail "pre counts are not the 7C production baseline"
grep -q '^rows | inventory_transfers not manual | absent$' "$work/pre.txt" || fail "the source column exists before 7D"
echo "ok - precheck passed on the 7C baseline (174/53/199/58/84) with transfers, a receipt, a request in flight, stock and invoices"

python3 - "supabase/migrations/$migration" "$work/broken.sql" <<'PY2'
import sys
text = open(sys.argv[1]).read()
marker = "\nCOMMIT;\n"
assert text.count(marker) == 1
open(sys.argv[2], "w").write(text.replace(marker, "\nDO $induced$ BEGIN RAISE EXCEPTION 'induced failure before COMMIT'; END $induced$;\nCOMMIT;\n"))
PY2
expect_failure "induced failure before COMMIT" "induced failure before COMMIT" editor "$work/broken.sql"
[ "$(objects)" = "0" ] || fail "partial 7D objects survived the failed migration"
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
node supabase/tests/support/phase7d_release_generate.mjs --pre "$work/pre.txt" --post "$work/post.txt" --check >/dev/null \
  || fail "precheck.sql / postcheck.sql are not what the generator produces from fingerprint.sql on this database"
echo "ok - precheck.sql and postcheck.sql are exactly what the generator produces from fingerprint.sql"

expect_failure "second application" "Phase 7D replenishment objects already exist unexpectedly" editor "supabase/migrations/$migration"
expect_failure "precheck after the migration" "precheck: Phase 7D objects already exist" readonly_editor "$release/precheck.sql"
cmp -s "$work/post.txt" <(fingerprint) || fail "the refused reapplication changed something"

new_functions='tg_guard_inventory_replenishment_rule|inventory_replenishment_rule_json|set_inventory_replenishment_rule|set_inventory_replenishment_rule_enabled|inventory_replenishment_rows|list_inventory_replenishment|get_inventory_replenishment_summary|list_inventory_location_replenishment_rules|move_inventory_stock'
strip() { grep -v -E "^(function|overloads) \| ($new_functions) \| " "$1" \
  | grep -v -E "^(table|policies|grants) \| inventory_replenishment_rules \| " \
  | grep -v -E "^table \| inventory_transfers \| " \
  | grep -v -E "^index \| inventory_replenishment_rules_" \
  | grep -v -E "^constraint \| inventory_replenishment_rules\." \
  | grep -v -E "^constraint \| inventory_transfers\.inventory_transfers_source_check \| " \
  | grep -v -E '^trigger \| inventory_replenishment_rules\.inventory_replenishment_rules_guard \| ' \
  | grep -v -E "^rows \| (inventory_replenishment_rules count|inventory_transfers not manual) \| " \
  | grep -v -E '^count \| public (functions|tables|indexes|triggers) \| '; }
diff <(strip "$work/pre.txt") <(strip "$work/post.txt") || fail "precheck/postcheck differ outside the documented lines"
delta() { echo $(( $(grep -F "count | public $1 |" "$work/post.txt" | awk -F' [|] ' '{print $3}') - $(grep -F "count | public $1 |" "$work/pre.txt" | awk -F' [|] ' '{print $3}') )); }
[ "$(delta functions)" = "8" ] && [ "$(delta tables)" = "1" ] && [ "$(delta indexes)" = "4" ] \
  && [ "$(delta policies)" = "0" ] && [ "$(delta triggers)" = "1" ] \
  || fail "unexpected object deltas: functions $(delta functions) tables $(delta tables) indexes $(delta indexes) policies $(delta policies) triggers $(delta triggers)"
for prefix in 'function | post_reviewed_invoice' 'function | inventory_apply_balance_delta' 'function | apply_inventory_location_delta' \
  'function | adjust_inventory_location_quantity' 'function | submit_inventory_count' 'function | inventory_workspace_stock_status' \
  'function | inventory_location_count_freshness' 'function | receive_supply_request' 'function | submit_supply_request' \
  'function | notification_approver_digest_content' 'function | is_org_admin' 'table | inventory_items' 'table | inventory_location_balances' \
  'grants | inventory_transfers' 'policies | inventory_transfers' \
  'rows | inventory_items hash' 'rows | inventory_location_balances hash' 'rows | inventory_adjustments hash' \
  'rows | inventory_transfers hash (without source)' 'rows | supply_requests hash' 'rows | supply_request_items hash' \
  'rows | supply_request_receipts hash' 'rows | supply_request_commitments hash' 'rows | notification_events hash' \
  'rows | notification_deliveries hash' 'rows | invoices hash' 'rows | inventory_count_policies hash'; do
  before="$(grep -F "$prefix |" "$work/pre.txt")"
  [ -n "$before" ] || fail "$prefix is not fingerprinted"
  if echo "$before" | grep -q ' | absent$'; then fail "$prefix is absent before the migration"; fi
  [ "$before" = "$(grep -F "$prefix |" "$work/post.txt")" ] || fail "$prefix changed"
done
grep -q '^rows | inventory_replenishment_rules count | 0$' "$work/post.txt" || fail "the migration wrote rules"
grep -q '^rows | inventory_transfers not manual | 0$' "$work/post.txt" || fail "an existing transfer is not manual"
grep -q '^overloads | move_inventory_stock | 1$' "$work/pre.txt" && grep -q '^overloads | move_inventory_stock | 1$' "$work/post.txt" \
  || fail "move_inventory_stock must have exactly one signature before and after"
echo "ok - pre/post differ only in documented lines: +8 functions, move_inventory_stock changed, +1 table (no client access), inventory_transfers +source, +4 indexes, +1 constraint, +1 trigger; no inventory, request, receipt, commitment, invoice or notification row changed"

# After the release.
owner_sql() { psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres -At -c "SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub', '6c3e0000-0000-4000-8000-000000000001', false); $1"; }
unassigned="$(q "SELECT id FROM public.inventory_locations WHERE organization_id = '$org' AND kind = 'unassigned'")"
owner_sql "SELECT public.move_inventory_stock(_organization_id => '$org', _inventory_item_id => '7d3f0000-0000-4000-8000-000000000401',
  _from_inventory_location_id => '$unassigned', _to_inventory_location_id => '7d3f0000-0000-4000-8000-000000000302', _quantity => 1,
  _idempotency_key => 'release-old-app')" >/dev/null || fail "an old-app Move Stock call failed after the release"
[ "$(q "SELECT source FROM public.inventory_transfers WHERE idempotency_key = 'release-old-app'")" = "manual" ] || fail "the old-app move is not manual"
[ "$(q "SELECT string_agg(source, ',' ORDER BY idempotency_key) FROM public.inventory_transfers WHERE idempotency_key LIKE 'release-move-%'")" = "manual,manual" ] \
  || fail "pre-release transfers are not manual"
echo "ok - an app loaded before the deploy moves stock with six named arguments (recorded manual); existing transfers are manual"
fingerprint > "$work/before_rule.txt"
owner_sql "SELECT public.set_inventory_replenishment_rule('$org', '7d3f0000-0000-4000-8000-000000000401', '7d3f0000-0000-4000-8000-000000000302', 2, 5)" >/dev/null \
  || fail "the owner could not create a rule"
[ "$(q "SELECT category || ' ' || current_quantity || ' ' || shortage_quantity FROM public.inventory_replenishment_rows('$org')")" = "move_available 2 3" ] \
  || fail "the calculation does not read the new rule: $(q "SELECT to_jsonb(r) FROM public.inventory_replenishment_rows('$org') r")"
fingerprint > "$work/after_rule.txt"
for line in 'inventory_items hash' 'inventory_location_balances hash' 'inventory_adjustments hash' 'inventory_transfers hash (without source)' 'supply_requests hash' 'notification_events hash'; do
  [ "$(grep -F "rows | $line |" "$work/before_rule.txt")" = "$(grep -F "rows | $line |" "$work/after_rule.txt")" ] || fail "creating a rule changed $line"
done
echo "ok - after the release an owner rule is read by the calculation (FCC2 ATR 2 <= 2: move available, short 3) and changes no stock, transfer, request or notification"
echo "--- documented pre/post differences"
diff "$work/pre.txt" "$work/post.txt" | grep -E "^[<>]" | grep -v -E '^[<>] (function|overloads|index|constraint) \| ' || true
echo "phase7d_release_check: all checks passed"
