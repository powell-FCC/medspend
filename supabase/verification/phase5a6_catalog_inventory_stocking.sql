-- Phase 5A.6 read-only deployment verification.
-- Run only after deploying 20260831140000_phase5a6_catalog_inventory_stocking.sql.

WITH rpc AS (
  SELECT
    procedure.oid,
    procedure.prosecdef,
    procedure.proconfig,
    pg_catalog.pg_get_functiondef(procedure.oid) AS definition
  FROM pg_catalog.pg_proc procedure
  WHERE procedure.oid = pg_catalog.to_regprocedure(
    'public.stock_catalog_vendor_product(uuid,uuid,text,numeric)'
  )
),
rpc_execute_privileges AS (
  SELECT
    pg_catalog.has_function_privilege('authenticated', rpc.oid, 'EXECUTE') AS authenticated_can_execute,
    pg_catalog.has_function_privilege('anon', rpc.oid, 'EXECUTE') AS anon_can_execute,
    pg_catalog.has_function_privilege('public', rpc.oid, 'EXECUTE') AS public_can_execute
  FROM rpc
),
inventory_unique_index AS (
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
    AND index_relation.relname = 'inventory_items_org_product_uq'
),
inventory_product_fk AS (
  SELECT pg_catalog.pg_get_constraintdef(constraint_definition.oid) AS definition
  FROM pg_catalog.pg_constraint constraint_definition
  WHERE constraint_definition.conrelid = 'public.inventory_items'::pg_catalog.regclass
    AND constraint_definition.conname = 'inventory_items_product_org_fk'
),
checks AS (
  SELECT
    'rpc_exists_with_exact_signature'::text AS check_name,
    EXISTS (SELECT 1 FROM rpc) AS passed,
    'public.stock_catalog_vendor_product(uuid,uuid,text,numeric)'::text AS details

  UNION ALL

  SELECT
    'rpc_security_definer_and_search_path_hardened',
    COALESCE((SELECT prosecdef AND proconfig @> ARRAY['search_path=public'] FROM rpc), false),
    COALESCE((SELECT proconfig::text FROM rpc), 'missing')

  UNION ALL

  SELECT
    'rpc_owner_admin_authorization_precedes_lock',
    COALESCE((
      SELECT
        pg_catalog.strpos(definition, 'public.is_org_admin(_organization_id, auth.uid())') > 0
        AND pg_catalog.strpos(definition, 'public.is_org_admin(_organization_id, auth.uid())') <
          pg_catalog.strpos(definition, 'pg_advisory_xact_lock')
      FROM rpc
    ), false),
    'is_org_admin before product-scoped advisory lock'

  UNION ALL

  SELECT
    'inventory_org_product_unique_index_exact',
    COALESCE((
      SELECT
        indisunique
        AND indisvalid
        AND indisready
        AND definition =
          'CREATE UNIQUE INDEX inventory_items_org_product_uq ON public.inventory_items USING btree (organization_id, product_id) WHERE (product_id IS NOT NULL)'
      FROM inventory_unique_index
    ), false),
    COALESCE((SELECT definition FROM inventory_unique_index), 'missing')

  UNION ALL

  SELECT
    'inventory_product_fk_is_organization_scoped',
    COALESCE((
      SELECT definition ~
        '^FOREIGN KEY \(product_id, organization_id\) REFERENCES (public\.)?products\(id, organization_id\)'
      FROM inventory_product_fk
    ), false),
    COALESCE((SELECT definition FROM inventory_product_fk), 'missing')

  UNION ALL

  SELECT
    'rpc_requires_exact_adoption_chain',
    COALESCE((
      SELECT
        definition LIKE '%catalog_vendor_product_id = _catalog_vendor_product.id%'
        AND definition LIKE '%_organization_vendor.catalog_vendor_id IS DISTINCT FROM _catalog_vendor.id%'
        AND definition LIKE '%_organization_product.catalog_product_id IS DISTINCT FROM _catalog_product.id%'
      FROM rpc
    ), false),
    'organization vendor-product, vendor, and product links are validated'

  UNION ALL

  SELECT
    'rpc_mutation_allowlist_is_inventory_item_only',
    COALESCE((
      SELECT
        definition ~* 'INSERT[[:space:]]+INTO[[:space:]]+public\.inventory_items'
        AND definition !~* '(INSERT[[:space:]]+INTO|UPDATE|DELETE[[:space:]]+FROM)[[:space:]]+public\.(catalog_[a-z_]+|products|vendors|vendor_products|inventory_adjustments|inventory_price_history)'
      FROM rpc
    ), false),
    'only public.inventory_items may be written'

  UNION ALL

  SELECT
    'rpc_zero_quantity_no_movement_or_price_history',
    COALESCE((
      SELECT
        definition LIKE '%_inventory_unit,%0,%_par_level,%'
        AND definition NOT LIKE '%INSERT INTO public.inventory_adjustments%'
        AND definition NOT LIKE '%INSERT INTO public.inventory_price_history%'
        AND definition NOT LIKE '%_catalog_vendor_product.package_quantity%'
      FROM rpc
    ), false),
    'quantity=0; no adjustment, price history, or package-quantity inference'

  UNION ALL

  SELECT
    'rpc_package_trust_rules_preserved',
    COALESCE((
      SELECT
        definition LIKE '%package_status = ''verified''%package_unit%'
        AND definition LIKE '%ELSE _requested_unit%'
        AND definition LIKE '%explicit inventory unit is required for source-only or unknown packages%'
      FROM rpc
    ), false),
    'verified may supply unit; source-only and unknown require explicit unit'

  UNION ALL

  SELECT
    'rpc_discontinued_creation_blocked',
    COALESCE((
      SELECT
        definition LIKE '%_catalog_vendor_product.discontinued%'
        AND definition LIKE '%Inactive or discontinued catalog products cannot create new active inventory%'
      FROM rpc
    ), false),
    'new active inventory is blocked for inactive/discontinued identities'

  UNION ALL

  SELECT
    'authenticated_rpc_execute_only',
    COALESCE((
      SELECT authenticated_can_execute AND NOT anon_can_execute AND NOT public_can_execute
      FROM rpc_execute_privileges
    ), false),
    COALESCE((
      SELECT pg_catalog.format(
        'authenticated=%s; anon=%s; PUBLIC=%s',
        authenticated_can_execute,
        anon_can_execute,
        public_can_execute
      )
      FROM rpc_execute_privileges
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
