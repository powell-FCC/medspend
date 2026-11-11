#!/usr/bin/env bash
# Phase 6C.3 race check: two real database sessions at once (a rollback-only suite runs in one
# transaction and cannot show this). Boots its own disposable Postgres with every migration and
# the integration fixture. Never reads .env files or talks to a hosted project.
#
#   1. claim: while worker A holds a claim transaction open, worker B claims at the same time;
#      B is not blocked (SKIP LOCKED) and gets a disjoint set; no delivery is leased twice.
#   2. dispatch: two dispatchers at once create each delivery exactly once.
#   3. complete: two completions of the same claim at once: one records 'sent', the other
#      waits for the row lock and returns 'stale_claim'.
#   4. digest enqueue: two schedulers at the same instant create one digest event.
#
# Requires Docker and public.ecr.aws/supabase/postgres:17.6.1.167.
# Usage: supabase/tests/phase6c3_race_check.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
container="medspend_6c3_race_$$"
port="${MEDSPEND_6C3_RACE_PORT:-55925}"
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
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f supabase/tests/integration/phase6c3_notifications_fixture.sql >/dev/null
# Sending ON, digest daily 08:00 New York; 10 submissions by staff (3 admin recipients each).
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<'SQL'
SELECT public.set_organization_notification_sending('6c3e0000-0000-4000-8000-000000000101', true);
SELECT set_config('request.jwt.claim.sub', '6c3e0000-0000-4000-8000-000000000003', false);
SELECT public.submit_supply_request('6c3e0000-0000-4000-8000-000000000101', 'reorder', NULL, NULL, NULL,
  jsonb_build_array(jsonb_build_object('freeTextItem', 'Race ' || n, 'quantity', 1))) FROM generate_series(1, 10) n;
SQL

# 2. Two dispatchers at once (A holds its transaction open).
psql -X -q -At -v ON_ERROR_STOP=1 -U postgres -d postgres > "$work/dispatch_a" <<'SQL' &
BEGIN;
SELECT public.dispatch_notification_events(5);
SELECT pg_sleep(3);
COMMIT;
SQL
sleep 1
start=$(date +%s)
q "SELECT public.dispatch_notification_events(100)" > "$work/dispatch_b"
elapsed=$(( $(date +%s) - start ))
wait
[ "$elapsed" -lt 2 ] || fail "the second dispatcher waited for the first (${elapsed}s)"
[ "$(head -1 "$work/dispatch_a")" = "5" ] && [ "$(cat "$work/dispatch_b")" = "5" ] || fail "dispatch split: A=$(head -1 "$work/dispatch_a") B=$(cat "$work/dispatch_b")"
[ "$(q "SELECT count(*), count(DISTINCT (event_id, recipient_user_id)) FROM public.notification_deliveries")" = "30|30" ] \
  || fail "deliveries after concurrent dispatch: $(q "SELECT count(*) FROM public.notification_deliveries")"
echo "ok - two dispatchers at once: 5 + 5 events, 30 deliveries, none twice, no waiting"

# 1. Two claimers at once.
psql -X -q -At -v ON_ERROR_STOP=1 -U postgres -d postgres > "$work/claim_a" <<'SQL' &
BEGIN;
SELECT delivery_id FROM public.claim_notification_deliveries(12, 300);
SELECT pg_sleep(3);
COMMIT;
SQL
sleep 1
start=$(date +%s)
q "SELECT delivery_id FROM public.claim_notification_deliveries(12, 300)" > "$work/claim_b"
elapsed=$(( $(date +%s) - start ))
wait
[ "$elapsed" -lt 2 ] || fail "the second claimer waited for the first (${elapsed}s)"
grep -E '^[0-9a-f-]{36}$' "$work/claim_a" | sort > "$work/a_ids"
sort "$work/claim_b" > "$work/b_ids"
[ "$(wc -l < "$work/a_ids" | tr -d ' ')" = "12" ] && [ "$(wc -l < "$work/b_ids" | tr -d ' ')" = "12" ] || fail "claims: A=$(wc -l < "$work/a_ids") B=$(wc -l < "$work/b_ids")"
[ -z "$(comm -12 "$work/a_ids" "$work/b_ids")" ] || fail "a delivery was claimed by both workers"
[ "$(q "SELECT count(*) FROM public.notification_deliveries WHERE status = 'processing' AND attempts = 1")" = "24" ] || fail "leases"
[ "$(q "SELECT count(*) FROM public.claim_notification_deliveries(100, 300)")" = "6" ] || fail "remaining claim"
echo "ok - two claimers at once: 12 + 12 disjoint deliveries, no waiting; the rest claimed once"

# 3. Two completions of the same claim at once.
row="$(q "SELECT id || ' ' || claim_token FROM public.notification_deliveries WHERE status = 'processing' ORDER BY id LIMIT 1")"
delivery="${row% *}"; token="${row#* }"
psql -X -q -At -v ON_ERROR_STOP=1 -U postgres -d postgres > "$work/complete_a" <<SQL &
BEGIN;
SELECT public.complete_notification_delivery('$delivery', '$token', 'sent', 'fake', 'race-a');
SELECT pg_sleep(2);
COMMIT;
SQL
sleep 1
q "SELECT public.complete_notification_delivery('$delivery', '$token', 'sent', 'fake', 'race-b')" > "$work/complete_b"
wait
[ "$(head -1 "$work/complete_a")" = "sent" ] && [ "$(cat "$work/complete_b")" = "stale_claim" ] \
  || fail "completions: A=$(head -1 "$work/complete_a") B=$(cat "$work/complete_b")"
[ "$(q "SELECT provider_message_id FROM public.notification_deliveries WHERE id = '$delivery'")" = "race-a" ] || fail "second completion overwrote the first"
echo "ok - two completions of one claim: one sent, the other stale_claim"

# 4. Two digest schedulers at the same instant.
q "UPDATE public.organization_notification_settings SET digest_enabled = true, digest_frequency = 'daily', digest_send_hour = 8, timezone = 'America/New_York'" >/dev/null
psql -X -q -At -v ON_ERROR_STOP=1 -U postgres -d postgres > "$work/digest_a" <<'SQL' &
BEGIN;
SELECT public.enqueue_due_notification_digests('2027-02-02 13:00:00+00');
SELECT pg_sleep(2);
COMMIT;
SQL
sleep 1
q "SELECT public.enqueue_due_notification_digests('2027-02-02 13:00:00+00')" > "$work/digest_b"
wait
[ "$(q "SELECT count(*) FROM public.notification_events WHERE event_type = 'approver_digest'")" = "1" ] \
  || fail "concurrent schedulers created $(q "SELECT count(*) FROM public.notification_events WHERE event_type = 'approver_digest'") digests"
[ "$(( $(head -1 "$work/digest_a") + $(cat "$work/digest_b") ))" = "1" ] || fail "enqueue results A=$(head -1 "$work/digest_a") B=$(cat "$work/digest_b")"
echo "ok - two digest schedulers at the same instant: one digest"
echo "phase6c3_race_check: all checks passed"
