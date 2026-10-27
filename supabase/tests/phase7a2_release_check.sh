#!/usr/bin/env bash
# Phase 7A.2 release-script check on a disposable Postgres. Never reads .env files or talks
# to a hosted project.
#
#   1. Boot a fresh container, apply every migration before 7A.2 (main with 7A.1), seed
#      pre-7A.2 inventory with physical locations and moves, and clone it as "pre".
#   2. Every release file is sent the way the Supabase SQL Editor sends it: rewritten by the
#      Editor's "Run and enable RLS" logic (support/studio_sql_editor_rewrite.mjs; the 7A.1
#      incident), then sent as ONE simple query. The rewrite must flag nothing and change
#      nothing. Pre/postchecks run with default_transaction_read_only=on.
#   3. precheck; an induced failure just before COMMIT (must roll back completely); the
#      migration (must return success with no output); postcheck; a second application and a
#      repeat precheck (both refused). Diff pre and post: only documented lines may differ.
#   4. The staff read hardening: refused before 7A.2 exists; applied after it; its postcheck;
#      diff post and hardened: only the inventory_items policy line may differ.
#
# Requires Docker, node and public.ecr.aws/supabase/postgres:17.6.1.167.
# Usage: supabase/tests/phase7a2_release_check.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
container="medspend_7a2_release_$$"
port="${MEDSPEND_7A2_RELEASE_PORT:-55485}"
work="$(mktemp -d)"
export PGPASSWORD=postgres PGHOST=127.0.0.1 PGPORT="$port" PGOPTIONS="-c client_min_messages=warning"
counts="20261027120000_phase7a2_inventory_physical_counts.sql"
hardening="20261027120100_phase7a2_staff_inventory_read_hardening.sql"
rewrite="$root/supabase/tests/support/studio_sql_editor_rewrite.mjs"
release="$root/supabase/release/phase7a2"
owner='7a1b0000-0000-4000-8000-000000000001'
org='7a1b0000-0000-4000-8000-000000000101'

cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

cd "$root"
for file in "supabase/migrations/$counts" "supabase/migrations/$hardening" "$release"/*.sql; do
  [ -z "$(node "$rewrite" "$file" --tables)" ] || fail "the SQL Editor would append RLS statements to $file"
  cmp -s "$file" <(node "$rewrite" "$file") || fail "the SQL Editor would rewrite $file"
done
grep -qi "create[[:space:]]\+temp" "supabase/migrations/$counts" "supabase/migrations/$hardening" && fail "a 7A.2 migration creates temp tables"
for file in "supabase/migrations/$counts" "supabase/migrations/$hardening"; do
  python3 - "$file" <<'PY' || fail "statements follow the final COMMIT in $file"
import re, sys
text = open(sys.argv[1]).read()
tail = text[text.rindex("\nCOMMIT;") + len("\nCOMMIT;"):]
sys.exit(0 if re.sub(r"--[^\n]*", "", tail).strip() == "" else 1)
PY
done
echo "ok - the SQL Editor sends every 7A.2 migration and release file unchanged; nothing follows COMMIT"

docker run -d --name "$container" -e POSTGRES_PASSWORD=postgres -p "127.0.0.1:$port:5432" \
  public.ecr.aws/supabase/postgres:17.6.1.167 >/dev/null
for _ in $(seq 1 60); do
  if psql -U supabase_admin -d postgres -Atc "select 1 from pg_roles where rolname = 'authenticator'" 2>/dev/null | grep -q 1; then break; fi
  sleep 2
done
sleep 5
psql -q -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -f supabase/tests/integration/local_stack_setup.sql >/dev/null
for migration in supabase/migrations/*.sql; do
  [[ "$(basename "$migration")" < "$counts" ]] || continue
  psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f "$migration" >/dev/null
done
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f supabase/tests/integration/phase7a1_backfill_fixture.sql >/dev/null
# 7A.1 in use: a physical location holding moved stock.
psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres -c "SELECT set_config('request.jwt.claim.sub', '$owner', false)" -c "
  SELECT public.move_inventory_stock('$org', item.id,
    (SELECT id FROM public.inventory_locations WHERE organization_id = '$org' AND kind = 'unassigned'),
    public.create_inventory_location('$org', 'Release Cabinet'), 3, 'release-move')
  FROM public.inventory_items item WHERE item.product_id = '7a1b0000-0000-4000-8000-000000000401'" >/dev/null
for _ in 1 2 3 4 5; do
  if psql -q -U supabase_admin -d template1 -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'postgres' AND pid <> pg_backend_pid();" \
       -c "CREATE DATABASE pre TEMPLATE postgres" >/dev/null 2>&1; then break; fi
  sleep 1
done
psql -q -U supabase_admin -d template1 -c "ALTER DATABASE pre OWNER TO postgres" >/dev/null

# The SQL Editor path: Studio's rewrite, then the whole text as ONE simple query.
editor() { psql -X -q -v ON_ERROR_STOP=1 -U postgres -d "${2:-postgres}" -At -F ' | ' -c "$(node "$rewrite" "$1")"; }
readonly_editor() { PGOPTIONS="$PGOPTIONS -c default_transaction_read_only=on" editor "$@"; }
fingerprint() { readonly_editor "$release/fingerprint.sql" "${1:-postgres}"; }
expect_failure() {  # <label> <expected message> <command...>
  local label="$1" expected="$2"; shift 2
  if out="$("$@" 2>&1)"; then fail "$label unexpectedly succeeded"; fi
  echo "$out" | grep -qF "$expected" || fail "$label: unexpected error: $out"
  echo "ok - $label refused: $expected"
}
objects() { psql -X -U postgres -d "${1:-postgres}" -Atc "SELECT count(*) FROM pg_class WHERE relname IN ('inventory_count_sessions', 'inventory_count_lines', 'inventory_location_labels')"; }

readonly_editor "$release/precheck.sql" > "$work/pre.txt"
cmp -s "$work/pre.txt" <(fingerprint) || fail "precheck output is not exactly the fingerprint"
echo "ok - precheck passed on the 7A.1 baseline"

expect_failure "hardening before 7A.2" "requires get_supply_request_inventory_identities" editor "supabase/migrations/$hardening" pre

python3 - "supabase/migrations/$counts" "$work/broken.sql" <<'PY'
import sys
text = open(sys.argv[1]).read()
marker = "\nCOMMIT;\n"
assert text.count(marker) == 1
open(sys.argv[2], "w").write(text.replace(marker, "\nDO $induced$ BEGIN RAISE EXCEPTION 'induced failure before COMMIT'; END $induced$;\nCOMMIT;\n"))
PY
expect_failure "induced failure before COMMIT" "induced failure before COMMIT" editor "$work/broken.sql"
[ "$(objects)" = "0" ] || fail "partial 7A.2 objects survived the failed migration"
cmp -s "$work/pre.txt" <(fingerprint) || fail "the failed migration left changes behind"
readonly_editor "$release/precheck.sql" > "$work/pre_again.txt"
cmp -s "$work/pre.txt" "$work/pre_again.txt" || fail "precheck changed after the failed attempt"
echo "ok - induced failure rolled back completely; precheck passes again"

out="$(editor "supabase/migrations/$counts" 2>&1)" || fail "the migration failed: $out"
[ -z "$out" ] || fail "the migration printed output: $out"
echo "ok - migration (as the SQL Editor sends it) returned success with no output"
readonly_editor "$release/postcheck.sql" > "$work/post.txt"
cmp -s "$work/post.txt" <(fingerprint) || fail "postcheck output is not exactly the fingerprint"
echo "ok - postcheck passed"

expect_failure "second application" "Phase 7A.2 inventory count tables already exist unexpectedly" editor "supabase/migrations/$counts"
expect_failure "precheck after the migration" "precheck: Phase 7A.2 objects already exist" readonly_editor "$release/precheck.sql"
cmp -s "$work/post.txt" <(fingerprint) || fail "the refused reapplication changed something"

# Lines allowed to differ: new functions and overloads, the ledger constraints, object
# counts, and the new tables' policies, triggers and grants. Every data line is identical.
new_functions='get_inventory_count_location|get_supply_request_inventory_identities|inventory_count_replay|inventory_count_summary|inventory_countable_balances|issue_inventory_location_label|list_countable_inventory_locations|list_inventory_location_count_status|resolve_inventory_count_label|revoke_inventory_location_labels|submit_inventory_count|tg_guard_inventory_count_history|tg_guard_inventory_location_label'
strip() { grep -v -E "^function \| ($new_functions) \| " "$1" \
  | grep -v -E '^overloads \| (submit_inventory_count|get_inventory_count_location|resolve_inventory_count_label|issue_inventory_location_label) \| ' \
  | grep -v -E '^constraint \| (inventory_adjustments_reason_check|inventory_adjustments_physical_count_check|inventory_adjustments_count_line_fk) \| ' \
  | grep -v -E '^count \| public (functions|tables|indexes|policies|triggers) \| ' \
  | grep -v -E '^(policies|triggers|grants) \| (inventory_count_sessions|inventory_count_lines|inventory_location_labels) \| '; }
diff <(strip "$work/pre.txt") <(strip "$work/post.txt") || fail "precheck/postcheck differ outside the documented lines"
delta() { echo $(( $(grep -F "count | public $1 |" "$work/post.txt" | awk -F' [|] ' '{print $3}') - $(grep -F "count | public $1 |" "$work/pre.txt" | awk -F' [|] ' '{print $3}') )); }
[ "$(delta functions)" = "13" ] && [ "$(delta tables)" = "3" ] && [ "$(delta indexes)" = "14" ] \
  && [ "$(delta policies)" = "2" ] && [ "$(delta triggers)" = "3" ] \
  || fail "unexpected object deltas: functions $(delta functions) tables $(delta tables) indexes $(delta indexes) policies $(delta policies) triggers $(delta triggers)"
grep -q '^rows | inventory_location_balances hash | [0-9a-f]\{32\}$' "$work/post.txt" || fail "balances were not fingerprinted"
echo "ok - pre/post differ only in documented lines: +13 functions, +3 tables, +14 indexes, +2 policies, +3 triggers"
echo "--- documented pre/post differences"
diff "$work/pre.txt" "$work/post.txt" | grep -E "^[<>]" || true

out="$(editor "supabase/migrations/$hardening" 2>&1)" || fail "the hardening failed: $out"
[ -z "$out" ] || fail "the hardening printed output: $out"
readonly_editor "$release/hardening_postcheck.sql" > "$work/hardened.txt"
expect_failure "postcheck after hardening" "the hardening step runs only after the deploy" readonly_editor "$release/postcheck.sql"
expect_failure "second hardening" "already hardened?" editor "supabase/migrations/$hardening"
diff <(grep -v -E '^policies \| inventory_items \| ' "$work/post.txt") <(grep -v -E '^policies \| inventory_items \| ' "$work/hardened.txt") \
  || fail "hardening changed more than the inventory_items policy"
echo "ok - hardening applied; only the inventory_items policy line changed"

echo "phase7a2_release_check: all checks passed"
