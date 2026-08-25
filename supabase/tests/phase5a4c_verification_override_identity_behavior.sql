\set ON_ERROR_STOP on

-- Run only after applying the Phase 5A.4C migration in the target test
-- environment. All fixture writes are enclosed in this transaction.
BEGIN;

DO $phase5a4c_behavior$
DECLARE
  test_vendor_id constant uuid := '5a4c0000-0000-4000-8000-000000000001';
  valid_override_id constant uuid := '5a4c0000-0000-4000-8000-000000000002';
  invalid_override_id constant uuid := '5a4c0000-0000-4000-8000-000000000003';
  failed_constraint text;
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.catalog_vendors
    WHERE id = test_vendor_id
  ) OR EXISTS (
    SELECT 1
    FROM public.catalog_verification_overrides
    WHERE id IN (valid_override_id, invalid_override_id)
  ) THEN
    RAISE EXCEPTION 'Phase 5A.4C rollback-test fixture IDs already exist';
  END IF;

  INSERT INTO public.catalog_vendors (
    id,
    name,
    normalized_name,
    active
  ) VALUES (
    test_vendor_id,
    'Phase 5A.4C rollback verification vendor',
    'phase 5a 4c rollback verification vendor',
    true
  );

  -- Of the four accepted identity paths, only normalized_verified_vendor_sku
  -- is populated. The normalization trigger derives it from verified_vendor_sku.
  INSERT INTO public.catalog_verification_overrides (
    id,
    catalog_vendor_id,
    verified_vendor_sku,
    override_type,
    evidence_status,
    production_rule,
    evidence,
    active
  ) VALUES (
    valid_override_id,
    test_vendor_id,
    '128-5851',
    'source_disposition',
    'pending',
    'HOLD FOR SECOND SOURCE',
    '{"test":"phase5a4c-rollback-only"}'::jsonb,
    true
  );

  IF NOT EXISTS (
    SELECT 1
    FROM public.catalog_verification_overrides
    WHERE id = valid_override_id
      AND source_record_id IS NULL
      AND normalized_source_vendor_sku IS NULL
      AND normalized_verified_vendor_sku = '128-5851'
      AND catalog_vendor_product_id IS NULL
  ) THEN
    RAISE EXCEPTION 'Verified-vendor-SKU-only identity path was not accepted';
  END IF;

  BEGIN
    INSERT INTO public.catalog_verification_overrides (
      id,
      catalog_vendor_id,
      override_type,
      evidence_status,
      production_rule,
      evidence,
      active
    ) VALUES (
      invalid_override_id,
      test_vendor_id,
      'other',
      'pending',
      'INVALID TEST ROW WITH NO IDENTITY',
      '{"test":"phase5a4c-rollback-only"}'::jsonb,
      true
    );

    RAISE EXCEPTION 'Identity-free override unexpectedly succeeded';
  EXCEPTION
    WHEN check_violation THEN
      GET STACKED DIAGNOSTICS failed_constraint = CONSTRAINT_NAME;
      IF failed_constraint <> 'catalog_verification_overrides_identity_present' THEN
        RAISE EXCEPTION
          'Identity-free override failed on unexpected constraint: %',
          failed_constraint;
      END IF;
  END;

  IF EXISTS (
    SELECT 1
    FROM public.catalog_verification_overrides
    WHERE id = invalid_override_id
  ) THEN
    RAISE EXCEPTION 'Rejected identity-free override remained visible';
  END IF;
END
$phase5a4c_behavior$;

ROLLBACK;

-- This post-rollback assertion is read-only and proves fixture rows did not
-- persist beyond the test transaction.
DO $phase5a4c_no_persistence$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.catalog_vendors
    WHERE id = '5a4c0000-0000-4000-8000-000000000001'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.catalog_verification_overrides
    WHERE id IN (
      '5a4c0000-0000-4000-8000-000000000002'::uuid,
      '5a4c0000-0000-4000-8000-000000000003'::uuid
    )
  ) THEN
    RAISE EXCEPTION 'Phase 5A.4C rollback-only test left persistent rows';
  END IF;
END
$phase5a4c_no_persistence$;
