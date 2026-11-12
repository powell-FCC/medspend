#!/usr/bin/env bash
# Phase 7C.0 race check: compound request actions in two real database sessions at once (a
# rollback-only suite runs in one transaction and cannot show this). Boots its own disposable
# Postgres with every migration. Never reads .env files or talks to a hosted project.
#
#   1. Approve & Order while a Decline is in flight: the decline wins, Approve & Order waits for
#      the row lock and is refused; no commitment, no Approved event, no partial history.
#   2. Decline while Approve & Order is in flight: Approve & Order wins, the decline waits and is
#      refused; exactly one Approved event, the full marked history, an active commitment.
#   3. Two Approve & Order calls at once (double tap from two tabs): one applies, the other
#      waits and returns alreadyApplied; three canonical rows, one Approved event.
#   4. Two Receive & Complete calls at once: one applies, the other returns alreadyApplied; two
#      marked rows, no notification event.
#   5. Real transactions: a request moved to under_review in an earlier transaction keeps that
#      row unmarked; only the rows written by the bundle carry the marker and share its
#      timestamp. The committed digest shows none of the bundled requests as approved but not
#      ordered, while a genuinely approved request is listed.
#
# Requires Docker and public.ecr.aws/supabase/postgres:17.6.1.167.
# Usage: supabase/tests/phase7c0_race_check.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
container="medspend_7c0_race_$$"
port="${MEDSPEND_7C0_RACE_PORT:-55625}"
work="$(mktemp -d)"
export PGPASSWORD=postgres PGHOST=127.0.0.1 PGPORT="$port" PGOPTIONS="-c client_min_messages=warning"
cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
q() { psql -X -q -At -v ON_ERROR_STOP=1 -U postgres -d postgres -c "$1"; }

docker run -d --name "$container" -e POSTGRES_PASSWORD=postgres -p "127.0.0.1:$port:5432" \
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

org=7c0e0000-0000-4000-8000-000000000101
owner=7c0e0000-0000-4000-8000-000000000001
admin=7c0e0000-0000-4000-8000-000000000002
staff=7c0e0000-0000-4000-8000-000000000003
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
VALUES ('$owner', 'authenticated', 'authenticated', 'race-owner@example.invalid', '', now(), '{}', '{"full_name":"Race Owner"}', now(), now()),
       ('$admin', 'authenticated', 'authenticated', 'race-admin@example.invalid', '', now(), '{}', '{"full_name":"Race Admin"}', now(), now()),
       ('$staff', 'authenticated', 'authenticated', 'race-staff@example.invalid', '', now(), '{}', '{"full_name":"Race Staff"}', now(), now());
INSERT INTO public.organizations (id, name, created_by) VALUES ('$org', 'Phase 7C.0 Race', '$owner');
INSERT INTO public.teams (id, organization_id, name, active) VALUES ('7c0e0000-0000-4000-8000-000000000201', '$org', 'Race Team', true);
INSERT INTO public.locations (id, organization_id, name, active) VALUES ('7c0e0000-0000-4000-8000-000000000211', '$org', 'Race Room', true);
INSERT INTO public.organization_memberships (organization_id, user_id, role, active, default_team_id, default_location_id) VALUES
  ('$org', '$owner', 'owner', true, NULL, NULL),
  ('$org', '$admin', 'admin', true, NULL, NULL),
  ('$org', '$staff', 'staff', true, '7c0e0000-0000-4000-8000-000000000201', '7c0e0000-0000-4000-8000-000000000211');
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
events() { q "SELECT coalesce(string_agg(event_type, ',' ORDER BY event_type), '') FROM public.notification_events WHERE entity_id = '$1'"; }
trail() { q "SELECT string_agg(concat(status_to, ':', coalesce(compound_action, '-')), ' ' ORDER BY created_at, status_to, id) FROM public.supply_request_updates WHERE supply_request_id = '$1'"; }

# 1. Decline in flight, then Approve & Order.
r1=$(submit "Race decline first"); v1=$(version "$r1")
session "$owner" "BEGIN; SELECT public.decide_supply_request('$org', '$r1', 'denied', 'Not this time', NULL, '$v1'); SELECT pg_sleep(3); COMMIT;" > "$work/1a" 2>&1 &
sleep 1
if session "$admin" "SELECT public.approve_and_order_supply_request('$org', '$r1', NULL, NULL, '$v1');" > "$work/1b" 2>&1; then
  fail "Approve & Order succeeded after a concurrent decline: $(cat "$work/1b")"
fi
wait
grep -q "can no longer be approved and ordered" "$work/1b" || fail "unexpected refusal: $(cat "$work/1b")"
[ "$(q "SELECT status FROM public.supply_requests WHERE id = '$r1'")" = "denied" ] || fail "1: status"
[ "$(events "$r1")" = "request_denied,request_submitted" ] || fail "1: events $(events "$r1")"
[ "$(q "SELECT count(*) FROM public.supply_request_commitments WHERE supply_request_id = '$r1'")" = "0" ] || fail "1: commitment"
[ "$(trail "$r1")" = "denied:-" ] || fail "1: history $(trail "$r1")"
echo "ok - decline in flight: Approve & Order waits and is refused; nothing partial written"

# 2. Approve & Order in flight, then Decline.
r2=$(submit "Race approve first"); v2=$(version "$r2")
session "$admin" "BEGIN; SELECT public.approve_and_order_supply_request('$org', '$r2', 'Ordered', NULL, '$v2'); SELECT pg_sleep(3); COMMIT;" > "$work/2a" 2>&1 &
sleep 1
if session "$owner" "SELECT public.decide_supply_request('$org', '$r2', 'denied', 'Too late', NULL, '$v2');" > "$work/2b" 2>&1; then
  fail "decline succeeded after a concurrent Approve & Order: $(cat "$work/2b")"
fi
wait
grep -q "already been decided" "$work/2b" || fail "unexpected refusal: $(cat "$work/2b")"
[ "$(trail "$r2")" = "under_review:approve_and_order approved:approve_and_order ordered:approve_and_order" ] || fail "2: history $(trail "$r2")"
[ "$(events "$r2")" = "request_approved,request_submitted" ] || fail "2: events $(events "$r2")"
[ "$(q "SELECT status FROM public.supply_request_commitments WHERE supply_request_id = '$r2'")" = "active" ] || fail "2: commitment"
echo "ok - Approve & Order in flight: the decline waits and is refused; one Approved event"

# 3. Two Approve & Order calls at once.
r3=$(submit "Race double approve"); v3=$(version "$r3")
session "$admin" "BEGIN; SELECT public.approve_and_order_supply_request('$org', '$r3', NULL, NULL, '$v3'); SELECT pg_sleep(3); COMMIT;" > "$work/3a" 2>&1 &
sleep 1
session "$owner" "SELECT public.approve_and_order_supply_request('$org', '$r3', NULL, NULL, '$v3') ->> 'alreadyApplied';" > "$work/3b" 2>&1 \
  || fail "second Approve & Order failed: $(cat "$work/3b")"
wait
[ "$(tail -1 "$work/3b")" = "true" ] || fail "3: second call was not alreadyApplied: $(cat "$work/3b")"
[ "$(q "SELECT count(*) FROM public.supply_request_updates WHERE supply_request_id = '$r3'")" = "3" ] || fail "3: rows"
[ "$(events "$r3")" = "request_approved,request_submitted" ] || fail "3: events $(events "$r3")"
[ "$(q "SELECT count(*) FROM public.supply_request_commitments WHERE supply_request_id = '$r3'")" = "1" ] || fail "3: commitments"
echo "ok - two Approve & Order calls at once: one applies, the other is alreadyApplied"

# 4. Two Receive & Complete calls at once (on request 3).
# Phase 7C: the receipt names a destination (Unassigned).
session "$admin" "BEGIN; SELECT public.receive_and_complete_supply_request('$org', '$r3', 'In the cage', NULL, (SELECT id FROM public.list_receiving_destinations('$org') WHERE kind = 'unassigned')); SELECT pg_sleep(3); COMMIT;" > "$work/4a" 2>&1 &
sleep 1
session "$owner" "SELECT public.receive_and_complete_supply_request('$org', '$r3', NULL, NULL) ->> 'alreadyApplied';" > "$work/4b" 2>&1 \
  || fail "second Receive & Complete failed: $(cat "$work/4b")"
wait
[ "$(tail -1 "$work/4b")" = "true" ] || fail "4: second call was not alreadyApplied: $(cat "$work/4b")"
[ "$(trail "$r3")" = "under_review:approve_and_order approved:approve_and_order ordered:approve_and_order received:receive_and_complete completed:receive_and_complete" ] \
  || fail "4: history $(trail "$r3")"
[ "$(events "$r3")" = "request_approved,request_submitted" ] || fail "4: events $(events "$r3")"
[ "$(q "SELECT received_at IS NOT NULL FROM public.supply_requests WHERE id = '$r3'")" = "t" ] || fail "4: received_at"
echo "ok - two Receive & Complete calls at once: one applies, the other is alreadyApplied; no event"

# 5. Separate transactions: only bundle rows are marked; committed digest is canonical.
r5=$(submit "Race reviewed earlier")
session "$admin" "SELECT public.transition_supply_request('$org', '$r5', 'under_review');" >/dev/null
sleep 1
session "$admin" "SELECT public.approve_and_order_supply_request('$org', '$r5', NULL, NULL, '$(version "$r5")');" >/dev/null
[ "$(trail "$r5")" = "under_review:- approved:approve_and_order ordered:approve_and_order" ] || fail "5: history $(trail "$r5")"
[ "$(q "SELECT count(DISTINCT created_at) FROM public.supply_request_updates WHERE supply_request_id = '$r5' AND compound_action IS NOT NULL")" = "1" ] \
  || fail "5: bundle rows do not share one timestamp"
[ "$(q "SELECT count(DISTINCT created_at) FROM public.supply_request_updates WHERE supply_request_id = '$r5'")" = "2" ] \
  || fail "5: the earlier under_review row should keep its own timestamp"
session "$owner" "SELECT public.update_organization_request_workflow_settings('$org', 'detailed');" >/dev/null
r6=$(submit "Race genuinely approved")
session "$admin" "SELECT public.decide_supply_request('$org', '$r6', 'approved', NULL, NULL, '$(version "$r6")');" >/dev/null
session "$owner" "SELECT public.update_organization_request_workflow_settings('$org', 'lean');" >/dev/null
[ "$(q "SELECT status FROM public.supply_requests WHERE id = '$r6'")" = "approved" ] || fail "5: profile change moved a request"
listed=$(q "SELECT coalesce(string_agg(item ->> 'requestId', ','), '') FROM jsonb_array_elements(public.notification_approver_digest_content('$org', now(), 7) -> 'sections' -> 'approvedNotOrdered' -> 'items') item")
[ "$listed" = "$r6" ] || fail "5: approved-not-ordered should list only $r6, got '$listed'"
echo "ok - bundle rows marked and simultaneous; earlier rows untouched; digest lists only the genuinely approved request"

echo "phase 7C.0 race check passed"
