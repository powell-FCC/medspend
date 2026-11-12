-- Phase 7C.0 rollback-only behavioral verification: organization request workflow profiles,
-- compound actions (Approve & Order, Receive & Complete), the shared receive path, the
-- compound_action provenance marker, notification events and the canonical digest. Run against a
-- disposable database after every migration through
-- 20261112120000_phase7c0_request_workflow_profiles.sql. Every fixture is rolled back.
--
-- One transaction means one now(): request versions (updated_at) cannot advance between steps,
-- so stale screens are tested with a deliberately wrong version. Real-session concurrency is
-- covered by supabase/tests/phase7c0_race_check.sh.

BEGIN;

DO $phase7c0_fixture_guard$
BEGIN
  IF EXISTS (SELECT 1 FROM auth.users
             WHERE id BETWEEN '7c000000-0000-4000-8000-000000000001'::uuid AND '7c000000-0000-4000-8000-000000000099'::uuid)
     OR EXISTS (SELECT 1 FROM public.organizations
             WHERE id BETWEEN '7c000000-0000-4000-8000-000000000101'::uuid AND '7c000000-0000-4000-8000-000000000199'::uuid) THEN
    RAISE EXCEPTION 'Phase 7C.0 rollback-test fixture IDs already exist';
  END IF;
END
$phase7c0_fixture_guard$;

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
CREATE FUNCTION pg_temp.u(_n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('7c000000-0000-4000-8000-0000000000' || lpad(_n::text, 2, '0'))::uuid $$;
CREATE FUNCTION pg_temp.o(_n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('7c000000-0000-4000-8000-000000000' || (100 + _n)::text)::uuid $$;
CREATE FUNCTION pg_temp.v(_name text) RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('phase7c0.' || _name, true), '')::uuid $$;
CREATE FUNCTION pg_temp.keep(_name text, _value uuid) RETURNS void LANGUAGE sql AS $$ SELECT set_config('phase7c0.' || _name, _value::text, true) $$;
CREATE FUNCTION pg_temp.as_user(_n integer) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub', pg_temp.u(_n)::text, true) $$;
-- Reads as the table owner.
CREATE FUNCTION pg_temp.status(_request uuid) RETURNS public.supply_request_status LANGUAGE sql SECURITY DEFINER AS $$
  SELECT status FROM public.supply_requests WHERE id = _request $$;
CREATE FUNCTION pg_temp.version(_request uuid) RETURNS timestamptz LANGUAGE sql SECURITY DEFINER AS $$
  SELECT updated_at FROM public.supply_requests WHERE id = _request $$;
CREATE FUNCTION pg_temp.rows(_request uuid)
RETURNS SETOF public.supply_request_updates LANGUAGE sql SECURITY DEFINER AS $$
  SELECT * FROM public.supply_request_updates WHERE supply_request_id = _request ORDER BY created_at, status_to, id $$;
CREATE FUNCTION pg_temp.trail(_request uuid) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT string_agg(concat(status_from, '>', status_to, ':', coalesce(compound_action, '-')), ' ' ORDER BY created_at, status_to, id)
  FROM public.supply_request_updates WHERE supply_request_id = _request $$;
CREATE FUNCTION pg_temp.events(_request uuid) RETURNS text[] LANGUAGE sql SECURITY DEFINER AS $$
  SELECT coalesce(array_agg(event_type ORDER BY event_type), ARRAY[]::text[]) FROM public.notification_events WHERE entity_id = _request $$;
CREATE FUNCTION pg_temp.commitment(_request uuid) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT status FROM public.supply_request_commitments WHERE supply_request_id = _request $$;
CREATE FUNCTION pg_temp.request(_request uuid) RETURNS public.supply_requests LANGUAGE sql SECURITY DEFINER AS $$
  SELECT * FROM public.supply_requests WHERE id = _request $$;
CREATE FUNCTION pg_temp.submit(_name text, _item text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE _id uuid;
BEGIN
  _id := public.submit_supply_request(pg_temp.o(1), 'reorder', NULL, NULL, NULL,
    jsonb_build_array(jsonb_build_object('freeTextItem', _item, 'quantity', 1)));
  PERFORM pg_temp.keep(_name, _id);
  RETURN _id;
END;
$$;
CREATE FUNCTION pg_temp.set_profile(_org uuid, _profile text) RETURNS void LANGUAGE sql SECURITY DEFINER AS $$
  INSERT INTO public.organization_request_workflow_settings (organization_id, workflow_profile) VALUES (_org, _profile)
  ON CONFLICT (organization_id) DO UPDATE SET workflow_profile = EXCLUDED.workflow_profile $$;

INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT pg_temp.u(n), 'authenticated', 'authenticated', 'phase7c0-user-' || n || '@example.invalid', '', now(), '{}',
  jsonb_build_object('full_name', 'Phase 7C User ' || n), now(), now()
FROM generate_series(1, 8) n;

INSERT INTO public.organizations (id, name, created_by) VALUES
  (pg_temp.o(1), 'Phase 7C.0 Athletics', pg_temp.u(1)),
  (pg_temp.o(2), 'Phase 7C.0 Other', pg_temp.u(6));

INSERT INTO public.teams (id, organization_id, name, active) VALUES
  ('7c000000-0000-4000-8000-000000000201', pg_temp.o(1), 'Phase 7C.0 Football', true);
INSERT INTO public.locations (id, organization_id, name, active) VALUES
  ('7c000000-0000-4000-8000-000000000211', pg_temp.o(1), 'Phase 7C.0 Training Room', true);

-- Org 1: u1 owner, u2 admin, u3 staff (requester), u4 staff, u5 inactive admin.
-- Org 2: u6 owner, u7 staff. u8 belongs to no organization.
INSERT INTO public.organization_memberships (organization_id, user_id, role, active, default_team_id, default_location_id) VALUES
  (pg_temp.o(1), pg_temp.u(1), 'owner', true, NULL, NULL),
  (pg_temp.o(1), pg_temp.u(2), 'admin', true, NULL, NULL),
  (pg_temp.o(1), pg_temp.u(3), 'staff', true, '7c000000-0000-4000-8000-000000000201', '7c000000-0000-4000-8000-000000000211'),
  (pg_temp.o(1), pg_temp.u(4), 'staff', true, '7c000000-0000-4000-8000-000000000201', '7c000000-0000-4000-8000-000000000211'),
  (pg_temp.o(1), pg_temp.u(5), 'admin', false, NULL, NULL),
  (pg_temp.o(2), pg_temp.u(6), 'owner', true, NULL, NULL),
  (pg_temp.o(2), pg_temp.u(7), 'staff', true, NULL, NULL);

-- ============================================================================================
-- 1. Structure and access
-- ============================================================================================
DO $phase7c0_structure$
DECLARE
  _fn text;
BEGIN
  PERFORM pg_temp.assert((SELECT relrowsecurity FROM pg_class WHERE oid = 'public.organization_request_workflow_settings'::regclass),
    'RLS on the settings table');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
    AND tablename = 'organization_request_workflow_settings'), 'no policies');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM information_schema.role_table_grants WHERE table_schema = 'public'
    AND table_name = 'organization_request_workflow_settings'
    AND (grantee IN ('anon', 'authenticated', 'PUBLIC') OR (grantee = 'service_role' AND privilege_type <> 'SELECT'))),
    'no client grants; service_role SELECT only');
  FOREACH _fn IN ARRAY ARRAY[
    'public.organization_request_workflow_profile(uuid)',
    'public.mark_supply_request_compound_action(uuid, uuid, text, public.supply_request_status[])',
    'public.apply_supply_request_receipt(uuid, uuid, uuid, text, text, text)',
    'public.guard_supply_request_update_compound_action()'] LOOP
    PERFORM pg_temp.assert(NOT has_function_privilege('authenticated', _fn, 'EXECUTE')
      AND NOT has_function_privilege('anon', _fn, 'EXECUTE')
      AND NOT has_function_privilege('service_role', _fn, 'EXECUTE'), _fn || ' is private');
  END LOOP;
  FOREACH _fn IN ARRAY ARRAY[
    'public.get_request_workflow_profile(uuid)',
    'public.get_organization_request_workflow_settings(uuid)',
    'public.update_organization_request_workflow_settings(uuid, text)',
    'public.receive_supply_request(uuid, uuid, text, text, uuid)',
    'public.approve_and_order_supply_request(uuid, uuid, text, text, timestamptz)',
    'public.receive_and_complete_supply_request(uuid, uuid, text, text, uuid)'] LOOP
    PERFORM pg_temp.assert(has_function_privilege('authenticated', _fn, 'EXECUTE'), _fn || ' executable by authenticated');
    PERFORM pg_temp.assert(NOT has_function_privilege('anon', _fn, 'EXECUTE'), _fn || ' not executable by anon');
    PERFORM pg_temp.assert(NOT has_function_privilege('service_role', _fn, 'EXECUTE'), _fn || ' not granted to service_role');
  END LOOP;
  FOREACH _fn IN ARRAY ARRAY[
    'public.organization_request_workflow_profile(uuid)',
    'public.mark_supply_request_compound_action(uuid, uuid, text, public.supply_request_status[])',
    'public.apply_supply_request_receipt(uuid, uuid, uuid, text, text, text)',
    'public.get_request_workflow_profile(uuid)',
    'public.get_organization_request_workflow_settings(uuid)',
    'public.update_organization_request_workflow_settings(uuid, text)',
    'public.receive_supply_request(uuid, uuid, text, text, uuid)',
    'public.approve_and_order_supply_request(uuid, uuid, text, text, timestamptz)',
    'public.receive_and_complete_supply_request(uuid, uuid, text, text, uuid)'] LOOP
    PERFORM pg_temp.assert((SELECT p.prosecdef AND p.proconfig::text LIKE '%search_path=pg_catalog, public, pg_temp%'
                            FROM pg_proc p WHERE p.oid = _fn::regprocedure), _fn || ' security definer with pinned search_path');
  END LOOP;
  -- The staff history projection keeps its access rules.
  PERFORM pg_temp.assert(has_function_privilege('authenticated', 'public.list_staff_supply_request_updates(uuid, uuid[])', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.list_staff_supply_request_updates(uuid, uuid[])', 'EXECUTE'),
    'staff history grants unchanged');
  -- The existing lifecycle functions are untouched (no profile or compound logic in them).
  FOREACH _fn IN ARRAY ARRAY[
    'public.apply_supply_request_transition(uuid, uuid, public.supply_request_status, text, text)',
    'public.transition_supply_request(uuid, uuid, public.supply_request_status, text, text)',
    'public.decide_supply_request(uuid, uuid, public.supply_request_status, text, text, timestamptz)',
    'public.capture_supply_request_decision_notification()',
    'public.notification_approver_digest_content(uuid, timestamptz, integer, integer)'] LOOP
    PERFORM pg_temp.assert(position('workflow_profile' IN pg_get_functiondef(_fn::regprocedure)) = 0
      AND position('compound_action' IN pg_get_functiondef(_fn::regprocedure)) = 0, _fn || ' untouched');
  END LOOP;
  -- Profile authority is is_org_admin, never a literal role.
  FOREACH _fn IN ARRAY ARRAY[
    'public.update_organization_request_workflow_settings(uuid, text)',
    'public.approve_and_order_supply_request(uuid, uuid, text, text, timestamptz)',
    'public.receive_and_complete_supply_request(uuid, uuid, text, text, uuid)'] LOOP
    PERFORM pg_temp.assert(position('is_org_admin' IN pg_get_functiondef(_fn::regprocedure)) > 0
      AND position('''owner''' IN pg_get_functiondef(_fn::regprocedure)) = 0
      AND position('''admin''' IN pg_get_functiondef(_fn::regprocedure)) = 0, _fn || ' uses is_org_admin');
  END LOOP;
  -- The marker check accepts only bundle rows of the right statuses.
  PERFORM pg_temp.assert(pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'supply_request_updates_compound_action_check'))
    LIKE '%approve_and_order%receive_and_complete%', 'compound_action check constraint');
END
$phase7c0_structure$;

SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(1);
SELECT pg_temp.expect_error('SELECT count(*) FROM public.organization_request_workflow_settings', 'permission denied');
SELECT pg_temp.expect_error($$INSERT INTO public.organization_request_workflow_settings (organization_id, workflow_profile)
  VALUES ('7c000000-0000-4000-8000-000000000101', 'lean')$$, 'permission denied');
SELECT pg_temp.expect_error($$SELECT public.organization_request_workflow_profile('7c000000-0000-4000-8000-000000000101')$$, 'permission denied');
SELECT pg_temp.expect_error($$SELECT public.apply_supply_request_receipt('7c000000-0000-4000-8000-000000000101', gen_random_uuid(), gen_random_uuid())$$, 'permission denied');
SELECT pg_temp.expect_error($$SELECT public.mark_supply_request_compound_action('7c000000-0000-4000-8000-000000000101', gen_random_uuid(), 'approve_and_order', ARRAY['ordered']::public.supply_request_status[])$$, 'permission denied');
SET LOCAL ROLE anon;
SELECT pg_temp.expect_error($$SELECT public.get_request_workflow_profile('7c000000-0000-4000-8000-000000000101')$$, 'permission denied');
SELECT pg_temp.expect_error($$SELECT public.update_organization_request_workflow_settings('7c000000-0000-4000-8000-000000000101', 'lean')$$, 'permission denied');
RESET ROLE;

-- ============================================================================================
-- 2. Settings: no row = detailed, admins change it, staff and outsiders cannot
-- ============================================================================================
SET LOCAL ROLE authenticated;
DO $phase7c0_settings$
DECLARE
  _settings jsonb;
BEGIN
  PERFORM pg_temp.as_user(1);
  _settings := public.get_organization_request_workflow_settings(pg_temp.o(1));
  PERFORM pg_temp.assert(_settings ->> 'workflowProfile' = 'detailed' AND _settings -> 'updatedAt' = 'null'::jsonb,
    'no row = detailed: ' || _settings::text);
  PERFORM pg_temp.assert(public.get_request_workflow_profile(pg_temp.o(1)) = 'detailed', 'member read: detailed');
  PERFORM pg_temp.as_user(3);
  PERFORM pg_temp.assert(public.get_request_workflow_profile(pg_temp.o(1)) = 'detailed', 'staff read: detailed');

  -- An admin membership (not only the owner) may change it.
  PERFORM pg_temp.as_user(2);
  _settings := public.update_organization_request_workflow_settings(pg_temp.o(1), 'standard');
  PERFORM pg_temp.assert(_settings ->> 'workflowProfile' = 'standard' AND _settings -> 'updatedAt' <> 'null'::jsonb, 'admin sets standard');
  PERFORM pg_temp.as_user(1);
  _settings := public.update_organization_request_workflow_settings(pg_temp.o(1), 'detailed');
  PERFORM pg_temp.assert(_settings ->> 'workflowProfile' = 'detailed', 'owner sets detailed');

  PERFORM pg_temp.expect_error($$SELECT public.update_organization_request_workflow_settings('7c000000-0000-4000-8000-000000000101', 'custom')$$, 'Choose Lean, Standard or Detailed');
  PERFORM pg_temp.expect_error($$SELECT public.update_organization_request_workflow_settings('7c000000-0000-4000-8000-000000000101', 'LEAN')$$, 'Choose Lean, Standard or Detailed');
  PERFORM pg_temp.expect_error($$SELECT public.update_organization_request_workflow_settings('7c000000-0000-4000-8000-000000000101', NULL)$$, 'Choose Lean, Standard or Detailed');

  -- Staff: may read the profile, may not read or change Admin Settings.
  PERFORM pg_temp.as_user(3);
  PERFORM pg_temp.expect_error($$SELECT public.update_organization_request_workflow_settings('7c000000-0000-4000-8000-000000000101', 'lean')$$, 'administrator access required');
  PERFORM pg_temp.expect_error($$SELECT public.get_organization_request_workflow_settings('7c000000-0000-4000-8000-000000000101')$$, 'administrator access required');
  -- An inactive admin is not an admin.
  PERFORM pg_temp.as_user(5);
  PERFORM pg_temp.expect_error($$SELECT public.update_organization_request_workflow_settings('7c000000-0000-4000-8000-000000000101', 'lean')$$, 'administrator access required');
  PERFORM pg_temp.expect_error($$SELECT public.get_request_workflow_profile('7c000000-0000-4000-8000-000000000101')$$, 'Not a member');
  -- Another organization's owner, and a non-member.
  PERFORM pg_temp.as_user(6);
  PERFORM pg_temp.expect_error($$SELECT public.update_organization_request_workflow_settings('7c000000-0000-4000-8000-000000000101', 'lean')$$, 'administrator access required');
  PERFORM pg_temp.expect_error($$SELECT public.get_request_workflow_profile('7c000000-0000-4000-8000-000000000101')$$, 'Not a member');
  PERFORM pg_temp.assert(public.get_request_workflow_profile(pg_temp.o(2)) = 'detailed', 'other org unaffected');
  PERFORM pg_temp.as_user(8);
  PERFORM pg_temp.expect_error($$SELECT public.update_organization_request_workflow_settings('7c000000-0000-4000-8000-000000000101', 'lean')$$, 'administrator access required');
END
$phase7c0_settings$;
RESET ROLE;
DO $phase7c0_settings_rows$
BEGIN
  PERFORM pg_temp.assert((SELECT workflow_profile FROM public.organization_request_workflow_settings WHERE organization_id = pg_temp.o(1)) = 'detailed'
    AND (SELECT updated_by FROM public.organization_request_workflow_settings WHERE organization_id = pg_temp.o(1)) = pg_temp.u(1),
    'one row, last writer recorded');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.organization_request_workflow_settings WHERE organization_id = pg_temp.o(2)),
    'no cross-org row');
END
$phase7c0_settings_rows$;

-- ============================================================================================
-- 3. Detailed (default): today's behavior; compound actions refused
-- ============================================================================================
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(3);
SELECT pg_temp.submit('detailed_full', 'Detailed full lifecycle');
SELECT pg_temp.submit('legacy_approved', 'Approved before the switch');
SELECT pg_temp.submit('legacy_received', 'Received before the switch');
SELECT pg_temp.submit('detailed_gate', 'Gate check');
SELECT pg_temp.as_user(2);
DO $phase7c0_detailed$
DECLARE
  _result jsonb;
BEGIN
  PERFORM public.decide_supply_request(pg_temp.o(1), pg_temp.v('detailed_full'), 'approved', NULL, NULL, pg_temp.version(pg_temp.v('detailed_full')));
  PERFORM public.transition_supply_request(pg_temp.o(1), pg_temp.v('detailed_full'), 'ordered', NULL, 'Ordered');
  _result := public.receive_supply_request(pg_temp.o(1), pg_temp.v('detailed_full'), 'Arrived', 'Internal: dock 2', (SELECT id FROM public.list_receiving_destinations(pg_temp.o(1)) WHERE kind = 'unassigned'));
  PERFORM pg_temp.assert(_result ->> 'status' = 'received' AND NOT (_result ->> 'alreadyApplied')::boolean
    AND _result ->> 'receivedAt' IS NOT NULL, 'Mark Received through the shared receive path');
  _result := public.receive_supply_request(pg_temp.o(1), pg_temp.v('detailed_full'), 'Again', NULL);
  PERFORM pg_temp.assert((_result ->> 'alreadyApplied')::boolean, 'Mark Received retry is idempotent');
  PERFORM public.transition_supply_request(pg_temp.o(1), pg_temp.v('detailed_full'), 'completed', NULL, 'Picked up');
  PERFORM pg_temp.expect_error($$SELECT public.receive_supply_request('7c000000-0000-4000-8000-000000000101', pg_temp.v('detailed_full'))$$, 'not awaiting delivery');

  -- Requests left mid-lifecycle under Detailed, used after the profile change.
  PERFORM public.decide_supply_request(pg_temp.o(1), pg_temp.v('legacy_approved'), 'approved', NULL, NULL, pg_temp.version(pg_temp.v('legacy_approved')));
  PERFORM public.decide_supply_request(pg_temp.o(1), pg_temp.v('legacy_received'), 'approved', NULL, NULL, pg_temp.version(pg_temp.v('legacy_received')));
  PERFORM public.transition_supply_request(pg_temp.o(1), pg_temp.v('legacy_received'), 'ordered');
  PERFORM public.receive_supply_request(pg_temp.o(1), pg_temp.v('legacy_received'), NULL, NULL, (SELECT id FROM public.list_receiving_destinations(pg_temp.o(1)) WHERE kind = 'unassigned'));

  -- Compound actions are refused under Detailed, before anything is written.
  PERFORM pg_temp.expect_error($$SELECT public.approve_and_order_supply_request('7c000000-0000-4000-8000-000000000101', pg_temp.v('detailed_gate'), NULL, NULL, pg_temp.version(pg_temp.v('detailed_gate')))$$,
    'Approve & Order is not enabled');
  PERFORM pg_temp.expect_error($$SELECT public.receive_and_complete_supply_request('7c000000-0000-4000-8000-000000000101', pg_temp.v('legacy_received'))$$,
    'Receive & Complete is not enabled');
END
$phase7c0_detailed$;
RESET ROLE;
DO $phase7c0_detailed_checks$
BEGIN
  PERFORM pg_temp.assert(pg_temp.trail(pg_temp.v('detailed_full'))
    = 'submitted>under_review:- under_review>approved:- approved>ordered:- ordered>received:- received>completed:-',
    'Detailed writes one unmarked row per stage: ' || pg_temp.trail(pg_temp.v('detailed_full')));
  PERFORM pg_temp.assert((SELECT staff_visible_note = 'Arrived' AND internal_note = 'Internal: dock 2' FROM pg_temp.rows(pg_temp.v('detailed_full')) WHERE status_to = 'received'),
    'Mark Received keeps its notes separated');
  PERFORM pg_temp.assert(pg_temp.events(pg_temp.v('detailed_full')) = ARRAY['request_approved', 'request_submitted'], 'Detailed events unchanged');
  PERFORM pg_temp.assert(pg_temp.status(pg_temp.v('detailed_gate')) = 'submitted' AND pg_temp.trail(pg_temp.v('detailed_gate')) IS NULL,
    'refused compound wrote nothing');
  PERFORM pg_temp.assert(pg_temp.status(pg_temp.v('legacy_received')) = 'received', 'refused Receive & Complete wrote nothing');
END
$phase7c0_detailed_checks$;

-- ============================================================================================
-- 4. Switch to Lean: no request changes; older requests stay actionable
-- ============================================================================================
CREATE TEMP TABLE phase7c0_before ON COMMIT DROP AS
  SELECT id, status, updated_at, ordered_at, received_at FROM public.supply_requests WHERE organization_id = pg_temp.o(1);
CREATE TEMP TABLE phase7c0_rows_before ON COMMIT DROP AS
  SELECT count(*) AS n FROM public.supply_request_updates WHERE organization_id = pg_temp.o(1);
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(2);
SELECT public.update_organization_request_workflow_settings(pg_temp.o(1), 'lean');
RESET ROLE;
DO $phase7c0_switch$
BEGIN
  PERFORM pg_temp.assert(NOT EXISTS (
    SELECT 1 FROM phase7c0_before b JOIN public.supply_requests r ON r.id = b.id
    WHERE r.status IS DISTINCT FROM b.status OR r.updated_at IS DISTINCT FROM b.updated_at
       OR r.ordered_at IS DISTINCT FROM b.ordered_at OR r.received_at IS DISTINCT FROM b.received_at),
    'a profile change transitions and touches no request');
  PERFORM pg_temp.assert((SELECT count(*) FROM public.supply_request_updates WHERE organization_id = pg_temp.o(1))
    = (SELECT n FROM phase7c0_rows_before), 'a profile change writes no history');
END
$phase7c0_switch$;

-- ============================================================================================
-- 5. Lean: Approve & Order
-- ============================================================================================
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(3);
SELECT pg_temp.submit('lean_submitted', 'Lean from submitted');
SELECT pg_temp.submit('lean_review', 'Lean from under review');
SELECT pg_temp.submit('lean_stale', 'Lean stale screen');
SELECT pg_temp.submit('lean_decline', 'Lean decline');
SELECT pg_temp.submit('lean_correct', 'Lean corrective denial');
SELECT pg_temp.submit('lean_staff', 'Staff cannot approve');
-- Staff cannot use compound actions, even on their own request.
SELECT pg_temp.expect_error($$SELECT public.approve_and_order_supply_request('7c000000-0000-4000-8000-000000000101', pg_temp.v('lean_staff'), NULL, NULL, pg_temp.version(pg_temp.v('lean_staff')))$$, 'administrator access required');
SELECT pg_temp.expect_error($$SELECT public.receive_and_complete_supply_request('7c000000-0000-4000-8000-000000000101', pg_temp.v('legacy_received'))$$, 'administrator access required');
SELECT pg_temp.expect_error($$SELECT public.receive_supply_request('7c000000-0000-4000-8000-000000000101', pg_temp.v('legacy_received'))$$, 'administrator access required');
-- Another organization's owner cannot reach this organization's request, by either org id.
SELECT pg_temp.as_user(6);
SELECT pg_temp.expect_error($$SELECT public.approve_and_order_supply_request('7c000000-0000-4000-8000-000000000101', pg_temp.v('lean_staff'), NULL, NULL, pg_temp.version(pg_temp.v('lean_staff')))$$, 'administrator access required');
SELECT pg_temp.expect_error($$SELECT public.receive_and_complete_supply_request('7c000000-0000-4000-8000-000000000101', pg_temp.v('legacy_received'))$$, 'administrator access required');
SELECT public.update_organization_request_workflow_settings(pg_temp.o(2), 'lean');
SELECT pg_temp.expect_error($$SELECT public.approve_and_order_supply_request('7c000000-0000-4000-8000-000000000102', pg_temp.v('lean_staff'), NULL, NULL, pg_temp.version(pg_temp.v('lean_staff')))$$, 'Supply request not found');
SELECT pg_temp.expect_error($$SELECT public.receive_and_complete_supply_request('7c000000-0000-4000-8000-000000000102', pg_temp.v('legacy_received'))$$, 'Supply request not found');
SELECT pg_temp.expect_error($$SELECT public.receive_supply_request('7c000000-0000-4000-8000-000000000102', pg_temp.v('legacy_received'))$$, 'Supply request not found');

SELECT pg_temp.as_user(2);
DO $phase7c0_lean_approve$
DECLARE
  _result jsonb;
BEGIN
  -- From submitted.
  _result := public.approve_and_order_supply_request(pg_temp.o(1), pg_temp.v('lean_submitted'),
    'Ordered from Henry Schein, arriving Tuesday', 'Internal: PO 4411', pg_temp.version(pg_temp.v('lean_submitted')));
  PERFORM pg_temp.assert(_result ->> 'status' = 'ordered' AND NOT (_result ->> 'alreadyApplied')::boolean
    AND _result ->> 'compoundAction' = 'approve_and_order' AND _result ->> 'orderedAt' IS NOT NULL
    AND _result -> 'transitions' = '["under_review", "approved", "ordered"]'::jsonb, 'Approve & Order from submitted: ' || _result::text);
  -- Retry (double tap, network retry), with or without the old version: nothing is written.
  _result := public.approve_and_order_supply_request(pg_temp.o(1), pg_temp.v('lean_submitted'), 'Again', 'Again', NULL);
  PERFORM pg_temp.assert((_result ->> 'alreadyApplied')::boolean AND _result ->> 'status' = 'ordered', 'retry is idempotent');

  -- From under_review (an earlier Start review through the plain transition).
  PERFORM public.transition_supply_request(pg_temp.o(1), pg_temp.v('lean_review'), 'under_review');
  _result := public.approve_and_order_supply_request(pg_temp.o(1), pg_temp.v('lean_review'), NULL, NULL, pg_temp.version(pg_temp.v('lean_review')));
  PERFORM pg_temp.assert(_result -> 'transitions' = '["approved", "ordered"]'::jsonb AND _result ->> 'compoundAction' = 'approve_and_order',
    'Approve & Order from under_review');

  -- From approved (decided before the switch): only the order step, unmarked.
  _result := public.approve_and_order_supply_request(pg_temp.o(1), pg_temp.v('legacy_approved'), NULL, NULL, pg_temp.version(pg_temp.v('legacy_approved')));
  PERFORM pg_temp.assert(_result -> 'transitions' = '["ordered"]'::jsonb AND _result -> 'compoundAction' = 'null'::jsonb,
    'Approve & Order from approved is a plain order: ' || _result::text);

  -- Stale screen: nothing is written.
  PERFORM pg_temp.expect_error($$SELECT public.approve_and_order_supply_request('7c000000-0000-4000-8000-000000000101', pg_temp.v('lean_stale'), NULL, NULL, pg_temp.version(pg_temp.v('lean_stale')) - interval '1 second')$$,
    'This request changed while you were reviewing it');
  PERFORM pg_temp.expect_error($$SELECT public.approve_and_order_supply_request('7c000000-0000-4000-8000-000000000101', pg_temp.v('lean_stale'), NULL, NULL, NULL)$$,
    'This request changed while you were reviewing it');
  PERFORM pg_temp.expect_error($$SELECT public.approve_and_order_supply_request('7c000000-0000-4000-8000-000000000101', pg_temp.v('lean_stale'), repeat('x', 5001), NULL, pg_temp.version(pg_temp.v('lean_stale')))$$,
    'at most 5000 characters');

  -- Decline is unchanged; a declined request cannot then be approved and ordered.
  PERFORM public.decide_supply_request(pg_temp.o(1), pg_temp.v('lean_decline'), 'denied', 'Use the stock in the cage', 'Internal: no budget',
    pg_temp.version(pg_temp.v('lean_decline')));
  PERFORM pg_temp.expect_error($$SELECT public.approve_and_order_supply_request('7c000000-0000-4000-8000-000000000101', pg_temp.v('lean_decline'), NULL, NULL, pg_temp.version(pg_temp.v('lean_decline')))$$,
    'can no longer be approved and ordered');

  -- Corrective denial after Approve & Order (ordered -> denied) is unchanged.
  PERFORM public.approve_and_order_supply_request(pg_temp.o(1), pg_temp.v('lean_correct'), NULL, NULL, pg_temp.version(pg_temp.v('lean_correct')));
  PERFORM public.transition_supply_request(pg_temp.o(1), pg_temp.v('lean_correct'), 'denied', 'Internal: vendor discontinued', 'Vendor discontinued it');
  PERFORM pg_temp.expect_error($$SELECT public.approve_and_order_supply_request('7c000000-0000-4000-8000-000000000101', pg_temp.v('lean_correct'), NULL, NULL, pg_temp.version(pg_temp.v('lean_correct')))$$,
    'can no longer be approved and ordered');
END
$phase7c0_lean_approve$;
RESET ROLE;

DO $phase7c0_lean_approve_checks$
DECLARE
  _request public.supply_requests;
BEGIN
  _request := pg_temp.request(pg_temp.v('lean_submitted'));
  PERFORM pg_temp.assert(_request.status = 'ordered' AND _request.ordered_at IS NOT NULL AND _request.received_at IS NULL, 'ordered with ordered_at');
  PERFORM pg_temp.assert(pg_temp.trail(pg_temp.v('lean_submitted'))
    = 'submitted>under_review:approve_and_order under_review>approved:approve_and_order approved>ordered:approve_and_order',
    'every canonical row exists and is marked: ' || pg_temp.trail(pg_temp.v('lean_submitted')));
  PERFORM pg_temp.assert((SELECT count(DISTINCT created_at) = 1 AND count(DISTINCT author_id) = 1 AND bool_and(author_id = pg_temp.u(2))
    FROM pg_temp.rows(pg_temp.v('lean_submitted'))), 'one instant, one acting admin');
  -- Notes once, on the final (ordered) row, staff and internal kept apart.
  PERFORM pg_temp.assert((SELECT count(*) FROM pg_temp.rows(pg_temp.v('lean_submitted')) WHERE staff_visible_note IS NOT NULL OR internal_note IS NOT NULL) = 1
    AND (SELECT staff_visible_note = 'Ordered from Henry Schein, arriving Tuesday' AND internal_note = 'Internal: PO 4411'
         FROM pg_temp.rows(pg_temp.v('lean_submitted')) WHERE status_to = 'ordered'), 'notes only on the ordered row');
  PERFORM pg_temp.assert(pg_temp.commitment(pg_temp.v('lean_submitted')) = 'active', 'approval commitment created');
  -- Exactly one approved event; no under-review or ordered event; retry added nothing.
  PERFORM pg_temp.assert(pg_temp.events(pg_temp.v('lean_submitted')) = ARRAY['request_approved', 'request_submitted'],
    'exactly one Approved event: ' || pg_temp.events(pg_temp.v('lean_submitted'))::text);
  PERFORM pg_temp.assert((SELECT source_id FROM public.notification_events WHERE entity_id = pg_temp.v('lean_submitted') AND event_type = 'request_approved')
    = (SELECT id FROM pg_temp.rows(pg_temp.v('lean_submitted')) WHERE status_to = 'approved'), 'approval event points at the approved row');
  PERFORM pg_temp.assert((SELECT count(*) FROM pg_temp.rows(pg_temp.v('lean_submitted'))) = 3, 'retry wrote no rows');

  PERFORM pg_temp.assert(pg_temp.trail(pg_temp.v('lean_review'))
    = 'submitted>under_review:- under_review>approved:approve_and_order approved>ordered:approve_and_order',
    'only the bundle rows are marked: ' || pg_temp.trail(pg_temp.v('lean_review')));
  PERFORM pg_temp.assert(pg_temp.events(pg_temp.v('lean_review')) = ARRAY['request_approved', 'request_submitted'], 'one Approved event from under_review');
  PERFORM pg_temp.assert(pg_temp.trail(pg_temp.v('legacy_approved'))
    = 'submitted>under_review:- under_review>approved:- approved>ordered:-', 'older approved request ordered plainly');
  PERFORM pg_temp.assert(pg_temp.events(pg_temp.v('legacy_approved')) = ARRAY['request_approved', 'request_submitted'], 'no second Approved event');

  PERFORM pg_temp.assert(pg_temp.status(pg_temp.v('lean_stale')) = 'submitted' AND pg_temp.trail(pg_temp.v('lean_stale')) IS NULL
    AND pg_temp.commitment(pg_temp.v('lean_stale')) IS NULL AND pg_temp.events(pg_temp.v('lean_stale')) = ARRAY['request_submitted'],
    'stale or invalid Approve & Order wrote nothing');

  PERFORM pg_temp.assert(pg_temp.events(pg_temp.v('lean_decline')) = ARRAY['request_denied', 'request_submitted'], 'Decline: one Denied event');
  PERFORM pg_temp.assert(pg_temp.trail(pg_temp.v('lean_decline')) = 'submitted>denied:-', 'Decline history unchanged');
  PERFORM pg_temp.assert(pg_temp.events(pg_temp.v('lean_correct')) = ARRAY['request_approved', 'request_denied', 'request_submitted'],
    'corrective denial: one Approved, one Denied');
  PERFORM pg_temp.assert(pg_temp.commitment(pg_temp.v('lean_correct')) = 'released', 'corrective denial releases the commitment');
  PERFORM pg_temp.assert(pg_temp.trail(pg_temp.v('lean_correct'))
    = 'submitted>under_review:approve_and_order under_review>approved:approve_and_order approved>ordered:approve_and_order ordered>denied:-',
    'corrective denial is an ordinary row');
END
$phase7c0_lean_approve_checks$;

-- ============================================================================================
-- 6. Lean: Receive & Complete
-- ============================================================================================
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(1);
DO $phase7c0_lean_receive$
DECLARE
  _result jsonb;
BEGIN
  -- Not awaiting delivery yet.
  PERFORM pg_temp.expect_error($$SELECT public.receive_and_complete_supply_request('7c000000-0000-4000-8000-000000000101', pg_temp.v('lean_stale'))$$,
    'not awaiting delivery');
  _result := public.receive_and_complete_supply_request(pg_temp.o(1), pg_temp.v('lean_submitted'), 'In the training room cage', 'Internal: box 3 of 3',
    (SELECT id FROM public.list_receiving_destinations(pg_temp.o(1)) WHERE kind = 'unassigned'));
  PERFORM pg_temp.assert(_result ->> 'status' = 'completed' AND _result ->> 'receivedAt' IS NOT NULL
    AND _result ->> 'compoundAction' = 'receive_and_complete' AND _result -> 'transitions' = '["received", "completed"]'::jsonb,
    'Receive & Complete from ordered: ' || _result::text);
  _result := public.receive_and_complete_supply_request(pg_temp.o(1), pg_temp.v('lean_submitted'), 'Again', NULL);
  PERFORM pg_temp.assert((_result ->> 'alreadyApplied')::boolean AND _result ->> 'status' = 'completed', 'retry is idempotent');
  -- An older request already at received (Ready for Staff before the switch): only completion, unmarked.
  _result := public.receive_and_complete_supply_request(pg_temp.o(1), pg_temp.v('legacy_received'), NULL, NULL);
  PERFORM pg_temp.assert(_result -> 'transitions' = '["completed"]'::jsonb AND _result -> 'compoundAction' = 'null'::jsonb,
    'Receive & Complete from received: ' || _result::text);
  -- Plain actions still work in Lean for valid canonical states (nothing is stranded). Phase 7C:
  -- Mark Received is the receive action (with a destination), not the generic transition.
  PERFORM public.receive_supply_request(pg_temp.o(1), pg_temp.v('legacy_approved'), NULL, NULL, (SELECT id FROM public.list_receiving_destinations(pg_temp.o(1)) WHERE kind = 'unassigned'));
  PERFORM public.transition_supply_request(pg_temp.o(1), pg_temp.v('legacy_approved'), 'completed');
  -- Denied requests cannot be received.
  PERFORM pg_temp.expect_error($$SELECT public.receive_and_complete_supply_request('7c000000-0000-4000-8000-000000000101', pg_temp.v('lean_correct'))$$,
    'not awaiting delivery');
END
$phase7c0_lean_receive$;
RESET ROLE;
DO $phase7c0_lean_receive_checks$
DECLARE
  _request public.supply_requests;
BEGIN
  _request := pg_temp.request(pg_temp.v('lean_submitted'));
  PERFORM pg_temp.assert(_request.status = 'completed' AND _request.received_at IS NOT NULL AND _request.ordered_at IS NOT NULL, 'completed with received_at');
  PERFORM pg_temp.assert(pg_temp.trail(pg_temp.v('lean_submitted'))
    = 'submitted>under_review:approve_and_order under_review>approved:approve_and_order approved>ordered:approve_and_order ordered>received:receive_and_complete received>completed:receive_and_complete',
    'full canonical history with both markers: ' || pg_temp.trail(pg_temp.v('lean_submitted')));
  PERFORM pg_temp.assert((SELECT staff_visible_note = 'In the training room cage' AND internal_note = 'Internal: box 3 of 3'
    FROM pg_temp.rows(pg_temp.v('lean_submitted')) WHERE status_to = 'completed')
    AND (SELECT staff_visible_note IS NULL AND internal_note IS NULL FROM pg_temp.rows(pg_temp.v('lean_submitted')) WHERE status_to = 'received'),
    'notes only on the completed row');
  PERFORM pg_temp.assert(pg_temp.events(pg_temp.v('lean_submitted')) = ARRAY['request_approved', 'request_submitted'], 'Receive & Complete: no event');
  PERFORM pg_temp.assert(pg_temp.commitment(pg_temp.v('lean_submitted')) = 'active', 'receipt does not release the commitment');
  PERFORM pg_temp.assert((SELECT count(*) FROM pg_temp.rows(pg_temp.v('lean_submitted'))) = 5, 'retry wrote no rows');
  PERFORM pg_temp.assert(pg_temp.trail(pg_temp.v('legacy_received'))
    = 'submitted>under_review:- under_review>approved:- approved>ordered:- ordered>received:- received>completed:-', 'older received request completed plainly');
  PERFORM pg_temp.assert(pg_temp.status(pg_temp.v('legacy_approved')) = 'completed', 'plain transitions available in Lean');
  -- No inventory effect (Phase 7C owns receiving destinations).
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.inventory_adjustments a JOIN public.inventory_items i ON i.id = a.inventory_item_id
    WHERE i.organization_id = pg_temp.o(1)), 'no inventory movement');
END
$phase7c0_lean_receive_checks$;

-- ============================================================================================
-- 7. Standard: separate approval and ordering; Receive & Complete bundled
-- ============================================================================================
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(3);
SELECT pg_temp.submit('standard', 'Standard lifecycle');
SELECT pg_temp.as_user(2);
SELECT public.update_organization_request_workflow_settings(pg_temp.o(1), 'standard');
DO $phase7c0_standard$
BEGIN
  PERFORM pg_temp.expect_error($$SELECT public.approve_and_order_supply_request('7c000000-0000-4000-8000-000000000101', pg_temp.v('standard'), NULL, NULL, pg_temp.version(pg_temp.v('standard')))$$,
    'Approve & Order is not enabled');
  PERFORM public.decide_supply_request(pg_temp.o(1), pg_temp.v('standard'), 'approved', 'Approved', NULL, pg_temp.version(pg_temp.v('standard')));
  PERFORM pg_temp.expect_error($$SELECT public.receive_and_complete_supply_request('7c000000-0000-4000-8000-000000000101', pg_temp.v('standard'))$$,
    'not awaiting delivery');
  PERFORM public.transition_supply_request(pg_temp.o(1), pg_temp.v('standard'), 'ordered', NULL, 'Ordered');
  PERFORM public.receive_and_complete_supply_request(pg_temp.o(1), pg_temp.v('standard'), 'Ready in the cage', NULL, (SELECT id FROM public.list_receiving_destinations(pg_temp.o(1)) WHERE kind = 'unassigned'));
END
$phase7c0_standard$;
RESET ROLE;
DO $phase7c0_standard_checks$
BEGIN
  PERFORM pg_temp.assert(pg_temp.trail(pg_temp.v('standard'))
    = 'submitted>under_review:- under_review>approved:- approved>ordered:- ordered>received:receive_and_complete received>completed:receive_and_complete',
    'Standard canonical rows: ' || pg_temp.trail(pg_temp.v('standard')));
  PERFORM pg_temp.assert(pg_temp.events(pg_temp.v('standard')) = ARRAY['request_approved', 'request_submitted'], 'Standard: one Approved event');
  PERFORM pg_temp.assert(pg_temp.commitment(pg_temp.v('standard')) = 'active', 'Standard approval commitment');
END
$phase7c0_standard_checks$;

-- ============================================================================================
-- 8. Provenance cannot be forged; staff history exposes it
-- ============================================================================================
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(2);
SELECT pg_temp.expect_error($$INSERT INTO public.supply_request_updates (organization_id, supply_request_id, author_id, status_from, status_to, compound_action)
  VALUES ('7c000000-0000-4000-8000-000000000101', pg_temp.v('standard'), auth.uid(), 'received', 'completed', 'receive_and_complete')$$,
  'Compound action provenance is written only by the request workflow');
SELECT pg_temp.expect_error($$UPDATE public.supply_request_updates SET compound_action = NULL WHERE supply_request_id = pg_temp.v('standard')$$,
  'Compound action provenance is written only by the request workflow');
SELECT pg_temp.expect_error($$UPDATE public.supply_request_updates SET compound_action = 'approve_and_order' WHERE supply_request_id = pg_temp.v('detailed_full') AND status_to = 'ordered'$$,
  'Compound action provenance is written only by the request workflow');
SELECT pg_temp.as_user(3);
DO $phase7c0_staff_history$
BEGIN
  PERFORM pg_temp.assert((SELECT string_agg(concat(status_to, ':', coalesce(compound_action, '-'), ':', coalesce(staff_visible_note, '')), ' ' ORDER BY created_at, status_to, id)
    FROM public.list_staff_supply_request_updates(pg_temp.o(1), ARRAY[pg_temp.v('lean_submitted')]))
    = 'under_review:approve_and_order: approved:approve_and_order: ordered:approve_and_order:Ordered from Henry Schein, arriving Tuesday received:receive_and_complete: completed:receive_and_complete:In the training room cage',
    'staff history lists every canonical row with its marker (internal notes never)');
END
$phase7c0_staff_history$;
RESET ROLE;
DO $phase7c0_constraint$
BEGIN
  -- As the table owner (no guard), the check constraint still rejects a mismatched marker.
  PERFORM pg_temp.expect_error($$UPDATE public.supply_request_updates SET compound_action = 'receive_and_complete' WHERE supply_request_id = pg_temp.v('detailed_full') AND status_to = 'ordered'$$,
    'supply_request_updates_compound_action_check');
  PERFORM pg_temp.expect_error($$UPDATE public.supply_request_updates SET compound_action = 'something_else' WHERE supply_request_id = pg_temp.v('detailed_full') AND status_to = 'ordered'$$,
    'supply_request_updates_compound_action_check');
END
$phase7c0_constraint$;

-- ============================================================================================
-- 9. Digest stays canonical: no transient entries; older approved requests stay actionable
-- ============================================================================================
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(3);
SELECT pg_temp.submit('digest_lean', 'Digest lean');
SELECT pg_temp.submit('digest_approved', 'Digest approved under standard');
SELECT pg_temp.submit('digest_review', 'Digest awaiting review');
SELECT pg_temp.as_user(2);
SELECT public.decide_supply_request(pg_temp.o(1), pg_temp.v('digest_approved'), 'approved', NULL, NULL, pg_temp.version(pg_temp.v('digest_approved')));
SELECT public.update_organization_request_workflow_settings(pg_temp.o(1), 'lean');
SELECT public.approve_and_order_supply_request(pg_temp.o(1), pg_temp.v('digest_lean'), NULL, NULL, pg_temp.version(pg_temp.v('digest_lean')));
RESET ROLE;
DO $phase7c0_digest$
DECLARE
  _digest jsonb := public.notification_approver_digest_content(pg_temp.o(1), now() + interval '30 days', 7, 50);
  _ids text;
BEGIN
  SELECT string_agg(item ->> 'requestId', ',') INTO _ids FROM jsonb_array_elements(_digest -> 'sections' -> 'approvedNotOrdered' -> 'items') item;
  PERFORM pg_temp.assert(_ids = pg_temp.v('digest_approved')::text,
    'approved-not-ordered lists only the genuinely approved request: ' || coalesce(_ids, '<none>'));
  PERFORM pg_temp.assert((_digest -> 'sections' -> 'awaitingReview' -> 'items') @> jsonb_build_array(jsonb_build_object('requestId', pg_temp.v('digest_review'))),
    'submitted requests still awaiting review');
  PERFORM pg_temp.assert((_digest -> 'sections' -> 'orderedNotReceived' -> 'items') @> jsonb_build_array(jsonb_build_object('requestId', pg_temp.v('digest_lean'))),
    'Approve & Order request is ordered-not-received after the threshold');
  PERFORM pg_temp.assert(NOT (_digest::text LIKE '%' || pg_temp.v('lean_submitted')::text || '%'), 'completed bundle never appears');
  PERFORM pg_temp.assert((_digest -> 'sections' -> 'underReview' ->> 'count')::integer = 0, 'no transient under-review entries');
END
$phase7c0_digest$;

ROLLBACK;
