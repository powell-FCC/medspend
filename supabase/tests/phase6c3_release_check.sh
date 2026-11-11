#!/usr/bin/env bash
# Phase 6C.3 release-script check on a disposable Postgres. Never reads .env files or talks
# to a hosted project.
#
#   1. The migration and every release file are sent the way the Supabase SQL Editor sends
#      them: rewritten by the Editor's "Run and enable RLS" logic
#      (support/studio_sql_editor_rewrite.mjs), then as ONE simple query. The rewrite must
#      flag nothing and change nothing (the migration enables RLS on its three tables itself);
#      nothing may follow COMMIT; no temp tables.
#   2. Boot a fresh container, apply every migration before 6C.3 (main c2891f6, through 6C.4),
#      and seed: the 6C.4, 5A.10, 7B.2 and 6C.3 fixtures (organizations with owner, admin and
#      staff memberships, the catalog, requests and their items, inventory and counts), plus
#      requests decided through the real lifecycle (update rows, a commitment), a budget and
#      invoices, so the request, membership, profile, budget, invoice and inventory lines hash
#      real rows.
#   3. precheck; an induced failure just before COMMIT (must roll back completely); the
#      migration (success, no output); postcheck; a second application and a repeat precheck
#      (both refused). Diff pre and post: only the documented lines may differ.
#   4. After the postcheck, a request submitted through the unchanged lifecycle raises exactly
#      one pending event and nothing else (no delivery, no settings row): the master sending
#      switch is OFF for every organization.
#
# Requires Docker, node and public.ecr.aws/supabase/postgres:17.6.1.167.
# Usage: supabase/tests/phase6c3_release_check.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
container="medspend_6c3_release_$$"
port="${MEDSPEND_6C3_RELEASE_PORT:-55935}"
work="$(mktemp -d)"
export PGPASSWORD=postgres PGHOST=127.0.0.1 PGPORT="$port" PGOPTIONS="-c client_min_messages=warning"
migration="20261110120000_phase6c3_request_notifications.sql"
rewrite="$root/supabase/tests/support/studio_sql_editor_rewrite.mjs"
release="$root/supabase/release/phase6c3"

cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
cd "$root"

for file in "supabase/migrations/$migration" "$release"/*.sql; do
  [ -z "$(node "$rewrite" "$file" --tables)" ] || fail "the SQL Editor would append RLS statements to $file"
  cmp -s "$file" <(node "$rewrite" "$file") || fail "the SQL Editor would rewrite $file"
done
grep -qi "create[[:space:]]\+temp" "supabase/migrations/$migration" && fail "the 6C.3 migration creates temp tables"
python3 - "supabase/migrations/$migration" <<'PY' || fail "statements follow the final COMMIT"
import re, sys
text = open(sys.argv[1]).read()
tail = text[text.rindex("\nCOMMIT;") + len("\nCOMMIT;"):]
sys.exit(0 if re.sub(r"--[^\n]*", "", tail).strip() == "" else 1)
PY
echo "ok - the SQL Editor sends the 6C.3 migration and release files unchanged; nothing follows COMMIT"

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
# The decided requests and the fixtures' own submissions raised nothing: 6C.3 is not applied yet.

editor() { psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres -At -F ' | ' -c "$(node "$rewrite" "$1")"; }
readonly_editor() { PGOPTIONS="$PGOPTIONS -c default_transaction_read_only=on" editor "$@"; }
fingerprint() { readonly_editor "$release/fingerprint.sql"; }
expect_failure() {  # <label> <expected message> <command...>
  local label="$1" expected="$2"; shift 2
  if out="$("$@" 2>&1)"; then fail "$label unexpectedly succeeded"; fi
  echo "$out" | grep -qF "$expected" || fail "$label: unexpected error: $out"
  echo "ok - $label refused: $expected"
}
objects() { psql -X -U postgres -d postgres -Atc "SELECT (SELECT count(*) FROM pg_class WHERE relname IN ('notification_events', 'notification_deliveries', 'organization_notification_settings')) + (SELECT count(*) FROM pg_proc WHERE proname IN ('claim_notification_deliveries', 'dispatch_notification_events', 'capture_supply_request_submitted_notification')) + (SELECT count(*) FROM pg_trigger WHERE tgname IN ('supply_requests_submitted_notification', 'supply_request_updates_decision_notification'))"; }

readonly_editor "$release/precheck.sql" > "$work/pre.txt"
cmp -s "$work/pre.txt" <(fingerprint) || fail "precheck output is not exactly the fingerprint"
for line in 'supply_requests hash' 'supply_request_updates hash' 'supply_request_items hash' 'supply_request_commitments hash' \
  'organizations hash' 'organization_memberships hash' 'profiles hash' 'organization_budgets hash' 'invoices hash' 'inventory_items hash'; do
  grep -q "^rows | $line | [0-9a-f]\{32\}\$" "$work/pre.txt" || fail "$line was not fingerprinted"
done
grep -q '^count | public functions | 149$' "$work/pre.txt" && grep -q '^count | public triggers | 76$' "$work/pre.txt" \
  || fail "pre counts are not the 6C.4 production baseline"
echo "ok - precheck passed on the 6C.4 baseline (149/48/181/58/76) with requests, decisions, memberships, budgets and invoices"

python3 - "supabase/migrations/$migration" "$work/broken.sql" <<'PY'
import sys
text = open(sys.argv[1]).read()
marker = "\nCOMMIT;\n"
assert text.count(marker) == 1
open(sys.argv[2], "w").write(text.replace(marker, "\nDO $induced$ BEGIN RAISE EXCEPTION 'induced failure before COMMIT'; END $induced$;\nCOMMIT;\n"))
PY
expect_failure "induced failure before COMMIT" "induced failure before COMMIT" editor "$work/broken.sql"
[ "$(objects)" = "0" ] || fail "partial 6C.3 objects survived the failed migration"
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
node supabase/tests/support/phase6c3_release_generate.mjs --pre "$work/pre.txt" --post "$work/post.txt" --check >/dev/null \
  || fail "precheck.sql / postcheck.sql are not what the generator produces from fingerprint.sql on this database"
echo "ok - precheck.sql and postcheck.sql are exactly what the generator produces from fingerprint.sql"

expect_failure "second application" "Phase 6C.3 notification objects already exist unexpectedly" editor "supabase/migrations/$migration"
expect_failure "precheck after the migration" "precheck: Phase 6C.3 objects already exist" readonly_editor "$release/precheck.sql"
cmp -s "$work/post.txt" <(fingerprint) || fail "the refused reapplication changed something"

new_functions='capture_supply_request_decision_notification|capture_supply_request_submitted_notification|claim_notification_deliveries|complete_notification_delivery|dispatch_notification_events|enqueue_due_notification_digests|get_organization_notification_settings|guard_notification_sending_boundary|notification_approver_digest_content|notification_request_items|set_organization_notification_sending|update_organization_notification_settings'
new_tables='notification_events|notification_deliveries|organization_notification_settings'
strip() { grep -v -E "^(function|overloads) \| ($new_functions) \| " "$1" \
  | grep -v -E "^(table|policies|grants) \| ($new_tables) \| " \
  | grep -v -E "^index \| (notification_|organization_notification_settings)" \
  | grep -v -E "^constraint \| ($new_tables)\." \
  | grep -v -E '^trigger \| (notification_deliveries\.notification_deliveries_updated_at|organization_notification_settings\.organization_notification_settings_updated_at|organization_notification_settings\.organization_notification_settings_sending_boundary|supply_requests\.supply_requests_submitted_notification|supply_request_updates\.supply_request_updates_decision_notification) \| ' \
  | grep -v -E "^rows \| ($new_tables) count \| " \
  | grep -v -E '^count \| public (functions|tables|indexes|triggers) \| '; }
diff <(strip "$work/pre.txt") <(strip "$work/post.txt") || fail "precheck/postcheck differ outside the documented lines"
delta() { echo $(( $(grep -F "count | public $1 |" "$work/post.txt" | awk -F' [|] ' '{print $3}') - $(grep -F "count | public $1 |" "$work/pre.txt" | awk -F' [|] ' '{print $3}') )); }
[ "$(delta functions)" = "12" ] && [ "$(delta tables)" = "3" ] && [ "$(delta indexes)" = "12" ] \
  && [ "$(delta policies)" = "0" ] && [ "$(delta triggers)" = "5" ] \
  || fail "unexpected object deltas: functions $(delta functions) tables $(delta tables) indexes $(delta indexes) policies $(delta policies) triggers $(delta triggers)"
for prefix in 'function | submit_supply_request' 'function | decide_supply_request' 'function | transition_supply_request' \
  'function | apply_supply_request_transition' 'function | is_org_admin' 'function | has_org_role' 'function | post_reviewed_invoice' \
  'function | get_budget_purchasing_overview' 'function | create_invoice_upload_batch' 'function | get_staff_product_discovery' \
  'table | supply_requests' 'table | supply_request_updates' 'table | organization_memberships' 'table | profiles' \
  'policies | supply_requests' 'grants | supply_requests' 'policies | supply_request_updates' 'grants | supply_request_updates' \
  'trigger | supply_requests.supply_requests_lifecycle_guard' \
  'rows | supply_requests hash' 'rows | supply_request_updates hash' 'rows | organization_memberships hash' 'rows | invoices hash'; do
  before="$(grep -F "$prefix |" "$work/pre.txt")"
  [ -n "$before" ] || fail "$prefix is not fingerprinted"
  if echo "$before" | grep -q ' | absent$'; then fail "$prefix is absent before the migration"; fi
  [ "$before" = "$(grep -F "$prefix |" "$work/post.txt")" ] || fail "$prefix changed"
done
[ "$(grep -c '^function | ' "$work/pre.txt")" = "44" ] || fail "expected 44 function pins (12 new, 32 existing)"
grep -q '^rows | notification_events count | 0$' "$work/post.txt" && grep -q '^rows | organization_notification_settings count | 0$' "$work/post.txt" \
  || fail "new tables are not empty"
echo "ok - pre/post differ only in documented lines: +12 functions, +3 tables (no client access), +12 indexes, +5 triggers; no request, membership, budget, invoice or inventory line changed"

# After the release: the unchanged lifecycle raises one pending event and nothing else.
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<'SQL'
SELECT set_config('request.jwt.claim.sub', '6c3e0000-0000-4000-8000-000000000003', false);
SELECT public.submit_supply_request('6c3e0000-0000-4000-8000-000000000101', 'reorder', NULL, NULL, NULL,
  '[{"freeTextItem": "After release", "quantity": 1}]'::jsonb);
SQL
[ "$(psql -X -U postgres -d postgres -Atc "SELECT count(*) || '/' || string_agg(DISTINCT event_type || ':' || status, ',') FROM public.notification_events")" = "1/request_submitted:pending" ] \
  || fail "a post-release submission did not raise exactly one pending event"
[ "$(psql -X -U postgres -d postgres -Atc "SELECT (SELECT count(*) FROM public.notification_deliveries) + (SELECT count(*) FROM public.organization_notification_settings)")" = "0" ] \
  || fail "the release created deliveries or settings"
psql -X -q -U postgres -d postgres -At -c "SELECT public.dispatch_notification_events()" >/dev/null
[ "$(psql -X -U postgres -d postgres -Atc "SELECT status || ':' || status_reason FROM public.notification_events")" = "suppressed:sending_disabled" ] \
  || fail "with no settings row the master switch is not OFF"
echo "ok - after the release a submission raises one pending event; dispatch suppresses it (master sending OFF by default)"
echo "--- documented pre/post differences"
diff "$work/pre.txt" "$work/post.txt" | grep -E "^[<>]" | grep -v -E '^[<>] (function|overloads|index|constraint) \| ' || true
echo "phase6c3_release_check: all checks passed"
