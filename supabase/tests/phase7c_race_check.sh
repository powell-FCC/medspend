#!/usr/bin/env bash
# Phase 7C race check: receipts in two real database sessions at once (a rollback-only suite runs
# in one transaction and cannot show this). Boots its own disposable Postgres with every migration
# (container logs capped). Never reads .env files or talks to a hosted project.
#
#   1. Two Receive & Complete calls at once to the same destination (Lean): one applies, the other
#      waits for the row lock and returns alreadyApplied; exactly one receipt.
#   2. Two Receive & Complete calls at once to different destinations: the first wins, the second
#      waits and is refused; the receipt keeps the first destination (never overwritten).
#   3. Two Mark Received calls at once (Detailed): one receipt, the other alreadyApplied.
#   4. A receipt in flight holds its destination: archiving that location waits until the receipt
#      commits, then succeeds (the location had no stock); the receipt keeps its name snapshot.
#
# Requires Docker and public.ecr.aws/supabase/postgres:17.6.1.167.
# Usage: supabase/tests/phase7c_race_check.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
container="medspend_7c_race_$$"
port="${MEDSPEND_7C_RACE_PORT:-55665}"
work="$(mktemp -d)"
export PGPASSWORD=postgres PGHOST=127.0.0.1 PGPORT="$port" PGOPTIONS="-c client_min_messages=warning"
cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
q() { psql -X -q -At -v ON_ERROR_STOP=1 -U postgres -d postgres -c "$1"; }

docker run -d --log-opt max-size=10m --log-opt max-file=1 --name "$container" -e POSTGRES_PASSWORD=postgres -p "127.0.0.1:$port:5432" \
  public.ecr.aws/supabase/postgres:17.6.1.167 >/dev/null
for _ in $(seq 1 60); do
  if psql -U supabase_admin -d postgres -Atc "select 1 from pg_roles where rolname = 'authenticator'" 2>/dev/null | grep -q 1; then break; fi
  sleep 2
done
sleep 5
cd "$root"
psql -q -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -f supabase/tests/integration/local_stack_setup.sql >/dev/null
for migration in supabase/migrations/*.sql; do
  psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f "$migration" >/dev/null
done

org=7c1e0000-0000-4000-8000-000000000101
owner=7c1e0000-0000-4000-8000-000000000001
admin=7c1e0000-0000-4000-8000-000000000002
staff=7c1e0000-0000-4000-8000-000000000003
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
VALUES ('$owner', 'authenticated', 'authenticated', 'race-owner@example.invalid', '', now(), '{}', '{"full_name":"Race Owner"}', now(), now()),
       ('$admin', 'authenticated', 'authenticated', 'race-admin@example.invalid', '', now(), '{}', '{"full_name":"Race Admin"}', now(), now()),
       ('$staff', 'authenticated', 'authenticated', 'race-staff@example.invalid', '', now(), '{}', '{"full_name":"Race Staff"}', now(), now());
INSERT INTO public.organizations (id, name, created_by) VALUES ('$org', 'Phase 7C Race', '$owner');
INSERT INTO public.teams (id, organization_id, name, active) VALUES ('7c1e0000-0000-4000-8000-000000000201', '$org', 'Race Team', true);
INSERT INTO public.locations (id, organization_id, name, active) VALUES ('7c1e0000-0000-4000-8000-000000000211', '$org', 'Race Room', true);
INSERT INTO public.organization_memberships (organization_id, user_id, role, active, default_team_id, default_location_id) VALUES
  ('$org', '$owner', 'owner', true, NULL, NULL),
  ('$org', '$admin', 'admin', true, NULL, NULL),
  ('$org', '$staff', 'staff', true, '7c1e0000-0000-4000-8000-000000000201', '7c1e0000-0000-4000-8000-000000000211');
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$admin', false);
SELECT public.update_organization_request_workflow_settings('$org', 'lean');
SELECT set_config('request.jwt.claim.sub', '$staff', false);
SQL
submit() {  # <label> -> request id
  q "SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub', '$staff', false);
     SELECT public.submit_supply_request('$org', 'reorder', NULL, NULL, NULL,
       jsonb_build_array(jsonb_build_object('freeTextItem', '$1', 'quantity', 1)));" | tail -1
}
version() { q "SELECT updated_at FROM public.supply_requests WHERE id = '$1'"; }
session() {  # <user> <sql> : runs as an authenticated user in one transaction
  psql -X -q -At -v ON_ERROR_STOP=1 -U postgres -d postgres <<SQL
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$1', false);
$2
SQL
}
receipts() { q "SELECT count(*) || ':' || coalesce(string_agg(destination_name_snapshot, ','), '') FROM public.supply_request_receipts WHERE supply_request_id = '$1'"; }
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
INSERT INTO public.inventory_locations (id, organization_id, name, kind, active) VALUES
  ('7c1e0000-0000-4000-8000-000000000301', '$org', 'First Team ATR', 'storage', true),
  ('7c1e0000-0000-4000-8000-000000000302', '$org', 'Academy ATR', 'storage', true),
  ('7c1e0000-0000-4000-8000-000000000303', '$org', 'Temporary Cage', 'storage', true);
SQL
ft=7c1e0000-0000-4000-8000-000000000301
academy=7c1e0000-0000-4000-8000-000000000302
cage=7c1e0000-0000-4000-8000-000000000303
ordered() {  # <label> -> request id, approved and ordered in one step (Lean)
  local r; r=$(submit "$1")
  session "$admin" "SELECT public.approve_and_order_supply_request('$org', '$r', NULL, NULL, '$(version "$r")');" >/dev/null
  echo "$r"
}

# 1. Same destination at once.
r1=$(ordered "Race same destination")
session "$admin" "BEGIN; SELECT public.receive_and_complete_supply_request('$org', '$r1', NULL, NULL, '$ft'); SELECT pg_sleep(3); COMMIT;" > "$work/1a" 2>&1 &
sleep 1
session "$owner" "SELECT public.receive_and_complete_supply_request('$org', '$r1', NULL, NULL, '$ft') ->> 'alreadyApplied';" > "$work/1b" 2>&1 \
  || fail "second same-destination call failed: $(cat "$work/1b")"
wait
[ "$(tail -1 "$work/1b")" = "true" ] || fail "1: second call was not alreadyApplied: $(cat "$work/1b")"
[ "$(receipts "$r1")" = "1:First Team ATR" ] || fail "1: receipts $(receipts "$r1")"
echo "ok - same destination at once: one receipt, the second call alreadyApplied"

# 2. Different destinations at once.
r2=$(ordered "Race different destinations")
session "$admin" "BEGIN; SELECT public.receive_and_complete_supply_request('$org', '$r2', NULL, NULL, '$ft'); SELECT pg_sleep(3); COMMIT;" > "$work/2a" 2>&1 &
sleep 1
if session "$owner" "SELECT public.receive_and_complete_supply_request('$org', '$r2', NULL, NULL, '$academy');" > "$work/2b" 2>&1; then
  fail "a different destination was accepted after a concurrent receipt: $(cat "$work/2b")"
fi
wait
grep -q "already received to First Team ATR" "$work/2b" || fail "2: unexpected refusal: $(cat "$work/2b")"
[ "$(receipts "$r2")" = "1:First Team ATR" ] || fail "2: receipts $(receipts "$r2")"
echo "ok - different destinations at once: the first wins, the second is refused, nothing overwritten"

# 3. Two Mark Received at once (Detailed).
session "$owner" "SELECT public.update_organization_request_workflow_settings('$org', 'detailed');" >/dev/null
r3=$(submit "Race Mark Received")
session "$admin" "SELECT public.decide_supply_request('$org', '$r3', 'approved', NULL, NULL, '$(version "$r3")'); SELECT public.transition_supply_request('$org', '$r3', 'ordered');" >/dev/null
session "$admin" "BEGIN; SELECT public.receive_supply_request('$org', '$r3', NULL, NULL, '$academy'); SELECT pg_sleep(3); COMMIT;" > "$work/3a" 2>&1 &
sleep 1
session "$owner" "SELECT public.receive_supply_request('$org', '$r3', NULL, NULL, '$academy') ->> 'alreadyApplied';" > "$work/3b" 2>&1 \
  || fail "second Mark Received failed: $(cat "$work/3b")"
wait
[ "$(tail -1 "$work/3b")" = "true" ] || fail "3: second call was not alreadyApplied"
[ "$(receipts "$r3")" = "1:Academy ATR" ] || fail "3: receipts $(receipts "$r3")"
[ "$(q "SELECT count(*) FROM public.supply_request_updates WHERE supply_request_id = '$r3' AND status_to = 'received'")" = "1" ] || fail "3: received rows"
echo "ok - two Mark Received at once: one receipt, one received row"

# 4. Archiving a destination while a receipt to it is in flight.
r4=$(submit "Race archive")
session "$admin" "SELECT public.decide_supply_request('$org', '$r4', 'approved', NULL, NULL, '$(version "$r4")'); SELECT public.transition_supply_request('$org', '$r4', 'ordered');" >/dev/null
session "$admin" "BEGIN; SELECT public.receive_supply_request('$org', '$r4', NULL, NULL, '$cage'); SELECT pg_sleep(3); COMMIT;" > "$work/4a" 2>&1 &
sleep 1
start=$(date +%s)
session "$owner" "SELECT public.set_inventory_location_active('$org', '$cage', false);" > "$work/4b" 2>&1 || fail "archive failed: $(cat "$work/4b")"
elapsed=$(( $(date +%s) - start ))
wait
[ "$elapsed" -ge 1 ] || fail "4: the archive did not wait for the receipt in flight (${elapsed}s)"
[ "$(receipts "$r4")" = "1:Temporary Cage" ] || fail "4: receipts $(receipts "$r4")"
[ "$(q "SELECT active FROM public.inventory_locations WHERE id = '$cage'")" = "f" ] || fail "4: not archived"
echo "ok - archiving a destination waits for an in-flight receipt; the receipt keeps its snapshot"

echo "phase 7C race check passed"
