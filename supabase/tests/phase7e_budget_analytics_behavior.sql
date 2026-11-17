-- Phase 7E rollback-only behavioral verification: spend rows, Actual Spend, Remaining,
-- commitments, pace, burn, coverage, signals, charts, drill-down, posted-document guards,
-- audited removal, the posting guard, NULL currency, the budget overlap guard and access.
-- Run against a disposable database after every migration through
-- 20261117120000_phase7e_budget_analytics.sql. Every fixture is rolled back.

BEGIN;

DO $phase7e_fixture_guard$
BEGIN
  IF EXISTS (SELECT 1 FROM auth.users
             WHERE id BETWEEN '7e000000-0000-4000-8000-000000000001'::uuid AND '7e000000-0000-4000-8000-000000000099'::uuid)
     OR EXISTS (SELECT 1 FROM public.organizations
             WHERE id BETWEEN '7e000000-0000-4000-8000-000000000101'::uuid AND '7e000000-0000-4000-8000-000000000199'::uuid) THEN
    RAISE EXCEPTION 'Phase 7E rollback-test fixture IDs already exist';
  END IF;
END
$phase7e_fixture_guard$;

CREATE FUNCTION pg_temp.expect_error(_statement text, _expected text, _sqlstate text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE _statement;
  EXCEPTION WHEN OTHERS THEN
    IF position(_expected IN SQLERRM) = 0 OR (_sqlstate IS NOT NULL AND SQLSTATE <> _sqlstate) THEN
      RAISE EXCEPTION 'Expected error containing "%" (%), got "%" (%)', _expected, _sqlstate, SQLERRM, SQLSTATE;
    END IF;
    RETURN;
  END;
  RAISE EXCEPTION 'Statement unexpectedly succeeded; expected "%": %', _expected, _statement;
END;
$$;
CREATE FUNCTION pg_temp.as_user(_user_id uuid)
RETURNS void LANGUAGE sql AS $$ SELECT pg_catalog.set_config('request.jwt.claim.sub', coalesce(_user_id::text, ''), true) $$;
CREATE FUNCTION pg_temp.assert(_condition boolean, _message text)
RETURNS void LANGUAGE plpgsql AS $$ BEGIN IF _condition IS NOT TRUE THEN RAISE EXCEPTION 'Check failed: %', _message; END IF; END; $$;
CREATE FUNCTION pg_temp.eq(_actual anyelement, _expected anyelement, _message text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF _actual IS DISTINCT FROM _expected THEN
    RAISE EXCEPTION 'Check failed: % (expected %, got %)', _message, _expected, _actual;
  END IF;
END;
$$;
CREATE TEMP TABLE phase7e_values (name text PRIMARY KEY, value jsonb) ON COMMIT DROP;
GRANT ALL ON phase7e_values TO authenticated, anon, service_role;
CREATE FUNCTION pg_temp.keep(_name text, _value jsonb)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO phase7e_values VALUES (_name, _value) ON CONFLICT (name) DO UPDATE SET value = EXCLUDED.value $$;
CREATE FUNCTION pg_temp.val(_name text)
RETURNS jsonb LANGUAGE sql AS $$ SELECT value FROM phase7e_values WHERE name = _name $$;
CREATE FUNCTION pg_temp.num(_value jsonb, _path text[])
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$ SELECT (_value #>> _path)::numeric $$;
CREATE FUNCTION pg_temp.signal(_summary jsonb, _code text)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT s FROM jsonb_array_elements(_summary -> 'signals') s WHERE s ->> 'code' = _code $$;
CREATE FUNCTION pg_temp.state()
RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT jsonb_build_object(
    'invoices', (SELECT md5(coalesce(string_agg(to_jsonb(i)::text, ',' ORDER BY id), '')) FROM public.invoices i),
    'items', (SELECT md5(coalesce(string_agg(to_jsonb(i)::text, ',' ORDER BY id), '')) FROM public.invoice_items i),
    'budgets', (SELECT md5(coalesce(string_agg(to_jsonb(b)::text, ',' ORDER BY id), '')) FROM public.organization_budgets b),
    'commitments', (SELECT md5(coalesce(string_agg(to_jsonb(c)::text, ',' ORDER BY id), '')) FROM public.supply_request_commitments c),
    'inventory', (SELECT md5(coalesce(string_agg(id::text || ':' || quantity::text, ',' ORDER BY id), '')) FROM public.inventory_items),
    'adjustments', (SELECT count(*) FROM public.inventory_adjustments),
    'removals', (SELECT count(*) FROM public.financial_document_removals))
$$;

-- ---------------------------------------------------------------------------------------
-- Fixtures. A: owner 001, admin 002, staff 003. B: owner 004. 007 belongs to nothing.
-- ---------------------------------------------------------------------------------------
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('7e000000-0000-4000-8000-00000000000' || n)::uuid, 'authenticated', 'authenticated',
  'phase7e-' || n || '@example.invalid', '', now(), '{}', '{}', now(), now()
FROM unnest(ARRAY[1, 2, 3, 4, 7]) n;

INSERT INTO public.organizations (id, name, created_by) VALUES
  ('7e000000-0000-4000-8000-000000000101', 'Phase 7E Organization', '7e000000-0000-4000-8000-000000000001'),
  ('7e000000-0000-4000-8000-000000000102', 'Phase 7E Other Organization', '7e000000-0000-4000-8000-000000000004');
INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES
  ('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000001', 'owner', true),
  ('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000002', 'admin', true),
  ('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000003', 'staff', true),
  ('7e000000-0000-4000-8000-000000000102', '7e000000-0000-4000-8000-000000000004', 'owner', true);
INSERT INTO public.teams (id, organization_id, name) VALUES
  ('7e000000-0000-4000-8000-000000000201', '7e000000-0000-4000-8000-000000000101', 'First Team');

INSERT INTO public.vendors (id, organization_id, name, active) VALUES
  ('7e000000-0000-4000-8000-000000000301', '7e000000-0000-4000-8000-000000000101', 'P7E Vendor One', true),
  ('7e000000-0000-4000-8000-000000000302', '7e000000-0000-4000-8000-000000000101', 'P7E Vendor Two', true),
  ('7e000000-0000-4000-8000-000000000303', '7e000000-0000-4000-8000-000000000102', 'P7E Other Vendor', true);

INSERT INTO public.product_categories (id, organization_id, name)
VALUES ('7e000000-0000-4000-8000-000000000351', '7e000000-0000-4000-8000-000000000101', 'P7E Wound Care');
INSERT INTO public.products (id, organization_id, name, approved, active, staff_requestable, category_id) VALUES
  ('7e000000-0000-4000-8000-000000000401', '7e000000-0000-4000-8000-000000000101', 'P7E Device', true, true, true, NULL),
  ('7e000000-0000-4000-8000-000000000402', '7e000000-0000-4000-8000-000000000101', 'P7E Gauze', true, true, true, '7e000000-0000-4000-8000-000000000351'),
  ('7e000000-0000-4000-8000-000000000403', '7e000000-0000-4000-8000-000000000102', 'P7E Other Tape', true, true, true, NULL);

INSERT INTO public.organization_budgets (id, organization_id, name, period_start, period_end, amount, active) VALUES
  ('7e000000-0000-4000-8000-000000000901', '7e000000-0000-4000-8000-000000000101', 'Tape', '2026-01-01', '2026-12-31', 50000, true),
  -- An inactive budget never covers spend.
  ('7e000000-0000-4000-8000-000000000900', '7e000000-0000-4000-8000-000000000101', '2025 (inactive)', '2025-01-01', '2025-12-31', 1000, false);

-- Posted documents written directly, as post_reviewed_invoice writes them.
SELECT set_config('sportspend.financial_context', 'post', true);
INSERT INTO public.invoices (id, organization_id, vendor_id, vendor_name, document_type, invoice_number, order_number,
  invoice_date, posted_at, processing_status, currency_code, subtotal, tax_amount, shipping_amount,
  invoice_total, total_amount, total) VALUES
  -- D1..D4: FC Cincinnati shape (no currency recorded).
  ('7e000000-0000-4000-8000-000000000501', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000301', 'Vendor One (as extracted)', 'INVOICE', 'INV-1', NULL,
    '2026-01-02', '2026-11-10 15:00+00', 'completed', NULL, 17850, 1204.88, NULL, 19054.88, 19054.88, 19054.88),
  ('7e000000-0000-4000-8000-000000000502', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000301', 'Vendor One', 'INVOICE', 'INV-2', NULL,
    '2026-01-07', '2026-11-10 15:01+00', 'completed', NULL, 300, 33.70, NULL, 333.70, 333.70, 333.70),
  ('7e000000-0000-4000-8000-000000000503', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000301', 'Vendor One', 'ORDER_CONFIRMATION', NULL, 'OC-1',
    NULL, '2026-10-12 23:59:30+00', 'completed', NULL, 150, 12.40, 3.95, 166.35, 166.35, 166.35),
  ('7e000000-0000-4000-8000-000000000504', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000301', 'Vendor One', 'ORDER_CONFIRMATION', NULL, 'OC-2',
    NULL, '2026-11-03 18:59:26+00', 'completed', NULL, 57.48, NULL, 20.45, 77.93, 77.93, 77.93),
  -- D5 UNKNOWN type, no currency; D6 EUR; D7 same vendor and amount as D5 within 30 days.
  ('7e000000-0000-4000-8000-000000000505', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000302', 'Vendor Two', 'UNKNOWN', 'V2-5', NULL,
    '2026-03-15', '2026-03-16 12:00+00', 'completed', NULL, 100, NULL, NULL, 100, 100, 100),
  ('7e000000-0000-4000-8000-000000000506', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000302', 'Vendor Two', 'INVOICE', 'V2-6', NULL,
    '2026-03-20', '2026-03-21 12:00+00', 'completed', 'EUR', 500, NULL, NULL, 500, 500, 500),
  ('7e000000-0000-4000-8000-000000000507', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000302', 'Vendor Two', 'INVOICE', 'V2-7', NULL,
    '2026-03-20', '2026-03-21 12:00+00', 'completed', 'USD', 100, NULL, NULL, 100, 100, 100),
  -- D8 before any budget; D9 header 60 vs lines 50; D10 posted 2026-12-31 23:30 ET = 2027-01-01 UTC.
  ('7e000000-0000-4000-8000-000000000508', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000301', 'Vendor One', 'INVOICE', 'INV-8', NULL,
    '2025-12-15', '2025-12-16 12:00+00', 'completed', 'USD', 40, NULL, NULL, 40, 40, 40),
  ('7e000000-0000-4000-8000-000000000509', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000301', 'Vendor One', 'INVOICE', 'INV-9', NULL,
    '2026-02-10', '2026-02-11 12:00+00', 'completed', 'USD', 50, NULL, NULL, 60, 60, 60),
  ('7e000000-0000-4000-8000-000000000510', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000301', 'Vendor One', 'INVOICE', 'INV-10', NULL,
    NULL, '2026-12-31 23:30:00-05', 'completed', 'USD', 12.5, NULL, NULL, 12.5, 12.5, 12.5),
  -- D12 credit memo and D13 statement posted before 7E (excluded, never counted).
  ('7e000000-0000-4000-8000-000000000512', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000301', 'Vendor One', 'CREDIT_MEMO', 'CM-12', NULL,
    '2026-05-01', '2026-05-02 12:00+00', 'completed', 'USD', 25, NULL, NULL, 25, 25, 25),
  ('7e000000-0000-4000-8000-000000000513', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000301', 'Vendor One', 'STATEMENT', 'ST-13', NULL,
    '2026-05-02', '2026-05-03 12:00+00', 'completed', 'USD', 1000, NULL, NULL, 1000, 1000, 1000),
  -- Organization B
  ('7e000000-0000-4000-8000-000000000520', '7e000000-0000-4000-8000-000000000102', '7e000000-0000-4000-8000-000000000303', 'Other Vendor', 'INVOICE', 'B-1', NULL,
    '2026-04-01', '2026-04-02 12:00+00', 'completed', 'USD', 9999, NULL, NULL, 9999, 9999, 9999);
INSERT INTO public.invoice_items (id, invoice_id, organization_id, line_number, description, quantity, unit_of_measure, package_size, unit_price, total_price, product_id) VALUES
  ('7e000000-0000-4000-8000-000000000601', '7e000000-0000-4000-8000-000000000501', '7e000000-0000-4000-8000-000000000101', 1, 'Deep oscillation unit', 1, 'ea', NULL, 17850, 17850, '7e000000-0000-4000-8000-000000000401'),
  ('7e000000-0000-4000-8000-000000000602', '7e000000-0000-4000-8000-000000000502', '7e000000-0000-4000-8000-000000000101', 1, 'Gauze', 6, 'bx', NULL, 50, 300, '7e000000-0000-4000-8000-000000000402'),
  ('7e000000-0000-4000-8000-000000000603', '7e000000-0000-4000-8000-000000000503', '7e000000-0000-4000-8000-000000000101', 1, 'Electrodes', 3, ' EA ', NULL, 50, 150, '7e000000-0000-4000-8000-000000000401'),
  ('7e000000-0000-4000-8000-000000000604', '7e000000-0000-4000-8000-000000000504', '7e000000-0000-4000-8000-000000000101', 1, 'Gauze', 1, 'BX', NULL, 57.48, 57.48, '7e000000-0000-4000-8000-000000000402'),
  ('7e000000-0000-4000-8000-000000000605', '7e000000-0000-4000-8000-000000000505', '7e000000-0000-4000-8000-000000000101', 1, 'Pads', 2, 'bx', '12', 50, 100, '7e000000-0000-4000-8000-000000000401'),
  ('7e000000-0000-4000-8000-000000000606', '7e000000-0000-4000-8000-000000000506', '7e000000-0000-4000-8000-000000000101', 1, 'EUR line', 1, 'ea', NULL, 500, 500, '7e000000-0000-4000-8000-000000000401'),
  ('7e000000-0000-4000-8000-000000000607', '7e000000-0000-4000-8000-000000000507', '7e000000-0000-4000-8000-000000000101', 1, 'Pads', 1, 'bx', '12', 100, 100, '7e000000-0000-4000-8000-000000000401'),
  ('7e000000-0000-4000-8000-000000000608', '7e000000-0000-4000-8000-000000000508', '7e000000-0000-4000-8000-000000000101', 1, 'Old', 1, 'ea', NULL, 40, 40, '7e000000-0000-4000-8000-000000000401'),
  ('7e000000-0000-4000-8000-000000000609', '7e000000-0000-4000-8000-000000000509', '7e000000-0000-4000-8000-000000000101', 1, 'Gauze', 1, 'bx', NULL, 50, 50, '7e000000-0000-4000-8000-000000000402'),
  ('7e000000-0000-4000-8000-000000000610', '7e000000-0000-4000-8000-000000000510', '7e000000-0000-4000-8000-000000000101', 1, 'Late', 1, 'ea', NULL, 12.5, 12.5, '7e000000-0000-4000-8000-000000000401'),
  ('7e000000-0000-4000-8000-000000000612', '7e000000-0000-4000-8000-000000000512', '7e000000-0000-4000-8000-000000000101', 1, 'Credit', 1, 'ea', NULL, 25, 25, '7e000000-0000-4000-8000-000000000401'),
  ('7e000000-0000-4000-8000-000000000613', '7e000000-0000-4000-8000-000000000513', '7e000000-0000-4000-8000-000000000101', 1, 'Statement', 1, 'ea', NULL, 1000, 1000, '7e000000-0000-4000-8000-000000000401'),
  ('7e000000-0000-4000-8000-000000000620', '7e000000-0000-4000-8000-000000000520', '7e000000-0000-4000-8000-000000000102', 1, 'B line', 1, 'ea', NULL, 9999, 9999, '7e000000-0000-4000-8000-000000000403');
-- A draft (never counted).
INSERT INTO public.invoices (id, organization_id, vendor_id, document_type, invoice_number, invoice_date, processing_status, invoice_total)
VALUES ('7e000000-0000-4000-8000-000000000511', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000301', 'INVOICE', 'DRAFT-11', '2026-04-01', 'review_required', 999);
SELECT set_config('sportspend.financial_context', '', true);

-- Requests and commitments (committed in 2026).
INSERT INTO public.supply_requests (id, organization_id, requested_by, team_id, request_type, quantity, notes, status) VALUES
  ('7e000000-0000-4000-8000-000000000701', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000003', '7e000000-0000-4000-8000-000000000201', 'reorder', 1, 'approved priced', 'approved'),
  ('7e000000-0000-4000-8000-000000000702', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000003', NULL, 'reorder', 1, 'ordered partly', 'ordered'),
  ('7e000000-0000-4000-8000-000000000703', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000003', NULL, 'reorder', 1, 'ordered unpriced', 'ordered'),
  ('7e000000-0000-4000-8000-000000000704', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000003', NULL, 'reorder', 1, 'received unpriced', 'received'),
  ('7e000000-0000-4000-8000-000000000705', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000003', NULL, 'reorder', 1, 'completed priced', 'completed'),
  ('7e000000-0000-4000-8000-000000000706', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000003', NULL, 'reorder', 1, 'denied', 'denied');
INSERT INTO public.supply_request_commitments (id, organization_id, supply_request_id, amount, total_item_count, priced_item_count,
  pricing_status, status, committed_at, released_at, release_kind, release_reason) VALUES
  ('7e000000-0000-4000-8000-000000000801', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000701', 100, 1, 1, 'fully_priced', 'active', '2026-11-10 12:00+00', NULL, NULL, NULL),
  ('7e000000-0000-4000-8000-000000000802', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000702', 36.78, 3, 1, 'partially_priced', 'active', '2026-09-01 12:00+00', NULL, NULL, NULL),
  ('7e000000-0000-4000-8000-000000000803', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000703', 0, 2, 0, 'unpriced', 'active', '2026-11-01 12:00+00', NULL, NULL, NULL),
  ('7e000000-0000-4000-8000-000000000804', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000704', 0, 1, 0, 'unpriced', 'active', '2026-08-01 12:00+00', NULL, NULL, NULL),
  ('7e000000-0000-4000-8000-000000000805', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000705', 200, 1, 1, 'fully_priced', 'active', '2026-07-01 12:00+00', NULL, NULL, NULL),
  ('7e000000-0000-4000-8000-000000000806', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000706', 50, 1, 1, 'fully_priced', 'released', '2026-06-01 12:00+00', '2026-06-02 12:00+00', 'denied', 'Denied');

-- ---------------------------------------------------------------------------------------
-- 1. Spend rows: the single definition.
-- ---------------------------------------------------------------------------------------
DO $spend_rows$
DECLARE _r record;
BEGIN
  SELECT * INTO _r FROM public.financial_spend_rows('7e000000-0000-4000-8000-000000000101', NULL, NULL, '7e000000-0000-4000-8000-000000000503');
  PERFORM pg_temp.eq(_r.spend_date, date '2026-10-12', 'order confirmation dated by UTC posting day');
  PERFORM pg_temp.eq(_r.date_basis, 'posted_at_utc', 'date basis');
  PERFORM pg_temp.eq(_r.document_number, 'OC-1', 'order confirmation number is the order number');
  PERFORM pg_temp.eq(_r.currency_basis, 'legacy_usd', 'no currency is legacy USD');
  PERFORM pg_temp.eq(_r.counted, true, 'order confirmation counted');
  PERFORM pg_temp.eq(_r.component_difference, 0::numeric, 'components reconcile');
  SELECT * INTO _r FROM public.financial_spend_rows('7e000000-0000-4000-8000-000000000101', NULL, NULL, '7e000000-0000-4000-8000-000000000510');
  PERFORM pg_temp.eq(_r.spend_date, date '2027-01-01', '23:30 ET on Dec 31 is Jan 1 UTC');
  SELECT * INTO _r FROM public.financial_spend_rows('7e000000-0000-4000-8000-000000000101', NULL, NULL, '7e000000-0000-4000-8000-000000000501');
  PERFORM pg_temp.eq(_r.vendor_name, 'P7E Vendor One', 'vendor name comes from the vendor record');
  PERFORM pg_temp.eq(_r.amount_basis, 'invoice_total', 'amount basis');
  SELECT * INTO _r FROM public.financial_spend_rows('7e000000-0000-4000-8000-000000000101', NULL, NULL, '7e000000-0000-4000-8000-000000000505');
  PERFORM pg_temp.eq(_r.type_status, 'unknown', 'UNKNOWN is disclosed');
  PERFORM pg_temp.eq(_r.counted, true, 'UNKNOWN is counted');
  SELECT * INTO _r FROM public.financial_spend_rows('7e000000-0000-4000-8000-000000000101', NULL, NULL, '7e000000-0000-4000-8000-000000000506');
  PERFORM pg_temp.eq(_r.exclusion_reason, 'non_usd', 'EUR excluded');
  SELECT * INTO _r FROM public.financial_spend_rows('7e000000-0000-4000-8000-000000000101', NULL, NULL, '7e000000-0000-4000-8000-000000000509');
  PERFORM pg_temp.eq(_r.currency_basis, 'usd', 'explicit USD');
  PERFORM pg_temp.eq(_r.component_difference, 10::numeric, 'header 60 vs lines 50');
  SELECT * INTO _r FROM public.financial_spend_rows('7e000000-0000-4000-8000-000000000101', NULL, NULL, '7e000000-0000-4000-8000-000000000512');
  PERFORM pg_temp.eq(_r.exclusion_reason, 'credit_memo', 'credit memo excluded');
  SELECT * INTO _r FROM public.financial_spend_rows('7e000000-0000-4000-8000-000000000101', NULL, NULL, '7e000000-0000-4000-8000-000000000513');
  PERFORM pg_temp.eq(_r.exclusion_reason, 'statement', 'statement excluded');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.financial_spend_rows('7e000000-0000-4000-8000-000000000101', NULL, NULL)
    WHERE invoice_id = '7e000000-0000-4000-8000-000000000511'), 'drafts are never spend rows');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.financial_spend_rows('7e000000-0000-4000-8000-000000000101', NULL, NULL)
    WHERE invoice_id = '7e000000-0000-4000-8000-000000000520'), 'other organization excluded');
END
$spend_rows$;

-- ---------------------------------------------------------------------------------------
-- 2. Summary for the Tape budget as of 2026-11-16 (admin view).
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7e000000-0000-4000-8000-000000000002');
SELECT pg_temp.keep('summary', public.get_financial_spend_summary('7e000000-0000-4000-8000-000000000101', NULL, '2026-11-16'));
RESET ROLE;
DO $summary$
DECLARE _s jsonb := pg_temp.val('summary');
BEGIN
  PERFORM pg_temp.eq(_s #>> '{scope,budgetName}', 'Tape', 'default budget is the active budget covering as-of');
  PERFORM pg_temp.eq(_s #>> '{scope,kind}', 'budget', 'scope kind');
  PERFORM pg_temp.eq((_s ->> 'viewerIsOwner')::boolean, false, 'admin is not owner');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{spent}'), 19892.86, 'Spent');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{countedDocumentCount}'), 7::numeric, 'counted documents');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{remaining}'), 30107.14, 'Remaining = Budget - Spent');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{commitments,open,count}'), 3::numeric, 'open commitments');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{commitments,open,pricedAmount}'), 136.78, 'open priced amount');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{commitments,open,fullyPriced}'), 1::numeric, 'open fully priced');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{commitments,open,partiallyPriced}'), 1::numeric, 'open partly priced');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{commitments,open,unpriced}'), 1::numeric, 'open unpriced');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{commitments,open,staleCount}'), 1::numeric, 'open stale (committed > 30 days)');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{commitments,receivedNotSettled,count}'), 2::numeric, 'received not settled');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{commitments,receivedNotSettled,pricedAmount}'), 200::numeric, 'received priced amount');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{commitments,unexpectedCount}'), 0::numeric, 'no unexpected buckets');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{approxRemainingAfterOpenCommitments}'), 29970.36,
    'approx = Remaining - priced open commitments; received never subtracted');
  PERFORM pg_temp.eq(_s #>> '{pace,state}', 'in_progress', 'pace state');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{pace,elapsedPercent}'), 87.67, 'elapsed 320/365');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{pace,spentPercent}'), 39.79, 'spent %');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{pace,gapPoints}'), -47.89, 'gap points');
  PERFORM pg_temp.eq(_s #>> '{pace,band}', 'behind', 'band');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{burn,spentThisMonth}'), 77.93, 'this UTC month');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{burn,trailing90Days}'), 244.28, 'trailing 90 days');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{burn,completeMonths}'), 10::numeric, 'complete months Jan-Oct');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{burn,monthsWithSpend}'), 4::numeric, 'months with spend');
  PERFORM pg_temp.assert(_s #> '{burn,averagePerCompleteMonth}' = 'null'::jsonb, 'no average with < 6 months of spend');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{coverage,datedByPosting,count}'), 2::numeric, 'dated by posting');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{coverage,datedByPosting,amount}'), 244.28, 'dated by posting amount');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{coverage,orderConfirmations,count}'), 2::numeric, 'order confirmations');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{coverage,typeUnknown,count}'), 1::numeric, 'type unknown');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{coverage,typeUnknown,amount}'), 100::numeric, 'type unknown amount');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{coverage,typeMissing,count}'), 0::numeric, 'type missing');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{coverage,excludedCreditMemos,count}'), 1::numeric, 'credit memos excluded');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{coverage,excludedStatements,amount}'), 1000::numeric, 'statements excluded');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{coverage,excludedNonUsd,count}'), 1::numeric, 'non-USD excluded');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{coverage,legacyNoCurrency,count}'), 5::numeric, 'legacy no currency');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{coverage,legacyNoCurrency,amount}'), 19732.86, 'legacy no currency amount');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{coverage,componentDifferences,count}'), 1::numeric, 'component differences');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{coverage,components,linesTotal}') + pg_temp.num(_s, '{coverage,components,taxTotal}')
    + pg_temp.num(_s, '{coverage,components,shippingTotal}') + pg_temp.num(_s, '{coverage,components,difference}'),
    pg_temp.num(_s, '{spent}'), 'lines + tax + shipping + difference = Spent');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{coverage,linesCategorized,categorized}'), 3::numeric, 'categorized lines');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{coverage,linesCategorized,total}'), 7::numeric, 'counted lines');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{coverage,spendOutsideBudgets,count}'), 2::numeric, 'outside budgets');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{coverage,spendOutsideBudgets,amount}'), 52.5, 'outside budgets amount');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{coverage,possibleDuplicates,count}'), 2::numeric, 'possible duplicates');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{coverage,removedAfterPosting,count}'), 0::numeric, 'nothing removed yet');
  PERFORM pg_temp.eq((SELECT string_agg(s ->> 'code', ',' ORDER BY o) FROM jsonb_array_elements(_s -> 'signals') WITH ORDINALITY e(s, o)),
    'open_commitments_unpriced,received_not_settled,open_commitment_stale,spend_outside_budgets,dated_by_posting,order_confirmations_counted,possible_duplicates,non_usd_excluded',
    'signals');
  PERFORM pg_temp.eq(pg_temp.num(pg_temp.signal(_s, 'open_commitments_unpriced'), '{count}'), 2::numeric, 'unpriced signal counts partial + unpriced');
  PERFORM pg_temp.assert(pg_temp.signal(_s, 'open_commitments_unpriced') -> 'amount' = 'null'::jsonb, 'unpriced exposure is never $0');
  PERFORM pg_temp.eq(jsonb_array_length(_s -> 'budgets'), 1, 'budget selector lists active budgets');
END
$summary$;

-- Existing budget reads agree with the Spend tab.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7e000000-0000-4000-8000-000000000001');
SELECT pg_temp.keep('legacy', (SELECT to_jsonb(s) FROM public.get_budget_summary('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000901') s));
SELECT pg_temp.keep('overview', public.get_budget_purchasing_overview('7e000000-0000-4000-8000-000000000101'));
SELECT pg_temp.keep('lineage', public.get_budget_lineage('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000901'));
RESET ROLE;
SELECT pg_temp.eq(pg_temp.num(pg_temp.val('legacy'), '{actual_spend}'), 19892.86, 'get_budget_summary actual = Spent');
SELECT pg_temp.eq(pg_temp.num(pg_temp.val('legacy'), '{remaining_amount}'), 30107.14, 'get_budget_summary remaining');
SELECT pg_temp.eq(pg_temp.num(pg_temp.val('legacy'), '{committed_spend}'), 336.78, 'get_budget_summary committed (all active)');
SELECT pg_temp.eq(pg_temp.num(pg_temp.val('legacy'), '{posted_invoice_count}'), 7::numeric, 'get_budget_summary counts counted documents');
SELECT pg_temp.eq(pg_temp.num(pg_temp.val('overview'), '{budgets,0,budgetAmount}') - pg_temp.num(pg_temp.val('overview'), '{budgets,0,actualSpend}'),
  30107.14, 'overview remaining (budget - actual)');
-- Old clients parse these objects strictly: the keys are exactly the pre-7E keys.
SELECT pg_temp.eq((SELECT string_agg(k, ',' ORDER BY k) FROM jsonb_object_keys(pg_temp.val('overview') -> 'budgets' -> 0) k),
  'activeCommitmentCount,actualSpend,availableAmount,budgetAmount,budgetId,budgetName,committedSpend,incompleteCommitmentCount,periodEnd,periodStart,postedInvoiceCount,settlementCandidateAmount,settlementCandidateCount',
  'overview budget keys unchanged');
SELECT pg_temp.eq(pg_temp.num(pg_temp.val('overview'), '{budgets,0,settlementCandidateCount}'), 2::numeric, 'overview received not settled');
SELECT pg_temp.assert(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(pg_temp.val('overview') -> 'recentPurchases') r
  WHERE r ->> 'invoiceId' IN ('7e000000-0000-4000-8000-000000000506', '7e000000-0000-4000-8000-000000000512', '7e000000-0000-4000-8000-000000000513')),
  'recent purchases list counted documents only');
SELECT pg_temp.eq(pg_temp.num(pg_temp.val('lineage'), '{postedTotal}'), 19892.86, 'lineage posted total = Spent');

-- ---------------------------------------------------------------------------------------
-- 3. Series, vendors, products, commitments, documents: every list sums to its headline.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7e000000-0000-4000-8000-000000000002');
SELECT pg_temp.keep('series', public.get_financial_spend_series('7e000000-0000-4000-8000-000000000101', '2026-01-01', '2026-12-31'));
SELECT pg_temp.keep('vendors', public.list_financial_vendor_spend('7e000000-0000-4000-8000-000000000101', '2026-01-01', '2026-12-31'));
SELECT pg_temp.keep('products', public.list_financial_product_spend('7e000000-0000-4000-8000-000000000101', '2026-01-01', '2026-12-31'));
SELECT pg_temp.keep('commitments', public.list_financial_commitments('7e000000-0000-4000-8000-000000000101', '2026-01-01', '2026-12-31', 'open'));
SELECT pg_temp.expect_error($$SELECT public.list_financial_spend_documents('7e000000-0000-4000-8000-000000000101', '2026-01-01', '2026-12-31')$$,
  'Forbidden: owner access required', '42501');
SELECT pg_temp.expect_error($$SELECT public.get_financial_document_detail('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000501')$$,
  'Forbidden: owner access required', '42501');
SELECT pg_temp.expect_error($$SELECT public.list_financial_product_lines('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000401', '2026-01-01', '2026-12-31')$$,
  'Forbidden: owner access required', '42501');
SELECT pg_temp.expect_error($$SELECT public.list_financial_document_removals('7e000000-0000-4000-8000-000000000101')$$,
  'Forbidden: owner access required', '42501');
RESET ROLE;
DO $lists$
DECLARE
  _series jsonb := pg_temp.val('series');
  _vendors jsonb := pg_temp.val('vendors');
  _products jsonb := pg_temp.val('products');
  _commitments jsonb := pg_temp.val('commitments');
BEGIN
  PERFORM pg_temp.eq(pg_temp.num(_series, '{total}'), 19892.86, 'series total');
  PERFORM pg_temp.eq(jsonb_array_length(_series -> 'months'), 12, 'every month, zeros included');
  PERFORM pg_temp.eq((SELECT sum((m ->> 'amount')::numeric) FROM jsonb_array_elements(_series -> 'months') m), 19892.86, 'months sum to Spent');
  PERFORM pg_temp.eq(pg_temp.num(_series, '{months,0,amount}'), 19388.58, 'January');
  PERFORM pg_temp.eq(pg_temp.num(_series, '{months,4,amount}'), 0::numeric, 'May is zero (credit memo and statement excluded)');
  PERFORM pg_temp.eq((_series -> 'cumulative' -> -1 ->> 'cumulative')::numeric, 19892.86, 'cumulative ends at Spent');
  PERFORM pg_temp.eq(_series -> 'cumulative' -> 0 ->> 'date', '2026-01-02', 'cumulative starts at the first spend date');

  PERFORM pg_temp.eq(pg_temp.num(_vendors, '{totalSpend}'), 19892.86, 'vendor total');
  PERFORM pg_temp.eq((SELECT sum((v ->> 'spend')::numeric) FROM jsonb_array_elements(_vendors -> 'rows') v), 19892.86, 'vendors sum to Spent');
  PERFORM pg_temp.eq(_vendors #>> '{rows,0,vendorName}', 'P7E Vendor One', 'largest vendor first');
  PERFORM pg_temp.eq(pg_temp.num(_vendors, '{rows,0,orderConfirmationCount}'), 2::numeric, 'vendor order confirmations');
  PERFORM pg_temp.eq(pg_temp.num(_vendors, '{rows,1,documentCount}'), 2::numeric, 'EUR document not counted for Vendor Two');

  PERFORM pg_temp.eq(pg_temp.num(_products, '{reconciliation,spent}'), 19892.86, 'product reconciliation spent');
  PERFORM pg_temp.eq((SELECT sum((p ->> 'lineSpend')::numeric) FROM jsonb_array_elements(_products -> 'rows') p),
    pg_temp.num(_products, '{reconciliation,linesTotal}'), 'products sum to line total');
  PERFORM pg_temp.eq(pg_temp.num(_products, '{reconciliation,linesTotal}') + pg_temp.num(_products, '{reconciliation,taxTotal}')
    + pg_temp.num(_products, '{reconciliation,shippingTotal}') + pg_temp.num(_products, '{reconciliation,difference}'),
    pg_temp.num(_products, '{reconciliation,spent}'), 'product reconciliation holds');
  PERFORM pg_temp.eq(_products #>> '{rows,0,productName}', 'P7E Device', 'top product');
  PERFORM pg_temp.eq(pg_temp.num(_products, '{rows,0,lineSpend}'), 18200::numeric, 'device line spend');
  PERFORM pg_temp.eq(jsonb_array_length(_products #> '{rows,0,unitGroups}'), 2, 'ea/EA merge; bx+12 is separate');
  PERFORM pg_temp.eq(pg_temp.num(_products, '{rows,1,lineSpend}'), 407.48, 'gauze line spend');
  PERFORM pg_temp.eq(jsonb_array_length(_products #> '{rows,1,unitGroups}'), 1, 'bx/BX merge');

  PERFORM pg_temp.eq(pg_temp.num(_commitments, '{totalCount}'), 3::numeric, 'open commitments listed');
  PERFORM pg_temp.eq(pg_temp.num(_commitments, '{pricedAmount}'), 136.78, 'open commitments priced amount');
  PERFORM pg_temp.assert((SELECT bool_and(c -> 'amount' = 'null'::jsonb) FROM jsonb_array_elements(_commitments -> 'rows') c
    WHERE c ->> 'pricingStatus' = 'unpriced'), 'unpriced commitments carry no amount');
  PERFORM pg_temp.eq((SELECT c ->> 'teamName' FROM jsonb_array_elements(_commitments -> 'rows') c
    WHERE c ->> 'requestId' = '7e000000-0000-4000-8000-000000000701'), 'First Team', 'team label');
END
$lists$;

-- Owner drill-down: pages of every filter sum to the filter's total.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7e000000-0000-4000-8000-000000000001');
DO $documents$
DECLARE
  _filter record;
  _page jsonb;
  _cursor jsonb;
  _sum numeric;
  _count integer;
  _total numeric;
BEGIN
  FOR _filter IN SELECT * FROM (VALUES
      ('all', NULL, 7, 19892.86),
      ('month', '2026-01', 2, 19388.58),
      ('vendor', '7e000000-0000-4000-8000-000000000302', 2, 200),
      ('dated_by_posting', NULL, 2, 244.28),
      ('order_confirmations', NULL, 2, 244.28),
      ('type_unclassified', NULL, 1, 100),
      ('legacy_currency', NULL, 5, 19732.86),
      ('component_difference', NULL, 1, 60),
      ('possible_duplicates', NULL, 2, 200),
      ('outside_budgets', NULL, 2, 52.5),
      ('excluded', NULL, 3, 1525)) f(name, value, expected_count, expected_amount)
  LOOP
    _cursor := NULL; _sum := 0; _count := 0;
    LOOP
      _page := public.list_financial_spend_documents('7e000000-0000-4000-8000-000000000101', '2026-01-01', '2026-12-31',
        _filter.name, _filter.value, 1, (_cursor ->> 'spendDate')::date, (_cursor ->> 'invoiceId')::uuid);
      _sum := _sum + COALESCE((SELECT sum((r ->> 'amount')::numeric) FROM jsonb_array_elements(_page -> 'rows') r), 0);
      _count := _count + jsonb_array_length(_page -> 'rows');
      _total := (_page ->> 'totalAmount')::numeric;
      PERFORM pg_temp.eq((_page ->> 'totalCount')::integer, _filter.expected_count, 'total count for ' || _filter.name);
      _cursor := _page -> 'nextCursor';
      EXIT WHEN _cursor IS NULL OR _cursor = 'null'::jsonb;
    END LOOP;
    PERFORM pg_temp.eq(_count, _filter.expected_count, 'paged rows for ' || _filter.name);
    PERFORM pg_temp.eq(_sum, _filter.expected_amount::numeric, 'paged amount for ' || _filter.name);
    PERFORM pg_temp.eq(_total, _filter.expected_amount::numeric, 'total amount for ' || _filter.name);
  END LOOP;
  _page := public.list_financial_spend_documents('7e000000-0000-4000-8000-000000000101', '2026-01-01', '2026-12-31', 'excluded');
  PERFORM pg_temp.eq((_page ->> 'countsTowardSpent')::boolean, false, 'excluded list never counts toward Spent');
  _page := public.get_financial_document_detail('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000505');
  PERFORM pg_temp.eq((_page #>> '{flags,possibleDuplicate}')::boolean, true, 'detail flags duplicate');
  PERFORM pg_temp.eq((_page #>> '{flags,typeUnclassified}')::boolean, true, 'detail flags unclassified type');
  PERFORM pg_temp.eq(jsonb_array_length(_page -> 'lines'), 1, 'detail lines');
  PERFORM pg_temp.assert(NOT (_page -> 'document' ? 'storagePath'), 'no storage path in detail');
  _page := public.list_financial_product_lines('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000401', '2026-01-01', '2026-12-31');
  PERFORM pg_temp.eq((_page ->> 'totalLineSpend')::numeric, 18200::numeric, 'product lines sum to product line spend');
  PERFORM pg_temp.expect_error($$SELECT public.list_financial_spend_documents('7e000000-0000-4000-8000-000000000101', '2026-01-01', '2026-12-31', 'bogus')$$,
    'Unknown document filter', '22023');
  PERFORM pg_temp.expect_error($$SELECT public.list_financial_spend_documents('7e000000-0000-4000-8000-000000000101', '2026-01-01', '2026-12-31', 'month', '2026-13')$$,
    'month filter needs YYYY-MM', '22023');
  PERFORM pg_temp.expect_error($$SELECT public.get_financial_spend_series('7e000000-0000-4000-8000-000000000101', '2026-12-31', '2026-01-01')$$,
    'from must be on or before to', '22023');
  PERFORM pg_temp.expect_error($$SELECT public.get_financial_document_detail('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000511')$$,
    'Posted document not found', 'P0002');
  PERFORM pg_temp.expect_error($$SELECT public.get_financial_document_detail('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000520')$$,
    'Posted document not found', 'P0002');
END
$documents$;
RESET ROLE;

-- ---------------------------------------------------------------------------------------
-- 4. Pace, thresholds and states with inactive budgets selected explicitly.
-- ---------------------------------------------------------------------------------------
-- Period 2026-01-01..2026-04-10 (100 days) holds 19648.58 of counted spend.
INSERT INTO public.organization_budgets (id, organization_id, name, period_start, period_end, amount, active) VALUES
  ('7e000000-0000-4000-8000-000000000911', '7e000000-0000-4000-8000-000000000101', 'Exactly ten ahead', '2026-01-01', '2026-04-10', 39297.16, false),
  ('7e000000-0000-4000-8000-000000000912', '7e000000-0000-4000-8000-000000000101', 'Just over ten ahead', '2026-01-01', '2026-04-10', 39297.15, false),
  ('7e000000-0000-4000-8000-000000000913', '7e000000-0000-4000-8000-000000000101', 'Five ahead', '2026-01-01', '2026-04-10', 49121.45, false),
  ('7e000000-0000-4000-8000-000000000914', '7e000000-0000-4000-8000-000000000101', 'Ninety percent', '2026-01-01', '2026-04-10', 21831.75, false),
  ('7e000000-0000-4000-8000-000000000915', '7e000000-0000-4000-8000-000000000101', 'Over', '2026-01-01', '2026-04-10', 19000, false),
  ('7e000000-0000-4000-8000-000000000916', '7e000000-0000-4000-8000-000000000101', 'Zero', '2026-01-01', '2026-04-10', 0, false),
  ('7e000000-0000-4000-8000-000000000918', '7e000000-0000-4000-8000-000000000101', 'Eighty five percent', '2026-01-01', '2026-04-10', 23200, false);
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7e000000-0000-4000-8000-000000000001');
DO $pace$
DECLARE _s jsonb;
BEGIN
  -- As of 2026-02-09: elapsed 40/100.
  _s := public.get_financial_spend_summary('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000911', '2026-02-09');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{pace,elapsedPercent}'), 40::numeric, 'elapsed 40%');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{pace,gapPoints}'), 10::numeric, 'gap exactly 10');
  PERFORM pg_temp.eq(_s #>> '{pace,band}', 'ahead', 'ahead band');
  PERFORM pg_temp.assert(pg_temp.signal(_s, 'pace_ahead') IS NULL, 'exactly 10 points ahead is not a signal');
  _s := public.get_financial_spend_summary('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000912', '2026-02-09');
  PERFORM pg_temp.assert(pg_temp.signal(_s, 'pace_ahead') IS NOT NULL, 'more than 10 points ahead is a signal');
  _s := public.get_financial_spend_summary('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000913', '2026-02-04');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{pace,gapPoints}'), 5::numeric, 'gap exactly 5');
  PERFORM pg_temp.eq(_s #>> '{pace,band}', 'even', '5 points is about even');
  _s := public.get_financial_spend_summary('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000914', '2026-04-10');
  PERFORM pg_temp.assert(pg_temp.signal(_s, 'budget_near_limit') IS NOT NULL, '90% used is near limit');
  PERFORM pg_temp.assert(pg_temp.signal(_s, 'budget_over') IS NULL, 'not over');
  PERFORM pg_temp.eq(_s #>> '{pace,band}', 'behind', 'last day: elapsed 100%, spent 90% is 10 points behind');
  _s := public.get_financial_spend_summary('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000918', '2026-04-10');
  PERFORM pg_temp.assert(pg_temp.signal(_s, 'budget_near_limit') IS NULL, '85% used is not near the limit');
  _s := public.get_financial_spend_summary('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000915', '2026-04-11');
  PERFORM pg_temp.eq(_s #>> '{pace,state}', 'ended', 'after the end');
  PERFORM pg_temp.assert(_s #> '{pace,band}' = 'null'::jsonb, 'no pace wording after the end');
  PERFORM pg_temp.eq(pg_temp.num(pg_temp.signal(_s, 'budget_over'), '{amount}'), 648.58, 'over budget by');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{remaining}'), -648.58, 'remaining is negative when over');
  _s := public.get_financial_spend_summary('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000915', '2025-12-31');
  PERFORM pg_temp.eq(_s #>> '{pace,state}', 'not_started', 'before the start');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{pace,elapsedPercent}'), 0::numeric, 'nothing elapsed');
  _s := public.get_financial_spend_summary('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000916', '2026-02-09');
  PERFORM pg_temp.eq(_s #>> '{pace,state}', 'no_amount', 'zero budget');
  PERFORM pg_temp.assert(_s #> '{pace,spentPercent}' = 'null'::jsonb, 'no percent of zero');
  -- Leap year: 2028-01-01..2028-12-31 has 366 days.
  INSERT INTO public.organization_budgets (id, organization_id, name, period_start, period_end, amount, active)
  VALUES ('7e000000-0000-4000-8000-000000000917', '7e000000-0000-4000-8000-000000000101', 'Leap', '2028-01-01', '2028-12-31', 100, true);
  _s := public.get_financial_spend_summary('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000917', '2028-06-30');
  PERFORM pg_temp.eq(pg_temp.num(_s, '{pace,elapsedPercent}'), round(182::numeric / 366 * 100, 2), 'leap-year elapsed');
  DELETE FROM public.organization_budgets WHERE id = '7e000000-0000-4000-8000-000000000917';
  -- No budget at all (organization B owner): calendar year to date.
END
$pace$;
SELECT pg_temp.as_user('7e000000-0000-4000-8000-000000000004');
SELECT pg_temp.keep('b_summary', public.get_financial_spend_summary('7e000000-0000-4000-8000-000000000102', NULL, '2026-11-16'));
SELECT pg_temp.expect_error($$SELECT public.get_financial_spend_summary('7e000000-0000-4000-8000-000000000102', '7e000000-0000-4000-8000-000000000901', '2026-11-16')$$,
  'Budget not found', 'P0002');
RESET ROLE;
SELECT pg_temp.eq(pg_temp.val('b_summary') #>> '{scope,kind}', 'calendar_year_to_date', 'no budget: calendar year to date');
SELECT pg_temp.eq(pg_temp.num(pg_temp.val('b_summary'), '{spent}'), 9999::numeric, 'organization B spend only');
SELECT pg_temp.assert(pg_temp.val('b_summary') -> 'remaining' = 'null'::jsonb AND pg_temp.val('b_summary') -> 'pace' = 'null'::jsonb,
  'no remaining or pace without a budget');

-- ---------------------------------------------------------------------------------------
-- 5. Active budget overlap guard.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7e000000-0000-4000-8000-000000000002');
SELECT pg_temp.expect_error($$INSERT INTO public.organization_budgets (organization_id, name, period_start, period_end, amount, active)
  VALUES ('7e000000-0000-4000-8000-000000000101', 'Overlap', '2026-06-01', '2027-05-31', 10, true)$$,
  'overlaps the active budget "Tape"', '23P01');
-- Admins keep 6A.1 budget editing: an adjacent period is fine.
INSERT INTO public.organization_budgets (id, organization_id, name, period_start, period_end, amount, active)
VALUES ('7e000000-0000-4000-8000-000000000902', '7e000000-0000-4000-8000-000000000101', '2027 Sports Medicine', '2027-01-01', '2027-12-31', 60000, true);
SELECT pg_temp.expect_error($$UPDATE public.organization_budgets SET period_end = '2027-01-01'
  WHERE id = '7e000000-0000-4000-8000-000000000901'$$, 'overlaps the active budget "2027 Sports Medicine"', '23P01');
SELECT pg_temp.expect_error($$UPDATE public.organization_budgets SET active = true
  WHERE id = '7e000000-0000-4000-8000-000000000911'$$, 'overlaps the active budget "Tape"', '23P01');
-- Deactivating is always allowed; the same period can then be activated elsewhere.
UPDATE public.organization_budgets SET active = false WHERE id = '7e000000-0000-4000-8000-000000000901';
UPDATE public.organization_budgets SET active = true WHERE id = '7e000000-0000-4000-8000-000000000911';
UPDATE public.organization_budgets SET active = false WHERE id = '7e000000-0000-4000-8000-000000000911';
UPDATE public.organization_budgets SET active = true WHERE id = '7e000000-0000-4000-8000-000000000901';
RESET ROLE;
-- Another organization's budgets never conflict.
INSERT INTO public.organization_budgets (organization_id, name, period_start, period_end, amount, active)
VALUES ('7e000000-0000-4000-8000-000000000102', 'B 2026', '2026-01-01', '2026-12-31', 1, true);
-- With 2027 covered, the Jan 1 UTC document is no longer outside every budget.
SELECT pg_temp.eq((SELECT count(*) FROM public.financial_outside_budget_ids('7e000000-0000-4000-8000-000000000101')), 1::bigint,
  'only the 2025 document is outside every active budget');

-- ---------------------------------------------------------------------------------------
-- 6. Posted-document guards (every client role, and postgres outside a sanctioned path).
-- ---------------------------------------------------------------------------------------
SELECT pg_temp.keep('before_guards', pg_temp.state());
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7e000000-0000-4000-8000-000000000001');
DO $guards$
DECLARE
  _change record;
BEGIN
  FOR _change IN SELECT * FROM (VALUES
      ('subtotal', '1'), ('tax_amount', '1'), ('shipping_amount', '1'), ('invoice_total', '1'),
      ('total_amount', '1'), ('total', '1'), ('invoice_date', '''2026-02-02'''), ('order_date', '''2026-02-02'''),
      ('vendor_id', '''7e000000-0000-4000-8000-000000000302'''), ('vendor_name', '''Changed'''),
      ('document_type', '''STATEMENT'''), ('invoice_number', '''X'''), ('purchase_order_number', '''PO'''),
      ('order_number', '''ON'''), ('currency_code', '''EUR'''), ('posted_at', 'NULL'), ('posted_at', 'now()'),
      ('processing_status', '''review_required'''), ('source_file_id', 'gen_random_uuid()'), ('payment_terms', '''Net 5''')) c(col, value)
  LOOP
    PERFORM pg_temp.expect_error(format('UPDATE public.invoices SET %I = %s WHERE id = %L',
      _change.col, _change.value, '7e000000-0000-4000-8000-000000000501'), 'Posted documents can''t be changed', '55000');
  END LOOP;
  PERFORM pg_temp.expect_error($$DELETE FROM public.invoices WHERE id = '7e000000-0000-4000-8000-000000000501'$$,
    'Posted documents can''t be deleted', '55000');
  PERFORM pg_temp.expect_error($$UPDATE public.invoice_items SET total_price = 1 WHERE id = '7e000000-0000-4000-8000-000000000601'$$,
    'Lines on a posted document can''t be changed', '55000');
  PERFORM pg_temp.expect_error($$UPDATE public.invoice_items SET description = 'x' WHERE id = '7e000000-0000-4000-8000-000000000601'$$,
    'Lines on a posted document can''t be changed', '55000');
  PERFORM pg_temp.expect_error($$DELETE FROM public.invoice_items WHERE id = '7e000000-0000-4000-8000-000000000601'$$,
    'Lines on a posted document can''t be changed', '55000');
  PERFORM pg_temp.expect_error($$INSERT INTO public.invoice_items (invoice_id, organization_id, description, quantity, total_price)
    VALUES ('7e000000-0000-4000-8000-000000000501', '7e000000-0000-4000-8000-000000000101', 'added', 1, 1)$$,
    'Lines on a posted document can''t be changed', '55000');
  -- Posting directly is refused: only invoice review posts.
  PERFORM pg_temp.expect_error($$UPDATE public.invoices SET posted_at = now() WHERE id = '7e000000-0000-4000-8000-000000000511'$$,
    'Documents can only be posted through invoice review', '55000');
  -- A client cannot borrow the posting context (the setting is ignored... because it cannot be set).
  PERFORM pg_temp.assert(NOT has_function_privilege('authenticated', 'public.financial_context_is(text)', 'EXECUTE'), 'context helper is internal');
  -- Drafts stay editable.
  UPDATE public.invoices SET invoice_total = 998 WHERE id = '7e000000-0000-4000-8000-000000000511';
  INSERT INTO public.invoice_items (invoice_id, organization_id, description, quantity, total_price)
  VALUES ('7e000000-0000-4000-8000-000000000511', '7e000000-0000-4000-8000-000000000101', 'draft line', 1, 1);
  -- A draft line cannot be moved onto a posted document.
  PERFORM pg_temp.expect_error($$UPDATE public.invoice_items SET invoice_id = '7e000000-0000-4000-8000-000000000501'
    WHERE invoice_id = '7e000000-0000-4000-8000-000000000511'$$, 'Lines on a posted document can''t be changed', '55000');
END
$guards$;
SET LOCAL ROLE service_role;
SELECT pg_temp.expect_error($$UPDATE public.invoices SET invoice_total = 1 WHERE id = '7e000000-0000-4000-8000-000000000501'$$,
  'Posted documents can''t be changed', '55000');
SELECT pg_temp.expect_error($$DELETE FROM public.invoice_items WHERE id = '7e000000-0000-4000-8000-000000000601'$$,
  'Lines on a posted document can''t be changed', '55000');
RESET ROLE;
-- Even postgres needs a sanctioned path.
SELECT pg_temp.expect_error($$UPDATE public.invoices SET invoice_total = 1 WHERE id = '7e000000-0000-4000-8000-000000000501'$$,
  'Posted documents can''t be changed', '55000');
SELECT pg_temp.expect_error($$DELETE FROM public.invoices WHERE id = '7e000000-0000-4000-8000-000000000501'$$,
  'Posted documents can''t be deleted', '55000');
SELECT pg_temp.expect_error($$UPDATE public.invoices SET reviewed_by = '7e000000-0000-4000-8000-000000000002' WHERE id = '7e000000-0000-4000-8000-000000000501'$$,
  'Posted documents can''t be changed', '55000');
-- Allowed on a posted row: a no-op write (updated_at only) and the reviewer cleared by user deletion.
UPDATE public.invoices SET updated_at = updated_at WHERE id = '7e000000-0000-4000-8000-000000000501';
UPDATE public.invoices SET reviewed_by = NULL WHERE id = '7e000000-0000-4000-8000-000000000501';
SELECT pg_temp.eq((pg_temp.state() ->> 'invoices') <> (pg_temp.val('before_guards') ->> 'invoices'), true, 'draft edits only changed drafts');
SELECT pg_temp.eq(pg_temp.num(to_jsonb(public.financial_spend_rows('7e000000-0000-4000-8000-000000000101', NULL, NULL, '7e000000-0000-4000-8000-000000000501')), '{amount}'),
  19054.88, 'posted amount unchanged');

-- ---------------------------------------------------------------------------------------
-- 7. Posting guard and the real posting path.
-- ---------------------------------------------------------------------------------------
INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type) VALUES
  ('7e000000-0000-4000-8000-000000000a20', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000001', '7e000000-0000-4000-8000-000000000101/d20.pdf', 'd20.pdf', 10, 'application/pdf'),
  ('7e000000-0000-4000-8000-000000000a21', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000001', '7e000000-0000-4000-8000-000000000101/d21.pdf', 'd21.pdf', 10, 'application/pdf'),
  ('7e000000-0000-4000-8000-000000000a22', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000001', '7e000000-0000-4000-8000-000000000101/d22.pdf', 'd22.pdf', 10, 'application/pdf'),
  ('7e000000-0000-4000-8000-000000000a23', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000001', '7e000000-0000-4000-8000-000000000101/d23.pdf', 'd23.pdf', 10, 'application/pdf');
INSERT INTO public.invoices (id, organization_id, source_file_id, vendor_id, vendor_name, document_type, invoice_number, invoice_date, processing_status, invoice_total, total_amount, total, currency_code) VALUES
  ('7e000000-0000-4000-8000-000000000b20', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000a20', '7e000000-0000-4000-8000-000000000301', 'P7E Vendor One', 'INVOICE', 'INV-20', '2026-06-01', 'review_required', 250, 250, 250, NULL),
  ('7e000000-0000-4000-8000-000000000b21', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000a21', '7e000000-0000-4000-8000-000000000301', 'P7E Vendor One', 'CREDIT_MEMO', 'CM-21', '2026-06-02', 'review_required', 30, 30, 30, NULL),
  ('7e000000-0000-4000-8000-000000000b22', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000a22', '7e000000-0000-4000-8000-000000000301', 'P7E Vendor One', 'STATEMENT', 'ST-22', '2026-06-03', 'review_required', 40, 40, 40, NULL),
  ('7e000000-0000-4000-8000-000000000b23', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000a23', '7e000000-0000-4000-8000-000000000301', 'P7E Vendor One', 'UNKNOWN', 'INV-23', '2026-06-04', 'review_required', 10, 10, 10, NULL);
INSERT INTO public.invoice_items (id, invoice_id, organization_id, line_number, description, quantity, unit_of_measure, unit_price, total_price, product_id) VALUES
  ('7e000000-0000-4000-8000-000000000c20', '7e000000-0000-4000-8000-000000000b20', '7e000000-0000-4000-8000-000000000101', 1, 'Device pads', 5, 'ea', 50, 250, '7e000000-0000-4000-8000-000000000401'),
  ('7e000000-0000-4000-8000-000000000c21', '7e000000-0000-4000-8000-000000000b21', '7e000000-0000-4000-8000-000000000101', 1, 'Credit', 1, 'ea', 30, 30, '7e000000-0000-4000-8000-000000000401'),
  ('7e000000-0000-4000-8000-000000000c22', '7e000000-0000-4000-8000-000000000b22', '7e000000-0000-4000-8000-000000000101', 1, 'Statement', 1, 'ea', 40, 40, '7e000000-0000-4000-8000-000000000401'),
  ('7e000000-0000-4000-8000-000000000c23', '7e000000-0000-4000-8000-000000000b23', '7e000000-0000-4000-8000-000000000101', 1, 'Gauze', 1, 'bx', 10, 10, '7e000000-0000-4000-8000-000000000402');

SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7e000000-0000-4000-8000-000000000001');
SELECT pg_temp.expect_error($$SELECT public.post_reviewed_invoice('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000a21')$$,
  'Credit memos can''t be posted yet', '22023');
SELECT pg_temp.expect_error($$SELECT public.post_reviewed_invoice('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000a22')$$,
  'Statements are reference documents', '22023');
SELECT public.post_reviewed_invoice('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000a20');
SELECT public.post_reviewed_invoice('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000a23');
SELECT pg_temp.assert(COALESCE(current_setting('sportspend.financial_context', true), '') = '', 'posting clears its context');
SELECT pg_temp.expect_error($$UPDATE public.invoices SET invoice_total = 1 WHERE id = '7e000000-0000-4000-8000-000000000b20'$$,
  'Posted documents can''t be changed', '55000');
SELECT pg_temp.keep('after_post', public.get_financial_spend_summary('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000901', '2026-11-16'));
SELECT pg_temp.keep('prices_after_post', public.get_price_intelligence_overview('7e000000-0000-4000-8000-000000000101'));
RESET ROLE;
SELECT pg_temp.assert(EXISTS (SELECT 1 FROM jsonb_array_elements(pg_temp.val('prices_after_post') -> 'rows') r
  WHERE r ->> 'productId' = '7e000000-0000-4000-8000-000000000401'),
  'Price Intelligence includes a posting with no currency recorded (legacy USD)');
SELECT pg_temp.eq(pg_temp.num(pg_temp.val('after_post'), '{spent}'), 20152.86, 'real postings count (250 + 10)');
SELECT pg_temp.assert((SELECT posted_at IS NULL FROM public.invoices WHERE id = '7e000000-0000-4000-8000-000000000b21'), 'credit memo still draft');
SELECT pg_temp.eq((SELECT quantity FROM public.inventory_items WHERE product_id = '7e000000-0000-4000-8000-000000000401'), 5::numeric, 'receipt landed');

-- ---------------------------------------------------------------------------------------
-- 8. Audited removal.
-- ---------------------------------------------------------------------------------------
SELECT pg_temp.keep('before_removal', pg_temp.state());
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7e000000-0000-4000-8000-000000000001');
SELECT pg_temp.keep('posted_at_20', to_jsonb((SELECT posted_at FROM public.invoices WHERE id = '7e000000-0000-4000-8000-000000000b20')));
SELECT pg_temp.expect_error($$SELECT public.delete_invoice_permanently('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000a20')$$,
  'Posted documents must be removed with a recorded reason.', '55000');
SELECT pg_temp.expect_error(format($$SELECT public.remove_posted_financial_document('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000a20', %L, 'INV-20', 'too short')$$,
  pg_temp.val('posted_at_20') #>> '{}'), 'Give a reason of 10 to 1000 characters', '22023');
SELECT pg_temp.expect_error(format($$SELECT public.remove_posted_financial_document('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000a20', %L, 'INV-2', 'Posted against the wrong vendor')$$,
  pg_temp.val('posted_at_20') #>> '{}'), 'Type INV-20 to confirm the removal.', '22023');
SELECT pg_temp.expect_error($$SELECT public.remove_posted_financial_document('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000a20', '2020-01-01', 'INV-20', 'Posted against the wrong vendor')$$,
  'This document changed since you opened it', '55000');
SELECT pg_temp.expect_error($$SELECT public.remove_posted_financial_document('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000a21', NULL, 'CM-21', 'Posted against the wrong vendor')$$,
  'isn''t posted', '55000');
SELECT pg_temp.as_user('7e000000-0000-4000-8000-000000000002');
SELECT pg_temp.expect_error(format($$SELECT public.remove_posted_financial_document('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000a20', %L, 'INV-20', 'Posted against the wrong vendor')$$,
  pg_temp.val('posted_at_20') #>> '{}'), 'Forbidden: owner access required', '42501');
SELECT pg_temp.as_user('7e000000-0000-4000-8000-000000000004');
SELECT pg_temp.expect_error(format($$SELECT public.remove_posted_financial_document('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000a20', %L, 'INV-20', 'Posted against the wrong vendor')$$,
  pg_temp.val('posted_at_20') #>> '{}'), 'Forbidden: owner access required', '42501');
RESET ROLE;
SELECT pg_temp.eq(pg_temp.state(), pg_temp.val('before_removal'), 'refused removals changed nothing');

-- A removal the inventory reversal refuses leaves no evidence row and changes nothing.
DELETE FROM public.inventory_price_history WHERE invoice_id = '7e000000-0000-4000-8000-000000000b23';
SELECT pg_temp.keep('before_refused_reversal', pg_temp.state());
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7e000000-0000-4000-8000-000000000001');
SELECT pg_temp.expect_error(format($$SELECT public.remove_posted_financial_document('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000a23', %L, 'inv-23', 'Duplicate of an earlier upload')$$,
  (SELECT posted_at FROM public.invoices WHERE id = '7e000000-0000-4000-8000-000000000b23')), 'inventory provenance is incomplete');
RESET ROLE;
SELECT pg_temp.eq(pg_temp.state(), pg_temp.val('before_refused_reversal'), 'refused reversal wrote no removal and changed nothing');

SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7e000000-0000-4000-8000-000000000001');
SELECT pg_temp.keep('removal', public.remove_posted_financial_document('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000a20',
  (pg_temp.val('posted_at_20') #>> '{}')::timestamptz, ' inv-20 ', '  Posted against the wrong vendor  '));
SELECT pg_temp.assert(COALESCE(current_setting('sportspend.financial_context', true), '') = '', 'removal clears its context');
SELECT pg_temp.keep('after_removal', public.get_financial_spend_summary('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000901', '2026-11-16'));
SELECT pg_temp.keep('removals', public.list_financial_document_removals('7e000000-0000-4000-8000-000000000101'));
SELECT pg_temp.expect_error($$SELECT * FROM public.financial_document_removals$$, 'permission denied');
RESET ROLE;
DO $removal$
DECLARE
  _r public.financial_document_removals%ROWTYPE;
  _result jsonb := pg_temp.val('removal');
  _list jsonb := pg_temp.val('removals');
BEGIN
  PERFORM pg_temp.eq((_result ->> 'spendAmount')::numeric, 250::numeric, 'removal returns spend amount');
  PERFORM pg_temp.eq((_result ->> 'sourceFileRetained')::boolean, true, 'source retained');
  PERFORM pg_temp.assert(NOT (_result ? 'storagePath'), 'no storage path returned');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.invoices WHERE id = '7e000000-0000-4000-8000-000000000b20'), 'invoice removed');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.vendor_invoices WHERE id = '7e000000-0000-4000-8000-000000000a20'), 'upload row removed');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.inventory_adjustments WHERE source_invoice_id = '7e000000-0000-4000-8000-000000000b20'), 'receipt reversed');
  PERFORM pg_temp.eq((SELECT quantity FROM public.inventory_items WHERE product_id = '7e000000-0000-4000-8000-000000000401'), 0::numeric, 'stock reversed');
  SELECT * INTO _r FROM public.financial_document_removals WHERE invoice_id = '7e000000-0000-4000-8000-000000000b20';
  PERFORM pg_temp.eq(_r.reason, 'Posted against the wrong vendor', 'reason trimmed');
  PERFORM pg_temp.eq(_r.removed_by, '7e000000-0000-4000-8000-000000000001'::uuid, 'removed by');
  PERFORM pg_temp.eq(_r.storage_path, '7e000000-0000-4000-8000-000000000101/d20.pdf', 'storage path recorded');
  PERFORM pg_temp.eq(_r.spend_date, date '2026-06-01', 'spend date');
  PERFORM pg_temp.eq(_r.counted_as_spend, true, 'counted');
  PERFORM pg_temp.eq(_r.header ->> 'invoice_number', 'INV-20', 'header snapshot');
  PERFORM pg_temp.eq((_r.header ->> 'invoice_total')::numeric, 250::numeric, 'header totals');
  PERFORM pg_temp.eq(jsonb_array_length(_r.lines), 1, 'line snapshot');
  PERFORM pg_temp.eq((_r.lines -> 0 ->> 'quantity')::numeric, 5::numeric, 'line quantity');
  PERFORM pg_temp.eq((_r.inventory_reversal ->> 'removedAdjustmentCount')::integer, 1, 'reversal summary');
  PERFORM pg_temp.eq(pg_temp.num(pg_temp.val('after_removal'), '{spent}'), 19902.86, 'removed document leaves Spent');
  PERFORM pg_temp.eq(pg_temp.num(pg_temp.val('after_removal'), '{coverage,removedAfterPosting,count}'), 1::numeric, 'coverage shows the removal');
  PERFORM pg_temp.eq(pg_temp.num(pg_temp.val('after_removal'), '{coverage,removedAfterPosting,amount}'), 250::numeric, 'coverage removal amount');
  PERFORM pg_temp.eq((_list ->> 'totalCount')::integer, 1, 'removals listed');
  PERFORM pg_temp.eq(_list #>> '{rows,0,reason}', 'Posted against the wrong vendor', 'listed reason');
  PERFORM pg_temp.assert(NOT (_list -> 'rows' -> 0 ? 'storagePath'), 'no storage path listed');
  PERFORM pg_temp.eq(_list #>> '{rows,0,removedByName}', 'phase7e-1@example.invalid', 'listed remover');
END
$removal$;
SELECT pg_temp.expect_error($$UPDATE public.financial_document_removals SET reason = 'changed reason here'$$, 'Removal records are permanent', '55000');
SELECT pg_temp.expect_error($$DELETE FROM public.financial_document_removals$$, 'Removal records are permanent', '55000');

-- Source files of posted and removed documents are retained; drafts stay deletable.
INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type) VALUES
  ('7e000000-0000-4000-8000-000000000a02', '7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000001', '7e000000-0000-4000-8000-000000000101/d2.pdf', 'd2.pdf', 10, 'application/pdf');
SELECT set_config('sportspend.financial_context', 'post', true);
UPDATE public.invoices SET source_file_id = '7e000000-0000-4000-8000-000000000a02' WHERE id = '7e000000-0000-4000-8000-000000000502';
SELECT set_config('sportspend.financial_context', '', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7e000000-0000-4000-8000-000000000001');
SELECT pg_temp.eq(public.vendor_invoice_storage_deletable('7e000000-0000-4000-8000-000000000101/d20.pdf'), false, 'removed document PDF is retained');
SELECT pg_temp.eq(public.vendor_invoice_storage_deletable('7e000000-0000-4000-8000-000000000101/d2.pdf'), false, 'posted document PDF is retained');
SELECT pg_temp.eq(public.vendor_invoice_storage_deletable('7e000000-0000-4000-8000-000000000101/d21.pdf'), true, 'draft PDF is deletable');
SELECT public.delete_invoice_permanently('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000a21');
SELECT pg_temp.eq(public.vendor_invoice_storage_deletable('7e000000-0000-4000-8000-000000000101/d21.pdf'), true, 'deleted draft PDF is deletable');
RESET ROLE;
SELECT pg_temp.assert(EXISTS (SELECT 1 FROM pg_policy WHERE polname = 'vendor_invoices_storage_owner_delete'
  AND polrelid = 'storage.objects'::regclass AND pg_get_expr(polqual, polrelid) LIKE '%vendor_invoice_storage_deletable(name)%'),
  'storage delete policy consults the retention check');

-- ---------------------------------------------------------------------------------------
-- 9. Access matrix and grants.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $access$
DECLARE
  _user uuid;
  _call text;
BEGIN
  FOREACH _user IN ARRAY ARRAY['7e000000-0000-4000-8000-000000000003', '7e000000-0000-4000-8000-000000000007']::uuid[] LOOP
    PERFORM pg_temp.as_user(_user);
    FOREACH _call IN ARRAY ARRAY[
      $$SELECT public.get_financial_spend_summary('7e000000-0000-4000-8000-000000000101')$$,
      $$SELECT public.get_financial_spend_series('7e000000-0000-4000-8000-000000000101', '2026-01-01', '2026-12-31')$$,
      $$SELECT public.list_financial_vendor_spend('7e000000-0000-4000-8000-000000000101', '2026-01-01', '2026-12-31')$$,
      $$SELECT public.list_financial_product_spend('7e000000-0000-4000-8000-000000000101', '2026-01-01', '2026-12-31')$$,
      $$SELECT public.list_financial_commitments('7e000000-0000-4000-8000-000000000101', '2026-01-01', '2026-12-31')$$,
      $$SELECT public.list_financial_spend_documents('7e000000-0000-4000-8000-000000000101', '2026-01-01', '2026-12-31')$$,
      $$SELECT public.get_financial_document_detail('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000501')$$,
      $$SELECT public.list_financial_product_lines('7e000000-0000-4000-8000-000000000101', NULL, '2026-01-01', '2026-12-31')$$,
      $$SELECT public.list_financial_document_removals('7e000000-0000-4000-8000-000000000101')$$,
      $$SELECT public.remove_posted_financial_document('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000a23', now(), 'INV-23', 'Not allowed for this user')$$]
    LOOP
      PERFORM pg_temp.expect_error(_call, 'Forbidden', '42501');
    END LOOP;
  END LOOP;
END
$access$;
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.expect_error($$SELECT public.get_financial_spend_summary('7e000000-0000-4000-8000-000000000101')$$, 'permission denied');
SELECT pg_temp.expect_error($$SELECT public.remove_posted_financial_document('7e000000-0000-4000-8000-000000000101', '7e000000-0000-4000-8000-000000000a23', now(), 'x', 'xxxxxxxxxxxx')$$, 'permission denied');
RESET ROLE;
DO $grants$
DECLARE _fn text;
BEGIN
  FOREACH _fn IN ARRAY ARRAY[
    'public.financial_spend_rows(uuid, date, date, uuid)', 'public.financial_spend_line_rows(uuid, date, date)',
    'public.financial_commitment_rows(uuid, date, date)', 'public.financial_currency_basis(text)',
    'public.financial_context_is(text)', 'public.delete_invoice_internal(uuid, uuid)',
    'public.financial_possible_duplicate_ids(uuid, date, date)', 'public.financial_outside_budget_ids(uuid)',
    'public.financial_assert_range(date, date)', 'public.financial_assert_access(uuid, boolean)',
    'public.financial_spend_row_json(jsonb)', 'public.tg_guard_posted_invoice()', 'public.tg_guard_posted_invoice_item()',
    'public.tg_guard_organization_budget_overlap()', 'public.tg_financial_document_removals_append_only()'] LOOP
    PERFORM pg_temp.assert(NOT has_function_privilege('authenticated', _fn, 'EXECUTE')
      AND NOT has_function_privilege('anon', _fn, 'EXECUTE')
      AND NOT has_function_privilege('service_role', _fn, 'EXECUTE'), _fn || ' is internal');
  END LOOP;
  FOREACH _fn IN ARRAY ARRAY[
    'public.get_financial_spend_summary(uuid, uuid, date)', 'public.get_financial_spend_series(uuid, date, date)',
    'public.list_financial_vendor_spend(uuid, date, date, integer, integer)',
    'public.list_financial_product_spend(uuid, date, date, text, integer, integer)',
    'public.list_financial_commitments(uuid, date, date, text, integer, integer)',
    'public.list_financial_spend_documents(uuid, date, date, text, text, integer, date, uuid)',
    'public.get_financial_document_detail(uuid, uuid)',
    'public.list_financial_product_lines(uuid, uuid, date, date, integer, date, uuid)',
    'public.list_financial_document_removals(uuid, integer, timestamptz, uuid)',
    'public.remove_posted_financial_document(uuid, uuid, timestamptz, text, text)',
    'public.vendor_invoice_storage_deletable(text)'] LOOP
    PERFORM pg_temp.assert(has_function_privilege('authenticated', _fn, 'EXECUTE')
      AND NOT has_function_privilege('anon', _fn, 'EXECUTE'), _fn || ' is authenticated-only');
  END LOOP;
  PERFORM pg_temp.assert(NOT has_table_privilege('authenticated', 'public.financial_document_removals', 'SELECT')
    AND NOT has_table_privilege('anon', 'public.financial_document_removals', 'SELECT')
    AND has_table_privilege('service_role', 'public.financial_document_removals', 'SELECT')
    AND NOT has_table_privilege('service_role', 'public.financial_document_removals', 'INSERT'),
    'removal records: service_role SELECT only');
END
$grants$;

SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
