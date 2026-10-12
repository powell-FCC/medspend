-- Fixture for tests/invoice-review-server-integration.test.ts. Local disposable database
-- only; this file commits its rows. Run as postgres after every migration.

INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
VALUES
  ('c0de0000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'itest-owner@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('c0de0000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'itest-admin@example.invalid', '', now(), '{}', '{}', now(), now());

INSERT INTO public.organizations (id, name, created_by)
VALUES ('c0de0000-0000-4000-8000-000000000101', 'Integration Athletics', 'c0de0000-0000-4000-8000-000000000001');

INSERT INTO public.organization_memberships (id, organization_id, user_id, role, active)
VALUES
  ('c0de0000-0000-4000-8000-000000000111', 'c0de0000-0000-4000-8000-000000000101', 'c0de0000-0000-4000-8000-000000000001', 'owner', true),
  ('c0de0000-0000-4000-8000-000000000112', 'c0de0000-0000-4000-8000-000000000101', 'c0de0000-0000-4000-8000-000000000002', 'admin', true);

INSERT INTO public.catalog_vendors (id, name, normalized_name)
VALUES
  ('c0de0000-0000-4000-8000-000000000201', 'Henry Schein', 'placeholder'),
  ('c0de0000-0000-4000-8000-000000000202', 'Medline', 'placeholder');

INSERT INTO public.catalog_products (id, name, manufacturer, active, verification_status)
VALUES
  ('c0de0000-0000-4000-8000-000000000211', 'Ready Wrap Plastic Wrap', NULL, true, 'verified'),
  ('c0de0000-0000-4000-8000-000000000212', 'Hydrofilm Transparent Dressing 4x6', 'Hartmann', true, 'verified'),
  ('c0de0000-0000-4000-8000-000000000213', 'Ready Wrap Mini', NULL, true, 'verified'),
  ('c0de0000-0000-4000-8000-000000000214', 'Medline Hydrofilm Transparent Dressing', NULL, true, 'verified'),
  ('c0de0000-0000-4000-8000-000000000215', 'Collision Named Catalog Product', NULL, true, 'verified');

INSERT INTO public.catalog_vendor_products (id, catalog_vendor_id, catalog_product_id, vendor_sku, normalized_vendor_sku, package_description, package_status, active, discontinued, verification_status)
VALUES
  ('c0de0000-0000-4000-8000-000000000231', 'c0de0000-0000-4000-8000-000000000201', 'c0de0000-0000-4000-8000-000000000211', '324-0025', 'x', '6Rl/Ca', 'source_only', true, false, 'verified'),
  ('c0de0000-0000-4000-8000-000000000232', 'c0de0000-0000-4000-8000-000000000201', 'c0de0000-0000-4000-8000-000000000212', '143-9000', 'x', '10/Bx', 'source_only', true, false, 'verified'),
  ('c0de0000-0000-4000-8000-000000000233', 'c0de0000-0000-4000-8000-000000000201', 'c0de0000-0000-4000-8000-000000000213', '324-0026', 'x', NULL, 'unknown', true, false, 'verified'),
  -- Another vendor with the same SKU and a similar name.
  ('c0de0000-0000-4000-8000-000000000238', 'c0de0000-0000-4000-8000-000000000202', 'c0de0000-0000-4000-8000-000000000214', '324-0025', 'x', NULL, 'unknown', true, false, 'verified'),
  ('c0de0000-0000-4000-8000-000000000239', 'c0de0000-0000-4000-8000-000000000201', 'c0de0000-0000-4000-8000-000000000215', '888-0001', 'x', NULL, 'unknown', true, false, 'verified');

INSERT INTO public.vendors (id, organization_id, name, normalized_name, active, catalog_vendor_id)
VALUES
  ('c0de0000-0000-4000-8000-000000000301', 'c0de0000-0000-4000-8000-000000000101', 'Henry Schein', 'henry schein', true, 'c0de0000-0000-4000-8000-000000000201'),
  ('c0de0000-0000-4000-8000-000000000302', 'c0de0000-0000-4000-8000-000000000101', 'Medline', 'medline', true, 'c0de0000-0000-4000-8000-000000000202'),
  ('c0de0000-0000-4000-8000-000000000303', 'c0de0000-0000-4000-8000-000000000101', 'Local Supply', 'local supply', true, NULL);

INSERT INTO public.products (id, organization_id, name, normalized_name, approved, active, staff_requestable)
VALUES
  ('c0de0000-0000-4000-8000-000000000401', 'c0de0000-0000-4000-8000-000000000101', 'Existing Organization Tape', 'x', true, true, true),
  ('c0de0000-0000-4000-8000-000000000402', 'c0de0000-0000-4000-8000-000000000101', 'Collision Named Catalog Product', 'x', true, true, true),
  ('c0de0000-0000-4000-8000-000000000403', 'c0de0000-0000-4000-8000-000000000101', 'Stocked Gauze', 'x', true, true, true),
  ('c0de0000-0000-4000-8000-000000000404', 'c0de0000-0000-4000-8000-000000000101', 'Other Gauze', 'x', true, true, true);

-- Product 403 already carries Henry Schein SKU GAUZE-1 in inventory.
INSERT INTO public.inventory_items (id, organization_id, product_id, sku, name, unit, quantity, vendor_name, active)
VALUES ('c0de0000-0000-4000-8000-000000000451', 'c0de0000-0000-4000-8000-000000000101', 'c0de0000-0000-4000-8000-000000000403', 'GAUZE-1', 'Stocked Gauze', 'each', 5, 'Henry Schein', true);

INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type)
SELECT ('c0de0000-0000-4000-8000-0000000006' || lpad(n::text, 2, '0'))::uuid, 'c0de0000-0000-4000-8000-000000000101',
  'c0de0000-0000-4000-8000-000000000001', 'c0de0000-0000-4000-8000-000000000101/itest-' || n || '.pdf', 'itest-' || n || '.pdf', 1024, 'application/pdf'
FROM generate_series(1, 7) n;

INSERT INTO public.invoices (id, organization_id, source_file_id, vendor_id, vendor_name, invoice_number, processing_status, subtotal, tax_amount, shipping_amount, invoice_total, total_amount, total)
VALUES
  ('c0de0000-0000-4000-8000-000000000701', 'c0de0000-0000-4000-8000-000000000101', 'c0de0000-0000-4000-8000-000000000601', 'c0de0000-0000-4000-8000-000000000301', 'Henry Schein', 'IT-MATCH', 'review_required', NULL, NULL, NULL, NULL, NULL, NULL),
  ('c0de0000-0000-4000-8000-000000000702', 'c0de0000-0000-4000-8000-000000000101', 'c0de0000-0000-4000-8000-000000000602', 'c0de0000-0000-4000-8000-000000000303', 'Local Supply', 'IT-UNLINKED', 'review_required', NULL, NULL, NULL, NULL, NULL, NULL),
  ('c0de0000-0000-4000-8000-000000000703', 'c0de0000-0000-4000-8000-000000000101', 'c0de0000-0000-4000-8000-000000000603', 'c0de0000-0000-4000-8000-000000000302', 'Medline', 'IT-MEDLINE', 'review_required', NULL, NULL, NULL, NULL, NULL, NULL),
  ('c0de0000-0000-4000-8000-000000000704', 'c0de0000-0000-4000-8000-000000000101', 'c0de0000-0000-4000-8000-000000000604', 'c0de0000-0000-4000-8000-000000000301', 'Henry Schein', 'IT-POST', 'review_required', NULL, NULL, NULL, NULL, NULL, NULL),
  -- Calculated subtotal and total (no total printed on the document).
  ('c0de0000-0000-4000-8000-000000000705', 'c0de0000-0000-4000-8000-000000000101', 'c0de0000-0000-4000-8000-000000000605', 'c0de0000-0000-4000-8000-000000000301', 'Henry Schein', 'IT-DERIVED-BOTH', 'review_required', 30, 2, 5, 37, 37, 37),
  -- Calculated subtotal, printed total.
  ('c0de0000-0000-4000-8000-000000000706', 'c0de0000-0000-4000-8000-000000000101', 'c0de0000-0000-4000-8000-000000000606', 'c0de0000-0000-4000-8000-000000000301', 'Henry Schein', 'IT-DERIVED-SUBTOTAL', 'review_required', 30, 2, 5, 37, 37, 37),
  -- Printed subtotal and total.
  ('c0de0000-0000-4000-8000-000000000707', 'c0de0000-0000-4000-8000-000000000101', 'c0de0000-0000-4000-8000-000000000607', 'c0de0000-0000-4000-8000-000000000301', 'Henry Schein', 'IT-PRINTED', 'review_required', 30, 2, 5, 37, 37, 37);

INSERT INTO public.invoice_items (id, invoice_id, organization_id, line_number, sku, description, quantity, unit_of_measure, unit_price, total_price)
VALUES
  ('c0de0000-0000-4000-8000-000000000801', 'c0de0000-0000-4000-8000-000000000701', 'c0de0000-0000-4000-8000-000000000101', 1, '3240025', 'Ready Wrap Classic 4"x650 Yd', 1, 'Ca', 38.25, 38.25),
  ('c0de0000-0000-4000-8000-000000000802', 'c0de0000-0000-4000-8000-000000000701', 'c0de0000-0000-4000-8000-000000000101', 2, '1439386', 'Hydrofilm Transparent Dre 4x6"', 3, 'BX', 6.81, 20.43),
  ('c0de0000-0000-4000-8000-000000000803', 'c0de0000-0000-4000-8000-000000000701', 'c0de0000-0000-4000-8000-000000000101', 3, 'HYD-46', 'Hydrofilm 4x6 printed with an old code', 1, 'BX', 6.81, 6.81),
  ('c0de0000-0000-4000-8000-000000000804', 'c0de0000-0000-4000-8000-000000000701', 'c0de0000-0000-4000-8000-000000000101', 4, '8880001', 'Collision named line', 1, 'EA', 4, 4),
  ('c0de0000-0000-4000-8000-000000000805', 'c0de0000-0000-4000-8000-000000000701', 'c0de0000-0000-4000-8000-000000000101', 5, '324-0025', 'Ready Wrap, exact catalog SKU', 1, 'Ca', 38.25, 38.25),
  ('c0de0000-0000-4000-8000-000000000806', 'c0de0000-0000-4000-8000-000000000701', 'c0de0000-0000-4000-8000-000000000101', 6, '3240025', 'Ready Wrap, SKU without separators', 1, 'Ca', 38.25, 38.25),
  ('c0de0000-0000-4000-8000-000000000811', 'c0de0000-0000-4000-8000-000000000702', 'c0de0000-0000-4000-8000-000000000101', 1, '324-0025', 'Ready Wrap from an unlinked vendor', 1, 'EA', 1, 1),
  ('c0de0000-0000-4000-8000-000000000821', 'c0de0000-0000-4000-8000-000000000703', 'c0de0000-0000-4000-8000-000000000101', 1, 'ML-UNKNOWN', 'Medline line', 1, 'EA', 1, 1),
  ('c0de0000-0000-4000-8000-000000000831', 'c0de0000-0000-4000-8000-000000000704', 'c0de0000-0000-4000-8000-000000000101', 1, 'GAUZE-1', 'Gauze printed with a SKU another product holds', 1, 'EA', 2, 2),
  ('c0de0000-0000-4000-8000-000000000851', 'c0de0000-0000-4000-8000-000000000705', 'c0de0000-0000-4000-8000-000000000101', 1, 'D-1', 'Derived both, line one', 2, 'EA', 10, 20),
  ('c0de0000-0000-4000-8000-000000000852', 'c0de0000-0000-4000-8000-000000000705', 'c0de0000-0000-4000-8000-000000000101', 2, 'D-2', 'Derived both, line two', 1, 'EA', 10, 10),
  ('c0de0000-0000-4000-8000-000000000861', 'c0de0000-0000-4000-8000-000000000706', 'c0de0000-0000-4000-8000-000000000101', 1, 'S-1', 'Derived subtotal, line one', 2, 'EA', 10, 20),
  ('c0de0000-0000-4000-8000-000000000862', 'c0de0000-0000-4000-8000-000000000706', 'c0de0000-0000-4000-8000-000000000101', 2, 'S-2', 'Derived subtotal, line two', 1, 'EA', 10, 10),
  ('c0de0000-0000-4000-8000-000000000871', 'c0de0000-0000-4000-8000-000000000707', 'c0de0000-0000-4000-8000-000000000101', 1, 'P-1', 'Printed totals, line one', 2, 'EA', 10, 20),
  ('c0de0000-0000-4000-8000-000000000872', 'c0de0000-0000-4000-8000-000000000707', 'c0de0000-0000-4000-8000-000000000101', 2, 'P-2', 'Printed totals, line two', 1, 'EA', 10, 10);

-- Stored extractions for the three totals invoices. The header says where each amount came
-- from; financialEvidence is what the document gave the parser at extraction.
CREATE FUNCTION pg_temp.itest_extraction(_subtotal_source text, _total_source text)
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT jsonb_build_object(
    'header', jsonb_build_object(
      'documentType', jsonb_build_object('value', 'INVOICE', 'confidence', 96, 'source', 'Parser', 'reviewed', false),
      'vendor', jsonb_build_object('value', 'Henry Schein', 'confidence', 94, 'source', 'Parser', 'reviewed', false),
      'invoiceNumber', jsonb_build_object('value', 'IT-1', 'confidence', 94, 'source', 'Parser', 'reviewed', false),
      'invoiceDate', jsonb_build_object('value', '2026-09-17', 'confidence', 92, 'source', 'Parser', 'reviewed', false),
      'purchaseOrder', jsonb_build_object('value', '', 'confidence', 0, 'source', 'Parser', 'reviewed', false),
      'subtotal', jsonb_build_object('value', 30, 'confidence', CASE _subtotal_source WHEN 'Derived' THEN 60 ELSE 94 END, 'source', _subtotal_source, 'reviewed', false),
      'tax', jsonb_build_object('value', 2, 'confidence', 92, 'source', 'Parser', 'reviewed', false),
      'shipping', jsonb_build_object('value', 5, 'confidence', 88, 'source', 'Parser', 'reviewed', false),
      'total', jsonb_build_object('value', 37, 'confidence', CASE _total_source WHEN 'Derived' THEN 60 ELSE 94 END, 'source', _total_source, 'reviewed', false)
    ),
    'items', '[]'::jsonb,
    'financialEvidence', jsonb_build_object('rejectedLineCandidates', 0, 'unexplainedAmounts', 0),
    'reconciliation', jsonb_build_object('lineItemsMatchSubtotal', NULL, 'componentsMatchTotal', NULL, 'needsReview', false)
  )
$$;

INSERT INTO public.invoice_processing_jobs (organization_id, invoice_id, status, extraction_result)
VALUES
  ('c0de0000-0000-4000-8000-000000000101', 'c0de0000-0000-4000-8000-000000000601', 'review_required', NULL),
  ('c0de0000-0000-4000-8000-000000000101', 'c0de0000-0000-4000-8000-000000000602', 'review_required', NULL),
  ('c0de0000-0000-4000-8000-000000000101', 'c0de0000-0000-4000-8000-000000000603', 'review_required', NULL),
  ('c0de0000-0000-4000-8000-000000000101', 'c0de0000-0000-4000-8000-000000000604', 'review_required', NULL),
  ('c0de0000-0000-4000-8000-000000000101', 'c0de0000-0000-4000-8000-000000000605', 'review_required', pg_temp.itest_extraction('Derived', 'Derived')),
  ('c0de0000-0000-4000-8000-000000000101', 'c0de0000-0000-4000-8000-000000000606', 'review_required', pg_temp.itest_extraction('Derived', 'Parser')),
  ('c0de0000-0000-4000-8000-000000000101', 'c0de0000-0000-4000-8000-000000000607', 'review_required', pg_temp.itest_extraction('Parser', 'Parser'))
-- Uploading an invoice file already created its job row.
ON CONFLICT (invoice_id) DO UPDATE SET status = EXCLUDED.status, extraction_result = EXCLUDED.extraction_result;

-- PostgREST caches the schema; make sure it sees everything the migrations created.
NOTIFY pgrst, 'reload schema';
