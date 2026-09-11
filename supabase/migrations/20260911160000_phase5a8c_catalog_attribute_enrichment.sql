-- Phase 5A.8C Catalog Attribute Enrichment:
-- Generalize source-backed specification recovery while preserving the
-- structured-variant-first rule and the established APS needle cleanup.

BEGIN;

CREATE OR REPLACE FUNCTION public.get_catalog_vendor_product_effective_specifications(
  _catalog_vendor_product_ids uuid[] DEFAULT NULL
)
RETURNS TABLE (
  catalog_vendor_product_id uuid,
  specification text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH eligible_products AS (
    SELECT
      catalog_vendor_product.id AS catalog_vendor_product_id,
      catalog_vendor_product.normalized_vendor_sku,
      catalog_product.name AS product_name
    FROM public.catalog_vendor_products catalog_vendor_product
    JOIN public.catalog_products catalog_product
      ON catalog_product.id = catalog_vendor_product.catalog_product_id
     AND catalog_product.active = true
     AND catalog_product.verification_status = 'verified'
    JOIN public.catalog_vendors catalog_vendor
      ON catalog_vendor.id = catalog_vendor_product.catalog_vendor_id
     AND catalog_vendor.active = true
    WHERE catalog_vendor_product.active = true
      AND catalog_vendor_product.discontinued = false
      AND catalog_vendor_product.verification_status = 'verified'
      AND (
        _catalog_vendor_product_ids IS NULL
        OR catalog_vendor_product.id = ANY(_catalog_vendor_product_ids)
      )
  ),
  structured_summary AS (
    SELECT
      eligible_product.catalog_vendor_product_id,
      pg_catalog.count(
        DISTINCT NULLIF(pg_catalog.btrim(source_record.raw_variant), '')
      ) AS distinct_specification_count,
      pg_catalog.min(
        NULLIF(pg_catalog.btrim(source_record.raw_variant), '')
      ) AS structured_specification
    FROM eligible_products eligible_product
    JOIN public.catalog_source_records source_record
      ON source_record.matched_catalog_vendor_product_id =
         eligible_product.catalog_vendor_product_id
     AND source_record.resolution_status IN ('matched', 'verified_match')
    GROUP BY eligible_product.catalog_vendor_product_id
  ),
  recovery_segments AS (
    SELECT
      eligible_product.catalog_vendor_product_id,
      eligible_product.product_name,
      pg_catalog.btrim(
        pg_catalog.regexp_replace(
          pg_catalog.regexp_replace(
            pg_catalog.left(
              source_record.raw_data -> 'fields' ->> 'Raw Product Block',
              pg_catalog.strpos(
                pg_catalog.upper(
                  source_record.raw_data -> 'fields' ->> 'Raw Product Block'
                ),
                '(' || eligible_product.normalized_vendor_sku || ')'
              ) - 1
            ),
            '[[:space:]]*[|][[:space:]]*$',
            ''
          ),
          '^.*[|]',
          ''
        )
      ) AS preceding_segment
    FROM eligible_products eligible_product
    JOIN structured_summary
      ON structured_summary.catalog_vendor_product_id =
         eligible_product.catalog_vendor_product_id
     AND structured_summary.distinct_specification_count = 0
    JOIN public.catalog_source_records source_record
      ON source_record.matched_catalog_vendor_product_id =
         eligible_product.catalog_vendor_product_id
     AND source_record.resolution_status IN ('matched', 'verified_match')
    WHERE source_record.raw_data -> 'fields' ->> 'Raw Product Block' IS NOT NULL
      AND eligible_product.normalized_vendor_sku <> ''
      AND pg_catalog.strpos(
        pg_catalog.upper(
          source_record.raw_data -> 'fields' ->> 'Raw Product Block'
        ),
        '(' || eligible_product.normalized_vendor_sku || ')'
      ) > 0
      AND (
        pg_catalog.length(
          pg_catalog.upper(
            source_record.raw_data -> 'fields' ->> 'Raw Product Block'
          )
        )
        - pg_catalog.length(
          pg_catalog.replace(
            pg_catalog.upper(
              source_record.raw_data -> 'fields' ->> 'Raw Product Block'
            ),
            '(' || eligible_product.normalized_vendor_sku || ')',
            ''
          )
        )
      ) / pg_catalog.length(
        '(' || eligible_product.normalized_vendor_sku || ')'
      ) = 1
  ),
  recovered_matches AS (
    SELECT
      recovery_segments.catalog_vendor_product_id,
      CASE
        -- Preserve the established APS cleanup: omit the manufacturer item
        -- number and expose only needle dimensions + tip color.
        WHEN recovery_segments.preceding_segment ~*
          '^#[[:alnum:]]+(-[[:alnum:]]+)+,[[:space:]]*[0-9]+[.][0-9]+[[:space:]]*[xX×][[:space:]]*[0-9]+([.][0-9]+)?[[:space:]]*mm,[[:space:]]*[[:alpha:]]+([[:space:]]+[[:alpha:]]+)*[[:space:]]+Tip$'
        THEN (
          pg_catalog.regexp_match(
            recovery_segments.preceding_segment,
            '^#[[:alnum:]]+(-[[:alnum:]]+)+,[[:space:]]*([0-9]+[.][0-9]+[[:space:]]*[xX×][[:space:]]*[0-9]+([.][0-9]+)?[[:space:]]*mm,[[:space:]]*[[:alpha:]]+([[:space:]]+[[:alpha:]]+)*[[:space:]]+Tip)$',
            'i'
          )
        )[2]

        -- General source-backed fallback. Only accept short, isolated
        -- specification-like segments and reject cross-SKU/prose contamination.
        WHEN recovery_segments.preceding_segment <> ''
         AND pg_catalog.length(recovery_segments.preceding_segment) <= 120
         AND recovery_segments.preceding_segment !~ '\([0-9]{3}-[0-9]{4}\)'
         AND recovery_segments.preceding_segment !~ '•'
         AND pg_catalog.lower(pg_catalog.btrim(recovery_segments.preceding_segment))
             <> pg_catalog.lower(pg_catalog.btrim(recovery_segments.product_name))
         AND pg_catalog.cardinality(
               pg_catalog.regexp_split_to_array(
                 pg_catalog.btrim(recovery_segments.preceding_segment),
                 '[[:space:]]+'
               )
             ) <= 18
        THEN recovery_segments.preceding_segment

        ELSE NULL
      END AS recovered_specification
    FROM recovery_segments
  ),
  recovered_summary AS (
    SELECT
      recovered_matches.catalog_vendor_product_id,
      pg_catalog.count(
        DISTINCT recovered_matches.recovered_specification
      ) FILTER (
        WHERE recovered_matches.recovered_specification IS NOT NULL
      ) AS distinct_specification_count,
      pg_catalog.min(
        recovered_matches.recovered_specification
      ) FILTER (
        WHERE recovered_matches.recovered_specification IS NOT NULL
      ) AS recovered_specification
    FROM recovered_matches
    GROUP BY recovered_matches.catalog_vendor_product_id
  ),
  effective AS (
    SELECT
      structured_summary.catalog_vendor_product_id,
      CASE
        WHEN structured_summary.distinct_specification_count = 1
          THEN structured_summary.structured_specification
        WHEN structured_summary.distinct_specification_count = 0
             AND recovered_summary.distinct_specification_count = 1
          THEN recovered_summary.recovered_specification
        ELSE NULL
      END AS specification
    FROM structured_summary
    LEFT JOIN recovered_summary
      ON recovered_summary.catalog_vendor_product_id =
         structured_summary.catalog_vendor_product_id
  )
  SELECT effective.catalog_vendor_product_id, effective.specification
  FROM effective
  WHERE effective.specification IS NOT NULL;
$$;

REVOKE ALL ON FUNCTION public.get_catalog_vendor_product_effective_specifications(uuid[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_catalog_vendor_product_effective_specifications(uuid[]) FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_catalog_vendor_product_effective_specifications(uuid[]) FROM authenticated;

COMMENT ON FUNCTION public.get_catalog_vendor_product_effective_specifications(uuid[]) IS
  'Internal effective-specification resolver: one trusted structured variant, otherwise conservative exact-SKU source-block recovery with APS-specific cleanup.';

COMMIT;
