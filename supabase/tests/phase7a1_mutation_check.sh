#!/usr/bin/env bash
# Phase 7A.1 mutation check. Proves phase7a1_location_aware_inventory_behavior.sql fails when
# a critical rule in the migration is removed. Disposable databases only: never point this at
# production.
#
# Usage:
#   supabase/tests/phase7a1_mutation_check.sh <database>
#
# <database> must have every migration applied, including
# 20261021120000_phase7a1_location_aware_inventory.sql. Connection settings come from the
# standard PGHOST/PGPORT/PGUSER environment variables. Each mutant re-creates the migration's
# functions (with one rule broken) inside one transaction, runs the suite there, and rolls
# everything back.
set -euo pipefail

database="${1:?usage: $0 <database>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
migration="$root/supabase/migrations/20261021120000_phase7a1_location_aware_inventory.sql"
suite="$root/supabase/tests/phase7a1_location_aware_inventory_behavior.sql"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

owner_check="IF auth.uid() IS NULL OR NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN"

# name | exact text in the migration | replacement [| more text | replacement ...]
mutants=(
  "primitive allows negative balances|IF _balance.quantity + _delta < 0 THEN|IF false THEN"
  "primitive skips the organization summary|  UPDATE public.inventory_items SET quantity = quantity + _delta
  WHERE id = _inventory_item_id
  RETURNING * INTO _item;|  SELECT * INTO _item FROM public.inventory_items WHERE id = _inventory_item_id;"
  "direct quantity writes allowed|  IF current_setting('medspend.inventory_sync', true) IS DISTINCT FROM 'on' THEN
    IF TG_OP = 'UPDATE' AND NEW.quantity|  IF false THEN
    IF TG_OP = 'UPDATE' AND NEW.quantity"
  "invariant never fires|  IF _quantity <> _balance THEN|  IF false THEN"
  "Unassigned can be renamed|  IF OLD.kind = 'unassigned' AND (NEW.name IS DISTINCT FROM OLD.name|  IF false AND (NEW.name IS DISTINCT FROM OLD.name"
  "stocked locations can be archived|  IF OLD.active AND NOT NEW.active AND EXISTS (|  IF false AND EXISTS ("
  "receipts land in a storage location|      _organization_id, _inventory.id, NULL, _line.quantity, 'Invoice received', 'invoice',|      _organization_id, _inventory.id, (SELECT id FROM public.inventory_locations WHERE organization_id = _organization_id AND kind = 'storage' AND active ORDER BY name LIMIT 1), _line.quantity, 'Invoice received', 'invoice',"
  "compatibility adjustment skips the owner check|  IF NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;
  IF _reason NOT IN ('Invoice received'|  IF _reason NOT IN ('Invoice received'"
  "location adjustment ignores the chosen location|    _organization_id, _inventory_item_id, _inventory_location_id, _adjustment_amount, _reason, 'manual');|    _organization_id, _inventory_item_id, NULL, _adjustment_amount, _reason, 'manual');"
  "legacy receive skips the owner check|  $owner_check
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;
  IF _quantity IS NULL|  IF _quantity IS NULL"
  "moves skip the owner check|  $owner_check
    RAISE EXCEPTION 'Forbidden: owner access required' USING ERRCODE = '42501';
  END IF;
  IF _key = ''|  IF _key = ''"
  "moves ignore idempotency|  IF FOUND THEN
    IF _existing.inventory_item_id|  IF false THEN
    IF _existing.inventory_item_id"
  "moves accept archived destinations|  IF NOT _to.active THEN|  IF false THEN|  IF _delta > 0 AND NOT _location.active THEN|  IF false THEN"
  "deletion pulls past an empty Unassigned|      IF _unassigned_quantity < _receipt_quantity THEN|      IF false THEN"
  "deletion ignores physical-count checkpoints|          AND counted.source_type = 'physical_count'|          AND false"
)

# The migration's functions only (tables, triggers and data already exist in <database>).
python3 - "$migration" "$work/functions.sql" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
found = re.findall(r"(CREATE (?:OR REPLACE )?FUNCTION .*?\nAS (\$\$|\$function\$)\n.*?\n\2;)", text, re.S)
if len(found) < 15:
    sys.exit(f"expected the migration's functions, found {len(found)}")
open(sys.argv[2], "w").write("\n".join(block for block, _ in found))
PY

survived=0
for entry in "${mutants[@]}"; do
  name="${entry%%|*}"
  python3 - "$work/functions.sql" "$suite" "$work/mutant.sql" "${entry#*|}" <<'PY'
import sys
functions, suite, target, spec = sys.argv[1:5]
parts = spec.split("|")
if len(parts) % 2:
    sys.exit(f"mutation needs text|replacement pairs: {spec!r}")
text = open(functions).read()
for needle, replacement in zip(parts[::2], parts[1::2]):
    if needle not in text:
        sys.exit(f"mutation target not found: {needle!r}")
    text = text.replace(needle, replacement)
text = text.replace("CREATE FUNCTION", "CREATE OR REPLACE FUNCTION")
body = open(suite).read().replace("BEGIN;\n", "", 1).replace("\nROLLBACK;\n", "\n")
open(target, "w").write("BEGIN;\n" + text + "\n" + body + "\nROLLBACK;\n")
PY
  if psql -q -v ON_ERROR_STOP=1 -d "$database" -f "$work/mutant.sql" >/dev/null 2>"$work/err"; then
    echo "SURVIVED - $name"
    survived=$((survived + 1))
  else
    echo "KILLED - $name: $(grep -m1 -o 'ERROR: .*' "$work/err" | head -c 120)"
  fi
done

# Control: the unmutated functions pass.
python3 - "$work/functions.sql" "$suite" "$work/control.sql" <<'PY'
import sys
functions, suite, target = sys.argv[1:4]
text = open(functions).read().replace("CREATE FUNCTION", "CREATE OR REPLACE FUNCTION")
body = open(suite).read().replace("BEGIN;\n", "", 1).replace("\nROLLBACK;\n", "\n")
open(target, "w").write("BEGIN;\n" + text + "\n" + body + "\nROLLBACK;\n")
PY
psql -q -v ON_ERROR_STOP=1 -d "$database" -f "$work/control.sql" >/dev/null || { echo "control run failed"; exit 1; }

if [ "$survived" -ne 0 ]; then
  echo "$survived mutant(s) survived"
  exit 1
fi
echo "all ${#mutants[@]} mutants killed; control passed"
