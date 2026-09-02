-- Phase 5A.7 read-only deployment verification.
-- Run only after deploying 20260901120000_phase5a7_request_identity_and_search.sql.

WITH expected_columns(column_name, data_type, is_nullable) AS (
  VALUES
    ('inventory_item_id'::text, 'uuid'::text, 'YES'::text),
    ('vendor_product_id'::text, 'uuid'::text, 'YES'::text),
    ('catalog_vendor_product_id'::text, 'uuid'::text, 'YES'::text)
),
actual_columns AS (
  SELECT column_name, data_type, is_nullable
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'supply_request_items'
    AND column_name IN (SELECT column_name FROM expected_columns)
),
identity_constraint AS (
  SELECT pg_catalog.pg_get_constraintdef(constraint_definition.oid) AS definition
  FROM pg_catalog.pg_constraint constraint_definition
  WHERE constraint_definition.conrelid = 'public.supply_request_items'::pg_catalog.regclass
    AND constraint_definition.conname = 'supply_request_items_identity_check'
),
request_item_fks AS (
  SELECT
    constraint_definition.conname,
    pg_catalog.pg_get_constraintdef(constraint_definition.oid) AS definition
  FROM pg_catalog.pg_constraint constraint_definition
  WHERE constraint_definition.conrelid = 'public.supply_request_items'::pg_catalog.regclass
    AND constraint_definition.conname IN (
      'supply_request_items_inventory_org_fk',
      'supply_request_items_vendor_product_org_fk',
      'supply_request_items_catalog_vendor_product_fk'
    )
),
inventory_identity_index AS (
  SELECT
    index_definition.indisunique,
    index_definition.indisvalid,
    index_definition.indisready,
    pg_catalog.pg_get_indexdef(index_relation.oid) AS definition
  FROM pg_catalog.pg_class index_relation
  JOIN pg_catalog.pg_namespace index_namespace
    ON index_namespace.oid = index_relation.relnamespace
  JOIN pg_catalog.pg_index index_definition
    ON index_definition.indexrelid = index_relation.oid
  WHERE index_namespace.nspname = 'public'
    AND index_relation.relname = 'inventory_items_id_org_uq'
),
submission_rpc AS (
  SELECT
    procedure.oid,
    procedure.prosecdef,
    procedure.proconfig,
    pg_catalog.pg_get_functiondef(procedure.oid) AS definition
  FROM pg_catalog.pg_proc procedure
  WHERE procedure.oid = pg_catalog.to_regprocedure(
    'public.submit_supply_request(uuid,public.supply_request_type,uuid,uuid,text,jsonb)'
  )
),
search_rpc AS (
  SELECT
    procedure.oid,
    procedure.prosecdef,
    procedure.provolatile,
    procedure.proconfig,
    pg_catalog.pg_get_functiondef(procedure.oid) AS definition,
    pg_catalog.pg_get_function_result(procedure.oid) AS result_definition
  FROM pg_catalog.pg_proc procedure
  WHERE procedure.oid = pg_catalog.to_regprocedure(
    'public.search_supply_request_products(uuid,text,integer)'
  )
),
search_privileges AS (
  SELECT
    pg_catalog.has_function_privilege('authenticated', search_rpc.oid, 'EXECUTE')
      AS authenticated_can_execute,
    pg_catalog.has_function_privilege('anon', search_rpc.oid, 'EXECUTE')
      AS anon_can_execute,
    pg_catalog.has_function_privilege('public', search_rpc.oid, 'EXECUTE')
      AS public_can_execute
  FROM search_rpc
),
checks AS (
  SELECT
    'request_identity_columns_exact'::text AS check_name,
    (SELECT count(*) FROM actual_columns) = 3
      AND NOT EXISTS (
        SELECT 1
        FROM expected_columns expected
        LEFT JOIN actual_columns actual USING (column_name)
        WHERE actual.column_name IS NULL
          OR actual.data_type <> expected.data_type
          OR actual.is_nullable <> expected.is_nullable
      ) AS passed,
    COALESCE((
      SELECT pg_catalog.jsonb_agg(to_jsonb(actual_columns) ORDER BY column_name)::text
      FROM actual_columns
    ), 'missing') AS details

  UNION ALL

  SELECT
    'identity_check_custom_xor_structured',
    COALESCE((
      SELECT
        lower(definition) LIKE '%nullif(btrim(free_text_item), %is not null%'
        AND lower(definition) LIKE '%free_text_item is null%'
        AND lower(definition) LIKE '%product_id is not null%'
        AND lower(definition) LIKE '%inventory_item_id is not null%'
        AND lower(definition) LIKE '%vendor_product_id is not null%'
        AND lower(definition) LIKE '%catalog_vendor_product_id is not null%'
        AND lower(definition) LIKE '%product_id is null%'
        AND lower(definition) LIKE '%inventory_item_id is null%'
        AND lower(definition) LIKE '%vendor_product_id is null%'
        AND lower(definition) LIKE '%catalog_vendor_product_id is null%'
      FROM identity_constraint
    ), false),
    COALESCE((SELECT definition FROM identity_constraint), 'missing')

  UNION ALL

  SELECT
    'inventory_identity_composite_key_exact',
    COALESCE((
      SELECT
        indisunique
        AND indisvalid
        AND indisready
        AND definition =
          'CREATE UNIQUE INDEX inventory_items_id_org_uq ON public.inventory_items USING btree (id, organization_id)'
      FROM inventory_identity_index
    ), false),
    COALESCE((SELECT definition FROM inventory_identity_index), 'missing')

  UNION ALL

  SELECT
    'inventory_fk_organization_scoped_restrictive',
    COALESCE((
      SELECT definition ~
        '^FOREIGN KEY \(inventory_item_id, organization_id\) REFERENCES (public\.)?inventory_items\(id, organization_id\) ON DELETE RESTRICT$'
      FROM request_item_fks
      WHERE conname = 'supply_request_items_inventory_org_fk'
    ), false),
    COALESCE((
      SELECT definition FROM request_item_fks
      WHERE conname = 'supply_request_items_inventory_org_fk'
    ), 'missing')

  UNION ALL

  SELECT
    'vendor_product_fk_organization_scoped_restrictive',
    COALESCE((
      SELECT definition ~
        '^FOREIGN KEY \(vendor_product_id, organization_id\) REFERENCES (public\.)?vendor_products\(id, organization_id\) ON DELETE RESTRICT$'
      FROM request_item_fks
      WHERE conname = 'supply_request_items_vendor_product_org_fk'
    ), false),
    COALESCE((
      SELECT definition FROM request_item_fks
      WHERE conname = 'supply_request_items_vendor_product_org_fk'
    ), 'missing')

  UNION ALL

  SELECT
    'catalog_vendor_product_fk_global_restrictive',
    COALESCE((
      SELECT definition ~
        '^FOREIGN KEY \(catalog_vendor_product_id\) REFERENCES (public\.)?catalog_vendor_products\(id\) ON DELETE RESTRICT$'
      FROM request_item_fks
      WHERE conname = 'supply_request_items_catalog_vendor_product_fk'
    ), false),
    COALESCE((
      SELECT definition FROM request_item_fks
      WHERE conname = 'supply_request_items_catalog_vendor_product_fk'
    ), 'missing')

  UNION ALL

  SELECT
    'submission_signature_and_security_unchanged',
    COALESCE((
      SELECT prosecdef AND proconfig @> ARRAY['search_path=public']
      FROM submission_rpc
    ), false),
    'public.submit_supply_request(uuid,public.supply_request_type,uuid,uuid,text,jsonb)'

  UNION ALL

  SELECT
    'submission_supports_all_identity_inputs_and_legacy_inputs',
    COALESCE((
      SELECT
        definition LIKE '%inventoryItemId%'
        AND definition LIKE '%vendorProductId%'
        AND definition LIKE '%catalogVendorProductId%'
        AND definition LIKE '%productId%'
        AND definition LIKE '%freeTextItem%'
        AND definition LIKE '%_first_product_id%'
        AND definition LIKE '%_first_free_text%'
      FROM submission_rpc
    ), false),
    'new JSON keys plus product-only/free-text compatibility mirror'

  UNION ALL

  SELECT
    'submission_derives_and_validates_exact_relationships',
    COALESCE((
      SELECT
        definition LIKE '%_product_id := _inventory.product_id%'
        AND definition LIKE '%_product_id := _vendor_product.product_id%'
        AND definition LIKE
          '%_catalog_vendor_product_id := _vendor_product.catalog_vendor_product_id%'
        AND definition LIKE '%organization_id = _organization_id%'
        AND definition LIKE '%does not belong to the supplied product%'
        AND definition LIKE '%does not link to the supplied global catalog identity%'
        AND definition LIKE '%unproven global catalog identity%'
      FROM submission_rpc
    ), false),
    'inventory -> product; vendor product -> product -> exact global listing'

  UNION ALL

  SELECT
    'submission_global_only_active_without_adoption',
    COALESCE((
      SELECT
        definition LIKE '%catalog_vendor_product.active = true%'
        AND definition LIKE '%catalog_vendor_product.discontinued = false%'
        AND definition NOT LIKE '%adopt_catalog_vendor_product%'
        AND definition NOT LIKE '%stock_catalog_vendor_product%'
      FROM submission_rpc
    ), false),
    'active global identity is validated and stored without lifecycle mutation'

  UNION ALL

  SELECT
    'submission_mutation_allowlist_request_tables_only',
    COALESCE((
      SELECT
        definition ~* 'INSERT[[:space:]]+INTO[[:space:]]+public\.supply_requests'
        AND definition ~* 'INSERT[[:space:]]+INTO[[:space:]]+public\.supply_request_items'
        AND definition ~* 'UPDATE[[:space:]]+public\.supply_requests'
        AND definition !~* '(INSERT[[:space:]]+INTO|UPDATE|DELETE[[:space:]]+FROM)[[:space:]]+public\.(products|vendors|vendor_products|inventory_items|catalog_[a-z_]+)'
      FROM submission_rpc
    ), false),
    'only supply_requests and supply_request_items may be written'

  UNION ALL

  SELECT
    'search_exact_signature_stable_and_hardened',
    COALESCE((
      SELECT
        prosecdef
        AND provolatile = 's'
        AND proconfig @> ARRAY['search_path=public']
      FROM search_rpc
    ), false),
    COALESCE((SELECT result_definition FROM search_rpc), 'missing')

  UNION ALL

  SELECT
    'search_staff_safe_return_allowlist',
    COALESCE((
      SELECT
        result_definition LIKE '%result_key text%'
        AND result_definition LIKE '%identity_source text%'
        AND result_definition LIKE '%product_name text%'
        AND result_definition LIKE '%package_display text%'
        AND result_definition LIKE '%catalog_vendor_product_id uuid%'
        AND result_definition NOT LIKE '%provenance%'
        AND result_definition NOT LIKE '%override%'
        AND result_definition NOT LIKE '%source_uri%'
        AND result_definition NOT LIKE '%checksum%'
        AND result_definition NOT LIKE '%notes%'
      FROM search_rpc
    ), false),
    COALESCE((SELECT result_definition FROM search_rpc), 'missing')

  UNION ALL

  SELECT
    'search_auth_membership_before_candidates',
    COALESCE((
      SELECT
        pg_catalog.strpos(definition, 'auth.uid()') > 0
        AND pg_catalog.strpos(definition, 'organization_memberships') > 0
        AND pg_catalog.strpos(definition, 'organization_memberships') <
          pg_catalog.strpos(definition, 'global_candidates')
        AND definition LIKE '%membership.active = true%'
      FROM search_rpc
    ), false),
    'authenticated active organization membership precedes set-based search'

  UNION ALL

  SELECT
    'search_bounded_read_only_mutation_surface',
    COALESCE((
      SELECT
        definition LIKE '%LEAST(GREATEST(COALESCE(_limit, 20), 1), 50)%'
        AND definition LIKE '%LIMIT _bounded_limit%'
        AND definition !~* '\m(INSERT|UPDATE|DELETE|TRUNCATE|ALTER|DROP|GRANT|REVOKE|CALL)\M'
      FROM search_rpc
    ), false),
    'limit clamped to 1..50; no write statements'

  UNION ALL

  SELECT
    'search_package_trust_semantics',
    COALESCE((
      SELECT
        definition LIKE '%WHEN ''verified'' THEN concat_ws%package_quantity%package_unit%'
        AND definition LIKE '%WHEN ''source_only'' THEN COALESCE%package_description%'
        AND definition LIKE '%ELSE ''Unknown''%'
        AND definition NOT LIKE '%quantity::integer%package_quantity%'
      FROM search_rpc
    ), false),
    'verified structured display; source-only raw text; unknown remains unknown'

  UNION ALL

  SELECT
    'search_deterministic_ranking_and_identity_dedupe',
    COALESCE((
      SELECT
        definition LIKE '%candidate.organization_sku = _normalized_sku THEN 0%'
        AND definition LIKE '%candidate.global_sku = _normalized_sku THEN 1%'
        AND definition LIKE '%THEN 2%'
        AND definition LIKE '%THEN 4%'
        AND definition LIKE '%THEN 5%'
        AND definition LIKE '%PARTITION BY scored.identity_key%'
        AND definition LIKE '%deduplicated.identity_rank = 1%'
        AND definition LIKE '%organization-product:%'
        AND definition LIKE '%catalog-vendor-product:%'
        AND definition NOT LIKE '%vendor_sku_match_key%'
      FROM search_rpc
    ), false),
    'exact SKU before text; canonical-ID keys only; deterministic ordering'

  UNION ALL

  SELECT
    'search_acl_authenticated_only',
    COALESCE((
      SELECT authenticated_can_execute AND NOT anon_can_execute AND NOT public_can_execute
      FROM search_privileges
    ), false),
    COALESCE((
      SELECT pg_catalog.format(
        'authenticated=%s; anon=%s; PUBLIC=%s',
        authenticated_can_execute,
        anon_can_execute,
        public_can_execute
      )
      FROM search_privileges
    ), 'missing')
)
SELECT
  CASE WHEN pg_catalog.bool_and(passed) THEN 'PASS' ELSE 'FAIL' END AS status,
  pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'check', check_name,
      'passed', passed,
      'details', details
    )
    ORDER BY check_name
  ) AS checks
FROM checks;
