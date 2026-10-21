#!/usr/bin/env bash
# Phase 7A.1 two-session concurrency checks on a disposable Postgres (all migrations applied,
# committed fixtures). Session 1 opens a transaction, performs an inventory mutation (taking
# its row locks) and holds the transaction open with pg_sleep; session 2 starts a competing
# mutation meanwhile. Each scenario then checks the committed balances: no lost update, no
# negative balance, no deadlock, and the organization-total invariant intact.
#
# Never reads .env files or talks to a hosted project.
# Requires Docker and public.ecr.aws/supabase/postgres:17.6.1.167.
# Usage: supabase/tests/phase7a1_race_check.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
container="medspend_7a1_race_$$"
port="${MEDSPEND_7A1_RACE_PORT:-55470}"
work="$(mktemp -d)"
export PGPASSWORD=postgres PGHOST=127.0.0.1 PGPORT="$port" PGOPTIONS="-c client_min_messages=warning"
owner='7a1b0000-0000-4000-8000-000000000001'
org='7a1b0000-0000-4000-8000-000000000101'

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
  psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f "$migration" >/dev/null
done
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f "$root/supabase/tests/integration/phase7a1_backfill_fixture.sql" >/dev/null

# Run SQL as the organization owner in its own session. Extra psql -c commands may precede
# the final SQL; they run after the owner identity is set.
as_owner() {
  local sql="${*: -1}"
  psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres -At \
    -c "SELECT pg_catalog.set_config('request.jwt.claim.sub', '$owner', false)" "${@:1:$#-1}" -c "$sql" | tail -n +2
}
sql() { psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres -At -c "$1"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

tape="$(sql "SELECT id FROM public.inventory_items WHERE product_id = '7a1b0000-0000-4000-8000-000000000401'")"
gauze="$(sql "SELECT id FROM public.inventory_items WHERE product_id = '7a1b0000-0000-4000-8000-000000000402'")"
unassigned="$(sql "SELECT id FROM public.inventory_locations WHERE organization_id = '$org' AND kind = 'unassigned'")"
l1="$(as_owner "SELECT public.create_inventory_location('$org', 'Race Cabinet')")"
l2="$(as_owner "SELECT public.create_inventory_location('$org', 'Race Cart')")"
l3="$(as_owner "SELECT public.create_inventory_location('$org', 'Race Storage')")"

qty() { sql "SELECT trim_scale(coalesce((SELECT quantity FROM public.inventory_location_balances WHERE inventory_item_id = '$1' AND inventory_location_id = '$2'), 0))"; }
total() { sql "SELECT trim_scale(quantity) FROM public.inventory_items WHERE id = '$1'"; }
invariant() {
  local bad
  bad="$(sql "SELECT count(*) FROM public.inventory_items i WHERE i.quantity <> coalesce((SELECT sum(b.quantity) FROM public.inventory_location_balances b WHERE b.inventory_item_id = i.id), -1) OR EXISTS (SELECT 1 FROM public.inventory_location_balances b WHERE b.inventory_item_id = i.id AND b.quantity < 0)")"
  [ "$bad" = "0" ] || fail "$1: invariant broken for $bad items"
}
expect() { [ "$2" = "$3" ] || fail "$1: expected $3, got $2"; }

# A fresh, unposted invoice of N tape rolls; prints its source file id.
new_invoice() {
  local n="$1" qty="$2"
  sql "INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type)
       VALUES ('7a1b0000-0000-4000-8000-0000000016$n', '$org', '$owner', '$org/race-$n.pdf', 'race-$n.pdf', 1024, 'application/pdf');
       INSERT INTO public.invoices (id, organization_id, source_file_id, vendor_id, vendor_name, invoice_number, processing_status, invoice_date)
       VALUES ('7a1b0000-0000-4000-8000-0000000017$n', '$org', '7a1b0000-0000-4000-8000-0000000016$n', '7a1b0000-0000-4000-8000-000000000301', 'Backfill Vendor', 'RACE-$n', 'review_required', '2026-10-0${n:1:1}');
       INSERT INTO public.invoice_items (id, invoice_id, organization_id, line_number, sku, description, quantity, unit_of_measure, unit_price, total_price, product_id)
       VALUES ('7a1b0000-0000-4000-8000-0000000018$n', '7a1b0000-0000-4000-8000-0000000017$n', '$org', 1, 'TAPE-1', 'Backfill Tape', $qty, 'roll', 2, $qty * 2, '7a1b0000-0000-4000-8000-000000000401')" >/dev/null
  echo "7a1b0000-0000-4000-8000-0000000016$n"
}

invariant "start"
expect "start total" "$(total "$tape")" "132.5"

# 1. Receiving while stock is being moved. The move holds the item; the receipt waits, then
#    lands in Unassigned on top of the moved-out balance. Neither update is lost.
inv1="$(new_invoice 01 25)"
as_owner -c "BEGIN" -c "SELECT public.move_inventory_stock('$org', '$tape', '$unassigned', '$l1', 50, 'race-1-move')" "SELECT pg_sleep(2); COMMIT" >/dev/null &
sleep 0.7
start=$(date +%s)
as_owner "SELECT public.post_reviewed_invoice('$org', '$inv1')" >/dev/null
waited=$(( $(date +%s) - start ))
wait
[ "$waited" -ge 1 ] || fail "1: receipt did not wait for the move's lock"
expect "1 Unassigned" "$(qty "$tape" "$unassigned")" "107.5"
expect "1 Cabinet" "$(qty "$tape" "$l1")" "50"
expect "1 total" "$(total "$tape")" "157.5"
invariant "1"
echo "PASS 1: receiving during a move (receipt waited ${waited}s; 132.5 - 50 + 25 = 107.5 Unassigned)"

# 2. Two moves draining the same source. Unassigned holds 107.5; each wants 70. The second
#    waits for the first, re-reads the balance, and is refused.
as_owner -c "BEGIN" -c "SELECT public.move_inventory_stock('$org', '$tape', '$unassigned', '$l1', 70, 'race-2a')" "SELECT pg_sleep(2); COMMIT" >/dev/null &
sleep 0.7
if out="$(as_owner "SELECT public.move_inventory_stock('$org', '$tape', '$unassigned', '$l2', 70, 'race-2b')" 2>&1)"; then
  wait; fail "2: second drain succeeded: $out"
fi
wait
echo "$out" | grep -q "Unassigned has only 37.5" || fail "2: unexpected refusal: $out"
expect "2 Unassigned" "$(qty "$tape" "$unassigned")" "37.5"
expect "2 Cabinet" "$(qty "$tape" "$l1")" "120"
expect "2 Cart" "$(qty "$tape" "$l2")" "0"
expect "2 total" "$(total "$tape")" "157.5"
invariant "2"
echo "PASS 2: simultaneous moves from one source (second refused after waiting: no oversell)"

# 3. Manual adjustment vs transfer. The adjustment takes 30 from Unassigned while a move
#    wants 10 of what is left (37.5 - 30 = 7.5): the move must be refused, not oversell.
as_owner -c "BEGIN" -c "SELECT public.adjust_inventory_quantity('$org', '$tape', -30, 'Correction')" "SELECT pg_sleep(2); COMMIT" >/dev/null &
sleep 0.7
if out="$(as_owner "SELECT public.move_inventory_stock('$org', '$tape', '$unassigned', '$l2', 10, 'race-3')" 2>&1)"; then
  wait; fail "3: move succeeded against a pending adjustment: $out"
fi
wait
echo "$out" | grep -q "Unassigned has only 7.5" || fail "3: unexpected refusal: $out"
expect "3 Unassigned" "$(qty "$tape" "$unassigned")" "7.5"
expect "3 total" "$(total "$tape")" "127.5"
invariant "3"
echo "PASS 3: manual adjustment vs transfer"

# 4a. Invoice deletion while another mutation holds the item. A move takes Unassigned down to
#     zero; the waiting deletion of a 25-roll receipt then finds Unassigned short and refuses.
as_owner -c "BEGIN" -c "SELECT public.move_inventory_stock('$org', '$tape', '$unassigned', '$l3', 7.5, 'race-4a')" "SELECT pg_sleep(2); COMMIT" >/dev/null &
sleep 0.7
if out="$(as_owner "SELECT public.delete_invoice_permanently('$org', '$inv1')" 2>&1)"; then
  wait; fail "4a: deletion succeeded with receipt stock moved away: $out"
fi
wait
echo "$out" | grep -q "Move 25 roll of Backfill Tape back to Unassigned before deleting this invoice." || fail "4a: unexpected refusal: $out"
expect "4a total" "$(total "$tape")" "127.5"
expect "4a invoice kept" "$(sql "SELECT count(*) FROM public.invoices WHERE source_file_id = '$inv1'")" "1"
invariant "4a"
echo "PASS 4a: deletion waiting on a move refuses when Unassigned is short"

# 4b. A deletion holding the item, with an adjustment elsewhere queued behind it. Move 25 back
#     first; the deletion commits, then the Cabinet adjustment applies on the new state.
as_owner "SELECT public.move_inventory_stock('$org', '$tape', '$l1', '$unassigned', 25, 'race-4b-refill')" >/dev/null
psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres -At \
  -c "SELECT pg_catalog.set_config('request.jwt.claim.sub', '$owner', false)" \
  -c "BEGIN" -c "SELECT public.delete_invoice_permanently('$org', '$inv1')" -c "SELECT pg_sleep(2)" -c "COMMIT" >/dev/null &
sleep 0.7
as_owner "SELECT public.adjust_inventory_location_quantity('$org', '$tape', '$l1', -5, 'Damaged')" >/dev/null
wait
expect "4b invoice deleted" "$(sql "SELECT count(*) FROM public.invoices WHERE source_file_id = '$inv1'")" "0"
expect "4b Unassigned" "$(qty "$tape" "$unassigned")" "0"
expect "4b Cabinet" "$(qty "$tape" "$l1")" "90"
expect "4b total" "$(total "$tape")" "97.5"
invariant "4b"
echo "PASS 4b: deletion and a queued adjustment both apply, in order"

# 5. Archive vs move into that location. The move holds a share lock on the destination; the
#    archive waits, then sees stock and refuses.
as_owner -c "BEGIN" -c "SELECT public.move_inventory_stock('$org', '$tape', '$l1', '$l2', 4, 'race-5')" "SELECT pg_sleep(2); COMMIT" >/dev/null &
sleep 0.7
if out="$(as_owner "SELECT public.set_inventory_location_active('$org', '$l2', false)" 2>&1)"; then
  wait; fail "5: archive succeeded under an incoming move: $out"
fi
wait
echo "$out" | grep -q "Move all stock out of Race Cart before archiving it" || fail "5: unexpected refusal: $out"
expect "5 Cart active" "$(sql "SELECT active FROM public.inventory_locations WHERE id = '$l2'")" "t"
invariant "5"
echo "PASS 5: archive cannot strand stock arriving concurrently"

# 6. Opposite-direction move storms between two locations and Unassigned, on two items,
#    in parallel. Every move takes the item lock first, then balances in location-id order,
#    so there must be no deadlock and no lost update.
as_owner "SELECT public.move_inventory_stock('$org', '$gauze', '$unassigned', '$l1', 2, 'race-6-seed')" >/dev/null
as_owner "SELECT public.move_inventory_stock('$org', '$tape', '$l1', '$l2', 20, 'race-6-seed-cart')" >/dev/null
storm() {
  local dir="$1" i
  for i in $(seq 1 25); do
    if [ "$dir" = "a" ]; then
      as_owner "SELECT public.move_inventory_stock('$org', '$tape', '$l1', '$l2', 1, 'race-6-a-$i'); SELECT public.move_inventory_stock('$org', '$gauze', '$l1', '$unassigned', 0.01, 'race-6-ga-$i')" >/dev/null
    else
      as_owner "SELECT public.move_inventory_stock('$org', '$tape', '$l2', '$l1', 0.5, 'race-6-b-$i'); SELECT public.move_inventory_stock('$org', '$gauze', '$unassigned', '$l1', 0.02, 'race-6-gb-$i')" >/dev/null
    fi
  done
}
storm a 2>"$work/storm_a.err" & pid_a=$!
storm b 2>"$work/storm_b.err" & pid_b=$!
wait "$pid_a" || fail "6: storm a failed: $(cat "$work/storm_a.err")"
wait "$pid_b" || fail "6: storm b failed: $(cat "$work/storm_b.err")"
grep -qi deadlock "$work/storm_a.err" "$work/storm_b.err" && fail "6: deadlock detected"
expect "6 Cabinet" "$(qty "$tape" "$l1")" "53.5"
expect "6 Cart" "$(qty "$tape" "$l2")" "36.5"
expect "6 tape total" "$(total "$tape")" "97.5"
expect "6 gauze total" "$(total "$gauze")" "3.75"
expect "6 gauze Cabinet" "$(qty "$gauze" "$l1")" "2.25"
expect "6 transfers" "$(sql "SELECT count(*) FROM public.inventory_transfers WHERE idempotency_key LIKE 'race-6-%' AND idempotency_key NOT LIKE 'race-6-seed%'")" "100"
invariant "6"
echo "PASS 6: 100 concurrent opposite-direction moves, no deadlock, totals exact"

# 7. Duplicate concurrent retries of one move request: exactly one applies.
as_owner -c "BEGIN" -c "SELECT public.move_inventory_stock('$org', '$tape', '$l1', '$l3', 3, 'race-7')" "SELECT pg_sleep(2); COMMIT" >/dev/null &
sleep 0.7
replayed="$(as_owner "SELECT (public.move_inventory_stock('$org', '$tape', '$l1', '$l3', 3, 'race-7') ->> 'replayed')")"
wait
expect "7 replayed" "$replayed" "true"
expect "7 Storage" "$(qty "$tape" "$l3")" "10.5"
expect "7 transfer rows" "$(sql "SELECT count(*) FROM public.inventory_transfers WHERE idempotency_key = 'race-7'")" "1"
invariant "7"
echo "PASS 7: concurrent retry of one move applied once"

# 8. A committed transaction that drifts the summary from the balances fails at COMMIT, and
#    none of its writes persist.
if out="$(psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres -At \
  -c "BEGIN" \
  -c "UPDATE public.inventory_items SET name = 'Drifted' WHERE id = '$gauze'" \
  -c "SELECT set_config('medspend.inventory_sync', 'on', true)" \
  -c "UPDATE public.inventory_items SET quantity = quantity + 1 WHERE id = '$gauze'" \
  -c "COMMIT" 2>&1)"; then
  fail "8: drifting transaction committed: $out"
fi
echo "$out" | grep -q "Inventory invariant violated" || fail "8: unexpected error: $out"
expect "8 name" "$(sql "SELECT name FROM public.inventory_items WHERE id = '$gauze'")" "Backfill Gauze"
expect "8 total" "$(total "$gauze")" "3.75"
invariant "8"
echo "PASS 8: drift aborts the whole transaction at commit"

echo "phase7a1_race_check: all checks passed"
