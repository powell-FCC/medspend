-- Phase 7A.1 backfill fixture: a committed, pre-7A.1 inventory history built through the
-- real main-branch functions (posting, manual adjustment), for supabase/tests/phase7a1_backfill_check.sh.
-- Two organizations; integer, fractional, zero and archived items; posted invoices with full
-- provenance; manual adjustments; a budget and a request. Run as postgres BEFORE the 7A.1
-- migration on a disposable database.

INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
VALUES
  ('7a1b0000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'phase7a1-backfill-owner@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('7a1b0000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'phase7a1-backfill-other@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('7a1b0000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'phase7a1-backfill-staff@example.invalid', '', now(), '{}', '{}', now(), now());

INSERT INTO public.organizations (id, name, created_by)
VALUES
  ('7a1b0000-0000-4000-8000-000000000101', 'Phase 7A.1 Backfill A', '7a1b0000-0000-4000-8000-000000000001'),
  ('7a1b0000-0000-4000-8000-000000000102', 'Phase 7A.1 Backfill B', '7a1b0000-0000-4000-8000-000000000002'),
  ('7a1b0000-0000-4000-8000-000000000103', 'Phase 7A.1 Backfill Empty', '7a1b0000-0000-4000-8000-000000000002');

INSERT INTO public.organization_memberships (organization_id, user_id, role, active)
VALUES
  ('7a1b0000-0000-4000-8000-000000000101', '7a1b0000-0000-4000-8000-000000000001', 'owner', true),
  ('7a1b0000-0000-4000-8000-000000000101', '7a1b0000-0000-4000-8000-000000000003', 'staff', true),
  ('7a1b0000-0000-4000-8000-000000000102', '7a1b0000-0000-4000-8000-000000000002', 'owner', true),
  ('7a1b0000-0000-4000-8000-000000000103', '7a1b0000-0000-4000-8000-000000000002', 'owner', true);

INSERT INTO public.locations (id, organization_id, name, active)
VALUES ('7a1b0000-0000-4000-8000-000000000121', '7a1b0000-0000-4000-8000-000000000101', 'Backfill Main Campus', true);

INSERT INTO public.vendors (id, organization_id, name, normalized_name, active)
VALUES
  ('7a1b0000-0000-4000-8000-000000000301', '7a1b0000-0000-4000-8000-000000000101', 'Backfill Vendor', 'backfill vendor', true),
  ('7a1b0000-0000-4000-8000-000000000302', '7a1b0000-0000-4000-8000-000000000102', 'Backfill Vendor', 'backfill vendor', true);

INSERT INTO public.products (id, organization_id, name, normalized_name, unit_of_measure, approved, active, staff_requestable)
VALUES
  ('7a1b0000-0000-4000-8000-000000000401', '7a1b0000-0000-4000-8000-000000000101', 'Backfill Tape', 'backfill tape', 'roll', true, true, true),
  ('7a1b0000-0000-4000-8000-000000000402', '7a1b0000-0000-4000-8000-000000000101', 'Backfill Gauze', 'backfill gauze', 'box', true, true, true),
  ('7a1b0000-0000-4000-8000-000000000403', '7a1b0000-0000-4000-8000-000000000102', 'Backfill Other Tape', 'backfill other tape', 'roll', true, true, true);

-- Items that predate the ledger (stock without history), as early production rows do.
INSERT INTO public.inventory_items (id, organization_id, sku, name, unit, quantity, active)
VALUES
  ('7a1b0000-0000-4000-8000-000000000501', '7a1b0000-0000-4000-8000-000000000101', 'LEGACY-1', 'Backfill Legacy Splint', 'each', 12.333333, true),
  ('7a1b0000-0000-4000-8000-000000000502', '7a1b0000-0000-4000-8000-000000000101', 'ZERO-1', 'Backfill Zero Item', 'each', 0, true),
  ('7a1b0000-0000-4000-8000-000000000503', '7a1b0000-0000-4000-8000-000000000101', 'OLD-1', 'Backfill Archived Item', 'each', 7, false),
  ('7a1b0000-0000-4000-8000-000000000504', '7a1b0000-0000-4000-8000-000000000102', 'B-1', 'Backfill B Item', 'each', 0.5, true);

INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type)
VALUES
  ('7a1b0000-0000-4000-8000-000000000601', '7a1b0000-0000-4000-8000-000000000101', '7a1b0000-0000-4000-8000-000000000001', '7a1b0000-0000-4000-8000-000000000101/backfill-1.pdf', 'backfill-1.pdf', 1024, 'application/pdf'),
  ('7a1b0000-0000-4000-8000-000000000602', '7a1b0000-0000-4000-8000-000000000101', '7a1b0000-0000-4000-8000-000000000001', '7a1b0000-0000-4000-8000-000000000101/backfill-2.pdf', 'backfill-2.pdf', 1024, 'application/pdf'),
  ('7a1b0000-0000-4000-8000-000000000603', '7a1b0000-0000-4000-8000-000000000102', '7a1b0000-0000-4000-8000-000000000002', '7a1b0000-0000-4000-8000-000000000102/backfill-3.pdf', 'backfill-3.pdf', 1024, 'application/pdf');

INSERT INTO public.invoices (id, organization_id, source_file_id, vendor_id, vendor_name, invoice_number, processing_status, invoice_date)
VALUES
  ('7a1b0000-0000-4000-8000-000000000701', '7a1b0000-0000-4000-8000-000000000101', '7a1b0000-0000-4000-8000-000000000601', '7a1b0000-0000-4000-8000-000000000301', 'Backfill Vendor', 'BF-1', 'review_required', '2026-09-01'),
  ('7a1b0000-0000-4000-8000-000000000702', '7a1b0000-0000-4000-8000-000000000101', '7a1b0000-0000-4000-8000-000000000602', '7a1b0000-0000-4000-8000-000000000301', 'Backfill Vendor', 'BF-2', 'review_required', '2026-09-05'),
  ('7a1b0000-0000-4000-8000-000000000703', '7a1b0000-0000-4000-8000-000000000102', '7a1b0000-0000-4000-8000-000000000603', '7a1b0000-0000-4000-8000-000000000302', 'Backfill Vendor', 'BF-3', 'review_required', '2026-09-07');

INSERT INTO public.invoice_items (id, invoice_id, organization_id, line_number, sku, description, quantity, unit_of_measure, unit_price, total_price, product_id)
VALUES
  ('7a1b0000-0000-4000-8000-000000000801', '7a1b0000-0000-4000-8000-000000000701', '7a1b0000-0000-4000-8000-000000000101', 1, 'TAPE-1', 'Backfill Tape', 120, 'roll', 2.1, 252, '7a1b0000-0000-4000-8000-000000000401'),
  ('7a1b0000-0000-4000-8000-000000000802', '7a1b0000-0000-4000-8000-000000000701', '7a1b0000-0000-4000-8000-000000000101', 2, 'GAUZE-1', 'Backfill Gauze', 3.75, 'box', 8, 30, '7a1b0000-0000-4000-8000-000000000402'),
  ('7a1b0000-0000-4000-8000-000000000803', '7a1b0000-0000-4000-8000-000000000702', '7a1b0000-0000-4000-8000-000000000101', 1, 'TAPE-1', 'Backfill Tape', 30, 'roll', 2.2, 66, '7a1b0000-0000-4000-8000-000000000401'),
  ('7a1b0000-0000-4000-8000-000000000804', '7a1b0000-0000-4000-8000-000000000703', '7a1b0000-0000-4000-8000-000000000102', 1, 'OTHER-1', 'Backfill Other Tape', 9, 'roll', 1, 9, '7a1b0000-0000-4000-8000-000000000403');

INSERT INTO public.organization_budgets (organization_id, name, period_start, period_end, amount)
VALUES ('7a1b0000-0000-4000-8000-000000000101', 'Backfill FY26', '2026-07-01', '2027-06-30', 25000);

INSERT INTO public.supply_requests (id, organization_id, requested_by, request_type, location_id, notes, status)
VALUES ('7a1b0000-0000-4000-8000-000000000901', '7a1b0000-0000-4000-8000-000000000101', '7a1b0000-0000-4000-8000-000000000003',
  'new_item', '7a1b0000-0000-4000-8000-000000000121', 'Backfill request', 'submitted');

-- Real history through main's functions, as the owner.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '7a1b0000-0000-4000-8000-000000000001', false);
SELECT public.post_reviewed_invoice('7a1b0000-0000-4000-8000-000000000101', '7a1b0000-0000-4000-8000-000000000601');
SELECT public.post_reviewed_invoice('7a1b0000-0000-4000-8000-000000000101', '7a1b0000-0000-4000-8000-000000000602');
SELECT public.adjust_inventory_quantity('7a1b0000-0000-4000-8000-000000000101',
  (SELECT id FROM public.inventory_items WHERE product_id = '7a1b0000-0000-4000-8000-000000000401'), -17.5, 'Damaged');
SELECT public.adjust_inventory_quantity('7a1b0000-0000-4000-8000-000000000101', '7a1b0000-0000-4000-8000-000000000501', 2, 'Correction');
SELECT pg_catalog.set_config('request.jwt.claim.sub', '7a1b0000-0000-4000-8000-000000000002', false);
SELECT public.post_reviewed_invoice('7a1b0000-0000-4000-8000-000000000102', '7a1b0000-0000-4000-8000-000000000603');
SELECT pg_catalog.set_config('request.jwt.claim.sub', '', false);
