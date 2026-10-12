-- Beta hardening rollback-only behavioral verification:
--   * creating a product from a line never gives a vendor SKU a second identity;
--   * plain manual confirmation refuses a stale request.
-- Run after 20261012120000_beta_invoice_manual_catalog_matching.sql. All data rolls back.

BEGIN;

CREATE FUNCTION pg_temp.create_expect_error(_statement text, _expected text)
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

CREATE FUNCTION pg_temp.create_line(_id uuid)
RETURNS public.invoice_items
LANGUAGE sql
AS $$ SELECT * FROM public.invoice_items WHERE id = _id $$;

CREATE FUNCTION pg_temp.create_state()
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT jsonb_build_object(
    'products', (SELECT coalesce(jsonb_agg(to_jsonb(p) - 'updated_at' ORDER BY p.id), '[]') FROM public.products p WHERE p.organization_id::text LIKE 'be150000-%'),
    'mappings', (SELECT coalesce(jsonb_agg(to_jsonb(m) - 'updated_at' ORDER BY m.id), '[]') FROM public.vendor_products m WHERE m.organization_id::text LIKE 'be150000-%'),
    'lines', (SELECT coalesce(jsonb_agg(to_jsonb(l) - 'updated_at' ORDER BY l.id), '[]') FROM public.invoice_items l WHERE l.organization_id::text LIKE 'be150000-%'),
    'inventory', (SELECT count(*) FROM public.inventory_items WHERE organization_id::text LIKE 'be150000-%')
  )
$$;

INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
VALUES
  ('be150000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'create-owner@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('be150000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'create-admin@example.invalid', '', now(), '{}', '{}', now(), now());
INSERT INTO public.organizations (id, name, created_by)
VALUES ('be150000-0000-4000-8000-000000000101', 'Create Athletics', 'be150000-0000-4000-8000-000000000001');
INSERT INTO public.organization_memberships (id, organization_id, user_id, role, active)
VALUES
  ('be150000-0000-4000-8000-000000000111', 'be150000-0000-4000-8000-000000000101', 'be150000-0000-4000-8000-000000000001', 'owner', true),
  ('be150000-0000-4000-8000-000000000112', 'be150000-0000-4000-8000-000000000101', 'be150000-0000-4000-8000-000000000002', 'admin', true);

INSERT INTO public.catalog_vendors (id, name, normalized_name)
VALUES ('be150000-0000-4000-8000-000000000201', 'Create Henry Schein', 'placeholder');
INSERT INTO public.catalog_products (id, name, active, verification_status)
VALUES
  ('be150000-0000-4000-8000-000000000211', 'Create Ready Wrap Plastic Wrap', true, 'verified'),
  ('be150000-0000-4000-8000-000000000212', 'Create Forgotten Catalog Product', true, 'verified');
INSERT INTO public.catalog_vendor_products (id, catalog_vendor_id, catalog_product_id, vendor_sku, normalized_vendor_sku, package_status, active, discontinued, verification_status)
VALUES
  ('be150000-0000-4000-8000-000000000231', 'be150000-0000-4000-8000-000000000201', 'be150000-0000-4000-8000-000000000211', '324-0025', 'x', 'unknown', true, false, 'verified'),
  ('be150000-0000-4000-8000-000000000232', 'be150000-0000-4000-8000-000000000201', 'be150000-0000-4000-8000-000000000212', '900-0001', 'x', 'unknown', true, false, 'verified');

INSERT INTO public.vendors (id, organization_id, name, normalized_name, active, catalog_vendor_id)
VALUES
  ('be150000-0000-4000-8000-000000000301', 'be150000-0000-4000-8000-000000000101', 'Henry Schein', 'henry schein', true, 'be150000-0000-4000-8000-000000000201'),
  ('be150000-0000-4000-8000-000000000302', 'be150000-0000-4000-8000-000000000101', 'Medline', 'medline', true, NULL);

INSERT INTO public.products (id, organization_id, name, normalized_name, approved, active, staff_requestable)
VALUES
  ('be150000-0000-4000-8000-000000000401', 'be150000-0000-4000-8000-000000000101', 'Remembered Tape', 'x', true, true, true),
  ('be150000-0000-4000-8000-000000000402', 'be150000-0000-4000-8000-000000000101', 'First Choice', 'x', true, true, true),
  ('be150000-0000-4000-8000-000000000403', 'be150000-0000-4000-8000-000000000101', 'Second Choice', 'x', true, true, true);

-- TAPE-1 is remembered by hand. OLD-1 was remembered and later forgotten (deactivated).
INSERT INTO public.vendor_products (id, organization_id, vendor_id, product_id, vendor_sku, active)
VALUES
  ('be150000-0000-4000-8000-000000000501', 'be150000-0000-4000-8000-000000000101', 'be150000-0000-4000-8000-000000000301', 'be150000-0000-4000-8000-000000000401', 'TAPE-1', true),
  ('be150000-0000-4000-8000-000000000502', 'be150000-0000-4000-8000-000000000101', 'be150000-0000-4000-8000-000000000301', 'be150000-0000-4000-8000-000000000401', 'OLD-1', false);

INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type)
SELECT ('be150000-0000-4000-8000-0000000006' || lpad(n::text, 2, '0'))::uuid, 'be150000-0000-4000-8000-000000000101',
  'be150000-0000-4000-8000-000000000001', 'be150000-0000-4000-8000-000000000101/create-' || n || '.pdf', 'create-' || n || '.pdf', 1024, 'application/pdf'
FROM generate_series(1, 3) n;
INSERT INTO public.invoices (id, organization_id, source_file_id, vendor_id, vendor_name, invoice_number, processing_status)
VALUES
  ('be150000-0000-4000-8000-000000000701', 'be150000-0000-4000-8000-000000000101', 'be150000-0000-4000-8000-000000000601', 'be150000-0000-4000-8000-000000000301', 'Henry Schein', 'C-1', 'review_required'),
  ('be150000-0000-4000-8000-000000000702', 'be150000-0000-4000-8000-000000000101', 'be150000-0000-4000-8000-000000000602', 'be150000-0000-4000-8000-000000000302', 'Medline', 'C-2', 'review_required'),
  ('be150000-0000-4000-8000-000000000703', 'be150000-0000-4000-8000-000000000101', 'be150000-0000-4000-8000-000000000603', 'be150000-0000-4000-8000-000000000301', 'Henry Schein', 'C-3', 'review_required');

INSERT INTO public.invoice_items (id, invoice_id, organization_id, line_number, sku, description, manufacturer, quantity, unit_of_measure, package_size, unit_price, total_price)
VALUES
  ('be150000-0000-4000-8000-000000000801', 'be150000-0000-4000-8000-000000000701', 'be150000-0000-4000-8000-000000000101', 1, '324-0025', 'Exact catalog SKU', NULL, 1, 'Ca', NULL, 1, 1),
  ('be150000-0000-4000-8000-000000000802', 'be150000-0000-4000-8000-000000000701', 'be150000-0000-4000-8000-000000000101', 2, '3240025', 'Catalog SKU without separators', NULL, 1, 'Ca', NULL, 1, 1),
  ('be150000-0000-4000-8000-000000000803', 'be150000-0000-4000-8000-000000000701', 'be150000-0000-4000-8000-000000000101', 3, '32-40025', 'Catalog SKU with separators elsewhere', NULL, 1, 'Ca', NULL, 1, 1),
  ('be150000-0000-4000-8000-000000000804', 'be150000-0000-4000-8000-000000000701', 'be150000-0000-4000-8000-000000000101', 4, 'tape-1', 'Hand-remembered SKU', NULL, 1, 'EA', NULL, 1, 1),
  ('be150000-0000-4000-8000-000000000805', 'be150000-0000-4000-8000-000000000701', 'be150000-0000-4000-8000-000000000101', 5, 'NEW-9', 'A genuinely new product', NULL, 2, 'BX', '10/Bx', 4, 8),
  ('be150000-0000-4000-8000-000000000806', 'be150000-0000-4000-8000-000000000701', 'be150000-0000-4000-8000-000000000101', 6, '9000001', 'Forgotten catalog SKU', NULL, 1, 'EA', NULL, 1, 1),
  ('be150000-0000-4000-8000-000000000807', 'be150000-0000-4000-8000-000000000701', 'be150000-0000-4000-8000-000000000101', 7, 'OLD-1', 'Forgotten hand-remembered SKU', NULL, 1, 'EA', NULL, 1, 1),
  ('be150000-0000-4000-8000-000000000808', 'be150000-0000-4000-8000-000000000701', 'be150000-0000-4000-8000-000000000101', 8, 'STALE-1', 'Line two reviewers are looking at', NULL, 1, 'EA', NULL, 1, 1),
  ('be150000-0000-4000-8000-000000000811', 'be150000-0000-4000-8000-000000000702', 'be150000-0000-4000-8000-000000000101', 1, '3240025', 'Medline prints the same digits', NULL, 1, 'EA', NULL, 1, 1),
  ('be150000-0000-4000-8000-000000000821', 'be150000-0000-4000-8000-000000000703', 'be150000-0000-4000-8000-000000000101', 1, 'STALE-1', 'Line on another invoice', NULL, 1, 'EA', NULL, 1, 1);

CREATE TEMP TABLE create_snapshots (name text PRIMARY KEY, value jsonb);
GRANT ALL ON create_snapshots TO authenticated, anon;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be150000-0000-4000-8000-000000000001', true);
-- Both listings were adopted earlier in Catalog; the owner later forgot the 900-0001 mapping.
SELECT public.adopt_catalog_vendor_product('be150000-0000-4000-8000-000000000101', 'be150000-0000-4000-8000-000000000231');
SELECT public.adopt_catalog_vendor_product('be150000-0000-4000-8000-000000000101', 'be150000-0000-4000-8000-000000000232');
RESET ROLE;
UPDATE public.vendor_products SET active = false WHERE catalog_vendor_product_id = 'be150000-0000-4000-8000-000000000232';
INSERT INTO create_snapshots VALUES ('before', pg_temp.create_state());
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be150000-0000-4000-8000-000000000001', true);

-- Checks 1 and 2: a SKU that is a catalog-adopted mapping, exactly or apart from separators
-- (anywhere), cannot be given a second product. The message names the existing product.
SELECT pg_temp.create_expect_error(
  $$SELECT public.create_product_from_invoice_item('be150000-0000-4000-8000-000000000101', 'be150000-0000-4000-8000-000000000601', 'be150000-0000-4000-8000-000000000801')$$,
  'Vendor SKU 324-0025 is already the catalog item "Create Ready Wrap Plastic Wrap" in your products (stored as 324-0025). Match this line to that product instead');
SELECT pg_temp.create_expect_error(
  $$SELECT public.create_product_from_invoice_item('be150000-0000-4000-8000-000000000101', 'be150000-0000-4000-8000-000000000601', 'be150000-0000-4000-8000-000000000802')$$,
  'Vendor SKU 3240025 is already the catalog item "Create Ready Wrap Plastic Wrap" in your products (stored as 324-0025)');
SELECT pg_temp.create_expect_error(
  $$SELECT public.create_product_from_invoice_item('be150000-0000-4000-8000-000000000101', 'be150000-0000-4000-8000-000000000601', 'be150000-0000-4000-8000-000000000803')$$,
  'Vendor SKU 32-40025 is already the catalog item');
-- A catalog mapping the owner deactivated still identifies the SKU.
SELECT pg_temp.create_expect_error(
  $$SELECT public.create_product_from_invoice_item('be150000-0000-4000-8000-000000000101', 'be150000-0000-4000-8000-000000000601', 'be150000-0000-4000-8000-000000000806')$$,
  'Vendor SKU 9000001 is already the catalog item "Create Forgotten Catalog Product"');
-- Check 3: a SKU the owner remembered by hand is refused the same controlled way.
SELECT pg_temp.create_expect_error(
  $$SELECT public.create_product_from_invoice_item('be150000-0000-4000-8000-000000000101', 'be150000-0000-4000-8000-000000000601', 'be150000-0000-4000-8000-000000000804')$$,
  'This vendor SKU already maps to another product; choose or correct that match instead');
-- Checks 5 and 6: every refusal was a controlled error and created nothing.
DO $create_check_1_3$
BEGIN
  IF pg_temp.create_state() IS DISTINCT FROM (SELECT value FROM create_snapshots WHERE name = 'before') THEN
    RAISE EXCEPTION 'Checks 1-3, 5, 6 failed: a refused product creation left writes behind';
  END IF;
END
$create_check_1_3$;

-- Check 4: a genuinely new SKU still creates a product and remembers the SKU, copying only
-- what the line says.
INSERT INTO create_snapshots VALUES ('created', public.create_product_from_invoice_item(
  'be150000-0000-4000-8000-000000000101', 'be150000-0000-4000-8000-000000000601', 'be150000-0000-4000-8000-000000000805'));
-- A hand-remembered SKU the owner forgot can be given a new product, as before.
SELECT public.create_product_from_invoice_item('be150000-0000-4000-8000-000000000101', 'be150000-0000-4000-8000-000000000601', 'be150000-0000-4000-8000-000000000807');
DO $create_check_4$
DECLARE
  _line public.invoice_items := pg_temp.create_line('be150000-0000-4000-8000-000000000805');
  _product public.products;
  _before jsonb := (SELECT value FROM create_snapshots WHERE name = 'before');
BEGIN
  SELECT * INTO _product FROM public.products WHERE id = _line.product_id;
  IF _line.product_match_source IS DISTINCT FROM 'manual'
     OR ((SELECT value FROM create_snapshots WHERE name = 'created')->>'productId')::uuid IS DISTINCT FROM _line.product_id
     OR _product.name <> 'A genuinely new product' OR _product.manufacturer IS NOT NULL
     OR _product.catalog_product_id IS NOT NULL OR _product.pack_size <> '10/Bx' OR _product.unit_of_measure <> 'BX'
     OR NOT EXISTS (SELECT 1 FROM public.vendor_products WHERE id = _line.vendor_product_id AND vendor_sku = 'NEW-9'
                    AND vendor_id = 'be150000-0000-4000-8000-000000000301' AND product_id = _product.id AND catalog_vendor_product_id IS NULL)
     OR (pg_temp.create_line('be150000-0000-4000-8000-000000000807')).product_id IS NULL
     -- Exactly two products and two mappings were added; nothing else changed.
     OR jsonb_array_length(pg_temp.create_state()->'products') <> jsonb_array_length(_before->'products') + 2
     OR jsonb_array_length(pg_temp.create_state()->'mappings') <> jsonb_array_length(_before->'mappings') + 2
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(_before->'mappings') old WHERE NOT (pg_temp.create_state()->'mappings') @> jsonb_build_array(old))
     OR (SELECT count(*) FROM public.vendor_products WHERE vendor_id = 'be150000-0000-4000-8000-000000000301'
         AND public.normalize_catalog_sku_match_key(vendor_sku) = '3240025') <> 1 THEN
    RAISE EXCEPTION 'Check 4 failed: ordinary product creation: % / %', to_jsonb(_line), to_jsonb(_product);
  END IF;
END
$create_check_4$;

-- Check 7: the rule is per vendor. Medline printing the same digits has no such mapping,
-- so its line can become a new product; Henry Schein's mapping is untouched.
SELECT public.create_product_from_invoice_item('be150000-0000-4000-8000-000000000101', 'be150000-0000-4000-8000-000000000602', 'be150000-0000-4000-8000-000000000811');
DO $create_check_7$
DECLARE _line public.invoice_items := pg_temp.create_line('be150000-0000-4000-8000-000000000811');
BEGIN
  IF _line.product_id IS NULL
     OR NOT EXISTS (SELECT 1 FROM public.vendor_products WHERE id = _line.vendor_product_id AND vendor_id = 'be150000-0000-4000-8000-000000000302' AND vendor_sku = '3240025')
     OR (SELECT count(*) FROM public.vendor_products WHERE vendor_id = 'be150000-0000-4000-8000-000000000301'
         AND public.normalize_catalog_sku_match_key(vendor_sku) = '3240025' AND catalog_vendor_product_id = 'be150000-0000-4000-8000-000000000231') <> 1
     OR (SELECT count(*) FROM public.vendor_products WHERE vendor_id = 'be150000-0000-4000-8000-000000000301'
         AND public.normalize_catalog_sku_match_key(vendor_sku) = '3240025') <> 1 THEN
    RAISE EXCEPTION 'Check 7 failed: vendor scope: %', to_jsonb(_line);
  END IF;
END
$create_check_7$;

-- Check 8: plain confirmation with the product the reviewer saw. An unmatched line is
-- confirmed by a caller that expects it unmatched.
INSERT INTO create_snapshots VALUES ('first_confirm', public.confirm_invoice_item_product_expected(
  'be150000-0000-4000-8000-000000000101', 'be150000-0000-4000-8000-000000000601',
  'be150000-0000-4000-8000-000000000808', 'be150000-0000-4000-8000-000000000402', NULL));
DO $create_check_8$
DECLARE _line public.invoice_items := pg_temp.create_line('be150000-0000-4000-8000-000000000808');
BEGIN
  IF _line.product_id IS DISTINCT FROM 'be150000-0000-4000-8000-000000000402'::uuid
     OR _line.product_match_source IS DISTINCT FROM 'manual' OR _line.vendor_product_id IS NULL
     OR (SELECT value FROM create_snapshots WHERE name = 'first_confirm')
        <> jsonb_build_object('productId', 'be150000-0000-4000-8000-000000000402', 'vendorProductId', _line.vendor_product_id,
                              'vendorSkuRemembered', true, 'preservedVendorProductId', NULL) THEN
    RAISE EXCEPTION 'Check 8 failed: confirmation with the expected product: %', to_jsonb(_line);
  END IF;
END
$create_check_8$;

-- Check 9: a second reviewer whose dialog still shows the line as unmatched (or matched to
-- something else) cannot overwrite the first reviewer's match. Nothing changes.
INSERT INTO create_snapshots VALUES ('before_stale', pg_temp.create_state());
SELECT pg_temp.create_expect_error(
  $$SELECT public.confirm_invoice_item_product_expected('be150000-0000-4000-8000-000000000101', 'be150000-0000-4000-8000-000000000601', 'be150000-0000-4000-8000-000000000808', 'be150000-0000-4000-8000-000000000403', NULL)$$,
  'product match has changed; reload the invoice');
SELECT pg_temp.create_expect_error(
  $$SELECT public.confirm_invoice_item_product_expected('be150000-0000-4000-8000-000000000101', 'be150000-0000-4000-8000-000000000601', 'be150000-0000-4000-8000-000000000808', 'be150000-0000-4000-8000-000000000403', 'be150000-0000-4000-8000-000000000401')$$,
  'product match has changed; reload the invoice');
-- A line cannot be reached through another invoice, and the usual refusals still apply.
SELECT pg_temp.create_expect_error(
  $$SELECT public.confirm_invoice_item_product_expected('be150000-0000-4000-8000-000000000101', 'be150000-0000-4000-8000-000000000603', 'be150000-0000-4000-8000-000000000808', 'be150000-0000-4000-8000-000000000403', 'be150000-0000-4000-8000-000000000402')$$,
  'Invoice line not found');
SELECT pg_temp.create_expect_error(
  $$SELECT public.confirm_invoice_item_product_expected('be150000-0000-4000-8000-000000000101', 'be150000-0000-4000-8000-000000000601', 'be150000-0000-4000-8000-000000000808', 'be150000-0000-4000-8000-00000000ffff', 'be150000-0000-4000-8000-000000000402')$$,
  'Selected product is unavailable');
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be150000-0000-4000-8000-000000000002', true);
SELECT pg_temp.create_expect_error(
  $$SELECT public.confirm_invoice_item_product_expected('be150000-0000-4000-8000-000000000101', 'be150000-0000-4000-8000-000000000601', 'be150000-0000-4000-8000-000000000808', 'be150000-0000-4000-8000-000000000403', 'be150000-0000-4000-8000-000000000402')$$,
  'Forbidden: owner access required');
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be150000-0000-4000-8000-000000000001', true);
DO $create_check_9$
BEGIN
  IF pg_temp.create_state() IS DISTINCT FROM (SELECT value FROM create_snapshots WHERE name = 'before_stale') THEN
    RAISE EXCEPTION 'Check 9 failed: a stale or refused confirmation changed something';
  END IF;
END
$create_check_9$;
SET LOCAL ROLE anon;
DO $create_check_9_anon$
BEGIN
  BEGIN
    PERFORM public.confirm_invoice_item_product_expected('be150000-0000-4000-8000-000000000101', 'be150000-0000-4000-8000-000000000601', 'be150000-0000-4000-8000-000000000808', 'be150000-0000-4000-8000-000000000403', 'be150000-0000-4000-8000-000000000402');
  EXCEPTION WHEN insufficient_privilege THEN RETURN;
  END;
  RAISE EXCEPTION 'Check 9 failed: anon could call the confirmation';
END
$create_check_9_anon$;
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be150000-0000-4000-8000-000000000001', true);

-- Check 10: naming the current product replaces it, with the same mapping rules as before
-- (the hand-remembered STALE-1 mapping follows the explicit re-match).
SELECT public.confirm_invoice_item_product_expected(
  'be150000-0000-4000-8000-000000000101', 'be150000-0000-4000-8000-000000000601',
  'be150000-0000-4000-8000-000000000808', 'be150000-0000-4000-8000-000000000403', 'be150000-0000-4000-8000-000000000402');
DO $create_check_10$
DECLARE _line public.invoice_items := pg_temp.create_line('be150000-0000-4000-8000-000000000808');
BEGIN
  IF _line.product_id IS DISTINCT FROM 'be150000-0000-4000-8000-000000000403'::uuid
     OR _line.product_match_source IS DISTINCT FROM 'manual'
     OR (SELECT count(*) FROM public.vendor_products WHERE vendor_id = 'be150000-0000-4000-8000-000000000301' AND vendor_sku = 'STALE-1') <> 1
     OR (SELECT product_id FROM public.vendor_products WHERE id = _line.vendor_product_id) IS DISTINCT FROM 'be150000-0000-4000-8000-000000000403'::uuid
     OR (SELECT (value->>'inventory')::integer FROM create_snapshots WHERE name = 'before') <> 0
     OR (pg_temp.create_state()->>'inventory')::integer <> 0 THEN
    RAISE EXCEPTION 'Check 10 failed: explicit replacement: %', to_jsonb(_line);
  END IF;
END
$create_check_10$;

SELECT 10 AS checks_passed, 0 AS checks_failed;

ROLLBACK;
