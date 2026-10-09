#!/usr/bin/env bash
# Phase 6C.1 mutation check. Proves the behavior suite fails when a critical guard in
# the migration is removed. Disposable databases only: never point this at production.
#
# Usage:
#   supabase/tests/phase6c1_mutation_check.sh <template_database>
#
# <template_database> must have every migration before
# 20261010120000_phase6c1_invoice_exact_match_auto_resolution.sql applied. Connection
# settings come from the standard PGHOST/PGPORT/PGUSER environment variables. Each
# mutant is applied to a fresh copy of the template and dropped afterwards.
set -euo pipefail

template="${1:?usage: $0 <template_database>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
migration="$root/supabase/migrations/20261010120000_phase6c1_invoice_exact_match_auto_resolution.sql"
suite="$root/supabase/tests/phase6c1_invoice_exact_match_auto_resolution_behavior.sql"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# name | exact text in the migration | replacement (replaced everywhere it occurs)
mutants=(
  "organization tier ignores the vendor|AND mapping.vendor_id = _vendor_id|"
  "catalog tier ignores the vendor|listing.catalog_vendor_id = _catalog_vendor_id|true"
  "organization ambiguity accepted|IF _count > 1 THEN
    RETURN QUERY SELECT 'review'::text, 'ambiguous_organization_mapping'|IF false THEN
    RETURN QUERY SELECT 'review'::text, 'ambiguous_organization_mapping'"
  "catalog ambiguity accepted|IF _count > 1 THEN
    RETURN QUERY SELECT 'review'::text, 'ambiguous_catalog_listing'|IF false THEN
    RETURN QUERY SELECT 'review'::text, 'ambiguous_catalog_listing'"
  "separator key used for SKUs with separators|_separator_free := _strict = _key;|_separator_free := true;"
  "unverified catalog listings adopted|OR _listing.verification_status <> 'verified'|"
  "deactivated organization mapping reused|IF NOT _mapping.active THEN|IF false THEN"
  "separator-variant organization mapping ignored|  IF EXISTS (
    SELECT 1 FROM public.vendor_products mapping
    WHERE mapping.organization_id = _organization_id
      AND mapping.vendor_id = _vendor_id
      AND public.normalize_catalog_sku_match_key(mapping.vendor_sku) = _key
  ) THEN|  IF false THEN"
  "manual decisions revisited|AND product_match_source IS NULL|"
  "owner unlink not recorded|product_match_source = 'manual_cleared'|product_match_source = NULL"
  "API can forge provenance|IF current_user IN ('authenticated', 'anon') THEN|IF false THEN"
  "unlinked vendor reaches the catalog|IF _catalog_vendor_id IS NULL THEN|IF false THEN"
)

survived=0
for entry in "${mutants[@]}"; do
  name="${entry%%|*}"; rest="${entry#*|}"
  needle="${rest%%|*}"; replacement="${rest#*|}"
  python3 - "$migration" "$work/mutant.sql" "$needle" "$replacement" <<'PY'
import sys
source, target, needle, replacement = sys.argv[1:5]
text = open(source).read()
if needle not in text:
    sys.exit(f"mutation target not found: {needle!r}")
open(target, "w").write(text.replace(needle, replacement))
PY
  db="phase6c1_mutant_$$"
  psql -q -d postgres -c "DROP DATABASE IF EXISTS $db" -c "CREATE DATABASE $db TEMPLATE $template" >/dev/null
  if ! psql -q -v ON_ERROR_STOP=1 -d "$db" -1 -f "$work/mutant.sql" >/dev/null 2>"$work/apply.err"; then
    echo "KILLED (migration rejected) - $name"
  elif psql -q -v ON_ERROR_STOP=1 -d "$db" -f "$suite" >/dev/null 2>"$work/suite.err"; then
    echo "SURVIVED - $name"
    survived=$((survived + 1))
  else
    echo "KILLED - $name: $(grep -m1 -o 'Check [0-9]* failed[^:]*\|ERROR: .*' "$work/suite.err" | head -c 160)"
  fi
  psql -q -d postgres -c "DROP DATABASE $db" >/dev/null
done

if [ "$survived" -ne 0 ]; then
  echo "$survived mutant(s) survived"
  exit 1
fi
echo "all ${#mutants[@]} mutants killed"
