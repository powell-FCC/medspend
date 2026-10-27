#!/usr/bin/env bash
# Phase 7A.2 two-session concurrency checks for physical counts, on a disposable Postgres
# (every migration applied, committed fixtures). Session 1 opens a transaction, performs an
# inventory mutation (taking its locks) and holds it open with pg_sleep; session 2 submits a
# competing count or mutation meanwhile. Each scenario checks the committed result: a stale
# count is refused rather than overwriting newer stock, retries replay, nothing deadlocks,
# and the organization-total invariant holds.
#
# Never reads .env files or talks to a hosted project.
# Requires Docker and public.ecr.aws/supabase/postgres:17.6.1.167.
# Usage: supabase/tests/phase7a2_race_check.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
container="medspend_7a2_race_$$"
port="${MEDSPEND_7A2_RACE_PORT:-55475}"
export PGPASSWORD=postgres PGHOST=127.0.0.1 PGPORT="$port" PGOPTIONS="-c client_min_messages=warning"
owner='7a1b0000-0000-4000-8000-000000000001'
org='7a1b0000-0000-4000-8000-000000000101'

cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; }
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
  psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f "$migration" >/dev/null
done
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f "$root/supabase/tests/integration/phase7a1_backfill_fixture.sql" >/dev/null

# SQL as the organization owner (an active member) in its own session. Extra psql -c commands
# may precede the final SQL; they run after the identity is set.
as_owner() {
  local sql="${*: -1}"
  psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres -At \
    -c "SELECT pg_catalog.set_config('request.jwt.claim.sub', '$owner', false)" "${@:1:$#-1}" -c "$sql" | tail -n +2
}
sql() { psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres -At -c "$1"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
expect() { [ "$2" = "$3" ] || fail "$1: expected $3, got $2"; }

tape="$(sql "SELECT id FROM public.inventory_items WHERE product_id = '7a1b0000-0000-4000-8000-000000000401'")"
gauze="$(sql "SELECT id FROM public.inventory_items WHERE product_id = '7a1b0000-0000-4000-8000-000000000402'")"
unassigned="$(sql "SELECT id FROM public.inventory_locations WHERE organization_id = '$org' AND kind = 'unassigned'")"
l1="$(as_owner "SELECT public.create_inventory_location('$org', 'Count Cabinet')")"
l2="$(as_owner "SELECT public.create_inventory_location('$org', 'Count Cart')")"

qty() { sql "SELECT trim_scale(coalesce((SELECT quantity FROM public.inventory_location_balances WHERE inventory_item_id = '$1' AND inventory_location_id = '$2'), 0))"; }
total() { sql "SELECT trim_scale(quantity) FROM public.inventory_items WHERE id = '$1'"; }
sessions() { sql "SELECT count(*) FROM public.inventory_count_sessions WHERE organization_id = '$org'"; }
invariant() {
  local bad
  bad="$(sql "SELECT count(*) FROM public.inventory_items i WHERE i.quantity <> coalesce((SELECT sum(b.quantity) FROM public.inventory_location_balances b WHERE b.inventory_item_id = i.id), -1) OR EXISTS (SELECT 1 FROM public.inventory_location_balances b WHERE b.inventory_item_id = i.id AND b.quantity < 0)")"
  [ "$bad" = "0" ] || fail "$1: invariant broken for $bad items"
  bad="$(sql "SELECT count(*) FROM public.inventory_count_lines line WHERE NOT EXISTS (SELECT 1 FROM public.inventory_adjustments a WHERE a.inventory_count_line_id = line.id AND a.adjustment_amount = line.delta)")"
  [ "$bad" = "0" ] || fail "$1: $bad count lines without their ledger row"
}
# The count page as it is now, turned into a submission confirming every quantity (optionally
# overriding one item's count): what a browser holds after loading the page.
page() {
  local location="$1" item="${2:-}" counted="${3:-}"
  as_owner "SELECT jsonb_agg(jsonb_build_object('inventoryItemId', i->>'inventoryItemId', 'observedVersion', (i->>'version')::bigint,
      'countedQuantity', CASE WHEN i->>'inventoryItemId' = '$item' THEN '$counted' ELSE i->>'quantity' END))
    FROM jsonb_array_elements(public.get_inventory_count_location('$org', '$location')->'items') i"
}
submit() { echo "SELECT public.submit_inventory_count('$org', '$1', '$2'::jsonb, '$3')"; }
new_invoice() {  # <two digits> <quantity>; prints the source file id
  local n="$1" qty="$2"
  sql "INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type)
       VALUES ('7a1b0000-0000-4000-8000-0000000026$n', '$org', '$owner', '$org/count-race-$n.pdf', 'count-race-$n.pdf', 1024, 'application/pdf');
       INSERT INTO public.invoices (id, organization_id, source_file_id, vendor_id, vendor_name, invoice_number, processing_status, invoice_date)
       VALUES ('7a1b0000-0000-4000-8000-0000000027$n', '$org', '7a1b0000-0000-4000-8000-0000000026$n', '7a1b0000-0000-4000-8000-000000000301', 'Backfill Vendor', 'COUNT-RACE-$n', 'review_required', '2026-10-2${n:1:1}');
       INSERT INTO public.invoice_items (id, invoice_id, organization_id, line_number, sku, description, quantity, unit_of_measure, unit_price, total_price, product_id)
       VALUES ('7a1b0000-0000-4000-8000-0000000028$n', '7a1b0000-0000-4000-8000-0000000027$n', '$org', 1, 'TAPE-1', 'Backfill Tape', $qty, 'roll', 2, $qty * 2, '7a1b0000-0000-4000-8000-000000000401')" >/dev/null
  echo "7a1b0000-0000-4000-8000-0000000026$n"
}

as_owner "SELECT public.move_inventory_stock('$org', '$tape', '$unassigned', '$l1', 10, 'setup-1')" >/dev/null
as_owner "SELECT public.move_inventory_stock('$org', '$gauze', '$unassigned', '$l1', 1, 'setup-2')" >/dev/null
invariant "start"

# 1. A move into the location lands while the count is being submitted. The count waits for
#    the item lock, sees the newer version and is refused: the move is not overwritten.
p="$(page "$l1" "$tape" 9)"
as_owner -c "BEGIN" -c "SELECT public.move_inventory_stock('$org', '$tape', '$unassigned', '$l1', 5, 'race-1-move')" "SELECT pg_sleep(2); COMMIT" >/dev/null &
sleep 0.7
start=$(date +%s)
if out="$(as_owner "$(submit "$l1" "$p" race-1)" 2>&1)"; then wait; fail "1: stale count accepted: $out"; fi
waited=$(( $(date +%s) - start ))
wait
[ "$waited" -ge 1 ] || fail "1: count did not wait for the move"
echo "$out" | grep -q "Inventory changed while you were counting" || fail "1: unexpected refusal: $out"
expect "1 cabinet" "$(qty "$tape" "$l1")" "15"
expect "1 sessions" "$(sessions)" "0"
invariant "1"
echo "PASS 1: move during count (count waited ${waited}s, refused as stale; move kept)"

# 2. A different item is moved into the location mid-count: the item set changed.
p="$(page "$l1")"
item_count="$(echo "$p" | grep -o inventoryItemId | wc -l | tr -d ' ')"
expect "2 page items" "$item_count" "2"
other="$(sql "SELECT id FROM public.inventory_items WHERE organization_id = '$org' AND active AND id NOT IN ('$tape', '$gauze') AND quantity > 0 ORDER BY id LIMIT 1")"
as_owner -c "BEGIN" -c "SELECT public.move_inventory_stock('$org', '$other', '$unassigned', '$l1', 1, 'race-2-move')" "SELECT pg_sleep(2); COMMIT" >/dev/null &
sleep 0.7
if out="$(as_owner "$(submit "$l1" "$p" race-2)" 2>&1)"; then wait; fail "2: incomplete count accepted: $out"; fi
wait
echo "$out" | grep -q "Inventory changed while you were counting" || fail "2: unexpected refusal: $out"
expect "2 new item at cabinet" "$(qty "$other" "$l1")" "1"
expect "2 sessions" "$(sessions)" "0"
invariant "2"
echo "PASS 2: item added to the location during count (count waited for the location lock, refused)"

# 3. An owner adjustment at the location during the count.
p="$(page "$l1" "$tape" 14)"
as_owner -c "BEGIN" -c "SELECT public.adjust_inventory_location_quantity('$org', '$tape', '$l1', -2, 'Damaged')" "SELECT pg_sleep(2); COMMIT" >/dev/null &
sleep 0.7
if out="$(as_owner "$(submit "$l1" "$p" race-3)" 2>&1)"; then wait; fail "3: stale count accepted: $out"; fi
wait
echo "$out" | grep -q "Inventory changed while you were counting" || fail "3: unexpected refusal: $out"
expect "3 cabinet" "$(qty "$tape" "$l1")" "13"
invariant "3"
echo "PASS 3: owner adjustment during count (adjustment kept, count refused)"

# 4. Two people submit counts of the same page. The second waits, sees the first count's
#    version bumps (zero deltas included) and is refused: only one count wins.
p="$(page "$l1")"
as_owner -c "BEGIN" -c "$(submit "$l1" "$p" race-4a)" "SELECT pg_sleep(2); COMMIT" >/dev/null &
sleep 0.7
if out="$(as_owner "$(submit "$l1" "$p" race-4b)" 2>&1)"; then wait; fail "4: second simultaneous count accepted: $out"; fi
wait
echo "$out" | grep -q "Inventory changed while you were counting" || fail "4: unexpected refusal: $out"
expect "4 sessions" "$(sessions)" "1"
invariant "4"
echo "PASS 4: simultaneous counts of one location (exactly one recorded)"

# 5. A retry of the same request while the first attempt is still committing replays it.
p="$(page "$l1" "$tape" 12.5)"
as_owner -c "BEGIN" -c "$(submit "$l1" "$p" race-5)" "SELECT pg_sleep(2); COMMIT" >/dev/null &
sleep 0.7
out="$(as_owner "$(submit "$l1" "$p" race-5)")"
wait
echo "$out" | grep -q '"replayed": true' || fail "5: retry did not replay: $out"
expect "5 sessions" "$(sessions)" "2"
expect "5 cabinet" "$(qty "$tape" "$l1")" "12.5"
invariant "5"
echo "PASS 5: concurrent retry with the same key replays the original count"

# 6. Receiving while a count holds the item: the receipt waits, then lands in Unassigned on
#    top of the counted state. Neither is lost.
inv_before="$(new_invoice 01 6)"
p="$(page "$l1" "$tape" 11)"
before_total="$(total "$tape")"
as_owner -c "BEGIN" -c "$(submit "$l1" "$p" race-6)" "SELECT pg_sleep(2); COMMIT" >/dev/null &
sleep 0.7
start=$(date +%s)
as_owner "SELECT public.post_reviewed_invoice('$org', '$inv_before')" >/dev/null
waited=$(( $(date +%s) - start ))
wait
[ "$waited" -ge 1 ] || fail "6: receipt did not wait for the count"
expect "6 cabinet" "$(qty "$tape" "$l1")" "11"
expect "6 total" "$(total "$tape")" "$(sql "SELECT trim_scale($before_total - 1.5 + 6)")"
invariant "6"
echo "PASS 6: receiving during a count (receipt waited ${waited}s; counted shelf and receipt both kept)"

# 7. A move out of the location queued behind a count proceeds from the counted quantity.
p="$(page "$l1" "$gauze" 0.5)"
as_owner -c "BEGIN" -c "$(submit "$l1" "$p" race-7)" "SELECT pg_sleep(2); COMMIT" >/dev/null &
sleep 0.7
if out="$(as_owner "SELECT public.move_inventory_stock('$org', '$gauze', '$l1', '$l2', 1, 'race-7-move')" 2>&1)"; then
  wait; fail "7: move of more than the counted stock succeeded: $out"
fi
wait
echo "$out" | grep -q "Count Cabinet has only 0.5" || fail "7: unexpected refusal: $out"
as_owner "SELECT public.move_inventory_stock('$org', '$gauze', '$l1', '$l2', 0.5, 'race-7-move-ok')" >/dev/null
expect "7 cabinet gauze" "$(qty "$gauze" "$l1")" "0"
expect "7 cart gauze" "$(qty "$gauze" "$l2")" "0.5"
invariant "7"
echo "PASS 7: move queued behind a count sees the counted quantity (no deadlock)"

# 8. Archiving the location while a count is submitted. Cart holds stock, so archive it empty
#    first: move the gauze back, then archive (held open) while a count of Cart arrives.
as_owner "SELECT public.move_inventory_stock('$org', '$gauze', '$l2', '$unassigned', 0.5, 'race-8-empty')" >/dev/null
p="$(page "$l2")"
as_owner -c "BEGIN" -c "SELECT public.set_inventory_location_active('$org', '$l2', false)" "SELECT pg_sleep(2); COMMIT" >/dev/null &
sleep 0.7
if out="$(as_owner "$(submit "$l2" "$p" race-8)" 2>&1)"; then wait; fail "8: count of an archived location accepted: $out"; fi
wait
echo "$out" | grep -q "not available for counting" || fail "8: unexpected refusal: $out"
invariant "8"
echo "PASS 8: archive during count (count waited, refused: location unavailable)"

# 9. Checkpoints across real transactions. The receipt posted before the latest count cannot
#    be deleted; a receipt posted after it deletes normally from Unassigned.
inv_after="$(new_invoice 02 4)"
as_owner "SELECT public.post_reviewed_invoice('$org', '$inv_after')" >/dev/null
if out="$(as_owner "SELECT public.delete_invoice_permanently('$org', '$inv_before')" 2>&1)"; then
  fail "9: receipt counted over was deleted: $out"
fi
echo "$out" | grep -q "was physically counted after it was received" || fail "9: unexpected refusal: $out"
before_total="$(total "$tape")"
as_owner "SELECT public.delete_invoice_permanently('$org', '$inv_after')" >/dev/null
expect "9 total" "$(total "$tape")" "$(sql "SELECT trim_scale($before_total - 4)")"
expect "9 cabinet untouched" "$(qty "$tape" "$l1")" "11"
invariant "9"
echo "PASS 9: earlier receipt blocked by the count checkpoint; later receipt deleted normally"

echo "phase7a2_race_check: all checks passed"
