#!/usr/bin/env bash
# Phase 7A.1 Supabase SQL Editor regression check on a disposable Postgres. Never reads .env
# files or talks to a hosted project.
#
# Guards against "the migration commits, then the client reports an error". The first
# production run of the 7A.1 migration did exactly that: the SQL Editor flagged the
# migration's temp snapshot tables as "created without RLS", its "Run and enable RLS" option
# appended `ALTER TABLE phase7a1_pre_quantities ENABLE ROW LEVEL SECURITY;` AFTER the file's
# COMMIT, and that statement failed because ON COMMIT DROP had already removed the table.
#
#   1. Boot a fresh container, apply every migration before 7A.1 (main's schema), seed
#      representative pre-7A.1 inventory, and clone it as old / fixed / induced databases.
#   2. Rewrite each migration exactly as the SQL Editor's "Run and enable RLS" does
#      (support/studio_sql_editor_rewrite.mjs) and send it as ONE simple query, as the
#      Editor does.
#        - the original artifact (commit 6fb6e15, or $PHASE7A1_OLD_MIGRATION) reproduces the
#          incident: the client gets `relation "phase7a1_pre_quantities" does not exist`, yet
#          the migration is committed and the postcheck passes;
#        - the current artifact is flagged for nothing, so the Editor sends it unchanged; it
#          returns success with no error, nothing follows its COMMIT, and the postcheck passes.
#   3. The old and fixed end states are identical: schema dump, release fingerprint, every
#      pre-existing row, and the new location, balance and transfer rows (ignoring only
#      generated ids and timestamps).
#   4. A deliberate quantity change before COMMIT trips the preservation assertion and rolls
#      back everything; a second application is refused and changes nothing.
#
# Requires Docker, node and public.ecr.aws/supabase/postgres:17.6.1.167.
# Usage: supabase/tests/phase7a1_sql_editor_check.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
container="medspend_7a1_editor_$$"
port="${MEDSPEND_7A1_EDITOR_DB_PORT:-55490}"
work="$(mktemp -d)"
export PGPASSWORD=postgres PGHOST=127.0.0.1 PGPORT="$port" PGOPTIONS="-c client_min_messages=warning"
target="20261021120000_phase7a1_location_aware_inventory.sql"
rewrite="$root/supabase/tests/support/studio_sql_editor_rewrite.mjs"

cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

if [ -n "${PHASE7A1_OLD_MIGRATION:-}" ]; then
  cp "$PHASE7A1_OLD_MIGRATION" "$work/old.sql"
else
  git -C "$root" show "6fb6e15:supabase/migrations/$target" > "$work/old.sql"
fi
cp "$root/supabase/migrations/$target" "$work/fixed.sql"

# --- Static checks on the current artifact -------------------------------------------------
[ -z "$(node "$rewrite" "$work/fixed.sql" --tables)" ] \
  || fail "the SQL Editor would append RLS statements for: $(node "$rewrite" "$work/fixed.sql" --tables | tr '\n' ' ')"
cmp -s "$work/fixed.sql" <(node "$rewrite" "$work/fixed.sql") || fail "the SQL Editor would rewrite the migration"
python3 - "$work/fixed.sql" <<'PY' || fail "statements follow the final COMMIT"
import re, sys
text = open(sys.argv[1]).read()
tail = text[text.rindex("\nCOMMIT;") + len("\nCOMMIT;"):]
sys.exit(0 if re.sub(r"--[^\n]*", "", tail).strip() == "" else 1)
PY
grep -qi "create[[:space:]]\+temp" "$work/fixed.sql" && fail "the migration still creates temp tables"
[ "$(node "$rewrite" "$work/old.sql" --tables | tr '\n' ' ')" = "phase7a1_pre_quantities phase7a1_pre_counts " ] \
  || fail "the original artifact no longer reproduces the SQL Editor rewrite"
echo "ok - SQL Editor flags nothing in the current migration and sends it unchanged"

# --- Disposable main-schema database with representative inventory -------------------------
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
for db in old fixed induced; do
  for _ in 1 2 3 4 5; do
    if psql -q -U supabase_admin -d template1 -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'postgres' AND pid <> pg_backend_pid();" \
         -c "CREATE DATABASE $db TEMPLATE postgres" >/dev/null 2>&1; then break; fi
    sleep 1
  done
  psql -q -U supabase_admin -d template1 -c "ALTER DATABASE $db OWNER TO postgres" >/dev/null
done

cd "$root"
# The SQL Editor path: Studio's rewrite, then the whole text as ONE simple query.
editor_run() {  # <sql file> <database>; stdout+stderr to $work/<database>.out, returns psql status
  node "$rewrite" "$1" > "$work/$2.sent.sql"
  psql -X -q -v ON_ERROR_STOP=1 -U postgres -d "$2" -At -c "$(cat "$work/$2.sent.sql")" > "$work/$2.out" 2>&1
}
readonly_run() { PGOPTIONS="$PGOPTIONS -c default_transaction_read_only=on" psql -X -q -v ON_ERROR_STOP=1 -U postgres -d "$2" -At -F ' | ' -c "$(cat "$1")"; }
fingerprint() { readonly_run supabase/release/phase7a1/fingerprint.sql "$1" | grep -v -E '^(precheck_at|postcheck_at|precheck|postcheck) \| '; }
seven_a1_objects() { psql -X -U postgres -d "$1" -Atc "SELECT count(*) FROM pg_class WHERE relname LIKE 'inventory_location%' OR relname = 'inventory_transfers'"; }

readonly_run supabase/release/phase7a1/precheck.sql postgres > /dev/null
fingerprint postgres > "$work/pre.txt"

# --- 1. The original artifact reproduces the incident -------------------------------------
if editor_run "$work/old.sql" old; then fail "the original artifact unexpectedly returned success"; fi
grep -qF 'relation "phase7a1_pre_quantities" does not exist' "$work/old.out" \
  || fail "the original artifact failed differently: $(cat "$work/old.out")"
[ "$(seven_a1_objects old)" != "0" ] || fail "the original artifact did not commit"
readonly_run supabase/release/phase7a1/postcheck.sql old > /dev/null || fail "postcheck failed after the original artifact"
echo "ok - original artifact reproduced: committed, then reported: $(grep -o 'relation "phase7a1_pre_quantities" does not exist' "$work/old.out")"

# --- 2. The fixed artifact returns success -------------------------------------------------
editor_run "$work/fixed.sql" fixed || fail "the fixed migration failed: $(cat "$work/fixed.out")"
[ ! -s "$work/fixed.out" ] || fail "the fixed migration printed output: $(cat "$work/fixed.out")"
cmp -s "$work/fixed.sql" "$work/fixed.sent.sql" || fail "the Editor rewrote the fixed migration"
readonly_run supabase/release/phase7a1/postcheck.sql fixed > "$work/postcheck_fixed.txt" || fail "postcheck failed after the fixed migration"
[ -z "$(psql -X -U postgres -d fixed -Atc "SELECT current_setting('phase7a1.pre_snapshot', true)")" ] \
  || fail "the snapshot setting outlived the migration session"
echo "ok - fixed artifact: SQL Editor-style run returned success with no error and the postcheck passes"

# --- 3. Old and fixed produce the same end state -------------------------------------------
schema_dump() { docker exec -e PGPASSWORD=postgres "$container" pg_dump -U postgres -h 127.0.0.1 -d "$1" --schema-only --no-owner 2>/dev/null \
  | grep -v -E '^\\(un)?restrict '; }
data_dump() { docker exec -e PGPASSWORD=postgres "$container" pg_dump -U postgres -h 127.0.0.1 -d "$1" --data-only --no-owner \
  --exclude-table=public.inventory_locations --exclude-table=public.inventory_location_balances --exclude-table=public.inventory_transfers 2>/dev/null \
  | grep -v -E '^\\(un)?restrict ' | sort; }
new_rows() { psql -X -U postgres -d "$1" -At <<'SQL'
SELECT 'locations', coalesce(jsonb_agg(to_jsonb(l) - 'id' - 'created_at' - 'updated_at'
  ORDER BY l.organization_id, l.kind, l.name), '[]') FROM public.inventory_locations l;
SELECT 'balances', coalesce(jsonb_agg((to_jsonb(b) - 'id' - 'inventory_location_id' - 'created_at' - 'updated_at')
  || jsonb_build_object('location_kind', l.kind, 'location_name', l.name)
  ORDER BY b.organization_id, b.inventory_item_id), '[]')
FROM public.inventory_location_balances b JOIN public.inventory_locations l ON l.id = b.inventory_location_id;
SELECT 'transfers', count(*) FROM public.inventory_transfers;
SQL
}
for kind in schema_dump data_dump fingerprint new_rows; do
  "$kind" old > "$work/old.$kind"; "$kind" fixed > "$work/fixed.$kind"
  [ -s "$work/old.$kind" ] || fail "$kind produced no output"
  diff "$work/old.$kind" "$work/fixed.$kind" > "$work/$kind.diff" || { cat "$work/$kind.diff" >&2; fail "old and fixed differ in $kind"; }
done
grep -q '"location_kind": "unassigned"' "$work/fixed.new_rows" || fail "no Unassigned balances were compared"
for expected in \
  'function | adjust_inventory_location_quantity | dac472b1d11b6f94b6315c873c0bfba6 ' \
  'function | adjust_inventory_quantity | e9e178ef7fa6dc4e50441b40adc8e1e9 ' \
  'function | apply_inventory_location_delta | cad102e48b8e69213e773746fae9723a ' \
  'function | create_inventory_location | 3662f48a85020f72885b7ea6a48a58d2 ' \
  'function | delete_invoice_permanently | ac77d1b05aa44675b295936021189673 ' \
  'function | ensure_inventory_unassigned_location | 71fbdd1a6d3d7a0681bf0148eea30bc7 ' \
  'function | inventory_apply_balance_delta | 83513cd3324f6045147a855bec061b64 ' \
  'function | move_inventory_stock | 70b42f11b495fbdc9a6f06482afabf03 ' \
  'function | post_reviewed_invoice | 4d0240ce910eb2f583a8b79706c7f8e8 ' \
  'function | receive_invoice_inventory_item | c843e23a4f8b8c432f26acb5dc885570 ' \
  'function | set_inventory_location_active | dd1a39beb2413d5fb5d2d24118d10970 ' \
  'function | update_inventory_location | f1984811549d0f777b985e5a8a4b220b ' \
  'constraint | inventory_adjustments_source_type_check | 094e8bf3ca6e33940e1c8ca6cf2c96be'; do
  grep -qF "$expected" "$work/fixed.fingerprint" || fail "fixed end state lacks the production value: $expected"
done
# Every pre-existing data line is untouched by either artifact.
diff <(grep -E '^(rows|org_total) \| ' "$work/pre.txt") <(grep -E '^(rows|org_total) \| ' "$work/fixed.fingerprint") \
  || fail "pre-existing rows changed"
[ "$(grep -c -E '^rows \| ' "$work/pre.txt")" -ge 14 ] || fail "the fingerprint compared too few row groups"
echo "ok - old and fixed end states identical: schema dump, fingerprint, all pre-existing rows, new location/balance/transfer rows"
echo "ok - fixed end state carries the 12 production function hashes and the production constraint hash"

# --- 4. Induced preservation failure rolls everything back --------------------------------
python3 - "$work/fixed.sql" "$work/induced.sql" <<'PY'
import sys
text = open(sys.argv[1]).read()
marker = "\nSET CONSTRAINTS public.inventory_items_balance_invariant, public.inventory_location_balances_invariant IMMEDIATE;\n"
assert text.count(marker) == 1
tamper = """
DO $tamper$
BEGIN
  -- One extra unit lands in Unassigned through the sanctioned primitive, so the balance
  -- invariant still holds and only the quantity-preservation assertion can catch it.
  PERFORM public.inventory_apply_balance_delta(
    '7a1b0000-0000-4000-8000-000000000101', '7a1b0000-0000-4000-8000-000000000501',
    (SELECT id FROM public.inventory_locations WHERE organization_id = '7a1b0000-0000-4000-8000-000000000101' AND kind = 'unassigned'),
    1);
END
$tamper$;
"""
open(sys.argv[2], "w").write(text.replace(marker, "\n" + tamper + marker))
PY
if editor_run "$work/induced.sql" induced; then fail "the tampered migration unexpectedly succeeded"; fi
grep -qF 'Phase 7A.1 postcheck: 1 inventory items changed quantity' "$work/induced.out" \
  || fail "the tampered migration failed for another reason: $(cat "$work/induced.out")"
[ "$(seven_a1_objects induced)" = "0" ] || fail "partial 7A.1 objects survived the failed migration"
fingerprint induced > "$work/induced.fingerprint"
cmp -s "$work/pre.txt" "$work/induced.fingerprint" || fail "the failed migration left changes behind"
readonly_run supabase/release/phase7a1/precheck.sql induced > /dev/null || fail "precheck fails after the rolled-back attempt"
echo "ok - induced quantity change before COMMIT refused by the preservation assertion; everything rolled back; precheck passes"

# --- 5. A second application is refused and changes nothing --------------------------------
if editor_run "$work/fixed.sql" fixed; then fail "a second application unexpectedly succeeded"; fi
grep -qF 'Phase 7A.1 inventory location tables already exist unexpectedly' "$work/fixed.out" \
  || fail "the second application failed for another reason: $(cat "$work/fixed.out")"
fingerprint fixed > "$work/fixed.after_reapply"
cmp -s "$work/fixed.fingerprint" "$work/fixed.after_reapply" || fail "the refused reapplication changed something"
echo "ok - second application refused and changed nothing"

echo "phase7a1_sql_editor_check: all checks passed"
