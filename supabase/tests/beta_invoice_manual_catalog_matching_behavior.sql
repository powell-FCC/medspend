-- Beta hardening rollback-only behavioral verification: manual invoice matching against the
-- invoice vendor's linked catalog.
-- Run after 20261012120000_beta_invoice_manual_catalog_matching.sql. All data rolls back.
--
-- Fixture mirrors the production observation: a Henry Schein document printing 3240025,
-- 7776538, 1519200 (catalog 324-0025, 777-6538, 151-9200) and 1439386, which the catalog
-- does not list.

BEGIN;

CREATE FUNCTION pg_temp.beta_expect_error(_statement text, _expected text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  BEGIN
    EXECUTE _statement;
  EXCEPTION WHEN OTHERS THEN
    IF position(_expected IN SQLERRM) = 0 THEN
      RAISE EXCEPTION 'Expected error containing "%", got "%" (%)', _expected, SQLERRM, SQLSTATE;
    END IF;
    RETURN;
  END;
  RAISE EXCEPTION 'Statement unexpectedly succeeded; expected "%": %', _expected, _statement;
END;
$$;

CREATE FUNCTION pg_temp.beta_line(_id uuid)
RETURNS public.invoice_items
LANGUAGE sql
AS $$ SELECT * FROM public.invoice_items WHERE id = _id $$;

CREATE FUNCTION pg_temp.beta_skus(_search jsonb)
RETURNS jsonb
LANGUAGE sql
AS $$ SELECT jsonb_path_query_array(_search, '$.results[*].vendorSku') $$;

-- Everything manual matching must never touch.
CREATE FUNCTION pg_temp.beta_side_effects()
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT jsonb_build_object(
    'inventoryItems', (SELECT count(*) FROM public.inventory_items WHERE organization_id::text LIKE 'be110000-%'),
    'inventoryQuantity', (SELECT coalesce(sum(quantity), 0) FROM public.inventory_items WHERE organization_id::text LIKE 'be110000-%'),
    'inventoryAdjustments', (SELECT count(*) FROM public.inventory_adjustments WHERE organization_id::text LIKE 'be110000-%'),
    'priceHistory', (SELECT count(*) FROM public.inventory_price_history WHERE organization_id::text LIKE 'be110000-%'),
    'invoices', (SELECT jsonb_agg(jsonb_build_object('id', id, 'status', processing_status, 'posted', posted_at) ORDER BY id) FROM public.invoices WHERE organization_id::text LIKE 'be110000-%'),
    'catalogListings', (SELECT jsonb_agg(to_jsonb(l) ORDER BY l.id) FROM public.catalog_vendor_products l WHERE l.id::text LIKE 'be110000-%'),
    'catalogProducts', (SELECT jsonb_agg(to_jsonb(p) ORDER BY p.id) FROM public.catalog_products p WHERE p.id::text LIKE 'be110000-%'),
    'vendorLinks', (SELECT jsonb_agg(jsonb_build_object('id', id, 'catalog', catalog_vendor_id) ORDER BY id) FROM public.vendors WHERE organization_id::text LIKE 'be110000-%')
  )
$$;

CREATE FUNCTION pg_temp.beta_identity_counts()
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT jsonb_build_object(
    'vendors', (SELECT count(*) FROM public.vendors WHERE organization_id::text LIKE 'be110000-%'),
    'products', (SELECT count(*) FROM public.products WHERE organization_id::text LIKE 'be110000-%'),
    'vendorProducts', (SELECT count(*) FROM public.vendor_products WHERE organization_id::text LIKE 'be110000-%')
  )
$$;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
VALUES
  ('be110000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'beta-owner@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('be110000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'beta-admin@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('be110000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'beta-staff@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('be110000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'beta-other-owner@example.invalid', '', now(), '{}', '{}', now(), now());

INSERT INTO public.organizations (id, name, created_by)
VALUES
  ('be110000-0000-4000-8000-000000000101', 'Beta Athletics', 'be110000-0000-4000-8000-000000000001'),
  ('be110000-0000-4000-8000-000000000102', 'Beta Other Athletics', 'be110000-0000-4000-8000-000000000004');

INSERT INTO public.organization_memberships (id, organization_id, user_id, role, active)
VALUES
  ('be110000-0000-4000-8000-000000000111', 'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000001', 'owner', true),
  ('be110000-0000-4000-8000-000000000112', 'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000002', 'admin', true),
  ('be110000-0000-4000-8000-000000000113', 'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000003', 'staff', true),
  ('be110000-0000-4000-8000-000000000114', 'be110000-0000-4000-8000-000000000102', 'be110000-0000-4000-8000-000000000004', 'owner', true);

INSERT INTO public.catalog_vendors (id, name, normalized_name)
VALUES
  ('be110000-0000-4000-8000-000000000201', 'Beta Henry Schein', 'placeholder'),
  ('be110000-0000-4000-8000-000000000202', 'Beta Medline', 'placeholder');

INSERT INTO public.catalog_products (id, name, manufacturer, active, verification_status)
VALUES
  ('be110000-0000-4000-8000-000000000211', 'Ready Wrap Plastic Wrap', NULL, true, 'verified'),
  ('be110000-0000-4000-8000-000000000212', 'Steri-Strip Skin Closures', '3M', true, 'verified'),
  ('be110000-0000-4000-8000-000000000213', 'Mediproxen', NULL, true, 'verified'),
  ('be110000-0000-4000-8000-000000000214', 'Hydrofilm Transparent Dressing 4x6', 'Hartmann', true, 'verified'),
  ('be110000-0000-4000-8000-000000000215', 'Pending Listing Product', NULL, true, 'verified'),
  ('be110000-0000-4000-8000-000000000216', 'Discontinued Listing Product', NULL, true, 'verified'),
  ('be110000-0000-4000-8000-000000000217', 'Rejected Listing Product', NULL, true, 'verified'),
  ('be110000-0000-4000-8000-000000000218', 'Medline Hydrofilm Transparent Dressing', NULL, true, 'verified'),
  ('be110000-0000-4000-8000-000000000219', 'Collision Named Catalog Product', NULL, true, 'verified'),
  ('be110000-0000-4000-8000-000000000220', 'Ready Wrap Mini', NULL, true, 'verified'),
  ('be110000-0000-4000-8000-000000000221', 'Inactive Canonical Product', NULL, false, 'verified');

INSERT INTO public.catalog_vendor_products (
  id, catalog_vendor_id, catalog_product_id, vendor_sku, normalized_vendor_sku,
  package_description, package_status, active, discontinued, verification_status
)
VALUES
  ('be110000-0000-4000-8000-000000000231', 'be110000-0000-4000-8000-000000000201', 'be110000-0000-4000-8000-000000000211', '324-0025', 'x', '6Rl/Ca', 'source_only', true, false, 'verified'),
  ('be110000-0000-4000-8000-000000000232', 'be110000-0000-4000-8000-000000000201', 'be110000-0000-4000-8000-000000000212', '777-6538', 'x', '50/Bx', 'source_only', true, false, 'verified'),
  ('be110000-0000-4000-8000-000000000233', 'be110000-0000-4000-8000-000000000201', 'be110000-0000-4000-8000-000000000213', '151-9200', 'x', '100/Bx', 'source_only', true, false, 'verified'),
  ('be110000-0000-4000-8000-000000000234', 'be110000-0000-4000-8000-000000000201', 'be110000-0000-4000-8000-000000000214', '143-9000', 'x', '10/Bx', 'source_only', true, false, 'verified'),
  ('be110000-0000-4000-8000-000000000235', 'be110000-0000-4000-8000-000000000201', 'be110000-0000-4000-8000-000000000215', '777-0001', 'x', NULL, 'unknown', true, false, 'pending'),
  ('be110000-0000-4000-8000-000000000236', 'be110000-0000-4000-8000-000000000201', 'be110000-0000-4000-8000-000000000216', '777-0002', 'x', NULL, 'unknown', false, true, 'verified'),
  ('be110000-0000-4000-8000-000000000237', 'be110000-0000-4000-8000-000000000201', 'be110000-0000-4000-8000-000000000217', '777-0003', 'x', NULL, 'unknown', true, false, 'rejected'),
  -- Another vendor listing the same SKU and a similar name: must never surface for Henry Schein.
  ('be110000-0000-4000-8000-000000000238', 'be110000-0000-4000-8000-000000000202', 'be110000-0000-4000-8000-000000000218', '324-0025', 'x', NULL, 'unknown', true, false, 'verified'),
  ('be110000-0000-4000-8000-000000000239', 'be110000-0000-4000-8000-000000000201', 'be110000-0000-4000-8000-000000000219', '888-0001', 'x', NULL, 'unknown', true, false, 'verified'),
  ('be110000-0000-4000-8000-000000000240', 'be110000-0000-4000-8000-000000000201', 'be110000-0000-4000-8000-000000000220', '324-0026', 'x', NULL, 'unknown', true, false, 'verified'),
  ('be110000-0000-4000-8000-000000000241', 'be110000-0000-4000-8000-000000000201', 'be110000-0000-4000-8000-000000000221', '777-0004', 'x', NULL, 'unknown', true, false, 'verified');

INSERT INTO public.vendors (id, organization_id, name, normalized_name, active, catalog_vendor_id)
VALUES
  ('be110000-0000-4000-8000-000000000301', 'be110000-0000-4000-8000-000000000101', 'Henry Schein', 'henry schein', true, 'be110000-0000-4000-8000-000000000201'),
  ('be110000-0000-4000-8000-000000000302', 'be110000-0000-4000-8000-000000000101', 'Medline', 'medline', true, 'be110000-0000-4000-8000-000000000202'),
  -- Same name as a catalog vendor would not matter: without an explicit link there is no catalog.
  ('be110000-0000-4000-8000-000000000303', 'be110000-0000-4000-8000-000000000101', 'Local Supply', 'local supply', true, NULL),
  ('be110000-0000-4000-8000-000000000304', 'be110000-0000-4000-8000-000000000102', 'Henry Schein', 'henry schein', true, 'be110000-0000-4000-8000-000000000201');

INSERT INTO public.products (id, organization_id, name, normalized_name, approved, active, staff_requestable)
VALUES
  ('be110000-0000-4000-8000-000000000401', 'be110000-0000-4000-8000-000000000101', 'Existing Organization Tape', 'x', true, true, true),
  ('be110000-0000-4000-8000-000000000402', 'be110000-0000-4000-8000-000000000101', 'Collision Named Catalog Product', 'x', true, true, true);

INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type)
SELECT ('be110000-0000-4000-8000-0000000006' || lpad(n::text, 2, '0'))::uuid,
  CASE WHEN n = 5 THEN 'be110000-0000-4000-8000-000000000102'::uuid ELSE 'be110000-0000-4000-8000-000000000101'::uuid END,
  CASE WHEN n = 5 THEN 'be110000-0000-4000-8000-000000000004'::uuid ELSE 'be110000-0000-4000-8000-000000000001'::uuid END,
  CASE WHEN n = 5 THEN 'be110000-0000-4000-8000-000000000102' ELSE 'be110000-0000-4000-8000-000000000101' END || '/beta-' || n || '.pdf',
  'beta-' || n || '.pdf', 1024, 'application/pdf'
FROM generate_series(1, 6) n;

INSERT INTO public.invoices (id, organization_id, source_file_id, vendor_id, vendor_name, invoice_number, processing_status)
VALUES
  ('be110000-0000-4000-8000-000000000701', 'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', 'be110000-0000-4000-8000-000000000301', 'Henry Schein', 'HS-BETA-1', 'review_required'),
  ('be110000-0000-4000-8000-000000000702', 'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000602', 'be110000-0000-4000-8000-000000000303', 'Local Supply', 'LS-BETA-1', 'review_required'),
  ('be110000-0000-4000-8000-000000000703', 'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000603', NULL, NULL, 'NV-BETA-1', 'review_required'),
  ('be110000-0000-4000-8000-000000000704', 'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000604', 'be110000-0000-4000-8000-000000000302', 'Medline', 'ML-BETA-1', 'review_required'),
  ('be110000-0000-4000-8000-000000000705', 'be110000-0000-4000-8000-000000000102', 'be110000-0000-4000-8000-000000000605', 'be110000-0000-4000-8000-000000000304', 'Henry Schein', 'HS-BETA-B', 'review_required'),
  ('be110000-0000-4000-8000-000000000706', 'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000606', 'be110000-0000-4000-8000-000000000301', 'Henry Schein', 'HS-BETA-DONE', 'completed');

INSERT INTO public.invoice_items (id, invoice_id, organization_id, line_number, sku, description, manufacturer, quantity, unit_of_measure, package_size, unit_price, total_price)
VALUES
  -- The production document.
  ('be110000-0000-4000-8000-000000000801', 'be110000-0000-4000-8000-000000000701', 'be110000-0000-4000-8000-000000000101', 1, '3240025', 'Ready Wrap Classic 4"x650 Yd', NULL, 1, 'Ca', NULL, 38.25, 38.25),
  ('be110000-0000-4000-8000-000000000802', 'be110000-0000-4000-8000-000000000701', 'be110000-0000-4000-8000-000000000101', 2, '7776538', 'Strip Steri-Strip Closure 1/4"x3"White', NULL, 1, 'Bx', NULL, 51.80, 51.80),
  ('be110000-0000-4000-8000-000000000803', 'be110000-0000-4000-8000-000000000701', 'be110000-0000-4000-8000-000000000101', 3, '1519200', 'Mediproxen Tablets 220mg', NULL, 2, 'Bx', NULL, 16.85, 33.70),
  ('be110000-0000-4000-8000-000000000804', 'be110000-0000-4000-8000-000000000701', 'be110000-0000-4000-8000-000000000101', 4, '1439386', 'Hydrofilm Transparent Dre 4x6"', NULL, 3, 'BX', NULL, 6.81, 20.43),
  -- More lines the resolver must leave for a person.
  ('be110000-0000-4000-8000-000000000805', 'be110000-0000-4000-8000-000000000701', 'be110000-0000-4000-8000-000000000101', 5, '7770001', 'Pending catalog listing', NULL, 1, 'EA', NULL, 1, 1),
  ('be110000-0000-4000-8000-000000000806', 'be110000-0000-4000-8000-000000000701', 'be110000-0000-4000-8000-000000000101', 6, 'HYD-46', 'Hydrofilm 4x6 printed with an old code', NULL, 1, 'BX', '10/Bx', 6.81, 6.81),
  ('be110000-0000-4000-8000-000000000807', 'be110000-0000-4000-8000-000000000701', 'be110000-0000-4000-8000-000000000101', 7, 'TAPE-1', 'Organization tape', NULL, 1, 'EA', NULL, 2, 2),
  ('be110000-0000-4000-8000-000000000808', 'be110000-0000-4000-8000-000000000701', 'be110000-0000-4000-8000-000000000101', 8, NULL, 'Ready wrap mini with no printed SKU', NULL, 1, 'EA', NULL, 3, 3),
  ('be110000-0000-4000-8000-000000000809', 'be110000-0000-4000-8000-000000000701', 'be110000-0000-4000-8000-000000000101', 9, '8880001', 'Collision named line', NULL, 1, 'EA', NULL, 4, 4),
  ('be110000-0000-4000-8000-000000000811', 'be110000-0000-4000-8000-000000000702', 'be110000-0000-4000-8000-000000000101', 1, '324-0025', 'Ready Wrap from an unlinked vendor', NULL, 1, 'EA', NULL, 1, 1),
  ('be110000-0000-4000-8000-000000000821', 'be110000-0000-4000-8000-000000000703', 'be110000-0000-4000-8000-000000000101', 1, '324-0025', 'Ready Wrap with no vendor', NULL, 1, 'EA', NULL, 1, 1),
  ('be110000-0000-4000-8000-000000000831', 'be110000-0000-4000-8000-000000000704', 'be110000-0000-4000-8000-000000000101', 1, 'ML-UNKNOWN', 'Medline line', NULL, 1, 'EA', NULL, 1, 1),
  ('be110000-0000-4000-8000-000000000841', 'be110000-0000-4000-8000-000000000705', 'be110000-0000-4000-8000-000000000102', 1, '7770001', 'Pending catalog listing', NULL, 1, 'EA', NULL, 1, 1),
  ('be110000-0000-4000-8000-000000000851', 'be110000-0000-4000-8000-000000000706', 'be110000-0000-4000-8000-000000000101', 1, '7770001', 'Line on a completed invoice', NULL, 1, 'EA', NULL, 1, 1);

CREATE TEMP TABLE beta_snapshots (name text PRIMARY KEY, value jsonb);
GRANT ALL ON beta_snapshots TO authenticated, anon;
INSERT INTO beta_snapshots VALUES ('side_effects_before', pg_temp.beta_side_effects());

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be110000-0000-4000-8000-000000000001', true);

INSERT INTO beta_snapshots VALUES ('resolve', public.resolve_invoice_exact_product_identities(
  'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601'));

-- Check 1: the fixture reproduces production. Three lines match automatically by vendor
-- SKU; 1439386 and every other exception stay for review.
DO $beta_check_1$
DECLARE _summary jsonb := (SELECT value FROM beta_snapshots WHERE name = 'resolve');
BEGIN
  IF (_summary->>'resolvedFromCatalog')::integer <> 3
     OR (SELECT count(*) FROM public.invoice_items
         WHERE invoice_id = 'be110000-0000-4000-8000-000000000701'
           AND product_match_source = 'catalog_vendor_sku_match_key') <> 3
     OR (SELECT count(*) FROM public.invoice_items
         WHERE invoice_id = 'be110000-0000-4000-8000-000000000701' AND product_id IS NULL) <> 6
     OR (pg_temp.beta_line('be110000-0000-4000-8000-000000000804')).product_id IS NOT NULL THEN
    RAISE EXCEPTION 'Check 1 failed: fixture does not reproduce 3 automatic + unresolved: %', _summary;
  END IF;
END
$beta_check_1$;
INSERT INTO beta_snapshots VALUES ('identity_after_resolve', pg_temp.beta_identity_counts());

-- Check 2: an unresolved line can search the linked vendor catalog by product name, and a
-- similarly named listing of another catalog vendor is not offered.
DO $beta_check_2$
DECLARE _search jsonb;
BEGIN
  _search := public.search_invoice_line_catalog_listings(
    'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', '  Hydrofilm ');
  IF (_search->>'available')::boolean IS NOT TRUE
     OR _search->>'catalogVendorName' <> 'Beta Henry Schein'
     OR pg_temp.beta_skus(_search) <> '["143-9000"]'::jsonb
     OR _search #>> '{results,0,catalogVendorProductId}' <> 'be110000-0000-4000-8000-000000000234'
     OR _search #>> '{results,0,name}' <> 'Hydrofilm Transparent Dressing 4x6'
     OR _search #>> '{results,0,manufacturer}' <> 'Hartmann'
     OR _search #>> '{results,0,packageDescription}' <> '10/Bx'
     OR (_search #>> '{results,0,verified}')::boolean IS NOT TRUE
     OR _search #>> '{results,0,organizationProductId}' IS NOT NULL THEN
    RAISE EXCEPTION 'Check 2 failed: name search of the linked catalog: %', _search;
  END IF;
END
$beta_check_2$;

-- Check 3: SKU search is separator-insensitive inside the vendor, ranks the exact SKU
-- first, marks an already adopted listing, and never returns ineligible listings.
DO $beta_check_3$
DECLARE _search jsonb;
BEGIN
  _search := public.search_invoice_line_catalog_listings(
    'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', '3240025');
  IF pg_temp.beta_skus(_search) <> '["324-0025"]'::jsonb
     OR _search #>> '{results,0,catalogVendorProductId}' <> 'be110000-0000-4000-8000-000000000231'
     OR _search #>> '{results,0,organizationProductId}' IS DISTINCT FROM
        (pg_temp.beta_line('be110000-0000-4000-8000-000000000801')).product_id::text THEN
    RAISE EXCEPTION 'Check 3 failed: bare SKU did not find the hyphenated listing: %', _search;
  END IF;
  IF pg_temp.beta_skus(public.search_invoice_line_catalog_listings(
       'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', '324-0025')) <> '["324-0025"]'::jsonb
     OR pg_temp.beta_skus(public.search_invoice_line_catalog_listings(
       'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', '32400')) <> '["324-0026", "324-0025"]'::jsonb
     OR pg_temp.beta_skus(public.search_invoice_line_catalog_listings(
       'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', 'ready wrap')) <> '["324-0026", "324-0025"]'::jsonb THEN
    RAISE EXCEPTION 'Check 3 failed: strict, prefix, or name ordering';
  END IF;
  _search := public.search_invoice_line_catalog_listings(
    'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', '7770001');
  IF pg_temp.beta_skus(_search) <> '["777-0001"]'::jsonb OR (_search #>> '{results,0,verified}')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 'Check 3 failed: an unverified listing must be offered and labelled: %', _search;
  END IF;
  -- Discontinued, rejected, and inactive-product listings; a one-character and an empty query.
  IF pg_temp.beta_skus(public.search_invoice_line_catalog_listings('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', '7770002')) <> '[]'::jsonb
     OR pg_temp.beta_skus(public.search_invoice_line_catalog_listings('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', '777-0003')) <> '[]'::jsonb
     OR pg_temp.beta_skus(public.search_invoice_line_catalog_listings('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', '7770004')) <> '[]'::jsonb
     OR pg_temp.beta_skus(public.search_invoice_line_catalog_listings('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', 'r')) <> '[]'::jsonb
     OR pg_temp.beta_skus(public.search_invoice_line_catalog_listings('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', NULL)) <> '[]'::jsonb
     OR pg_temp.beta_skus(public.search_invoice_line_catalog_listings('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', '%')) <> '[]'::jsonb THEN
    RAISE EXCEPTION 'Check 3 failed: an ineligible listing or an unusable query returned results';
  END IF;
END
$beta_check_3$;

-- Check 4: results come only from the invoice vendor's linked catalog vendor. The same
-- SKU and the same words at another catalog vendor never cross.
DO $beta_check_4$
DECLARE _search jsonb; _query text;
BEGIN
  FOREACH _query IN ARRAY ARRAY['3240025', '324-0025', 'hydrofilm', 'ready wrap', 'dressing', '777', 'wrap']
  LOOP
    _search := public.search_invoice_line_catalog_listings(
      'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', _query);
    IF EXISTS (
      SELECT 1 FROM jsonb_array_elements(_search->'results') result
      JOIN public.catalog_vendor_products listing ON listing.id = (result->>'catalogVendorProductId')::uuid
      WHERE listing.catalog_vendor_id <> 'be110000-0000-4000-8000-000000000201'
    ) THEN
      RAISE EXCEPTION 'Check 4 failed: Henry Schein search for % returned another vendor: %', _query, _search;
    END IF;
  END LOOP;
  -- The Medline invoice sees only Medline.
  _search := public.search_invoice_line_catalog_listings(
    'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000604', '3240025');
  IF _search->>'catalogVendorName' <> 'Beta Medline'
     OR _search #>> '{results,0,catalogVendorProductId}' <> 'be110000-0000-4000-8000-000000000238'
     OR jsonb_array_length(_search->'results') <> 1
     OR pg_temp.beta_skus(public.search_invoice_line_catalog_listings(
       'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000604', 'ready wrap')) <> '[]'::jsonb THEN
    RAISE EXCEPTION 'Check 4 failed: Medline invoice search: %', _search;
  END IF;
END
$beta_check_4$;

-- Check 5: an unlinked organization vendor, or no vendor, exposes no global catalog at
-- all, even for an exact catalog SKU. Nothing is linked by name.
DO $beta_check_5$
DECLARE _unlinked jsonb; _none jsonb;
BEGIN
  _unlinked := public.search_invoice_line_catalog_listings(
    'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000602', '324-0025');
  _none := public.search_invoice_line_catalog_listings(
    'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000603', '324-0025');
  IF _unlinked <> '{"available": false, "reason": "vendor_not_linked_to_catalog", "catalogVendorName": null, "results": []}'::jsonb
     OR _none <> '{"available": false, "reason": "no_vendor", "catalogVendorName": null, "results": []}'::jsonb
     OR (SELECT catalog_vendor_id FROM public.vendors WHERE id = 'be110000-0000-4000-8000-000000000303') IS NOT NULL THEN
    RAISE EXCEPTION 'Check 5 failed: unlinked % / no vendor %', _unlinked, _none;
  END IF;
END
$beta_check_5$;

-- Check 6: choosing an existing organization product matches the line through the existing
-- confirmation path and creates no product.
SELECT public.confirm_invoice_item_product(
  'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601',
  'be110000-0000-4000-8000-000000000807', 'be110000-0000-4000-8000-000000000401', true);
DO $beta_check_6$
DECLARE _line public.invoice_items := pg_temp.beta_line('be110000-0000-4000-8000-000000000807');
BEGIN
  IF _line.product_id IS DISTINCT FROM 'be110000-0000-4000-8000-000000000401'::uuid
     OR _line.product_match_source IS DISTINCT FROM 'manual'
     OR (pg_temp.beta_identity_counts()->>'products')::integer
        <> ((SELECT value FROM beta_snapshots WHERE name = 'identity_after_resolve')->>'products')::integer THEN
    RAISE EXCEPTION 'Check 6 failed: existing organization product match: %', to_jsonb(_line);
  END IF;
END
$beta_check_6$;

-- Check 7: choosing a catalog listing adopts it through adopt_catalog_vendor_product and
-- matches the line in one call, with manual provenance.
INSERT INTO beta_snapshots VALUES ('same_sku_match', public.match_invoice_item_to_catalog_listing(
  'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601',
  'be110000-0000-4000-8000-000000000805', 'be110000-0000-4000-8000-000000000235', NULL));
INSERT INTO beta_snapshots VALUES ('other_sku_match', public.match_invoice_item_to_catalog_listing(
  'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601',
  'be110000-0000-4000-8000-000000000806', 'be110000-0000-4000-8000-000000000234', NULL));
INSERT INTO beta_snapshots VALUES ('no_sku_match', public.match_invoice_item_to_catalog_listing(
  'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601',
  'be110000-0000-4000-8000-000000000808', 'be110000-0000-4000-8000-000000000240', NULL));
DO $beta_check_7$
DECLARE
  _same public.invoice_items := pg_temp.beta_line('be110000-0000-4000-8000-000000000805');
  _other public.invoice_items := pg_temp.beta_line('be110000-0000-4000-8000-000000000806');
  _bare public.invoice_items := pg_temp.beta_line('be110000-0000-4000-8000-000000000808');
  _result jsonb := (SELECT value FROM beta_snapshots WHERE name = 'same_sku_match');
BEGIN
  -- 7770001 is the listing's own SKU: the adopted 777-0001 mapping is the line's identity
  -- and no separator-variant duplicate is created.
  IF _same.product_match_source IS DISTINCT FROM 'manual' OR _same.product_match_decided_at IS NULL
     OR (_result->>'productCreated')::boolean IS NOT TRUE
     OR (_result->>'vendorProductCreated')::boolean IS NOT TRUE
     OR (_result->>'productId')::uuid IS DISTINCT FROM _same.product_id
     OR NOT EXISTS (
       SELECT 1 FROM public.products p JOIN public.vendor_products vp ON vp.product_id = p.id
       WHERE p.id = _same.product_id AND vp.id = _same.vendor_product_id
         AND p.organization_id = 'be110000-0000-4000-8000-000000000101' AND p.active
         AND p.catalog_product_id = 'be110000-0000-4000-8000-000000000215'
         AND vp.catalog_vendor_product_id = 'be110000-0000-4000-8000-000000000235'
         AND vp.vendor_id = 'be110000-0000-4000-8000-000000000301' AND vp.vendor_sku = '777-0001'
     )
     OR (SELECT count(*) FROM public.vendor_products
         WHERE vendor_id = 'be110000-0000-4000-8000-000000000301'
           AND public.normalize_catalog_sku_match_key(vendor_sku) = '7770001') <> 1 THEN
    RAISE EXCEPTION 'Check 7 failed: same-SKU catalog choice: % / %', to_jsonb(_same), _result;
  END IF;
  -- HYD-46 is a different SKU: the product is the adopted catalog product, the listing has
  -- its own mapping, and HYD-46 is remembered for that product like any manual match.
  IF _other.product_match_source IS DISTINCT FROM 'manual'
     OR NOT EXISTS (
       SELECT 1 FROM public.products p
       WHERE p.id = _other.product_id AND p.catalog_product_id = 'be110000-0000-4000-8000-000000000214'
         AND p.name = 'Hydrofilm Transparent Dressing 4x6' AND p.manufacturer = 'Hartmann'
     )
     OR NOT EXISTS (
       SELECT 1 FROM public.vendor_products vp
       WHERE vp.id = _other.vendor_product_id AND vp.vendor_sku = 'HYD-46'
         AND vp.product_id = _other.product_id AND vp.catalog_vendor_product_id IS NULL
         AND vp.vendor_id = 'be110000-0000-4000-8000-000000000301'
     )
     OR (SELECT count(*) FROM public.vendor_products vp
         WHERE vp.catalog_vendor_product_id = 'be110000-0000-4000-8000-000000000234'
           AND vp.vendor_sku = '143-9000' AND vp.product_id = _other.product_id) <> 1 THEN
    RAISE EXCEPTION 'Check 7 failed: different-SKU catalog choice: %', to_jsonb(_other);
  END IF;
  -- A line with no printed SKU has nothing to remember.
  IF _bare.product_match_source IS DISTINCT FROM 'manual' OR _bare.vendor_product_id IS NOT NULL
     OR NOT EXISTS (SELECT 1 FROM public.products p WHERE p.id = _bare.product_id
                    AND p.catalog_product_id = 'be110000-0000-4000-8000-000000000220') THEN
    RAISE EXCEPTION 'Check 7 failed: no-SKU catalog choice: %', to_jsonb(_bare);
  END IF;
END
$beta_check_7$;
INSERT INTO beta_snapshots VALUES ('identity_after_catalog', pg_temp.beta_identity_counts());

-- Check 8: repeating the same choice, and re-running the resolver, creates nothing and
-- changes nothing.
INSERT INTO beta_snapshots VALUES ('lines_before_repeat', (
  SELECT jsonb_agg(to_jsonb(i) - 'product_match_decided_at' - 'updated_at' ORDER BY i.id)
  FROM public.invoice_items i WHERE i.invoice_id = 'be110000-0000-4000-8000-000000000701'));
INSERT INTO beta_snapshots VALUES ('repeat_same', public.match_invoice_item_to_catalog_listing(
  'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601',
  'be110000-0000-4000-8000-000000000805', 'be110000-0000-4000-8000-000000000235',
  (pg_temp.beta_line('be110000-0000-4000-8000-000000000805')).product_id));
INSERT INTO beta_snapshots VALUES ('repeat_other', public.match_invoice_item_to_catalog_listing(
  'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601',
  'be110000-0000-4000-8000-000000000806', 'be110000-0000-4000-8000-000000000234',
  (pg_temp.beta_line('be110000-0000-4000-8000-000000000806')).product_id));
SELECT public.resolve_invoice_exact_product_identities(
  'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601');
DO $beta_check_8$
BEGIN
  IF pg_temp.beta_identity_counts() IS DISTINCT FROM (SELECT value FROM beta_snapshots WHERE name = 'identity_after_catalog')
     OR ((SELECT value FROM beta_snapshots WHERE name = 'repeat_same')->>'alreadyAdopted')::boolean IS NOT TRUE
     OR ((SELECT value FROM beta_snapshots WHERE name = 'repeat_other')->>'productCreated')::boolean IS NOT FALSE
     OR (SELECT jsonb_agg(to_jsonb(i) - 'product_match_decided_at' - 'updated_at' ORDER BY i.id)
         FROM public.invoice_items i WHERE i.invoice_id = 'be110000-0000-4000-8000-000000000701')
        IS DISTINCT FROM (SELECT value FROM beta_snapshots WHERE name = 'lines_before_repeat')
     OR EXISTS (SELECT 1 FROM public.products WHERE organization_id = 'be110000-0000-4000-8000-000000000101'
                AND catalog_product_id IS NOT NULL GROUP BY catalog_product_id HAVING count(*) > 1)
     OR EXISTS (SELECT 1 FROM public.vendor_products WHERE organization_id = 'be110000-0000-4000-8000-000000000101'
                AND catalog_vendor_product_id IS NOT NULL GROUP BY catalog_vendor_product_id HAVING count(*) > 1) THEN
    RAISE EXCEPTION 'Check 8 failed: a repeated catalog choice or resolver run changed identities: % vs %',
      pg_temp.beta_identity_counts(), (SELECT value FROM beta_snapshots WHERE name = 'identity_after_catalog');
  END IF;
END
$beta_check_8$;

-- Check 9: an existing match is never replaced unless the caller names it. A stale caller
-- (expects no match, or a different product) changes nothing; naming it replaces it.
SELECT pg_temp.beta_expect_error(
  $$SELECT public.match_invoice_item_to_catalog_listing('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', 'be110000-0000-4000-8000-000000000807', 'be110000-0000-4000-8000-000000000233', NULL)$$,
  'product match has changed');
SELECT pg_temp.beta_expect_error(
  $$SELECT public.match_invoice_item_to_catalog_listing('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', 'be110000-0000-4000-8000-000000000807', 'be110000-0000-4000-8000-000000000233', 'be110000-0000-4000-8000-000000000402')$$,
  'product match has changed');
-- An automatic match is protected the same way.
SELECT pg_temp.beta_expect_error(
  $$SELECT public.match_invoice_item_to_catalog_listing('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', 'be110000-0000-4000-8000-000000000801', 'be110000-0000-4000-8000-000000000240', NULL)$$,
  'product match has changed');
DO $beta_check_9a$
DECLARE _line public.invoice_items := pg_temp.beta_line('be110000-0000-4000-8000-000000000807');
BEGIN
  IF _line.product_id IS DISTINCT FROM 'be110000-0000-4000-8000-000000000401'::uuid
     OR _line.product_match_source IS DISTINCT FROM 'manual'
     OR (pg_temp.beta_line('be110000-0000-4000-8000-000000000801')).product_match_source IS DISTINCT FROM 'catalog_vendor_sku_match_key'
     OR pg_temp.beta_identity_counts() IS DISTINCT FROM (SELECT value FROM beta_snapshots WHERE name = 'identity_after_catalog') THEN
    RAISE EXCEPTION 'Check 9 failed: a stale catalog choice changed a matched line: %', to_jsonb(_line);
  END IF;
END
$beta_check_9a$;
SELECT public.match_invoice_item_to_catalog_listing(
  'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601',
  'be110000-0000-4000-8000-000000000807', 'be110000-0000-4000-8000-000000000233',
  'be110000-0000-4000-8000-000000000401');
DO $beta_check_9b$
DECLARE _line public.invoice_items := pg_temp.beta_line('be110000-0000-4000-8000-000000000807');
BEGIN
  -- Mediproxen was already adopted by the resolver: the explicit replacement reuses it.
  IF _line.product_id IS DISTINCT FROM (pg_temp.beta_line('be110000-0000-4000-8000-000000000803')).product_id
     OR _line.product_match_source IS DISTINCT FROM 'manual'
     OR (pg_temp.beta_identity_counts()->>'products') <> ((SELECT value FROM beta_snapshots WHERE name = 'identity_after_catalog')->>'products') THEN
    RAISE EXCEPTION 'Check 9 failed: an explicit replacement did not apply cleanly: %', to_jsonb(_line);
  END IF;
END
$beta_check_9b$;
INSERT INTO beta_snapshots VALUES ('identity_before_refusals', pg_temp.beta_identity_counts());
INSERT INTO beta_snapshots VALUES ('lines_before_refusals', (
  SELECT jsonb_agg(to_jsonb(i) ORDER BY i.id) FROM public.invoice_items i WHERE i.organization_id::text LIKE 'be110000-%'));

-- Check 10: a catalog listing outside the invoice vendor's linked catalog cannot be chosen,
-- whatever the caller sends; neither can an ineligible listing or a completed invoice.
SELECT pg_temp.beta_expect_error(
  $$SELECT public.match_invoice_item_to_catalog_listing('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', 'be110000-0000-4000-8000-000000000804', 'be110000-0000-4000-8000-000000000238', NULL)$$,
  'does not belong to the invoice vendor''s catalog');
SELECT pg_temp.beta_expect_error(
  $$SELECT public.match_invoice_item_to_catalog_listing('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000604', 'be110000-0000-4000-8000-000000000831', 'be110000-0000-4000-8000-000000000231', NULL)$$,
  'does not belong to the invoice vendor''s catalog');
SELECT pg_temp.beta_expect_error(
  $$SELECT public.match_invoice_item_to_catalog_listing('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', 'be110000-0000-4000-8000-000000000804', 'be110000-0000-4000-8000-00000000ffff', NULL)$$,
  'does not belong to the invoice vendor''s catalog');
SELECT pg_temp.beta_expect_error(
  $$SELECT public.match_invoice_item_to_catalog_listing('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000602', 'be110000-0000-4000-8000-000000000811', 'be110000-0000-4000-8000-000000000231', NULL)$$,
  'not linked to a catalog vendor');
SELECT pg_temp.beta_expect_error(
  $$SELECT public.match_invoice_item_to_catalog_listing('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000603', 'be110000-0000-4000-8000-000000000821', 'be110000-0000-4000-8000-000000000231', NULL)$$,
  'Select an existing vendor');
SELECT pg_temp.beta_expect_error(
  $$SELECT public.match_invoice_item_to_catalog_listing('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', 'be110000-0000-4000-8000-000000000804', 'be110000-0000-4000-8000-000000000236', NULL)$$,
  'not available to match');
SELECT pg_temp.beta_expect_error(
  $$SELECT public.match_invoice_item_to_catalog_listing('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', 'be110000-0000-4000-8000-000000000804', 'be110000-0000-4000-8000-000000000237', NULL)$$,
  'not available to match');
SELECT pg_temp.beta_expect_error(
  $$SELECT public.match_invoice_item_to_catalog_listing('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', 'be110000-0000-4000-8000-000000000804', 'be110000-0000-4000-8000-000000000241', NULL)$$,
  'not available to match');
SELECT pg_temp.beta_expect_error(
  $$SELECT public.match_invoice_item_to_catalog_listing('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000606', 'be110000-0000-4000-8000-000000000851', 'be110000-0000-4000-8000-000000000235', NULL)$$,
  'Completed invoices cannot be changed');
-- A line from another invoice cannot be reached through this invoice, whether or not its
-- SKU is the listing's own.
SELECT pg_temp.beta_expect_error(
  $$SELECT public.match_invoice_item_to_catalog_listing('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', 'be110000-0000-4000-8000-000000000831', 'be110000-0000-4000-8000-000000000231', NULL)$$,
  'Invoice line not found');
SELECT pg_temp.beta_expect_error(
  $$SELECT public.match_invoice_item_to_catalog_listing('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', 'be110000-0000-4000-8000-000000000811', 'be110000-0000-4000-8000-000000000231', NULL)$$,
  'Invoice line not found');

-- Check 11: when adoption needs reconciliation (an organization product already has the
-- catalog product's name) the whole decision rolls back with a controlled error, not the
-- constraint failure; the reviewer picks that product under their own products instead.
SELECT pg_temp.beta_expect_error(
  $$SELECT public.match_invoice_item_to_catalog_listing('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', 'be110000-0000-4000-8000-000000000809', 'be110000-0000-4000-8000-000000000239', NULL)$$,
  'conflicts with a product or vendor SKU mapping your organization already has');
DO $beta_check_10_11$
BEGIN
  IF pg_temp.beta_identity_counts() IS DISTINCT FROM (SELECT value FROM beta_snapshots WHERE name = 'identity_before_refusals')
     OR (SELECT jsonb_agg(to_jsonb(i) ORDER BY i.id) FROM public.invoice_items i WHERE i.organization_id::text LIKE 'be110000-%')
        IS DISTINCT FROM (SELECT value FROM beta_snapshots WHERE name = 'lines_before_refusals') THEN
    RAISE EXCEPTION 'Checks 10-11 failed: a refused catalog choice left writes behind';
  END IF;
END
$beta_check_10_11$;

-- Check 12: a SKU the catalog does not list (1439386) still has a safe recovery path. The
-- catalog offers nothing, and the existing explicit product creation copies only what the
-- line itself says: no manufacturer, category, or catalog identity is invented.
DO $beta_check_12$
DECLARE _search jsonb; _result jsonb; _line public.invoice_items; _product public.products;
BEGIN
  _search := public.search_invoice_line_catalog_listings(
    'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', '1439386');
  IF (_search->>'available')::boolean IS NOT TRUE OR _search->'results' <> '[]'::jsonb THEN
    RAISE EXCEPTION 'Check 12 failed: an unlisted SKU returned catalog results: %', _search;
  END IF;
  _result := public.create_product_from_invoice_item(
    'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', 'be110000-0000-4000-8000-000000000804');
  _line := pg_temp.beta_line('be110000-0000-4000-8000-000000000804');
  SELECT * INTO _product FROM public.products WHERE id = _line.product_id;
  IF _line.product_match_source IS DISTINCT FROM 'manual'
     OR _product.name <> 'Hydrofilm Transparent Dre 4x6"'
     OR _product.manufacturer IS NOT NULL OR _product.category_id IS NOT NULL
     OR _product.catalog_product_id IS NOT NULL OR _product.pack_size IS NOT NULL
     OR _product.unit_of_measure <> 'BX'
     OR NOT EXISTS (
       SELECT 1 FROM public.vendor_products vp
       WHERE vp.id = _line.vendor_product_id AND vp.vendor_sku = '1439386'
         AND vp.vendor_id = 'be110000-0000-4000-8000-000000000301' AND vp.catalog_vendor_product_id IS NULL
     ) THEN
    RAISE EXCEPTION 'Check 12 failed: manual product creation: % / %', to_jsonb(_line), to_jsonb(_product);
  END IF;
END
$beta_check_12$;

-- Check 13: none of it stocked inventory, recorded a price, changed an invoice's status,
-- linked a vendor, or wrote to the global catalog.
RESET ROLE;
DO $beta_check_13$
BEGIN
  IF pg_temp.beta_side_effects() IS DISTINCT FROM (SELECT value FROM beta_snapshots WHERE name = 'side_effects_before') THEN
    RAISE EXCEPTION 'Check 13 failed: manual catalog matching had side effects: % vs %',
      pg_temp.beta_side_effects(), (SELECT value FROM beta_snapshots WHERE name = 'side_effects_before');
  END IF;
  IF (pg_temp.beta_side_effects()->>'inventoryItems')::integer <> 0 THEN
    RAISE EXCEPTION 'Check 13 failed: inventory exists before posting';
  END IF;
END
$beta_check_13$;

-- Check 14: owner-only and organization-scoped, for both functions.
INSERT INTO beta_snapshots VALUES ('identity_before_denials', pg_temp.beta_identity_counts());
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be110000-0000-4000-8000-000000000002', true);
SELECT pg_temp.beta_expect_error(
  $$SELECT public.search_invoice_line_catalog_listings('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', 'ready wrap')$$,
  'Forbidden: owner access required');
SELECT pg_temp.beta_expect_error(
  $$SELECT public.match_invoice_item_to_catalog_listing('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', 'be110000-0000-4000-8000-000000000809', 'be110000-0000-4000-8000-000000000232', NULL)$$,
  'Forbidden: owner access required');
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be110000-0000-4000-8000-000000000003', true);
SELECT pg_temp.beta_expect_error(
  $$SELECT public.search_invoice_line_catalog_listings('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', 'ready wrap')$$,
  'Forbidden: owner access required');
SELECT pg_temp.beta_expect_error(
  $$SELECT public.match_invoice_item_to_catalog_listing('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', 'be110000-0000-4000-8000-000000000809', 'be110000-0000-4000-8000-000000000232', NULL)$$,
  'Forbidden: owner access required');
-- Another organization's owner: not this organization, and not this invoice through their own.
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be110000-0000-4000-8000-000000000004', true);
SELECT pg_temp.beta_expect_error(
  $$SELECT public.search_invoice_line_catalog_listings('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', 'ready wrap')$$,
  'Forbidden: owner access required');
SELECT pg_temp.beta_expect_error(
  $$SELECT public.match_invoice_item_to_catalog_listing('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', 'be110000-0000-4000-8000-000000000809', 'be110000-0000-4000-8000-000000000232', NULL)$$,
  'Forbidden: owner access required');
SELECT pg_temp.beta_expect_error(
  $$SELECT public.search_invoice_line_catalog_listings('be110000-0000-4000-8000-000000000102', 'be110000-0000-4000-8000-000000000601', 'ready wrap')$$,
  'Invoice review not found');
SELECT pg_temp.beta_expect_error(
  $$SELECT public.match_invoice_item_to_catalog_listing('be110000-0000-4000-8000-000000000102', 'be110000-0000-4000-8000-000000000601', 'be110000-0000-4000-8000-000000000809', 'be110000-0000-4000-8000-000000000232', NULL)$$,
  'Invoice review not found');
SET LOCAL ROLE anon;
SELECT pg_temp.beta_expect_error(
  $$SELECT public.search_invoice_line_catalog_listings('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', 'ready wrap')$$,
  'permission denied');
SELECT pg_temp.beta_expect_error(
  $$SELECT public.match_invoice_item_to_catalog_listing('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601', 'be110000-0000-4000-8000-000000000809', 'be110000-0000-4000-8000-000000000232', NULL)$$,
  'permission denied');
RESET ROLE;
DO $beta_check_14a$
BEGIN
  IF pg_temp.beta_identity_counts() IS DISTINCT FROM (SELECT value FROM beta_snapshots WHERE name = 'identity_before_denials') THEN
    RAISE EXCEPTION 'Check 14 failed: a denied caller wrote identities';
  END IF;
END
$beta_check_14a$;
-- The other organization adopts the same global listing into its own, separate product.
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be110000-0000-4000-8000-000000000004', true);
SELECT public.match_invoice_item_to_catalog_listing(
  'be110000-0000-4000-8000-000000000102', 'be110000-0000-4000-8000-000000000605',
  'be110000-0000-4000-8000-000000000841', 'be110000-0000-4000-8000-000000000235', NULL);
RESET ROLE;
DO $beta_check_14b$
DECLARE
  _theirs public.invoice_items := pg_temp.beta_line('be110000-0000-4000-8000-000000000841');
  _ours public.invoice_items := pg_temp.beta_line('be110000-0000-4000-8000-000000000805');
BEGIN
  IF _theirs.product_id IS NULL OR _theirs.product_id = _ours.product_id
     OR (SELECT organization_id FROM public.products WHERE id = _theirs.product_id) <> 'be110000-0000-4000-8000-000000000102'
     OR (SELECT organization_id FROM public.vendor_products WHERE id = _theirs.vendor_product_id) <> 'be110000-0000-4000-8000-000000000102'
     OR (SELECT count(*) FROM public.products
         WHERE organization_id = 'be110000-0000-4000-8000-000000000101'
           AND catalog_product_id = 'be110000-0000-4000-8000-000000000215') <> 1 THEN
    RAISE EXCEPTION 'Check 14 failed: organizations are not isolated: %', to_jsonb(_theirs);
  END IF;
END
$beta_check_14b$;

-- Check 15: the Phase 6C.1 posting boundary is unchanged. An unresolved line still blocks
-- posting; once every line is reviewed, manually catalog-matched lines post with exactly
-- their reviewed product and mapping, and only posting creates inventory.
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be110000-0000-4000-8000-000000000001', true);
SELECT pg_temp.beta_expect_error(
  $$SELECT public.post_reviewed_invoice('be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601')$$,
  'Match or create a product for every invoice line before approval');
SELECT public.confirm_invoice_item_product(
  'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601',
  'be110000-0000-4000-8000-000000000809', 'be110000-0000-4000-8000-000000000402', true);
-- Snapshots are taken and compared as the migration role so both organizations are visible.
RESET ROLE;
INSERT INTO beta_snapshots VALUES ('identity_before_post', pg_temp.beta_identity_counts());
INSERT INTO beta_snapshots VALUES ('links_before_post', (
  SELECT jsonb_agg(jsonb_build_object('id', id, 'product', product_id, 'mapping', vendor_product_id, 'source', product_match_source) ORDER BY id)
  FROM public.invoice_items WHERE invoice_id = 'be110000-0000-4000-8000-000000000701'));
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be110000-0000-4000-8000-000000000001', true);
INSERT INTO beta_snapshots VALUES ('post', public.post_reviewed_invoice(
  'be110000-0000-4000-8000-000000000101', 'be110000-0000-4000-8000-000000000601'));
RESET ROLE;
DO $beta_check_15$
DECLARE _post jsonb := (SELECT value FROM beta_snapshots WHERE name = 'post');
BEGIN
  IF (_post->>'alreadyCompleted')::boolean IS NOT FALSE
     OR (SELECT processing_status FROM public.invoices WHERE id = 'be110000-0000-4000-8000-000000000701') <> 'completed'
     OR pg_temp.beta_identity_counts() IS DISTINCT FROM (SELECT value FROM beta_snapshots WHERE name = 'identity_before_post')
     OR (SELECT jsonb_agg(jsonb_build_object('id', id, 'product', product_id, 'mapping', vendor_product_id, 'source', product_match_source) ORDER BY id)
         FROM public.invoice_items WHERE invoice_id = 'be110000-0000-4000-8000-000000000701')
        IS DISTINCT FROM (SELECT value FROM beta_snapshots WHERE name = 'links_before_post')
     OR (SELECT count(*) FROM public.inventory_items WHERE organization_id = 'be110000-0000-4000-8000-000000000101')
        <> (SELECT count(DISTINCT product_id) FROM public.invoice_items WHERE invoice_id = 'be110000-0000-4000-8000-000000000701')
     OR (SELECT count(*) FROM public.inventory_items WHERE organization_id = 'be110000-0000-4000-8000-000000000102') <> 0 THEN
    RAISE EXCEPTION 'Check 15 failed: posting after manual catalog matching: %', _post;
  END IF;
END
$beta_check_15$;

SELECT 15 AS checks_passed, 0 AS checks_failed;

ROLLBACK;
