-- Stale-screen decisions return a non-retryable application error.
--
-- decide_supply_request (Phase 6C) raised SQLSTATE 40001 (serialization_failure) when an admin
-- approved or declined from a screen showing an older version of the request. PostgREST treats
-- 40001 as a transient serialization failure and retries the whole call: a stale decision never
-- answered (the request hung until the client gave up), and PostgREST kept re-running the
-- rolled-back transaction, thousands of times per second, even after the client disconnected.
-- Nothing was ever written (the check runs under the row lock before any write), but the admin
-- saw a hang instead of "This request changed while you were reviewing it".
--
-- This re-creates decide_supply_request with exactly the Phase 6C body, changing only that
-- deliberate stale-screen error to SQLSTATE 55000 (object_not_in_prerequisite_state), the code the
-- other workflow refusals use. Genuine database serialization failures still surface as 40001.
-- Same signature, message, authorization, row lock, reviewed-version check, same-decision retry
-- result, transitions, commitments and notification events; grants are re-stated unchanged.
-- CREATE OR REPLACE keeps the function's identity, so nothing that depends on it changes.

BEGIN;

DO $decide_stale_preflight$
BEGIN
  IF pg_catalog.to_regprocedure(
    'public.decide_supply_request(uuid,uuid,public.supply_request_status,text,text,timestamptz)'
  ) IS NULL THEN
    RAISE EXCEPTION 'This migration requires the Phase 6C decide_supply_request';
  END IF;
  IF position('''40001''' IN pg_catalog.pg_get_functiondef(
    'public.decide_supply_request(uuid,uuid,public.supply_request_status,text,text,timestamptz)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'decide_supply_request no longer raises 40001; this migration has already been applied or the function changed';
  END IF;
END
$decide_stale_preflight$;

CREATE OR REPLACE FUNCTION public.decide_supply_request(
  _organization_id uuid,
  _request_id uuid,
  _decision public.supply_request_status,
  _staff_visible_note text DEFAULT NULL,
  _internal_note text DEFAULT NULL,
  _expected_updated_at timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _request public.supply_requests%ROWTYPE;
  _result jsonb;
BEGIN
  IF NOT public.is_org_admin(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: administrator access required' USING ERRCODE = '42501';
  END IF;
  IF _decision IS NULL OR _decision NOT IN ('approved', 'denied') THEN
    RAISE EXCEPTION 'Choose approve or decline' USING ERRCODE = '22023';
  END IF;
  IF _decision = 'denied' AND nullif(btrim(_staff_visible_note), '') IS NULL THEN
    RAISE EXCEPTION 'A staff-visible reason is required to decline a request' USING ERRCODE = '22023';
  END IF;
  IF length(_staff_visible_note) > 5000 OR length(_internal_note) > 5000 THEN
    RAISE EXCEPTION 'Request messages must be at most 5000 characters' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO _request FROM public.supply_requests
  WHERE id = _request_id AND organization_id = _organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Supply request not found' USING ERRCODE = 'P0002'; END IF;
  -- Competing decisions serialize. Same-decision retries add no audit events and stay
  -- idempotent even though the first decision advanced the version.
  IF _request.status = _decision THEN
    RETURN jsonb_build_object('id', _request.id, 'status', _request.status, 'alreadyDecided', true);
  END IF;
  IF _request.status NOT IN ('submitted', 'under_review') THEN
    RAISE EXCEPTION 'This request has already been decided. Refresh the inbox.' USING ERRCODE = '22023';
  END IF;
  -- Checked under the row lock, before any transition, audit row, or commitment. 55000, not
  -- 40001: PostgREST retries serialization failures, so a stale screen would never get an answer.
  IF _expected_updated_at IS NULL OR _request.updated_at IS DISTINCT FROM _expected_updated_at THEN
    RAISE EXCEPTION 'This request changed while you were reviewing it. Refresh the request and review the latest details before making a decision.'
      USING ERRCODE = '55000';
  END IF;
  IF _decision = 'approved' AND _request.status = 'submitted' THEN
    PERFORM public.apply_supply_request_transition(_organization_id, _request_id, 'under_review');
  END IF;
  _result := public.apply_supply_request_transition(
    _organization_id, _request_id, _decision, _internal_note, _staff_visible_note
  );
  RETURN _result || jsonb_build_object('alreadyDecided', false);
END;
$$;

REVOKE ALL ON FUNCTION public.decide_supply_request(
  uuid, uuid, public.supply_request_status, text, text, timestamptz
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.decide_supply_request(
  uuid, uuid, public.supply_request_status, text, text, timestamptz
) TO authenticated;

COMMIT;
