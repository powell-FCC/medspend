#!/usr/bin/env bash
# Manual catalog matching mutation check. Proves the behavior suite fails when a critical
# guard in the migration is removed. Disposable databases only: never point this at
# production.
#
# Usage:
#   supabase/tests/beta_invoice_manual_catalog_mutation_check.sh <template_database>
#
# <template_database> must have every migration before
# 20261012120000_beta_invoice_manual_catalog_matching.sql applied. Connection settings come
# from the standard PGHOST/PGPORT/PGUSER environment variables. Each mutant is applied to a
# fresh copy of the template and dropped afterwards.
set -euo pipefail

template="${1:?usage: $0 <template_database>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
migration="$root/supabase/migrations/20261012120000_beta_invoice_manual_catalog_matching.sql"
suite="$root/supabase/tests/beta_invoice_manual_catalog_matching_behavior.sql"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# name | exact text in the migration | replacement [| more text | replacement ...]
# Each text is replaced everywhere it occurs. Texts cannot contain the | separator.
mutants=(
  "search ignores the invoice vendor|WHERE listing.catalog_vendor_id = _catalog_vendor_id|WHERE true"
  "search reaches the catalog for an unlinked vendor|  IF _catalog_vendor_id IS NULL THEN
    RETURN jsonb_build_object('available', false, 'reason', 'vendor_not_linked_to_catalog'|  IF false THEN
    RETURN jsonb_build_object('available', false, 'reason', 'vendor_not_linked_to_catalog'"
  "search is no longer separator-insensitive|        OR (_key <> '' AND listing.vendor_sku_match_key = _key)||        OR (length(_key) >= 3 AND listing.vendor_sku_match_key LIKE _key|        OR (false AND listing.vendor_sku_match_key LIKE _key"
  "search offers inactive and discontinued listings|      AND listing.active
      AND NOT listing.discontinued|"
  "search offers rejected listings|      AND listing.verification_status <> 'rejected'|"
  "search offers listings of inactive products|      AND catalog_product.active
      AND catalog_product.verification_status <> 'rejected'|"
  "owner checks removed|IF NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN|IF false THEN"
  "match accepts another vendor's listing|IF NOT FOUND OR _listing.catalog_vendor_id IS DISTINCT FROM _vendor.catalog_vendor_id THEN|IF NOT FOUND THEN"
  "match accepts another vendor's listing and its adoption|IF NOT FOUND OR _listing.catalog_vendor_id IS DISTINCT FROM _vendor.catalog_vendor_id THEN|IF NOT FOUND THEN|IF (_adoption->>'vendorId')::uuid IS DISTINCT FROM _invoice.vendor_id|IF false"
  "match works for an unlinked vendor|  IF _vendor.catalog_vendor_id IS NULL THEN|  IF false THEN"
  "match accepts rejected listings|     OR _listing.verification_status = 'rejected'|"
  "match accepts discontinued listings|  IF NOT _listing.active
     OR _listing.discontinued|  IF false"
  "match overwrites an existing match silently|IF _line.product_id IS DISTINCT FROM _expected_product_id THEN|IF false THEN"
  "match changes completed invoices|  IF _invoice.posted_at IS NOT NULL OR _invoice.processing_status = 'completed' THEN|  IF false THEN"
  "match duplicates a separator-variant mapping|  IF public.normalize_catalog_sku_match_key(_line.sku) <> ''|  IF false AND public.normalize_catalog_sku_match_key(_line.sku) <> ''"
  "match forgets manual provenance|      product_match_source = 'manual', product_match_decided_at = now()|      product_match_source = NULL, product_match_decided_at = NULL"
  "match reaches a line on another invoice|WHERE id = _invoice_item_id AND invoice_id = _invoice.id AND organization_id = _organization_id FOR UPDATE;|WHERE id = _invoice_item_id AND organization_id = _organization_id FOR UPDATE;"
)

survived=0
for entry in "${mutants[@]}"; do
  name="${entry%%|*}"
  python3 - "$migration" "$work/mutant.sql" "${entry#*|}" <<'PY'
import sys
source, target, spec = sys.argv[1:4]
parts = spec.split("|")
if len(parts) % 2:
    sys.exit(f"mutation needs text|replacement pairs: {spec!r}")
text = open(source).read()
for needle, replacement in zip(parts[::2], parts[1::2]):
    if needle not in text:
        sys.exit(f"mutation target not found: {needle!r}")
    text = text.replace(needle, replacement)
open(target, "w").write(text)
PY
  db="beta_manual_catalog_mutant_$$"
  psql -q -d postgres -c "DROP DATABASE IF EXISTS $db" -c "CREATE DATABASE $db TEMPLATE $template" >/dev/null
  if ! psql -q -v ON_ERROR_STOP=1 -d "$db" -1 -f "$work/mutant.sql" >/dev/null 2>"$work/apply.err"; then
    echo "KILLED (migration rejected) - $name"
  elif psql -q -v ON_ERROR_STOP=1 -d "$db" -f "$suite" >/dev/null 2>"$work/suite.err"; then
    echo "SURVIVED - $name"
    survived=$((survived + 1))
  else
    echo "KILLED - $name: $(grep -m1 -o 'Checks* [0-9-]* failed[^:]*\|ERROR: .*' "$work/suite.err" | head -c 160)"
  fi
  psql -q -d postgres -c "DROP DATABASE $db" >/dev/null
done

if [ "$survived" -ne 0 ]; then
  echo "$survived mutant(s) survived"
  exit 1
fi
echo "all ${#mutants[@]} mutants killed"
