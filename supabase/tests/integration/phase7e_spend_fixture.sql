-- Phase 7E integration / benchmark fixture. Disposable local database only (loaded by
-- supabase/tests/run_phase7e_spend_integration.sh after every migration).
--
-- Organization A (7e1c...0101): owner 001, admin 002, staff 003.
--   * 200 vendors, 5,000 products (every 4th categorized), 5 non-overlapping active yearly
--     budgets 2022-2026 of $3,000,000, plus one inactive overlapping budget.
--   * 50,000 posted documents with 5 lines each (250,000 lines) between 2022-01-01 and
--     2026-11-16: every 25th an order confirmation with no invoice date (dated by the UTC posting
--     day), every 50th UNKNOWN, 80% with no currency, 10 in EUR (excluded), 20 credit memos
--     (excluded). Header = lines + 5% tax (+ $4.95 shipping on every 10th).
--   * 2,000 requests with active commitments across approved / ordered / received / completed and
--     fully / partially / unpriced.
-- Organizations B, C, D (noise): 50,000 documents and 250,000 lines each, so the database holds
-- 200,000 documents and 1,000,000 lines; nothing of theirs may appear in A's figures.
-- Rows are written directly in the posting context, as post_reviewed_invoice writes them.

SET client_min_messages = warning;
SELECT set_config('sportspend.financial_context', 'post', false);

INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('7e1c0000-0000-4000-8000-00000000000' || n)::uuid, 'authenticated', 'authenticated',
  'phase7e-itest-' || n || '@example.invalid', '', now(), '{}', '{}', now(), now()
FROM unnest(ARRAY[1, 2, 3, 4]) n;

INSERT INTO public.organizations (id, name, created_by)
SELECT ('7e1c0000-0000-4000-8000-00000000010' || n)::uuid, 'Phase 7E Integration ' || n, '7e1c0000-0000-4000-8000-000000000001'
FROM generate_series(1, 4) n;
INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES
  ('7e1c0000-0000-4000-8000-000000000101', '7e1c0000-0000-4000-8000-000000000001', 'owner', true),
  ('7e1c0000-0000-4000-8000-000000000101', '7e1c0000-0000-4000-8000-000000000002', 'admin', true),
  ('7e1c0000-0000-4000-8000-000000000101', '7e1c0000-0000-4000-8000-000000000003', 'staff', true),
  ('7e1c0000-0000-4000-8000-000000000102', '7e1c0000-0000-4000-8000-000000000004', 'owner', true),
  ('7e1c0000-0000-4000-8000-000000000103', '7e1c0000-0000-4000-8000-000000000004', 'owner', true),
  ('7e1c0000-0000-4000-8000-000000000104', '7e1c0000-0000-4000-8000-000000000004', 'owner', true);

DO $fixture$
DECLARE
  _org uuid;
  _o integer;
BEGIN
  FOR _o IN 1..4 LOOP
    _org := ('7e1c0000-0000-4000-8000-00000000010' || _o)::uuid;

    INSERT INTO public.product_categories (id, organization_id, name)
    VALUES (md5('cat' || _o)::uuid, _org, 'Integration category ' || _o);

    INSERT INTO public.vendors (id, organization_id, name, active)
    SELECT md5('v' || _o || ':' || v)::uuid, _org, 'Vendor ' || _o || '-' || lpad(v::text, 3, '0'), true
    FROM generate_series(1, 200) v;

    INSERT INTO public.products (id, organization_id, name, approved, active, staff_requestable, category_id)
    SELECT md5('p' || _o || ':' || p)::uuid, _org, 'Product ' || _o || '-' || lpad(p::text, 4, '0'), true, true, true,
      CASE WHEN p % 4 = 0 THEN md5('cat' || _o)::uuid END
    FROM generate_series(1, 5000) p;

    INSERT INTO public.invoices (id, organization_id, vendor_id, vendor_name, document_type, invoice_number, order_number,
      invoice_date, posted_at, processing_status, currency_code)
    SELECT md5('i' || _o || ':' || n)::uuid, _org, md5('v' || _o || ':' || (1 + n % 200))::uuid, 'Vendor',
      CASE WHEN n <= 20 THEN 'CREDIT_MEMO' WHEN n % 25 = 0 THEN 'ORDER_CONFIRMATION' WHEN n % 50 = 1 THEN 'UNKNOWN' ELSE 'INVOICE' END,
      CASE WHEN n % 25 = 0 THEN NULL ELSE 'INV-' || _o || '-' || n END,
      CASE WHEN n % 25 = 0 THEN 'OC-' || _o || '-' || n END,
      CASE WHEN n % 25 = 0 THEN NULL ELSE date '2022-01-01' + (n % 1781) END,
      (date '2022-01-01' + (n % 1781))::timestamp AT TIME ZONE 'UTC' + interval '15 hours',
      'completed',
      CASE WHEN n % 5000 = 7 THEN 'EUR' WHEN n % 5 = 0 THEN 'USD' END
    FROM generate_series(1, 50000) n;

    INSERT INTO public.invoice_items (invoice_id, organization_id, line_number, description, quantity, unit_of_measure,
      package_size, unit_price, total_price, product_id)
    SELECT md5('i' || _o || ':' || n)::uuid, _org, k, 'Line ' || k, 1 + (n + k) % 10,
      (ARRAY['ea', 'bx', 'cs', 'EA'])[1 + (n * k) % 4], CASE WHEN k = 5 THEN '12' END,
      round((3 + (n * 7 + k * 13) % 97)::numeric, 2),
      round((1 + (n + k) % 10) * (3 + (n * 7 + k * 13) % 97)::numeric, 2),
      md5('p' || _o || ':' || (1 + (n * 7 + k * 31) % 5000))::uuid
    FROM generate_series(1, 50000) n CROSS JOIN generate_series(1, 5) k;

    UPDATE public.invoices invoice SET
      subtotal = line.total,
      tax_amount = round(line.total * 0.05, 2),
      shipping_amount = CASE WHEN right(invoice.invoice_number, 1) = '0' THEN 4.95 END,
      invoice_total = line.total + round(line.total * 0.05, 2) + CASE WHEN right(invoice.invoice_number, 1) = '0' THEN 4.95 ELSE 0 END,
      total_amount = line.total + round(line.total * 0.05, 2) + CASE WHEN right(invoice.invoice_number, 1) = '0' THEN 4.95 ELSE 0 END,
      total = line.total + round(line.total * 0.05, 2) + CASE WHEN right(invoice.invoice_number, 1) = '0' THEN 4.95 ELSE 0 END
    FROM (
      SELECT invoice_id, sum(total_price) AS total FROM public.invoice_items
      WHERE organization_id = _org GROUP BY invoice_id
    ) line
    WHERE invoice.id = line.invoice_id;
  END LOOP;
END
$fixture$;

SELECT set_config('sportspend.financial_context', '', false);

INSERT INTO public.organization_budgets (organization_id, name, period_start, period_end, amount, active)
SELECT '7e1c0000-0000-4000-8000-000000000101', 'FY ' || y, make_date(y, 1, 1), make_date(y, 12, 31), 3000000, true
FROM generate_series(2022, 2026) y;
INSERT INTO public.organization_budgets (organization_id, name, period_start, period_end, amount, active)
VALUES ('7e1c0000-0000-4000-8000-000000000101', 'Old overlapping draft', '2026-06-01', '2027-05-31', 1, false);

INSERT INTO public.supply_requests (id, organization_id, requested_by, request_type, quantity, notes, status)
SELECT md5('r' || n)::uuid, '7e1c0000-0000-4000-8000-000000000101', '7e1c0000-0000-4000-8000-000000000003', 'reorder', 1,
  'integration', (ARRAY['approved', 'ordered', 'received', 'completed'])[1 + n % 4]::public.supply_request_status
FROM generate_series(1, 2000) n;
INSERT INTO public.supply_request_commitments (organization_id, supply_request_id, amount, total_item_count, priced_item_count,
  pricing_status, status, committed_at)
SELECT '7e1c0000-0000-4000-8000-000000000101', md5('r' || n)::uuid,
  CASE n % 3 WHEN 0 THEN 0 ELSE 10 + n % 90 END, 2, CASE n % 3 WHEN 0 THEN 0 WHEN 1 THEN 2 ELSE 1 END,
  CASE n % 3 WHEN 0 THEN 'unpriced' WHEN 1 THEN 'fully_priced' ELSE 'partially_priced' END,
  'active', timestamptz '2026-01-01 12:00+00' + make_interval(days => n % 319)
FROM generate_series(1, 2000) n;

ANALYZE public.invoices;
ANALYZE public.invoice_items;
ANALYZE public.supply_request_commitments;
