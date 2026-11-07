-- Phase 5A.10 behavior suite: deterministic search relevance, Saved Items, organization
-- history signals and discovery sections. Rollback-only; run on a disposable database with
-- every migration applied:
--   psql -v ON_ERROR_STOP=1 -f supabase/tests/phase5a10_staff_product_discovery_behavior.sql
--
-- Users: 01 owner A, 02 admin A, 03 staff A, 04 staff A and staff B, 05 owner B,
--        07 former staff A (inactive membership), 09 signed in but a member of nothing.

BEGIN;

INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('5a10b000-0000-4000-8000-0000000000' || lpad(n::text, 2, '0'))::uuid, 'authenticated', 'authenticated',
  'phase5a10-behavior-' || n || '@example.invalid', '', now(), '{}', '{}', now(), now()
FROM unnest(ARRAY[1, 2, 3, 4, 5, 7, 9]) n;

INSERT INTO public.organizations (id, name, created_by) VALUES
  ('5a10b000-0000-4000-8000-000000000101', 'Phase 5A.10 A', '5a10b000-0000-4000-8000-000000000001'),
  ('5a10b000-0000-4000-8000-000000000102', 'Phase 5A.10 B', '5a10b000-0000-4000-8000-000000000005');
INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES
  ('5a10b000-0000-4000-8000-000000000101', '5a10b000-0000-4000-8000-000000000001', 'owner', true),
  ('5a10b000-0000-4000-8000-000000000101', '5a10b000-0000-4000-8000-000000000002', 'admin', true),
  ('5a10b000-0000-4000-8000-000000000101', '5a10b000-0000-4000-8000-000000000003', 'staff', true),
  ('5a10b000-0000-4000-8000-000000000101', '5a10b000-0000-4000-8000-000000000004', 'staff', true),
  ('5a10b000-0000-4000-8000-000000000102', '5a10b000-0000-4000-8000-000000000004', 'staff', true),
  ('5a10b000-0000-4000-8000-000000000102', '5a10b000-0000-4000-8000-000000000005', 'owner', true),
  ('5a10b000-0000-4000-8000-000000000101', '5a10b000-0000-4000-8000-000000000007', 'staff', false);

-- Global catalog.
INSERT INTO public.catalog_vendors (id, name, normalized_name, active)
VALUES ('5a10b000-0000-4000-8000-000000000201', 'Fixture Medical', 'fixture medical', true);

INSERT INTO public.catalog_products (id, name, normalized_name, description, manufacturer, active, verification_status)
VALUES
  ('5a10b000-0000-4000-8000-000000000301', 'Athletic Tape', 'x', '2" x 15 yd', 'Fixture Mfg', true, 'verified'),
  ('5a10b000-0000-4000-8000-000000000302', 'Athletic Tape', 'x', '3" x 15 yd', 'Fixture Mfg', true, 'verified'),
  ('5a10b000-0000-4000-8000-000000000303', 'Athletic Tape', 'x', '1/2" x 10 yd', 'Fixture Mfg', true, 'verified'),
  ('5a10b000-0000-4000-8000-000000000304', 'Coach Tape', 'x', '12" x 10 yd', 'Fixture Mfg', true, 'verified'),
  ('5a10b000-0000-4000-8000-000000000305', 'Prewrap Foam', 'x', 'Beige', 'Fixture Mfg', true, 'verified'),
  ('5a10b000-0000-4000-8000-000000000306', 'Nitrile Exam Gloves', 'x', 'Medium', 'Fixture Mfg', true, 'verified'),
  ('5a10b000-0000-4000-8000-000000000307', 'Nitrile Exam Gloves', 'x', 'Large', 'Fixture Mfg', true, 'verified'),
  ('5a10b000-0000-4000-8000-000000000309', 'Tape Athletic Bulk Pack', 'x', NULL, 'Fixture Mfg', true, 'verified'),
  ('5a10b000-0000-4000-8000-000000000310', 'Axle Pad', 'x', NULL, 'Fixture Mfg', true, 'verified'),
  ('5a10b000-0000-4000-8000-000000000311', 'AT 3000 Tape Remover', 'x', NULL, 'Fixture Mfg', true, 'verified'),
  ('5a10b000-0000-4000-8000-000000000312', 'Hidden Inactive Tape', 'x', NULL, 'Fixture Mfg', true, 'verified');

INSERT INTO public.catalog_vendor_products (id, catalog_product_id, catalog_vendor_id, vendor_sku,
  normalized_vendor_sku, manufacturer_sku, package_quantity, package_unit, package_status, active,
  discontinued, verification_status)
VALUES
  ('5a10b000-0000-4000-8000-000000000401', '5a10b000-0000-4000-8000-000000000301', '5a10b000-0000-4000-8000-000000000201', 'AT-2000', 'x', NULL, 24, 'roll', 'verified', true, false, 'verified'),
  ('5a10b000-0000-4000-8000-000000000402', '5a10b000-0000-4000-8000-000000000302', '5a10b000-0000-4000-8000-000000000201', 'AT-3000', 'x', NULL, 16, 'roll', 'verified', true, false, 'verified'),
  ('5a10b000-0000-4000-8000-000000000403', '5a10b000-0000-4000-8000-000000000303', '5a10b000-0000-4000-8000-000000000201', 'AT-0500', 'x', NULL, 48, 'roll', 'verified', true, false, 'verified'),
  ('5a10b000-0000-4000-8000-000000000404', '5a10b000-0000-4000-8000-000000000304', '5a10b000-0000-4000-8000-000000000201', 'CT-1200', 'x', NULL, NULL, NULL, 'unknown', true, false, 'verified'),
  ('5a10b000-0000-4000-8000-000000000405', '5a10b000-0000-4000-8000-000000000305', '5a10b000-0000-4000-8000-000000000201', 'PW-100', 'x', '0123456789012', NULL, NULL, 'unknown', true, false, 'verified'),
  ('5a10b000-0000-4000-8000-000000000406', '5a10b000-0000-4000-8000-000000000306', '5a10b000-0000-4000-8000-000000000201', 'NG-M', 'x', NULL, 100, 'glove', 'verified', true, false, 'verified'),
  ('5a10b000-0000-4000-8000-000000000407', '5a10b000-0000-4000-8000-000000000307', '5a10b000-0000-4000-8000-000000000201', 'NG-L', 'x', NULL, 100, 'glove', 'verified', true, false, 'verified'),
  ('5a10b000-0000-4000-8000-000000000409', '5a10b000-0000-4000-8000-000000000309', '5a10b000-0000-4000-8000-000000000201', 'BULK-9', 'x', NULL, NULL, NULL, 'unknown', true, false, 'verified'),
  ('5a10b000-0000-4000-8000-000000000410', '5a10b000-0000-4000-8000-000000000310', '5a10b000-0000-4000-8000-000000000201', 'AX-1', 'x', NULL, NULL, NULL, 'unknown', true, false, 'verified'),
  ('5a10b000-0000-4000-8000-000000000411', '5a10b000-0000-4000-8000-000000000311', '5a10b000-0000-4000-8000-000000000201', 'REM-11', 'x', NULL, NULL, NULL, 'unknown', true, false, 'verified'),
  ('5a10b000-0000-4000-8000-000000000412', '5a10b000-0000-4000-8000-000000000312', '5a10b000-0000-4000-8000-000000000201', 'AT-9999', 'x', NULL, NULL, NULL, 'unknown', false, false, 'verified');

-- Organization A local products, aliases and unlinked inventory; organization B's product.
INSERT INTO public.products (id, organization_id, name, description, internal_item_code, active, staff_requestable) VALUES
  ('5a10b000-0000-4000-8000-000000000501', '5a10b000-0000-4000-8000-000000000101', 'Ice Bag Small', 'Small', NULL, true, true),
  ('5a10b000-0000-4000-8000-000000000502', '5a10b000-0000-4000-8000-000000000101', 'Ice Bag Large', 'Large', NULL, true, true),
  ('5a10b000-0000-4000-8000-000000000503', '5a10b000-0000-4000-8000-000000000101', 'Foam Roll Pad', NULL, NULL, true, true),
  ('5a10b000-0000-4000-8000-000000000504', '5a10b000-0000-4000-8000-000000000101', 'Kinesiology Tape Roll', NULL, 'LOC-77', true, true),
  ('5a10b000-0000-4000-8000-000000000505', '5a10b000-0000-4000-8000-000000000101', 'Admin Only Splint', NULL, NULL, true, false),
  ('5a10b000-0000-4000-8000-000000000511', '5a10b000-0000-4000-8000-000000000102', 'Ice Bag Small', 'Organization B', NULL, true, true);
INSERT INTO public.product_aliases (organization_id, product_id, alias, normalized_alias) VALUES
  ('5a10b000-0000-4000-8000-000000000101', '5a10b000-0000-4000-8000-000000000503', 'underwrap', 'underwrap'),
  ('5a10b000-0000-4000-8000-000000000101', '5a10b000-0000-4000-8000-000000000504', 'kt tape', 'kt tape');
INSERT INTO public.inventory_items (id, organization_id, sku, name, unit, quantity, active) VALUES
  ('5a10b000-0000-4000-8000-000000000601', '5a10b000-0000-4000-8000-000000000101', 'ICE-1', 'Cold Pack', 'each', 3, true),
  ('5a10b000-0000-4000-8000-000000000611', '5a10b000-0000-4000-8000-000000000102', 'ICE-1', 'Cold Pack', 'each', 3, true);

-- Request history. A: cvp 409 and 411 approved 4 times (popular), cvp 402 approved twice,
-- Ice Bag Small approved twice, cvp 401 only denied / cancelled / submitted / under review.
-- B: cvp 401 approved five times (must never reach A).
INSERT INTO public.supply_requests (id, organization_id, requested_by, request_type, status, created_at)
SELECT ('5a10b000-0000-4000-8000-0000000007' || lpad(n::text, 2, '0'))::uuid,
  CASE WHEN n BETWEEN 40 AND 44 THEN '5a10b000-0000-4000-8000-000000000102' ELSE '5a10b000-0000-4000-8000-000000000101' END::uuid,
  CASE WHEN n BETWEEN 40 AND 44 THEN '5a10b000-0000-4000-8000-000000000005' ELSE '5a10b000-0000-4000-8000-000000000004' END::uuid,
  'reorder',
  (CASE
     WHEN n IN (1, 11) THEN 'approved' WHEN n IN (2, 12) THEN 'ordered'
     WHEN n = 3 THEN 'received' WHEN n = 4 THEN 'completed'
     WHEN n IN (21, 22, 23) THEN 'denied' WHEN n = 24 THEN 'cancelled'
     WHEN n = 25 THEN 'submitted' WHEN n = 26 THEN 'under_review'
     WHEN n IN (31, 32) THEN 'completed'
     ELSE 'approved'
   END)::public.supply_request_status,
  now() - (n || ' days')::interval
FROM unnest(ARRAY[1, 2, 3, 4, 11, 12, 21, 22, 23, 24, 25, 26, 31, 32, 40, 41, 42, 43, 44]) n;

INSERT INTO public.supply_request_items (organization_id, supply_request_id, catalog_vendor_product_id, product_id, inventory_item_id, quantity)
SELECT request.organization_id, request.id, line.catalog_vendor_product_id, line.product_id, NULL, 1
FROM public.supply_requests request
JOIN LATERAL (
  SELECT '5a10b000-0000-4000-8000-000000000409'::uuid AS catalog_vendor_product_id, NULL::uuid AS product_id
  WHERE request.id::text ~ '0000000007(01|02|03|04)$'
  UNION ALL SELECT '5a10b000-0000-4000-8000-000000000411', NULL WHERE request.id::text ~ '0000000007(01|02|03|04)$'
  UNION ALL SELECT '5a10b000-0000-4000-8000-000000000402', NULL WHERE request.id::text ~ '0000000007(11|12)$'
  UNION ALL SELECT '5a10b000-0000-4000-8000-000000000401', NULL WHERE request.id::text ~ '0000000007(21|22|23|24|25|26|40|41|42|43|44)$'
  UNION ALL SELECT NULL, '5a10b000-0000-4000-8000-000000000501' WHERE request.id::text ~ '0000000007(31|32)$'
) line ON true
WHERE request.id::text LIKE '5a10b000-0000-4000-8000-0000000007%';

-- Invoices. A: posted invoice with Ice Bag Large; an unposted invoice and a posted credit memo
-- with Ice Bag Small (neither counts). B: posted invoice with its own Ice Bag Small, plus one
-- legacy-style line (predating the composite product FK) that names A's Ice Bag Small: an
-- organization filter must keep it out of A.
INSERT INTO public.invoices (id, organization_id, invoice_number, invoice_date, posted_at, processing_status, document_type) VALUES
  ('5a10b000-0000-4000-8000-000000000801', '5a10b000-0000-4000-8000-000000000101', 'A-1', current_date - 10, now() - interval '9 days', 'completed', 'INVOICE'),
  ('5a10b000-0000-4000-8000-000000000802', '5a10b000-0000-4000-8000-000000000101', 'A-2', current_date - 5, NULL, 'review_required', 'INVOICE'),
  ('5a10b000-0000-4000-8000-000000000803', '5a10b000-0000-4000-8000-000000000101', 'A-3', current_date - 4, now() - interval '3 days', 'completed', 'CREDIT_MEMO'),
  ('5a10b000-0000-4000-8000-000000000811', '5a10b000-0000-4000-8000-000000000102', 'B-1', current_date - 2, now() - interval '1 day', 'completed', 'INVOICE');
INSERT INTO public.invoice_items (invoice_id, organization_id, description, quantity, product_id) VALUES
  ('5a10b000-0000-4000-8000-000000000801', '5a10b000-0000-4000-8000-000000000101', 'Ice bag large', 2, '5a10b000-0000-4000-8000-000000000502'),
  ('5a10b000-0000-4000-8000-000000000802', '5a10b000-0000-4000-8000-000000000101', 'Ice bag small', 2, '5a10b000-0000-4000-8000-000000000501'),
  ('5a10b000-0000-4000-8000-000000000803', '5a10b000-0000-4000-8000-000000000101', 'Ice bag small credit', 1, '5a10b000-0000-4000-8000-000000000501'),
  ('5a10b000-0000-4000-8000-000000000811', '5a10b000-0000-4000-8000-000000000102', 'Ice bag small B', 1, '5a10b000-0000-4000-8000-000000000511');
ALTER TABLE public.invoice_items DROP CONSTRAINT invoice_items_product_org_fk;
INSERT INTO public.invoice_items (invoice_id, organization_id, description, quantity, product_id) VALUES
  ('5a10b000-0000-4000-8000-000000000811', '5a10b000-0000-4000-8000-000000000102', 'Legacy line', 1, '5a10b000-0000-4000-8000-000000000501');

-- Organization B Saved Item for user 04 (a member of both organizations).
INSERT INTO public.staff_saved_products (organization_id, user_id, catalog_vendor_product_id)
VALUES ('5a10b000-0000-4000-8000-000000000102', '5a10b000-0000-4000-8000-000000000004', '5a10b000-0000-4000-8000-000000000401');

-- Derived search documents follow catalog writes (statement triggers).
DO $documents$
BEGIN
  IF (SELECT count(*) FROM public.catalog_vendor_product_search_documents
      WHERE catalog_vendor_product_id::text LIKE '5a10b000-%') <> 11 THEN
    RAISE EXCEPTION 'Search documents were not built for every new catalog vendor product';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.catalog_search_terms WHERE term = 'athletic') THEN
    RAISE EXCEPTION 'Vocabulary was not built';
  END IF;
  IF (SELECT document FROM public.catalog_vendor_product_search_documents
      WHERE catalog_vendor_product_id = '5a10b000-0000-4000-8000-000000000403') !~ ' 1/2inch ' THEN
    RAISE EXCEPTION 'Fractions were not kept whole in the search document';
  END IF;
END
$documents$;

SET LOCAL ROLE authenticated;

-- ---------------------------------------------------------------------------------------
-- Search relevance (staff 03 in A).
-- ---------------------------------------------------------------------------------------
SELECT set_config('request.jwt.claim.sub', '5a10b000-0000-4000-8000-000000000003', true);

DO $search$
DECLARE
  _org constant uuid := '5a10b000-0000-4000-8000-000000000101';
  _row record;
  _ids uuid[];
  _keys text[];
BEGIN
  -- Exact catalog SKU: tier 1 and first, ahead of a popular product named "AT 3000 ...".
  SELECT * INTO _row FROM public.search_supply_request_products_with_signals(_org, 'AT-3000', 20) LIMIT 1;
  IF _row.catalog_vendor_product_id IS DISTINCT FROM '5a10b000-0000-4000-8000-000000000402' OR _row.match_tier <> 1 THEN
    RAISE EXCEPTION 'Exact SKU did not win: % tier %', _row.product_name, _row.match_tier;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals(_org, 'AT-3000', 20)
                 WHERE catalog_vendor_product_id = '5a10b000-0000-4000-8000-000000000411' AND approved_request_count = 4) THEN
    RAISE EXCEPTION 'Popular name match missing from exact-SKU fixture';
  END IF;
  -- Separator-insensitive exact SKU.
  SELECT * INTO _row FROM public.search_supply_request_products_with_signals(_org, 'at3000', 20) LIMIT 1;
  IF _row.catalog_vendor_product_id IS DISTINCT FROM '5a10b000-0000-4000-8000-000000000402' OR _row.match_tier <> 1 THEN
    RAISE EXCEPTION 'Separator-insensitive SKU failed: %', _row.product_name;
  END IF;
  -- Exact manufacturer SKU (the closest stored field to a UPC; the catalog has no UPC column).
  SELECT * INTO _row FROM public.search_supply_request_products_with_signals(_org, '0123456789012', 20) LIMIT 1;
  IF _row.catalog_vendor_product_id IS DISTINCT FROM '5a10b000-0000-4000-8000-000000000405' OR _row.match_tier <> 1 THEN
    RAISE EXCEPTION 'Exact manufacturer SKU failed';
  END IF;
  -- Exact organization SKU (internal item code) is tier 0.
  SELECT * INTO _row FROM public.search_supply_request_products_with_signals(_org, 'loc-77', 20) LIMIT 1;
  IF _row.product_id IS DISTINCT FROM '5a10b000-0000-4000-8000-000000000504' OR _row.match_tier <> 0 THEN
    RAISE EXCEPTION 'Exact organization SKU failed';
  END IF;
  -- Partial SKU (4+ characters with a digit).
  IF NOT EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals(_org, '3000', 20)
                 WHERE catalog_vendor_product_id = '5a10b000-0000-4000-8000-000000000402' AND match_tier = 3) THEN
    RAISE EXCEPTION 'Partial SKU failed';
  END IF;

  -- Exact product name, then phrase; the popular "Tape Athletic Bulk Pack" (tier 5) stays
  -- below all three Athletic Tape variants (tier 2) despite four approvals.
  SELECT array_agg(catalog_vendor_product_id ORDER BY ordinality), array_agg(match_tier::text ORDER BY ordinality)
  INTO _ids, _keys
  FROM public.search_supply_request_products_with_signals(_org, 'athletic tape', 20) WITH ORDINALITY;
  IF _ids[1:3] IS DISTINCT FROM ARRAY['5a10b000-0000-4000-8000-000000000402', '5a10b000-0000-4000-8000-000000000403',
                                     '5a10b000-0000-4000-8000-000000000401']::uuid[]
     OR _keys[1:3] IS DISTINCT FROM ARRAY['2', '2', '2']
     OR _ids[4] IS DISTINCT FROM '5a10b000-0000-4000-8000-000000000409'::uuid OR _keys[4] <> '5' THEN
    RAISE EXCEPTION 'Exact name / approved boost / relevance order wrong: % %', _ids, _keys;
  END IF;

  -- Prefix (word start) and multi-token, any order.
  IF NOT EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals(_org, 'nitr glo', 20)
                 WHERE catalog_vendor_product_id = '5a10b000-0000-4000-8000-000000000406' AND match_tier = 5) THEN
    RAISE EXCEPTION 'Prefix multi-token match failed';
  END IF;
  -- Attribute match: the size lives in the description, the vendor name is an attribute.
  SELECT array_agg(catalog_vendor_product_id) INTO _ids
  FROM public.search_supply_request_products_with_signals(_org, 'gloves large', 20);
  IF _ids IS DISTINCT FROM ARRAY['5a10b000-0000-4000-8000-000000000407']::uuid[] THEN
    RAISE EXCEPTION 'Attribute match failed: %', _ids;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals(_org, 'fixture medical gloves', 20)
                 WHERE match_tier = 6) THEN
    RAISE EXCEPTION 'Vendor attribute match failed';
  END IF;
  -- Organization alias (synonym) is a name-level match.
  SELECT * INTO _row FROM public.search_supply_request_products_with_signals(_org, 'underwrap', 20) LIMIT 1;
  IF _row.product_id IS DISTINCT FROM '5a10b000-0000-4000-8000-000000000503' OR _row.match_tier <> 2 THEN
    RAISE EXCEPTION 'Exact alias failed';
  END IF;
  SELECT * INTO _row FROM public.search_supply_request_products_with_signals(_org, 'kt tape', 20) LIMIT 1;
  IF _row.product_id IS DISTINCT FROM '5a10b000-0000-4000-8000-000000000504' OR _row.match_tier <> 2 THEN
    RAISE EXCEPTION 'Multi-word alias failed';
  END IF;

  -- Typo tolerance: swap, missing letter; first letter must match; never for short words.
  IF (SELECT count(*) FILTER (WHERE product_name = 'Athletic Tape') FROM public.search_supply_request_products_with_signals(_org, 'atheltic', 20)) <> 3
     OR EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals(_org, 'atheltic', 20) WHERE match_tier <> 7) THEN
    RAISE EXCEPTION 'Adjacent-swap typo failed';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals(_org, 'prewarp', 20)
                 WHERE catalog_vendor_product_id = '5a10b000-0000-4000-8000-000000000405' AND match_tier = 7) THEN
    RAISE EXCEPTION 'Typo prewarp failed';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals(_org, 'nitril gloves', 20)
                 WHERE match_tier = 5) THEN
    RAISE EXCEPTION 'A word that is a prefix must match strictly, not as a typo';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals(_org, 'nitrle gloves', 20)
                 WHERE match_tier = 7) THEN
    RAISE EXCEPTION 'Missing-letter typo failed';
  END IF;
  IF EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals(_org, 'nitxle gloves', 20)) THEN
    RAISE EXCEPTION 'A 6-letter word was corrected with two edits';
  END IF;
  IF EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals(_org, 'tpe', 20)) THEN
    RAISE EXCEPTION 'A 3-letter word was typo-corrected (tpe)';
  END IF;
  IF EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals(_org, 'glv', 20)) THEN
    RAISE EXCEPTION 'A 3-letter word was typo-corrected';
  END IF;
  IF EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals(_org, 'rpewrap', 20)) THEN
    RAISE EXCEPTION 'A first-letter typo was corrected';
  END IF;
  IF EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals(_org, 'zzqxv', 20)) THEN
    RAISE EXCEPTION 'Nonsense produced results';
  END IF;
  -- Digits are never corrected: AT-4000 is not AT-3000.
  IF EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals(_org, 'AT-4000', 20)
             WHERE catalog_vendor_product_id IN ('5a10b000-0000-4000-8000-000000000402', '5a10b000-0000-4000-8000-000000000401')) THEN
    RAISE EXCEPTION 'A SKU digit was fuzzed';
  END IF;

  -- Short-query safeguards.
  IF EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals(_org, 'x', 20))
     OR EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals(_org, ' - ', 20)) THEN
    RAISE EXCEPTION 'A one-character query searched';
  END IF;
  IF EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals(_org, 'xl', 20)
             WHERE catalog_vendor_product_id = '5a10b000-0000-4000-8000-000000000410') THEN
    RAISE EXCEPTION 'A two-letter token matched inside a word (axle)';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals(_org, 'ax', 20)
                 WHERE catalog_vendor_product_id = '5a10b000-0000-4000-8000-000000000410') THEN
    RAISE EXCEPTION 'A two-letter word start did not match';
  END IF;

  -- Numeric sizes keep their meaning.
  SELECT array_agg(catalog_vendor_product_id ORDER BY catalog_vendor_product_id) INTO _ids
  FROM public.search_supply_request_products_with_signals(_org, '2 inch tape', 20);
  IF _ids IS DISTINCT FROM ARRAY['5a10b000-0000-4000-8000-000000000401']::uuid[] THEN
    RAISE EXCEPTION '2 inch matched other sizes (12" or 1/2"): %', _ids;
  END IF;
  SELECT array_agg(catalog_vendor_product_id ORDER BY catalog_vendor_product_id) INTO _ids
  FROM public.search_supply_request_products_with_signals(_org, '2" tape', 20);
  IF _ids IS DISTINCT FROM ARRAY['5a10b000-0000-4000-8000-000000000401']::uuid[] THEN
    RAISE EXCEPTION '2" did not equal 2 inch: %', _ids;
  END IF;
  SELECT array_agg(catalog_vendor_product_id ORDER BY catalog_vendor_product_id) INTO _ids
  FROM public.search_supply_request_products_with_signals(_org, '3 in tape', 20);
  IF _ids IS DISTINCT FROM ARRAY['5a10b000-0000-4000-8000-000000000402']::uuid[] THEN
    RAISE EXCEPTION '3 in failed: %', _ids;
  END IF;
  SELECT array_agg(catalog_vendor_product_id ORDER BY catalog_vendor_product_id) INTO _ids
  FROM public.search_supply_request_products_with_signals(_org, '1/2 inch tape', 20);
  IF _ids IS DISTINCT FROM ARRAY['5a10b000-0000-4000-8000-000000000403']::uuid[] THEN
    RAISE EXCEPTION '1/2 inch failed: %', _ids;
  END IF;
  IF EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals(_org, 'gloves 10', 20)) THEN
    RAISE EXCEPTION '10 matched 100';
  END IF;
  SELECT array_agg(catalog_vendor_product_id ORDER BY catalog_vendor_product_id) INTO _ids
  FROM public.search_supply_request_products_with_signals(_org, '12 inch', 20);
  IF _ids IS DISTINCT FROM ARRAY['5a10b000-0000-4000-8000-000000000404']::uuid[] THEN
    RAISE EXCEPTION '12 inch failed: %', _ids;
  END IF;

  -- Inactive catalog rows and non-requestable organization products never appear.
  IF EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals(_org, 'AT-9999', 20))
     OR EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals(_org, 'hidden inactive', 20))
     OR EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals(_org, 'admin only splint', 20)) THEN
    RAISE EXCEPTION 'Inactive or non-requestable products leaked';
  END IF;

  -- Variant presentation fields.
  SELECT * INTO _row FROM public.search_supply_request_products_with_signals(_org, 'AT-0500', 1);
  IF _row.variant_detail IS DISTINCT FROM '1/2" x 10 yd' OR _row.package_display IS DISTINCT FROM '48 roll' THEN
    RAISE EXCEPTION 'Variant detail missing: % %', _row.variant_detail, _row.package_display;
  END IF;
  SELECT * INTO _row FROM public.search_supply_request_products_with_signals(_org, 'ice bag small', 1);
  IF _row.variant_detail IS NOT NULL THEN
    RAISE EXCEPTION 'A description already in the name was repeated as a variant: %', _row.variant_detail;
  END IF;

  -- Denied, cancelled, submitted and under-review requests never count; another
  -- organization's approvals never count.
  SELECT * INTO _row FROM public.search_supply_request_products_with_signals(_org, 'AT-2000', 1);
  IF _row.approved_request_count <> 0 OR _row.last_approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'Denied / cancelled / pending or other-organization history counted: %', _row.approved_request_count;
  END IF;
  -- Purchases: posted invoices only, no credit memos, no unposted invoices, no other
  -- organization's lines.
  SELECT * INTO _row FROM public.search_supply_request_products_with_signals(_org, 'ice bag large', 1);
  IF _row.purchase_count <> 1 OR _row.last_purchased_at IS NULL THEN
    RAISE EXCEPTION 'Posted purchase not counted';
  END IF;
  SELECT * INTO _row FROM public.search_supply_request_products_with_signals(_org, 'ice bag small', 1);
  IF _row.purchase_count <> 0 OR _row.approved_request_count <> 2 THEN
    RAISE EXCEPTION 'Unposted / credit-memo / other-organization purchases counted: % %', _row.purchase_count, _row.approved_request_count;
  END IF;

  -- Purchase boost inside a tier: with nothing saved, Ice Bag Small (2 approvals) leads
  -- Ice Bag Large (1 purchase) because approvals rank before purchases.
  SELECT array_agg(product_id ORDER BY ordinality) INTO _ids
  FROM public.search_supply_request_products_with_signals(_org, 'ice bag', 20) WITH ORDINALITY;
  IF _ids[1:2] IS DISTINCT FROM ARRAY['5a10b000-0000-4000-8000-000000000501', '5a10b000-0000-4000-8000-000000000502']::uuid[] THEN
    RAISE EXCEPTION 'Approval-before-purchase order wrong: %', _ids;
  END IF;
  -- Purchase boost alone: "large" bags vs the cold pack? Use "bag": Large (purchase) vs Small
  -- (approvals) keeps the approval order; the purchase boost is checked on its own below.
  SELECT array_agg(product_id ORDER BY ordinality) INTO _ids
  FROM public.search_supply_request_products_with_signals(_org, 'bag large', 20) WITH ORDINALITY;
  IF _ids[1] IS DISTINCT FROM '5a10b000-0000-4000-8000-000000000502'::uuid THEN
    RAISE EXCEPTION 'Large lookup failed';
  END IF;
END
$search$;

-- Purchase boost on its own: two unboosted equals, one purchased.
RESET ROLE;
-- Purchase boost isolated from recency: Bbb was bought twice (latest 10 days ago), Aaa once
-- (yesterday). Strapping Roll mentions zinc oxide only in its description (attribute tier).
INSERT INTO public.products (id, organization_id, name, description, active, staff_requestable) VALUES
  ('5a10b000-0000-4000-8000-000000000521', '5a10b000-0000-4000-8000-000000000101', 'Zinc Oxide Tape Aaa', NULL, true, true),
  ('5a10b000-0000-4000-8000-000000000522', '5a10b000-0000-4000-8000-000000000101', 'Zinc Oxide Tape Bbb', NULL, true, true),
  ('5a10b000-0000-4000-8000-000000000523', '5a10b000-0000-4000-8000-000000000101', 'Strapping Roll', 'zinc oxide', true, true);
INSERT INTO public.invoices (id, organization_id, invoice_number, invoice_date, posted_at, processing_status, document_type) VALUES
  ('5a10b000-0000-4000-8000-000000000804', '5a10b000-0000-4000-8000-000000000101', 'A-4', current_date - 20, now() - interval '19 days', 'completed', 'INVOICE'),
  ('5a10b000-0000-4000-8000-000000000805', '5a10b000-0000-4000-8000-000000000101', 'A-5', current_date - 1, now(), 'completed', 'INVOICE');
INSERT INTO public.invoice_items (invoice_id, organization_id, description, quantity, product_id) VALUES
  ('5a10b000-0000-4000-8000-000000000801', '5a10b000-0000-4000-8000-000000000101', 'Zinc', 1, '5a10b000-0000-4000-8000-000000000522'),
  ('5a10b000-0000-4000-8000-000000000804', '5a10b000-0000-4000-8000-000000000101', 'Zinc', 1, '5a10b000-0000-4000-8000-000000000522'),
  ('5a10b000-0000-4000-8000-000000000805', '5a10b000-0000-4000-8000-000000000101', 'Zinc', 1, '5a10b000-0000-4000-8000-000000000521');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '5a10b000-0000-4000-8000-000000000003', true);

DO $purchase_boost$
DECLARE
  _ids uuid[];
BEGIN
  SELECT array_agg(product_id ORDER BY ordinality) INTO _ids
  FROM public.search_supply_request_products_with_signals('5a10b000-0000-4000-8000-000000000101', 'zinc oxide', 20) WITH ORDINALITY;
  IF _ids IS DISTINCT FROM ARRAY['5a10b000-0000-4000-8000-000000000522', '5a10b000-0000-4000-8000-000000000521',
                                 '5a10b000-0000-4000-8000-000000000523']::uuid[] THEN
    RAISE EXCEPTION 'Purchase boost failed (count must beat recency): %', _ids;
  END IF;
  -- ...but never across tiers: the exact name of the unpurchased one wins.
  SELECT array_agg(product_id ORDER BY ordinality) INTO _ids
  FROM public.search_supply_request_products_with_signals('5a10b000-0000-4000-8000-000000000101', 'zinc oxide tape aaa', 20) WITH ORDINALITY;
  IF _ids[1] IS DISTINCT FROM '5a10b000-0000-4000-8000-000000000521'::uuid THEN
    RAISE EXCEPTION 'Purchase boost crossed a tier: %', _ids;
  END IF;
END
$purchase_boost$;

-- ---------------------------------------------------------------------------------------
-- Saved Items.
-- ---------------------------------------------------------------------------------------
DO $saved$
DECLARE
  _org constant uuid := '5a10b000-0000-4000-8000-000000000101';
  _row record;
  _ids uuid[];
BEGIN
  -- Add (product and catalog identities), idempotent: a duplicate save is not a second row.
  PERFORM * FROM public.save_staff_product(_org, _product_id => '5a10b000-0000-4000-8000-000000000502');
  PERFORM * FROM public.save_staff_product(_org, _product_id => '5a10b000-0000-4000-8000-000000000502');
  PERFORM * FROM public.save_staff_product(_org, _catalog_vendor_product_id => '5a10b000-0000-4000-8000-000000000405');
  PERFORM * FROM public.save_staff_product(_org, _inventory_item_id => '5a10b000-0000-4000-8000-000000000601');
  PERFORM * FROM public.save_staff_product(_org, _product_id => '5a10b000-0000-4000-8000-000000000523');
  SELECT array_agg(product_id ORDER BY ordinality) INTO _ids
  FROM public.search_supply_request_products_with_signals(_org, 'zinc oxide', 20) WITH ORDINALITY;
  IF _ids[3] IS DISTINCT FROM '5a10b000-0000-4000-8000-000000000523'::uuid THEN
    RAISE EXCEPTION 'A saved attribute match outranked name matches: %', _ids;
  END IF;

  -- Saved boost inside a tier: Large (saved, 1 purchase) now leads Small (2 approvals).
  SELECT array_agg(product_id ORDER BY ordinality) INTO _ids
  FROM public.search_supply_request_products_with_signals(_org, 'ice bag', 20) WITH ORDINALITY;
  IF _ids[1:2] IS DISTINCT FROM ARRAY['5a10b000-0000-4000-8000-000000000502', '5a10b000-0000-4000-8000-000000000501']::uuid[] THEN
    RAISE EXCEPTION 'Saved boost failed: %', _ids;
  END IF;
  -- ...but a saved item never beats a better tier: exact name "Ice Bag Small" wins.
  SELECT * INTO _row FROM public.search_supply_request_products_with_signals(_org, 'ice bag small', 20) LIMIT 1;
  IF _row.product_id IS DISTINCT FROM '5a10b000-0000-4000-8000-000000000501' OR _row.is_saved THEN
    RAISE EXCEPTION 'Saved boost crossed a tier';
  END IF;
  SELECT * INTO _row FROM public.search_supply_request_products_with_signals(_org, 'PW-100', 1);
  IF NOT _row.is_saved THEN
    RAISE EXCEPTION 'Saved catalog item not flagged';
  END IF;
  -- Another organization's Saved Item of the same user does not leak into A.
  -- (user 03 is not in B; checked for user 04 below.)

  -- Unavailable identities cannot be saved.
  BEGIN
    PERFORM * FROM public.save_staff_product(_org, _product_id => '5a10b000-0000-4000-8000-000000000505');
    RAISE EXCEPTION 'A non-requestable product was saved';
  EXCEPTION WHEN no_data_found THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.save_staff_product(_org, _catalog_vendor_product_id => '5a10b000-0000-4000-8000-000000000412');
    RAISE EXCEPTION 'An inactive catalog product was saved';
  EXCEPTION WHEN no_data_found THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.save_staff_product(_org, _product_id => '5a10b000-0000-4000-8000-000000000511');
    RAISE EXCEPTION 'Another organization''s product was saved';
  EXCEPTION WHEN no_data_found THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.save_staff_product(_org, _inventory_item_id => '5a10b000-0000-4000-8000-000000000611');
    RAISE EXCEPTION 'Another organization''s inventory item was saved';
  EXCEPTION WHEN no_data_found THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.save_staff_product(_org);
    RAISE EXCEPTION 'A save without an identity was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.save_staff_product(_org, '5a10b000-0000-4000-8000-000000000502', '5a10b000-0000-4000-8000-000000000405');
    RAISE EXCEPTION 'A save with two identities was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;

  -- No direct table access.
  BEGIN
    PERFORM 1 FROM public.staff_saved_products;
    RAISE EXCEPTION 'staff_saved_products is readable by authenticated';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO public.staff_saved_products (organization_id, user_id, product_id)
    VALUES (_org, '5a10b000-0000-4000-8000-000000000003', '5a10b000-0000-4000-8000-000000000501');
    RAISE EXCEPTION 'staff_saved_products is writable by authenticated';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM 1 FROM public.catalog_vendor_product_search_documents;
    RAISE EXCEPTION 'search documents are readable by authenticated';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.supply_request_product_history(_org);
    RAISE EXCEPTION 'internal history is executable by authenticated';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.supply_request_product_search(_org, 'tape', 5);
    RAISE EXCEPTION 'internal search is executable by authenticated';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END
$saved$;

-- Staff 04: does not see 03's Saved Items, cannot remove them, and B's Saved Item stays in B.
SELECT set_config('request.jwt.claim.sub', '5a10b000-0000-4000-8000-000000000004', true);
DO $other_user$
DECLARE
  _org constant uuid := '5a10b000-0000-4000-8000-000000000101';
  _row record;
BEGIN
  IF EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals(_org, 'ice bag', 20) WHERE is_saved)
     OR EXISTS (SELECT 1 FROM public.get_staff_product_discovery(_org, 6) WHERE section = 'saved') THEN
    RAISE EXCEPTION 'Another user''s Saved Items leaked';
  END IF;
  SELECT * INTO _row FROM public.search_supply_request_products_with_signals(_org, 'AT-2000', 1);
  IF _row.is_saved THEN
    RAISE EXCEPTION 'A Saved Item from organization B leaked into A';
  END IF;
  SELECT * INTO _row FROM public.remove_staff_saved_product(_org, _product_id => '5a10b000-0000-4000-8000-000000000502');
  IF _row.removed THEN
    RAISE EXCEPTION 'Removed another user''s Saved Item';
  END IF;
  -- In B, the same user sees their B Saved Item.
  IF NOT EXISTS (SELECT 1 FROM public.get_staff_product_discovery('5a10b000-0000-4000-8000-000000000102', 6)
                 WHERE section = 'saved' AND catalog_vendor_product_id = '5a10b000-0000-4000-8000-000000000401') THEN
    RAISE EXCEPTION 'Organization B Saved Item missing in B';
  END IF;
  -- B's approvals are visible in B only.
  SELECT * INTO _row FROM public.search_supply_request_products_with_signals('5a10b000-0000-4000-8000-000000000102', 'AT-2000', 1);
  IF _row.approved_request_count <> 5 OR NOT _row.is_saved THEN
    RAISE EXCEPTION 'Organization B history missing in B: %', _row.approved_request_count;
  END IF;
  -- Discovery as 04 in A: Frequently requested by approvals (popular first), Ice Bag Small
  -- frequent (not saved by 04), Purchased before holds Large and Zinc B.
  IF (SELECT array_agg(result_key ORDER BY section_rank) FROM public.get_staff_product_discovery(_org, 6) WHERE section = 'frequent')
     IS DISTINCT FROM ARRAY['catalog-vendor-product:5a10b000-0000-4000-8000-000000000411',
                            'catalog-vendor-product:5a10b000-0000-4000-8000-000000000409',
                            'catalog-vendor-product:5a10b000-0000-4000-8000-000000000402',
                            'organization-product:5a10b000-0000-4000-8000-000000000501'] THEN
    RAISE EXCEPTION 'Frequent section for 04 wrong: %',
      (SELECT array_agg(result_key ORDER BY section_rank) FROM public.get_staff_product_discovery(_org, 6) WHERE section = 'frequent');
  END IF;
END
$other_user$;

-- Staff 03 discovery: sections, order, deduplication, signals.
SELECT set_config('request.jwt.claim.sub', '5a10b000-0000-4000-8000-000000000003', true);
DO $discovery$
DECLARE
  _org constant uuid := '5a10b000-0000-4000-8000-000000000101';
  _sections text[];
  _keys text[];
  _row record;
BEGIN
  SELECT array_agg(section || ':' || result_key ORDER BY CASE section WHEN 'saved' THEN 1 WHEN 'frequent' THEN 2 ELSE 3 END, section_rank)
  INTO _keys FROM public.get_staff_product_discovery(_org, 6);
  -- Saved newest first (saved in one transaction here, so by name); Ice Bag Large is saved so it is NOT also under Purchased before;
  -- Ice Bag Small is frequent (2 approvals) for 03.
  IF _keys IS DISTINCT FROM ARRAY[
       'saved:inventory:5a10b000-0000-4000-8000-000000000601',
       'saved:organization-product:5a10b000-0000-4000-8000-000000000502',
       'saved:catalog-vendor-product:5a10b000-0000-4000-8000-000000000405',
       'saved:organization-product:5a10b000-0000-4000-8000-000000000523',
       'frequent:catalog-vendor-product:5a10b000-0000-4000-8000-000000000411',
       'frequent:catalog-vendor-product:5a10b000-0000-4000-8000-000000000409',
       'frequent:catalog-vendor-product:5a10b000-0000-4000-8000-000000000402',
       'frequent:organization-product:5a10b000-0000-4000-8000-000000000501',
       'purchased:organization-product:5a10b000-0000-4000-8000-000000000521',
       'purchased:organization-product:5a10b000-0000-4000-8000-000000000522'] THEN
    RAISE EXCEPTION 'Discovery sections wrong: %', _keys;
  END IF;
  IF (SELECT count(*) FROM public.get_staff_product_discovery(_org, 6)) <>
     (SELECT count(DISTINCT result_key) FROM public.get_staff_product_discovery(_org, 6)) THEN
    RAISE EXCEPTION 'A product appeared in two sections';
  END IF;
  SELECT * INTO _row FROM public.get_staff_product_discovery(_org, 6)
  WHERE result_key = 'organization-product:5a10b000-0000-4000-8000-000000000502';
  IF NOT _row.is_saved OR _row.purchase_count <> 1 OR _row.last_purchased_at IS NULL THEN
    RAISE EXCEPTION 'Saved row lost its signals';
  END IF;
  -- Limit applies to history sections, never to Saved Items.
  IF (SELECT count(*) FROM public.get_staff_product_discovery(_org, 1) WHERE section = 'frequent') <> 1
     OR (SELECT count(*) FROM public.get_staff_product_discovery(_org, 1) WHERE section = 'saved') <> 4 THEN
    RAISE EXCEPTION 'Discovery limit wrong';
  END IF;

  -- Remove (own), idempotent.
  SELECT * INTO _row FROM public.remove_staff_saved_product(_org, _product_id => '5a10b000-0000-4000-8000-000000000502');
  IF NOT _row.removed OR _row.saved THEN
    RAISE EXCEPTION 'Own Saved Item not removed';
  END IF;
  SELECT * INTO _row FROM public.remove_staff_saved_product(_org, _product_id => '5a10b000-0000-4000-8000-000000000502');
  IF _row.removed THEN
    RAISE EXCEPTION 'Second remove reported a removal';
  END IF;
  -- Removed: now under Purchased before.
  IF NOT EXISTS (SELECT 1 FROM public.get_staff_product_discovery(_org, 6)
                 WHERE section = 'purchased' AND product_id = '5a10b000-0000-4000-8000-000000000502') THEN
    RAISE EXCEPTION 'Unsaved product did not return to Purchased before';
  END IF;
END
$discovery$;

-- Owner and admin can use discovery and Saved Items for themselves.
SELECT set_config('request.jwt.claim.sub', '5a10b000-0000-4000-8000-000000000002', true);
DO $admin$
BEGIN
  PERFORM * FROM public.save_staff_product('5a10b000-0000-4000-8000-000000000101', _product_id => '5a10b000-0000-4000-8000-000000000501');
  IF NOT EXISTS (SELECT 1 FROM public.get_staff_product_discovery('5a10b000-0000-4000-8000-000000000101', 6)
                 WHERE section = 'saved' AND product_id = '5a10b000-0000-4000-8000-000000000501')
     OR NOT EXISTS (SELECT 1 FROM public.search_supply_request_products('5a10b000-0000-4000-8000-000000000101', 'ice bag', 20)) THEN
    RAISE EXCEPTION 'Admin discovery failed';
  END IF;
END
$admin$;
SELECT set_config('request.jwt.claim.sub', '5a10b000-0000-4000-8000-000000000001', true);
DO $owner$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.get_staff_product_discovery('5a10b000-0000-4000-8000-000000000101', 6) WHERE section = 'frequent')
     OR EXISTS (SELECT 1 FROM public.get_staff_product_discovery('5a10b000-0000-4000-8000-000000000101', 6) WHERE section = 'saved') THEN
    RAISE EXCEPTION 'Owner discovery wrong (or saw the admin''s Saved Items)';
  END IF;
END
$owner$;

-- Denials: former member, non-member, other organization, signed out.
DO $denials$
DECLARE
  _user text;
  _org text;
BEGIN
  FOR _user, _org IN VALUES
    ('5a10b000-0000-4000-8000-000000000007', '5a10b000-0000-4000-8000-000000000101'),
    ('5a10b000-0000-4000-8000-000000000009', '5a10b000-0000-4000-8000-000000000101'),
    ('5a10b000-0000-4000-8000-000000000003', '5a10b000-0000-4000-8000-000000000102'),
    ('5a10b000-0000-4000-8000-000000000005', '5a10b000-0000-4000-8000-000000000101')
  LOOP
    PERFORM set_config('request.jwt.claim.sub', _user, true);
    BEGIN
      PERFORM * FROM public.search_supply_request_products_with_signals(_org::uuid, 'tape', 20);
      RAISE EXCEPTION 'search allowed for % in %', _user, _org;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
      PERFORM * FROM public.search_supply_request_products(_org::uuid, 'tape', 20);
      RAISE EXCEPTION 'legacy search allowed for % in %', _user, _org;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
      PERFORM * FROM public.get_staff_product_discovery(_org::uuid, 6);
      RAISE EXCEPTION 'discovery allowed for % in %', _user, _org;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
      PERFORM * FROM public.save_staff_product(_org::uuid, _product_id => '5a10b000-0000-4000-8000-000000000501');
      RAISE EXCEPTION 'save allowed for % in %', _user, _org;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
      PERFORM * FROM public.remove_staff_saved_product(_org::uuid, _product_id => '5a10b000-0000-4000-8000-000000000501');
      RAISE EXCEPTION 'remove allowed for % in %', _user, _org;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END LOOP;
  PERFORM set_config('request.jwt.claim.sub', '', true);
  BEGIN
    PERFORM * FROM public.get_staff_product_discovery('5a10b000-0000-4000-8000-000000000101', 6);
    RAISE EXCEPTION 'signed-out discovery allowed';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END
$denials$;

RESET ROLE;

-- The former member's rows are untouched, and nothing above wrote outside the fixture.
DO $state$
BEGIN
  IF (SELECT count(*) FROM public.staff_saved_products WHERE user_id = '5a10b000-0000-4000-8000-000000000003') <> 3
     OR (SELECT count(*) FROM public.staff_saved_products WHERE user_id = '5a10b000-0000-4000-8000-000000000002') <> 1
     OR (SELECT count(*) FROM public.staff_saved_products WHERE user_id = '5a10b000-0000-4000-8000-000000000004') <> 1 THEN
    RAISE EXCEPTION 'Saved Items state wrong after the suite';
  END IF;
  BEGIN
    INSERT INTO public.staff_saved_products (organization_id, user_id, product_id)
    VALUES ('5a10b000-0000-4000-8000-000000000101', '5a10b000-0000-4000-8000-000000000002', '5a10b000-0000-4000-8000-000000000501');
    RAISE EXCEPTION 'A duplicate Saved Item row was stored';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
END
$state$;

-- Document maintenance: each catalog change is searchable at once (checked right after it,
-- so one trigger cannot mask another); eligibility is never stale.
UPDATE public.catalog_products SET name = 'Elastic Wrap Bandage' WHERE id = '5a10b000-0000-4000-8000-000000000304';
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '5a10b000-0000-4000-8000-000000000003', true);
DO $product_rename$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals('5a10b000-0000-4000-8000-000000000101', 'elastic wrap', 20)
                 WHERE catalog_vendor_product_id = '5a10b000-0000-4000-8000-000000000404')
     OR EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals('5a10b000-0000-4000-8000-000000000101', 'coach tape', 20)
                WHERE catalog_vendor_product_id = '5a10b000-0000-4000-8000-000000000404') THEN
    RAISE EXCEPTION 'Product rename not reflected';
  END IF;
END
$product_rename$;
RESET ROLE;

UPDATE public.catalog_vendor_products SET package_description = 'Case of 12 sleeves' WHERE id = '5a10b000-0000-4000-8000-000000000410';
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '5a10b000-0000-4000-8000-000000000003', true);
DO $package_change$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals('5a10b000-0000-4000-8000-000000000101', 'axle sleeves', 20)
                 WHERE catalog_vendor_product_id = '5a10b000-0000-4000-8000-000000000410') THEN
    RAISE EXCEPTION 'Package change not reflected';
  END IF;
END
$package_change$;
RESET ROLE;

UPDATE public.catalog_vendors SET name = 'Renamed Supply Co' WHERE id = '5a10b000-0000-4000-8000-000000000201';
UPDATE public.catalog_vendor_products SET active = false, discontinued = true WHERE id = '5a10b000-0000-4000-8000-000000000407';
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '5a10b000-0000-4000-8000-000000000003', true);
DO $vendor_rename$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals('5a10b000-0000-4000-8000-000000000101', 'renamed supply bulk', 20)
                 WHERE catalog_vendor_product_id = '5a10b000-0000-4000-8000-000000000409') THEN
    RAISE EXCEPTION 'Vendor rename not reflected';
  END IF;
  IF EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals('5a10b000-0000-4000-8000-000000000101', 'NG-L', 20)) THEN
    RAISE EXCEPTION 'Discontinued product still searchable';
  END IF;
END
$vendor_rename$;
RESET ROLE;

INSERT INTO public.catalog_import_batches (id, catalog_vendor_id, source_name, source_version, status)
VALUES ('5a10b000-0000-4000-8000-000000000901', '5a10b000-0000-4000-8000-000000000201', 'fixture', '1', 'completed');
INSERT INTO public.catalog_source_records (import_batch_id, catalog_vendor_id, source_ordinal, raw_vendor_sku,
  raw_product_name, raw_variant, raw_data, matched_catalog_vendor_product_id, resolution_status, resolved_at)
VALUES ('5a10b000-0000-4000-8000-000000000901', '5a10b000-0000-4000-8000-000000000201', 1, 'NG-M',
  'Nitrile Exam Gloves', 'Violet Blue', '{}', '5a10b000-0000-4000-8000-000000000406', 'matched', now());
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '5a10b000-0000-4000-8000-000000000003', true);
DO $specification$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.search_supply_request_products_with_signals('5a10b000-0000-4000-8000-000000000101', 'violet gloves', 20)
                 WHERE catalog_vendor_product_id = '5a10b000-0000-4000-8000-000000000406') THEN
    RAISE EXCEPTION 'New trusted specification not searchable';
  END IF;
END
$specification$;

ROLLBACK;
