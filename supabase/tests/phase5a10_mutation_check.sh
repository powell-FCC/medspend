#!/usr/bin/env bash
# Phase 5A.10 mutation check. Proves phase5a10_staff_product_discovery_behavior.sql fails when a
# critical relevance, history or Saved Items rule in the 5A.10 migration is removed.
# Disposable databases only: never point this at production.
#
# Usage:
#   supabase/tests/phase5a10_mutation_check.sh <database>
#
# <database> must have every migration applied, through
# 20261107120000_phase5a10_staff_product_discovery.sql. Each mutant re-creates the 5A.10
# functions (with one rule broken), or prepends one schema change, inside one transaction,
# runs the suite there, and rolls everything back. The suite inserts its own catalog rows, so
# mutants of the document builder are exercised through the statement triggers.
#
# Equivalent changes, deliberately not listed: letting digits into typo correction (the
# vocabulary holds letter-only words, so a digit token can never be corrected) and granting
# INSERT on staff_saved_products (RLS with no policies still refuses the row).
set -euo pipefail

database="${1:?usage: $0 <database>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
migration="$root/supabase/migrations/20261107120000_phase5a10_staff_product_discovery.sql"
suite="$root/supabase/tests/phase5a10_staff_product_discovery_behavior.sql"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# name | exact text in the migration | replacement [| more text | replacement ...]
# name | PREPEND | SQL run before the suite (schema mutants)
# Every occurrence of a target is replaced. No mutant uses SQL's string concatenation
# operator: specs split on the pipe character.
mutants=(
  # Relevance dominates popularity.
  "exact catalog SKU loses priority|             OR (pg_catalog.length(_sku_key) >= 3 AND _sku_key = ANY(candidate.global_sku_keys)) THEN 1|             OR (pg_catalog.length(_sku_key) >= 3 AND _sku_key = ANY(candidate.global_sku_keys)) THEN 8"
  "exact organization SKU loses priority|             OR (pg_catalog.length(_sku_key) >= 3 AND _sku_key = ANY(candidate.organization_sku_keys)) THEN 0|             OR (pg_catalog.length(_sku_key) >= 3 AND _sku_key = ANY(candidate.organization_sku_keys)) THEN 8"
  "exact name is only a phrase match|THEN 2
        WHEN _sku_partial AND EXISTS (|THEN 4
        WHEN _sku_partial AND EXISTS ("
  "approval history overpowers relevance|    matched.match_rank,
    (saved.identity_key IS NOT NULL) DESC,
    COALESCE(signals.approved_count, 0) DESC,|    COALESCE(signals.approved_count, 0) DESC,
    matched.match_rank,
    (saved.identity_key IS NOT NULL) DESC,"
  "saved boost overpowers relevance|    matched.match_rank,
    (saved.identity_key IS NOT NULL) DESC,|    (saved.identity_key IS NOT NULL) DESC,
    matched.match_rank,"
  "purchase history overpowers relevance|    matched.match_rank,
    (saved.identity_key IS NOT NULL) DESC,
    COALESCE(signals.approved_count, 0) DESC,
    COALESCE(signals.purchase_count, 0) DESC,|    COALESCE(signals.purchase_count, 0) DESC,
    matched.match_rank,
    (saved.identity_key IS NOT NULL) DESC,
    COALESCE(signals.approved_count, 0) DESC,"
  "no saved boost|    (saved.identity_key IS NOT NULL) DESC,
    COALESCE(signals.approved_count, 0) DESC,|    COALESCE(signals.approved_count, 0) DESC,"
  "no approval boost|    COALESCE(signals.approved_count, 0) DESC,
    COALESCE(signals.purchase_count, 0) DESC,
    matched.source_priority,|    COALESCE(signals.purchase_count, 0) DESC,
    matched.source_priority,"
  "no purchase boost|    COALESCE(signals.purchase_count, 0) DESC,
    matched.source_priority,|    matched.source_priority,"
  # History signals.
  "denied requests count as approved|    AND request.status IN ('approved', 'ordered', 'received', 'completed')|    AND request.status IN ('approved', 'ordered', 'received', 'completed', 'denied')"
  "cancelled and pending requests count|    AND request.status IN ('approved', 'ordered', 'received', 'completed')|    AND request.status <> 'denied'"
  "approval history from every organization|  WHERE request.organization_id = _organization_id
    AND request.status|  WHERE request.status"
  "purchase history from every organization|  WHERE invoice.organization_id = _organization_id
    AND invoice.posted_at IS NOT NULL|  WHERE invoice.posted_at IS NOT NULL"
  "unposted invoices count as purchases|    AND invoice.posted_at IS NOT NULL
    AND invoice.document_type|    AND invoice.document_type"
  "credit memos count as purchases|    AND invoice.document_type <> 'CREDIT_MEMO'|    AND true"
  # Saved Items scope.
  "search reads Saved Items from every organization|     ON saved_product.organization_id = _organization_id
     AND saved_product.user_id = _uid|     ON saved_product.user_id = _uid"
  "search reads every user's Saved Items|     ON saved_product.organization_id = _organization_id
     AND saved_product.user_id = _uid|     ON saved_product.organization_id = _organization_id"
  "discovery reads Saved Items from every organization|    WHERE saved_product.organization_id = _organization_id
      AND saved_product.user_id = _uid
    ORDER BY|    WHERE saved_product.user_id = _uid
    ORDER BY"
  "discovery reads every user's Saved Items|    WHERE saved_product.organization_id = _organization_id
      AND saved_product.user_id = _uid
    ORDER BY|    WHERE saved_product.organization_id = _organization_id
    ORDER BY"
  "remove deletes another user's Saved Item|  DELETE FROM public.staff_saved_products saved_product
  WHERE saved_product.organization_id = _organization_id
    AND saved_product.user_id = _uid|  DELETE FROM public.staff_saved_products saved_product
  WHERE saved_product.organization_id = _organization_id"
  "unavailable products can be saved|  IF NOT EXISTS (
    SELECT 1 FROM public.supply_request_product_identities(|  IF false AND NOT EXISTS (
    SELECT 1 FROM public.supply_request_product_identities("
  "save accepts two identities|  IF num_nonnulls(_product_id, _catalog_vendor_product_id, _inventory_item_id) <> 1 THEN|  IF num_nonnulls(_product_id, _catalog_vendor_product_id, _inventory_item_id) = 0 THEN"
  "former members allowed|      AND membership.active = true|      AND true"
  "discovery shows a saved product twice|        WHEN saved_keys.result_key IS NOT NULL THEN 'saved'
        WHEN COALESCE(signals.approved_count, 0) >= 2 THEN 'frequent'
        WHEN COALESCE(signals.purchase_count, 0) >= 1 THEN 'purchased'|        WHEN COALESCE(signals.approved_count, 0) >= 2 THEN 'frequent'
        WHEN COALESCE(signals.purchase_count, 0) >= 1 THEN 'purchased'
        WHEN saved_keys.result_key IS NOT NULL THEN 'saved'"
  "discovery limit applies to Saved Items|  WHERE ordered.section = 'saved' AND ordered.position <= 50|  WHERE ordered.section = 'saved' AND ordered.position <= _bounded_limit"
  # Matching safeguards.
  "short tokens match inside words|           WHEN pg_catalog.length(_token) <= 2 THEN ' '|           WHEN pg_catalog.length(_token) <= 2 THEN ''"
  "numbers may follow a digit|           WHEN _token ~ '^[0-9]' THEN '[^0-9/]'|           WHEN _token ~ '^[0-9]' THEN ''"
  "numbers may be followed by a digit|              WHEN _token ~ '[0-9]\$' THEN '[^0-9/]'|              WHEN _token ~ '[0-9]\$' THEN ''"
  "fractions split into two numbers|'([0-9])[[:space:]]*[/⁄∕][[:space:]]*([0-9])'|'(NEVER)(MATCH)'"
  "one-character queries search|  IF pg_catalog.length(_normalized_text) < 2 THEN|  IF pg_catalog.length(_normalized_text) < 1 THEN"
  "typo correction for 3-letter words|    CONTINUE WHEN _token !~ '^[a-z]{4,40}\$';|    CONTINUE WHEN _token !~ '^[a-z]{2,40}\$';"
  "typo correction ignores the first letter|        WHERE terms.term >= pg_catalog.left(_token, 1) COLLATE \"C\"
          AND terms.term < pg_catalog.chr(pg_catalog.ascii(pg_catalog.left(_token, 1)) + 1) COLLATE \"C\"
          AND|        WHERE"
  "two edits for short words|    _limit_edits := CASE WHEN pg_catalog.length(_token) >= 8 THEN 2 ELSE 1 END;|    _limit_edits := 2;"
  "no typo correction|      _corrected := true;|      _corrected := false;"
  "aliases ignored|    WHERE alias.organization_id = _organization_id
    GROUP BY alias.product_id|    WHERE false
    GROUP BY alias.product_id"
  "inactive catalog products searchable|    JOIN public.catalog_vendor_products catalog_vendor_product
      ON catalog_vendor_product.id = hit.catalog_vendor_product_id
     AND catalog_vendor_product.active = true|    JOIN public.catalog_vendor_products catalog_vendor_product
      ON catalog_vendor_product.id = hit.catalog_vendor_product_id"
  "non-requestable products searchable|    WHERE organization_product.organization_id = _organization_id
      AND organization_product.active = true
      AND organization_product.staff_requestable = true
  ),
  unlinked_inventory_candidates|    WHERE organization_product.organization_id = _organization_id
      AND organization_product.active = true
  ),
  unlinked_inventory_candidates"
  "documents miss descriptions|          targets.description,
          targets.vendor_sku,|          targets.vendor_sku,"
  "documents miss specifications|          targets.package_unit,
          specifications.specification)),|          targets.package_unit)),"
  # Schema mutants.
  "product renames not reindexed|PREPEND|DROP TRIGGER catalog_products_search_document_update ON public.catalog_products;"
  "vendor renames not reindexed|PREPEND|DROP TRIGGER catalog_vendors_search_document_update ON public.catalog_vendors;"
  "new source records not reindexed|PREPEND|DROP TRIGGER catalog_source_records_search_document_insert ON public.catalog_source_records;"
  "catalog product updates not reindexed|PREPEND|DROP TRIGGER catalog_vendor_products_search_document_update ON public.catalog_vendor_products;"
  "clients read Saved Items|PREPEND|GRANT SELECT ON public.staff_saved_products TO authenticated;"
  "clients read search documents|PREPEND|GRANT SELECT ON public.catalog_vendor_product_search_documents TO authenticated;"
  "clients call the internal search|PREPEND|GRANT EXECUTE ON FUNCTION public.supply_request_product_search(uuid, text, integer) TO authenticated;"
  "clients call the internal history|PREPEND|GRANT EXECUTE ON FUNCTION public.supply_request_product_history(uuid) TO authenticated;"
  "duplicate saves allowed|PREPEND|ALTER TABLE public.staff_saved_products DROP CONSTRAINT staff_saved_products_user_identity_uq;"
)

# The migration's functions only (tables, triggers and data already exist in <database>).
python3 - "$migration" "$work/functions.sql" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
found = re.findall(r"(CREATE (?:OR REPLACE )?FUNCTION .*?\nAS \$\$\n.*?\n\$\$;)", text, re.S)
if len(found) != 17:
    sys.exit(f"expected the migration's 17 functions, found {len(found)}")
open(sys.argv[2], "w").write("\n".join(found))
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
body = open(suite).read().replace("BEGIN;\n", "", 1).replace("\nROLLBACK;\n", "\n")
open(target, "w").write("BEGIN;\n" + prepend + "\n" + text + "\n" + body + "\nROLLBACK;\n")
PY
}

survived=0
for entry in "${mutants[@]}"; do
  name="${entry%%|*}"
  build "${entry#*|}" "$work/mutant.sql"
  if psql -q -v ON_ERROR_STOP=1 -d "$database" -o /dev/null -f "$work/mutant.sql" >/dev/null 2>"$work/err"; then
    echo "SURVIVED - $name"
    survived=$((survived + 1))
  else
    echo "KILLED - $name: $(grep -m1 -o 'ERROR: .*' "$work/err" | head -c 120)"
  fi
done

# Control: the unmutated functions pass.
build "" "$work/control.sql"
psql -q -v ON_ERROR_STOP=1 -d "$database" -o /dev/null -f "$work/control.sql" >/dev/null || { echo "control run failed"; exit 1; }

if [ "$survived" -ne 0 ]; then
  echo "$survived mutant(s) survived"
  exit 1
fi
echo "all ${#mutants[@]} mutants killed; control passed"
