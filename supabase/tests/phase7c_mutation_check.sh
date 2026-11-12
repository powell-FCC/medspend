#!/usr/bin/env bash
# Phase 7C mutation check. Proves phase7c_receiving_destination_behavior.sql fails when a critical
# rule in the 7C migration is removed. Disposable databases only: never point this at production.
#
# Usage:
#   supabase/tests/phase7c_mutation_check.sh <database>
#
# <database> must have every migration applied, through
# 20261112140000_phase7c_receiving_destination.sql. Each mutant re-creates the 7C functions (with
# one rule broken), or prepends one schema change, inside one transaction, runs the suite there,
# and rolls everything back.
#
# Equivalent, deliberately not listed:
#   * the helper's own "no destination" refusal: both callers refuse a missing destination first,
#     and a NULL destination would also fail the same-organization lookup;
#   * the helper's "already has a receipt" refusal and the UNIQUE (supply_request_id) constraint:
#     callers return alreadyApplied for a received or completed request before reaching the helper,
#     so a second receipt is unreachable through them (the race check covers concurrent calls).
# Covered elsewhere: row-lock serialization of concurrent receipts (supabase/tests/phase7c_race_check.sh).
set -euo pipefail

database="${1:?usage: $0 <database>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
migration="$root/supabase/migrations/20261112140000_phase7c_receiving_destination.sql"
suites=("$root/supabase/tests/phase7c_receiving_destination_behavior.sql")
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# name | exact text in the migration | replacement [| more text | replacement ...]
# name | PREPEND | SQL run before the suite (schema mutants)
# Every occurrence of a target is replaced. No mutant uses SQL's string concatenation
# operator: specs split on the pipe character.
mutants=(
  "staff may list destinations|    RAISE EXCEPTION 'Forbidden: administrator access required' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT location.id|    NULL;
  END IF;
  RETURN QUERY
    SELECT location.id"
  "archived destinations listed|    WHERE location.organization_id = _organization_id AND location.active|    WHERE location.organization_id = _organization_id"
  "other organizations' destinations listed|    WHERE location.organization_id = _organization_id AND location.active|    WHERE location.active"
  "staff get the location id|      CASE WHEN _admin THEN receipt.inventory_location_id END,|      receipt.inventory_location_id,"
  "staff see other people's receipts|      AND (_admin OR request.requested_by = auth.uid())|      AND true"
  "cross-organization destination accepted|  WHERE id = _inventory_location_id AND organization_id = _organization_id
  FOR SHARE;|  WHERE id = _inventory_location_id
  FOR SHARE;"
  "archived destination accepted|  IF NOT _location.active THEN|  IF false THEN"
  "receipt linked to the wrong history row|    AND update_row.status_to = 'received';|    AND update_row.status_to = 'ordered';"
  "name snapshot not taken from the destination|    (_organization_id, _request_id, _location.id, _location.name, _location.kind, auth.uid(),|    (_organization_id, _request_id, _location.id, 'Destination', _location.kind, auth.uid(),"
  "actor not recorded|    (_organization_id, _request_id, _location.id, _location.name, _location.kind, auth.uid(),|    (_organization_id, _request_id, _location.id, _location.name, _location.kind, NULL,"
  "compound action not recorded|     (_result ->> 'receivedAt')::timestamptz, _update_id, _compound_action)|     (_result ->> 'receivedAt')::timestamptz, _update_id, NULL)"
  "Mark Received without a destination|  IF _inventory_location_id IS NULL THEN
    RAISE EXCEPTION 'Refresh SportSpend and choose a receiving destination to receive this request.'
      USING ERRCODE = '22023';
  END IF;
  RETURN public.apply_supply_request_receipt(|  RETURN public.apply_supply_request_receipt("
  "Receive & Complete without a destination|    IF _inventory_location_id IS NULL THEN
      RAISE EXCEPTION 'Refresh SportSpend and choose a receiving destination to receive this request.'
        USING ERRCODE = '22023';
    END IF;
    PERFORM public.apply_supply_request_receipt(|    PERFORM public.apply_supply_request_receipt("
  "Mark Received retry can change the destination|    IF _receipt.id IS NOT NULL AND _inventory_location_id IS NOT NULL
       AND _receipt.inventory_location_id IS DISTINCT FROM _inventory_location_id THEN
      RAISE|    IF false THEN
      RAISE"
  "Receive & Complete retry can change the destination|  IF _receipt.id IS NOT NULL AND _inventory_location_id IS NOT NULL
     AND _receipt.inventory_location_id IS DISTINCT FROM _inventory_location_id THEN
    RAISE|  IF false THEN
    RAISE"
  "Mark Received retry fails|  IF _request.status = 'received' THEN|  IF false THEN"
  "Receive & Complete retry writes again|  IF _request.status = 'completed' THEN|  IF false THEN"
  "Receive & Complete enabled for Detailed|NOT IN ('lean', 'standard') THEN|NOT IN ('lean', 'standard', 'detailed') THEN"
  "Receive & Complete disabled for Standard|NOT IN ('lean', 'standard') THEN|NOT IN ('lean') THEN"
  "Receive & Complete accepts an approved request|  IF _request.status NOT IN ('ordered', 'received') THEN|  IF _request.status NOT IN ('approved', 'ordered', 'received') THEN"
  "a destination is added to a legacy received request|  ELSIF _receipt.id IS NULL AND _inventory_location_id IS NOT NULL THEN|  ELSIF false THEN"
  "receipt notes duplicated on the received row|      _organization_id, _request_id, _inventory_location_id, NULL, NULL, 'receive_and_complete'|      _organization_id, _request_id, _inventory_location_id, _internal_note, _staff_visible_note, 'receive_and_complete'"
  "bundled receipt not marked|      _organization_id, _request_id, _inventory_location_id, NULL, NULL, 'receive_and_complete'|      _organization_id, _request_id, _inventory_location_id, NULL, NULL, NULL"
  "staff may receive|     OR NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Forbidden: administrator access required' USING ERRCODE = '42501';
  END IF;
  IF length(|     OR NOT COALESCE(public.is_org_member(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Forbidden: administrator access required' USING ERRCODE = '42501';
  END IF;
  IF length("
  "generic transition still receives|  IF _status = 'received' THEN|  IF false THEN"
  "generic transition refuses completion too|  IF _status = 'received' THEN|  IF _status IN ('received', 'completed') THEN"
  "receipts are mutable|PREPEND|DROP TRIGGER supply_request_receipts_immutable ON public.supply_request_receipts;"
  "clients may read receipts|PREPEND|GRANT SELECT ON public.supply_request_receipts TO authenticated;"
  "clients may call the receipt helper|PREPEND|GRANT EXECUTE ON FUNCTION public.apply_supply_request_receipt(uuid, uuid, uuid, text, text, text) TO authenticated;"
  "anon may list destinations|PREPEND|GRANT EXECUTE ON FUNCTION public.list_receiving_destinations(uuid) TO anon;"
)

# The migration's functions only (tables, triggers and data already exist in <database>).
python3 - "$migration" "$work/functions.sql" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
found = re.findall(r"(CREATE (?:OR REPLACE )?FUNCTION .*?\nAS (\$\$|\$function\$)\n.*?\n\2;)", text, re.S)
if len(found) != 7:
    sys.exit(f"expected the migration's 7 functions, found {len(found)}")
open(sys.argv[2], "w").write("\n".join(block for block, _ in found))
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
