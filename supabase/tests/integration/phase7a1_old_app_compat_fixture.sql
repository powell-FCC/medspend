-- Fixture for tests/phase7a1-old-app-compat.test.ts. Runs as postgres AFTER
-- phase7a1_backfill_fixture.sql, on a local disposable database only; this file commits its rows.
-- Adds an admin, an unposted invoice and an adoptable catalog listing, so the currently deployed
-- (main f8a60fd) application's inventory, posting, deletion and stocking calls can be replayed.

INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
VALUES ('7a1b0000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'phase7a1-compat-admin@example.invalid', '', now(), '{}', '{}', now(), now());

INSERT INTO public.organization_memberships (organization_id, user_id, role, active)
VALUES ('7a1b0000-0000-4000-8000-000000000101', '7a1b0000-0000-4000-8000-000000000004', 'admin', true);

INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type)
VALUES ('7a1b0000-0000-4000-8000-000000000604', '7a1b0000-0000-4000-8000-000000000101', '7a1b0000-0000-4000-8000-000000000001',
  '7a1b0000-0000-4000-8000-000000000101/compat-4.pdf', 'compat-4.pdf', 1024, 'application/pdf');
INSERT INTO public.invoices (id, organization_id, source_file_id, vendor_id, vendor_name, invoice_number, processing_status, invoice_date)
VALUES ('7a1b0000-0000-4000-8000-000000000704', '7a1b0000-0000-4000-8000-000000000101', '7a1b0000-0000-4000-8000-000000000604',
  '7a1b0000-0000-4000-8000-000000000301', 'Backfill Vendor', 'COMPAT-4', 'review_required', '2026-10-10');
INSERT INTO public.invoice_items (id, invoice_id, organization_id, line_number, sku, description, quantity, unit_of_measure, unit_price, total_price, product_id)
VALUES ('7a1b0000-0000-4000-8000-000000000805', '7a1b0000-0000-4000-8000-000000000704', '7a1b0000-0000-4000-8000-000000000101', 1,
  'TAPE-1', 'Backfill Tape', 12.5, 'roll', 2, 25, '7a1b0000-0000-4000-8000-000000000401');

INSERT INTO public.catalog_vendors (id, name, normalized_name)
VALUES ('7a1b0000-0000-4000-8000-000000000201', 'Compat Catalog Vendor', 'placeholder');
INSERT INTO public.catalog_products (id, name, manufacturer, active, verification_status)
VALUES ('7a1b0000-0000-4000-8000-000000000211', 'Compat Cold Pack', NULL, true, 'verified');
INSERT INTO public.catalog_vendor_products (id, catalog_vendor_id, catalog_product_id, vendor_sku, normalized_vendor_sku,
  package_description, package_status, active, discontinued, verification_status)
VALUES ('7a1b0000-0000-4000-8000-000000000231', '7a1b0000-0000-4000-8000-000000000201', '7a1b0000-0000-4000-8000-000000000211',
  'CP-100', 'x', '24/Cs', 'source_only', true, false, 'verified');
INSERT INTO public.vendors (id, organization_id, name, normalized_name, active, catalog_vendor_id)
VALUES ('7a1b0000-0000-4000-8000-000000000303', '7a1b0000-0000-4000-8000-000000000101', 'Compat Catalog Vendor',
  'compat catalog vendor', true, '7a1b0000-0000-4000-8000-000000000201');
