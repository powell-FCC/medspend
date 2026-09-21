-- Phase 6B rollback-only behavioral verification.
-- Run after 20260921120000_phase6b_price_intelligence.sql. All data rolls back.

BEGIN;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
VALUES
  ('6b000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'phase6b-owner@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('6b000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'phase6b-admin@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('6b000000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'phase6b-staff@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('6b000000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'phase6b-other@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('6b000000-0000-4000-8000-000000000005', 'authenticated', 'authenticated', 'phase6b-nonmember@example.invalid', '', now(), '{}', '{}', now(), now());

INSERT INTO public.organizations (id, name, created_by)
VALUES
  ('6b000000-0000-4000-8000-000000000101', 'Phase 6B Organization', '6b000000-0000-4000-8000-000000000001'),
  ('6b000000-0000-4000-8000-000000000102', 'Phase 6B Other Organization', '6b000000-0000-4000-8000-000000000004');

INSERT INTO public.organization_memberships (id, organization_id, user_id, role, active)
VALUES
  ('6b000000-0000-4000-8000-000000000111', '6b000000-0000-4000-8000-000000000101', '6b000000-0000-4000-8000-000000000001', 'owner', true),
  ('6b000000-0000-4000-8000-000000000112', '6b000000-0000-4000-8000-000000000101', '6b000000-0000-4000-8000-000000000002', 'admin', true),
  ('6b000000-0000-4000-8000-000000000113', '6b000000-0000-4000-8000-000000000101', '6b000000-0000-4000-8000-000000000003', 'staff', true),
  ('6b000000-0000-4000-8000-000000000114', '6b000000-0000-4000-8000-000000000102', '6b000000-0000-4000-8000-000000000004', 'admin', true);

INSERT INTO public.products (id, organization_id, name, approved, active, staff_requestable)
VALUES
  ('6b000000-0000-4000-8000-000000000201', '6b000000-0000-4000-8000-000000000101', 'Canonical Tape', true, true, true),
  ('6b000000-0000-4000-8000-000000000202', '6b000000-0000-4000-8000-000000000101', 'Zero Baseline Tape', true, true, true),
  ('6b000000-0000-4000-8000-000000000203', '6b000000-0000-4000-8000-000000000102', 'Other Organization Tape', true, true, true);

INSERT INTO public.vendors (id, organization_id, name, active)
VALUES
  ('6b000000-0000-4000-8000-000000000301', '6b000000-0000-4000-8000-000000000101', 'Vendor A', true),
  ('6b000000-0000-4000-8000-000000000302', '6b000000-0000-4000-8000-000000000101', 'Vendor B', true),
  ('6b000000-0000-4000-8000-000000000303', '6b000000-0000-4000-8000-000000000102', 'Other Vendor', true);

INSERT INTO public.vendor_products (
  id, organization_id, vendor_id, product_id, vendor_sku, package_size, unit_of_measure, active
)
VALUES
  ('6b000000-0000-4000-8000-000000000401', '6b000000-0000-4000-8000-000000000101', '6b000000-0000-4000-8000-000000000301', '6b000000-0000-4000-8000-000000000201', 'A-TAPE', 'case of 12', 'case', true),
  ('6b000000-0000-4000-8000-000000000402', '6b000000-0000-4000-8000-000000000101', '6b000000-0000-4000-8000-000000000302', '6b000000-0000-4000-8000-000000000201', 'B-TAPE', '6 rolls', 'box', true),
  ('6b000000-0000-4000-8000-000000000403', '6b000000-0000-4000-8000-000000000101', '6b000000-0000-4000-8000-000000000301', '6b000000-0000-4000-8000-000000000202', 'ZERO-TAPE', 'each', 'each', true),
  ('6b000000-0000-4000-8000-000000000404', '6b000000-0000-4000-8000-000000000102', '6b000000-0000-4000-8000-000000000303', '6b000000-0000-4000-8000-000000000203', 'OTHER-TAPE', 'each', 'each', true);

-- Twenty-five valid USD observations exercise summary math, vendor grouping, exact
-- canonical identity, and the 20-row history bound. Prices and dates increase together.
DO $phase6b_seed_valid$
DECLARE
  _position integer;
  _invoice_id uuid;
  _item_id uuid;
  _vendor_id uuid;
  _vendor_product_id uuid;
BEGIN
  FOR _position IN 1..25 LOOP
    _invoice_id := gen_random_uuid();
    _item_id := gen_random_uuid();
    IF _position % 2 = 1 THEN
      _vendor_id := '6b000000-0000-4000-8000-000000000301';
      _vendor_product_id := '6b000000-0000-4000-8000-000000000401';
    ELSE
      _vendor_id := '6b000000-0000-4000-8000-000000000302';
      _vendor_product_id := '6b000000-0000-4000-8000-000000000402';
    END IF;

    INSERT INTO public.invoices (
      id, organization_id, vendor_id, invoice_number, invoice_date,
      currency_code, processing_status, posted_at
    ) VALUES (
      _invoice_id, '6b000000-0000-4000-8000-000000000101', _vendor_id,
      '6B-' || _position, date '2026-08-01' + _position, 'USD', 'completed',
      timestamptz '2026-08-01 12:00:00+00' + make_interval(days => _position)
    );
    INSERT INTO public.invoice_items (
      id, invoice_id, organization_id, description, quantity, unit_price,
      total_price, product_id, vendor_product_id, review_status
    ) VALUES (
      _item_id, _invoice_id, '6b000000-0000-4000-8000-000000000101',
      'Canonical Tape', 1, _position, _position,
      '6b000000-0000-4000-8000-000000000201', _vendor_product_id, 'approved'
    );
    INSERT INTO public.inventory_price_history (
      organization_id, product_id, vendor_id, vendor_product_id, invoice_id,
      invoice_item_id, purchase_date, quantity, package_size, unit_of_measure,
      unit_price, extended_price, created_at
    ) VALUES (
      '6b000000-0000-4000-8000-000000000101',
      '6b000000-0000-4000-8000-000000000201', _vendor_id, _vendor_product_id,
      _invoice_id, _item_id, date '2026-08-01' + _position, 1,
      CASE WHEN _position % 2 = 1 THEN 'case of 12' ELSE '6 rolls' END,
      CASE WHEN _position % 2 = 1 THEN 'case' ELSE 'box' END,
      _position, _position,
      timestamptz '2026-08-01 12:00:00+00' + make_interval(days => _position)
    );
  END LOOP;
END
$phase6b_seed_valid$;

-- Currency and posting fixtures prove that unknown/non-USD/missing-price observations
-- never enter USD math, while an unposted row is not authoritative at all.
DO $phase6b_seed_exclusions$
DECLARE
  _currency text;
  _posted boolean;
  _price numeric;
  _invoice_id uuid;
  _item_id uuid;
BEGIN
  FOR _currency, _posted, _price IN
    SELECT * FROM (VALUES
      (NULL::text, true, 666::numeric),
      ('EUR'::text, true, 777::numeric),
      ('USD'::text, true, NULL::numeric),
      ('USD'::text, false, 999::numeric)
    ) fixture(currency_code, posted, price)
  LOOP
    _invoice_id := gen_random_uuid();
    _item_id := gen_random_uuid();
    INSERT INTO public.invoices (
      id, organization_id, vendor_id, invoice_number, invoice_date,
      currency_code, processing_status, posted_at
    ) VALUES (
      _invoice_id, '6b000000-0000-4000-8000-000000000101',
      '6b000000-0000-4000-8000-000000000301', '6B-EXCLUDED', date '2026-09-01',
      _currency, CASE WHEN _posted THEN 'completed' ELSE 'review_required' END,
      CASE WHEN _posted THEN timestamptz '2026-09-01 12:00:00+00' ELSE NULL END
    );
    INSERT INTO public.invoice_items (
      id, invoice_id, organization_id, description, quantity, unit_price,
      total_price, product_id, vendor_product_id, review_status
    ) VALUES (
      _item_id, _invoice_id, '6b000000-0000-4000-8000-000000000101',
      'Canonical Tape', 1, _price, _price,
      '6b000000-0000-4000-8000-000000000201',
      '6b000000-0000-4000-8000-000000000401', 'approved'
    );
    INSERT INTO public.inventory_price_history (
      organization_id, product_id, vendor_id, vendor_product_id, invoice_id,
      invoice_item_id, purchase_date, quantity, package_size, unit_of_measure,
      unit_price, extended_price
    ) VALUES (
      '6b000000-0000-4000-8000-000000000101',
      '6b000000-0000-4000-8000-000000000201',
      '6b000000-0000-4000-8000-000000000301',
      '6b000000-0000-4000-8000-000000000401', _invoice_id, _item_id,
      date '2026-09-01', 1, 'case of 12', 'case', _price, _price
    );
  END LOOP;
END
$phase6b_seed_exclusions$;

-- A different canonical product has a zero previous price. It must remain isolated and
-- must not produce an invalid percentage.
DO $phase6b_seed_zero_baseline$
DECLARE
  _price numeric;
  _position integer := 0;
  _invoice_id uuid;
  _item_id uuid;
BEGIN
  FOREACH _price IN ARRAY ARRAY[0::numeric, 5::numeric] LOOP
    _position := _position + 1;
    _invoice_id := gen_random_uuid();
    _item_id := gen_random_uuid();
    INSERT INTO public.invoices (
      id, organization_id, vendor_id, invoice_number, invoice_date,
      currency_code, processing_status, posted_at
    ) VALUES (
      _invoice_id, '6b000000-0000-4000-8000-000000000101',
      '6b000000-0000-4000-8000-000000000301', '6B-ZERO-' || _position,
      date '2026-09-10' + _position, 'USD', 'completed', now()
    );
    INSERT INTO public.invoice_items (
      id, invoice_id, organization_id, description, quantity, unit_price,
      total_price, product_id, vendor_product_id, review_status
    ) VALUES (
      _item_id, _invoice_id, '6b000000-0000-4000-8000-000000000101',
      'Zero Baseline Tape', 1, _price, _price,
      '6b000000-0000-4000-8000-000000000202',
      '6b000000-0000-4000-8000-000000000403', 'approved'
    );
    INSERT INTO public.inventory_price_history (
      organization_id, product_id, vendor_id, vendor_product_id, invoice_id,
      invoice_item_id, purchase_date, quantity, unit_price, extended_price,
      package_size, unit_of_measure, created_at
    ) VALUES (
      '6b000000-0000-4000-8000-000000000101',
      '6b000000-0000-4000-8000-000000000202',
      '6b000000-0000-4000-8000-000000000301',
      '6b000000-0000-4000-8000-000000000403', _invoice_id, _item_id,
      date '2026-09-10' + _position, 1, _price, _price, 'each', 'each',
      timestamptz '2026-09-10 12:00:00+00' + make_interval(days => _position)
    );
  END LOOP;
END
$phase6b_seed_zero_baseline$;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6b000000-0000-4000-8000-000000000002', true);

DO $phase6b_summary$
DECLARE
  _result jsonb;
  _percent numeric;
BEGIN
  _result := public.get_product_price_intelligence(
    '6b000000-0000-4000-8000-000000000101',
    '6b000000-0000-4000-8000-000000000201'
  );
  _percent := (_result #>> '{summary,percentChange}')::numeric;
  IF (_result #>> '{summary,latestPrice}')::numeric <> 25
     OR (_result #>> '{summary,previousPrice}')::numeric <> 24
     OR (_result #>> '{summary,absoluteChange}')::numeric <> 1
     OR abs(_percent - (100::numeric / 24)) > 0.000001
     OR (_result #>> '{summary,historicalLow}')::numeric <> 1
     OR (_result #>> '{summary,historicalHigh}')::numeric <> 25
     OR (_result #>> '{summary,observationCount}')::integer <> 25 THEN
    RAISE EXCEPTION 'Price summary is incorrect: %', _result -> 'summary';
  END IF;
  IF jsonb_array_length(_result -> 'recentPurchases') <> 20
     OR (_result #>> '{recentPurchases,0,purchasePrice}')::numeric <> 25
     OR (_result #>> '{recentPurchases,19,purchasePrice}')::numeric <> 6 THEN
    RAISE EXCEPTION 'History bound or deterministic ordering is incorrect';
  END IF;
  IF jsonb_array_length(_result -> 'vendorHistory') <> 2
     OR NOT EXISTS (
       SELECT 1 FROM jsonb_array_elements(_result -> 'vendorHistory') vendor
       WHERE vendor ->> 'vendorName' = 'Vendor A'
         AND (vendor ->> 'observationCount')::integer = 13
     )
     OR NOT EXISTS (
       SELECT 1 FROM jsonb_array_elements(_result -> 'vendorHistory') vendor
       WHERE vendor ->> 'vendorName' = 'Vendor B'
         AND (vendor ->> 'observationCount')::integer = 12
     ) THEN
    RAISE EXCEPTION 'Vendor grouping is incorrect';
  END IF;
  IF (_result #>> '{coverage,postedObservationCount}')::integer <> 28
     OR (_result #>> '{coverage,includedUsdObservationCount}')::integer <> 25
     OR (_result #>> '{coverage,excludedUnknownCurrencyCount}')::integer <> 1
     OR (_result #>> '{coverage,excludedNonUsdCount}')::integer <> 1
     OR (_result #>> '{coverage,excludedMissingPriceCount}')::integer <> 1 THEN
    RAISE EXCEPTION 'Currency or authoritative-posting coverage is incorrect: %', _result -> 'coverage';
  END IF;
  IF (_result #>> '{packageComparability,normalizedUnitEconomicsAvailable}')::boolean
     OR _result #>> '{packageComparability,status}' <> 'not_verified' THEN
    RAISE EXCEPTION 'Unverified packages produced normalized comparison data';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(_result -> 'recentPurchases') observation
    WHERE observation ->> 'provenanceType' <> 'posted_invoice_purchase_history'
       OR observation ->> 'packageEvidenceStatus' <> 'unverified'
  ) THEN
    RAISE EXCEPTION 'Observation provenance or package trust is incorrect';
  END IF;
END
$phase6b_summary$;

DO $phase6b_zero_and_identity$
DECLARE _result jsonb;
BEGIN
  _result := public.get_product_price_intelligence(
    '6b000000-0000-4000-8000-000000000101',
    '6b000000-0000-4000-8000-000000000202'
  );
  IF (_result #>> '{summary,observationCount}')::integer <> 2
     OR (_result #>> '{summary,latestPrice}')::numeric <> 5
     OR (_result #>> '{summary,previousPrice}')::numeric <> 0
     OR (_result #> '{summary,percentChange}') <> 'null'::jsonb THEN
    RAISE EXCEPTION 'Exact product scoping or zero-baseline behavior is incorrect: %', _result;
  END IF;
END
$phase6b_zero_and_identity$;

-- Owners have the same explicit RPC access as admins.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6b000000-0000-4000-8000-000000000001', true);
SELECT public.get_product_price_intelligence(
  '6b000000-0000-4000-8000-000000000101',
  '6b000000-0000-4000-8000-000000000201'
);

-- Staff, nonmembers, and an admin from another organization are denied before data lookup.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6b000000-0000-4000-8000-000000000003', true);
DO $phase6b_staff_denied$
BEGIN
  BEGIN
    PERFORM public.get_product_price_intelligence(
      '6b000000-0000-4000-8000-000000000101',
      '6b000000-0000-4000-8000-000000000201'
    );
    RAISE EXCEPTION 'Staff price intelligence access unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END
$phase6b_staff_denied$;

SELECT pg_catalog.set_config('request.jwt.claim.sub', '6b000000-0000-4000-8000-000000000005', true);
DO $phase6b_nonmember_denied$
BEGIN
  BEGIN
    PERFORM public.get_product_price_intelligence(
      '6b000000-0000-4000-8000-000000000101',
      '6b000000-0000-4000-8000-000000000201'
    );
    RAISE EXCEPTION 'Nonmember price intelligence access unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END
$phase6b_nonmember_denied$;

SELECT pg_catalog.set_config('request.jwt.claim.sub', '6b000000-0000-4000-8000-000000000004', true);
DO $phase6b_cross_org_denied$
BEGIN
  BEGIN
    PERFORM public.get_product_price_intelligence(
      '6b000000-0000-4000-8000-000000000101',
      '6b000000-0000-4000-8000-000000000201'
    );
    RAISE EXCEPTION 'Cross-organization price intelligence access unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END
$phase6b_cross_org_denied$;

RESET ROLE;

SELECT 18 AS checks_passed, 0 AS checks_failed;

ROLLBACK;
