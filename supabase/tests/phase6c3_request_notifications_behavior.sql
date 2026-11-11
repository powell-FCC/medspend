-- Phase 6C.3 rollback-only behavioral verification: request notification events, recipient
-- resolution, delivery claiming / retry / dead-letter, approver digest scheduling, organization
-- settings and access. Run against a disposable database after every migration through
-- 20261110120000_phase6c3_request_notifications.sql. Every fixture is rolled back.
--
-- Concurrency across real sessions (two workers claiming at once) is covered by
-- supabase/tests/phase6c3_race_check.sh; this suite runs in one transaction.

BEGIN;

DO $phase6c3_fixture_guard$
BEGIN
  IF EXISTS (SELECT 1 FROM auth.users
             WHERE id BETWEEN '6c300000-0000-4000-8000-000000000001'::uuid AND '6c300000-0000-4000-8000-000000000099'::uuid)
     OR EXISTS (SELECT 1 FROM public.organizations
             WHERE id BETWEEN '6c300000-0000-4000-8000-000000000101'::uuid AND '6c300000-0000-4000-8000-000000000199'::uuid) THEN
    RAISE EXCEPTION 'Phase 6C.3 rollback-test fixture IDs already exist';
  END IF;
END
$phase6c3_fixture_guard$;

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
-- Fixture ids: u(n) users, o(n) organizations.
CREATE FUNCTION pg_temp.u(_n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('6c300000-0000-4000-8000-0000000000' || lpad(_n::text, 2, '0'))::uuid $$;
CREATE FUNCTION pg_temp.o(_n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('6c300000-0000-4000-8000-000000000' || (100 + _n)::text)::uuid $$;
CREATE FUNCTION pg_temp.v(_name text) RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('phase6c3.' || _name, true), '')::uuid $$;
CREATE FUNCTION pg_temp.keep(_name text, _value uuid) RETURNS void LANGUAGE sql AS $$ SELECT set_config('phase6c3.' || _name, _value::text, true) $$;
-- Reads as the table owner (no client grants exist).
CREATE FUNCTION pg_temp.events(_entity uuid)
RETURNS SETOF public.notification_events LANGUAGE sql SECURITY DEFINER AS $$
  SELECT * FROM public.notification_events WHERE entity_id = _entity ORDER BY event_type, created_at, id $$;
CREATE FUNCTION pg_temp.request_count(_org uuid)
RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$ SELECT count(*) FROM public.supply_requests WHERE organization_id = _org $$;
CREATE FUNCTION pg_temp.deliveries_for(_entity uuid)
RETURNS SETOF public.notification_deliveries LANGUAGE sql SECURITY DEFINER AS $$
  SELECT d.* FROM public.notification_deliveries d JOIN public.notification_events e ON e.id = d.event_id
  WHERE e.entity_id = _entity ORDER BY d.recipient_user_id $$;

INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT pg_temp.u(n), 'authenticated', 'authenticated', 'phase6c3-user-' || n || '@example.invalid', '', now(), '{}',
  jsonb_build_object('full_name', 'Phase Six User ' || n), now(), now()
FROM generate_series(1, 12) n;

INSERT INTO public.organizations (id, name, created_by) VALUES
  (pg_temp.o(1), 'Phase 6C.3 Athletics', pg_temp.u(1)),
  (pg_temp.o(2), 'Phase 6C.3 West', pg_temp.u(7)),
  (pg_temp.o(3), 'Phase 6C.3 South Pacific', pg_temp.u(9)),
  (pg_temp.o(4), 'Phase 6C.3 Quiet', pg_temp.u(10));

INSERT INTO public.teams (id, organization_id, name, active) VALUES
  ('6c300000-0000-4000-8000-000000000201', pg_temp.o(1), 'Phase 6C.3 Football', true),
  ('6c300000-0000-4000-8000-000000000202', pg_temp.o(2), 'Phase 6C.3 West Team', true);
INSERT INTO public.locations (id, organization_id, name, active) VALUES
  ('6c300000-0000-4000-8000-000000000211', pg_temp.o(1), 'Phase 6C.3 Training Room', true),
  ('6c300000-0000-4000-8000-000000000212', pg_temp.o(2), 'Phase 6C.3 West Room', true);

-- Org 1: u1 owner, u2 admin, u3 staff (requester), u4 staff, u5 inactive admin, u6 admin
-- (demoted later), u11 admin (deactivated later), u12 staff (direct insert path).
-- Org 2: u7 owner, u8 staff. Org 3: u9 owner. Org 4: u10 owner, nothing actionable.
INSERT INTO public.organization_memberships (organization_id, user_id, role, active, default_team_id, default_location_id) VALUES
  (pg_temp.o(1), pg_temp.u(1), 'owner', true, NULL, NULL),
  (pg_temp.o(1), pg_temp.u(2), 'admin', true, '6c300000-0000-4000-8000-000000000201', '6c300000-0000-4000-8000-000000000211'),
  (pg_temp.o(1), pg_temp.u(3), 'staff', true, '6c300000-0000-4000-8000-000000000201', '6c300000-0000-4000-8000-000000000211'),
  (pg_temp.o(1), pg_temp.u(4), 'staff', true, '6c300000-0000-4000-8000-000000000201', '6c300000-0000-4000-8000-000000000211'),
  (pg_temp.o(1), pg_temp.u(5), 'admin', false, NULL, NULL),
  (pg_temp.o(1), pg_temp.u(6), 'admin', true, NULL, NULL),
  (pg_temp.o(1), pg_temp.u(11), 'admin', true, NULL, NULL),
  (pg_temp.o(1), pg_temp.u(12), 'staff', true, '6c300000-0000-4000-8000-000000000201', '6c300000-0000-4000-8000-000000000211'),
  (pg_temp.o(2), pg_temp.u(7), 'owner', true, NULL, NULL),
  (pg_temp.o(2), pg_temp.u(8), 'staff', true, '6c300000-0000-4000-8000-000000000202', '6c300000-0000-4000-8000-000000000212'),
  (pg_temp.o(3), pg_temp.u(9), 'owner', true, NULL, NULL),
  (pg_temp.o(4), pg_temp.u(10), 'owner', true, NULL, NULL);

INSERT INTO public.products (id, organization_id, name, normalized_name, unit_of_measure, active, staff_requestable)
VALUES ('6c300000-0000-4000-8000-000000000601', pg_temp.o(1), 'Phase 6C.3 Athletic Tape', 'phase 6c.3 athletic tape', 'roll', true, true);

-- ============================================================================================
-- 1. Structure and access
-- ============================================================================================
DO $phase6c3_structure$
DECLARE
  _fn text;
BEGIN
  PERFORM pg_temp.assert(
    (SELECT bool_and(c.relrowsecurity) FROM pg_class c
     WHERE c.oid IN ('public.notification_events'::regclass, 'public.notification_deliveries'::regclass,
                     'public.organization_notification_settings'::regclass)), 'RLS on all three tables');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
    AND tablename IN ('notification_events', 'notification_deliveries', 'organization_notification_settings')), 'no policies');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM information_schema.role_table_grants WHERE table_schema = 'public'
    AND table_name IN ('notification_events', 'notification_deliveries', 'organization_notification_settings')
    AND (grantee IN ('anon', 'authenticated', 'PUBLIC') OR (grantee = 'service_role' AND privilege_type <> 'SELECT'))),
    'no client grants; service_role SELECT only');
  FOREACH _fn IN ARRAY ARRAY[
    'public.enqueue_due_notification_digests(timestamptz)',
    'public.dispatch_notification_events(integer, timestamptz)',
    'public.claim_notification_deliveries(integer, integer, timestamptz)',
    'public.complete_notification_delivery(uuid, uuid, text, text, text, text, jsonb, timestamptz)',
    'public.set_organization_notification_sending(uuid, boolean)',
    'public.notification_request_items(uuid, uuid, integer)',
    'public.notification_approver_digest_content(uuid, timestamptz, integer, integer)'] LOOP
    PERFORM pg_temp.assert(has_function_privilege('service_role', _fn, 'EXECUTE'), _fn || ' executable by service_role');
    PERFORM pg_temp.assert(NOT has_function_privilege('authenticated', _fn, 'EXECUTE'), _fn || ' not executable by authenticated');
    PERFORM pg_temp.assert(NOT has_function_privilege('anon', _fn, 'EXECUTE'), _fn || ' not executable by anon');
    PERFORM pg_temp.assert((SELECT p.prosecdef AND p.proconfig::text LIKE '%search_path=pg_catalog, public, pg_temp%'
                            FROM pg_proc p WHERE p.oid = _fn::regprocedure), _fn || ' security definer with pinned search_path');
  END LOOP;
  FOREACH _fn IN ARRAY ARRAY[
    'public.get_organization_notification_settings(uuid)',
    'public.update_organization_notification_settings(uuid, boolean, text, integer, integer, text)'] LOOP
    PERFORM pg_temp.assert(has_function_privilege('authenticated', _fn, 'EXECUTE'), _fn || ' executable by authenticated');
    PERFORM pg_temp.assert(NOT has_function_privilege('anon', _fn, 'EXECUTE'), _fn || ' not executable by anon');
    PERFORM pg_temp.assert(NOT has_function_privilege('service_role', _fn, 'EXECUTE'), _fn || ' not granted to service_role');
  END LOOP;
  FOREACH _fn IN ARRAY ARRAY['public.capture_supply_request_submitted_notification()', 'public.capture_supply_request_decision_notification()'] LOOP
    PERFORM pg_temp.assert(NOT has_function_privilege('authenticated', _fn, 'EXECUTE')
      AND NOT has_function_privilege('anon', _fn, 'EXECUTE') AND NOT has_function_privilege('service_role', _fn, 'EXECUTE'),
      _fn || ' has no client EXECUTE');
  END LOOP;
  -- The request lifecycle functions are not changed by this phase (no notification code in them).
  PERFORM pg_temp.assert(position('notification' IN pg_get_functiondef('public.apply_supply_request_transition(uuid, uuid, public.supply_request_status, text, text)'::regprocedure)) = 0
    AND position('notification' IN pg_get_functiondef('public.decide_supply_request(uuid, uuid, public.supply_request_status, text, text, timestamptz)'::regprocedure)) = 0
    AND position('notification' IN pg_get_functiondef('public.submit_supply_request(uuid, public.supply_request_type, uuid, uuid, text, jsonb)'::regprocedure)) = 0,
    'request lifecycle functions untouched');
  -- No owner-only or literal-admin recipient logic: approvers resolve through is_org_admin.
  PERFORM pg_temp.assert(position('is_org_admin' IN pg_get_functiondef('public.dispatch_notification_events(integer, timestamptz)'::regprocedure)) > 0
    AND position('''admin''' IN pg_get_functiondef('public.dispatch_notification_events(integer, timestamptz)'::regprocedure)) = 0
    AND position('''owner''' IN pg_get_functiondef('public.dispatch_notification_events(integer, timestamptz)'::regprocedure)) = 0
    AND position('''admin''' IN pg_get_functiondef('public.claim_notification_deliveries(integer, integer, timestamptz)'::regprocedure)) = 0,
    'recipients use is_org_admin semantics, never a literal role');
  -- profiles.email is never the delivery address.
  PERFORM pg_temp.assert(position('auth.users' IN pg_get_functiondef('public.claim_notification_deliveries(integer, integer, timestamptz)'::regprocedure)) > 0
    AND position('p.email' IN pg_get_functiondef('public.claim_notification_deliveries(integer, integer, timestamptz)'::regprocedure)) = 0,
    'delivery address comes from auth.users');
END
$phase6c3_structure$;

-- Clients cannot read or write the notification tables, call worker functions, or read auth.users.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', pg_temp.u(1)::text, true);
SELECT pg_temp.expect_error('SELECT count(*) FROM public.notification_events', 'permission denied');
SELECT pg_temp.expect_error('SELECT count(*) FROM public.notification_deliveries', 'permission denied');
SELECT pg_temp.expect_error('SELECT count(*) FROM public.organization_notification_settings', 'permission denied');
SELECT pg_temp.expect_error($$INSERT INTO public.notification_events (organization_id, event_type, entity_type, entity_id, source_type, source_id, dedupe_key)
  VALUES ('6c300000-0000-4000-8000-000000000101', 'request_submitted', 'supply_request', gen_random_uuid(), 'supply_request', gen_random_uuid(), 'forged')$$, 'permission denied');
SELECT pg_temp.expect_error($$UPDATE public.notification_deliveries SET status = 'sent'$$, 'permission denied');
SELECT pg_temp.expect_error('SELECT * FROM public.claim_notification_deliveries()', 'permission denied');
SELECT pg_temp.expect_error($$SELECT public.complete_notification_delivery(gen_random_uuid(), gen_random_uuid(), 'sent')$$, 'permission denied');
SELECT pg_temp.expect_error('SELECT public.dispatch_notification_events()', 'permission denied');
SELECT pg_temp.expect_error('SELECT public.enqueue_due_notification_digests()', 'permission denied');
SELECT pg_temp.expect_error($$SELECT public.set_organization_notification_sending('6c300000-0000-4000-8000-000000000101', true)$$, 'permission denied');
SELECT pg_temp.expect_error($$SELECT public.notification_approver_digest_content('6c300000-0000-4000-8000-000000000101', now(), 7)$$, 'permission denied');
SELECT pg_temp.expect_error('SELECT email FROM auth.users', 'permission denied');
SET LOCAL ROLE anon;
SELECT pg_temp.expect_error($$SELECT public.get_organization_notification_settings('6c300000-0000-4000-8000-000000000101')$$, 'permission denied');
RESET ROLE;

-- ============================================================================================
-- 2. Settings: admin-only, defaults, validation, master switch not client-editable
-- ============================================================================================
SET LOCAL ROLE authenticated;
DO $phase6c3_settings$
DECLARE
  _settings jsonb;
BEGIN
  -- An existing owner membership is an admin (is_org_admin).
  PERFORM set_config('request.jwt.claim.sub', pg_temp.u(1)::text, true);
  _settings := public.get_organization_notification_settings(pg_temp.o(1));
  PERFORM pg_temp.assert(_settings @> '{"sendingEnabled": false, "digestEnabled": true, "digestFrequency": "daily", "digestSendHour": 8, "digestWeekday": 1, "timezone": "America/New_York", "orderedReceiptThresholdDays": 7}'::jsonb,
    'defaults: sending off, digest on, daily 08:00 Monday New York, 7 days: ' || _settings::text);
  PERFORM pg_temp.assert(_settings -> 'updatedAt' = 'null'::jsonb, 'no row until first save');

  PERFORM set_config('request.jwt.claim.sub', pg_temp.u(2)::text, true);
  _settings := public.update_organization_notification_settings(pg_temp.o(1), true, 'weekly', 7, 3, 'America/Chicago');
  PERFORM pg_temp.assert(_settings @> '{"digestFrequency": "weekly", "digestSendHour": 7, "digestWeekday": 3, "timezone": "America/Chicago", "sendingEnabled": false}'::jsonb,
    'admin saves digest preference; master switch stays off: ' || _settings::text);

  PERFORM pg_temp.expect_error($$SELECT public.update_organization_notification_settings('6c300000-0000-4000-8000-000000000101', true, 'daily', 8, 1, 'Mars/Phobos')$$, 'Choose a supported time zone');
  PERFORM pg_temp.expect_error($$SELECT public.update_organization_notification_settings('6c300000-0000-4000-8000-000000000101', true, 'daily', 8, 1, 'EST')$$, 'Choose a supported time zone');
  PERFORM pg_temp.expect_error($$SELECT public.update_organization_notification_settings('6c300000-0000-4000-8000-000000000101', true, 'daily', 8, 1, 'America/New_York; DROP TABLE x')$$, 'Choose a supported time zone');
  PERFORM pg_temp.expect_error($$SELECT public.update_organization_notification_settings('6c300000-0000-4000-8000-000000000101', true, 'hourly', 8, 1, 'UTC')$$, 'Choose Daily, Weekdays only or Weekly');
  PERFORM pg_temp.expect_error($$SELECT public.update_organization_notification_settings('6c300000-0000-4000-8000-000000000101', true, 'off', 8, 1, 'UTC')$$, 'Choose Daily, Weekdays only or Weekly');
  PERFORM pg_temp.expect_error($$SELECT public.update_organization_notification_settings('6c300000-0000-4000-8000-000000000101', true, 'daily', 24, 1, 'UTC')$$, 'Choose a send time on the hour');
  PERFORM pg_temp.expect_error($$SELECT public.update_organization_notification_settings('6c300000-0000-4000-8000-000000000101', true, 'weekly', 8, 0, 'UTC')$$, 'Choose a weekday');

  -- Staff, an inactive admin and another organization's owner are refused.
  PERFORM set_config('request.jwt.claim.sub', pg_temp.u(3)::text, true);
  PERFORM pg_temp.expect_error($$SELECT public.get_organization_notification_settings('6c300000-0000-4000-8000-000000000101')$$, 'Forbidden');
  PERFORM pg_temp.expect_error($$SELECT public.update_organization_notification_settings('6c300000-0000-4000-8000-000000000101', false, 'daily', 8, 1, 'UTC')$$, 'Forbidden');
  PERFORM set_config('request.jwt.claim.sub', pg_temp.u(5)::text, true);
  PERFORM pg_temp.expect_error($$SELECT public.update_organization_notification_settings('6c300000-0000-4000-8000-000000000101', false, 'daily', 8, 1, 'UTC')$$, 'Forbidden');
  PERFORM set_config('request.jwt.claim.sub', pg_temp.u(7)::text, true);
  PERFORM pg_temp.expect_error($$SELECT public.update_organization_notification_settings('6c300000-0000-4000-8000-000000000101', false, 'daily', 8, 1, 'UTC')$$, 'Forbidden');
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM pg_temp.expect_error($$SELECT public.get_organization_notification_settings('6c300000-0000-4000-8000-000000000101')$$, 'Forbidden');

  -- Back to the defaults for the rest of the suite.
  PERFORM set_config('request.jwt.claim.sub', pg_temp.u(1)::text, true);
  PERFORM public.update_organization_notification_settings(pg_temp.o(1), true, 'daily', 8, 1, 'America/New_York');
END
$phase6c3_settings$;
RESET ROLE;
DO $$ BEGIN
  PERFORM pg_temp.assert((SELECT NOT sending_enabled AND updated_by = pg_temp.u(1) FROM public.organization_notification_settings WHERE organization_id = pg_temp.o(1)),
    'settings row records the editor; sending stays off');
END $$;

-- ============================================================================================
-- 3. Event capture: which actions create events (master switch still OFF)
-- ============================================================================================
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', pg_temp.u(3)::text, true);
DO $phase6c3_submit$
DECLARE
  _request uuid;
BEGIN
  -- A multi-item submission: the event is written when the request row is inserted, BEFORE its
  -- lines exist; it stores identity only (no snapshot of the request content).
  _request := public.submit_supply_request(pg_temp.o(1), 'reorder', NULL, NULL, 'Needed before Saturday',
    jsonb_build_array(
      jsonb_build_object('productId', '6c300000-0000-4000-8000-000000000601', 'quantity', 3),
      jsonb_build_object('freeTextItem', 'Knee sleeve <b>large</b>', 'quantity', 2),
      jsonb_build_object('freeTextItem', 'Ice bags', 'quantity', 10)));
  PERFORM pg_temp.keep('multi', _request);
  -- Requester edit and requester cancellation of another request create no events beyond its submission.
  _request := public.submit_supply_request(pg_temp.o(1), 'reorder', NULL, NULL, NULL,
    jsonb_build_array(jsonb_build_object('freeTextItem', 'Pre wrap', 'quantity', 1)));
  PERFORM pg_temp.keep('edited', _request);
  PERFORM public.update_submitted_supply_request(pg_temp.o(1), _request, NULL, NULL, NULL, 'More please',
    jsonb_build_array(jsonb_build_object('freeTextItem', 'Pre wrap', 'quantity', 6)));
  _request := public.submit_supply_request(pg_temp.o(1), 'reorder', NULL, NULL, NULL,
    jsonb_build_array(jsonb_build_object('freeTextItem', 'Gauze', 'quantity', 1)));
  PERFORM pg_temp.keep('cancelled', _request);
  PERFORM public.cancel_submitted_supply_request(pg_temp.o(1), _request);
  PERFORM public.cancel_submitted_supply_request(pg_temp.o(1), _request);  -- idempotent retry
  -- Requests for the decision paths.
  PERFORM pg_temp.keep('approve_direct', public.submit_supply_request(pg_temp.o(1), 'reorder', NULL, NULL, NULL,
    jsonb_build_array(jsonb_build_object('freeTextItem', 'Approve me', 'quantity', 1))));
  PERFORM pg_temp.keep('deny_direct', public.submit_supply_request(pg_temp.o(1), 'reorder', NULL, NULL, NULL,
    jsonb_build_array(jsonb_build_object('freeTextItem', 'Deny me', 'quantity', 1))));
  PERFORM pg_temp.keep('reversal', public.submit_supply_request(pg_temp.o(1), 'reorder', NULL, NULL, NULL,
    jsonb_build_array(jsonb_build_object('freeTextItem', 'Approve then deny', 'quantity', 1))));
  PERFORM pg_temp.keep('lifecycle', public.submit_supply_request(pg_temp.o(1), 'reorder', NULL, NULL, NULL,
    jsonb_build_array(jsonb_build_object('freeTextItem', 'Full lifecycle', 'quantity', 1))));
END
$phase6c3_submit$;
-- The direct-insert path (RLS sr_insert_member) is a submission too.
SELECT set_config('request.jwt.claim.sub', pg_temp.u(12)::text, true);
INSERT INTO public.supply_requests (id, organization_id, requested_by, request_type, team_id, location_id, status)
VALUES ('6c300000-0000-4000-8000-000000000901', pg_temp.o(1), pg_temp.u(12), 'new_item',
  '6c300000-0000-4000-8000-000000000201', '6c300000-0000-4000-8000-000000000211', 'submitted');
RESET ROLE;

DO $phase6c3_submit_events$
DECLARE
  _event public.notification_events%ROWTYPE;
BEGIN
  SELECT * INTO _event FROM pg_temp.events(pg_temp.v('multi'));
  PERFORM pg_temp.assert(_event.event_type = 'request_submitted' AND _event.actor_id = pg_temp.u(3)
    AND _event.organization_id = pg_temp.o(1) AND _event.source_type = 'supply_request' AND _event.source_id = pg_temp.v('multi')
    AND _event.dedupe_key = 'request_submitted:' || pg_temp.v('multi') AND _event.context = '{}'::jsonb AND _event.status = 'pending',
    'submission event: identity only, pending');
  PERFORM pg_temp.assert((SELECT count(*) FROM pg_temp.events(pg_temp.v('multi'))) = 1, 'one event for the multi-item submission');
  PERFORM pg_temp.assert((SELECT count(*) FROM pg_temp.events(pg_temp.v('edited'))) = 1, 'requester edit adds no event');
  PERFORM pg_temp.assert((SELECT count(*) FROM pg_temp.events(pg_temp.v('cancelled'))) = 1
    AND (SELECT event_type FROM pg_temp.events(pg_temp.v('cancelled'))) = 'request_submitted', 'requester cancellation adds no event');
  PERFORM pg_temp.assert((SELECT count(*) FROM pg_temp.events('6c300000-0000-4000-8000-000000000901')) = 1
    AND (SELECT actor_id FROM pg_temp.events('6c300000-0000-4000-8000-000000000901')) = pg_temp.u(12), 'direct insert captured');
END
$phase6c3_submit_events$;

-- Admin decisions and the rest of the lifecycle.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', pg_temp.u(2)::text, true);
DO $phase6c3_decide$
DECLARE
  _result jsonb;
BEGIN
  -- Submitted -> approved directly writes submitted->under_review and under_review->approved.
  _result := public.decide_supply_request(pg_temp.o(1), pg_temp.v('approve_direct'), 'approved',
    'Approved, ordering Monday', 'Internal: SECRET-APPROVAL-NOTE',
    (SELECT updated_at FROM public.supply_requests WHERE id = pg_temp.v('approve_direct')));
  -- Replay of the same decision (double tap / retried request).
  _result := public.decide_supply_request(pg_temp.o(1), pg_temp.v('approve_direct'), 'approved', NULL, NULL, NULL);
  PERFORM pg_temp.assert((_result ->> 'alreadyDecided')::boolean, 'replayed decision is idempotent');

  _result := public.decide_supply_request(pg_temp.o(1), pg_temp.v('deny_direct'), 'denied',
    'Use the stock in the cage <script>x</script>', 'Internal: SECRET-DENIAL-NOTE',
    (SELECT updated_at FROM public.supply_requests WHERE id = pg_temp.v('deny_direct')));
  _result := public.decide_supply_request(pg_temp.o(1), pg_temp.v('deny_direct'), 'denied', 'Again', NULL, NULL);
  PERFORM pg_temp.assert((_result ->> 'alreadyDecided')::boolean, 'replayed denial is idempotent');

  -- Approved -> ordered -> denied (reversal).
  PERFORM public.decide_supply_request(pg_temp.o(1), pg_temp.v('reversal'), 'approved', NULL, NULL,
    (SELECT updated_at FROM public.supply_requests WHERE id = pg_temp.v('reversal')));
  PERFORM public.transition_supply_request(pg_temp.o(1), pg_temp.v('reversal'), 'ordered', NULL, 'Ordered from vendor');
  PERFORM public.transition_supply_request(pg_temp.o(1), pg_temp.v('reversal'), 'denied', 'Internal: SECRET-REVERSAL', 'Vendor discontinued it');

  -- Full lifecycle through transition_supply_request: under review, then approval, ordered,
  -- received, completed. Only the approval creates an event.
  PERFORM public.transition_supply_request(pg_temp.o(1), pg_temp.v('lifecycle'), 'under_review', NULL, 'Looking at it');
  PERFORM public.decide_supply_request(pg_temp.o(1), pg_temp.v('lifecycle'), 'approved', NULL, NULL,
    (SELECT updated_at FROM public.supply_requests WHERE id = pg_temp.v('lifecycle')));
  PERFORM public.transition_supply_request(pg_temp.o(1), pg_temp.v('lifecycle'), 'ordered', NULL, 'Ordered');
  PERFORM public.transition_supply_request(pg_temp.o(1), pg_temp.v('lifecycle'), 'received', NULL, 'Arrived');
  PERFORM public.transition_supply_request(pg_temp.o(1), pg_temp.v('lifecycle'), 'completed', NULL, 'Picked up');
END
$phase6c3_decide$;
RESET ROLE;

DO $phase6c3_decision_events$
BEGIN
  PERFORM pg_temp.assert((SELECT array_agg(event_type ORDER BY event_type) FROM pg_temp.events(pg_temp.v('approve_direct')))
    = ARRAY['request_approved', 'request_submitted'], 'submitted->approved: one approval event, no under-review event');
  PERFORM pg_temp.assert((SELECT count(*) FROM public.supply_request_updates WHERE supply_request_id = pg_temp.v('approve_direct')) = 2,
    'the lifecycle still writes under_review and approved rows');
  PERFORM pg_temp.assert((SELECT source_id FROM pg_temp.events(pg_temp.v('approve_direct')) WHERE event_type = 'request_approved')
    = (SELECT id FROM public.supply_request_updates WHERE supply_request_id = pg_temp.v('approve_direct') AND status_to = 'approved'),
    'approval event points at the approved update row');
  PERFORM pg_temp.assert((SELECT actor_id FROM pg_temp.events(pg_temp.v('approve_direct')) WHERE event_type = 'request_approved') = pg_temp.u(2),
    'actor is the deciding admin');
  PERFORM pg_temp.assert((SELECT array_agg(event_type ORDER BY event_type) FROM pg_temp.events(pg_temp.v('deny_direct')))
    = ARRAY['request_denied', 'request_submitted'], 'submitted->denied: exactly one denial event');
  PERFORM pg_temp.assert((SELECT array_agg(event_type ORDER BY event_type) FROM pg_temp.events(pg_temp.v('reversal')))
    = ARRAY['request_approved', 'request_denied', 'request_submitted'], 'approved->denied: approval and one corrective denial');
  PERFORM pg_temp.assert((SELECT array_agg(event_type ORDER BY event_type) FROM pg_temp.events(pg_temp.v('lifecycle')))
    = ARRAY['request_approved', 'request_submitted'], 'under review, ordered, received, completed: no events');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.notification_events WHERE context::text LIKE '%SECRET%'),
    'events never carry notes');
END
$phase6c3_decision_events$;

-- Forced event-capture failure: the source write rolls back with it.
CREATE FUNCTION pg_temp.fail_event_capture() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'induced notification event failure'; END $$;
CREATE TRIGGER phase6c3_induced_failure BEFORE INSERT ON public.notification_events
  FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_event_capture();
SET LOCAL ROLE authenticated;
DO $phase6c3_capture_failure$
DECLARE
  _before bigint := pg_temp.request_count(pg_temp.o(1));
  _request uuid;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', pg_temp.u(4)::text, true);
  BEGIN
    _request := public.submit_supply_request(pg_temp.o(1), 'reorder', NULL, NULL, NULL,
      jsonb_build_array(jsonb_build_object('freeTextItem', 'Never saved', 'quantity', 1)));
    RAISE EXCEPTION 'submission committed without its event';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'induced notification event failure' THEN RAISE; END IF;
  END;
  PERFORM pg_temp.assert(pg_temp.request_count(pg_temp.o(1)) = _before,
    'failed capture rolled back the submission');

  PERFORM set_config('request.jwt.claim.sub', pg_temp.u(2)::text, true);
  BEGIN
    PERFORM public.decide_supply_request(pg_temp.o(1), pg_temp.v('edited'), 'approved', NULL, NULL,
      (SELECT updated_at FROM public.supply_requests WHERE id = pg_temp.v('edited')));
    RAISE EXCEPTION 'decision committed without its event';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'induced notification event failure' THEN RAISE; END IF;
  END;
  PERFORM pg_temp.assert((SELECT status FROM public.supply_requests WHERE id = pg_temp.v('edited')) = 'submitted'
    AND NOT EXISTS (SELECT 1 FROM public.supply_request_updates WHERE supply_request_id = pg_temp.v('edited') AND status_to IS NOT NULL)
    AND NOT EXISTS (SELECT 1 FROM public.supply_request_commitments WHERE supply_request_id = pg_temp.v('edited')),
    'failed capture rolled back the decision, its audit rows and its commitment');
END
$phase6c3_capture_failure$;
RESET ROLE;
DROP TRIGGER phase6c3_induced_failure ON public.notification_events;

-- ============================================================================================
-- 4. Dispatch: master switch OFF suppresses; ON fans out to current recipients
-- ============================================================================================
SET LOCAL ROLE service_role;
DO $phase6c3_dispatch_off$
DECLARE
  _processed integer;
BEGIN
  _processed := public.dispatch_notification_events();
  PERFORM pg_temp.assert(_processed >= 12, 'pending events processed: ' || _processed);
END
$phase6c3_dispatch_off$;
RESET ROLE;
DO $$ BEGIN
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.notification_events WHERE organization_id = pg_temp.o(1) AND status <> 'suppressed'),
    'master OFF: every event suppressed');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.notification_deliveries WHERE organization_id = pg_temp.o(1)),
    'master OFF: no deliveries');
  PERFORM pg_temp.assert((SELECT bool_and(status_reason = 'sending_disabled' AND recipient_count = 0 AND processed_at IS NOT NULL)
    FROM public.notification_events WHERE organization_id = pg_temp.o(1)), 'suppression reason recorded');
END $$;

-- Turning the switch ON later never replays suppressed events.
SET LOCAL ROLE service_role;
SELECT public.set_organization_notification_sending(pg_temp.o(1), true);
SELECT public.set_organization_notification_sending(pg_temp.o(2), true);
SELECT pg_temp.assert(public.dispatch_notification_events() = 0, 'suppressed events are not dispatched again');
SELECT pg_temp.expect_error($$SELECT public.set_organization_notification_sending('6c300000-0000-4000-8000-000000000199', true)$$, 'Organization not found');
RESET ROLE;

-- Fresh activity with sending ON.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', pg_temp.u(3)::text, true);
DO $phase6c3_on$
BEGIN
  PERFORM pg_temp.keep('on_multi', public.submit_supply_request(pg_temp.o(1), 'reorder', NULL, NULL, 'Team travel <tonight> & weekend',
    jsonb_build_array(
      jsonb_build_object('productId', '6c300000-0000-4000-8000-000000000601', 'quantity', 4),
      jsonb_build_object('freeTextItem', 'Knee sleeve', 'quantity', 2),
      jsonb_build_object('freeTextItem', 'Ice bags', 'quantity', 10))));
  PERFORM pg_temp.keep('on_approve', public.submit_supply_request(pg_temp.o(1), 'reorder', NULL, NULL, NULL,
    jsonb_build_array(jsonb_build_object('freeTextItem', 'Approve me', 'quantity', 1))));
  PERFORM pg_temp.keep('on_deny', public.submit_supply_request(pg_temp.o(1), 'reorder', NULL, NULL, NULL,
    jsonb_build_array(jsonb_build_object('freeTextItem', 'Deny me', 'quantity', 1))));
  PERFORM pg_temp.keep('on_reversal', public.submit_supply_request(pg_temp.o(1), 'reorder', NULL, NULL, NULL,
    jsonb_build_array(jsonb_build_object('freeTextItem', 'Reverse me', 'quantity', 1))));
  PERFORM pg_temp.keep('on_edit', public.submit_supply_request(pg_temp.o(1), 'reorder', NULL, NULL, NULL,
    jsonb_build_array(jsonb_build_object('freeTextItem', 'Edit me', 'quantity', 1))));
  PERFORM public.update_submitted_supply_request(pg_temp.o(1), pg_temp.v('on_edit'), NULL, NULL, NULL, NULL,
    jsonb_build_array(jsonb_build_object('freeTextItem', 'Edited line', 'quantity', 9)));
  PERFORM pg_temp.keep('on_cancel', public.submit_supply_request(pg_temp.o(1), 'reorder', NULL, NULL, NULL,
    jsonb_build_array(jsonb_build_object('freeTextItem', 'Cancel me', 'quantity', 1))));
  PERFORM public.cancel_submitted_supply_request(pg_temp.o(1), pg_temp.v('on_cancel'));
END
$phase6c3_on$;
-- An admin submitting their own request: other admins are told, never the actor.
SELECT set_config('request.jwt.claim.sub', pg_temp.u(2)::text, true);
SELECT pg_temp.keep('admin_own', public.submit_supply_request(pg_temp.o(1), 'reorder', NULL, NULL, NULL,
  jsonb_build_array(jsonb_build_object('freeTextItem', 'Admin own', 'quantity', 1))));
DO $phase6c3_on_decide$
BEGIN
  PERFORM public.decide_supply_request(pg_temp.o(1), pg_temp.v('on_approve'), 'approved', 'On its way', 'Internal: SECRET-ON-APPROVE',
    (SELECT updated_at FROM public.supply_requests WHERE id = pg_temp.v('on_approve')));
  PERFORM public.decide_supply_request(pg_temp.o(1), pg_temp.v('on_deny'), 'denied', 'Use the cage stock <b>first</b> & ask', 'Internal: SECRET-ON-DENY',
    (SELECT updated_at FROM public.supply_requests WHERE id = pg_temp.v('on_deny')));
  PERFORM public.decide_supply_request(pg_temp.o(1), pg_temp.v('on_reversal'), 'approved', NULL, NULL,
    (SELECT updated_at FROM public.supply_requests WHERE id = pg_temp.v('on_reversal')));
  -- The admin approves their own request: no outcome email to themselves.
  PERFORM public.decide_supply_request(pg_temp.o(1), pg_temp.v('admin_own'), 'approved', NULL, NULL,
    (SELECT updated_at FROM public.supply_requests WHERE id = pg_temp.v('admin_own')));
END
$phase6c3_on_decide$;
-- Another organization's submission.
SELECT set_config('request.jwt.claim.sub', pg_temp.u(8)::text, true);
SELECT pg_temp.keep('org2', public.submit_supply_request(pg_temp.o(2), 'reorder', NULL, NULL, NULL,
  jsonb_build_array(jsonb_build_object('freeTextItem', 'West line', 'quantity', 1))));
RESET ROLE;

-- An event older than 24 hours is expired, not delivered.
INSERT INTO public.notification_events (organization_id, event_type, entity_type, entity_id, source_type, source_id, actor_id, dedupe_key, created_at)
VALUES (pg_temp.o(1), 'request_submitted', 'supply_request', pg_temp.v('on_multi'), 'supply_request', pg_temp.v('on_multi'), pg_temp.u(3),
  'phase6c3-test-old-event', now() - interval '25 hours');

SET LOCAL ROLE service_role;
SELECT public.dispatch_notification_events();
SELECT pg_temp.assert(public.dispatch_notification_events() = 0, 'dispatch is idempotent: nothing pending');
RESET ROLE;

DO $phase6c3_recipients$
DECLARE
  _admins uuid[] := ARRAY[pg_temp.u(1), pg_temp.u(2), pg_temp.u(6), pg_temp.u(11)];
BEGIN
  -- Submission: every active is_org_admin member (owner u1, admins u2, u6, u11); never staff,
  -- never the inactive admin u5, never another organization.
  PERFORM pg_temp.assert((SELECT array_agg(recipient_user_id ORDER BY recipient_user_id) FROM pg_temp.deliveries_for(pg_temp.v('on_multi')))
    = (SELECT array_agg(x ORDER BY x) FROM unnest(_admins) x), 'submission goes to all active admins including the owner membership');
  PERFORM pg_temp.assert((SELECT bool_and(audience = 'approver' AND channel = 'email' AND status = 'pending' AND attempts = 0)
    FROM pg_temp.deliveries_for(pg_temp.v('on_multi'))), 'approver email deliveries pending');
  PERFORM pg_temp.assert((SELECT status FROM public.notification_events WHERE dedupe_key = 'phase6c3-test-old-event') = 'expired'
    AND NOT EXISTS (SELECT 1 FROM public.notification_deliveries d JOIN public.notification_events e ON e.id = d.event_id
                    WHERE e.dedupe_key = 'phase6c3-test-old-event'), 'old event expired, no deliveries');
  -- Actor excluded.
  PERFORM pg_temp.assert((SELECT array_agg(recipient_user_id ORDER BY recipient_user_id) FROM pg_temp.deliveries_for(pg_temp.v('admin_own'))
                          WHERE audience = 'approver')
    = ARRAY[pg_temp.u(1), pg_temp.u(6), pg_temp.u(11)], 'admin-submitted request: other admins only');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM pg_temp.deliveries_for(pg_temp.v('admin_own')) WHERE audience = 'requester'),
    'admin approving their own request: no outcome email');
  PERFORM pg_temp.assert((SELECT status_reason FROM public.notification_events WHERE dedupe_key LIKE 'request_approved:%'
    AND entity_id = pg_temp.v('admin_own')) = 'no_recipients', 'recorded as no recipients');
  -- Outcomes: only the requester.
  PERFORM pg_temp.assert((SELECT array_agg(recipient_user_id || ':' || audience) FROM pg_temp.deliveries_for(pg_temp.v('on_approve'))
                          WHERE audience = 'requester') = ARRAY[pg_temp.u(3) || ':requester'], 'approval: requester only');
  PERFORM pg_temp.assert((SELECT count(*) FROM pg_temp.deliveries_for(pg_temp.v('on_approve')) WHERE audience = 'requester') = 1
    AND (SELECT count(*) FROM pg_temp.deliveries_for(pg_temp.v('on_deny')) WHERE audience = 'requester') = 1,
    'exactly one outcome delivery each');
  -- Edits and cancellations: only the original submission deliveries.
  PERFORM pg_temp.assert((SELECT count(*) FROM pg_temp.deliveries_for(pg_temp.v('on_edit'))) = 4
    AND (SELECT count(*) FROM pg_temp.deliveries_for(pg_temp.v('on_cancel'))) = 4, 'edits and cancellations add no deliveries');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.notification_deliveries d
    WHERE d.organization_id = pg_temp.o(1) AND d.recipient_user_id IN (pg_temp.u(4), pg_temp.u(5), pg_temp.u(7), pg_temp.u(8), pg_temp.u(12))),
    'staff, inactive admin and other organization never receive organization 1 notices');
  -- Organization 2: its owner only.
  PERFORM pg_temp.assert((SELECT array_agg(recipient_user_id) FROM pg_temp.deliveries_for(pg_temp.v('org2'))) = ARRAY[pg_temp.u(7)],
    'organization boundary: org 2 owner only');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.notification_deliveries d JOIN public.notification_events e ON e.id = d.event_id
    WHERE d.organization_id <> e.organization_id), 'delivery organization always equals event organization');
END
$phase6c3_recipients$;

-- Reversal after dispatch: the corrective denial is one more requester delivery.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', pg_temp.u(2)::text, true);
SELECT public.transition_supply_request(pg_temp.o(1), pg_temp.v('on_reversal'), 'ordered', NULL, 'Ordered');
SELECT public.transition_supply_request(pg_temp.o(1), pg_temp.v('on_reversal'), 'denied', 'Internal: SECRET-ON-REVERSAL', 'Vendor discontinued it');
RESET ROLE;
SET LOCAL ROLE service_role;
SELECT public.dispatch_notification_events();
RESET ROLE;
DO $$ BEGIN
  PERFORM pg_temp.assert((SELECT array_agg(e.event_type ORDER BY e.event_type) FROM public.notification_deliveries d
    JOIN public.notification_events e ON e.id = d.event_id WHERE e.entity_id = pg_temp.v('on_reversal') AND d.audience = 'requester')
    = ARRAY['request_approved', 'request_denied'], 'reversal: one approval and one denial delivery to the requester');
END $$;

-- ============================================================================================
-- 5. Claim: eligibility rechecked, sign-in email, rendering context
-- ============================================================================================
-- profiles.email is stale; auth.users holds the current sign-in address.
UPDATE public.profiles SET email = 'stale-profile-address@example.invalid' WHERE id = pg_temp.u(3);
UPDATE auth.users SET email = 'phase6c3-requester-current@example.invalid' WHERE id = pg_temp.u(3);
-- Before delivery: u11 is deactivated, u6 is demoted to staff.
UPDATE public.organization_memberships SET active = false WHERE organization_id = pg_temp.o(1) AND user_id = pg_temp.u(11);
UPDATE public.organization_memberships SET role = 'staff' WHERE organization_id = pg_temp.o(1) AND user_id = pg_temp.u(6);

CREATE TEMP TABLE phase6c3_claims AS
SELECT * FROM public.claim_notification_deliveries(0, 300, now()) LIMIT 0;
GRANT ALL ON phase6c3_claims TO service_role;
SET LOCAL ROLE service_role;
INSERT INTO phase6c3_claims SELECT * FROM public.claim_notification_deliveries(500, 300, now());
SELECT pg_temp.assert((SELECT count(*) FROM public.claim_notification_deliveries(500, 300, now())) = 0,
  'a second worker finds nothing: every due delivery is leased');
RESET ROLE;

DO $phase6c3_claimed$
DECLARE
  _row phase6c3_claims%ROWTYPE;
BEGIN
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM phase6c3_claims c JOIN public.notification_deliveries d ON d.id = c.delivery_id
    WHERE d.recipient_user_id IN (pg_temp.u(6), pg_temp.u(11))), 'demoted and deactivated admins are not claimed');
  PERFORM pg_temp.assert((SELECT bool_and(d.status = 'skipped' AND d.status_reason = 'recipient_not_admin')
    FROM public.notification_deliveries d WHERE d.recipient_user_id = pg_temp.u(6) AND d.organization_id = pg_temp.o(1)), 'demoted admin skipped');
  PERFORM pg_temp.assert((SELECT bool_and(d.status = 'skipped' AND d.status_reason = 'recipient_inactive')
    FROM public.notification_deliveries d WHERE d.recipient_user_id = pg_temp.u(11)), 'deactivated admin skipped');
  PERFORM pg_temp.assert((SELECT bool_and(d.status = 'processing' AND d.attempts = 1 AND d.claim_token = c.claim_token
                                          AND d.claim_expires_at = now() + interval '300 seconds')
    FROM phase6c3_claims c JOIN public.notification_deliveries d ON d.id = c.delivery_id), 'claimed rows leased');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM phase6c3_claims WHERE context::text LIKE '%SECRET%'),
    'internal notes never appear in any delivery context');

  -- Multi-item submission rendered from the current lines (written after the event).
  SELECT c.* INTO _row FROM phase6c3_claims c JOIN public.notification_deliveries d ON d.id = c.delivery_id
  JOIN public.notification_events e ON e.id = d.event_id
  WHERE e.entity_id = pg_temp.v('on_multi') AND e.event_type = 'request_submitted' AND d.recipient_user_id = pg_temp.u(1);
  PERFORM pg_temp.assert(_row.event_type = 'request_submitted' AND _row.channel = 'email' AND _row.attempt = 1
    AND _row.recipient_email = 'phase6c3-user-1@example.invalid', 'admin email from auth.users');
  PERFORM pg_temp.assert((_row.context -> 'items' ->> 'itemCount')::integer = 3
    AND jsonb_array_length(_row.context -> 'items' -> 'items') = 3
    AND _row.context -> 'items' -> 'items' @> '[{"label": "Phase 6C.3 Athletic Tape", "quantity": 4, "unit": "roll"}, {"label": "Ice bags", "quantity": 10}]'
    AND _row.context ->> 'requesterName' = 'Phase Six User 3'
    AND _row.context ->> 'requestNote' = 'Team travel <tonight> & weekend'
    AND _row.context ->> 'organizationName' = 'Phase 6C.3 Athletics'
    AND _row.context ->> 'requestId' = pg_temp.v('on_multi')::text
    AND _row.context ? 'submittedAt', 'submission context: current items, requester, note: ' || _row.context::text);

  -- Edited request renders its current lines.
  SELECT c.* INTO _row FROM phase6c3_claims c JOIN public.notification_deliveries d ON d.id = c.delivery_id
  JOIN public.notification_events e ON e.id = d.event_id
  WHERE e.entity_id = pg_temp.v('on_edit') AND d.recipient_user_id = pg_temp.u(1);
  PERFORM pg_temp.assert(_row.context -> 'items' -> 'items' -> 0 @> '{"label": "Edited line", "quantity": 9}', 'edited lines rendered');

  -- Approval: requester's CURRENT sign-in email (not profiles.email); no notes.
  SELECT c.* INTO _row FROM phase6c3_claims c JOIN public.notification_deliveries d ON d.id = c.delivery_id
  JOIN public.notification_events e ON e.id = d.event_id
  WHERE e.entity_id = pg_temp.v('on_approve') AND e.event_type = 'request_approved';
  PERFORM pg_temp.assert(_row.recipient_email = 'phase6c3-requester-current@example.invalid', 'auth sign-in email, not profiles.email');
  PERFORM pg_temp.assert(_row.context ->> 'audience' = 'requester' AND NOT _row.context ? 'staffVisibleNote' AND NOT _row.context ? 'requestNote'
    AND _row.context ? 'decidedAt' AND _row.context ->> 'reference' = upper(left(pg_temp.v('on_approve')::text, 8)),
    'approval context: reference, no notes: ' || _row.context::text);

  -- Denial: the staff-visible reason only.
  SELECT c.* INTO _row FROM phase6c3_claims c JOIN public.notification_deliveries d ON d.id = c.delivery_id
  JOIN public.notification_events e ON e.id = d.event_id
  WHERE e.entity_id = pg_temp.v('on_deny') AND e.event_type = 'request_denied';
  PERFORM pg_temp.assert(_row.context ->> 'staffVisibleNote' = 'Use the cage stock <b>first</b> & ask', 'denial carries the staff-visible note');

  -- Reversal denial: its own staff-visible note, not the internal one.
  SELECT c.* INTO _row FROM phase6c3_claims c JOIN public.notification_deliveries d ON d.id = c.delivery_id
  JOIN public.notification_events e ON e.id = d.event_id
  WHERE e.entity_id = pg_temp.v('on_reversal') AND e.event_type = 'request_denied';
  PERFORM pg_temp.assert(_row.context ->> 'staffVisibleNote' = 'Vendor discontinued it', 'reversal denial note');
END
$phase6c3_claimed$;

-- ============================================================================================
-- 6. Stale claims, completion, retry with backoff, dead-letter
-- ============================================================================================
-- Stale claim recovery: a crashed worker's lease expires; another worker reclaims with a new
-- token; the crashed worker's late completion is ignored. (Leases are expired directly here so
-- only the victim is affected.)
DO $phase6c3_stale$
DECLARE
  _victim uuid;
  _old uuid;
  _new record;
BEGIN
  SELECT c.delivery_id, c.claim_token INTO _victim, _old FROM phase6c3_claims c ORDER BY c.delivery_id OFFSET 3 LIMIT 1;
  PERFORM pg_temp.assert(_victim IS NOT NULL, 'a leased delivery exists');
  PERFORM pg_temp.assert((SELECT count(*) FROM public.claim_notification_deliveries(500, 60, now()) WHERE delivery_id = _victim) = 0,
    'an unexpired lease is not reclaimed');
  UPDATE public.notification_deliveries SET claim_expires_at = now() - interval '1 second' WHERE id = _victim;
  SELECT * INTO _new FROM public.claim_notification_deliveries(500, 60, now()) c WHERE c.delivery_id = _victim;
  PERFORM pg_temp.assert(_new.claim_token IS NOT NULL AND _new.claim_token <> _old AND _new.attempt = 2, 'expired lease reclaimed as attempt 2');
  PERFORM pg_temp.assert(public.complete_notification_delivery(_victim, _old, 'sent', 'fake', 'late') = 'stale_claim', 'late completion ignored');
  PERFORM pg_temp.assert(public.complete_notification_delivery(_victim, _new.claim_token, 'sent', 'fake', 'current') = 'sent', 'current claim completes');
  PERFORM pg_temp.assert((SELECT provider_message_id FROM public.notification_deliveries WHERE id = _victim) = 'current', 'one sent record');

  -- A lease that expires on the 5th attempt dead-letters instead of retrying forever.
  SELECT c.delivery_id INTO _victim FROM phase6c3_claims c ORDER BY c.delivery_id OFFSET 4 LIMIT 1;
  UPDATE public.notification_deliveries SET attempts = 5, claim_expires_at = now() - interval '1 second' WHERE id = _victim;
  PERFORM public.claim_notification_deliveries(500, 60, now());
  PERFORM pg_temp.assert((SELECT status = 'dead' AND status_reason = 'lease_expired' AND claim_token IS NULL
    FROM public.notification_deliveries WHERE id = _victim), 'expired final lease dead-letters');
END
$phase6c3_stale$;

SET LOCAL ROLE service_role;
DO $phase6c3_complete$
DECLARE
  _sent phase6c3_claims%ROWTYPE;
  _retry phase6c3_claims%ROWTYPE;
  _reject phase6c3_claims%ROWTYPE;
  _claim record;
  _status text;
  _t timestamptz := now();
  _token uuid;
BEGIN
  SELECT * INTO _sent FROM phase6c3_claims ORDER BY delivery_id LIMIT 1;
  SELECT * INTO _retry FROM phase6c3_claims ORDER BY delivery_id OFFSET 1 LIMIT 1;
  SELECT * INTO _reject FROM phase6c3_claims ORDER BY delivery_id OFFSET 2 LIMIT 1;

  -- Success; a wrong token and a repeat completion are ignored.
  PERFORM pg_temp.assert(public.complete_notification_delivery(_sent.delivery_id, gen_random_uuid(), 'sent', 'fake', 'msg-x') = 'stale_claim', 'wrong token ignored');
  _status := public.complete_notification_delivery(_sent.delivery_id, _sent.claim_token, 'sent', 'fake', 'msg-1', NULL, '{"opaque": true}');
  PERFORM pg_temp.assert(_status = 'sent', 'sent');
  PERFORM pg_temp.assert(public.complete_notification_delivery(_sent.delivery_id, _sent.claim_token, 'sent', 'fake', 'msg-2') = 'stale_claim', 'repeat completion ignored');
  PERFORM pg_temp.assert((SELECT status = 'sent' AND sent_at = _t AND provider = 'fake' AND provider_message_id = 'msg-1'
    AND provider_metadata = '{"opaque": true}' AND claim_token IS NULL FROM public.notification_deliveries WHERE id = _sent.delivery_id), 'sent recorded once');

  -- Permanent rejection dead-letters at once.
  PERFORM pg_temp.assert(public.complete_notification_delivery(_reject.delivery_id, _reject.claim_token, 'permanent_failure', 'fake', NULL,
    repeat('x', 900)) = 'dead', 'permanent failure is dead');
  PERFORM pg_temp.assert((SELECT status_reason = 'rejected' AND attempts = 1 AND length(last_error) = 500
    FROM public.notification_deliveries WHERE id = _reject.delivery_id), 'rejection recorded, error truncated');
  PERFORM pg_temp.expect_error(format('SELECT public.complete_notification_delivery(%L, %L, %L)', _reject.delivery_id, _reject.claim_token, 'bounced'),
    'unknown delivery outcome');
  PERFORM pg_temp.expect_error('SELECT * FROM public.claim_notification_deliveries(10, 5)', 'lease must be between 30 and 3600 seconds');

  -- Retryable failures: 1, 5, 30, 120 minutes, then dead after the 5th attempt.
  _token := _retry.claim_token;
  FOR _i IN 1..5 LOOP
    _status := public.complete_notification_delivery(_retry.delivery_id, _token, 'retryable_failure', 'fake', NULL,
      'HTTP 503 provider unavailable attempt ' || _i, NULL, _t);
    IF _i < 5 THEN
      PERFORM pg_temp.assert(_status = 'pending', 'attempt ' || _i || ' rescheduled');
      PERFORM pg_temp.assert((SELECT next_attempt_at - _t FROM public.notification_deliveries WHERE id = _retry.delivery_id)
        = (ARRAY[interval '1 minute', interval '5 minutes', interval '30 minutes', interval '120 minutes'])[_i], 'backoff after attempt ' || _i);
      -- Not claimable before it is due; claimable when due, with the next attempt number.
      PERFORM pg_temp.assert((SELECT count(*) FROM public.claim_notification_deliveries(500, 3600,
        (SELECT next_attempt_at - interval '1 second' FROM public.notification_deliveries WHERE id = _retry.delivery_id))
        WHERE delivery_id = _retry.delivery_id) = 0, 'not claimed before due');
      _t := (SELECT next_attempt_at FROM public.notification_deliveries WHERE id = _retry.delivery_id);
      SELECT * INTO _claim FROM public.claim_notification_deliveries(500, 3600, _t) c WHERE c.delivery_id = _retry.delivery_id;
      PERFORM pg_temp.assert(_claim.attempt = _i + 1, 'retry claimed as attempt ' || (_i + 1));
      _token := _claim.claim_token;
    END IF;
  END LOOP;
  PERFORM pg_temp.assert(_status = 'dead', 'dead after the 5th failed attempt');
  PERFORM pg_temp.assert((SELECT status = 'dead' AND attempts = 5 AND status_reason = 'retries_exhausted'
    AND last_error = 'HTTP 503 provider unavailable attempt 5' FROM public.notification_deliveries WHERE id = _retry.delivery_id), 'dead-letter recorded');
  PERFORM pg_temp.assert((SELECT count(*) FROM public.claim_notification_deliveries(500, 300, _t + interval '30 days')
    WHERE delivery_id IN (_retry.delivery_id, _sent.delivery_id, _reject.delivery_id)) = 0, 'sent and dead deliveries are never claimed again');
END
$phase6c3_complete$;
RESET ROLE;

-- Master switch turned OFF while deliveries are pending: they are skipped, not sent later.
UPDATE public.notification_deliveries SET status = 'sent', sent_at = now(), claim_token = NULL, claim_expires_at = NULL WHERE status = 'processing';
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', pg_temp.u(4)::text, true);
SELECT pg_temp.keep('switch_off', public.submit_supply_request(pg_temp.o(1), 'reorder', NULL, NULL, NULL,
  jsonb_build_array(jsonb_build_object('freeTextItem', 'Switch off', 'quantity', 1))));
RESET ROLE;
DO $phase6c3_switch_off$
BEGIN
  PERFORM public.dispatch_notification_events();
  PERFORM pg_temp.assert((SELECT array_agg(recipient_user_id ORDER BY recipient_user_id) FROM pg_temp.deliveries_for(pg_temp.v('switch_off')))
    = ARRAY[pg_temp.u(1), pg_temp.u(2)], 'dispatch uses current admins (demoted and deactivated admins gone)');
  PERFORM public.set_organization_notification_sending(pg_temp.o(1), false);
  PERFORM public.claim_notification_deliveries(500, 300, now());
  PERFORM pg_temp.assert((SELECT bool_and(status = 'skipped' AND status_reason = 'sending_disabled') FROM pg_temp.deliveries_for(pg_temp.v('switch_off'))),
    'master OFF at delivery time skips');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.notification_deliveries WHERE organization_id = pg_temp.o(1) AND status IN ('pending', 'processing')),
    'nothing left to deliver for organization 1');
END
$phase6c3_switch_off$;

-- ============================================================================================
-- 7. Approver digest: content, scheduling, time zones, DST, frequencies, idempotency
-- ============================================================================================
-- Fresh actionable state in organization 2 (Los Angeles): requests in every state.
INSERT INTO public.supply_requests (id, organization_id, requested_by, request_type, team_id, location_id, status, created_at, ordered_at, received_at)
VALUES
  ('6c300000-0000-4000-8000-000000000911', pg_temp.o(2), pg_temp.u(8), 'reorder', '6c300000-0000-4000-8000-000000000202', '6c300000-0000-4000-8000-000000000212', 'submitted', now() - interval '3 days', NULL, NULL),
  ('6c300000-0000-4000-8000-000000000912', pg_temp.o(2), pg_temp.u(8), 'reorder', '6c300000-0000-4000-8000-000000000202', '6c300000-0000-4000-8000-000000000212', 'under_review', now() - interval '5 days', NULL, NULL),
  ('6c300000-0000-4000-8000-000000000913', pg_temp.o(2), pg_temp.u(8), 'reorder', '6c300000-0000-4000-8000-000000000202', '6c300000-0000-4000-8000-000000000212', 'approved', now() - interval '6 days', NULL, NULL),
  ('6c300000-0000-4000-8000-000000000914', pg_temp.o(2), pg_temp.u(8), 'reorder', '6c300000-0000-4000-8000-000000000202', '6c300000-0000-4000-8000-000000000212', 'ordered', now() - interval '20 days', now() - interval '8 days', NULL),
  ('6c300000-0000-4000-8000-000000000915', pg_temp.o(2), pg_temp.u(8), 'reorder', '6c300000-0000-4000-8000-000000000202', '6c300000-0000-4000-8000-000000000212', 'ordered', now() - interval '20 days', now() - interval '6 days', NULL),
  ('6c300000-0000-4000-8000-000000000916', pg_temp.o(2), pg_temp.u(8), 'reorder', '6c300000-0000-4000-8000-000000000202', '6c300000-0000-4000-8000-000000000212', 'received', now() - interval '30 days', now() - interval '25 days', now() - interval '1 day'),
  ('6c300000-0000-4000-8000-000000000917', pg_temp.o(2), pg_temp.u(8), 'reorder', '6c300000-0000-4000-8000-000000000202', '6c300000-0000-4000-8000-000000000212', 'denied', now() - interval '30 days', NULL, NULL),
  ('6c300000-0000-4000-8000-000000000918', pg_temp.o(2), pg_temp.u(8), 'reorder', '6c300000-0000-4000-8000-000000000202', '6c300000-0000-4000-8000-000000000212', 'completed', now() - interval '30 days', now() - interval '29 days', now() - interval '28 days'),
  ('6c300000-0000-4000-8000-000000000919', pg_temp.o(2), pg_temp.u(8), 'reorder', '6c300000-0000-4000-8000-000000000202', '6c300000-0000-4000-8000-000000000212', 'cancelled', now() - interval '30 days', NULL, NULL);
INSERT INTO public.supply_request_items (organization_id, supply_request_id, free_text_item, quantity)
SELECT pg_temp.o(2), id, 'Digest line ' || right(id::text, 2), 1 FROM public.supply_requests
WHERE id BETWEEN '6c300000-0000-4000-8000-000000000911' AND '6c300000-0000-4000-8000-000000000919';
-- Fixture inserts raise submission events too; clear organization 2's backlog (sending is ON there).
SET LOCAL ROLE service_role;
SELECT public.dispatch_notification_events();
SELECT public.complete_notification_delivery(c.delivery_id, c.claim_token, 'sent', 'fake', 'setup') FROM public.claim_notification_deliveries(500, 300, now()) c;
RESET ROLE;

SET LOCAL ROLE service_role;
DO $phase6c3_digest_content$
DECLARE
  _content jsonb := public.notification_approver_digest_content(pg_temp.o(2), now(), 7, 10);
BEGIN
  -- The org 2 submission from section 4 is still submitted, so awaiting review has 2.
  PERFORM pg_temp.assert((_content -> 'sections' -> 'awaitingReview' ->> 'count')::integer = 2
    AND (_content -> 'sections' -> 'underReview' ->> 'count')::integer = 1
    AND (_content -> 'sections' -> 'approvedNotOrdered' ->> 'count')::integer = 1
    AND (_content -> 'sections' -> 'orderedNotReceived' ->> 'count')::integer = 1
    AND (_content ->> 'totalCount')::integer = 5, 'actionable sections only (8-day order in, 6-day order out, closed states out): ' || _content::text);
  PERFORM pg_temp.assert((_content -> 'sections' -> 'orderedNotReceived' -> 'items' -> 0 ->> 'requestId') = '6c300000-0000-4000-8000-000000000914',
    'ordered past the threshold listed');
  PERFORM pg_temp.assert((_content -> 'sections' -> 'awaitingReview' ->> 'oldestAt')::timestamptz = now() - interval '3 days',
    'oldest age reported');
  PERFORM pg_temp.assert((public.notification_approver_digest_content(pg_temp.o(2), now(), 5, 10) -> 'sections' -> 'orderedNotReceived' ->> 'count')::integer = 2,
    'threshold is configuration');
  PERFORM pg_temp.assert(jsonb_array_length(public.notification_approver_digest_content(pg_temp.o(2), now(), 7, 1) -> 'sections' -> 'awaitingReview' -> 'items') = 1,
    'item list is capped');
  PERFORM pg_temp.assert(position('budget' IN lower(_content::text)) = 0 AND position('inventory' IN lower(_content::text)) = 0,
    'no budget or inventory content');
  PERFORM pg_temp.assert((public.notification_approver_digest_content(pg_temp.o(4), now(), 7, 10) ->> 'totalCount')::integer = 0,
    'empty organization has nothing actionable');
END
$phase6c3_digest_content$;
RESET ROLE;

-- Scheduling. Settings rows are written directly here (as the table owner) to cover every
-- combination; section 2 covers the admin RPC.
DELETE FROM public.organization_notification_settings WHERE organization_id IN (pg_temp.o(1), pg_temp.o(2), pg_temp.o(3), pg_temp.o(4));
INSERT INTO public.organization_notification_settings (organization_id, sending_enabled, digest_enabled, digest_frequency, digest_send_hour, digest_weekday, timezone)
VALUES (pg_temp.o(2), true, true, 'daily', 8, 1, 'America/Los_Angeles');
CREATE FUNCTION pg_temp.digests(_org uuid)
RETURNS TABLE (local_date text, status text, frequency text) LANGUAGE sql SECURITY DEFINER AS $$
  SELECT context ->> 'localDate', status, context ->> 'frequency' FROM public.notification_events
  WHERE organization_id = _org AND event_type = 'approver_digest' ORDER BY context ->> 'localDate' $$;

SET LOCAL ROLE service_role;
DO $phase6c3_daily$
BEGIN
  -- 2026-11-10 is a Tuesday. 08:00 in Los Angeles (PST, UTC-8) is 16:00Z.
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-10 15:59:59+00') = 0, 'not before the send hour');
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-10 16:00:00+00') = 1, 'due at 08:00 local');
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-10 16:00:00+00') = 0, 'cron retry: no duplicate');
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-10 23:00:00+00') = 0, 'later the same local day: no duplicate');
  -- 2026-11-11 07:59 local is still the 11th's morning; the 10th is done.
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-11 07:00:00+00') = 0, 'midnight UTC is not a new local day');
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-11 16:30:00+00') = 1, 'next local day');
  PERFORM pg_temp.assert((SELECT array_agg(local_date || '/' || status) FROM pg_temp.digests(pg_temp.o(2)))
    = ARRAY['2026-11-10/pending', '2026-11-11/pending'], 'one digest per local date');
END
$phase6c3_daily$;
RESET ROLE;

-- Dispatch and claim the digest: all active admins of organization 2 (its owner), rendered now.
SET LOCAL ROLE service_role;
DO $phase6c3_digest_delivery$
DECLARE
  _claim record;
BEGIN
  PERFORM public.dispatch_notification_events();
  PERFORM pg_temp.assert((SELECT count(*) FROM public.notification_deliveries d JOIN public.notification_events e ON e.id = d.event_id
    WHERE e.organization_id = pg_temp.o(2) AND e.event_type = 'approver_digest' AND d.recipient_user_id = pg_temp.u(7) AND d.audience = 'approver') = 2,
    'each digest delivered to the active admins (owner membership)');
  -- One worker slot: the other digest delivery stays pending for the next check.
  SELECT * INTO _claim FROM public.claim_notification_deliveries(1, 300, now()) c;
  PERFORM pg_temp.assert(_claim.event_type = 'approver_digest', 'digest claimed');
  PERFORM pg_temp.assert(_claim.recipient_email = 'phase6c3-user-7@example.invalid'
    AND (_claim.context -> 'digest' ->> 'totalCount')::integer = 5
    AND _claim.context ->> 'timezone' = 'America/Los_Angeles' AND _claim.context ->> 'frequency' = 'daily', 'digest rendered at claim time');
  PERFORM public.complete_notification_delivery(_claim.delivery_id, _claim.claim_token, 'sent', 'fake', 'digest-1');
END
$phase6c3_digest_delivery$;
RESET ROLE;

-- Requests resolved before delivery: a cancelled / decided request drops out; with nothing
-- actionable left at claim time the remaining digest delivery is skipped, never sent empty.
UPDATE public.supply_requests SET status = 'cancelled' WHERE organization_id = pg_temp.o(2) AND status IN ('submitted');
UPDATE public.supply_requests SET status = 'denied' WHERE organization_id = pg_temp.o(2) AND status IN ('under_review', 'approved', 'ordered');
SET LOCAL ROLE service_role;
DO $phase6c3_digest_emptied$
BEGIN
  PERFORM pg_temp.assert((SELECT count(*) FROM public.claim_notification_deliveries(10, 300, now()) c WHERE c.event_type = 'approver_digest') = 0,
    'emptied digest is not claimed');
  PERFORM pg_temp.assert((SELECT bool_and(d.status = 'skipped' AND d.status_reason = 'nothing_actionable') FROM public.notification_deliveries d
    JOIN public.notification_events e ON e.id = d.event_id WHERE e.organization_id = pg_temp.o(2) AND e.event_type = 'approver_digest'
    AND d.status <> 'sent'), 'skipped as nothing actionable');
  -- A due day with nothing actionable records one suppressed evaluation and no deliveries.
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-12 16:00:00+00') = 1, 'evaluated once');
  PERFORM pg_temp.assert((SELECT status FROM pg_temp.digests(pg_temp.o(2)) WHERE local_date = '2026-11-12') = 'suppressed', 'empty digest suppressed');
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-12 18:00:00+00') = 0, 'empty day not re-evaluated');
  PERFORM public.dispatch_notification_events();
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.notification_deliveries d JOIN public.notification_events e ON e.id = d.event_id
    WHERE e.context ->> 'localDate' = '2026-11-12' AND e.organization_id = pg_temp.o(2)), 'no empty digest deliveries');
END
$phase6c3_digest_emptied$;
RESET ROLE;

-- Frequencies, weekdays, weekly, digest off, master off, time zones and DST in organization 3,
-- with something actionable throughout.
INSERT INTO public.supply_requests (id, organization_id, requested_by, request_type, status)
VALUES ('6c300000-0000-4000-8000-000000000931', pg_temp.o(3), pg_temp.u(9), 'reorder', 'approved');
INSERT INTO public.organization_notification_settings (organization_id, sending_enabled, digest_enabled, digest_frequency, digest_send_hour, digest_weekday, timezone)
VALUES (pg_temp.o(3), true, true, 'weekdays', 8, 1, 'America/New_York');
DELETE FROM public.organization_notification_settings WHERE organization_id = pg_temp.o(2);

DO $phase6c3_frequencies$
BEGIN
  -- Weekdays only (New York, EST UTC-5 in November). 2026-11-14 Saturday, 15 Sunday, 16 Monday.
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-13 13:00:00+00') = 1, 'Friday sends');
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-14 13:00:00+00') = 0, 'Saturday skipped');
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-15 20:00:00+00') = 0, 'Sunday skipped');
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-16 12:59:00+00') = 0, 'Monday before 08:00');
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-16 13:00:00+00') = 1, 'Monday sends');
  -- Saturday 03:00Z is still Friday evening in New York: the Friday digest already exists.
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-14 03:00:00+00') = 0, 'local weekday, not UTC weekday');

  -- Weekly on Wednesday (3). 2026-11-18 Wednesday, 2026-11-25 next Wednesday.
  UPDATE public.organization_notification_settings SET digest_frequency = 'weekly', digest_weekday = 3 WHERE organization_id = pg_temp.o(3);
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-17 13:00:00+00') = 0, 'weekly: Tuesday skipped');
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-18 13:00:00+00') = 1, 'weekly: Wednesday sends');
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-18 20:00:00+00') = 0, 'weekly: once on the day');
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-19 13:00:00+00') = 0, 'weekly: Thursday skipped');
  -- Changing the weekday mid-week does not produce a second weekly digest that week.
  UPDATE public.organization_notification_settings SET digest_weekday = 5 WHERE organization_id = pg_temp.o(3);
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-20 13:00:00+00') = 0, 'weekly: one per ISO week after a weekday change');
  UPDATE public.organization_notification_settings SET digest_weekday = 3 WHERE organization_id = pg_temp.o(3);
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-25 13:00:00+00') = 1, 'weekly: next week');

  -- Frequency change on a day that already had a digest: still one per local date.
  UPDATE public.organization_notification_settings SET digest_frequency = 'daily' WHERE organization_id = pg_temp.o(3);
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-25 18:00:00+00') = 0, 'daily after weekly the same day: no second digest');
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-26 13:00:00+00') = 1, 'daily resumes next day');

  -- Digest off, then master off.
  UPDATE public.organization_notification_settings SET digest_enabled = false WHERE organization_id = pg_temp.o(3);
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-27 13:00:00+00') = 0, 'digest off');
  UPDATE public.organization_notification_settings SET digest_enabled = true, sending_enabled = false WHERE organization_id = pg_temp.o(3);
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-27 13:00:00+00') = 0, 'master off overrides digest preference');
  UPDATE public.organization_notification_settings SET sending_enabled = true WHERE organization_id = pg_temp.o(3);

  -- DST, New York. Fall back 2026-11-01 (01:00 happens twice): send hour 1 → one digest.
  UPDATE public.organization_notification_settings SET digest_send_hour = 1 WHERE organization_id = pg_temp.o(3);
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-01 05:00:00+00') = 1, 'fall back: first 01:00 EDT');
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-01 06:00:00+00') = 0, 'fall back: repeated 01:00 EST is not a second digest');
  -- Spring forward 2027-03-14 (02:00 does not exist): send hour 2 → sent at 03:00 EDT, once.
  UPDATE public.organization_notification_settings SET digest_send_hour = 2 WHERE organization_id = pg_temp.o(3);
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2027-03-14 06:59:00+00') = 0, 'spring forward: 01:59 EST not due');
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2027-03-14 07:00:00+00') = 1, 'spring forward: due at 03:00 EDT');
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2027-03-14 08:00:00+00') = 0, 'spring forward: once');
  -- Summer time: 08:00 EDT is 12:00Z.
  UPDATE public.organization_notification_settings SET digest_send_hour = 8 WHERE organization_id = pg_temp.o(3);
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2027-06-15 11:59:00+00') = 0
    AND public.enqueue_due_notification_digests('2027-06-15 12:00:00+00') = 1, 'EDT offset applied');

  -- A time zone ahead of UTC: Auckland (NZDT, UTC+13). 08:00 on 2026-11-11 local is 19:00Z on the 10th.
  UPDATE public.organization_notification_settings SET timezone = 'Pacific/Auckland' WHERE organization_id = pg_temp.o(3);
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-11-10 18:59:00+00') = 0
    AND public.enqueue_due_notification_digests('2026-11-10 19:00:00+00') = 1, 'Auckland 08:00');
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM pg_temp.digests(pg_temp.o(3)) WHERE local_date = '2026-11-11'), 'local date is the Auckland date');
END
$phase6c3_frequencies$;

-- Several organizations in different zones in one sweep: each evaluated on its own clock.
INSERT INTO public.organization_notification_settings (organization_id, sending_enabled, digest_enabled, digest_frequency, digest_send_hour, timezone)
VALUES (pg_temp.o(4), true, true, 'daily', 8, 'Europe/London'),
       (pg_temp.o(2), true, true, 'daily', 8, 'America/Los_Angeles');
INSERT INTO public.supply_requests (organization_id, requested_by, request_type, status)
VALUES (pg_temp.o(2), pg_temp.u(8), 'reorder', 'approved');
UPDATE public.organization_notification_settings SET timezone = 'America/New_York', digest_send_hour = 8 WHERE organization_id = pg_temp.o(3);
SET LOCAL ROLE service_role;
DO $phase6c3_multi_zone$
BEGIN
  -- 2026-12-01 13:00Z: London 13:00 (due), New York 08:00 (due), Los Angeles 05:00 (not yet).
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-12-01 13:00:00+00') = 2, 'London and New York due');
  PERFORM pg_temp.assert((SELECT status FROM pg_temp.digests(pg_temp.o(4)) WHERE local_date = '2026-12-01') = 'suppressed', 'London org: nothing actionable');
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM pg_temp.digests(pg_temp.o(3)) WHERE local_date = '2026-12-01' AND status = 'pending'), 'New York org pending');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM pg_temp.digests(pg_temp.o(2)) WHERE local_date = '2026-12-01'), 'Los Angeles not yet');
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests('2026-12-01 16:00:00+00') = 1, 'Los Angeles at its 08:00');
END
$phase6c3_multi_zone$;
RESET ROLE;

ROLLBACK;
