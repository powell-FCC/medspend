#!/usr/bin/env bash
# Budget & Purchasing command center mutation check. Proves the behavior suite fails when a
# critical rule in the migration is removed. Disposable databases only: never point this at
# production.
#
# Usage:
#   supabase/tests/budget_purchasing_command_center_mutation_check.sh <database>
#
# <database> must have every migration applied, including
# 20261015120000_budget_purchasing_command_center.sql. Connection settings come from the
# standard PGHOST/PGPORT/PGUSER environment variables. Each mutant replaces the functions
# inside one transaction, runs the suite there, and rolls everything back.
set -euo pipefail

database="${1:?usage: $0 <database>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
migration="$root/supabase/migrations/20261015120000_budget_purchasing_command_center.sql"
suite="$root/supabase/tests/budget_purchasing_command_center_behavior.sql"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# name | exact text in the migration | replacement [| more text | replacement ...]
mutants=(
  "alternatives ignore package size|
     AND other.package_key = current_row.package_key|"
  "alternatives accept unrecorded packages|     AND other.package_key = current_row.package_key|     AND other.package_key IS NOT DISTINCT FROM current_row.package_key"
  "previous price ignores unit of measure|        PARTITION BY product_id, vendor_id, uom_key, package_key
        ORDER BY purchase_date, created_at, id|        PARTITION BY product_id, vendor_id
        ORDER BY purchase_date, created_at, id"
  "previous price ignores vendor|      unit_history AS (
        PARTITION BY product_id, vendor_id, uom_key, package_key|      unit_history AS (
        PARTITION BY product_id, uom_key, package_key"
  "unit-less prices are compared|'previous', CASE WHEN cur.uom_key IS NOT NULL AND|'previous', CASE WHEN"
  "average window widened to a year|interval '89 days'|interval '364 days'"
  "unposted observations count|     AND invoice.posted_at IS NOT NULL
    JOIN public.vendors vendor|    JOIN public.vendors vendor"
  "non-USD observations count|      AND invoice.currency_code = 'USD'
      AND COALESCE(history.unit_price|      AND COALESCE(history.unit_price"
  "savings shown for a dearer alternative|WHEN alternative.price < cur.price|WHEN alternative.price IS NOT NULL"
  "prices are not organization-scoped|    WHERE history.organization_id = _organization_id
      AND invoice.currency_code|    WHERE invoice.currency_code"
  "inactive budgets listed|      AND budget.active = true
  ),
  active_commitments|  ),
  active_commitments"
  "approvals count every status|          AND request.status IN ('submitted', 'under_review')|"
  "settled commitments still need settling|    WHERE commitment.organization_id = _organization_id
      AND commitment.status = 'active'
  ),
  recent_invoices|    WHERE commitment.organization_id = _organization_id
  ),
  recent_invoices"
  "admins see invoice detail|    WHERE _is_owner
      AND invoice.organization_id = _organization_id
      AND invoice.posted_at IS NOT NULL
    ORDER BY|    WHERE invoice.organization_id = _organization_id
      AND invoice.posted_at IS NOT NULL
    ORDER BY|    'recentPurchases', CASE WHEN _is_owner THEN|    'recentPurchases', CASE WHEN true THEN"
  "lineage includes released commitments|      AND commitment.status = 'active'
      AND commitment.committed_at::date BETWEEN _budget.period_start|      AND commitment.committed_at::date BETWEEN _budget.period_start"
  "lineage ignores the budget's organization|  WHERE budget.id = _budget_id AND budget.organization_id = _organization_id;|  WHERE budget.id = _budget_id;"
  "admin checks removed|  IF NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN|  IF false THEN"
)

survived=0
for entry in "${mutants[@]}"; do
  name="${entry%%|*}"
  python3 - "$migration" "$suite" "$work/mutant.sql" "${entry#*|}" <<'PY'
import sys
migration, suite, target, spec = sys.argv[1:5]
parts = spec.split("|")
if len(parts) % 2:
    sys.exit(f"mutation needs text|replacement pairs: {spec!r}")
text = open(migration).read()
for needle, replacement in zip(parts[::2], parts[1::2]):
    if needle not in text:
        sys.exit(f"mutation target not found: {needle!r}")
    text = text.replace(needle, replacement)
text = text.replace("BEGIN;\n", "", 1).replace("\nCOMMIT;\n", "\n").replace("CREATE FUNCTION", "CREATE OR REPLACE FUNCTION")
body = open(suite).read().replace("BEGIN;\n", "", 1).replace("\nROLLBACK;\n", "\n")
open(target, "w").write("BEGIN;\n" + text + body + "\nROLLBACK;\n")
PY
  if psql -q -v ON_ERROR_STOP=1 -d "$database" -f "$work/mutant.sql" >/dev/null 2>"$work/err"; then
    echo "SURVIVED - $name"
    survived=$((survived + 1))
  else
    echo "KILLED - $name: $(grep -m1 -o 'ERROR: .*' "$work/err" | head -c 120)"
  fi
done

if [ "$survived" -ne 0 ]; then
  echo "$survived mutant(s) survived"
  exit 1
fi
echo "all ${#mutants[@]} mutants killed"
