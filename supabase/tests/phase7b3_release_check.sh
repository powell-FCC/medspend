#!/usr/bin/env bash
# Phase 7B.3 release-script check on a disposable Postgres. Never reads .env files or talks
# to a hosted project.
#
#   1. Every release file and the migration are sent the way the Supabase SQL Editor sends
#      them: rewritten by the Editor's "Run and enable RLS" logic
#      (support/studio_sql_editor_rewrite.mjs), then as ONE simple query. The rewrite must
#      flag nothing and change nothing; nothing may follow COMMIT.
#   2. Boot a fresh container, apply every migration before 7B.3 (main, through 7B.2), and
#      seed inventory in use: 1100 items, physical locations, moves, an archived location, QR
#      labels (one revoked), a manual adjustment and a physical count.
#   3. precheck; an induced failure just before COMMIT (must roll back completely); the
#      migration (must return success with no output); postcheck; a second application and a
#      repeat precheck (both refused). Diff pre and post: only the two new functions, their
#      overload counts, the four new indexes and the function and index counts may differ.
#      Every data line is identical.
#
# Requires Docker, node and public.ecr.aws/supabase/postgres:17.6.1.167.
# Usage: supabase/tests/phase7b3_release_check.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
container="medspend_7b3_release_$$"
port="${MEDSPEND_7B3_RELEASE_PORT:-55605}"
work="$(mktemp -d)"
export PGPASSWORD=postgres PGHOST=127.0.0.1 PGPORT="$port" PGOPTIONS="-c client_min_messages=warning"
migration="20261029140000_phase7b3_inventory_activity_history.sql"
rewrite="$root/supabase/tests/support/studio_sql_editor_rewrite.mjs"
release="$root/supabase/release/phase7b3"
owner='7b1c0000-0000-4000-8000-000000000001'
staff='7b1c0000-0000-4000-8000-000000000003'
org='7b1c0000-0000-4000-8000-000000000101'

cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

cd "$root"
for file in "supabase/migrations/$migration" "$release"/*.sql; do
  [ -z "$(node "$rewrite" "$file" --tables)" ] || fail "the SQL Editor would append RLS statements to $file"
  cmp -s "$file" <(node "$rewrite" "$file") || fail "the SQL Editor would rewrite $file"
done
grep -qi "create[[:space:]]\+temp" "supabase/migrations/$migration" && fail "the 7B.3 migration creates temp tables"
python3 - "supabase/migrations/$migration" <<'PY' || fail "statements follow the final COMMIT"
import re, sys
text = open(sys.argv[1]).read()
tail = text[text.rindex("\nCOMMIT;") + len("\nCOMMIT;"):]
sys.exit(0 if re.sub(r"--[^\n]*", "", tail).strip() == "" else 1)
PY
echo "ok - the SQL Editor sends the 7B.3 migration and release files unchanged; nothing follows COMMIT"

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
# Inventory in use (the 7B.1 integration fixture: 1100 items, 210 locations, moves).
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f supabase/tests/integration/phase7b1_workspace_fixture.sql >/dev/null
# Labels (one revoked) and a physical count, as production holds after 7A.2.
psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres -c "SELECT set_config('request.jwt.claim.sub', '$owner', false)" -c "
  SELECT public.issue_inventory_location_label('$org', id) FROM public.inventory_locations
  WHERE organization_id = '$org' AND name IN ('Bulk Cabinet', 'Side Cart');
  SELECT public.revoke_inventory_location_labels('$org', id) FROM public.inventory_locations
  WHERE organization_id = '$org' AND name = 'Side Cart';
  SELECT public.adjust_inventory_location_quantity('$org', balance.inventory_item_id, balance.inventory_location_id, -1, 'Damaged')
  FROM public.inventory_location_balances balance JOIN public.inventory_locations location ON location.id = balance.inventory_location_id
  WHERE balance.organization_id = '$org' AND location.name = 'Side Cart' AND balance.quantity >= 1
  ORDER BY balance.inventory_item_id LIMIT 1;" >/dev/null
psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres -c "SELECT set_config('request.jwt.claim.sub', '$staff', false)" -c "
  WITH loc AS (SELECT id FROM public.inventory_locations WHERE organization_id = '$org' AND name = 'Side Cart'),
  page AS (SELECT public.get_inventory_count_location('$org', (SELECT id FROM loc)) AS p)
  SELECT public.submit_inventory_count('$org', (SELECT id FROM loc),
    (SELECT jsonb_agg(jsonb_build_object('inventoryItemId', i->>'inventoryItemId', 'observedVersion', (i->>'version')::bigint,
       'countedQuantity', i->>'quantity')) FROM page, jsonb_array_elements(page.p->'items') i), 'release-count')" >/dev/null

# The SQL Editor path: Studio's rewrite, then the whole text as ONE simple query.
editor() { psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres -At -F ' | ' -c "$(node "$rewrite" "$1")"; }
readonly_editor() { PGOPTIONS="$PGOPTIONS -c default_transaction_read_only=on" editor "$@"; }
fingerprint() { readonly_editor "$release/fingerprint.sql"; }
expect_failure() {  # <label> <expected message> <command...>
  local label="$1" expected="$2"; shift 2
  if out="$("$@" 2>&1)"; then fail "$label unexpectedly succeeded"; fi
  echo "$out" | grep -qF "$expected" || fail "$label: unexpected error: $out"
  echo "ok - $label refused: $expected"
}
objects() { psql -X -U postgres -d postgres -Atc "SELECT (SELECT count(*) FROM pg_proc WHERE proname IN ('list_inventory_transfer_history', 'list_inventory_adjustment_history'))
  + (SELECT count(*) FROM pg_class WHERE relname IN ('inventory_transfers_org_created_idx', 'inventory_transfers_from_created_idx',
     'inventory_transfers_to_created_idx', 'inventory_adjustments_manual_org_created_idx'))"; }

readonly_editor "$release/precheck.sql" > "$work/pre.txt"
cmp -s "$work/pre.txt" <(fingerprint) || fail "precheck output is not exactly the fingerprint"
grep -q '^rows | inventory_location_labels hash | [0-9a-f]\{32\}$' "$work/pre.txt" || fail "labels were not fingerprinted"
grep -q '^rows | inventory_count_sessions hash | [0-9a-f]\{32\}$' "$work/pre.txt" || fail "counts were not fingerprinted"
grep -q '^rows | inventory_adjustments hash | [0-9a-f]\{32\}$' "$work/pre.txt" || fail "adjustments were not fingerprinted"
grep -q '^rows | inventory_transfers hash | [0-9a-f]\{32\}$' "$work/pre.txt" || fail "transfers were not fingerprinted"
echo "ok - precheck passed on the 7B.2 baseline with stock, moves, an adjustment, labels and a count"

python3 - "supabase/migrations/$migration" "$work/broken.sql" <<'PY'
import sys
text = open(sys.argv[1]).read()
marker = "\nCOMMIT;\n"
assert text.count(marker) == 1
open(sys.argv[2], "w").write(text.replace(marker, "\nDO $induced$ BEGIN RAISE EXCEPTION 'induced failure before COMMIT'; END $induced$;\nCOMMIT;\n"))
PY
expect_failure "induced failure before COMMIT" "induced failure before COMMIT" editor "$work/broken.sql"
[ "$(objects)" = "0" ] || fail "partial 7B.3 objects survived the failed migration"
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

expect_failure "second application" "Phase 7B.3 activity history objects already exist unexpectedly" editor "supabase/migrations/$migration"
expect_failure "precheck after the migration" "precheck: Phase 7B.3 objects already exist" readonly_editor "$release/precheck.sql"
cmp -s "$work/post.txt" <(fingerprint) || fail "the refused reapplication changed something"

new_functions='list_inventory_adjustment_history|list_inventory_transfer_history'
new_indexes='inventory_adjustments_manual_org_created_idx|inventory_transfers_from_created_idx|inventory_transfers_org_created_idx|inventory_transfers_to_created_idx'
strip() { grep -v -E "^function \| ($new_functions) \| " "$1" \
  | grep -v -E "^overloads \| ($new_functions) \| " \
  | grep -v -E "^index \| ($new_indexes) \| " \
  | grep -v -E '^count \| public (functions|indexes) \| '; }
diff <(strip "$work/pre.txt") <(strip "$work/post.txt") || fail "precheck/postcheck differ outside the documented lines"
delta() { echo $(( $(grep -F "count | public $1 |" "$work/post.txt" | awk -F' [|] ' '{print $3}') - $(grep -F "count | public $1 |" "$work/pre.txt" | awk -F' [|] ' '{print $3}') )); }
[ "$(delta functions)" = "2" ] && [ "$(delta tables)" = "0" ] && [ "$(delta indexes)" = "4" ] \
  && [ "$(delta policies)" = "0" ] && [ "$(delta triggers)" = "0" ] \
  || fail "unexpected object deltas: functions $(delta functions) tables $(delta tables) indexes $(delta indexes) policies $(delta policies) triggers $(delta triggers)"
for name in ${new_indexes//|/ }; do
  grep -qE "^index \| $name \| absent$" "$work/pre.txt" || fail "$name was not absent before"
  grep -qE "^index \| $name \| [0-9a-f]{32} valid=true$" "$work/post.txt" || fail "$name is not valid after"
done
echo "ok - pre/post differ only in documented lines: +2 functions, +4 indexes; no table, policy, trigger, grant or row changed"
echo "--- documented pre/post differences"
diff "$work/pre.txt" "$work/post.txt" | grep -E "^[<>]" || true
echo "phase7b3_release_check: all checks passed"
