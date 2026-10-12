-- Beta hardening rollback-only behavioral verification: re-matching a line by hand when its
-- vendor SKU is already a catalog-adopted mapping.
-- Run after 20261012120000_beta_invoice_manual_catalog_matching.sql. All data rolls back.
--
-- The invoice prints 324-0025 (the adopted catalog SKU exactly) and 3240025 (the same SKU
-- without separators). Both lines are matched automatically to the adopted catalog product.
-- The reviewer then deliberately chooses a different product.

BEGIN;

CREATE FUNCTION pg_temp.rematch_expect_error(_statement text, _expected text)
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
    -- A controlled domain error, never a constraint or trigger failure.
    IF SQLSTATE <> 'P0001' THEN
      RAISE EXCEPTION 'Expected a controlled domain error, got SQLSTATE % ("%")', SQLSTATE, SQLERRM;
    END IF;
    RETURN;
  END;
  RAISE EXCEPTION 'Statement unexpectedly succeeded; expected "%": %', _expected, _statement;
END;
$$;

CREATE FUNCTION pg_temp.rematch_line(_id uuid)
RETURNS public.invoice_items
LANGUAGE sql
AS $$ SELECT * FROM public.invoice_items WHERE id = _id $$;

-- Every organization vendor mapping, exactly as stored (updated_at aside).
CREATE FUNCTION pg_temp.rematch_mappings()
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT coalesce(jsonb_agg(to_jsonb(m) - 'updated_at' ORDER BY m.id), '[]'::jsonb)
  FROM public.vendor_products m WHERE m.organization_id::text LIKE 'be120000-%'
$$;

CREATE FUNCTION pg_temp.rematch_side_effects()
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT jsonb_build_object(
    'inventoryItems', (SELECT count(*) FROM public.inventory_items WHERE organization_id::text LIKE 'be120000-%'),
    'inventoryAdjustments', (SELECT count(*) FROM public.inventory_adjustments WHERE organization_id::text LIKE 'be120000-%'),
    'priceHistory', (SELECT count(*) FROM public.inventory_price_history WHERE organization_id::text LIKE 'be120000-%'),
    'invoices', (SELECT jsonb_agg(jsonb_build_object('id', id, 'status', processing_status, 'posted', posted_at) ORDER BY id) FROM public.invoices WHERE organization_id::text LIKE 'be120000-%'),
    'catalogListings', (SELECT jsonb_agg(to_jsonb(l) ORDER BY l.id) FROM public.catalog_vendor_products l WHERE l.id::text LIKE 'be120000-%'),
    'vendorLinks', (SELECT jsonb_agg(jsonb_build_object('id', id, 'catalog', catalog_vendor_id) ORDER BY id) FROM public.vendors WHERE organization_id::text LIKE 'be120000-%')
  )
$$;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
VALUES ('be120000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'rematch-owner@example.invalid', '', now(), '{}', '{}', now(), now());

INSERT INTO public.organizations (id, name, created_by)
VALUES ('be120000-0000-4000-8000-000000000101', 'Rematch Athletics', 'be120000-0000-4000-8000-000000000001');

INSERT INTO public.organization_memberships (id, organization_id, user_id, role, active)
VALUES ('be120000-0000-4000-8000-000000000111', 'be120000-0000-4000-8000-000000000101', 'be120000-0000-4000-8000-000000000001', 'owner', true);

INSERT INTO public.catalog_vendors (id, name, normalized_name)
VALUES
  ('be120000-0000-4000-8000-000000000201', 'Rematch Henry Schein', 'placeholder'),
  ('be120000-0000-4000-8000-000000000202', 'Rematch Medline', 'placeholder');

INSERT INTO public.catalog_products (id, name, manufacturer, active, verification_status)
VALUES
  ('be120000-0000-4000-8000-000000000211', 'Rematch Ready Wrap Plastic Wrap', NULL, true, 'verified'),
  ('be120000-0000-4000-8000-000000000212', 'Rematch Ready Wrap Mini', NULL, true, 'verified'),
  ('be120000-0000-4000-8000-000000000213', 'Rematch Conflict Catalog Product', NULL, true, 'verified'),
  ('be120000-0000-4000-8000-000000000214', 'Rematch Medline Product', NULL, true, 'verified');

INSERT INTO public.catalog_vendor_products (
  id, catalog_vendor_id, catalog_product_id, vendor_sku, normalized_vendor_sku,
  package_description, package_status, active, discontinued, verification_status
)
VALUES
  ('be120000-0000-4000-8000-000000000231', 'be120000-0000-4000-8000-000000000201', 'be120000-0000-4000-8000-000000000211', '324-0025', 'x', '6Rl/Ca', 'source_only', true, false, 'verified'),
  ('be120000-0000-4000-8000-000000000232', 'be120000-0000-4000-8000-000000000201', 'be120000-0000-4000-8000-000000000212', '324-0026', 'x', NULL, 'unknown', true, false, 'verified'),
  ('be120000-0000-4000-8000-000000000233', 'be120000-0000-4000-8000-000000000201', 'be120000-0000-4000-8000-000000000213', '555-0001', 'x', NULL, 'unknown', true, false, 'verified'),
  ('be120000-0000-4000-8000-000000000234', 'be120000-0000-4000-8000-000000000202', 'be120000-0000-4000-8000-000000000214', 'ML-1', 'x', NULL, 'unknown', true, false, 'verified');

INSERT INTO public.vendors (id, organization_id, name, normalized_name, active, catalog_vendor_id)
VALUES
  ('be120000-0000-4000-8000-000000000301', 'be120000-0000-4000-8000-000000000101', 'Henry Schein', 'henry schein', true, 'be120000-0000-4000-8000-000000000201'),
  ('be120000-0000-4000-8000-000000000302', 'be120000-0000-4000-8000-000000000101', 'Medline', 'medline', true, 'be120000-0000-4000-8000-000000000202');

INSERT INTO public.products (id, organization_id, name, normalized_name, approved, active, staff_requestable)
VALUES
  ('be120000-0000-4000-8000-000000000401', 'be120000-0000-4000-8000-000000000101', 'Local Stretch Wrap', 'x', true, true, true),
  ('be120000-0000-4000-8000-000000000402', 'be120000-0000-4000-8000-000000000101', 'Local Tape', 'x', true, true, true),
  ('be120000-0000-4000-8000-000000000403', 'be120000-0000-4000-8000-000000000101', 'Local Tape Alternative', 'x', true, true, true);

-- An ordinary remembered mapping (not from the catalog): repointing it on an explicit
-- re-match is the existing behavior and must stay.
INSERT INTO public.vendor_products (id, organization_id, vendor_id, product_id, vendor_sku, active)
VALUES ('be120000-0000-4000-8000-000000000501', 'be120000-0000-4000-8000-000000000101', 'be120000-0000-4000-8000-000000000301', 'be120000-0000-4000-8000-000000000402', 'TAPE-1', true);

INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type)
VALUES ('be120000-0000-4000-8000-000000000601', 'be120000-0000-4000-8000-000000000101', 'be120000-0000-4000-8000-000000000001', 'be120000-0000-4000-8000-000000000101/rematch-1.pdf', 'rematch-1.pdf', 1024, 'application/pdf');

INSERT INTO public.invoices (id, organization_id, source_file_id, vendor_id, vendor_name, invoice_number, processing_status)
VALUES ('be120000-0000-4000-8000-000000000701', 'be120000-0000-4000-8000-000000000101', 'be120000-0000-4000-8000-000000000601', 'be120000-0000-4000-8000-000000000301', 'Henry Schein', 'HS-REMATCH-1', 'review_required');

INSERT INTO public.invoice_items (id, invoice_id, organization_id, line_number, sku, description, quantity, unit_of_measure, package_size, unit_price, total_price)
VALUES
  ('be120000-0000-4000-8000-000000000801', 'be120000-0000-4000-8000-000000000701', 'be120000-0000-4000-8000-000000000101', 1, '324-0025', 'Exact SKU, re-matched to an organization product', 1, 'Ca', NULL, 38.25, 38.25),
  ('be120000-0000-4000-8000-000000000802', 'be120000-0000-4000-8000-000000000701', 'be120000-0000-4000-8000-000000000101', 2, '3240025', 'Bare SKU, re-matched to an organization product', 1, 'Ca', NULL, 38.25, 38.25),
  ('be120000-0000-4000-8000-000000000803', 'be120000-0000-4000-8000-000000000701', 'be120000-0000-4000-8000-000000000101', 3, '324-0025', 'Exact SKU, re-matched to another catalog product', 1, 'Ca', NULL, 38.25, 38.25),
  ('be120000-0000-4000-8000-000000000804', 'be120000-0000-4000-8000-000000000701', 'be120000-0000-4000-8000-000000000101', 4, '3240025', 'Bare SKU, re-matched to another catalog product', 1, 'Ca', NULL, 38.25, 38.25),
  ('be120000-0000-4000-8000-000000000805', 'be120000-0000-4000-8000-000000000701', 'be120000-0000-4000-8000-000000000101', 5, ' 324-0025 ', 'Exact SKU, stale request', 1, 'Ca', NULL, 38.25, 38.25),
  ('be120000-0000-4000-8000-000000000806', 'be120000-0000-4000-8000-000000000701', 'be120000-0000-4000-8000-000000000101', 6, '555-0001', 'Conflicting mapping', 1, 'EA', NULL, 2, 2),
  ('be120000-0000-4000-8000-000000000807', 'be120000-0000-4000-8000-000000000701', 'be120000-0000-4000-8000-000000000101', 7, 'TAPE-1', 'Ordinary remembered SKU', 1, 'EA', '12/Bx', 3, 3),
  ('be120000-0000-4000-8000-000000000808', 'be120000-0000-4000-8000-000000000701', 'be120000-0000-4000-8000-000000000101', 8, '3240025', 'Bare SKU, matched back to the catalog product', 1, 'Ca', NULL, 38.25, 38.25);

CREATE TEMP TABLE rematch_snapshots (name text PRIMARY KEY, value jsonb);
GRANT ALL ON rematch_snapshots TO authenticated;
INSERT INTO rematch_snapshots VALUES ('side_effects_before', pg_temp.rematch_side_effects());

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be120000-0000-4000-8000-000000000001', true);

-- The Medline listing is adopted, then its product is remembered for Henry Schein SKU
-- 555-0001 by an earlier manual match. Henry Schein's catalog lists 555-0001 as something
-- else, so adopting that listing cannot be reconciled automatically.
SELECT public.adopt_catalog_vendor_product('be120000-0000-4000-8000-000000000101', 'be120000-0000-4000-8000-000000000234');
RESET ROLE;
INSERT INTO public.vendor_products (id, organization_id, vendor_id, product_id, vendor_sku, active)
SELECT 'be120000-0000-4000-8000-000000000502', 'be120000-0000-4000-8000-000000000101', 'be120000-0000-4000-8000-000000000301', id, '555-0001', true
FROM public.products WHERE organization_id = 'be120000-0000-4000-8000-000000000101' AND catalog_product_id = 'be120000-0000-4000-8000-000000000214';
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be120000-0000-4000-8000-000000000001', true);

SELECT public.resolve_invoice_exact_product_identities(
  'be120000-0000-4000-8000-000000000101', 'be120000-0000-4000-8000-000000000601');

-- Setup check: every line is matched automatically, the 324-0025 lines to one adopted
-- catalog mapping that stores the hyphenated SKU.
DO $rematch_setup$
DECLARE _adopted public.vendor_products;
BEGIN
  SELECT * INTO STRICT _adopted FROM public.vendor_products
  WHERE organization_id = 'be120000-0000-4000-8000-000000000101'
    AND catalog_vendor_product_id = 'be120000-0000-4000-8000-000000000231';
  IF _adopted.vendor_sku <> '324-0025' OR NOT _adopted.active
     OR (SELECT count(*) FROM public.invoice_items
         WHERE invoice_id = 'be120000-0000-4000-8000-000000000701' AND product_id IS NULL) <> 0
     OR (SELECT count(*) FROM public.invoice_items
         WHERE invoice_id = 'be120000-0000-4000-8000-000000000701'
           AND vendor_product_id = _adopted.id AND product_id = _adopted.product_id) <> 6
     OR (pg_temp.rematch_line('be120000-0000-4000-8000-000000000801')).product_match_source <> 'catalog_vendor_sku'
     OR (pg_temp.rematch_line('be120000-0000-4000-8000-000000000802')).product_match_source <> 'org_vendor_sku_match_key' THEN
    RAISE EXCEPTION 'Setup failed: lines were not matched to the adopted mapping: %',
      (SELECT jsonb_agg(jsonb_build_object('sku', sku, 'source', product_match_source, 'mapping', vendor_product_id) ORDER BY line_number)
       FROM public.invoice_items WHERE invoice_id = 'be120000-0000-4000-8000-000000000701');
  END IF;
END
$rematch_setup$;
INSERT INTO rematch_snapshots VALUES ('mappings_after_resolve', pg_temp.rematch_mappings());

-- Check 1: exact SKU, re-matched to another organization product. Succeeds; the line is
-- matched for this invoice with manual provenance; the adopted mapping is not repointed.
INSERT INTO rematch_snapshots VALUES ('exact_to_product', public.confirm_invoice_item_product(
  'be120000-0000-4000-8000-000000000101', 'be120000-0000-4000-8000-000000000601',
  'be120000-0000-4000-8000-000000000801', 'be120000-0000-4000-8000-000000000401', true));
DO $rematch_check_1$
DECLARE
  _line public.invoice_items := pg_temp.rematch_line('be120000-0000-4000-8000-000000000801');
  _result jsonb := (SELECT value FROM rematch_snapshots WHERE name = 'exact_to_product');
  _adopted uuid := (SELECT id FROM public.vendor_products WHERE catalog_vendor_product_id = 'be120000-0000-4000-8000-000000000231'
                    AND organization_id = 'be120000-0000-4000-8000-000000000101');
BEGIN
  IF _line.product_id IS DISTINCT FROM 'be120000-0000-4000-8000-000000000401'::uuid
     OR _line.vendor_product_id IS NOT NULL
     OR _line.product_match_source IS DISTINCT FROM 'manual'
     OR (_result->>'productId')::uuid IS DISTINCT FROM 'be120000-0000-4000-8000-000000000401'::uuid
     OR _result->>'vendorProductId' IS NOT NULL
     OR (_result->>'vendorSkuRemembered')::boolean IS NOT FALSE
     OR (_result->>'preservedVendorProductId')::uuid IS DISTINCT FROM _adopted
     OR pg_temp.rematch_mappings() IS DISTINCT FROM (SELECT value FROM rematch_snapshots WHERE name = 'mappings_after_resolve') THEN
    RAISE EXCEPTION 'Check 1 failed: exact SKU re-match to an organization product: % / %', to_jsonb(_line), _result;
  END IF;
END
$rematch_check_1$;

-- Check 2: the same with the SKU printed without separators. No separator-variant mapping
-- is created to shadow the adopted one.
INSERT INTO rematch_snapshots VALUES ('bare_to_product', public.confirm_invoice_item_product(
  'be120000-0000-4000-8000-000000000101', 'be120000-0000-4000-8000-000000000601',
  'be120000-0000-4000-8000-000000000802', 'be120000-0000-4000-8000-000000000401', true));
DO $rematch_check_2$
DECLARE
  _line public.invoice_items := pg_temp.rematch_line('be120000-0000-4000-8000-000000000802');
  _result jsonb := (SELECT value FROM rematch_snapshots WHERE name = 'bare_to_product');
BEGIN
  IF _line.product_id IS DISTINCT FROM 'be120000-0000-4000-8000-000000000401'::uuid
     OR _line.vendor_product_id IS NOT NULL
     OR _line.product_match_source IS DISTINCT FROM 'manual'
     OR (_result->>'vendorSkuRemembered')::boolean IS NOT FALSE
     OR _result->>'preservedVendorProductId' IS NULL
     OR pg_temp.rematch_mappings() IS DISTINCT FROM (SELECT value FROM rematch_snapshots WHERE name = 'mappings_after_resolve')
     OR (SELECT count(*) FROM public.vendor_products
         WHERE vendor_id = 'be120000-0000-4000-8000-000000000301'
           AND public.normalize_catalog_sku_match_key(vendor_sku) = '3240025') <> 1 THEN
    RAISE EXCEPTION 'Check 2 failed: bare SKU re-match to an organization product: % / %', to_jsonb(_line), _result;
  END IF;
END
$rematch_check_2$;

-- Checks 3 and 4: re-matched to another catalog product of the same vendor, for the exact
-- and the bare SKU. The chosen listing is adopted once; 324-0025 keeps its own mapping.
INSERT INTO rematch_snapshots VALUES ('exact_to_catalog', public.match_invoice_item_to_catalog_listing(
  'be120000-0000-4000-8000-000000000101', 'be120000-0000-4000-8000-000000000601',
  'be120000-0000-4000-8000-000000000803', 'be120000-0000-4000-8000-000000000232',
  (pg_temp.rematch_line('be120000-0000-4000-8000-000000000803')).product_id));
INSERT INTO rematch_snapshots VALUES ('bare_to_catalog', public.match_invoice_item_to_catalog_listing(
  'be120000-0000-4000-8000-000000000101', 'be120000-0000-4000-8000-000000000601',
  'be120000-0000-4000-8000-000000000804', 'be120000-0000-4000-8000-000000000232',
  (pg_temp.rematch_line('be120000-0000-4000-8000-000000000804')).product_id));
DO $rematch_check_3_4$
DECLARE
  _exact public.invoice_items := pg_temp.rematch_line('be120000-0000-4000-8000-000000000803');
  _bare public.invoice_items := pg_temp.rematch_line('be120000-0000-4000-8000-000000000804');
  _mini uuid := (SELECT id FROM public.products WHERE organization_id = 'be120000-0000-4000-8000-000000000101'
                 AND catalog_product_id = 'be120000-0000-4000-8000-000000000212');
  _first jsonb := (SELECT value FROM rematch_snapshots WHERE name = 'exact_to_catalog');
  _second jsonb := (SELECT value FROM rematch_snapshots WHERE name = 'bare_to_catalog');
BEGIN
  IF _mini IS NULL
     OR _exact.product_id IS DISTINCT FROM _mini OR _bare.product_id IS DISTINCT FROM _mini
     OR _exact.vendor_product_id IS NOT NULL OR _bare.vendor_product_id IS NOT NULL
     OR _exact.product_match_source IS DISTINCT FROM 'manual' OR _bare.product_match_source IS DISTINCT FROM 'manual'
     OR (_first->>'vendorSkuRemembered')::boolean IS NOT FALSE OR (_second->>'vendorSkuRemembered')::boolean IS NOT FALSE
     OR (_first->>'productCreated')::boolean IS NOT TRUE OR (_second->>'alreadyAdopted')::boolean IS NOT TRUE
     -- Exactly one new mapping: the chosen listing's own adoption (324-0026).
     OR (SELECT count(*) FROM public.vendor_products WHERE organization_id = 'be120000-0000-4000-8000-000000000101')
        <> jsonb_array_length((SELECT value FROM rematch_snapshots WHERE name = 'mappings_after_resolve')) + 1
     OR (SELECT count(*) FROM public.vendor_products
         WHERE catalog_vendor_product_id = 'be120000-0000-4000-8000-000000000232' AND vendor_sku = '324-0026' AND product_id = _mini) <> 1
     OR (SELECT jsonb_agg(to_jsonb(m) - 'updated_at' ORDER BY m.id) FROM public.vendor_products m
         WHERE m.organization_id = 'be120000-0000-4000-8000-000000000101'
           AND m.catalog_vendor_product_id IS DISTINCT FROM 'be120000-0000-4000-8000-000000000232')
        IS DISTINCT FROM (SELECT value FROM rematch_snapshots WHERE name = 'mappings_after_resolve') THEN
    RAISE EXCEPTION 'Checks 3-4 failed: re-match to another catalog product: % / % / % / %', to_jsonb(_exact), to_jsonb(_bare), _first, _second;
  END IF;
END
$rematch_check_3_4$;
INSERT INTO rematch_snapshots VALUES ('mappings_after_catalog', pg_temp.rematch_mappings());

-- Check 5: stale overwrite protection is intact. A caller that does not name the product
-- it is replacing changes nothing.
INSERT INTO rematch_snapshots VALUES ('stale_line', to_jsonb(pg_temp.rematch_line('be120000-0000-4000-8000-000000000805')));
SELECT pg_temp.rematch_expect_error(
  $$SELECT public.match_invoice_item_to_catalog_listing('be120000-0000-4000-8000-000000000101', 'be120000-0000-4000-8000-000000000601', 'be120000-0000-4000-8000-000000000805', 'be120000-0000-4000-8000-000000000232', NULL)$$,
  'product match has changed');
SELECT pg_temp.rematch_expect_error(
  $$SELECT public.match_invoice_item_to_catalog_listing('be120000-0000-4000-8000-000000000101', 'be120000-0000-4000-8000-000000000601', 'be120000-0000-4000-8000-000000000805', 'be120000-0000-4000-8000-000000000232', 'be120000-0000-4000-8000-000000000401')$$,
  'product match has changed');
DO $rematch_check_5$
BEGIN
  IF to_jsonb(pg_temp.rematch_line('be120000-0000-4000-8000-000000000805')) IS DISTINCT FROM (SELECT value FROM rematch_snapshots WHERE name = 'stale_line')
     OR pg_temp.rematch_mappings() IS DISTINCT FROM (SELECT value FROM rematch_snapshots WHERE name = 'mappings_after_catalog') THEN
    RAISE EXCEPTION 'Check 5 failed: a stale re-match changed the line or a mapping';
  END IF;
END
$rematch_check_5$;

-- Check 6: a mapping conflict that makes the request unsafe is refused with a controlled
-- domain error. SKU 555-0001 is remembered for a product that is a different catalog
-- product, so the Henry Schein listing for 555-0001 cannot be adopted over it.
INSERT INTO rematch_snapshots VALUES ('conflict_line', to_jsonb(pg_temp.rematch_line('be120000-0000-4000-8000-000000000806')));
SELECT pg_temp.rematch_expect_error(
  $$SELECT public.match_invoice_item_to_catalog_listing('be120000-0000-4000-8000-000000000101', 'be120000-0000-4000-8000-000000000601', 'be120000-0000-4000-8000-000000000806', 'be120000-0000-4000-8000-000000000233', (SELECT product_id FROM public.invoice_items WHERE id = 'be120000-0000-4000-8000-000000000806'))$$,
  'conflicts with a product or vendor SKU mapping');
DO $rematch_check_6$
BEGIN
  IF to_jsonb(pg_temp.rematch_line('be120000-0000-4000-8000-000000000806')) IS DISTINCT FROM (SELECT value FROM rematch_snapshots WHERE name = 'conflict_line')
     OR pg_temp.rematch_mappings() IS DISTINCT FROM (SELECT value FROM rematch_snapshots WHERE name = 'mappings_after_catalog')
     OR EXISTS (SELECT 1 FROM public.products WHERE organization_id = 'be120000-0000-4000-8000-000000000101'
                AND catalog_product_id = 'be120000-0000-4000-8000-000000000213') THEN
    RAISE EXCEPTION 'Check 6 failed: a refused conflicting re-match left writes behind';
  END IF;
END
$rematch_check_6$;

-- Check 7: matching back to the catalog product reuses the adopted mapping for the bare
-- SKU and for the exact SKU. Nothing is duplicated.
SELECT public.confirm_invoice_item_product(
  'be120000-0000-4000-8000-000000000101', 'be120000-0000-4000-8000-000000000601',
  'be120000-0000-4000-8000-000000000808', 'be120000-0000-4000-8000-000000000401', true);
INSERT INTO rematch_snapshots VALUES ('bare_back', public.confirm_invoice_item_product(
  'be120000-0000-4000-8000-000000000101', 'be120000-0000-4000-8000-000000000601',
  'be120000-0000-4000-8000-000000000808',
  (SELECT product_id FROM public.vendor_products WHERE catalog_vendor_product_id = 'be120000-0000-4000-8000-000000000231' AND organization_id = 'be120000-0000-4000-8000-000000000101'),
  true));
INSERT INTO rematch_snapshots VALUES ('exact_back', public.confirm_invoice_item_product(
  'be120000-0000-4000-8000-000000000101', 'be120000-0000-4000-8000-000000000601',
  'be120000-0000-4000-8000-000000000801',
  (SELECT product_id FROM public.vendor_products WHERE catalog_vendor_product_id = 'be120000-0000-4000-8000-000000000231' AND organization_id = 'be120000-0000-4000-8000-000000000101'),
  true));
DO $rematch_check_7$
DECLARE
  _adopted public.vendor_products;
  _bare public.invoice_items := pg_temp.rematch_line('be120000-0000-4000-8000-000000000808');
  _exact public.invoice_items := pg_temp.rematch_line('be120000-0000-4000-8000-000000000801');
BEGIN
  SELECT * INTO STRICT _adopted FROM public.vendor_products
  WHERE organization_id = 'be120000-0000-4000-8000-000000000101'
    AND catalog_vendor_product_id = 'be120000-0000-4000-8000-000000000231';
  IF _bare.vendor_product_id IS DISTINCT FROM _adopted.id OR _bare.product_id IS DISTINCT FROM _adopted.product_id
     OR _exact.vendor_product_id IS DISTINCT FROM _adopted.id OR _exact.product_id IS DISTINCT FROM _adopted.product_id
     OR _bare.product_match_source IS DISTINCT FROM 'manual' OR _exact.product_match_source IS DISTINCT FROM 'manual'
     OR ((SELECT value FROM rematch_snapshots WHERE name = 'bare_back')->>'vendorSkuRemembered')::boolean IS NOT TRUE
     OR (SELECT value FROM rematch_snapshots WHERE name = 'bare_back')->>'preservedVendorProductId' IS NOT NULL
     OR _adopted.vendor_sku <> '324-0025' OR NOT _adopted.active
     OR _adopted.catalog_vendor_product_id IS DISTINCT FROM 'be120000-0000-4000-8000-000000000231'::uuid
     OR (SELECT count(*) FROM public.vendor_products WHERE organization_id = 'be120000-0000-4000-8000-000000000101')
        <> jsonb_array_length((SELECT value FROM rematch_snapshots WHERE name = 'mappings_after_catalog'))
     OR EXISTS (SELECT 1 FROM public.vendor_products WHERE organization_id = 'be120000-0000-4000-8000-000000000101'
                GROUP BY vendor_id, lower(btrim(vendor_sku)) HAVING count(*) > 1) THEN
    RAISE EXCEPTION 'Check 7 failed: matching back to the catalog product: % / % / %', to_jsonb(_bare), to_jsonb(_exact), to_jsonb(_adopted);
  END IF;
END
$rematch_check_7$;

-- Check 8: an ordinary remembered SKU (not from the catalog) is still re-pointed by an
-- explicit re-match, as before.
SELECT public.confirm_invoice_item_product(
  'be120000-0000-4000-8000-000000000101', 'be120000-0000-4000-8000-000000000601',
  'be120000-0000-4000-8000-000000000807', 'be120000-0000-4000-8000-000000000403', true);
DO $rematch_check_8$
DECLARE
  _line public.invoice_items := pg_temp.rematch_line('be120000-0000-4000-8000-000000000807');
  _mapping public.vendor_products;
BEGIN
  SELECT * INTO STRICT _mapping FROM public.vendor_products WHERE id = 'be120000-0000-4000-8000-000000000501';
  IF _line.vendor_product_id IS DISTINCT FROM _mapping.id
     OR _line.product_id IS DISTINCT FROM 'be120000-0000-4000-8000-000000000403'::uuid
     OR _mapping.product_id IS DISTINCT FROM 'be120000-0000-4000-8000-000000000403'::uuid
     OR _mapping.package_size IS DISTINCT FROM '12/Bx' OR NOT _mapping.active
     OR (SELECT count(*) FROM public.vendor_products WHERE vendor_id = 'be120000-0000-4000-8000-000000000301' AND vendor_sku = 'TAPE-1') <> 1 THEN
    RAISE EXCEPTION 'Check 8 failed: ordinary remembered SKU: % / %', to_jsonb(_line), to_jsonb(_mapping);
  END IF;
END
$rematch_check_8$;

-- Check 9: none of the re-matching stocked inventory, recorded a price, changed an invoice
-- status, linked a vendor, or wrote to the global catalog.
RESET ROLE;
DO $rematch_check_9$
BEGIN
  IF pg_temp.rematch_side_effects() IS DISTINCT FROM (SELECT value FROM rematch_snapshots WHERE name = 'side_effects_before')
     OR (pg_temp.rematch_side_effects()->>'inventoryItems')::integer <> 0 THEN
    RAISE EXCEPTION 'Check 9 failed: re-matching had side effects: %', pg_temp.rematch_side_effects();
  END IF;
END
$rematch_check_9$;

-- Check 10: posting still takes the reviewed identity exactly. A line matched for this
-- invoice only posts without a mapping, and posting does not create or repoint one.
-- (Inventory allows one item per vendor SKU, so the fixture's other lines for the same SKU
-- are removed first; that pre-existing posting rule is not part of this change.)
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be120000-0000-4000-8000-000000000001', true);
SELECT public.confirm_invoice_item_product(
  'be120000-0000-4000-8000-000000000101', 'be120000-0000-4000-8000-000000000601',
  'be120000-0000-4000-8000-000000000801', 'be120000-0000-4000-8000-000000000401', true);
RESET ROLE;
DELETE FROM public.invoice_items WHERE id IN (
  'be120000-0000-4000-8000-000000000802', 'be120000-0000-4000-8000-000000000803', 'be120000-0000-4000-8000-000000000804',
  'be120000-0000-4000-8000-000000000805', 'be120000-0000-4000-8000-000000000808');
INSERT INTO rematch_snapshots VALUES ('mappings_before_post', (
  SELECT jsonb_agg(jsonb_build_object('id', id, 'product', product_id, 'sku', vendor_sku, 'active', active, 'catalog', catalog_vendor_product_id) ORDER BY id)
  FROM public.vendor_products WHERE organization_id = 'be120000-0000-4000-8000-000000000101'));
INSERT INTO rematch_snapshots VALUES ('links_before_post', (
  SELECT jsonb_agg(jsonb_build_object('id', id, 'product', product_id, 'mapping', vendor_product_id, 'source', product_match_source) ORDER BY id)
  FROM public.invoice_items WHERE invoice_id = 'be120000-0000-4000-8000-000000000701'));
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be120000-0000-4000-8000-000000000001', true);
SELECT public.post_reviewed_invoice('be120000-0000-4000-8000-000000000101', 'be120000-0000-4000-8000-000000000601');
RESET ROLE;
DO $rematch_check_10$
BEGIN
  IF (SELECT processing_status FROM public.invoices WHERE id = 'be120000-0000-4000-8000-000000000701') <> 'completed'
     OR (SELECT jsonb_agg(jsonb_build_object('id', id, 'product', product_id, 'sku', vendor_sku, 'active', active, 'catalog', catalog_vendor_product_id) ORDER BY id)
         FROM public.vendor_products WHERE organization_id = 'be120000-0000-4000-8000-000000000101')
        IS DISTINCT FROM (SELECT value FROM rematch_snapshots WHERE name = 'mappings_before_post')
     OR (SELECT jsonb_agg(jsonb_build_object('id', id, 'product', product_id, 'mapping', vendor_product_id, 'source', product_match_source) ORDER BY id)
         FROM public.invoice_items WHERE invoice_id = 'be120000-0000-4000-8000-000000000701')
        IS DISTINCT FROM (SELECT value FROM rematch_snapshots WHERE name = 'links_before_post')
     OR (SELECT count(*) FROM public.inventory_price_history
         WHERE organization_id = 'be120000-0000-4000-8000-000000000101' AND vendor_product_id IS NULL) <> 1
     OR (SELECT count(*) FROM public.inventory_items
         WHERE organization_id = 'be120000-0000-4000-8000-000000000101'
           AND product_id = 'be120000-0000-4000-8000-000000000401' AND sku = '324-0025') <> 1 THEN
    RAISE EXCEPTION 'Check 10 failed: posting after re-matching changed a reviewed identity or a mapping';
  END IF;
END
$rematch_check_10$;

SELECT 10 AS checks_passed, 0 AS checks_failed;

ROLLBACK;
