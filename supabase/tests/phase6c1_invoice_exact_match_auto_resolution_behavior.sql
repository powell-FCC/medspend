-- Phase 6C.1 rollback-only behavioral verification.
-- Run after 20261010120000_phase6c1_invoice_exact_match_auto_resolution.sql. All data rolls back.
--
-- Realistic fixture: a Henry Schein invoice whose SKUs print without separators
-- (3980143, 1127149, 1507581, 1200685) while the verified global catalog stores them as
-- 398-0143, 112-7149, 150-7581, 120-0685.

BEGIN;

CREATE FUNCTION pg_temp.phase6c1_expect_error(_statement text, _expected text)
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

CREATE FUNCTION pg_temp.phase6c1_line(_id uuid)
RETURNS public.invoice_items
LANGUAGE sql
AS $$ SELECT * FROM public.invoice_items WHERE id = _id $$;

CREATE FUNCTION pg_temp.phase6c1_side_effects()
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT jsonb_build_object(
    'inventoryItems', (SELECT count(*) FROM public.inventory_items WHERE organization_id IN ('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000102')),
    'inventoryQuantity', (SELECT coalesce(sum(quantity), 0) FROM public.inventory_items WHERE organization_id IN ('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000102')),
    'inventoryAdjustments', (SELECT count(*) FROM public.inventory_adjustments WHERE organization_id IN ('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000102')),
    'priceHistory', (SELECT count(*) FROM public.inventory_price_history WHERE organization_id IN ('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000102')),
    'requests', (SELECT jsonb_agg(to_jsonb(r) ORDER BY r.id) FROM public.supply_requests r WHERE r.organization_id IN ('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000102')),
    'requestItems', (SELECT jsonb_agg(to_jsonb(i) ORDER BY i.id) FROM public.supply_request_items i WHERE i.organization_id IN ('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000102')),
    'requestUpdates', (SELECT jsonb_agg(to_jsonb(u) ORDER BY u.id) FROM public.supply_request_updates u WHERE u.organization_id IN ('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000102')),
    'commitments', (SELECT jsonb_agg(to_jsonb(c) ORDER BY c.id) FROM public.supply_request_commitments c WHERE c.organization_id IN ('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000102')),
    'commitmentItems', (SELECT jsonb_agg(to_jsonb(c) ORDER BY c.id) FROM public.supply_request_commitment_items c WHERE c.organization_id IN ('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000102')),
    'invoices', (SELECT jsonb_agg(jsonb_build_object('id', id, 'status', processing_status, 'posted', posted_at, 'reviewedBy', reviewed_by) ORDER BY id) FROM public.invoices WHERE organization_id IN ('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000102')),
    'catalog', (SELECT jsonb_agg(to_jsonb(l) - 'updated_at' ORDER BY l.id) FROM public.catalog_vendor_products l WHERE l.id::text LIKE '6c100000-%'),
    'catalogProducts', (SELECT jsonb_agg(to_jsonb(p) - 'updated_at' ORDER BY p.id) FROM public.catalog_products p WHERE p.id::text LIKE '6c100000-%')
  )
$$;

CREATE FUNCTION pg_temp.phase6c1_identity_counts()
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT jsonb_build_object(
    'vendors', (SELECT count(*) FROM public.vendors WHERE organization_id IN ('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000102')),
    'products', (SELECT count(*) FROM public.products WHERE organization_id IN ('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000102')),
    'vendorProducts', (SELECT count(*) FROM public.vendor_products WHERE organization_id IN ('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000102')),
    'catalogProducts', (SELECT count(*) FROM public.catalog_products),
    'catalogListings', (SELECT count(*) FROM public.catalog_vendor_products)
  )
$$;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
VALUES
  ('6c100000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'phase6c1-owner@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('6c100000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'phase6c1-admin@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('6c100000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'phase6c1-staff@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('6c100000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'phase6c1-other-owner@example.invalid', '', now(), '{}', '{}', now(), now());

INSERT INTO public.organizations (id, name, created_by)
VALUES
  ('6c100000-0000-4000-8000-000000000101', 'Phase 6C.1 Athletics', '6c100000-0000-4000-8000-000000000001'),
  ('6c100000-0000-4000-8000-000000000102', 'Phase 6C.1 Other Athletics', '6c100000-0000-4000-8000-000000000004');

INSERT INTO public.organization_memberships (id, organization_id, user_id, role, active)
VALUES
  ('6c100000-0000-4000-8000-000000000111', '6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000001', 'owner', true),
  ('6c100000-0000-4000-8000-000000000112', '6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000002', 'admin', true),
  ('6c100000-0000-4000-8000-000000000113', '6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000003', 'staff', true),
  ('6c100000-0000-4000-8000-000000000114', '6c100000-0000-4000-8000-000000000102', '6c100000-0000-4000-8000-000000000004', 'owner', true);

-- Platform catalog (deterministic test rows; nothing is assumed to exist already).
INSERT INTO public.catalog_vendors (id, name, normalized_name)
VALUES
  ('6c100000-0000-4000-8000-000000000201', 'Phase 6C.1 Henry Schein', 'placeholder'),
  ('6c100000-0000-4000-8000-000000000202', 'Phase 6C.1 Medline', 'placeholder');

INSERT INTO public.catalog_products (id, name, manufacturer, active, verification_status)
VALUES
  ('6c100000-0000-4000-8000-000000000211', 'Ammex Black PF Nitrile Gloves Medium', 'Ammex', true, 'verified'),
  ('6c100000-0000-4000-8000-000000000212', 'Sharps Container Sliding Lid 1qt Red', NULL, true, 'verified'),
  ('6c100000-0000-4000-8000-000000000213', 'Dry Needle Click APS with Guide .30x50mm', NULL, true, 'verified'),
  ('6c100000-0000-4000-8000-000000000214', 'Sponge Nonwoven 4 Ply Sterile 4x4in', NULL, true, 'verified'),
  ('6c100000-0000-4000-8000-000000000215', 'Medline Catalog Only Item', NULL, true, 'verified'),
  ('6c100000-0000-4000-8000-000000000216', 'Collision Product One', NULL, true, 'verified'),
  ('6c100000-0000-4000-8000-000000000217', 'Collision Product Two', NULL, true, 'verified'),
  ('6c100000-0000-4000-8000-000000000218', 'Pending Listing Product', NULL, true, 'verified'),
  ('6c100000-0000-4000-8000-000000000219', 'Discontinued Listing Product', NULL, true, 'verified'),
  ('6c100000-0000-4000-8000-000000000220', 'Forgotten Mapping Catalog Product', NULL, true, 'verified');

INSERT INTO public.catalog_vendor_products (
  id, catalog_vendor_id, catalog_product_id, vendor_sku, normalized_vendor_sku,
  package_description, package_status, active, discontinued, verification_status
)
VALUES
  ('6c100000-0000-4000-8000-000000000221', '6c100000-0000-4000-8000-000000000201', '6c100000-0000-4000-8000-000000000211', '398-0143', 'x', '100/Bx', 'source_only', true, false, 'verified'),
  ('6c100000-0000-4000-8000-000000000222', '6c100000-0000-4000-8000-000000000201', '6c100000-0000-4000-8000-000000000212', '112-7149', 'x', NULL, 'unknown', true, false, 'verified'),
  ('6c100000-0000-4000-8000-000000000223', '6c100000-0000-4000-8000-000000000201', '6c100000-0000-4000-8000-000000000213', '150-7581', 'x', '100/Bx', 'source_only', true, false, 'verified'),
  ('6c100000-0000-4000-8000-000000000224', '6c100000-0000-4000-8000-000000000201', '6c100000-0000-4000-8000-000000000214', '120-0685', 'x', '200/Pk', 'source_only', true, false, 'verified'),
  ('6c100000-0000-4000-8000-000000000225', '6c100000-0000-4000-8000-000000000202', '6c100000-0000-4000-8000-000000000215', 'ML-4410', 'x', NULL, 'unknown', true, false, 'verified'),
  ('6c100000-0000-4000-8000-000000000226', '6c100000-0000-4000-8000-000000000201', '6c100000-0000-4000-8000-000000000216', '555-1234', 'x', NULL, 'unknown', true, false, 'verified'),
  ('6c100000-0000-4000-8000-000000000227', '6c100000-0000-4000-8000-000000000201', '6c100000-0000-4000-8000-000000000217', '5551-234', 'x', NULL, 'unknown', true, false, 'verified'),
  ('6c100000-0000-4000-8000-000000000228', '6c100000-0000-4000-8000-000000000201', '6c100000-0000-4000-8000-000000000218', '777-0001', 'x', NULL, 'unknown', true, false, 'pending'),
  ('6c100000-0000-4000-8000-000000000229', '6c100000-0000-4000-8000-000000000201', '6c100000-0000-4000-8000-000000000219', '777-0002', 'x', NULL, 'unknown', false, true, 'verified'),
  ('6c100000-0000-4000-8000-000000000230', '6c100000-0000-4000-8000-000000000201', '6c100000-0000-4000-8000-000000000220', 'FORGOT-1', 'x', NULL, 'unknown', true, false, 'verified');

-- Organization vendors: two linked to catalog vendors, one deliberately unlinked.
INSERT INTO public.vendors (id, organization_id, name, normalized_name, active, catalog_vendor_id)
VALUES
  ('6c100000-0000-4000-8000-000000000301', '6c100000-0000-4000-8000-000000000101', 'Henry Schein', 'henry schein', true, '6c100000-0000-4000-8000-000000000201'),
  ('6c100000-0000-4000-8000-000000000302', '6c100000-0000-4000-8000-000000000101', 'Medline', 'medline', true, '6c100000-0000-4000-8000-000000000202'),
  ('6c100000-0000-4000-8000-000000000303', '6c100000-0000-4000-8000-000000000101', 'Local Supply', 'local supply', true, NULL),
  ('6c100000-0000-4000-8000-000000000304', '6c100000-0000-4000-8000-000000000102', 'Henry Schein', 'henry schein', true, '6c100000-0000-4000-8000-000000000201');

INSERT INTO public.products (id, organization_id, name, normalized_name, manufacturer, unit_of_measure, pack_size, approved, active, staff_requestable)
VALUES
  ('6c100000-0000-4000-8000-000000000401', '6c100000-0000-4000-8000-000000000101', 'Local Sharps Container', 'x', NULL, NULL, NULL, true, true, true),
  ('6c100000-0000-4000-8000-000000000402', '6c100000-0000-4000-8000-000000000101', 'Canonical Tape', 'x', NULL, 'box', '100', true, true, true),
  ('6c100000-0000-4000-8000-000000000403', '6c100000-0000-4000-8000-000000000101', 'Ammex Black Nitrile Glove Medium', 'x', 'Ammex', 'box', NULL, true, true, true),
  ('6c100000-0000-4000-8000-000000000404', '6c100000-0000-4000-8000-000000000101', 'Owner Chosen Sponge', 'x', NULL, NULL, NULL, true, true, true),
  ('6c100000-0000-4000-8000-000000000405', '6c100000-0000-4000-8000-000000000101', 'Ambiguous Mapping One', 'x', NULL, NULL, NULL, true, true, true),
  ('6c100000-0000-4000-8000-000000000406', '6c100000-0000-4000-8000-000000000101', 'Ambiguous Mapping Two', 'x', NULL, NULL, NULL, true, true, true),
  ('6c100000-0000-4000-8000-000000000407', '6c100000-0000-4000-8000-000000000101', 'Forgotten Mapping Product', 'x', NULL, NULL, NULL, true, true, true);

INSERT INTO public.vendor_products (id, organization_id, vendor_id, product_id, vendor_sku, active)
VALUES
  -- Trusted organization mapping remembered from an earlier manual confirmation.
  ('6c100000-0000-4000-8000-000000000501', '6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000301', '6c100000-0000-4000-8000-000000000401', '1127149', true),
  -- Two mappings that collide on the separator-insensitive key AB12.
  ('6c100000-0000-4000-8000-000000000502', '6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000301', '6c100000-0000-4000-8000-000000000405', 'AB-12', true),
  ('6c100000-0000-4000-8000-000000000503', '6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000301', '6c100000-0000-4000-8000-000000000406', 'A-B12', true),
  -- An owner "forgot" this mapping; the catalog also lists FORGOT-1.
  ('6c100000-0000-4000-8000-000000000504', '6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000301', '6c100000-0000-4000-8000-000000000407', 'FORGOT-1', false);

-- An existing approved request with its commitment: resolution must leave both untouched,
-- even though the request names a product that the invoice also contains.
INSERT INTO public.supply_requests (id, organization_id, requested_by, product_id, request_type, quantity, status)
VALUES ('6c100000-0000-4000-8000-000000000901', '6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000003', '6c100000-0000-4000-8000-000000000401', 'reorder', 4, 'approved');
INSERT INTO public.supply_request_items (id, organization_id, supply_request_id, product_id, quantity)
VALUES ('6c100000-0000-4000-8000-000000000902', '6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000901', '6c100000-0000-4000-8000-000000000401', 4);
INSERT INTO public.supply_request_commitments (id, organization_id, supply_request_id, amount, total_item_count, priced_item_count, pricing_status, committed_by)
VALUES ('6c100000-0000-4000-8000-000000000903', '6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000901', 0, 1, 0, 'unpriced', '6c100000-0000-4000-8000-000000000002');
INSERT INTO public.supply_request_commitment_items (id, organization_id, commitment_id, supply_request_item_id, quantity_snapshot, price_source)
VALUES ('6c100000-0000-4000-8000-000000000904', '6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000903', '6c100000-0000-4000-8000-000000000902', 4, 'unpriced');

INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type)
SELECT ('6c100000-0000-4000-8000-0000000006' || lpad(n::text, 2, '0'))::uuid,
  CASE WHEN n = 5 THEN '6c100000-0000-4000-8000-000000000102'::uuid ELSE '6c100000-0000-4000-8000-000000000101'::uuid END,
  CASE WHEN n = 5 THEN '6c100000-0000-4000-8000-000000000004'::uuid ELSE '6c100000-0000-4000-8000-000000000001'::uuid END,
  CASE WHEN n = 5 THEN '6c100000-0000-4000-8000-000000000102' ELSE '6c100000-0000-4000-8000-000000000101' END || '/phase6c1-' || n || '.pdf',
  'phase6c1-' || n || '.pdf', 1024, 'application/pdf'
FROM generate_series(1, 6) n;

INSERT INTO public.invoices (id, organization_id, source_file_id, vendor_id, vendor_name, invoice_number, processing_status)
VALUES
  ('6c100000-0000-4000-8000-000000000701', '6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000601', '6c100000-0000-4000-8000-000000000301', 'Henry Schein', 'HS-6C1-1', 'review_required'),
  ('6c100000-0000-4000-8000-000000000702', '6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000602', '6c100000-0000-4000-8000-000000000302', 'Medline', 'ML-6C1-1', 'review_required'),
  ('6c100000-0000-4000-8000-000000000703', '6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000603', '6c100000-0000-4000-8000-000000000303', 'Local Supply', 'LS-6C1-1', 'review_required'),
  ('6c100000-0000-4000-8000-000000000704', '6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000604', NULL, NULL, 'NV-6C1-1', 'review_required'),
  ('6c100000-0000-4000-8000-000000000705', '6c100000-0000-4000-8000-000000000102', '6c100000-0000-4000-8000-000000000605', '6c100000-0000-4000-8000-000000000304', 'Henry Schein', 'HS-6C1-B', 'review_required'),
  ('6c100000-0000-4000-8000-000000000706', '6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000606', '6c100000-0000-4000-8000-000000000301', 'Henry Schein', 'HS-6C1-2', 'review_required');

INSERT INTO public.invoice_items (id, invoice_id, organization_id, line_number, sku, description, manufacturer, quantity, unit_of_measure, package_size, unit_price, total_price)
VALUES
  -- Henry Schein invoice, organization A.
  ('6c100000-0000-4000-8000-000000000801', '6c100000-0000-4000-8000-000000000701', '6c100000-0000-4000-8000-000000000101', 1, '3980143', 'Ammex Black PF Nitrile Gl Medium', 'Ammex', 2, 'BX', NULL, 9.5, 19),
  ('6c100000-0000-4000-8000-000000000802', '6c100000-0000-4000-8000-000000000701', '6c100000-0000-4000-8000-000000000101', 2, '1127149', 'Sharps Container Sliding 1qt Red', NULL, 4, 'EA', NULL, 3.25, 13),
  ('6c100000-0000-4000-8000-000000000803', '6c100000-0000-4000-8000-000000000701', '6c100000-0000-4000-8000-000000000101', 3, '1507581', 'Needle Dry Click APS w/Gu .30x50mm', NULL, 1, 'BX', NULL, 28, 28),
  ('6c100000-0000-4000-8000-000000000804', '6c100000-0000-4000-8000-000000000701', '6c100000-0000-4000-8000-000000000101', 4, '120-0685', 'Sponge Nonwoven 4Ply ST 4x4"', NULL, 3, 'PK', NULL, 6, 18),
  ('6c100000-0000-4000-8000-000000000805', '6c100000-0000-4000-8000-000000000701', '6c100000-0000-4000-8000-000000000101', 5, NULL, 'Canonical Tape', NULL, 1, 'box', '100', 4, 4),
  ('6c100000-0000-4000-8000-000000000806', '6c100000-0000-4000-8000-000000000701', '6c100000-0000-4000-8000-000000000101', 6, 'ZZ-0001', 'Ammex Black Nitrile Glove Medium', 'Ammex', 1, 'box', NULL, 9, 9),
  ('6c100000-0000-4000-8000-000000000807', '6c100000-0000-4000-8000-000000000701', '6c100000-0000-4000-8000-000000000101', 7, 'PKG-0001', 'Unrelated description', NULL, 1, 'box', '100', 1, 1),
  ('6c100000-0000-4000-8000-000000000808', '6c100000-0000-4000-8000-000000000701', '6c100000-0000-4000-8000-000000000101', 8, '5551234', 'Collision', NULL, 1, 'EA', NULL, 1, 1),
  ('6c100000-0000-4000-8000-000000000809', '6c100000-0000-4000-8000-000000000701', '6c100000-0000-4000-8000-000000000101', 9, '7770001', 'Pending listing', NULL, 1, 'EA', NULL, 1, 1),
  ('6c100000-0000-4000-8000-000000000810', '6c100000-0000-4000-8000-000000000701', '6c100000-0000-4000-8000-000000000101', 10, '7770002', 'Discontinued listing', NULL, 1, 'EA', NULL, 1, 1),
  ('6c100000-0000-4000-8000-000000000811', '6c100000-0000-4000-8000-000000000701', '6c100000-0000-4000-8000-000000000101', 11, 'AB12', 'Ambiguous organization mapping', NULL, 1, 'EA', NULL, 1, 1),
  ('6c100000-0000-4000-8000-000000000812', '6c100000-0000-4000-8000-000000000701', '6c100000-0000-4000-8000-000000000101', 12, 'FORGOT-1', 'Forgotten mapping', NULL, 1, 'EA', NULL, 1, 1),
  ('6c100000-0000-4000-8000-000000000813', '6c100000-0000-4000-8000-000000000701', '6c100000-0000-4000-8000-000000000101', 13, '1200685', 'Sponge Nonwoven 4Ply ST 4x4"', NULL, 1, 'PK', NULL, 6, 6),
  ('6c100000-0000-4000-8000-000000000814', '6c100000-0000-4000-8000-000000000701', '6c100000-0000-4000-8000-000000000101', 14, '1127149', 'Sharps Container Sliding 1qt Red', NULL, 1, 'EA', NULL, 3.25, 3.25),
  ('6c100000-0000-4000-8000-000000000815', '6c100000-0000-4000-8000-000000000701', '6c100000-0000-4000-8000-000000000101', 15, '39-80143', 'Different separator placement', NULL, 1, 'EA', NULL, 1, 1),
  ('6c100000-0000-4000-8000-000000000816', '6c100000-0000-4000-8000-000000000701', '6c100000-0000-4000-8000-000000000101', 16, ' 120-0685 ', 'Sponge repeated on the same invoice', NULL, 1, 'PK', NULL, 6, 6),
  -- Medline invoice, organization A: same SKUs as Henry Schein must not cross vendors.
  ('6c100000-0000-4000-8000-000000000821', '6c100000-0000-4000-8000-000000000702', '6c100000-0000-4000-8000-000000000101', 1, '3980143', 'Ammex Black PF Nitrile Gl Medium', 'Ammex', 1, 'BX', NULL, 9.5, 9.5),
  ('6c100000-0000-4000-8000-000000000822', '6c100000-0000-4000-8000-000000000702', '6c100000-0000-4000-8000-000000000101', 2, '1127149', 'Sharps Container Sliding 1qt Red', NULL, 1, 'EA', NULL, 3.25, 3.25),
  ('6c100000-0000-4000-8000-000000000823', '6c100000-0000-4000-8000-000000000702', '6c100000-0000-4000-8000-000000000101', 3, 'ml-4410', 'Medline catalog item', NULL, 1, 'EA', NULL, 2, 2),
  -- Unlinked vendor and no-vendor invoices.
  ('6c100000-0000-4000-8000-000000000831', '6c100000-0000-4000-8000-000000000703', '6c100000-0000-4000-8000-000000000101', 1, '398-0143', 'Ammex Black PF Nitrile Gl Medium', 'Ammex', 1, 'BX', NULL, 9.5, 9.5),
  ('6c100000-0000-4000-8000-000000000841', '6c100000-0000-4000-8000-000000000704', '6c100000-0000-4000-8000-000000000101', 1, '398-0143', 'Ammex Black PF Nitrile Gl Medium', 'Ammex', 1, 'BX', NULL, 9.5, 9.5),
  -- Organization B.
  ('6c100000-0000-4000-8000-000000000851', '6c100000-0000-4000-8000-000000000705', '6c100000-0000-4000-8000-000000000102', 1, '3980143', 'Ammex Black PF Nitrile Gl Medium', 'Ammex', 1, 'BX', NULL, 9.5, 9.5),
  -- A second organization A Henry Schein invoice used for posting.
  ('6c100000-0000-4000-8000-000000000861', '6c100000-0000-4000-8000-000000000706', '6c100000-0000-4000-8000-000000000101', 1, '3980143', 'Ammex Black PF Nitrile Gl Medium', 'Ammex', 5, 'BX', NULL, 9.75, 48.75);

-- Raw fixture writes run as the migration role, so provenance starts empty.
DO $phase6c1_fixture_check$
BEGIN
  IF EXISTS (SELECT 1 FROM public.invoice_items WHERE id::text LIKE '6c100000-%' AND (product_id IS NOT NULL OR product_match_source IS NOT NULL)) THEN
    RAISE EXCEPTION 'Fixture lines must start unresolved';
  END IF;
END
$phase6c1_fixture_check$;

CREATE TEMP TABLE phase6c1_snapshots (name text PRIMARY KEY, value jsonb);
GRANT ALL ON phase6c1_snapshots TO authenticated;
INSERT INTO phase6c1_snapshots VALUES ('before', pg_temp.phase6c1_side_effects());

-- Organization A owner works the invoice through the API role.
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c100000-0000-4000-8000-000000000001', true);

-- The needle was adopted earlier through the Catalog admin flow: its organization
-- mapping stores the canonical 150-7581 while the invoice prints 1507581.
SELECT public.adopt_catalog_vendor_product('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000223');

-- Human decisions recorded before any resolution: line 13 is matched by the owner to a
-- different product even though 1200685 has a catalog identity; line 14 is unlinked.
SELECT public.confirm_invoice_item_product(
  '6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000601',
  '6c100000-0000-4000-8000-000000000813', '6c100000-0000-4000-8000-000000000404', false
);
SELECT public.unlink_invoice_item_product(
  '6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000601',
  '6c100000-0000-4000-8000-000000000814', false
);

INSERT INTO phase6c1_snapshots VALUES ('identity_before_resolve', pg_temp.phase6c1_identity_counts());
INSERT INTO phase6c1_snapshots VALUES ('first_resolve', public.resolve_invoice_exact_product_identities(
  '6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000601'
));

-- Check 1: an existing organization vendor + SKU mapping resolves automatically.
DO $phase6c1_check_1$
DECLARE _line public.invoice_items;
BEGIN
  _line := pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000802');
  IF _line.product_id IS DISTINCT FROM '6c100000-0000-4000-8000-000000000401'::uuid
     OR _line.vendor_product_id IS DISTINCT FROM '6c100000-0000-4000-8000-000000000501'::uuid
     OR _line.product_match_source IS DISTINCT FROM 'org_vendor_sku' THEN
    RAISE EXCEPTION 'Check 1 failed: trusted organization mapping did not resolve: %', to_jsonb(_line);
  END IF;
END
$phase6c1_check_1$;

-- Check 2: a catalog-adopted organization mapping (150-7581) resolves bare 1507581.
DO $phase6c1_check_2$
DECLARE _line public.invoice_items; _mapping public.vendor_products;
BEGIN
  _line := pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000803');
  SELECT * INTO _mapping FROM public.vendor_products WHERE id = _line.vendor_product_id;
  IF _line.product_match_source IS DISTINCT FROM 'org_vendor_sku_match_key'
     OR _mapping.catalog_vendor_product_id IS DISTINCT FROM '6c100000-0000-4000-8000-000000000223'::uuid
     OR _mapping.vendor_sku <> '150-7581' THEN
    RAISE EXCEPTION 'Check 2 failed: adopted mapping did not resolve by separator-free key: %', to_jsonb(_line);
  END IF;
END
$phase6c1_check_2$;

-- Check 3: exact unique global vendor + SKU resolves and adopts (strict and key tiers).
DO $phase6c1_check_3$
DECLARE _gloves public.invoice_items; _sponge public.invoice_items; _repeat public.invoice_items;
BEGIN
  _gloves := pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000801');
  _sponge := pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000804');
  _repeat := pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000816');
  IF _gloves.product_match_source IS DISTINCT FROM 'catalog_vendor_sku_match_key'
     OR NOT EXISTS (
       SELECT 1 FROM public.products p JOIN public.vendor_products vp ON vp.product_id = p.id
       WHERE p.id = _gloves.product_id AND vp.id = _gloves.vendor_product_id
         AND p.organization_id = '6c100000-0000-4000-8000-000000000101'
         AND p.catalog_product_id = '6c100000-0000-4000-8000-000000000211'
         AND vp.catalog_vendor_product_id = '6c100000-0000-4000-8000-000000000221'
         AND vp.vendor_id = '6c100000-0000-4000-8000-000000000301'
         AND vp.vendor_sku = '398-0143'
     ) THEN
    RAISE EXCEPTION 'Check 3 failed: 3980143 did not resolve to the adopted 398-0143 identity: %', to_jsonb(_gloves);
  END IF;
  IF _sponge.product_match_source IS DISTINCT FROM 'catalog_vendor_sku'
     OR _repeat.product_match_source IS DISTINCT FROM 'org_vendor_sku'
     OR _repeat.product_id IS DISTINCT FROM _sponge.product_id
     OR _repeat.vendor_product_id IS DISTINCT FROM _sponge.vendor_product_id THEN
    RAISE EXCEPTION 'Check 3 failed: strict catalog tier or same-invoice repeat: % / %', to_jsonb(_sponge), to_jsonb(_repeat);
  END IF;
END
$phase6c1_check_3$;

-- Check 4: adoption created exactly one product and mapping per listing, nothing else,
-- and left canonical SKUs and raw package metadata untouched.
DO $phase6c1_check_4$
DECLARE _before jsonb; _after jsonb := pg_temp.phase6c1_identity_counts();
BEGIN
  SELECT value INTO _before FROM phase6c1_snapshots WHERE name = 'identity_before_resolve';
  IF (_after->>'products')::int - (_before->>'products')::int <> 2
     OR (_after->>'vendorProducts')::int - (_before->>'vendorProducts')::int <> 2
     OR (_after->>'vendors')::int <> (_before->>'vendors')::int
     OR (_after->>'catalogProducts')::int <> (_before->>'catalogProducts')::int
     OR (_after->>'catalogListings')::int <> (_before->>'catalogListings')::int THEN
    RAISE EXCEPTION 'Check 4 failed: unexpected identity writes % -> %', _before, _after;
  END IF;
  IF (SELECT count(*) FROM public.vendor_products WHERE organization_id = '6c100000-0000-4000-8000-000000000101' AND catalog_vendor_product_id = '6c100000-0000-4000-8000-000000000224') <> 1
     OR (SELECT count(*) FROM public.products WHERE organization_id = '6c100000-0000-4000-8000-000000000101' AND catalog_product_id = '6c100000-0000-4000-8000-000000000214') <> 1 THEN
    RAISE EXCEPTION 'Check 4 failed: repeated SKU on one invoice duplicated an adoption';
  END IF;
  IF (SELECT package_size FROM public.vendor_products WHERE catalog_vendor_product_id = '6c100000-0000-4000-8000-000000000221' AND organization_id = '6c100000-0000-4000-8000-000000000101') IS DISTINCT FROM '100/Bx'
     OR (SELECT unit_of_measure FROM public.vendor_products WHERE catalog_vendor_product_id = '6c100000-0000-4000-8000-000000000221' AND organization_id = '6c100000-0000-4000-8000-000000000101') IS NOT NULL THEN
    RAISE EXCEPTION 'Check 4 failed: source-only package text was normalized or replaced';
  END IF;
END
$phase6c1_check_4$;

-- Check 5: exception lines stay for review.
DO $phase6c1_check_5$
DECLARE _id uuid;
BEGIN
  FOREACH _id IN ARRAY ARRAY[
    '6c100000-0000-4000-8000-000000000805', -- description equals an organization product name, no SKU
    '6c100000-0000-4000-8000-000000000806', -- manufacturer and description equal an organization product
    '6c100000-0000-4000-8000-000000000807', -- package and unit equal an organization product
    '6c100000-0000-4000-8000-000000000808', -- 5551234 collides with 555-1234 and 5551-234
    '6c100000-0000-4000-8000-000000000809', -- listing pending verification
    '6c100000-0000-4000-8000-000000000810', -- listing discontinued
    '6c100000-0000-4000-8000-000000000811', -- two organization mappings share key AB12
    '6c100000-0000-4000-8000-000000000812', -- organization mapping was deactivated by an owner
    '6c100000-0000-4000-8000-000000000815'  -- 39-80143 has separators that differ from 398-0143
  ]::uuid[] LOOP
    IF (pg_temp.phase6c1_line(_id)).product_id IS NOT NULL
       OR (pg_temp.phase6c1_line(_id)).product_match_source IS NOT NULL THEN
      RAISE EXCEPTION 'Check 5 failed: line % auto-resolved: %', _id, to_jsonb(pg_temp.phase6c1_line(_id));
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM public.vendor_products WHERE catalog_vendor_product_id IN (
       '6c100000-0000-4000-8000-000000000226', '6c100000-0000-4000-8000-000000000227',
       '6c100000-0000-4000-8000-000000000228', '6c100000-0000-4000-8000-000000000229',
       '6c100000-0000-4000-8000-000000000230')) THEN
    RAISE EXCEPTION 'Check 5 failed: a non-authoritative or blocked listing was adopted';
  END IF;
END
$phase6c1_check_5$;

-- Check 6: the resolver reports exactly what it did and why the rest need review.
DO $phase6c1_check_6$
DECLARE _result jsonb;
BEGIN
  SELECT value INTO _result FROM phase6c1_snapshots WHERE name = 'first_resolve';
  IF _result->>'resolvedFromOrganizationMapping' <> '3'
     OR _result->>'resolvedFromCatalog' <> '2'
     OR _result->>'adoptedCatalogProducts' <> '2'
     OR _result->>'needsReview' <> '9'
     OR _result->'reviewReasons' <> jsonb_build_object(
       'no_sku', 1, 'no_exact_identity', 2, 'ambiguous_catalog_listing', 1,
       'catalog_listing_not_authoritative', 2, 'ambiguous_organization_mapping', 1,
       'inactive_organization_mapping', 1, 'organization_mapping_conflict', 1) THEN
    RAISE EXCEPTION 'Check 6 failed: unexpected resolver summary %', _result;
  END IF;
END
$phase6c1_check_6$;

-- Check 7: human decisions are untouched by resolution.
DO $phase6c1_check_7$
DECLARE _manual public.invoice_items; _cleared public.invoice_items;
BEGIN
  _manual := pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000813');
  _cleared := pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000814');
  IF _manual.product_id IS DISTINCT FROM '6c100000-0000-4000-8000-000000000404'::uuid
     OR _manual.product_match_source IS DISTINCT FROM 'manual'
     OR _cleared.product_id IS NOT NULL
     OR _cleared.product_match_source IS DISTINCT FROM 'manual_cleared' THEN
    RAISE EXCEPTION 'Check 7 failed: manual decisions changed: % / %', to_jsonb(_manual), to_jsonb(_cleared);
  END IF;
END
$phase6c1_check_7$;

-- Check 8: re-running is idempotent and does not touch already-resolved rows.
CREATE TEMP TABLE phase6c1_lines_after_first AS
SELECT id, product_id, vendor_product_id, product_match_source, product_match_decided_at, updated_at
FROM public.invoice_items WHERE id::text LIKE '6c100000-%';
INSERT INTO phase6c1_snapshots VALUES ('identity_after_first', pg_temp.phase6c1_identity_counts());
INSERT INTO phase6c1_snapshots VALUES ('second_resolve', public.resolve_invoice_exact_product_identities(
  '6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000601'
));
DO $phase6c1_check_8$
DECLARE _second jsonb;
BEGIN
  SELECT value INTO _second FROM phase6c1_snapshots WHERE name = 'second_resolve';
  IF _second->>'resolvedFromOrganizationMapping' <> '0' OR _second->>'resolvedFromCatalog' <> '0'
     OR _second->>'adoptedCatalogProducts' <> '0' OR _second->>'needsReview' <> '9' THEN
    RAISE EXCEPTION 'Check 8 failed: second run did work %', _second;
  END IF;
  IF pg_temp.phase6c1_identity_counts() IS DISTINCT FROM (SELECT value FROM phase6c1_snapshots WHERE name = 'identity_after_first') THEN
    RAISE EXCEPTION 'Check 8 failed: second run wrote identity rows';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.invoice_items current_line
    JOIN phase6c1_lines_after_first previous USING (id)
    WHERE (current_line.product_id, current_line.vendor_product_id, current_line.product_match_source,
           current_line.product_match_decided_at, current_line.updated_at)
      IS DISTINCT FROM (previous.product_id, previous.vendor_product_id, previous.product_match_source,
           previous.product_match_decided_at, previous.updated_at)
  ) THEN
    RAISE EXCEPTION 'Check 8 failed: second run rewrote invoice lines';
  END IF;
END
$phase6c1_check_8$;

-- Check 9: the same SKUs on a different vendor's invoice never cross-match; that
-- vendor's own catalog listing still resolves (case-insensitively).
INSERT INTO phase6c1_snapshots VALUES ('medline_resolve', public.resolve_invoice_exact_product_identities(
  '6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000602'
));
DO $phase6c1_check_9$
DECLARE _medline public.invoice_items;
BEGIN
  -- The Medline lines must find no identity at all, rather than being rescued by a
  -- later safeguard after reaching for another vendor's listing or mapping.
  IF (SELECT value->'reviewReasons' FROM phase6c1_snapshots WHERE name = 'medline_resolve')
       <> '{"no_exact_identity": 2}'::jsonb THEN
    RAISE EXCEPTION 'Check 9 failed: unexpected Medline review reasons %',
      (SELECT value FROM phase6c1_snapshots WHERE name = 'medline_resolve');
  END IF;
  IF (pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000821')).product_id IS NOT NULL
     OR (pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000822')).product_id IS NOT NULL THEN
    RAISE EXCEPTION 'Check 9 failed: Henry Schein SKU matched on a Medline invoice';
  END IF;
  _medline := pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000823');
  IF _medline.product_match_source IS DISTINCT FROM 'catalog_vendor_sku'
     OR NOT EXISTS (
       SELECT 1 FROM public.vendor_products
       WHERE id = _medline.vendor_product_id
         AND vendor_id = '6c100000-0000-4000-8000-000000000302'
         AND catalog_vendor_product_id = '6c100000-0000-4000-8000-000000000225'
     ) THEN
    RAISE EXCEPTION 'Check 9 failed: Medline listing did not resolve to the Medline vendor: %', to_jsonb(_medline);
  END IF;
END
$phase6c1_check_9$;

-- Check 10: an unlinked vendor never uses the global catalog; a missing vendor is a no-op.
DO $phase6c1_check_10$
DECLARE _unlinked jsonb; _missing jsonb;
BEGIN
  _unlinked := public.resolve_invoice_exact_product_identities('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000603');
  _missing := public.resolve_invoice_exact_product_identities('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000604');
  IF _unlinked->'reviewReasons' <> '{"vendor_not_linked_to_catalog": 1}'::jsonb
     OR (pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000831')).product_id IS NOT NULL
     OR _missing->>'skipped' <> 'no_vendor'
     OR (pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000841')).product_id IS NOT NULL THEN
    RAISE EXCEPTION 'Check 10 failed: % / %', _unlinked, _missing;
  END IF;
  IF (SELECT catalog_vendor_id FROM public.vendors WHERE id = '6c100000-0000-4000-8000-000000000303') IS NOT NULL THEN
    RAISE EXCEPTION 'Check 10 failed: resolver linked a vendor to the catalog';
  END IF;
END
$phase6c1_check_10$;

-- Check 11: API writes cannot forge machine provenance; client product changes are manual.
UPDATE public.invoice_items SET product_match_source = 'catalog_vendor_sku'
WHERE id = '6c100000-0000-4000-8000-000000000805';
UPDATE public.invoice_items SET product_match_source = 'manual'
WHERE id = '6c100000-0000-4000-8000-000000000801';
INSERT INTO public.invoice_items (id, invoice_id, organization_id, line_number, sku, description, quantity, product_match_source, product_match_decided_at)
VALUES ('6c100000-0000-4000-8000-000000000817', '6c100000-0000-4000-8000-000000000701', '6c100000-0000-4000-8000-000000000101', 17, '398-0143', 'Inserted through the API', 1, 'manual_cleared', now());
UPDATE public.invoice_items SET product_id = '6c100000-0000-4000-8000-000000000402'
WHERE id = '6c100000-0000-4000-8000-000000000807';
DO $phase6c1_check_11$
BEGIN
  IF (pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000805')).product_match_source IS NOT NULL
     OR (pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000801')).product_match_source IS DISTINCT FROM 'catalog_vendor_sku_match_key'
     OR (pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000817')).product_match_source IS NOT NULL
     OR (pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000807')).product_match_source IS DISTINCT FROM 'manual' THEN
    RAISE EXCEPTION 'Check 11 failed: API provenance writes were not derived server-side';
  END IF;
END
$phase6c1_check_11$;

-- Check 12: a line added later resolves on the next pass; an owner unlink of an
-- automatic match is final; an owner SKU correction makes a cleared line eligible again.
SELECT public.resolve_invoice_exact_product_identities('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000601');
SELECT public.unlink_invoice_item_product('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000601', '6c100000-0000-4000-8000-000000000801', false);
SELECT public.resolve_invoice_exact_product_identities('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000601');
UPDATE public.invoice_items SET sku = '1127149 ' WHERE id = '6c100000-0000-4000-8000-000000000814';
INSERT INTO phase6c1_snapshots VALUES ('after_sku_correction', to_jsonb(pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000814')));
SELECT public.resolve_invoice_exact_product_identities('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000601');
DO $phase6c1_check_12$
BEGIN
  IF (pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000817')).product_match_source IS DISTINCT FROM 'org_vendor_sku' THEN
    RAISE EXCEPTION 'Check 12 failed: newly added line did not resolve';
  END IF;
  IF (pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000801')).product_id IS NOT NULL
     OR (pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000801')).product_match_source IS DISTINCT FROM 'manual_cleared' THEN
    RAISE EXCEPTION 'Check 12 failed: owner unlink of an automatic match was reverted';
  END IF;
  IF (SELECT value->>'product_match_source' FROM phase6c1_snapshots WHERE name = 'after_sku_correction') IS NOT NULL
     OR (pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000814')).product_match_source IS DISTINCT FROM 'org_vendor_sku' THEN
    RAISE EXCEPTION 'Check 12 failed: corrected SKU did not become eligible';
  END IF;
END
$phase6c1_check_12$;

-- Check 13: a vendor change through rematch clears vendor-scoped links and re-resolves
-- under the new vendor only; the owner's manual product-only match survives.
UPDATE public.invoices SET vendor_id = '6c100000-0000-4000-8000-000000000301', vendor_name = 'Henry Schein'
WHERE id = '6c100000-0000-4000-8000-000000000702';
DO $phase6c1_check_13$
DECLARE _matched integer;
BEGIN
  _matched := public.rematch_invoice_vendor_products('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000602');
  IF _matched <> 2
     OR (pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000821')).product_match_source IS DISTINCT FROM 'org_vendor_sku_match_key'
     OR (pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000822')).vendor_product_id IS DISTINCT FROM '6c100000-0000-4000-8000-000000000501'::uuid
     OR (pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000823')).product_id IS NOT NULL
     OR (pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000823')).product_match_source IS NOT NULL THEN
    RAISE EXCEPTION 'Check 13 failed: rematch did not delegate to the vendor-scoped resolver (%)', _matched;
  END IF;
  IF (pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000813')).product_id IS DISTINCT FROM '6c100000-0000-4000-8000-000000000404'::uuid THEN
    RAISE EXCEPTION 'Check 13 failed: manual product-only match changed';
  END IF;
END
$phase6c1_check_13$;

-- Check 14: resolution stocked nothing, posted nothing, and touched no request,
-- commitment, purchasing, receiving, price, or global catalog data.
RESET ROLE;
DO $phase6c1_check_14$
DECLARE _before jsonb; _after jsonb := pg_temp.phase6c1_side_effects();
BEGIN
  SELECT value INTO _before FROM phase6c1_snapshots WHERE name = 'before';
  IF _after IS DISTINCT FROM _before THEN
    RAISE EXCEPTION 'Check 14 failed: side effects % -> %', _before, _after;
  END IF;
  IF EXISTS (SELECT 1 FROM public.inventory_items i JOIN public.products p ON p.id = i.product_id
             WHERE p.catalog_product_id::text LIKE '6c100000-%') THEN
    RAISE EXCEPTION 'Check 14 failed: adoption created an inventory record';
  END IF;
  IF EXISTS (SELECT 1 FROM public.invoice_items WHERE id::text LIKE '6c100000-%' AND review_status <> 'pending_review') THEN
    RAISE EXCEPTION 'Check 14 failed: resolution approved invoice lines';
  END IF;
  IF (SELECT status FROM public.supply_requests WHERE id = '6c100000-0000-4000-8000-000000000901') <> 'approved'
     OR (SELECT status FROM public.supply_request_commitments WHERE id = '6c100000-0000-4000-8000-000000000903') <> 'active' THEN
    RAISE EXCEPTION 'Check 14 failed: request or commitment state changed';
  END IF;
  IF to_regclass('public.purchase_orders') IS NOT NULL OR to_regclass('public.receipts') IS NOT NULL THEN
    RAISE EXCEPTION 'Check 14 failed: purchasing tables appeared';
  END IF;
END
$phase6c1_check_14$;

-- Check 15: provenance is complete for every automatic match.
DO $phase6c1_check_15$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.invoice_items
    WHERE id::text LIKE '6c100000-%'
      AND product_match_source IN ('org_vendor_sku', 'org_vendor_sku_match_key', 'catalog_vendor_sku', 'catalog_vendor_sku_match_key')
      AND (product_id IS NULL OR vendor_product_id IS NULL OR product_match_decided_at IS NULL)
  ) THEN
    RAISE EXCEPTION 'Check 15 failed: incomplete automatic provenance';
  END IF;
  BEGIN
    UPDATE public.invoice_items SET product_match_source = 'catalog_vendor_sku'
    WHERE id = '6c100000-0000-4000-8000-000000000805';
    RAISE EXCEPTION 'Check 15 failed: automatic provenance without a product was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END
$phase6c1_check_15$;

-- Check 16: organization isolation and authorization.
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c100000-0000-4000-8000-000000000004', true);
SELECT pg_temp.phase6c1_expect_error(
  $$SELECT public.resolve_invoice_exact_product_identities('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000601')$$,
  'Forbidden: owner access required');
SELECT pg_temp.phase6c1_expect_error(
  $$SELECT public.resolve_invoice_exact_product_identities('6c100000-0000-4000-8000-000000000102', '6c100000-0000-4000-8000-000000000601')$$,
  'Invoice review not found');
SELECT public.resolve_invoice_exact_product_identities('6c100000-0000-4000-8000-000000000102', '6c100000-0000-4000-8000-000000000605');
DO $phase6c1_check_16_owner_b$
DECLARE _line public.invoice_items;
BEGIN
  IF EXISTS (SELECT 1 FROM public.invoice_items WHERE organization_id = '6c100000-0000-4000-8000-000000000101') THEN
    RAISE EXCEPTION 'Check 16 failed: organization B owner can read organization A lines';
  END IF;
  SELECT * INTO _line FROM public.invoice_items WHERE id = '6c100000-0000-4000-8000-000000000851';
  IF _line.product_match_source IS DISTINCT FROM 'catalog_vendor_sku_match_key'
     OR NOT EXISTS (SELECT 1 FROM public.products WHERE id = _line.product_id AND organization_id = '6c100000-0000-4000-8000-000000000102')
     OR NOT EXISTS (SELECT 1 FROM public.vendor_products WHERE id = _line.vendor_product_id AND organization_id = '6c100000-0000-4000-8000-000000000102' AND vendor_id = '6c100000-0000-4000-8000-000000000304') THEN
    RAISE EXCEPTION 'Check 16 failed: organization B did not resolve inside organization B';
  END IF;
END
$phase6c1_check_16_owner_b$;
SELECT pg_temp.phase6c1_expect_error(
  $$SELECT public.find_invoice_line_exact_identity('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000301', '3980143')$$,
  'permission denied');
SELECT pg_temp.phase6c1_expect_error(
  $$SELECT public.apply_invoice_exact_product_identities('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000701')$$,
  'permission denied');
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c100000-0000-4000-8000-000000000002', true);
SELECT pg_temp.phase6c1_expect_error(
  $$SELECT public.resolve_invoice_exact_product_identities('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000601')$$,
  'Forbidden: owner access required');
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c100000-0000-4000-8000-000000000003', true);
SELECT pg_temp.phase6c1_expect_error(
  $$SELECT public.resolve_invoice_exact_product_identities('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000601')$$,
  'Forbidden: owner access required');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.phase6c1_expect_error(
  $$SELECT public.resolve_invoice_exact_product_identities('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000601')$$,
  'permission denied');
RESET ROLE;
DO $phase6c1_check_16_isolation$
BEGIN
  IF (SELECT count(*) FROM public.products WHERE catalog_product_id = '6c100000-0000-4000-8000-000000000211') <> 2
     OR (SELECT count(DISTINCT organization_id) FROM public.products WHERE catalog_product_id = '6c100000-0000-4000-8000-000000000211') <> 2 THEN
    RAISE EXCEPTION 'Check 16 failed: adoption crossed organizations';
  END IF;
END
$phase6c1_check_16_isolation$;

-- Check 17: posting is still a separate human action, and auto-resolved lines post
-- through the unchanged Phase 2D path (which, as before, is what receives inventory).
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c100000-0000-4000-8000-000000000001', true);
SELECT public.resolve_invoice_exact_product_identities('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000606');
DO $phase6c1_check_17_pre$
BEGIN
  IF (SELECT processing_status FROM public.invoices WHERE id = '6c100000-0000-4000-8000-000000000706') <> 'review_required'
     OR (SELECT posted_at FROM public.invoices WHERE id = '6c100000-0000-4000-8000-000000000706') IS NOT NULL
     OR (pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000861')).product_match_source IS DISTINCT FROM 'org_vendor_sku_match_key' THEN
    RAISE EXCEPTION 'Check 17 failed: resolution posted or did not resolve the invoice';
  END IF;
END
$phase6c1_check_17_pre$;
SELECT public.post_reviewed_invoice('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000606');
RESET ROLE;
DO $phase6c1_check_17$
DECLARE _line public.invoice_items := pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000861');
BEGIN
  IF (SELECT processing_status FROM public.invoices WHERE id = '6c100000-0000-4000-8000-000000000706') <> 'completed'
     OR _line.review_status <> 'approved'
     OR _line.product_match_source IS DISTINCT FROM 'org_vendor_sku_match_key'
     OR NOT EXISTS (SELECT 1 FROM public.inventory_price_history WHERE invoice_item_id = _line.id AND vendor_product_id = _line.vendor_product_id AND package_size IS NULL)
     OR (SELECT quantity FROM public.inventory_items WHERE product_id = _line.product_id) <> 5 THEN
    RAISE EXCEPTION 'Check 17 failed: posting an auto-resolved line changed behavior: %', to_jsonb(_line);
  END IF;
END
$phase6c1_check_17$;

-- Check 18: completed invoices are never resolved again.
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c100000-0000-4000-8000-000000000001', true);
DO $phase6c1_check_18$
BEGIN
  IF public.resolve_invoice_exact_product_identities('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000606')->>'skipped' <> 'completed' THEN
    RAISE EXCEPTION 'Check 18 failed: completed invoice was processed';
  END IF;
END
$phase6c1_check_18$;
RESET ROLE;

-- Posting boundary. post_reviewed_invoice must refuse unresolved lines on its own and
-- must post exactly the identity the owner reviewed, never one inferred from SKU,
-- inventory, or product names, and never remember a vendor SKU the review left unset.
CREATE FUNCTION pg_temp.phase6c1_posting_effects()
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT jsonb_build_object(
    'products', (SELECT jsonb_agg(to_jsonb(p) - 'updated_at' ORDER BY p.id) FROM public.products p WHERE p.organization_id = '6c100000-0000-4000-8000-000000000101'),
    'vendors', (SELECT count(*) FROM public.vendors WHERE organization_id = '6c100000-0000-4000-8000-000000000101'),
    'vendorProducts', (SELECT jsonb_agg(to_jsonb(vp) - 'updated_at' ORDER BY vp.id) FROM public.vendor_products vp WHERE vp.organization_id = '6c100000-0000-4000-8000-000000000101'),
    'inventory', (SELECT jsonb_agg(to_jsonb(i) - 'updated_at' ORDER BY i.id) FROM public.inventory_items i WHERE i.organization_id = '6c100000-0000-4000-8000-000000000101'),
    'adjustments', (SELECT count(*) FROM public.inventory_adjustments WHERE organization_id = '6c100000-0000-4000-8000-000000000101'),
    'priceHistory', (SELECT count(*) FROM public.inventory_price_history WHERE organization_id = '6c100000-0000-4000-8000-000000000101'),
    'invoices', (SELECT jsonb_agg(jsonb_build_object('id', id, 'status', processing_status, 'posted', posted_at, 'vendor', vendor_id) ORDER BY id) FROM public.invoices WHERE organization_id = '6c100000-0000-4000-8000-000000000101'),
    'lines', (SELECT jsonb_agg(jsonb_build_object('id', id, 'product', product_id, 'mapping', vendor_product_id, 'status', review_status) ORDER BY id) FROM public.invoice_items WHERE organization_id = '6c100000-0000-4000-8000-000000000101'),
    'jobs', (SELECT jsonb_agg(jsonb_build_object('id', id, 'status', status) ORDER BY id) FROM public.invoice_processing_jobs WHERE organization_id = '6c100000-0000-4000-8000-000000000101')
  )
$$;

-- An inventory record whose SKU belongs to another vendor's item.
INSERT INTO public.inventory_items (id, organization_id, product_id, sku, name, unit, quantity, vendor_name)
VALUES ('6c100000-0000-4000-8000-000000000951', '6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000403', 'XV-INV-1', 'Medline glove stock', 'box', 7, 'Medline');

INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type)
SELECT ('6c100000-0000-4000-8000-0000000006' || n)::uuid, '6c100000-0000-4000-8000-000000000101',
  '6c100000-0000-4000-8000-000000000001', '6c100000-0000-4000-8000-000000000101/phase6c1-post-' || n || '.pdf',
  'phase6c1-post-' || n || '.pdf', 1024, 'application/pdf'
FROM generate_series(11, 15) n;
INSERT INTO public.invoices (id, organization_id, source_file_id, vendor_id, vendor_name, invoice_number, processing_status)
SELECT ('6c100000-0000-4000-8000-0000000007' || n)::uuid, '6c100000-0000-4000-8000-000000000101',
  ('6c100000-0000-4000-8000-0000000006' || n)::uuid, '6c100000-0000-4000-8000-000000000301', 'Henry Schein',
  'HS-6C1-POST-' || n, 'review_required'
FROM generate_series(11, 15) n;

INSERT INTO public.invoice_items (id, invoice_id, organization_id, line_number, sku, description, quantity, unit_of_measure, unit_price, total_price)
VALUES
  -- Invoice 711: every legacy fallback would have produced an identity for these lines.
  ('6c100000-0000-4000-8000-000000000871', '6c100000-0000-4000-8000-000000000711', '6c100000-0000-4000-8000-000000000101', 1, '1127149', 'Vendor SKU has a remembered mapping', 1, 'EA', 1, 1),
  ('6c100000-0000-4000-8000-000000000872', '6c100000-0000-4000-8000-000000000711', '6c100000-0000-4000-8000-000000000101', 2, 'XV-INV-1', 'Inventory SKU from another vendor', 1, 'EA', 1, 1),
  ('6c100000-0000-4000-8000-000000000873', '6c100000-0000-4000-8000-000000000711', '6c100000-0000-4000-8000-000000000101', 3, NULL, 'Canonical Tape', 1, 'EA', 1, 1),
  ('6c100000-0000-4000-8000-000000000874', '6c100000-0000-4000-8000-000000000711', '6c100000-0000-4000-8000-000000000101', 4, 'BRAND-NEW', 'Brand new product text', 1, 'EA', 1, 1),
  ('6c100000-0000-4000-8000-000000000875', '6c100000-0000-4000-8000-000000000711', '6c100000-0000-4000-8000-000000000101', 5, '3980143', 'Resolved line on an unresolved invoice', 1, 'BX', 1, 1),
  -- Invoice 712: fully reviewed, through each kind of decision.
  ('6c100000-0000-4000-8000-000000000881', '6c100000-0000-4000-8000-000000000712', '6c100000-0000-4000-8000-000000000101', 1, '1127149', 'Local Sharps Container', 2, 'EA', 3, 6),
  ('6c100000-0000-4000-8000-000000000882', '6c100000-0000-4000-8000-000000000712', '6c100000-0000-4000-8000-000000000101', 2, 'NEVER-REMEMBER', 'Owner chose not to remember', 1, 'EA', 4, 4),
  ('6c100000-0000-4000-8000-000000000883', '6c100000-0000-4000-8000-000000000712', '6c100000-0000-4000-8000-000000000101', 3, 'XV-INV-1', 'Owner matched; SKU collides with other-vendor inventory', 3, 'EA', 5, 15),
  ('6c100000-0000-4000-8000-000000000884', '6c100000-0000-4000-8000-000000000712', '6c100000-0000-4000-8000-000000000101', 4, '3980143', 'Ammex Black PF Nitrile Gl Medium', 2, 'BX', 9.5, 19),
  ('6c100000-0000-4000-8000-000000000885', '6c100000-0000-4000-8000-000000000712', '6c100000-0000-4000-8000-000000000101', 5, 'REMEMBER-ME', 'Owner chose to remember', 1, 'EA', 2, 2),
  -- Invoices 713-715: one invalid reviewed mapping each.
  ('6c100000-0000-4000-8000-000000000891', '6c100000-0000-4000-8000-000000000713', '6c100000-0000-4000-8000-000000000101', 1, 'AB-12', 'Mapping names another product', 1, 'EA', 1, 1),
  ('6c100000-0000-4000-8000-000000000892', '6c100000-0000-4000-8000-000000000714', '6c100000-0000-4000-8000-000000000101', 1, 'ML-4410', 'Mapping belongs to another vendor', 1, 'EA', 1, 1),
  ('6c100000-0000-4000-8000-000000000893', '6c100000-0000-4000-8000-000000000715', '6c100000-0000-4000-8000-000000000101', 1, 'FORGOT-1', 'Mapping was deactivated', 1, 'EA', 1, 1);

-- Raw (migration-role) links standing in for stale or tampered reviewed state.
UPDATE public.invoice_items SET product_id = '6c100000-0000-4000-8000-000000000401', vendor_product_id = '6c100000-0000-4000-8000-000000000502'
WHERE id = '6c100000-0000-4000-8000-000000000891';
UPDATE public.invoice_items SET product_id = vp.product_id, vendor_product_id = vp.id
FROM public.vendor_products vp
WHERE invoice_items.id = '6c100000-0000-4000-8000-000000000892'
  AND vp.organization_id = '6c100000-0000-4000-8000-000000000101'
  AND vp.catalog_vendor_product_id = '6c100000-0000-4000-8000-000000000225';
UPDATE public.invoice_items SET product_id = '6c100000-0000-4000-8000-000000000407', vendor_product_id = '6c100000-0000-4000-8000-000000000504'
WHERE id = '6c100000-0000-4000-8000-000000000893';

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c100000-0000-4000-8000-000000000001', true);
SELECT public.resolve_invoice_exact_product_identities('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000611');
SELECT public.resolve_invoice_exact_product_identities('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000612');
-- The owner removed line 871's automatic match; legacy posting would re-find mapping 501 by SKU.
SELECT public.unlink_invoice_item_product('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000611',
  '6c100000-0000-4000-8000-000000000871', false);
-- Owner decisions on invoice 712: a name-equal, SKU-mapped line matched elsewhere without
-- remembering; an unmapped SKU not remembered; an other-vendor inventory SKU matched to a
-- different product; a remembered manual match. Line 884 resolves automatically.
SELECT public.confirm_invoice_item_product('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000612',
  '6c100000-0000-4000-8000-000000000881', '6c100000-0000-4000-8000-000000000402', false);
SELECT public.confirm_invoice_item_product('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000612',
  '6c100000-0000-4000-8000-000000000882', '6c100000-0000-4000-8000-000000000406', false);
SELECT public.confirm_invoice_item_product('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000612',
  '6c100000-0000-4000-8000-000000000883', '6c100000-0000-4000-8000-000000000405', false);
SELECT public.confirm_invoice_item_product('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000612',
  '6c100000-0000-4000-8000-000000000885', '6c100000-0000-4000-8000-000000000404', true);
RESET ROLE;

-- Line 881 was resolved to mapping 501 before the owner re-matched it without remembering.
DO $phase6c1_posting_fixture_check$
BEGIN
  IF (pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000875')).product_match_source IS DISTINCT FROM 'org_vendor_sku_match_key'
     OR (pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000871')).product_id IS NOT NULL
     OR (pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000881')).vendor_product_id IS NOT NULL
     OR (pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000882')).vendor_product_id IS NOT NULL
     OR (pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000884')).product_match_source IS DISTINCT FROM 'org_vendor_sku_match_key'
     OR (pg_temp.phase6c1_line('6c100000-0000-4000-8000-000000000885')).vendor_product_id IS NULL THEN
    RAISE EXCEPTION 'Posting fixture is not in the expected reviewed state';
  END IF;
END
$phase6c1_posting_fixture_check$;

-- Check 19: a direct owner call cannot post an invoice with unresolved lines, and the
-- refusal comes from the up-front gate before any write.
INSERT INTO phase6c1_snapshots VALUES ('before_unresolved_post', pg_temp.phase6c1_posting_effects());
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c100000-0000-4000-8000-000000000001', true);
SELECT pg_temp.phase6c1_expect_error(
  $$SELECT public.post_reviewed_invoice('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000611')$$,
  'Match or create a product for every invoice line before approval (4 unresolved)');
RESET ROLE;
DO $phase6c1_check_19$
BEGIN
  IF pg_temp.phase6c1_posting_effects() IS DISTINCT FROM (SELECT value FROM phase6c1_snapshots WHERE name = 'before_unresolved_post') THEN
    RAISE EXCEPTION 'Check 19 failed: refused posting left side effects';
  END IF;
  IF EXISTS (SELECT 1 FROM public.products WHERE organization_id = '6c100000-0000-4000-8000-000000000101' AND name = 'Brand new product text')
     OR EXISTS (SELECT 1 FROM public.vendor_products WHERE organization_id = '6c100000-0000-4000-8000-000000000101' AND vendor_sku IN ('BRAND-NEW', 'XV-INV-1'))
     OR EXISTS (SELECT 1 FROM public.inventory_adjustments WHERE source_invoice_id = '6c100000-0000-4000-8000-000000000711')
     OR EXISTS (SELECT 1 FROM public.inventory_price_history WHERE invoice_id = '6c100000-0000-4000-8000-000000000711')
     OR (SELECT processing_status FROM public.invoices WHERE id = '6c100000-0000-4000-8000-000000000711') <> 'review_required'
     OR (SELECT posted_at FROM public.invoices WHERE id = '6c100000-0000-4000-8000-000000000711') IS NOT NULL
     OR (SELECT quantity FROM public.inventory_items WHERE id = '6c100000-0000-4000-8000-000000000951') <> 7 THEN
    RAISE EXCEPTION 'Check 19 failed: unresolved posting created identity, inventory, or completion';
  END IF;
END
$phase6c1_check_19$;

-- Check 20: posting a completed invoice again stays an idempotent no-op.
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c100000-0000-4000-8000-000000000001', true);
DO $phase6c1_check_20$
DECLARE _before jsonb := pg_temp.phase6c1_posting_effects(); _result jsonb;
BEGIN
  _result := public.post_reviewed_invoice('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000606');
  IF _result->>'alreadyCompleted' <> 'true' OR pg_temp.phase6c1_posting_effects() IS DISTINCT FROM _before THEN
    RAISE EXCEPTION 'Check 20 failed: completed invoice posted again: %', _result;
  END IF;
END
$phase6c1_check_20$;

-- Check 21: the ordinary approved path posts exactly the reviewed identities.
DO $phase6c1_check_21_app_gate$
BEGIN
  -- The application refuses approval while any line is unlinked; this invoice passes.
  IF EXISTS (SELECT 1 FROM public.invoice_items WHERE invoice_id = '6c100000-0000-4000-8000-000000000712' AND product_id IS NULL) THEN
    RAISE EXCEPTION 'Check 21 failed: reviewed invoice still has unresolved lines';
  END IF;
END
$phase6c1_check_21_app_gate$;
INSERT INTO phase6c1_snapshots VALUES ('mapping_501_before_post', (SELECT to_jsonb(vp) - 'updated_at' FROM public.vendor_products vp WHERE id = '6c100000-0000-4000-8000-000000000501'));
INSERT INTO phase6c1_snapshots VALUES ('post_712', public.post_reviewed_invoice('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000612'));
RESET ROLE;
DO $phase6c1_check_21$
DECLARE
  _line public.invoice_items;
  _expected record;
BEGIN
  IF (SELECT processing_status FROM public.invoices WHERE id = '6c100000-0000-4000-8000-000000000712') <> 'completed'
     OR (SELECT value->>'alreadyCompleted' FROM phase6c1_snapshots WHERE name = 'post_712') <> 'false' THEN
    RAISE EXCEPTION 'Check 21 failed: reviewed invoice did not post';
  END IF;
  -- Every line posts its reviewed product and mapping, approved, with one adjustment and
  -- one price observation carrying the same identity.
  FOR _line IN SELECT * FROM public.invoice_items WHERE invoice_id = '6c100000-0000-4000-8000-000000000712' LOOP
    IF _line.review_status <> 'approved'
       OR (SELECT count(*) FROM public.inventory_price_history h
           WHERE h.invoice_item_id = _line.id AND h.product_id = _line.product_id
             AND h.vendor_product_id IS NOT DISTINCT FROM _line.vendor_product_id) <> 1
       OR (SELECT count(*) FROM public.inventory_adjustments a JOIN public.inventory_items i ON i.id = a.inventory_item_id
           WHERE a.source_invoice_item_id = _line.id AND i.product_id = _line.product_id AND a.adjustment_amount = _line.quantity) <> 1 THEN
      RAISE EXCEPTION 'Check 21 failed: line % did not post its reviewed identity', to_jsonb(_line);
    END IF;
  END LOOP;
  -- Reviewed identities, not legacy inference: 881 keeps the owner's product even though its
  -- SKU maps to, and its description names, product 401; 883 ignores the other-vendor
  -- inventory SKU; lines without a remembered mapping stay without one.
  FOR _expected IN SELECT * FROM (VALUES
    ('6c100000-0000-4000-8000-000000000881'::uuid, '6c100000-0000-4000-8000-000000000402'::uuid, false),
    ('6c100000-0000-4000-8000-000000000882'::uuid, '6c100000-0000-4000-8000-000000000406'::uuid, false),
    ('6c100000-0000-4000-8000-000000000883'::uuid, '6c100000-0000-4000-8000-000000000405'::uuid, false),
    ('6c100000-0000-4000-8000-000000000885'::uuid, '6c100000-0000-4000-8000-000000000404'::uuid, true)
  ) expected(line_id, product_id, mapped) LOOP
    _line := pg_temp.phase6c1_line(_expected.line_id);
    IF _line.product_id IS DISTINCT FROM _expected.product_id OR (_line.vendor_product_id IS NOT NULL) <> _expected.mapped THEN
      RAISE EXCEPTION 'Check 21 failed: line % posted as %', _expected.line_id, to_jsonb(_line);
    END IF;
  END LOOP;
  IF (SELECT to_jsonb(vp) - 'updated_at' FROM public.vendor_products vp WHERE id = '6c100000-0000-4000-8000-000000000501')
       IS DISTINCT FROM (SELECT value FROM phase6c1_snapshots WHERE name = 'mapping_501_before_post') THEN
    RAISE EXCEPTION 'Check 21 failed: posting repointed or changed the remembered 1127149 mapping';
  END IF;
  IF EXISTS (SELECT 1 FROM public.vendor_products WHERE organization_id = '6c100000-0000-4000-8000-000000000101' AND vendor_sku IN ('NEVER-REMEMBER', 'XV-INV-1')) THEN
    RAISE EXCEPTION 'Check 21 failed: posting remembered a vendor SKU the owner chose not to remember';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.vendor_products WHERE organization_id = '6c100000-0000-4000-8000-000000000101' AND vendor_sku = 'REMEMBER-ME' AND product_id = '6c100000-0000-4000-8000-000000000404' AND active) THEN
    RAISE EXCEPTION 'Check 21 failed: remembered manual mapping missing';
  END IF;
  IF (SELECT quantity FROM public.inventory_items WHERE id = '6c100000-0000-4000-8000-000000000951') <> 7
     OR (SELECT quantity FROM public.inventory_items WHERE organization_id = '6c100000-0000-4000-8000-000000000101' AND product_id = '6c100000-0000-4000-8000-000000000405') <> 3
     OR (SELECT quantity FROM public.inventory_items WHERE organization_id = '6c100000-0000-4000-8000-000000000101' AND product_id = '6c100000-0000-4000-8000-000000000402') <> 2
     OR EXISTS (SELECT 1 FROM public.inventory_items WHERE organization_id = '6c100000-0000-4000-8000-000000000101' AND product_id = '6c100000-0000-4000-8000-000000000401') THEN
    RAISE EXCEPTION 'Check 21 failed: inventory was posted to an inferred product';
  END IF;
  -- The automatic line adds to the stock created when invoice 706 was posted.
  IF (SELECT i.quantity FROM public.inventory_items i JOIN public.invoice_items l ON l.product_id = i.product_id
      WHERE l.id = '6c100000-0000-4000-8000-000000000884') <> 7 THEN
    RAISE EXCEPTION 'Check 21 failed: automatic line did not accumulate onto existing stock';
  END IF;
END
$phase6c1_check_21$;

-- Checks 22-24: a reviewed mapping must name the line's product, belong to the invoice
-- vendor, and be active; otherwise posting is refused with no side effects.
INSERT INTO phase6c1_snapshots VALUES ('before_bad_mappings', pg_temp.phase6c1_posting_effects());
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c100000-0000-4000-8000-000000000001', true);
SELECT pg_temp.phase6c1_expect_error(
  $$SELECT public.post_reviewed_invoice('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000613')$$,
  'A selected vendor product maps to a different product than the invoice line');
SELECT pg_temp.phase6c1_expect_error(
  $$SELECT public.post_reviewed_invoice('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000614')$$,
  'A selected vendor product is unavailable');
SELECT pg_temp.phase6c1_expect_error(
  $$SELECT public.post_reviewed_invoice('6c100000-0000-4000-8000-000000000101', '6c100000-0000-4000-8000-000000000615')$$,
  'A selected vendor product is unavailable');
RESET ROLE;
DO $phase6c1_check_22_24$
BEGIN
  IF pg_temp.phase6c1_posting_effects() IS DISTINCT FROM (SELECT value FROM phase6c1_snapshots WHERE name = 'before_bad_mappings') THEN
    RAISE EXCEPTION 'Checks 22-24 failed: a refused posting left side effects';
  END IF;
END
$phase6c1_check_22_24$;

SELECT 24 AS checks_passed, 0 AS checks_failed;

ROLLBACK;
