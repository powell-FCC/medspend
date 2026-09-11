-- Phase 5A.8B production hotfix:
-- inventory_items.unit_of_measure was renamed to unit in Phase 2C.

BEGIN;

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
          inventory.unit
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

COMMIT;
