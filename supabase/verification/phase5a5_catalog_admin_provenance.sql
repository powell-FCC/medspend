-- Phase 5A.5 Catalog Admin provenance deployment verification (read-only).
-- Run only after deploying 20260831130000_phase5a5_catalog_admin_provenance.sql.
-- Every row should return passed = true.

WITH
expected_json_keys(key_name) AS (
  VALUES
    ('active'),
    ('active'),
    ('active'),
    ('catalogVendorProductId'),
    ('description'),
    ('discontinued'),
    ('effectiveFrom'),
    ('evidenceStatus'),
    ('id'),
    ('id'),
    ('lifecycle'),
    ('manufacturer'),
    ('manufacturerSku'),
    ('name'),
    ('name'),
    ('normalizedVendorSku'),
    ('overrideType'),
    ('package'),
    ('product'),
    ('productionRule'),
    ('provenance'),
    ('rawDescription'),
    ('rawPackage'),
    ('rawProductName'),
    ('rawVariant'),
    ('rawVendorSku'),
    ('sourceName'),
    ('sourceName'),
    ('sourcePage'),
    ('sourceVendorSku'),
    ('sourceVersion'),
    ('sourceVersion'),
    ('status'),
    ('vendor'),
    ('vendorSku'),
    ('verificationOverrides'),
    ('verificationStatus'),
    ('verificationStatus'),
    ('verifiedQuantity'),
    ('verifiedUnit'),
    ('verifiedVendorSku'),
    ('website')
),
sensitive_json_keys(key_name) AS (
  VALUES
    ('artifactName'),
    ('artifactSha256'),
    ('createdBy'),
    ('evidence'),
    ('metadata'),
    ('notes'),
    ('rawData'),
    ('resolutionStatus'),
    ('secret'),
    ('sourceOrdinal'),
    ('sourceUri'),
    ('token')
),
restricted_tables(table_name) AS (
  VALUES
    ('catalog_import_batches'),
    ('catalog_source_records'),
    ('catalog_verification_overrides')
),
client_roles(role_name) AS (
  VALUES ('authenticated'), ('anon'), ('public')
),
table_privileges(privilege_name) AS (
  VALUES
    ('SELECT'),
    ('INSERT'),
    ('UPDATE'),
    ('DELETE'),
    ('TRUNCATE'),
    ('REFERENCES'),
    ('TRIGGER')
),
rpc AS (
  SELECT
    procedure.oid,
    procedure.prosecdef,
    procedure.provolatile,
    procedure.proconfig,
    pg_catalog.pg_get_functiondef(procedure.oid) AS definition
  FROM pg_catalog.pg_proc procedure
  WHERE procedure.oid = pg_catalog.to_regprocedure(
    'public.get_catalog_vendor_product_admin_detail(uuid,uuid)'
  )
),
function_json_keys AS (
  SELECT key_parts[1] AS key_name
  FROM rpc
  CROSS JOIN LATERAL pg_catalog.regexp_matches(
    rpc.definition,
    '''([A-Za-z][A-Za-z0-9]*)''[[:space:]]*,',
    'g'
  ) AS matched(key_parts)
),
json_key_footprint AS (
  SELECT
    COALESCE(
      (SELECT array_agg(key_name ORDER BY key_name) FROM function_json_keys),
      ARRAY[]::text[]
    ) AS actual_keys,
    (SELECT array_agg(key_name ORDER BY key_name) FROM expected_json_keys)
      AS expected_keys
),
privileges AS (
  SELECT
    pg_catalog.has_function_privilege('authenticated', rpc.oid, 'EXECUTE')
      AS authenticated_can_execute,
    pg_catalog.has_function_privilege('anon', rpc.oid, 'EXECUTE')
      AS anon_can_execute,
    pg_catalog.has_function_privilege('public', rpc.oid, 'EXECUTE')
      AS public_can_execute
  FROM rpc
),
restricted_table_acl AS (
  SELECT
    restricted_table.table_name,
    client_role.role_name,
    table_privilege.privilege_name,
    pg_catalog.has_table_privilege(
      client_role.role_name,
      pg_catalog.format('public.%I', restricted_table.table_name),
      table_privilege.privilege_name
    ) AS has_privilege
  FROM restricted_tables restricted_table
  CROSS JOIN client_roles client_role
  CROSS JOIN table_privileges table_privilege
),
checks(check_name, passed, details) AS (
  SELECT
    'rpc_exists_with_exact_signature',
    pg_catalog.to_regprocedure(
      'public.get_catalog_vendor_product_admin_detail(uuid,uuid)'
    ) IS NOT NULL,
    COALESCE(
      pg_catalog.to_regprocedure(
        'public.get_catalog_vendor_product_admin_detail(uuid,uuid)'
      )::text,
      'missing'
    )

  UNION ALL

  SELECT
    'rpc_security_definer',
    COALESCE((SELECT prosecdef FROM rpc), false),
    COALESCE((SELECT 'security_definer=' || prosecdef::text FROM rpc), 'missing')

  UNION ALL

  SELECT
    'rpc_stable',
    COALESCE((SELECT provolatile = 's' FROM rpc), false),
    COALESCE((SELECT 'volatility=' || provolatile::text FROM rpc), 'missing')

  UNION ALL

  SELECT
    'rpc_search_path_hardened',
    COALESCE((SELECT proconfig = ARRAY['search_path=public']::text[] FROM rpc), false),
    COALESCE((SELECT array_to_string(proconfig, ',') FROM rpc), 'missing')

  UNION ALL

  SELECT
    'security_definer_schema_not_client_writable',
    NOT pg_catalog.has_schema_privilege('authenticated', 'public', 'CREATE')
      AND NOT pg_catalog.has_schema_privilege('anon', 'public', 'CREATE'),
    pg_catalog.format(
      'authenticated_create=%s; anon_create=%s',
      pg_catalog.has_schema_privilege('authenticated', 'public', 'CREATE'),
      pg_catalog.has_schema_privilege('anon', 'public', 'CREATE')
    )

  UNION ALL

  SELECT
    'rpc_authenticated_execute_only',
    COALESCE(
      (
        SELECT
          authenticated_can_execute
          AND NOT anon_can_execute
          AND NOT public_can_execute
        FROM privileges
      ),
      false
    ),
    COALESCE(
      (
        SELECT pg_catalog.format(
          'authenticated=%s; anon=%s; PUBLIC=%s',
          authenticated_can_execute,
          anon_can_execute,
          public_can_execute
        )
        FROM privileges
      ),
      'function missing'
    )

  UNION ALL

  SELECT
    'restricted_provenance_tables_remain_client_inaccessible',
    COALESCE(NOT bool_or(has_privilege), false),
    COALESCE(
      string_agg(
        table_name || ':' || role_name || ':' || privilege_name
          || '=' || has_privilege::text,
        ', '
        ORDER BY table_name, role_name, privilege_name
      ),
      'missing privilege rows'
    )
  FROM restricted_table_acl

  UNION ALL

  SELECT
    'rpc_owner_admin_authorization_present',
    COALESCE(
      (
        SELECT
          strpos(
            definition,
            'public.is_org_admin(_organization_id, auth.uid())'
          ) > 0
          AND strpos(definition, 'USING ERRCODE = ''42501''') > 0
        FROM rpc
      ),
      false
    ),
    'authorization must bind the supplied organization to auth.uid()'

  UNION ALL

  SELECT
    'rpc_authorization_precedes_protected_access',
    COALESCE(
      (
        SELECT
          strpos(definition, 'public.is_org_admin') > 0
          AND strpos(definition, 'public.is_org_admin')
            < strpos(definition, 'public.catalog_vendor_products')
          AND strpos(definition, 'public.is_org_admin')
            < strpos(definition, 'public.catalog_source_records')
          AND strpos(definition, 'public.is_org_admin')
            < strpos(definition, 'public.catalog_verification_overrides')
        FROM rpc
      ),
      false
    ),
    'owner/admin authorization must precede every catalog and provenance read'

  UNION ALL

  SELECT
    'rpc_function_body_is_read_only',
    COALESCE(
      (
        SELECT definition !~* '\m(INSERT|UPDATE|DELETE|TRUNCATE|MERGE|COPY|CALL|EXECUTE)\M'
        FROM rpc
      ),
      false
    ),
    'function body must contain no write or dynamic-execution statement'

  UNION ALL

  SELECT
    'rpc_returned_field_footprint_exact',
    actual_keys = expected_keys,
    pg_catalog.format(
      'actual={%s}; expected={%s}',
      array_to_string(actual_keys, ','),
      array_to_string(expected_keys, ',')
    )
  FROM json_key_footprint

  UNION ALL

  SELECT
    'rpc_sensitive_fields_not_exposed',
    NOT EXISTS (
      SELECT 1
      FROM function_json_keys actual
      JOIN sensitive_json_keys sensitive USING (key_name)
    )
      AND COALESCE(
        (
          SELECT definition !~* '\m(raw_data|evidence|created_by|artifact_name|artifact_sha256|metadata|notes|source_uri)\M'
          FROM rpc
        ),
        false
      ),
    'raw JSON, evidence, actors, artifacts, metadata, notes, and source URIs must remain private'

  UNION ALL

  SELECT
    'rpc_named_schema_footprint_exact',
    (
      SELECT
        count(*) = 1
        AND bool_and(
          procedure.oid = pg_catalog.to_regprocedure(
            'public.get_catalog_vendor_product_admin_detail(uuid,uuid)'
          )
        )
      FROM pg_catalog.pg_proc procedure
      JOIN pg_catalog.pg_namespace namespace
        ON namespace.oid = procedure.pronamespace
      WHERE namespace.nspname::text = 'public'
        AND procedure.proname::text = 'get_catalog_vendor_product_admin_detail'
    )
      AND NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_class relation
        WHERE relation.relnamespace = pg_catalog.to_regnamespace('public')
          AND relation.relname::text = 'get_catalog_vendor_product_admin_detail'
      ),
    'exactly one public RPC with no same-named relation'
)
SELECT
  check_name,
  passed,
  details
FROM checks
ORDER BY check_name;
