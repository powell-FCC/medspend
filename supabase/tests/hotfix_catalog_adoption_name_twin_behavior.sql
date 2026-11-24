-- Hotfix rollback-only behavioral verification: catalog adoption of same-named catalog
-- variants, and named refusals from manual catalog matching.
-- Run after 20261124120000_hotfix_catalog_adoption_name_twin.sql. All data rolls back.
--
-- The fixture mirrors production invoice 64685535 (2026-11-23): Henry Schein lists PowerFlex
-- 2.75" (101-2983) and PowerFlex 2" (613-0167) as two catalog products that share the name
-- "The PowerFlex® Taping System". Before the hotfix the second variant could never be
-- adopted, at import or by hand.

BEGIN;

CREATE FUNCTION pg_temp.nt_try(_sql text)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  _result jsonb;
  _message text;
  _detail text;
  _hint text;
  _state text;
BEGIN
  EXECUTE _sql INTO _result;
  RETURN jsonb_build_object('ok', true, 'result', _result);
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS _message = MESSAGE_TEXT, _detail = PG_EXCEPTION_DETAIL,
    _hint = PG_EXCEPTION_HINT, _state = RETURNED_SQLSTATE;
  RETURN jsonb_build_object('ok', false, 'sqlstate', _state, 'message', _message,
    'detail', _detail, 'hint', CASE WHEN _hint ~ '^\{' THEN _hint::jsonb END);
END;
$$;

CREATE FUNCTION pg_temp.nt_match(_source uuid, _item uuid, _listing uuid)
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT pg_temp.nt_try(format(
    'SELECT public.match_invoice_item_to_catalog_listing(%L, %L, %L, %L, (SELECT product_id FROM public.invoice_items WHERE id = %L))',
    'ca7a0000-0000-4000-8000-000000000101', _source, _item, _listing, _item))
$$;

CREATE FUNCTION pg_temp.nt_identity()
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT jsonb_build_object(
    'products', (SELECT jsonb_agg(jsonb_build_object('id', id, 'name', name, 'active', active, 'catalog', catalog_product_id) ORDER BY id)
                 FROM public.products WHERE organization_id = 'ca7a0000-0000-4000-8000-000000000101'),
    'vendorProducts', (SELECT jsonb_agg(jsonb_build_object('id', id, 'product', product_id, 'sku', vendor_sku, 'active', active, 'listing', catalog_vendor_product_id) ORDER BY id)
                       FROM public.vendor_products WHERE organization_id = 'ca7a0000-0000-4000-8000-000000000101'),
    'lines', (SELECT jsonb_agg(jsonb_build_object('id', id, 'product', product_id, 'vendorProduct', vendor_product_id, 'source', product_match_source) ORDER BY id)
              FROM public.invoice_items WHERE organization_id = 'ca7a0000-0000-4000-8000-000000000101')
  )
$$;

CREATE FUNCTION pg_temp.nt_product_for(_listing uuid)
RETURNS public.products
LANGUAGE sql
AS $$
  SELECT product.* FROM public.products product
  JOIN public.catalog_vendor_products listing ON listing.catalog_product_id = product.catalog_product_id
  WHERE product.organization_id = 'ca7a0000-0000-4000-8000-000000000101' AND listing.id = _listing
$$;

CREATE TEMP TABLE nt_out (k text PRIMARY KEY, v jsonb);
GRANT ALL ON nt_out TO authenticated;

INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
VALUES
  ('ca7a0000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'nt-owner@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('ca7a0000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'nt-admin@example.invalid', '', now(), '{}', '{}', now(), now());
INSERT INTO public.organizations (id, name, created_by)
VALUES ('ca7a0000-0000-4000-8000-000000000101', 'Name Twin Athletics', 'ca7a0000-0000-4000-8000-000000000001');
INSERT INTO public.organization_memberships (id, organization_id, user_id, role, active)
VALUES
  ('ca7a0000-0000-4000-8000-000000000111', 'ca7a0000-0000-4000-8000-000000000101', 'ca7a0000-0000-4000-8000-000000000001', 'owner', true),
  ('ca7a0000-0000-4000-8000-000000000112', 'ca7a0000-0000-4000-8000-000000000101', 'ca7a0000-0000-4000-8000-000000000002', 'admin', true);
INSERT INTO public.catalog_vendors (id, name, normalized_name)
VALUES ('ca7a0000-0000-4000-8000-000000000201', 'Name Twin Henry Schein', 'x');

-- 211/212: production PowerFlex pair (import order). 213/214: the same shape matched by hand
-- in the opposite order. 215: twin whose qualified name is already taken. 216: local
-- unlinked twin. 217/218: SKU mapped to a product of another catalog product. 219: brand
-- new. 220: adopted product with a second SKU. 221: twin only as an inactive product.
-- 222: two mappings for one SKU.
INSERT INTO public.catalog_products (id, name, active, verification_status)
VALUES
  ('ca7a0000-0000-4000-8000-000000000211', 'The PowerFlex® Taping System', true, 'verified'),
  ('ca7a0000-0000-4000-8000-000000000212', 'The PowerFlex® Taping System', true, 'verified'),
  ('ca7a0000-0000-4000-8000-000000000213', 'Eco-Flex™ Stretch Cohesive Tape', true, 'verified'),
  ('ca7a0000-0000-4000-8000-000000000214', 'Eco-Flex™ Stretch Cohesive Tape', true, 'verified'),
  ('ca7a0000-0000-4000-8000-000000000215', 'Cover-Roll® Stretch Non-Woven Bandage', true, 'verified'),
  ('ca7a0000-0000-4000-8000-000000000225', 'Cover-Roll® Stretch Non-Woven Bandage', true, 'verified'),
  ('ca7a0000-0000-4000-8000-000000000216', 'Flexi-Wrap Plastic Film', true, 'verified'),
  ('ca7a0000-0000-4000-8000-000000000217', 'Ammex Nitrile Glove', true, 'verified'),
  ('ca7a0000-0000-4000-8000-000000000218', 'Ammex Nitrile Glove Large', true, 'verified'),
  ('ca7a0000-0000-4000-8000-000000000219', 'Brand New Catalog Item', true, 'verified'),
  ('ca7a0000-0000-4000-8000-000000000220', 'Ready Wrap', true, 'verified'),
  ('ca7a0000-0000-4000-8000-000000000221', 'Retired Name Product', true, 'verified'),
  ('ca7a0000-0000-4000-8000-000000000222', 'Duplicate Mapping Product', true, 'verified');
INSERT INTO public.catalog_vendor_products (id, catalog_vendor_id, catalog_product_id, vendor_sku, normalized_vendor_sku, package_status, active, discontinued, verification_status)
VALUES
  ('ca7a0000-0000-4000-8000-000000000231', 'ca7a0000-0000-4000-8000-000000000201', 'ca7a0000-0000-4000-8000-000000000211', '101-2983', 'x', 'unknown', true, false, 'verified'),
  ('ca7a0000-0000-4000-8000-000000000232', 'ca7a0000-0000-4000-8000-000000000201', 'ca7a0000-0000-4000-8000-000000000212', '613-0167', 'x', 'unknown', true, false, 'verified'),
  ('ca7a0000-0000-4000-8000-000000000233', 'ca7a0000-0000-4000-8000-000000000201', 'ca7a0000-0000-4000-8000-000000000213', '134-4998', 'x', 'unknown', true, false, 'verified'),
  ('ca7a0000-0000-4000-8000-000000000234', 'ca7a0000-0000-4000-8000-000000000201', 'ca7a0000-0000-4000-8000-000000000214', '735-0022', 'x', 'unknown', true, false, 'verified'),
  ('ca7a0000-0000-4000-8000-000000000235', 'ca7a0000-0000-4000-8000-000000000201', 'ca7a0000-0000-4000-8000-000000000215', '911-0006', 'x', 'unknown', true, false, 'verified'),
  ('ca7a0000-0000-4000-8000-000000000245', 'ca7a0000-0000-4000-8000-000000000201', 'ca7a0000-0000-4000-8000-000000000225', '911-0007', 'x', 'unknown', true, false, 'verified'),
  ('ca7a0000-0000-4000-8000-000000000236', 'ca7a0000-0000-4000-8000-000000000201', 'ca7a0000-0000-4000-8000-000000000216', '134-0281', 'x', 'unknown', true, false, 'verified'),
  ('ca7a0000-0000-4000-8000-000000000237', 'ca7a0000-0000-4000-8000-000000000201', 'ca7a0000-0000-4000-8000-000000000217', '398-0145', 'x', 'unknown', true, false, 'verified'),
  ('ca7a0000-0000-4000-8000-000000000238', 'ca7a0000-0000-4000-8000-000000000201', 'ca7a0000-0000-4000-8000-000000000218', '398-0144', 'x', 'unknown', true, false, 'verified'),
  ('ca7a0000-0000-4000-8000-000000000239', 'ca7a0000-0000-4000-8000-000000000201', 'ca7a0000-0000-4000-8000-000000000219', '600-0001', 'x', 'unknown', true, false, 'verified'),
  ('ca7a0000-0000-4000-8000-000000000240', 'ca7a0000-0000-4000-8000-000000000201', 'ca7a0000-0000-4000-8000-000000000220', '324-0025', 'x', 'unknown', true, false, 'verified'),
  ('ca7a0000-0000-4000-8000-000000000241', 'ca7a0000-0000-4000-8000-000000000201', 'ca7a0000-0000-4000-8000-000000000220', '324-0026', 'x', 'unknown', true, false, 'verified'),
  ('ca7a0000-0000-4000-8000-000000000242', 'ca7a0000-0000-4000-8000-000000000201', 'ca7a0000-0000-4000-8000-000000000221', '700-0001', 'x', 'unknown', true, false, 'verified'),
  ('ca7a0000-0000-4000-8000-000000000243', 'ca7a0000-0000-4000-8000-000000000201', 'ca7a0000-0000-4000-8000-000000000222', '800-0001', 'x', 'unknown', true, false, 'verified');

INSERT INTO public.vendors (id, organization_id, name, normalized_name, active, catalog_vendor_id)
VALUES ('ca7a0000-0000-4000-8000-000000000301', 'ca7a0000-0000-4000-8000-000000000101', 'Henry Schein', 'henry schein', true, 'ca7a0000-0000-4000-8000-000000000201');

-- 401: a local product that happens to carry a catalog name (may be the same item).
-- 402: an active, unlinked product already holding the qualified Cover-Roll name.
-- 403: inactive product with a catalog name (the active-name constraint ignores it).
-- 404/405: two products for SKU 800-0001, one mapping inactive.
INSERT INTO public.products (id, organization_id, name, normalized_name, approved, active, staff_requestable)
VALUES
  ('ca7a0000-0000-4000-8000-000000000401', 'ca7a0000-0000-4000-8000-000000000101', 'Flexi-Wrap Plastic Film', 'x', true, true, true),
  ('ca7a0000-0000-4000-8000-000000000402', 'ca7a0000-0000-4000-8000-000000000101', 'Cover-Roll® Stretch Non-Woven Bandage (911-0007)', 'x', true, true, true),
  ('ca7a0000-0000-4000-8000-000000000403', 'ca7a0000-0000-4000-8000-000000000101', 'Retired Name Product', 'x', true, false, false),
  ('ca7a0000-0000-4000-8000-000000000404', 'ca7a0000-0000-4000-8000-000000000101', 'Duplicate A', 'x', true, true, true),
  ('ca7a0000-0000-4000-8000-000000000405', 'ca7a0000-0000-4000-8000-000000000101', 'Duplicate B', 'x', true, true, true);
INSERT INTO public.vendor_products (id, organization_id, vendor_id, product_id, vendor_sku, active)
VALUES
  ('ca7a0000-0000-4000-8000-000000000504', 'ca7a0000-0000-4000-8000-000000000101', 'ca7a0000-0000-4000-8000-000000000301', 'ca7a0000-0000-4000-8000-000000000404', '800-0001', true),
  ('ca7a0000-0000-4000-8000-000000000505', 'ca7a0000-0000-4000-8000-000000000101', 'ca7a0000-0000-4000-8000-000000000301', 'ca7a0000-0000-4000-8000-000000000405', '800-0001', false);

INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type)
SELECT ('ca7a0000-0000-4000-8000-0000000006' || lpad(n::text, 2, '0'))::uuid,
  'ca7a0000-0000-4000-8000-000000000101', 'ca7a0000-0000-4000-8000-000000000001',
  'ca7a0000-0000-4000-8000-000000000101/nt-' || n || '.pdf', 'nt-' || n || '.pdf', 1024, 'application/pdf'
FROM generate_series(1, 2) n;
INSERT INTO public.invoices (id, organization_id, source_file_id, vendor_id, vendor_name, invoice_number, processing_status)
VALUES
  ('ca7a0000-0000-4000-8000-000000000701', 'ca7a0000-0000-4000-8000-000000000101', 'ca7a0000-0000-4000-8000-000000000601', 'ca7a0000-0000-4000-8000-000000000301', 'Henry Schein', 'NT-IMPORT', 'review_required'),
  ('ca7a0000-0000-4000-8000-000000000702', 'ca7a0000-0000-4000-8000-000000000101', 'ca7a0000-0000-4000-8000-000000000602', 'ca7a0000-0000-4000-8000-000000000301', 'Henry Schein', 'NT-MANUAL', 'review_required');
INSERT INTO public.invoice_items (id, invoice_id, organization_id, line_number, sku, description, quantity, unit_of_measure, unit_price, total_price)
VALUES
  ('ca7a0000-0000-4000-8000-000000000801', 'ca7a0000-0000-4000-8000-000000000701', 'ca7a0000-0000-4000-8000-000000000101', 1, '101-2983', 'Powerflex Tape Black 2.75"x6Yds', 1, 'CA', 10, 10),
  ('ca7a0000-0000-4000-8000-000000000802', 'ca7a0000-0000-4000-8000-000000000701', 'ca7a0000-0000-4000-8000-000000000101', 2, '613-0167', 'Powerflex Tape Black 2"x6Yds', 1, 'CA', 10, 10),
  ('ca7a0000-0000-4000-8000-000000000811', 'ca7a0000-0000-4000-8000-000000000702', 'ca7a0000-0000-4000-8000-000000000101', 1, '735-0022', 'Eco-Flex Blue', 1, 'RL', 1, 1),
  ('ca7a0000-0000-4000-8000-000000000812', 'ca7a0000-0000-4000-8000-000000000702', 'ca7a0000-0000-4000-8000-000000000101', 2, '134-4998', 'Eco-Flex Orange', 1, 'RL', 1, 1),
  ('ca7a0000-0000-4000-8000-000000000813', 'ca7a0000-0000-4000-8000-000000000702', 'ca7a0000-0000-4000-8000-000000000101', 3, '911-0006', 'Cover-Roll 6"', 1, 'RL', 1, 1),
  ('ca7a0000-0000-4000-8000-000000000814', 'ca7a0000-0000-4000-8000-000000000702', 'ca7a0000-0000-4000-8000-000000000101', 4, '911-0007', 'Cover-Roll 4"', 1, 'RL', 1, 1),
  ('ca7a0000-0000-4000-8000-000000000815', 'ca7a0000-0000-4000-8000-000000000702', 'ca7a0000-0000-4000-8000-000000000101', 5, '134-0281', 'Flexi-Wrap w/Handle', 1, 'CA', 1, 1),
  ('ca7a0000-0000-4000-8000-000000000816', 'ca7a0000-0000-4000-8000-000000000702', 'ca7a0000-0000-4000-8000-000000000101', 6, '398-0145', 'Ammex X-Large', 1, 'BX', 1, 1),
  ('ca7a0000-0000-4000-8000-000000000817', 'ca7a0000-0000-4000-8000-000000000702', 'ca7a0000-0000-4000-8000-000000000101', 7, 'NOT-THE-SKU', 'Ammex printed with another code', 1, 'BX', 1, 1),
  ('ca7a0000-0000-4000-8000-000000000818', 'ca7a0000-0000-4000-8000-000000000702', 'ca7a0000-0000-4000-8000-000000000101', 8, '600-0001', 'Brand new', 1, 'EA', 1, 1),
  ('ca7a0000-0000-4000-8000-000000000819', 'ca7a0000-0000-4000-8000-000000000702', 'ca7a0000-0000-4000-8000-000000000101', 9, '324-0026', 'Ready Wrap second SKU', 1, 'EA', 1, 1),
  ('ca7a0000-0000-4000-8000-000000000820', 'ca7a0000-0000-4000-8000-000000000702', 'ca7a0000-0000-4000-8000-000000000101', 10, '700-0001', 'Retired name', 1, 'EA', 1, 1),
  ('ca7a0000-0000-4000-8000-000000000821', 'ca7a0000-0000-4000-8000-000000000702', 'ca7a0000-0000-4000-8000-000000000101', 11, '800-0001', 'Duplicate mapping', 1, 'EA', 1, 1),
  ('ca7a0000-0000-4000-8000-000000000822', 'ca7a0000-0000-4000-8000-000000000702', 'ca7a0000-0000-4000-8000-000000000101', 12, '398-0144', 'Ammex Large', 1, 'BX', 1, 1);

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'ca7a0000-0000-4000-8000-000000000001', true);

-- Setup by normal adoption: Ready Wrap's first SKU and the Ammex Large glove. Then SKU
-- 398-0145 (X-Large, its own catalog product) is remembered for the Large product, the
-- production workaround this hotfix stops recommending.
INSERT INTO nt_out VALUES ('setup_ready_wrap', pg_temp.nt_try($q$SELECT public.adopt_catalog_vendor_product('ca7a0000-0000-4000-8000-000000000101', 'ca7a0000-0000-4000-8000-000000000240')$q$));
INSERT INTO nt_out VALUES ('setup_ammex_large', pg_temp.nt_try($q$SELECT public.adopt_catalog_vendor_product('ca7a0000-0000-4000-8000-000000000101', 'ca7a0000-0000-4000-8000-000000000238')$q$));
RESET ROLE;
INSERT INTO public.vendor_products (id, organization_id, vendor_id, product_id, vendor_sku, active)
SELECT 'ca7a0000-0000-4000-8000-000000000501', 'ca7a0000-0000-4000-8000-000000000101', 'ca7a0000-0000-4000-8000-000000000301',
  (v->'result'->>'productId')::uuid, '398-0145', true
FROM nt_out WHERE k = 'setup_ammex_large';
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'ca7a0000-0000-4000-8000-000000000001', true);

-- Check 1: import. The resolver adopts both PowerFlex variants as two products; the second
-- takes the catalog name qualified by its SKU. Nothing is left for review.
INSERT INTO nt_out VALUES ('import', public.resolve_invoice_exact_product_identities(
  'ca7a0000-0000-4000-8000-000000000101', 'ca7a0000-0000-4000-8000-000000000601'));
DO $nt_check_1$
DECLARE
  _summary jsonb := (SELECT v FROM nt_out WHERE k = 'import');
  _first public.products := pg_temp.nt_product_for('ca7a0000-0000-4000-8000-000000000231');
  _second public.products := pg_temp.nt_product_for('ca7a0000-0000-4000-8000-000000000232');
BEGIN
  IF (_summary->>'resolvedFromCatalog')::integer <> 2 OR (_summary->>'needsReview')::integer <> 0
     OR _first.name IS DISTINCT FROM 'The PowerFlex® Taping System'
     OR _second.name IS DISTINCT FROM 'The PowerFlex® Taping System (613-0167)'
     OR _first.id = _second.id
     OR NOT _second.active
     OR (SELECT product_id FROM public.invoice_items WHERE id = 'ca7a0000-0000-4000-8000-000000000801') IS DISTINCT FROM _first.id
     OR (SELECT product_id FROM public.invoice_items WHERE id = 'ca7a0000-0000-4000-8000-000000000802') IS DISTINCT FROM _second.id
     OR (SELECT product_match_source FROM public.invoice_items WHERE id = 'ca7a0000-0000-4000-8000-000000000802') IS DISTINCT FROM 'catalog_vendor_sku'
     OR NOT EXISTS (SELECT 1 FROM public.vendor_products WHERE product_id = _second.id AND vendor_sku = '613-0167'
                    AND catalog_vendor_product_id = 'ca7a0000-0000-4000-8000-000000000232' AND active) THEN
    RAISE EXCEPTION 'Check 1 failed: import did not adopt both PowerFlex variants: % / % / %', _summary, to_jsonb(_first), to_jsonb(_second);
  END IF;
END
$nt_check_1$;

-- Check 2: by hand, in the opposite order. The first Eco-Flex choice keeps the catalog
-- name; the second is qualified by its own SKU. Each SKU stays on its own product.
INSERT INTO nt_out VALUES ('eco_first', pg_temp.nt_match('ca7a0000-0000-4000-8000-000000000602', 'ca7a0000-0000-4000-8000-000000000811', 'ca7a0000-0000-4000-8000-000000000234'));
INSERT INTO nt_out VALUES ('eco_second', pg_temp.nt_match('ca7a0000-0000-4000-8000-000000000602', 'ca7a0000-0000-4000-8000-000000000812', 'ca7a0000-0000-4000-8000-000000000233'));
DO $nt_check_2$
DECLARE
  _first jsonb := (SELECT v FROM nt_out WHERE k = 'eco_first');
  _second jsonb := (SELECT v FROM nt_out WHERE k = 'eco_second');
BEGIN
  IF NOT (_first->>'ok')::boolean OR NOT (_second->>'ok')::boolean
     OR NOT (_second->'result'->>'productCreated')::boolean
     OR (pg_temp.nt_product_for('ca7a0000-0000-4000-8000-000000000234')).name IS DISTINCT FROM 'Eco-Flex™ Stretch Cohesive Tape'
     OR (pg_temp.nt_product_for('ca7a0000-0000-4000-8000-000000000233')).name IS DISTINCT FROM 'Eco-Flex™ Stretch Cohesive Tape (134-4998)'
     OR (SELECT count(DISTINCT product_id) FROM public.vendor_products
         WHERE organization_id = 'ca7a0000-0000-4000-8000-000000000101' AND vendor_sku IN ('735-0022', '134-4998')) <> 2
     OR (SELECT product_match_source FROM public.invoice_items WHERE id = 'ca7a0000-0000-4000-8000-000000000812') IS DISTINCT FROM 'manual' THEN
    RAISE EXCEPTION 'Check 2 failed: manual opposite-order adoption: % / %', _first, _second;
  END IF;
END
$nt_check_2$;

-- Check 3: a twin whose qualified name is already an active product is refused, names that
-- product, and writes nothing. (911-0006 is adopted first so 911-0007's twin is linked.)
INSERT INTO nt_out VALUES ('cover_first', pg_temp.nt_match('ca7a0000-0000-4000-8000-000000000602', 'ca7a0000-0000-4000-8000-000000000813', 'ca7a0000-0000-4000-8000-000000000235'));
INSERT INTO nt_out VALUES ('identity_before_refusals', pg_temp.nt_identity());
INSERT INTO nt_out VALUES ('cover_taken', pg_temp.nt_match('ca7a0000-0000-4000-8000-000000000602', 'ca7a0000-0000-4000-8000-000000000814', 'ca7a0000-0000-4000-8000-000000000245'));
DO $nt_check_3$
DECLARE _refusal jsonb := (SELECT v FROM nt_out WHERE k = 'cover_taken');
BEGIN
  IF NOT ((SELECT v FROM nt_out WHERE k = 'cover_first')->>'ok')::boolean
     OR (_refusal->>'ok')::boolean
     OR _refusal->>'sqlstate' <> 'P0001'
     OR _refusal->'hint'->>'conflictType' IS DISTINCT FROM 'name_twin_taken'
     OR _refusal->'hint'->>'productId' IS DISTINCT FROM 'ca7a0000-0000-4000-8000-000000000402'
     OR _refusal->'hint'->>'productName' IS DISTINCT FROM 'Cover-Roll® Stretch Non-Woven Bandage (911-0007)'
     OR (_refusal->'hint'->>'canMatchExisting')::boolean
     OR position('conflicts with a product or vendor SKU mapping your organization already has' IN _refusal->>'message') <> 1 + length('This catalog item ')
     OR position('Your products already has "Cover-Roll® Stretch Non-Woven Bandage (911-0007)".' IN _refusal->>'message') = 0 THEN
    RAISE EXCEPTION 'Check 3 failed: taken qualified name: %', _refusal;
  END IF;
END
$nt_check_3$;

-- Check 4: an unlinked local product with the catalog name may be the same item, so it is
-- still refused. The message names it; no "match to" is offered for a name alone.
INSERT INTO nt_out VALUES ('local_twin', pg_temp.nt_match('ca7a0000-0000-4000-8000-000000000602', 'ca7a0000-0000-4000-8000-000000000815', 'ca7a0000-0000-4000-8000-000000000236'));
DO $nt_check_4$
DECLARE _refusal jsonb := (SELECT v FROM nt_out WHERE k = 'local_twin');
BEGIN
  IF (_refusal->>'ok')::boolean
     OR _refusal->'hint'->>'conflictType' IS DISTINCT FROM 'name_twin_local'
     OR _refusal->'hint'->>'productId' IS DISTINCT FROM 'ca7a0000-0000-4000-8000-000000000401'
     OR (_refusal->'hint'->>'canMatchExisting')::boolean
     OR position('Your products already has "Flexi-Wrap Plastic Film", which is not linked to the catalog.' IN _refusal->>'message') = 0
     OR position('An active organization product already uses normalized name flexi wrap plastic film' IN _refusal->>'detail') = 0 THEN
    RAISE EXCEPTION 'Check 4 failed: local twin: %', _refusal;
  END IF;
END
$nt_check_4$;

-- Check 5: the line's SKU already maps to a product of a different catalog product. That
-- contradiction stays refused, now naming the product, and matching to it is offered
-- because vendor + SKU already resolves there.
INSERT INTO nt_out VALUES ('sku_mapped', pg_temp.nt_match('ca7a0000-0000-4000-8000-000000000602', 'ca7a0000-0000-4000-8000-000000000816', 'ca7a0000-0000-4000-8000-000000000237'));
DO $nt_check_5$
DECLARE
  _refusal jsonb := (SELECT v FROM nt_out WHERE k = 'sku_mapped');
  _large uuid := ((SELECT v FROM nt_out WHERE k = 'setup_ammex_large')->'result'->>'productId')::uuid;
BEGIN
  IF (_refusal->>'ok')::boolean
     OR _refusal->'hint'->>'conflictType' IS DISTINCT FROM 'sku_mapped_to_other_product'
     OR (_refusal->'hint'->>'productId')::uuid IS DISTINCT FROM _large
     OR _refusal->'hint'->>'productName' IS DISTINCT FROM 'Ammex Nitrile Glove Large'
     OR _refusal->'hint'->>'vendorProductId' IS DISTINCT FROM 'ca7a0000-0000-4000-8000-000000000501'
     OR _refusal->'hint'->>'vendorSku' IS DISTINCT FROM '398-0145'
     OR NOT (_refusal->'hint'->>'canMatchExisting')::boolean
     OR position('Vendor SKU 398-0145 is already mapped to "Ammex Nitrile Glove Large", which is a different catalog item. Match this line to "Ammex Nitrile Glove Large"' IN _refusal->>'message') = 0 THEN
    RAISE EXCEPTION 'Check 5 failed: SKU mapped to another catalog product: %', _refusal;
  END IF;
END
$nt_check_5$;

-- Check 6: the same listing chosen for a line printed with another SKU, or after the
-- mapping is retired, is still refused but no longer offers the existing product.
INSERT INTO nt_out VALUES ('sku_mapped_other_line', pg_temp.nt_match('ca7a0000-0000-4000-8000-000000000602', 'ca7a0000-0000-4000-8000-000000000817', 'ca7a0000-0000-4000-8000-000000000237'));
RESET ROLE;
UPDATE public.vendor_products SET active = false WHERE id = 'ca7a0000-0000-4000-8000-000000000501';
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'ca7a0000-0000-4000-8000-000000000001', true);
INSERT INTO nt_out VALUES ('sku_mapped_inactive', pg_temp.nt_match('ca7a0000-0000-4000-8000-000000000602', 'ca7a0000-0000-4000-8000-000000000816', 'ca7a0000-0000-4000-8000-000000000237'));
RESET ROLE;
UPDATE public.vendor_products SET active = true WHERE id = 'ca7a0000-0000-4000-8000-000000000501';
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'ca7a0000-0000-4000-8000-000000000001', true);
DO $nt_check_6$
DECLARE
  _other jsonb := (SELECT v FROM nt_out WHERE k = 'sku_mapped_other_line');
  _inactive jsonb := (SELECT v FROM nt_out WHERE k = 'sku_mapped_inactive');
BEGIN
  IF (_other->>'ok')::boolean OR (_inactive->>'ok')::boolean
     OR _other->'hint'->>'conflictType' IS DISTINCT FROM 'sku_mapped_to_other_product'
     OR _inactive->'hint'->>'conflictType' IS DISTINCT FROM 'sku_mapped_to_other_product'
     OR (_other->'hint'->>'canMatchExisting')::boolean
     OR (_inactive->'hint'->>'canMatchExisting')::boolean
     OR position('Correct that mapping in Catalog first.' IN _other->>'message') = 0
     OR position('Match this line to' IN _inactive->>'message') <> 0 THEN
    RAISE EXCEPTION 'Check 6 failed: reuse offered without a live SKU resolution: % / %', _other, _inactive;
  END IF;
END
$nt_check_6$;

-- Check 7: one SKU held by two products (one mapping retired) is refused by name.
INSERT INTO nt_out VALUES ('duplicate', pg_temp.nt_match('ca7a0000-0000-4000-8000-000000000602', 'ca7a0000-0000-4000-8000-000000000821', 'ca7a0000-0000-4000-8000-000000000243'));
DO $nt_check_7$
DECLARE _refusal jsonb := (SELECT v FROM nt_out WHERE k = 'duplicate');
BEGIN
  IF (_refusal->>'ok')::boolean
     OR _refusal->'hint'->>'conflictType' IS DISTINCT FROM 'multiple_sku_mappings'
     OR _refusal->'hint'->>'productId' IS NOT NULL
     OR position('Vendor SKU 800-0001 is mapped to more than one of your products.' IN _refusal->>'message') = 0 THEN
    RAISE EXCEPTION 'Check 7 failed: duplicate mappings: %', _refusal;
  END IF;
END
$nt_check_7$;

-- Check 8: refusals wrote nothing (Checks 3-7 ran after the snapshot; Check 6's
-- deactivate/reactivate restored its row, which is compared without updated_at).
DO $nt_check_8$
BEGIN
  IF pg_temp.nt_identity() IS DISTINCT FROM (SELECT v FROM nt_out WHERE k = 'identity_before_refusals') THEN
    RAISE EXCEPTION 'Check 8 failed: a refusal left writes behind';
  END IF;
END
$nt_check_8$;

-- Check 9: unchanged paths. A brand-new item keeps the plain catalog name; a second SKU of
-- an adopted catalog product joins that product; an inactive product with the catalog
-- name does not force a qualified name.
INSERT INTO nt_out VALUES ('brand_new', pg_temp.nt_match('ca7a0000-0000-4000-8000-000000000602', 'ca7a0000-0000-4000-8000-000000000818', 'ca7a0000-0000-4000-8000-000000000239'));
INSERT INTO nt_out VALUES ('second_sku', pg_temp.nt_match('ca7a0000-0000-4000-8000-000000000602', 'ca7a0000-0000-4000-8000-000000000819', 'ca7a0000-0000-4000-8000-000000000241'));
INSERT INTO nt_out VALUES ('inactive_twin', pg_temp.nt_match('ca7a0000-0000-4000-8000-000000000602', 'ca7a0000-0000-4000-8000-000000000820', 'ca7a0000-0000-4000-8000-000000000242'));
DO $nt_check_9$
DECLARE
  _new jsonb := (SELECT v FROM nt_out WHERE k = 'brand_new');
  _second jsonb := (SELECT v FROM nt_out WHERE k = 'second_sku');
  _inactive jsonb := (SELECT v FROM nt_out WHERE k = 'inactive_twin');
BEGIN
  IF NOT (_new->>'ok')::boolean OR NOT (_second->>'ok')::boolean OR NOT (_inactive->>'ok')::boolean
     OR (pg_temp.nt_product_for('ca7a0000-0000-4000-8000-000000000239')).name IS DISTINCT FROM 'Brand New Catalog Item'
     OR (_second->'result'->>'productCreated')::boolean
     OR (_second->'result'->>'productId')::uuid IS DISTINCT FROM ((SELECT v FROM nt_out WHERE k = 'setup_ready_wrap')->'result'->>'productId')::uuid
     OR (pg_temp.nt_product_for('ca7a0000-0000-4000-8000-000000000242')).name IS DISTINCT FROM 'Retired Name Product'
     OR (pg_temp.nt_product_for('ca7a0000-0000-4000-8000-000000000242')).id = 'ca7a0000-0000-4000-8000-000000000403' THEN
    RAISE EXCEPTION 'Check 9 failed: unchanged adoption paths: % / % / %', _new, _second, _inactive;
  END IF;
END
$nt_check_9$;

-- Check 10: Catalog (owner/admin) adoption follows the same rule, and adoption refusals
-- carry the JSON hint directly.
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'ca7a0000-0000-4000-8000-000000000002', true);
INSERT INTO nt_out VALUES ('admin_local_twin', pg_temp.nt_try($q$SELECT public.adopt_catalog_vendor_product('ca7a0000-0000-4000-8000-000000000101', 'ca7a0000-0000-4000-8000-000000000236')$q$));
DO $nt_check_10$
DECLARE _refusal jsonb := (SELECT v FROM nt_out WHERE k = 'admin_local_twin');
BEGIN
  IF (_refusal->>'ok')::boolean OR _refusal->>'sqlstate' <> '23505'
     OR _refusal->'hint'->>'conflictType' IS DISTINCT FROM 'name_twin_local'
     OR _refusal->'hint'->>'productId' IS DISTINCT FROM 'ca7a0000-0000-4000-8000-000000000401' THEN
    RAISE EXCEPTION 'Check 10 failed: direct adoption refusal: %', _refusal;
  END IF;
END
$nt_check_10$;

RESET ROLE;
ROLLBACK;
