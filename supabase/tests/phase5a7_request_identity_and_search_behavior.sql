-- Phase 5A.7 rollback-only behavioral verification.
-- Run in the Supabase SQL Editor only after deploying the Phase 5A.7 migration.
-- All fixture and request writes occur inside this transaction and are rolled back.

BEGIN;

DO $phase5a7_fixture_guard$
BEGIN
  IF EXISTS (
    SELECT 1 FROM auth.users
    WHERE id BETWEEN
      '5a7a0000-0000-4000-8000-000000000001'::uuid AND
      '5a7a0000-0000-4000-8000-000000000004'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.organizations
    WHERE id BETWEEN
      '5a7a0000-0000-4000-8000-000000000101'::uuid AND
      '5a7a0000-0000-4000-8000-000000000102'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.catalog_vendors
    WHERE id = '5a7a0000-0000-4000-8000-000000000201'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.catalog_products
    WHERE id BETWEEN
      '5a7a0000-0000-4000-8000-000000000301'::uuid AND
      '5a7a0000-0000-4000-8000-000000000305'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.catalog_vendor_products
    WHERE id BETWEEN
      '5a7a0000-0000-4000-8000-000000000401'::uuid AND
      '5a7a0000-0000-4000-8000-000000000405'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.teams
    WHERE id BETWEEN
      '5a7a0000-0000-4000-8000-000000000111'::uuid AND
      '5a7a0000-0000-4000-8000-000000000112'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.locations
    WHERE id BETWEEN
      '5a7a0000-0000-4000-8000-000000000121'::uuid AND
      '5a7a0000-0000-4000-8000-000000000122'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.organization_memberships
    WHERE id BETWEEN
      '5a7a0000-0000-4000-8000-000000000131'::uuid AND
      '5a7a0000-0000-4000-8000-000000000134'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.vendors
    WHERE id BETWEEN
      '5a7a0000-0000-4000-8000-000000000501'::uuid AND
      '5a7a0000-0000-4000-8000-000000000502'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.products
    WHERE id BETWEEN
      '5a7a0000-0000-4000-8000-000000000601'::uuid AND
      '5a7a0000-0000-4000-8000-000000000604'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.vendor_products
    WHERE id BETWEEN
      '5a7a0000-0000-4000-8000-000000000701'::uuid AND
      '5a7a0000-0000-4000-8000-000000000702'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.inventory_items
    WHERE id BETWEEN
      '5a7a0000-0000-4000-8000-000000000801'::uuid AND
      '5a7a0000-0000-4000-8000-000000000803'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.supply_requests
    WHERE id = '5a7a0000-0000-4000-8000-000000000901'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.supply_request_items
    WHERE id = '5a7a0000-0000-4000-8000-000000000902'::uuid
  ) THEN
    RAISE EXCEPTION 'Phase 5A.7 rollback-test fixture IDs already exist';
  END IF;
END
$phase5a7_fixture_guard$;

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
    '5a7a0000-0000-4000-8000-000000000001'::uuid,
    'authenticated',
    'authenticated',
    'phase5a7-owner@example.invalid',
    '',
    now(),
    '{}'::jsonb,
    '{"full_name":"Phase 5A.7 Owner"}'::jsonb,
    now(),
    now()
  ),
  (
    '5a7a0000-0000-4000-8000-000000000002'::uuid,
    'authenticated',
    'authenticated',
    'phase5a7-admin@example.invalid',
    '',
    now(),
    '{}'::jsonb,
    '{"full_name":"Phase 5A.7 Admin"}'::jsonb,
    now(),
    now()
  ),
  (
    '5a7a0000-0000-4000-8000-000000000003'::uuid,
    'authenticated',
    'authenticated',
    'phase5a7-staff@example.invalid',
    '',
    now(),
    '{}'::jsonb,
    '{"full_name":"Phase 5A.7 Staff"}'::jsonb,
    now(),
    now()
  ),
  (
    '5a7a0000-0000-4000-8000-000000000004'::uuid,
    'authenticated',
    'authenticated',
    'phase5a7-other-owner@example.invalid',
    '',
    now(),
    '{}'::jsonb,
    '{"full_name":"Phase 5A.7 Other Owner"}'::jsonb,
    now(),
    now()
  );

INSERT INTO public.organizations (id, name, created_by)
VALUES
  (
    '5a7a0000-0000-4000-8000-000000000101'::uuid,
    'Phase 5A.7 Request Organization',
    '5a7a0000-0000-4000-8000-000000000001'::uuid
  ),
  (
    '5a7a0000-0000-4000-8000-000000000102'::uuid,
    'Phase 5A.7 Other Organization',
    '5a7a0000-0000-4000-8000-000000000004'::uuid
  );

INSERT INTO public.teams (id, organization_id, name, active)
VALUES
  (
    '5a7a0000-0000-4000-8000-000000000111'::uuid,
    '5a7a0000-0000-4000-8000-000000000101'::uuid,
    'Phase 5A.7 Team',
    true
  ),
  (
    '5a7a0000-0000-4000-8000-000000000112'::uuid,
    '5a7a0000-0000-4000-8000-000000000102'::uuid,
    'Phase 5A.7 Other Team',
    true
  );

INSERT INTO public.locations (id, organization_id, name, active)
VALUES
  (
    '5a7a0000-0000-4000-8000-000000000121'::uuid,
    '5a7a0000-0000-4000-8000-000000000101'::uuid,
    'Phase 5A.7 Location',
    true
  ),
  (
    '5a7a0000-0000-4000-8000-000000000122'::uuid,
    '5a7a0000-0000-4000-8000-000000000102'::uuid,
    'Phase 5A.7 Other Location',
    true
  );

INSERT INTO public.organization_memberships (
  id,
  organization_id,
  user_id,
  role,
  active,
  default_team_id,
  default_location_id
)
VALUES
  (
    '5a7a0000-0000-4000-8000-000000000131'::uuid,
    '5a7a0000-0000-4000-8000-000000000101'::uuid,
    '5a7a0000-0000-4000-8000-000000000001'::uuid,
    'owner'::public.org_role,
    true,
    '5a7a0000-0000-4000-8000-000000000111'::uuid,
    '5a7a0000-0000-4000-8000-000000000121'::uuid
  ),
  (
    '5a7a0000-0000-4000-8000-000000000132'::uuid,
    '5a7a0000-0000-4000-8000-000000000101'::uuid,
    '5a7a0000-0000-4000-8000-000000000002'::uuid,
    'admin'::public.org_role,
    true,
    '5a7a0000-0000-4000-8000-000000000111'::uuid,
    '5a7a0000-0000-4000-8000-000000000121'::uuid
  ),
  (
    '5a7a0000-0000-4000-8000-000000000133'::uuid,
    '5a7a0000-0000-4000-8000-000000000101'::uuid,
    '5a7a0000-0000-4000-8000-000000000003'::uuid,
    'staff'::public.org_role,
    true,
    '5a7a0000-0000-4000-8000-000000000111'::uuid,
    '5a7a0000-0000-4000-8000-000000000121'::uuid
  ),
  (
    '5a7a0000-0000-4000-8000-000000000134'::uuid,
    '5a7a0000-0000-4000-8000-000000000102'::uuid,
    '5a7a0000-0000-4000-8000-000000000004'::uuid,
    'owner'::public.org_role,
    true,
    '5a7a0000-0000-4000-8000-000000000112'::uuid,
    '5a7a0000-0000-4000-8000-000000000122'::uuid
  );

INSERT INTO public.catalog_vendors (
  id,
  name,
  normalized_name,
  active
)
VALUES (
  '5a7a0000-0000-4000-8000-000000000201'::uuid,
  'Henry Schein Phase 5A.7',
  'henry schein phase 5a 7',
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
    '5a7a0000-0000-4000-8000-000000000301'::uuid,
    'Good''N''Cheap Prewrap',
    'good n cheap prewrap',
    'Medical prewrap fixture',
    'Good''N''Cheap',
    true,
    'verified'
  ),
  (
    '5a7a0000-0000-4000-8000-000000000302'::uuid,
    'Good''N''Cheap Adhesive Stretch Tape',
    'good n cheap adhesive stretch tape',
    'Legitimate separate adhesive tape fixture',
    'Good''N''Cheap',
    true,
    'verified'
  ),
  (
    '5a7a0000-0000-4000-8000-000000000303'::uuid,
    'Accucold Medical Refrigerator',
    'accucold medical refrigerator',
    'Verified canonical Accucold identity phase5a7unlinkedpair',
    'Accucold',
    true,
    'verified'
  ),
  (
    '5a7a0000-0000-4000-8000-000000000304'::uuid,
    'Mueller Kold Towel Pink',
    'mueller kold towel pink',
    'Historical discontinued fixture',
    'Mueller',
    true,
    'verified'
  ),
  (
    '5a7a0000-0000-4000-8000-000000000305'::uuid,
    '128-5852 Reference Gauze',
    '128 5852 reference gauze',
    'Text-only ranking decoy',
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
    '5a7a0000-0000-4000-8000-000000000401'::uuid,
    '5a7a0000-0000-4000-8000-000000000301'::uuid,
    '5a7a0000-0000-4000-8000-000000000201'::uuid,
    '128-5852',
    '128-5852',
    '10 Rolls',
    10,
    'rolls',
    'verified',
    true,
    false,
    'verified'
  ),
  (
    '5a7a0000-0000-4000-8000-000000000402'::uuid,
    '5a7a0000-0000-4000-8000-000000000302'::uuid,
    '5a7a0000-0000-4000-8000-000000000201'::uuid,
    '128-5853',
    '128-5853',
    'Source says case of twelve',
    NULL,
    NULL,
    'source_only',
    true,
    false,
    'verified'
  ),
  (
    '5a7a0000-0000-4000-8000-000000000403'::uuid,
    '5a7a0000-0000-4000-8000-000000000303'::uuid,
    '5a7a0000-0000-4000-8000-000000000201'::uuid,
    '139-7157',
    '139-7157',
    NULL,
    NULL,
    NULL,
    'unknown',
    true,
    false,
    'verified'
  ),
  (
    '5a7a0000-0000-4000-8000-000000000404'::uuid,
    '5a7a0000-0000-4000-8000-000000000304'::uuid,
    '5a7a0000-0000-4000-8000-000000000201'::uuid,
    '364-0444',
    '364-0444',
    '1 Each',
    1,
    'each',
    'verified',
    false,
    true,
    'verified'
  ),
  (
    '5a7a0000-0000-4000-8000-000000000405'::uuid,
    '5a7a0000-0000-4000-8000-000000000305'::uuid,
    '5a7a0000-0000-4000-8000-000000000201'::uuid,
    'TEXT-ONLY-5852',
    'TEXT-ONLY-5852',
    NULL,
    NULL,
    NULL,
    'unknown',
    true,
    false,
    'verified'
  );

INSERT INTO public.vendors (
  id,
  organization_id,
  name,
  normalized_name,
  active,
  catalog_vendor_id
)
VALUES
  (
    '5a7a0000-0000-4000-8000-000000000501'::uuid,
    '5a7a0000-0000-4000-8000-000000000101'::uuid,
    'Henry Schein Phase 5A.7',
    'henry schein phase 5a 7',
    true,
    '5a7a0000-0000-4000-8000-000000000201'::uuid
  ),
  (
    '5a7a0000-0000-4000-8000-000000000502'::uuid,
    '5a7a0000-0000-4000-8000-000000000102'::uuid,
    'Other Organization Vendor',
    'other organization vendor',
    true,
    NULL
  );

INSERT INTO public.products (
  id,
  organization_id,
  name,
  normalized_name,
  description,
  unit_of_measure,
  active,
  staff_requestable,
  catalog_product_id
)
VALUES
  (
    '5a7a0000-0000-4000-8000-000000000601'::uuid,
    '5a7a0000-0000-4000-8000-000000000101'::uuid,
    'Good''N''Cheap Prewrap',
'good n cheap prewrap',
NULL,
'roll',
    true,
    true,
    '5a7a0000-0000-4000-8000-000000000301'::uuid
  ),
  (
    '5a7a0000-0000-4000-8000-000000000602'::uuid,
    '5a7a0000-0000-4000-8000-000000000101'::uuid,
    'Good''N''Cheap Adhesive Stretch Tape',
'good n cheap adhesive stretch tape',
NULL,
'roll',
    true,
    true,
    '5a7a0000-0000-4000-8000-000000000302'::uuid
  ),
  (
    '5a7a0000-0000-4000-8000-000000000603'::uuid,
    '5a7a0000-0000-4000-8000-000000000101'::uuid,
    'Accucold Medical Refrigerator',
'accucold medical refrigerator',
NULL,
'each',
    true,
    true,
    NULL
  ),
  (
    '5a7a0000-0000-4000-8000-000000000604'::uuid,
    '5a7a0000-0000-4000-8000-000000000102'::uuid,
   'Other Organization Product',
'other organization product',
NULL,
'each',
    true,
    true,
    NULL
  );

INSERT INTO public.vendor_products (
  id,
  organization_id,
  vendor_id,
  product_id,
  vendor_sku,
  unit_of_measure,
  active,
  catalog_vendor_product_id
)
VALUES
  (
    '5a7a0000-0000-4000-8000-000000000701'::uuid,
    '5a7a0000-0000-4000-8000-000000000101'::uuid,
    '5a7a0000-0000-4000-8000-000000000501'::uuid,
    '5a7a0000-0000-4000-8000-000000000601'::uuid,
    '128-5852',
    'roll',
    true,
    '5a7a0000-0000-4000-8000-000000000401'::uuid
  ),
  (
    '5a7a0000-0000-4000-8000-000000000702'::uuid,
    '5a7a0000-0000-4000-8000-000000000101'::uuid,
    '5a7a0000-0000-4000-8000-000000000501'::uuid,
    '5a7a0000-0000-4000-8000-000000000602'::uuid,
    '128-5853',
    'roll',
    true,
    '5a7a0000-0000-4000-8000-000000000402'::uuid
  );

INSERT INTO public.inventory_items (
  id,
  organization_id,
  sku,
  name,
  quantity,
  unit,
  active,
  product_id
)
VALUES
  (
    '5a7a0000-0000-4000-8000-000000000801'::uuid,
    '5a7a0000-0000-4000-8000-000000000101'::uuid,
    '128-5852',
    'Good''N''Cheap Prewrap',
    3,
    'roll',
    true,
    '5a7a0000-0000-4000-8000-000000000601'::uuid
  ),
  (
    '5a7a0000-0000-4000-8000-000000000802'::uuid,
    '5a7a0000-0000-4000-8000-000000000102'::uuid,
    'OTHER-ORG',
    'Other Organization Inventory',
    1,
    'each',
    true,
    '5a7a0000-0000-4000-8000-000000000604'::uuid
  ),
  (
    '5a7a0000-0000-4000-8000-000000000803'::uuid,
    '5a7a0000-0000-4000-8000-000000000101'::uuid,
    'LOCAL-UNLINKED',
    'Historical Local Inventory Item',
    2,
    'each',
    true,
    NULL
  );

-- One historical product-only request proves that the migration and new submissions
-- leave existing rows unchanged.
INSERT INTO public.supply_requests (
  id,
  organization_id,
  requested_by,
  team_id,
  location_id,
  product_id,
  request_type,
  quantity,
  status
)
VALUES (
  '5a7a0000-0000-4000-8000-000000000901'::uuid,
  '5a7a0000-0000-4000-8000-000000000101'::uuid,
  '5a7a0000-0000-4000-8000-000000000003'::uuid,
  '5a7a0000-0000-4000-8000-000000000111'::uuid,
  '5a7a0000-0000-4000-8000-000000000121'::uuid,
  '5a7a0000-0000-4000-8000-000000000603'::uuid,
  'reorder',
  1,
  'submitted'
);

INSERT INTO public.supply_request_items (
  id,
  organization_id,
  supply_request_id,
  product_id,
  quantity,
  unit
)
VALUES (
  '5a7a0000-0000-4000-8000-000000000902'::uuid,
  '5a7a0000-0000-4000-8000-000000000101'::uuid,
  '5a7a0000-0000-4000-8000-000000000901'::uuid,
  '5a7a0000-0000-4000-8000-000000000603'::uuid,
  1,
  'each'
);

-- ACL denial is checked as anon before authenticated behavior.
SET LOCAL ROLE anon;
DO $phase5a7_anon_search$
BEGIN
  BEGIN
    PERFORM *
    FROM public.search_supply_request_products(
      '5a7a0000-0000-4000-8000-000000000101'::uuid,
      '128-5852',
      20
    );
    RAISE EXCEPTION 'Anon search unexpectedly succeeded';
  EXCEPTION
    WHEN insufficient_privilege THEN NULL;
  END;
END
$phase5a7_anon_search$;
RESET ROLE;

SET LOCAL ROLE authenticated;

DO $phase5a7_behavior$
DECLARE
  _organization_id constant uuid := '5a7a0000-0000-4000-8000-000000000101';
  _other_organization_id constant uuid := '5a7a0000-0000-4000-8000-000000000102';
  _team_id constant uuid := '5a7a0000-0000-4000-8000-000000000111';
  _location_id constant uuid := '5a7a0000-0000-4000-8000-000000000121';
  _global_rows_before jsonb;
  _global_rows_after jsonb;
  _local_rows_before jsonb;
  _local_rows_after jsonb;
  _historical_before jsonb;
  _historical_after jsonb;
  _result jsonb;
  _request_id uuid;
  _count integer;
BEGIN
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub',
    '5a7a0000-0000-4000-8000-000000000002',
    true
  );

  WITH fixture_rows AS (
    SELECT 'catalog_vendors'::text AS table_name, vendor.id, to_jsonb(vendor) AS row_data
    FROM public.catalog_vendors vendor
    WHERE vendor.id = '5a7a0000-0000-4000-8000-000000000201'::uuid
    UNION ALL
    SELECT 'catalog_products', product.id, to_jsonb(product)
    FROM public.catalog_products product
    WHERE product.id BETWEEN
      '5a7a0000-0000-4000-8000-000000000301'::uuid AND
      '5a7a0000-0000-4000-8000-000000000305'::uuid
    UNION ALL
    SELECT 'catalog_vendor_products', vendor_product.id, to_jsonb(vendor_product)
    FROM public.catalog_vendor_products vendor_product
    WHERE vendor_product.id BETWEEN
      '5a7a0000-0000-4000-8000-000000000401'::uuid AND
      '5a7a0000-0000-4000-8000-000000000405'::uuid
  )
  SELECT pg_catalog.jsonb_object_agg(
    table_name || ':' || id::text,
    row_data ORDER BY table_name, id
  )
  INTO _global_rows_before
  FROM fixture_rows;

  WITH fixture_rows AS (
    SELECT 'vendors'::text AS table_name, vendor.id, to_jsonb(vendor) AS row_data
    FROM public.vendors vendor
    WHERE vendor.organization_id IN (_organization_id, _other_organization_id)
    UNION ALL
    SELECT 'products', product.id, to_jsonb(product)
    FROM public.products product
    WHERE product.organization_id IN (_organization_id, _other_organization_id)
    UNION ALL
    SELECT 'vendor_products', vendor_product.id, to_jsonb(vendor_product)
    FROM public.vendor_products vendor_product
    WHERE vendor_product.organization_id IN (_organization_id, _other_organization_id)
    UNION ALL
    SELECT 'inventory_items', inventory.id, to_jsonb(inventory)
    FROM public.inventory_items inventory
    WHERE inventory.organization_id IN (_organization_id, _other_organization_id)
  )
  SELECT pg_catalog.jsonb_object_agg(
    table_name || ':' || id::text,
    row_data ORDER BY table_name, id
  )
  INTO _local_rows_before
  FROM fixture_rows;

  SELECT pg_catalog.jsonb_build_object(
    'request', to_jsonb(request),
    'item', to_jsonb(item)
  )
  INTO _historical_before
  FROM public.supply_requests request
  JOIN public.supply_request_items item
    ON item.supply_request_id = request.id
   AND item.organization_id = request.organization_id
  WHERE request.id = '5a7a0000-0000-4000-8000-000000000901'::uuid;

  -- Staff, owner, and admin all use the request search surface.
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub',
    '5a7a0000-0000-4000-8000-000000000003',
    true
  );
  SELECT count(*) INTO _count
  FROM public.search_supply_request_products(_organization_id, '128-5852', 20);
  IF _count = 0 THEN RAISE EXCEPTION 'Staff could not search own organization'; END IF;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub',
    '5a7a0000-0000-4000-8000-000000000001',
    true
  );
  SELECT count(*) INTO _count
  FROM public.search_supply_request_products(_organization_id, '128-5852', 20);
  IF _count = 0 THEN RAISE EXCEPTION 'Owner could not search request products'; END IF;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub',
    '5a7a0000-0000-4000-8000-000000000002',
    true
  );
  SELECT count(*) INTO _count
  FROM public.search_supply_request_products(_organization_id, '128-5852', 20);
  IF _count = 0 THEN RAISE EXCEPTION 'Admin could not search request products'; END IF;

  -- A member of a different organization is a nonmember for this scope.
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub',
    '5a7a0000-0000-4000-8000-000000000004',
    true
  );
  BEGIN
    PERFORM *
    FROM public.search_supply_request_products(_organization_id, '128-5852', 20);
    RAISE EXCEPTION 'Nonmember search unexpectedly succeeded';
  EXCEPTION
    WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM *
    FROM public.search_supply_request_products(_organization_id, 'OTHER-ORG', 20);
    RAISE EXCEPTION 'Cross-organization search unexpectedly succeeded';
  EXCEPTION
    WHEN insufficient_privilege THEN NULL;
  END;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub',
    '5a7a0000-0000-4000-8000-000000000003',
    true
  );

  -- Exact adopted SKU wins over the product-name text decoy and carries the complete
  -- proven inventory -> product -> vendor-product -> global identity chain.
  SELECT to_jsonb(search_result)
  INTO _result
  FROM public.search_supply_request_products(_organization_id, '128-5852', 20) search_result
  LIMIT 1;
  IF _result->>'catalog_vendor_product_id' IS DISTINCT FROM
       '5a7a0000-0000-4000-8000-000000000401'
     OR _result->>'vendor_product_id' IS DISTINCT FROM
       '5a7a0000-0000-4000-8000-000000000701'
     OR _result->>'product_id' IS DISTINCT FROM
       '5a7a0000-0000-4000-8000-000000000601'
     OR _result->>'inventory_item_id' IS DISTINCT FROM
       '5a7a0000-0000-4000-8000-000000000801'
     OR _result->>'identity_source' IS DISTINCT FROM 'inventory'
     OR _result->>'package_status' IS DISTINCT FROM 'verified'
     OR _result->>'package_display' IS DISTINCT FROM '10 rolls' THEN
    RAISE EXCEPTION 'Inventory-backed exact-SKU result is incorrect: %', _result;
  END IF;

  SELECT count(*) INTO _count
  FROM public.search_supply_request_products(_organization_id, '128-5852', 20)
  WHERE result_key =
    'organization-product:5a7a0000-0000-4000-8000-000000000601';
  IF _count <> 1 THEN
    RAISE EXCEPTION 'Proven linked identities did not collapse to one result';
  END IF;

  SELECT to_jsonb(search_result)
  INTO _result
  FROM public.search_supply_request_products(_organization_id, '128-5853', 20) search_result
  LIMIT 1;
  IF _result->>'catalog_vendor_product_id' IS DISTINCT FROM
       '5a7a0000-0000-4000-8000-000000000402'
     OR _result->>'vendor_product_id' IS DISTINCT FROM
       '5a7a0000-0000-4000-8000-000000000702'
     OR _result->>'inventory_item_id' IS NOT NULL
     OR _result->>'identity_source' IS DISTINCT FROM 'organization_catalog'
     OR _result->>'package_status' IS DISTINCT FROM 'source_only'
     OR _result->>'package_display' IS DISTINCT FROM 'Source says case of twelve' THEN
    RAISE EXCEPTION 'Adopted unstocked source-only result is incorrect: %', _result;
  END IF;

SELECT count(DISTINCT result_key) INTO _count
FROM public.search_supply_request_products(_organization_id, '128-585', 20)
WHERE catalog_vendor_product_id IN (
  '5a7a0000-0000-4000-8000-000000000401'::uuid,
  '5a7a0000-0000-4000-8000-000000000402'::uuid
);

IF _count <> 2 THEN
  RAISE EXCEPTION
    '128-5852 and 128-5853 fixture identities were incorrectly deduplicated';
END IF;

  SELECT to_jsonb(search_result)
  INTO _result
  FROM public.search_supply_request_products(_organization_id, '139-7157', 20) search_result
  LIMIT 1;
  IF _result->>'catalog_vendor_product_id' IS DISTINCT FROM
       '5a7a0000-0000-4000-8000-000000000403'
     OR _result->>'product_name' IS DISTINCT FROM 'Accucold Medical Refrigerator'
     OR _result->>'product_id' IS NOT NULL
     OR _result->>'identity_source' IS DISTINCT FROM 'global_catalog'
     OR _result->>'package_status' IS DISTINCT FROM 'unknown'
     OR _result->>'package_display' IS DISTINCT FROM 'Unknown' THEN
    RAISE EXCEPTION 'Global-only Accucold identity is incorrect: %', _result;
  END IF;

  SELECT count(*) INTO _count
 FROM public.search_supply_request_products(
  _organization_id,
  'Accucold Medical Refrigerator',
  20
)
  WHERE result_key IN (
    'organization-product:5a7a0000-0000-4000-8000-000000000603',
    'catalog-vendor-product:5a7a0000-0000-4000-8000-000000000403'
  );
  IF _count <> 2 THEN
    RAISE EXCEPTION 'Unlinked local and global identities were merged by text';
  END IF;

  SELECT count(*) INTO _count
  FROM public.search_supply_request_products(_organization_id, '364-0444', 20);
  IF _count <> 0 THEN
    RAISE EXCEPTION 'Inactive/discontinued 364-0444 appeared in active staff search';
  END IF;

  SELECT to_jsonb(search_result)
  INTO _result
  FROM public.search_supply_request_products(_organization_id, 'LOCAL-UNLINKED', 20) search_result
  LIMIT 1;
  IF _result->>'inventory_item_id' IS DISTINCT FROM
       '5a7a0000-0000-4000-8000-000000000803'
     OR _result->>'product_id' IS NOT NULL
     OR _result->>'identity_source' IS DISTINCT FROM 'inventory' THEN
    RAISE EXCEPTION 'Unlinked historical inventory result is incorrect: %', _result;
  END IF;

  -- Existing product-only payload remains valid.
  _request_id := public.submit_supply_request(
    _organization_id,
    'reorder',
    _team_id,
    _location_id,
    NULL,
    jsonb_build_array(jsonb_build_object(
      'productId', '5a7a0000-0000-4000-8000-000000000603',
      'quantity', 1
    ))
  );
  SELECT to_jsonb(item) INTO _result
  FROM public.supply_request_items item
  WHERE item.supply_request_id = _request_id;
  IF _result->>'product_id' IS DISTINCT FROM
       '5a7a0000-0000-4000-8000-000000000603'
     OR _result->>'inventory_item_id' IS NOT NULL
     OR _result->>'vendor_product_id' IS NOT NULL
     OR _result->>'catalog_vendor_product_id' IS NOT NULL THEN
    RAISE EXCEPTION 'Existing product-only request compatibility failed: %', _result;
  END IF;

  -- Existing free-text payload remains valid.
  _request_id := public.submit_supply_request(
    _organization_id,
    'new_item',
    _team_id,
    _location_id,
    NULL,
    jsonb_build_array(jsonb_build_object(
      'freeTextItem', 'Custom athletic wrap',
      'quantity', 2
    ))
  );
  SELECT to_jsonb(item) INTO _result
  FROM public.supply_request_items item
  WHERE item.supply_request_id = _request_id;
  IF _result->>'free_text_item' IS DISTINCT FROM 'Custom athletic wrap'
     OR _result->>'product_id' IS NOT NULL
     OR _result->>'inventory_item_id' IS NOT NULL
     OR _result->>'vendor_product_id' IS NOT NULL
     OR _result->>'catalog_vendor_product_id' IS NOT NULL THEN
    RAISE EXCEPTION 'Existing free-text request compatibility failed: %', _result;
  END IF;

  -- Global-only identity persists without local lifecycle mutation.
  _request_id := public.submit_supply_request(
    _organization_id,
    'new_item',
    _team_id,
    _location_id,
    NULL,
    jsonb_build_array(jsonb_build_object(
      'catalogVendorProductId', '5a7a0000-0000-4000-8000-000000000403',
      'quantity', 1
    ))
  );
  SELECT to_jsonb(item) INTO _result
  FROM public.supply_request_items item
  WHERE item.supply_request_id = _request_id;
  IF _result->>'catalog_vendor_product_id' IS DISTINCT FROM
       '5a7a0000-0000-4000-8000-000000000403'
     OR _result->>'product_id' IS NOT NULL
     OR _result->>'vendor_product_id' IS NOT NULL
     OR _result->>'inventory_item_id' IS NOT NULL THEN
    RAISE EXCEPTION 'Global-only request identity was not preserved exactly: %', _result;
  END IF;

  -- Vendor product derives its organization product and exact global listing.
  _request_id := public.submit_supply_request(
    _organization_id,
    'reorder',
    _team_id,
    _location_id,
    NULL,
    jsonb_build_array(jsonb_build_object(
      'vendorProductId', '5a7a0000-0000-4000-8000-000000000702',
      'quantity', 3
    ))
  );
  SELECT to_jsonb(item) INTO _result
  FROM public.supply_request_items item
  WHERE item.supply_request_id = _request_id;
  IF _result->>'product_id' IS DISTINCT FROM
       '5a7a0000-0000-4000-8000-000000000602'
     OR _result->>'vendor_product_id' IS DISTINCT FROM
       '5a7a0000-0000-4000-8000-000000000702'
     OR _result->>'catalog_vendor_product_id' IS DISTINCT FROM
       '5a7a0000-0000-4000-8000-000000000402'
     OR _result->>'inventory_item_id' IS NOT NULL THEN
    RAISE EXCEPTION 'Adopted request identity derivation failed: %', _result;
  END IF;

  -- Inventory selection persists the complete chain returned by search.
  _request_id := public.submit_supply_request(
    _organization_id,
    'reorder',
    _team_id,
    _location_id,
    NULL,
    jsonb_build_array(jsonb_build_object(
      'inventoryItemId', '5a7a0000-0000-4000-8000-000000000801',
      'productId', '5a7a0000-0000-4000-8000-000000000601',
      'vendorProductId', '5a7a0000-0000-4000-8000-000000000701',
      'catalogVendorProductId', '5a7a0000-0000-4000-8000-000000000401',
      'quantity', 4
    ))
  );
  SELECT to_jsonb(item) INTO _result
  FROM public.supply_request_items item
  WHERE item.supply_request_id = _request_id;
  IF _result->>'inventory_item_id' IS DISTINCT FROM
       '5a7a0000-0000-4000-8000-000000000801'
     OR _result->>'product_id' IS DISTINCT FROM
       '5a7a0000-0000-4000-8000-000000000601'
     OR _result->>'vendor_product_id' IS DISTINCT FROM
       '5a7a0000-0000-4000-8000-000000000701'
     OR _result->>'catalog_vendor_product_id' IS DISTINCT FROM
       '5a7a0000-0000-4000-8000-000000000401'
     OR _result->>'unit' IS DISTINCT FROM 'roll' THEN
    RAISE EXCEPTION 'Inventory request identity was not preserved exactly: %', _result;
  END IF;

  -- An inventory identity with no product link remains exact without invented parents.
  _request_id := public.submit_supply_request(
    _organization_id,
    'reorder',
    _team_id,
    _location_id,
    NULL,
    jsonb_build_array(jsonb_build_object(
      'inventoryItemId', '5a7a0000-0000-4000-8000-000000000803',
      'quantity', 1
    ))
  );
  SELECT to_jsonb(item) INTO _result
  FROM public.supply_request_items item
  WHERE item.supply_request_id = _request_id;
  IF _result->>'inventory_item_id' IS DISTINCT FROM
       '5a7a0000-0000-4000-8000-000000000803'
     OR _result->>'product_id' IS NOT NULL
     OR _result->>'vendor_product_id' IS NOT NULL
     OR _result->>'catalog_vendor_product_id' IS NOT NULL THEN
    RAISE EXCEPTION 'Unlinked inventory request invented a parent identity: %', _result;
  END IF;

  BEGIN
    PERFORM public.submit_supply_request(
      _organization_id,
      'reorder',
      _team_id,
      _location_id,
      NULL,
      jsonb_build_array(jsonb_build_object(
        'inventoryItemId', '5a7a0000-0000-4000-8000-000000000801',
        'productId', '5a7a0000-0000-4000-8000-000000000603',
        'quantity', 1
      ))
    );
    RAISE EXCEPTION 'Conflicting client identity IDs unexpectedly succeeded';
  EXCEPTION
    WHEN invalid_parameter_value THEN NULL;
  END;

  BEGIN
    PERFORM public.submit_supply_request(
      _organization_id,
      'reorder',
      _team_id,
      _location_id,
      NULL,
      jsonb_build_array(jsonb_build_object(
        'productId', '5a7a0000-0000-4000-8000-000000000604',
        'quantity', 1
      ))
    );
    RAISE EXCEPTION 'Cross-organization local identity unexpectedly succeeded';
  EXCEPTION
    WHEN no_data_found THEN NULL;
  END;

  BEGIN
    PERFORM public.submit_supply_request(
      _organization_id,
      'new_item',
      _team_id,
      _location_id,
      NULL,
      jsonb_build_array(jsonb_build_object(
        'freeTextItem', 'Ambiguous item',
        'productId', '5a7a0000-0000-4000-8000-000000000603',
        'quantity', 1
      ))
    );
    RAISE EXCEPTION 'Free text plus structured identity unexpectedly succeeded';
  EXCEPTION
    WHEN invalid_parameter_value THEN NULL;
  END;

  BEGIN
    PERFORM public.submit_supply_request(
      _organization_id,
      'new_item',
      _team_id,
      _location_id,
      NULL,
      jsonb_build_array(jsonb_build_object('quantity', 1))
    );
    RAISE EXCEPTION 'Empty request-line identity unexpectedly succeeded';
  EXCEPTION
    WHEN invalid_parameter_value THEN NULL;
  END;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub',
    '5a7a0000-0000-4000-8000-000000000002',
    true
  );

  WITH fixture_rows AS (
    SELECT 'catalog_vendors'::text AS table_name, vendor.id, to_jsonb(vendor) AS row_data
    FROM public.catalog_vendors vendor
    WHERE vendor.id = '5a7a0000-0000-4000-8000-000000000201'::uuid
    UNION ALL
    SELECT 'catalog_products', product.id, to_jsonb(product)
    FROM public.catalog_products product
    WHERE product.id BETWEEN
      '5a7a0000-0000-4000-8000-000000000301'::uuid AND
      '5a7a0000-0000-4000-8000-000000000305'::uuid
    UNION ALL
    SELECT 'catalog_vendor_products', vendor_product.id, to_jsonb(vendor_product)
    FROM public.catalog_vendor_products vendor_product
    WHERE vendor_product.id BETWEEN
      '5a7a0000-0000-4000-8000-000000000401'::uuid AND
      '5a7a0000-0000-4000-8000-000000000405'::uuid
  )
  SELECT pg_catalog.jsonb_object_agg(
    table_name || ':' || id::text,
    row_data ORDER BY table_name, id
  )
  INTO _global_rows_after
  FROM fixture_rows;

  IF _global_rows_after IS DISTINCT FROM _global_rows_before THEN
    RAISE EXCEPTION 'Phase 5A.7 submission mutated global catalog rows';
  END IF;

  WITH fixture_rows AS (
    SELECT 'vendors'::text AS table_name, vendor.id, to_jsonb(vendor) AS row_data
    FROM public.vendors vendor
    WHERE vendor.organization_id IN (_organization_id, _other_organization_id)
    UNION ALL
    SELECT 'products', product.id, to_jsonb(product)
    FROM public.products product
    WHERE product.organization_id IN (_organization_id, _other_organization_id)
    UNION ALL
    SELECT 'vendor_products', vendor_product.id, to_jsonb(vendor_product)
    FROM public.vendor_products vendor_product
    WHERE vendor_product.organization_id IN (_organization_id, _other_organization_id)
    UNION ALL
    SELECT 'inventory_items', inventory.id, to_jsonb(inventory)
    FROM public.inventory_items inventory
    WHERE inventory.organization_id IN (_organization_id, _other_organization_id)
  )
  SELECT pg_catalog.jsonb_object_agg(
    table_name || ':' || id::text,
    row_data ORDER BY table_name, id
  )
  INTO _local_rows_after
  FROM fixture_rows;

  IF _local_rows_after IS DISTINCT FROM _local_rows_before THEN
    RAISE EXCEPTION 'Submission auto-adopted or created/changed organization inventory';
  END IF;

  SELECT pg_catalog.jsonb_build_object(
    'request', to_jsonb(request),
    'item', to_jsonb(item)
  )
  INTO _historical_after
  FROM public.supply_requests request
  JOIN public.supply_request_items item
    ON item.supply_request_id = request.id
   AND item.organization_id = request.organization_id
  WHERE request.id = '5a7a0000-0000-4000-8000-000000000901'::uuid;

  IF _historical_after IS DISTINCT FROM _historical_before THEN
    RAISE EXCEPTION 'Phase 5A.7 changed a historical request line';
  END IF;
END
$phase5a7_behavior$;

RESET ROLE;
ROLLBACK;

DO $phase5a7_no_persistence$
BEGIN
  IF EXISTS (
    SELECT 1 FROM auth.users
    WHERE id BETWEEN
      '5a7a0000-0000-4000-8000-000000000001'::uuid AND
      '5a7a0000-0000-4000-8000-000000000004'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.organizations
    WHERE id BETWEEN
      '5a7a0000-0000-4000-8000-000000000101'::uuid AND
      '5a7a0000-0000-4000-8000-000000000102'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.catalog_vendors
    WHERE id = '5a7a0000-0000-4000-8000-000000000201'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.catalog_products
    WHERE id BETWEEN
      '5a7a0000-0000-4000-8000-000000000301'::uuid AND
      '5a7a0000-0000-4000-8000-000000000305'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.catalog_vendor_products
    WHERE id BETWEEN
      '5a7a0000-0000-4000-8000-000000000401'::uuid AND
      '5a7a0000-0000-4000-8000-000000000405'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.teams
    WHERE id BETWEEN
      '5a7a0000-0000-4000-8000-000000000111'::uuid AND
      '5a7a0000-0000-4000-8000-000000000112'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.locations
    WHERE id BETWEEN
      '5a7a0000-0000-4000-8000-000000000121'::uuid AND
      '5a7a0000-0000-4000-8000-000000000122'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.organization_memberships
    WHERE id BETWEEN
      '5a7a0000-0000-4000-8000-000000000131'::uuid AND
      '5a7a0000-0000-4000-8000-000000000134'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.vendors
    WHERE id BETWEEN
      '5a7a0000-0000-4000-8000-000000000501'::uuid AND
      '5a7a0000-0000-4000-8000-000000000502'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.products
    WHERE id BETWEEN
      '5a7a0000-0000-4000-8000-000000000601'::uuid AND
      '5a7a0000-0000-4000-8000-000000000604'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.vendor_products
    WHERE id BETWEEN
      '5a7a0000-0000-4000-8000-000000000701'::uuid AND
      '5a7a0000-0000-4000-8000-000000000702'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.inventory_items
    WHERE id BETWEEN
      '5a7a0000-0000-4000-8000-000000000801'::uuid AND
      '5a7a0000-0000-4000-8000-000000000803'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.supply_requests
    WHERE id = '5a7a0000-0000-4000-8000-000000000901'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.supply_request_items
    WHERE id = '5a7a0000-0000-4000-8000-000000000902'::uuid
  ) THEN
    RAISE EXCEPTION 'Phase 5A.7 rollback-only test left persistent fixture rows';
  END IF;
END
$phase5a7_no_persistence$;

SELECT
  'phase5a7_request_identity_and_search_post_rollback' AS check_name,
  true AS passed,
  'PASS' AS result;
