#!/usr/bin/env bash
# Phase 6B.1 mutation check. Proves the behaviour suites fail when a critical rule in the 6B.1
# migration is removed. Disposable databases only: never point this at production.
#
# Usage:
#   supabase/tests/phase6b1_mutation_check.sh <database>
#
# <database> must have every migration applied, through
# 20261123120000_phase6b1_multi_vendor_intelligence.sql. Each mutant re-creates the 6B.1
# functions (with one rule broken) inside one transaction, runs the suites there, and rolls
# everything back. A control run with the unmutated functions must pass every suite.
#
# Equivalent, deliberately not listed:
#   * SKU identity in the same-SKU grouping (GROUP BY ... sku_key, unit_key): a change is only
#     reported when the product is not insufficient identity, which already requires every vendor
#     to have exactly one SKU identity, so all of the anchor vendor's rows share it;
#   * the organization filter on the detail's inventory-item lookup: the resolved product is
#     then looked up with the organization filter, so another organization's item is still
#     "Product not found" (the suite asserts that response);
#   * the GREATEST(..., 0) age floor: a future-dated observation is fresh either way (age < 0
#     is below every threshold), so only the reported ageDays changes, and it is display-only;
#   * the product sort's second key (product_id): products.normalized_name is unique among
#     active products, and no fixture has two inactive products with one name;
#   * the request-context first query (product ids): the second query re-derives every item,
#     so dropping a product id there only drops that item's state, already asserted below.
# Covered elsewhere: concurrent posting and removal (supabase/tests/phase6b1_race_check.sh).
set -euo pipefail

database="${1:?usage: $0 <database>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
migration="$root/supabase/migrations/20261123120000_phase6b1_multi_vendor_intelligence.sql"
suites=(
  "$root/supabase/tests/phase6b1_multi_vendor_behavior.sql"
  "$root/supabase/tests/phase6b_price_intelligence_behavior.sql"
  "$root/supabase/tests/budget_purchasing_command_center_behavior.sql"
)
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# name | exact text in the migration | replacement [| more text | replacement ...]
# Every occurrence of a target is replaced. Specs split on the pipe character, so no mutant uses
# SQL's string concatenation operator, and none contains a dollar-quote (bash would expand it).
mutants=(
  # Same-SKU history
  "unit dropped from the same-SKU grouping|    GROUP BY o.product_id, o.vendor_id, o.sku_key, o.unit_key|    GROUP BY o.product_id, o.vendor_id, o.sku_key"
  "insufficient identity still shows a change|      CASE WHEN stated.state <> 'insufficient_identity' AND stated.prior_id IS NOT NULL|      CASE WHEN stated.prior_id IS NOT NULL"
  "prior taken from another same-SKU group|      (array_agg(g.ids[2] ORDER BY g.newest_date DESC, g.newest_created_at DESC, g.ids[1] DESC))[1] AS rep_prior_id,
      (array_agg(g.prices[2] ORDER BY g.newest_date DESC, g.newest_created_at DESC, g.ids[1] DESC))[1] AS rep_prior_price|      (array_agg(g.ids[1] ORDER BY g.newest_date DESC, g.newest_created_at DESC, g.ids[1] DESC))[2] AS rep_prior_id,
      (array_agg(g.prices[1] ORDER BY g.newest_date DESC, g.newest_created_at DESC, g.ids[1] DESC))[2] AS rep_prior_price"
  "old detail vendor previous crosses SKUs|         AND o.sku_key = rep.sku_key AND o.unit_key = rep.unit_key AND o.unit_valid AND rep.unit_valid
       ORDER BY|         AND o.unit_key = rep.unit_key AND o.unit_valid AND rep.unit_valid
       ORDER BY|        'previousPrice', CASE WHEN vendor_row.sku_count = 1 AND NOT vendor_row.missing_sku
          AND vendor_row.other_mapped_skus = 0 THEN vendor_row.prior_price END,|        'previousPrice', vendor_row.prior_price,"
  # Identity
  "multi-SKU guard off|      bool_or(v.multiple_skus) AS multiple_skus,|      false AS multiple_skus,"
  "unpurchased mappings ignored|               AND mapping.active
               AND NULLIF(btrim(mapping.vendor_sku), '') IS NOT NULL
             UNION|               AND false
             UNION"
  "missing SKU allowed|      bool_or(v.missing_sku) AS missing_sku,|      false AS missing_sku,"
  "unit problems are not identity problems|        WHEN c.multiple_skus OR c.missing_sku OR c.missing_unit OR c.malformed_unit THEN 'insufficient_identity'|        WHEN c.multiple_skus OR c.missing_sku THEN 'insufficient_identity'"
  "unit validator loosened|'^[a-z]{1,10}\$'|'^.{1,10}\$'"
  "unit key keeps case|NULLIF(lower(btrim(history.unit_of_measure)), '')|NULLIF(btrim(history.unit_of_measure), '')"
  # Cross-vendor comparability
  "cross-vendor unit equality removed|        AND p.anchor_unit_key = r ->> 'unitKey'
|"
  "no package evidence agrees|    WHEN _catalog_vendor_product_a IS NULL OR _catalog_vendor_product_b IS NULL THEN false|    WHEN _catalog_vendor_product_a IS NULL OR _catalog_vendor_product_b IS NULL THEN true"
  "differing package text falls back to the catalog|    WHEN NULLIF(lower(btrim(_package_a)), '') IS NOT NULL AND NULLIF(lower(btrim(_package_b)), '') IS NOT NULL
      THEN lower(btrim(_package_a)) = lower(btrim(_package_b))|    WHEN NULLIF(lower(btrim(_package_a)), '') IS NOT NULL AND NULLIF(lower(btrim(_package_b)), '') IS NOT NULL
        AND lower(btrim(_package_a)) = lower(btrim(_package_b))
      THEN true"
  "catalog agreement with the invoiced unit skipped|      AND public.price_catalog_unit_agrees(a.package_quantity, a.package_description, _unit_key)
      AND public.price_catalog_unit_agrees(b.package_quantity, b.package_description, _unit_key)
|"
  "source-only catalog packages accepted|      AND a.package_status = 'verified'
      AND b.package_status = 'verified'
|"
  "catalog quantity mismatch accepted|    SELECT a.package_quantity = b.package_quantity
      AND|    SELECT"
  "quantity 1 agrees with any unit|    WHEN _quantity = 1 THEN _unit_key IN ('ea', 'each')|    WHEN _quantity = 1 THEN true"
  "lower-price signal on equal prices|      CASE WHEN marked.numbers AND marked.anchor_price > marked.cheapest_price|      CASE WHEN marked.numbers AND marked.anchor_price >= marked.cheapest_price"
  "a tie ranks the other vendor|      CASE WHEN marked.anchor_price <= marked.cheapest_price THEN marked.anchor_id ELSE marked.cheapest_id END, _today)|      CASE WHEN marked.anchor_price < marked.cheapest_price THEN marked.anchor_id ELSE marked.cheapest_id END, _today)"
  "stale pairs produce numbers|      (stated.state = 'comparable' AND COALESCE(stated.fresh_count, 0) > 0) AS numbers|      (stated.state = 'comparable' AND COALESCE(stated.match_count, 0) > 0) AS numbers"
  # Recency
  "freshness at 181 days|      GREATEST(_today - v.rep_date, 0) <= 180 AS rep_fresh,|      GREATEST(_today - v.rep_date, 0) <= 181 AS rep_fresh,"
  "recent at 91 days|    WHEN GREATEST(_today - _purchase_date, 0) <= 90 THEN 'recent'|    WHEN GREATEST(_today - _purchase_date, 0) <= 91 THEN 'recent'"
  "aging at 181 days|    WHEN GREATEST(_today - _purchase_date, 0) <= 180 THEN 'aging'|    WHEN GREATEST(_today - _purchase_date, 0) <= 181 THEN 'aging'"
  "stale anchor still signals an increase|      CASE WHEN marked.change > 0 AND marked.anchor_fresh THEN 'same_sku_price_increased' END,|      CASE WHEN marked.change > 0 THEN 'same_sku_price_increased' END,"
  "stale anchor not marked|      (NOT decided.anchor_fresh OR decided.withheld IS NOT DISTINCT FROM 'stale') AS is_stale|      (decided.withheld IS NOT DISTINCT FROM 'stale') AS is_stale"
  # Order confirmations and currency
  "order confirmations lose their posting-date label|    CASE WHEN invoice.invoice_date IS NULL THEN 'posting_date' ELSE 'invoice_date' END,|    'invoice_date',"
  "document type not labelled|    COALESCE(NULLIF(btrim(invoice.document_type), ''), 'UNKNOWN'),|    'INVOICE',"
  "order confirmations show no order number|    CASE WHEN invoice.document_type = 'ORDER_CONFIRMATION'
      THEN COALESCE(NULLIF(btrim(invoice.order_number), ''), NULLIF(btrim(invoice.invoice_number), ''))|    CASE WHEN false
      THEN NULL"
  "non-USD included|    AND (_currency_code IS NULL OR btrim(_currency_code) = '' OR upper(btrim(_currency_code)) = 'USD')) IS TRUE|    AND true) IS TRUE"
  "NULL currency excluded|    AND (_currency_code IS NULL OR btrim(_currency_code) = '' OR upper(btrim(_currency_code)) = 'USD')) IS TRUE|    AND upper(btrim(_currency_code)) = 'USD') IS TRUE"
  "unposted documents observed|   AND invoice.posted_at IS NOT NULL
  LEFT JOIN public.vendor_products mapping|  LEFT JOIN public.vendor_products mapping"
  "observations not organization-scoped|    WHERE all_rows.organization_id = _organization_id AND _product_ids IS NULL|    WHERE _product_ids IS NULL"
  # Access
  "admins may open source documents|    'canOpenSourceDocument', _is_owner,|    'canOpenSourceDocument', true,"
  "new RPCs skip the access check|  PERFORM public.financial_assert_access(_organization_id, false);|  PERFORM 1;|  _is_owner := public.financial_assert_access(_organization_id, false);|  _is_owner := true;"
  "old RPCs skip the access check|  IF NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN|  IF false THEN"
  "request context leaks another organization's request|  WHERE request.id = _request_id AND request.organization_id = _organization_id;|  WHERE request.id = _request_id;"
  # Old RPC compatibility and removed savings
  "old savings resurrected|      'unitSavings', NULL|      'unitSavings', state.difference"
  "old 90-day average resurrected|      'recentAverage', NULL,|      'recentAverage', jsonb_build_object('average', 1, 'observationCount', 1, 'windowStart', '2026-01-01', 'windowEnd', '2026-01-01'),"
  "old alternative ignores comparability|      'bestAlternative', CASE WHEN state.alternative IS NOT NULL THEN jsonb_build_object(|      'bestAlternative', CASE WHEN state.anchor IS NOT NULL THEN jsonb_build_object("
  # Keyset pagination and request context
  "recent walk keeps older observations|          AND (newer.purchase_date, newer.created_at, newer.id) > (history.purchase_date, history.created_at, history.id)|          AND (newer.purchase_date, newer.created_at, newer.id) < (history.purchase_date, history.created_at, history.id)"
  "recent cursor re-reads the boundary row|      AND (history.purchase_date, history.created_at, history.id)
        < (COALESCE(|      AND (history.purchase_date, history.created_at, history.id)
        <= (COALESCE("
  "name cursor re-reads the boundary row|        AND (_after_name IS NULL OR (candidate.normalized_name, candidate.id) > (_after_name, _after_product_id))|        AND (_after_name IS NULL OR (candidate.normalized_name, candidate.id) >= (_after_name, _after_product_id))"
  "filtered scan stops without a cursor|      WHEN bounds.scanned_count >= _scan THEN
        CASE WHEN _filter = 'all' THEN bounds.last_page_position ELSE bounds.last_scan_position END|      WHEN false THEN NULL"
  "lower-price line shown against another SKU|          AND (r.sku_purchase IS NULL OR r.sku_purchase -> 'observationId' = r.anchor -> 'observationId')
|"
  "several SKUs show a price|        WHEN r.state IS NULL OR r.state = 'insufficient_identity' THEN NULL
        ELSE jsonb_build_object(|        WHEN r.state IS NULL THEN NULL
        ELSE jsonb_build_object("
  # Summary counting path (price_summary_*): each must still equal price_product_state.
  "summary counts non-USD as USD|      (invoice.currency_code IS NULL OR btrim(invoice.currency_code) = ''
        OR upper(btrim(invoice.currency_code)) = 'USD') AS usd_basis,|      true AS usd_basis,"
  "summary validity ignores price|            AND COALESCE(history.unit_price, history.extended_price / NULLIF(history.quantity, 0)) >= 0
            AND history.quantity > 0 THEN 4 ELSE 0 END)|            THEN 4 ELSE 0 END)"
  "summary loses order confirmations|       + (CASE WHEN flag.order_confirmation THEN 8 ELSE 0 END)|       + 0"
  "summary loses missing packages|       + (CASE WHEN NULLIF(btrim(history.package_size), '') IS NULL THEN 32 ELSE 0 END)|       + 0"
  "summary ignores mapped SKU identities|       OR COALESCE(mk.key_count, 0) > 1
|"
  "summary ignores unmapped lines without a SKU|      COALESCE(bool_or(k.no_sku_n > 0) FILTER (WHERE k.valid), false) AS missing_sku,|      false AS missing_sku,"
  "summary counts valid units as problems|      (COALESCE(sum(k.n) FILTER (WHERE k.valid AND NOT k.unit_valid), 0))::integer AS unit_problem_n|      (COALESCE(sum(k.n) FILTER (WHERE k.valid), 0))::integer AS unit_problem_n"
  "summary freshness at 181 days|      GREATEST(_today - p.dates[1], 0) <= 180 AS rep_fresh,|      GREATEST(_today - p.dates[1], 0) <= 181 AS rep_fresh,"
  "summary prior ignores the unit|        AND public.price_unit_key(p.units[2]) IS NOT DISTINCT FROM public.price_unit_key(p.units[1])
|"
  "summary increase on a stale anchor|      CASE WHEN s.state <> 'insufficient_identity' AND s.anchor_fresh AND s.anchor_unit_valid THEN CASE|      CASE WHEN s.state <> 'insufficient_identity' AND s.anchor_unit_valid THEN CASE"
  "summary malformed units are not identity problems|        WHEN p.multiple_skus OR p.missing_sku OR p.missing_unit OR p.malformed_unit THEN 'insufficient_identity'|        WHEN p.multiple_skus OR p.missing_sku OR p.missing_unit THEN 'insufficient_identity'"
  "summary stale anchor not marked|      (NOT d.anchor_fresh OR d.withheld IS NOT DISTINCT FROM 'stale') AS is_stale|      (d.withheld IS NOT DISTINCT FROM 'stale') AS is_stale"
  "summary lower-price signal on equal prices|      CASE WHEN f.numbers AND f.anchor_price > f.cheapest_price THEN 'lower_comparable_price_other_vendor' END,|      CASE WHEN f.numbers AND f.anchor_price >= f.cheapest_price THEN 'lower_comparable_price_other_vendor' END,"
)

python3 - "$migration" "$work/functions.sql" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
found = re.findall(r"(CREATE (?:OR REPLACE )?FUNCTION .*?\nAS (\$\$|\$function\$)\n.*?\n\2;)", text, re.S)
if len(found) != 21:
    sys.exit(f"expected the migration's 21 functions, found {len(found)}")
open(sys.argv[2], "w").write("\n".join(block for block, _ in found))
PY

build() {  # <spec or empty> <target> <suite>
  python3 - "$work/functions.sql" "$3" "$2" "$1" <<'PY'
import sys
functions, suite, target, spec = sys.argv[1:5]
text = open(functions).read()
if spec:
    parts = spec.split("|")
    if len(parts) % 2:
        sys.exit(f"mutation needs text|replacement pairs: {spec!r}")
    for needle, replacement in zip(parts[::2], parts[1::2]):
        needle = needle.replace("\\$", "$"); replacement = replacement.replace("\\$", "$")
        if needle not in text:
            sys.exit(f"mutation target not found: {needle!r}")
        text = text.replace(needle, replacement)
text = text.replace("CREATE FUNCTION", "CREATE OR REPLACE FUNCTION")
body = open(suite).read().replace("BEGIN;\n", "", 1).replace("\nROLLBACK;\n", "\n")
open(target, "w").write("BEGIN;\n" + text + "\n" + body + "\nROLLBACK;\n")
PY
}

# Control first: the unmutated functions pass every suite.
for suite in "${suites[@]}"; do
  build "" "$work/control.sql" "$suite"
  psql -q -v ON_ERROR_STOP=1 -d "$database" -f "$work/control.sql" >/dev/null || { echo "control run failed: $suite"; exit 1; }
done

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

if [ "$survived" -ne 0 ]; then
  echo "$survived mutant(s) survived"
  exit 1
fi
echo "all ${#mutants[@]} mutants killed; control passed"
