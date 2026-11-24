#!/usr/bin/env bash
# Phase 7F.1A mutation check. Proves the behavior suite fails when a safety rule of the
# migration is removed or weakened. Disposable databases only: never point this at
# production.
#
# Usage:
#   supabase/tests/phase7f1a_mutation_check.sh <template_database>
#
# <template_database> must have every migration BEFORE
# 20261125120000_phase7f1a_core_catalog_foundation.sql applied and no open connections
# (create it with CREATE DATABASE <name> TEMPLATE postgres on a disposable stack). For
# each mutant the script creates a database from the template, applies the mutated
# migration, runs the suite and drops the database. Connection settings come from the
# standard PGHOST/PGPORT/PGUSER/PGPASSWORD variables; the user needs CREATEDB.
# A mutant only counts as killed when a suite check fails ("Check N failed"), never on a
# syntax or setup error.
#
# Not mutated, because no reachable state can observe them (documented, defense in depth):
#   * the exact-SKU UNION branches of global_hits: an exact SKU is also in the listing's
#     search document, so they only make the lookup an index probe; tier 1 is decided
#     from the candidate's SKUs, not from the branch that found it;
#   * the "cardinality(...) > 0" short-circuit in global_hits: with no enabled catalog
#     vendor, "= ANY('{}')" already excludes every listing; the short-circuit only skips
#     the scan (see the benchmark in supabase/release/phase7f1a/README.md).
set -euo pipefail

template="${1:?usage: $0 <template_database>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
migration="$root/supabase/migrations/20261125120000_phase7f1a_core_catalog_foundation.sql"
suite="$root/supabase/tests/phase7f1a_core_catalog_foundation_behavior.sql"
work="$(mktemp -d)"
db="phase7f1a_mutant_$$"
trap 'psql -q -d postgres -c "DROP DATABASE IF EXISTS $db" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

# name | exact text in the migration | replacement [| more text | replacement ...]
mutants=(
  "search scope removed|    WHERE pg_catalog.cardinality(_enabled_catalog_vendor_ids) > 0
      AND scoped_listing.catalog_vendor_id = ANY(_enabled_catalog_vendor_ids)|    WHERE true"
  "search scope uses every organization's vendors|  FROM public.vendors organization_vendor
  WHERE organization_vendor.organization_id = _organization_id
    AND organization_vendor.active = true|  FROM public.vendors organization_vendor
  WHERE organization_vendor.active = true"
  "search scope accepts an inactive linked vendor|  WHERE organization_vendor.organization_id = _organization_id
    AND organization_vendor.active = true
    AND organization_vendor.catalog_vendor_id IS NOT NULL;|  WHERE organization_vendor.organization_id = _organization_id
    AND organization_vendor.catalog_vendor_id IS NOT NULL;"
  "discovery scope ignores which catalog vendor|         AND organization_vendor.catalog_vendor_id = catalog_vendor.id|         AND organization_vendor.catalog_vendor_id IS NOT NULL"
  "discovery scope uses every organization's vendors|     -- Phase 7F.1A: only catalog vendors this organization uses.
     AND EXISTS (
       SELECT 1 FROM public.vendors organization_vendor
       WHERE organization_vendor.organization_id = _organization_id|     AND EXISTS (
       SELECT 1 FROM public.vendors organization_vendor
       WHERE true"
  "search typo tier renumbered|pattern WHERE candidate.search_text !~ pattern) THEN 7|pattern WHERE candidate.search_text !~ pattern) THEN 6"
  "search result column changed (vendor name)|      COALESCE(adoption.vendor_name, catalog_vendor.name) AS vendor_name,
      catalog_vendor_product.vendor_sku,
      CASE catalog_vendor_product.package_status
        WHEN 'verified' THEN pg_catalog.concat_ws(
|      COALESCE(adoption.vendor_name, catalog_vendor_product.vendor_sku) AS vendor_name,
      catalog_vendor_product.vendor_sku,
      CASE catalog_vendor_product.package_status
        WHEN 'verified' THEN pg_catalog.concat_ws(
"
  "concepts inferred from product names|COMMENT ON TABLE public.catalog_product_concepts IS|CREATE FUNCTION public.mutant_concept_by_name() RETURNS trigger LANGUAGE plpgsql AS \$m\$
BEGIN
  INSERT INTO public.catalog_product_concepts (catalog_product_id, concept_id, assignment_source, rule_key)
  SELECT NEW.id, concept.id, 'deterministic_rule', 'name.match'
  FROM public.catalog_concepts concept WHERE concept.normalized_name = NEW.normalized_name
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END \$m\$;
CREATE TRIGGER mutant_concept_by_name AFTER INSERT OR UPDATE ON public.catalog_products
  FOR EACH ROW EXECUTE FUNCTION public.mutant_concept_by_name();
COMMENT ON TABLE public.catalog_product_concepts IS"
  "duplicate normalized concepts allowed|,
  CONSTRAINT catalog_concepts_normalized_name_uq UNIQUE (normalized_name)|"
  "duplicate normalized brands allowed|,
  CONSTRAINT catalog_brands_normalized_name_uq UNIQUE (normalized_name)|"
  "duplicate synonyms within a concept allowed|,
  CONSTRAINT catalog_concept_synonyms_concept_synonym_uq UNIQUE (concept_id, normalized_synonym)|"
  "duplicate families within a brand allowed|,
  CONSTRAINT catalog_product_families_brand_name_uq UNIQUE NULLS NOT DISTINCT (brand_id, normalized_name)|"
  "brandless families never collide|UNIQUE NULLS NOT DISTINCT (brand_id, normalized_name)|UNIQUE (brand_id, normalized_name)"
  "imported concept link without provenance|    assignment_source <> 'imported' OR import_batch_id IS NOT NULL|    true"
  "rule concept link without a rule key|    (assignment_source = 'deterministic_rule') = (rule_key IS NOT NULL)|    true"
  "certification without product linkage|  catalog_product_id uuid NOT NULL REFERENCES public.catalog_products(id) ON DELETE CASCADE,
  certification_code|  catalog_product_id uuid REFERENCES public.catalog_products(id) ON DELETE CASCADE,
  certification_code"
  "certification without evidence|    import_batch_id IS NOT NULL
    OR source_record_id IS NOT NULL
    OR NULLIF(pg_catalog.btrim(evidence_url), '') IS NOT NULL|    true
    OR NULLIF(pg_catalog.btrim(evidence_url), '') IS NOT NULL"
  "certification without verified_at|  verified_at timestamptz NOT NULL,|  verified_at timestamptz,"
  "two active certifications of one type|CREATE UNIQUE INDEX catalog_product_certifications_active_uq|CREATE INDEX catalog_product_certifications_active_uq"
  "certification in attributes allowed|ARRAY['certification', 'certifications', 'certified']|ARRAY['unused_key']"
  "brand MPN made unique|CREATE INDEX catalog_products_brand_mpn_idx|CREATE UNIQUE INDEX catalog_products_brand_mpn_idx"
  "GTIN made unique|CREATE INDEX catalog_products_gtin_idx|CREATE UNIQUE INDEX catalog_products_gtin_idx"
  "MPN without a brand allowed|  ADD CONSTRAINT catalog_products_mpn_requires_brand CHECK (normalized_mpn IS NULL OR brand_id IS NOT NULL),|"
  "bundle may be a single product|    FOREIGN KEY (bundle_catalog_product_id, bundle_kind)
    REFERENCES public.catalog_products (id, product_kind) ON UPDATE RESTRICT ON DELETE CASCADE,|    FOREIGN KEY (bundle_catalog_product_id)
    REFERENCES public.catalog_products (id) ON DELETE CASCADE,"
  "empty bundle component allowed|    component_catalog_product_id IS NOT NULL OR NULLIF(pg_catalog.btrim(component_text), '') IS NOT NULL|    true"
  "purchase restriction unchecked|    purchase_restriction IN ('none', 'licensed_professional', 'prescription', 'restricted', 'unknown')|    true"
  "purchase restriction defaults to none|  ADD COLUMN purchase_restriction text NOT NULL DEFAULT 'unknown',|  ADD COLUMN purchase_restriction text NOT NULL DEFAULT 'none',"
  "availability without an observation time|    (availability_status IS NULL) = (availability_observed_at IS NULL)|    true"
  "last seen batch of another catalog vendor|    FOREIGN KEY (last_seen_batch_id, catalog_vendor_id)
    REFERENCES public.catalog_import_batches (id, catalog_vendor_id) ON DELETE RESTRICT,|    FOREIGN KEY (last_seen_batch_id)
    REFERENCES public.catalog_import_batches (id) ON DELETE RESTRICT,"
  "authenticated may write brands|CREATE POLICY catalog_brands_authenticated_select
  ON public.catalog_brands FOR SELECT TO authenticated USING (true);|GRANT INSERT, UPDATE, DELETE ON public.catalog_brands TO authenticated;
CREATE POLICY catalog_brands_authenticated_select
  ON public.catalog_brands FOR ALL TO authenticated USING (true) WITH CHECK (true);"
  "authenticated may forge certifications|CREATE POLICY catalog_product_certifications_authenticated_select
  ON public.catalog_product_certifications FOR SELECT TO authenticated USING (true);|GRANT INSERT, UPDATE ON public.catalog_product_certifications TO authenticated;
CREATE POLICY catalog_product_certifications_authenticated_select
  ON public.catalog_product_certifications FOR ALL TO authenticated USING (true) WITH CHECK (true);"
  "authenticated may assign concepts|CREATE POLICY catalog_product_concepts_authenticated_select
  ON public.catalog_product_concepts FOR SELECT TO authenticated USING (true);|GRANT INSERT, DELETE ON public.catalog_product_concepts TO authenticated;
CREATE POLICY catalog_product_concepts_authenticated_select
  ON public.catalog_product_concepts FOR ALL TO authenticated USING (true) WITH CHECK (true);"
  "concepts left without RLS and open to clients|CREATE POLICY catalog_concepts_authenticated_select
  ON public.catalog_concepts FOR SELECT TO authenticated USING (true);|ALTER TABLE public.catalog_concepts DISABLE ROW LEVEL SECURITY;
GRANT ALL ON public.catalog_concepts TO authenticated, anon;"
  "anon may read global facts|GRANT SELECT ON TABLE
  public.catalog_brands, public.catalog_product_families, public.catalog_concepts,|GRANT SELECT ON public.catalog_concepts TO anon;
GRANT SELECT ON TABLE
  public.catalog_brands, public.catalog_product_families, public.catalog_concepts,"
  "service_role write removed|GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE
  public.catalog_brands,|GRANT SELECT ON TABLE
  public.catalog_brands,"
  "internal search exposed to authenticated|REVOKE ALL ON FUNCTION public.supply_request_product_search(uuid, text, integer) FROM anon, authenticated;|GRANT EXECUTE ON FUNCTION public.supply_request_product_search(uuid, text, integer) TO anon, authenticated;"
)

mutate() {
  python3 - "$migration" "$work/mutant.sql" "$1" <<'PY'
import sys
source, target, spec = sys.argv[1:4]
text = open(source).read()
parts = spec.split("|")[1:]
assert len(parts) % 2 == 0, "mutant spec needs text/replacement pairs"
for old, new in zip(parts[0::2], parts[1::2]):
    if text.count(old) != 1:
        sys.exit(f"mutant text found {text.count(old)} times: {old[:80]!r}")
    text = text.replace(old, new)
open(target, "w").write(text)
PY
}

run_mutant() {
  local name="$1" sql="$2"
  psql -q -d postgres -c "DROP DATABASE IF EXISTS $db" >/dev/null
  psql -q -d postgres -c "CREATE DATABASE $db TEMPLATE $template" >/dev/null
  if ! psql -q -v ON_ERROR_STOP=1 -d "$db" -f "$sql" >/dev/null 2>"$work/err"; then
    echo "SETUP ERROR - $name: $(grep -m1 -o 'ERROR: .*' "$work/err" | head -c 160)"
    return 2
  fi
  psql -q -v ON_ERROR_STOP=1 -d "$db" -o /dev/null -f "$suite" >/dev/null 2>"$work/err" || true
  psql -q -d postgres -c "DROP DATABASE IF EXISTS $db" >/dev/null
}

# The unmutated migration must pass the suite.
run_mutant "unmutated" "$migration"
if grep -q 'ERROR' "$work/err"; then
  echo "FAIL - the unmutated migration fails the suite: $(grep -m1 -o 'ERROR: .*' "$work/err")"
  exit 1
fi
echo "ok - unmutated migration passes the suite"

total=0
survived=0
for spec in "${mutants[@]}"; do
  name="${spec%%|*}"
  total=$((total + 1))
  mutate "$spec"
  if ! run_mutant "$name" "$work/mutant.sql"; then
    survived=$((survived + 1))
    continue
  fi
  if grep -q 'Check [0-9]*[a-z]* failed' "$work/err"; then
    echo "KILLED - $name: $(grep -m1 -o 'Check [0-9]*[a-z]* failed[^:]*' "$work/err")"
  else
    echo "SURVIVED - $name: $(grep -m1 -o 'ERROR: .*' "$work/err" | head -c 160)"
    survived=$((survived + 1))
  fi
done

echo "$((total - survived))/$total mutants killed"
[ "$survived" -eq 0 ]
