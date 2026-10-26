#!/usr/bin/env bash
# Phase 7A.1 migration, release-script and invoice-deletion parity check on a disposable
# Postgres. Never reads .env files or talks to a hosted project.
#
#   1. Boot a fresh container and apply every migration BEFORE 7A.1 (main f8a60fd's schema).
#   2. Seed real pre-7A.1 history (integration/phase7a1_backfill_fixture.sql) through main's
#      own posting and adjustment functions, and copy that database as "pre".
#   3. Run release/phase7a1/precheck.sql, an intentionally failing copy of the migration (must
#      roll back completely), the 7A.1 migration, postcheck.sql, then a second application and a
#      repeat precheck (both must be refused). Every release file is sent as ONE query, as the
#      Supabase SQL Editor sends it; pre/postcheck run read-only. Diff pre and post: every data
#      line must be identical; only the documented schema lines may differ.
#   4. Run the same invoice deletions on "pre" (main code) and on the migrated database, and
#      require identical results: deletion behaves exactly as before while all stock is
#      Unassigned and no move or count exists.
#
# Requires Docker and public.ecr.aws/supabase/postgres:17.6.1.167.
# Usage: supabase/tests/phase7a1_backfill_check.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
container="medspend_7a1_backfill_$$"
port="${MEDSPEND_7A1_DB_PORT:-55460}"
work="$(mktemp -d)"
export PGPASSWORD=postgres PGHOST=127.0.0.1 PGPORT="$port" PGOPTIONS="-c client_min_messages=warning"
target="20261021120000_phase7a1_location_aware_inventory.sql"

cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

docker run -d --name "$container" -e POSTGRES_PASSWORD=postgres -p "127.0.0.1:$port:5432" \
  public.ecr.aws/supabase/postgres:17.6.1.167 >/dev/null
for _ in $(seq 1 60); do
  if psql -U supabase_admin -d postgres -Atc "select 1 from pg_roles where rolname = 'authenticator'" 2>/dev/null | grep -q 1; then break; fi
  sleep 2
done
sleep 5

psql -q -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -f "$root/supabase/tests/integration/local_stack_setup.sql" >/dev/null
for migration in "$root"/supabase/migrations/*.sql; do
  [[ "$(basename "$migration")" < "$target" ]] || continue
  psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f "$migration" >/dev/null
done
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f "$root/supabase/tests/integration/phase7a1_backfill_fixture.sql" >/dev/null

# Copy the seeded pre-7A.1 database for the deletion parity run.
for _ in 1 2 3 4 5; do
  if psql -q -U supabase_admin -d template1 -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'postgres' AND pid <> pg_backend_pid();" \
       -c "CREATE DATABASE pre TEMPLATE postgres" >/dev/null 2>&1; then break; fi
  sleep 1
done
psql -q -U supabase_admin -d template1 -c "ALTER DATABASE pre OWNER TO postgres" >/dev/null

cd "$root"
# Every release file runs exactly as the Supabase SQL Editor sends it: the whole file as ONE
# simple query (no psql meta-commands possible). Pre/postcheck also run with
# default_transaction_read_only=on, proving they write nothing.
editor() { psql -X -q -v ON_ERROR_STOP=1 -U postgres -d "${2:-postgres}" -At -F ' | ' -c "$(cat "$1")"; }
readonly_editor() { PGOPTIONS="$PGOPTIONS -c default_transaction_read_only=on" editor "$@"; }
fingerprint() { readonly_editor supabase/release/phase7a1/fingerprint.sql "${1:-postgres}"; }
expect_failure() {  # <label> <expected message> <command...>
  local label="$1" expected="$2"; shift 2
  if out="$("$@" 2>&1)"; then echo "FAIL: $label unexpectedly succeeded" >&2; exit 1; fi
  echo "$out" | grep -qF "$expected" || { echo "FAIL: $label: unexpected error: $out" >&2; exit 1; }
  echo "ok - $label refused: $expected"
}

readonly_editor supabase/release/phase7a1/precheck.sql > "$work/pre.txt"
cmp -s "$work/pre.txt" <(fingerprint) || { echo "FAIL: precheck output is not exactly the fingerprint" >&2; exit 1; }

# An induced failure late in the migration (after tables, functions and backfill) must roll
# everything back: the fingerprint afterwards is byte-for-byte the precheck fingerprint.
python3 - "supabase/migrations/$target" "$work/broken.sql" <<'PY'
import sys
text = open(sys.argv[1]).read()
marker = "\nCOMMIT;\n"
assert text.count(marker) == 1
open(sys.argv[2], "w").write(text.replace(marker, "\nDO $induced$ BEGIN RAISE EXCEPTION 'induced failure before COMMIT'; END $induced$;\nCOMMIT;\n"))
PY
expect_failure "induced mid-migration failure" "induced failure before COMMIT" editor "$work/broken.sql"
cmp -s "$work/pre.txt" <(fingerprint) || { echo "FAIL: the failed migration left changes behind" >&2; exit 1; }
[ "$(psql -X -U postgres -d postgres -Atc "SELECT count(*) FROM pg_class WHERE relname LIKE 'inventory_location%' OR relname = 'inventory_transfers'")" = "0" ] \
  || { echo "FAIL: partial 7A.1 objects survived the failed migration" >&2; exit 1; }
readonly_editor supabase/release/phase7a1/precheck.sql > "$work/pre_after_failure.txt"
cmp -s "$work/pre.txt" "$work/pre_after_failure.txt" || { echo "FAIL: precheck changed after the failed attempt" >&2; exit 1; }
echo "ok - induced failure rolled back completely; precheck passes again"

editor "supabase/migrations/$target" >/dev/null
readonly_editor supabase/release/phase7a1/postcheck.sql > "$work/post.txt"
cmp -s "$work/post.txt" <(fingerprint) || { echo "FAIL: postcheck output is not exactly the fingerprint" >&2; exit 1; }

# Operator mistakes are refused loudly, not absorbed: a second application of the migration
# and a precheck against an already-migrated database both stop with a clear message, and
# change nothing.
expect_failure "second application of the migration" "Phase 7A.1 inventory location tables already exist unexpectedly" \
  editor "supabase/migrations/$target"
expect_failure "precheck on an already-migrated database" "precheck: Phase 7A.1 tables already exist" \
  readonly_editor supabase/release/phase7a1/precheck.sql
cmp -s "$work/post.txt" <(fingerprint) || { echo "FAIL: the refused reapplication changed something" >&2; exit 1; }

# Lines allowed to differ: timestamps, assertion banners, new/replaced function bodies,
# overloads of new functions, object counts, and inventory-table policy/trigger/grant
# fingerprints. Every 'rows' and 'org_total' line must be identical.
strip() { grep -v -E '^(precheck_at|postcheck_at|precheck|postcheck) \| ' "$1" \
  | grep -v -E '^function \| (adjust_inventory_location_quantity|apply_inventory_location_delta|create_inventory_location|ensure_inventory_unassigned_location|inventory_apply_balance_delta|move_inventory_stock|set_inventory_location_active|update_inventory_location|adjust_inventory_quantity|delete_invoice_permanently|post_reviewed_invoice|receive_invoice_inventory_item) \| ' \
  | grep -v -E '^overloads \| (move_inventory_stock|adjust_inventory_location_quantity) \| ' \
  | grep -v -E '^constraint \| inventory_adjustments_source_type_check \| ' \
  | grep -v -E '^count \| public (functions|tables|indexes|policies|triggers) \| ' \
  | grep -v -E '^(policies|triggers|grants) \| (inventory_items|inventory_adjustments|inventory_locations|inventory_location_balances|inventory_transfers|organizations) \| ' ; }
if ! diff <(strip "$work/pre.txt") <(strip "$work/post.txt"); then
  echo "FAIL: precheck/postcheck differ outside the documented lines" >&2
  exit 1
fi
for line in 'rows | inventory_items quantity hash' 'rows | inventory organization totals hash' 'rows | inventory_adjustments hash' 'rows | invoices hash' 'rows | organization_budgets hash' 'rows | inventory_price_history hash'; do
  pre_value="$(grep -F "$line" "$work/pre.txt")"; post_value="$(grep -F "$line" "$work/post.txt")"
  [ -n "$pre_value" ] && [ "$pre_value" = "$post_value" ] || { echo "FAIL: $line changed" >&2; exit 1; }
  case "$pre_value" in *'| empty') echo "FAIL: $line is empty; the fixture did not load" >&2; exit 1 ;; esac
done
for expected in \
  'function | delete_invoice_permanently | ac77d1b05aa44675b295936021189673 secdef=true authenticated=true anon=false public=false' \
  'function | receive_invoice_inventory_item | c843e23a4f8b8c432f26acb5dc885570 secdef=true authenticated=true anon=false public=false' \
  'function | adjust_inventory_quantity | e9e178ef7fa6dc4e50441b40adc8e1e9 secdef=true authenticated=true anon=false public=false' \
  'function | inventory_apply_balance_delta | 83513cd3324f6045147a855bec061b64 secdef=true authenticated=false anon=false public=false' \
  'grants | inventory_location_balances | authenticated=SELECT,service_role=SELECT'; do
  grep -qxF "$expected" "$work/post.txt" || { echo "FAIL: postcheck lacks: $expected" >&2; exit 1; }
done
echo "--- documented pre/post differences"
diff "$work/pre.txt" "$work/post.txt" | grep -E "^[<>]" || true

# Backfill specifics on the seeded data.
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres <<'SQL'
DO $backfill$
BEGIN
  IF (SELECT quantity FROM public.inventory_location_balances b JOIN public.inventory_locations l ON l.id = b.inventory_location_id
      WHERE b.inventory_item_id = '7a1b0000-0000-4000-8000-000000000501' AND l.kind = 'unassigned') <> 14.333333 THEN
    RAISE EXCEPTION 'fractional legacy quantity not preserved exactly in Unassigned';
  END IF;
  IF (SELECT quantity FROM public.inventory_location_balances WHERE inventory_item_id = '7a1b0000-0000-4000-8000-000000000502') <> 0 THEN
    RAISE EXCEPTION 'zero item has no zero Unassigned balance';
  END IF;
  IF (SELECT quantity FROM public.inventory_location_balances WHERE inventory_item_id = '7a1b0000-0000-4000-8000-000000000503') <> 7 THEN
    RAISE EXCEPTION 'archived item stock not carried into Unassigned';
  END IF;
  IF (SELECT count(*) FROM public.inventory_locations WHERE organization_id = '7a1b0000-0000-4000-8000-000000000103') <> 1 THEN
    RAISE EXCEPTION 'empty organization lacks its Unassigned location';
  END IF;
  IF EXISTS (SELECT 1 FROM public.inventory_location_balances b JOIN public.inventory_locations l ON l.id = b.inventory_location_id
             WHERE l.organization_id <> b.organization_id) THEN
    RAISE EXCEPTION 'backfill crossed organizations';
  END IF;
  IF EXISTS (SELECT 1 FROM public.inventory_adjustments WHERE inventory_location_id IS NOT NULL) THEN
    RAISE EXCEPTION 'historical adjustments were relabelled with a location';
  END IF;
END
$backfill$;
SQL

# Invoice deletion parity. The same deletions run on main's code (pre) and on 7A.1.
cat > "$work/deletion.sql" <<'SQL'
SELECT pg_catalog.set_config('request.jwt.claim.sub', '7a1b0000-0000-4000-8000-000000000001', false);
CREATE TEMP TABLE parity (step int, value text);
-- 1. Delete the second tape invoice: its 30 rolls come off, later history is rebuilt.
INSERT INTO parity SELECT 1, (public.delete_invoice_permanently('7a1b0000-0000-4000-8000-000000000101', '7a1b0000-0000-4000-8000-000000000602') - 'deletedAt')::text;
-- 2. Remove more tape so the first invoice's 120-roll receipt can no longer come off.
SELECT public.adjust_inventory_quantity('7a1b0000-0000-4000-8000-000000000101',
  (SELECT id FROM public.inventory_items WHERE product_id = '7a1b0000-0000-4000-8000-000000000401'), -10, 'Expired');
DO $refuse$
BEGIN
  PERFORM public.delete_invoice_permanently('7a1b0000-0000-4000-8000-000000000101', '7a1b0000-0000-4000-8000-000000000601');
  INSERT INTO parity VALUES (2, 'unexpectedly deleted');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO parity VALUES (2, SQLERRM);
END
$refuse$;
INSERT INTO parity SELECT 3, string_agg(concat_ws(':', id, quantity, active), ',' ORDER BY id) FROM public.inventory_items;
INSERT INTO parity SELECT 4, string_agg(concat_ws(':', inventory_item_id, adjustment_amount, previous_quantity, new_quantity, reason, source_type, source_invoice_id), ',' ORDER BY inventory_item_id, created_at, adjustment_amount)
  FROM public.inventory_adjustments;
INSERT INTO parity SELECT 5, count(*)::text FROM public.invoices;
INSERT INTO parity SELECT 6, count(*)::text FROM public.inventory_price_history;
SELECT step, value FROM parity ORDER BY step;
SQL
psql -U postgres -d pre -v ON_ERROR_STOP=1 -At -f "$work/deletion.sql" | grep -E '^[0-9]+\|' > "$work/deletion_pre.txt"
psql -U postgres -d postgres -v ON_ERROR_STOP=1 -At -f "$work/deletion.sql" | grep -E '^[0-9]+\|' > "$work/deletion_post.txt"
# 7A.1 adds a location and the 'manual' source type on the step-2 adjustment; neither appears
# in the compared columns except source_type, which main leaves NULL. Normalise that one field.
sed -E 's/:Expired:manual(:|,|$)/:Expired\1/' "$work/deletion_post.txt" > "$work/deletion_post_normalised.txt"
if ! diff "$work/deletion_pre.txt" "$work/deletion_post_normalised.txt"; then
  echo "FAIL: invoice deletion differs between main and 7A.1" >&2
  exit 1
fi
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres <<'SQL'
BEGIN;
SET CONSTRAINTS ALL IMMEDIATE;
DO $after_delete$
BEGIN
  IF EXISTS (SELECT 1 FROM public.inventory_items i WHERE i.quantity <> (SELECT sum(b.quantity) FROM public.inventory_location_balances b WHERE b.inventory_item_id = i.id)) THEN
    RAISE EXCEPTION 'balances differ from totals after deletion';
  END IF;
END
$after_delete$;
COMMIT;
SQL
echo "--- deletion parity (main == 7A.1)"
cat "$work/deletion_pre.txt" | cut -c1-160

echo "phase7a1_backfill_check: all checks passed"
