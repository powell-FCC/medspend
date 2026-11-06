#!/usr/bin/env bash
# Phase 7B.5 mutation check. Proves phase7b5_inventory_count_cadence_behavior.sql fails when a
# critical rule in the 7B.5 migration is removed. Disposable databases only: never point this
# at production.
#
# Usage:
#   supabase/tests/phase7b5_mutation_check.sh <database>
#
# <database> must have every migration applied, through
# 20261106120000_phase7b5_inventory_count_cadence.sql. Each mutant re-creates the 7B.5
# functions (with one rule broken), or prepends one schema change, inside one transaction,
# runs the suite there, and rolls everything back.
#
# Equivalent changes, deliberately not listed: dropping the auth.uid() IS NULL tests
# (is_org_admin / has_org_role with a NULL user are false) and the sessions' organization
# condition (a session's composite foreign key pins its location to its organization).
set -euo pipefail

database="${1:?usage: $0 <database>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
migration="$root/supabase/migrations/20261106120000_phase7b5_inventory_count_cadence.sql"
suite="$root/supabase/tests/phase7b5_inventory_count_cadence_behavior.sql"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# name | exact text in the migration | replacement [| more text | replacement ...]
# name | PREPEND | SQL run before the suite (schema mutants)
# Every occurrence of a target is replaced. No mutant uses SQL's string concatenation
# operator: specs split on the pipe character.
mutants=(
  "reads allow every member, staff included|public.is_org_admin(_organization_id, auth.uid())|public.is_org_member(_organization_id, auth.uid())"
  "admins may set the policy|public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[])|public.is_org_admin(_organization_id, auth.uid())"
  "policy read ignores the organization|  SELECT * INTO _policy FROM public.inventory_count_policies WHERE organization_id = _organization_id;|  SELECT * INTO _policy FROM public.inventory_count_policies LIMIT 1;"
  "freshness reads every organization's policy|    FROM public.inventory_count_policies p
    WHERE p.organization_id = _organization_id
  ),
  located AS|    FROM public.inventory_count_policies p
  ),
  located AS"
  "freshness reads every organization's locations|    WHERE location.organization_id = _organization_id AND location.kind = 'storage'|    WHERE location.kind = 'storage'"
  "Unassigned is scheduled|    WHERE location.organization_id = _organization_id AND location.kind = 'storage'|    WHERE location.organization_id = _organization_id"
  "oldest count decides|       ORDER BY session.submitted_at DESC LIMIT 1) AS last_counted_at|       ORDER BY session.submitted_at ASC LIMIT 1) AS last_counted_at"
  "archived locations are scheduled|      WHEN NOT scheduled.active THEN 'not_applicable'
|"
  "empty locations are scheduled|      WHEN scheduled.countable = 0 THEN 'nothing_to_count'
|"
  "cadence off infers a schedule|      WHEN NOT scheduled.enabled THEN 'counted'
|"
  "due starts one day late|      WHEN _as_of < scheduled.due_at THEN 'current'|      WHEN _as_of <= scheduled.due_at THEN 'current'"
  "due window never closes|      WHEN _as_of < scheduled.due_at + interval '1 day' THEN 'due'|      WHEN _as_of < scheduled.due_at + interval '100 years' THEN 'due'"
  "due window is a week|      WHEN _as_of < scheduled.due_at + interval '1 day' THEN 'due'|      WHEN _as_of < scheduled.due_at + interval '7 days' THEN 'due'"
  "interval counted in hours|make_interval(days => policy.interval_days)|make_interval(hours => policy.interval_days)"
  "zero days accepted|  IF _interval_days IS NOT NULL AND (_interval_days < 1 OR _interval_days > 365) THEN|  IF _interval_days IS NOT NULL AND (_interval_days < 0 OR _interval_days > 365) THEN"
  "366 days accepted|  IF _interval_days IS NOT NULL AND (_interval_days < 1 OR _interval_days > 365) THEN|  IF _interval_days IS NOT NULL AND (_interval_days < 1 OR _interval_days > 366) THEN"
  "on without an interval|  IF _enabled AND _interval_days IS NULL THEN|  IF false THEN"
  "null enabled coerced|  IF _enabled IS NULL THEN|  IF false THEN"
  "turning off forgets the interval|      interval_days = coalesce(EXCLUDED.interval_days, policy.interval_days),|      interval_days = EXCLUDED.interval_days,"
  "former member shows their profile name|      WHERE identity.user_id = _policy.updated_by), 'Former member') END);|      WHERE identity.user_id = _policy.updated_by), (SELECT p.full_name FROM public.profiles p WHERE p.id = _policy.updated_by), 'Former member') END);"
  "attention includes never counted|    SELECT * FROM freshness WHERE freshness.state IN ('due', 'overdue')|    SELECT * FROM freshness WHERE freshness.state IN ('due', 'overdue', 'never_counted')"
  "attention least overdue first|          ORDER BY row.next_due_at, lower(row.name), row.inventory_location_id)
        FROM (SELECT * FROM attention ORDER BY attention.next_due_at, lower(attention.name), attention.inventory_location_id|          ORDER BY row.next_due_at DESC, lower(row.name), row.inventory_location_id)
        FROM (SELECT * FROM attention ORDER BY attention.next_due_at DESC, lower(attention.name), attention.inventory_location_id"
  "attention total counts the page|      'total', (SELECT count(*) FROM attention),|      'total', LEAST((SELECT count(*) FROM attention), _limit),"
  "interval shown while off|                 'intervalDays', CASE WHEN policy.enabled THEN policy.interval_days END) FROM policy),|                 'intervalDays', policy.interval_days) FROM policy),"
  "next due ignores the state|                FROM freshness row WHERE row.state = 'current'|                FROM freshness row WHERE row.next_due_at IS NOT NULL"
  "other organization location accepted|    WHERE id = _inventory_location_id AND organization_id = _organization_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Inventory location not found'|    WHERE id = _inventory_location_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Inventory location not found'"
  "Unassigned gets a state|      WHEN _kind <> 'storage' THEN jsonb_build_object|      WHEN false THEN jsonb_build_object"
  "page size unbounded|  IF _limit IS NULL OR _limit < 1 OR _limit > 50 THEN|  IF _limit IS NULL OR _limit < 1 THEN"
  "anon may read freshness|PREPEND|GRANT EXECUTE ON FUNCTION public.get_inventory_count_freshness(uuid, uuid, integer) TO anon;"
  "clients may call the freshness helper|PREPEND|GRANT EXECUTE ON FUNCTION public.inventory_location_count_freshness(uuid, timestamptz) TO authenticated;"
  "clients read the policy table|PREPEND|GRANT SELECT ON public.inventory_count_policies TO authenticated;"
  "clients write the policy table|PREPEND|GRANT INSERT ON public.inventory_count_policies TO authenticated;"
  "no enabled-interval constraint|PREPEND|ALTER TABLE public.inventory_count_policies DROP CONSTRAINT inventory_count_policies_enabled_interval_check;"
  "interval range constraint dropped|PREPEND|ALTER TABLE public.inventory_count_policies DROP CONSTRAINT inventory_count_policies_interval_days_check;"
)

# The migration's functions only (tables, triggers and data already exist in <database>).
python3 - "$migration" "$work/functions.sql" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
found = re.findall(r"(CREATE (?:OR REPLACE )?FUNCTION .*?\nAS (\$\$|\$function\$)\n.*?\n\2;)", text, re.S)
if len(found) != 4:
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
