#!/usr/bin/env bash
# Phase 7B.1 mutation check. Proves phase7b1_inventory_admin_workspace_behavior.sql fails when
# a critical rule in the 7B.1 migration is removed. Disposable databases only: never point
# this at production.
#
# Usage:
#   supabase/tests/phase7b1_mutation_check.sh <database>
#
# <database> must have every migration applied, through
# 20261028120000_phase7b1_inventory_admin_workspace.sql. Each mutant re-creates the 7B.1
# functions (with one rule broken), or prepends one schema change, inside one transaction,
# runs the suite there, and rolls everything back.
#
# Equivalent changes, deliberately not listed: dropping replace_inventory_location_labels'
# own owner, Unassigned or archived checks (issue_inventory_location_label, which it calls in
# the same transaction, refuses the same callers and locations), and dropping the
# auth.uid() IS NULL test from a read (is_org_admin(org, NULL) is false).
set -euo pipefail

database="${1:?usage: $0 <database>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
migration="$root/supabase/migrations/20261028120000_phase7b1_inventory_admin_workspace.sql"
suite="$root/supabase/tests/phase7b1_inventory_admin_workspace_behavior.sql"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# name | exact text in the migration | replacement [| more text | replacement ...]
# name | PREPEND | SQL run before the suite (schema mutants)
mutants=(
  "reads allow every member, staff included|public.is_org_admin(_organization_id, auth.uid())|public.is_org_member(_organization_id, auth.uid())"
  "location lookups ignore the organization|WHERE id = _inventory_location_id AND organization_id = _organization_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Inventory location not found'|WHERE id = _inventory_location_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Inventory location not found'"
  "items ignore the organization|    WHERE item.organization_id = _organization_id
      AND (_status|    WHERE true
      AND (_status"
  "item balances ignore the organization|  WHERE id = _inventory_item_id AND organization_id = _organization_id;|  WHERE id = _inventory_item_id;"
  "countable count ignores the 7A.2 rule|      (SELECT count(*)::integer FROM public.inventory_countable_balances(_organization_id, page.id)) END,|      (SELECT count(*)::integer FROM public.inventory_location_balances b WHERE b.inventory_location_id = page.id) END,"
  "stocked count includes empty balances|       AND balance.quantity > 0),
    CASE WHEN page.kind = 'storage' THEN|       ),
    CASE WHEN page.kind = 'storage' THEN"
  "Unassigned stock lists zero rows|             ELSE balance.quantity > 0 END|             ELSE true END"
  "storage stock ignores the countable rule|             THEN item.active OR balance.quantity > 0|             THEN true"
  "Unassigned gets a countable count|    CASE WHEN page.kind = 'storage' THEN
      (SELECT count(*)::integer FROM public.inventory_countable_balances|    CASE WHEN true THEN
      (SELECT count(*)::integer FROM public.inventory_countable_balances"
  "archived locations listed as active|      AND (_status = 'all' OR (_status = 'active') = location.active)|      AND true"
  "keyset cursor skips a row|            lower(location.name), location.id) > (_after_sort_group, _after_name, _after_id))|            lower(location.name), location.id) > (_after_sort_group, _after_name, _after_id)
           AND random() >= 0 AND location.name <> 'Empty Room')"
  "status rule drops critical|    WHEN _quantity <= _par_level * 0.5 THEN 'critical'|    WHEN _quantity <= _par_level * 0.5 THEN 'low'"
  "low-stock filter includes healthy items|IN ('low', 'critical'))|IN ('low', 'critical', 'healthy'))"
  "search becomes a pattern|           OR position(_needle IN lower(item.name)) > 0|           OR lower(item.name) LIKE concat('%', _needle, '%')"
  "last counter is not resolved|    CASE WHEN last_session.counted_by IS NOT NULL THEN coalesce(identities.display_name, 'Former member') END,|    NULL::text,"
  "replace revokes nothing|  WHERE organization_id = _organization_id AND inventory_location_id = _location.id
    AND revoked_at IS NULL;
  GET DIAGNOSTICS _revoked = ROW_COUNT;|  WHERE false;
  GET DIAGNOSTICS _revoked = ROW_COUNT;"
  "replace swallows an issuing failure|  _issued := public.issue_inventory_location_label(_organization_id, _location.id);|  BEGIN
    _issued := public.issue_inventory_location_label(_organization_id, _location.id);
  EXCEPTION WHEN OTHERS THEN
    _issued := jsonb_build_object('token', NULL);
  END;"
  "anon may call a read|PREPEND|GRANT EXECUTE ON FUNCTION public.list_inventory_workspace_items(uuid, text, text, text, text, integer, text, uuid) TO anon;"
  "admins read raw locations|PREPEND|CREATE POLICY phase7b1_mutant_admin_locations ON public.inventory_locations FOR SELECT TO authenticated USING (public.is_org_admin(organization_id, auth.uid()));"
)

# The migration's functions only (tables, triggers and data already exist in <database>).
python3 - "$migration" "$work/functions.sql" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
found = re.findall(r"(CREATE (?:OR REPLACE )?FUNCTION .*?\nAS (\$\$|\$function\$)\n.*?\n\2;)", text, re.S)
if len(found) != 7:
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
