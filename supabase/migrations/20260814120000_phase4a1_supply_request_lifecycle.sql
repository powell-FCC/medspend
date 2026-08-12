-- Phase 4A.1: atomic, organization-scoped supply request lifecycle transitions.
-- received = received by the organization/admin team; completed = fulfilled and closed.
CREATE OR REPLACE FUNCTION public.transition_supply_request(
  _organization_id uuid,
  _request_id uuid,
  _status public.supply_request_status,
  _internal_note text DEFAULT NULL,
  _staff_visible_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _request public.supply_requests%ROWTYPE;
  _allowed boolean := false;
BEGIN
  IF NOT public.has_org_role(
    _organization_id, auth.uid(), ARRAY['owner','admin']::public.org_role[]
  ) THEN
    RAISE EXCEPTION 'Forbidden: administrator access required';
  END IF;

  SELECT * INTO _request
  FROM public.supply_requests
  WHERE id = _request_id AND organization_id = _organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Supply request not found'; END IF;

  _allowed := CASE _request.status
    WHEN 'submitted' THEN _status IN ('under_review', 'denied')
    WHEN 'under_review' THEN _status IN ('approved', 'denied')
    WHEN 'approved' THEN _status IN ('ordered', 'denied')
    WHEN 'ordered' THEN _status IN ('received', 'denied')
    WHEN 'received' THEN _status = 'completed'
    ELSE false
  END;
  IF NOT _allowed THEN
    RAISE EXCEPTION 'Invalid supply request transition: % to %', _request.status, _status;
  END IF;

  UPDATE public.supply_requests SET
    status = _status,
    ordered_at = CASE
      WHEN _status = 'ordered' THEN coalesce(ordered_at, now())
      ELSE ordered_at
    END,
    received_at = CASE
      WHEN _status = 'received' THEN coalesce(received_at, now())
      ELSE received_at
    END
  WHERE id = _request.id;

  INSERT INTO public.supply_request_updates
    (organization_id, supply_request_id, author_id, status_from, status_to,
     internal_note, staff_visible_note)
  VALUES
    (_organization_id, _request.id, auth.uid(), _request.status, _status,
     nullif(btrim(_internal_note), ''), nullif(btrim(_staff_visible_note), ''));

  SELECT * INTO _request FROM public.supply_requests WHERE id = _request.id;
  RETURN jsonb_build_object(
    'id', _request.id,
    'status', _request.status,
    'orderedAt', _request.ordered_at,
    'receivedAt', _request.received_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.transition_supply_request(
  uuid, uuid, public.supply_request_status, text, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.transition_supply_request(
  uuid, uuid, public.supply_request_status, text, text
) TO authenticated;

