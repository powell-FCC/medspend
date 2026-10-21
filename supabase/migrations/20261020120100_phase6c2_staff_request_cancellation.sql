-- Phase 6C.2: staff request cancellation, step 2 of 2.
--
-- A requester may cancel their own request in exactly the Phase 6C edit window:
-- status 'submitted' and no commitment. Cancellation is a lifecycle event, not a
-- deletion: the request row, its lines, its note, and its audit history are kept, the
-- status becomes the terminal 'cancelled', and one requester_cancelled audit row records
-- who cancelled it and when.
--
-- Commitments are only created at approval (Phase 6A.2), so a cancellable request never
-- has one. Cancellation touches no commitment, budget, purchasing, inventory, invoice,
-- or pricing data. No admin path to 'cancelled' is added: the transition matrix in
-- apply_supply_request_transition has no entry for it, so it is unreachable there and
-- terminal ('Invalid supply request transition: cancelled to X').
--
-- Requires 20261020120000_phase6c2_cancelled_request_status.sql to have committed.

BEGIN;

DO $phase6c2_preflight$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_enum enum_value
    WHERE enum_value.enumtypid = 'public.supply_request_status'::regtype
      AND enum_value.enumlabel = 'cancelled'
  ) THEN
    RAISE EXCEPTION 'Phase 6C.2 requires the cancelled supply_request_status value';
  END IF;
  IF pg_catalog.to_regprocedure(
    'public.update_submitted_supply_request(uuid,uuid,public.supply_request_type,uuid,uuid,text,jsonb)'
  ) IS NULL THEN
    RAISE EXCEPTION 'Phase 6C.2 requires the Phase 6C update_submitted_supply_request RPC';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_constraint
    WHERE conrelid = 'public.supply_request_updates'::regclass
      AND conname = 'supply_request_updates_event_kind_check'
  ) THEN
    RAISE EXCEPTION 'Phase 6C.2 requires the Phase 6C event_kind check constraint';
  END IF;
  IF pg_catalog.to_regprocedure('public.cancel_submitted_supply_request(uuid,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'Phase 6C.2 cancel_submitted_supply_request already exists unexpectedly';
  END IF;
  IF EXISTS (SELECT 1 FROM public.supply_requests WHERE status = 'cancelled')
     OR EXISTS (SELECT 1 FROM public.supply_request_updates WHERE status_to = 'cancelled') THEN
    RAISE EXCEPTION 'Phase 6C.2 found cancelled requests before the cancellation workflow exists';
  END IF;
END
$phase6c2_preflight$;

-- The audit history gains one more requester event. A cancellation row always records
-- exactly submitted -> cancelled and never carries a note, so it cannot smuggle an admin
-- note to staff. A row moving a request to 'cancelled' must be a requester cancellation,
-- so the lifecycle event cannot be forged as an ordinary status update. Every existing
-- row satisfies the new constraint (no 'cancelled' rows exist; checked above).
ALTER TABLE public.supply_request_updates
  DROP CONSTRAINT supply_request_updates_event_kind_check,
  ADD CONSTRAINT supply_request_updates_event_kind_check CHECK (
    (
      event_kind IS NULL
      AND status_to IS DISTINCT FROM 'cancelled'
    )
    OR (
      event_kind = 'requester_edited'
      AND status_from IS NULL
      AND status_to IS NULL
      AND internal_note IS NULL
      AND staff_visible_note IS NULL
    )
    OR (
      event_kind = 'requester_cancelled'
      AND status_from = 'submitted'
      AND status_to = 'cancelled'
      AND internal_note IS NULL
      AND staff_visible_note IS NULL
    )
  );

-- The canonical cancellation boundary. Authorization and lifecycle rules are the Phase
-- 6C edit rules, in the same order, under the same request row lock taken by
-- update_submitted_supply_request, transition_supply_request, decide_supply_request,
-- and commitment creation: a cancellation and an admin decision serialize, and
-- whichever commits second sees the other's status.
CREATE FUNCTION public.cancel_submitted_supply_request(
  _organization_id uuid,
  _request_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid uuid := auth.uid();
  _request public.supply_requests%ROWTYPE;
  _cancelled_at timestamptz;
BEGIN
  IF _uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;
  IF NOT public.is_org_member(_organization_id, _uid) THEN
    RAISE EXCEPTION 'Not a member of this organization' USING ERRCODE = '42501';
  END IF;

  SELECT *
  INTO _request
  FROM public.supply_requests
  WHERE id = _request_id
    AND organization_id = _organization_id
  FOR UPDATE;
  -- Another member's request is indistinguishable from a missing one.
  IF NOT FOUND OR _request.requested_by IS DISTINCT FROM _uid THEN
    RAISE EXCEPTION 'Supply request not found' USING ERRCODE = 'P0002';
  END IF;

  -- A repeated cancellation (double tap, retry after a lost response) is a no-op: no
  -- second event, no row write, and the original cancellation time is returned.
  IF _request.status = 'cancelled' THEN
    SELECT update_row.created_at
    INTO _cancelled_at
    FROM public.supply_request_updates update_row
    WHERE update_row.supply_request_id = _request.id
      AND update_row.organization_id = _organization_id
      AND update_row.event_kind = 'requester_cancelled'
    ORDER BY update_row.created_at
    LIMIT 1;
    RETURN jsonb_build_object(
      'id', _request.id,
      'status', _request.status,
      'alreadyCancelled', true,
      'cancelledAt', _cancelled_at,
      'updatedAt', _request.updated_at
    );
  END IF;
  IF _request.status = 'denied' THEN
    RAISE EXCEPTION 'This request has been declined and can no longer be cancelled.'
      USING ERRCODE = '55000';
  END IF;
  IF _request.status <> 'submitted' OR EXISTS (
    SELECT 1
    FROM public.supply_request_commitments commitment
    WHERE commitment.supply_request_id = _request.id
      AND commitment.organization_id = _organization_id
  ) THEN
    RAISE EXCEPTION 'This request has already entered review and can no longer be cancelled.'
      USING ERRCODE = '55000';
  END IF;

  -- Status only. Lines, note, team, location, and request type are left untouched.
  UPDATE public.supply_requests
  SET status = 'cancelled'
  WHERE id = _request.id
    AND organization_id = _organization_id;

  INSERT INTO public.supply_request_updates
    (organization_id, supply_request_id, author_id, status_from, status_to, event_kind)
  VALUES
    (_organization_id, _request.id, _uid, 'submitted', 'cancelled', 'requester_cancelled')
  RETURNING created_at INTO _cancelled_at;

  SELECT * INTO _request FROM public.supply_requests WHERE id = _request.id;
  RETURN jsonb_build_object(
    'id', _request.id,
    'status', _request.status,
    'alreadyCancelled', false,
    'cancelledAt', _cancelled_at,
    'updatedAt', _request.updated_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_submitted_supply_request(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_submitted_supply_request(uuid, uuid) TO authenticated;

-- The Phase 6C edit RPC, unchanged except for a specific message when the request was
-- cancelled (it previously fell through to the generic "entered review" message).
CREATE OR REPLACE FUNCTION public.update_submitted_supply_request(
  _organization_id uuid,
  _request_id uuid,
  _request_type public.supply_request_type,
  _team_id uuid,
  _location_id uuid,
  _notes text,
  _items jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid uuid := auth.uid();
  _request public.supply_requests%ROWTYPE;
  _context record;
  _line_count integer;
BEGIN
  IF _uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;
  IF NOT public.is_org_member(_organization_id, _uid) THEN
    RAISE EXCEPTION 'Not a member of this organization' USING ERRCODE = '42501';
  END IF;

  SELECT *
  INTO _request
  FROM public.supply_requests
  WHERE id = _request_id
    AND organization_id = _organization_id
  FOR UPDATE;
  -- Another member's request is indistinguishable from a missing one.
  IF NOT FOUND OR _request.requested_by IS DISTINCT FROM _uid THEN
    RAISE EXCEPTION 'Supply request not found' USING ERRCODE = 'P0002';
  END IF;

  IF _request.status = 'cancelled' THEN
    RAISE EXCEPTION 'This request has been cancelled and can no longer be edited.'
      USING ERRCODE = '55000';
  END IF;
  IF _request.status = 'denied' THEN
    RAISE EXCEPTION 'This request has been declined and can no longer be edited.'
      USING ERRCODE = '55000';
  END IF;
  IF _request.status <> 'submitted' OR EXISTS (
    SELECT 1
    FROM public.supply_request_commitments commitment
    WHERE commitment.supply_request_id = _request.id
      AND commitment.organization_id = _organization_id
  ) THEN
    RAISE EXCEPTION 'This request has already entered review and can no longer be edited.'
      USING ERRCODE = '55000';
  END IF;

  SELECT *
  INTO _context
  FROM public.resolve_supply_request_context(
    _organization_id,
    _uid,
    coalesce(_team_id, _request.team_id),
    coalesce(_location_id, _request.location_id)
  );

  UPDATE public.supply_requests
  SET request_type = coalesce(_request_type, _request.request_type),
      team_id = _context.team_id,
      location_id = _context.location_id,
      notes = nullif(btrim(_notes), '')
  WHERE id = _request.id
    AND organization_id = _organization_id;

  _line_count := public.replace_supply_request_items(_organization_id, _request.id, _items);

  INSERT INTO public.supply_request_updates
    (organization_id, supply_request_id, author_id, event_kind)
  VALUES
    (_organization_id, _request.id, _uid, 'requester_edited');

  SELECT * INTO _request FROM public.supply_requests WHERE id = _request.id;
  RETURN jsonb_build_object(
    'id', _request.id,
    'status', _request.status,
    'itemCount', _line_count,
    'updatedAt', _request.updated_at
  );
END;
$$;

COMMIT;
