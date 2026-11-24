#!/usr/bin/env python3
"""Phase 7F.1A benchmark helper: turn the reviewed Henry Schein v28 dry-run artifacts
(outputs/catalog/henry-schein/v28, untracked) into SQL that loads the real 9,059-listing
catalog into a DISPOSABLE database. IDs are md5 of the artifact's logical keys, so two
databases loaded from the same artifacts hold identical rows. Never run against production.

Usage: phase7f1a_henry_schein_fixture.py <artifact_dir>  > fixture.sql
"""
import csv
import json
import sys

directory = sys.argv[1]


def copy_line(record):
    text = json.dumps(record, ensure_ascii=False)
    return text.replace("\\", "\\\\")


out = sys.stdout
out.write("BEGIN;\nCREATE TEMP TABLE phase7f1a_hs_stage (kind text, doc jsonb);\n")
out.write("COPY phase7f1a_hs_stage (kind, doc) FROM STDIN;\n")
vendor = json.load(open(f"{directory}/catalog_vendor.json"))
out.write("vendor\t" + copy_line(vendor) + "\n")
batch = json.load(open(f"{directory}/import_batch.json"))
out.write("batch\t" + copy_line(batch) + "\n")
with open(f"{directory}/catalog_products.csv", newline="") as handle:
    for row in csv.DictReader(handle):
        out.write("product\t" + copy_line(row) + "\n")
with open(f"{directory}/catalog_vendor_products.csv", newline="") as handle:
    for row in csv.DictReader(handle):
        out.write("listing\t" + copy_line(row) + "\n")
with open(f"{directory}/catalog_source_records.jsonl") as handle:
    for line in handle:
        out.write("source\t" + copy_line(json.loads(line)) + "\n")
out.write("\\.\n")
out.write(r"""
INSERT INTO public.catalog_vendors (id, name, normalized_name, website, domain, active)
SELECT md5(doc->>'catalog_vendor_key')::uuid, doc->>'name', doc->>'normalized_name', doc->>'website', doc->>'domain', true
FROM phase7f1a_hs_stage WHERE kind = 'vendor';

INSERT INTO public.catalog_import_batches (id, catalog_vendor_id, source_name, source_version, artifact_name,
  artifact_sha256, status, raw_record_count, unique_key_count, matched_record_count, warning_count, metadata,
  started_at, completed_at)
SELECT md5(doc->>'import_batch_key')::uuid, md5(doc->>'catalog_vendor_key')::uuid, doc->>'source_name',
  doc->>'source_version', doc->>'artifact_name', doc->>'artifact_sha256', 'completed',
  (doc->>'raw_record_count')::integer, (doc->>'unique_key_count')::integer,
  (doc->>'matched_record_count')::integer, (doc->>'warning_count')::integer, doc->'metadata', now(), now()
FROM phase7f1a_hs_stage WHERE kind = 'batch';

INSERT INTO public.catalog_products (id, name, normalized_name, description, manufacturer, active, verification_status)
SELECT md5(doc->>'product_key')::uuid, doc->>'name', doc->>'normalized_name', NULLIF(doc->>'description', ''),
  NULLIF(doc->>'manufacturer', ''), (doc->>'active')::boolean, doc->>'verification_status'
FROM phase7f1a_hs_stage WHERE kind = 'product';

INSERT INTO public.catalog_vendor_products (id, catalog_product_id, catalog_vendor_id, vendor_sku, normalized_vendor_sku,
  manufacturer_sku, package_description, package_quantity, package_unit, package_status, currency_code, active,
  discontinued, verification_status)
SELECT md5(doc->>'vendor_product_key')::uuid, md5(doc->>'catalog_product_key')::uuid, md5(doc->>'catalog_vendor_key')::uuid,
  doc->>'vendor_sku', doc->>'normalized_vendor_sku', NULLIF(doc->>'manufacturer_sku', ''),
  NULLIF(doc->>'package_description', ''), NULLIF(doc->>'package_quantity', '')::numeric,
  NULLIF(doc->>'package_unit', ''), doc->>'package_status', NULLIF(doc->>'currency_code', ''),
  (doc->>'active')::boolean, (doc->>'discontinued')::boolean, doc->>'verification_status'
FROM phase7f1a_hs_stage WHERE kind = 'listing';

-- Source records in chunks of 500 ordinals, as the production importer writes them: each
-- statement's search-document refresh then covers at most 500 listings.
DO $load$
DECLARE _first integer;
BEGIN
  FOR _first IN SELECT generate_series(1, (SELECT max((doc->>'source_ordinal')::integer) FROM phase7f1a_hs_stage WHERE kind = 'source'), 500) LOOP
    INSERT INTO public.catalog_source_records (id, import_batch_id, catalog_vendor_id, source_ordinal, raw_vendor_sku,
      raw_product_name, raw_category, raw_subsection, raw_variant, raw_package, source_page, raw_data,
      matched_catalog_vendor_product_id, resolution_status, resolved_at)
    SELECT md5(doc->>'source_record_key')::uuid, md5(doc->>'import_batch_key')::uuid, md5(doc->>'catalog_vendor_key')::uuid,
      (doc->>'source_ordinal')::integer, doc->>'raw_vendor_sku', doc->>'raw_product_name', doc->>'raw_category',
      doc->>'raw_subsection', doc->>'raw_variant', doc->>'raw_package', doc->>'source_page', doc->'raw_data',
      md5(doc->>'matched_catalog_vendor_product_key')::uuid, doc->>'resolution_status',
      CASE WHEN doc->>'resolution_status' <> 'pending' THEN now() END
    FROM phase7f1a_hs_stage WHERE kind = 'source'
          AND (doc->>'source_ordinal')::integer BETWEEN _first AND _first + 499;
  END LOOP;
END
$load$;
COMMIT;
""")
