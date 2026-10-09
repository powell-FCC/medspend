-- Phase 6C rollback-only behavioral verification.
-- Run against a disposable database after 20261009120000_phase6c_staff_request_forgiveness.sql.
-- All fixture, request, and audit writes occur inside this transaction and are rolled back.

BEGIN;

DO $phase6c_fixture_guard$
BEGIN
  IF EXISTS (
    SELECT 1 FROM auth.users
    WHERE id BETWEEN '6c6c0000-0000-4000-8000-000000000001'::uuid
      AND '6c6c0000-0000-4000-8000-000000000099'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.organizations
    WHERE id BETWEEN '6c6c0000-0000-4000-8000-000000000101'::uuid
      AND '6c6c0000-0000-4000-8000-000000000199'::uuid
  ) THEN
    RAISE EXCEPTION 'Phase 6C rollback-test fixture IDs already exist';
  END IF;
END
$phase6c_fixture_guard$;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
VALUES
  ('6c6c0000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'phase6c-admin@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('6c6c0000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'phase6c-staff@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('6c6c0000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'phase6c-other-staff@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('6c6c0000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'phase6c-other-owner@example.invalid', '', now(), '{}', '{}', now(), now());

INSERT INTO public.organizations (id, name, created_by)
VALUES
  ('6c6c0000-0000-4000-8000-000000000101', 'Phase 6C Organization', '6c6c0000-0000-4000-8000-000000000001'),
  ('6c6c0000-0000-4000-8000-000000000102', 'Phase 6C Other Organization', '6c6c0000-0000-4000-8000-000000000004');

INSERT INTO public.teams (id, organization_id, name, active)
VALUES
  ('6c6c0000-0000-4000-8000-000000000111', '6c6c0000-0000-4000-8000-000000000101', 'Phase 6C Football', true),
  ('6c6c0000-0000-4000-8000-000000000112', '6c6c0000-0000-4000-8000-000000000101', 'Phase 6C Soccer', true),
  ('6c6c0000-0000-4000-8000-000000000113', '6c6c0000-0000-4000-8000-000000000101', 'Phase 6C Archived Team', false),
  ('6c6c0000-0000-4000-8000-000000000114', '6c6c0000-0000-4000-8000-000000000102', 'Phase 6C Other Team', true);

INSERT INTO public.locations (id, organization_id, name, active)
VALUES
  ('6c6c0000-0000-4000-8000-000000000121', '6c6c0000-0000-4000-8000-000000000101', 'Phase 6C Main Room', true),
  ('6c6c0000-0000-4000-8000-000000000122', '6c6c0000-0000-4000-8000-000000000101', 'Phase 6C Field House', true),
  ('6c6c0000-0000-4000-8000-000000000124', '6c6c0000-0000-4000-8000-000000000102', 'Phase 6C Other Location', true);

INSERT INTO public.organization_memberships (
  id, organization_id, user_id, role, active, default_team_id, default_location_id
)
VALUES
  ('6c6c0000-0000-4000-8000-000000000131', '6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000001', 'admin', true, NULL, NULL),
  ('6c6c0000-0000-4000-8000-000000000132', '6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000002', 'staff', true,
    '6c6c0000-0000-4000-8000-000000000111', '6c6c0000-0000-4000-8000-000000000121'),
  ('6c6c0000-0000-4000-8000-000000000133', '6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000003', 'staff', true,
    '6c6c0000-0000-4000-8000-000000000111', '6c6c0000-0000-4000-8000-000000000121'),
  ('6c6c0000-0000-4000-8000-000000000134', '6c6c0000-0000-4000-8000-000000000102', '6c6c0000-0000-4000-8000-000000000004', 'owner', true,
    '6c6c0000-0000-4000-8000-000000000114', '6c6c0000-0000-4000-8000-000000000124');

INSERT INTO public.catalog_vendors (id, name, normalized_name, active)
VALUES ('6c6c0000-0000-4000-8000-000000000201', 'Phase 6C Catalog Vendor', 'phase 6c catalog vendor', true);
INSERT INTO public.catalog_products (id, name, normalized_name, active, verification_status)
VALUES
  ('6c6c0000-0000-4000-8000-000000000301', 'Phase 6C Prewrap', 'phase 6c prewrap', true, 'verified'),
  ('6c6c0000-0000-4000-8000-000000000302', 'Phase 6C Cold Pack', 'phase 6c cold pack', true, 'verified');
INSERT INTO public.catalog_vendor_products (
  id, catalog_product_id, catalog_vendor_id, vendor_sku, normalized_vendor_sku,
  source_catalog_price, currency_code, active, discontinued, verification_status
)
VALUES
  ('6c6c0000-0000-4000-8000-000000000401', '6c6c0000-0000-4000-8000-000000000301',
    '6c6c0000-0000-4000-8000-000000000201', '6C-PREWRAP', '6C-PREWRAP', 10, 'USD', true, false, 'verified'),
  ('6c6c0000-0000-4000-8000-000000000402', '6c6c0000-0000-4000-8000-000000000302',
    '6c6c0000-0000-4000-8000-000000000201', '6C-COLD', '6C-COLD', 25, 'USD', true, false, 'verified');

INSERT INTO public.vendors (id, organization_id, name, normalized_name, active, catalog_vendor_id)
VALUES ('6c6c0000-0000-4000-8000-000000000501', '6c6c0000-0000-4000-8000-000000000101',
  'Phase 6C Vendor', 'phase 6c vendor', true, '6c6c0000-0000-4000-8000-000000000201');

INSERT INTO public.products (
  id, organization_id, name, normalized_name, description, unit_of_measure,
  active, staff_requestable, catalog_product_id
)
VALUES
  ('6c6c0000-0000-4000-8000-000000000601', '6c6c0000-0000-4000-8000-000000000101',
    'Phase 6C Prewrap', 'phase 6c prewrap', NULL, 'roll', true, true, '6c6c0000-0000-4000-8000-000000000301'),
  ('6c6c0000-0000-4000-8000-000000000602', '6c6c0000-0000-4000-8000-000000000101',
    'Phase 6C Admin Only Product', 'phase 6c admin only product', NULL, 'each', true, false, NULL),
  ('6c6c0000-0000-4000-8000-000000000603', '6c6c0000-0000-4000-8000-000000000102',
    'Phase 6C Other Org Product', 'phase 6c other org product', NULL, 'each', true, true, NULL);

INSERT INTO public.vendor_products (
  id, organization_id, vendor_id, product_id, vendor_sku, unit_of_measure, active,
  catalog_vendor_product_id
)
VALUES ('6c6c0000-0000-4000-8000-000000000701', '6c6c0000-0000-4000-8000-000000000101',
  '6c6c0000-0000-4000-8000-000000000501', '6c6c0000-0000-4000-8000-000000000601',
  '6C-PREWRAP', 'roll', true, '6c6c0000-0000-4000-8000-000000000401');

INSERT INTO public.inventory_items (id, organization_id, sku, name, quantity, unit, active, product_id)
VALUES
  ('6c6c0000-0000-4000-8000-000000000801', '6c6c0000-0000-4000-8000-000000000101',
    '6C-PREWRAP', 'Phase 6C Prewrap Stock', 4, 'roll', true, '6c6c0000-0000-4000-8000-000000000601'),
  ('6c6c0000-0000-4000-8000-000000000802', '6c6c0000-0000-4000-8000-000000000102',
    '6C-OTHER', 'Phase 6C Other Org Stock', 1, 'each', true, '6c6c0000-0000-4000-8000-000000000603');

-- One staff-owned request per later lifecycle status. Lines are custom so no
-- commitment fixtures are required; the edit RPC must reject before touching lines.
INSERT INTO public.supply_requests (
  id, organization_id, requested_by, request_type, team_id, location_id, notes, status
)
SELECT
  fixture.id::uuid, '6c6c0000-0000-4000-8000-000000000101',
  '6c6c0000-0000-4000-8000-000000000002', 'new_item',
  '6c6c0000-0000-4000-8000-000000000111', '6c6c0000-0000-4000-8000-000000000121',
  'Locked ' || fixture.status, fixture.status::public.supply_request_status
FROM (VALUES
  ('6c6c0000-0000-4000-8000-000000000901', 'under_review'),
  ('6c6c0000-0000-4000-8000-000000000902', 'approved'),
  ('6c6c0000-0000-4000-8000-000000000903', 'ordered'),
  ('6c6c0000-0000-4000-8000-000000000904', 'received'),
  ('6c6c0000-0000-4000-8000-000000000905', 'completed'),
  ('6c6c0000-0000-4000-8000-000000000906', 'denied')
) AS fixture(id, status);
INSERT INTO public.supply_request_items (organization_id, supply_request_id, free_text_item, quantity)
SELECT organization_id, id, 'Locked line', 1
FROM public.supply_requests
WHERE id BETWEEN '6c6c0000-0000-4000-8000-000000000901' AND '6c6c0000-0000-4000-8000-000000000906';

-- Runs as the caller's role; asserts the exact user-safe error and SQLSTATE.
CREATE FUNCTION pg_temp.phase6c_expect_edit_error(
  _organization_id uuid,
  _request_id uuid,
  _team_id uuid,
  _location_id uuid,
  _items jsonb,
  _expected_message text,
  _expected_state text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  BEGIN
    PERFORM public.update_submitted_supply_request(
      _organization_id, _request_id, NULL, _team_id, _location_id, 'Must not persist', _items
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> _expected_message
       OR (_expected_state IS NOT NULL AND SQLSTATE <> _expected_state) THEN
      RAISE EXCEPTION 'Expected "%" (%), got "%" (%)',
        _expected_message, coalesce(_expected_state, 'any'), SQLERRM, SQLSTATE;
    END IF;
    RETURN;
  END;
  RAISE EXCEPTION 'Edit unexpectedly succeeded; expected "%"', _expected_message;
END;
$$;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c6c0000-0000-4000-8000-000000000002', true);

-- Existing create workflow still works through the refactored shared helpers.
DO $phase6c_submit$
DECLARE
  _request_id uuid;
  _request public.supply_requests%ROWTYPE;
BEGIN
  _request_id := public.submit_supply_request(
    '6c6c0000-0000-4000-8000-000000000101', 'reorder', NULL, NULL, '  First note  ',
    jsonb_build_array(
      jsonb_build_object('inventoryItemId', '6c6c0000-0000-4000-8000-000000000801', 'quantity', 2),
      jsonb_build_object('freeTextItem', 'Ankle brace', 'quantity', 1)
    )
  );
  SELECT * INTO _request FROM public.supply_requests WHERE id = _request_id;
  IF _request.status <> 'submitted'
     OR _request.team_id <> '6c6c0000-0000-4000-8000-000000000111'
     OR _request.location_id <> '6c6c0000-0000-4000-8000-000000000121'
     OR _request.notes <> 'First note'
     OR _request.product_id <> '6c6c0000-0000-4000-8000-000000000601'
     OR _request.quantity <> 2
     OR (SELECT count(*) FROM public.supply_request_items WHERE supply_request_id = _request_id) <> 2 THEN
    RAISE EXCEPTION 'Refactored submission changed behavior: %', row_to_json(_request);
  END IF;
  PERFORM pg_catalog.set_config('phase6c.request_id', _request_id::text, true);
END
$phase6c_submit$;

-- Requester edits quantity, removes a line, adds structured and custom lines, and
-- changes team, location, and note. Same ID, same status, no duplicate, no commitment.
DO $phase6c_edit$
DECLARE
  _request_id uuid := current_setting('phase6c.request_id')::uuid;
  _result jsonb;
  _request public.supply_requests%ROWTYPE;
  _request_count bigint;
BEGIN
  SELECT count(*) INTO _request_count FROM public.supply_requests;
  _result := public.update_submitted_supply_request(
    '6c6c0000-0000-4000-8000-000000000101', _request_id, 'new_item',
    '6c6c0000-0000-4000-8000-000000000112', '6c6c0000-0000-4000-8000-000000000122',
    'Updated note',
    jsonb_build_array(
      jsonb_build_object('inventoryItemId', '6c6c0000-0000-4000-8000-000000000801', 'quantity', 5),
      jsonb_build_object('vendorProductId', '6c6c0000-0000-4000-8000-000000000701', 'quantity', 3),
      jsonb_build_object('catalogVendorProductId', '6c6c0000-0000-4000-8000-000000000402', 'quantity', 1),
      jsonb_build_object('freeTextItem', 'Knee sleeve', 'quantity', 2)
    )
  );
  SELECT * INTO _request FROM public.supply_requests WHERE id = _request_id;

  IF (_result->>'id')::uuid <> _request_id OR _result->>'status' <> 'submitted'
     OR (_result->>'itemCount')::integer <> 4 THEN
    RAISE EXCEPTION 'Unexpected edit result: %', _result;
  END IF;
  IF (SELECT count(*) FROM public.supply_requests) <> _request_count THEN
    RAISE EXCEPTION 'Editing created or removed a request';
  END IF;
  IF _request.status <> 'submitted'
     OR _request.request_type <> 'new_item'
     OR _request.team_id <> '6c6c0000-0000-4000-8000-000000000112'
     OR _request.location_id <> '6c6c0000-0000-4000-8000-000000000122'
     OR _request.notes <> 'Updated note'
     OR _request.requested_by <> '6c6c0000-0000-4000-8000-000000000002'
     OR _request.product_id <> '6c6c0000-0000-4000-8000-000000000601'
     OR _request.quantity <> 5 THEN
    RAISE EXCEPTION 'Edited request fields are incorrect: %', row_to_json(_request);
  END IF;

  IF (SELECT count(*) FROM public.supply_request_items WHERE supply_request_id = _request_id) <> 4
     OR NOT EXISTS (
       SELECT 1 FROM public.supply_request_items
       WHERE supply_request_id = _request_id
         AND inventory_item_id = '6c6c0000-0000-4000-8000-000000000801'
         AND product_id = '6c6c0000-0000-4000-8000-000000000601'
         AND quantity = 5 AND unit = 'roll'
     ) OR NOT EXISTS (
       SELECT 1 FROM public.supply_request_items
       WHERE supply_request_id = _request_id
         AND vendor_product_id = '6c6c0000-0000-4000-8000-000000000701'
         AND product_id = '6c6c0000-0000-4000-8000-000000000601'
         AND catalog_vendor_product_id = '6c6c0000-0000-4000-8000-000000000401'
         AND quantity = 3
     ) OR NOT EXISTS (
       SELECT 1 FROM public.supply_request_items
       WHERE supply_request_id = _request_id
         AND catalog_vendor_product_id = '6c6c0000-0000-4000-8000-000000000402'
         AND product_id IS NULL AND vendor_product_id IS NULL AND inventory_item_id IS NULL
         AND quantity = 1
     ) OR NOT EXISTS (
       SELECT 1 FROM public.supply_request_items
       WHERE supply_request_id = _request_id
         AND free_text_item = 'Knee sleeve' AND quantity = 2
     ) OR EXISTS (
       SELECT 1 FROM public.supply_request_items
       WHERE supply_request_id = _request_id AND free_text_item = 'Ankle brace'
     ) THEN
    RAISE EXCEPTION 'Edited mixed line set is incorrect';
  END IF;

  IF (
    SELECT count(*) FROM public.list_staff_supply_request_updates(
      '6c6c0000-0000-4000-8000-000000000101', ARRAY[_request_id]
    ) update_row
    WHERE update_row.event_kind = 'requester_edited'
      AND update_row.status_from IS NULL AND update_row.status_to IS NULL
      AND update_row.staff_visible_note IS NULL
  ) <> 1 THEN
    RAISE EXCEPTION 'Requester edit was not visible in the staff-safe history';
  END IF;
END
$phase6c_edit$;

-- Omitted team/location keep the request's current context, not membership defaults.
DO $phase6c_keep_context$
DECLARE
  _request_id uuid := current_setting('phase6c.request_id')::uuid;
  _request public.supply_requests%ROWTYPE;
BEGIN
  PERFORM public.update_submitted_supply_request(
    '6c6c0000-0000-4000-8000-000000000101', _request_id, NULL, NULL, NULL, '   ',
    jsonb_build_array(
      jsonb_build_object('inventoryItemId', '6c6c0000-0000-4000-8000-000000000801', 'quantity', 5),
      jsonb_build_object('vendorProductId', '6c6c0000-0000-4000-8000-000000000701', 'quantity', 3),
      jsonb_build_object('catalogVendorProductId', '6c6c0000-0000-4000-8000-000000000402', 'quantity', 1),
      jsonb_build_object('freeTextItem', 'Knee sleeve', 'quantity', 2)
    )
  );
  SELECT * INTO _request FROM public.supply_requests WHERE id = _request_id;
  IF _request.team_id <> '6c6c0000-0000-4000-8000-000000000112'
     OR _request.location_id <> '6c6c0000-0000-4000-8000-000000000122'
     OR _request.request_type <> 'new_item'
     OR _request.notes IS NOT NULL THEN
    RAISE EXCEPTION 'Omitted context or blank note handled incorrectly: %', row_to_json(_request);
  END IF;
END
$phase6c_keep_context$;

-- Edit mode resubmits each line's stored identity tuple. Every stored tuple produced by
-- submission must re-validate unchanged under the same rules.
DO $phase6c_stored_identity_roundtrip$
DECLARE
  _request_id uuid := current_setting('phase6c.request_id')::uuid;
  _before jsonb;
  _after jsonb;
  _stored_lines jsonb;
BEGIN
  SELECT jsonb_agg(jsonb_build_array(
           product_id, inventory_item_id, vendor_product_id, catalog_vendor_product_id,
           free_text_item, quantity, unit
         ) ORDER BY quantity, free_text_item)
  INTO _before
  FROM public.supply_request_items WHERE supply_request_id = _request_id;

  SELECT jsonb_agg(jsonb_build_object(
           'productId', product_id,
           'inventoryItemId', inventory_item_id,
           'vendorProductId', vendor_product_id,
           'catalogVendorProductId', catalog_vendor_product_id,
           'freeTextItem', free_text_item,
           'quantity', quantity
         ))
  INTO _stored_lines
  FROM public.supply_request_items WHERE supply_request_id = _request_id;

  PERFORM public.update_submitted_supply_request(
    '6c6c0000-0000-4000-8000-000000000101', _request_id, NULL, NULL, NULL, NULL, _stored_lines
  );

  SELECT jsonb_agg(jsonb_build_array(
           product_id, inventory_item_id, vendor_product_id, catalog_vendor_product_id,
           free_text_item, quantity, unit
         ) ORDER BY quantity, free_text_item)
  INTO _after
  FROM public.supply_request_items WHERE supply_request_id = _request_id;

  IF _before IS DISTINCT FROM _after THEN
    RAISE EXCEPTION 'Stored identity round trip changed lines: % -> %', _before, _after;
  END IF;
END
$phase6c_stored_identity_roundtrip$;

-- Every rejected edit fails atomically with the submission path's own messages.
SELECT pg_temp.phase6c_expect_edit_error(
  '6c6c0000-0000-4000-8000-000000000101', current_setting('phase6c.request_id')::uuid, NULL, NULL,
  '[{"freeTextItem":"Tape","quantity":0}]', 'Each requested quantity must be a positive whole number');
SELECT pg_temp.phase6c_expect_edit_error(
  '6c6c0000-0000-4000-8000-000000000101', current_setting('phase6c.request_id')::uuid, NULL, NULL,
  '[{"freeTextItem":"Tape","quantity":1.5}]', 'Each requested quantity must be a positive whole number');
SELECT pg_temp.phase6c_expect_edit_error(
  '6c6c0000-0000-4000-8000-000000000101', current_setting('phase6c.request_id')::uuid, NULL, NULL,
  '[{"freeTextItem":"Tape","quantity":"many"}]', 'Each requested quantity must be a positive whole number');
SELECT pg_temp.phase6c_expect_edit_error(
  '6c6c0000-0000-4000-8000-000000000101', current_setting('phase6c.request_id')::uuid, NULL, NULL,
  '[]', 'Add at least one item to the request');
SELECT pg_temp.phase6c_expect_edit_error(
  '6c6c0000-0000-4000-8000-000000000101', current_setting('phase6c.request_id')::uuid,
  '6c6c0000-0000-4000-8000-000000000114', NULL,
  '[{"freeTextItem":"Tape","quantity":1}]', 'Select an available team for this request');
SELECT pg_temp.phase6c_expect_edit_error(
  '6c6c0000-0000-4000-8000-000000000101', current_setting('phase6c.request_id')::uuid,
  '6c6c0000-0000-4000-8000-000000000113', NULL,
  '[{"freeTextItem":"Tape","quantity":1}]', 'Select an available team for this request');
SELECT pg_temp.phase6c_expect_edit_error(
  '6c6c0000-0000-4000-8000-000000000101', current_setting('phase6c.request_id')::uuid,
  NULL, '6c6c0000-0000-4000-8000-000000000124',
  '[{"freeTextItem":"Tape","quantity":1}]', 'Select an available location for this request');
SELECT pg_temp.phase6c_expect_edit_error(
  '6c6c0000-0000-4000-8000-000000000101', current_setting('phase6c.request_id')::uuid, NULL, NULL,
  '[{"inventoryItemId":"6c6c0000-0000-4000-8000-000000000802","quantity":1}]',
  'A selected inventory item is unavailable for this organization', 'P0002');
SELECT pg_temp.phase6c_expect_edit_error(
  '6c6c0000-0000-4000-8000-000000000101', current_setting('phase6c.request_id')::uuid, NULL, NULL,
  '[{"productId":"6c6c0000-0000-4000-8000-000000000602","quantity":1}]',
  'A selected product is unavailable for this organization', 'P0002');
SELECT pg_temp.phase6c_expect_edit_error(
  '6c6c0000-0000-4000-8000-000000000101', current_setting('phase6c.request_id')::uuid, NULL, NULL,
  '[{"productId":"6c6c0000-0000-4000-8000-000000000601","catalogVendorProductId":"6c6c0000-0000-4000-8000-000000000401","quantity":1}]',
  'A local product cannot claim an unproven global catalog identity', '22023');
SELECT pg_temp.phase6c_expect_edit_error(
  '6c6c0000-0000-4000-8000-000000000101', current_setting('phase6c.request_id')::uuid, NULL, NULL,
  '[{"productId":"6c6c0000-0000-4000-8000-000000000601","freeTextItem":"Spoofed","quantity":1}]',
  'A custom request line cannot include structured identity IDs', '22023');
SELECT pg_temp.phase6c_expect_edit_error(
  '6c6c0000-0000-4000-8000-000000000101', current_setting('phase6c.request_id')::uuid, NULL, NULL,
  '[{"freeTextItem":"Valid first line","quantity":1},{"quantity":1}]',
  'Each line must contain a structured identity or one custom item', '22023');

DO $phase6c_failed_edits_atomic$
DECLARE
  _request_id uuid := current_setting('phase6c.request_id')::uuid;
BEGIN
  IF (SELECT count(*) FROM public.supply_request_items WHERE supply_request_id = _request_id) <> 4
     OR EXISTS (SELECT 1 FROM public.supply_requests WHERE id = _request_id AND notes = 'Must not persist')
     OR (SELECT count(*) FROM public.supply_request_updates WHERE supply_request_id = _request_id) <> 0 THEN
    -- Staff cannot read their requester_edited rows directly (no staff-visible note).
    RAISE EXCEPTION 'A rejected edit partially persisted or leaked audit rows to direct staff reads';
  END IF;
END
$phase6c_failed_edits_atomic$;

-- Later lifecycle statuses are locked with deterministic messages.
SELECT pg_temp.phase6c_expect_edit_error('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000901', NULL, NULL,
  '[{"freeTextItem":"Tape","quantity":1}]', 'This request has already entered review and can no longer be edited.', '55000');
SELECT pg_temp.phase6c_expect_edit_error('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000902', NULL, NULL,
  '[{"freeTextItem":"Tape","quantity":1}]', 'This request has already entered review and can no longer be edited.', '55000');
SELECT pg_temp.phase6c_expect_edit_error('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000903', NULL, NULL,
  '[{"freeTextItem":"Tape","quantity":1}]', 'This request has already entered review and can no longer be edited.', '55000');
SELECT pg_temp.phase6c_expect_edit_error('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000904', NULL, NULL,
  '[{"freeTextItem":"Tape","quantity":1}]', 'This request has already entered review and can no longer be edited.', '55000');
SELECT pg_temp.phase6c_expect_edit_error('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000905', NULL, NULL,
  '[{"freeTextItem":"Tape","quantity":1}]', 'This request has already entered review and can no longer be edited.', '55000');
SELECT pg_temp.phase6c_expect_edit_error('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000906', NULL, NULL,
  '[{"freeTextItem":"Tape","quantity":1}]', 'This request has been declined and can no longer be edited.', '55000');

DO $phase6c_locked_unchanged$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.supply_request_items
    WHERE supply_request_id BETWEEN '6c6c0000-0000-4000-8000-000000000901' AND '6c6c0000-0000-4000-8000-000000000906'
      AND free_text_item <> 'Locked line'
  ) OR EXISTS (
    SELECT 1 FROM public.supply_requests
    WHERE id BETWEEN '6c6c0000-0000-4000-8000-000000000901' AND '6c6c0000-0000-4000-8000-000000000906'
      AND notes NOT LIKE 'Locked %'
  ) THEN
    RAISE EXCEPTION 'A locked request was modified';
  END IF;
END
$phase6c_locked_unchanged$;

-- Staff cannot bypass the RPC: private helpers are not executable, and direct
-- request/line writes are still denied by grants and RLS.
DO $phase6c_no_bypass$
DECLARE
  _request_id uuid := current_setting('phase6c.request_id')::uuid;
  _changed integer;
BEGIN
  BEGIN
    PERFORM public.replace_supply_request_items(
      '6c6c0000-0000-4000-8000-000000000101', _request_id, '[{"freeTextItem":"Bypass","quantity":1}]'
    );
    RAISE EXCEPTION 'Private line helper was executable by staff';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.resolve_supply_request_context(
      '6c6c0000-0000-4000-8000-000000000101', auth.uid(), NULL, NULL
    );
    RAISE EXCEPTION 'Private context helper was executable by staff';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  UPDATE public.supply_requests SET notes = 'Direct bypass' WHERE id = _request_id;
  GET DIAGNOSTICS _changed = ROW_COUNT;
  IF _changed <> 0 THEN RAISE EXCEPTION 'Staff updated a request directly'; END IF;
  -- Depending on default grants this is either denied or filtered to zero rows by RLS.
  BEGIN
    DELETE FROM public.supply_request_items WHERE supply_request_id = _request_id;
    GET DIAGNOSTICS _changed = ROW_COUNT;
    IF _changed <> 0 THEN RAISE EXCEPTION 'Staff deleted request lines directly'; END IF;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO public.supply_request_updates (organization_id, supply_request_id, author_id, event_kind)
    VALUES ('6c6c0000-0000-4000-8000-000000000101', _request_id, auth.uid(), 'requester_edited');
    RAISE EXCEPTION 'Staff forged a requester edit event directly';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END
$phase6c_no_bypass$;

-- Another member's request is indistinguishable from a missing one.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c6c0000-0000-4000-8000-000000000003', true);
SELECT pg_temp.phase6c_expect_edit_error(
  '6c6c0000-0000-4000-8000-000000000101', current_setting('phase6c.request_id')::uuid, NULL, NULL,
  '[{"freeTextItem":"Hijack","quantity":1}]', 'Supply request not found', 'P0002');

-- Cross-organization callers are denied in either organization scope.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c6c0000-0000-4000-8000-000000000004', true);
SELECT pg_temp.phase6c_expect_edit_error(
  '6c6c0000-0000-4000-8000-000000000101', current_setting('phase6c.request_id')::uuid, NULL, NULL,
  '[{"freeTextItem":"Hijack","quantity":1}]', 'Not a member of this organization', '42501');
SELECT pg_temp.phase6c_expect_edit_error(
  '6c6c0000-0000-4000-8000-000000000102', current_setting('phase6c.request_id')::uuid, NULL, NULL,
  '[{"freeTextItem":"Hijack","quantity":1}]', 'Supply request not found', 'P0002');

-- Admin queue reads the edited contents and the auditable edit events; no commitment
-- exists before approval.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c6c0000-0000-4000-8000-000000000001', true);
DO $phase6c_admin_view$
DECLARE
  _request_id uuid := current_setting('phase6c.request_id')::uuid;
BEGIN
  IF (SELECT count(*) FROM public.supply_request_items WHERE supply_request_id = _request_id) <> 4
     OR NOT EXISTS (
       SELECT 1 FROM public.supply_request_items
       WHERE supply_request_id = _request_id AND free_text_item = 'Knee sleeve'
     ) THEN
    RAISE EXCEPTION 'Admin cannot see edited request contents';
  END IF;
  IF (
    SELECT count(*) FROM public.supply_request_updates
    WHERE supply_request_id = _request_id
      AND event_kind = 'requester_edited'
      AND author_id = '6c6c0000-0000-4000-8000-000000000002'
  ) <> 3 THEN
    RAISE EXCEPTION 'Admin history does not contain all three requester edit events';
  END IF;
  IF EXISTS (SELECT 1 FROM public.supply_request_commitments WHERE supply_request_id = _request_id) THEN
    RAISE EXCEPTION 'A requester edit created a commitment';
  END IF;
END
$phase6c_admin_view$;

-- Review begins. A stale requester save afterwards fails without overwriting.
SELECT public.transition_supply_request(
  '6c6c0000-0000-4000-8000-000000000101', current_setting('phase6c.request_id')::uuid,
  'under_review', 'Admin-only reasoning', NULL
);
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c6c0000-0000-4000-8000-000000000002', true);
SELECT pg_temp.phase6c_expect_edit_error(
  '6c6c0000-0000-4000-8000-000000000101', current_setting('phase6c.request_id')::uuid, NULL, NULL,
  '[{"freeTextItem":"Stale save","quantity":9}]',
  'This request has already entered review and can no longer be edited.', '55000');

-- Internal admin notes never appear in the staff-safe projection or direct staff reads.
DO $phase6c_staff_privacy$
DECLARE
  _request_id uuid := current_setting('phase6c.request_id')::uuid;
BEGIN
  IF (SELECT count(*) FROM public.supply_request_items WHERE supply_request_id = _request_id) <> 4
     OR EXISTS (SELECT 1 FROM public.supply_request_items WHERE supply_request_id = _request_id AND free_text_item = 'Stale save') THEN
    RAISE EXCEPTION 'A stale save overwrote the reviewed request';
  END IF;
  IF EXISTS (SELECT 1 FROM public.supply_request_updates WHERE internal_note IS NOT NULL) THEN
    RAISE EXCEPTION 'Staff can read an internal admin note';
  END IF;
  IF (
    SELECT count(*) FROM public.list_staff_supply_request_updates(
      '6c6c0000-0000-4000-8000-000000000101', ARRAY[_request_id]
    )
  ) <> 4 THEN
    RAISE EXCEPTION 'Staff history should contain three edits and the review transition';
  END IF;
END
$phase6c_staff_privacy$;

-- Approval keeps 6A.2 behavior and snapshots the edited (current) lines exactly once.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c6c0000-0000-4000-8000-000000000001', true);
SELECT public.decide_supply_request(
  '6c6c0000-0000-4000-8000-000000000101', current_setting('phase6c.request_id')::uuid, 'approved',
  _expected_updated_at => (
    SELECT updated_at FROM public.supply_requests
    WHERE id = current_setting('phase6c.request_id')::uuid
  )
);
DO $phase6c_commitment$
DECLARE
  _request_id uuid := current_setting('phase6c.request_id')::uuid;
BEGIN
  IF (SELECT count(*) FROM public.supply_request_commitments WHERE supply_request_id = _request_id) <> 1
     OR NOT EXISTS (
       SELECT 1 FROM public.supply_request_commitments
       WHERE supply_request_id = _request_id
         AND status = 'active'
         AND total_item_count = 4
         AND priced_item_count = 2
         AND pricing_status = 'partially_priced'
         AND amount = 55
     )
     OR (
       SELECT count(*) FROM public.supply_request_commitment_items item
       JOIN public.supply_request_commitments commitment ON commitment.id = item.commitment_id
       WHERE commitment.supply_request_id = _request_id
     ) <> 4 THEN
    RAISE EXCEPTION 'Approval commitment after requester edits is incorrect: %', (
      SELECT row_to_json(commitment) FROM public.supply_request_commitments commitment
      WHERE commitment.supply_request_id = _request_id
    );
  END IF;
END
$phase6c_commitment$;

SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c6c0000-0000-4000-8000-000000000002', true);
SELECT pg_temp.phase6c_expect_edit_error(
  '6c6c0000-0000-4000-8000-000000000101', current_setting('phase6c.request_id')::uuid, NULL, NULL,
  '[{"freeTextItem":"After approval","quantity":1}]',
  'This request has already entered review and can no longer be edited.', '55000');

-- Deactivated requesters lose edit access even to their own submitted request.
RESET ROLE;
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c6c0000-0000-4000-8000-000000000001', true);
INSERT INTO public.supply_requests (
  id, organization_id, requested_by, request_type, team_id, location_id, status
)
VALUES ('6c6c0000-0000-4000-8000-000000000907', '6c6c0000-0000-4000-8000-000000000101',
  '6c6c0000-0000-4000-8000-000000000002', 'new_item',
  '6c6c0000-0000-4000-8000-000000000111', '6c6c0000-0000-4000-8000-000000000121', 'submitted');
INSERT INTO public.supply_request_items (organization_id, supply_request_id, free_text_item, quantity)
VALUES ('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000907', 'Original', 1);
UPDATE public.organization_memberships SET active = false
WHERE id = '6c6c0000-0000-4000-8000-000000000132';
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c6c0000-0000-4000-8000-000000000002', true);
SELECT pg_temp.phase6c_expect_edit_error(
  '6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000907', NULL, NULL,
  '[{"freeTextItem":"After deactivation","quantity":1}]', 'Not a member of this organization', '42501');

-- Requester edit events cannot carry lifecycle state or admin notes.
RESET ROLE;
DO $phase6c_event_constraint$
BEGIN
  BEGIN
    INSERT INTO public.supply_request_updates (
      organization_id, supply_request_id, author_id, event_kind, internal_note
    )
    VALUES ('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000907',
      '6c6c0000-0000-4000-8000-000000000002', 'requester_edited', 'Smuggled admin note');
    RAISE EXCEPTION 'Requester edit event accepted an internal note';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.supply_request_updates (
      organization_id, supply_request_id, author_id, event_kind, status_from, status_to
    )
    VALUES ('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000907',
      '6c6c0000-0000-4000-8000-000000000002', 'requester_edited', 'submitted', 'submitted');
    RAISE EXCEPTION 'Requester edit event accepted a lifecycle transition';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END
$phase6c_event_constraint$;

-- ---------------------------------------------------------------------------
-- Admin decisions are version-checked (optimistic concurrency).
--
-- now() is constant inside this rollback-only transaction, so every UPDATE here
-- stamps the same updated_at. Fixtures therefore start with distinct backdated
-- versions standing in for "the version the admin screen loaded earlier"; the
-- first write to each request then moves it to now(). Versions round-trip through
-- text exactly as the admin UI's JSON string does.
-- ---------------------------------------------------------------------------
INSERT INTO public.supply_requests (
  id, organization_id, requested_by, request_type, team_id, location_id, status, updated_at
)
SELECT
  fixture.id::uuid, '6c6c0000-0000-4000-8000-000000000101',
  '6c6c0000-0000-4000-8000-000000000003', 'reorder',
  '6c6c0000-0000-4000-8000-000000000111', '6c6c0000-0000-4000-8000-000000000121',
  fixture.status::public.supply_request_status, now() - fixture.age::interval
FROM (VALUES
  ('6c6c0000-0000-4000-8000-000000000911', 'submitted', '10 minutes 0.000123 seconds'),
  ('6c6c0000-0000-4000-8000-000000000912', 'submitted', '9 minutes'),
  ('6c6c0000-0000-4000-8000-000000000913', 'submitted', '8 minutes'),
  ('6c6c0000-0000-4000-8000-000000000914', 'submitted', '7 minutes'),
  ('6c6c0000-0000-4000-8000-000000000915', 'submitted', '6 minutes')
) AS fixture(id, status, age);
INSERT INTO public.supply_request_items (
  organization_id, supply_request_id, catalog_vendor_product_id, free_text_item, quantity
)
VALUES
  -- 911: the reviewed version is "Item A (cold pack) x2, Item B x1".
  ('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000911', '6c6c0000-0000-4000-8000-000000000402', NULL, 2),
  ('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000911', NULL, 'Item B', 1),
  ('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000912', NULL, 'Decline me', 1),
  ('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000913', NULL, 'Request X', 1),
  ('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000914', NULL, 'Request Y', 1),
  ('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000915', NULL, 'Review started', 1);

-- Runs as the caller's role; asserts the decision is rejected with the exact message
-- and SQLSTATE, and that nothing about the request changed.
CREATE FUNCTION pg_temp.phase6c_expect_decision_error(
  _organization_id uuid,
  _request_id uuid,
  _decision public.supply_request_status,
  _expected_version text,
  _expected_message text,
  _expected_state text
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  _status_before public.supply_request_status;
  _version_before timestamptz;
  _updates_before bigint;
  _commitments_before bigint;
BEGIN
  SELECT status, updated_at INTO _status_before, _version_before
  FROM public.supply_requests WHERE id = _request_id;
  SELECT count(*) INTO _updates_before FROM public.supply_request_updates WHERE supply_request_id = _request_id;
  SELECT count(*) INTO _commitments_before FROM public.supply_request_commitments WHERE supply_request_id = _request_id;
  BEGIN
    PERFORM public.decide_supply_request(
      _organization_id, _request_id, _decision,
      CASE WHEN _decision = 'denied' THEN 'Declined from a stale screen' END,
      'Stale internal note',
      _expected_updated_at => _expected_version::timestamptz
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> _expected_message OR SQLSTATE <> _expected_state THEN
      RAISE EXCEPTION 'Expected "%" (%), got "%" (%)', _expected_message, _expected_state, SQLERRM, SQLSTATE;
    END IF;
    IF _status_before IS NOT NULL AND (
      (SELECT status FROM public.supply_requests WHERE id = _request_id) IS DISTINCT FROM _status_before
      OR (SELECT updated_at FROM public.supply_requests WHERE id = _request_id) IS DISTINCT FROM _version_before
      OR (SELECT count(*) FROM public.supply_request_updates WHERE supply_request_id = _request_id) <> _updates_before
      OR (SELECT count(*) FROM public.supply_request_commitments WHERE supply_request_id = _request_id) <> _commitments_before
    ) THEN
      RAISE EXCEPTION 'A rejected decision wrote state for request %', _request_id;
    END IF;
    RETURN;
  END;
  RAISE EXCEPTION 'Decision unexpectedly succeeded; expected "%"', _expected_message;
END;
$$;

SET LOCAL ROLE authenticated;

-- The admin screen loads every request's current version.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c6c0000-0000-4000-8000-000000000001', true);
SELECT pg_catalog.set_config('phase6c.v911_loaded', (SELECT updated_at::text FROM public.supply_requests WHERE id = '6c6c0000-0000-4000-8000-000000000911'), true);
SELECT pg_catalog.set_config('phase6c.v912_loaded', (SELECT updated_at::text FROM public.supply_requests WHERE id = '6c6c0000-0000-4000-8000-000000000912'), true);
SELECT pg_catalog.set_config('phase6c.v913_loaded', (SELECT updated_at::text FROM public.supply_requests WHERE id = '6c6c0000-0000-4000-8000-000000000913'), true);
SELECT pg_catalog.set_config('phase6c.v914_loaded', (SELECT updated_at::text FROM public.supply_requests WHERE id = '6c6c0000-0000-4000-8000-000000000914'), true);
SELECT pg_catalog.set_config('phase6c.v915_loaded', (SELECT updated_at::text FROM public.supply_requests WHERE id = '6c6c0000-0000-4000-8000-000000000915'), true);

-- Microsecond versions survive the text round trip exactly.
DO $phase6c_version_roundtrip$
BEGIN
  IF current_setting('phase6c.v911_loaded')::timestamptz IS DISTINCT FROM (
    SELECT updated_at FROM public.supply_requests WHERE id = '6c6c0000-0000-4000-8000-000000000911'
  ) THEN
    RAISE EXCEPTION 'Version text round trip lost precision';
  END IF;
END
$phase6c_version_roundtrip$;

-- Requester edits 911 after the admin loaded it: Item A x10, Item B removed.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c6c0000-0000-4000-8000-000000000003', true);
SELECT public.update_submitted_supply_request(
  '6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000911', NULL, NULL, NULL, NULL,
  '[{"catalogVendorProductId":"6c6c0000-0000-4000-8000-000000000402","quantity":10}]'
);
-- Requester edits 912 after the admin loaded it.
SELECT public.update_submitted_supply_request(
  '6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000912', NULL, NULL, NULL, NULL,
  '[{"freeTextItem":"Decline me - changed","quantity":3}]'
);

-- Stale approval and stale decline are rejected with no lifecycle, audit, or commitment write.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c6c0000-0000-4000-8000-000000000001', true);
SELECT pg_temp.phase6c_expect_decision_error(
  '6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000911', 'approved',
  current_setting('phase6c.v911_loaded'),
  'This request changed while you were reviewing it. Refresh the request and review the latest details before making a decision.',
  '40001');
SELECT pg_temp.phase6c_expect_decision_error(
  '6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000911', 'denied',
  current_setting('phase6c.v911_loaded'),
  'This request changed while you were reviewing it. Refresh the request and review the latest details before making a decision.',
  '40001');
SELECT pg_temp.phase6c_expect_decision_error(
  '6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000912', 'denied',
  current_setting('phase6c.v912_loaded'),
  'This request changed while you were reviewing it. Refresh the request and review the latest details before making a decision.',
  '40001');
-- A decision that names no version is treated as stale.
SELECT pg_temp.phase6c_expect_decision_error(
  '6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000913', 'approved',
  NULL,
  'This request changed while you were reviewing it. Refresh the request and review the latest details before making a decision.',
  '40001');
-- Another request's version cannot authorize this request.
SELECT pg_temp.phase6c_expect_decision_error(
  '6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000913', 'approved',
  current_setting('phase6c.v914_loaded'),
  'This request changed while you were reviewing it. Refresh the request and review the latest details before making a decision.',
  '40001');

DO $phase6c_stale_no_writes$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.supply_request_commitments
    WHERE supply_request_id IN ('6c6c0000-0000-4000-8000-000000000911', '6c6c0000-0000-4000-8000-000000000912', '6c6c0000-0000-4000-8000-000000000913')
  ) THEN
    RAISE EXCEPTION 'A stale decision created a commitment';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.supply_request_updates
    WHERE supply_request_id IN ('6c6c0000-0000-4000-8000-000000000911', '6c6c0000-0000-4000-8000-000000000912', '6c6c0000-0000-4000-8000-000000000913')
      AND (status_to IS NOT NULL OR internal_note IS NOT NULL OR staff_visible_note IS NOT NULL)
  ) THEN
    RAISE EXCEPTION 'A stale decision wrote an approval or decline audit event';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.supply_requests
    WHERE id IN ('6c6c0000-0000-4000-8000-000000000911', '6c6c0000-0000-4000-8000-000000000912', '6c6c0000-0000-4000-8000-000000000913')
      AND status <> 'submitted'
  ) THEN
    RAISE EXCEPTION 'A stale decision changed request status';
  END IF;
END
$phase6c_stale_no_writes$;

-- Cross-organization admins cannot decide this organization's request, even with the
-- request's real current version.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c6c0000-0000-4000-8000-000000000004', true);
SELECT pg_temp.phase6c_expect_decision_error(
  '6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000913', 'approved',
  current_setting('phase6c.v913_loaded'), 'Forbidden: administrator access required', '42501');
SELECT pg_temp.phase6c_expect_decision_error(
  '6c6c0000-0000-4000-8000-000000000102', '6c6c0000-0000-4000-8000-000000000913', 'approved',
  current_setting('phase6c.v913_loaded'), 'Supply request not found', 'P0002');

-- After reload, the admin decides the latest version normally.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c6c0000-0000-4000-8000-000000000001', true);
SELECT pg_catalog.set_config('phase6c.v911_reloaded', (SELECT updated_at::text FROM public.supply_requests WHERE id = '6c6c0000-0000-4000-8000-000000000911'), true);
DO $phase6c_reloaded_approval$
DECLARE
  _result jsonb;
  _approvals_before bigint;
BEGIN
  IF current_setting('phase6c.v911_reloaded') = current_setting('phase6c.v911_loaded') THEN
    RAISE EXCEPTION 'Requester edit did not advance the request version';
  END IF;
  _result := public.decide_supply_request(
    '6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000911', 'approved',
    'Approved after review', NULL,
    _expected_updated_at => current_setting('phase6c.v911_reloaded')::timestamptz
  );
  IF _result->>'status' <> 'approved' OR (_result->>'alreadyDecided')::boolean THEN
    RAISE EXCEPTION 'Reloaded approval failed: %', _result;
  END IF;

  -- 6A.2 snapshots exactly the latest reviewed line set, once.
  IF (SELECT count(*) FROM public.supply_request_commitments WHERE supply_request_id = '6c6c0000-0000-4000-8000-000000000911') <> 1
     OR NOT EXISTS (
       SELECT 1 FROM public.supply_request_commitments
       WHERE supply_request_id = '6c6c0000-0000-4000-8000-000000000911'
         AND status = 'active' AND amount = 250
         AND total_item_count = 1 AND priced_item_count = 1 AND pricing_status = 'fully_priced'
     )
     OR (
       SELECT count(*) FROM public.supply_request_commitment_items item
       JOIN public.supply_request_commitments commitment ON commitment.id = item.commitment_id
       WHERE commitment.supply_request_id = '6c6c0000-0000-4000-8000-000000000911'
         AND item.quantity_snapshot = 10 AND item.line_amount_snapshot = 250
     ) <> 1
     OR (
       SELECT count(*) FROM public.supply_request_commitment_items item
       JOIN public.supply_request_commitments commitment ON commitment.id = item.commitment_id
       WHERE commitment.supply_request_id = '6c6c0000-0000-4000-8000-000000000911'
     ) <> 1 THEN
    RAISE EXCEPTION 'Commitment did not snapshot the latest reviewed lines exactly once';
  END IF;
  IF (
    SELECT count(*) FROM public.supply_request_updates
    WHERE supply_request_id = '6c6c0000-0000-4000-8000-000000000911'
      AND ((status_from = 'submitted' AND status_to = 'under_review')
        OR (status_from = 'under_review' AND status_to = 'approved'))
  ) <> 2 THEN
    RAISE EXCEPTION 'Approval audit transitions are incorrect';
  END IF;

  -- Retry idempotency is unchanged, with either the stale or the reloaded version.
  SELECT count(*) INTO _approvals_before FROM public.supply_request_updates
  WHERE supply_request_id = '6c6c0000-0000-4000-8000-000000000911';
  _result := public.decide_supply_request(
    '6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000911', 'approved',
    _expected_updated_at => current_setting('phase6c.v911_reloaded')::timestamptz
  );
  IF NOT (_result->>'alreadyDecided')::boolean THEN RAISE EXCEPTION 'Retry was not idempotent: %', _result; END IF;
  _result := public.decide_supply_request(
    '6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000911', 'approved',
    _expected_updated_at => current_setting('phase6c.v911_loaded')::timestamptz
  );
  IF NOT (_result->>'alreadyDecided')::boolean THEN RAISE EXCEPTION 'Stale-version retry was not idempotent: %', _result; END IF;
  IF (SELECT count(*) FROM public.supply_request_updates WHERE supply_request_id = '6c6c0000-0000-4000-8000-000000000911') <> _approvals_before
     OR (SELECT count(*) FROM public.supply_request_commitments WHERE supply_request_id = '6c6c0000-0000-4000-8000-000000000911') <> 1 THEN
    RAISE EXCEPTION 'A decision retry added audit rows or commitments';
  END IF;
END
$phase6c_reloaded_approval$;

-- The opposite decision after approval keeps its existing terminal-state error.
SELECT pg_temp.phase6c_expect_decision_error(
  '6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000911', 'denied',
  current_setting('phase6c.v911_reloaded'),
  'This request has already been decided. Refresh the inbox.', '22023');

-- Decline with the matching (reloaded) version succeeds and creates no commitment.
DO $phase6c_reloaded_decline$
DECLARE
  _result jsonb;
BEGIN
  _result := public.decide_supply_request(
    '6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000912', 'denied',
    'Already in storage', 'Checked shelf',
    _expected_updated_at => (SELECT updated_at FROM public.supply_requests WHERE id = '6c6c0000-0000-4000-8000-000000000912')
  );
  IF _result->>'status' <> 'denied'
     OR (SELECT count(*) FROM public.supply_request_updates
         WHERE supply_request_id = '6c6c0000-0000-4000-8000-000000000912' AND status_to = 'denied') <> 1
     OR EXISTS (SELECT 1 FROM public.supply_request_commitments WHERE supply_request_id = '6c6c0000-0000-4000-8000-000000000912') THEN
    RAISE EXCEPTION 'Matching-version decline is incorrect: %', _result;
  END IF;
END
$phase6c_reloaded_decline$;

-- An unedited request decided with its own loaded version succeeds (approve path).
DO $phase6c_matching_approval$
DECLARE
  _result jsonb;
BEGIN
  _result := public.decide_supply_request(
    '6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000913', 'approved',
    _expected_updated_at => current_setting('phase6c.v913_loaded')::timestamptz
  );
  IF _result->>'status' <> 'approved'
     OR (SELECT count(*) FROM public.supply_request_commitments WHERE supply_request_id = '6c6c0000-0000-4000-8000-000000000913') <> 1 THEN
    RAISE EXCEPTION 'Matching-version approval is incorrect: %', _result;
  END IF;
END
$phase6c_matching_approval$;

-- Review starting (under_review) advances the version too: a decision prepared on a
-- screen loaded before review began must be re-made from the refreshed screen.
SELECT public.transition_supply_request(
  '6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000915', 'under_review'
);
SELECT pg_temp.phase6c_expect_decision_error(
  '6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000915', 'approved',
  current_setting('phase6c.v915_loaded'),
  'This request changed while you were reviewing it. Refresh the request and review the latest details before making a decision.',
  '40001');
DO $phase6c_under_review_reloaded$
DECLARE
  _result jsonb;
BEGIN
  _result := public.decide_supply_request(
    '6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000915', 'approved',
    _expected_updated_at => (SELECT updated_at FROM public.supply_requests WHERE id = '6c6c0000-0000-4000-8000-000000000915')
  );
  IF _result->>'status' <> 'approved'
     OR (SELECT count(*) FROM public.supply_request_updates
         WHERE supply_request_id = '6c6c0000-0000-4000-8000-000000000915' AND status_to = 'approved') <> 1 THEN
    RAISE EXCEPTION 'Under-review approval after reload is incorrect: %', _result;
  END IF;
END
$phase6c_under_review_reloaded$;

RESET ROLE;

-- ---------------------------------------------------------------------------
-- decide_supply_request is the exclusive approve/deny path for pending requests.
-- ---------------------------------------------------------------------------
INSERT INTO public.supply_requests (
  id, organization_id, requested_by, request_type, team_id, location_id, status, updated_at
)
VALUES ('6c6c0000-0000-4000-8000-000000000916', '6c6c0000-0000-4000-8000-000000000101',
  '6c6c0000-0000-4000-8000-000000000003', 'reorder',
  '6c6c0000-0000-4000-8000-000000000111', '6c6c0000-0000-4000-8000-000000000121',
  'submitted', now() - interval '5 minutes');
INSERT INTO public.supply_request_items (organization_id, supply_request_id, free_text_item, quantity)
VALUES ('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000916', 'Pending decision', 1);

-- Runs as the caller's role; asserts a transition is rejected with the exact message
-- and SQLSTATE and leaves the request, its audit trail, and commitments unchanged.
CREATE FUNCTION pg_temp.phase6c_expect_transition_error(
  _organization_id uuid,
  _request_id uuid,
  _status public.supply_request_status,
  _expected_message text,
  _expected_state text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  _status_before public.supply_request_status;
  _updates_before bigint;
  _commitment_before text;
BEGIN
  SELECT status INTO _status_before FROM public.supply_requests WHERE id = _request_id;
  SELECT count(*) INTO _updates_before FROM public.supply_request_updates WHERE supply_request_id = _request_id;
  SELECT coalesce(string_agg(status, ','), '') INTO _commitment_before
  FROM public.supply_request_commitments WHERE supply_request_id = _request_id;
  BEGIN
    PERFORM public.transition_supply_request(
      _organization_id, _request_id, _status, 'Bypass attempt', 'Bypass attempt'
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> _expected_message OR (_expected_state IS NOT NULL AND SQLSTATE <> _expected_state) THEN
      RAISE EXCEPTION 'Expected "%" (%), got "%" (%)',
        _expected_message, coalesce(_expected_state, 'any'), SQLERRM, SQLSTATE;
    END IF;
    IF _status_before IS NOT NULL AND (
      (SELECT status FROM public.supply_requests WHERE id = _request_id) IS DISTINCT FROM _status_before
      OR (SELECT count(*) FROM public.supply_request_updates WHERE supply_request_id = _request_id) <> _updates_before
      OR (SELECT coalesce(string_agg(status, ','), '') FROM public.supply_request_commitments WHERE supply_request_id = _request_id) <> _commitment_before
    ) THEN
      RAISE EXCEPTION 'A rejected transition wrote state for request %', _request_id;
    END IF;
    RETURN;
  END;
  RAISE EXCEPTION 'Transition to % unexpectedly succeeded; expected "%"', _status, _expected_message;
END;
$$;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c6c0000-0000-4000-8000-000000000001', true);

-- Direct decision transitions are refused for submitted and under_review requests.
SELECT pg_temp.phase6c_expect_transition_error('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000916', 'approved',
  'Approve or decline this request through the request decision workflow.', '42501');
SELECT pg_temp.phase6c_expect_transition_error('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000916', 'denied',
  'Approve or decline this request through the request decision workflow.', '42501');
-- Starting review is still an ordinary operational transition.
SELECT public.transition_supply_request(
  '6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000914', 'under_review'
);
SELECT pg_temp.phase6c_expect_transition_error('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000914', 'approved',
  'Approve or decline this request through the request decision workflow.', '42501');
SELECT pg_temp.phase6c_expect_transition_error('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000914', 'denied',
  'Approve or decline this request through the request decision workflow.', '42501');

-- The private transition body cannot be called by API clients.
DO $phase6c_private_transition$
BEGIN
  BEGIN
    PERFORM public.apply_supply_request_transition(
      '6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000914', 'approved'
    );
    RAISE EXCEPTION 'Private transition helper was executable by an admin client';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END
$phase6c_private_transition$;

-- Direct table writes cannot set or change status, for admins or staff.
DO $phase6c_direct_status_write$
DECLARE
  _changed integer;
BEGIN
  BEGIN
    UPDATE public.supply_requests SET status = 'approved'
    WHERE id = '6c6c0000-0000-4000-8000-000000000914';
    RAISE EXCEPTION 'Admin direct status update succeeded';
  EXCEPTION WHEN insufficient_privilege THEN
    IF SQLERRM <> 'Request status can only change through the request lifecycle workflow' THEN RAISE; END IF;
  END;
  BEGIN
    UPDATE public.supply_requests SET status = 'denied'
    WHERE id = '6c6c0000-0000-4000-8000-000000000916';
    RAISE EXCEPTION 'Admin direct denial succeeded';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  -- Non-lifecycle admin edits keep their existing behavior.
  UPDATE public.supply_requests SET assigned_to = '6c6c0000-0000-4000-8000-000000000001'
  WHERE id = '6c6c0000-0000-4000-8000-000000000916';
  GET DIAGNOSTICS _changed = ROW_COUNT;
  IF _changed <> 1 THEN RAISE EXCEPTION 'Admin non-lifecycle update regressed'; END IF;
  IF (SELECT status FROM public.supply_requests WHERE id = '6c6c0000-0000-4000-8000-000000000914') <> 'under_review'
     OR (SELECT status FROM public.supply_requests WHERE id = '6c6c0000-0000-4000-8000-000000000916') <> 'submitted' THEN
    RAISE EXCEPTION 'A direct write changed request status';
  END IF;
END
$phase6c_direct_status_write$;

SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c6c0000-0000-4000-8000-000000000003', true);
DO $phase6c_staff_direct_writes$
DECLARE
  _changed integer;
BEGIN
  BEGIN
    INSERT INTO public.supply_requests (organization_id, requested_by, request_type, team_id, location_id, status)
    VALUES ('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000003', 'reorder',
      '6c6c0000-0000-4000-8000-000000000111', '6c6c0000-0000-4000-8000-000000000121', 'approved');
    RAISE EXCEPTION 'Staff inserted an already-approved request';
  EXCEPTION WHEN insufficient_privilege THEN
    IF SQLERRM <> 'New requests must start as submitted' THEN RAISE; END IF;
  END;
  UPDATE public.supply_requests SET status = 'approved'
  WHERE id = '6c6c0000-0000-4000-8000-000000000916';
  GET DIAGNOSTICS _changed = ROW_COUNT;
  IF _changed <> 0 THEN RAISE EXCEPTION 'Staff updated request status directly'; END IF;
END
$phase6c_staff_direct_writes$;

-- Staff and cross-organization callers gain no transition or decision authority.
SELECT pg_temp.phase6c_expect_transition_error('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000914', 'approved',
  'Forbidden: administrator access required');
SELECT pg_temp.phase6c_expect_transition_error('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000911', 'ordered',
  'Forbidden: administrator access required');
SELECT pg_temp.phase6c_expect_decision_error(
  '6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000914', 'approved',
  (SELECT updated_at::text FROM public.supply_requests WHERE id = '6c6c0000-0000-4000-8000-000000000914'),
  'Forbidden: administrator access required', '42501');
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c6c0000-0000-4000-8000-000000000004', true);
SELECT pg_temp.phase6c_expect_transition_error('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000911', 'ordered',
  'Forbidden: administrator access required');
SELECT pg_temp.phase6c_expect_transition_error('6c6c0000-0000-4000-8000-000000000102', '6c6c0000-0000-4000-8000-000000000911', 'ordered',
  'Supply request not found');

-- The canonical path still decides both pending states with a matching version.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c6c0000-0000-4000-8000-000000000001', true);
DO $phase6c_canonical_decisions$
DECLARE
  _result jsonb;
BEGIN
  _result := public.decide_supply_request(
    '6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000914', 'approved',
    _expected_updated_at => (SELECT updated_at FROM public.supply_requests WHERE id = '6c6c0000-0000-4000-8000-000000000914')
  );
  IF _result->>'status' <> 'approved'
     OR (SELECT count(*) FROM public.supply_request_commitments WHERE supply_request_id = '6c6c0000-0000-4000-8000-000000000914' AND status = 'active') <> 1 THEN
    RAISE EXCEPTION 'Canonical approval from under_review failed: %', _result;
  END IF;
  _result := public.decide_supply_request(
    '6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000916', 'denied',
    'Not needed', NULL,
    _expected_updated_at => (SELECT updated_at FROM public.supply_requests WHERE id = '6c6c0000-0000-4000-8000-000000000916')
  );
  IF _result->>'status' <> 'denied'
     OR EXISTS (SELECT 1 FROM public.supply_request_commitments WHERE supply_request_id = '6c6c0000-0000-4000-8000-000000000916')
     OR (SELECT count(*) FROM public.supply_request_updates
         WHERE supply_request_id = '6c6c0000-0000-4000-8000-000000000916'
           AND status_from = 'submitted' AND status_to = 'denied' AND staff_visible_note = 'Not needed') <> 1 THEN
    RAISE EXCEPTION 'Canonical decline from submitted failed: %', _result;
  END IF;
END
$phase6c_canonical_decisions$;

-- Operational steps after a decision still run through transition_supply_request.
SELECT public.transition_supply_request('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000911', 'ordered');
SELECT public.transition_supply_request('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000911', 'received');
SELECT public.transition_supply_request('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000911', 'completed');
-- Denial after approval (a cancellation of an approved request) keeps 6A.2 release semantics.
SELECT public.transition_supply_request('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000913', 'denied', NULL, 'No longer needed');
DO $phase6c_operational_transitions$
BEGIN
  IF (SELECT status FROM public.supply_requests WHERE id = '6c6c0000-0000-4000-8000-000000000911') <> 'completed'
     OR (SELECT ordered_at IS NULL OR received_at IS NULL FROM public.supply_requests WHERE id = '6c6c0000-0000-4000-8000-000000000911')
     OR (SELECT count(*) FROM public.supply_request_updates
         WHERE supply_request_id = '6c6c0000-0000-4000-8000-000000000911'
           AND status_to IN ('ordered', 'received', 'completed')) <> 3
     OR (SELECT status FROM public.supply_request_commitments WHERE supply_request_id = '6c6c0000-0000-4000-8000-000000000911') <> 'active'
     OR (SELECT count(*) FROM public.supply_request_commitments WHERE supply_request_id = '6c6c0000-0000-4000-8000-000000000911') <> 1 THEN
    RAISE EXCEPTION 'approved -> ordered -> received -> completed regressed';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.supply_request_commitments
    WHERE supply_request_id = '6c6c0000-0000-4000-8000-000000000913'
      AND status = 'released' AND release_kind = 'denied'
  ) OR (SELECT status FROM public.supply_requests WHERE id = '6c6c0000-0000-4000-8000-000000000913') <> 'denied' THEN
    RAISE EXCEPTION 'Denial after approval no longer releases its commitment';
  END IF;
END
$phase6c_operational_transitions$;

-- Backward, skipped, and terminal transitions remain invalid.
SELECT pg_temp.phase6c_expect_transition_error('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000915', 'received',
  'Invalid supply request transition: approved to received');
SELECT pg_temp.phase6c_expect_transition_error('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000915', 'submitted',
  'Invalid supply request transition: approved to submitted');
SELECT pg_temp.phase6c_expect_transition_error('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000915', 'under_review',
  'Invalid supply request transition: approved to under_review');
SELECT pg_temp.phase6c_expect_transition_error('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000911', 'ordered',
  'Invalid supply request transition: completed to ordered');
SELECT pg_temp.phase6c_expect_transition_error('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000911', 'denied',
  'Invalid supply request transition: completed to denied');
SELECT pg_temp.phase6c_expect_transition_error('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000916', 'approved',
  'Invalid supply request transition: denied to approved');
SELECT pg_temp.phase6c_expect_transition_error('6c6c0000-0000-4000-8000-000000000101', '6c6c0000-0000-4000-8000-000000000916', 'submitted',
  'Invalid supply request transition: denied to submitted');

RESET ROLE;

SELECT 71 AS checks_passed, 0 AS checks_failed;

ROLLBACK;
