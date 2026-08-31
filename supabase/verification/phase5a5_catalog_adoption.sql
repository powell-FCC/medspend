-- Phase 5A.5 deployment verification (read-only).
-- Run after deploying 20260827120000_phase5a5_catalog_adoption.sql and
-- 20260831120000_phase5a5_rpc_privilege_hardening.sql.
-- Every row should return passed = true.

WITH
expected_indexes(index_name, expected_definition) AS (
  VALUES
    (
      'vendors_org_catalog_vendor_uq',
      'CREATE UNIQUE INDEX vendors_org_catalog_vendor_uq ON public.vendors USING btree (organization_id, catalog_vendor_id) WHERE (catalog_vendor_id IS NOT NULL)'
    ),
    (
      'products_org_catalog_product_uq',
      'CREATE UNIQUE INDEX products_org_catalog_product_uq ON public.products USING btree (organization_id, catalog_product_id) WHERE (catalog_product_id IS NOT NULL)'
    ),
    (
      'vendor_products_org_catalog_vendor_product_uq',
      'CREATE UNIQUE INDEX vendor_products_org_catalog_vendor_product_uq ON public.vendor_products USING btree (organization_id, catalog_vendor_product_id) WHERE (catalog_vendor_product_id IS NOT NULL)'
    )
),
index_checks AS (
  SELECT
    'index_' || expected.index_name AS check_name,
    coalesce(
      count(index_relation.oid) = 1
        AND bool_and(index_metadata.indisunique)
        AND bool_and(index_metadata.indisvalid)
        AND bool_and(index_metadata.indisready)
        AND bool_and(
          regexp_replace(
            pg_catalog.pg_get_indexdef(index_relation.oid),
            '[[:space:]]+',
            ' ',
            'g'
          ) = expected.expected_definition
        ),
      false
    ) AS passed,
    coalesce(
      max(pg_catalog.pg_get_indexdef(index_relation.oid)),
      'missing'
    ) AS details
  FROM expected_indexes expected
  LEFT JOIN pg_catalog.pg_class index_relation
    ON index_relation.relname::text = expected.index_name
   AND index_relation.relkind = 'i'
   AND index_relation.relnamespace = pg_catalog.to_regnamespace('public')
  LEFT JOIN pg_catalog.pg_index index_metadata
    ON index_metadata.indexrelid = index_relation.oid
  GROUP BY expected.index_name, expected.expected_definition
),
rpc AS (
  SELECT
    procedure.oid,
    procedure.prosecdef,
    procedure.proconfig,
    procedure.proowner,
    pg_catalog.pg_get_functiondef(procedure.oid) AS definition
  FROM pg_catalog.pg_proc procedure
  WHERE procedure.oid = pg_catalog.to_regprocedure(
    'public.adopt_catalog_vendor_product(uuid,uuid)'
  )
),
rpc_execute_privileges AS (
  SELECT
    coalesce(
      pg_catalog.has_function_privilege('authenticated', rpc.oid, 'EXECUTE'),
      false
    ) AS authenticated_can_execute,
    coalesce(
      pg_catalog.has_function_privilege('anon', rpc.oid, 'EXECUTE'),
      false
    ) AS anon_can_execute,
    coalesce(
      pg_catalog.has_function_privilege('public', rpc.oid, 'EXECUTE'),
      false
    ) AS public_can_execute
  FROM rpc
),
trigger_functions AS (
  SELECT
    procedure.oid,
    procedure.proname::text AS proname,
    procedure.prosecdef,
    procedure.proconfig,
    procedure.proowner,
    pg_catalog.pg_get_functiondef(procedure.oid) AS definition
  FROM pg_catalog.pg_proc procedure
  JOIN pg_catalog.pg_namespace namespace
    ON namespace.oid = procedure.pronamespace
  WHERE namespace.nspname::text = 'public'
    AND procedure.proname::text IN (
      'validate_vendor_product_catalog_link',
      'validate_catalog_parent_link_change'
    )
),
expected_triggers(
  trigger_name,
  table_name,
  function_signature,
  includes_insert,
  required_columns
) AS (
  VALUES
    (
      'vendor_products_validate_catalog_link',
      'vendor_products',
      'public.validate_vendor_product_catalog_link()',
      true,
      ARRAY[
        'catalog_vendor_product_id',
        'organization_id',
        'product_id',
        'vendor_id'
      ]::text[]
    ),
    (
      'vendors_validate_catalog_link_change',
      'vendors',
      'public.validate_catalog_parent_link_change()',
      false,
      ARRAY['catalog_vendor_id']::text[]
    ),
    (
      'products_validate_catalog_link_change',
      'products',
      'public.validate_catalog_parent_link_change()',
      false,
      ARRAY['catalog_product_id']::text[]
    ),
    (
      'catalog_vendor_products_validate_parent_link_change',
      'catalog_vendor_products',
      'public.validate_catalog_parent_link_change()',
      false,
      ARRAY['catalog_product_id', 'catalog_vendor_id']::text[]
    )
),
trigger_checks AS (
  SELECT
    'trigger_' || expected.trigger_name AS check_name,
    coalesce(
      count(trigger.oid) = 1
        AND bool_and(trigger.tgenabled = 'O')
        AND bool_and(
          trigger.tgfoid = pg_catalog.to_regprocedure(expected.function_signature)
        )
        AND bool_and(
          (trigger.tgtype & 1) = 1
          AND (trigger.tgtype & 2) = 2
          AND (trigger.tgtype & 16) = 16
          AND ((trigger.tgtype & 4) = 4) = expected.includes_insert
          AND (trigger.tgtype & 8) = 0
          AND (trigger.tgtype & 32) = 0
        )
        AND bool_and(
          ARRAY(
            SELECT attribute.attname::text
            FROM unnest(trigger.tgattr::smallint[]) AS trigger_column(column_number)
            JOIN pg_catalog.pg_attribute attribute
              ON attribute.attrelid = trigger.tgrelid
             AND attribute.attnum = trigger_column.column_number
            ORDER BY attribute.attname::text
          ) = expected.required_columns
        ),
      false
    ) AS passed,
    coalesce(max(pg_catalog.pg_get_triggerdef(trigger.oid)), 'missing') AS details
  FROM expected_triggers expected
  LEFT JOIN pg_catalog.pg_class table_relation
    ON table_relation.relname::text = expected.table_name
   AND table_relation.relnamespace = pg_catalog.to_regnamespace('public')
  LEFT JOIN pg_catalog.pg_trigger trigger
    ON trigger.tgrelid = table_relation.oid
   AND trigger.tgname::text = expected.trigger_name
   AND NOT trigger.tgisinternal
  GROUP BY
    expected.trigger_name,
    expected.function_signature,
    expected.includes_insert,
    expected.required_columns
),
local_write_policy_checks AS (
  SELECT
    table_name,
    row_security,
    admin_policy_count
  FROM (
    SELECT
      table_relation.relname::text AS table_name,
      table_relation.relrowsecurity AS row_security,
      (
        SELECT count(*)
        FROM pg_catalog.pg_policy policy
        WHERE policy.polrelid = table_relation.oid
          AND policy.polcmd = '*'
          AND pg_catalog.pg_get_expr(policy.polqual, policy.polrelid)
            LIKE '%is_org_admin%'
          AND pg_catalog.pg_get_expr(policy.polwithcheck, policy.polrelid)
            LIKE '%is_org_admin%'
      ) AS admin_policy_count
    FROM pg_catalog.pg_class table_relation
    JOIN pg_catalog.pg_namespace table_namespace
      ON table_namespace.oid = table_relation.relnamespace
    WHERE table_namespace.nspname::text = 'public'
      AND table_relation.relname::text IN ('vendors', 'products', 'vendor_products')
  ) policies
),
rpc_mutation_targets AS (
  SELECT DISTINCT lower(mutation_match[2]) AS table_name
  FROM rpc
  CROSS JOIN LATERAL pg_catalog.regexp_matches(
    definition,
    '(INSERT[[:space:]]+INTO|UPDATE|DELETE[[:space:]]+FROM)[[:space:]]+public\.([a-z_]+)',
    'gi'
  ) mutation_match
),
phase5a5_fixture_residue(table_name, fixture_rows) AS (
  SELECT 'auth.users', count(*)
  FROM auth.users
  WHERE id IN (
      '5a5a0000-0000-4000-8000-000000000001'::uuid,
      '5a5a0000-0000-4000-8000-000000000002'::uuid,
      '5a5a0000-0000-4000-8000-000000000003'::uuid
    )
    OR email IN (
      'phase5a5-admin@example.invalid',
      'phase5a5-staff@example.invalid',
      'phase5a5-other-owner@example.invalid'
    )

  UNION ALL

  SELECT 'public.profiles', count(*)
  FROM public.profiles
  WHERE id IN (
    '5a5a0000-0000-4000-8000-000000000001'::uuid,
    '5a5a0000-0000-4000-8000-000000000002'::uuid,
    '5a5a0000-0000-4000-8000-000000000003'::uuid
  )

  UNION ALL

  SELECT 'public.organizations', count(*)
  FROM public.organizations
  WHERE id IN (
      '5a5a0000-0000-4000-8000-000000000101'::uuid,
      '5a5a0000-0000-4000-8000-000000000102'::uuid
    )
    OR name IN (
      'Phase 5A.5 Adoption Organization',
      'Phase 5A.5 Other Organization'
    )

  UNION ALL

  SELECT 'public.organization_memberships', count(*)
  FROM public.organization_memberships
  WHERE id BETWEEN
      '5a5a0000-0000-4000-8000-000000000601'::uuid AND
      '5a5a0000-0000-4000-8000-000000000603'::uuid
    OR organization_id IN (
      '5a5a0000-0000-4000-8000-000000000101'::uuid,
      '5a5a0000-0000-4000-8000-000000000102'::uuid
    )
    OR user_id IN (
      '5a5a0000-0000-4000-8000-000000000001'::uuid,
      '5a5a0000-0000-4000-8000-000000000002'::uuid,
      '5a5a0000-0000-4000-8000-000000000003'::uuid
    )

  UNION ALL

  SELECT 'public.catalog_vendors', count(*)
  FROM public.catalog_vendors
  WHERE id = '5a5a0000-0000-4000-8000-000000000201'::uuid
    OR normalized_name = 'phase 5a 5 behavioral vendor'

  UNION ALL

  SELECT 'public.catalog_products', count(*)
  FROM public.catalog_products
  WHERE id BETWEEN
      '5a5a0000-0000-4000-8000-000000000301'::uuid AND
      '5a5a0000-0000-4000-8000-000000000306'::uuid
    OR normalized_name IN (
      'phase 5a 5 verified package product',
      'phase 5a 5 source package product',
      'phase 5a 5 unknown package product',
      'phase 5a 5 discontinued product',
      'phase 5a 5 conflict target product',
      'phase 5a 5 existing local identity'
    )

  UNION ALL

  SELECT 'public.catalog_vendor_products', count(*)
  FROM public.catalog_vendor_products
  WHERE id BETWEEN
      '5a5a0000-0000-4000-8000-000000000401'::uuid AND
      '5a5a0000-0000-4000-8000-000000000405'::uuid
    OR normalized_vendor_sku IN (
      'TEST-VERIFIED',
      'TEST-SOURCE',
      'TEST-UNKNOWN',
      'TEST-DISCONTINUED',
      'TEST-CONFLICT'
    )

  UNION ALL

  SELECT 'public.vendors', count(*)
  FROM public.vendors
  WHERE id = '5a5a0000-0000-4000-8000-000000000503'::uuid
    OR organization_id IN (
      '5a5a0000-0000-4000-8000-000000000101'::uuid,
      '5a5a0000-0000-4000-8000-000000000102'::uuid
    )
    OR normalized_name = 'phase 5a 5 unauthorized direct vendor'

  UNION ALL

  SELECT 'public.products', count(*)
  FROM public.products
  WHERE id = '5a5a0000-0000-4000-8000-000000000501'::uuid
    OR organization_id IN (
      '5a5a0000-0000-4000-8000-000000000101'::uuid,
      '5a5a0000-0000-4000-8000-000000000102'::uuid
    )
    OR normalized_name = 'phase 5a 5 conflicting local product'

  UNION ALL

  SELECT 'public.vendor_products', count(*)
  FROM public.vendor_products
  WHERE id = '5a5a0000-0000-4000-8000-000000000502'::uuid
    OR organization_id IN (
      '5a5a0000-0000-4000-8000-000000000101'::uuid,
      '5a5a0000-0000-4000-8000-000000000102'::uuid
    )
    OR vendor_sku IN (
      'TEST-VERIFIED',
      'TEST-SOURCE',
      'TEST-UNKNOWN',
      'TEST-DISCONTINUED',
      'TEST-CONFLICT'
    )

  UNION ALL

  SELECT 'public.inventory_items', count(*)
  FROM public.inventory_items
  WHERE organization_id IN (
    '5a5a0000-0000-4000-8000-000000000101'::uuid,
    '5a5a0000-0000-4000-8000-000000000102'::uuid
  )
),
checks(check_name, passed, details) AS (
  SELECT check_name, passed, details FROM index_checks

  UNION ALL

  SELECT
    'phase5a5_behavioral_fixture_rows_absent',
    coalesce(sum(fixture_rows), 0) = 0,
    string_agg(
      table_name || '=' || fixture_rows::text,
      ', '
      ORDER BY table_name
    )
  FROM phase5a5_fixture_residue

  UNION ALL

  SELECT
    'rpc_exists_with_exact_signature',
    pg_catalog.to_regprocedure(
      'public.adopt_catalog_vendor_product(uuid,uuid)'
    ) IS NOT NULL,
    coalesce(
      pg_catalog.to_regprocedure(
        'public.adopt_catalog_vendor_product(uuid,uuid)'
      )::text,
      'missing'
    )

  UNION ALL

  SELECT
    'rpc_security_definer_intended',
    coalesce((SELECT prosecdef FROM rpc), false),
    coalesce((SELECT 'security_definer=' || prosecdef::text FROM rpc), 'missing')

  UNION ALL

  SELECT
    'rpc_search_path_hardened',
    coalesce(
      (SELECT proconfig = ARRAY['search_path=public']::text[] FROM rpc),
      false
    ),
    coalesce((SELECT array_to_string(proconfig, ',') FROM rpc), 'missing')

  UNION ALL

  SELECT
    'security_definer_schema_not_client_writable',
    NOT pg_catalog.has_schema_privilege('authenticated', 'public', 'CREATE')
      AND NOT pg_catalog.has_schema_privilege('anon', 'public', 'CREATE')
      AND NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_namespace namespace
        CROSS JOIN LATERAL pg_catalog.aclexplode(
          coalesce(
            namespace.nspacl,
            pg_catalog.acldefault('n', namespace.nspowner)
          )
        ) acl
        WHERE namespace.nspname::text = 'public'
          AND acl.grantee = 0
          AND acl.privilege_type = 'CREATE'
      ),
    'authenticated, anon, and PUBLIC cannot create objects in the fixed public search_path'

  UNION ALL

  SELECT
    'rpc_owner_admin_authorization_precedes_lock',
    coalesce(
      (
        SELECT
          strpos(definition, 'public.is_org_admin(_organization_id, auth.uid())') > 0
          AND strpos(definition, 'USING ERRCODE = ''42501''') > 0
          AND strpos(definition, 'public.is_org_admin(_organization_id, auth.uid())')
            < strpos(definition, 'pg_advisory_xact_lock')
        FROM rpc
      ),
      false
    ),
    'is_org_admin(auth.uid()) must reject before locking or writing'

  UNION ALL

  SELECT
    'rpc_organization_scoped',
    coalesce(
      (
        SELECT
          definition LIKE '%organization_id = _organization_id%'
          AND definition LIKE '%VALUES (%_organization_id,%'
          AND definition LIKE '%''organizationId'', _organization_id%'
        FROM rpc
      ),
      false
    ),
    'all organization lookups/inserts and the response use _organization_id'

  UNION ALL

  SELECT
    'rpc_advisory_lock_is_organization_scoped',
    coalesce(
      (
        SELECT definition LIKE
          '%pg_advisory_xact_lock(%hashtextextended(''catalog-adoption:'' || _organization_id::text, 0)%'
        FROM rpc
      ),
      false
    ),
    'transaction advisory lock derives from catalog-adoption:<organization uuid>'

  UNION ALL

  SELECT
    'rpc_exact_idempotent_reuse',
    coalesce(
      (
        SELECT
          definition LIKE '%catalog_vendor_product_id = _catalog_vendor_product.id%'
          AND definition LIKE '%_already_adopted := FOUND%'
          AND definition LIKE '%''alreadyAdopted'', true%'
          AND definition LIKE '%catalog_vendor_id = _catalog_vendor.id%'
          AND definition LIKE '%catalog_product_id = _catalog_product.id%'
          AND definition LIKE
            '%lower(btrim(vendor_sku)) = lower(btrim(_catalog_vendor_product.vendor_sku))%'
        FROM rpc
      ),
      false
    ),
    'catalog links are preferred and exact normalized local vendor SKU reuse is explicit'

  UNION ALL

  SELECT
    'rpc_verified_package_rule',
    coalesce(
      (
        SELECT
          definition LIKE '%package_status = ''verified''%'
          AND definition LIKE '%THEN _catalog_vendor_product.package_unit%'
          AND definition LIKE '%ELSE NULL%'
        FROM rpc
      ),
      false
    ),
    'package_unit is copied only for verified package rows'

  UNION ALL

  SELECT
    'rpc_never_touches_inventory',
    coalesce(
      (SELECT definition !~* '\m(INSERT[[:space:]]+INTO|UPDATE|DELETE[[:space:]]+FROM)[[:space:]]+(public\.)?inventory' FROM rpc),
      false
    ),
    'RPC definition contains no inventory mutation target'

  UNION ALL

  SELECT
    'rpc_mutation_allowlist_exact',
    coalesce(
      (
        SELECT array_agg(table_name ORDER BY table_name) =
          ARRAY['products', 'vendor_products', 'vendors']::text[]
        FROM rpc_mutation_targets
      ),
      false
    ),
    coalesce(
      (SELECT array_to_string(array_agg(table_name ORDER BY table_name), ', ') FROM rpc_mutation_targets),
      'none'
    )

  UNION ALL

  SELECT
    'rpc_global_catalog_is_read_only',
    coalesce(
      (
        SELECT definition !~* '\m(INSERT[[:space:]]+INTO|UPDATE|DELETE[[:space:]]+FROM)[[:space:]]+public\.catalog_'
        FROM rpc
      ),
      false
    ),
    'RPC definition contains no global catalog mutation target'

  UNION ALL

  SELECT
    'trigger_functions_are_invoker_and_search_path_hardened',
    coalesce(
      (
        SELECT
          count(*) = 2
          AND bool_and(NOT prosecdef)
          AND bool_and(proconfig = ARRAY['search_path=public']::text[])
        FROM trigger_functions
      ),
      false
    ),
    'both consistency trigger functions must be invoker functions with search_path=public'

  UNION ALL

  SELECT
    'trigger_functions_cover_parent_consistency',
    coalesce(
      (
        SELECT
          bool_and(
            CASE proname
              WHEN 'validate_vendor_product_catalog_link' THEN
                definition LIKE '%catalog_vendor_id = _catalog_vendor_id%'
                AND definition LIKE '%catalog_product_id = _catalog_product_id%'
              WHEN 'validate_catalog_parent_link_change' THEN
                definition LIKE '%TG_TABLE_NAME = ''vendors''%'
                AND definition LIKE '%TG_TABLE_NAME = ''products''%'
                AND definition LIKE '%TG_TABLE_NAME = ''catalog_vendor_products''%'
              ELSE false
            END
          )
        FROM trigger_functions
      ),
      false
    ),
    'child links and both organization/global parent change directions are guarded'

  UNION ALL

  SELECT check_name, passed, details FROM trigger_checks

  UNION ALL

  SELECT
    'authenticated_rpc_execute_only',
    coalesce(
      (
        SELECT
          authenticated_can_execute
          AND NOT anon_can_execute
          AND NOT public_can_execute
        FROM rpc_execute_privileges
      ),
      false
    ),
    coalesce(
      (
        SELECT pg_catalog.format(
          'authenticated=%s; anon=%s; PUBLIC=%s',
          authenticated_can_execute,
          anon_can_execute,
          public_can_execute
        )
        FROM rpc_execute_privileges
      ),
      'function missing'
    )

  UNION ALL

  SELECT
    'trigger_functions_not_publicly_executable',
    coalesce(
      (
        SELECT
          count(*) = 2
          AND bool_and(
            NOT EXISTS (
              SELECT 1
              FROM pg_catalog.aclexplode(trigger_function.proacl) acl
              WHERE acl.grantee = 0
                AND acl.privilege_type = 'EXECUTE'
            )
          )
        FROM pg_catalog.pg_proc trigger_function
        WHERE trigger_function.oid IN (
          pg_catalog.to_regprocedure('public.validate_vendor_product_catalog_link()'),
          pg_catalog.to_regprocedure('public.validate_catalog_parent_link_change()')
        )
      ),
      false
    ),
    'PUBLIC cannot call either trigger function'

  UNION ALL

  SELECT
    'organization_catalog_tables_keep_admin_only_writes',
    count(*) = 3
      AND bool_and(row_security)
      AND bool_and(admin_policy_count = 1),
    string_agg(
      table_name || ':rls=' || row_security::text || ':admin_policies=' || admin_policy_count::text,
      ', '
      ORDER BY table_name
    )
  FROM local_write_policy_checks

  UNION ALL

  SELECT
    'organization_catalog_policy_set_unchanged',
    (
      SELECT array_agg(policyname::text ORDER BY policyname::text) =
        ARRAY[
          'product_select_catalog',
          'product_write_admin',
          'vendor_admin_all',
          'vendor_products_admin_all'
        ]::text[]
      FROM pg_catalog.pg_policies
      WHERE schemaname::text = 'public'
        AND tablename::text IN ('vendors', 'products', 'vendor_products')
    ),
    'expected existing policies only: product read/admin write, vendor admin, vendor-product admin'

  UNION ALL

  SELECT
    'global_catalog_policy_set_unchanged',
    (
      SELECT array_agg(policyname::text ORDER BY policyname::text) =
        ARRAY[
          'catalog_products_authenticated_select',
          'catalog_vendor_products_authenticated_select',
          'catalog_vendors_authenticated_select'
        ]::text[]
      FROM pg_catalog.pg_policies
      WHERE schemaname::text = 'public'
        AND tablename::text IN ('catalog_vendors', 'catalog_products', 'catalog_vendor_products')
    ),
    'the three global identity tables retain only their authenticated SELECT policies'

  UNION ALL

  SELECT
    'authenticated_global_catalog_privileges_remain_read_only',
    bool_and(
      pg_catalog.has_table_privilege('authenticated', table_name, 'SELECT')
      AND NOT pg_catalog.has_table_privilege('authenticated', table_name, 'INSERT')
      AND NOT pg_catalog.has_table_privilege('authenticated', table_name, 'UPDATE')
      AND NOT pg_catalog.has_table_privilege('authenticated', table_name, 'DELETE')
      AND NOT pg_catalog.has_table_privilege('authenticated', table_name, 'TRUNCATE')
    ),
    'authenticated has SELECT only on the three global identity tables'
  FROM unnest(ARRAY[
    'public.catalog_vendors',
    'public.catalog_products',
    'public.catalog_vendor_products'
  ]) AS catalog_tables(table_name)

  UNION ALL

  SELECT
    'phase5a5_named_object_footprint_exact',
    (SELECT count(*) FROM index_checks WHERE passed) = 3
      AND (SELECT count(*) FROM trigger_checks WHERE passed) = 4
      AND (SELECT count(*) FROM rpc) = 1
      AND (SELECT count(*) FROM trigger_functions) = 2,
    'expected footprint: 3 indexes, 4 triggers, 1 RPC, 2 trigger functions; no RLS objects'
)
SELECT
  check_name,
  passed,
  CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result,
  details
FROM checks
ORDER BY check_name;
