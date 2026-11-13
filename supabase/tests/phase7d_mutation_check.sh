#!/usr/bin/env bash
# Phase 7D mutation check. Proves phase7d_inventory_replenishment_behavior.sql fails when a
# critical rule in the 7D migration is removed. Disposable databases only: never point this at
# production.
#
# Usage:
#   supabase/tests/phase7d_mutation_check.sh <database>
#
# <database> must have every migration applied, through
# 20261113120000_phase7d_inventory_replenishment.sql. Each mutant re-creates the 7D functions
# (with one rule broken), or prepends one schema change, inside one transaction, runs the suite
# there, and rolls everything back.
#
# Equivalent, deliberately not listed:
#   * dropping "location.active" from the donor scan: a location cannot be archived while it holds
#     stock (7A.1 guard), so an archived location never has spare quantity;
#   * list_inventory_location_replenishment_rules's own role check: it reads through
#     list_inventory_replenishment, which refuses the same callers with the same message;
#   * the replay match ignoring _source: the replay branch has no source to compare against other
#     than the stored one, and the suite proves the stored source is kept.
# Covered elsewhere: concurrent creates and edits (supabase/tests/phase7d_race_check.sh).
set -euo pipefail

database="${1:?usage: $0 <database>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
migration="$root/supabase/migrations/20261113120000_phase7d_inventory_replenishment.sql"
suites=("$root/supabase/tests/phase7d_inventory_replenishment_behavior.sql")
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# name | exact text in the migration | replacement [| more text | replacement ...]
# name | PREPEND | SQL run before the suite (schema mutants)
# Every occurrence of a target is replaced. No mutant uses SQL's string concatenation
# operator: specs split on the pipe character.
mutants=(
  "admins may write rules|ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required' USING ERRCODE = '42501';
  END IF;
  IF _inventory_item_id IS NULL|ARRAY['owner', 'admin']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required' USING ERRCODE = '42501';
  END IF;
  IF _inventory_item_id IS NULL"
  "admins may disable rules|ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required' USING ERRCODE = '42501';
  END IF;
  IF _rule_id IS NULL|ARRAY['owner', 'admin']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required' USING ERRCODE = '42501';
  END IF;
  IF _rule_id IS NULL"
  "admins may move stock|ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required' USING ERRCODE = '42501';
  END IF;
  IF _source IS NULL|ARRAY['owner', 'admin']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required' USING ERRCODE = '42501';
  END IF;
  IF _source IS NULL"
  "staff may list replenishment|NOT public.is_org_admin(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;
  IF _view IS NULL|NOT public.is_org_member(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;
  IF _view IS NULL"
  "staff may read the summary|NOT public.is_org_admin(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;

  WITH calc AS|NOT public.is_org_member(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;

  WITH calc AS"
  "Unassigned accepted by the rule function|  IF _location.kind <> 'storage' THEN|  IF false THEN"
  "guard lets Unassigned in|  IF TG_OP = 'INSERT' AND NOT EXISTS (|  IF false AND NOT EXISTS ("
  "rule identity mutable|  IF TG_OP = 'UPDATE' AND (NEW.id IS DISTINCT FROM OLD.id|  IF false AND (NEW.id IS DISTINCT FROM OLD.id"
  "archived item accepted|  IF NOT _item.active THEN
    RAISE EXCEPTION '% is archived; it cannot have|  IF false THEN
    RAISE EXCEPTION '% is archived; it cannot have"
  "archived location accepted|  IF NOT _location.active THEN
    RAISE EXCEPTION '% is archived; it cannot have|  IF false THEN
    RAISE EXCEPTION '% is archived; it cannot have"
  "re-enable skips eligibility|  IF _enabled THEN
    SELECT * INTO _item|  IF false THEN
    SELECT * INTO _item"
  "duplicate create overwrites|    ON CONFLICT (inventory_item_id, inventory_location_id) DO NOTHING|    ON CONFLICT (inventory_item_id, inventory_location_id) DO UPDATE SET minimum_quantity = EXCLUDED.minimum_quantity, target_quantity = EXCLUDED.target_quantity"
  "stale edits accepted|  IF _rule.updated_at IS DISTINCT FROM _expected_updated_at THEN|  IF false THEN"
  "edits do not move updated_at|    NEW.updated_at := greatest(clock_timestamp(), OLD.updated_at + interval '1 microsecond');|    NEW.updated_at := OLD.updated_at;"
  "Target below Minimum accepted|  IF _target_quantity < _minimum_quantity THEN|  IF false THEN"
  "exactly at Minimum is not below|calculated.current_quantity <= calculated.minimum_quantity|calculated.current_quantity < calculated.minimum_quantity"
  "shortage measured to Minimum|        THEN calculated.target_quantity - calculated.current_quantity ELSE 0 END AS shortage|        THEN calculated.minimum_quantity - calculated.current_quantity ELSE 0 END AS shortage"
  "donor taken below its Minimum|           ELSE greatest(0, balance.quantity - coalesce(minimum.minimum_quantity, 0)) END AS spare|           ELSE balance.quantity END AS spare"
  "Unassigned not a donor|      CASE WHEN location.kind = 'unassigned' THEN balance.quantity|      CASE WHEN location.kind = 'unassigned' THEN 0"
  "Unassigned not first|      ORDER BY (stock.kind = 'unassigned') DESC, stock.spare DESC|      ORDER BY stock.spare DESC"
  "ties not ordered by name|stock.spare DESC, lower(stock.name), stock.inventory_location_id|stock.spare DESC, lower(stock.name) DESC, stock.inventory_location_id"
  "more than three donors|              ORDER BY entry.ordinality LIMIT 3) listed|              ORDER BY entry.ordinality LIMIT 4) listed"
  "donor takes ignore earlier donors|            moved.move - coalesce(sum((listed.donor->>'spareQuantity')::numeric) OVER (|            moved.move - 0 * coalesce(sum((listed.donor->>'spareQuantity')::numeric) OVER ("
  "disabled rule's Minimum kept|      ON minimum.live AND minimum.inventory_item_id|      ON minimum.inventory_item_id"
  "own spare counted as available|      coalesce(totals.spare, 0) - coalesce(own.spare, 0) AS available,|      coalesce(totals.spare, 0) AS available,"
  "archived item stays live|      (rule.enabled AND item.active AND location.active AND location.kind = 'storage') AS live|      (rule.enabled AND location.active AND location.kind = 'storage') AS live"
  "disabled rule stays live|      (rule.enabled AND item.active AND location.active AND location.kind = 'storage') AS live|      (item.active AND location.active AND location.kind = 'storage') AS live"
  "a zero balance row reads as not stocked|    SELECT rules.*, balance.quantity IS NULL AS not_stocked_here,|    SELECT rules.*, coalesce(balance.quantity, 0) = 0 AS not_stocked_here,"
  "full cover reported as partly covered|      WHEN moved.move >= moved.shortage THEN|      WHEN moved.move > moved.shortage THEN"
  "short elsewhere counts itself|      THEN (count(*) FILTER (WHERE moved.live AND moved.shortage > 0) OVER (PARTITION BY moved.inventory_item_id))::integer - 1|      THEN (count(*) FILTER (WHERE moved.live AND moved.shortage > 0) OVER (PARTITION BY moved.inventory_item_id))::integer"
  "submitted requests counted as open|      AND request.status IN ('approved', 'ordered')|      AND request.status IN ('submitted', 'approved', 'ordered')"
  "free-text requests counted|    WHERE line.organization_id = _organization_id AND line.inventory_item_id = page.inventory_item_id|    WHERE line.organization_id = _organization_id AND (line.inventory_item_id = page.inventory_item_id OR line.free_text_item IS NOT NULL)"
  "last count from any location|     WHERE line.inventory_item_id = page.inventory_item_id AND line.inventory_location_id = page.inventory_location_id|     WHERE line.inventory_item_id = page.inventory_item_id"
  "location list not filtered|  FROM public.list_inventory_replenishment(_organization_id, 'all', _inventory_location_id, _limit,|  FROM public.list_inventory_replenishment(_organization_id, 'all', NULL, _limit,"
  "unknown move source accepted|  IF _source IS NULL OR _source NOT IN ('manual', 'replenishment') THEN|  IF false THEN"
  "move source not stored|  VALUES (_organization_id, _inventory_item_id, _from.id, _to.id, _quantity, _key, auth.uid(), _source)|  VALUES (_organization_id, _inventory_item_id, _from.id, _to.id, _quantity, _key, auth.uid(), 'manual')"
  "old callers marked replenishment|  _source text DEFAULT 'manual'|  _source text DEFAULT 'replenishment'"
  "clients may read the rules table|PREPEND|GRANT SELECT ON public.inventory_replenishment_rules TO authenticated;"
  "clients may call the calculation|PREPEND|GRANT EXECUTE ON FUNCTION public.inventory_replenishment_rows(uuid) TO authenticated;"
)

# The migration's functions only (tables, triggers and data already exist in <database>).
python3 - "$migration" "$work/functions.sql" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
found = re.findall(r"(CREATE (?:OR REPLACE )?FUNCTION .*?\nAS (\$\$|\$function\$)\n.*?\n\2;)", text, re.S)
if len(found) != 9:
    sys.exit(f"expected the migration's 9 functions, found {len(found)}")
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

# Control: the unmutated functions pass the suite.
for suite in "${suites[@]}"; do
  build "" "$work/control.sql" "$suite"
  psql -q -v ON_ERROR_STOP=1 -d "$database" -f "$work/control.sql" >/dev/null || { echo "control run failed: $suite"; exit 1; }
done

if [ "$survived" -ne 0 ]; then
  echo "$survived mutant(s) survived"
  exit 1
fi
echo "all ${#mutants[@]} mutants killed; control passed"
