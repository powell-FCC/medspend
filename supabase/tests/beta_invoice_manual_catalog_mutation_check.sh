#!/usr/bin/env bash
# Manual catalog matching mutation check. Proves the behavior suites fail when a critical
# guard in the migration is removed: catalog search and matching, manual re-matching of
# catalog-adopted SKUs, and the withdrawal of calculated totals. Disposable databases only:
# never point this at production.
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
suites=(
  "$root/supabase/tests/beta_invoice_manual_catalog_matching_behavior.sql"
  "$root/supabase/tests/beta_invoice_rematch_behavior.sql"
  "$root/supabase/tests/beta_invoice_derived_totals_behavior.sql"
  "$root/supabase/tests/beta_invoice_posting_rematch_behavior.sql"
  "$root/supabase/tests/beta_invoice_create_and_confirm_behavior.sql"
  "$root/supabase/tests/phase6c1_invoice_exact_match_auto_resolution_behavior.sql"
)
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
  "confirm repoints a catalog-adopted mapping|IF _mapping.product_id = _product_id OR _mapping.catalog_vendor_product_id IS NULL THEN|IF true THEN"
  "confirm shadows a catalog-adopted mapping with a separator variant|      IF _adopted_count = 0 THEN|      IF true THEN"
  "confirm links a line to an adopted mapping for another product|IF _adopted_count = 1 AND _mapping.active AND _mapping.product_id = _product_id THEN|IF true THEN"
  "confirm never reuses the adopted mapping|IF _adopted_count = 1 AND _mapping.active AND _mapping.product_id = _product_id THEN|IF false THEN"
  "confirm forgets manual provenance|    product_match_source = 'manual', product_match_decided_at = now()|    product_match_source = NULL, product_match_decided_at = NULL"
  "confirm does not say which mapping it kept|'preservedVendorProductId', _preserved_vendor_product_id);|'preservedVendorProductId', NULL);"
  "adoption conflicts leak as constraint errors|EXCEPTION WHEN unique_violation OR check_violation OR foreign_key_violation THEN|EXCEPTION WHEN division_by_zero THEN"
  "match reaches a line on another invoice|WHERE id = _invoice_item_id AND invoice_id = _invoice.id AND organization_id = _organization_id FOR UPDATE;|WHERE id = _invoice_item_id AND organization_id = _organization_id FOR UPDATE;"
  "calculated totals survive API line changes|  IF current_user NOT IN ('authenticated', 'anon') THEN RETURN NULL; END IF;|  RETURN NULL;"
  "database functions withdraw calculated totals too|  IF current_user NOT IN ('authenticated', 'anon') THEN RETURN NULL; END IF;|"
  "printed totals are withdrawn|    _total := coalesce(_extraction #>> '{header,total,source}' = 'Derived', false);|    _total := true;"
  "printed subtotals are withdrawn|    _subtotal := coalesce(_extraction #>> '{header,subtotal,source}' = 'Derived', false);|    _subtotal := true;"
  "a price change keeps a calculated total|        OR NEW.unit_price IS DISTINCT FROM OLD.unit_price|"
  "a line total change keeps a calculated total|        OR NEW.total_price IS DISTINCT FROM OLD.total_price THEN| THEN"
  "a removed line keeps a calculated total|    _invoice_ids := ARRAY[OLD.invoice_id];|    _invoice_ids := ARRAY[]::uuid[];"
  "an added line keeps a calculated total|    _invoice_ids := ARRAY[NEW.invoice_id];
  ELSIF TG_OP = 'DELETE' THEN|    _invoice_ids := ARRAY[]::uuid[];
  ELSIF TG_OP = 'DELETE' THEN"
  "any line update withdraws calculated totals|  ELSE
    RETURN NULL;
  END IF;|  ELSE
    _invoice_ids := ARRAY[NEW.invoice_id];
  END IF;"
  "completed invoices lose calculated totals|      OR _invoice.posted_at IS NOT NULL OR _invoice.processing_status = 'completed';|;"
  "the stored extraction keeps a withdrawn total|    UPDATE public.invoice_processing_jobs SET extraction_result = _extraction
    WHERE invoice_id = _invoice.source_file_id AND organization_id = _invoice.organization_id;|"
  "the invoice row keeps a withdrawn subtotal|      subtotal = CASE WHEN _subtotal THEN NULL ELSE subtotal END,|      subtotal = subtotal,"
  "the invoice row keeps a withdrawn total|      total_amount = CASE WHEN _total THEN NULL ELSE total_amount END,|      total_amount = total_amount,"
  "posting claims a SKU label another product's item carries|          AND lower(other.sku) = lower(_candidate_sku)|          AND false"
  "posting label check ignores the vendor|          AND lower(other.vendor_name) = lower(_vendor_name)|"
  "posting takes the label away from the item that carries it|          AND other.id IS DISTINCT FROM _inventory.id|"
  "posting drops a product's own label on a collision|ARRAY[nullif(btrim(_line.sku), ''), _inventory.sku]|ARRAY[nullif(btrim(_line.sku), '')]"
  "posting never labels an inventory item|        _inventory_sku := _candidate_sku;|        _inventory_sku := NULL;"
  "posting accepts unresolved lines|  IF _unresolved > 0 THEN|  IF false THEN|    IF _product_id IS NULL THEN|    IF false THEN"
  "posting accepts a mapping for another product|IF _mapping.product_id IS DISTINCT FROM _product_id THEN|IF false THEN"
  "create shadows a catalog-adopted SKU|    IF FOUND THEN
      SELECT name INTO _existing_name|    IF false THEN
      SELECT name INTO _existing_name"
  "create ignores separators|        AND public.normalize_catalog_sku_match_key(vendor_sku) = public.normalize_catalog_sku_match_key(_line.sku)|        AND lower(btrim(vendor_sku)) = lower(btrim(_line.sku))"
  "create ignores the vendor|      WHERE organization_id = _organization_id AND vendor_id = _invoice.vendor_id
        AND catalog_vendor_product_id IS NOT NULL
        AND public.normalize_catalog_sku_match_key(_line.sku) <> ''|      WHERE organization_id = _organization_id
        AND catalog_vendor_product_id IS NOT NULL
        AND public.normalize_catalog_sku_match_key(_line.sku) <> ''"
  "create ignores forgotten catalog mappings|        AND public.normalize_catalog_sku_match_key(_line.sku) <> ''|        AND active AND public.normalize_catalog_sku_match_key(_line.sku) <> ''"
  "plain confirm overwrites a newer match|    RAISE EXCEPTION 'This line''s product match has changed; reload the invoice before changing it';
  END IF;
  RETURN public.confirm_invoice_item_product(|    NULL;
  END IF;
  RETURN public.confirm_invoice_item_product("
  "a withdrawn total stays reviewed|\"source\": \"Derived\", \"reviewed\": false}';|\"source\": \"Derived\", \"reviewed\": true}';"
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
  else
    killed=""
    for suite in "${suites[@]}"; do
      if ! psql -q -v ON_ERROR_STOP=1 -d "$db" -f "$suite" >/dev/null 2>"$work/suite.err"; then
        killed="$(basename "$suite" .sql): $(grep -m1 -o 'Checks* [0-9-]*[^:]* failed[^:]*\|ERROR: .*' "$work/suite.err" | head -c 140)"
        break
      fi
    done
    if [ -z "$killed" ]; then
      echo "SURVIVED - $name"
      survived=$((survived + 1))
    else
      echo "KILLED - $name: $killed"
    fi
  fi
  psql -q -d postgres -c "DROP DATABASE $db" >/dev/null
done

if [ "$survived" -ne 0 ]; then
  echo "$survived mutant(s) survived"
  exit 1
fi
echo "all ${#mutants[@]} mutants killed"
