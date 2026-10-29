#!/usr/bin/env bash
# Phase 7B.2 mutation check. Proves phase7b2_inventory_count_history_behavior.sql fails when
# a critical rule in the 7B.2 migration is removed. Disposable databases only: never point
# this at production.
#
# Usage:
#   supabase/tests/phase7b2_mutation_check.sh <database>
#
# <database> must have every migration applied, through
# 20261029120000_phase7b2_inventory_count_history.sql. Each mutant re-creates the 7B.2
# functions (with one rule broken), or prepends one schema change, inside one transaction,
# runs the suite there, and rolls everything back.
#
# Equivalent changes, deliberately not listed: dropping the auth.uid() IS NULL test
# (is_org_admin(org, NULL) is false) and the location join's organization condition (the
# session's composite foreign key already pins its location to the same organization).
set -euo pipefail

database="${1:?usage: $0 <database>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
migration="$root/supabase/migrations/20261029120000_phase7b2_inventory_count_history.sql"
suite="$root/supabase/tests/phase7b2_inventory_count_history_behavior.sql"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# name | exact text in the migration | replacement [| more text | replacement ...]
# name | PREPEND | SQL run before the suite (schema mutants)
# Every occurrence of a target is replaced. No mutant uses SQL's string concatenation
# operator: specs split on the pipe character.
mutants=(
  "reads allow every member, staff included|public.is_org_admin(_organization_id, auth.uid())|public.is_org_member(_organization_id, auth.uid())"
  "history ignores the organization|    WHERE session.organization_id = _organization_id
      AND (_inventory_location_id IS NULL|    WHERE true
      AND (_inventory_location_id IS NULL"
  "session lookup ignores the organization|  WHERE id = _count_session_id AND organization_id = _organization_id;|  WHERE id = _count_session_id;"
  "location filter ignored|      AND (_inventory_location_id IS NULL OR session.inventory_location_id = _inventory_location_id)|      AND true"
  "person filter ignored|      AND (_counted_by IS NULL OR session.counted_by = _counted_by)|      AND true"
  "changed-only filter ignored|      AND (NOT _changed_only OR session.changed_count > 0)|      AND true"
  "date range start becomes exclusive|session.submitted_at >= _submitted_from|session.submitted_at > _submitted_from"
  "date range end becomes inclusive|session.submitted_at < _submitted_before|session.submitted_at <= _submitted_before"
  "date filters ignored|      AND (_submitted_from IS NULL OR session.submitted_at >= _submitted_from)
      AND (_submitted_before IS NULL OR session.submitted_at < _submitted_before)|"
  "keyset cursor drops the id tiebreak|(session.submitted_at, session.id) < (_after_submitted_at, _after_id)|session.submitted_at < _after_submitted_at"
  "page order breaks ties the wrong way|    ORDER BY session.submitted_at DESC, session.id DESC
    LIMIT _limit|    ORDER BY session.submitted_at DESC, session.id ASC
    LIMIT _limit"
  "page returns one row too many|    LIMIT _limit
  ),|    LIMIT _limit + 1
  ),"
  "summary adds incompatible units together|        SELECT line.item_unit AS unit, count(*)::integer AS changed_lines,|        SELECT min(line.item_unit) AS unit, count(*)::integer AS changed_lines,|        GROUP BY line.item_unit|"
  "summary counts unchanged lines|          AND line.delta <> 0
        GROUP BY line.item_unit|        GROUP BY line.item_unit"
  "summary decrease loses its sign|0)) AS decrease|0)) * -1 AS decrease"
  "summary net is rounded|trim_scale(sum(line.delta)) AS net_delta|round(sum(line.delta)) AS net_delta"
  "former members show their profile name|coalesce(identities.display_name, 'Former member')|coalesce(identities.display_name, (SELECT p.full_name FROM public.profiles p WHERE p.id = page.counted_by), 'Former member')"
  "detail former member shows their profile name|                   WHERE identity.user_id = _session.counted_by), 'Former member')|                   WHERE identity.user_id = _session.counted_by),
                  (SELECT p.full_name FROM public.profiles p WHERE p.id = _session.counted_by), 'Former member')"
  "list reports the location as always active|location.name, location.active,|location.name, true,"
  "detail drops zero-delta lines|      WHERE line.count_session_id = _session.id AND line.organization_id = _organization_id), '[]'::jsonb)|      WHERE line.count_session_id = _session.id AND line.organization_id = _organization_id AND line.delta <> 0), '[]'::jsonb)"
  "detail uses the current item name|          'name', line.item_name,|          'name', item.name,"
  "detail uses the current SKU|          'sku', line.item_sku,|          'sku', item.sku,"
  "detail uses the current unit|          'unit', line.item_unit,|          'unit', item.unit,"
  "detail does not put changed lines first|ORDER BY (line.delta = 0), lower(line.item_name)|ORDER BY lower(line.item_name)"
  "detail never shows archived now|'itemArchivedNow', NOT item.active|'itemArchivedNow', false"
  "detail rounds fractional quantities|'delta', trim_scale(line.delta),|'delta', round(line.delta),"
  "detail reports the location as always active|    'locationActive', _location.active,|    'locationActive', true,"
  "anon may call the history|PREPEND|GRANT EXECUTE ON FUNCTION public.list_inventory_count_history(uuid, uuid, uuid, boolean, timestamptz, timestamptz, integer, timestamptz, uuid) TO anon;"
  "admins read raw count sessions|PREPEND|CREATE POLICY phase7b2_mutant_admin_sessions ON public.inventory_count_sessions FOR SELECT TO authenticated USING (public.is_org_admin(organization_id, auth.uid()));"
  "admins read raw count lines|PREPEND|CREATE POLICY phase7b2_mutant_admin_lines ON public.inventory_count_lines FOR SELECT TO authenticated USING (public.is_org_admin(organization_id, auth.uid()));"
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
