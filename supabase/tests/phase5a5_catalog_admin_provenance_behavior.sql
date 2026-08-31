-- Phase 5A.5 Catalog Admin provenance rollback-only behavioral verification.
-- Run in the Supabase SQL Editor only after deploying the provenance RPC.
-- All fixture writes occur inside this transaction and are rolled back.

BEGIN;

DO $phase5a5_provenance_fixture_guard$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM auth.users
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000701'::uuid AND
      '5a5b0000-0000-4000-8000-000000000704'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.organizations
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000711'::uuid AND
      '5a5b0000-0000-4000-8000-000000000712'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.catalog_vendors
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000731'::uuid AND
      '5a5b0000-0000-4000-8000-000000000732'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.catalog_products
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000741'::uuid AND
      '5a5b0000-0000-4000-8000-000000000742'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.catalog_vendor_products
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000751'::uuid AND
      '5a5b0000-0000-4000-8000-000000000752'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.catalog_import_batches
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000761'::uuid AND
      '5a5b0000-0000-4000-8000-000000000762'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.catalog_source_records
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000771'::uuid AND
      '5a5b0000-0000-4000-8000-000000000772'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.catalog_verification_overrides
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000781'::uuid AND
      '5a5b0000-0000-4000-8000-000000000783'::uuid
  ) THEN
    RAISE EXCEPTION 'Phase 5A.5 provenance rollback-test fixture IDs already exist';
  END IF;
END
$phase5a5_provenance_fixture_guard$;

INSERT INTO auth.users (
  id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  raw_app_meta_data,
  raw_user_meta_data,
  created_at,
  updated_at
)
VALUES
  (
    '5a5b0000-0000-4000-8000-000000000701'::uuid,
    'authenticated',
    'authenticated',
    'phase5a5-provenance-owner@example.invalid',
    '',
    now(),
    '{}'::jsonb,
    '{"full_name":"Phase 5A.5 Provenance Owner"}'::jsonb,
    now(),
    now()
  ),
  (
    '5a5b0000-0000-4000-8000-000000000702'::uuid,
    'authenticated',
    'authenticated',
    'phase5a5-provenance-admin@example.invalid',
    '',
    now(),
    '{}'::jsonb,
    '{"full_name":"Phase 5A.5 Provenance Admin"}'::jsonb,
    now(),
    now()
  ),
  (
    '5a5b0000-0000-4000-8000-000000000703'::uuid,
    'authenticated',
    'authenticated',
    'phase5a5-provenance-staff@example.invalid',
    '',
    now(),
    '{}'::jsonb,
    '{"full_name":"Phase 5A.5 Provenance Staff"}'::jsonb,
    now(),
    now()
  ),
  (
    '5a5b0000-0000-4000-8000-000000000704'::uuid,
    'authenticated',
    'authenticated',
    'phase5a5-provenance-other-owner@example.invalid',
    '',
    now(),
    '{}'::jsonb,
    '{"full_name":"Phase 5A.5 Provenance Other Owner"}'::jsonb,
    now(),
    now()
  );

INSERT INTO public.organizations (id, name, created_by)
VALUES
  (
    '5a5b0000-0000-4000-8000-000000000711'::uuid,
    'Phase 5A.5 Provenance Organization',
    '5a5b0000-0000-4000-8000-000000000701'::uuid
  ),
  (
    '5a5b0000-0000-4000-8000-000000000712'::uuid,
    'Phase 5A.5 Provenance Other Organization',
    '5a5b0000-0000-4000-8000-000000000704'::uuid
  );

INSERT INTO public.organization_memberships (
  id,
  organization_id,
  user_id,
  role,
  active
)
VALUES
  (
    '5a5b0000-0000-4000-8000-000000000721'::uuid,
    '5a5b0000-0000-4000-8000-000000000711'::uuid,
    '5a5b0000-0000-4000-8000-000000000701'::uuid,
    'owner'::public.org_role,
    true
  ),
  (
    '5a5b0000-0000-4000-8000-000000000722'::uuid,
    '5a5b0000-0000-4000-8000-000000000711'::uuid,
    '5a5b0000-0000-4000-8000-000000000702'::uuid,
    'admin'::public.org_role,
    true
  ),
  (
    '5a5b0000-0000-4000-8000-000000000723'::uuid,
    '5a5b0000-0000-4000-8000-000000000711'::uuid,
    '5a5b0000-0000-4000-8000-000000000703'::uuid,
    'staff'::public.org_role,
    true
  ),
  (
    '5a5b0000-0000-4000-8000-000000000724'::uuid,
    '5a5b0000-0000-4000-8000-000000000712'::uuid,
    '5a5b0000-0000-4000-8000-000000000704'::uuid,
    'owner'::public.org_role,
    true
  );

INSERT INTO public.catalog_vendors (
  id,
  name,
  normalized_name,
  website,
  active
)
VALUES
  (
    '5a5b0000-0000-4000-8000-000000000731'::uuid,
    'Phase 5A.5 Provenance Vendor',
    'phase 5a 5 provenance vendor',
    'https://requested-provenance.example.invalid',
    true
  ),
  (
    '5a5b0000-0000-4000-8000-000000000732'::uuid,
    'Unrelated Phase 5A.5 Provenance Vendor',
    'unrelated phase 5a 5 provenance vendor',
    'https://unrelated-provenance.example.invalid',
    true
  );

INSERT INTO public.catalog_products (
  id,
  name,
  normalized_name,
  description,
  manufacturer,
  active,
  verification_status
)
VALUES
  (
    '5a5b0000-0000-4000-8000-000000000741'::uuid,
    'Phase 5A.5 Requested Provenance Product',
    'phase 5a 5 requested provenance product',
    'Requested canonical description',
    'Requested Manufacturer',
    true,
    'verified'
  ),
  (
    '5a5b0000-0000-4000-8000-000000000742'::uuid,
    'Unrelated Phase 5A.5 Provenance Product',
    'unrelated phase 5a 5 provenance product',
    'UNRELATED CANONICAL DESCRIPTION',
    'Unrelated Manufacturer',
    true,
    'verified'
  );

INSERT INTO public.catalog_vendor_products (
  id,
  catalog_product_id,
  catalog_vendor_id,
  vendor_sku,
  normalized_vendor_sku,
  package_description,
  package_quantity,
  package_unit,
  package_status,
  active,
  discontinued,
  verification_status
)
VALUES
  (
    '5a5b0000-0000-4000-8000-000000000751'::uuid,
    '5a5b0000-0000-4000-8000-000000000741'::uuid,
    '5a5b0000-0000-4000-8000-000000000731'::uuid,
    'REQ-001',
    'REQ-001',
    '24 rolls/case — raw source text',
    24,
    'roll',
    'source_only',
    true,
    false,
    'verified'
  ),
  (
    '5a5b0000-0000-4000-8000-000000000752'::uuid,
    '5a5b0000-0000-4000-8000-000000000742'::uuid,
    '5a5b0000-0000-4000-8000-000000000732'::uuid,
    'UNRELATED-002',
    'UNRELATED-002',
    '1 each',
    1,
    'each',
    'verified',
    true,
    false,
    'verified'
  );

INSERT INTO public.catalog_import_batches (
  id,
  catalog_vendor_id,
  source_name,
  source_version,
  artifact_name,
  artifact_sha256,
  source_uri,
  status,
  raw_record_count,
  unique_key_count,
  matched_record_count,
  unmatched_record_count,
  warning_count,
  error_count,
  metadata,
  started_at,
  completed_at
)
VALUES
  (
    '5a5b0000-0000-4000-8000-000000000761'::uuid,
    '5a5b0000-0000-4000-8000-000000000731'::uuid,
    'Requested Source Catalog',
    'requested-v1',
    'INTERNAL-REQUESTED-ARTIFACT.xlsx',
    repeat('a', 64),
    'https://internal-requested-source.example.invalid/secret',
    'completed',
    1,
    1,
    1,
    0,
    0,
    0,
    '{"secret":"REQUESTED INTERNAL METADATA"}'::jsonb,
    now() - interval '1 minute',
    now()
  ),
  (
    '5a5b0000-0000-4000-8000-000000000762'::uuid,
    '5a5b0000-0000-4000-8000-000000000732'::uuid,
    'UNRELATED SOURCE CATALOG',
    'unrelated-v1',
    'UNRELATED-INTERNAL-ARTIFACT.xlsx',
    repeat('b', 64),
    'https://unrelated-source.example.invalid/secret',
    'completed',
    1,
    1,
    1,
    0,
    0,
    0,
    '{"secret":"UNRELATED INTERNAL METADATA"}'::jsonb,
    now() - interval '1 minute',
    now()
  );

INSERT INTO public.catalog_source_records (
  id,
  import_batch_id,
  catalog_vendor_id,
  source_ordinal,
  raw_vendor_sku,
  raw_product_name,
  raw_variant,
  raw_package,
  source_page,
  raw_data,
  matched_catalog_vendor_product_id,
  resolution_status,
  resolved_at
)
VALUES
  (
    '5a5b0000-0000-4000-8000-000000000771'::uuid,
    '5a5b0000-0000-4000-8000-000000000761'::uuid,
    '5a5b0000-0000-4000-8000-000000000731'::uuid,
    1,
    'RAW-REQUESTED-001',
    'Requested Raw Source Product',
    'Requested Raw Variant',
    '24 rolls/case — raw source text',
    '22',
    '{"secret":"REQUESTED RAW JSON MUST NOT RETURN"}'::jsonb,
    '5a5b0000-0000-4000-8000-000000000751'::uuid,
    'verified_match',
    now()
  ),
  (
    '5a5b0000-0000-4000-8000-000000000772'::uuid,
    '5a5b0000-0000-4000-8000-000000000762'::uuid,
    '5a5b0000-0000-4000-8000-000000000732'::uuid,
    1,
    'UNRELATED-RAW-002',
    'UNRELATED RAW SOURCE PRODUCT',
    'UNRELATED RAW VARIANT',
    'UNRELATED RAW PACKAGE',
    '99',
    '{"secret":"UNRELATED RAW JSON"}'::jsonb,
    '5a5b0000-0000-4000-8000-000000000752'::uuid,
    'verified_match',
    now()
  );

INSERT INTO public.catalog_verification_overrides (
  id,
  catalog_vendor_id,
  import_batch_id,
  source_record_id,
  catalog_vendor_product_id,
  source_vendor_sku,
  verified_vendor_sku,
  override_type,
  evidence_status,
  production_rule,
  evidence,
  notes,
  active,
  effective_from,
  created_by
)
VALUES
  (
    '5a5b0000-0000-4000-8000-000000000781'::uuid,
    '5a5b0000-0000-4000-8000-000000000731'::uuid,
    '5a5b0000-0000-4000-8000-000000000761'::uuid,
    '5a5b0000-0000-4000-8000-000000000771'::uuid,
    '5a5b0000-0000-4000-8000-000000000751'::uuid,
    'RAW-REQUESTED-001',
    'REQ-001',
    'sku_correction',
    'verified',
    'USE VERIFIED REQUESTED SKU',
    '{"secret":"REQUESTED EVIDENCE MUST NOT RETURN"}'::jsonb,
    'REQUESTED INTERNAL NOTE MUST NOT RETURN',
    true,
    now() - interval '1 minute',
    '5a5b0000-0000-4000-8000-000000000701'::uuid
  ),
  (
    '5a5b0000-0000-4000-8000-000000000782'::uuid,
    '5a5b0000-0000-4000-8000-000000000732'::uuid,
    '5a5b0000-0000-4000-8000-000000000762'::uuid,
    '5a5b0000-0000-4000-8000-000000000772'::uuid,
    '5a5b0000-0000-4000-8000-000000000752'::uuid,
    'UNRELATED-RAW-002',
    'UNRELATED-002',
    'identity_decision',
    'verified',
    'UNRELATED PRODUCTION RULE',
    '{"secret":"UNRELATED EVIDENCE"}'::jsonb,
    'UNRELATED INTERNAL NOTE',
    true,
    now() - interval '1 minute',
    '5a5b0000-0000-4000-8000-000000000704'::uuid
  ),
  (
    '5a5b0000-0000-4000-8000-000000000783'::uuid,
    '5a5b0000-0000-4000-8000-000000000731'::uuid,
    '5a5b0000-0000-4000-8000-000000000761'::uuid,
    '5a5b0000-0000-4000-8000-000000000771'::uuid,
    '5a5b0000-0000-4000-8000-000000000751'::uuid,
    'RAW-REQUESTED-001',
    'REQ-001',
    'identity_decision',
    'verified',
    'INACTIVE REQUESTED RULE MUST NOT RETURN',
    '{"secret":"INACTIVE EVIDENCE"}'::jsonb,
    'INACTIVE INTERNAL NOTE',
    false,
    now() - interval '2 minutes',
    '5a5b0000-0000-4000-8000-000000000701'::uuid
  );

DO $phase5a5_provenance_behavior$
DECLARE
  _organization_id constant uuid := '5a5b0000-0000-4000-8000-000000000711';
  _other_organization_id constant uuid := '5a5b0000-0000-4000-8000-000000000712';
  _catalog_vendor_product_id constant uuid := '5a5b0000-0000-4000-8000-000000000751';
  _global_rows_before jsonb;
  _global_rows_after jsonb;
  _global_counts_before jsonb;
  _global_counts_after jsonb;
  _organization_rows_before jsonb;
  _organization_rows_after jsonb;
  _organization_counts_before jsonb;
  _organization_counts_after jsonb;
  _owner_result jsonb;
  _admin_result jsonb;
BEGIN
  WITH fixture_rows AS (
    SELECT 'catalog_vendors'::text AS table_name, id, to_jsonb(row_data) AS row_data
    FROM public.catalog_vendors row_data
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000731'::uuid AND
      '5a5b0000-0000-4000-8000-000000000732'::uuid

    UNION ALL

    SELECT 'catalog_products', id, to_jsonb(row_data)
    FROM public.catalog_products row_data
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000741'::uuid AND
      '5a5b0000-0000-4000-8000-000000000742'::uuid

    UNION ALL

    SELECT 'catalog_vendor_products', id, to_jsonb(row_data)
    FROM public.catalog_vendor_products row_data
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000751'::uuid AND
      '5a5b0000-0000-4000-8000-000000000752'::uuid

    UNION ALL

    SELECT 'catalog_import_batches', id, to_jsonb(row_data)
    FROM public.catalog_import_batches row_data
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000761'::uuid AND
      '5a5b0000-0000-4000-8000-000000000762'::uuid

    UNION ALL

    SELECT 'catalog_source_records', id, to_jsonb(row_data)
    FROM public.catalog_source_records row_data
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000771'::uuid AND
      '5a5b0000-0000-4000-8000-000000000772'::uuid

    UNION ALL

    SELECT 'catalog_verification_overrides', id, to_jsonb(row_data)
    FROM public.catalog_verification_overrides row_data
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000781'::uuid AND
      '5a5b0000-0000-4000-8000-000000000783'::uuid
  )
  SELECT COALESCE(
    jsonb_object_agg(
      table_name || ':' || id::text,
      row_data
      ORDER BY table_name, id
    ),
    '{}'::jsonb
  )
  INTO _global_rows_before
  FROM fixture_rows;

  SELECT jsonb_build_object(
    'catalog_vendors', (SELECT count(*) FROM public.catalog_vendors),
    'catalog_products', (SELECT count(*) FROM public.catalog_products),
    'catalog_vendor_products', (SELECT count(*) FROM public.catalog_vendor_products),
    'catalog_import_batches', (SELECT count(*) FROM public.catalog_import_batches),
    'catalog_source_records', (SELECT count(*) FROM public.catalog_source_records),
    'catalog_verification_overrides', (SELECT count(*) FROM public.catalog_verification_overrides)
  )
  INTO _global_counts_before;

  WITH fixture_rows AS (
    SELECT 'organizations'::text AS table_name, id, to_jsonb(row_data) AS row_data
    FROM public.organizations row_data
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000711'::uuid AND
      '5a5b0000-0000-4000-8000-000000000712'::uuid

    UNION ALL

    SELECT 'organization_memberships', id, to_jsonb(row_data)
    FROM public.organization_memberships row_data
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000721'::uuid AND
      '5a5b0000-0000-4000-8000-000000000724'::uuid

    UNION ALL

    SELECT 'profiles', id, to_jsonb(row_data)
    FROM public.profiles row_data
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000701'::uuid AND
      '5a5b0000-0000-4000-8000-000000000704'::uuid
  )
  SELECT COALESCE(
    jsonb_object_agg(
      table_name || ':' || id::text,
      row_data
      ORDER BY table_name, id
    ),
    '{}'::jsonb
  )
  INTO _organization_rows_before
  FROM fixture_rows;

  SELECT jsonb_build_object(
    'organizations', (SELECT count(*) FROM public.organizations),
    'organization_memberships', (SELECT count(*) FROM public.organization_memberships),
    'profiles', (SELECT count(*) FROM public.profiles),
    'product_categories', (SELECT count(*) FROM public.product_categories),
    'vendors', (SELECT count(*) FROM public.vendors),
    'products', (SELECT count(*) FROM public.products),
    'vendor_products', (SELECT count(*) FROM public.vendor_products),
    'inventory_items', (SELECT count(*) FROM public.inventory_items)
  )
  INTO _organization_counts_before;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub',
    '5a5b0000-0000-4000-8000-000000000701',
    true
  );
  _owner_result := public.get_catalog_vendor_product_admin_detail(
    _organization_id,
    _catalog_vendor_product_id
  );

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub',
    '5a5b0000-0000-4000-8000-000000000702',
    true
  );
  _admin_result := public.get_catalog_vendor_product_admin_detail(
    _organization_id,
    _catalog_vendor_product_id
  );

  IF _admin_result IS DISTINCT FROM _owner_result THEN
    RAISE EXCEPTION 'Owner and admin received different provenance payloads';
  END IF;

  IF (
    SELECT array_agg(key ORDER BY key)
    FROM jsonb_object_keys(_owner_result) AS keys(key)
  ) IS DISTINCT FROM ARRAY[
    'catalogVendorProductId',
    'lifecycle',
    'package',
    'product',
    'provenance',
    'vendor',
    'verificationOverrides'
  ]::text[] THEN
    RAISE EXCEPTION 'Top-level provenance payload keys were not exact: %', _owner_result;
  END IF;

  IF (
    SELECT array_agg(key ORDER BY key)
    FROM jsonb_object_keys(_owner_result->'product') AS keys(key)
  ) IS DISTINCT FROM ARRAY[
    'active',
    'description',
    'id',
    'manufacturer',
    'name',
    'verificationStatus'
  ]::text[] THEN
    RAISE EXCEPTION 'Product identity payload keys were not exact';
  END IF;

  IF (
    SELECT array_agg(key ORDER BY key)
    FROM jsonb_object_keys(_owner_result->'vendor') AS keys(key)
  ) IS DISTINCT FROM ARRAY[
    'active',
    'id',
    'manufacturerSku',
    'name',
    'normalizedVendorSku',
    'vendorSku',
    'website'
  ]::text[] THEN
    RAISE EXCEPTION 'Vendor identity payload keys were not exact';
  END IF;

  IF (
    SELECT array_agg(key ORDER BY key)
    FROM jsonb_object_keys(_owner_result->'package') AS keys(key)
  ) IS DISTINCT FROM ARRAY[
    'rawDescription',
    'status',
    'verifiedQuantity',
    'verifiedUnit'
  ]::text[] THEN
    RAISE EXCEPTION 'Package payload keys were not exact';
  END IF;

  IF (
    SELECT array_agg(key ORDER BY key)
    FROM jsonb_object_keys(_owner_result->'lifecycle') AS keys(key)
  ) IS DISTINCT FROM ARRAY[
    'active',
    'discontinued',
    'verificationStatus'
  ]::text[] THEN
    RAISE EXCEPTION 'Lifecycle payload keys were not exact';
  END IF;

  IF jsonb_array_length(_owner_result->'provenance') <> 1
     OR (
       SELECT array_agg(key ORDER BY key)
       FROM jsonb_object_keys(_owner_result->'provenance'->0) AS keys(key)
     ) IS DISTINCT FROM ARRAY[
       'rawPackage',
       'rawProductName',
       'rawVariant',
       'rawVendorSku',
       'sourceName',
       'sourcePage',
       'sourceVersion'
     ]::text[] THEN
    RAISE EXCEPTION 'Source provenance payload was not exact: %', _owner_result->'provenance';
  END IF;

  IF jsonb_array_length(_owner_result->'verificationOverrides') <> 1
     OR (
       SELECT array_agg(key ORDER BY key)
       FROM jsonb_object_keys(_owner_result->'verificationOverrides'->0) AS keys(key)
     ) IS DISTINCT FROM ARRAY[
       'effectiveFrom',
       'evidenceStatus',
       'overrideType',
       'productionRule',
       'sourceName',
       'sourceVendorSku',
       'sourceVersion',
       'verifiedVendorSku'
     ]::text[] THEN
    RAISE EXCEPTION 'Verification decision payload was not exact: %', _owner_result->'verificationOverrides';
  END IF;

  IF _owner_result->'package'->>'status' <> 'source_only'
     OR _owner_result->'package'->>'rawDescription'
       <> '24 rolls/case — raw source text'
     OR _owner_result->'package'->'verifiedQuantity' IS DISTINCT FROM 'null'::jsonb
     OR _owner_result->'package'->'verifiedUnit' IS DISTINCT FROM 'null'::jsonb THEN
    RAISE EXCEPTION 'Source-only package data masqueraded as verified: %', _owner_result->'package';
  END IF;

  IF _owner_result->'provenance'->0->>'sourceName' <> 'Requested Source Catalog'
     OR _owner_result->'provenance'->0->>'sourceVersion' <> 'requested-v1'
     OR _owner_result->'provenance'->0->>'sourcePage' <> '22'
     OR _owner_result->'provenance'->0->>'rawVendorSku' <> 'RAW-REQUESTED-001'
     OR _owner_result->'provenance'->0->>'rawProductName'
       <> 'Requested Raw Source Product'
     OR _owner_result->'provenance'->0->>'rawVariant' <> 'Requested Raw Variant'
     OR _owner_result->'provenance'->0->>'rawPackage'
       <> '24 rolls/case — raw source text' THEN
    RAISE EXCEPTION 'Requested source catalog/version/raw text was not preserved';
  END IF;

  IF _owner_result->'verificationOverrides'->0->>'evidenceStatus' <> 'verified'
     OR _owner_result->'verificationOverrides'->0->>'productionRule'
       <> 'USE VERIFIED REQUESTED SKU'
     OR _owner_result->'verificationOverrides'->0->>'sourceVendorSku'
       <> 'RAW-REQUESTED-001'
     OR _owner_result->'verificationOverrides'->0->>'verifiedVendorSku'
       <> 'REQ-001' THEN
    RAISE EXCEPTION 'Active verification decision was not returned correctly';
  END IF;

  IF _owner_result::text ~ '"(artifactName|artifactSha256|createdBy|evidence|metadata|notes|rawData|resolutionStatus|secret|sourceOrdinal|sourceUri|token)"[[:space:]]*:'
     OR _owner_result::text LIKE '%REQUESTED INTERNAL%'
     OR _owner_result::text LIKE '%INTERNAL-REQUESTED-ARTIFACT%'
     OR _owner_result::text LIKE '%REQUESTED RAW JSON MUST NOT RETURN%'
     OR _owner_result::text LIKE '%REQUESTED EVIDENCE MUST NOT RETURN%'
     OR _owner_result::text LIKE '%INACTIVE REQUESTED RULE%'
     OR _owner_result::text LIKE '%UNRELATED%' THEN
    RAISE EXCEPTION 'Sensitive, inactive, or unrelated provenance leaked: %', _owner_result;
  END IF;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub',
    '5a5b0000-0000-4000-8000-000000000703',
    true
  );
  BEGIN
    PERFORM public.get_catalog_vendor_product_admin_detail(
      _organization_id,
      _catalog_vendor_product_id
    );
    RAISE EXCEPTION 'Staff provenance access unexpectedly succeeded';
  EXCEPTION
    WHEN insufficient_privilege THEN NULL;
  END;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub',
    '5a5b0000-0000-4000-8000-000000000701',
    true
  );
  BEGIN
    PERFORM public.get_catalog_vendor_product_admin_detail(
      _other_organization_id,
      _catalog_vendor_product_id
    );
    RAISE EXCEPTION 'Cross-organization provenance access unexpectedly succeeded';
  EXCEPTION
    WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    PERFORM public.get_catalog_vendor_product_admin_detail(
      NULL,
      _catalog_vendor_product_id
    );
    RAISE EXCEPTION 'Null organization provenance access unexpectedly succeeded';
  EXCEPTION
    WHEN null_value_not_allowed THEN NULL;
  END;

  WITH fixture_rows AS (
    SELECT 'catalog_vendors'::text AS table_name, id, to_jsonb(row_data) AS row_data
    FROM public.catalog_vendors row_data
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000731'::uuid AND
      '5a5b0000-0000-4000-8000-000000000732'::uuid

    UNION ALL

    SELECT 'catalog_products', id, to_jsonb(row_data)
    FROM public.catalog_products row_data
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000741'::uuid AND
      '5a5b0000-0000-4000-8000-000000000742'::uuid

    UNION ALL

    SELECT 'catalog_vendor_products', id, to_jsonb(row_data)
    FROM public.catalog_vendor_products row_data
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000751'::uuid AND
      '5a5b0000-0000-4000-8000-000000000752'::uuid

    UNION ALL

    SELECT 'catalog_import_batches', id, to_jsonb(row_data)
    FROM public.catalog_import_batches row_data
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000761'::uuid AND
      '5a5b0000-0000-4000-8000-000000000762'::uuid

    UNION ALL

    SELECT 'catalog_source_records', id, to_jsonb(row_data)
    FROM public.catalog_source_records row_data
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000771'::uuid AND
      '5a5b0000-0000-4000-8000-000000000772'::uuid

    UNION ALL

    SELECT 'catalog_verification_overrides', id, to_jsonb(row_data)
    FROM public.catalog_verification_overrides row_data
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000781'::uuid AND
      '5a5b0000-0000-4000-8000-000000000783'::uuid
  )
  SELECT COALESCE(
    jsonb_object_agg(
      table_name || ':' || id::text,
      row_data
      ORDER BY table_name, id
    ),
    '{}'::jsonb
  )
  INTO _global_rows_after
  FROM fixture_rows;

  SELECT jsonb_build_object(
    'catalog_vendors', (SELECT count(*) FROM public.catalog_vendors),
    'catalog_products', (SELECT count(*) FROM public.catalog_products),
    'catalog_vendor_products', (SELECT count(*) FROM public.catalog_vendor_products),
    'catalog_import_batches', (SELECT count(*) FROM public.catalog_import_batches),
    'catalog_source_records', (SELECT count(*) FROM public.catalog_source_records),
    'catalog_verification_overrides', (SELECT count(*) FROM public.catalog_verification_overrides)
  )
  INTO _global_counts_after;

  WITH fixture_rows AS (
    SELECT 'organizations'::text AS table_name, id, to_jsonb(row_data) AS row_data
    FROM public.organizations row_data
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000711'::uuid AND
      '5a5b0000-0000-4000-8000-000000000712'::uuid

    UNION ALL

    SELECT 'organization_memberships', id, to_jsonb(row_data)
    FROM public.organization_memberships row_data
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000721'::uuid AND
      '5a5b0000-0000-4000-8000-000000000724'::uuid

    UNION ALL

    SELECT 'profiles', id, to_jsonb(row_data)
    FROM public.profiles row_data
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000701'::uuid AND
      '5a5b0000-0000-4000-8000-000000000704'::uuid
  )
  SELECT COALESCE(
    jsonb_object_agg(
      table_name || ':' || id::text,
      row_data
      ORDER BY table_name, id
    ),
    '{}'::jsonb
  )
  INTO _organization_rows_after
  FROM fixture_rows;

  SELECT jsonb_build_object(
    'organizations', (SELECT count(*) FROM public.organizations),
    'organization_memberships', (SELECT count(*) FROM public.organization_memberships),
    'profiles', (SELECT count(*) FROM public.profiles),
    'product_categories', (SELECT count(*) FROM public.product_categories),
    'vendors', (SELECT count(*) FROM public.vendors),
    'products', (SELECT count(*) FROM public.products),
    'vendor_products', (SELECT count(*) FROM public.vendor_products),
    'inventory_items', (SELECT count(*) FROM public.inventory_items)
  )
  INTO _organization_counts_after;

  IF _global_rows_after IS DISTINCT FROM _global_rows_before
     OR _global_counts_after IS DISTINCT FROM _global_counts_before THEN
    RAISE EXCEPTION 'Provenance RPC mutated a global catalog or provenance table';
  END IF;

  IF _organization_rows_after IS DISTINCT FROM _organization_rows_before
     OR _organization_counts_after IS DISTINCT FROM _organization_counts_before THEN
    RAISE EXCEPTION 'Provenance RPC mutated an organization or inventory table';
  END IF;
END
$phase5a5_provenance_behavior$;

SET LOCAL ROLE authenticated;

DO $phase5a5_provenance_authenticated_roles$
BEGIN
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub',
    '5a5b0000-0000-4000-8000-000000000701',
    true
  );
  PERFORM public.get_catalog_vendor_product_admin_detail(
    '5a5b0000-0000-4000-8000-000000000711'::uuid,
    '5a5b0000-0000-4000-8000-000000000751'::uuid
  );

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub',
    '5a5b0000-0000-4000-8000-000000000702',
    true
  );
  PERFORM public.get_catalog_vendor_product_admin_detail(
    '5a5b0000-0000-4000-8000-000000000711'::uuid,
    '5a5b0000-0000-4000-8000-000000000751'::uuid
  );

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub',
    '5a5b0000-0000-4000-8000-000000000703',
    true
  );
  BEGIN
    PERFORM public.get_catalog_vendor_product_admin_detail(
      '5a5b0000-0000-4000-8000-000000000711'::uuid,
      '5a5b0000-0000-4000-8000-000000000751'::uuid
    );
    RAISE EXCEPTION 'Authenticated staff provenance access unexpectedly succeeded';
  EXCEPTION
    WHEN insufficient_privilege THEN NULL;
  END;
END
$phase5a5_provenance_authenticated_roles$;

RESET ROLE;
SET LOCAL ROLE anon;

DO $phase5a5_provenance_anon_denial$
BEGIN
  BEGIN
    PERFORM public.get_catalog_vendor_product_admin_detail(
      '5a5b0000-0000-4000-8000-000000000711'::uuid,
      '5a5b0000-0000-4000-8000-000000000751'::uuid
    );
    RAISE EXCEPTION 'Anonymous provenance access unexpectedly succeeded';
  EXCEPTION
    WHEN insufficient_privilege THEN NULL;
  END;
END
$phase5a5_provenance_anon_denial$;

RESET ROLE;

SELECT
  'phase5a5_catalog_admin_provenance_behavior' AS check_name,
  true AS passed,
  'PASS' AS result;

ROLLBACK;

-- This assertion is read-only and proves fixture rows did not persist.
DO $phase5a5_provenance_no_persistence$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM auth.users
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000701'::uuid AND
      '5a5b0000-0000-4000-8000-000000000704'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.profiles
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000701'::uuid AND
      '5a5b0000-0000-4000-8000-000000000704'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.organizations
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000711'::uuid AND
      '5a5b0000-0000-4000-8000-000000000712'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.organization_memberships
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000721'::uuid AND
      '5a5b0000-0000-4000-8000-000000000724'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.catalog_vendors
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000731'::uuid AND
      '5a5b0000-0000-4000-8000-000000000732'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.catalog_products
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000741'::uuid AND
      '5a5b0000-0000-4000-8000-000000000742'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.catalog_vendor_products
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000751'::uuid AND
      '5a5b0000-0000-4000-8000-000000000752'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.catalog_import_batches
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000761'::uuid AND
      '5a5b0000-0000-4000-8000-000000000762'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.catalog_source_records
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000771'::uuid AND
      '5a5b0000-0000-4000-8000-000000000772'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.catalog_verification_overrides
    WHERE id BETWEEN
      '5a5b0000-0000-4000-8000-000000000781'::uuid AND
      '5a5b0000-0000-4000-8000-000000000783'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.vendors
    WHERE organization_id IN (
      '5a5b0000-0000-4000-8000-000000000711'::uuid,
      '5a5b0000-0000-4000-8000-000000000712'::uuid
    )
  ) OR EXISTS (
    SELECT 1
    FROM public.products
    WHERE organization_id IN (
      '5a5b0000-0000-4000-8000-000000000711'::uuid,
      '5a5b0000-0000-4000-8000-000000000712'::uuid
    )
  ) OR EXISTS (
    SELECT 1
    FROM public.vendor_products
    WHERE organization_id IN (
      '5a5b0000-0000-4000-8000-000000000711'::uuid,
      '5a5b0000-0000-4000-8000-000000000712'::uuid
    )
  ) OR EXISTS (
    SELECT 1
    FROM public.inventory_items
    WHERE organization_id IN (
      '5a5b0000-0000-4000-8000-000000000711'::uuid,
      '5a5b0000-0000-4000-8000-000000000712'::uuid
    )
  ) THEN
    RAISE EXCEPTION 'Phase 5A.5 provenance rollback-only test left persistent fixture rows';
  END IF;
END
$phase5a5_provenance_no_persistence$;

SELECT
  'phase5a5_catalog_admin_provenance_post_rollback' AS check_name,
  true AS passed,
  'PASS' AS result;
