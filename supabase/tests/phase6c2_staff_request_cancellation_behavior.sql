-- Phase 6C.2 rollback-only behavioral verification: staff request cancellation.
-- Run against a disposable database after 20261020120100_phase6c2_staff_request_cancellation.sql.
-- All fixture, request, and audit writes occur inside this transaction and are rolled back.

BEGIN;

DO $phase6c2_fixture_guard$
BEGIN
  IF EXISTS (
    SELECT 1 FROM auth.users
    WHERE id BETWEEN '6c200000-0000-4000-8000-000000000001'::uuid
      AND '6c200000-0000-4000-8000-000000000099'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.organizations
    WHERE id BETWEEN '6c200000-0000-4000-8000-000000000101'::uuid
      AND '6c200000-0000-4000-8000-000000000199'::uuid
  ) THEN
    RAISE EXCEPTION 'Phase 6C.2 rollback-test fixture IDs already exist';
  END IF;
END
$phase6c2_fixture_guard$;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
VALUES
  ('6c200000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'phase6c2-admin@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('6c200000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'phase6c2-staff@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('6c200000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'phase6c2-other-staff@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('6c200000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'phase6c2-other-owner@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('6c200000-0000-4000-8000-000000000005', 'authenticated', 'authenticated', 'phase6c2-former-staff@example.invalid', '', now(), '{}', '{}', now(), now());

INSERT INTO public.organizations (id, name, created_by)
VALUES
  ('6c200000-0000-4000-8000-000000000101', 'Phase 6C.2 Organization', '6c200000-0000-4000-8000-000000000001'),
  ('6c200000-0000-4000-8000-000000000102', 'Phase 6C.2 Other Organization', '6c200000-0000-4000-8000-000000000004');

INSERT INTO public.teams (id, organization_id, name, active)
VALUES
  ('6c200000-0000-4000-8000-000000000111', '6c200000-0000-4000-8000-000000000101', 'Phase 6C.2 Football', true),
  ('6c200000-0000-4000-8000-000000000114', '6c200000-0000-4000-8000-000000000102', 'Phase 6C.2 Other Team', true);

INSERT INTO public.locations (id, organization_id, name, active)
VALUES
  ('6c200000-0000-4000-8000-000000000121', '6c200000-0000-4000-8000-000000000101', 'Phase 6C.2 Main Room', true),
  ('6c200000-0000-4000-8000-000000000124', '6c200000-0000-4000-8000-000000000102', 'Phase 6C.2 Other Location', true);

INSERT INTO public.organization_memberships (
  id, organization_id, user_id, role, active, default_team_id, default_location_id
)
VALUES
  ('6c200000-0000-4000-8000-000000000131', '6c200000-0000-4000-8000-000000000101', '6c200000-0000-4000-8000-000000000001', 'admin', true, NULL, NULL),
  ('6c200000-0000-4000-8000-000000000132', '6c200000-0000-4000-8000-000000000101', '6c200000-0000-4000-8000-000000000002', 'staff', true,
    '6c200000-0000-4000-8000-000000000111', '6c200000-0000-4000-8000-000000000121'),
  ('6c200000-0000-4000-8000-000000000133', '6c200000-0000-4000-8000-000000000101', '6c200000-0000-4000-8000-000000000003', 'staff', true,
    '6c200000-0000-4000-8000-000000000111', '6c200000-0000-4000-8000-000000000121'),
  ('6c200000-0000-4000-8000-000000000134', '6c200000-0000-4000-8000-000000000102', '6c200000-0000-4000-8000-000000000004', 'owner', true,
    '6c200000-0000-4000-8000-000000000114', '6c200000-0000-4000-8000-000000000124'),
  ('6c200000-0000-4000-8000-000000000135', '6c200000-0000-4000-8000-000000000101', '6c200000-0000-4000-8000-000000000005', 'staff', false,
    '6c200000-0000-4000-8000-000000000111', '6c200000-0000-4000-8000-000000000121');

INSERT INTO public.products (
  id, organization_id, name, normalized_name, description, unit_of_measure, active, staff_requestable
)
VALUES ('6c200000-0000-4000-8000-000000000601', '6c200000-0000-4000-8000-000000000101',
  'Phase 6C.2 Tape', 'phase 6c.2 tape', NULL, 'roll', true, true);

-- Staff-owned requests in every later lifecycle status, one submitted request owned by
-- another staff member, and one owned by the now-deactivated member.
INSERT INTO public.supply_requests (
  id, organization_id, requested_by, request_type, team_id, location_id, notes, status
)
SELECT
  fixture.id::uuid, '6c200000-0000-4000-8000-000000000101', fixture.requester::uuid, 'new_item',
  '6c200000-0000-4000-8000-000000000111', '6c200000-0000-4000-8000-000000000121',
  'Fixture ' || fixture.status, fixture.status::public.supply_request_status
FROM (VALUES
  ('6c200000-0000-4000-8000-000000000901', 'under_review', '6c200000-0000-4000-8000-000000000002'),
  ('6c200000-0000-4000-8000-000000000902', 'approved', '6c200000-0000-4000-8000-000000000002'),
  ('6c200000-0000-4000-8000-000000000903', 'ordered', '6c200000-0000-4000-8000-000000000002'),
  ('6c200000-0000-4000-8000-000000000904', 'received', '6c200000-0000-4000-8000-000000000002'),
  ('6c200000-0000-4000-8000-000000000905', 'completed', '6c200000-0000-4000-8000-000000000002'),
  ('6c200000-0000-4000-8000-000000000906', 'denied', '6c200000-0000-4000-8000-000000000002'),
  ('6c200000-0000-4000-8000-000000000907', 'submitted', '6c200000-0000-4000-8000-000000000003'),
  ('6c200000-0000-4000-8000-000000000908', 'submitted', '6c200000-0000-4000-8000-000000000005')
) AS fixture(id, status, requester);
INSERT INTO public.supply_request_items (organization_id, supply_request_id, free_text_item, quantity)
SELECT organization_id, id, 'Fixture line', 1
FROM public.supply_requests
WHERE id BETWEEN '6c200000-0000-4000-8000-000000000901' AND '6c200000-0000-4000-8000-000000000908';

-- Runs as the caller's role; asserts the exact user-safe error and SQLSTATE, and that the
-- rejected attempt changed nothing.
CREATE FUNCTION pg_temp.phase6c2_expect_cancel_error(
  _organization_id uuid,
  _request_id uuid,
  _expected_message text,
  _expected_state text
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  BEGIN
    PERFORM public.cancel_submitted_supply_request(_organization_id, _request_id);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> _expected_message OR SQLSTATE <> _expected_state THEN
      RAISE EXCEPTION 'Expected "%" (%), got "%" (%)',
        _expected_message, _expected_state, SQLERRM, SQLSTATE;
    END IF;
    RETURN;
  END;
  RAISE EXCEPTION 'Cancellation unexpectedly succeeded; expected "%"', _expected_message;
END;
$$;

-- Snapshot of every fixture request's status and audit count, checked after the
-- rejected attempts below.
CREATE TEMP TABLE phase6c2_before AS
SELECT request.id, request.status, request.updated_at,
  (SELECT count(*) FROM public.supply_request_updates u WHERE u.supply_request_id = request.id) AS updates
FROM public.supply_requests request
WHERE request.organization_id = '6c200000-0000-4000-8000-000000000101';
GRANT SELECT ON phase6c2_before TO authenticated;

-- Admin baseline for the command center's "awaiting approval" attention count.
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c200000-0000-4000-8000-000000000001', true);
SELECT pg_catalog.set_config(
  'phase6c2.awaiting_before',
  (public.get_budget_purchasing_overview('6c200000-0000-4000-8000-000000000101')
    -> 'attention' ->> 'awaitingApprovalCount'),
  true
);

-- The requester submits a request with a structured line, a custom line, and a note.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c200000-0000-4000-8000-000000000002', true);
DO $phase6c2_submit$
DECLARE
  _request_id uuid;
BEGIN
  _request_id := public.submit_supply_request(
    '6c200000-0000-4000-8000-000000000101', 'reorder', NULL, NULL, 'Needed for Saturday',
    jsonb_build_array(
      jsonb_build_object('productId', '6c200000-0000-4000-8000-000000000601', 'quantity', 3),
      jsonb_build_object('freeTextItem', 'Knee sleeve', 'quantity', 2)
    )
  );
  PERFORM pg_catalog.set_config('phase6c2.request_id', _request_id::text, true);
  -- A normal edit still works on a request with lines, and is audited, before cancelling.
  PERFORM public.update_submitted_supply_request(
    '6c200000-0000-4000-8000-000000000101', _request_id, NULL, NULL, NULL, 'Needed for Saturday',
    jsonb_build_array(
      jsonb_build_object('productId', '6c200000-0000-4000-8000-000000000601', 'quantity', 4),
      jsonb_build_object('freeTextItem', 'Knee sleeve', 'quantity', 2)
    )
  );
  IF (SELECT status FROM public.supply_requests WHERE id = _request_id) <> 'submitted'
     OR (SELECT quantity FROM public.supply_request_items
         WHERE supply_request_id = _request_id AND product_id IS NOT NULL) <> 4 THEN
    RAISE EXCEPTION 'Edit-while-submitted regressed';
  END IF;
END
$phase6c2_submit$;

-- Cross-member and cross-organization callers cannot cancel it.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c200000-0000-4000-8000-000000000003', true);
SELECT pg_temp.phase6c2_expect_cancel_error('6c200000-0000-4000-8000-000000000101',
  current_setting('phase6c2.request_id')::uuid, 'Supply request not found', 'P0002');
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c200000-0000-4000-8000-000000000004', true);
SELECT pg_temp.phase6c2_expect_cancel_error('6c200000-0000-4000-8000-000000000101',
  current_setting('phase6c2.request_id')::uuid, 'Not a member of this organization', '42501');
SELECT pg_temp.phase6c2_expect_cancel_error('6c200000-0000-4000-8000-000000000102',
  current_setting('phase6c2.request_id')::uuid, 'Supply request not found', 'P0002');
-- Admins get no cancel action: the RPC is requester-only, even for an admin of the org.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c200000-0000-4000-8000-000000000001', true);
SELECT pg_temp.phase6c2_expect_cancel_error('6c200000-0000-4000-8000-000000000101',
  current_setting('phase6c2.request_id')::uuid, 'Supply request not found', 'P0002');
-- A deactivated member cannot cancel their own request.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c200000-0000-4000-8000-000000000005', true);
SELECT pg_temp.phase6c2_expect_cancel_error('6c200000-0000-4000-8000-000000000101',
  '6c200000-0000-4000-8000-000000000908', 'Not a member of this organization', '42501');
-- Unauthenticated.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '', true);
SELECT pg_temp.phase6c2_expect_cancel_error('6c200000-0000-4000-8000-000000000101',
  current_setting('phase6c2.request_id')::uuid, 'Not authenticated', '42501');

-- The requester cannot cancel another member's request or a request outside the window.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c200000-0000-4000-8000-000000000002', true);
SELECT pg_temp.phase6c2_expect_cancel_error('6c200000-0000-4000-8000-000000000101',
  '6c200000-0000-4000-8000-000000000907', 'Supply request not found', 'P0002');
SELECT pg_temp.phase6c2_expect_cancel_error('6c200000-0000-4000-8000-000000000101', fixture.id,
  'This request has already entered review and can no longer be cancelled.', '55000')
FROM (VALUES
  ('6c200000-0000-4000-8000-000000000901'::uuid),
  ('6c200000-0000-4000-8000-000000000902'::uuid),
  ('6c200000-0000-4000-8000-000000000903'::uuid),
  ('6c200000-0000-4000-8000-000000000904'::uuid),
  ('6c200000-0000-4000-8000-000000000905'::uuid)
) AS fixture(id);
SELECT pg_temp.phase6c2_expect_cancel_error('6c200000-0000-4000-8000-000000000101',
  '6c200000-0000-4000-8000-000000000906',
  'This request has been declined and can no longer be cancelled.', '55000');

-- Rejected attempts wrote nothing.
DO $phase6c2_rejections_wrote_nothing$
BEGIN
  IF EXISTS (
    SELECT 1 FROM phase6c2_before before
    JOIN public.supply_requests request ON request.id = before.id
    WHERE request.status IS DISTINCT FROM before.status
       OR request.updated_at IS DISTINCT FROM before.updated_at
       OR (SELECT count(*) FROM public.supply_request_updates u WHERE u.supply_request_id = before.id)
          <> before.updates
  ) THEN
    RAISE EXCEPTION 'A rejected cancellation changed a request or its history';
  END IF;
END
$phase6c2_rejections_wrote_nothing$;

-- Direct API writes cannot cancel: the 6C lifecycle guard rejects a status change, and
-- staff cannot forge a cancellation audit row.
DO $phase6c2_no_direct_cancel$
BEGIN
  -- Staff have no UPDATE policy on requests, so the row is invisible to the write;
  -- an admin's direct status write is rejected by the 6C lifecycle guard (below).
  BEGIN
    UPDATE public.supply_requests SET status = 'cancelled'
    WHERE id = current_setting('phase6c2.request_id')::uuid;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  IF (SELECT status FROM public.supply_requests
      WHERE id = current_setting('phase6c2.request_id')::uuid) <> 'submitted' THEN
    RAISE EXCEPTION 'Direct status update cancelled the request';
  END IF;
  BEGIN
    INSERT INTO public.supply_request_updates
      (organization_id, supply_request_id, author_id, status_from, status_to, event_kind)
    VALUES ('6c200000-0000-4000-8000-000000000101', current_setting('phase6c2.request_id')::uuid,
      '6c200000-0000-4000-8000-000000000002', 'submitted', 'cancelled', 'requester_cancelled');
    RAISE EXCEPTION 'Staff forged a cancellation audit row';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END
$phase6c2_no_direct_cancel$;

-- The requester cancels their own submitted request.
DO $phase6c2_cancel$
DECLARE
  _request_id uuid := current_setting('phase6c2.request_id')::uuid;
  _lines_before jsonb;
  _result jsonb;
  _request public.supply_requests%ROWTYPE;
  _request_count bigint;
BEGIN
  SELECT count(*) INTO _request_count FROM public.supply_requests;
  SELECT jsonb_agg(to_jsonb(item) ORDER BY item.id) INTO _lines_before
  FROM public.supply_request_items item WHERE item.supply_request_id = _request_id;

  _result := public.cancel_submitted_supply_request('6c200000-0000-4000-8000-000000000101', _request_id);
  SELECT * INTO _request FROM public.supply_requests WHERE id = _request_id;

  IF (_result->>'id')::uuid <> _request_id OR _result->>'status' <> 'cancelled'
     OR (_result->>'alreadyCancelled')::boolean OR _result->>'cancelledAt' IS NULL THEN
    RAISE EXCEPTION 'Unexpected cancel result: %', _result;
  END IF;
  IF _request.status <> 'cancelled' THEN
    RAISE EXCEPTION 'Request was not cancelled: %', row_to_json(_request);
  END IF;
  -- Not deleted, not duplicated, not converted to denied; contents and note intact.
  IF (SELECT count(*) FROM public.supply_requests) <> _request_count THEN
    RAISE EXCEPTION 'Cancelling created or removed a request';
  END IF;
  IF _request.notes IS DISTINCT FROM 'Needed for Saturday'
     OR _request.requested_by <> '6c200000-0000-4000-8000-000000000002'
     OR _request.team_id <> '6c200000-0000-4000-8000-000000000111'
     OR _request.location_id <> '6c200000-0000-4000-8000-000000000121'
     OR _request.request_type <> 'reorder' THEN
    RAISE EXCEPTION 'Cancelling rewrote the request: %', row_to_json(_request);
  END IF;
  IF (SELECT jsonb_agg(to_jsonb(item) ORDER BY item.id)
      FROM public.supply_request_items item WHERE item.supply_request_id = _request_id)
     IS DISTINCT FROM _lines_before
     OR jsonb_array_length(_lines_before) <> 2 THEN
    RAISE EXCEPTION 'Cancelling changed the request lines';
  END IF;

  PERFORM pg_catalog.set_config('phase6c2.cancelled_at', _result->>'cancelledAt', true);
  -- No commitment exists or was created.
  IF EXISTS (SELECT 1 FROM public.supply_request_commitments WHERE supply_request_id = _request_id) THEN
    RAISE EXCEPTION 'Cancellation created a commitment';
  END IF;
END
$phase6c2_cancel$;

-- A second cancellation is an idempotent no-op: no new event, no row write.
DO $phase6c2_repeat$
DECLARE
  _request_id uuid := current_setting('phase6c2.request_id')::uuid;
  _updated_at timestamptz;
  _first_cancelled_at timestamptz := current_setting('phase6c2.cancelled_at')::timestamptz;
  _result jsonb;
BEGIN
  SELECT updated_at INTO _updated_at FROM public.supply_requests WHERE id = _request_id;
  _result := public.cancel_submitted_supply_request('6c200000-0000-4000-8000-000000000101', _request_id);
  IF NOT (_result->>'alreadyCancelled')::boolean
     OR (_result->>'cancelledAt')::timestamptz <> _first_cancelled_at THEN
    RAISE EXCEPTION 'Repeat cancellation was not idempotent: %', _result;
  END IF;
  IF (SELECT updated_at FROM public.supply_requests WHERE id = _request_id) <> _updated_at THEN
    RAISE EXCEPTION 'Repeat cancellation touched the request';
  END IF;
END
$phase6c2_repeat$;

-- The stored audit trail, read as the table owner (staff RLS hides rows without a
-- staff-visible note): exactly one cancellation event, authored by the requester, after
-- the preserved edit event, even after the repeat attempt.
RESET ROLE;
DO $phase6c2_audit_trail$
DECLARE
  _request_id uuid := current_setting('phase6c2.request_id')::uuid;
  _event public.supply_request_updates%ROWTYPE;
BEGIN
  IF (SELECT count(*) FROM public.supply_request_updates
      WHERE supply_request_id = _request_id AND event_kind = 'requester_cancelled') <> 1
     OR (SELECT count(*) FROM public.supply_request_updates
         WHERE supply_request_id = _request_id AND event_kind = 'requester_edited') <> 1
     OR (SELECT count(*) FROM public.supply_request_updates
         WHERE supply_request_id = _request_id) <> 2 THEN
    RAISE EXCEPTION 'Expected exactly one edit and one cancellation event';
  END IF;
  SELECT * INTO _event FROM public.supply_request_updates
  WHERE supply_request_id = _request_id AND event_kind = 'requester_cancelled';
  IF _event.author_id <> '6c200000-0000-4000-8000-000000000002'
     OR _event.organization_id <> '6c200000-0000-4000-8000-000000000101'
     OR _event.status_from <> 'submitted' OR _event.status_to <> 'cancelled'
     OR _event.internal_note IS NOT NULL OR _event.staff_visible_note IS NOT NULL
     OR _event.created_at <> current_setting('phase6c2.cancelled_at')::timestamptz THEN
    RAISE EXCEPTION 'Unexpected cancellation event: %', row_to_json(_event);
  END IF;
END
$phase6c2_audit_trail$;
SET LOCAL ROLE authenticated;

-- Another member still cannot observe or replay the cancellation.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c200000-0000-4000-8000-000000000003', true);
SELECT pg_temp.phase6c2_expect_cancel_error('6c200000-0000-4000-8000-000000000101',
  current_setting('phase6c2.request_id')::uuid, 'Supply request not found', 'P0002');
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c200000-0000-4000-8000-000000000002', true);

-- A cancelled request cannot be edited.
DO $phase6c2_no_edit_after_cancel$
BEGIN
  BEGIN
    PERFORM public.update_submitted_supply_request(
      '6c200000-0000-4000-8000-000000000101', current_setting('phase6c2.request_id')::uuid,
      NULL, NULL, NULL, 'Must not persist',
      jsonb_build_array(jsonb_build_object('freeTextItem', 'New line', 'quantity', 1))
    );
    RAISE EXCEPTION 'Edit after cancellation unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'This request has been cancelled and can no longer be edited.' OR SQLSTATE <> '55000' THEN
      RAISE;
    END IF;
  END;
  IF (SELECT notes FROM public.supply_requests WHERE id = current_setting('phase6c2.request_id')::uuid)
     <> 'Needed for Saturday' THEN
    RAISE EXCEPTION 'Rejected edit changed a cancelled request';
  END IF;
END
$phase6c2_no_edit_after_cancel$;

-- The staff-safe timeline projection returns the cancellation as a stored event, with
-- no internal note column.
DO $phase6c2_staff_timeline$
DECLARE
  _events jsonb;
BEGIN
  -- Ordered by kind: a rollback-only suite runs in one transaction, so now() is fixed and
  -- both events share a timestamp here (in production they are separate transactions).
  SELECT jsonb_agg(jsonb_build_object('kind', event_kind, 'to', status_to) ORDER BY event_kind DESC)
  INTO _events
  FROM public.list_staff_supply_request_updates(
    '6c200000-0000-4000-8000-000000000101', ARRAY[current_setting('phase6c2.request_id')::uuid]
  );
  IF _events <> jsonb_build_array(
    jsonb_build_object('kind', 'requester_edited', 'to', NULL),
    jsonb_build_object('kind', 'requester_cancelled', 'to', 'cancelled')
  ) THEN
    RAISE EXCEPTION 'Unexpected staff timeline: %', _events;
  END IF;
END
$phase6c2_staff_timeline$;

-- Admin view: the request leaves the awaiting-approval count, cannot be decided or
-- transitioned, and keeps its full audit history.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c200000-0000-4000-8000-000000000001', true);
DO $phase6c2_admin$
DECLARE
  _request_id uuid := current_setting('phase6c2.request_id')::uuid;
  _overview jsonb := public.get_budget_purchasing_overview('6c200000-0000-4000-8000-000000000101');
  _updated_at timestamptz;
BEGIN
  -- Baseline had the 3 fixture pending requests (under_review + two submitted) and not
  -- the new one; the new request was submitted then cancelled, so the count is unchanged.
  IF (_overview -> 'attention' ->> 'awaitingApprovalCount')::integer
     <> current_setting('phase6c2.awaiting_before')::integer THEN
    RAISE EXCEPTION 'Cancelled request counted as awaiting approval: %', _overview -> 'attention';
  END IF;
  SELECT updated_at INTO _updated_at FROM public.supply_requests WHERE id = _request_id;
  BEGIN
    PERFORM public.decide_supply_request(
      '6c200000-0000-4000-8000-000000000101', _request_id, 'approved', NULL, NULL, _updated_at
    );
    RAISE EXCEPTION 'Admin approved a cancelled request';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'This request has already been decided. Refresh the inbox.' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.transition_supply_request(
      '6c200000-0000-4000-8000-000000000101', _request_id, 'under_review'
    );
    RAISE EXCEPTION 'Admin reopened a cancelled request';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'Invalid supply request transition: cancelled to under_review' THEN RAISE; END IF;
  END;
  -- No admin path into 'cancelled' from any status.
  BEGIN
    PERFORM public.transition_supply_request(
      '6c200000-0000-4000-8000-000000000101', '6c200000-0000-4000-8000-000000000902', 'cancelled'
    );
    RAISE EXCEPTION 'Admin cancelled a request through the transition RPC';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'Invalid supply request transition: approved to cancelled' THEN RAISE; END IF;
  END;
  IF EXISTS (SELECT 1 FROM public.supply_request_commitments WHERE supply_request_id = _request_id) THEN
    RAISE EXCEPTION 'Admin attempts created a commitment';
  END IF;
  IF (SELECT status FROM public.supply_requests WHERE id = _request_id) <> 'cancelled'
     OR (SELECT count(*) FROM public.supply_request_updates WHERE supply_request_id = _request_id) <> 2 THEN
    RAISE EXCEPTION 'Admin attempts changed the cancelled request or its history';
  END IF;
  -- Admins can still read the whole history, including the cancellation event.
  IF NOT EXISTS (
    SELECT 1 FROM public.supply_request_updates
    WHERE supply_request_id = _request_id AND event_kind = 'requester_cancelled'
  ) THEN
    RAISE EXCEPTION 'Admin cannot see the cancellation event';
  END IF;
  -- An admin's direct status write cannot cancel either.
  BEGIN
    UPDATE public.supply_requests SET status = 'cancelled'
    WHERE id = '6c200000-0000-4000-8000-000000000907';
    RAISE EXCEPTION 'Admin direct status update to cancelled unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  -- Even an admin cannot forge a cancelled status row outside the requester event shape.
  BEGIN
    INSERT INTO public.supply_request_updates
      (organization_id, supply_request_id, author_id, status_from, status_to)
    VALUES ('6c200000-0000-4000-8000-000000000101', '6c200000-0000-4000-8000-000000000901',
      '6c200000-0000-4000-8000-000000000001', 'under_review', 'cancelled');
    RAISE EXCEPTION 'Admin inserted a non-requester cancellation row';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END
$phase6c2_admin$;

-- Denied and completed behavior is unchanged: the edit RPC keeps its 6C messages.
SELECT pg_catalog.set_config('request.jwt.claim.sub', '6c200000-0000-4000-8000-000000000002', true);
DO $phase6c2_denied_completed_unchanged$
BEGIN
  BEGIN
    PERFORM public.update_submitted_supply_request(
      '6c200000-0000-4000-8000-000000000101', '6c200000-0000-4000-8000-000000000906',
      NULL, NULL, NULL, NULL, jsonb_build_array(jsonb_build_object('freeTextItem', 'X', 'quantity', 1))
    );
    RAISE EXCEPTION 'Edit of denied request succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'This request has been declined and can no longer be edited.' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.update_submitted_supply_request(
      '6c200000-0000-4000-8000-000000000101', '6c200000-0000-4000-8000-000000000905',
      NULL, NULL, NULL, NULL, jsonb_build_array(jsonb_build_object('freeTextItem', 'X', 'quantity', 1))
    );
    RAISE EXCEPTION 'Edit of completed request succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'This request has already entered review and can no longer be edited.' THEN RAISE; END IF;
  END;
END
$phase6c2_denied_completed_unchanged$;

RESET ROLE;

-- The cancellation RPC is callable by authenticated users only.
DO $phase6c2_grants$
BEGIN
  IF has_function_privilege('anon', 'public.cancel_submitted_supply_request(uuid,uuid)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.cancel_submitted_supply_request(uuid,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Unexpected cancel_submitted_supply_request grants';
  END IF;
END
$phase6c2_grants$;

SELECT 'phase6c2 staff request cancellation behavior passed' AS result;

ROLLBACK;
