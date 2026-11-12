#!/usr/bin/env bash
# Phase 7C.0 release-script check on a disposable Postgres. Never reads .env files or talks
# to a hosted project.
#
#   1. The migration and every release file are sent the way the Supabase SQL Editor sends
#      them: rewritten by the Editor's "Run and enable RLS" logic
#      (support/studio_sql_editor_rewrite.mjs), then as ONE simple query. The rewrite must
#      flag nothing and change nothing (the migration enables RLS on its table itself);
#      nothing may follow COMMIT; no temp tables.
#   2. Boot a fresh container, apply every migration before 7C.0 (main 79a2c49, through 6C.3),
#      and seed: the 6C.4, 5A.10, 7B.2 and 6C.3 fixtures plus requests decided and ordered
#      through the real lifecycle (update rows, a commitment, notification events), a budget
#      and invoices, so the request, history, notification, membership, profile, budget,
#      invoice and inventory lines hash real rows.
#   3. precheck; an induced failure just before COMMIT (must roll back completely); the
#      migration (success, no output); postcheck; a second application and a repeat precheck
#      (both refused). Diff pre and post: only the documented lines may differ.
#   4. After the postcheck every organization is Detailed: Approve & Order and Receive &
#      Complete are refused, the plain lifecycle still works, an approval still raises exactly
#      one Approved event, and no history row carries a compound marker.
#
# Requires Docker, node and public.ecr.aws/supabase/postgres:17.6.1.167.
# Usage: supabase/tests/phase7c0_release_check.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
container="medspend_7c0_release_$$"
port="${MEDSPEND_7C0_RELEASE_PORT:-55645}"
work="$(mktemp -d)"
export PGPASSWORD=postgres PGHOST=127.0.0.1 PGPORT="$port" PGOPTIONS="-c client_min_messages=warning"
fix="20261112110000_decide_stale_screen_sqlstate.sql"
migration="20261112120000_phase7c0_request_workflow_profiles.sql"
rewrite="$root/supabase/tests/support/studio_sql_editor_rewrite.mjs"
release="$root/supabase/release/phase7c0"

cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
cd "$root"

for file in "supabase/migrations/$fix" "supabase/migrations/$migration" "$release"/*.sql; do
  [ -z "$(node "$rewrite" "$file" --tables)" ] || fail "the SQL Editor would append RLS statements to $file"
  cmp -s "$file" <(node "$rewrite" "$file") || fail "the SQL Editor would rewrite $file"
done
for file in "supabase/migrations/$fix" "supabase/migrations/$migration"; do
  grep -qi "create[[:space:]]\+temp" "$file" && fail "$file creates temp tables"
  python3 - "$file" <<'PY' || fail "statements follow the final COMMIT in $file"
import re, sys
text = open(sys.argv[1]).read()
tail = text[text.rindex("\nCOMMIT;") + len("\nCOMMIT;"):]
sys.exit(0 if re.sub(r"--[^\n]*", "", tail).strip() == "" else 1)
PY
done
echo "ok - the SQL Editor sends the 7C.0 migration and release files unchanged; nothing follows COMMIT"

docker run -d --name "$container" -e POSTGRES_PASSWORD=postgres -p "127.0.0.1:$port:5432" \
  public.ecr.aws/supabase/postgres:17.6.1.167 >/dev/null
for _ in $(seq 1 60); do
  if psql -U supabase_admin -d postgres -Atc "select 1 from pg_roles where rolname = 'authenticator'" 2>/dev/null | grep -q 1; then break; fi
  sleep 2
done
sleep 5
psql -q -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -f supabase/tests/integration/local_stack_setup.sql >/dev/null
for file in supabase/migrations/*.sql; do
  [[ "$(basename "$file")" < "$fix" ]] || continue
  psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f "$file" >/dev/null
done
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f supabase/tests/integration/phase6c4_batch_intake_fixture.sql >/dev/null
PGOPTIONS="-c client_min_messages=error" psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f supabase/tests/integration/phase5a10_discovery_fixture.sql >/dev/null
PGOPTIONS="-c client_min_messages=error" psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f supabase/tests/integration/phase7b2_count_history_fixture.sql >/dev/null
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f supabase/tests/integration/phase6c3_notifications_fixture.sql >/dev/null
# Requests through the real lifecycle (update rows and a commitment), a budget, invoices, stock.
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<'SQL'
SELECT set_config('request.jwt.claim.sub', '6c3e0000-0000-4000-8000-000000000003', false);
SELECT set_config('release.r' || n, public.submit_supply_request('6c3e0000-0000-4000-8000-000000000101', 'reorder', NULL, NULL, 'Release ' || n,
  jsonb_build_array(jsonb_build_object('freeTextItem', 'Release line ' || n, 'quantity', n)))::text, false)
FROM generate_series(1, 4) n;
SELECT set_config('request.jwt.claim.sub', '6c3e0000-0000-4000-8000-000000000002', false);
SELECT public.decide_supply_request('6c3e0000-0000-4000-8000-000000000101', current_setting('release.r1')::uuid, 'approved', 'ok', 'internal',
  (SELECT updated_at FROM public.supply_requests WHERE id = current_setting('release.r1')::uuid));
SELECT public.decide_supply_request('6c3e0000-0000-4000-8000-000000000101', current_setting('release.r2')::uuid, 'denied', 'no', NULL,
  (SELECT updated_at FROM public.supply_requests WHERE id = current_setting('release.r2')::uuid));
SELECT public.transition_supply_request('6c3e0000-0000-4000-8000-000000000101', current_setting('release.r1')::uuid, 'ordered', NULL, 'Ordered');
INSERT INTO public.organization_budgets (organization_id, name, period_start, period_end, amount)
VALUES ('6c3e0000-0000-4000-8000-000000000101', 'FY Supplies', date '2026-07-01', date '2027-06-30', 50000);
INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type)
SELECT ('6c3f0000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, '6c4e0000-0000-4000-8000-000000000101', '6c4e0000-0000-4000-8000-000000000001',
  '6c4e0000-0000-4000-8000-000000000101/6c3f-' || n || '.pdf', 'Invoice ' || n || '.pdf', 1000 + n, 'application/pdf'
FROM generate_series(1, 3) n;
INSERT INTO public.invoices (organization_id, source_file_id, vendor_name, invoice_number, invoice_date, processing_status, invoice_total)
SELECT '6c4e0000-0000-4000-8000-000000000101', ('6c3f0000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, 'Henry Schein',
  (60000000 + n)::text, date '2026-01-01' + n, 'review_required', 10 * n
FROM generate_series(1, 3) n;
SQL
# 6C.3 is applied: the submissions and decisions above raised notification events.

editor() { psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres -At -F ' | ' -c "$(node "$rewrite" "$1")"; }
readonly_editor() { PGOPTIONS="$PGOPTIONS -c default_transaction_read_only=on" editor "$@"; }
fingerprint() { readonly_editor "$release/fingerprint.sql"; }
expect_failure() {  # <label> <expected message> <command...>
  local label="$1" expected="$2"; shift 2
  if out="$("$@" 2>&1)"; then fail "$label unexpectedly succeeded"; fi
  echo "$out" | grep -qF "$expected" || fail "$label: unexpected error: $out"
  echo "ok - $label refused: $expected"
}
objects() { psql -X -U postgres -d postgres -Atc "SELECT (SELECT count(*) FROM pg_class WHERE relname = 'organization_request_workflow_settings') + (SELECT count(*) FROM information_schema.columns WHERE table_name = 'supply_request_updates' AND column_name = 'compound_action') + (SELECT count(*) FROM pg_proc WHERE proname IN ('approve_and_order_supply_request', 'receive_and_complete_supply_request', 'receive_supply_request', 'apply_supply_request_receipt')) + (SELECT count(*) FROM pg_trigger WHERE tgname = 'supply_request_updates_compound_action_guard')"; }

readonly_editor "$release/precheck.sql" > "$work/pre.txt"
cmp -s "$work/pre.txt" <(fingerprint) || fail "precheck output is not exactly the fingerprint"
for line in 'supply_requests hash' 'supply_request_updates hash' 'supply_request_items hash' 'supply_request_commitments hash' \
  'notification_events hash' 'organizations hash' 'organization_memberships hash' 'profiles hash' 'organization_budgets hash' 'invoices hash' 'inventory_items hash'; do
  grep -q "^rows | $line | [0-9a-f]\{32\}\$" "$work/pre.txt" || fail "$line was not fingerprinted"
done
grep -q '^count | public functions | 161$' "$work/pre.txt" && grep -q '^count | public tables | 51$' "$work/pre.txt" \
  && grep -q '^count | public indexes | 193$' "$work/pre.txt" && grep -q '^count | public triggers | 81$' "$work/pre.txt" \
  || fail "pre counts are not the 6C.3 production baseline"
echo "ok - precheck passed on the 6C.3 baseline (161/51/193/58/81) with requests, decisions, events, memberships, budgets and invoices"

for name in "$fix" "$migration"; do
  python3 - "supabase/migrations/$name" "$work/broken.sql" <<'PY'
import sys
text = open(sys.argv[1]).read()
marker = "\nCOMMIT;\n"
assert text.count(marker) == 1
open(sys.argv[2], "w").write(text.replace(marker, "\nDO $induced$ BEGIN RAISE EXCEPTION 'induced failure before COMMIT'; END $induced$;\nCOMMIT;\n"))
PY
  expect_failure "induced failure before COMMIT ($name)" "induced failure before COMMIT" editor "$work/broken.sql"
  [ "$(objects)" = "0" ] || fail "partial 7C.0 objects survived the failed migration"
  cmp -s "$work/pre.txt" <(fingerprint) || fail "the failed $name left changes behind"
done
readonly_editor "$release/precheck.sql" > "$work/pre_again.txt"
cmp -s "$work/pre.txt" "$work/pre_again.txt" || fail "precheck changed after the failed attempts"
echo "ok - induced failures in both migrations rolled back completely; precheck passes again"

for name in "$fix" "$migration"; do
  out="$(editor "supabase/migrations/$name" 2>&1)" || fail "$name failed: $out"
  [ -z "$out" ] || fail "$name printed output: $out"
done
echo "ok - both migrations (as the SQL Editor sends them, in order) returned success with no output"

readonly_editor "$release/postcheck.sql" > "$work/post.txt"
cmp -s "$work/post.txt" <(fingerprint) || fail "postcheck output is not exactly the fingerprint"
echo "ok - postcheck passed"
node supabase/tests/support/phase7c0_release_generate.mjs --pre "$work/pre.txt" --post "$work/post.txt" --check >/dev/null \
  || fail "precheck.sql / postcheck.sql are not what the generator produces from fingerprint.sql on this database"
echo "ok - precheck.sql and postcheck.sql are exactly what the generator produces from fingerprint.sql"

expect_failure "second application of the stale-screen fix" "decide_supply_request no longer raises 40001" editor "supabase/migrations/$fix"
expect_failure "second application" "Phase 7C.0 workflow profile objects already exist unexpectedly" editor "supabase/migrations/$migration"
expect_failure "precheck after the migration" "precheck: Phase 7C.0 objects already exist" readonly_editor "$release/precheck.sql"
cmp -s "$work/post.txt" <(fingerprint) || fail "the refused reapplication changed something"

new_functions='approve_and_order_supply_request|apply_supply_request_receipt|get_organization_request_workflow_settings|get_request_workflow_profile|guard_supply_request_update_compound_action|mark_supply_request_compound_action|organization_request_workflow_profile|receive_and_complete_supply_request|receive_supply_request|update_organization_request_workflow_settings|list_staff_supply_request_updates|decide_supply_request'
strip() { grep -v -E "^(function|overloads) \| ($new_functions) \| " "$1" \
  | grep -v -E "^(table|policies|grants) \| organization_request_workflow_settings \| " \
  | grep -v -E "^table \| supply_request_updates \| " \
  | grep -v -E "^index \| organization_request_workflow_settings" \
  | grep -v -E "^constraint \| (organization_request_workflow_settings\.|supply_request_updates\.supply_request_updates_compound_action_check \| )" \
  | grep -v -E '^trigger \| (organization_request_workflow_settings\.organization_request_workflow_settings_updated_at|supply_request_updates\.supply_request_updates_compound_action_guard) \| ' \
  | grep -v -E "^rows \| organization_request_workflow_settings count \| " \
  | grep -v -E '^count \| public (functions|tables|indexes|triggers) \| '; }
diff <(strip "$work/pre.txt") <(strip "$work/post.txt") || fail "precheck/postcheck differ outside the documented lines"
delta() { echo $(( $(grep -F "count | public $1 |" "$work/post.txt" | awk -F' [|] ' '{print $3}') - $(grep -F "count | public $1 |" "$work/pre.txt" | awk -F' [|] ' '{print $3}') )); }
[ "$(delta functions)" = "10" ] && [ "$(delta tables)" = "1" ] && [ "$(delta indexes)" = "1" ] \
  && [ "$(delta policies)" = "0" ] && [ "$(delta triggers)" = "2" ] \
  || fail "unexpected object deltas: functions $(delta functions) tables $(delta tables) indexes $(delta indexes) policies $(delta policies) triggers $(delta triggers)"
[ "$(grep -F 'function | decide_supply_request |' "$work/pre.txt")" != "$(grep -F 'function | decide_supply_request |' "$work/post.txt")" ] \
  || fail "decide_supply_request was expected to change (stale-screen SQLSTATE)"
grep -F 'function | decide_supply_request |' "$work/post.txt" | grep -q 'secdef=true authenticated=true anon=false service_role=true public=false$' \
  || fail "decide_supply_request access changed"
for prefix in 'function | submit_supply_request' 'function | transition_supply_request' \
  'function | apply_supply_request_transition' 'function | create_supply_request_commitment' 'function | is_org_admin' 'function | has_org_role' \
  'function | capture_supply_request_decision_notification' 'function | notification_approver_digest_content' 'function | dispatch_notification_events' \
  'function | post_reviewed_invoice' 'function | get_budget_purchasing_overview' 'function | move_inventory_stock' \
  'function | create_invoice_upload_batch' 'function | get_staff_product_discovery' \
  'table | supply_requests' 'table | organization_memberships' 'table | profiles' 'table | organizations' \
  'policies | supply_requests' 'grants | supply_requests' 'policies | supply_request_updates' 'grants | supply_request_updates' \
  'trigger | supply_requests.supply_requests_lifecycle_guard' 'trigger | supply_request_updates.supply_request_updates_decision_notification' \
  'rows | supply_requests hash' 'rows | supply_request_updates hash' 'rows | supply_request_commitments hash' 'rows | notification_events hash' \
  'rows | organizations hash' 'rows | organization_memberships hash' 'rows | invoices hash' 'rows | inventory_items hash'; do
  before="$(grep -F "$prefix |" "$work/pre.txt")"
  [ -n "$before" ] || fail "$prefix is not fingerprinted"
  if echo "$before" | grep -q ' | absent$'; then fail "$prefix is absent before the migration"; fi
  [ "$before" = "$(grep -F "$prefix |" "$work/post.txt")" ] || fail "$prefix changed"
done
[ "$(grep -c '^function | ' "$work/pre.txt")" = "54" ] || fail "expected 54 function pins (10 new, 2 changed, 42 unchanged), got $(grep -c '^function | ' "$work/pre.txt")"
grep -q '^rows | organization_request_workflow_settings count | 0$' "$work/post.txt" \
  && grep -q '^rows | supply_request_updates with compound_action | 0$' "$work/post.txt" \
  || fail "the migration wrote settings or compound markers"
echo "ok - pre/post differ only in documented lines: +10 functions, decide_supply_request (stale screen 55000) and list_staff_supply_request_updates changed, +1 table (no client access), +1 column, +1 index, +2 triggers; no request, history, notification, membership, budget, invoice or inventory row changed"

# After the release: no organization has a settings row, so every organization is Detailed.
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<'SQL'
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '6c3e0000-0000-4000-8000-000000000003', false);
SELECT set_config('release.after', public.submit_supply_request('6c3e0000-0000-4000-8000-000000000101', 'reorder', NULL, NULL, NULL,
  '[{"freeTextItem": "After release", "quantity": 1}]'::jsonb)::text, false);
SELECT set_config('request.jwt.claim.sub', '6c3e0000-0000-4000-8000-000000000002', false);
SELECT public.decide_supply_request('6c3e0000-0000-4000-8000-000000000101', current_setting('release.after')::uuid, 'approved', NULL, NULL,
  (SELECT updated_at FROM public.supply_requests WHERE id = current_setting('release.after')::uuid));
SELECT public.transition_supply_request('6c3e0000-0000-4000-8000-000000000101', current_setting('release.after')::uuid, 'ordered');
SELECT public.receive_supply_request('6c3e0000-0000-4000-8000-000000000101', current_setting('release.after')::uuid);
SELECT public.transition_supply_request('6c3e0000-0000-4000-8000-000000000101', current_setting('release.after')::uuid, 'completed');
SQL
q() { psql -X -U postgres -d postgres -Atc "$1"; }
after="$(q "SELECT id FROM public.supply_requests WHERE organization_id = '6c3e0000-0000-4000-8000-000000000101' ORDER BY created_at DESC, id LIMIT 1")"
[ "$(q "SELECT string_agg(status_to || ':' || coalesce(compound_action, '-'), ' ' ORDER BY created_at, status_to) FROM public.supply_request_updates WHERE supply_request_id = '$after'")" \
  = "under_review:- approved:- ordered:- received:- completed:-" ] || fail "the Detailed lifecycle changed after the release"
[ "$(q "SELECT string_agg(event_type, ',' ORDER BY event_type) FROM public.notification_events WHERE entity_id = '$after'")" = "request_approved,request_submitted" ] \
  || fail "the approval did not raise exactly one Approved event"
admin_sql() { psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres -At -c "SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub', '6c3e0000-0000-4000-8000-000000000002', false); $1"; }
expect_failure "Approve & Order before any profile is chosen" "Approve & Order is not enabled" admin_sql "SELECT public.approve_and_order_supply_request('6c3e0000-0000-4000-8000-000000000101', '$after', NULL, NULL, now())"
expect_failure "Receive & Complete before any profile is chosen" "Receive & Complete is not enabled" admin_sql "SELECT public.receive_and_complete_supply_request('6c3e0000-0000-4000-8000-000000000101', '$after')"
[ "$(admin_sql "SELECT public.get_request_workflow_profile('6c3e0000-0000-4000-8000-000000000101')" | tail -1)" = "detailed" ] || fail "an organization without a settings row is not Detailed"
[ "$(q "SELECT (SELECT count(*) FROM public.organization_request_workflow_settings) + (SELECT count(*) FROM public.supply_request_updates WHERE compound_action IS NOT NULL)")" = "0" ] \
  || fail "the release created settings or compound markers"
echo "ok - after the release every organization is Detailed: compound actions refused, the plain lifecycle and one Approved event unchanged"

# After the release a stale decision is refused at once with the non-retryable 55000.
stale="$(q "SELECT id FROM public.supply_requests WHERE organization_id = '6c3e0000-0000-4000-8000-000000000101' AND status = 'submitted' ORDER BY created_at, id LIMIT 1")"
[ -n "$stale" ] || fail "no submitted request to test a stale decision"
started=$(date +%s)
out="$(admin_sql "DO \$stale\$ BEGIN PERFORM public.decide_supply_request('6c3e0000-0000-4000-8000-000000000101', '$stale', 'approved', NULL, NULL, '2000-01-01'); EXCEPTION WHEN SQLSTATE '55000' THEN RAISE WARNING 'stale-55000'; END \$stale\$;" 2>&1 || true)"
[ $(( $(date +%s) - started )) -lt 3 ] || fail "the stale decision did not answer promptly"
echo "$out" | grep -q 'stale-55000' || fail "a stale decision did not raise 55000: $out"
echo "ok - after the release a stale decision raises 55000 immediately"
echo "--- documented pre/post differences"
diff "$work/pre.txt" "$work/post.txt" | grep -E "^[<>]" | grep -v -E '^[<>] (function|overloads|index|constraint) \| ' || true
echo "phase7c0_release_check: all checks passed"
