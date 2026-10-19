-- Catalog vendor management rollback-only behavioral verification.
-- Run after 20261019120000_catalog_vendor_management.sql. All data rolls back.
--
-- Fixture: organization A's "Henry Schein" vendor starts unlinked even though the global
-- catalog has a vendor of exactly that name (the production case that motivated this).

BEGIN;

CREATE FUNCTION pg_temp.cvm_expect_error(_statement text, _expected text)
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

CREATE FUNCTION pg_temp.cvm_assert(_condition boolean, _message text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF _condition IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Assertion failed: %', _message;
  END IF;
END;
$$;

-- Everything a link or coverage read must never change. Organization vendor rows are
-- excluded (linking is the one intended write) and checked separately.
CREATE FUNCTION pg_temp.cvm_side_effects()
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT jsonb_build_object(
    'catalogVendors', (SELECT jsonb_agg(to_jsonb(v) ORDER BY v.id) FROM public.catalog_vendors v),
    'catalogProducts', (SELECT jsonb_agg(to_jsonb(p) ORDER BY p.id) FROM public.catalog_products p),
    'catalogListings', (SELECT jsonb_agg(to_jsonb(l) ORDER BY l.id) FROM public.catalog_vendor_products l),
    'products', (SELECT jsonb_agg(to_jsonb(p) ORDER BY p.id) FROM public.products p WHERE p.id::text LIKE 'c7d00000-%'),
    'vendorProducts', (SELECT jsonb_agg(to_jsonb(m) ORDER BY m.id) FROM public.vendor_products m WHERE m.id::text LIKE 'c7d00000-%'),
    'invoices', (SELECT jsonb_agg(to_jsonb(i) ORDER BY i.id) FROM public.invoices i WHERE i.id::text LIKE 'c7d00000-%'),
    'invoiceItems', (SELECT jsonb_agg(to_jsonb(i) ORDER BY i.id) FROM public.invoice_items i WHERE i.id::text LIKE 'c7d00000-%'),
    'inventory', (SELECT jsonb_agg(to_jsonb(i) ORDER BY i.id) FROM public.inventory_items i WHERE i.id::text LIKE 'c7d00000-%'),
    'priceHistory', (SELECT jsonb_agg(to_jsonb(h) ORDER BY h.id) FROM public.inventory_price_history h WHERE h.organization_id::text LIKE 'c7d00000-%')
  )
$$;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
VALUES
  ('c7d00000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'cvm-owner@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('c7d00000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'cvm-admin@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('c7d00000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'cvm-staff@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('c7d00000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'cvm-other-owner@example.invalid', '', now(), '{}', '{}', now(), now());

INSERT INTO public.organizations (id, name, created_by)
VALUES
  ('c7d00000-0000-4000-8000-000000000101', 'Catalog Vendor Athletics', 'c7d00000-0000-4000-8000-000000000001'),
  ('c7d00000-0000-4000-8000-000000000102', 'Catalog Vendor Other Athletics', 'c7d00000-0000-4000-8000-000000000004');

INSERT INTO public.organization_memberships (id, organization_id, user_id, role, active)
VALUES
  ('c7d00000-0000-4000-8000-000000000111', 'c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000001', 'owner', true),
  ('c7d00000-0000-4000-8000-000000000112', 'c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000002', 'admin', true),
  ('c7d00000-0000-4000-8000-000000000113', 'c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000003', 'staff', true),
  ('c7d00000-0000-4000-8000-000000000114', 'c7d00000-0000-4000-8000-000000000102', 'c7d00000-0000-4000-8000-000000000004', 'owner', true);

-- Global catalog. "Henry Schein" deliberately has the same normalized name as the
-- organization vendor, so any name-based inference would be visible.
INSERT INTO public.catalog_vendors (id, name, normalized_name, active)
VALUES
  ('c7d00000-0000-4000-8000-000000000201', 'Henry Schein', 'placeholder', true),
  ('c7d00000-0000-4000-8000-000000000202', 'CVM Medline', 'placeholder', true),
  ('c7d00000-0000-4000-8000-000000000203', 'CVM Retired Vendor', 'placeholder', false),
  -- Same normalized name as organization A's "Medline", which is linked to CVM Medline.
  ('c7d00000-0000-4000-8000-000000000204', 'Medline', 'placeholder', true),
  -- No organization vendor has this name.
  ('c7d00000-0000-4000-8000-000000000205', 'CVM Brand New Supply', 'placeholder', true);

INSERT INTO public.catalog_products (id, name, manufacturer, active, verification_status)
VALUES
  ('c7d00000-0000-4000-8000-000000000211', 'Ammex Black PF Nitrile Gloves Medium', 'Ammex', true, 'verified'),
  ('c7d00000-0000-4000-8000-000000000212', 'Sharps Container Sliding Lid 1qt Red', NULL, true, 'verified'),
  ('c7d00000-0000-4000-8000-000000000213', 'Collision Product One', NULL, true, 'verified'),
  ('c7d00000-0000-4000-8000-000000000214', 'Collision Product Two', NULL, true, 'verified'),
  ('c7d00000-0000-4000-8000-000000000215', 'Discontinued Listing Product', NULL, true, 'verified'),
  ('c7d00000-0000-4000-8000-000000000216', 'CVM Adoptable Tape', NULL, true, 'verified'),
  ('c7d00000-0000-4000-8000-000000000217', 'Medline Only Product', NULL, true, 'verified'),
  ('c7d00000-0000-4000-8000-000000000218', 'Rejected Listing Product', NULL, true, 'rejected'),
  ('c7d00000-0000-4000-8000-000000000219', 'Medline Namesake Product', NULL, true, 'verified'),
  ('c7d00000-0000-4000-8000-000000000220', 'Brand New Supply Product', NULL, true, 'verified');

INSERT INTO public.catalog_vendor_products (
  id, catalog_vendor_id, catalog_product_id, vendor_sku, normalized_vendor_sku,
  package_status, active, discontinued, verification_status
)
VALUES
  ('c7d00000-0000-4000-8000-000000000221', 'c7d00000-0000-4000-8000-000000000201', 'c7d00000-0000-4000-8000-000000000211', '398-0143', 'x', 'unknown', true, false, 'verified'),
  ('c7d00000-0000-4000-8000-000000000222', 'c7d00000-0000-4000-8000-000000000201', 'c7d00000-0000-4000-8000-000000000212', '112-7149', 'x', 'unknown', true, false, 'verified'),
  ('c7d00000-0000-4000-8000-000000000223', 'c7d00000-0000-4000-8000-000000000201', 'c7d00000-0000-4000-8000-000000000213', '555-1234', 'x', 'unknown', true, false, 'verified'),
  ('c7d00000-0000-4000-8000-000000000224', 'c7d00000-0000-4000-8000-000000000201', 'c7d00000-0000-4000-8000-000000000214', '5551-234', 'x', 'unknown', true, false, 'verified'),
  ('c7d00000-0000-4000-8000-000000000225', 'c7d00000-0000-4000-8000-000000000201', 'c7d00000-0000-4000-8000-000000000215', '777-0002', 'x', 'unknown', false, true, 'verified'),
  ('c7d00000-0000-4000-8000-000000000226', 'c7d00000-0000-4000-8000-000000000201', 'c7d00000-0000-4000-8000-000000000216', 'ADOPT-1', 'x', 'unknown', true, false, 'verified'),
  ('c7d00000-0000-4000-8000-000000000227', 'c7d00000-0000-4000-8000-000000000202', 'c7d00000-0000-4000-8000-000000000217', 'ONLY-ML', 'x', 'unknown', true, false, 'verified'),
  ('c7d00000-0000-4000-8000-000000000228', 'c7d00000-0000-4000-8000-000000000201', 'c7d00000-0000-4000-8000-000000000218', 'REJ-9', 'x', 'unknown', true, false, 'rejected'),
  ('c7d00000-0000-4000-8000-000000000229', 'c7d00000-0000-4000-8000-000000000204', 'c7d00000-0000-4000-8000-000000000219', 'MED-1', 'x', 'unknown', true, false, 'verified'),
  ('c7d00000-0000-4000-8000-000000000230', 'c7d00000-0000-4000-8000-000000000205', 'c7d00000-0000-4000-8000-000000000220', 'NEW-1', 'x', 'unknown', true, false, 'verified');

INSERT INTO public.vendors (id, organization_id, name, normalized_name, active, catalog_vendor_id)
VALUES
  ('c7d00000-0000-4000-8000-000000000301', 'c7d00000-0000-4000-8000-000000000101', 'Henry Schein', 'x', true, NULL),
  ('c7d00000-0000-4000-8000-000000000302', 'c7d00000-0000-4000-8000-000000000101', 'Medline', 'x', true, 'c7d00000-0000-4000-8000-000000000202'),
  ('c7d00000-0000-4000-8000-000000000303', 'c7d00000-0000-4000-8000-000000000101', 'Local Supply', 'x', true, NULL),
  ('c7d00000-0000-4000-8000-000000000304', 'c7d00000-0000-4000-8000-000000000102', 'Henry Schein', 'x', true, NULL);

INSERT INTO public.products (id, organization_id, name, normalized_name, manufacturer, approved, active, staff_requestable)
VALUES
  ('c7d00000-0000-4000-8000-000000000401', 'c7d00000-0000-4000-8000-000000000101', 'Org Gloves', 'x', 'Ammex', true, true, true),
  ('c7d00000-0000-4000-8000-000000000402', 'c7d00000-0000-4000-8000-000000000101', 'Org Sharps', 'x', NULL, true, true, true),
  ('c7d00000-0000-4000-8000-000000000403', 'c7d00000-0000-4000-8000-000000000101', 'Org Collision', 'x', NULL, true, true, true),
  ('c7d00000-0000-4000-8000-000000000404', 'c7d00000-0000-4000-8000-000000000101', 'Org Discontinued', 'x', NULL, true, true, true),
  ('c7d00000-0000-4000-8000-000000000405', 'c7d00000-0000-4000-8000-000000000101', 'Org Only Prewrap', 'x', 'Mueller', true, true, true),
  ('c7d00000-0000-4000-8000-000000000406', 'c7d00000-0000-4000-8000-000000000101', 'Org Medline Lookalike', 'x', NULL, true, true, true),
  ('c7d00000-0000-4000-8000-000000000407', 'c7d00000-0000-4000-8000-000000000101', 'Org Forgotten', 'x', NULL, true, true, true),
  ('c7d00000-0000-4000-8000-000000000408', 'c7d00000-0000-4000-8000-000000000101', 'Org Rejected', 'x', NULL, true, true, true),
  ('c7d00000-0000-4000-8000-000000000409', 'c7d00000-0000-4000-8000-000000000102', 'Other Org Secret Product', 'x', NULL, true, true, true);

INSERT INTO public.vendor_products (id, organization_id, vendor_id, product_id, vendor_sku, package_size, unit_of_measure, active)
VALUES
  ('c7d00000-0000-4000-8000-000000000501', 'c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000301', 'c7d00000-0000-4000-8000-000000000401', '398-0143', '100/Bx', 'BX', true),
  ('c7d00000-0000-4000-8000-000000000502', 'c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000301', 'c7d00000-0000-4000-8000-000000000402', '1127149', NULL, 'EA', true),
  ('c7d00000-0000-4000-8000-000000000503', 'c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000301', 'c7d00000-0000-4000-8000-000000000403', '5551234', NULL, NULL, true),
  ('c7d00000-0000-4000-8000-000000000504', 'c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000301', 'c7d00000-0000-4000-8000-000000000404', '777-0002', NULL, NULL, true),
  ('c7d00000-0000-4000-8000-000000000505', 'c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000301', 'c7d00000-0000-4000-8000-000000000405', '1439386', '48 rolls', 'CS', true),
  -- Listed by CVM Medline only: must not count as Henry Schein coverage.
  ('c7d00000-0000-4000-8000-000000000506', 'c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000301', 'c7d00000-0000-4000-8000-000000000406', 'ONLY-ML', NULL, NULL, true),
  ('c7d00000-0000-4000-8000-000000000507', 'c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000301', 'c7d00000-0000-4000-8000-000000000407', '2677976', NULL, NULL, false),
  ('c7d00000-0000-4000-8000-000000000508', 'c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000301', 'c7d00000-0000-4000-8000-000000000408', 'REJ-9', NULL, NULL, true),
  ('c7d00000-0000-4000-8000-000000000509', 'c7d00000-0000-4000-8000-000000000102', 'c7d00000-0000-4000-8000-000000000304', 'c7d00000-0000-4000-8000-000000000409', 'B-SECRET-1', NULL, NULL, true);

-- 1,005 more organization B mappings: the row list is capped at 1,000, the counts are not.
INSERT INTO public.vendor_products (organization_id, vendor_id, product_id, vendor_sku, active)
SELECT 'c7d00000-0000-4000-8000-000000000102', 'c7d00000-0000-4000-8000-000000000304',
  'c7d00000-0000-4000-8000-000000000409', 'B-BULK-' || lpad(n::text, 4, '0'), true
FROM generate_series(1, 1005) n;

-- Invoice, line, inventory and price history that linking and coverage must leave alone.
INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type)
VALUES ('c7d00000-0000-4000-8000-000000000601', 'c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000001', 'c7d00000-0000-4000-8000-000000000101/cvm.pdf', 'cvm.pdf', 1024, 'application/pdf');
INSERT INTO public.invoices (id, organization_id, source_file_id, vendor_id, vendor_name, invoice_number, invoice_date, processing_status)
VALUES ('c7d00000-0000-4000-8000-000000000701', 'c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000601', 'c7d00000-0000-4000-8000-000000000301', 'Henry Schein', 'HS-CVM-1', '2026-10-01', 'review_required');
INSERT INTO public.invoice_items (id, invoice_id, organization_id, line_number, sku, description, quantity, unit_of_measure, unit_price, total_price)
VALUES
  ('c7d00000-0000-4000-8000-000000000801', 'c7d00000-0000-4000-8000-000000000701', 'c7d00000-0000-4000-8000-000000000101', 1, '1439386', 'Prewrap 2.75in', 2, 'CS', 41.5, 83),
  ('c7d00000-0000-4000-8000-000000000802', 'c7d00000-0000-4000-8000-000000000701', 'c7d00000-0000-4000-8000-000000000101', 2, '3980143', 'Ammex gloves', 1, 'BX', 9.5, 9.5);
INSERT INTO public.inventory_items (id, organization_id, name, unit, quantity, product_id)
VALUES ('c7d00000-0000-4000-8000-000000000901', 'c7d00000-0000-4000-8000-000000000101', 'Org Only Prewrap', 'CS', 7, 'c7d00000-0000-4000-8000-000000000405');
INSERT INTO public.inventory_price_history (organization_id, product_id, vendor_id, invoice_id, invoice_item_id, purchase_date, quantity, unit_price)
VALUES ('c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000405', 'c7d00000-0000-4000-8000-000000000301', 'c7d00000-0000-4000-8000-000000000701', 'c7d00000-0000-4000-8000-000000000801', '2026-10-01', 2, 41.5);

CREATE TEMP TABLE cvm_state (name text PRIMARY KEY, value jsonb);
GRANT ALL ON cvm_state TO authenticated;
INSERT INTO cvm_state VALUES ('before', pg_temp.cvm_side_effects());
INSERT INTO cvm_state
SELECT 'hsVersion', to_jsonb(updated_at) FROM public.vendors WHERE id = 'c7d00000-0000-4000-8000-000000000301';
INSERT INTO cvm_state
SELECT 'medlineVersion', to_jsonb(updated_at) FROM public.vendors WHERE id = 'c7d00000-0000-4000-8000-000000000302';
INSERT INTO cvm_state
SELECT 'localVersion', to_jsonb(updated_at) FROM public.vendors WHERE id = 'c7d00000-0000-4000-8000-000000000303';
INSERT INTO cvm_state
SELECT 'otherVersion', to_jsonb(updated_at) FROM public.vendors WHERE id = 'c7d00000-0000-4000-8000-000000000304';

CREATE FUNCTION pg_temp.cvm_version(_name text)
RETURNS text
LANGUAGE sql
AS $$ SELECT quote_literal(value #>> '{}') || '::timestamptz' FROM cvm_state WHERE name = _name $$;

SET LOCAL ROLE authenticated;

-- 1. Listing: an admin reads organization vendors and their links directly under RLS.
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'c7d00000-0000-4000-8000-000000000002', true);
SELECT pg_temp.cvm_assert(
  (SELECT jsonb_object_agg(vendor.name, catalog_vendor.name)
   FROM public.vendors vendor
   LEFT JOIN public.catalog_vendors catalog_vendor ON catalog_vendor.id = vendor.catalog_vendor_id
   WHERE vendor.organization_id = 'c7d00000-0000-4000-8000-000000000101')
  = '{"Henry Schein": null, "Medline": "CVM Medline", "Local Supply": null}'::jsonb,
  'admin sees organization A vendors with their catalog links'
);
SELECT pg_temp.cvm_assert(
  NOT EXISTS (SELECT 1 FROM public.vendors WHERE organization_id = 'c7d00000-0000-4000-8000-000000000102'),
  'organization A admin cannot read organization B vendors'
);

-- 8. No implicit name link: an unlinked vendor stays unlinked even though a catalog vendor
-- has exactly its name, and a coverage read reports "not linked" without linking it.
SELECT pg_temp.cvm_assert(
  (public.get_organization_vendor_catalog_coverage('c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000301'))
  = jsonb_build_object('vendorId', 'c7d00000-0000-4000-8000-000000000301', 'vendorName', 'Henry Schein', 'linked', false,
      'catalogVendor', NULL, 'summary', NULL, 'rows', '[]'::jsonb, 'truncated', false),
  'unlinked vendor coverage is empty and says not linked'
);
SELECT pg_temp.cvm_assert(
  (SELECT catalog_vendor_id IS NULL FROM public.vendors WHERE id = 'c7d00000-0000-4000-8000-000000000301'),
  'same-name catalog vendor was not linked implicitly'
);

-- Adoption never links by name. Organization A's unlinked "Henry Schein" has exactly the
-- catalog vendor's normalized name; adopting one of that catalog vendor's listings is
-- refused until the vendor is linked explicitly, and writes nothing.
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'c7d00000-0000-4000-8000-000000000001', true);
SELECT pg_temp.cvm_expect_error(
  $$SELECT public.adopt_catalog_vendor_product('c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000226')$$,
  'link it in Catalog Vendors before adopting'
);
-- The listing's SKU is not mapped yet, so this also covers the "no mapping yet" case.
SELECT pg_temp.cvm_expect_error(
  $$SELECT public.adopt_catalog_vendor_product('c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000221')$$,
  'link it in Catalog Vendors before adopting'
);
SELECT pg_temp.cvm_assert(
  (SELECT catalog_vendor_id IS NULL FROM public.vendors WHERE id = 'c7d00000-0000-4000-8000-000000000301')
  AND (SELECT count(*) FROM public.vendors WHERE organization_id = 'c7d00000-0000-4000-8000-000000000101') = 3
  AND (SELECT count(*) FROM public.products WHERE organization_id = 'c7d00000-0000-4000-8000-000000000101') = 8
  AND (SELECT count(*) FROM public.vendor_products WHERE organization_id = 'c7d00000-0000-4000-8000-000000000101') = 8
  AND NOT EXISTS (SELECT 1 FROM public.vendor_products WHERE organization_id = 'c7d00000-0000-4000-8000-000000000101' AND catalog_vendor_product_id IS NOT NULL),
  'refused adoption left vendor link, vendors, products, and mappings unchanged'
);

-- A same-name vendor linked to a different catalog vendor is refused and not repointed.
SELECT pg_temp.cvm_expect_error(
  $$SELECT public.adopt_catalog_vendor_product('c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000229')$$,
  'links to a different catalog vendor'
);
SELECT pg_temp.cvm_assert(
  (SELECT catalog_vendor_id = 'c7d00000-0000-4000-8000-000000000202' FROM public.vendors WHERE id = 'c7d00000-0000-4000-8000-000000000302'),
  'vendor linked elsewhere keeps its link'
);

-- Another organization's owner cannot adopt into organization A.
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'c7d00000-0000-4000-8000-000000000004', true);
SELECT pg_temp.cvm_expect_error(
  $$SELECT public.adopt_catalog_vendor_product('c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000230')$$,
  'Only organization owners and admins can adopt catalog products'
);

-- 4. Unauthorized role: staff can neither link nor read coverage.
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'c7d00000-0000-4000-8000-000000000003', true);
SELECT pg_temp.cvm_expect_error(
  format('SELECT public.link_organization_vendor_to_catalog_vendor(%L, %L, %L, %s)',
    'c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000301',
    'c7d00000-0000-4000-8000-000000000201', pg_temp.cvm_version('hsVersion')),
  'Only organization owners and admins can link catalog vendors'
);
SELECT pg_temp.cvm_expect_error(
  $$SELECT public.get_organization_vendor_catalog_coverage('c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000301')$$,
  'Only organization owners and admins can review catalog coverage'
);

-- 3. Cross-organization: organization B's owner cannot act in organization A, and cannot
-- reach an organization A vendor through organization B's id either.
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'c7d00000-0000-4000-8000-000000000004', true);
SELECT pg_temp.cvm_expect_error(
  format('SELECT public.link_organization_vendor_to_catalog_vendor(%L, %L, %L, %s)',
    'c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000301',
    'c7d00000-0000-4000-8000-000000000201', pg_temp.cvm_version('hsVersion')),
  'Only organization owners and admins can link catalog vendors'
);
SELECT pg_temp.cvm_expect_error(
  format('SELECT public.link_organization_vendor_to_catalog_vendor(%L, %L, %L, %s)',
    'c7d00000-0000-4000-8000-000000000102', 'c7d00000-0000-4000-8000-000000000301',
    'c7d00000-0000-4000-8000-000000000201', pg_temp.cvm_version('hsVersion')),
  'Organization vendor not found'
);
SELECT pg_temp.cvm_expect_error(
  $$SELECT public.get_organization_vendor_catalog_coverage('c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000301')$$,
  'Only organization owners and admins can review catalog coverage'
);
SELECT pg_temp.cvm_expect_error(
  $$SELECT public.get_organization_vendor_catalog_coverage('c7d00000-0000-4000-8000-000000000102', 'c7d00000-0000-4000-8000-000000000301')$$,
  'Organization vendor not found'
);

-- Direct API writes cannot set or change a link, on insert or update, for any vendor.
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'c7d00000-0000-4000-8000-000000000001', true);
SELECT pg_temp.cvm_expect_error(
  $$UPDATE public.vendors SET catalog_vendor_id = 'c7d00000-0000-4000-8000-000000000201' WHERE id = 'c7d00000-0000-4000-8000-000000000301'$$,
  'Catalog vendor links can only be set through catalog vendor management'
);
SELECT pg_temp.cvm_expect_error(
  $$UPDATE public.vendors SET catalog_vendor_id = NULL WHERE id = 'c7d00000-0000-4000-8000-000000000302'$$,
  'Catalog vendor links can only be set through catalog vendor management'
);
SELECT pg_temp.cvm_expect_error(
  $$INSERT INTO public.vendors (organization_id, name, normalized_name, catalog_vendor_id)
    VALUES ('c7d00000-0000-4000-8000-000000000101', 'Sneaky Vendor', 'x', 'c7d00000-0000-4000-8000-000000000203')$$,
  'Catalog vendor links can only be set through catalog vendor management'
);

-- 5. Nonexistent and inactive catalog vendors.
SELECT pg_temp.cvm_expect_error(
  format('SELECT public.link_organization_vendor_to_catalog_vendor(%L, %L, %L, %s)',
    'c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000301',
    'c7d00000-0000-4000-8000-0000000002ff', pg_temp.cvm_version('hsVersion')),
  'Catalog vendor not found'
);
SELECT pg_temp.cvm_expect_error(
  format('SELECT public.link_organization_vendor_to_catalog_vendor(%L, %L, %L, %s)',
    'c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000301',
    'c7d00000-0000-4000-8000-000000000203', pg_temp.cvm_version('hsVersion')),
  'Catalog vendor is inactive'
);
SELECT pg_temp.cvm_expect_error(
  format('SELECT public.link_organization_vendor_to_catalog_vendor(%L, %L, %L, %s)',
    'c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-0000000003ff',
    'c7d00000-0000-4000-8000-000000000201', pg_temp.cvm_version('hsVersion')),
  'Organization vendor not found'
);

-- 7. Stale write: a version from before an unrelated edit is refused.
SELECT pg_temp.cvm_expect_error(
  format('SELECT public.link_organization_vendor_to_catalog_vendor(%L, %L, %L, %s)',
    'c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000301',
    'c7d00000-0000-4000-8000-000000000201', quote_literal('2001-01-01T00:00:00Z') || '::timestamptz'),
  'Organization vendor changed since it was loaded'
);

-- Plain vendor edits through the API still work. (Inside this one transaction now() is
-- fixed, so the edit cannot advance updated_at here; the stale token above covers that.)
UPDATE public.vendors SET notes = 'Account rep: J. Doe' WHERE id = 'c7d00000-0000-4000-8000-000000000303';
SELECT pg_temp.cvm_assert(
  (SELECT notes = 'Account rep: J. Doe' AND catalog_vendor_id IS NULL FROM public.vendors WHERE id = 'c7d00000-0000-4000-8000-000000000303'),
  'non-link vendor edits through the API still work'
);

-- 2. NULL -> catalog vendor by an admin succeeds and changes only the link.
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'c7d00000-0000-4000-8000-000000000002', true);
INSERT INTO cvm_state
SELECT 'link', public.link_organization_vendor_to_catalog_vendor(
  'c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000301',
  'c7d00000-0000-4000-8000-000000000201', (SELECT (value #>> '{}')::timestamptz FROM cvm_state WHERE name = 'hsVersion'));
SELECT pg_temp.cvm_assert(
  (SELECT value - 'updatedAt' FROM cvm_state WHERE name = 'link') = jsonb_build_object(
    'organizationId', 'c7d00000-0000-4000-8000-000000000101',
    'vendorId', 'c7d00000-0000-4000-8000-000000000301',
    'catalogVendorId', 'c7d00000-0000-4000-8000-000000000201',
    'catalogVendorName', 'Henry Schein',
    'alreadyLinked', false),
  'link result describes the new link'
);
SELECT pg_temp.cvm_assert(
  (SELECT catalog_vendor_id = 'c7d00000-0000-4000-8000-000000000201' AND name = 'Henry Schein' AND active
   FROM public.vendors WHERE id = 'c7d00000-0000-4000-8000-000000000301'),
  'vendor is linked and otherwise unchanged'
);

-- Repeating the same link is an idempotent no-op, even with the old version.
SELECT pg_temp.cvm_assert(
  (public.link_organization_vendor_to_catalog_vendor(
    'c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000301',
    'c7d00000-0000-4000-8000-000000000201', (SELECT (value #>> '{}')::timestamptz FROM cvm_state WHERE name = 'hsVersion'))
  ->> 'alreadyLinked')::boolean,
  'repeat link reports alreadyLinked'
);

-- 6. Existing links cannot be repointed through the RPC.
SELECT pg_temp.cvm_expect_error(
  format('SELECT public.link_organization_vendor_to_catalog_vendor(%L, %L, %L, %L::timestamptz)',
    'c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000301',
    'c7d00000-0000-4000-8000-000000000202', (SELECT value ->> 'updatedAt' FROM cvm_state WHERE name = 'link')),
  'Organization vendor is already linked to a different catalog vendor'
);
SELECT pg_temp.cvm_expect_error(
  format('SELECT public.link_organization_vendor_to_catalog_vendor(%L, %L, %L, %s)',
    'c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000302',
    'c7d00000-0000-4000-8000-000000000201', pg_temp.cvm_version('medlineVersion')),
  'Organization vendor is already linked to a different catalog vendor'
);

-- One organization vendor per catalog vendor (Phase 5A.5 uniqueness), refused cleanly.
UPDATE cvm_state SET value = (SELECT to_jsonb(updated_at) FROM public.vendors WHERE id = 'c7d00000-0000-4000-8000-000000000303')
WHERE name = 'localVersion';
SELECT pg_temp.cvm_expect_error(
  format('SELECT public.link_organization_vendor_to_catalog_vendor(%L, %L, %L, %s)',
    'c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000303',
    'c7d00000-0000-4000-8000-000000000201', pg_temp.cvm_version('localVersion')),
  'Another organization vendor is already linked to this catalog vendor'
);

-- Organization B links its own vendor to the same catalog vendor independently.
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'c7d00000-0000-4000-8000-000000000004', true);
SELECT pg_temp.cvm_assert(
  NOT (public.link_organization_vendor_to_catalog_vendor(
    'c7d00000-0000-4000-8000-000000000102', 'c7d00000-0000-4000-8000-000000000304',
    'c7d00000-0000-4000-8000-000000000201', (SELECT (value #>> '{}')::timestamptz FROM cvm_state WHERE name = 'otherVersion'))
  ->> 'alreadyLinked')::boolean,
  'organization B links its own vendor'
);

-- Adopt one listing through the existing Phase 5A.5 RPC so a "linked" mapping exists.
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'c7d00000-0000-4000-8000-000000000001', true);
INSERT INTO cvm_state
SELECT 'adoption', public.adopt_catalog_vendor_product('c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000226');
SELECT pg_temp.cvm_assert(
  (SELECT value @> '{"vendorId": "c7d00000-0000-4000-8000-000000000301", "vendorCreated": false, "productCreated": true, "vendorProductCreated": true, "alreadyAdopted": false}'::jsonb
   FROM cvm_state WHERE name = 'adoption'),
  format('explicitly linked vendor adopts under that vendor: %s', (SELECT value FROM cvm_state WHERE name = 'adoption'))
);
SELECT pg_temp.cvm_assert(
  (public.adopt_catalog_vendor_product('c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000226')
   @> jsonb_build_object('alreadyAdopted', true, 'vendorProductId', (SELECT value ->> 'vendorProductId' FROM cvm_state WHERE name = 'adoption'))),
  'repeat adoption is an idempotent no-op'
);

-- With no organization vendor of that name, adoption still creates a new vendor from the
-- catalog vendor itself (Phase 5A.5 behavior, not a name inference about an existing row).
SELECT pg_temp.cvm_assert(
  public.adopt_catalog_vendor_product('c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000230')
  @> '{"vendorCreated": true, "alreadyAdopted": false}'::jsonb,
  'adoption with no same-name vendor reports a created vendor'
);
-- Separate statement: a query cannot see rows written by a function it calls.
SELECT pg_temp.cvm_assert(
  (SELECT count(*) FROM public.vendors
       WHERE organization_id = 'c7d00000-0000-4000-8000-000000000101'
         AND name = 'CVM Brand New Supply' AND catalog_vendor_id = 'c7d00000-0000-4000-8000-000000000205') = 1,
  'adoption with no same-name vendor creates one vendor from the catalog vendor'
);

-- COVERAGE 9-14.
INSERT INTO cvm_state
SELECT 'coverage', public.get_organization_vendor_catalog_coverage('c7d00000-0000-4000-8000-000000000101', 'c7d00000-0000-4000-8000-000000000301');

SELECT pg_temp.cvm_assert(
  (SELECT value -> 'summary' FROM cvm_state WHERE name = 'coverage')
  = '{"mapped": 8, "represented": 6, "notRepresented": 2, "inactiveMappings": 1}'::jsonb,
  format('coverage summary counts active mappings: %s', (SELECT value -> 'summary' FROM cvm_state WHERE name = 'coverage'))
);
SELECT pg_temp.cvm_assert(
  (SELECT value -> 'catalogVendor' FROM cvm_state WHERE name = 'coverage')
  = '{"id": "c7d00000-0000-4000-8000-000000000201", "name": "Henry Schein", "active": true}'::jsonb,
  'coverage is scoped to the linked catalog vendor'
);
SELECT pg_temp.cvm_assert(
  (SELECT jsonb_object_agg(row_value ->> 'vendorSku', row_value ->> 'status')
   FROM cvm_state, jsonb_array_elements(value -> 'rows') row_value WHERE name = 'coverage')
  = '{
      "398-0143": "exact",
      "1127149": "separator_equivalent",
      "5551234": "ambiguous",
      "777-0002": "exact",
      "1439386": "not_cataloged",
      "ONLY-ML": "not_cataloged",
      "2677976": "not_cataloged",
      "REJ-9": "exact",
      "ADOPT-1": "linked"
    }'::jsonb,
  format('coverage statuses: %s', (SELECT jsonb_object_agg(row_value ->> 'vendorSku', row_value ->> 'status')
   FROM cvm_state, jsonb_array_elements(value -> 'rows') row_value WHERE name = 'coverage'))
);
-- Separator-equivalent rows name the listing they match; ambiguous rows name none.
SELECT pg_temp.cvm_assert(
  (SELECT row_value -> 'listing' ->> 'vendorSku' = '112-7149'
   FROM cvm_state, jsonb_array_elements(value -> 'rows') row_value
   WHERE name = 'coverage' AND row_value ->> 'vendorSku' = '1127149'),
  'separator-equivalent mapping names its listing'
);
SELECT pg_temp.cvm_assert(
  (SELECT row_value -> 'listing' = 'null'::jsonb
   FROM cvm_state, jsonb_array_elements(value -> 'rows') row_value
   WHERE name = 'coverage' AND row_value ->> 'vendorSku' = '5551234'),
  'ambiguous mapping names no listing'
);
-- Listing state is reported, not reinterpreted.
SELECT pg_temp.cvm_assert(
  (SELECT row_value -> 'listing' @> '{"vendorSku": "777-0002", "active": false, "discontinued": true}'::jsonb
   FROM cvm_state, jsonb_array_elements(value -> 'rows') row_value
   WHERE name = 'coverage' AND row_value ->> 'vendorSku' = '777-0002'),
  'discontinued listing is reported as discontinued'
);
SELECT pg_temp.cvm_assert(
  (SELECT row_value -> 'listing' ->> 'verificationStatus' = 'rejected'
   FROM cvm_state, jsonb_array_elements(value -> 'rows') row_value
   WHERE name = 'coverage' AND row_value ->> 'vendorSku' = 'REJ-9'),
  'rejected listing is reported as rejected'
);
SELECT pg_temp.cvm_assert(
  (SELECT (row_value ->> 'mappingActive')::boolean = false
   FROM cvm_state, jsonb_array_elements(value -> 'rows') row_value
   WHERE name = 'coverage' AND row_value ->> 'vendorSku' = '2677976'),
  'inactive mapping is listed as inactive'
);
SELECT pg_temp.cvm_assert(
  (SELECT row_value @> '{"productName": "Org Only Prewrap", "manufacturer": "Mueller", "packageSize": "48 rolls", "unitOfMeasure": "CS"}'::jsonb
   FROM cvm_state, jsonb_array_elements(value -> 'rows') row_value
   WHERE name = 'coverage' AND row_value ->> 'vendorSku' = '1439386'),
  'organization-only row carries its local product detail'
);
-- Uncataloged active rows come first.
SELECT pg_temp.cvm_assert(
  (SELECT array_agg(row_value ->> 'status' ORDER BY ordinality)
   FROM cvm_state, jsonb_array_elements(value -> 'rows') WITH ORDINALITY AS r(row_value, ordinality)
   WHERE name = 'coverage') [1:3] = ARRAY['not_cataloged', 'not_cataloged', 'not_cataloged'],
  'uncataloged rows are listed first'
);
SELECT pg_temp.cvm_assert(
  (SELECT row_value ->> 'vendorSku' FROM cvm_state, jsonb_array_elements(value -> 'rows') WITH ORDINALITY AS r(row_value, ordinality)
   WHERE name = 'coverage' AND ordinality = 3) = '2677976',
  'inactive uncataloged rows follow active ones'
);

-- 13. Another organization's mapping never appears, even on the same catalog vendor.
SELECT pg_temp.cvm_assert(
  NOT EXISTS (
    SELECT 1 FROM cvm_state, jsonb_array_elements(value -> 'rows') row_value
    WHERE name = 'coverage' AND (row_value ->> 'vendorSku' = 'B-SECRET-1' OR row_value ->> 'productName' = 'Other Org Secret Product')
  ),
  'organization B mapping is absent from organization A coverage'
);
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'c7d00000-0000-4000-8000-000000000004', true);
INSERT INTO cvm_state
SELECT 'otherCoverage', public.get_organization_vendor_catalog_coverage(
  'c7d00000-0000-4000-8000-000000000102', 'c7d00000-0000-4000-8000-000000000304');
SELECT pg_temp.cvm_assert(
  NOT EXISTS (
    SELECT 1 FROM cvm_state, jsonb_array_elements(value -> 'rows') row_value
    WHERE name = 'otherCoverage' AND row_value ->> 'vendorSku' NOT LIKE 'B-%'
  ),
  'organization B coverage contains only its own mappings'
);
-- Display cap: rows stop at 1,000; summary counts cover all 1,006 mappings.
SELECT pg_temp.cvm_assert(
  (SELECT jsonb_array_length(value -> 'rows') = 1000
      AND (value ->> 'truncated')::boolean
      AND value -> 'summary' = '{"mapped": 1006, "represented": 0, "notRepresented": 1006, "inactiveMappings": 0}'::jsonb
   FROM cvm_state WHERE name = 'otherCoverage'),
  format('row list is capped while counts are complete: %s', (SELECT value -> 'summary' FROM cvm_state WHERE name = 'otherCoverage'))
);

RESET ROLE;

-- Even trusted callers cannot repoint an existing link in one write.
SELECT pg_temp.cvm_expect_error(
  $$UPDATE public.vendors SET catalog_vendor_id = 'c7d00000-0000-4000-8000-000000000202' WHERE id = 'c7d00000-0000-4000-8000-000000000301'$$,
  'An existing catalog vendor link cannot be repointed to a different catalog vendor'
);

-- Nothing outside the intended writes changed: no catalog row, existing product or mapping
-- (the adoption's new rows have generated ids), invoice, line, inventory, or price
-- observation.
SELECT pg_temp.cvm_assert(
  (SELECT value FROM cvm_state WHERE name = 'before') = pg_temp.cvm_side_effects(),
  'catalog, existing products and mappings, invoices, inventory, and price history are untouched'
);
SELECT pg_temp.cvm_assert(
  (SELECT count(*) FROM public.vendor_products
   WHERE organization_id = 'c7d00000-0000-4000-8000-000000000101' AND id::text NOT LIKE 'c7d00000-%') = 2,
  'only the two successful adoptions added mappings'
);
SELECT pg_temp.cvm_assert(
  (SELECT count(*) FROM public.vendors WHERE organization_id = 'c7d00000-0000-4000-8000-000000000101') = 4,
  'only the no-same-name adoption created an organization vendor'
);
SELECT pg_temp.cvm_assert(
  (SELECT catalog_vendor_id IS NULL FROM public.vendors WHERE id = 'c7d00000-0000-4000-8000-000000000303')
  AND (SELECT catalog_vendor_id = 'c7d00000-0000-4000-8000-000000000202' FROM public.vendors WHERE id = 'c7d00000-0000-4000-8000-000000000302'),
  'other vendor links are unchanged'
);

ROLLBACK;
