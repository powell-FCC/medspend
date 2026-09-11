-- Rollback-only verification for Phase 5A.8B effective specifications and search.
BEGIN;

DO $fixture_guard$
BEGIN
  IF EXISTS (
    SELECT 1 FROM auth.users
    WHERE id IN (
      '5a8b0000-0000-4000-8000-000000000001'::uuid,
      '5a8b0000-0000-4000-8000-000000000002'::uuid,
      '5a8b0000-0000-4000-8000-000000000003'::uuid,
      '5a8b0000-0000-4000-8000-000000000004'::uuid
    )
  ) OR EXISTS (
    SELECT 1 FROM public.organizations
    WHERE id IN (
      '5a8b0000-0000-4000-8000-000000000100'::uuid,
      '5a8b0000-0000-4000-8000-000000000101'::uuid
    )
  ) THEN
    RAISE EXCEPTION 'Phase 5A.8B fixture IDs already exist';
  END IF;
END
$fixture_guard$;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
VALUES
  ('5a8b0000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'phase5a8b-owner@example.invalid', '', now(), '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('5a8b0000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'phase5a8b-admin@example.invalid', '', now(), '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('5a8b0000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'phase5a8b-staff@example.invalid', '', now(), '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('5a8b0000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'phase5a8b-other@example.invalid', '', now(), '{}'::jsonb, '{}'::jsonb, now(), now());

INSERT INTO public.organizations (id, name, created_by)
VALUES
  ('5a8b0000-0000-4000-8000-000000000100', 'Phase 5A.8B Organization', '5a8b0000-0000-4000-8000-000000000001'),
  ('5a8b0000-0000-4000-8000-000000000101', 'Phase 5A.8B Other Organization', '5a8b0000-0000-4000-8000-000000000004');

INSERT INTO public.organization_memberships (
  id, organization_id, user_id, role, active
)
VALUES
  ('5a8b0000-0000-4000-8000-000000000700', '5a8b0000-0000-4000-8000-000000000100', '5a8b0000-0000-4000-8000-000000000001', 'owner', true),
  ('5a8b0000-0000-4000-8000-000000000701', '5a8b0000-0000-4000-8000-000000000100', '5a8b0000-0000-4000-8000-000000000002', 'admin', true),
  ('5a8b0000-0000-4000-8000-000000000702', '5a8b0000-0000-4000-8000-000000000100', '5a8b0000-0000-4000-8000-000000000003', 'staff', true),
  ('5a8b0000-0000-4000-8000-000000000703', '5a8b0000-0000-4000-8000-000000000101', '5a8b0000-0000-4000-8000-000000000004', 'owner', true),
  ('5a8b0000-0000-4000-8000-000000000704', '5a8b0000-0000-4000-8000-000000000100', '5a8b0000-0000-4000-8000-000000000004', 'staff', false);

INSERT INTO public.catalog_vendors (id, name, normalized_name, active)
VALUES ('5a8b0000-0000-4000-8000-000000000200', 'Henry Schein Phase 5A.8B', 'henry schein phase 5a 8b', true);

INSERT INTO public.catalog_products (
  id, name, normalized_name, description, manufacturer, normalized_manufacturer,
  active, verification_status
)
VALUES
  ('5a8b0000-0000-4000-8000-000000000300', 'APS Dry Needle', 'aps dry needle', 'Sterile acupuncture needle', 'APS', 'aps', true, 'verified'),
  ('5a8b0000-0000-4000-8000-000000000301', 'APS Dry Needle', 'aps dry needle', 'Sterile acupuncture needle', 'APS', 'aps', true, 'verified'),
  ('5a8b0000-0000-4000-8000-000000000302', 'APS Dry Needle', 'aps dry needle', 'Sterile acupuncture needle', 'APS', 'aps', true, 'verified'),
  ('5a8b0000-0000-4000-8000-000000000303', 'Precision Needle', 'precision needle', 'Clinical needle', 'Acme', 'acme', true, 'verified'),
  ('5a8b0000-0000-4000-8000-000000000304', 'Elastic Sports Tape', 'elastic sports tape', 'Durable athletic tape', 'Acme', 'acme', true, 'verified'),
  ('5a8b0000-0000-4000-8000-000000000305', 'Conflicting Variant Product', 'conflicting variant product', 'Should remain unresolved', 'Acme', 'acme', true, 'verified'),
  ('5a8b0000-0000-4000-8000-000000000306', 'Unrelated Blank Variant', 'unrelated blank variant', 'Unrelated catalog item', 'Acme', 'acme', true, 'verified'),
  ('5a8b0000-0000-4000-8000-000000000307', 'Inactive Search Product', 'inactive search product', 'Do not retrieve', 'Acme', 'acme', false, 'verified'),
  ('5a8b0000-0000-4000-8000-000000000308', 'Discontinued Search Product', 'discontinued search product', 'Do not retrieve', 'Acme', 'acme', true, 'verified'),
  ('5a8b0000-0000-4000-8000-000000000309', 'SKU Mention Decoy', 'sku mention decoy', 'Mentions 127-2589 and LOCAL-2589 in descriptive metadata', 'Acme', 'acme', true, 'verified'),
  ('5a8b0000-0000-4000-8000-000000000310', 'Malformed APS-like Product', 'malformed aps like product', 'Must not recover a distant segment', 'Acme', 'acme', true, 'verified');

INSERT INTO public.catalog_vendor_products (
  id, catalog_product_id, catalog_vendor_id, vendor_sku, normalized_vendor_sku,
  package_description, package_quantity, package_unit, package_status,
  active, discontinued, verification_status
)
VALUES
  ('5a8b0000-0000-4000-8000-000000000400', '5a8b0000-0000-4000-8000-000000000300', '5a8b0000-0000-4000-8000-000000000200', '127-2589', '127-2589', 'Box of 100 needles', NULL, NULL, 'source_only', true, false, 'verified'),
  ('5a8b0000-0000-4000-8000-000000000401', '5a8b0000-0000-4000-8000-000000000301', '5a8b0000-0000-4000-8000-000000000200', '127-2587', '127-2587', 'Box of 100 needles', NULL, NULL, 'source_only', true, false, 'verified'),
  ('5a8b0000-0000-4000-8000-000000000402', '5a8b0000-0000-4000-8000-000000000302', '5a8b0000-0000-4000-8000-000000000200', '127-2578', '127-2578', 'Box of 100 needles', NULL, NULL, 'source_only', true, false, 'verified'),
  ('5a8b0000-0000-4000-8000-000000000403', '5a8b0000-0000-4000-8000-000000000303', '5a8b0000-0000-4000-8000-000000000200', 'NEEDLE-50', 'NEEDLE-50', 'Box of 50', NULL, NULL, 'source_only', true, false, 'verified'),
  ('5a8b0000-0000-4000-8000-000000000404', '5a8b0000-0000-4000-8000-000000000304', '5a8b0000-0000-4000-8000-000000000200', 'TAPE-2IN', 'TAPE-2IN', '24 rolls/case', 24, 'roll', 'verified', true, false, 'verified'),
  ('5a8b0000-0000-4000-8000-000000000405', '5a8b0000-0000-4000-8000-000000000305', '5a8b0000-0000-4000-8000-000000000200', 'CONFLICT', 'CONFLICT', NULL, NULL, NULL, 'unknown', true, false, 'verified'),
  ('5a8b0000-0000-4000-8000-000000000406', '5a8b0000-0000-4000-8000-000000000306', '5a8b0000-0000-4000-8000-000000000200', 'UNRELATED', 'UNRELATED', NULL, NULL, NULL, 'unknown', true, false, 'verified'),
  ('5a8b0000-0000-4000-8000-000000000407', '5a8b0000-0000-4000-8000-000000000307', '5a8b0000-0000-4000-8000-000000000200', 'INACTIVE-ONLY', 'INACTIVE-ONLY', NULL, NULL, NULL, 'unknown', true, false, 'verified'),
  ('5a8b0000-0000-4000-8000-000000000408', '5a8b0000-0000-4000-8000-000000000308', '5a8b0000-0000-4000-8000-000000000200', 'DISCONTINUED-ONLY', 'DISCONTINUED-ONLY', NULL, NULL, NULL, 'unknown', true, true, 'verified'),
  ('5a8b0000-0000-4000-8000-000000000409', '5a8b0000-0000-4000-8000-000000000309', '5a8b0000-0000-4000-8000-000000000200', 'DECOY-1272589', 'DECOY-1272589', NULL, NULL, NULL, 'unknown', true, false, 'verified'),
  ('5a8b0000-0000-4000-8000-000000000410', '5a8b0000-0000-4000-8000-000000000310', '5a8b0000-0000-4000-8000-000000000200', 'MALFORMED', 'MALFORMED', NULL, NULL, NULL, 'unknown', true, false, 'verified');

INSERT INTO public.catalog_import_batches (
  id, catalog_vendor_id, source_name, source_version, status,
  raw_record_count, unique_key_count, matched_record_count, started_at, completed_at
)
VALUES (
  '5a8b0000-0000-4000-8000-000000000500',
  '5a8b0000-0000-4000-8000-000000000200',
  'Phase 5A.8B recovery fixture', '1', 'completed', 11, 10, 11, now(), now()
);

INSERT INTO public.catalog_source_records (
  id, import_batch_id, catalog_vendor_id, source_ordinal, raw_vendor_sku,
  raw_product_name, raw_variant, raw_package, raw_data,
  matched_catalog_vendor_product_id, resolution_status, resolved_at
)
VALUES
  ('5a8b0000-0000-4000-8000-000000000600', '5a8b0000-0000-4000-8000-000000000500', '5a8b0000-0000-4000-8000-000000000200', 1, '127-2589', 'APS Dry Needle', NULL, 'Box of 100', '{"fields":{"Raw Product Block":"APS Dry Needle | #D-MI-02530, 0.25 x 30 mm, Brown Tip | (127-2589) | Box of 100"},"secretEvidence":"PHASE5A8B-DO-NOT-LEAK"}', '5a8b0000-0000-4000-8000-000000000400', 'matched', now()),
  ('5a8b0000-0000-4000-8000-000000000601', '5a8b0000-0000-4000-8000-000000000500', '5a8b0000-0000-4000-8000-000000000200', 2, '127-2587', 'APS Dry Needle', NULL, 'Box of 100', '{"fields":{"Raw Product Block":"APS Dry Needle | #D-MI-03030, 0.30 x 30 mm, Gold Tip | (127-2587) | Box of 100"}}', '5a8b0000-0000-4000-8000-000000000401', 'verified_match', now()),
  ('5a8b0000-0000-4000-8000-000000000602', '5a8b0000-0000-4000-8000-000000000500', '5a8b0000-0000-4000-8000-000000000200', 3, '127-2578', 'APS Dry Needle', NULL, 'Box of 100', '{"fields":{"Raw Product Block":"APS Dry Needle | #D-MI-03075, 0.30 x 75 mm, Black Tip | (127-2578) | Box of 100"}}', '5a8b0000-0000-4000-8000-000000000402', 'matched', now()),
  ('5a8b0000-0000-4000-8000-000000000603', '5a8b0000-0000-4000-8000-000000000500', '5a8b0000-0000-4000-8000-000000000200', 4, 'NEEDLE-50', 'Precision Needle', '0.40 x 50 mm, Green Tip', 'Box of 50', '{}', '5a8b0000-0000-4000-8000-000000000403', 'matched', now()),
  ('5a8b0000-0000-4000-8000-000000000604', '5a8b0000-0000-4000-8000-000000000500', '5a8b0000-0000-4000-8000-000000000200', 5, 'TAPE-2IN', 'Elastic Sports Tape', '2" x 5 yd Rolls', '24 rolls/case', '{}', '5a8b0000-0000-4000-8000-000000000404', 'matched', now()),
  ('5a8b0000-0000-4000-8000-000000000605', '5a8b0000-0000-4000-8000-000000000500', '5a8b0000-0000-4000-8000-000000000200', 6, 'CONFLICT', 'Conflicting Variant Product', 'Small', NULL, '{"fields":{"Raw Product Block":"Conflicting | #D-MI-02530, 0.25 x 30 mm, Brown Tip | (CONFLICT)"}}', '5a8b0000-0000-4000-8000-000000000405', 'matched', now()),
  ('5a8b0000-0000-4000-8000-000000000606', '5a8b0000-0000-4000-8000-000000000500', '5a8b0000-0000-4000-8000-000000000200', 7, 'CONFLICT', 'Conflicting Variant Product', 'Large', NULL, '{}', '5a8b0000-0000-4000-8000-000000000405', 'matched', now()),
  ('5a8b0000-0000-4000-8000-000000000607', '5a8b0000-0000-4000-8000-000000000500', '5a8b0000-0000-4000-8000-000000000200', 8, 'UNRELATED', 'Unrelated Blank Variant', NULL, NULL, '{"fields":{"Raw Product Block":"Unrelated product | approximately thirty millimeters (UNRELATED)"}}', '5a8b0000-0000-4000-8000-000000000406', 'matched', now()),
  ('5a8b0000-0000-4000-8000-000000000608', '5a8b0000-0000-4000-8000-000000000500', '5a8b0000-0000-4000-8000-000000000200', 9, 'INACTIVE-ONLY', 'Inactive Search Product', 'Inactive specification', NULL, '{}', '5a8b0000-0000-4000-8000-000000000407', 'matched', now()),
  ('5a8b0000-0000-4000-8000-000000000609', '5a8b0000-0000-4000-8000-000000000500', '5a8b0000-0000-4000-8000-000000000200', 10, 'DISCONTINUED-ONLY', 'Discontinued Search Product', 'Discontinued specification', NULL, '{}', '5a8b0000-0000-4000-8000-000000000408', 'matched', now()),
  ('5a8b0000-0000-4000-8000-000000000610', '5a8b0000-0000-4000-8000-000000000500', '5a8b0000-0000-4000-8000-000000000200', 11, 'MALFORMED', 'Malformed APS-like Product', NULL, NULL, '{"fields":{"Raw Product Block":"Malformed | #D-MI-02530, 0.25 x 30 mm, Brown Tip | unrelated intervening segment | (MALFORMED)"}}', '5a8b0000-0000-4000-8000-000000000410', 'matched', now());

INSERT INTO public.vendors (id, organization_id, name, active)
VALUES (
  '5a8b0000-0000-4000-8000-000000000800',
  '5a8b0000-0000-4000-8000-000000000100',
  'Organization Vendor',
  true
);

INSERT INTO public.products (
  id, organization_id, name, manufacturer, description, active, staff_requestable
)
VALUES (
  '5a8b0000-0000-4000-8000-000000000801',
  '5a8b0000-0000-4000-8000-000000000100',
  'APS Local Dry Needle',
  'APS',
  'Adopted organization product',
  true,
  true
);

INSERT INTO public.vendor_products (
  id, organization_id, vendor_id, product_id, catalog_vendor_product_id,
  vendor_sku, manufacturer_sku, package_size, unit_of_measure, active
)
VALUES (
  '5a8b0000-0000-4000-8000-000000000802',
  '5a8b0000-0000-4000-8000-000000000100',
  '5a8b0000-0000-4000-8000-000000000800',
  '5a8b0000-0000-4000-8000-000000000801',
  '5a8b0000-0000-4000-8000-000000000400',
  'LOCAL-2589',
  'D-MI-02530',
  'Box of 100',
  'needle',
  true
);

INSERT INTO public.inventory_items (
  id, organization_id, product_id, sku, name, description, manufacturer,
  vendor_name, unit_of_measure, active
)
VALUES (
  '5a8b0000-0000-4000-8000-000000000803',
  '5a8b0000-0000-4000-8000-000000000100',
  '5a8b0000-0000-4000-8000-000000000801',
  'STOCK-2589',
  'APS Local Dry Needle',
  'Stocked adopted product',
  'APS',
  'Organization Vendor',
  'needle',
  true
);

CREATE TEMP TABLE phase5a8b_catalog_counts AS
SELECT
  (SELECT count(*) FROM public.catalog_vendor_products) AS catalog_count,
  (SELECT count(*) FROM public.catalog_source_records) AS source_count;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', '5a8b0000-0000-4000-8000-000000000003', true);

DO $staff_behavior$
DECLARE
  _organization_id uuid := '5a8b0000-0000-4000-8000-000000000100';
  _specifications jsonb;
  _first_id uuid;
  _quote_ids uuid[];
  _inch_ids uuid[];
  _short_inch_ids uuid[];
  _compact_mm_ids uuid[];
  _spaced_mm_ids uuid[];
  _ordered_ids uuid[];
  _reordered_ids uuid[];
  _aps_count bigint;
  _aps_identity_count bigint;
BEGIN
  SELECT pg_catalog.jsonb_object_agg(catalog_vendor_product_id::text, specification)
  INTO _specifications
  FROM public.get_supply_request_product_specifications(
    _organization_id,
    ARRAY[
      '5a8b0000-0000-4000-8000-000000000400'::uuid,
      '5a8b0000-0000-4000-8000-000000000401'::uuid,
      '5a8b0000-0000-4000-8000-000000000402'::uuid,
      '5a8b0000-0000-4000-8000-000000000403'::uuid,
      '5a8b0000-0000-4000-8000-000000000404'::uuid,
      '5a8b0000-0000-4000-8000-000000000405'::uuid,
      '5a8b0000-0000-4000-8000-000000000406'::uuid,
      '5a8b0000-0000-4000-8000-000000000410'::uuid
    ]
  );

  IF _specifications ->> '5a8b0000-0000-4000-8000-000000000400' <> '0.25 x 30 mm, Brown Tip'
     OR _specifications ->> '5a8b0000-0000-4000-8000-000000000401' <> '0.30 x 30 mm, Gold Tip'
     OR _specifications ->> '5a8b0000-0000-4000-8000-000000000402' <> '0.30 x 75 mm, Black Tip'
     OR _specifications ->> '5a8b0000-0000-4000-8000-000000000403' <> '0.40 x 50 mm, Green Tip'
     OR _specifications ->> '5a8b0000-0000-4000-8000-000000000404' <> '2" x 5 yd Rolls' THEN
    RAISE EXCEPTION 'Effective specification recovery returned unexpected values: %', _specifications;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.jsonb_each_text(_specifications)
    WHERE value LIKE '#%'
  ) THEN
    RAISE EXCEPTION 'Manufacturer item number leaked into effective specification: %', _specifications;
  END IF;

  IF _specifications ? '5a8b0000-0000-4000-8000-000000000405'
     OR _specifications ? '5a8b0000-0000-4000-8000-000000000406'
     OR _specifications ? '5a8b0000-0000-4000-8000-000000000410' THEN
    RAISE EXCEPTION 'Conflicting, unrelated, or malformed blank variants were not safely omitted: %', _specifications;
  END IF;

  BEGIN
    PERFORM * FROM public.get_supply_request_product_specifications(
      _organization_id,
      pg_catalog.array_fill(
        '5a8b0000-0000-4000-8000-000000000400'::uuid,
        ARRAY[51]
      )
    );
    RAISE EXCEPTION 'Specification lookup accepted more than 50 IDs';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;

  SELECT catalog_vendor_product_id INTO _first_id
  FROM public.search_supply_request_products(_organization_id, '127-2589', 20)
  LIMIT 1;
  IF _first_id <> '5a8b0000-0000-4000-8000-000000000400'::uuid THEN
    RAISE EXCEPTION 'Exact vendor SKU did not outrank metadata decoy: %', _first_id;
  END IF;

  IF (
    SELECT catalog_vendor_product_id
    FROM public.search_supply_request_products(_organization_id, 'LOCAL-2589', 20)
    LIMIT 1
  ) <> '5a8b0000-0000-4000-8000-000000000400'::uuid OR (
    SELECT count(*)
    FROM public.search_supply_request_products(_organization_id, 'LOCAL-2589', 20)
    WHERE product_id = '5a8b0000-0000-4000-8000-000000000801'::uuid
  ) <> 1 THEN
    RAISE EXCEPTION 'Exact adopted SKU ranking or linked identity collapse regressed';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.search_supply_request_products(_organization_id, 'aps dry needle', 20)
    WHERE catalog_vendor_product_id = '5a8b0000-0000-4000-8000-000000000400'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.search_supply_request_products(_organization_id, 'aps 30', 20)
    WHERE catalog_vendor_product_id = '5a8b0000-0000-4000-8000-000000000401'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.search_supply_request_products(_organization_id, 'needle 50mm', 20)
    WHERE catalog_vendor_product_id = '5a8b0000-0000-4000-8000-000000000403'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.search_supply_request_products(_organization_id, '0.25 30', 20)
    WHERE catalog_vendor_product_id = '5a8b0000-0000-4000-8000-000000000400'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.search_supply_request_products(_organization_id, 'brown tip', 1)
    WHERE catalog_vendor_product_id = '5a8b0000-0000-4000-8000-000000000400'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.search_supply_request_products(_organization_id, 'box 100', 20)
    WHERE catalog_vendor_product_id = '5a8b0000-0000-4000-8000-000000000400'
  ) THEN
    RAISE EXCEPTION 'Human-friendly name, size, color, or package search failed';
  END IF;

  SELECT count(*), count(DISTINCT catalog_vendor_product_id)
  INTO _aps_count, _aps_identity_count
  FROM public.search_supply_request_products(_organization_id, 'aps dry needle', 20);
  IF _aps_count <> 3 OR _aps_identity_count <> 3 THEN
    RAISE EXCEPTION 'Distinct APS SKUs were merged or duplicated: %, %', _aps_count, _aps_identity_count;
  END IF;

  SELECT pg_catalog.array_agg(catalog_vendor_product_id ORDER BY catalog_vendor_product_id)
  INTO _compact_mm_ids
  FROM public.search_supply_request_products(_organization_id, '30mm', 20);
  SELECT pg_catalog.array_agg(catalog_vendor_product_id ORDER BY catalog_vendor_product_id)
  INTO _spaced_mm_ids
  FROM public.search_supply_request_products(_organization_id, '30 mm', 20);
  IF _compact_mm_ids IS DISTINCT FROM _spaced_mm_ids
     OR NOT ('5a8b0000-0000-4000-8000-000000000400'::uuid = ANY(_compact_mm_ids))
     OR NOT ('5a8b0000-0000-4000-8000-000000000401'::uuid = ANY(_compact_mm_ids)) THEN
    RAISE EXCEPTION 'Conservative millimeter equivalence failed: %, %', _compact_mm_ids, _spaced_mm_ids;
  END IF;

  SELECT pg_catalog.array_agg(catalog_vendor_product_id ORDER BY catalog_vendor_product_id)
  INTO _ordered_ids
  FROM public.search_supply_request_products(_organization_id, 'needle brown 30mm', 20);
  SELECT pg_catalog.array_agg(catalog_vendor_product_id ORDER BY catalog_vendor_product_id)
  INTO _reordered_ids
  FROM public.search_supply_request_products(_organization_id, '30 mm brown needle', 20);
  IF _ordered_ids IS DISTINCT FROM _reordered_ids
     OR _ordered_ids <> ARRAY['5a8b0000-0000-4000-8000-000000000400'::uuid] THEN
    RAISE EXCEPTION 'Token-order-independent search failed: %, %', _ordered_ids, _reordered_ids;
  END IF;

  SELECT pg_catalog.array_agg(catalog_vendor_product_id ORDER BY catalog_vendor_product_id)
  INTO _quote_ids
  FROM public.search_supply_request_products(_organization_id, '2" tape', 20);
  SELECT pg_catalog.array_agg(catalog_vendor_product_id ORDER BY catalog_vendor_product_id)
  INTO _inch_ids
  FROM public.search_supply_request_products(_organization_id, '2 inch tape', 20);
  SELECT pg_catalog.array_agg(catalog_vendor_product_id ORDER BY catalog_vendor_product_id)
  INTO _short_inch_ids
  FROM public.search_supply_request_products(_organization_id, '2 in tape', 20);
  IF _quote_ids IS DISTINCT FROM _inch_ids OR _quote_ids IS DISTINCT FROM _short_inch_ids
     OR NOT ('5a8b0000-0000-4000-8000-000000000404'::uuid = ANY(_quote_ids)) THEN
    RAISE EXCEPTION 'Conservative inch equivalence failed: %, %, %', _quote_ids, _inch_ids, _short_inch_ids;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.search_supply_request_products(_organization_id, 'INACTIVE-ONLY', 20)
  ) OR EXISTS (
    SELECT 1 FROM public.search_supply_request_products(_organization_id, 'DISCONTINUED-ONLY', 20)
  ) THEN
    RAISE EXCEPTION 'Inactive or discontinued catalog rows leaked into search';
  END IF;

  PERFORM * FROM public.search_supply_request_products(_organization_id, 'needle brown 30 mm', 50);
  PERFORM * FROM public.get_supply_request_product_specifications(
    _organization_id,
    ARRAY['5a8b0000-0000-4000-8000-000000000400'::uuid]
  );
END
$staff_behavior$;

DO $staff_admin_denial$
BEGIN
  BEGIN
    PERFORM public.get_catalog_vendor_product_admin_detail(
      '5a8b0000-0000-4000-8000-000000000100',
      '5a8b0000-0000-4000-8000-000000000400'
    );
    RAISE EXCEPTION 'Staff unexpectedly accessed catalog admin detail';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END
$staff_admin_denial$;

SELECT pg_catalog.set_config('request.jwt.claim.sub', '5a8b0000-0000-4000-8000-000000000004', true);

DO $cross_organization_denial$
BEGIN
  BEGIN
    PERFORM * FROM public.get_supply_request_product_specifications(
      '5a8b0000-0000-4000-8000-000000000100',
      ARRAY['5a8b0000-0000-4000-8000-000000000400'::uuid]
    );
    RAISE EXCEPTION 'Cross-organization specification lookup unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM * FROM public.search_supply_request_products(
      '5a8b0000-0000-4000-8000-000000000100', 'needle', 20
    );
    RAISE EXCEPTION 'Inactive cross-organization member unexpectedly searched';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END
$cross_organization_denial$;

SELECT pg_catalog.set_config('request.jwt.claim.sub', '5a8b0000-0000-4000-8000-000000000001', true);

DO $owner_admin_detail$
DECLARE
  _detail jsonb;
BEGIN
  _detail := public.get_catalog_vendor_product_admin_detail(
    '5a8b0000-0000-4000-8000-000000000100',
    '5a8b0000-0000-4000-8000-000000000400'
  );
  IF _detail ->> 'effectiveSpecification' <> '0.25 x 30 mm, Brown Tip' THEN
    RAISE EXCEPTION 'Owner admin detail omitted effective specification: %', _detail;
  END IF;
  IF _detail::text LIKE '%PHASE5A8B-DO-NOT-LEAK%' OR _detail ? 'rawData' THEN
    RAISE EXCEPTION 'Admin detail leaked raw evidence: %', _detail;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.search_supply_request_products(
      '5a8b0000-0000-4000-8000-000000000100', 'brown tip', 20
    )
    WHERE catalog_vendor_product_id = '5a8b0000-0000-4000-8000-000000000400'
  ) THEN
    RAISE EXCEPTION 'Active owner could not search';
  END IF;
END
$owner_admin_detail$;

SELECT pg_catalog.set_config('request.jwt.claim.sub', '5a8b0000-0000-4000-8000-000000000002', true);

DO $admin_detail$
DECLARE
  _detail jsonb;
BEGIN
  _detail := public.get_catalog_vendor_product_admin_detail(
    '5a8b0000-0000-4000-8000-000000000100',
    '5a8b0000-0000-4000-8000-000000000401'
  );
  IF _detail ->> 'effectiveSpecification' <> '0.30 x 30 mm, Gold Tip' THEN
    RAISE EXCEPTION 'Admin detail omitted effective specification: %', _detail;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.search_supply_request_products(
      '5a8b0000-0000-4000-8000-000000000100', 'gold 30mm', 20
    )
    WHERE catalog_vendor_product_id = '5a8b0000-0000-4000-8000-000000000401'
  ) THEN
    RAISE EXCEPTION 'Active admin could not search';
  END IF;
END
$admin_detail$;

RESET ROLE;

DO $non_mutation$
BEGIN
  IF (SELECT catalog_count FROM phase5a8b_catalog_counts)
       <> (SELECT count(*) FROM public.catalog_vendor_products)
     OR (SELECT source_count FROM phase5a8b_catalog_counts)
       <> (SELECT count(*) FROM public.catalog_source_records) THEN
    RAISE EXCEPTION 'Read-only retrieval mutated catalog state';
  END IF;
END
$non_mutation$;

SET LOCAL ROLE anon;

DO $anonymous_denial$
BEGIN
  BEGIN
    PERFORM * FROM public.search_supply_request_products(
      '5a8b0000-0000-4000-8000-000000000100', 'needle', 20
    );
    RAISE EXCEPTION 'Anonymous search unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END
$anonymous_denial$;

RESET ROLE;
ROLLBACK;

SELECT 'phase5a8b_catalog_specification_search_no_persistence' AS check_name,
       NOT EXISTS (
         SELECT 1 FROM auth.users
         WHERE id = '5a8b0000-0000-4000-8000-000000000001'::uuid
       ) AS passed;
