-- Phase 6C.3 rollback-only regression: the master sending switch is a durable delivery
-- boundary. Events created while an organization's sending is OFF must never become
-- deliverable later merely because sending is turned ON, whatever the order of operator
-- actions and Worker runs. Run against a disposable database after every migration through
-- 20261110120000_phase6c3_request_notifications.sql. Every fixture is rolled back.
--
-- Scenario A reproduces the defect found in review on caa29c3 (an event raised while OFF and
-- not yet dispatched was delivered once sending was turned ON); it fails there at its first
-- check. Concurrent enable/insert ordering (scenario F) is covered by
-- supabase/tests/phase6c3_race_check.sh.

BEGIN;

DO $guard$
BEGIN
  IF EXISTS (SELECT 1 FROM auth.users
             WHERE id BETWEEN '6c3b0000-0000-4000-8000-000000000001'::uuid AND '6c3b0000-0000-4000-8000-000000000099'::uuid)
     OR EXISTS (SELECT 1 FROM public.organizations
             WHERE id BETWEEN '6c3b0000-0000-4000-8000-000000000101'::uuid AND '6c3b0000-0000-4000-8000-000000000199'::uuid) THEN
    RAISE EXCEPTION 'Phase 6C.3 boundary rollback-test fixture IDs already exist';
  END IF;
END
$guard$;

CREATE FUNCTION pg_temp.assert(_condition boolean, _message text)
RETURNS void LANGUAGE plpgsql AS $$ BEGIN IF _condition IS NOT TRUE THEN RAISE EXCEPTION 'Check failed: %', _message; END IF; END; $$;
CREATE FUNCTION pg_temp.u(_n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('6c3b0000-0000-4000-8000-0000000000' || lpad(_n::text, 2, '0'))::uuid $$;
CREATE FUNCTION pg_temp.o(_n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('6c3b0000-0000-4000-8000-000000000' || (100 + _n)::text)::uuid $$;
-- Submit as the organization's staff member (user 3 of each organization block).
CREATE FUNCTION pg_temp.submit(_org integer, _label text)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE _request uuid;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', pg_temp.u(_org * 10 + 3)::text, true);
  _request := public.submit_supply_request(pg_temp.o(_org), 'reorder', NULL, NULL, NULL,
    jsonb_build_array(jsonb_build_object('freeTextItem', _label, 'quantity', 1)));
  PERFORM set_config('request.jwt.claim.sub', '', true);
  RETURN _request;
END $$;
CREATE FUNCTION pg_temp.decide(_org integer, _request uuid, _decision public.supply_request_status)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', pg_temp.u(_org * 10 + 2)::text, true);
  PERFORM public.decide_supply_request(pg_temp.o(_org), _request, _decision, 'Reason', NULL,
    (SELECT updated_at FROM public.supply_requests WHERE id = _request));
  PERFORM set_config('request.jwt.claim.sub', '', true);
END $$;
CREATE FUNCTION pg_temp.deliveries(_entity uuid) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM public.notification_deliveries d JOIN public.notification_events e ON e.id = d.event_id WHERE e.entity_id = _entity $$;
CREATE FUNCTION pg_temp.event_states(_entity uuid) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(event_type || ':' || status || ':' || coalesce(status_reason, ''), ',' ORDER BY event_type)
  FROM public.notification_events WHERE entity_id = _entity $$;
CREATE FUNCTION pg_temp.enable(_org integer, _on boolean) RETURNS void LANGUAGE sql AS $$
  SELECT public.set_organization_notification_sending(pg_temp.o(_org), _on) $$;

-- Organizations 1..4, each with owner (n1), admin (n2) and staff (n3); n = organization * 10.
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT pg_temp.u(org * 10 + n), 'authenticated', 'authenticated', 'boundary-' || org || '-' || n || '@example.invalid', '', now(), '{}', '{}', now(), now()
FROM generate_series(1, 4) org, generate_series(1, 3) n;
INSERT INTO public.organizations (id, name, created_by)
SELECT pg_temp.o(org), 'Boundary Org ' || org, pg_temp.u(org * 10 + 1) FROM generate_series(1, 4) org;
INSERT INTO public.teams (id, organization_id, name, active)
SELECT ('6c3b0000-0000-4000-8000-0000000002' || lpad(org::text, 2, '0'))::uuid, pg_temp.o(org), 'Team ' || org, true FROM generate_series(1, 4) org;
INSERT INTO public.locations (id, organization_id, name, active)
SELECT ('6c3b0000-0000-4000-8000-0000000003' || lpad(org::text, 2, '0'))::uuid, pg_temp.o(org), 'Room ' || org, true FROM generate_series(1, 4) org;
INSERT INTO public.organization_memberships (organization_id, user_id, role, active, default_team_id, default_location_id)
SELECT pg_temp.o(org), pg_temp.u(org * 10 + n), (ARRAY['owner', 'admin', 'staff']::public.org_role[])[n], true,
  ('6c3b0000-0000-4000-8000-0000000002' || lpad(org::text, 2, '0'))::uuid, ('6c3b0000-0000-4000-8000-0000000003' || lpad(org::text, 2, '0'))::uuid
FROM generate_series(1, 4) org, generate_series(1, 3) n;

-- ============================================================================================
-- A. Event while OFF, sending enabled before any Worker run (the reproduced defect).
-- ============================================================================================
DO $scenario_a$
DECLARE
  _before_on uuid;
BEGIN
  _before_on := pg_temp.submit(1, 'Raised while OFF');          -- 1-2. OFF, event, no dispatch
  PERFORM pg_temp.enable(1, true);                              -- 4. sending ON
  PERFORM public.dispatch_notification_events();                -- 5. first dispatch
  PERFORM pg_temp.assert(pg_temp.deliveries(_before_on) = 0,
    'A: an event raised while sending was OFF created deliveries after sending was turned ON');
  PERFORM pg_temp.assert(pg_temp.event_states(_before_on) = 'request_submitted:suppressed:created_before_sending_enabled',
    'A: suppression is recorded: ' || coalesce(pg_temp.event_states(_before_on), 'none'));
  PERFORM pg_temp.assert((SELECT count(*) FROM public.claim_notification_deliveries(100, 300)) = 0, 'A: nothing to send');
  PERFORM pg_catalog.set_config('boundary.a', _before_on::text, true);
END
$scenario_a$;

-- ============================================================================================
-- B. Event after enablement: delivered normally.
-- ============================================================================================
DO $scenario_b$
DECLARE
  _after_on uuid := pg_temp.submit(1, 'Raised while ON');
  _claimed integer;
BEGIN
  PERFORM public.dispatch_notification_events();
  PERFORM pg_temp.assert(pg_temp.deliveries(_after_on) = 2, 'B: owner and admin deliveries for an event after enablement');
  PERFORM pg_temp.assert(pg_temp.event_states(_after_on) = 'request_submitted:dispatched:', 'B: dispatched');
  SELECT count(*) INTO _claimed FROM public.claim_notification_deliveries(100, 300) c
  JOIN public.notification_deliveries d ON d.id = c.delivery_id JOIN public.notification_events e ON e.id = d.event_id
  WHERE e.entity_id = _after_on;
  PERFORM pg_temp.assert(_claimed = 2, 'B: both deliveries claimable');
  -- Outcome after enablement: one requester delivery.
  PERFORM pg_temp.decide(1, _after_on, 'approved');
  PERFORM public.dispatch_notification_events();
  PERFORM pg_temp.assert(pg_temp.deliveries(_after_on) = 3, 'B: approval delivered to the requester');
  -- The A event stays suppressed for good.
  PERFORM public.dispatch_notification_events();
  PERFORM pg_temp.assert(pg_temp.deliveries(current_setting('boundary.a')::uuid) = 0, 'B: the A event never replays');
END
$scenario_b$;

-- ============================================================================================
-- C. OFF -> ON -> OFF -> ON with events in every interval.
-- ============================================================================================
DO $scenario_c$
DECLARE
  _off1 uuid; _on1 uuid; _on1_dispatched uuid; _off2 uuid; _on2 uuid;
  _first timestamptz; _second timestamptz;
BEGIN
  _off1 := pg_temp.submit(2, 'OFF interval 1');
  PERFORM pg_temp.enable(2, true);
  _first := (SELECT sending_enabled_at FROM public.organization_notification_settings WHERE organization_id = pg_temp.o(2));
  PERFORM pg_temp.assert(_first IS NOT NULL, 'C: enabling records the boundary');
  -- Re-enabling while already ON does not move the boundary.
  PERFORM pg_temp.enable(2, true);
  PERFORM pg_temp.assert((SELECT sending_enabled_at FROM public.organization_notification_settings WHERE organization_id = pg_temp.o(2)) = _first,
    'C: ON -> ON keeps the boundary');
  -- An admin digest edit keeps it too, and a direct write cannot backdate it.
  PERFORM set_config('request.jwt.claim.sub', pg_temp.u(22)::text, true);
  PERFORM public.update_organization_notification_settings(pg_temp.o(2), true, 'weekly', 9, 4, 'America/Chicago');
  PERFORM set_config('request.jwt.claim.sub', '', true);
  UPDATE public.organization_notification_settings SET sending_enabled_at = '2000-01-01' WHERE organization_id = pg_temp.o(2);
  PERFORM pg_temp.assert((SELECT sending_enabled_at FROM public.organization_notification_settings WHERE organization_id = pg_temp.o(2)) = _first,
    'C: the boundary cannot be edited or backdated');

  _on1_dispatched := pg_temp.submit(2, 'ON interval 1, dispatched');
  PERFORM public.dispatch_notification_events();
  PERFORM pg_temp.assert(pg_temp.deliveries(_on1_dispatched) = 2, 'C: ON1 event dispatched');
  _on1 := pg_temp.submit(2, 'ON interval 1, not dispatched before OFF');
  PERFORM pg_temp.enable(2, false);
  _off2 := pg_temp.submit(2, 'OFF interval 2');
  PERFORM pg_temp.enable(2, true);
  _second := (SELECT sending_enabled_at FROM public.organization_notification_settings WHERE organization_id = pg_temp.o(2));
  PERFORM pg_temp.assert(_second > _first, 'C: OFF -> ON sets a new, later boundary');
  _on2 := pg_temp.submit(2, 'ON interval 2');
  PERFORM public.dispatch_notification_events();

  PERFORM pg_temp.assert(pg_temp.deliveries(_off1) = 0 AND pg_temp.event_states(_off1) LIKE '%created_before_sending_enabled',
    'C: OFF1 event never replays');
  PERFORM pg_temp.assert(pg_temp.deliveries(_off2) = 0 AND pg_temp.event_states(_off2) LIKE '%created_before_sending_enabled',
    'C: OFF2 event never replays');
  PERFORM pg_temp.assert(pg_temp.deliveries(_on1) = 0 AND pg_temp.event_states(_on1) LIKE '%created_before_sending_enabled',
    'C: an ON1 event still pending when sending went OFF is not valid under the new boundary');
  PERFORM pg_temp.assert(pg_temp.deliveries(_on2) = 2 AND pg_temp.event_states(_on2) = 'request_submitted:dispatched:',
    'C: ON2 event delivered');
  -- The ON1 deliveries queued before OFF are not sent under the new boundary either.
  PERFORM public.claim_notification_deliveries(100, 300);
  PERFORM pg_temp.assert((SELECT bool_and(d.status = 'skipped' AND d.status_reason = 'created_before_sending_enabled')
    FROM public.notification_deliveries d JOIN public.notification_events e ON e.id = d.event_id WHERE e.entity_id = _on1_dispatched),
    'C: deliveries queued in ON1 are skipped after OFF -> ON');
  PERFORM pg_temp.assert((SELECT bool_and(d.status = 'processing')
    FROM public.notification_deliveries d JOIN public.notification_events e ON e.id = d.event_id WHERE e.entity_id = _on2),
    'C: ON2 deliveries claimed normally');
END
$scenario_c$;

-- ============================================================================================
-- D. First production enablement after a backlog of historical events.
-- ============================================================================================
DO $scenario_d$
DECLARE
  _requests uuid[] := ARRAY[]::uuid[];
  _request uuid;
BEGIN
  FOR _i IN 1..6 LOOP
    _requests := _requests || pg_temp.submit(3, 'Historical ' || _i);
  END LOOP;
  PERFORM pg_temp.decide(3, _requests[1], 'approved');
  PERFORM pg_temp.decide(3, _requests[2], 'denied');
  PERFORM pg_temp.assert((SELECT count(*) FROM public.notification_events WHERE organization_id = pg_temp.o(3) AND status = 'pending') = 8,
    'D: eight historical events waiting (6 submissions, 1 approval, 1 denial)');
  PERFORM pg_temp.enable(3, true);
  PERFORM public.dispatch_notification_events();
  PERFORM public.claim_notification_deliveries(100, 300);
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.notification_deliveries WHERE organization_id = pg_temp.o(3)),
    'D: no historical immediate emails at first enablement');
  PERFORM pg_temp.assert((SELECT bool_and(status = 'suppressed' AND status_reason = 'created_before_sending_enabled')
    FROM public.notification_events WHERE organization_id = pg_temp.o(3)), 'D: every historical event suppressed with a reason');
  PERFORM pg_catalog.set_config('boundary.d1', _requests[3]::text, true);
END
$scenario_d$;

-- ============================================================================================
-- E. Digest after enablement: no pre-enable period, next scheduled digest summarizes current
--    state, no duplicate.
-- ============================================================================================
DO $scenario_e$
DECLARE
  _boundary timestamptz := (SELECT sending_enabled_at FROM public.organization_notification_settings WHERE organization_id = pg_temp.o(3));
  _local timestamp := _boundary AT TIME ZONE 'America/New_York';
  _next_slot timestamptz;
BEGIN
  -- Only organization 3's digest is under test here.
  UPDATE public.organization_notification_settings SET digest_enabled = false WHERE organization_id <> pg_temp.o(3);
  -- Daily at the boundary's own local hour: that hour's slot (hh:00) is before the boundary.
  UPDATE public.organization_notification_settings
  SET digest_enabled = true, digest_frequency = 'daily', timezone = 'America/New_York', digest_send_hour = extract(hour FROM _local)::integer
  WHERE organization_id = pg_temp.o(3);
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests(_boundary + interval '1 second') = 0,
    'E: no digest for a scheduled slot that precedes enablement');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.notification_events WHERE organization_id = pg_temp.o(3) AND event_type = 'approver_digest'),
    'E: nothing recorded for the pre-enable slot');
  -- The next day's slot is after the boundary: one digest of the current actionable state.
  _next_slot := (date_trunc('hour', _local) + interval '1 day') AT TIME ZONE 'America/New_York';
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests(_next_slot - interval '1 second') = 0, 'E: not before the next slot');
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests(_next_slot) = 1, 'E: next scheduled digest');
  PERFORM pg_temp.assert(public.enqueue_due_notification_digests(_next_slot + interval '10 minutes') = 0, 'E: no duplicate digest');
  PERFORM public.dispatch_notification_events();
  PERFORM pg_temp.assert((SELECT count(*) FROM public.notification_deliveries d JOIN public.notification_events e ON e.id = d.event_id
    WHERE e.organization_id = pg_temp.o(3) AND e.event_type = 'approver_digest') = 2, 'E: digest to the owner and admin');
  PERFORM pg_temp.assert((SELECT ((c.context -> 'digest') ->> 'totalCount')::integer FROM public.claim_notification_deliveries(100, 300) c
    WHERE c.event_type = 'approver_digest' LIMIT 1) = 5, 'E: the digest summarizes the current actionable requests (4 awaiting review, 1 approved not ordered)');
  -- Historical immediate events still never replay.
  PERFORM public.dispatch_notification_events();
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.notification_deliveries d JOIN public.notification_events e ON e.id = d.event_id
    WHERE e.organization_id = pg_temp.o(3) AND e.event_type <> 'approver_digest'), 'E: no historical immediate emails');

  -- An organization that has never been enabled gets no digest at all.
  INSERT INTO public.organization_notification_settings (organization_id, sending_enabled, digest_enabled)
  VALUES (pg_temp.o(4), false, true);
  PERFORM pg_temp.submit(4, 'Never enabled');
  PERFORM public.enqueue_due_notification_digests(now() + interval '2 days');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.notification_events WHERE organization_id = pg_temp.o(4) AND event_type = 'approver_digest'),
    'E: never-enabled organization gets no digest');
  PERFORM pg_temp.assert((SELECT sending_enabled_at IS NULL FROM public.organization_notification_settings WHERE organization_id = pg_temp.o(4)),
    'E: no boundary until first enabled');
END
$scenario_e$;

ROLLBACK;
