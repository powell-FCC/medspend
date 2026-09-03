-- Phase 5A.9: atomic decisions over the existing audited lifecycle, plus a
-- staff-safe update projection. No request lines or catalog/inventory data change.
BEGIN;

CREATE OR REPLACE FUNCTION public.decide_supply_request(
  _organization_id uuid,
  _request_id uuid,
  _decision public.supply_request_status,
  _staff_visible_note text DEFAULT NULL,
  _internal_note text DEFAULT NULL
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
  -- Competing decisions serialize. Same-decision retries add no audit events.
  IF _request.status = _decision THEN
    RETURN jsonb_build_object('id', _request.id, 'status', _request.status, 'alreadyDecided', true);
  END IF;
  IF _request.status NOT IN ('submitted', 'under_review') THEN
    RAISE EXCEPTION 'This request has already been decided. Refresh the inbox.' USING ERRCODE = '22023';
  END IF;
  IF _decision = 'approved' AND _request.status = 'submitted' THEN
    PERFORM public.transition_supply_request(_organization_id, _request_id, 'under_review');
  END IF;
  _result := public.transition_supply_request(
    _organization_id, _request_id, _decision, _internal_note, _staff_visible_note
  );
  RETURN _result || jsonb_build_object('alreadyDecided', false);
END;
$$;

REVOKE ALL ON FUNCTION public.decide_supply_request(uuid, uuid, public.supply_request_status, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.decide_supply_request(uuid, uuid, public.supply_request_status, text, text) TO authenticated;

-- RLS cannot redact one column. Hide mixed private/public rows from direct
-- staff reads and project owned public fields. Preserve existing audit rows.
CREATE OR REPLACE FUNCTION public.list_staff_supply_request_updates(
  _organization_id uuid,
  _request_ids uuid[]
)
RETURNS TABLE (
  id uuid,
  supply_request_id uuid,
  status_from public.supply_request_status,
  status_to public.supply_request_status,
  staff_visible_note text,
  created_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_org_member(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Not a member of this organization' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT u.id, u.supply_request_id, u.status_from, u.status_to, u.staff_visible_note, u.created_at
    FROM public.supply_request_updates u
    JOIN public.supply_requests r ON r.id = u.supply_request_id AND r.organization_id = u.organization_id
    WHERE r.organization_id = _organization_id
      AND r.requested_by = auth.uid()
      AND r.id = ANY(_request_ids)
      AND (u.status_to IS NOT NULL OR u.staff_visible_note IS NOT NULL)
    ORDER BY u.created_at, u.status_to, u.id;
END;
$$;

REVOKE ALL ON FUNCTION public.list_staff_supply_request_updates(uuid, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_staff_supply_request_updates(uuid, uuid[]) TO authenticated;

ALTER POLICY "sru_select_visibility" ON public.supply_request_updates
USING (
  public.is_org_admin(organization_id, auth.uid())
  OR (
    internal_note IS NULL
    AND staff_visible_note IS NOT NULL
    AND public.is_org_member(organization_id, auth.uid())
    AND EXISTS (
      SELECT 1 FROM public.supply_requests r
      WHERE r.id = supply_request_updates.supply_request_id
        AND r.organization_id = supply_request_updates.organization_id
        AND r.requested_by = auth.uid()
    )
  )
);

COMMIT;
