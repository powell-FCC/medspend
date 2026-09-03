-- Phase 5A.9 rollback-only behavioral verification.
-- Run after deploying 20260903140000_phase5a9_admin_request_decisions.sql.
-- Every fixture and mutation in this file is rolled back.

BEGIN;

DO $phase5a9_fixture_guard$
BEGIN
  IF EXISTS (
    SELECT 1 FROM auth.users
    WHERE id BETWEEN
      '5a9a0000-0000-4000-8000-000000000001'::uuid AND
      '5a9a0000-0000-4000-8000-000000000005'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.organizations
    WHERE id BETWEEN
      '5a9a0000-0000-4000-8000-000000000101'::uuid AND
      '5a9a0000-0000-4000-8000-000000000102'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.supply_requests
    WHERE id BETWEEN
      '5a9a0000-0000-4000-8000-000000000901'::uuid AND
      '5a9a0000-0000-4000-8000-000000000904'::uuid
  ) THEN
    RAISE EXCEPTION 'Phase 5A.9 rollback-test fixture IDs already exist';
  END IF;
END
$phase5a9_fixture_guard$;

CREATE TEMP TABLE phase5a9_checks (
  name text PRIMARY KEY
);
GRANT SELECT, INSERT ON phase5a9_checks TO authenticated;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
VALUES
  ('5a9a0000-0000-4000-8000-000000000001', 'authenticated', 'authenticated',
   'phase5a9-owner@example.invalid', '', now(), '{}', '{"full_name":"Phase 5A.9 Owner"}', now(), now()),
  ('5a9a0000-0000-4000-8000-000000000002', 'authenticated', 'authenticated',
   'phase5a9-admin@example.invalid', '', now(), '{}', '{"full_name":"Phase 5A.9 Admin"}', now(), now()),
  ('5a9a0000-0000-4000-8000-000000000003', 'authenticated', 'authenticated',
   'phase5a9-staff@example.invalid', '', now(), '{}', '{"full_name":"Phase 5A.9 Staff"}', now(), now()),
  ('5a9a0000-0000-4000-8000-000000000004', 'authenticated', 'authenticated',
   'phase5a9-other-owner@example.invalid', '', now(), '{}', '{"full_name":"Phase 5A.9 Other Owner"}', now(), now()),
  ('5a9a0000-0000-4000-8000-000000000005', 'authenticated', 'authenticated',
   'phase5a9-other-staff@example.invalid', '', now(), '{}', '{"full_name":"Phase 5A.9 Other Staff"}', now(), now());

INSERT INTO public.organizations (id, name, created_by)
VALUES
  ('5a9a0000-0000-4000-8000-000000000101', 'Phase 5A.9 Request Organization', '5a9a0000-0000-4000-8000-000000000001'),
  ('5a9a0000-0000-4000-8000-000000000102', 'Phase 5A.9 Other Organization', '5a9a0000-0000-4000-8000-000000000004');

INSERT INTO public.teams (id, organization_id, name, active)
VALUES
  ('5a9a0000-0000-4000-8000-000000000111', '5a9a0000-0000-4000-8000-000000000101', 'Phase 5A.9 Team', true),
  ('5a9a0000-0000-4000-8000-000000000112', '5a9a0000-0000-4000-8000-000000000102', 'Phase 5A.9 Other Team', true);

INSERT INTO public.locations (id, organization_id, name, active)
VALUES
  ('5a9a0000-0000-4000-8000-000000000121', '5a9a0000-0000-4000-8000-000000000101', 'Phase 5A.9 Location', true),
  ('5a9a0000-0000-4000-8000-000000000122', '5a9a0000-0000-4000-8000-000000000102', 'Phase 5A.9 Other Location', true);

INSERT INTO public.organization_memberships (
  id, organization_id, user_id, role, active, default_team_id, default_location_id
)
VALUES
  ('5a9a0000-0000-4000-8000-000000000131', '5a9a0000-0000-4000-8000-000000000101', '5a9a0000-0000-4000-8000-000000000001', 'owner', true, '5a9a0000-0000-4000-8000-000000000111', '5a9a0000-0000-4000-8000-000000000121'),
  ('5a9a0000-0000-4000-8000-000000000132', '5a9a0000-0000-4000-8000-000000000101', '5a9a0000-0000-4000-8000-000000000002', 'admin', true, '5a9a0000-0000-4000-8000-000000000111', '5a9a0000-0000-4000-8000-000000000121'),
  ('5a9a0000-0000-4000-8000-000000000133', '5a9a0000-0000-4000-8000-000000000101', '5a9a0000-0000-4000-8000-000000000003', 'staff', true, '5a9a0000-0000-4000-8000-000000000111', '5a9a0000-0000-4000-8000-000000000121'),
  ('5a9a0000-0000-4000-8000-000000000134', '5a9a0000-0000-4000-8000-000000000102', '5a9a0000-0000-4000-8000-000000000004', 'owner', true, '5a9a0000-0000-4000-8000-000000000112', '5a9a0000-0000-4000-8000-000000000122'),
  ('5a9a0000-0000-4000-8000-000000000135', '5a9a0000-0000-4000-8000-000000000101', '5a9a0000-0000-4000-8000-000000000005', 'staff', true, '5a9a0000-0000-4000-8000-000000000111', '5a9a0000-0000-4000-8000-000000000121');

-- One proven identity chain exercises all four request-line identity columns.
INSERT INTO public.catalog_vendors (id, name, normalized_name, active)
VALUES ('5a9a0000-0000-4000-8000-000000000201', 'Phase 5A.9 Global Vendor', 'phase 5a 9 global vendor', true);
INSERT INTO public.catalog_products (
  id, name, normalized_name, manufacturer, active, verification_status
)
VALUES ('5a9a0000-0000-4000-8000-000000000301', 'Phase 5A.9 Structured Tape', 'phase 5a 9 structured tape', 'Fixture Maker', true, 'verified');
INSERT INTO public.catalog_vendor_products (
  id, catalog_product_id, catalog_vendor_id, vendor_sku, normalized_vendor_sku,
  package_quantity, package_unit, package_status, active, discontinued, verification_status
)
VALUES ('5a9a0000-0000-4000-8000-000000000401', '5a9a0000-0000-4000-8000-000000000301',
  '5a9a0000-0000-4000-8000-000000000201', 'P5A9-TAPE', 'P5A9-TAPE', 12, 'rolls', 'verified', true, false, 'verified');
INSERT INTO public.vendors (id, organization_id, name, normalized_name, active, catalog_vendor_id)
VALUES ('5a9a0000-0000-4000-8000-000000000501', '5a9a0000-0000-4000-8000-000000000101',
  'Phase 5A.9 Local Vendor', 'phase 5a 9 local vendor', true, '5a9a0000-0000-4000-8000-000000000201');
INSERT INTO public.products (
  id, organization_id, name, normalized_name, unit, unit_of_measure, approved,
  active, staff_requestable, manufacturer, catalog_product_id
)
VALUES ('5a9a0000-0000-4000-8000-000000000601', '5a9a0000-0000-4000-8000-000000000101',
  'Phase 5A.9 Structured Tape', 'phase 5a 9 structured tape', 'roll', 'roll', true,
  true, true, 'Fixture Maker', '5a9a0000-0000-4000-8000-000000000301');
INSERT INTO public.vendor_products (
  id, organization_id, vendor_id, product_id, vendor_sku, package_size,
  unit_of_measure, active, catalog_vendor_product_id
)
VALUES ('5a9a0000-0000-4000-8000-000000000701', '5a9a0000-0000-4000-8000-000000000101',
  '5a9a0000-0000-4000-8000-000000000501', '5a9a0000-0000-4000-8000-000000000601',
  'P5A9-TAPE', '12 rolls', 'roll', true, '5a9a0000-0000-4000-8000-000000000401');
INSERT INTO public.inventory_items (
  id, organization_id, sku, name, quantity, unit, active, product_id, manufacturer, vendor_name
)
VALUES ('5a9a0000-0000-4000-8000-000000000801', '5a9a0000-0000-4000-8000-000000000101',
  'P5A9-TAPE', 'Phase 5A.9 Structured Tape', 7, 'roll', true,
  '5a9a0000-0000-4000-8000-000000000601', 'Fixture Maker', 'Phase 5A.9 Local Vendor');

INSERT INTO public.supply_requests (
  id, organization_id, requested_by, team_id, location_id, request_type,
  quantity, notes, status
)
VALUES
  ('5a9a0000-0000-4000-8000-000000000901', '5a9a0000-0000-4000-8000-000000000101', '5a9a0000-0000-4000-8000-000000000003', '5a9a0000-0000-4000-8000-000000000111', '5a9a0000-0000-4000-8000-000000000121', 'reorder', 2, 'Approve fixture', 'submitted'),
  ('5a9a0000-0000-4000-8000-000000000902', '5a9a0000-0000-4000-8000-000000000101', '5a9a0000-0000-4000-8000-000000000003', '5a9a0000-0000-4000-8000-000000000111', '5a9a0000-0000-4000-8000-000000000121', 'new_item', 1, 'Decline fixture', 'submitted'),
  ('5a9a0000-0000-4000-8000-000000000903', '5a9a0000-0000-4000-8000-000000000101', '5a9a0000-0000-4000-8000-000000000003', '5a9a0000-0000-4000-8000-000000000111', '5a9a0000-0000-4000-8000-000000000121', 'new_item', 1, 'Atomicity fixture', 'submitted'),
  ('5a9a0000-0000-4000-8000-000000000904', '5a9a0000-0000-4000-8000-000000000101', '5a9a0000-0000-4000-8000-000000000003', '5a9a0000-0000-4000-8000-000000000111', '5a9a0000-0000-4000-8000-000000000121', 'reorder', 1, 'In-review fixture', 'under_review');

INSERT INTO public.supply_request_items (
  id, organization_id, supply_request_id, product_id, inventory_item_id,
  vendor_product_id, catalog_vendor_product_id, free_text_item, quantity, unit
)
VALUES
  ('5a9a0000-0000-4000-8000-000000000911', '5a9a0000-0000-4000-8000-000000000101', '5a9a0000-0000-4000-8000-000000000901', '5a9a0000-0000-4000-8000-000000000601', '5a9a0000-0000-4000-8000-000000000801', '5a9a0000-0000-4000-8000-000000000701', '5a9a0000-0000-4000-8000-000000000401', NULL, 2, 'roll'),
  ('5a9a0000-0000-4000-8000-000000000912', '5a9a0000-0000-4000-8000-000000000101', '5a9a0000-0000-4000-8000-000000000901', NULL, NULL, NULL, NULL, 'Custom travel kit', 3, NULL),
  ('5a9a0000-0000-4000-8000-000000000913', '5a9a0000-0000-4000-8000-000000000101', '5a9a0000-0000-4000-8000-000000000902', NULL, NULL, NULL, NULL, 'Already stocked elsewhere', 1, NULL),
  ('5a9a0000-0000-4000-8000-000000000914', '5a9a0000-0000-4000-8000-000000000101', '5a9a0000-0000-4000-8000-000000000903', NULL, NULL, NULL, NULL, 'Force rollback', 1, NULL),
  ('5a9a0000-0000-4000-8000-000000000915', '5a9a0000-0000-4000-8000-000000000101', '5a9a0000-0000-4000-8000-000000000904', NULL, NULL, NULL, NULL, 'Continue review', 1, NULL);

INSERT INTO public.supply_request_updates (
  id, organization_id, supply_request_id, author_id, status_from, status_to
)
VALUES ('5a9a0000-0000-4000-8000-000000000921', '5a9a0000-0000-4000-8000-000000000101',
  '5a9a0000-0000-4000-8000-000000000904', '5a9a0000-0000-4000-8000-000000000001', 'submitted', 'under_review');

-- An anonymous client cannot execute either security-definer API.
SET LOCAL ROLE anon;
DO $phase5a9_anon_acl$
BEGIN
  BEGIN
    PERFORM public.decide_supply_request(
      '5a9a0000-0000-4000-8000-000000000101',
      '5a9a0000-0000-4000-8000-000000000901', 'approved'
    );
    RAISE EXCEPTION 'Anonymous decision unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.list_staff_supply_request_updates(
      '5a9a0000-0000-4000-8000-000000000101',
      ARRAY['5a9a0000-0000-4000-8000-000000000901'::uuid]
    );
    RAISE EXCEPTION 'Anonymous update projection unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END
$phase5a9_anon_acl$;
RESET ROLE;
INSERT INTO phase5a9_checks VALUES ('authenticated-only database functions');

SET LOCAL ROLE authenticated;

-- Staff cannot decide, and an administrator from another organization cannot cross scope.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '5a9a0000-0000-4000-8000-000000000003', true);
DO $phase5a9_staff_decision_denied$
BEGIN
  BEGIN
    PERFORM public.decide_supply_request(
      '5a9a0000-0000-4000-8000-000000000101',
      '5a9a0000-0000-4000-8000-000000000901', 'approved'
    );
    RAISE EXCEPTION 'Staff decision unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END
$phase5a9_staff_decision_denied$;
INSERT INTO phase5a9_checks VALUES ('staff cannot invoke admin decision');

SELECT pg_catalog.set_config('request.jwt.claim.sub', '5a9a0000-0000-4000-8000-000000000004', true);
DO $phase5a9_cross_org_decision_denied$
BEGIN
  BEGIN
    PERFORM public.decide_supply_request(
      '5a9a0000-0000-4000-8000-000000000101',
      '5a9a0000-0000-4000-8000-000000000901', 'approved'
    );
    RAISE EXCEPTION 'Cross-organization decision unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END
$phase5a9_cross_org_decision_denied$;
INSERT INTO phase5a9_checks VALUES ('cross-organization admin decision blocked');

-- Approve as an admin. Capture all identity and non-request data before the call.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '5a9a0000-0000-4000-8000-000000000002', true);
DO $phase5a9_approve$
DECLARE
  _result jsonb;
  _items_before jsonb;
  _items_after jsonb;
  _data_before jsonb;
  _data_after jsonb;
  _purchase_before jsonb;
  _purchase_after jsonb;
  _count integer;
BEGIN
  SELECT jsonb_agg(to_jsonb(item) ORDER BY item.id) INTO _items_before
  FROM public.supply_request_items item
  WHERE item.supply_request_id = '5a9a0000-0000-4000-8000-000000000901';

  SELECT jsonb_build_object(
    'product', (SELECT to_jsonb(p) FROM public.products p WHERE p.id = '5a9a0000-0000-4000-8000-000000000601'),
    'vendor', (SELECT to_jsonb(v) FROM public.vendors v WHERE v.id = '5a9a0000-0000-4000-8000-000000000501'),
    'vendorProduct', (SELECT to_jsonb(vp) FROM public.vendor_products vp WHERE vp.id = '5a9a0000-0000-4000-8000-000000000701'),
    'inventory', (SELECT to_jsonb(i) FROM public.inventory_items i WHERE i.id = '5a9a0000-0000-4000-8000-000000000801'),
    'catalogVendor', (SELECT to_jsonb(cv) FROM public.catalog_vendors cv WHERE cv.id = '5a9a0000-0000-4000-8000-000000000201'),
    'catalogProduct', (SELECT to_jsonb(cp) FROM public.catalog_products cp WHERE cp.id = '5a9a0000-0000-4000-8000-000000000301'),
    'catalogVendorProduct', (SELECT to_jsonb(cvp) FROM public.catalog_vendor_products cvp WHERE cvp.id = '5a9a0000-0000-4000-8000-000000000401')
  ) INTO _data_before;
  SELECT jsonb_build_object(
    'vendorInvoices', (SELECT count(*) FROM public.vendor_invoices WHERE organization_id = '5a9a0000-0000-4000-8000-000000000101'),
    'invoices', (SELECT count(*) FROM public.invoices WHERE organization_id = '5a9a0000-0000-4000-8000-000000000101'),
    'invoiceItems', (SELECT count(*) FROM public.invoice_items WHERE organization_id = '5a9a0000-0000-4000-8000-000000000101'),
    'inventoryAdjustments', (SELECT count(*) FROM public.inventory_adjustments WHERE organization_id = '5a9a0000-0000-4000-8000-000000000101'),
    'priceHistory', (SELECT count(*) FROM public.inventory_price_history WHERE organization_id = '5a9a0000-0000-4000-8000-000000000101')
  ) INTO _purchase_before;

  _result := public.decide_supply_request(
    '5a9a0000-0000-4000-8000-000000000101',
    '5a9a0000-0000-4000-8000-000000000901', 'approved',
    'Approved for staff', 'Admin-only approval note'
  );
  IF _result->>'status' IS DISTINCT FROM 'approved'
     OR (_result->>'alreadyDecided')::boolean THEN
    RAISE EXCEPTION 'Approval result is incorrect: %', _result;
  END IF;
  IF (SELECT status FROM public.supply_requests WHERE id = '5a9a0000-0000-4000-8000-000000000901') <> 'approved' THEN
    RAISE EXCEPTION 'Approval did not reach approved status';
  END IF;
  SELECT count(*) INTO _count FROM public.supply_request_updates
  WHERE supply_request_id = '5a9a0000-0000-4000-8000-000000000901'
    AND ((status_from = 'submitted' AND status_to = 'under_review')
      OR (status_from = 'under_review' AND status_to = 'approved'));
  IF _count <> 2 THEN RAISE EXCEPTION 'Approval did not preserve both audit transitions'; END IF;
  IF EXISTS (
    SELECT 1 FROM public.supply_request_updates
    WHERE supply_request_id = '5a9a0000-0000-4000-8000-000000000901'
      AND author_id <> '5a9a0000-0000-4000-8000-000000000002'
  ) THEN RAISE EXCEPTION 'Approval audit author is incorrect'; END IF;

  SELECT jsonb_agg(to_jsonb(item) ORDER BY item.id) INTO _items_after
  FROM public.supply_request_items item
  WHERE item.supply_request_id = '5a9a0000-0000-4000-8000-000000000901';
  IF _items_after IS DISTINCT FROM _items_before THEN RAISE EXCEPTION 'Approval changed request lines'; END IF;
  SELECT jsonb_build_object(
    'product', (SELECT to_jsonb(p) FROM public.products p WHERE p.id = '5a9a0000-0000-4000-8000-000000000601'),
    'vendor', (SELECT to_jsonb(v) FROM public.vendors v WHERE v.id = '5a9a0000-0000-4000-8000-000000000501'),
    'vendorProduct', (SELECT to_jsonb(vp) FROM public.vendor_products vp WHERE vp.id = '5a9a0000-0000-4000-8000-000000000701'),
    'inventory', (SELECT to_jsonb(i) FROM public.inventory_items i WHERE i.id = '5a9a0000-0000-4000-8000-000000000801'),
    'catalogVendor', (SELECT to_jsonb(cv) FROM public.catalog_vendors cv WHERE cv.id = '5a9a0000-0000-4000-8000-000000000201'),
    'catalogProduct', (SELECT to_jsonb(cp) FROM public.catalog_products cp WHERE cp.id = '5a9a0000-0000-4000-8000-000000000301'),
    'catalogVendorProduct', (SELECT to_jsonb(cvp) FROM public.catalog_vendor_products cvp WHERE cvp.id = '5a9a0000-0000-4000-8000-000000000401')
  ) INTO _data_after;
  SELECT jsonb_build_object(
    'vendorInvoices', (SELECT count(*) FROM public.vendor_invoices WHERE organization_id = '5a9a0000-0000-4000-8000-000000000101'),
    'invoices', (SELECT count(*) FROM public.invoices WHERE organization_id = '5a9a0000-0000-4000-8000-000000000101'),
    'invoiceItems', (SELECT count(*) FROM public.invoice_items WHERE organization_id = '5a9a0000-0000-4000-8000-000000000101'),
    'inventoryAdjustments', (SELECT count(*) FROM public.inventory_adjustments WHERE organization_id = '5a9a0000-0000-4000-8000-000000000101'),
    'priceHistory', (SELECT count(*) FROM public.inventory_price_history WHERE organization_id = '5a9a0000-0000-4000-8000-000000000101')
  ) INTO _purchase_after;
  IF _data_after IS DISTINCT FROM _data_before THEN RAISE EXCEPTION 'Approval mutated inventory or catalog identity'; END IF;
  IF _purchase_after IS DISTINCT FROM _purchase_before THEN RAISE EXCEPTION 'Approval created a purchasing record'; END IF;
END
$phase5a9_approve$;
INSERT INTO phase5a9_checks VALUES
  ('submitted approval reaches approved'),
  ('approval preserves both lifecycle audits'),
  ('approval preserves multi-line request identity'),
  ('approval does not mutate inventory or catalogs'),
  ('approval creates no invoice, purchase, or adjustment data');

-- Same-decision retry is idempotent; the opposite terminal decision is rejected.
DO $phase5a9_repeat_approve$
DECLARE
  _before integer;
  _after integer;
  _result jsonb;
BEGIN
  SELECT count(*) INTO _before FROM public.supply_request_updates
  WHERE supply_request_id = '5a9a0000-0000-4000-8000-000000000901';
  _result := public.decide_supply_request(
    '5a9a0000-0000-4000-8000-000000000101',
    '5a9a0000-0000-4000-8000-000000000901', 'approved',
    'Retry must not append', 'Retry must not append'
  );
  SELECT count(*) INTO _after FROM public.supply_request_updates
  WHERE supply_request_id = '5a9a0000-0000-4000-8000-000000000901';
  IF NOT (_result->>'alreadyDecided')::boolean OR _after <> _before THEN
    RAISE EXCEPTION 'Repeat approval was not idempotent';
  END IF;
  BEGIN
    PERFORM public.decide_supply_request(
      '5a9a0000-0000-4000-8000-000000000101',
      '5a9a0000-0000-4000-8000-000000000901', 'denied', 'Conflicting decision'
    );
    RAISE EXCEPTION 'Conflicting terminal decision unexpectedly succeeded';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
END
$phase5a9_repeat_approve$;
INSERT INTO phase5a9_checks VALUES
  ('repeat approval is idempotent'),
  ('conflicting terminal decision rejected');

-- An under-review request performs only its remaining valid transition.
SELECT public.decide_supply_request(
  '5a9a0000-0000-4000-8000-000000000101',
  '5a9a0000-0000-4000-8000-000000000904', 'approved'
);
DO $phase5a9_under_review$
BEGIN
  IF (SELECT status FROM public.supply_requests WHERE id = '5a9a0000-0000-4000-8000-000000000904') <> 'approved'
     OR (SELECT count(*) FROM public.supply_request_updates WHERE supply_request_id = '5a9a0000-0000-4000-8000-000000000904') <> 2 THEN
    RAISE EXCEPTION 'Under-review approval did not add exactly one approval transition';
  END IF;
END
$phase5a9_under_review$;
INSERT INTO phase5a9_checks VALUES ('under-review approval performs only remaining transition');

-- Decline requires a public reason, persists public/private notes, and is idempotent.
DO $phase5a9_decline$
DECLARE
  _before integer;
  _after integer;
  _result jsonb;
BEGIN
  BEGIN
    PERFORM public.decide_supply_request(
      '5a9a0000-0000-4000-8000-000000000101',
      '5a9a0000-0000-4000-8000-000000000902', 'denied', '   ', 'Private note'
    );
    RAISE EXCEPTION 'Blank decline reason unexpectedly succeeded';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  IF (SELECT status FROM public.supply_requests WHERE id = '5a9a0000-0000-4000-8000-000000000902') <> 'submitted' THEN
    RAISE EXCEPTION 'Failed decline changed request state';
  END IF;
  _result := public.decide_supply_request(
    '5a9a0000-0000-4000-8000-000000000101',
    '5a9a0000-0000-4000-8000-000000000902', 'denied',
    'This item is already available in storage.', 'Duplicate request; verified by admin.'
  );
  IF _result->>'status' IS DISTINCT FROM 'denied'
     OR (SELECT status FROM public.supply_requests WHERE id = '5a9a0000-0000-4000-8000-000000000902') <> 'denied' THEN
    RAISE EXCEPTION 'Decline result is incorrect: %', _result;
  END IF;
  SELECT count(*) INTO _before FROM public.supply_request_updates
  WHERE supply_request_id = '5a9a0000-0000-4000-8000-000000000902';
  _result := public.decide_supply_request(
    '5a9a0000-0000-4000-8000-000000000101',
    '5a9a0000-0000-4000-8000-000000000902', 'denied',
    'This item is already available in storage.', 'Duplicate request; verified by admin.'
  );
  SELECT count(*) INTO _after FROM public.supply_request_updates
  WHERE supply_request_id = '5a9a0000-0000-4000-8000-000000000902';
  IF NOT (_result->>'alreadyDecided')::boolean OR _after <> _before THEN
    RAISE EXCEPTION 'Repeat decline was not idempotent';
  END IF;
END
$phase5a9_decline$;
INSERT INTO phase5a9_checks VALUES
  ('decline requires staff-visible reason'),
  ('decline persists terminal status and reason'),
  ('repeat decline is idempotent');

RESET ROLE;

-- Force the second approval audit insert to fail. The first transition must roll back.
CREATE FUNCTION pg_temp.phase5a9_force_second_transition_failure()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.staff_visible_note = 'Phase 5A.9 forced failure' THEN
    RAISE EXCEPTION 'Phase 5A.9 forced second-transition failure';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER phase5a9_force_second_transition_failure
  BEFORE INSERT ON public.supply_request_updates
  FOR EACH ROW EXECUTE FUNCTION pg_temp.phase5a9_force_second_transition_failure();

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', '5a9a0000-0000-4000-8000-000000000002', true);
DO $phase5a9_atomic_failure$
BEGIN
  BEGIN
    PERFORM public.decide_supply_request(
      '5a9a0000-0000-4000-8000-000000000101',
      '5a9a0000-0000-4000-8000-000000000903', 'approved',
      'Phase 5A.9 forced failure'
    );
    RAISE EXCEPTION 'Forced second-transition failure unexpectedly succeeded';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'Phase 5A.9 forced second-transition failure' THEN RAISE; END IF;
  END;
  IF (SELECT status FROM public.supply_requests WHERE id = '5a9a0000-0000-4000-8000-000000000903') <> 'submitted'
     OR EXISTS (SELECT 1 FROM public.supply_request_updates WHERE supply_request_id = '5a9a0000-0000-4000-8000-000000000903') THEN
    RAISE EXCEPTION 'Approval left partial state after its second transition failed';
  END IF;
END
$phase5a9_atomic_failure$;
INSERT INTO phase5a9_checks VALUES ('approval is atomic when second transition fails');
RESET ROLE;
DROP TRIGGER phase5a9_force_second_transition_failure ON public.supply_request_updates;

-- Admin sees both fields directly. Staff sees public status/message only through
-- the projection; the tightened table policy cannot expose a mixed private row.
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', '5a9a0000-0000-4000-8000-000000000002', true);
DO $phase5a9_admin_visibility$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.supply_request_updates
    WHERE supply_request_id = '5a9a0000-0000-4000-8000-000000000902'
      AND staff_visible_note = 'This item is already available in storage.'
      AND internal_note = 'Duplicate request; verified by admin.'
  ) THEN RAISE EXCEPTION 'Admin cannot read both decline note fields'; END IF;
END
$phase5a9_admin_visibility$;
INSERT INTO phase5a9_checks VALUES ('admin reads public and internal notes');

SELECT pg_catalog.set_config('request.jwt.claim.sub', '5a9a0000-0000-4000-8000-000000000003', true);
DO $phase5a9_staff_visibility$
DECLARE
  _projection jsonb;
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.supply_request_updates
    WHERE supply_request_id IN (
      '5a9a0000-0000-4000-8000-000000000901',
      '5a9a0000-0000-4000-8000-000000000902'
    ) AND internal_note IS NOT NULL
  ) THEN RAISE EXCEPTION 'Staff can directly read an internal-note row'; END IF;

  SELECT jsonb_agg(to_jsonb(update_row) ORDER BY update_row.created_at, update_row.status_to)
  INTO _projection
  FROM public.list_staff_supply_request_updates(
    '5a9a0000-0000-4000-8000-000000000101',
    ARRAY[
      '5a9a0000-0000-4000-8000-000000000901'::uuid,
      '5a9a0000-0000-4000-8000-000000000902'::uuid
    ]
  ) update_row;
  IF _projection IS NULL
     OR _projection::text NOT LIKE '%This item is already available in storage.%'
     OR _projection::text NOT LIKE '%approved%'
     OR _projection::text NOT LIKE '%denied%'
     OR _projection::text LIKE '%Duplicate request; verified by admin.%'
     OR EXISTS (
       SELECT 1 FROM jsonb_array_elements(_projection) row_value
       WHERE row_value ? 'internal_note'
     ) THEN
    RAISE EXCEPTION 'Staff projection did not isolate public update data: %', _projection;
  END IF;
END
$phase5a9_staff_visibility$;
INSERT INTO phase5a9_checks VALUES
  ('staff direct table read cannot expose internal notes'),
  ('staff projection exposes status timestamp and public reason only');

-- Another staff member in the same organization owns no fixture requests.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '5a9a0000-0000-4000-8000-000000000005', true);
DO $phase5a9_requester_scope$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.list_staff_supply_request_updates(
      '5a9a0000-0000-4000-8000-000000000101',
      ARRAY['5a9a0000-0000-4000-8000-000000000902'::uuid]
    )
  ) THEN RAISE EXCEPTION 'Staff projection leaked another requester update'; END IF;
END
$phase5a9_requester_scope$;
INSERT INTO phase5a9_checks VALUES ('staff projection is requester scoped');

-- A member of another organization cannot use the projection for this org.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '5a9a0000-0000-4000-8000-000000000004', true);
DO $phase5a9_projection_org_scope$
BEGIN
  BEGIN
    PERFORM * FROM public.list_staff_supply_request_updates(
      '5a9a0000-0000-4000-8000-000000000101',
      ARRAY['5a9a0000-0000-4000-8000-000000000902'::uuid]
    );
    RAISE EXCEPTION 'Cross-organization staff projection unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END
$phase5a9_projection_org_scope$;
INSERT INTO phase5a9_checks VALUES ('staff projection is organization scoped');

RESET ROLE;

SELECT count(*) AS checks_passed, 0 AS checks_failed
FROM phase5a9_checks;
SELECT name AS passed_check FROM phase5a9_checks ORDER BY name;

ROLLBACK;
