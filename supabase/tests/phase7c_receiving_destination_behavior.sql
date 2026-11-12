-- Phase 7C rollback-only behavioral verification: receiving destinations. Every canonical
-- receipt records exactly one destination (an active inventory location of the organization,
-- Unassigned included) in one immutable supply_request_receipts row; receiving changes no
-- inventory, invoice, commitment or notification; the generic transition never receives.
-- Run against a disposable database after every migration through
-- 20261112140000_phase7c_receiving_destination.sql. Every fixture is rolled back.
-- Real-session concurrency is covered by supabase/tests/phase7c_race_check.sh.

BEGIN;

DO $phase7c_fixture_guard$
BEGIN
  IF EXISTS (SELECT 1 FROM auth.users
             WHERE id BETWEEN '7cd00000-0000-4000-8000-000000000001'::uuid AND '7cd00000-0000-4000-8000-000000000099'::uuid)
     OR EXISTS (SELECT 1 FROM public.organizations
             WHERE id BETWEEN '7cd00000-0000-4000-8000-000000000101'::uuid AND '7cd00000-0000-4000-8000-000000000199'::uuid) THEN
    RAISE EXCEPTION 'Phase 7C rollback-test fixture IDs already exist';
  END IF;
END
$phase7c_fixture_guard$;

CREATE FUNCTION pg_temp.assert(_condition boolean, _message text)
RETURNS void LANGUAGE plpgsql AS $$ BEGIN IF _condition IS NOT TRUE THEN RAISE EXCEPTION 'Check failed: %', _message; END IF; END; $$;
CREATE FUNCTION pg_temp.expect_error(_statement text, _expected text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE _statement;
  EXCEPTION WHEN OTHERS THEN
    IF position(_expected IN SQLERRM) = 0 THEN
      RAISE EXCEPTION 'Expected error containing "%", got "%" (%)', _expected, SQLERRM, SQLSTATE;
    END IF;
    RETURN;
  END;
  RAISE EXCEPTION 'Statement unexpectedly succeeded; expected "%": %', _expected, _statement;
END;
$$;
CREATE FUNCTION pg_temp.u(_n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('7cd00000-0000-4000-8000-0000000000' || lpad(_n::text, 2, '0'))::uuid $$;
CREATE FUNCTION pg_temp.o(_n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('7cd00000-0000-4000-8000-000000000' || (100 + _n)::text)::uuid $$;
CREATE FUNCTION pg_temp.l(_n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('7cd00000-0000-4000-8000-000000000' || (300 + _n)::text)::uuid $$;
CREATE FUNCTION pg_temp.v(_name text) RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('phase7c.' || _name, true), '')::uuid $$;
CREATE FUNCTION pg_temp.keep(_name text, _value uuid) RETURNS void LANGUAGE sql AS $$ SELECT set_config('phase7c.' || _name, _value::text, true) $$;
CREATE FUNCTION pg_temp.as_user(_n integer) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub', pg_temp.u(_n)::text, true) $$;
-- Reads as the table owner.
CREATE FUNCTION pg_temp.unassigned(_org uuid) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM public.inventory_locations WHERE organization_id = _org AND kind = 'unassigned' $$;
CREATE FUNCTION pg_temp.status(_request uuid) RETURNS public.supply_request_status LANGUAGE sql SECURITY DEFINER AS $$
  SELECT status FROM public.supply_requests WHERE id = _request $$;
CREATE FUNCTION pg_temp.version(_request uuid) RETURNS timestamptz LANGUAGE sql SECURITY DEFINER AS $$
  SELECT updated_at FROM public.supply_requests WHERE id = _request $$;
CREATE FUNCTION pg_temp.receipt(_request uuid) RETURNS public.supply_request_receipts LANGUAGE sql SECURITY DEFINER AS $$
  SELECT * FROM public.supply_request_receipts WHERE supply_request_id = _request $$;
CREATE FUNCTION pg_temp.receipts(_request uuid) RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$
  SELECT count(*) FROM public.supply_request_receipts WHERE supply_request_id = _request $$;
CREATE FUNCTION pg_temp.trail(_request uuid) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT string_agg(concat(status_to, ':', coalesce(compound_action, '-')), ' ' ORDER BY created_at, status_to, id)
  FROM public.supply_request_updates WHERE supply_request_id = _request AND status_to IS NOT NULL $$;
CREATE FUNCTION pg_temp.received_row(_request uuid) RETURNS public.supply_request_updates LANGUAGE sql SECURITY DEFINER AS $$
  SELECT * FROM public.supply_request_updates WHERE supply_request_id = _request AND status_to = 'received' $$;
CREATE FUNCTION pg_temp.events(_request uuid) RETURNS text[] LANGUAGE sql SECURITY DEFINER AS $$
  SELECT coalesce(array_agg(event_type ORDER BY event_type), ARRAY[]::text[]) FROM public.notification_events WHERE entity_id = _request $$;
-- Every inventory and invoice row of the fixture organizations, hashed.
CREATE FUNCTION pg_temp.stock_hash() RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT md5(concat_ws('|',
    (SELECT string_agg(to_jsonb(i)::text, ',' ORDER BY i.id) FROM public.inventory_items i WHERE i.organization_id IN (pg_temp.o(1), pg_temp.o(2))),
    (SELECT string_agg(to_jsonb(b)::text, ',' ORDER BY b.inventory_item_id, b.inventory_location_id) FROM public.inventory_location_balances b WHERE b.organization_id IN (pg_temp.o(1), pg_temp.o(2))),
    (SELECT string_agg(to_jsonb(a)::text, ',' ORDER BY a.id) FROM public.inventory_adjustments a WHERE a.organization_id IN (pg_temp.o(1), pg_temp.o(2))),
    (SELECT string_agg(to_jsonb(t)::text, ',' ORDER BY t.id) FROM public.inventory_transfers t WHERE t.organization_id IN (pg_temp.o(1), pg_temp.o(2))),
    (SELECT string_agg(to_jsonb(v)::text, ',' ORDER BY v.id) FROM public.invoices v WHERE v.organization_id IN (pg_temp.o(1), pg_temp.o(2)))
  )) $$;
-- Commitments (created by approvals, never changed by receiving) are hashed separately, per request.
CREATE FUNCTION pg_temp.commitment_hash(_request uuid) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT md5(coalesce(string_agg(to_jsonb(c)::text, ',' ORDER BY c.id), '')) FROM public.supply_request_commitments c WHERE c.supply_request_id = _request $$;
CREATE FUNCTION pg_temp.submit(_name text, _item text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE _id uuid;
BEGIN
  _id := public.submit_supply_request(pg_temp.o(1), 'reorder', NULL, NULL, NULL,
    jsonb_build_array(jsonb_build_object('freeTextItem', _item, 'quantity', 2)));
  PERFORM pg_temp.keep(_name, _id);
  RETURN _id;
END;
$$;
-- Approve and order (Detailed path) as the current admin.
CREATE FUNCTION pg_temp.order(_name text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM public.decide_supply_request(pg_temp.o(1), pg_temp.v(_name), 'approved', NULL, NULL, pg_temp.version(pg_temp.v(_name)));
  PERFORM public.transition_supply_request(pg_temp.o(1), pg_temp.v(_name), 'ordered');
END;
$$;

INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT pg_temp.u(n), 'authenticated', 'authenticated', 'phase7c-user-' || n || '@example.invalid', '', now(), '{}',
  jsonb_build_object('full_name', 'Phase 7C User ' || n), now(), now()
FROM generate_series(1, 8) n;
INSERT INTO public.organizations (id, name, created_by) VALUES
  (pg_temp.o(1), 'Phase 7C Athletics', pg_temp.u(1)),
  (pg_temp.o(2), 'Phase 7C Other', pg_temp.u(6));
INSERT INTO public.teams (id, organization_id, name, active) VALUES
  ('7cd00000-0000-4000-8000-000000000201', pg_temp.o(1), 'Phase 7C First Team', true);
-- The request location shares a name with an inventory location; it must never be used.
INSERT INTO public.locations (id, organization_id, name, active) VALUES
  ('7cd00000-0000-4000-8000-000000000211', pg_temp.o(1), 'First Team ATR', true);
-- Org 1: u1 owner, u2 admin, u3 staff (requester), u4 staff. Org 2: u6 owner, u7 staff.
INSERT INTO public.organization_memberships (organization_id, user_id, role, active, default_team_id, default_location_id) VALUES
  (pg_temp.o(1), pg_temp.u(1), 'owner', true, NULL, NULL),
  (pg_temp.o(1), pg_temp.u(2), 'admin', true, NULL, NULL),
  (pg_temp.o(1), pg_temp.u(3), 'staff', true, '7cd00000-0000-4000-8000-000000000201', '7cd00000-0000-4000-8000-000000000211'),
  (pg_temp.o(1), pg_temp.u(4), 'staff', true, '7cd00000-0000-4000-8000-000000000201', '7cd00000-0000-4000-8000-000000000211'),
  (pg_temp.o(2), pg_temp.u(6), 'owner', true, NULL, NULL),
  (pg_temp.o(2), pg_temp.u(7), 'staff', true, NULL, NULL);
-- Inventory locations: two active storage locations, one archived, and another organization's.
INSERT INTO public.inventory_locations (id, organization_id, name, kind, active) VALUES
  (pg_temp.l(1), pg_temp.o(1), 'First Team ATR', 'storage', true),
  (pg_temp.l(2), pg_temp.o(1), 'Academy ATR', 'storage', true),
  (pg_temp.l(3), pg_temp.o(1), 'Old Cage', 'storage', true),
  (pg_temp.l(4), pg_temp.o(2), 'West Room', 'storage', true);
UPDATE public.inventory_locations SET active = false WHERE id = pg_temp.l(3);
-- Stock exists in Unassigned (as invoice posting leaves it); receiving must never touch it.
INSERT INTO public.inventory_items (id, organization_id, name, unit, quantity, active)
VALUES ('7cd00000-0000-4000-8000-000000000401', pg_temp.o(1), 'Phase 7C Tape', 'roll', 0, true);
SELECT public.adjust_inventory_location_quantity(pg_temp.o(1), '7cd00000-0000-4000-8000-000000000401', pg_temp.unassigned(pg_temp.o(1)), 12, 'Correction')
FROM (SELECT set_config('request.jwt.claim.sub', pg_temp.u(1)::text, true)) s;

CREATE TEMP TABLE phase7c_stock ON COMMIT DROP AS SELECT pg_temp.stock_hash() AS hash;

-- ============================================================================================
-- 1. Structure and access
-- ============================================================================================
DO $phase7c_structure$
DECLARE
  _fn text;
BEGIN
  PERFORM pg_temp.assert((SELECT relrowsecurity FROM pg_class WHERE oid = 'public.supply_request_receipts'::regclass), 'RLS on receipts');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'supply_request_receipts'), 'no policies');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM information_schema.role_table_grants WHERE table_schema = 'public'
    AND table_name = 'supply_request_receipts'
    AND (grantee IN ('anon', 'authenticated', 'PUBLIC') OR (grantee = 'service_role' AND privilege_type <> 'SELECT'))),
    'no client grants; service_role SELECT only');
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'supply_request_receipts_immutable'), 'immutability trigger');
  FOREACH _fn IN ARRAY ARRAY[
    'public.apply_supply_request_receipt(uuid, uuid, uuid, text, text, text)',
    'public.guard_supply_request_receipt_immutable()'] LOOP
    PERFORM pg_temp.assert(NOT has_function_privilege('authenticated', _fn, 'EXECUTE')
      AND NOT has_function_privilege('anon', _fn, 'EXECUTE') AND NOT has_function_privilege('service_role', _fn, 'EXECUTE'), _fn || ' is private');
  END LOOP;
  FOREACH _fn IN ARRAY ARRAY[
    'public.list_receiving_destinations(uuid)',
    'public.list_supply_request_receipts(uuid, uuid[])',
    'public.receive_supply_request(uuid, uuid, text, text, uuid)',
    'public.receive_and_complete_supply_request(uuid, uuid, text, text, uuid)'] LOOP
    PERFORM pg_temp.assert(has_function_privilege('authenticated', _fn, 'EXECUTE')
      AND NOT has_function_privilege('anon', _fn, 'EXECUTE') AND NOT has_function_privilege('service_role', _fn, 'EXECUTE'),
      _fn || ' executable by authenticated only');
  END LOOP;
  FOREACH _fn IN ARRAY ARRAY[
    'public.apply_supply_request_receipt(uuid, uuid, uuid, text, text, text)',
    'public.list_receiving_destinations(uuid)',
    'public.list_supply_request_receipts(uuid, uuid[])',
    'public.receive_supply_request(uuid, uuid, text, text, uuid)',
    'public.receive_and_complete_supply_request(uuid, uuid, text, text, uuid)'] LOOP
    PERFORM pg_temp.assert((SELECT p.prosecdef AND p.proconfig::text LIKE '%search_path=pg_catalog, public, pg_temp%'
      FROM pg_proc p WHERE p.oid = _fn::regprocedure), _fn || ' security definer with pinned search_path');
  END LOOP;
  -- The old destination-less signatures are gone (no fallback).
  PERFORM pg_temp.assert(to_regprocedure('public.apply_supply_request_receipt(uuid, uuid, text, text)') IS NULL
    AND to_regprocedure('public.receive_supply_request(uuid, uuid, text, text)') IS NULL
    AND to_regprocedure('public.receive_and_complete_supply_request(uuid, uuid, text, text)') IS NULL, 'no destination-less signatures');
  -- Receiving touches no inventory function, and no inventory function knows about receipts.
  PERFORM pg_temp.assert(position('inventory_apply_balance_delta' IN pg_get_functiondef('public.apply_supply_request_receipt(uuid, uuid, uuid, text, text, text)'::regprocedure)) = 0
    AND position('apply_inventory_location_delta' IN pg_get_functiondef('public.apply_supply_request_receipt(uuid, uuid, uuid, text, text, text)'::regprocedure)) = 0
    AND position('inventory_transfers' IN pg_get_functiondef('public.apply_supply_request_receipt(uuid, uuid, uuid, text, text, text)'::regprocedure)) = 0,
    'the receipt path never mutates inventory');
  PERFORM pg_temp.assert(position('supply_request_receipts' IN pg_get_functiondef('public.post_reviewed_invoice(uuid, uuid)'::regprocedure)) = 0
    AND position('supply_request_receipts' IN pg_get_functiondef('public.move_inventory_stock(uuid, uuid, uuid, uuid, numeric, text)'::regprocedure)) = 0,
    'invoice posting and stock moves are untouched');
  -- Authority is is_org_admin, never a literal role.
  FOREACH _fn IN ARRAY ARRAY['public.list_receiving_destinations(uuid)', 'public.receive_supply_request(uuid, uuid, text, text, uuid)',
                             'public.receive_and_complete_supply_request(uuid, uuid, text, text, uuid)'] LOOP
    PERFORM pg_temp.assert(position('is_org_admin' IN pg_get_functiondef(_fn::regprocedure)) > 0
      AND position('''owner''' IN pg_get_functiondef(_fn::regprocedure)) = 0, _fn || ' uses is_org_admin');
  END LOOP;
END
$phase7c_structure$;

SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(1);
SELECT pg_temp.expect_error('SELECT count(*) FROM public.supply_request_receipts', 'permission denied');
SELECT pg_temp.expect_error($$INSERT INTO public.supply_request_receipts (organization_id, supply_request_id, inventory_location_id, destination_name_snapshot, destination_kind, received_at, supply_request_update_id)
  VALUES ('7cd00000-0000-4000-8000-000000000101', gen_random_uuid(), gen_random_uuid(), 'x', 'storage', now(), gen_random_uuid())$$, 'permission denied');
SELECT pg_temp.expect_error($$SELECT public.apply_supply_request_receipt('7cd00000-0000-4000-8000-000000000101', gen_random_uuid(), gen_random_uuid())$$, 'permission denied');
SET LOCAL ROLE anon;
SELECT pg_temp.expect_error($$SELECT * FROM public.list_receiving_destinations('7cd00000-0000-4000-8000-000000000101')$$, 'permission denied');
RESET ROLE;

-- ============================================================================================
-- 2. Destinations: active, same organization, Unassigned included; admins only
-- ============================================================================================
SET LOCAL ROLE authenticated;
DO $phase7c_destinations$
BEGIN
  PERFORM pg_temp.as_user(2);
  PERFORM pg_temp.assert((SELECT string_agg(name || ':' || kind, ', ' ORDER BY ordinality)
    FROM public.list_receiving_destinations(pg_temp.o(1)) WITH ORDINALITY)
    = 'Academy ATR:storage, First Team ATR:storage, Unassigned:unassigned', 'admin: active storage by name, then Unassigned');
  PERFORM pg_temp.as_user(1);
  PERFORM pg_temp.assert((SELECT count(*) FROM public.list_receiving_destinations(pg_temp.o(1))) = 3, 'owner reads the same');
  PERFORM pg_temp.as_user(3);
  PERFORM pg_temp.expect_error($$SELECT * FROM public.list_receiving_destinations('7cd00000-0000-4000-8000-000000000101')$$, 'administrator access required');
  PERFORM pg_temp.as_user(6);
  PERFORM pg_temp.expect_error($$SELECT * FROM public.list_receiving_destinations('7cd00000-0000-4000-8000-000000000101')$$, 'administrator access required');
  PERFORM pg_temp.assert((SELECT string_agg(name, ', ' ORDER BY name) FROM public.list_receiving_destinations(pg_temp.o(2))) = 'Unassigned, West Room',
    'another organization sees only its own');
  -- Admins still cannot read or move inventory directly.
  PERFORM pg_temp.as_user(2);
  PERFORM pg_temp.assert((SELECT count(*) FROM public.inventory_locations WHERE organization_id = pg_temp.o(1)) = 0, 'raw table still owner-only');
  PERFORM pg_temp.expect_error($$SELECT public.move_inventory_stock('7cd00000-0000-4000-8000-000000000101', '7cd00000-0000-4000-8000-000000000401',
    pg_temp.unassigned('7cd00000-0000-4000-8000-000000000101'), '7cd00000-0000-4000-8000-000000000301', 1, 'phase7c-admin-move')$$, 'owner access required');
END
$phase7c_destinations$;
RESET ROLE;

-- ============================================================================================
-- 3. Detailed: Mark Received records one receipt; validation; idempotency; immutability
-- ============================================================================================
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(3);
SELECT pg_temp.submit('detailed', 'Detailed delivery');
SELECT pg_temp.submit('bypass', 'Generic bypass attempt');
SELECT pg_temp.submit('freetext', 'Custom knee brace, left, size M');
SELECT pg_temp.as_user(2);
SELECT pg_temp.order('detailed');
SELECT pg_temp.order('bypass');
SELECT pg_temp.order('freetext');
DO $phase7c_detailed$
DECLARE
  _result jsonb;
BEGIN
  -- An app loaded before this release sends no destination.
  PERFORM pg_temp.expect_error($$SELECT public.receive_supply_request('7cd00000-0000-4000-8000-000000000101', pg_temp.v('detailed'))$$,
    'Refresh SportSpend and choose a receiving destination');
  PERFORM pg_temp.expect_error($$SELECT public.receive_supply_request('7cd00000-0000-4000-8000-000000000101', pg_temp.v('detailed'), NULL, NULL, gen_random_uuid())$$,
    'Choose a receiving destination of this organization');
  PERFORM pg_temp.expect_error($$SELECT public.receive_supply_request('7cd00000-0000-4000-8000-000000000101', pg_temp.v('detailed'), NULL, NULL, pg_temp.l(4))$$,
    'Choose a receiving destination of this organization');
  PERFORM pg_temp.expect_error($$SELECT public.receive_supply_request('7cd00000-0000-4000-8000-000000000101', pg_temp.v('detailed'), NULL, NULL, pg_temp.l(3))$$,
    'Old Cage is archived');
  -- Detailed offers Mark Received only: Receive & Complete is refused before anything is written.
  PERFORM pg_temp.expect_error($$SELECT public.receive_and_complete_supply_request('7cd00000-0000-4000-8000-000000000101', pg_temp.v('detailed'), NULL, NULL, pg_temp.l(1))$$,
    'Receive & Complete is not enabled');
  PERFORM pg_temp.assert(pg_temp.status(pg_temp.v('detailed')) = 'ordered' AND pg_temp.receipts(pg_temp.v('detailed')) = 0,
    'refused receipts wrote nothing');

  PERFORM set_config('phase7c.detailed_commitment', pg_temp.commitment_hash(pg_temp.v('detailed')), true);
  _result := public.receive_supply_request(pg_temp.o(1), pg_temp.v('detailed'), 'In the ATR fridge', 'Internal: box 1 of 1', pg_temp.l(1));
  PERFORM pg_temp.assert(_result ->> 'status' = 'received' AND NOT (_result ->> 'alreadyApplied')::boolean
    AND _result #>> '{receipt,destinationName}' = 'First Team ATR' AND _result #>> '{receipt,destinationKind}' = 'storage',
    'Mark Received with a destination: ' || _result::text);
  -- Retries: same destination or none = alreadyApplied; a different destination = refused.
  _result := public.receive_supply_request(pg_temp.o(1), pg_temp.v('detailed'), 'Again', NULL, pg_temp.l(1));
  PERFORM pg_temp.assert((_result ->> 'alreadyApplied')::boolean AND _result #>> '{receipt,destinationName}' = 'First Team ATR', 'same-destination retry');
  _result := public.receive_supply_request(pg_temp.o(1), pg_temp.v('detailed'));
  PERFORM pg_temp.assert((_result ->> 'alreadyApplied')::boolean, 'destination-less retry after receipt');
  PERFORM pg_temp.expect_error($$SELECT public.receive_supply_request('7cd00000-0000-4000-8000-000000000101', pg_temp.v('detailed'), NULL, NULL, pg_temp.l(2))$$,
    'already received to First Team ATR. A receiving destination cannot be changed');
  -- Complete Request asks for no destination and keeps the receipt.
  PERFORM public.transition_supply_request(pg_temp.o(1), pg_temp.v('detailed'), 'completed', NULL, 'Picked up');

  -- The generic transition can no longer receive.
  PERFORM pg_temp.expect_error($$SELECT public.transition_supply_request('7cd00000-0000-4000-8000-000000000101', pg_temp.v('bypass'), 'received')$$,
    'Use the receiving action to choose a receiving destination');
  PERFORM pg_temp.expect_error($$SELECT public.transition_supply_request('7cd00000-0000-4000-8000-000000000101', pg_temp.v('bypass'), 'received', 'Internal', 'Arrived')$$,
    'Use the receiving action to choose a receiving destination');

  -- Free text: received with an explicit Unassigned, no product or inventory created.
  _result := public.receive_supply_request(pg_temp.o(1), pg_temp.v('freetext'), NULL, NULL, pg_temp.unassigned(pg_temp.o(1)));
  PERFORM pg_temp.assert(_result #>> '{receipt,destinationName}' = 'Unassigned' AND _result #>> '{receipt,destinationKind}' = 'unassigned',
    'Unassigned is an explicit destination');
END
$phase7c_detailed$;
RESET ROLE;

DO $phase7c_detailed_checks$
DECLARE
  _receipt public.supply_request_receipts;
  _received public.supply_request_updates;
BEGIN
  _receipt := pg_temp.receipt(pg_temp.v('detailed'));
  _received := pg_temp.received_row(pg_temp.v('detailed'));
  PERFORM pg_temp.assert(pg_temp.receipts(pg_temp.v('detailed')) = 1, 'exactly one receipt');
  PERFORM pg_temp.assert(_receipt.organization_id = pg_temp.o(1) AND _receipt.inventory_location_id = pg_temp.l(1)
    AND _receipt.destination_name_snapshot = 'First Team ATR' AND _receipt.destination_kind = 'storage'
    AND _receipt.received_by = pg_temp.u(2) AND _receipt.compound_action IS NULL
    AND _receipt.supply_request_update_id = _received.id
    AND _receipt.received_at = (SELECT received_at FROM public.supply_requests WHERE id = pg_temp.v('detailed')),
    'receipt fields: destination, snapshots, actor, time, received row');
  PERFORM pg_temp.assert(_received.staff_visible_note = 'In the ATR fridge' AND _received.internal_note = 'Internal: box 1 of 1'
    AND (SELECT count(*) FROM public.supply_request_updates WHERE supply_request_id = pg_temp.v('detailed') AND status_to = 'received') = 1,
    'one received history row with its notes; retries added none');
  PERFORM pg_temp.assert(pg_temp.trail(pg_temp.v('detailed')) = 'under_review:- approved:- ordered:- received:- completed:-', 'Detailed canonical history');
  PERFORM pg_temp.assert(pg_temp.status(pg_temp.v('bypass')) = 'ordered' AND pg_temp.receipts(pg_temp.v('bypass')) = 0
    AND (SELECT count(*) FROM public.supply_request_updates WHERE supply_request_id = pg_temp.v('bypass') AND status_to = 'received') = 0,
    'generic bypass wrote nothing');
  PERFORM pg_temp.assert((SELECT count(*) FROM public.inventory_items WHERE organization_id = pg_temp.o(1)) = 1, 'free text created no inventory item');
  -- A receipt never changes, even as the table owner; the name snapshot outlives a rename.
  PERFORM pg_temp.expect_error($$UPDATE public.supply_request_receipts SET destination_name_snapshot = 'Moved' WHERE supply_request_id = pg_temp.v('detailed')$$,
    'A receipt cannot be changed after it is recorded');
  UPDATE public.inventory_locations SET name = 'First Team ATR (renamed)' WHERE id = pg_temp.l(1);
  PERFORM pg_temp.assert((pg_temp.receipt(pg_temp.v('detailed'))).destination_name_snapshot = 'First Team ATR', 'snapshot survives a rename');
  UPDATE public.inventory_locations SET name = 'First Team ATR' WHERE id = pg_temp.l(1);
END
$phase7c_detailed_checks$;

-- ============================================================================================
-- 4. Lean: Receive & Complete records one receipt, marked; Standard likewise
-- ============================================================================================
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(3);
SELECT pg_temp.submit('lean', 'Lean delivery');
SELECT pg_temp.submit('standard', 'Standard delivery');
SELECT pg_temp.submit('legacy', 'Received before 7C');
SELECT pg_temp.submit('received_first', 'Received under Detailed, completed under Lean');
SELECT pg_temp.as_user(2);
SELECT pg_temp.order('received_first');
SELECT public.receive_supply_request(pg_temp.o(1), pg_temp.v('received_first'), NULL, NULL, pg_temp.l(2));
SELECT public.update_organization_request_workflow_settings(pg_temp.o(1), 'lean');
DO $phase7c_lean$
DECLARE
  _result jsonb;
BEGIN
  PERFORM public.approve_and_order_supply_request(pg_temp.o(1), pg_temp.v('lean'), NULL, NULL, pg_temp.version(pg_temp.v('lean')));
  PERFORM pg_temp.expect_error($$SELECT public.receive_and_complete_supply_request('7cd00000-0000-4000-8000-000000000101', pg_temp.v('lean'))$$,
    'Refresh SportSpend and choose a receiving destination');
  PERFORM pg_temp.expect_error($$SELECT public.receive_and_complete_supply_request('7cd00000-0000-4000-8000-000000000101', pg_temp.v('lean'), NULL, NULL, pg_temp.l(3))$$,
    'Old Cage is archived');
  _result := public.receive_and_complete_supply_request(pg_temp.o(1), pg_temp.v('lean'), 'Delivered to the ATR', 'Internal: signed by AP', pg_temp.l(1));
  PERFORM pg_temp.assert(_result ->> 'status' = 'completed' AND _result ->> 'compoundAction' = 'receive_and_complete'
    AND _result #>> '{receipt,destinationName}' = 'First Team ATR', 'Receive & Complete: ' || _result::text);
  _result := public.receive_and_complete_supply_request(pg_temp.o(1), pg_temp.v('lean'), NULL, NULL, pg_temp.l(1));
  PERFORM pg_temp.assert((_result ->> 'alreadyApplied')::boolean, 'same-destination retry');
  _result := public.receive_and_complete_supply_request(pg_temp.o(1), pg_temp.v('lean'));
  PERFORM pg_temp.assert((_result ->> 'alreadyApplied')::boolean, 'destination-less retry after completion');
  PERFORM pg_temp.expect_error($$SELECT public.receive_and_complete_supply_request('7cd00000-0000-4000-8000-000000000101', pg_temp.v('lean'), NULL, NULL, pg_temp.l(2))$$,
    'already received to First Team ATR');

  -- From received (with a receipt): completes only, keeps the receipt; a different destination is refused.
  PERFORM pg_temp.expect_error($$SELECT public.receive_and_complete_supply_request('7cd00000-0000-4000-8000-000000000101', pg_temp.v('received_first'), NULL, NULL, pg_temp.l(1))$$,
    'already received to Academy ATR');
  _result := public.receive_and_complete_supply_request(pg_temp.o(1), pg_temp.v('received_first'), 'Done', NULL);
  PERFORM pg_temp.assert(_result -> 'transitions' = '["completed"]'::jsonb AND _result #>> '{receipt,destinationName}' = 'Academy ATR',
    'completes a received request without a new destination');
END
$phase7c_lean$;
RESET ROLE;
-- A request received before 7C (no receipt): completes without a destination; one cannot be added.
UPDATE public.supply_requests SET status = 'received', ordered_at = now(), received_at = now() WHERE id = pg_temp.v('legacy');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(1);
SELECT pg_temp.expect_error($$SELECT public.receive_and_complete_supply_request('7cd00000-0000-4000-8000-000000000101', pg_temp.v('legacy'), NULL, NULL, pg_temp.l(1))$$,
  'a receiving destination cannot be added now');
SELECT public.receive_and_complete_supply_request(pg_temp.o(1), pg_temp.v('legacy'));
SELECT public.update_organization_request_workflow_settings(pg_temp.o(1), 'standard');
SELECT public.decide_supply_request(pg_temp.o(1), pg_temp.v('standard'), 'approved', NULL, NULL, pg_temp.version(pg_temp.v('standard')));
-- An approved (not yet ordered) request cannot be received.
SELECT pg_temp.expect_error($$SELECT public.receive_and_complete_supply_request('7cd00000-0000-4000-8000-000000000101', pg_temp.v('standard'), NULL, NULL, pg_temp.l(1))$$,
  'not awaiting delivery');
SELECT pg_temp.expect_error($$SELECT public.receive_supply_request('7cd00000-0000-4000-8000-000000000101', pg_temp.v('standard'), NULL, NULL, pg_temp.l(1))$$,
  'not awaiting delivery');
SELECT public.transition_supply_request(pg_temp.o(1), pg_temp.v('standard'), 'ordered');
SELECT public.receive_and_complete_supply_request(pg_temp.o(1), pg_temp.v('standard'), NULL, NULL, pg_temp.unassigned(pg_temp.o(1)));
RESET ROLE;

DO $phase7c_lean_checks$
DECLARE
  _receipt public.supply_request_receipts;
BEGIN
  _receipt := pg_temp.receipt(pg_temp.v('lean'));
  PERFORM pg_temp.assert(pg_temp.receipts(pg_temp.v('lean')) = 1 AND _receipt.compound_action = 'receive_and_complete'
    AND _receipt.inventory_location_id = pg_temp.l(1) AND _receipt.supply_request_update_id = (pg_temp.received_row(pg_temp.v('lean'))).id,
    'Lean: one receipt, compound marker, linked to the received row');
  PERFORM pg_temp.assert(pg_temp.trail(pg_temp.v('lean'))
    = 'under_review:approve_and_order approved:approve_and_order ordered:approve_and_order received:receive_and_complete completed:receive_and_complete',
    'canonical rows and markers: ' || pg_temp.trail(pg_temp.v('lean')));
  PERFORM pg_temp.assert((SELECT staff_visible_note IS NULL AND internal_note IS NULL FROM public.supply_request_updates WHERE supply_request_id = pg_temp.v('lean') AND status_to = 'received')
    AND (SELECT staff_visible_note = 'Delivered to the ATR' AND internal_note = 'Internal: signed by AP' FROM public.supply_request_updates WHERE supply_request_id = pg_temp.v('lean') AND status_to = 'completed'),
    'notes stay on the completed row');
  PERFORM pg_temp.assert(pg_temp.receipts(pg_temp.v('received_first')) = 1 AND (pg_temp.receipt(pg_temp.v('received_first'))).compound_action IS NULL
    AND pg_temp.status(pg_temp.v('received_first')) = 'completed', 'received-first: original receipt kept');
  PERFORM pg_temp.assert(pg_temp.receipts(pg_temp.v('legacy')) = 0 AND pg_temp.status(pg_temp.v('legacy')) = 'completed', 'legacy request completed without a receipt');
  PERFORM pg_temp.assert(pg_temp.receipts(pg_temp.v('standard')) = 1 AND (pg_temp.receipt(pg_temp.v('standard'))).destination_kind = 'unassigned'
    AND (pg_temp.receipt(pg_temp.v('standard'))).compound_action = 'receive_and_complete', 'Standard: one receipt');
  -- Notifications: receiving and completing raise nothing (submission and approval only).
  PERFORM pg_temp.assert(pg_temp.events(pg_temp.v('lean')) = ARRAY['request_approved', 'request_submitted']
    AND pg_temp.events(pg_temp.v('detailed')) = ARRAY['request_approved', 'request_submitted']
    AND pg_temp.events(pg_temp.v('standard')) = ARRAY['request_approved', 'request_submitted']
    AND pg_temp.events(pg_temp.v('freetext')) = ARRAY['request_approved', 'request_submitted'], 'no receipt or completion events');
  -- Inventory, invoices and commitments: unchanged by every receipt above.
  PERFORM pg_temp.assert(pg_temp.stock_hash() = (SELECT hash FROM phase7c_stock), 'receiving changed no inventory or invoice row');
  PERFORM pg_temp.assert(pg_temp.commitment_hash(pg_temp.v('detailed')) = current_setting('phase7c.detailed_commitment'),
    'receiving and completing left the commitment row unchanged');
  PERFORM pg_temp.assert((SELECT bool_and(status = 'active') FROM public.supply_request_commitments
    WHERE supply_request_id IN (pg_temp.v('detailed'), pg_temp.v('lean'), pg_temp.v('standard'))), 'commitments stay active');
END
$phase7c_lean_checks$;

-- ============================================================================================
-- 5. Receipt reads: admins get the location id; staff only their own, by snapshot name
-- ============================================================================================
SET LOCAL ROLE authenticated;
DO $phase7c_reads$
BEGIN
  PERFORM pg_temp.as_user(2);
  PERFORM pg_temp.assert((SELECT inventory_location_id = pg_temp.l(1) AND destination_name = 'First Team ATR' AND destination_kind = 'storage'
    FROM public.list_supply_request_receipts(pg_temp.o(1), ARRAY[pg_temp.v('detailed')])), 'admin read with location id');
  PERFORM pg_temp.assert((SELECT count(*) FROM public.list_supply_request_receipts(pg_temp.o(1),
    ARRAY[pg_temp.v('detailed'), pg_temp.v('lean'), pg_temp.v('standard'), pg_temp.v('freetext'), pg_temp.v('legacy')])) = 4, 'admin sees every receipt');
  PERFORM pg_temp.as_user(3);
  PERFORM pg_temp.assert((SELECT inventory_location_id IS NULL AND destination_name = 'First Team ATR'
    FROM public.list_supply_request_receipts(pg_temp.o(1), ARRAY[pg_temp.v('detailed')])), 'requester: name, never the location id');
  PERFORM pg_temp.as_user(4);
  PERFORM pg_temp.assert((SELECT count(*) FROM public.list_supply_request_receipts(pg_temp.o(1), ARRAY[pg_temp.v('detailed')])) = 0,
    'another staff member sees nothing');
  PERFORM pg_temp.as_user(6);
  PERFORM pg_temp.expect_error($$SELECT * FROM public.list_supply_request_receipts('7cd00000-0000-4000-8000-000000000101', ARRAY[pg_temp.v('detailed')])$$, 'Not a member');
  PERFORM pg_temp.as_user(2);
  PERFORM pg_temp.expect_error($$SELECT * FROM public.list_supply_request_receipts('7cd00000-0000-4000-8000-000000000102', ARRAY[pg_temp.v('detailed')])$$, 'Not a member');
  -- Staff and cross-organization callers cannot receive.
  PERFORM pg_temp.as_user(3);
  PERFORM pg_temp.expect_error($$SELECT public.receive_supply_request('7cd00000-0000-4000-8000-000000000101', pg_temp.v('bypass'), NULL, NULL, pg_temp.l(1))$$, 'administrator access required');
  PERFORM pg_temp.as_user(6);
  PERFORM pg_temp.expect_error($$SELECT public.receive_supply_request('7cd00000-0000-4000-8000-000000000101', pg_temp.v('bypass'), NULL, NULL, pg_temp.l(1))$$, 'administrator access required');
  PERFORM pg_temp.expect_error($$SELECT public.receive_supply_request('7cd00000-0000-4000-8000-000000000102', pg_temp.v('bypass'), NULL, NULL, pg_temp.l(4))$$, 'Supply request not found');
END
$phase7c_reads$;
RESET ROLE;

-- ============================================================================================
-- Deleting a user account that received requests keeps every receipt and clears only the actor
-- (received_by ON DELETE SET NULL); every other change to a receipt is still refused.
-- ============================================================================================
DO $phase7c_user_deletion$
DECLARE
  _before jsonb;
  _ids uuid[];
BEGIN
  SELECT jsonb_agg(to_jsonb(r) - 'received_by' ORDER BY r.id), array_agg(r.id) INTO _before, _ids
  FROM public.supply_request_receipts r WHERE r.received_by = pg_temp.u(2);
  PERFORM pg_temp.assert(cardinality(_ids) > 0, 'the admin has receipts to keep');
  PERFORM pg_temp.expect_error($$UPDATE public.supply_request_receipts SET received_by = NULL, destination_name_snapshot = 'Moved' WHERE received_by = pg_temp.u(2)$$,
    'A receipt cannot be changed after it is recorded');
  PERFORM pg_temp.expect_error($$UPDATE public.supply_request_receipts SET received_by = pg_temp.u(1) WHERE received_by = pg_temp.u(2)$$,
    'A receipt cannot be changed after it is recorded');
  DELETE FROM auth.users WHERE id = pg_temp.u(2);
  PERFORM pg_temp.assert(
    (SELECT jsonb_agg(to_jsonb(r) - 'received_by' ORDER BY r.id) FROM public.supply_request_receipts r WHERE r.id = ANY(_ids)) = _before
    AND (SELECT bool_and(received_by IS NULL) FROM public.supply_request_receipts WHERE id = ANY(_ids)),
    'user deletion kept every receipt unchanged except the cleared actor');
  PERFORM pg_temp.expect_error($$UPDATE public.supply_request_receipts SET destination_name_snapshot = 'Moved' WHERE received_by IS NULL$$,
    'A receipt cannot be changed after it is recorded');
END
$phase7c_user_deletion$;

ROLLBACK;
