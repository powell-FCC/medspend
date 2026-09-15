-- Phase 6A.2 rollback-only behavioral verification.
-- Run after 20260914120000_phase6a2_request_commitments.sql. All data rolls back.

BEGIN;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
VALUES
  ('6a2a0000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'phase6a2-admin@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('6a2a0000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'phase6a2-staff@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('6a2a0000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'phase6a2-other-admin@example.invalid', '', now(), '{}', '{}', now(), now());

INSERT INTO public.organizations (id, name, created_by)
VALUES
  ('6a2a0000-0000-4000-8000-000000000101', 'Phase 6A.2 Organization', '6a2a0000-0000-4000-8000-000000000001'),
  ('6a2a0000-0000-4000-8000-000000000102', 'Phase 6A.2 Other Organization', '6a2a0000-0000-4000-8000-000000000003');

INSERT INTO public.organization_memberships (id, organization_id, user_id, role, active)
VALUES
  ('6a2a0000-0000-4000-8000-000000000111', '6a2a0000-0000-4000-8000-000000000101', '6a2a0000-0000-4000-8000-000000000001', 'admin', true),
  ('6a2a0000-0000-4000-8000-000000000112', '6a2a0000-0000-4000-8000-000000000101', '6a2a0000-0000-4000-8000-000000000002', 'staff', true),
  ('6a2a0000-0000-4000-8000-000000000113', '6a2a0000-0000-4000-8000-000000000102', '6a2a0000-0000-4000-8000-000000000003', 'admin', true);

INSERT INTO public.catalog_vendors (id, name, normalized_name, active)
VALUES ('6a2a0000-0000-4000-8000-000000000201', 'Phase 6A.2 Vendor', 'phase 6a 2 vendor', true);
INSERT INTO public.catalog_products (id, name, normalized_name, active, verification_status)
VALUES ('6a2a0000-0000-4000-8000-000000000301', 'Phase 6A.2 Tape', 'phase 6a 2 tape', true, 'verified');
INSERT INTO public.catalog_vendor_products (
  id, catalog_product_id, catalog_vendor_id, vendor_sku, normalized_vendor_sku,
  source_catalog_price, currency_code, active, discontinued, verification_status
)
VALUES ('6a2a0000-0000-4000-8000-000000000401', '6a2a0000-0000-4000-8000-000000000301',
  '6a2a0000-0000-4000-8000-000000000201', '6A2-TAPE', '6A2-TAPE', 100, 'USD', true, false, 'verified');

INSERT INTO public.organization_budgets (
  id, organization_id, name, period_start, period_end, amount, active
)
VALUES ('6a2a0000-0000-4000-8000-000000000501', '6a2a0000-0000-4000-8000-000000000101',
  'Current operating budget', current_date - 30, current_date + 30, 1000, true);

-- Actual spend fixture. It intentionally has no request relationship.
INSERT INTO public.invoices (
  id, organization_id, invoice_number, invoice_date, invoice_total, posted_at
)
VALUES ('6a2a0000-0000-4000-8000-000000000601', '6a2a0000-0000-4000-8000-000000000101',
  '6A2-ACTUAL', current_date, 300, now());

INSERT INTO public.supply_requests (
  id, organization_id, requested_by, request_type, quantity, notes, status
)
VALUES
  ('6a2a0000-0000-4000-8000-000000000701', '6a2a0000-0000-4000-8000-000000000101', '6a2a0000-0000-4000-8000-000000000002', 'reorder', 2, 'Priced request', 'submitted'),
  ('6a2a0000-0000-4000-8000-000000000702', '6a2a0000-0000-4000-8000-000000000101', '6a2a0000-0000-4000-8000-000000000002', 'reorder', 1, 'Partial request', 'submitted'),
  ('6a2a0000-0000-4000-8000-000000000703', '6a2a0000-0000-4000-8000-000000000101', '6a2a0000-0000-4000-8000-000000000002', 'new_item', 1, 'Unpriced request', 'submitted'),
  ('6a2a0000-0000-4000-8000-000000000704', '6a2a0000-0000-4000-8000-000000000101', '6a2a0000-0000-4000-8000-000000000002', 'new_item', 1, 'Denied request', 'submitted');

INSERT INTO public.supply_request_items (
  id, organization_id, supply_request_id, catalog_vendor_product_id,
  free_text_item, quantity
)
VALUES
  ('6a2a0000-0000-4000-8000-000000000801', '6a2a0000-0000-4000-8000-000000000101', '6a2a0000-0000-4000-8000-000000000701', '6a2a0000-0000-4000-8000-000000000401', NULL, 2),
  ('6a2a0000-0000-4000-8000-000000000802', '6a2a0000-0000-4000-8000-000000000101', '6a2a0000-0000-4000-8000-000000000702', '6a2a0000-0000-4000-8000-000000000401', NULL, 1),
  ('6a2a0000-0000-4000-8000-000000000803', '6a2a0000-0000-4000-8000-000000000101', '6a2a0000-0000-4000-8000-000000000702', NULL, 'Custom partial line', 1),
  ('6a2a0000-0000-4000-8000-000000000804', '6a2a0000-0000-4000-8000-000000000101', '6a2a0000-0000-4000-8000-000000000703', NULL, 'Custom unpriced line', 1),
  ('6a2a0000-0000-4000-8000-000000000805', '6a2a0000-0000-4000-8000-000000000101', '6a2a0000-0000-4000-8000-000000000704', NULL, 'Custom denied line', 1);

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6a2a0000-0000-4000-8000-000000000001', true);

-- Approval preview includes actuals, current commitments, available, and projection.
DO $phase6a2_preview$
DECLARE _impact record;
BEGIN
  SELECT * INTO _impact FROM public.get_supply_request_budget_impact(
    '6a2a0000-0000-4000-8000-000000000101',
    '6a2a0000-0000-4000-8000-000000000701'
  );
  IF _impact.estimated_amount <> 200 OR _impact.pricing_status <> 'fully_priced'
     OR _impact.actual_spend <> 300 OR _impact.committed_spend <> 0
     OR _impact.available_amount <> 700
     OR _impact.projected_available_after_approval <> 500 THEN
    RAISE EXCEPTION 'Incorrect approval preview: %', row_to_json(_impact);
  END IF;
END
$phase6a2_preview$;

-- Approval creates exactly one immutable item-level snapshot.
SELECT public.decide_supply_request(
  '6a2a0000-0000-4000-8000-000000000101',
  '6a2a0000-0000-4000-8000-000000000701', 'approved'
);
DO $phase6a2_approval$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.supply_request_commitments commitment
    WHERE commitment.supply_request_id = '6a2a0000-0000-4000-8000-000000000701'
      AND commitment.status = 'active' AND commitment.amount = 200
      AND commitment.pricing_status = 'fully_priced'
      AND commitment.total_item_count = 1 AND commitment.priced_item_count = 1
  ) OR NOT EXISTS (
    SELECT 1 FROM public.supply_request_commitment_items item
    JOIN public.supply_request_commitments commitment ON commitment.id = item.commitment_id
    WHERE commitment.supply_request_id = '6a2a0000-0000-4000-8000-000000000701'
      AND item.quantity_snapshot = 2 AND item.unit_cost_snapshot = 100
      AND item.line_amount_snapshot = 200 AND item.price_source = 'catalog_source_price'
  ) THEN RAISE EXCEPTION 'Approval snapshot is incorrect'; END IF;
END
$phase6a2_approval$;

-- Same-decision retry cannot duplicate parent, items, or lifecycle audit rows.
SELECT public.decide_supply_request(
  '6a2a0000-0000-4000-8000-000000000101',
  '6a2a0000-0000-4000-8000-000000000701', 'approved'
);
DO $phase6a2_retry$
BEGIN
  IF (SELECT count(*) FROM public.supply_request_commitments WHERE supply_request_id = '6a2a0000-0000-4000-8000-000000000701') <> 1
     OR (SELECT count(*) FROM public.supply_request_commitment_items item JOIN public.supply_request_commitments commitment ON commitment.id = item.commitment_id WHERE commitment.supply_request_id = '6a2a0000-0000-4000-8000-000000000701') <> 1 THEN
    RAISE EXCEPTION 'Repeated approval duplicated commitment data';
  END IF;
END
$phase6a2_retry$;

-- Mutable catalog price changes do not affect the captured commitment.
RESET ROLE;
UPDATE public.catalog_vendor_products SET source_catalog_price = 999
WHERE id = '6a2a0000-0000-4000-8000-000000000401';

-- Exercise the immutable trigger as the database owner. Authenticated users are
-- separately protected by RLS and therefore may match zero rows on direct UPDATE.
DO $phase6a2_immutable_trigger$
BEGIN
  IF (SELECT amount FROM public.supply_request_commitments WHERE supply_request_id = '6a2a0000-0000-4000-8000-000000000701') <> 200 THEN
    RAISE EXCEPTION 'Mutable catalog price changed the commitment';
  END IF;
  BEGIN
    UPDATE public.supply_request_commitments SET amount = 999
    WHERE supply_request_id = '6a2a0000-0000-4000-8000-000000000701';
    RAISE EXCEPTION 'Immutable parent update unexpectedly succeeded';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'Committed financial snapshots are immutable' THEN RAISE; END IF;
  END;
END
$phase6a2_immutable_trigger$;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6a2a0000-0000-4000-8000-000000000001', true);

-- Ordered, received, and completed keep the commitment active.
SELECT public.transition_supply_request('6a2a0000-0000-4000-8000-000000000101', '6a2a0000-0000-4000-8000-000000000701', 'ordered');
SELECT public.transition_supply_request('6a2a0000-0000-4000-8000-000000000101', '6a2a0000-0000-4000-8000-000000000701', 'received');
SELECT public.transition_supply_request('6a2a0000-0000-4000-8000-000000000101', '6a2a0000-0000-4000-8000-000000000701', 'completed');
DO $phase6a2_completed_active$
BEGIN
  IF (SELECT status FROM public.supply_request_commitments WHERE supply_request_id = '6a2a0000-0000-4000-8000-000000000701') <> 'active' THEN
    RAISE EXCEPTION 'Received/completed silently released commitment';
  END IF;
END
$phase6a2_completed_active$;

-- Explicit release is audited and retry-safe.
SELECT public.release_supply_request_commitment(
  '6a2a0000-0000-4000-8000-000000000101',
  '6a2a0000-0000-4000-8000-000000000701', 'settled', 'Invoice 6A2-ACTUAL is posted'
);
SELECT public.release_supply_request_commitment(
  '6a2a0000-0000-4000-8000-000000000101',
  '6a2a0000-0000-4000-8000-000000000701', 'settled', 'Retry'
);
DO $phase6a2_release$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.supply_request_commitments
    WHERE supply_request_id = '6a2a0000-0000-4000-8000-000000000701'
      AND status = 'released' AND release_kind = 'settled'
      AND release_reason = 'Invoice 6A2-ACTUAL is posted'
      AND released_at IS NOT NULL AND released_by = '6a2a0000-0000-4000-8000-000000000001'
  ) THEN RAISE EXCEPTION 'Release audit or retry behavior is incorrect'; END IF;
END
$phase6a2_release$;

-- Partial and unpriced requests preserve missing-cost state.
SELECT public.decide_supply_request('6a2a0000-0000-4000-8000-000000000101', '6a2a0000-0000-4000-8000-000000000702', 'approved');
SELECT public.decide_supply_request('6a2a0000-0000-4000-8000-000000000101', '6a2a0000-0000-4000-8000-000000000703', 'approved');
DO $phase6a2_incomplete$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.supply_request_commitments
    WHERE supply_request_id = '6a2a0000-0000-4000-8000-000000000702'
      AND pricing_status = 'partially_priced' AND amount = 999
      AND priced_item_count = 1 AND total_item_count = 2
  ) OR NOT EXISTS (
    SELECT 1 FROM public.supply_request_commitments
    WHERE supply_request_id = '6a2a0000-0000-4000-8000-000000000703'
      AND pricing_status = 'unpriced' AND amount = 0
      AND priced_item_count = 0 AND total_item_count = 1
  ) THEN RAISE EXCEPTION 'Partial or unpriced commitment is incorrect'; END IF;
END
$phase6a2_incomplete$;

-- Denied-before-approval does not commit; denied-after-approval releases.
SELECT public.decide_supply_request('6a2a0000-0000-4000-8000-000000000101', '6a2a0000-0000-4000-8000-000000000704', 'denied', 'Not needed');
SELECT public.transition_supply_request('6a2a0000-0000-4000-8000-000000000101', '6a2a0000-0000-4000-8000-000000000702', 'denied');
DO $phase6a2_denial$
BEGIN
  IF EXISTS (SELECT 1 FROM public.supply_request_commitments WHERE supply_request_id = '6a2a0000-0000-4000-8000-000000000704')
     OR NOT EXISTS (SELECT 1 FROM public.supply_request_commitments WHERE supply_request_id = '6a2a0000-0000-4000-8000-000000000702' AND status = 'released' AND release_kind = 'denied') THEN
    RAISE EXCEPTION 'Denial commitment behavior is incorrect';
  END IF;
END
$phase6a2_denial$;

-- Budget summary keeps actual math and counts only active known commitment values.
DO $phase6a2_budget$
DECLARE _summary record;
BEGIN
  SELECT * INTO _summary FROM public.get_budget_summary(
    '6a2a0000-0000-4000-8000-000000000101',
    '6a2a0000-0000-4000-8000-000000000501'
  );
  IF _summary.actual_spend <> 300 OR _summary.committed_spend <> 0
     OR _summary.available_amount <> 700 OR _summary.remaining_amount <> 700
     OR _summary.posted_invoice_count <> 1 OR _summary.active_commitment_count <> 1
     OR _summary.incomplete_commitment_count <> 1 THEN
    RAISE EXCEPTION 'Budget summary is incorrect: %', row_to_json(_summary);
  END IF;
END
$phase6a2_budget$;

-- Staff and cross-organization admins cannot read or manipulate commitment state.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6a2a0000-0000-4000-8000-000000000002', true);
DO $phase6a2_staff_isolation$
BEGIN
  IF EXISTS (SELECT 1 FROM public.supply_request_commitments) THEN
    RAISE EXCEPTION 'Staff can read admin commitment records';
  END IF;
  BEGIN
    PERFORM public.release_supply_request_commitment(
      '6a2a0000-0000-4000-8000-000000000101',
      '6a2a0000-0000-4000-8000-000000000703', 'other', 'Unauthorized'
    );
    RAISE EXCEPTION 'Staff release unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END
$phase6a2_staff_isolation$;

SELECT pg_catalog.set_config('request.jwt.claim.sub', '6a2a0000-0000-4000-8000-000000000003', true);
DO $phase6a2_org_isolation$
BEGIN
  BEGIN
    PERFORM * FROM public.get_supply_request_budget_impact(
      '6a2a0000-0000-4000-8000-000000000101',
      '6a2a0000-0000-4000-8000-000000000703'
    );
    RAISE EXCEPTION 'Cross-organization budget impact unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END
$phase6a2_org_isolation$;

RESET ROLE;

SELECT 15 AS checks_passed, 0 AS checks_failed;

ROLLBACK;
