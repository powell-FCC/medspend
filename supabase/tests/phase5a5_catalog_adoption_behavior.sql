-- Phase 5A.5 rollback-only behavioral verification.
-- Run in the Supabase SQL Editor only after deploying the Phase 5A.5 migration.
-- All fixture writes occur inside the transaction and are rolled back.

BEGIN;

DO $phase5a5_fixture_guard$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM auth.users
    WHERE id IN (
      '5a5a0000-0000-4000-8000-000000000001'::uuid,
      '5a5a0000-0000-4000-8000-000000000002'::uuid,
      '5a5a0000-0000-4000-8000-000000000003'::uuid
    )
  ) OR EXISTS (
    SELECT 1
    FROM public.organizations
    WHERE id IN (
      '5a5a0000-0000-4000-8000-000000000101'::uuid,
      '5a5a0000-0000-4000-8000-000000000102'::uuid
    )
  ) OR EXISTS (
    SELECT 1
    FROM public.catalog_vendors
    WHERE id = '5a5a0000-0000-4000-8000-000000000201'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.catalog_products
    WHERE id BETWEEN
      '5a5a0000-0000-4000-8000-000000000301'::uuid AND
      '5a5a0000-0000-4000-8000-000000000306'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.catalog_vendor_products
    WHERE id BETWEEN
      '5a5a0000-0000-4000-8000-000000000401'::uuid AND
      '5a5a0000-0000-4000-8000-000000000405'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.products
    WHERE id = '5a5a0000-0000-4000-8000-000000000501'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.vendor_products
    WHERE id = '5a5a0000-0000-4000-8000-000000000502'::uuid
  ) THEN
    RAISE EXCEPTION 'Phase 5A.5 rollback-test fixture IDs already exist';
  END IF;
END
$phase5a5_fixture_guard$;

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
    '5a5a0000-0000-4000-8000-000000000001'::uuid,
    'authenticated',
    'authenticated',
    'phase5a5-admin@example.invalid',
    '',
    now(),
    '{}'::jsonb,
    '{"full_name":"Phase 5A.5 Admin"}'::jsonb,
    now(),
    now()
  ),
  (
    '5a5a0000-0000-4000-8000-000000000002'::uuid,
    'authenticated',
    'authenticated',
    'phase5a5-staff@example.invalid',
    '',
    now(),
    '{}'::jsonb,
    '{"full_name":"Phase 5A.5 Staff"}'::jsonb,
    now(),
    now()
  ),
  (
    '5a5a0000-0000-4000-8000-000000000003'::uuid,
    'authenticated',
    'authenticated',
    'phase5a5-other-owner@example.invalid',
    '',
    now(),
    '{}'::jsonb,
    '{"full_name":"Phase 5A.5 Other Owner"}'::jsonb,
    now(),
    now()
  );

INSERT INTO public.organizations (id, name, created_by)
VALUES
  (
    '5a5a0000-0000-4000-8000-000000000101'::uuid,
    'Phase 5A.5 Adoption Organization',
    '5a5a0000-0000-4000-8000-000000000001'::uuid
  ),
  (
    '5a5a0000-0000-4000-8000-000000000102'::uuid,
    'Phase 5A.5 Other Organization',
    '5a5a0000-0000-4000-8000-000000000003'::uuid
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
    '5a5a0000-0000-4000-8000-000000000601'::uuid,
    '5a5a0000-0000-4000-8000-000000000101'::uuid,
    '5a5a0000-0000-4000-8000-000000000001'::uuid,
    'admin'::public.org_role,
    true
  ),
  (
    '5a5a0000-0000-4000-8000-000000000602'::uuid,
    '5a5a0000-0000-4000-8000-000000000101'::uuid,
    '5a5a0000-0000-4000-8000-000000000002'::uuid,
    'staff'::public.org_role,
    true
  ),
  (
    '5a5a0000-0000-4000-8000-000000000603'::uuid,
    '5a5a0000-0000-4000-8000-000000000102'::uuid,
    '5a5a0000-0000-4000-8000-000000000003'::uuid,
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
VALUES (
  '5a5a0000-0000-4000-8000-000000000201'::uuid,
  'Phase 5A.5 Behavioral Vendor',
  'phase 5a 5 behavioral vendor',
  'https://phase5a5.example.invalid',
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
    '5a5a0000-0000-4000-8000-000000000301'::uuid,
    'Phase 5A.5 Verified Package Product',
    'phase 5a 5 verified package product',
    'Verified fixture product',
    'Fixture Manufacturer',
    true,
    'verified'
  ),
  (
    '5a5a0000-0000-4000-8000-000000000302'::uuid,
    'Phase 5A.5 Source Package Product',
    'phase 5a 5 source package product',
    'Source-only fixture product',
    'Fixture Manufacturer',
    true,
    'verified'
  ),
  (
    '5a5a0000-0000-4000-8000-000000000303'::uuid,
    'Phase 5A.5 Unknown Package Product',
    'phase 5a 5 unknown package product',
    'Unknown-package fixture product',
    'Fixture Manufacturer',
    true,
    'verified'
  ),
  (
    '5a5a0000-0000-4000-8000-000000000304'::uuid,
    'Phase 5A.5 Discontinued Product',
    'phase 5a 5 discontinued product',
    'Discontinued fixture product',
    'Fixture Manufacturer',
    true,
    'verified'
  ),
  (
    '5a5a0000-0000-4000-8000-000000000305'::uuid,
    'Phase 5A.5 Conflict Target Product',
    'phase 5a 5 conflict target product',
    'Conflict target fixture product',
    'Fixture Manufacturer',
    true,
    'verified'
  ),
  (
    '5a5a0000-0000-4000-8000-000000000306'::uuid,
    'Phase 5A.5 Existing Local Identity',
    'phase 5a 5 existing local identity',
    'Existing alternate identity for the conflict test',
    'Fixture Manufacturer',
    true,
    'verified'
  );

INSERT INTO public.catalog_vendor_products (
  id,
  catalog_product_id,
  catalog_vendor_id,
  vendor_sku,
  normalized_vendor_sku,
  manufacturer_sku,
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
    '5a5a0000-0000-4000-8000-000000000401'::uuid,
    '5a5a0000-0000-4000-8000-000000000301'::uuid,
    '5a5a0000-0000-4000-8000-000000000201'::uuid,
    'TEST-VERIFIED',
    'TEST-VERIFIED',
    'MFG-VERIFIED',
    '12 Each / Box',
    12,
    'each',
    'verified',
    true,
    false,
    'verified'
  ),
  (
    '5a5a0000-0000-4000-8000-000000000402'::uuid,
    '5a5a0000-0000-4000-8000-000000000302'::uuid,
    '5a5a0000-0000-4000-8000-000000000201'::uuid,
    'TEST-SOURCE',
    'TEST-SOURCE',
    NULL,
    'Source says case of twelve',
    NULL,
    NULL,
    'source_only',
    true,
    false,
    'verified'
  ),
  (
    '5a5a0000-0000-4000-8000-000000000403'::uuid,
    '5a5a0000-0000-4000-8000-000000000303'::uuid,
    '5a5a0000-0000-4000-8000-000000000201'::uuid,
    'TEST-UNKNOWN',
    'TEST-UNKNOWN',
    NULL,
    NULL,
    NULL,
    NULL,
    'unknown',
    true,
    false,
    'pending'
  ),
  (
    '5a5a0000-0000-4000-8000-000000000404'::uuid,
    '5a5a0000-0000-4000-8000-000000000304'::uuid,
    '5a5a0000-0000-4000-8000-000000000201'::uuid,
    'TEST-DISCONTINUED',
    'TEST-DISCONTINUED',
    NULL,
    '1 Each',
    1,
    'each',
    'verified',
    false,
    true,
    'verified'
  ),
  (
    '5a5a0000-0000-4000-8000-000000000405'::uuid,
    '5a5a0000-0000-4000-8000-000000000305'::uuid,
    '5a5a0000-0000-4000-8000-000000000201'::uuid,
    'TEST-CONFLICT',
    'TEST-CONFLICT',
    NULL,
    NULL,
    NULL,
    NULL,
    'unknown',
    true,
    false,
    'verified'
  );

SET LOCAL ROLE authenticated;

DO $phase5a5_adoption_behavior$
DECLARE
  _organization_id constant uuid := '5a5a0000-0000-4000-8000-000000000101';
  _catalog_vendor_id constant uuid := '5a5a0000-0000-4000-8000-000000000201';
  _global_rows_before jsonb;
  _global_rows_after jsonb;
  _global_counts_before jsonb;
  _global_counts_after jsonb;
  first_result jsonb;
  second_result jsonb;
  organization_vendor_id uuid;
BEGIN
  WITH fixture_rows AS (
    SELECT
      'catalog_vendors'::text AS table_name,
      vendor.id,
      to_jsonb(vendor) AS row_data
    FROM public.catalog_vendors vendor
    WHERE vendor.id = _catalog_vendor_id

    UNION ALL

    SELECT
      'catalog_products',
      product.id,
      to_jsonb(product)
    FROM public.catalog_products product
    WHERE product.id BETWEEN
      '5a5a0000-0000-4000-8000-000000000301'::uuid AND
      '5a5a0000-0000-4000-8000-000000000306'::uuid

    UNION ALL

    SELECT
      'catalog_vendor_products',
      vendor_product.id,
      to_jsonb(vendor_product)
    FROM public.catalog_vendor_products vendor_product
    WHERE vendor_product.id BETWEEN
      '5a5a0000-0000-4000-8000-000000000401'::uuid AND
      '5a5a0000-0000-4000-8000-000000000405'::uuid
  )
  SELECT coalesce(
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
    'catalog_vendor_products', (SELECT count(*) FROM public.catalog_vendor_products)
  )
  INTO _global_counts_before;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub',
    '5a5a0000-0000-4000-8000-000000000002',
    true
  );

  BEGIN
    PERFORM public.adopt_catalog_vendor_product(
      _organization_id,
      '5a5a0000-0000-4000-8000-000000000401'::uuid
    );
    RAISE EXCEPTION 'Staff adoption unexpectedly succeeded';
  EXCEPTION
    WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    INSERT INTO public.vendors (
      id,
      organization_id,
      name,
      normalized_name,
      active,
      catalog_vendor_id
    ) VALUES (
      '5a5a0000-0000-4000-8000-000000000503'::uuid,
      _organization_id,
      'Phase 5A.5 Unauthorized Direct Vendor',
      'phase 5a 5 unauthorized direct vendor',
      true,
      '5a5a0000-0000-4000-8000-000000000201'::uuid
    );
    RAISE EXCEPTION 'Staff direct organization catalog write unexpectedly succeeded';
  EXCEPTION
    WHEN insufficient_privilege THEN NULL;
  END;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub',
    '5a5a0000-0000-4000-8000-000000000001',
    true
  );

  BEGIN
    PERFORM public.adopt_catalog_vendor_product(
      '5a5a0000-0000-4000-8000-000000000102'::uuid,
      '5a5a0000-0000-4000-8000-000000000401'::uuid
    );
    RAISE EXCEPTION 'Cross-organization adoption unexpectedly succeeded';
  EXCEPTION
    WHEN insufficient_privilege THEN NULL;
  END;

  IF EXISTS (
    SELECT 1 FROM public.vendors
    WHERE organization_id = '5a5a0000-0000-4000-8000-000000000102'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.products
    WHERE organization_id = '5a5a0000-0000-4000-8000-000000000102'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.vendor_products
    WHERE organization_id = '5a5a0000-0000-4000-8000-000000000102'::uuid
  ) THEN
    RAISE EXCEPTION 'Cross-organization denial left organization catalog rows';
  END IF;

  first_result := public.adopt_catalog_vendor_product(
    _organization_id,
    '5a5a0000-0000-4000-8000-000000000401'::uuid
  );

  IF (first_result->>'vendorCreated')::boolean IS DISTINCT FROM true
     OR (first_result->>'productCreated')::boolean IS DISTINCT FROM true
     OR (first_result->>'vendorProductCreated')::boolean IS DISTINCT FROM true
     OR (first_result->>'alreadyAdopted')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'First adoption did not report exactly three created organization rows: %', first_result;
  END IF;

  organization_vendor_id := (first_result->>'vendorId')::uuid;

  IF (SELECT count(*) FROM public.vendors WHERE organization_id = _organization_id) <> 1
     OR (SELECT count(*) FROM public.products WHERE organization_id = _organization_id) <> 1
     OR (SELECT count(*) FROM public.vendor_products WHERE organization_id = _organization_id) <> 1 THEN
    RAISE EXCEPTION 'First adoption did not create exactly one vendor, product, and vendor product';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.vendor_products organization_vendor_product
    JOIN public.vendors organization_vendor
      ON organization_vendor.id = organization_vendor_product.vendor_id
     AND organization_vendor.organization_id = organization_vendor_product.organization_id
    JOIN public.products organization_product
      ON organization_product.id = organization_vendor_product.product_id
     AND organization_product.organization_id = organization_vendor_product.organization_id
    WHERE organization_vendor_product.id = (first_result->>'vendorProductId')::uuid
      AND organization_vendor_product.organization_id = _organization_id
      AND organization_vendor_product.catalog_vendor_product_id =
        '5a5a0000-0000-4000-8000-000000000401'::uuid
      AND organization_vendor.catalog_vendor_id = _catalog_vendor_id
      AND organization_product.catalog_product_id =
        '5a5a0000-0000-4000-8000-000000000301'::uuid
      AND organization_product.id = (first_result->>'productId')::uuid
      AND organization_vendor.id = organization_vendor_id
  ) THEN
    RAISE EXCEPTION 'First adoption did not populate the exact catalog links';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.products organization_product
    JOIN public.vendor_products organization_vendor_product
      ON organization_vendor_product.product_id = organization_product.id
     AND organization_vendor_product.organization_id = organization_product.organization_id
    WHERE organization_product.id = (first_result->>'productId')::uuid
      AND organization_product.unit = 'each'
      AND organization_product.unit_of_measure = 'each'
      AND organization_product.pack_size = '12 Each / Box'
      AND organization_vendor_product.unit_of_measure = 'each'
      AND organization_vendor_product.package_size = '12 Each / Box'
  ) THEN
    RAISE EXCEPTION 'Verified package data was not copied under the verified rule';
  END IF;

  second_result := public.adopt_catalog_vendor_product(
    _organization_id,
    '5a5a0000-0000-4000-8000-000000000401'::uuid
  );

  IF (second_result->>'alreadyAdopted')::boolean IS DISTINCT FROM true
     OR second_result->>'vendorId' IS DISTINCT FROM first_result->>'vendorId'
     OR second_result->>'productId' IS DISTINCT FROM first_result->>'productId'
     OR second_result->>'vendorProductId' IS DISTINCT FROM first_result->>'vendorProductId'
     OR (second_result->>'vendorCreated')::boolean IS DISTINCT FROM false
     OR (second_result->>'productCreated')::boolean IS DISTINCT FROM false
     OR (second_result->>'vendorProductCreated')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'Repeated adoption was not idempotent: first %, second %', first_result, second_result;
  END IF;

  IF (SELECT count(*) FROM public.vendors WHERE organization_id = _organization_id) <> 1
     OR (SELECT count(*) FROM public.products WHERE organization_id = _organization_id) <> 1
     OR (SELECT count(*) FROM public.vendor_products WHERE organization_id = _organization_id) <> 1 THEN
    RAISE EXCEPTION 'Repeated adoption created duplicate organization rows';
  END IF;

  PERFORM public.adopt_catalog_vendor_product(
    _organization_id,
    '5a5a0000-0000-4000-8000-000000000402'::uuid
  );
  PERFORM public.adopt_catalog_vendor_product(
    _organization_id,
    '5a5a0000-0000-4000-8000-000000000403'::uuid
  );

  IF NOT EXISTS (
    SELECT 1
    FROM public.products
    WHERE organization_id = _organization_id
      AND catalog_product_id = '5a5a0000-0000-4000-8000-000000000302'::uuid
      AND unit IS NULL
      AND unit_of_measure IS NULL
      AND pack_size = 'Source says case of twelve'
  ) OR NOT EXISTS (
    SELECT 1
    FROM public.vendor_products
    WHERE organization_id = _organization_id
      AND catalog_vendor_product_id = '5a5a0000-0000-4000-8000-000000000402'::uuid
      AND unit_of_measure IS NULL
      AND package_size = 'Source says case of twelve'
  ) THEN
    RAISE EXCEPTION 'Source-only adoption invented verified unit data or lost source package wording';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.products
    WHERE organization_id = _organization_id
      AND catalog_product_id = '5a5a0000-0000-4000-8000-000000000303'::uuid
      AND unit IS NULL
      AND unit_of_measure IS NULL
      AND pack_size IS NULL
  ) OR NOT EXISTS (
    SELECT 1
    FROM public.vendor_products
    WHERE organization_id = _organization_id
      AND catalog_vendor_product_id = '5a5a0000-0000-4000-8000-000000000403'::uuid
      AND unit_of_measure IS NULL
      AND package_size IS NULL
  ) THEN
    RAISE EXCEPTION 'Unknown-package adoption invented package normalization';
  END IF;

  PERFORM public.adopt_catalog_vendor_product(
    _organization_id,
    '5a5a0000-0000-4000-8000-000000000404'::uuid
  );

  IF NOT EXISTS (
    SELECT 1
    FROM public.products
    WHERE organization_id = _organization_id
      AND catalog_product_id = '5a5a0000-0000-4000-8000-000000000304'::uuid
      AND NOT active
      AND NOT approved
      AND NOT staff_requestable
  ) OR NOT EXISTS (
    SELECT 1
    FROM public.vendor_products
    WHERE organization_id = _organization_id
      AND catalog_vendor_product_id = '5a5a0000-0000-4000-8000-000000000404'::uuid
      AND NOT active
  ) THEN
    RAISE EXCEPTION 'Discontinued catalog identity was not safely adopted as inactive';
  END IF;

  INSERT INTO public.products (
    id,
    organization_id,
    name,
    unit,
    approved,
    normalized_name,
    preferred_vendor_id,
    active,
    staff_requestable,
    catalog_product_id
  ) VALUES (
    '5a5a0000-0000-4000-8000-000000000501'::uuid,
    _organization_id,
    'Phase 5A.5 Conflicting Local Product',
    NULL,
    true,
    'phase 5a 5 conflicting local product',
    organization_vendor_id,
    true,
    true,
    '5a5a0000-0000-4000-8000-000000000306'::uuid
  );

  INSERT INTO public.vendor_products (
    id,
    organization_id,
    vendor_id,
    product_id,
    vendor_sku,
    active
  ) VALUES (
    '5a5a0000-0000-4000-8000-000000000502'::uuid,
    _organization_id,
    organization_vendor_id,
    '5a5a0000-0000-4000-8000-000000000501'::uuid,
    'TEST-CONFLICT',
    true
  );

  BEGIN
    PERFORM public.adopt_catalog_vendor_product(
      _organization_id,
      '5a5a0000-0000-4000-8000-000000000405'::uuid
    );
    RAISE EXCEPTION 'Conflicting local vendor-SKU identity was silently relinked';
  EXCEPTION
    WHEN unique_violation THEN NULL;
  END;

  IF NOT EXISTS (
    SELECT 1
    FROM public.products
    WHERE id = '5a5a0000-0000-4000-8000-000000000501'::uuid
      AND catalog_product_id = '5a5a0000-0000-4000-8000-000000000306'::uuid
  ) OR NOT EXISTS (
    SELECT 1
    FROM public.vendor_products
    WHERE id = '5a5a0000-0000-4000-8000-000000000502'::uuid
      AND catalog_vendor_product_id IS NULL
  ) OR EXISTS (
    SELECT 1
    FROM public.products
    WHERE organization_id = _organization_id
      AND catalog_product_id = '5a5a0000-0000-4000-8000-000000000305'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.vendor_products
    WHERE organization_id = _organization_id
      AND catalog_vendor_product_id = '5a5a0000-0000-4000-8000-000000000405'::uuid
  ) THEN
    RAISE EXCEPTION 'Rejected vendor-SKU conflict changed organization identity links';
  END IF;

  IF (SELECT count(*) FROM public.vendors WHERE organization_id = _organization_id) <> 1
     OR (SELECT count(*) FROM public.products WHERE organization_id = _organization_id) <> 5
     OR (SELECT count(*) FROM public.vendor_products WHERE organization_id = _organization_id) <> 5 THEN
    RAISE EXCEPTION 'Final organization catalog row counts are not duplicate-free';
  END IF;

  IF EXISTS (
    SELECT catalog_vendor_id
    FROM public.vendors
    WHERE organization_id = _organization_id
      AND catalog_vendor_id IS NOT NULL
    GROUP BY catalog_vendor_id
    HAVING count(*) > 1
  ) OR EXISTS (
    SELECT catalog_product_id
    FROM public.products
    WHERE organization_id = _organization_id
      AND catalog_product_id IS NOT NULL
    GROUP BY catalog_product_id
    HAVING count(*) > 1
  ) OR EXISTS (
    SELECT catalog_vendor_product_id
    FROM public.vendor_products
    WHERE organization_id = _organization_id
      AND catalog_vendor_product_id IS NOT NULL
    GROUP BY catalog_vendor_product_id
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'Duplicate organization/global catalog links were created';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.inventory_items
    WHERE organization_id = _organization_id
  ) THEN
    RAISE EXCEPTION 'Catalog adoption created an inventory item';
  END IF;

  WITH fixture_rows AS (
    SELECT
      'catalog_vendors'::text AS table_name,
      vendor.id,
      to_jsonb(vendor) AS row_data
    FROM public.catalog_vendors vendor
    WHERE vendor.id = _catalog_vendor_id

    UNION ALL

    SELECT
      'catalog_products',
      product.id,
      to_jsonb(product)
    FROM public.catalog_products product
    WHERE product.id BETWEEN
      '5a5a0000-0000-4000-8000-000000000301'::uuid AND
      '5a5a0000-0000-4000-8000-000000000306'::uuid

    UNION ALL

    SELECT
      'catalog_vendor_products',
      vendor_product.id,
      to_jsonb(vendor_product)
    FROM public.catalog_vendor_products vendor_product
    WHERE vendor_product.id BETWEEN
      '5a5a0000-0000-4000-8000-000000000401'::uuid AND
      '5a5a0000-0000-4000-8000-000000000405'::uuid
  )
  SELECT coalesce(
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
    'catalog_vendor_products', (SELECT count(*) FROM public.catalog_vendor_products)
  )
  INTO _global_counts_after;

  IF _global_rows_after IS DISTINCT FROM _global_rows_before THEN
    RAISE EXCEPTION 'Adoption changed a global catalog fixture row';
  END IF;

  IF _global_counts_after IS DISTINCT FROM _global_counts_before THEN
    RAISE EXCEPTION 'Adoption changed a global catalog table row count';
  END IF;
END
$phase5a5_adoption_behavior$;

RESET ROLE;

SELECT
  'phase5a5_catalog_adoption_behavior' AS check_name,
  true AS passed,
  'PASS' AS result;

ROLLBACK;

-- This assertion is read-only and proves fixture rows did not persist.
DO $phase5a5_no_persistence$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM auth.users
    WHERE id IN (
      '5a5a0000-0000-4000-8000-000000000001'::uuid,
      '5a5a0000-0000-4000-8000-000000000002'::uuid,
      '5a5a0000-0000-4000-8000-000000000003'::uuid
    )
  ) OR EXISTS (
    SELECT 1
    FROM public.organizations
    WHERE id IN (
      '5a5a0000-0000-4000-8000-000000000101'::uuid,
      '5a5a0000-0000-4000-8000-000000000102'::uuid
    )
  ) OR EXISTS (
    SELECT 1
    FROM public.organization_memberships
    WHERE id BETWEEN
      '5a5a0000-0000-4000-8000-000000000601'::uuid AND
      '5a5a0000-0000-4000-8000-000000000603'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.profiles
    WHERE id IN (
      '5a5a0000-0000-4000-8000-000000000001'::uuid,
      '5a5a0000-0000-4000-8000-000000000002'::uuid,
      '5a5a0000-0000-4000-8000-000000000003'::uuid
    )
  ) OR EXISTS (
    SELECT 1
    FROM public.catalog_vendors
    WHERE id = '5a5a0000-0000-4000-8000-000000000201'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.catalog_products
    WHERE id BETWEEN
      '5a5a0000-0000-4000-8000-000000000301'::uuid AND
      '5a5a0000-0000-4000-8000-000000000306'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.catalog_vendor_products
    WHERE id BETWEEN
      '5a5a0000-0000-4000-8000-000000000401'::uuid AND
      '5a5a0000-0000-4000-8000-000000000405'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.vendors
    WHERE organization_id IN (
      '5a5a0000-0000-4000-8000-000000000101'::uuid,
      '5a5a0000-0000-4000-8000-000000000102'::uuid
    )
  ) OR EXISTS (
    SELECT 1
    FROM public.products
    WHERE organization_id IN (
      '5a5a0000-0000-4000-8000-000000000101'::uuid,
      '5a5a0000-0000-4000-8000-000000000102'::uuid
    )
  ) OR EXISTS (
    SELECT 1
    FROM public.vendor_products
    WHERE organization_id IN (
      '5a5a0000-0000-4000-8000-000000000101'::uuid,
      '5a5a0000-0000-4000-8000-000000000102'::uuid
    )
  ) OR EXISTS (
    SELECT 1
    FROM public.inventory_items
    WHERE organization_id IN (
      '5a5a0000-0000-4000-8000-000000000101'::uuid,
      '5a5a0000-0000-4000-8000-000000000102'::uuid
    )
  ) THEN
    RAISE EXCEPTION 'Phase 5A.5 rollback-only test left persistent fixture rows';
  END IF;
END
$phase5a5_no_persistence$;

SELECT
  'phase5a5_catalog_adoption_post_rollback' AS check_name,
  true AS passed,
  'PASS' AS result;
