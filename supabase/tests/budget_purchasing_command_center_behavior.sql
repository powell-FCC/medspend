-- Budget & Purchasing command center rollback-only behavioral verification.
-- Run after 20261015120000_budget_purchasing_command_center.sql. All data rolls back.

BEGIN;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
VALUES
  ('bc000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'bpcc-owner@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('bc000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'bpcc-admin@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('bc000000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'bpcc-staff@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('bc000000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'bpcc-other@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('bc000000-0000-4000-8000-000000000005', 'authenticated', 'authenticated', 'bpcc-nonmember@example.invalid', '', now(), '{}', '{}', now(), now());

INSERT INTO public.organizations (id, name, created_by)
VALUES
  ('bc000000-0000-4000-8000-000000000101', 'Command Center Org', 'bc000000-0000-4000-8000-000000000001'),
  ('bc000000-0000-4000-8000-000000000102', 'Command Center Other Org', 'bc000000-0000-4000-8000-000000000004');

INSERT INTO public.organization_memberships (id, organization_id, user_id, role, active)
VALUES
  ('bc000000-0000-4000-8000-000000000111', 'bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000001', 'owner', true),
  ('bc000000-0000-4000-8000-000000000112', 'bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000002', 'admin', true),
  ('bc000000-0000-4000-8000-000000000113', 'bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000003', 'staff', true),
  ('bc000000-0000-4000-8000-000000000114', 'bc000000-0000-4000-8000-000000000102', 'bc000000-0000-4000-8000-000000000004', 'owner', true);

-- Budgets: two non-overlapping active halves, one inactive, and one in the other org.
INSERT INTO public.organization_budgets (id, organization_id, name, period_start, period_end, amount, active)
VALUES
  ('bc000000-0000-4000-8000-000000000201', 'bc000000-0000-4000-8000-000000000101', 'H1 2027', '2027-01-01', '2027-06-30', 1000, true),
  ('bc000000-0000-4000-8000-000000000202', 'bc000000-0000-4000-8000-000000000101', 'H2 2027', '2027-07-01', '2027-12-31', 500, true),
  ('bc000000-0000-4000-8000-000000000203', 'bc000000-0000-4000-8000-000000000101', 'Retired', '2027-01-01', '2027-12-31', 7, false),
  ('bc000000-0000-4000-8000-000000000204', 'bc000000-0000-4000-8000-000000000102', 'Other H1', '2027-01-01', '2027-06-30', 99999, true);

INSERT INTO public.vendors (id, organization_id, name, active)
VALUES
  ('bc000000-0000-4000-8000-000000000301', 'bc000000-0000-4000-8000-000000000101', 'Vendor A', true),
  ('bc000000-0000-4000-8000-000000000302', 'bc000000-0000-4000-8000-000000000101', 'Vendor B', true),
  ('bc000000-0000-4000-8000-000000000303', 'bc000000-0000-4000-8000-000000000101', 'Vendor C', true),
  ('bc000000-0000-4000-8000-000000000304', 'bc000000-0000-4000-8000-000000000102', 'Other Vendor', true);

INSERT INTO public.products (id, organization_id, name, approved, active, staff_requestable)
VALUES
  ('bc000000-0000-4000-8000-000000000401', 'bc000000-0000-4000-8000-000000000101', 'Tape', true, true, true),
  ('bc000000-0000-4000-8000-000000000402', 'bc000000-0000-4000-8000-000000000101', 'Gauze', true, true, true),
  ('bc000000-0000-4000-8000-000000000403', 'bc000000-0000-4000-8000-000000000101', 'Wrap', true, true, true),
  ('bc000000-0000-4000-8000-000000000404', 'bc000000-0000-4000-8000-000000000101', 'Ice', true, true, true),
  ('bc000000-0000-4000-8000-000000000405', 'bc000000-0000-4000-8000-000000000102', 'Other Tape', true, true, true);

-- Spend fixtures. Totals use the canonical resolution: explicit total, else line items.
INSERT INTO public.invoices (id, organization_id, vendor_id, vendor_name, invoice_number, invoice_date, currency_code, processing_status, posted_at, invoice_total)
VALUES
  ('bc000000-0000-4000-8000-000000000501', 'bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000301', 'Vendor A', 'H1-200', '2027-02-01', 'USD', 'completed', '2027-02-02 12:00+00', 200),
  ('bc000000-0000-4000-8000-000000000502', 'bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000301', 'Vendor A', 'H1-ITEMS', '2027-03-01', 'USD', 'completed', '2027-03-02 12:00+00', NULL),
  ('bc000000-0000-4000-8000-000000000503', 'bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000302', 'Vendor B', 'H2-100', '2027-08-01', 'USD', 'completed', '2027-08-02 12:00+00', 100),
  ('bc000000-0000-4000-8000-000000000504', 'bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000301', 'Vendor A', 'UNPOSTED', '2027-02-02', 'USD', 'review_required', NULL, 999),
  ('bc000000-0000-4000-8000-000000000505', 'bc000000-0000-4000-8000-000000000102', 'bc000000-0000-4000-8000-000000000304', 'Other Vendor', 'OTHER', '2027-02-01', 'USD', 'completed', '2027-02-02 12:00+00', 5000);
INSERT INTO public.invoice_items (id, invoice_id, organization_id, description, quantity, unit_price, total_price)
VALUES
  ('bc000000-0000-4000-8000-000000000511', 'bc000000-0000-4000-8000-000000000502', 'bc000000-0000-4000-8000-000000000101', 'Line one', 1, 30, 30),
  ('bc000000-0000-4000-8000-000000000512', 'bc000000-0000-4000-8000-000000000502', 'bc000000-0000-4000-8000-000000000101', 'Line two', 2, 10, 20);

-- Request and commitment fixtures.
INSERT INTO public.supply_requests (id, organization_id, requested_by, request_type, quantity, notes, status)
VALUES
  ('bc000000-0000-4000-8000-000000000601', 'bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000003', 'reorder', 1, 'approved active', 'approved'),
  ('bc000000-0000-4000-8000-000000000602', 'bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000003', 'reorder', 1, 'completed still committed', 'completed'),
  ('bc000000-0000-4000-8000-000000000603', 'bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000003', 'reorder', 1, 'completed and settled', 'completed'),
  ('bc000000-0000-4000-8000-000000000604', 'bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000003', 'reorder', 1, 'submitted', 'submitted'),
  ('bc000000-0000-4000-8000-000000000605', 'bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000003', 'reorder', 1, 'under review', 'under_review'),
  ('bc000000-0000-4000-8000-000000000606', 'bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000003', 'reorder', 1, 'H2 partial', 'ordered'),
  ('bc000000-0000-4000-8000-000000000607', 'bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000003', 'reorder', 1, 'denied', 'denied'),
  ('bc000000-0000-4000-8000-000000000610', 'bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000003', 'reorder', 1, 'H2 received still committed', 'received'),
  ('bc000000-0000-4000-8000-000000000608', 'bc000000-0000-4000-8000-000000000102', 'bc000000-0000-4000-8000-000000000004', 'reorder', 1, 'other submitted', 'submitted'),
  ('bc000000-0000-4000-8000-000000000609', 'bc000000-0000-4000-8000-000000000102', 'bc000000-0000-4000-8000-000000000004', 'reorder', 1, 'other received', 'received');
INSERT INTO public.supply_request_commitments (
  id, organization_id, supply_request_id, amount, total_item_count, priced_item_count,
  pricing_status, status, committed_at, released_at, release_kind, release_reason
)
VALUES
  ('bc000000-0000-4000-8000-000000000701', 'bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000601', 30, 1, 1, 'fully_priced', 'active', '2027-02-10 12:00+00', NULL, NULL, NULL),
  ('bc000000-0000-4000-8000-000000000702', 'bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000602', 40, 1, 1, 'fully_priced', 'active', '2027-03-01 12:00+00', NULL, NULL, NULL),
  -- Settled: its dollars now live in posted spend and must not also count as committed.
  ('bc000000-0000-4000-8000-000000000703', 'bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000603', 25, 1, 1, 'fully_priced', 'released', '2027-02-15 12:00+00', '2027-03-05 12:00+00', 'settled', 'Invoiced on H1-200'),
  ('bc000000-0000-4000-8000-000000000704', 'bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000606', 10, 2, 1, 'partially_priced', 'active', '2027-08-05 12:00+00', NULL, NULL, NULL),
  ('bc000000-0000-4000-8000-000000000706', 'bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000610', 15, 1, 1, 'fully_priced', 'active', '2027-09-01 12:00+00', NULL, NULL, NULL),
  ('bc000000-0000-4000-8000-000000000705', 'bc000000-0000-4000-8000-000000000102', 'bc000000-0000-4000-8000-000000000609', 777, 1, 1, 'fully_priced', 'active', '2027-02-10 12:00+00', NULL, NULL, NULL);

-- Invoice review queue: one job awaiting review per org, plus one completed job.
INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type)
VALUES
  ('bc000000-0000-4000-8000-000000000801', 'bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000001', 'bc/review.pdf', 'review.pdf', 10, 'application/pdf'),
  ('bc000000-0000-4000-8000-000000000802', 'bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000001', 'bc/done.pdf', 'done.pdf', 10, 'application/pdf'),
  ('bc000000-0000-4000-8000-000000000803', 'bc000000-0000-4000-8000-000000000102', 'bc000000-0000-4000-8000-000000000004', 'bc/other.pdf', 'other.pdf', 10, 'application/pdf');
UPDATE public.invoice_processing_jobs SET status = 'review_required'
WHERE invoice_id IN ('bc000000-0000-4000-8000-000000000801', 'bc000000-0000-4000-8000-000000000803');
UPDATE public.invoice_processing_jobs SET status = 'completed'
WHERE invoice_id = 'bc000000-0000-4000-8000-000000000802';

-- Price observations. Each needs its own invoice and line (invoice_item_id is unique).
CREATE FUNCTION pg_temp.observe(
  _org uuid, _product uuid, _vendor uuid, _date date, _price numeric,
  _uom text, _package text, _currency text DEFAULT 'USD', _posted boolean DEFAULT true
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE _invoice uuid := gen_random_uuid(); _item uuid := gen_random_uuid();
BEGIN
  INSERT INTO public.invoices (id, organization_id, vendor_id, invoice_number, invoice_date,
    currency_code, processing_status, posted_at, invoice_total)
  VALUES (_invoice, _org, _vendor, 'PI-' || _date, _date, _currency,
    CASE WHEN _posted THEN 'completed' ELSE 'review_required' END,
    CASE WHEN _posted THEN _date::timestamptz + interval '12 hours' END, 0);
  INSERT INTO public.invoice_items (id, invoice_id, organization_id, description, quantity, unit_price, total_price)
  VALUES (_item, _invoice, _org, 'observation', 1, _price, _price);
  INSERT INTO public.inventory_price_history (organization_id, product_id, vendor_id, invoice_id,
    invoice_item_id, purchase_date, quantity, package_size, unit_of_measure, unit_price, extended_price)
  VALUES (_org, _product, _vendor, _invoice, _item, _date, 1, _package, _uom, _price, _price);
END $$;

-- Price fixtures live in 2026 so they never touch the 2027 budget periods above.
DO $seed_prices$
DECLARE
  _a constant uuid := 'bc000000-0000-4000-8000-000000000101';
  _b constant uuid := 'bc000000-0000-4000-8000-000000000102';
  _va constant uuid := 'bc000000-0000-4000-8000-000000000301';
  _vb constant uuid := 'bc000000-0000-4000-8000-000000000302';
  _vc constant uuid := 'bc000000-0000-4000-8000-000000000303';
  _tape constant uuid := 'bc000000-0000-4000-8000-000000000401';
  _gauze constant uuid := 'bc000000-0000-4000-8000-000000000402';
  _wrap constant uuid := 'bc000000-0000-4000-8000-000000000403';
  _ice constant uuid := 'bc000000-0000-4000-8000-000000000404';
BEGIN
  -- Tape: Vendor A case of 12 history; a same-vendor "each" purchase in between must not
  -- become the previous price; Vendor B sells the same case (formatting differs);
  -- Vendor C is cheaper but for a different package and must be ignored.
  PERFORM pg_temp.observe(_a, _tape, _va, '2026-01-10', 100, 'case', 'case of 12');
  PERFORM pg_temp.observe(_a, _tape, _va, '2026-03-01', 104, 'case', 'case of 12');
  PERFORM pg_temp.observe(_a, _tape, _va, '2026-04-20', 9, 'each', NULL);
  PERFORM pg_temp.observe(_a, _tape, _vb, '2026-02-01', 110, 'Case', 'Case of 12');
  PERFORM pg_temp.observe(_a, _tape, _vb, '2026-04-01', 106.20, ' CASE ', 'case  of 12');
  PERFORM pg_temp.observe(_a, _tape, _vc, '2026-04-15', 90, 'case', 'case of 24');
  PERFORM pg_temp.observe(_a, _tape, _va, '2026-05-01', 118, 'case', 'case of 12');
  -- Non-authoritative observations newer than everything else must be ignored.
  PERFORM pg_temp.observe(_a, _tape, _vb, '2026-06-01', 1, 'case', 'case of 12', 'USD', false);
  PERFORM pg_temp.observe(_a, _tape, _vb, '2026-06-02', 2, 'case', 'case of 12', 'EUR', true);
  -- Gauze: same-vendor decrease with no recorded package; another vendor's unpackaged
  -- price cannot be a comparable alternative.
  PERFORM pg_temp.observe(_a, _gauze, _va, '2026-02-01', 25, 'box', NULL);
  PERFORM pg_temp.observe(_a, _gauze, _vb, '2026-03-15', 15, 'box', NULL);
  PERFORM pg_temp.observe(_a, _gauze, _va, '2026-04-01', 20, 'box', NULL);
  -- Wrap: no unit of measure recorded, so nothing is compared.
  PERFORM pg_temp.observe(_a, _wrap, _va, '2026-01-05', 4, NULL, NULL);
  PERFORM pg_temp.observe(_a, _wrap, _va, '2026-04-05', 5, NULL, NULL);
  -- Ice: a comparable alternative exists but is more expensive.
  PERFORM pg_temp.observe(_a, _ice, _vb, '2026-03-01', 12, 'each', 'each');
  PERFORM pg_temp.observe(_a, _ice, _va, '2026-04-01', 10, 'each', 'each');
  -- Other organization: a much cheaper price that must never reach organization A.
  PERFORM pg_temp.observe(_b, 'bc000000-0000-4000-8000-000000000405',
    'bc000000-0000-4000-8000-000000000304', '2026-05-02', 0.01, 'case', 'case of 12');
END
$seed_prices$;

-- Snapshot commitment state so the suite can prove that viewing the dashboard changes nothing.
CREATE TEMP TABLE commitment_state_before AS
SELECT id, status, released_at, amount FROM public.supply_request_commitments
WHERE organization_id IN ('bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000102');
GRANT SELECT ON commitment_state_before TO authenticated;

GRANT EXECUTE ON FUNCTION pg_temp.observe(uuid, uuid, uuid, date, numeric, text, text, text, boolean) TO authenticated;

SET LOCAL ROLE authenticated;

-- Owner: financial summary, attention, recent purchases.
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'bc000000-0000-4000-8000-000000000001', true);
DO $owner_overview$
DECLARE
  _result jsonb := public.get_budget_purchasing_overview('bc000000-0000-4000-8000-000000000101');
  _h1 jsonb;
  _h2 jsonb;
  _canonical record;
BEGIN
  IF jsonb_array_length(_result -> 'budgets') <> 2 THEN
    RAISE EXCEPTION 'Only active budgets of this organization are listed: %', _result -> 'budgets';
  END IF;
  SELECT value INTO _h1 FROM jsonb_array_elements(_result -> 'budgets') WHERE value ->> 'budgetName' = 'H1 2027';
  SELECT value INTO _h2 FROM jsonb_array_elements(_result -> 'budgets') WHERE value ->> 'budgetName' = 'H2 2027';

  -- Spent: 200 explicit + 50 from lines; unposted 999 and other-org 5000 excluded.
  -- Committed: 30 + 40 active; settled 25 excluded (no double count with spend).
  IF (_h1 ->> 'budgetAmount')::numeric <> 1000
     OR (_h1 ->> 'actualSpend')::numeric <> 250
     OR (_h1 ->> 'committedSpend')::numeric <> 70
     OR (_h1 ->> 'availableAmount')::numeric <> 680
     OR (_h1 ->> 'postedInvoiceCount')::integer <> 2
     OR (_h1 ->> 'activeCommitmentCount')::integer <> 2
     OR (_h1 ->> 'incompleteCommitmentCount')::integer <> 0 THEN
    RAISE EXCEPTION 'H1 budget math is incorrect: %', _h1;
  END IF;
  -- H2 committed: ordered request 10 + received request 15 (still active).
  IF (_h2 ->> 'actualSpend')::numeric <> 100
     OR (_h2 ->> 'committedSpend')::numeric <> 25
     OR (_h2 ->> 'availableAmount')::numeric <> 375
     OR (_h2 ->> 'incompleteCommitmentCount')::integer <> 1 THEN
    RAISE EXCEPTION 'H2 budget math is incorrect: %', _h2;
  END IF;

  -- Settlement candidates are a disclosed subset of the canonical committed figure:
  -- H1 holds the completed request (40), H2 the received one (15); the ordered request
  -- and the settled commitment are not candidates. Committed/available stay canonical.
  IF (_h1 ->> 'settlementCandidateCount')::integer <> 1
     OR (_h1 ->> 'settlementCandidateAmount')::numeric <> 40
     OR (_h2 ->> 'settlementCandidateCount')::integer <> 1
     OR (_h2 ->> 'settlementCandidateAmount')::numeric <> 15 THEN
    RAISE EXCEPTION 'Per-budget settlement candidates are incorrect: % %', _h1, _h2;
  END IF;
  IF jsonb_array_length(_result -> 'settlementCandidates') <> 2
     OR _result #>> '{settlementCandidates,0,requestId}' <> 'bc000000-0000-4000-8000-000000000602'
     OR _result #>> '{settlementCandidates,0,requestStatus}' <> 'completed'
     OR (_result #>> '{settlementCandidates,0,amount}')::numeric <> 40
     OR _result #>> '{settlementCandidates,1,requestId}' <> 'bc000000-0000-4000-8000-000000000610'
     OR _result #>> '{settlementCandidates,1,requestStatus}' <> 'received'
     OR (_result ->> 'settlementCandidateLimit')::integer <> 25 THEN
    RAISE EXCEPTION 'Settlement candidate list is incorrect: %', _result -> 'settlementCandidates';
  END IF;

  -- The command center must agree exactly with the canonical per-budget RPC.
  SELECT * INTO _canonical FROM public.get_budget_summary(
    'bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000201');
  IF _canonical.actual_spend <> (_h1 ->> 'actualSpend')::numeric
     OR _canonical.committed_spend <> (_h1 ->> 'committedSpend')::numeric
     OR _canonical.available_amount <> (_h1 ->> 'availableAmount')::numeric THEN
    RAISE EXCEPTION 'Overview diverges from get_budget_summary';
  END IF;

  IF (_result #>> '{attention,awaitingApprovalCount}')::integer <> 2
     OR (_result #>> '{attention,commitmentsToSettleCount}')::integer <> 2
     OR (_result #>> '{attention,commitmentsToSettleAmount}')::numeric <> 55
     OR (_result #>> '{attention,unpricedCommitmentCount}')::integer <> 1
     OR (_result #>> '{attention,invoiceReviewCount}')::integer <> 1 THEN
    RAISE EXCEPTION 'Attention counts are incorrect: %', _result -> 'attention';
  END IF;

  IF (_result ->> 'viewerIsOwner')::boolean IS NOT TRUE
     OR jsonb_array_length(_result -> 'recentPurchases') <> 8
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(_result -> 'recentPurchases') purchase
       WHERE purchase ->> 'invoiceNumber' IN ('UNPOSTED', 'OTHER')) THEN
    RAISE EXCEPTION 'Recent purchases are not bounded/posted-only/org-scoped: %', _result -> 'recentPurchases';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(_result -> 'recentPurchases') purchase
       WHERE purchase ->> 'invoiceNumber' = 'H2-100' AND (purchase ->> 'amount')::numeric = 100) THEN
    RAISE EXCEPTION 'Most recent posted invoice is missing or mis-totalled';
  END IF;
END
$owner_overview$;

-- Owner lineage: lists reconcile to the budget's committed and spent totals.
DO $owner_lineage$
DECLARE
  _lineage jsonb := public.get_budget_lineage(
    'bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000201');
BEGIN
  IF (_lineage ->> 'commitmentTotal')::numeric <> 70
     OR (_lineage ->> 'commitmentCount')::integer <> 2
     OR (_lineage ->> 'postedTotal')::numeric <> 250
     OR (_lineage ->> 'postedInvoiceCount')::integer <> 2
     OR jsonb_array_length(_lineage -> 'commitments') <> 2
     OR jsonb_array_length(_lineage -> 'postedInvoices') <> 2 THEN
    RAISE EXCEPTION 'Budget lineage does not reconcile: %', _lineage;
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(_lineage -> 'commitments') c
       WHERE c ->> 'requestId' = 'bc000000-0000-4000-8000-000000000603') THEN
    RAISE EXCEPTION 'Released commitment appears in lineage';
  END IF;
  IF (_lineage ->> 'settlementCandidateCount')::integer <> 1
     OR (_lineage ->> 'settlementCandidateTotal')::numeric <> 40
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(_lineage -> 'commitments') c
       WHERE c ->> 'requestId' = 'bc000000-0000-4000-8000-000000000602' AND (c ->> 'settlementCandidate')::boolean)
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(_lineage -> 'commitments') c
       WHERE c ->> 'requestId' = 'bc000000-0000-4000-8000-000000000601' AND NOT (c ->> 'settlementCandidate')::boolean) THEN
    RAISE EXCEPTION 'Lineage settlement flags are incorrect: %', _lineage;
  END IF;
END
$owner_lineage$;

-- Admin (not owner): same financial totals, but no invoice-level detail.
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'bc000000-0000-4000-8000-000000000002', true);
DO $admin_overview$
DECLARE
  _result jsonb := public.get_budget_purchasing_overview('bc000000-0000-4000-8000-000000000101');
  _lineage jsonb := public.get_budget_lineage(
    'bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000201');
BEGIN
  IF (_result ->> 'viewerIsOwner')::boolean
     OR _result -> 'recentPurchases' <> 'null'::jsonb
     OR _result #> '{attention,invoiceReviewCount}' <> 'null'::jsonb
     OR (_result #>> '{attention,awaitingApprovalCount}')::integer <> 2
     OR jsonb_array_length(_result -> 'budgets') <> 2 THEN
    RAISE EXCEPTION 'Admin overview visibility is incorrect: %', _result;
  END IF;
  IF _lineage -> 'postedInvoices' <> 'null'::jsonb
     OR _lineage -> 'postedTotal' <> 'null'::jsonb
     OR (_lineage ->> 'commitmentTotal')::numeric <> 70 THEN
    RAISE EXCEPTION 'Admin lineage visibility is incorrect: %', _lineage;
  END IF;
END
$admin_overview$;

-- Price intelligence semantics (admin access, as in Phase 6B).
DO $price_rules$
DECLARE
  _result jsonb := public.get_price_intelligence_overview('bc000000-0000-4000-8000-000000000101');
  _tape jsonb;
  _gauze jsonb;
  _wrap jsonb;
  _ice jsonb;
BEGIN
  IF (_result ->> 'productCount')::integer <> 4 OR jsonb_array_length(_result -> 'rows') <> 4 THEN
    RAISE EXCEPTION 'Price rows are not organization-scoped: %', _result;
  END IF;
  SELECT value INTO _tape FROM jsonb_array_elements(_result -> 'rows') WHERE value ->> 'productName' = 'Tape';
  SELECT value INTO _gauze FROM jsonb_array_elements(_result -> 'rows') WHERE value ->> 'productName' = 'Gauze';
  SELECT value INTO _wrap FROM jsonb_array_elements(_result -> 'rows') WHERE value ->> 'productName' = 'Wrap';
  SELECT value INTO _ice FROM jsonb_array_elements(_result -> 'rows') WHERE value ->> 'productName' = 'Ice';

  -- Latest comparable price ignores unposted and non-USD rows.
  IF (_tape #>> '{current,price}')::numeric <> 118
     OR _tape #>> '{current,vendorName}' <> 'Vendor A'
     OR _tape #>> '{current,purchaseDate}' <> '2026-05-01' THEN
    RAISE EXCEPTION 'Tape current price is incorrect: %', _tape -> 'current';
  END IF;
  -- Previous skips the same vendor's "each" purchase and other vendors.
  IF (_tape #>> '{previous,price}')::numeric <> 104
     OR _tape #>> '{previous,purchaseDate}' <> '2026-03-01'
     OR (_tape ->> 'absoluteChange')::numeric <> 14
     OR round((_tape ->> 'percentChange')::numeric, 4) <> 13.4615 THEN
    RAISE EXCEPTION 'Tape previous price or change is incorrect: %', _tape;
  END IF;
  -- 90-day window ending 2026-05-01 starts 2026-02-01: 104 and 118 only.
  IF (_tape #>> '{recentAverage,average}')::numeric <> 111
     OR (_tape #>> '{recentAverage,observationCount}')::integer <> 2
     OR _tape #>> '{recentAverage,windowStart}' <> '2026-02-01' THEN
    RAISE EXCEPTION 'Tape 90-day average is incorrect: %', _tape -> 'recentAverage';
  END IF;
  -- Best alternative is Vendor B's latest same-package price, not Vendor C's 24-pack,
  -- not the unposted/EUR rows, and never the other organization's 0.01.
  IF _tape #>> '{bestAlternative,vendorName}' <> 'Vendor B'
     OR (_tape #>> '{bestAlternative,price}')::numeric <> 106.20
     OR (_tape #>> '{bestAlternative,comparableVendorCount}')::integer <> 1
     OR (_tape ->> 'unitSavings')::numeric <> 11.80 THEN
    RAISE EXCEPTION 'Tape alternative or savings is incorrect: %', _tape;
  END IF;

  IF (_gauze #>> '{previous,price}')::numeric <> 25
     OR (_gauze ->> 'percentChange')::numeric <> -20
     OR _gauze -> 'bestAlternative' <> 'null'::jsonb
     OR _gauze -> 'unitSavings' <> 'null'::jsonb THEN
    RAISE EXCEPTION 'Gauze decrease or unpackaged alternative handling is incorrect: %', _gauze;
  END IF;

  IF _wrap ->> 'comparability' <> 'missing_unit_of_measure'
     OR _wrap -> 'previous' <> 'null'::jsonb
     OR _wrap -> 'percentChange' <> 'null'::jsonb
     OR _wrap -> 'recentAverage' <> 'null'::jsonb
     OR _wrap -> 'bestAlternative' <> 'null'::jsonb THEN
    RAISE EXCEPTION 'Unit-less observations were compared: %', _wrap;
  END IF;

  IF (_ice #>> '{bestAlternative,price}')::numeric <> 12
     OR _ice -> 'unitSavings' <> 'null'::jsonb
     OR _ice -> 'previous' <> 'null'::jsonb THEN
    RAISE EXCEPTION 'More expensive alternative fabricated savings: %', _ice;
  END IF;
END
$price_rules$;

-- Staff, non-members and other organizations are refused by every function.
DO $refusals$
DECLARE
  _user uuid;
  _call text;
BEGIN
  FOREACH _user IN ARRAY ARRAY[
    'bc000000-0000-4000-8000-000000000003',
    'bc000000-0000-4000-8000-000000000004',
    'bc000000-0000-4000-8000-000000000005'
  ]::uuid[] LOOP
    PERFORM pg_catalog.set_config('request.jwt.claim.sub', _user::text, true);
    FOREACH _call IN ARRAY ARRAY[
      'SELECT public.get_budget_purchasing_overview(''bc000000-0000-4000-8000-000000000101'')',
      'SELECT public.get_budget_lineage(''bc000000-0000-4000-8000-000000000101'', ''bc000000-0000-4000-8000-000000000201'')',
      'SELECT public.get_price_intelligence_overview(''bc000000-0000-4000-8000-000000000101'')'
    ] LOOP
      BEGIN
        EXECUTE _call;
        RAISE EXCEPTION 'Unauthorized call succeeded for %: %', _user, _call;
      EXCEPTION WHEN insufficient_privilege THEN NULL;
      END;
    END LOOP;
  END LOOP;
END
$refusals$;

-- The other organization's owner sees only their own totals and prices; budget IDs of
-- organization A cannot be used through organization B either.
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'bc000000-0000-4000-8000-000000000004', true);
DO $other_org$
DECLARE
  _result jsonb := public.get_budget_purchasing_overview('bc000000-0000-4000-8000-000000000102');
  _prices jsonb := public.get_price_intelligence_overview('bc000000-0000-4000-8000-000000000102');
BEGIN
  IF jsonb_array_length(_result -> 'budgets') <> 1
     OR (_result #>> '{budgets,0,actualSpend}')::numeric <> 5000
     OR (_result #>> '{budgets,0,committedSpend}')::numeric <> 777
     OR (_result #>> '{attention,awaitingApprovalCount}')::integer <> 1
     OR (_result #>> '{attention,invoiceReviewCount}')::integer <> 1
     OR (_result #>> '{attention,commitmentsToSettleCount}')::integer <> 1
     OR (_result #>> '{attention,commitmentsToSettleAmount}')::numeric <> 777
     OR jsonb_array_length(_result -> 'settlementCandidates') <> 1
     OR _result #>> '{settlementCandidates,0,requestId}' <> 'bc000000-0000-4000-8000-000000000609' THEN
    RAISE EXCEPTION 'Other organization overview leaked or mis-scoped: %', _result;
  END IF;
  IF jsonb_array_length(_prices -> 'rows') <> 1
     OR _prices #>> '{rows,0,productName}' <> 'Other Tape'
     OR _prices #> '{rows,0,bestAlternative}' <> 'null'::jsonb THEN
    RAISE EXCEPTION 'Other organization prices leaked or mis-scoped: %', _prices;
  END IF;
  BEGIN
    PERFORM public.get_budget_lineage(
      'bc000000-0000-4000-8000-000000000102', 'bc000000-0000-4000-8000-000000000201');
    RAISE EXCEPTION 'Cross-organization budget lineage succeeded';
  EXCEPTION WHEN no_data_found THEN NULL;
  END;
END
$other_org$;

-- An organization with no budgets and no purchases returns empty, not zero-filled, data.
RESET ROLE;
INSERT INTO public.organizations (id, name, created_by)
VALUES ('bc000000-0000-4000-8000-000000000103', 'Empty Org', 'bc000000-0000-4000-8000-000000000005');
INSERT INTO public.organization_memberships (id, organization_id, user_id, role, active)
VALUES ('bc000000-0000-4000-8000-000000000115', 'bc000000-0000-4000-8000-000000000103', 'bc000000-0000-4000-8000-000000000005', 'owner', true);
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', 'bc000000-0000-4000-8000-000000000005', true);
DO $empty_org$
DECLARE
  _result jsonb := public.get_budget_purchasing_overview('bc000000-0000-4000-8000-000000000103');
  _prices jsonb := public.get_price_intelligence_overview('bc000000-0000-4000-8000-000000000103');
BEGIN
  IF _result -> 'budgets' <> '[]'::jsonb OR _result -> 'recentPurchases' <> '[]'::jsonb
     OR _result -> 'settlementCandidates' <> '[]'::jsonb
     OR _prices -> 'rows' <> '[]'::jsonb OR (_prices ->> 'productCount')::integer <> 0 THEN
    RAISE EXCEPTION 'Empty organization state is incorrect: % %', _result, _prices;
  END IF;
END
$empty_org$;

-- Viewing the dashboard (every call above, as every role) released or altered nothing.
RESET ROLE;
DO $no_mutation$
BEGIN
  IF EXISTS (
    SELECT 1 FROM commitment_state_before before
    FULL JOIN public.supply_request_commitments now ON now.id = before.id
    WHERE (before.id IS NULL AND now.organization_id IN ('bc000000-0000-4000-8000-000000000101', 'bc000000-0000-4000-8000-000000000102'))
       OR (before.id IS NOT NULL AND (now.id IS NULL OR now.status IS DISTINCT FROM before.status
         OR now.released_at IS DISTINCT FROM before.released_at OR now.amount IS DISTINCT FROM before.amount))
  ) THEN
    RAISE EXCEPTION 'Viewing the dashboard changed commitment state';
  END IF;
END
$no_mutation$;

-- The functions are read-only: STABLE, and not executable by anon.
DO $grants$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc
    WHERE proname IN ('get_budget_purchasing_overview', 'get_budget_lineage', 'get_price_intelligence_overview')
      AND (provolatile <> 's' OR NOT prosecdef
        OR has_function_privilege('anon', oid, 'EXECUTE'))
  ) THEN
    RAISE EXCEPTION 'Command center functions must be STABLE security-definer and not anon-executable';
  END IF;
END
$grants$;

ROLLBACK;
