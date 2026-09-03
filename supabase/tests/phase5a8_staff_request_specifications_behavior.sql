-- Rollback-only verification for post-5A.8 staff request specifications.
BEGIN;

DO $fixture_guard$
BEGIN
  IF EXISTS (
    SELECT 1 FROM auth.users
    WHERE id = '5a8e0000-0000-4000-8000-000000000001'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.organizations
    WHERE id = '5a8e0000-0000-4000-8000-000000000100'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.catalog_vendors
    WHERE id = '5a8e0000-0000-4000-8000-000000000200'::uuid
  ) THEN
    RAISE EXCEPTION 'Post-5A.8 specification fixture IDs already exist';
  END IF;
END
$fixture_guard$;

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
VALUES (
  '5a8e0000-0000-4000-8000-000000000001'::uuid,
  'authenticated',
  'authenticated',
  'phase5a8-specification@example.invalid',
  '',
  now(),
  '{}'::jsonb,
  '{"full_name":"Phase 5A.8 Specification Staff"}'::jsonb,
  now(),
  now()
);

INSERT INTO public.organizations (id, name, created_by)
VALUES (
  '5a8e0000-0000-4000-8000-000000000100'::uuid,
  'Phase 5A.8 Specification Organization',
  '5a8e0000-0000-4000-8000-000000000001'::uuid
);

INSERT INTO public.organization_memberships (
  id,
  organization_id,
  user_id,
  role,
  active
)
VALUES (
  '5a8e0000-0000-4000-8000-000000000700'::uuid,
  '5a8e0000-0000-4000-8000-000000000100'::uuid,
  '5a8e0000-0000-4000-8000-000000000001'::uuid,
  'staff'::public.org_role,
  true
);

INSERT INTO public.catalog_vendors (id, name, normalized_name, active)
VALUES (
  '5a8e0000-0000-4000-8000-000000000200'::uuid,
  'Henry Schein Phase 5A.8',
  'henry schein phase 5a 8',
  true
);

INSERT INTO public.catalog_products (
  id,
  name,
  normalized_name,
  description,
  active,
  verification_status
)
VALUES
  (
    '5a8e0000-0000-4000-8000-000000000300'::uuid,
    'Lightplast Pro Elastic Stretch Tape',
    'lightplast pro elastic stretch tape',
    '2" x 5-yd Rolls',
    true,
    'verified'
  ),
  (
    '5a8e0000-0000-4000-8000-000000000301'::uuid,
    'Product Without Source Variant',
    'product without source variant',
    NULL,
    true,
    'verified'
  ),
  (
    '5a8e0000-0000-4000-8000-000000000302'::uuid,
    'Product With Conflicting Variants',
    'product with conflicting variants',
    'Size varies',
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
    '5a8e0000-0000-4000-8000-000000000400'::uuid,
    '5a8e0000-0000-4000-8000-000000000300'::uuid,
    '5a8e0000-0000-4000-8000-000000000200'::uuid,
    '632-0535',
    '632-0535',
    '24 rolls/case',
    24,
    'roll',
    'verified',
    true,
    false,
    'verified'
  ),
  (
    '5a8e0000-0000-4000-8000-000000000401'::uuid,
    '5a8e0000-0000-4000-8000-000000000301'::uuid,
    '5a8e0000-0000-4000-8000-000000000200'::uuid,
    'NO-SPEC',
    'NO-SPEC',
    NULL,
    NULL,
    NULL,
    'unknown',
    true,
    false,
    'verified'
  ),
  (
    '5a8e0000-0000-4000-8000-000000000402'::uuid,
    '5a8e0000-0000-4000-8000-000000000302'::uuid,
    '5a8e0000-0000-4000-8000-000000000200'::uuid,
    'AMBIGUOUS-SPEC',
    'AMBIGUOUS-SPEC',
    NULL,
    NULL,
    NULL,
    'unknown',
    true,
    false,
    'verified'
  );

INSERT INTO public.catalog_import_batches (
  id,
  catalog_vendor_id,
  source_name,
  source_version,
  status,
  raw_record_count,
  unique_key_count,
  matched_record_count,
  started_at,
  completed_at
)
VALUES (
  '5a8e0000-0000-4000-8000-000000000500'::uuid,
  '5a8e0000-0000-4000-8000-000000000200'::uuid,
  'Post-5A.8 specification fixture',
  '1',
  'completed',
  3,
  2,
  3,
  now(),
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
  raw_data,
  matched_catalog_vendor_product_id,
  resolution_status,
  resolved_at
)
VALUES
  (
    '5a8e0000-0000-4000-8000-000000000600'::uuid,
    '5a8e0000-0000-4000-8000-000000000500'::uuid,
    '5a8e0000-0000-4000-8000-000000000200'::uuid,
    1,
    '632-0535',
    'Lightplast Pro Elastic Stretch Tape',
    '2" x 5-yd Rolls',
    '24 rolls/case',
    '{}'::jsonb,
    '5a8e0000-0000-4000-8000-000000000400'::uuid,
    'matched',
    now()
  ),
  (
    '5a8e0000-0000-4000-8000-000000000601'::uuid,
    '5a8e0000-0000-4000-8000-000000000500'::uuid,
    '5a8e0000-0000-4000-8000-000000000200'::uuid,
    2,
    'AMBIGUOUS-SPEC',
    'Product With Conflicting Variants',
    'Small',
    NULL,
    '{}'::jsonb,
    '5a8e0000-0000-4000-8000-000000000402'::uuid,
    'matched',
    now()
  ),
  (
    '5a8e0000-0000-4000-8000-000000000602'::uuid,
    '5a8e0000-0000-4000-8000-000000000500'::uuid,
    '5a8e0000-0000-4000-8000-000000000200'::uuid,
    3,
    'AMBIGUOUS-SPEC',
    'Product With Conflicting Variants',
    'Large',
    NULL,
    '{}'::jsonb,
    '5a8e0000-0000-4000-8000-000000000402'::uuid,
    'matched',
    now()
  );

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub',
  '5a8e0000-0000-4000-8000-000000000001',
  true
);

DO $behavior$
DECLARE
  _organization_id uuid := '5a8e0000-0000-4000-8000-000000000100'::uuid;
  _result jsonb;
  _count integer;
BEGIN
  SELECT to_jsonb(search_result)
  INTO _result
  FROM public.search_supply_request_products(_organization_id, '2 x 5 yd rolls', 20)
    search_result
  WHERE search_result.catalog_vendor_product_id =
    '5a8e0000-0000-4000-8000-000000000400'::uuid;
  IF _result IS NULL
     OR _result->>'inventory_item_id' IS NOT NULL
     OR _result->>'product_id' IS NOT NULL
     OR _result->>'vendor_product_id' IS NOT NULL
     OR _result->>'catalog_vendor_product_id' IS DISTINCT FROM
       '5a8e0000-0000-4000-8000-000000000400' THEN
    RAISE EXCEPTION 'Authoritative size search changed or lost structured identity: %', _result;
  END IF;

  SELECT to_jsonb(specification_result)
  INTO _result
  FROM public.get_supply_request_product_specifications(
    _organization_id,
    ARRAY['5a8e0000-0000-4000-8000-000000000400'::uuid]
  ) specification_result;
  IF _result->>'catalog_vendor_product_id' IS DISTINCT FROM
       '5a8e0000-0000-4000-8000-000000000400'
     OR _result->>'specification' IS DISTINCT FROM '2" x 5-yd Rolls' THEN
    RAISE EXCEPTION 'Source-backed specification was not returned exactly: %', _result;
  END IF;

  SELECT count(*)
  INTO _count
  FROM public.get_supply_request_product_specifications(
    _organization_id,
    ARRAY[
      '5a8e0000-0000-4000-8000-000000000401'::uuid,
      '5a8e0000-0000-4000-8000-000000000402'::uuid
    ]
  );
  IF _count <> 0 THEN
    RAISE EXCEPTION 'Missing or conflicting source variants were not omitted';
  END IF;

  BEGIN
    PERFORM *
    FROM public.get_supply_request_product_specifications(
      '5a8e0000-0000-4000-8000-000000000999'::uuid,
      ARRAY['5a8e0000-0000-4000-8000-000000000400'::uuid]
    );
    RAISE EXCEPTION 'Cross-organization specification lookup unexpectedly succeeded';
  EXCEPTION
    WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    PERFORM *
    FROM public.get_supply_request_product_specifications(
      _organization_id,
      array_fill(
        '5a8e0000-0000-4000-8000-000000000400'::uuid,
        ARRAY[51]
      )
    );
    RAISE EXCEPTION 'Oversized specification lookup unexpectedly succeeded';
  EXCEPTION
    WHEN invalid_parameter_value THEN NULL;
  END;
END
$behavior$;

ROLLBACK;

DO $no_persistence$
BEGIN
  IF EXISTS (
    SELECT 1 FROM auth.users
    WHERE id = '5a8e0000-0000-4000-8000-000000000001'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.organizations
    WHERE id = '5a8e0000-0000-4000-8000-000000000100'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.catalog_vendors
    WHERE id = '5a8e0000-0000-4000-8000-000000000200'::uuid
  ) THEN
    RAISE EXCEPTION 'phase5a8_specification_no_persistence failed';
  END IF;
END
$no_persistence$;

SELECT 'PASS' AS phase5a8_staff_request_specifications_behavior;
