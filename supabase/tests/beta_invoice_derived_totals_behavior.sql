-- Beta hardening rollback-only behavioral verification: a calculated (never printed)
-- subtotal or total cannot outlive the line items it was calculated from.
-- Run after 20261012120000_beta_invoice_manual_catalog_matching.sql. All data rolls back.
--
-- The database only withdraws a calculated amount (blank, unreviewed). Recalculating it is
-- the application's job, with the same rules as extraction; that path is covered by
-- tests/invoice-derived-totals.test.ts and tests/invoice-review-server-integration.test.ts.

BEGIN;

CREATE FUNCTION pg_temp.derived_extraction(_subtotal_source text, _total_source text, _subtotal numeric DEFAULT 30, _total numeric DEFAULT 37)
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT jsonb_build_object(
    'header', jsonb_build_object(
      'vendor', jsonb_build_object('value', 'Henry Schein', 'confidence', 94, 'source', 'Parser', 'reviewed', true),
      'invoiceNumber', jsonb_build_object('value', 'D-1', 'confidence', 94, 'source', 'Parser', 'reviewed', true),
      'invoiceDate', jsonb_build_object('value', '2026-09-17', 'confidence', 92, 'source', 'Parser', 'reviewed', true),
      'purchaseOrder', jsonb_build_object('value', '', 'confidence', 0, 'source', 'Parser', 'reviewed', true),
      'subtotal', jsonb_build_object('value', _subtotal, 'confidence', CASE _subtotal_source WHEN 'Derived' THEN 60 WHEN 'User' THEN 100 ELSE 94 END, 'source', _subtotal_source, 'reviewed', true),
      'tax', jsonb_build_object('value', 2, 'confidence', 92, 'source', 'Parser', 'reviewed', true),
      'shipping', jsonb_build_object('value', 5, 'confidence', 88, 'source', 'Parser', 'reviewed', true),
      'total', jsonb_build_object('value', _total, 'confidence', CASE _total_source WHEN 'Derived' THEN 60 WHEN 'User' THEN 100 ELSE 94 END, 'source', _total_source, 'reviewed', true)
    ),
    'items', jsonb_build_array(
      jsonb_build_object(
        'sku', jsonb_build_object('value', 'D-1', 'confidence', 92, 'source', 'Parser', 'reviewed', false),
        'description', jsonb_build_object('value', 'Line one', 'confidence', 90, 'source', 'Parser', 'reviewed', false),
        'manufacturer', jsonb_build_object('value', '', 'confidence', 0, 'source', 'Parser', 'reviewed', false),
        'quantity', jsonb_build_object('value', 2, 'confidence', 96, 'source', 'Parser', 'reviewed', false),
        'unit', jsonb_build_object('value', 'EA', 'confidence', 86, 'source', 'Parser', 'reviewed', false),
        'unitPrice', jsonb_build_object('value', 10, 'confidence', 96, 'source', 'Parser', 'reviewed', false),
        'lineTotal', jsonb_build_object('value', 20, 'confidence', 98, 'source', 'Parser', 'reviewed', false),
        'suggestedCategory', jsonb_build_object('value', '', 'confidence', 0, 'source', 'Parser', 'reviewed', false)
      )
    ),
    'financialEvidence', jsonb_build_object('rejectedLineCandidates', 0, 'unexplainedAmounts', 0),
    'reconciliation', jsonb_build_object('lineItemsMatchSubtotal', NULL, 'componentsMatchTotal', NULL, 'needsReview', false)
  )
$$;

-- An invoice's amounts and how its stored extraction describes them.
CREATE FUNCTION pg_temp.derived_state(_invoice_id uuid)
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT jsonb_build_object(
    'subtotal', invoice.subtotal, 'tax', invoice.tax_amount, 'shipping', invoice.shipping_amount,
    'totals', jsonb_build_array(invoice.invoice_total, invoice.total_amount, invoice.total),
    'subtotalField', job.extraction_result #> '{header,subtotal}',
    'totalField', job.extraction_result #> '{header,total}',
    'taxField', job.extraction_result #> '{header,tax}',
    'rest', job.extraction_result - 'header'
  )
  FROM public.invoices invoice
  LEFT JOIN public.invoice_processing_jobs job ON job.invoice_id = invoice.source_file_id
  WHERE invoice.id = _invoice_id
$$;

CREATE FUNCTION pg_temp.derived_expect(_name text, _invoice_id uuid, _subtotal numeric, _subtotal_field jsonb, _total numeric, _total_field jsonb)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE _state jsonb := pg_temp.derived_state(_invoice_id);
BEGIN
  IF _state->'subtotal' IS DISTINCT FROM coalesce(to_jsonb(_subtotal), 'null'::jsonb)
     OR _state->'totals' IS DISTINCT FROM jsonb_build_array(_total, _total, _total)
     OR _state->'subtotalField' IS DISTINCT FROM _subtotal_field
     OR _state->'totalField' IS DISTINCT FROM _total_field
     -- Printed tax and shipping are never touched.
     OR _state->'tax' <> '2'::jsonb OR _state->'shipping' <> '5'::jsonb
     OR _state #>> '{taxField,source}' <> 'Parser' OR (_state #>> '{taxField,value}')::numeric <> 2 THEN
    RAISE EXCEPTION '% failed: %', _name, _state;
  END IF;
END;
$$;

INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
VALUES ('be130000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'derived-owner@example.invalid', '', now(), '{}', '{}', now(), now());
INSERT INTO public.organizations (id, name, created_by)
VALUES ('be130000-0000-4000-8000-000000000101', 'Derived Totals Athletics', 'be130000-0000-4000-8000-000000000001');
INSERT INTO public.organization_memberships (id, organization_id, user_id, role, active)
VALUES ('be130000-0000-4000-8000-000000000111', 'be130000-0000-4000-8000-000000000101', 'be130000-0000-4000-8000-000000000001', 'owner', true);
INSERT INTO public.vendors (id, organization_id, name, normalized_name, active)
VALUES ('be130000-0000-4000-8000-000000000301', 'be130000-0000-4000-8000-000000000101', 'Henry Schein', 'henry schein', true);
INSERT INTO public.products (id, organization_id, name, normalized_name, approved, active, staff_requestable)
VALUES ('be130000-0000-4000-8000-000000000401', 'be130000-0000-4000-8000-000000000101', 'Derived Totals Product', 'x', true, true, true);

INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type)
SELECT ('be130000-0000-4000-8000-0000000006' || lpad(n::text, 2, '0'))::uuid, 'be130000-0000-4000-8000-000000000101',
  'be130000-0000-4000-8000-000000000001', 'be130000-0000-4000-8000-000000000101/derived-' || n || '.pdf', 'derived-' || n || '.pdf', 1024, 'application/pdf'
FROM generate_series(1, 8) n;

INSERT INTO public.invoices (id, organization_id, source_file_id, vendor_id, vendor_name, invoice_number, processing_status, subtotal, tax_amount, shipping_amount, invoice_total, total_amount, total)
VALUES
  -- 1: subtotal and total both calculated. 2: calculated subtotal, printed total.
  -- 3: printed. 4: owner-entered. 5: completed. 6: no stored extraction.
  -- 7: a second calculated invoice that nothing touches. 8: pristine, for draft seeding.
  ('be130000-0000-4000-8000-000000000701', 'be130000-0000-4000-8000-000000000101', 'be130000-0000-4000-8000-000000000601', 'be130000-0000-4000-8000-000000000301', 'Henry Schein', 'D-1', 'review_required', 30, 2, 5, 37, 37, 37),
  ('be130000-0000-4000-8000-000000000702', 'be130000-0000-4000-8000-000000000101', 'be130000-0000-4000-8000-000000000602', 'be130000-0000-4000-8000-000000000301', 'Henry Schein', 'D-2', 'review_required', 30, 2, 5, 37, 37, 37),
  ('be130000-0000-4000-8000-000000000703', 'be130000-0000-4000-8000-000000000101', 'be130000-0000-4000-8000-000000000603', 'be130000-0000-4000-8000-000000000301', 'Henry Schein', 'D-3', 'review_required', 30, 2, 5, 37, 37, 37),
  ('be130000-0000-4000-8000-000000000704', 'be130000-0000-4000-8000-000000000101', 'be130000-0000-4000-8000-000000000604', 'be130000-0000-4000-8000-000000000301', 'Henry Schein', 'D-4', 'review_required', 30, 2, 5, 37, 37, 37),
  ('be130000-0000-4000-8000-000000000705', 'be130000-0000-4000-8000-000000000101', 'be130000-0000-4000-8000-000000000605', 'be130000-0000-4000-8000-000000000301', 'Henry Schein', 'D-5', 'completed', 30, 2, 5, 37, 37, 37),
  ('be130000-0000-4000-8000-000000000706', 'be130000-0000-4000-8000-000000000101', 'be130000-0000-4000-8000-000000000606', 'be130000-0000-4000-8000-000000000301', 'Henry Schein', 'D-6', 'review_required', 30, 2, 5, 37, 37, 37),
  ('be130000-0000-4000-8000-000000000707', 'be130000-0000-4000-8000-000000000101', 'be130000-0000-4000-8000-000000000607', 'be130000-0000-4000-8000-000000000301', 'Henry Schein', 'D-7', 'review_required', 30, 2, 5, 37, 37, 37),
  ('be130000-0000-4000-8000-000000000708', 'be130000-0000-4000-8000-000000000101', 'be130000-0000-4000-8000-000000000608', NULL, NULL, NULL, 'review_required', NULL, NULL, NULL, NULL, NULL, NULL);

INSERT INTO public.invoice_items (id, invoice_id, organization_id, line_number, sku, description, quantity, unit_of_measure, unit_price, total_price, product_id)
SELECT ('be130000-0000-4000-8000-0000000008' || n || line)::uuid, ('be130000-0000-4000-8000-00000000070' || n)::uuid,
  'be130000-0000-4000-8000-000000000101', line, 'D-' || line, 'Line ' || line, CASE line WHEN 1 THEN 2 ELSE 1 END, 'EA', 10, CASE line WHEN 1 THEN 20 ELSE 10 END,
  CASE WHEN n = 5 THEN 'be130000-0000-4000-8000-000000000401'::uuid END
FROM generate_series(1, 7) n, generate_series(1, 2) line;

-- Uploading the files created each job; give them their stored extractions.
UPDATE public.invoice_processing_jobs job SET status = 'review_required', extraction_result = extraction.value
FROM (VALUES
  ('be130000-0000-4000-8000-000000000601'::uuid, pg_temp.derived_extraction('Derived', 'Derived')),
  ('be130000-0000-4000-8000-000000000602'::uuid, pg_temp.derived_extraction('Derived', 'Parser')),
  ('be130000-0000-4000-8000-000000000603'::uuid, pg_temp.derived_extraction('Parser', 'Parser')),
  ('be130000-0000-4000-8000-000000000604'::uuid, pg_temp.derived_extraction('User', 'User')),
  ('be130000-0000-4000-8000-000000000605'::uuid, pg_temp.derived_extraction('Derived', 'Derived')),
  ('be130000-0000-4000-8000-000000000607'::uuid, pg_temp.derived_extraction('Derived', 'Derived'))
) AS extraction(source_file_id, value)
WHERE job.invoice_id = extraction.source_file_id;
UPDATE public.invoice_processing_jobs SET status = 'completed' WHERE invoice_id = 'be130000-0000-4000-8000-000000000605';

CREATE TEMP TABLE derived_snapshots (name text PRIMARY KEY, value jsonb);
GRANT ALL ON derived_snapshots TO authenticated;
INSERT INTO derived_snapshots
SELECT 'invoice_' || n, pg_temp.derived_state(('be130000-0000-4000-8000-00000000070' || n)::uuid) FROM generate_series(1, 7) n;
INSERT INTO derived_snapshots VALUES ('inventory', (SELECT to_jsonb(count(*)) FROM public.inventory_items WHERE organization_id = 'be130000-0000-4000-8000-000000000101'));

-- Fixture writes above ran as the migration role and withdrew nothing.
DO $derived_setup$
BEGIN
  PERFORM pg_temp.derived_expect('Setup', 'be130000-0000-4000-8000-000000000701', 30,
    '{"value": 30, "confidence": 60, "source": "Derived", "reviewed": true}', 37,
    '{"value": 37, "confidence": 60, "source": "Derived", "reviewed": true}');
END
$derived_setup$;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be130000-0000-4000-8000-000000000001', true);

-- Check 1: a change that does not touch an amount withdraws nothing.
UPDATE public.invoice_items SET description = 'Renamed', sku = 'D-9', package_size = '10/Bx', review_status = 'pending_review'
WHERE id = 'be130000-0000-4000-8000-000000000811';
UPDATE public.invoice_items SET quantity = quantity, unit_price = unit_price, total_price = total_price
WHERE invoice_id = 'be130000-0000-4000-8000-000000000701';
SELECT public.confirm_invoice_item_product('be130000-0000-4000-8000-000000000101', 'be130000-0000-4000-8000-000000000601',
  'be130000-0000-4000-8000-000000000811', 'be130000-0000-4000-8000-000000000401', false);
DO $derived_check_1$
BEGIN
  IF pg_temp.derived_state('be130000-0000-4000-8000-000000000701') IS DISTINCT FROM (SELECT value FROM derived_snapshots WHERE name = 'invoice_1') THEN
    RAISE EXCEPTION 'Check 1 failed: a non-amount change withdrew a calculated total: %', pg_temp.derived_state('be130000-0000-4000-8000-000000000701');
  END IF;
END
$derived_check_1$;

-- Check 2: re-pricing a line withdraws both calculated amounts, in the row and in the stored
-- extraction, and marks them unreviewed. They stay calculations (source Derived).
UPDATE public.invoice_items SET quantity = 3, total_price = 30 WHERE id = 'be130000-0000-4000-8000-000000000811';
SELECT pg_temp.derived_expect('Check 2', 'be130000-0000-4000-8000-000000000701', NULL,
  '{"value": null, "confidence": 0, "source": "Derived", "reviewed": false}', NULL,
  '{"value": null, "confidence": 0, "source": "Derived", "reviewed": false}');
DO $derived_check_2$
BEGIN
  -- Nothing else in the stored extraction changes.
  IF pg_temp.derived_state('be130000-0000-4000-8000-000000000701')->'rest' IS DISTINCT FROM (SELECT value->'rest' FROM derived_snapshots WHERE name = 'invoice_1') THEN
    RAISE EXCEPTION 'Check 2 failed: the stored extraction changed outside its calculated totals';
  END IF;
END
$derived_check_2$;

-- Checks 3 and 4: so do a price-only change, an added line, and a removed line. Each
-- starts from a calculated value put back the way the application would.
RESET ROLE;
CREATE FUNCTION pg_temp.derived_restore(_n integer) RETURNS void LANGUAGE sql AS $$
  UPDATE public.invoice_processing_jobs SET extraction_result = pg_temp.derived_extraction('Derived', 'Derived')
  WHERE invoice_id = ('be130000-0000-4000-8000-00000000060' || _n)::uuid;
  UPDATE public.invoices SET subtotal = 30, invoice_total = 37, total_amount = 37, total = 37
  WHERE id = ('be130000-0000-4000-8000-00000000070' || _n)::uuid;
$$;
SELECT pg_temp.derived_restore(1);
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be130000-0000-4000-8000-000000000001', true);
UPDATE public.invoice_items SET unit_price = 11 WHERE id = 'be130000-0000-4000-8000-000000000812';
SELECT pg_temp.derived_expect('Check 3 (unit price)', 'be130000-0000-4000-8000-000000000701', NULL,
  '{"value": null, "confidence": 0, "source": "Derived", "reviewed": false}', NULL,
  '{"value": null, "confidence": 0, "source": "Derived", "reviewed": false}');
RESET ROLE;
SELECT pg_temp.derived_restore(1);
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be130000-0000-4000-8000-000000000001', true);
INSERT INTO public.invoice_items (id, invoice_id, organization_id, line_number, sku, description, quantity, unit_of_measure, unit_price, total_price)
VALUES ('be130000-0000-4000-8000-000000000819', 'be130000-0000-4000-8000-000000000701', 'be130000-0000-4000-8000-000000000101', 3, 'D-3', 'Added line', 1, 'EA', 5, 5);
SELECT pg_temp.derived_expect('Check 4 (insert)', 'be130000-0000-4000-8000-000000000701', NULL,
  '{"value": null, "confidence": 0, "source": "Derived", "reviewed": false}', NULL,
  '{"value": null, "confidence": 0, "source": "Derived", "reviewed": false}');
RESET ROLE;
SELECT pg_temp.derived_restore(1);
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be130000-0000-4000-8000-000000000001', true);
DELETE FROM public.invoice_items WHERE invoice_id = 'be130000-0000-4000-8000-000000000701' AND line_number >= 2;
SELECT pg_temp.derived_expect('Check 4 (delete, two rows in one statement)', 'be130000-0000-4000-8000-000000000701', NULL,
  '{"value": null, "confidence": 0, "source": "Derived", "reviewed": false}', NULL,
  '{"value": null, "confidence": 0, "source": "Derived", "reviewed": false}');

-- Check 5: beside a printed total, only the calculated subtotal is withdrawn.
UPDATE public.invoice_items SET total_price = 25 WHERE id = 'be130000-0000-4000-8000-000000000821';
SELECT pg_temp.derived_expect('Check 5', 'be130000-0000-4000-8000-000000000702', NULL,
  '{"value": null, "confidence": 0, "source": "Derived", "reviewed": false}', 37,
  '{"value": 37, "confidence": 94, "source": "Parser", "reviewed": true}');

-- Check 6: printed and owner-entered amounts are never touched, whatever happens to lines.
UPDATE public.invoice_items SET quantity = 9, unit_price = 9, total_price = 81
WHERE invoice_id IN ('be130000-0000-4000-8000-000000000703', 'be130000-0000-4000-8000-000000000704');
DELETE FROM public.invoice_items WHERE id IN ('be130000-0000-4000-8000-000000000832', 'be130000-0000-4000-8000-000000000842');
INSERT INTO public.invoice_items (invoice_id, organization_id, line_number, description, quantity, unit_of_measure, unit_price, total_price)
VALUES
  ('be130000-0000-4000-8000-000000000703', 'be130000-0000-4000-8000-000000000101', 3, 'Added', 1, 'EA', 1, 1),
  ('be130000-0000-4000-8000-000000000704', 'be130000-0000-4000-8000-000000000101', 3, 'Added', 1, 'EA', 1, 1);
-- Check 7: an invoice with no stored extraction is simply left alone.
UPDATE public.invoice_items SET total_price = 99 WHERE invoice_id = 'be130000-0000-4000-8000-000000000706';
DELETE FROM public.invoice_items WHERE id = 'be130000-0000-4000-8000-000000000862';
RESET ROLE;
DO $derived_check_6_7$
DECLARE _n integer;
BEGIN
  FOREACH _n IN ARRAY ARRAY[3, 4, 6] LOOP
    IF pg_temp.derived_state(('be130000-0000-4000-8000-00000000070' || _n)::uuid) IS DISTINCT FROM (SELECT value FROM derived_snapshots WHERE name = 'invoice_' || _n) THEN
      RAISE EXCEPTION 'Checks 6-7 failed: invoice % changed: %', _n, pg_temp.derived_state(('be130000-0000-4000-8000-00000000070' || _n)::uuid);
    END IF;
  END LOOP;
  -- Check 8: lines changed on other invoices only; this calculated invoice is untouched.
  IF pg_temp.derived_state('be130000-0000-4000-8000-000000000707') IS DISTINCT FROM (SELECT value FROM derived_snapshots WHERE name = 'invoice_7') THEN
    RAISE EXCEPTION 'Check 8 failed: a calculated total on an untouched invoice was withdrawn';
  END IF;
END
$derived_check_6_7$;

-- Check 9: a completed invoice keeps its totals.
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be130000-0000-4000-8000-000000000001', true);
UPDATE public.invoice_items SET total_price = 99 WHERE id = 'be130000-0000-4000-8000-000000000851';
RESET ROLE;
DO $derived_check_9$
BEGIN
  IF pg_temp.derived_state('be130000-0000-4000-8000-000000000705') IS DISTINCT FROM (SELECT value FROM derived_snapshots WHERE name = 'invoice_5') THEN
    RAISE EXCEPTION 'Check 9 failed: a completed invoice lost its totals';
  END IF;
END
$derived_check_9$;

-- Check 10: the database's own functions are not affected. Draft seeding stores the
-- calculated amounts it is given and then inserts the lines; posting keeps them.
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be130000-0000-4000-8000-000000000001', true);
SELECT public.seed_structured_invoice_draft('be130000-0000-4000-8000-000000000101', 'be130000-0000-4000-8000-000000000608',
  jsonb_set(pg_temp.derived_extraction('Derived', 'Derived', 20, 27), '{header,subtotal,reviewed}', 'false'), 'deterministic-invoice-v2');
RESET ROLE;
DO $derived_check_10a$
DECLARE _state jsonb := pg_temp.derived_state('be130000-0000-4000-8000-000000000708');
BEGIN
  IF _state->'subtotal' <> '20'::jsonb OR _state->'totals' <> '[27, 27, 27]'::jsonb
     OR _state #>> '{subtotalField,source}' <> 'Derived' OR (_state #>> '{subtotalField,value}')::numeric <> 20
     OR (SELECT count(*) FROM public.invoice_items WHERE invoice_id = 'be130000-0000-4000-8000-000000000708') <> 1 THEN
    RAISE EXCEPTION 'Check 10 failed: seeding a draft withdrew the calculated totals it stored: %', _state;
  END IF;
END
$derived_check_10a$;
INSERT INTO derived_snapshots VALUES ('invoice_7_before_post', pg_temp.derived_state('be130000-0000-4000-8000-000000000707'));
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'be130000-0000-4000-8000-000000000001', true);
SELECT public.confirm_invoice_item_product('be130000-0000-4000-8000-000000000101', 'be130000-0000-4000-8000-000000000607', id, 'be130000-0000-4000-8000-000000000401', false)
FROM public.invoice_items WHERE invoice_id = 'be130000-0000-4000-8000-000000000707';
SELECT public.post_reviewed_invoice('be130000-0000-4000-8000-000000000101', 'be130000-0000-4000-8000-000000000607');
RESET ROLE;
DO $derived_check_10b$
BEGIN
  IF (SELECT processing_status FROM public.invoices WHERE id = 'be130000-0000-4000-8000-000000000707') <> 'completed'
     OR pg_temp.derived_state('be130000-0000-4000-8000-000000000707') IS DISTINCT FROM (SELECT value FROM derived_snapshots WHERE name = 'invoice_7_before_post') THEN
    RAISE EXCEPTION 'Check 10 failed: posting changed calculated totals: %', pg_temp.derived_state('be130000-0000-4000-8000-000000000707');
  END IF;
  -- The only inventory in this suite is what that posting created.
  IF (SELECT count(*) FROM public.inventory_items WHERE organization_id = 'be130000-0000-4000-8000-000000000101') <> 1 THEN
    RAISE EXCEPTION 'Check 10 failed: withdrawing totals touched inventory';
  END IF;
END
$derived_check_10b$;

SELECT 10 AS checks_passed, 0 AS checks_failed;

ROLLBACK;
