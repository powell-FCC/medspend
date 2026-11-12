-- Phase 7C.0: configurable request workflow profiles.
--
-- The canonical request lifecycle is unchanged. Every status still exists, and every
-- transition still runs through apply_supply_request_transition and writes its own audited
-- supply_request_updates row. An organization profile only decides which user actions are
-- offered and which actions are bundled:
--
--   * detailed (the default; no settings row means detailed): every stage is a separate
--     action (Approve, Mark Ordered, Mark Received, Complete Request).
--   * standard: Approve and Mark Ordered stay separate; Receive & Complete bundles
--     ordered -> received -> completed.
--   * lean: Approve & Order bundles (submitted ->) under_review -> approved -> ordered, and
--     Receive & Complete bundles ordered -> received -> completed.
--
-- Compound actions run in ONE transaction under the request row lock. They reuse the
-- existing machinery (decide_supply_request for the approval, apply_supply_request_transition
-- for every other step), so commitment creation, ordered_at / received_at, the approval
-- notification event and the audit rows are exactly those of the individual actions. A
-- committed request is therefore never left in a transient approved or received state by a
-- compound action, and the canonical digest never shows one.
--
-- supply_request_updates.compound_action is supplemental provenance: it marks every row one
-- bundled action wrote ('approve_and_order' or 'receive_and_complete'), so reporting can
-- separate bundled transitions from standalone ones. It is set only when one call wrote more
-- than one canonical transition; a call that finds the request one step from the end (for
-- example an approved request ordered by Approve & Order) writes an ordinary, unmarked row.
-- Inside a bundle every row shares the transaction timestamp, so approval -> order (for
-- approve_and_order) and receipt -> completion (for receive_and_complete) durations are
-- intentionally 0 and must be segmented out of any speed metric. Human-entered notes are
-- written once, on the final canonical row of the bundle (ordered or completed).
--
-- Compound functions enforce the profile server-side (lean: both; standard: Receive &
-- Complete only). The ordinary transition functions are not gated: they keep every valid
-- canonical state actionable after a profile change. Changing the profile never changes a
-- request's status or history.
--
-- One shared receive path: apply_supply_request_receipt is the single place a request moves
-- ordered -> received for both Mark Received (receive_supply_request) and Receive & Complete.
-- Phase 7C adds receiving-destination behavior there once. This phase moves no inventory.
--
-- Additive: one table (RLS on, no policies, no client grants), one column with its check and
-- client-write guard, eight functions, and a drop/recreate of
-- list_staff_supply_request_updates to add compound_action to its result (same arguments,
-- filter, ordering and grants). decide_supply_request, transition_supply_request,
-- apply_supply_request_transition, the notification triggers and the digest are unchanged.

BEGIN;

DO $phase7c0_preflight$
BEGIN
  IF pg_catalog.to_regprocedure('public.apply_supply_request_transition(uuid, uuid, public.supply_request_status, text, text)') IS NULL
     OR pg_catalog.to_regprocedure('public.decide_supply_request(uuid, uuid, public.supply_request_status, text, text, timestamptz)') IS NULL
     OR pg_catalog.to_regprocedure('public.transition_supply_request(uuid, uuid, public.supply_request_status, text, text)') IS NULL
     OR pg_catalog.to_regprocedure('public.list_staff_supply_request_updates(uuid, uuid[])') IS NULL
     OR pg_catalog.to_regprocedure('public.is_org_admin(uuid, uuid)') IS NULL
     OR pg_catalog.to_regprocedure('public.is_org_member(uuid, uuid)') IS NULL
     OR pg_catalog.to_regprocedure('public.tg_set_updated_at()') IS NULL
     OR pg_catalog.to_regprocedure('public.capture_supply_request_decision_notification()') IS NULL THEN
    RAISE EXCEPTION 'Phase 7C.0 requires the request lifecycle and notifications through Phase 6C.3';
  END IF;
  IF pg_catalog.to_regclass('public.organization_request_workflow_settings') IS NOT NULL
     OR EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'supply_request_updates'
                  AND column_name = 'compound_action')
     OR EXISTS (SELECT 1 FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public' AND p.proname IN (
                  'organization_request_workflow_profile',
                  'get_request_workflow_profile',
                  'get_organization_request_workflow_settings',
                  'update_organization_request_workflow_settings',
                  'guard_supply_request_update_compound_action',
                  'mark_supply_request_compound_action',
                  'apply_supply_request_receipt',
                  'receive_supply_request',
                  'approve_and_order_supply_request',
                  'receive_and_complete_supply_request')) THEN
    RAISE EXCEPTION 'Phase 7C.0 workflow profile objects already exist unexpectedly';
  END IF;
END
$phase7c0_preflight$;

-- ---------------------------------------------------------------------------------------------
-- Organization workflow profile
-- ---------------------------------------------------------------------------------------------

CREATE TABLE public.organization_request_workflow_settings (
  organization_id uuid PRIMARY KEY REFERENCES public.organizations(id) ON DELETE CASCADE,
  workflow_profile text NOT NULL DEFAULT 'detailed'
    CONSTRAINT organization_request_workflow_settings_profile_check
      CHECK (workflow_profile IN ('lean', 'standard', 'detailed')),
  updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER organization_request_workflow_settings_updated_at
  BEFORE UPDATE ON public.organization_request_workflow_settings
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

ALTER TABLE public.organization_request_workflow_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.organization_request_workflow_settings FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.organization_request_workflow_settings TO service_role;

-- The effective profile. No row means detailed. Private: callers check access themselves.
CREATE FUNCTION public.organization_request_workflow_profile(_organization_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT COALESCE((
    SELECT settings.workflow_profile FROM public.organization_request_workflow_settings settings
    WHERE settings.organization_id = _organization_id
  ), 'detailed')
$$;

-- Any active member (staff included) can read the profile their request screens follow.
-- Nothing else about the settings is exposed here.
CREATE FUNCTION public.get_request_workflow_profile(_organization_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF _organization_id IS NULL OR NOT COALESCE(public.is_org_member(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Not a member of this organization' USING ERRCODE = '42501';
  END IF;
  RETURN public.organization_request_workflow_profile(_organization_id);
END;
$$;

-- Admin Settings (is_org_admin: every active owner or admin membership).
CREATE FUNCTION public.get_organization_request_workflow_settings(_organization_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  _row public.organization_request_workflow_settings%ROWTYPE;
BEGIN
  IF _organization_id IS NULL OR NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Forbidden: administrator access required' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO _row FROM public.organization_request_workflow_settings WHERE organization_id = _organization_id;
  RETURN jsonb_build_object(
    'organizationId', _organization_id,
    'workflowProfile', COALESCE(_row.workflow_profile, 'detailed'),
    'updatedAt', _row.updated_at
  );
END;
$$;

-- Changes only which actions are offered from now on. No request status or history changes.
CREATE FUNCTION public.update_organization_request_workflow_settings(
  _organization_id uuid,
  _workflow_profile text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF _organization_id IS NULL OR NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Forbidden: administrator access required' USING ERRCODE = '42501';
  END IF;
  IF _workflow_profile IS NULL OR _workflow_profile NOT IN ('lean', 'standard', 'detailed') THEN
    RAISE EXCEPTION 'Choose Lean, Standard or Detailed' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.organization_request_workflow_settings AS settings
    (organization_id, workflow_profile, updated_by)
  VALUES (_organization_id, _workflow_profile, auth.uid())
  ON CONFLICT (organization_id) DO UPDATE SET
    workflow_profile = EXCLUDED.workflow_profile,
    updated_by = EXCLUDED.updated_by;

  RETURN public.get_organization_request_workflow_settings(_organization_id);
END;
$$;

-- ---------------------------------------------------------------------------------------------
-- Compound-action provenance
-- ---------------------------------------------------------------------------------------------

ALTER TABLE public.supply_request_updates
  ADD COLUMN compound_action text,
  ADD CONSTRAINT supply_request_updates_compound_action_check CHECK (
    compound_action IS NULL
    OR (
      event_kind IS NULL
      AND (
        (compound_action = 'approve_and_order' AND status_to IN ('under_review', 'approved', 'ordered'))
        OR (compound_action = 'receive_and_complete' AND status_to IN ('received', 'completed'))
      )
    )
  );

-- Only the compound functions (SECURITY DEFINER, so not running as a client role) can set the
-- marker. Direct API writes cannot forge or change it. Other columns are unaffected.
CREATE FUNCTION public.guard_supply_request_update_compound_action()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF current_user IN ('authenticated', 'anon') THEN
    IF (TG_OP = 'INSERT' AND NEW.compound_action IS NOT NULL)
       OR (TG_OP = 'UPDATE' AND NEW.compound_action IS DISTINCT FROM OLD.compound_action) THEN
      RAISE EXCEPTION 'Compound action provenance is written only by the request workflow'
        USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.guard_supply_request_update_compound_action() FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER supply_request_updates_compound_action_guard
  BEFORE INSERT OR UPDATE OF compound_action ON public.supply_request_updates
  FOR EACH ROW EXECUTE FUNCTION public.guard_supply_request_update_compound_action();

-- Marks the rows this transaction just wrote for the request. The lifecycle is forward-only,
-- so each status_to occurs at most once per request; created_at = now() (the transaction
-- timestamp every row of the bundle carries) restricts it to this transaction's rows.
CREATE FUNCTION public.mark_supply_request_compound_action(
  _organization_id uuid,
  _request_id uuid,
  _compound_action text,
  _statuses public.supply_request_status[]
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  _marked integer;
BEGIN
  UPDATE public.supply_request_updates
  SET compound_action = _compound_action
  WHERE organization_id = _organization_id
    AND supply_request_id = _request_id
    AND status_to = ANY(_statuses)
    AND compound_action IS NULL
    AND event_kind IS NULL
    AND created_at = now();
  GET DIAGNOSTICS _marked = ROW_COUNT;
  IF _marked <> cardinality(_statuses) THEN
    RAISE EXCEPTION 'Compound action provenance mismatch: expected %, marked %', cardinality(_statuses), _marked;
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------------------------
-- Shared receive path
-- ---------------------------------------------------------------------------------------------

-- The one place a request moves ordered -> received. Phase 7C adds the receiving destination
-- here, so Mark Received and Receive & Complete gain it together. Today it is exactly the
-- canonical transition (received_at, audit row, no inventory, budget or notification effect).
-- Private: callers hold the request row lock and have checked authority and state.
CREATE FUNCTION public.apply_supply_request_receipt(
  _organization_id uuid,
  _request_id uuid,
  _internal_note text DEFAULT NULL,
  _staff_visible_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  RETURN public.apply_supply_request_transition(
    _organization_id, _request_id, 'received', _internal_note, _staff_visible_note
  );
END;
$$;

-- Mark Received (Detailed, and any profile with a request still awaiting delivery that is
-- received on its own). Not profile-gated. A retry after success writes nothing.
CREATE FUNCTION public.receive_supply_request(
  _organization_id uuid,
  _request_id uuid,
  _staff_visible_note text DEFAULT NULL,
  _internal_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  _request public.supply_requests%ROWTYPE;
BEGIN
  IF _organization_id IS NULL OR _request_id IS NULL
     OR NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Forbidden: administrator access required' USING ERRCODE = '42501';
  END IF;
  IF length(_staff_visible_note) > 5000 OR length(_internal_note) > 5000 THEN
    RAISE EXCEPTION 'Request messages must be at most 5000 characters' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO _request FROM public.supply_requests
  WHERE id = _request_id AND organization_id = _organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Supply request not found' USING ERRCODE = 'P0002'; END IF;
  IF _request.status = 'received' THEN
    RETURN jsonb_build_object('id', _request.id, 'status', _request.status, 'orderedAt', _request.ordered_at,
      'receivedAt', _request.received_at, 'alreadyApplied', true);
  END IF;
  IF _request.status <> 'ordered' THEN
    RAISE EXCEPTION 'This request is not awaiting delivery. Refresh the inbox.' USING ERRCODE = '22023';
  END IF;
  RETURN public.apply_supply_request_receipt(_organization_id, _request_id, _internal_note, _staff_visible_note)
    || jsonb_build_object('alreadyApplied', false);
END;
$$;

-- ---------------------------------------------------------------------------------------------
-- Compound actions
-- ---------------------------------------------------------------------------------------------

-- Lean: Approve & Order. From submitted: under_review, approved, ordered. From under_review:
-- approved, ordered. From approved: ordered. Already ordered: nothing is written.
-- The approval is decide_supply_request itself (same lock, same reviewed-version check, same
-- commitment and exactly one approval notification event), called without notes; the notes go
-- once on the ordered row.
CREATE FUNCTION public.approve_and_order_supply_request(
  _organization_id uuid,
  _request_id uuid,
  _staff_visible_note text DEFAULT NULL,
  _internal_note text DEFAULT NULL,
  _expected_updated_at timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  _request public.supply_requests%ROWTYPE;
  _written public.supply_request_status[] := ARRAY[]::public.supply_request_status[];
  _result jsonb;
BEGIN
  IF _organization_id IS NULL OR _request_id IS NULL
     OR NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Forbidden: administrator access required' USING ERRCODE = '42501';
  END IF;
  IF length(_staff_visible_note) > 5000 OR length(_internal_note) > 5000 THEN
    RAISE EXCEPTION 'Request messages must be at most 5000 characters' USING ERRCODE = '22023';
  END IF;
  IF public.organization_request_workflow_profile(_organization_id) <> 'lean' THEN
    RAISE EXCEPTION 'Approve & Order is not enabled for this organization''s request workflow. Refresh the inbox.'
      USING ERRCODE = '55000';
  END IF;

  SELECT * INTO _request FROM public.supply_requests
  WHERE id = _request_id AND organization_id = _organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Supply request not found' USING ERRCODE = 'P0002'; END IF;

  -- A retry after success (double tap, network retry) adds nothing.
  IF _request.status = 'ordered' THEN
    RETURN jsonb_build_object('id', _request.id, 'status', _request.status, 'orderedAt', _request.ordered_at,
      'receivedAt', _request.received_at, 'alreadyApplied', true);
  END IF;
  IF _request.status NOT IN ('submitted', 'under_review', 'approved') THEN
    RAISE EXCEPTION 'This request can no longer be approved and ordered. Refresh the inbox.' USING ERRCODE = '22023';
  END IF;
  -- Checked under the row lock, before any transition, audit row or commitment. 55000, not
  -- 40001: PostgREST retries serialization failures, which would hang the request.
  IF _expected_updated_at IS NULL OR _request.updated_at IS DISTINCT FROM _expected_updated_at THEN
    RAISE EXCEPTION 'This request changed while you were reviewing it. Refresh the request and review the latest details before making a decision.'
      USING ERRCODE = '55000';
  END IF;

  IF _request.status IN ('submitted', 'under_review') THEN
    PERFORM public.decide_supply_request(
      _organization_id, _request_id, 'approved', NULL, NULL, _request.updated_at
    );
    _written := CASE WHEN _request.status = 'submitted'
      THEN ARRAY['under_review', 'approved']::public.supply_request_status[]
      ELSE ARRAY['approved']::public.supply_request_status[] END;
  END IF;

  _result := public.apply_supply_request_transition(
    _organization_id, _request_id, 'ordered', _internal_note, _staff_visible_note
  );
  _written := _written || 'ordered'::public.supply_request_status;

  IF cardinality(_written) > 1 THEN
    PERFORM public.mark_supply_request_compound_action(_organization_id, _request_id, 'approve_and_order', _written);
  END IF;

  RETURN _result || jsonb_build_object(
    'alreadyApplied', false,
    'compoundAction', CASE WHEN cardinality(_written) > 1 THEN 'approve_and_order' END,
    'transitions', to_jsonb(_written)
  );
END;
$$;

-- Lean and Standard: Receive & Complete. From ordered: received (through the shared receive
-- path), completed. From received: completed. Already completed: nothing is written. No
-- notification event (received and completed raise none). Notes go once on the completed row.
CREATE FUNCTION public.receive_and_complete_supply_request(
  _organization_id uuid,
  _request_id uuid,
  _staff_visible_note text DEFAULT NULL,
  _internal_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  _request public.supply_requests%ROWTYPE;
  _written public.supply_request_status[] := ARRAY[]::public.supply_request_status[];
  _result jsonb;
BEGIN
  IF _organization_id IS NULL OR _request_id IS NULL
     OR NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Forbidden: administrator access required' USING ERRCODE = '42501';
  END IF;
  IF length(_staff_visible_note) > 5000 OR length(_internal_note) > 5000 THEN
    RAISE EXCEPTION 'Request messages must be at most 5000 characters' USING ERRCODE = '22023';
  END IF;
  IF public.organization_request_workflow_profile(_organization_id) NOT IN ('lean', 'standard') THEN
    RAISE EXCEPTION 'Receive & Complete is not enabled for this organization''s request workflow. Refresh the inbox.'
      USING ERRCODE = '55000';
  END IF;

  SELECT * INTO _request FROM public.supply_requests
  WHERE id = _request_id AND organization_id = _organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Supply request not found' USING ERRCODE = 'P0002'; END IF;

  IF _request.status = 'completed' THEN
    RETURN jsonb_build_object('id', _request.id, 'status', _request.status, 'orderedAt', _request.ordered_at,
      'receivedAt', _request.received_at, 'alreadyApplied', true);
  END IF;
  IF _request.status NOT IN ('ordered', 'received') THEN
    RAISE EXCEPTION 'This request is not awaiting delivery. Refresh the inbox.' USING ERRCODE = '22023';
  END IF;

  IF _request.status = 'ordered' THEN
    PERFORM public.apply_supply_request_receipt(_organization_id, _request_id, NULL, NULL);
    _written := ARRAY['received']::public.supply_request_status[];
  END IF;

  _result := public.apply_supply_request_transition(
    _organization_id, _request_id, 'completed', _internal_note, _staff_visible_note
  );
  _written := _written || 'completed'::public.supply_request_status;

  IF cardinality(_written) > 1 THEN
    PERFORM public.mark_supply_request_compound_action(_organization_id, _request_id, 'receive_and_complete', _written);
  END IF;

  RETURN _result || jsonb_build_object(
    'alreadyApplied', false,
    'compoundAction', CASE WHEN cardinality(_written) > 1 THEN 'receive_and_complete' END,
    'transitions', to_jsonb(_written)
  );
END;
$$;

-- ---------------------------------------------------------------------------------------------
-- Staff-safe history gains compound_action (so a bundle shows as one step). PostgreSQL needs a
-- drop/recreate to add a result column; arguments, filter, ordering and grants are unchanged.
-- ---------------------------------------------------------------------------------------------

DROP FUNCTION public.list_staff_supply_request_updates(uuid, uuid[]);
CREATE FUNCTION public.list_staff_supply_request_updates(
  _organization_id uuid,
  _request_ids uuid[]
)
RETURNS TABLE (
  id uuid,
  supply_request_id uuid,
  status_from public.supply_request_status,
  status_to public.supply_request_status,
  staff_visible_note text,
  event_kind text,
  created_at timestamptz,
  compound_action text
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
    SELECT u.id, u.supply_request_id, u.status_from, u.status_to, u.staff_visible_note,
      u.event_kind, u.created_at, u.compound_action
    FROM public.supply_request_updates u
    JOIN public.supply_requests r ON r.id = u.supply_request_id AND r.organization_id = u.organization_id
    WHERE r.organization_id = _organization_id
      AND r.requested_by = auth.uid()
      AND r.id = ANY(_request_ids)
      AND (
        u.status_to IS NOT NULL
        OR u.staff_visible_note IS NOT NULL
        OR u.event_kind = 'requester_edited'
      )
    ORDER BY u.created_at, u.status_to, u.id;
END;
$$;

REVOKE ALL ON FUNCTION public.list_staff_supply_request_updates(uuid, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_staff_supply_request_updates(uuid, uuid[]) TO authenticated;

-- ---------------------------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.organization_request_workflow_profile(uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.mark_supply_request_compound_action(uuid, uuid, text, public.supply_request_status[])
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.apply_supply_request_receipt(uuid, uuid, text, text) FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.get_request_workflow_profile(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_request_workflow_profile(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.get_organization_request_workflow_settings(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_organization_request_workflow_settings(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.update_organization_request_workflow_settings(uuid, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.update_organization_request_workflow_settings(uuid, text) TO authenticated;
REVOKE ALL ON FUNCTION public.receive_supply_request(uuid, uuid, text, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.receive_supply_request(uuid, uuid, text, text) TO authenticated;
REVOKE ALL ON FUNCTION public.approve_and_order_supply_request(uuid, uuid, text, text, timestamptz) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.approve_and_order_supply_request(uuid, uuid, text, text, timestamptz) TO authenticated;
REVOKE ALL ON FUNCTION public.receive_and_complete_supply_request(uuid, uuid, text, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.receive_and_complete_supply_request(uuid, uuid, text, text) TO authenticated;

COMMENT ON TABLE public.organization_request_workflow_settings IS
  'Phase 7C.0 organization request workflow profile (lean / standard / detailed). No row means detailed. Admins change it through update_organization_request_workflow_settings.';
COMMENT ON COLUMN public.supply_request_updates.compound_action IS
  'Phase 7C.0 provenance: set on every canonical row one bundled action wrote (approve_and_order, receive_and_complete). NULL for ordinary transitions. Bundled rows share one timestamp, so in-bundle stage durations are 0 by construction.';

COMMIT;
