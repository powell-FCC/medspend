-- Phase 5A.8B: recover narrowly validated catalog specifications and make
-- request-product search useful for human-entered dimensions and attributes.
--
-- Catalog identity, adoption, and request submission semantics are unchanged.

BEGIN;

CREATE OR REPLACE FUNCTION public.normalize_catalog_search_text(_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = public
AS $$
  WITH quoted AS (
    SELECT pg_catalog.regexp_replace(
      pg_catalog.lower(COALESCE(_value, '')),
      '["“”″]+',
      ' inch ',
      'g'
    ) AS value
  ),
  metric_units AS (
    SELECT pg_catalog.regexp_replace(
      quoted.value,
      '([0-9])[[:space:]]*(mm|millimeters?|millimetres?)\y',
      '\1mm',
      'g'
    ) AS value
    FROM quoted
  ),
  inch_units AS (
    SELECT pg_catalog.regexp_replace(
      metric_units.value,
      '([0-9])[[:space:]]*(inches|inch|in)\y',
      '\1inch',
      'g'
    ) AS value
    FROM metric_units
  )
  SELECT pg_catalog.btrim(
    pg_catalog.regexp_replace(inch_units.value, '[^[:alnum:]]+', ' ', 'g')
  )
  FROM inch_units;
$$;

REVOKE ALL ON FUNCTION public.normalize_catalog_search_text(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.normalize_catalog_search_text(text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.normalize_catalog_search_text(text) FROM authenticated;

COMMENT ON FUNCTION public.normalize_catalog_search_text(text) IS
  'Search-only normalization for word-order-independent catalog retrieval, including conservative mm and inch equivalence.';

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
  WITH source_context AS (
    SELECT
      catalog_vendor_product.id AS catalog_vendor_product_id,
      NULLIF(pg_catalog.btrim(source_record.raw_variant), '') AS structured_specification,
      source_record.raw_data -> 'fields' ->> 'Raw Product Block' AS raw_product_block,
      catalog_vendor_product.normalized_vendor_sku
    FROM public.catalog_vendor_products catalog_vendor_product
    JOIN public.catalog_products catalog_product
      ON catalog_product.id = catalog_vendor_product.catalog_product_id
     AND catalog_product.active = true
     AND catalog_product.verification_status = 'verified'
    JOIN public.catalog_vendors catalog_vendor
      ON catalog_vendor.id = catalog_vendor_product.catalog_vendor_id
     AND catalog_vendor.active = true
    JOIN public.catalog_source_records source_record
      ON source_record.matched_catalog_vendor_product_id = catalog_vendor_product.id
     AND source_record.resolution_status IN ('matched', 'verified_match')
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
      source_context.catalog_vendor_product_id,
      pg_catalog.count(DISTINCT source_context.structured_specification) AS distinct_specification_count,
      pg_catalog.min(source_context.structured_specification) AS structured_specification
    FROM source_context
    GROUP BY source_context.catalog_vendor_product_id
  ),
  aps_segments AS (
    SELECT
      source_context.catalog_vendor_product_id,
      pg_catalog.btrim(
        pg_catalog.regexp_replace(
          pg_catalog.regexp_replace(
            pg_catalog.left(
              source_context.raw_product_block,
              pg_catalog.strpos(
                pg_catalog.upper(source_context.raw_product_block),
                '(' || source_context.normalized_vendor_sku || ')'
              ) - 1
            ),
            '[[:space:]]*[|][[:space:]]*$',
            ''
          ),
          '^.*[|]',
          ''
        )
      ) AS preceding_segment
    FROM source_context
    JOIN structured_summary
      ON structured_summary.catalog_vendor_product_id = source_context.catalog_vendor_product_id
     AND structured_summary.distinct_specification_count = 0
    WHERE source_context.raw_product_block IS NOT NULL
      AND source_context.normalized_vendor_sku <> ''
      AND pg_catalog.strpos(
        pg_catalog.upper(source_context.raw_product_block),
        '(' || source_context.normalized_vendor_sku || ')'
      ) > 0
      AND pg_catalog.left(
        source_context.raw_product_block,
        pg_catalog.strpos(
          pg_catalog.upper(source_context.raw_product_block),
          '(' || source_context.normalized_vendor_sku || ')'
        ) - 1
      ) ~ '[|][[:space:]]*$'
      AND (
        pg_catalog.length(pg_catalog.upper(source_context.raw_product_block))
        - pg_catalog.length(
          pg_catalog.replace(
            pg_catalog.upper(source_context.raw_product_block),
            '(' || source_context.normalized_vendor_sku || ')',
            ''
          )
        )
      ) / pg_catalog.length('(' || source_context.normalized_vendor_sku || ')') = 1
  ),
  aps_matches AS (
    SELECT
      aps_segments.catalog_vendor_product_id,
      (
        pg_catalog.regexp_match(
          aps_segments.preceding_segment,
          '^#[[:alnum:]]+(-[[:alnum:]]+)+,[[:space:]]*([0-9]+[.][0-9]+[[:space:]]*[xX×][[:space:]]*[0-9]+([.][0-9]+)?[[:space:]]*mm,[[:space:]]*[[:alpha:]]+([[:space:]]+[[:alpha:]]+)*[[:space:]]+Tip)$',
          'i'
        )
      )[2] AS recovered_specification
    FROM aps_segments
    WHERE aps_segments.preceding_segment ~* '^#[[:alnum:]]+(-[[:alnum:]]+)+,[[:space:]]*[0-9]+[.][0-9]+[[:space:]]*[xX×][[:space:]]*[0-9]+([.][0-9]+)?[[:space:]]*mm,[[:space:]]*[[:alpha:]]+([[:space:]]+[[:alpha:]]+)*[[:space:]]+Tip$'
  ),
  aps_summary AS (
    SELECT
      aps_matches.catalog_vendor_product_id,
      pg_catalog.count(DISTINCT aps_matches.recovered_specification) AS distinct_specification_count,
      pg_catalog.min(aps_matches.recovered_specification) AS recovered_specification
    FROM aps_matches
    GROUP BY aps_matches.catalog_vendor_product_id
  ),
  effective AS (
    SELECT
      structured_summary.catalog_vendor_product_id,
      CASE
        WHEN structured_summary.distinct_specification_count = 1
          THEN structured_summary.structured_specification
        WHEN structured_summary.distinct_specification_count = 0
             AND aps_summary.distinct_specification_count = 1
          THEN aps_summary.recovered_specification
        ELSE NULL
      END AS specification
    FROM structured_summary
    LEFT JOIN aps_summary
      ON aps_summary.catalog_vendor_product_id = structured_summary.catalog_vendor_product_id
  )
  SELECT effective.catalog_vendor_product_id, effective.specification
  FROM effective
  WHERE effective.specification IS NOT NULL;
$$;

REVOKE ALL ON FUNCTION public.get_catalog_vendor_product_effective_specifications(uuid[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_catalog_vendor_product_effective_specifications(uuid[]) FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_catalog_vendor_product_effective_specifications(uuid[]) FROM authenticated;

COMMENT ON FUNCTION public.get_catalog_vendor_product_effective_specifications(uuid[]) IS
  'Internal effective-specification resolver: one trusted structured variant, or the narrow exact-SKU APS product-block recovery rule.';

CREATE OR REPLACE FUNCTION public.get_supply_request_product_specifications(
  _organization_id uuid,
  _catalog_vendor_product_ids uuid[]
)
RETURNS TABLE (
  catalog_vendor_product_id uuid,
  specification text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid uuid := auth.uid();
BEGIN
  IF _uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;
  IF _organization_id IS NULL THEN
    RAISE EXCEPTION 'organization_id is required' USING ERRCODE = '22004';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.organization_memberships membership
    WHERE membership.organization_id = _organization_id
      AND membership.user_id = _uid
      AND membership.active = true
  ) THEN
    RAISE EXCEPTION 'Not a member of this organization' USING ERRCODE = '42501';
  END IF;
  IF COALESCE(pg_catalog.cardinality(_catalog_vendor_product_ids), 0) > 50 THEN
    RAISE EXCEPTION 'At most 50 catalog product specifications can be requested'
      USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT effective.catalog_vendor_product_id, effective.specification
  FROM public.get_catalog_vendor_product_effective_specifications(
    COALESCE(_catalog_vendor_product_ids, ARRAY[]::uuid[])
  ) effective;
END;
$$;

REVOKE ALL ON FUNCTION public.get_supply_request_product_specifications(uuid, uuid[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_supply_request_product_specifications(uuid, uuid[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_supply_request_product_specifications(uuid, uuid[]) TO authenticated;

COMMENT ON FUNCTION public.get_supply_request_product_specifications(uuid, uuid[]) IS
  'Returns trustworthy effective catalog specifications for up to 50 product IDs to an active organization member.';

CREATE OR REPLACE FUNCTION public.search_supply_request_products(
  _organization_id uuid,
  _query text,
  _limit integer DEFAULT 20
)
RETURNS TABLE (
  result_key text,
  identity_source text,
  product_name text,
  manufacturer text,
  vendor_name text,
  vendor_sku text,
  package_display text,
  package_status text,
  inventory_item_id uuid,
  product_id uuid,
  vendor_product_id uuid,
  catalog_vendor_product_id uuid
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid uuid := auth.uid();
  _raw_query text := pg_catalog.btrim(COALESCE(_query, ''));
  _normalized_text text;
  _normalized_sku text;
  _tokens text[];
  _bounded_limit integer := LEAST(GREATEST(COALESCE(_limit, 20), 1), 50);
BEGIN
  IF _uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;
  IF _organization_id IS NULL THEN
    RAISE EXCEPTION 'organization_id is required' USING ERRCODE = '22004';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.organization_memberships membership
    WHERE membership.organization_id = _organization_id
      AND membership.user_id = _uid
      AND membership.active = true
  ) THEN
    RAISE EXCEPTION 'Not a member of this organization' USING ERRCODE = '42501';
  END IF;
  IF pg_catalog.length(_raw_query) > 120 THEN
    RAISE EXCEPTION 'Search query cannot exceed 120 characters' USING ERRCODE = '22001';
  END IF;
  IF _raw_query = '' THEN
    RETURN;
  END IF;

  _normalized_text := public.normalize_catalog_search_text(_raw_query);
  _normalized_sku := public.normalize_catalog_sku(_raw_query);
  _tokens := pg_catalog.regexp_split_to_array(_normalized_text, '[[:space:]]+');

  RETURN QUERY
  WITH effective_specifications AS (
    SELECT effective.catalog_vendor_product_id, effective.specification
    FROM public.get_catalog_vendor_product_effective_specifications(NULL) effective
  ),
  organization_adoptions AS (
    SELECT
      organization_vendor_product.id AS vendor_product_id,
      organization_vendor_product.product_id,
      organization_vendor_product.catalog_vendor_product_id,
      organization_vendor_product.vendor_sku,
      organization_vendor_product.manufacturer_sku,
      organization_vendor_product.package_size,
      organization_product.name AS product_name,
      organization_product.normalized_name,
      organization_product.manufacturer,
      organization_product.description,
      organization_product.pack_size,
      organization_vendor.name AS vendor_name,
      inventory.id AS inventory_item_id
    FROM public.vendor_products organization_vendor_product
    JOIN public.products organization_product
      ON organization_product.id = organization_vendor_product.product_id
     AND organization_product.organization_id = organization_vendor_product.organization_id
     AND organization_product.active = true
     AND organization_product.staff_requestable = true
    JOIN public.vendors organization_vendor
      ON organization_vendor.id = organization_vendor_product.vendor_id
     AND organization_vendor.organization_id = organization_vendor_product.organization_id
     AND organization_vendor.active = true
    LEFT JOIN public.inventory_items inventory
      ON inventory.organization_id = organization_vendor_product.organization_id
     AND inventory.product_id = organization_vendor_product.product_id
     AND inventory.active = true
    WHERE organization_vendor_product.organization_id = _organization_id
      AND organization_vendor_product.active = true
      AND organization_vendor_product.catalog_vendor_product_id IS NOT NULL
  ),
  global_candidates AS (
    SELECT
      CASE
        WHEN adoption.product_id IS NOT NULL
          THEN 'organization-product:' || adoption.product_id::text
        ELSE 'catalog-vendor-product:' || catalog_vendor_product.id::text
      END AS identity_key,
      CASE
        WHEN adoption.inventory_item_id IS NOT NULL THEN 'inventory'
        WHEN adoption.vendor_product_id IS NOT NULL THEN 'organization_catalog'
        ELSE 'global_catalog'
      END AS identity_source,
      COALESCE(adoption.product_name, catalog_product.name) AS product_name,
      COALESCE(adoption.manufacturer, catalog_product.manufacturer) AS manufacturer,
      COALESCE(adoption.vendor_name, catalog_vendor.name) AS vendor_name,
      catalog_vendor_product.vendor_sku,
      CASE catalog_vendor_product.package_status
        WHEN 'verified' THEN pg_catalog.concat_ws(
          ' ',
          catalog_vendor_product.package_quantity::text,
          catalog_vendor_product.package_unit
        )
        WHEN 'source_only' THEN COALESCE(
          catalog_vendor_product.package_description,
          'Source package text unavailable'
        )
        ELSE 'Unknown'
      END AS package_display,
      catalog_vendor_product.package_status,
      adoption.inventory_item_id,
      adoption.product_id,
      adoption.vendor_product_id,
      catalog_vendor_product.id AS catalog_vendor_product_id,
      public.normalize_catalog_sku(adoption.vendor_sku) AS organization_sku,
      catalog_vendor_product.normalized_vendor_sku AS global_sku,
      COALESCE(adoption.normalized_name, catalog_product.normalized_name) AS primary_name,
      catalog_product.normalized_name AS alternate_name,
      public.normalize_catalog_search_text(
        pg_catalog.concat_ws(' ', adoption.product_name, catalog_product.name)
      ) AS product_search,
      public.normalize_catalog_search_text(
        pg_catalog.concat_ws(
          ' ',
          adoption.product_name,
          catalog_product.name,
          adoption.manufacturer,
          catalog_product.manufacturer,
          adoption.vendor_name,
          catalog_vendor.name,
          adoption.description,
          catalog_product.description,
          adoption.vendor_sku,
          adoption.manufacturer_sku,
          catalog_vendor_product.vendor_sku,
          catalog_vendor_product.manufacturer_sku,
          adoption.package_size,
          adoption.pack_size,
          catalog_vendor_product.package_description,
          catalog_vendor_product.package_quantity::text,
          catalog_vendor_product.package_unit,
          effective_specification.specification
        )
      ) AS search_text,
      CASE
        WHEN adoption.inventory_item_id IS NOT NULL THEN 0
        WHEN adoption.vendor_product_id IS NOT NULL THEN 1
        ELSE 3
      END AS source_priority
    FROM public.catalog_vendor_products catalog_vendor_product
    JOIN public.catalog_products catalog_product
      ON catalog_product.id = catalog_vendor_product.catalog_product_id
     AND catalog_product.active = true
    JOIN public.catalog_vendors catalog_vendor
      ON catalog_vendor.id = catalog_vendor_product.catalog_vendor_id
     AND catalog_vendor.active = true
    LEFT JOIN organization_adoptions adoption
      ON adoption.catalog_vendor_product_id = catalog_vendor_product.id
    LEFT JOIN effective_specifications effective_specification
      ON effective_specification.catalog_vendor_product_id = catalog_vendor_product.id
    WHERE catalog_vendor_product.active = true
      AND catalog_vendor_product.discontinued = false
  ),
  local_vendor_candidates AS (
    SELECT
      'organization-product:' || organization_product.id::text AS identity_key,
      CASE
        WHEN inventory.id IS NOT NULL THEN 'inventory'
        ELSE 'organization_catalog'
      END AS identity_source,
      organization_product.name AS product_name,
      organization_product.manufacturer,
      organization_vendor.name AS vendor_name,
      organization_vendor_product.vendor_sku,
      'Unknown'::text AS package_display,
      'unknown'::text AS package_status,
      inventory.id AS inventory_item_id,
      organization_product.id AS product_id,
      organization_vendor_product.id AS vendor_product_id,
      NULL::uuid AS catalog_vendor_product_id,
      public.normalize_catalog_sku(organization_vendor_product.vendor_sku) AS organization_sku,
      NULL::text AS global_sku,
      organization_product.normalized_name AS primary_name,
      NULL::text AS alternate_name,
      public.normalize_catalog_search_text(organization_product.name) AS product_search,
      public.normalize_catalog_search_text(
        pg_catalog.concat_ws(
          ' ',
          organization_product.name,
          organization_product.manufacturer,
          organization_product.description,
          organization_product.pack_size,
          organization_product.vendor_item_number,
          organization_product.internal_item_code,
          organization_vendor.name,
          organization_vendor_product.vendor_sku,
          organization_vendor_product.manufacturer_sku,
          organization_vendor_product.package_size,
          organization_vendor_product.unit_of_measure
        )
      ) AS search_text,
      CASE WHEN inventory.id IS NOT NULL THEN 0 ELSE 1 END AS source_priority
    FROM public.vendor_products organization_vendor_product
    JOIN public.products organization_product
      ON organization_product.id = organization_vendor_product.product_id
     AND organization_product.organization_id = organization_vendor_product.organization_id
     AND organization_product.active = true
     AND organization_product.staff_requestable = true
    JOIN public.vendors organization_vendor
      ON organization_vendor.id = organization_vendor_product.vendor_id
     AND organization_vendor.organization_id = organization_vendor_product.organization_id
     AND organization_vendor.active = true
    LEFT JOIN public.inventory_items inventory
      ON inventory.organization_id = organization_product.organization_id
     AND inventory.product_id = organization_product.id
     AND inventory.active = true
    WHERE organization_vendor_product.organization_id = _organization_id
      AND organization_vendor_product.active = true
      AND organization_vendor_product.catalog_vendor_product_id IS NULL
  ),
  local_product_candidates AS (
    SELECT
      'organization-product:' || organization_product.id::text AS identity_key,
      CASE
        WHEN inventory.id IS NOT NULL THEN 'inventory'
        ELSE 'organization_product'
      END AS identity_source,
      organization_product.name AS product_name,
      organization_product.manufacturer,
      NULL::text AS vendor_name,
      NULL::text AS vendor_sku,
      'Unknown'::text AS package_display,
      'unknown'::text AS package_status,
      inventory.id AS inventory_item_id,
      organization_product.id AS product_id,
      NULL::uuid AS vendor_product_id,
      NULL::uuid AS catalog_vendor_product_id,
      public.normalize_catalog_sku(
        COALESCE(organization_product.vendor_item_number, organization_product.internal_item_code)
      ) AS organization_sku,
      NULL::text AS global_sku,
      organization_product.normalized_name AS primary_name,
      NULL::text AS alternate_name,
      public.normalize_catalog_search_text(organization_product.name) AS product_search,
      public.normalize_catalog_search_text(
        pg_catalog.concat_ws(
          ' ',
          organization_product.name,
          organization_product.manufacturer,
          organization_product.description,
          organization_product.pack_size,
          organization_product.vendor_item_number,
          organization_product.internal_item_code,
          organization_product.unit_of_measure
        )
      ) AS search_text,
      CASE WHEN inventory.id IS NOT NULL THEN 0 ELSE 2 END AS source_priority
    FROM public.products organization_product
    LEFT JOIN public.inventory_items inventory
      ON inventory.organization_id = organization_product.organization_id
     AND inventory.product_id = organization_product.id
     AND inventory.active = true
    WHERE organization_product.organization_id = _organization_id
      AND organization_product.active = true
      AND organization_product.staff_requestable = true
  ),
  unlinked_inventory_candidates AS (
    SELECT
      'inventory:' || inventory.id::text AS identity_key,
      'inventory'::text AS identity_source,
      inventory.name AS product_name,
      inventory.manufacturer,
      inventory.vendor_name,
      inventory.sku AS vendor_sku,
      'Unknown'::text AS package_display,
      'unknown'::text AS package_status,
      inventory.id AS inventory_item_id,
      NULL::uuid AS product_id,
      NULL::uuid AS vendor_product_id,
      NULL::uuid AS catalog_vendor_product_id,
      public.normalize_catalog_sku(inventory.sku) AS organization_sku,
      NULL::text AS global_sku,
      public.normalize_catalog_search_text(inventory.name) AS primary_name,
      NULL::text AS alternate_name,
      public.normalize_catalog_search_text(inventory.name) AS product_search,
      public.normalize_catalog_search_text(
        pg_catalog.concat_ws(
          ' ',
          inventory.name,
          inventory.manufacturer,
          inventory.vendor_name,
          inventory.sku,
          inventory.description,
          inventory.category,
          inventory.unit_of_measure
        )
      ) AS search_text,
      0 AS source_priority
    FROM public.inventory_items inventory
    WHERE inventory.organization_id = _organization_id
      AND inventory.active = true
      AND inventory.product_id IS NULL
  ),
  candidates AS (
    SELECT * FROM global_candidates
    UNION ALL
    SELECT * FROM local_vendor_candidates
    UNION ALL
    SELECT * FROM local_product_candidates
    UNION ALL
    SELECT * FROM unlinked_inventory_candidates
  ),
  scored AS (
    SELECT
      candidate.*,
      CASE
        WHEN _normalized_sku <> ''
             AND candidate.organization_sku = _normalized_sku THEN 0
        WHEN _normalized_sku <> ''
             AND candidate.global_sku = _normalized_sku THEN 1
        WHEN _normalized_text <> ''
             AND (
               candidate.primary_name = _normalized_text
               OR candidate.alternate_name = _normalized_text
             ) THEN 2
        WHEN _normalized_sku <> ''
             AND (
               pg_catalog.strpos(COALESCE(candidate.organization_sku, ''), _normalized_sku) > 0
               OR pg_catalog.strpos(COALESCE(candidate.global_sku, ''), _normalized_sku) > 0
             ) THEN 3
        WHEN _normalized_text <> ''
             AND pg_catalog.strpos(candidate.product_search, _normalized_text) > 0 THEN 4
        WHEN _normalized_text <> ''
             AND NOT EXISTS (
               SELECT 1
               FROM pg_catalog.unnest(_tokens) token
               WHERE pg_catalog.strpos(candidate.product_search, token) = 0
             ) THEN 5
        WHEN _normalized_text <> ''
             AND NOT EXISTS (
               SELECT 1
               FROM pg_catalog.unnest(_tokens) token
               WHERE pg_catalog.strpos(candidate.search_text, token) = 0
             ) THEN 6
        ELSE 99
      END AS match_rank
    FROM candidates candidate
  ),
  deduplicated AS (
    SELECT
      scored.*,
      pg_catalog.row_number() OVER (
        PARTITION BY scored.identity_key
        ORDER BY
          scored.match_rank,
          scored.source_priority,
          scored.catalog_vendor_product_id NULLS LAST,
          scored.vendor_product_id NULLS LAST,
          scored.inventory_item_id NULLS LAST,
          pg_catalog.lower(scored.product_name),
          COALESCE(scored.vendor_sku, ''),
          scored.identity_key
      ) AS identity_rank
    FROM scored
    WHERE scored.match_rank < 99
  )
  SELECT
    deduplicated.identity_key,
    deduplicated.identity_source,
    deduplicated.product_name,
    deduplicated.manufacturer,
    deduplicated.vendor_name,
    deduplicated.vendor_sku,
    deduplicated.package_display,
    deduplicated.package_status,
    deduplicated.inventory_item_id,
    deduplicated.product_id,
    deduplicated.vendor_product_id,
    deduplicated.catalog_vendor_product_id
  FROM deduplicated
  WHERE deduplicated.identity_rank = 1
  ORDER BY
    deduplicated.match_rank,
    deduplicated.source_priority,
    pg_catalog.lower(deduplicated.product_name),
    COALESCE(deduplicated.vendor_name, ''),
    COALESCE(deduplicated.vendor_sku, ''),
    deduplicated.identity_key
  LIMIT _bounded_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.search_supply_request_products(uuid, text, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.search_supply_request_products(uuid, text, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.search_supply_request_products(uuid, text, integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_catalog_vendor_product_admin_detail(
  _organization_id uuid,
  _catalog_vendor_product_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _detail jsonb;
BEGIN
  IF _organization_id IS NULL OR _catalog_vendor_product_id IS NULL THEN
    RAISE EXCEPTION 'organization_id and catalog_vendor_product_id are required'
      USING ERRCODE = '22004';
  END IF;

  IF NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Only organization owners and admins can view catalog provenance'
      USING ERRCODE = '42501';
  END IF;

  SELECT pg_catalog.jsonb_build_object(
    'catalogVendorProductId', catalog_vendor_product.id,
    'effectiveSpecification', effective_specification.specification,
    'product', pg_catalog.jsonb_build_object(
      'id', catalog_product.id,
      'name', catalog_product.name,
      'manufacturer', catalog_product.manufacturer,
      'description', catalog_product.description,
      'active', catalog_product.active,
      'verificationStatus', catalog_product.verification_status
    ),
    'vendor', pg_catalog.jsonb_build_object(
      'id', catalog_vendor.id,
      'name', catalog_vendor.name,
      'website', catalog_vendor.website,
      'active', catalog_vendor.active,
      'vendorSku', catalog_vendor_product.vendor_sku,
      'normalizedVendorSku', catalog_vendor_product.normalized_vendor_sku,
      'manufacturerSku', catalog_vendor_product.manufacturer_sku
    ),
    'package', pg_catalog.jsonb_build_object(
      'rawDescription', catalog_vendor_product.package_description,
      'verifiedQuantity', CASE
        WHEN catalog_vendor_product.package_status = 'verified'
          THEN catalog_vendor_product.package_quantity
        ELSE NULL
      END,
      'verifiedUnit', CASE
        WHEN catalog_vendor_product.package_status = 'verified'
          THEN catalog_vendor_product.package_unit
        ELSE NULL
      END,
      'status', catalog_vendor_product.package_status
    ),
    'lifecycle', pg_catalog.jsonb_build_object(
      'active', catalog_vendor_product.active,
      'discontinued', catalog_vendor_product.discontinued,
      'verificationStatus', catalog_vendor_product.verification_status
    ),
    'provenance', COALESCE(
      (
        SELECT pg_catalog.jsonb_agg(
          pg_catalog.jsonb_build_object(
            'sourceName', import_batch.source_name,
            'sourceVersion', import_batch.source_version,
            'sourcePage', source_record.source_page,
            'rawVendorSku', source_record.raw_vendor_sku,
            'rawProductName', source_record.raw_product_name,
            'rawVariant', source_record.raw_variant,
            'rawPackage', source_record.raw_package
          )
          ORDER BY import_batch.created_at DESC, source_record.source_ordinal
        )
        FROM public.catalog_source_records source_record
        JOIN public.catalog_import_batches import_batch
          ON import_batch.id = source_record.import_batch_id
         AND import_batch.catalog_vendor_id = source_record.catalog_vendor_id
        WHERE source_record.matched_catalog_vendor_product_id = catalog_vendor_product.id
      ),
      '[]'::jsonb
    ),
    'verificationOverrides', COALESCE(
      (
        SELECT pg_catalog.jsonb_agg(
          pg_catalog.jsonb_build_object(
            'overrideType', verification_override.override_type,
            'evidenceStatus', verification_override.evidence_status,
            'productionRule', verification_override.production_rule,
            'sourceVendorSku', verification_override.source_vendor_sku,
            'verifiedVendorSku', verification_override.verified_vendor_sku,
            'effectiveFrom', verification_override.effective_from,
            'sourceName', import_batch.source_name,
            'sourceVersion', import_batch.source_version
          )
          ORDER BY verification_override.effective_from DESC, verification_override.id
        )
        FROM public.catalog_verification_overrides verification_override
        LEFT JOIN public.catalog_import_batches import_batch
          ON import_batch.id = verification_override.import_batch_id
         AND import_batch.catalog_vendor_id = verification_override.catalog_vendor_id
        WHERE verification_override.catalog_vendor_product_id = catalog_vendor_product.id
          AND verification_override.active
          AND (
            verification_override.effective_to IS NULL
            OR verification_override.effective_to > pg_catalog.now()
          )
      ),
      '[]'::jsonb
    )
  )
  INTO _detail
  FROM public.catalog_vendor_products catalog_vendor_product
  JOIN public.catalog_products catalog_product
    ON catalog_product.id = catalog_vendor_product.catalog_product_id
  JOIN public.catalog_vendors catalog_vendor
    ON catalog_vendor.id = catalog_vendor_product.catalog_vendor_id
  LEFT JOIN public.get_catalog_vendor_product_effective_specifications(
    ARRAY[_catalog_vendor_product_id]
  ) effective_specification
    ON effective_specification.catalog_vendor_product_id = catalog_vendor_product.id
  WHERE catalog_vendor_product.id = _catalog_vendor_product_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Catalog vendor product % does not exist', _catalog_vendor_product_id
      USING ERRCODE = 'P0002';
  END IF;

  RETURN _detail;
END;
$$;

REVOKE ALL ON FUNCTION public.get_catalog_vendor_product_admin_detail(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_catalog_vendor_product_admin_detail(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_catalog_vendor_product_admin_detail(uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.get_catalog_vendor_product_admin_detail(uuid, uuid) IS
  'Returns sanitized global catalog identity, effective specification, source provenance, and active verification decisions for one organization owner/admin.';

COMMIT;
