-- Beta hardening rollback-only behavioral verification: a line that was deliberately
-- re-matched to a different product can be posted, without rewriting inventory history.
-- Run after 20261012120000_beta_invoice_manual_catalog_matching.sql. All data rolls back.
--
-- Vendor SKU SKU-1 is a catalog-adopted mapping for product A, and A is already stocked
-- from Henry Schein under that SKU. A reviewer decides one invoice's SKU-1 line is really
-- product B.

BEGIN;

CREATE FUNCTION pg_temp.posting_expect_error(_statement text, _expected text)
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

-- Everything posting may write, for one organization.
CREATE FUNCTION pg_temp.posting_state()
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT jsonb_build_object(
    'inventory', (SELECT coalesce(jsonb_agg(to_jsonb(i) - 'updated_at' ORDER BY i.id), '[]') FROM public.inventory_items i WHERE i.organization_id = 'be140000-0000-4000-8000-000000000101'),
    'adjustments', (SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.id), '[]') FROM public.inventory_adjustments a WHERE a.organization_id = 'be140000-0000-4000-8000-000000000101'),
    'prices', (SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.id), '[]') FROM public.inventory_price_history p WHERE p.organization_id = 'be140000-0000-4000-8000-000000000101'),
    'mappings', (SELECT coalesce(jsonb_agg(to_jsonb(m) - 'updated_at' ORDER BY m.id), '[]') FROM public.vendor_products m WHERE m.organization_id = 'be140000-0000-4000-8000-000000000101'),
    'products', (SELECT coalesce(jsonb_agg(to_jsonb(p) - 'updated_at' ORDER BY p.id), '[]') FROM public.products p WHERE p.organization_id = 'be140000-0000-4000-8000-000000000101'),
    'vendors', (SELECT coalesce(jsonb_agg(to_jsonb(v) - 'updated_at' ORDER BY v.id), '[]') FROM public.vendors v WHERE v.organization_id = 'be140000-0000-4000-8000-000000000101'),
    'lines', (SELECT coalesce(jsonb_agg(to_jsonb(l) - 'updated_at' ORDER BY l.id), '[]') FROM public.invoice_items l WHERE l.organization_id = 'be140000-0000-4000-8000-000000000101'),
    'invoices', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'status', processing_status, 'posted', posted_at IS NOT NULL) ORDER BY id), '[]') FROM public.invoices WHERE organization_id = 'be140000-0000-4000-8000-000000000101')
  )
$$;

CREATE FUNCTION pg_temp.posting_item(_product_id uuid)
RETURNS public.inventory_items
LANGUAGE sql
AS $$ SELECT * FROM public.inventory_items WHERE product_id = _product_id AND organization_id = 'be140000-0000-4000-8000-000000000101' $$;

INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
VALUES ('be140000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'posting-owner@example.invalid', '', now(), '{}', '{}', now(), now());
INSERT INTO public.organizations (id, name, created_by)
VALUES ('be140000-0000-4000-8000-000000000101', 'Posting Athletics', 'be140000-0000-4000-8000-000000000001');
INSERT INTO public.organization_memberships (id, organization_id, user_id, role, active)
VALUES ('be140000-0000-4000-8000-000000000111', 'be140000-0000-4000-8000-000000000101', 'be140000-0000-4000-8000-000000000001', 'owner', true);

INSERT INTO public.catalog_vendors (id, name, normalized_name)
VALUES ('be140000-0000-4000-8000-000000000201', 'Posting Henry Schein', 'placeholder');
INSERT INTO public.catalog_products (id, name, active, verification_status)
VALUES ('be140000-0000-4000-8000-000000000211', 'Posting Catalog Product A', true, 'verified');
INSERT INTO public.catalog_vendor_products (id, catalog_vendor_id, catalog_product_id, vendor_sku, normalized_vendor_sku, package_status, active, discontinued, verification_status)
VALUES ('be140000-0000-4000-8000-000000000231', 'be140000-0000-4000-8000-000000000201', 'be140000-0000-4000-8000-000000000211', 'SKU-1', 'x', 'unknown', true, false, 'verified');

INSERT INTO public.vendors (id, organization_id, name, normalized_name, active, catalog_vendor_id)
VALUES
  ('be140000-0000-4000-8000-000000000301', 'be140000-0000-4000-8000-000000000101', 'Henry Schein', 'henry schein', true, 'be140000-0000-4000-8000-000000000201'),
  ('be140000-0000-4000-8000-000000000302', 'be140000-0000-4000-8000-000000000101', 'Medline', 'medline', true, NULL);

INSERT INTO public.products (id, organization_id, name, normalized_name, approved, active, staff_requestable)
VALUES
  ('be140000-0000-4000-8000-000000000402', 'be140000-0000-4000-8000-000000000101', 'Product B', 'x', true, true, true),
  ('be140000-0000-4000-8000-000000000403', 'be140000-0000-4000-8000-000000000101', 'Product C', 'x', true, true, true),
  ('be140000-0000-4000-8000-000000000404', 'be140000-0000-4000-8000-000000000101', 'Product D', 'x', true, true, true);

INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type)
SELECT ('be140000-0000-4000-8000-0000000006' || lpad(n::text, 2, '0'))::uuid, 'be140000-0000-4000-8000-000000000101',
  'be140000-0000-4000-8000-000000000001', 'be140000-0000-4000-8000-000000000101/posting-' || n || '.pdf', 'posting-' || n || '.pdf', 1024, 'application/pdf'
FROM generate_series(0, 5) n;

INSERT INTO public.invoices (id, organization_id, source_file_id, vendor_id, vendor_name, invoice_number, invoice_date, processing_status)
VALUES
  -- 0: the earlier invoice that stocked A. 1: an ordinary invoice. 2: the re-matched invoice.
  -- 3: another vendor printing the same SKU. 4: an unresolved line. 5: a mismatched mapping.
  ('be140000-0000-4000-8000-000000000700', 'be140000-0000-4000-8000-000000000101', 'be140000-0000-4000-8000-000000000600', 'be140000-0000-4000-8000-000000000301', 'Henry Schein', 'P-0', '2026-09-01', 'review_required'),
  ('be140000-0000-4000-8000-000000000701', 'be140000-0000-4000-8000-000000000101', 'be140000-0000-4000-8000-000000000601', 'be140000-0000-4000-8000-000000000301', 'Henry Schein', 'P-1', '2026-09-10', 'review_required'),
  ('be140000-0000-4000-8000-000000000702', 'be140000-0000-4000-8000-000000000101', 'be140000-0000-4000-8000-000000000602', 'be140000-0000-4000-8000-000000000301', 'Henry Schein', 'P-2', '2026-09-17', 'review_required'),
  ('be140000-0000-4000-8000-000000000703', 'be140000-0000-4000-8000-000000000101', 'be140000-0000-4000-8000-000000000603', 'be140000-0000-4000-8000-000000000302', 'Medline', 'P-3', '2026-09-18', 'review_required'),
  ('be140000-0000-4000-8000-000000000704', 'be140000-0000-4000-8000-000000000101', 'be140000-0000-4000-8000-000000000604', 'be140000-0000-4000-8000-000000000301', 'Henry Schein', 'P-4', '2026-09-19', 'review_required'),
  ('be140000-0000-4000-8000-000000000705', 'be140000-0000-4000-8000-000000000101', 'be140000-0000-4000-8000-000000000605', 'be140000-0000-4000-8000-000000000301', 'Henry Schein', 'P-5', '2026-09-20', 'review_required');

INSERT INTO public.invoice_items (id, invoice_id, organization_id, line_number, sku, description, quantity, unit_of_measure, unit_price, total_price)
VALUES
  ('be140000-0000-4000-8000-000000000801', 'be140000-0000-4000-8000-000000000700', 'be140000-0000-4000-8000-000000000101', 1, 'SKU-1', 'First receipt of A', 5, 'EA', 10, 50),
  ('be140000-0000-4000-8000-000000000802', 'be140000-0000-4000-8000-000000000700', 'be140000-0000-4000-8000-000000000101', 2, 'D-OLD', 'First receipt of D', 2, 'EA', 3, 6),
  ('be140000-0000-4000-8000-000000000811', 'be140000-0000-4000-8000-000000000701', 'be140000-0000-4000-8000-000000000101', 1, 'SKU-1', 'Ordinary receipt of A', 1, 'EA', 11, 11),
  ('be140000-0000-4000-8000-000000000821', 'be140000-0000-4000-8000-000000000702', 'be140000-0000-4000-8000-000000000101', 1, 'SKU-1', 'Printed as SKU-1, really product B', 4, 'EA', 12, 48),
  ('be140000-0000-4000-8000-000000000822', 'be140000-0000-4000-8000-000000000702', 'be140000-0000-4000-8000-000000000101', 2, 'sku-1', 'Lower-case SKU-1, really product D', 3, 'EA', 2, 6),
  ('be140000-0000-4000-8000-000000000823', 'be140000-0000-4000-8000-000000000702', 'be140000-0000-4000-8000-000000000101', 3, 'SKU-1', 'A second SKU-1 line that is product B', 1, 'EA', 12, 12),
  ('be140000-0000-4000-8000-000000000824', 'be140000-0000-4000-8000-000000000702', 'be140000-0000-4000-8000-000000000101', 4, 'SKU-1', 'A SKU-1 line left as product A', 2, 'EA', 10, 20),
  ('be140000-0000-4000-8000-000000000831', 'be140000-0000-4000-8000-000000000703', 'be140000-0000-4000-8000-000000000101', 1, 'SKU-1', 'Medline prints SKU-1 for product C', 1, 'EA', 7, 7),
  ('be140000-0000-4000-8000-000000000841', 'be140000-0000-4000-8000-000000000704', 'be140000-0000-4000-8000-000000000101', 1, 'UNKNOWN-9', 'Nobody matched this line', 1, 'EA', 1, 1),
  ('be140000-0000-4000-8000-000000000851', 'be140000-0000-4000-8000-000000000705', 'be140000-0000-4000-8000-000000000101', 1, 'SKU-1', 'Line for B pointing at the mapping for A', 1, 'EA', 1, 1);

CREATE TEMP TABLE posting_snapshots (name text PRIMARY KEY, value jsonb);
GRANT ALL ON posting_snapshots TO authenticated;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be140000-0000-4000-8000-000000000001', true);

-- History: an earlier invoice adopts SKU-1 from the catalog as product A and stocks A and D.
SELECT public.resolve_invoice_exact_product_identities('be140000-0000-4000-8000-000000000101', 'be140000-0000-4000-8000-000000000600');
SELECT public.confirm_invoice_item_product('be140000-0000-4000-8000-000000000101', 'be140000-0000-4000-8000-000000000600',
  'be140000-0000-4000-8000-000000000802', 'be140000-0000-4000-8000-000000000404', true);
SELECT public.post_reviewed_invoice('be140000-0000-4000-8000-000000000101', 'be140000-0000-4000-8000-000000000600');
RESET ROLE;
CREATE FUNCTION pg_temp.product_a() RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM public.products WHERE organization_id = 'be140000-0000-4000-8000-000000000101' AND catalog_product_id = 'be140000-0000-4000-8000-000000000211'
$$;
DO $posting_setup$
DECLARE _a public.inventory_items := pg_temp.posting_item(pg_temp.product_a());
BEGIN
  IF _a.sku IS DISTINCT FROM 'SKU-1' OR _a.vendor_name IS DISTINCT FROM 'Henry Schein' OR _a.quantity IS DISTINCT FROM 5
     OR (pg_temp.posting_item('be140000-0000-4000-8000-000000000404')).sku IS DISTINCT FROM 'D-OLD' THEN
    RAISE EXCEPTION 'Setup failed: A should be stocked under SKU-1: %', to_jsonb(_a);
  END IF;
END
$posting_setup$;

-- Check 1: an ordinary matched line posts normally, onto the product that holds the SKU.
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be140000-0000-4000-8000-000000000001', true);
SELECT public.resolve_invoice_exact_product_identities('be140000-0000-4000-8000-000000000101', 'be140000-0000-4000-8000-000000000601');
INSERT INTO posting_snapshots VALUES ('ordinary', public.post_reviewed_invoice('be140000-0000-4000-8000-000000000101', 'be140000-0000-4000-8000-000000000601'));
RESET ROLE;
DO $posting_check_1$
DECLARE _a public.inventory_items := pg_temp.posting_item(pg_temp.product_a());
BEGIN
  IF (SELECT value FROM posting_snapshots WHERE name = 'ordinary') <> jsonb_build_object('invoiceId', 'be140000-0000-4000-8000-000000000701', 'createdInventoryItems', 0, 'updatedInventoryItems', 1, 'alreadyCompleted', false)
     OR _a.quantity IS DISTINCT FROM 6 OR _a.sku IS DISTINCT FROM 'SKU-1' OR _a.last_purchase_price IS DISTINCT FROM 11
     OR (SELECT count(*) FROM public.inventory_items WHERE organization_id = 'be140000-0000-4000-8000-000000000101') <> 2 THEN
    RAISE EXCEPTION 'Check 1 failed: ordinary posting: % / %', (SELECT value FROM posting_snapshots WHERE name = 'ordinary'), to_jsonb(_a);
  END IF;
END
$posting_check_1$;

-- The reviewer works invoice 2: SKU-1 lines are matched automatically to A, then two are
-- re-matched to B and the lower-case line to D. One SKU-1 line stays with A.
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be140000-0000-4000-8000-000000000001', true);
SELECT public.resolve_invoice_exact_product_identities('be140000-0000-4000-8000-000000000101', 'be140000-0000-4000-8000-000000000602');
SELECT public.confirm_invoice_item_product('be140000-0000-4000-8000-000000000101', 'be140000-0000-4000-8000-000000000602', line.id, line.product, true)
FROM (VALUES
  ('be140000-0000-4000-8000-000000000821'::uuid, 'be140000-0000-4000-8000-000000000402'::uuid),
  ('be140000-0000-4000-8000-000000000822'::uuid, 'be140000-0000-4000-8000-000000000404'::uuid),
  ('be140000-0000-4000-8000-000000000823'::uuid, 'be140000-0000-4000-8000-000000000402'::uuid)
) AS line(id, product);
RESET ROLE;
DO $posting_rematch_setup$
BEGIN
  IF (SELECT count(*) FROM public.invoice_items WHERE invoice_id = 'be140000-0000-4000-8000-000000000702' AND product_id IS NULL) <> 0
     OR (SELECT product_id FROM public.invoice_items WHERE id = 'be140000-0000-4000-8000-000000000824') IS DISTINCT FROM pg_temp.product_a()
     OR (SELECT vendor_product_id FROM public.invoice_items WHERE id = 'be140000-0000-4000-8000-000000000821') IS NOT NULL THEN
    RAISE EXCEPTION 'Setup failed: invoice 2 is not re-matched as intended';
  END IF;
END
$posting_rematch_setup$;
INSERT INTO posting_snapshots VALUES ('before_rematch_post', pg_temp.posting_state());

-- Check 2: the manually re-matched invoice posts.
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be140000-0000-4000-8000-000000000001', true);
INSERT INTO posting_snapshots VALUES ('rematch', public.post_reviewed_invoice('be140000-0000-4000-8000-000000000101', 'be140000-0000-4000-8000-000000000602'));
RESET ROLE;
INSERT INTO posting_snapshots VALUES ('after_rematch_post', pg_temp.posting_state());
DO $posting_check_2$
DECLARE _result jsonb := (SELECT value FROM posting_snapshots WHERE name = 'rematch');
BEGIN
  -- B is new to inventory; B's second line, D, and A are updates.
  IF _result <> jsonb_build_object('invoiceId', 'be140000-0000-4000-8000-000000000702', 'createdInventoryItems', 1, 'updatedInventoryItems', 3, 'alreadyCompleted', false)
     OR (SELECT processing_status FROM public.invoices WHERE id = 'be140000-0000-4000-8000-000000000702') <> 'completed'
     OR (SELECT count(*) FROM public.invoice_items WHERE invoice_id = 'be140000-0000-4000-8000-000000000702' AND review_status <> 'approved') <> 0 THEN
    RAISE EXCEPTION 'Check 2 failed: the re-matched invoice did not post: %', _result;
  END IF;
END
$posting_check_2$;

-- Check 3: A's inventory item is still A's, still carries SKU-1, and changed only by its own line.
DO $posting_check_3$
DECLARE
  _before jsonb := (SELECT item FROM jsonb_array_elements((SELECT value->'inventory' FROM posting_snapshots WHERE name = 'before_rematch_post')) item WHERE (item->>'product_id')::uuid = pg_temp.product_a());
  _a public.inventory_items := pg_temp.posting_item(pg_temp.product_a());
BEGIN
  IF _a.id::text <> _before->>'id' OR _a.product_id IS DISTINCT FROM pg_temp.product_a()
     OR _a.sku IS DISTINCT FROM 'SKU-1' OR _a.vendor_name IS DISTINCT FROM 'Henry Schein' OR _a.name IS DISTINCT FROM _before->>'name'
     OR _a.quantity IS DISTINCT FROM 8 OR _a.last_purchase_price IS DISTINCT FROM 10 THEN
    RAISE EXCEPTION 'Check 3 failed: the old inventory item changed identity: % (was %)', to_jsonb(_a), _before;
  END IF;
END
$posting_check_3$;

-- Check 4: the receipt is attributed to B, on B's own inventory item. That item does not
-- claim SKU-1, which already labels A's item for this vendor.
DO $posting_check_4$
DECLARE _b public.inventory_items := pg_temp.posting_item('be140000-0000-4000-8000-000000000402');
BEGIN
  IF _b.id IS NULL OR _b.quantity IS DISTINCT FROM 5 OR _b.sku IS NOT NULL OR _b.vendor_name IS DISTINCT FROM 'Henry Schein'
     OR _b.name IS DISTINCT FROM 'Printed as SKU-1, really product B' OR _b.last_purchase_price IS DISTINCT FROM 12
     OR (SELECT jsonb_agg(jsonb_build_array(a.source_invoice_item_id, a.previous_quantity, a.adjustment_amount, a.new_quantity) ORDER BY a.previous_quantity)
         FROM public.inventory_adjustments a WHERE a.inventory_item_id = _b.id)
        <> '[["be140000-0000-4000-8000-000000000821", 0, 4, 4], ["be140000-0000-4000-8000-000000000823", 4, 1, 5]]'::jsonb THEN
    RAISE EXCEPTION 'Check 4 failed: the receipt was not attributed to B: %', to_jsonb(_b);
  END IF;
END
$posting_check_4$;

-- Check 5: no vendor mapping, product, or vendor changed. SKU-1 still maps to A.
-- Check 6: every inventory adjustment and price observation that existed before is unchanged.
DO $posting_check_5_6$
DECLARE
  _before jsonb := (SELECT value FROM posting_snapshots WHERE name = 'before_rematch_post');
  _after jsonb := (SELECT value FROM posting_snapshots WHERE name = 'after_rematch_post');
  _key text;
BEGIN
  FOREACH _key IN ARRAY ARRAY['mappings', 'products', 'vendors'] LOOP
    IF _after->_key IS DISTINCT FROM _before->_key THEN
      RAISE EXCEPTION 'Check 5 failed: posting changed %', _key;
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM public.vendor_products WHERE vendor_sku = 'SKU-1' AND product_id = pg_temp.product_a()
                 AND catalog_vendor_product_id = 'be140000-0000-4000-8000-000000000231' AND active)
     OR (SELECT count(*) FROM public.vendor_products WHERE organization_id = 'be140000-0000-4000-8000-000000000101'
         AND public.normalize_catalog_sku_match_key(vendor_sku) = 'SKU1') <> 1 THEN
    RAISE EXCEPTION 'Check 5 failed: SKU-1 no longer maps only to A';
  END IF;
  FOREACH _key IN ARRAY ARRAY['adjustments', 'prices'] LOOP
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(_before->_key) old WHERE NOT (_after->_key) @> jsonb_build_array(old)) THEN
      RAISE EXCEPTION 'Check 6 failed: an existing row in % changed', _key;
    END IF;
    IF jsonb_array_length(_after->_key) <> jsonb_array_length(_before->_key) + 4 THEN
      RAISE EXCEPTION 'Check 6 failed: % should gain exactly one row per posted line', _key;
    END IF;
  END LOOP;
END
$posting_check_5_6$;

-- Check 7: posting again is a no-op.
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be140000-0000-4000-8000-000000000001', true);
INSERT INTO posting_snapshots VALUES ('repeat', public.post_reviewed_invoice('be140000-0000-4000-8000-000000000101', 'be140000-0000-4000-8000-000000000602'));
RESET ROLE;
DO $posting_check_7$
BEGIN
  IF ((SELECT value FROM posting_snapshots WHERE name = 'repeat')->>'alreadyCompleted')::boolean IS NOT TRUE
     OR pg_temp.posting_state() IS DISTINCT FROM (SELECT value FROM posting_snapshots WHERE name = 'after_rematch_post') THEN
    RAISE EXCEPTION 'Check 7 failed: posting a completed invoice again changed something';
  END IF;
END
$posting_check_7$;

-- Check 8: the same SKU from another vendor is a different thing entirely. It labels that
-- vendor's item, and no Henry Schein mapping or item is involved.
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be140000-0000-4000-8000-000000000001', true);
SELECT public.confirm_invoice_item_product('be140000-0000-4000-8000-000000000101', 'be140000-0000-4000-8000-000000000603',
  'be140000-0000-4000-8000-000000000831', 'be140000-0000-4000-8000-000000000403', true);
SELECT public.post_reviewed_invoice('be140000-0000-4000-8000-000000000101', 'be140000-0000-4000-8000-000000000603');
RESET ROLE;
DO $posting_check_8$
DECLARE _c public.inventory_items := pg_temp.posting_item('be140000-0000-4000-8000-000000000403');
BEGIN
  IF _c.sku IS DISTINCT FROM 'SKU-1' OR _c.vendor_name IS DISTINCT FROM 'Medline' OR _c.quantity IS DISTINCT FROM 1
     OR (pg_temp.posting_item(pg_temp.product_a())).quantity <> 8
     OR (SELECT count(*) FROM public.vendor_products WHERE vendor_id = 'be140000-0000-4000-8000-000000000302' AND vendor_sku = 'SKU-1' AND product_id = 'be140000-0000-4000-8000-000000000403') <> 1
     OR (SELECT count(*) FROM public.vendor_products WHERE vendor_id = 'be140000-0000-4000-8000-000000000301' AND product_id = 'be140000-0000-4000-8000-000000000403') <> 0
     OR (SELECT count(*) FROM public.inventory_price_history WHERE product_id = 'be140000-0000-4000-8000-000000000403' AND vendor_id <> 'be140000-0000-4000-8000-000000000302') <> 0 THEN
    RAISE EXCEPTION 'Check 8 failed: vendors are not kept apart: %', to_jsonb(_c);
  END IF;
END
$posting_check_8$;

-- Checks 9 and 10: the Phase 6C.1 posting protections are intact. An unresolved line, and a
-- reviewed mapping that names a different product than the line, are refused with no writes.
UPDATE public.invoice_items SET product_id = 'be140000-0000-4000-8000-000000000402',
  vendor_product_id = (SELECT id FROM public.vendor_products WHERE catalog_vendor_product_id = 'be140000-0000-4000-8000-000000000231' AND organization_id = 'be140000-0000-4000-8000-000000000101')
WHERE id = 'be140000-0000-4000-8000-000000000851';
INSERT INTO posting_snapshots VALUES ('before_refusals', pg_temp.posting_state());
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be140000-0000-4000-8000-000000000001', true);
SELECT pg_temp.posting_expect_error(
  $$SELECT public.post_reviewed_invoice('be140000-0000-4000-8000-000000000101', 'be140000-0000-4000-8000-000000000604')$$,
  'Match or create a product for every invoice line before approval (1 unresolved)');
SELECT pg_temp.posting_expect_error(
  $$SELECT public.post_reviewed_invoice('be140000-0000-4000-8000-000000000101', 'be140000-0000-4000-8000-000000000605')$$,
  'A selected vendor product maps to a different product than the invoice line');
RESET ROLE;
DO $posting_check_9_10$
BEGIN
  IF pg_temp.posting_state() IS DISTINCT FROM (SELECT value FROM posting_snapshots WHERE name = 'before_refusals') THEN
    RAISE EXCEPTION 'Checks 9-10 failed: a refused posting left writes behind';
  END IF;
END
$posting_check_9_10$;

-- Check 11: price history lands on the product each line was reviewed as, with the line's
-- own mapping (none for the re-matched lines), and adjustments on that product's item.
DO $posting_check_11$
DECLARE _wrong jsonb;
BEGIN
  SELECT jsonb_agg(jsonb_build_object('line', line.id, 'price', to_jsonb(price), 'item', adjustment.inventory_item_id)) INTO _wrong
  FROM public.invoice_items line
  LEFT JOIN public.inventory_price_history price ON price.invoice_item_id = line.id
  LEFT JOIN public.inventory_adjustments adjustment ON adjustment.source_invoice_item_id = line.id
  LEFT JOIN public.inventory_items item ON item.id = adjustment.inventory_item_id
  WHERE line.invoice_id = 'be140000-0000-4000-8000-000000000702'
    AND (price.product_id IS DISTINCT FROM line.product_id
      OR price.vendor_product_id IS DISTINCT FROM line.vendor_product_id
      OR price.vendor_id <> 'be140000-0000-4000-8000-000000000301'
      OR price.quantity <> line.quantity OR price.unit_price <> line.unit_price
      OR item.product_id IS DISTINCT FROM line.product_id
      OR adjustment.adjustment_amount <> line.quantity);
  IF _wrong IS NOT NULL
     OR (SELECT count(*) FROM public.inventory_price_history WHERE invoice_id = 'be140000-0000-4000-8000-000000000702' AND product_id = 'be140000-0000-4000-8000-000000000402' AND vendor_product_id IS NULL) <> 2
     OR (SELECT count(*) FROM public.inventory_price_history WHERE invoice_id = 'be140000-0000-4000-8000-000000000702' AND product_id = pg_temp.product_a() AND vendor_product_id IS NOT NULL) <> 1 THEN
    RAISE EXCEPTION 'Check 11 failed: price history or adjustments on the wrong identity: %', _wrong;
  END IF;
END
$posting_check_11$;

-- Check 12: a product that already has inventory gets no second item, even when the line
-- prints a SKU that labels another product's item. Its own SKU label is kept.
DO $posting_check_12$
DECLARE _d public.inventory_items := pg_temp.posting_item('be140000-0000-4000-8000-000000000404');
BEGIN
  IF _d.quantity IS DISTINCT FROM 5 OR _d.sku IS DISTINCT FROM 'D-OLD'
     OR (SELECT count(*) FROM public.inventory_items WHERE organization_id = 'be140000-0000-4000-8000-000000000101') <> 4
     OR EXISTS (SELECT 1 FROM public.inventory_items WHERE organization_id = 'be140000-0000-4000-8000-000000000101' GROUP BY product_id HAVING count(*) > 1)
     OR EXISTS (SELECT 1 FROM public.inventory_items WHERE organization_id = 'be140000-0000-4000-8000-000000000101' AND sku IS NOT NULL GROUP BY lower(vendor_name), lower(sku) HAVING count(*) > 1) THEN
    RAISE EXCEPTION 'Check 12 failed: duplicate or relabelled inventory: %', to_jsonb(_d);
  END IF;
END
$posting_check_12$;

SELECT 12 AS checks_passed, 0 AS checks_failed;

ROLLBACK;
