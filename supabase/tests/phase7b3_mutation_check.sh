#!/usr/bin/env bash
# Phase 7B.3 mutation check. Proves phase7b3_inventory_activity_history_behavior.sql fails
# when a critical rule in the 7B.3 migration is removed. Disposable databases only: never
# point this at production.
#
# Usage:
#   supabase/tests/phase7b3_mutation_check.sh <database>
#
# <database> must have every migration applied, through
# 20261029140000_phase7b3_inventory_activity_history.sql. Each mutant re-creates the 7B.3
# functions (with one rule broken), or prepends one schema change, inside one transaction,
# runs the suite there, and rolls everything back.
#
# Equivalent changes, deliberately not listed: dropping the auth.uid() IS NULL test
# (is_org_admin(org, NULL) is false), the item/location joins' organization conditions (the
# tables' composite foreign keys already pin them to the row's organization), and dropping
# plan_cache_mode (a performance setting the suite asserts structurally, not behaviorally).
set -euo pipefail

database="${1:?usage: $0 <database>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
migration="$root/supabase/migrations/20261029140000_phase7b3_inventory_activity_history.sql"
suite="$root/supabase/tests/phase7b3_inventory_activity_history_behavior.sql"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# name | exact text in the migration | replacement [| more text | replacement ...]
# name | PREPEND | SQL run before the suite (schema mutants)
# Every occurrence of a target is replaced. No mutant uses SQL's string concatenation
# operator: specs split on the pipe character.
mutants=(
  "reads allow every member, staff included|public.is_org_admin(_organization_id, auth.uid())|public.is_org_member(_organization_id, auth.uid())"
  "reads allow owners only|IF auth.uid() IS NULL OR NOT public.is_org_admin(_organization_id, auth.uid()) THEN|IF auth.uid() IS NULL OR NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN"
  "transfers ignore the organization|       WHERE _inventory_location_id IS NULL
         AND transfer.organization_id = _organization_id|       WHERE _inventory_location_id IS NULL"
  "adjustments ignore the organization|    WHERE adjustment.organization_id = _organization_id
      -- Manual|    WHERE true
      -- Manual"
  "location filter ignores the from side|       WHERE transfer.from_inventory_location_id = _inventory_location_id|       WHERE false"
  "location filter ignores the to side|       WHERE transfer.to_inventory_location_id = _inventory_location_id|       WHERE false"
  "location filter ignored when set|       WHERE _inventory_location_id IS NULL
         AND transfer.organization_id|       WHERE true
         AND transfer.organization_id"
  "transfer item filter ignored|         AND (_inventory_item_id IS NULL OR transfer.inventory_item_id = _inventory_item_id)|         AND true"
  "transfer person filter ignored|         AND (_created_by IS NULL OR transfer.created_by = _created_by)|         AND true"
  "transfer date start becomes exclusive|transfer.created_at >= _created_from|transfer.created_at > _created_from"
  "transfer date end becomes inclusive|transfer.created_at < _created_before|transfer.created_at <= _created_before"
  "transfer keyset drops the id tiebreak|(transfer.created_at, transfer.id) < (_after_created_at, _after_id)|transfer.created_at < _after_created_at"
  "transfer merge breaks ties the wrong way|    ORDER BY candidate.created_at DESC, candidate.id DESC|    ORDER BY candidate.created_at DESC, candidate.id ASC"
  "transfer page returns one row too many|    ORDER BY candidate.created_at DESC, candidate.id DESC
    LIMIT _limit|    ORDER BY candidate.created_at DESC, candidate.id DESC
    LIMIT _limit + 1"
  "transfer names the wrong side|    page.to_inventory_location_id, to_location.name, page.created_by,|    page.to_inventory_location_id, from_location.name, page.created_by,"
  "transfer quantity rounded|    trim_scale(page.quantity), page.from_inventory_location_id|    round(page.quantity), page.from_inventory_location_id"
  "physical-count corrections appear in adjustments|      AND (adjustment.source_type = 'manual' OR (adjustment.source_type IS NULL AND adjustment.reason <> 'Invoice received'))|      AND adjustment.source_type IS DISTINCT FROM 'invoice'"
  "invoice receipts appear in adjustments|      AND (adjustment.source_type = 'manual' OR (adjustment.source_type IS NULL AND adjustment.reason <> 'Invoice received'))|      AND adjustment.source_type IS DISTINCT FROM 'physical_count'"
  "pre-provenance receipts appear|(adjustment.source_type IS NULL AND adjustment.reason <> 'Invoice received')|adjustment.source_type IS NULL"
  "pre-provenance manual rows hidden|      AND (adjustment.source_type = 'manual' OR (adjustment.source_type IS NULL AND adjustment.reason <> 'Invoice received'))|      AND adjustment.source_type = 'manual'"
  "manual Invoice received reason hidden|      AND (adjustment.source_type = 'manual' OR|      AND (adjustment.source_type = 'manual' AND adjustment.reason <> 'Invoice received' OR"
  "adjustment location filter ignored|      AND (_inventory_location_id IS NULL OR adjustment.inventory_location_id = _inventory_location_id)|      AND true"
  "adjustment item filter ignored|      AND (_inventory_item_id IS NULL OR adjustment.inventory_item_id = _inventory_item_id)|      AND true"
  "adjustment person filter ignored|      AND (_created_by IS NULL OR adjustment.created_by = _created_by)|      AND true"
  "adjustment reason filter ignored|      AND (_reason IS NULL OR adjustment.reason = _reason)|      AND true"
  "Physical count reason accepted|_reason NOT IN ('Manual adjustment', 'Damaged', 'Expired', 'Correction', 'Invoice received')|_reason NOT IN ('Manual adjustment', 'Damaged', 'Expired', 'Correction', 'Invoice received', 'Physical count')"
  "adjustment date filters ignored|      AND (_created_from IS NULL OR adjustment.created_at >= _created_from)
      AND (_created_before IS NULL OR adjustment.created_at < _created_before)|"
  "adjustment keyset drops the id tiebreak|(adjustment.created_at, adjustment.id) < (_after_created_at, _after_id)|adjustment.created_at < _after_created_at"
  "adjustment order breaks ties the wrong way|    ORDER BY adjustment.created_at DESC, adjustment.id DESC|    ORDER BY adjustment.created_at DESC, adjustment.id ASC"
  "location-less adjustments dropped|  LEFT JOIN public.inventory_locations location|  JOIN public.inventory_locations location"
  "adjustment before/after swapped|trim_scale(page.previous_quantity),
    trim_scale(page.adjustment_amount), trim_scale(page.new_quantity)|trim_scale(page.new_quantity),
    trim_scale(page.adjustment_amount), trim_scale(page.previous_quantity)"
  "adjustment amount loses its sign|    trim_scale(page.adjustment_amount), trim_scale(page.new_quantity)|    trim_scale(abs(page.adjustment_amount)), trim_scale(page.new_quantity)"
  "former members show their profile name|coalesce(identities.display_name, 'Former member')|coalesce(identities.display_name, (SELECT p.full_name FROM public.profiles p WHERE p.id = page.created_by), 'Former member')"
  "page size unbounded|  IF _limit IS NULL OR _limit < 1 OR _limit > 200 THEN|  IF _limit IS NULL OR _limit < 1 THEN"
  "anon may call transfer history|PREPEND|GRANT EXECUTE ON FUNCTION public.list_inventory_transfer_history(uuid, uuid, uuid, uuid, timestamptz, timestamptz, integer, timestamptz, uuid) TO anon;"
  "anon may call adjustment history|PREPEND|GRANT EXECUTE ON FUNCTION public.list_inventory_adjustment_history(uuid, uuid, uuid, uuid, text, timestamptz, timestamptz, integer, timestamptz, uuid) TO anon;"
  "admins read raw transfers|PREPEND|CREATE POLICY phase7b3_mutant_admin_transfers ON public.inventory_transfers FOR SELECT TO authenticated USING (public.is_org_admin(organization_id, auth.uid()));"
  "admins read raw adjustments|PREPEND|CREATE POLICY phase7b3_mutant_admin_adjustments ON public.inventory_adjustments FOR SELECT TO authenticated USING (public.is_org_admin(organization_id, auth.uid()));"
)

# The migration's functions only (tables, triggers and data already exist in <database>).
python3 - "$migration" "$work/functions.sql" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
found = re.findall(r"(CREATE (?:OR REPLACE )?FUNCTION .*?\nAS (\$\$|\$function\$)\n.*?\n\2;)", text, re.S)
if len(found) != 2:
    sys.exit(f"expected the migration's functions, found {len(found)}")
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
