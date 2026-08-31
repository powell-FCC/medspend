-- Phase 5A.6 rollback-only behavioral verification.
-- Run in the Supabase SQL Editor only after deploying the Phase 5A.6 migration.
-- All fixture writes occur inside the transaction and are rolled back.

BEGIN;

DO $phase5a6_fixture_guard$
BEGIN
  IF EXISTS (
    SELECT 1 FROM auth.users
    WHERE id BETWEEN
      '5a6a0000-0000-4000-8000-000000000001'::uuid AND
      '5a6a0000-0000-4000-8000-000000000004'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.organizations
    WHERE id BETWEEN
      '5a6a0000-0000-4000-8000-000000000101'::uuid AND
      '5a6a0000-0000-4000-8000-000000000102'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.catalog_vendors
    WHERE id = '5a6a0000-0000-4000-8000-000000000201'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.catalog_products
    WHERE id BETWEEN
      '5a6a0000-0000-4000-8000-000000000301'::uuid AND
      '5a6a0000-0000-4000-8000-000000000305'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.catalog_vendor_products
    WHERE id BETWEEN
      '5a6a0000-0000-4000-8000-000000000401'::uuid AND
      '5a6a0000-0000-4000-8000-000000000405'::uuid
  ) THEN
    RAISE EXCEPTION 'Phase 5A.6 rollback-test fixture IDs already exist';
  END IF;
END
$phase5a6_fixture_guard$;

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
    '5a6a0000-0000-4000-8000-000000000001'::uuid,
    'authenticated',
    'authenticated',
    'phase5a6-owner@example.invalid',
    '',
    now(),
    '{}'::jsonb,
    '{"full_name":"Phase 5A.6 Owner"}'::jsonb,
    now(),
    now()
  ),
  (
    '5a6a0000-0000-4000-8000-000000000002'::uuid,
    'authenticated',
    'authenticated',
    'phase5a6-admin@example.invalid',
    '',
    now(),
    '{}'::jsonb,
    '{"full_name":"Phase 5A.6 Admin"}'::jsonb,
    now(),
    now()
  ),
  (
    '5a6a0000-0000-4000-8000-000000000003'::uuid,
    'authenticated',
    'authenticated',
    'phase5a6-staff@example.invalid',
    '',
    now(),
    '{}'::jsonb,
    '{"full_name":"Phase 5A.6 Staff"}'::jsonb,
    now(),
    now()
  ),
  (
    '5a6a0000-0000-4000-8000-000000000004'::uuid,
    'authenticated',
    'authenticated',
    'phase5a6-other-owner@example.invalid',
    '',
    now(),
    '{}'::jsonb,
    '{"full_name":"Phase 5A.6 Other Owner"}'::jsonb,
    now(),
    now()
  );

INSERT INTO public.organizations (id, name, created_by)
VALUES
  (
    '5a6a0000-0000-4000-8000-000000000101'::uuid,
    'Phase 5A.6 Stocking Organization',
    '5a6a0000-0000-4000-8000-000000000001'::uuid
  ),
  (
    '5a6a0000-0000-4000-8000-000000000102'::uuid,
    'Phase 5A.6 Other Organization',
    '5a6a0000-0000-4000-8000-000000000004'::uuid
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
    '5a6a0000-0000-4000-8000-000000000601'::uuid,
    '5a6a0000-0000-4000-8000-000000000101'::uuid,
    '5a6a0000-0000-4000-8000-000000000001'::uuid,
    'owner'::public.org_role,
    true
  ),
  (
    '5a6a0000-0000-4000-8000-000000000602'::uuid,
    '5a6a0000-0000-4000-8000-000000000101'::uuid,
    '5a6a0000-0000-4000-8000-000000000002'::uuid,
    'admin'::public.org_role,
    true
  ),
  (
    '5a6a0000-0000-4000-8000-000000000603'::uuid,
    '5a6a0000-0000-4000-8000-000000000101'::uuid,
    '5a6a0000-0000-4000-8000-000000000003'::uuid,
    'staff'::public.org_role,
    true
  ),
  (
    '5a6a0000-0000-4000-8000-000000000604'::uuid,
    '5a6a0000-0000-4000-8000-000000000102'::uuid,
    '5a6a0000-0000-4000-8000-000000000004'::uuid,
    'owner'::public.org_role,
    true
  );
INSERT INTO public.catalog_vendors (
  id,
  name,
  normalized_name,
  active
)
VALUES (
  '5a6a0000-0000-4000-8000-000000000201'::uuid,
  'Phase 5A.6 Behavioral Vendor',
  'phase 5a 6 behavioral vendor',
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
    '5a6a0000-0000-4000-8000-000000000301'::uuid,
    'Phase 5A.6 Verified Product',
    'phase 5a 6 verified product',
    'Verified fixture product',
    'Fixture Manufacturer',
    true,
    'verified'
  ),
  (
    '5a6a0000-0000-4000-8000-000000000302'::uuid,
    'Phase 5A.6 Source-only Product',
    'phase 5a 6 source only product',
    'Source-only fixture product',
    'Fixture Manufacturer',
    true,
    'verified'
  ),
  (
    '5a6a0000-0000-4000-8000-000000000303'::uuid,
    'Phase 5A.6 Unknown Product',
    'phase 5a 6 unknown product',
    'Unknown-package fixture product',
    'Fixture Manufacturer',
    true,
    'verified'
  ),
  (
    '5a6a0000-0000-4000-8000-000000000304'::uuid,
    'Phase 5A.6 Discontinued Product',
    'phase 5a 6 discontinued product',
    'Discontinued fixture product',
    'Fixture Manufacturer',
    true,
    'verified'
  ),
  (
    '5a6a0000-0000-4000-8000-000000000305'::uuid,
    'Phase 5A.6 Not Adopted Product',
    'phase 5a 6 not adopted product',
    'Not-adopted fixture product',
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
    '5a6a0000-0000-4000-8000-000000000401'::uuid,
    '5a6a0000-0000-4000-8000-000000000301'::uuid,
    '5a6a0000-0000-4000-8000-000000000201'::uuid,
    'PHASE5A6-VERIFIED',
    'PHASE5A6-VERIFIED',
    '12 Each / Box',
    12,
    'each',
    'verified',
    true,
    false,
    'verified'
  ),
  (
    '5a6a0000-0000-4000-8000-000000000402'::uuid,
    '5a6a0000-0000-4000-8000-000000000302'::uuid,
    '5a6a0000-0000-4000-8000-000000000201'::uuid,
    'PHASE5A6-SOURCE',
    'PHASE5A6-SOURCE',
    'Source says case of twelve',
    NULL,
    NULL,
    'source_only',
    true,
    false,
    'verified'
  ),
  (
    '5a6a0000-0000-4000-8000-000000000403'::uuid,
    '5a6a0000-0000-4000-8000-000000000303'::uuid,
    '5a6a0000-0000-4000-8000-000000000201'::uuid,
    'PHASE5A6-UNKNOWN',
    'PHASE5A6-UNKNOWN',
    NULL,
    NULL,
    NULL,
    'unknown',
    true,
    false,
    'pending'
  ),
  (
    '5a6a0000-0000-4000-8000-000000000404'::uuid,
    '5a6a0000-0000-4000-8000-000000000304'::uuid,
    '5a6a0000-0000-4000-8000-000000000201'::uuid,
    'PHASE5A6-DISCONTINUED',
    'PHASE5A6-DISCONTINUED',
    '1 Each',
    1,
    'each',
    'verified',
    false,
    true,
    'verified'
  ),
  (
    '5a6a0000-0000-4000-8000-000000000405'::uuid,
    '5a6a0000-0000-4000-8000-000000000305'::uuid,
    '5a6a0000-0000-4000-8000-000000000201'::uuid,
    'PHASE5A6-NOT-ADOPTED',
    'PHASE5A6-NOT-ADOPTED',
    '1 Each',
    1,
    'each',
    'verified',
    true,
    false,
    'verified'
  );

SET LOCAL ROLE authenticated;

DO $phase5a6_stocking_behavior$
DECLARE
  _organization_id constant uuid := '5a6a0000-0000-4000-8000-000000000101';
  _other_organization_id constant uuid := '5a6a0000-0000-4000-8000-000000000102';
  _global_rows_before jsonb;
  _global_rows_after jsonb;
  _local_identity_counts_before jsonb;
  _local_identity_counts_after jsonb;
  _first_result jsonb;
  _second_result jsonb;
  _source_result jsonb;
  _unknown_result jsonb;
BEGIN
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub',
    '5a6a0000-0000-4000-8000-000000000003',
    true
  );

  BEGIN
    PERFORM public.stock_catalog_vendor_product(
      _organization_id,
      '5a6a0000-0000-4000-8000-000000000405'::uuid,
      NULL,
      NULL
    );
    RAISE EXCEPTION 'Staff stocking unexpectedly succeeded';
  EXCEPTION
    WHEN insufficient_privilege THEN NULL;
  END;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub',
    '5a6a0000-0000-4000-8000-000000000002',
    true
  );

  BEGIN
    PERFORM public.stock_catalog_vendor_product(
      _organization_id,
      '5a6a0000-0000-4000-8000-000000000405'::uuid,
      NULL,
      NULL
    );
    RAISE EXCEPTION 'Not-adopted catalog product unexpectedly stocked';
  EXCEPTION
    WHEN object_not_in_prerequisite_state THEN NULL;
  END;

  PERFORM public.adopt_catalog_vendor_product(
    _organization_id,
    '5a6a0000-0000-4000-8000-000000000401'::uuid
  );
  PERFORM public.adopt_catalog_vendor_product(
    _organization_id,
    '5a6a0000-0000-4000-8000-000000000402'::uuid
  );
  PERFORM public.adopt_catalog_vendor_product(
    _organization_id,
    '5a6a0000-0000-4000-8000-000000000403'::uuid
  );
  PERFORM public.adopt_catalog_vendor_product(
    _organization_id,
    '5a6a0000-0000-4000-8000-000000000404'::uuid
  );

  WITH fixture_rows AS (
    SELECT 'catalog_vendors'::text AS table_name, vendor.id, to_jsonb(vendor) AS row_data
    FROM public.catalog_vendors vendor
    WHERE vendor.id = '5a6a0000-0000-4000-8000-000000000201'::uuid

    UNION ALL

    SELECT 'catalog_products', product.id, to_jsonb(product)
    FROM public.catalog_products product
    WHERE product.id BETWEEN
      '5a6a0000-0000-4000-8000-000000000301'::uuid AND
      '5a6a0000-0000-4000-8000-000000000305'::uuid

    UNION ALL

    SELECT 'catalog_vendor_products', vendor_product.id, to_jsonb(vendor_product)
    FROM public.catalog_vendor_products vendor_product
    WHERE vendor_product.id BETWEEN
      '5a6a0000-0000-4000-8000-000000000401'::uuid AND
      '5a6a0000-0000-4000-8000-000000000405'::uuid
  )
  SELECT pg_catalog.jsonb_object_agg(
    table_name || ':' || id::text,
    row_data
    ORDER BY table_name, id
  )
  INTO _global_rows_before
  FROM fixture_rows;

  SELECT pg_catalog.jsonb_build_object(
    'vendors', (SELECT count(*) FROM public.vendors WHERE organization_id = _organization_id),
    'products', (SELECT count(*) FROM public.products WHERE organization_id = _organization_id),
    'vendorProducts', (
      SELECT count(*) FROM public.vendor_products WHERE organization_id = _organization_id
    )
  )
  INTO _local_identity_counts_before;

  _first_result := public.stock_catalog_vendor_product(
    _organization_id,
    '5a6a0000-0000-4000-8000-000000000401'::uuid,
    NULL,
    NULL
  );

  IF (_first_result->>'inventoryCreated')::boolean IS DISTINCT FROM true
     OR (_first_result->>'alreadyStocked')::boolean IS DISTINCT FROM false
     OR (_first_result->>'quantity')::numeric IS DISTINCT FROM 0
     OR _first_result->>'parLevel' IS NOT NULL
     OR _first_result->>'unit' IS DISTINCT FROM 'each' THEN
    RAISE EXCEPTION 'Verified-package stocking result is incorrect: %', _first_result;
  END IF;

  _second_result := public.stock_catalog_vendor_product(
    _organization_id,
    '5a6a0000-0000-4000-8000-000000000401'::uuid,
    NULL,
    99
  );

  IF (_second_result->>'inventoryCreated')::boolean IS DISTINCT FROM false
     OR (_second_result->>'alreadyStocked')::boolean IS DISTINCT FROM true
     OR _second_result->>'inventoryItemId' IS DISTINCT FROM _first_result->>'inventoryItemId'
     OR _second_result->>'parLevel' IS NOT NULL THEN
    RAISE EXCEPTION 'Repeated stocking was not idempotent: first %, second %',
      _first_result,
      _second_result;
  END IF;

  BEGIN
    PERFORM public.stock_catalog_vendor_product(
      _organization_id,
      '5a6a0000-0000-4000-8000-000000000402'::uuid,
      NULL,
      NULL
    );
    RAISE EXCEPTION 'Source-only package stocked without an explicit unit';
  EXCEPTION
    WHEN invalid_parameter_value THEN NULL;
  END;

  BEGIN
    PERFORM public.stock_catalog_vendor_product(
      _organization_id,
      '5a6a0000-0000-4000-8000-000000000403'::uuid,
      NULL,
      NULL
    );
    RAISE EXCEPTION 'Unknown package stocked without an explicit unit';
  EXCEPTION
    WHEN invalid_parameter_value THEN NULL;
  END;

  BEGIN
    PERFORM public.stock_catalog_vendor_product(
      _organization_id,
      '5a6a0000-0000-4000-8000-000000000404'::uuid,
      NULL,
      NULL
    );
    RAISE EXCEPTION 'Discontinued catalog product unexpectedly created active inventory';
  EXCEPTION
    WHEN object_not_in_prerequisite_state THEN NULL;
  END;

  _unknown_result := public.stock_catalog_vendor_product(
    _organization_id,
    '5a6a0000-0000-4000-8000-000000000403'::uuid,
    'each',
    NULL
  );

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub',
    '5a6a0000-0000-4000-8000-000000000001',
    true
  );

  _source_result := public.stock_catalog_vendor_product(
    _organization_id,
    '5a6a0000-0000-4000-8000-000000000402'::uuid,
    'case',
    5
  );

  IF (_source_result->>'quantity')::numeric IS DISTINCT FROM 0
     OR (_source_result->>'parLevel')::numeric IS DISTINCT FROM 5
     OR _source_result->>'unit' IS DISTINCT FROM 'case'
     OR (_unknown_result->>'quantity')::numeric IS DISTINCT FROM 0
     OR _unknown_result->>'parLevel' IS NOT NULL
     OR _unknown_result->>'unit' IS DISTINCT FROM 'each' THEN
    RAISE EXCEPTION 'Explicit source-only/unknown operational values were not preserved';
  END IF;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub',
    '5a6a0000-0000-4000-8000-000000000004',
    true
  );
  PERFORM public.adopt_catalog_vendor_product(
    _other_organization_id,
    '5a6a0000-0000-4000-8000-000000000401'::uuid
  );

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub',
    '5a6a0000-0000-4000-8000-000000000001',
    true
  );

  BEGIN
    PERFORM public.stock_catalog_vendor_product(
      _other_organization_id,
      '5a6a0000-0000-4000-8000-000000000401'::uuid,
      NULL,
      NULL
    );
    RAISE EXCEPTION 'Cross-organization stocking unexpectedly succeeded';
  EXCEPTION
    WHEN insufficient_privilege THEN NULL;
  END;

  IF (SELECT count(*) FROM public.inventory_items WHERE organization_id = _organization_id) <> 3
     OR EXISTS (
       SELECT 1
       FROM public.inventory_items inventory
       WHERE inventory.organization_id = _organization_id
         AND (
           inventory.product_id IS NULL
           OR inventory.quantity <> 0
           OR NOT inventory.active
         )
     ) THEN
    RAISE EXCEPTION 'Stocking did not create exactly three active zero-quantity linked rows';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.inventory_items inventory
    WHERE inventory.organization_id = _organization_id
      AND inventory.product_id = (
        SELECT product.id FROM public.products product
        WHERE product.organization_id = _organization_id
          AND product.catalog_product_id = '5a6a0000-0000-4000-8000-000000000304'::uuid
      )
  ) THEN
    RAISE EXCEPTION 'Discontinued catalog product has an inventory row';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.inventory_adjustments adjustment
    WHERE adjustment.organization_id = _organization_id
  ) OR EXISTS (
    SELECT 1
    FROM public.inventory_price_history history
    WHERE history.organization_id = _organization_id
  ) THEN
    RAISE EXCEPTION 'Zero-quantity stocking fabricated movement or purchase history';
  END IF;

  SELECT pg_catalog.jsonb_build_object(
    'vendors', (SELECT count(*) FROM public.vendors WHERE organization_id = _organization_id),
    'products', (SELECT count(*) FROM public.products WHERE organization_id = _organization_id),
    'vendorProducts', (
      SELECT count(*) FROM public.vendor_products WHERE organization_id = _organization_id
    )
  )
  INTO _local_identity_counts_after;

  IF _local_identity_counts_after IS DISTINCT FROM _local_identity_counts_before THEN
    RAISE EXCEPTION 'Stocking created or changed organization catalog identity counts';
  END IF;

  WITH fixture_rows AS (
    SELECT 'catalog_vendors'::text AS table_name, vendor.id, to_jsonb(vendor) AS row_data
    FROM public.catalog_vendors vendor
    WHERE vendor.id = '5a6a0000-0000-4000-8000-000000000201'::uuid

    UNION ALL

    SELECT 'catalog_products', product.id, to_jsonb(product)
    FROM public.catalog_products product
    WHERE product.id BETWEEN
      '5a6a0000-0000-4000-8000-000000000301'::uuid AND
      '5a6a0000-0000-4000-8000-000000000305'::uuid

    UNION ALL

    SELECT 'catalog_vendor_products', vendor_product.id, to_jsonb(vendor_product)
    FROM public.catalog_vendor_products vendor_product
    WHERE vendor_product.id BETWEEN
      '5a6a0000-0000-4000-8000-000000000401'::uuid AND
      '5a6a0000-0000-4000-8000-000000000405'::uuid
  )
  SELECT pg_catalog.jsonb_object_agg(
    table_name || ':' || id::text,
    row_data
    ORDER BY table_name, id
  )
  INTO _global_rows_after
  FROM fixture_rows;

  IF _global_rows_after IS DISTINCT FROM _global_rows_before THEN
    RAISE EXCEPTION 'Phase 5A.6 stocking mutated global catalog rows';
  END IF;
END
$phase5a6_stocking_behavior$;

RESET ROLE;
ROLLBACK;

DO $phase5a6_no_persistence$
BEGIN
  IF EXISTS (
    SELECT 1 FROM auth.users
    WHERE id BETWEEN
      '5a6a0000-0000-4000-8000-000000000001'::uuid AND
      '5a6a0000-0000-4000-8000-000000000004'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.organizations
    WHERE id BETWEEN
      '5a6a0000-0000-4000-8000-000000000101'::uuid AND
      '5a6a0000-0000-4000-8000-000000000102'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.catalog_vendors
    WHERE id = '5a6a0000-0000-4000-8000-000000000201'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.catalog_products
    WHERE id BETWEEN
      '5a6a0000-0000-4000-8000-000000000301'::uuid AND
      '5a6a0000-0000-4000-8000-000000000305'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.catalog_vendor_products
    WHERE id BETWEEN
      '5a6a0000-0000-4000-8000-000000000401'::uuid AND
      '5a6a0000-0000-4000-8000-000000000405'::uuid
  ) THEN
    RAISE EXCEPTION 'Phase 5A.6 rollback-only test left persistent fixture rows';
  END IF;
END
$phase5a6_no_persistence$;
