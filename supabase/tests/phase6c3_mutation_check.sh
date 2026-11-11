#!/usr/bin/env bash
# Phase 6C.3 mutation check. Proves phase6c3_request_notifications_behavior.sql fails when a
# critical rule in the 6C.3 migration is removed. Disposable databases only: never point this
# at production.
#
# Usage:
#   supabase/tests/phase6c3_mutation_check.sh <database>
#
# <database> must have every migration applied, through
# 20261110120000_phase6c3_request_notifications.sql. Each mutant re-creates the 6C.3 functions
# (with one rule broken), or prepends one schema change, inside one transaction, runs the suite
# there, and rolls everything back.
#
# Equivalent changes, deliberately not listed:
#   * dropping "AND m.active" in dispatch (is_org_admin already requires an active membership);
#   * dropping the organization filter on the requester lookup in dispatch (request ids are
#     unique and events are only written for their own organization);
#   * removing the per-date EXISTS short-cut in enqueue (the unique dedupe_key still refuses
#     the second row).
# Not expressible here: granting clients SELECT on auth.users (postgres holds no grant option on
# it; the suite still asserts that clients are refused).
# Covered elsewhere: FOR UPDATE SKIP LOCKED (a single session cannot observe it) is proven by
# supabase/tests/phase6c3_race_check.sh and the concurrent-worker integration tests.
set -euo pipefail

database="${1:?usage: $0 <database>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
migration="$root/supabase/migrations/20261110120000_phase6c3_request_notifications.sql"
suite="$root/supabase/tests/phase6c3_request_notifications_behavior.sql"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# name | exact text in the migration | replacement [| more text | replacement ...]
# name | PREPEND | SQL run before the suite (schema mutants)
# Every occurrence of a target is replaced. No mutant uses SQL's string concatenation
# operator: specs split on the pipe character.
mutants=(
  "staff may read and edit settings|IF _organization_id IS NULL OR NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN|IF _organization_id IS NULL OR NOT COALESCE(public.is_org_member(_organization_id, auth.uid()), false) THEN"
  "an unknown time zone is accepted|     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name = _timezone) THEN|     THEN"
  "admin edits turn the master switch on|    digest_enabled = EXCLUDED.digest_enabled,|    sending_enabled = true, digest_enabled = EXCLUDED.digest_enabled,"
  "send hour applies only on the exact hour|    CONTINUE WHEN extract(hour FROM _local)::integer < _settings.digest_send_hour;|    CONTINUE WHEN extract(hour FROM _local)::integer <> _settings.digest_send_hour;"
  "digests are scheduled in UTC|    _local := _now AT TIME ZONE _settings.timezone;|    _local := _now AT TIME ZONE 'UTC';"
  "weekdays include the weekend|_settings.digest_frequency = 'weekdays' AND extract(isodow FROM _local)::integer > 5;|_settings.digest_frequency = 'weekdays' AND extract(isodow FROM _local)::integer > 7;"
  "weekly ignores the weekday|      AND extract(isodow FROM _local)::integer <> _settings.digest_weekday;|      AND false;"
  "weekly may send twice in a week|        AND e.context ->> 'frequency' = 'weekly' AND e.context ->> 'isoWeek' = _iso_week);|        AND false);"
  "digest preference off is ignored|    WHERE s.sending_enabled AND s.digest_enabled|    WHERE s.sending_enabled"
  "master switch ignored by the digest schedule|    WHERE s.sending_enabled AND s.digest_enabled|    WHERE s.digest_enabled"
  "an empty digest is queued for sending|       CASE WHEN (_content ->> 'totalCount')::integer > 0 THEN 'pending' ELSE 'suppressed' END,|       'pending',|       CASE WHEN (_content ->> 'totalCount')::integer > 0 THEN NULL ELSE _now END)|       NULL)"
  "master switch ignored at dispatch|    IF NOT COALESCE(_sending, false) THEN|    IF false THEN"
  "events older than a day are delivered|    IF _event.created_at < _now - interval '24 hours' THEN|    IF false THEN"
  "submission notices go to every member|        AND public.is_org_admin(_event.organization_id, m.user_id)|        AND true"
  "the submitting admin is notified of their own request|        AND m.user_id IS DISTINCT FROM _event.actor_id|        AND true"
  "an admin deciding their own request is emailed|      IF _requester IS NOT NULL AND _requester IS DISTINCT FROM _event.actor_id THEN|      IF _requester IS NOT NULL THEN"
  "outcomes are sent to the deciding admin|        VALUES (_event.organization_id, _event.id, 'email', _requester, 'requester')|        VALUES (_event.organization_id, _event.id, 'email', _event.actor_id, 'requester')"
  "master switch not rechecked at delivery|    IF NOT COALESCE(_settings.sending_enabled, false) THEN|    IF false THEN"
  "deactivated recipients are still emailed|                        AND m.active) THEN|                        ) THEN"
  "demoted admins are still emailed|          AND NOT COALESCE(public.is_org_admin(_delivery.organization_id, _delivery.recipient_user_id), false) THEN|          AND false THEN"
  "profiles.email used as the address|      SELECT nullif(btrim(u.email), '') INTO _email FROM auth.users u
      WHERE u.id = _delivery.recipient_user_id AND u.deleted_at IS NULL;|      SELECT nullif(btrim(u.email), '') INTO _email FROM public.profiles u
      WHERE u.id = _delivery.recipient_user_id;"
  "internal notes reach staff|              SELECT left(nullif(btrim(u.staff_visible_note), ''), 2000)|              SELECT left(concat(u.staff_visible_note, ' ', u.internal_note), 2000)"
  "an emptied digest is still sent|        IF ((_context -> 'digest') ->> 'totalCount')::integer = 0 THEN|        IF false THEN"
  "an unexpired lease is reclaimed|       OR (d.status = 'processing' AND d.claim_expires_at <= _now)|       OR (d.status = 'processing')"
  "a stale claim token is accepted|  IF NOT FOUND OR _delivery.status <> 'processing' OR _delivery.claim_token IS DISTINCT FROM _claim_token THEN|  IF NOT FOUND OR _delivery.status <> 'processing' THEN"
  "retries never dead-letter|  ELSIF _outcome = 'permanent_failure' OR _delivery.attempts >= 5 THEN|  ELSIF _outcome = 'permanent_failure' THEN"
  "a permanent rejection is retried|  ELSIF _outcome = 'permanent_failure' OR _delivery.attempts >= 5 THEN|  ELSIF _delivery.attempts >= 5 THEN"
  "no backoff after the first failure|          WHEN 1 THEN interval '1 minute'|          WHEN 1 THEN interval '0 minutes'"
  "an expired final lease retries again|    IF _delivery.status = 'processing' AND _delivery.attempts >= 5 THEN|    IF false THEN"
  "a sent delivery keeps its claim|    SET status = 'sent', sent_at = _now, finished_at = _now, claim_token = NULL, claim_expires_at = NULL,|    SET status = 'sent', sent_at = _now, finished_at = _now, claim_token = claim_token, claim_expires_at = NULL,"
  "the receipt threshold is ignored|             AND r.ordered_at <= _now - make_interval(days => _threshold_days) THEN 'orderedNotReceived'| THEN 'orderedNotReceived'"
  "received requests appear in the digest|        WHEN r.status = 'approved' THEN 'approvedNotOrdered'|        WHEN r.status IN ('approved', 'received') THEN 'approvedNotOrdered'|      AND r.status IN ('submitted', 'under_review', 'approved', 'ordered')|      AND r.status IN ('submitted', 'under_review', 'approved', 'ordered', 'received')"
  "the digest item list is not capped|        WHERE a.section = s.key AND a.position <= GREATEST(_item_limit, 0)|        WHERE a.section = s.key"
  "the submission trigger is missing|PREPEND|DROP TRIGGER supply_requests_submitted_notification ON public.supply_requests;"
  "every lifecycle change raises an event|PREPEND|DROP TRIGGER supply_request_updates_decision_notification ON public.supply_request_updates; CREATE TRIGGER supply_request_updates_decision_notification AFTER INSERT ON public.supply_request_updates FOR EACH ROW WHEN (NEW.status_to IS NOT NULL) EXECUTE FUNCTION public.capture_supply_request_decision_notification();"
  "requester edits raise an event|PREPEND|DROP TRIGGER supply_request_updates_decision_notification ON public.supply_request_updates; CREATE TRIGGER supply_request_updates_decision_notification AFTER INSERT ON public.supply_request_updates FOR EACH ROW WHEN (NEW.status_to IN ('approved', 'denied') OR NEW.event_kind = 'requester_edited') EXECUTE FUNCTION public.capture_supply_request_decision_notification();"
  "the event dedupe key is not unique|PREPEND|ALTER TABLE public.notification_events DROP CONSTRAINT notification_events_dedupe_key_key; CREATE INDEX phase6c3_mutant_dedupe ON public.notification_events (dedupe_key);"
  "anon may read settings|PREPEND|GRANT EXECUTE ON FUNCTION public.get_organization_notification_settings(uuid) TO anon;"
  "clients read deliveries directly|PREPEND|GRANT SELECT ON public.notification_deliveries TO authenticated;"
  "clients write events directly|PREPEND|GRANT INSERT ON public.notification_events TO authenticated;"
  "clients may claim deliveries|PREPEND|GRANT EXECUTE ON FUNCTION public.claim_notification_deliveries(integer, integer, timestamptz) TO authenticated;"
  "clients may mark deliveries|PREPEND|GRANT EXECUTE ON FUNCTION public.complete_notification_delivery(uuid, uuid, text, text, text, text, jsonb, timestamptz) TO authenticated;"
  "clients may flip the master switch|PREPEND|GRANT EXECUTE ON FUNCTION public.set_organization_notification_sending(uuid, boolean) TO authenticated;"
  "RLS off on deliveries|PREPEND|ALTER TABLE public.notification_deliveries DISABLE ROW LEVEL SECURITY;"
)

# The migration's functions only (tables, triggers and data already exist in <database>).
python3 - "$migration" "$work/functions.sql" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
found = re.findall(r"(CREATE (?:OR REPLACE )?FUNCTION .*?\nAS (\$\$|\$function\$)\n.*?\n\2;)", text, re.S)
if len(found) != 11:
    sys.exit(f"expected the migration's 11 functions, found {len(found)}")
open(sys.argv[2], "w").write("\n".join(block for block, _ in found))
PY

build() {  # <spec or empty> <target>
  python3 - "$work/functions.sql" "$suite" "$2" "$1" <<'PY'
import sys
functions, suite, target, spec = sys.argv[1:5]
text = open(functions).read()
prepend = ""
if spec:
    parts = spec.split("|")
    if parts[0] == "PREPEND":
        prepend = parts[1]
    else:
        if len(parts) % 2:
            sys.exit(f"mutation needs text|replacement pairs: {spec!r}")
        for needle, replacement in zip(parts[::2], parts[1::2]):
            if needle not in text:
                sys.exit(f"mutation target not found: {needle!r}")
            text = text.replace(needle, replacement)
text = text.replace("CREATE FUNCTION", "CREATE OR REPLACE FUNCTION")
body = open(suite).read().replace("BEGIN;\n", "", 1).replace("\nROLLBACK;\n", "\n")
open(target, "w").write("BEGIN;\n" + prepend + "\n" + text + "\n" + body + "\nROLLBACK;\n")
PY
}

survived=0
for entry in "${mutants[@]}"; do
  name="${entry%%|*}"
  build "${entry#*|}" "$work/mutant.sql"
  if psql -q -v ON_ERROR_STOP=1 -d "$database" -f "$work/mutant.sql" >/dev/null 2>"$work/err"; then
    echo "SURVIVED - $name"
    survived=$((survived + 1))
  else
    echo "KILLED - $name: $(grep -m1 -o 'ERROR: .*' "$work/err" | head -c 120)"
  fi
done

# Control: the unmutated functions pass.
build "" "$work/control.sql"
psql -q -v ON_ERROR_STOP=1 -d "$database" -f "$work/control.sql" >/dev/null || { echo "control run failed"; exit 1; }

if [ "$survived" -ne 0 ]; then
  echo "$survived mutant(s) survived"
  exit 1
fi
echo "all ${#mutants[@]} mutants killed; control passed"
