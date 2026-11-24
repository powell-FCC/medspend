#!/usr/bin/env bash
# Catalog name-twin hotfix mutation check. Proves the behavior suite fails when a rule in
# the hotfix is removed, and when the pre-hotfix function definitions are restored.
# Disposable databases only: never point this at production.
#
# Usage:
#   supabase/tests/hotfix_catalog_adoption_name_twin_mutation_check.sh <database>
#
# <database> must have every migration applied, including
# 20261124120000_hotfix_catalog_adoption_name_twin.sql. Connection settings come from the
# standard PGHOST/PGPORT/PGUSER environment variables. Each mutant replaces the two
# functions inside one transaction, runs the suite there, and rolls everything back. A
# mutant only counts as killed when a suite check fails ("Check N failed"), never on a
# syntax or setup error.
#
# Not mutated: the reuse condition's vendor_id check (the fixture has one vendor, so a
# mutant cannot be observed; it is defense in depth).
set -euo pipefail

database="${1:?usage: $0 <database>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
migration="$root/supabase/migrations/20261124120000_hotfix_catalog_adoption_name_twin.sql"
suite="$root/supabase/tests/hotfix_catalog_adoption_name_twin_behavior.sql"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# name | exact text in the migration | replacement [| more text | replacement ...]
mutants=(
  "linked twin still refused|        IF _name_twin.catalog_product_id IS NULL THEN|        IF true THEN"
  "unlinked local twin accepted|        IF _name_twin.catalog_product_id IS NULL THEN|        IF false THEN"
  "taken qualified name not checked|          AND normalized_name = public.normalize_catalog_text(_product_name)
        LIMIT 1;|          AND false
        LIMIT 1;"
  "new twin inserted under the plain catalog name|        _product_name,
        _verified_unit,|        _catalog_product.name,
        _verified_unit,"
  "inactive product counted as a twin|        AND active
        AND normalized_name = _catalog_product.normalized_name
      LIMIT 1;|        AND normalized_name = _catalog_product.normalized_name
      LIMIT 1;"
  "reuse offered for a line printed with another SKU|      AND public.normalize_catalog_sku_match_key(_line.sku) = public.normalize_catalog_sku_match_key(_listing.vendor_sku);|      AND true;"
  "reuse offered through a retired mapping|      AND _conflict_vendor_product.active
|"
  "SKU conflict hint dropped|      _organization_product.id
        USING ERRCODE = '23505',
          HINT = jsonb_build_object('conflictType', 'sku_mapped_to_other_product', 'productId', _organization_product.id, 'vendorProductId', _organization_vendor_product.id)::text;|      _organization_product.id
        USING ERRCODE = '23505';"
  "local twin hint omits the product|'name_twin_local', 'productId', _name_twin.id)|'name_twin_local')"
  "adoption hint ignored|      _conflict := nullif(_adoption_hint, '')::jsonb;|      _conflict := NULL;"
  "local twin message not named|      WHEN _conflict_type = 'name_twin_local' AND|      WHEN false AND"
  "duplicate-mapping message not named|      WHEN _conflict_type = 'multiple_sku_mappings' THEN|      WHEN false THEN"
  "match hint omits the product name|          'productName', _conflict_product.name,
|"
)

run_suite() {
  local functions="$1" target="$2"
  python3 - "$functions" "$suite" "$target" <<'PY'
import sys
functions, suite, target = sys.argv[1:4]
body = open(suite).read().replace("BEGIN;\n", "", 1).replace("\nROLLBACK;\n", "\n")
open(target, "w").write("BEGIN;\n" + open(functions).read() + "\n" + body + "\nROLLBACK;\n")
PY
  psql -q -v ON_ERROR_STOP=1 -d "$database" -o /dev/null -f "$target" >/dev/null 2>"$work/err"
}

survived=0
total=0
report() {
  local name="$1"
  total=$((total + 1))
  if grep -q 'Check [0-9]* failed' "$work/err"; then
    echo "KILLED - $name: $(grep -m1 -o 'Check [0-9]* failed[^:]*' "$work/err")"
  else
    echo "SURVIVED - $name: $(grep -m1 -o 'ERROR: .*' "$work/err" | head -c 160)"
    survived=$((survived + 1))
  fi
}

# The functions exactly as they were before the hotfix must fail the suite.
python3 - "$root" "$work/baseline.sql" <<'PY'
import sys
root, target = sys.argv[1:3]
def block(path, start, end_marker):
    text = open(f"{root}/supabase/migrations/{path}").read()
    begin = text.index(start)
    end = text.index(end_marker, begin) + len(end_marker)
    return text[begin:end]
adopt = block("20261019120000_catalog_vendor_management.sql",
              "CREATE OR REPLACE FUNCTION public.adopt_catalog_vendor_product(",
              "inventory is never created or changed.';")
match = block("20261012120000_beta_invoice_manual_catalog_matching.sql",
              "CREATE FUNCTION public.match_invoice_item_to_catalog_listing(",
              "Never approves, posts, or stocks.';")
match = match.replace("CREATE FUNCTION", "CREATE OR REPLACE FUNCTION", 1)
open(target, "w").write(adopt + "\n\n" + match + "\n")
PY
if run_suite "$work/baseline.sql" "$work/run.sql"; then
  echo "SURVIVED - pre-hotfix functions pass the suite"
  survived=$((survived + 1)); total=$((total + 1))
else
  report "pre-hotfix functions"
fi

for entry in "${mutants[@]}"; do
  name="${entry%%|*}"
  python3 - "$migration" "$work/functions.sql" "${entry#*|}" <<'PY'
import sys
migration, target, spec = sys.argv[1:4]
parts = spec.split("|")
if len(parts) % 2:
    sys.exit(f"mutation needs text|replacement pairs: {spec!r}")
text = open(migration).read()
for needle, replacement in zip(parts[::2], parts[1::2]):
    if text.count(needle) != 1:
        sys.exit(f"mutation target must occur exactly once ({text.count(needle)}): {needle!r}")
    text = text.replace(needle, replacement)
start = text.index("CREATE OR REPLACE FUNCTION public.adopt_catalog_vendor_product(")
open(target, "w").write(text[start:].replace("\nCOMMIT;", "\n"))
PY
  if run_suite "$work/functions.sql" "$work/run.sql"; then
    echo "SURVIVED - $name"
    survived=$((survived + 1)); total=$((total + 1))
  else
    report "$name"
  fi
done

if [ "$survived" -ne 0 ]; then
  echo "$survived of $total mutant(s) survived"
  exit 1
fi
echo "all $total mutants killed"
