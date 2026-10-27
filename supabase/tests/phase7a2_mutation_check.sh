#!/usr/bin/env bash
# Phase 7A.2 mutation check. Proves phase7a2_inventory_physical_counts_behavior.sql fails when
# a critical rule in the 7A.2 migrations is removed. Disposable databases only: never point
# this at production.
#
# Usage:
#   supabase/tests/phase7a2_mutation_check.sh <database>
#
# <database> must have every migration applied, through
# 20261027120100_phase7a2_staff_inventory_read_hardening.sql. Each mutant re-creates the
# 7A.2 functions (with one rule broken), or prepends one schema change, inside one
# transaction, runs the suite there, and rolls everything back.
set -euo pipefail

database="${1:?usage: $0 <database>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
migration="$root/supabase/migrations/20261027120000_phase7a2_inventory_physical_counts.sql"
suite="$root/supabase/tests/phase7a2_inventory_physical_counts_behavior.sql"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

owner_check="IF auth.uid() IS NULL OR NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required' USING ERRCODE = '42501';
  END IF;"
member_check="IF auth.uid() IS NULL OR NOT public.is_org_member(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: organization membership required' USING ERRCODE = '42501';
  END IF;"

# name | exact text in the migration | replacement [| more text | replacement ...]
# name | PREPEND | SQL run before the suite (schema mutants)
mutants=(
  "count skips the membership check|  $member_check
  IF _key = ''|  IF _key = ''"
  "stale versions accepted|AND _versions[i] = countable.version))|))"
  "incomplete item sets accepted|  IF _countable_count <> cardinality(_item_ids) OR _matched <> _countable_count THEN|  IF _matched <> cardinality(_item_ids) THEN"
  "active zero-balance items not countable|    AND (item.active OR balance.quantity > 0);|    AND balance.quantity > 0;"
  "archived stocked items not countable|    AND (item.active OR balance.quantity > 0);|    AND item.active;"
  "zero deltas skip the balance primitive|    _result := public.inventory_apply_balance_delta(
      _organization_id, _item_ids[_i], _location.id, _quantities[_i] - _previous);|    IF _quantities[_i] <> _previous THEN
      _result := public.inventory_apply_balance_delta(
        _organization_id, _item_ids[_i], _location.id, _quantities[_i] - _previous);
    ELSE
      _result := (SELECT jsonb_build_object('itemPreviousQuantity', quantity, 'itemQuantity', quantity)
                  FROM public.inventory_items WHERE id = _item_ids[_i]);
    END IF;"
  "zero deltas write no checkpoint|    INSERT INTO public.inventory_adjustments
      (organization_id, inventory_item_id, inventory_location_id, adjustment_amount, previous_quantity,|    INSERT INTO public.inventory_adjustments
      (organization_id, inventory_item_id, inventory_location_id, adjustment_amount, previous_quantity,|       auth.uid(), _submitted_at, 'physical_count', _line_id);|       auth.uid(), _submitted_at, 'physical_count', _line_id)
      ON CONFLICT DO NOTHING;
    DELETE FROM public.inventory_adjustments WHERE inventory_count_line_id = _line_id AND adjustment_amount = 0;"
  "idempotency ignores the request hash|AND _existing.request_hash = _request_hash THEN| THEN"
  # Not a mutant: dropping the replay's location comparison is equivalent, because the
  # request hash already includes the location.
  "request hash is not canonical|trim_scale(_quantity);|_quantity;"
  "count accepts Unassigned|  FOR UPDATE;
  IF NOT FOUND OR _location.kind <> 'storage' OR NOT _location.active THEN|  FOR UPDATE;
  IF NOT FOUND OR NOT _location.active THEN"
  "label resolution skips membership|  IF NOT FOUND OR NOT public.is_org_member(_label.organization_id, auth.uid()) THEN|  IF NOT FOUND THEN"
  "revoked labels still resolve|  IF _label.revoked_at IS NOT NULL THEN|  IF false THEN"
  "archived locations still resolve|  IF NOT FOUND OR _location.kind <> 'storage' OR NOT _location.active THEN
    RETURN jsonb_build_object('status', 'location_unavailable');|  IF NOT FOUND OR _location.kind <> 'storage' THEN
    RETURN jsonb_build_object('status', 'location_unavailable');"
  "labels issued without the owner check|  $owner_check
  SELECT * INTO _location FROM public.inventory_locations
  WHERE id = _inventory_location_id AND organization_id = _organization_id
  FOR SHARE;|  SELECT * INTO _location FROM public.inventory_locations
  WHERE id = _inventory_location_id AND organization_id = _organization_id
  FOR SHARE;"
  "labels revoked without the owner check|  $owner_check
  IF NOT EXISTS (SELECT 1 FROM public.inventory_locations|  IF NOT EXISTS (SELECT 1 FROM public.inventory_locations"
  "labels issued for Unassigned|  IF _location.kind <> 'storage' THEN
    RAISE EXCEPTION 'Unassigned is not a physical location|  IF false THEN
    RAISE EXCEPTION 'Unassigned is not a physical location"
  "count page leaks prices|          'archived', NOT countable.item_active)|          'archived', NOT countable.item_active,
          'lastPurchasePrice', (SELECT last_purchase_price FROM public.inventory_items WHERE id = countable.inventory_item_id))"
  "count page skips the membership check|  $member_check
  SELECT * INTO _location FROM public.inventory_locations
  WHERE id = _inventory_location_id AND organization_id = _organization_id;
  IF NOT FOUND OR _location.kind <> 'storage' OR NOT _location.active THEN
    RAISE EXCEPTION 'This inventory location is not available for counting' USING ERRCODE = 'P0002';
  END IF;
  RETURN jsonb_build_object(|  SELECT * INTO _location FROM public.inventory_locations
  WHERE id = _inventory_location_id AND organization_id = _organization_id;
  IF NOT FOUND OR _location.kind <> 'storage' OR NOT _location.active THEN
    RAISE EXCEPTION 'This inventory location is not available for counting' USING ERRCODE = 'P0002';
  END IF;
  RETURN jsonb_build_object("
  "staff identities include archived items|    AND (item.active OR public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]))|    AND true"
  "staff identities skip the membership check|  $member_check
  IF cardinality(_inventory_item_ids) > 500 THEN|  IF cardinality(_inventory_item_ids) > 500 THEN"
  "physical_count rows need no count line|PREPEND|ALTER TABLE public.inventory_adjustments DROP CONSTRAINT inventory_adjustments_physical_count_check;"
  "count history is editable|PREPEND|DROP TRIGGER inventory_count_sessions_guard ON public.inventory_count_sessions; DROP TRIGGER inventory_count_lines_guard ON public.inventory_count_lines;"
  "labels are editable|PREPEND|DROP TRIGGER inventory_location_labels_guard ON public.inventory_location_labels;"
  "staff keep direct inventory reads|PREPEND|CREATE POLICY inventory_items_member_select ON public.inventory_items FOR SELECT TO authenticated USING (active = true AND public.is_org_member(organization_id, auth.uid()));"
)

# The migration's functions only (tables, triggers and data already exist in <database>).
python3 - "$migration" "$work/functions.sql" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
found = re.findall(r"(CREATE (?:OR REPLACE )?FUNCTION .*?\nAS (\$\$|\$function\$)\n.*?\n\2;)", text, re.S)
if len(found) < 13:
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
