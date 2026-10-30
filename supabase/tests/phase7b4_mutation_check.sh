#!/usr/bin/env bash
# Phase 7B.4 mutation check. Proves phase7b4_inventory_overview_behavior.sql fails when a
# critical rule in the 7B.4 migration is removed. Disposable databases only: never point this
# at production.
#
# Usage:
#   supabase/tests/phase7b4_mutation_check.sh <database>
#
# <database> must have every migration applied, through
# 20261030120000_phase7b4_inventory_overview.sql. Each mutant re-creates the 7B.4 function
# (with one rule broken), or prepends one schema change, inside one transaction, runs the
# suite there, and rolls everything back.
#
# Equivalent changes, deliberately not listed: dropping the auth.uid() IS NULL test
# (is_org_admin(org, NULL) is false); dropping the balances CTE's organization condition or its
# item join's (balances also join the organization-scoped locations, and composite foreign
# keys pin a balance's item and location to its organization); and removing the OFFSET 0
# fence (a plan-shape choice the suite cannot observe).
set -euo pipefail

database="${1:?usage: $0 <database>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
migration="$root/supabase/migrations/20261030120000_phase7b4_inventory_overview.sql"
suite="$root/supabase/tests/phase7b4_inventory_overview_behavior.sql"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# name | exact text in the migration | replacement [| more text | replacement ...]
# name | PREPEND | SQL run before the suite (schema mutants)
# Every occurrence of a target is replaced. No mutant uses SQL's string concatenation
# operator: specs split on the pipe character.
mutants=(
  "reads allow every member, staff included|public.is_org_admin(_organization_id, auth.uid())|public.is_org_member(_organization_id, auth.uid())"
  "reads allow owners only|IF auth.uid() IS NULL OR NOT public.is_org_admin(_organization_id, auth.uid()) THEN|IF auth.uid() IS NULL OR NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN"
  "locations ignore the organization|    FROM public.inventory_locations location
    WHERE location.organization_id = _organization_id|    FROM public.inventory_locations location
    WHERE true"
  "active items counted across organizations|                          WHERE item.organization_id = _organization_id AND item.active),|                          WHERE item.active),"
  "zero Unassigned balances listed|    WHERE balances.kind = 'unassigned' AND balances.quantity > 0|    WHERE balances.kind = 'unassigned'"
  "countability ignores the item rule|      AND (balances.item_active OR balances.quantity > 0)|      AND true"
  "countability counts archived locations|    WHERE balances.kind = 'storage' AND balances.location_active|    WHERE balances.kind = 'storage'"
  "never-counted locations ignore count history|      AND NOT EXISTS (SELECT 1 FROM public.inventory_count_sessions session|      AND NOT EXISTS (SELECT 1 FROM public.inventory_count_sessions session WHERE false AND"
  "never-counted items ignore count lines|                      WHERE line.inventory_item_id = counted.inventory_item_id OFFSET 0)|                      WHERE false OFFSET 0)"
  "never-counted items include Unassigned-only stock|    WHERE balances.kind = 'storage' AND balances.location_active
      AND (balances.item_active OR balances.quantity > 0)|    WHERE (balances.kind = 'unassigned' OR balances.location_active)
      AND (balances.item_active OR balances.quantity > 0)"
  "no-label list includes archived locations|    WHERE location.kind = 'storage' AND location.active
      AND NOT EXISTS (SELECT 1 FROM active_labels|    WHERE location.kind = 'storage'
      AND NOT EXISTS (SELECT 1 FROM active_labels"
  "no-label list includes Unassigned|    WHERE location.kind = 'storage' AND location.active
      AND NOT EXISTS (SELECT 1 FROM active_labels|    WHERE location.active
      AND NOT EXISTS (SELECT 1 FROM active_labels"
  "revoked labels count as active|    WHERE label.organization_id = _organization_id AND label.revoked_at IS NULL|    WHERE label.organization_id = _organization_id"
  "archived-with-label list includes active locations|    WHERE location.kind = 'storage' AND NOT location.active|    WHERE location.kind = 'storage'"
  "attention lists are not cut at the limit|                LIMIT _attention_limit) row)|                ) row)"
  "list totals count only the shown rows|        'total', (SELECT count(*) FROM no_active_label),|        'total', (SELECT least(count(*), _attention_limit) FROM no_active_label),"
  "attention limit unbounded|  IF _attention_limit IS NULL OR _attention_limit < 1 OR _attention_limit > 50 THEN|  IF _attention_limit IS NULL OR _attention_limit < 1 THEN"
  "recorded quantity counts only active items|      'recordedQuantity', (SELECT trim_scale(coalesce(sum(item.quantity), 0)) FROM public.inventory_items item
                           WHERE item.organization_id = _organization_id),|      'recordedQuantity', (SELECT trim_scale(coalesce(sum(item.quantity), 0)) FROM public.inventory_items item
                           WHERE item.organization_id = _organization_id AND item.active),"
  "archived storage locations counted as active|      'activeStorageLocationCount', (SELECT count(*) FROM locations WHERE locations.kind = 'storage' AND locations.active),|      'activeStorageLocationCount', (SELECT count(*) FROM locations WHERE locations.kind = 'storage'),"
  "anon may call the overview|PREPEND|GRANT EXECUTE ON FUNCTION public.get_inventory_overview(uuid, integer) TO anon;"
  "admins read raw balances|PREPEND|CREATE POLICY phase7b4_mutant_admin_balances ON public.inventory_location_balances FOR SELECT TO authenticated USING (public.is_org_admin(organization_id, auth.uid()));"
)

# The migration's functions only (tables, triggers and data already exist in <database>).
python3 - "$migration" "$work/functions.sql" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
found = re.findall(r"(CREATE (?:OR REPLACE )?FUNCTION .*?\nAS (\$\$|\$function\$)\n.*?\n\2;)", text, re.S)
if len(found) != 1:
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
