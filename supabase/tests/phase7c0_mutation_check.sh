#!/usr/bin/env bash
# Phase 7C.0 mutation check. Proves phase7c0_request_workflow_profiles_behavior.sql fails when a
# critical rule in the 7C.0 migration is removed. Disposable databases only: never point this at
# production.
#
# Usage:
#   supabase/tests/phase7c0_mutation_check.sh <database>
#
# <database> must have every migration applied, through
# 20261112120000_phase7c0_request_workflow_profiles.sql. Each mutant re-creates the 7C.0 functions
# (with one rule broken), or prepends one schema change, inside one transaction, runs the suite
# there, and rolls everything back.
#
# Equivalent inside one transaction, deliberately not listed:
#   * dropping "AND created_at = now()" in mark_supply_request_compound_action: the lifecycle is
#     forward-only, so a status_to occurs once per request and the status filter alone already
#     selects only this call's rows (real-transaction marking is proven by phase7c0_race_check.sh);
#   * removing only the admin check in update_organization_request_workflow_settings: it returns
#     through the admin-only settings getter, so the call is still refused and rolled back (the
#     listed mutant removes both checks);
#   * the mark row-count assertion (an internal consistency guard that cannot fail while the
#     callers pass exactly the statuses they wrote).
# Phase 7C replaced apply_supply_request_receipt, receive_supply_request and
# receive_and_complete_supply_request (receiving destination). They are no longer re-created here;
# their mutants (profile gating, retries, notes, accepted states) live in phase7c_mutation_check.sh.
# Covered elsewhere: row-lock serialization of concurrent compound actions and decisions
# (supabase/tests/phase7c0_race_check.sh).
set -euo pipefail

database="${1:?usage: $0 <database>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
migration="$root/supabase/migrations/20261112120000_phase7c0_request_workflow_profiles.sql"
suites=("$root/supabase/tests/phase7c0_request_workflow_profiles_behavior.sql")
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# name | exact text in the migration | replacement [| more text | replacement ...]
# name | PREPEND | SQL run before the suite (schema mutants)
# Every occurrence of a target is replaced. No mutant uses SQL's string concatenation
# operator: specs split on the pipe character.
mutants=(
  "staff may change the workflow profile|    RAISE EXCEPTION 'Forbidden: administrator access required' USING ERRCODE = '42501';
  END IF;
  IF _workflow_profile IS NULL|    NULL;
  END IF;
  IF _workflow_profile IS NULL|    RAISE EXCEPTION 'Forbidden: administrator access required' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO _row FROM public.organization_request_workflow_settings|    NULL;
  END IF;
  SELECT * INTO _row FROM public.organization_request_workflow_settings"
  "staff may read Admin Settings|    RAISE EXCEPTION 'Forbidden: administrator access required' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO _row FROM public.organization_request_workflow_settings|    NULL;
  END IF;
  SELECT * INTO _row FROM public.organization_request_workflow_settings"
  "an unknown profile is accepted|  IF _workflow_profile IS NULL OR _workflow_profile NOT IN ('lean', 'standard', 'detailed') THEN|  IF false THEN"
  "no row defaults to lean|  ), 'detailed')|  ), 'lean')"
  "non-members read the profile|  IF _organization_id IS NULL OR NOT COALESCE(public.is_org_member(_organization_id, auth.uid()), false) THEN|  IF _organization_id IS NULL THEN"
  "Approve & Order ignores the profile|  IF public.organization_request_workflow_profile(_organization_id) <> 'lean' THEN|  IF false THEN"
  "Approve & Order enabled for Standard|  IF public.organization_request_workflow_profile(_organization_id) <> 'lean' THEN|  IF public.organization_request_workflow_profile(_organization_id) NOT IN ('lean', 'standard') THEN"
  "no stale-screen check|  IF _expected_updated_at IS NULL OR _request.updated_at IS DISTINCT FROM _expected_updated_at THEN|  IF false THEN"
  "Approve & Order retry writes again|  -- A retry after success (double tap, network retry) adds nothing.
  IF _request.status = 'ordered' THEN|  IF false THEN"
  "Approve & Order accepts a declined request|  IF _request.status NOT IN ('submitted', 'under_review', 'approved') THEN|  IF _request.status NOT IN ('submitted', 'under_review', 'approved', 'denied') THEN"
  "approval notes duplicated on the approved row|'approved', NULL, NULL, _request.updated_at|'approved', _staff_visible_note, _internal_note, _request.updated_at"
  "approval bypasses decide (no under_review row)|    PERFORM public.decide_supply_request(
      _organization_id, _request_id, 'approved', NULL, NULL, _request.updated_at
    );|    PERFORM public.apply_supply_request_transition(_organization_id, _request_id, 'approved');"
  "a one-step call is marked as a bundle|  IF cardinality(_written) > 1 THEN|  IF cardinality(_written) > 0 THEN"
  "bundles are never marked|  IF cardinality(_written) > 1 THEN|  IF false THEN"
  "staff history drops the marker|      u.event_kind, u.created_at, u.compound_action|      u.event_kind, u.created_at, NULL::text"
  "guard lets clients insert a marker|    IF (TG_OP = 'INSERT' AND NEW.compound_action IS NOT NULL)|    IF false"
  "guard lets clients change a marker|       OR (TG_OP = 'UPDATE' AND NEW.compound_action IS DISTINCT FROM OLD.compound_action) THEN|       THEN"
  "guard removed|PREPEND|DROP TRIGGER supply_request_updates_compound_action_guard ON public.supply_request_updates;"
  "marker check removed|PREPEND|ALTER TABLE public.supply_request_updates DROP CONSTRAINT supply_request_updates_compound_action_check;"
  "clients may read the settings table|PREPEND|GRANT SELECT ON public.organization_request_workflow_settings TO authenticated;"
  "clients may call the receipt helper|PREPEND|GRANT EXECUTE ON FUNCTION public.apply_supply_request_receipt(uuid, uuid, text, text) TO authenticated;"
  "anon may change the profile|PREPEND|GRANT EXECUTE ON FUNCTION public.update_organization_request_workflow_settings(uuid, text) TO anon;"
)

# The migration's functions only (tables, triggers and data already exist in <database>).
python3 - "$migration" "$work/functions.sql" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
found = re.findall(r"(CREATE (?:OR REPLACE )?FUNCTION .*?\nAS (\$\$|\$function\$)\n.*?\n\2;)", text, re.S)
if len(found) != 11:
    sys.exit(f"expected the migration's 11 functions, found {len(found)}")
# Phase 7C re-created the receive path with a receiving destination; those three functions are
# mutated by supabase/tests/phase7c_mutation_check.sh against their current bodies.
superseded = ("apply_supply_request_receipt", "receive_supply_request", "receive_and_complete_supply_request")
kept = [block for block, _ in found if not re.match(r"CREATE (?:OR REPLACE )?FUNCTION public\.(%s)\(" % "|".join(superseded), block)]
if len(kept) != 8:
    sys.exit(f"expected 8 functions after removing the Phase 7C receive path, found {len(kept)}")
open(sys.argv[2], "w").write("\n".join(kept))
PY

build() {  # <spec or empty> <target> <suite>
  python3 - "$work/functions.sql" "$3" "$2" "$1" <<'PY'
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
  killed=""
  for suite in "${suites[@]}"; do
    build "${entry#*|}" "$work/mutant.sql" "$suite"
    if ! psql -q -v ON_ERROR_STOP=1 -d "$database" -f "$work/mutant.sql" >/dev/null 2>"$work/err"; then
      killed="$(basename "$suite" .sql): $(grep -m1 -o 'ERROR: .*' "$work/err" | head -c 110)"
      break
    fi
  done
  if [ -z "$killed" ]; then
    echo "SURVIVED - $name"
    survived=$((survived + 1))
  else
    echo "KILLED - $name: $killed"
  fi
done

# Control: the unmutated functions pass both suites.
for suite in "${suites[@]}"; do
  build "" "$work/control.sql" "$suite"
  psql -q -v ON_ERROR_STOP=1 -d "$database" -f "$work/control.sql" >/dev/null || { echo "control run failed: $suite"; exit 1; }
done

if [ "$survived" -ne 0 ]; then
  echo "$survived mutant(s) survived"
  exit 1
fi
echo "all ${#mutants[@]} mutants killed; control passed"
