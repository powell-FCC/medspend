#!/usr/bin/env bash
# Catalog vendor management mutation check. Proves the behavior suite fails when a critical
# rule in the migration is removed. Disposable databases only: never point this at
# production.
#
# Usage:
#   supabase/tests/catalog_vendor_management_mutation_check.sh <database>
#
# <database> must have every migration applied, including
# 20261019120000_catalog_vendor_management.sql. Connection settings come from the standard
# PGHOST/PGPORT/PGUSER environment variables. Each mutant replaces the functions inside one
# transaction, runs the suite there, and rolls everything back.
#
# The adoption mutants cover the redefined Phase 5A.5 adoption: restoring its name-based link
# must fail the suite.
#
# Organization scoping inside get_organization_vendor_catalog_coverage is deliberately not
# mutated: it runs with the caller's privileges, so vendor and mapping RLS enforces the same
# boundary and such a mutant cannot be observed (defense in depth, not a gap).
set -euo pipefail

database="${1:?usage: $0 <database>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
migration="$root/supabase/migrations/20261019120000_catalog_vendor_management.sql"
suite="$root/supabase/tests/catalog_vendor_management_behavior.sql"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# name | exact text in the migration | replacement [| more text | replacement ...]
mutants=(
  "API roles may write links directly|  IF current_user IN ('authenticated', 'anon') AND (|  IF false AND ("
  "existing links may be repointed|     AND NEW.catalog_vendor_id <> OLD.catalog_vendor_id THEN|     AND false THEN"
  "link admin check removed|  IF auth.uid() IS NULL OR NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Only organization owners and admins can link catalog vendors'|  IF false THEN
    RAISE EXCEPTION 'Only organization owners and admins can link catalog vendors'"
  "link ignores the vendor's organization|  WHERE id = _vendor_id AND organization_id = _organization_id
  FOR UPDATE;|  WHERE id = _vendor_id
  FOR UPDATE;"
  "same-target link is not idempotent|  IF _vendor.catalog_vendor_id = _catalog_vendor.id THEN|  IF false THEN"
  "already-linked vendor not refused|  IF _vendor.catalog_vendor_id IS NOT NULL THEN|  IF false THEN"
  "stale version accepted|  IF _vendor.updated_at IS DISTINCT FROM _expected_updated_at THEN|  IF false THEN"
  "inactive catalog vendor accepted|  IF NOT _catalog_vendor.active THEN|  IF false THEN"
  "second organization vendor per catalog vendor not refused|      AND other.id <> _vendor.id
  ) THEN|      AND other.id <> _vendor.id
      AND false
  ) THEN"
  "coverage admin check removed|  IF auth.uid() IS NULL OR NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Only organization owners and admins can review catalog coverage'|  IF false THEN
    RAISE EXCEPTION 'Only organization owners and admins can review catalog coverage'"
  "exact match crosses vendors|      ON exact.catalog_vendor_id = _catalog_vendor.id
     AND exact.normalized_vendor_sku = mapping.strict_sku|      ON exact.normalized_vendor_sku = mapping.strict_sku"
  "separator match crosses vendors|      WHERE listing.catalog_vendor_id = _catalog_vendor.id
        AND mapping.sku_key IS NOT NULL|      WHERE mapping.sku_key IS NOT NULL"
  "separator equivalence ignored|        WHEN keyed.match_count = 1 THEN 'separator_equivalent'|        WHEN false THEN 'separator_equivalent'"
  "ambiguous keys treated as uncataloged|        WHEN keyed.match_count > 1 THEN 'ambiguous'|        WHEN false THEN 'ambiguous'"
  "adopted listing not recognized|        WHEN adopted.id IS NOT NULL THEN 'linked'|        WHEN false THEN 'linked'"
  "inactive mappings counted|      'mapped', count(*) FILTER (WHERE active),|      'mapped', count(*),"
  "adoption links a same-name vendor again|      RAISE EXCEPTION
        'Organization vendor % is not linked to catalog vendor %; link it in Catalog Vendors before adopting',
        _organization_vendor.id,
        _catalog_vendor.id
        USING ERRCODE = '55000';|      UPDATE public.vendors
      SET catalog_vendor_id = _catalog_vendor.id
      WHERE id = _organization_vendor.id
      RETURNING * INTO _organization_vendor;"
  "adoption accepts a same-name vendor linked elsewhere|      IF _organization_vendor.catalog_vendor_id IS NOT NULL THEN
        RAISE EXCEPTION
          'Active organization vendor|      IF false THEN
        RAISE EXCEPTION
          'Active organization vendor"
  "adoption admin check removed|  IF NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Only organization owners and admins can adopt catalog products'|  IF false THEN
    RAISE EXCEPTION 'Only organization owners and admins can adopt catalog products'"
  "coverage row cap counts only displayed rows|    'truncated', count(*) > 1000
  )
  INTO _result
  FROM ordered;|    'truncated', count(*) > 1000
  )
  INTO _result
  FROM ordered WHERE position <= 1000;"
  "inactive uncataloged rows counted|      'notRepresented', count(*) FILTER (WHERE active AND status = 'not_cataloged'),|      'notRepresented', count(*) FILTER (WHERE status = 'not_cataloged'),"
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
# Re-create the trigger and functions in place; the DO preflight would refuse a second run.
start = text.index("-- Like the Phase 6C.1 provenance guard")
text = text[start:].replace("\nCOMMIT;\n", "\n")
text = text.replace("CREATE FUNCTION", "CREATE OR REPLACE FUNCTION")
text = text.replace("CREATE TRIGGER vendors_guard_catalog_link", "CREATE OR REPLACE TRIGGER vendors_guard_catalog_link")
body = open(suite).read().replace("BEGIN;\n", "", 1).replace("\nROLLBACK;\n", "\n")
open(target, "w").write("BEGIN;\n" + text + body + "\nROLLBACK;\n")
PY
  if psql -q -v ON_ERROR_STOP=1 -d "$database" -o /dev/null -f "$work/mutant.sql" >/dev/null 2>"$work/err"; then
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
