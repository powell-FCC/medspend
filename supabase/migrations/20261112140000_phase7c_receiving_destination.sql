-- Phase 7C: receiving destination.
--
-- Every canonical receipt (ordered -> received) now records exactly one receiving destination:
-- an active inventory location of the organization (a storage location, or the protected
-- Unassigned location as an explicit "not yet placed" choice). The destination is operational
-- metadata only. Receiving still adds, removes, moves and creates no inventory, and changes no
-- invoice, commitment, budget or notification. Invoice posting remains the only way stock
-- enters inventory (into Unassigned); placing stock stays the owner's Move. Purchase-linked
-- stock placement, line quantities and partial receipts belong to Phase 8B.
--
--   * supply_request_receipts: one immutable row per received request (V1), written only by
--     apply_supply_request_receipt in the same transaction as the canonical received transition.
--     It keeps the destination's identity (inventory_location_id) plus name and kind snapshots
--     (locations can be renamed later), the actor, the receipt time, the received history row
--     and the compound action (receive_and_complete when bundled). RLS on, no policies, no
--     client grants; clients read through list_supply_request_receipts.
--   * apply_supply_request_receipt (the Phase 7C.0 shared receive path) now requires the
--     destination, validates it (same organization, active) and writes the receipt. Mark Received
--     (receive_supply_request) and Receive & Complete (receive_and_complete_supply_request) both
--     go through it, so every profile records the destination the same way.
--   * receive_supply_request and receive_and_complete_supply_request take the destination as a new
--     trailing argument. Without one (an app loaded before this release), receiving an ordered
--     request is refused with a "refresh and choose a receiving destination" message. Retries are
--     safe: an already received/completed request returns alreadyApplied and writes nothing; a
--     retry naming a different destination is refused (a receipt's destination never changes).
--   * transition_supply_request refuses the target status 'received', so no request can be
--     received without a receipt through the client API. Every other transition is unchanged.
--   * list_receiving_destinations: the picker's options (id, name, kind of active locations of
--     the organization, Unassigned included) for owners and admins, without widening the
--     owner-only inventory_locations table.
--   * list_supply_request_receipts: receipts of requests the caller may see (admins: their
--     organization's; staff: their own requests). Staff never get the inventory location id.
--
-- Additive: one table (with its indexes and an immutability trigger), four new functions (two
-- client reads, the trigger function, and the receipt helper re-created with the destination),
-- receive_supply_request and receive_and_complete_supply_request re-created with the new
-- argument, and transition_supply_request replaced with the same signature. No existing row,
-- policy or table grant changes. Requests received before this release have no receipt.

BEGIN;

DO $phase7c_preflight$
BEGIN
  IF pg_catalog.to_regclass('public.supply_request_receipts') IS NOT NULL
     OR pg_catalog.to_regprocedure('public.apply_supply_request_receipt(uuid, uuid, uuid, text, text, text)') IS NOT NULL
     OR EXISTS (SELECT 1 FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public' AND p.proname IN (
                  'list_receiving_destinations',
                  'list_supply_request_receipts',
                  'guard_supply_request_receipt_immutable')) THEN
    RAISE EXCEPTION 'Phase 7C receiving destination objects already exist unexpectedly';
  END IF;
  IF pg_catalog.to_regprocedure('public.apply_supply_request_receipt(uuid, uuid, text, text)') IS NULL
     OR pg_catalog.to_regprocedure('public.receive_supply_request(uuid, uuid, text, text)') IS NULL
     OR pg_catalog.to_regprocedure('public.receive_and_complete_supply_request(uuid, uuid, text, text)') IS NULL
     OR pg_catalog.to_regprocedure('public.apply_supply_request_transition(uuid, uuid, public.supply_request_status, text, text)') IS NULL
     OR pg_catalog.to_regprocedure('public.transition_supply_request(uuid, uuid, public.supply_request_status, text, text)') IS NULL
     OR pg_catalog.to_regprocedure('public.mark_supply_request_compound_action(uuid, uuid, text, public.supply_request_status[])') IS NULL
     OR pg_catalog.to_regprocedure('public.organization_request_workflow_profile(uuid)') IS NULL
     OR pg_catalog.to_regclass('public.inventory_locations') IS NULL
     OR pg_catalog.to_regclass('public.inventory_locations_id_org_uq') IS NULL
     OR pg_catalog.to_regclass('public.supply_requests_id_org_uq') IS NULL THEN
    RAISE EXCEPTION 'Phase 7C requires Phase 7A.1 inventory locations and the Phase 7C.0 receive path';
  END IF;
END
$phase7c_preflight$;

-- ---------------------------------------------------------------------------------------------
-- Receipts
-- ---------------------------------------------------------------------------------------------

CREATE TABLE public.supply_request_receipts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  supply_request_id uuid NOT NULL,
  inventory_location_id uuid NOT NULL,
  destination_name_snapshot text NOT NULL
    CONSTRAINT supply_request_receipts_name_check CHECK (btrim(destination_name_snapshot) <> ''),
  destination_kind text NOT NULL
    CONSTRAINT supply_request_receipts_kind_check CHECK (destination_kind IN ('unassigned', 'storage')),
  received_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  received_at timestamptz NOT NULL,
  supply_request_update_id uuid NOT NULL REFERENCES public.supply_request_updates(id) ON DELETE RESTRICT,
  compound_action text
    CONSTRAINT supply_request_receipts_compound_action_check
      CHECK (compound_action IS NULL OR compound_action = 'receive_and_complete'),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT supply_request_receipts_request_org_fk
    FOREIGN KEY (supply_request_id, organization_id)
    REFERENCES public.supply_requests(id, organization_id) ON DELETE RESTRICT,
  CONSTRAINT supply_request_receipts_location_org_fk
    FOREIGN KEY (inventory_location_id, organization_id)
    REFERENCES public.inventory_locations(id, organization_id) ON DELETE RESTRICT,
  -- V1: whole-request receiving, one receipt per request and per received history row.
  CONSTRAINT supply_request_receipts_request_key UNIQUE (supply_request_id),
  CONSTRAINT supply_request_receipts_update_key UNIQUE (supply_request_update_id)
);

CREATE INDEX supply_request_receipts_org_location_idx
  ON public.supply_request_receipts (organization_id, inventory_location_id, received_at DESC);
CREATE INDEX supply_request_receipts_org_received_idx
  ON public.supply_request_receipts (organization_id, received_at DESC);

-- A receipt is history: it never changes after it is written. The one exception is the
-- received_by foreign key's own ON DELETE SET NULL action, so deleting a user account keeps the
-- receipt (actor cleared, as on supply_request_updates.author_id) instead of failing.
CREATE FUNCTION public.guard_supply_request_receipt_immutable()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF OLD.received_by IS NOT NULL AND NEW.received_by IS NULL
     AND (to_jsonb(NEW) - 'received_by') = (to_jsonb(OLD) - 'received_by') THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'A receipt cannot be changed after it is recorded' USING ERRCODE = '55000';
END;
$$;

REVOKE ALL ON FUNCTION public.guard_supply_request_receipt_immutable() FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER supply_request_receipts_immutable
  BEFORE UPDATE ON public.supply_request_receipts
  FOR EACH ROW EXECUTE FUNCTION public.guard_supply_request_receipt_immutable();

ALTER TABLE public.supply_request_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.supply_request_receipts FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.supply_request_receipts TO service_role;

-- ---------------------------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------------------------

-- The receiving picker's options. Owners and admins (is_org_admin). Active locations only, the
-- protected Unassigned included; storage locations first, by name.
CREATE FUNCTION public.list_receiving_destinations(_organization_id uuid)
RETURNS TABLE (id uuid, name text, kind text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF _organization_id IS NULL OR NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Forbidden: administrator access required' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT location.id, location.name, location.kind
    FROM public.inventory_locations location
    WHERE location.organization_id = _organization_id AND location.active
    ORDER BY (location.kind = 'unassigned'), lower(location.name), location.id;
END;
$$;

-- Receipts of the given requests that the caller may see: every receipt of the organization for
-- an admin, only receipts of the caller's own requests for staff. Staff never get the inventory
-- location id (it is NULL); everyone gets the immutable name and kind snapshots.
CREATE FUNCTION public.list_supply_request_receipts(_organization_id uuid, _request_ids uuid[])
RETURNS TABLE (
  supply_request_id uuid,
  supply_request_update_id uuid,
  inventory_location_id uuid,
  destination_name text,
  destination_kind text,
  received_at timestamptz,
  compound_action text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  _admin boolean;
BEGIN
  IF _organization_id IS NULL OR NOT COALESCE(public.is_org_member(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Not a member of this organization' USING ERRCODE = '42501';
  END IF;
  _admin := COALESCE(public.is_org_admin(_organization_id, auth.uid()), false);
  RETURN QUERY
    SELECT receipt.supply_request_id, receipt.supply_request_update_id,
      CASE WHEN _admin THEN receipt.inventory_location_id END,
      receipt.destination_name_snapshot, receipt.destination_kind, receipt.received_at, receipt.compound_action
    FROM public.supply_request_receipts receipt
    JOIN public.supply_requests request
      ON request.id = receipt.supply_request_id AND request.organization_id = receipt.organization_id
    WHERE receipt.organization_id = _organization_id
      AND receipt.supply_request_id = ANY(_request_ids)
      AND (_admin OR request.requested_by = auth.uid())
    ORDER BY receipt.received_at, receipt.id;
END;
$$;

-- ---------------------------------------------------------------------------------------------
-- The shared receive path
-- ---------------------------------------------------------------------------------------------

-- The one place a request becomes received. It validates the destination (this organization,
-- active), runs the canonical ordered -> received transition (received_at, history row, notes)
-- and records exactly one receipt linked to that history row. It changes no inventory. Callers
-- hold the request row lock and have checked authority, state, idempotency and the profile.
DROP FUNCTION public.apply_supply_request_receipt(uuid, uuid, text, text);
CREATE FUNCTION public.apply_supply_request_receipt(
  _organization_id uuid,
  _request_id uuid,
  _inventory_location_id uuid,
  _internal_note text DEFAULT NULL,
  _staff_visible_note text DEFAULT NULL,
  _compound_action text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  _request public.supply_requests%ROWTYPE;
  _location public.inventory_locations%ROWTYPE;
  _result jsonb;
  _update_id uuid;
  _receipt public.supply_request_receipts%ROWTYPE;
BEGIN
  SELECT * INTO _request FROM public.supply_requests
  WHERE id = _request_id AND organization_id = _organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Supply request not found' USING ERRCODE = 'P0002'; END IF;
  IF _inventory_location_id IS NULL THEN
    RAISE EXCEPTION 'Choose where this delivery was received.' USING ERRCODE = '22023';
  END IF;
  -- The share lock holds off a concurrent archive or rename until the receipt commits.
  SELECT * INTO _location FROM public.inventory_locations
  WHERE id = _inventory_location_id AND organization_id = _organization_id
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Choose a receiving destination of this organization.' USING ERRCODE = '22023';
  END IF;
  IF NOT _location.active THEN
    RAISE EXCEPTION '% is archived. Choose an active receiving destination.', _location.name USING ERRCODE = '55000';
  END IF;
  IF EXISTS (SELECT 1 FROM public.supply_request_receipts WHERE supply_request_id = _request_id) THEN
    RAISE EXCEPTION 'This request already has a receipt.' USING ERRCODE = '55000';
  END IF;

  _result := public.apply_supply_request_transition(
    _organization_id, _request_id, 'received', _internal_note, _staff_visible_note
  );
  -- The lifecycle is forward-only, so a request has at most one received history row.
  SELECT update_row.id INTO _update_id FROM public.supply_request_updates update_row
  WHERE update_row.organization_id = _organization_id AND update_row.supply_request_id = _request_id
    AND update_row.status_to = 'received';

  INSERT INTO public.supply_request_receipts
    (organization_id, supply_request_id, inventory_location_id, destination_name_snapshot,
     destination_kind, received_by, received_at, supply_request_update_id, compound_action)
  VALUES
    (_organization_id, _request_id, _location.id, _location.name, _location.kind, auth.uid(),
     (_result ->> 'receivedAt')::timestamptz, _update_id, _compound_action)
  RETURNING * INTO _receipt;

  RETURN _result || jsonb_build_object('receipt', jsonb_build_object(
    'id', _receipt.id,
    'inventoryLocationId', _receipt.inventory_location_id,
    'destinationName', _receipt.destination_name_snapshot,
    'destinationKind', _receipt.destination_kind,
    'receivedAt', _receipt.received_at));
END;
$$;

-- ---------------------------------------------------------------------------------------------
-- Receiving actions
-- ---------------------------------------------------------------------------------------------

-- Mark Received. Any profile. The destination is a new trailing argument; an app loaded before
-- this release sends none and is asked to refresh. A retry after success writes nothing; a retry
-- naming a different destination is refused.
DROP FUNCTION public.receive_supply_request(uuid, uuid, text, text);
CREATE FUNCTION public.receive_supply_request(
  _organization_id uuid,
  _request_id uuid,
  _staff_visible_note text DEFAULT NULL,
  _internal_note text DEFAULT NULL,
  _inventory_location_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  _request public.supply_requests%ROWTYPE;
  _receipt public.supply_request_receipts%ROWTYPE;
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
  SELECT * INTO _receipt FROM public.supply_request_receipts WHERE supply_request_id = _request_id;

  IF _request.status = 'received' THEN
    IF _receipt.id IS NOT NULL AND _inventory_location_id IS NOT NULL
       AND _receipt.inventory_location_id IS DISTINCT FROM _inventory_location_id THEN
      RAISE EXCEPTION 'This request was already received to %. A receiving destination cannot be changed.',
        _receipt.destination_name_snapshot USING ERRCODE = '55000';
    END IF;
    RETURN jsonb_build_object('id', _request.id, 'status', _request.status, 'orderedAt', _request.ordered_at,
      'receivedAt', _request.received_at, 'alreadyApplied', true,
      'receipt', CASE WHEN _receipt.id IS NULL THEN NULL ELSE jsonb_build_object(
        'id', _receipt.id, 'inventoryLocationId', _receipt.inventory_location_id,
        'destinationName', _receipt.destination_name_snapshot, 'destinationKind', _receipt.destination_kind,
        'receivedAt', _receipt.received_at) END);
  END IF;
  IF _request.status <> 'ordered' THEN
    RAISE EXCEPTION 'This request is not awaiting delivery. Refresh the inbox.' USING ERRCODE = '22023';
  END IF;
  IF _inventory_location_id IS NULL THEN
    RAISE EXCEPTION 'Refresh SportSpend and choose a receiving destination to receive this request.'
      USING ERRCODE = '22023';
  END IF;
  RETURN public.apply_supply_request_receipt(
    _organization_id, _request_id, _inventory_location_id, _internal_note, _staff_visible_note, NULL
  ) || jsonb_build_object('alreadyApplied', false);
END;
$$;

-- Lean and Standard: Receive & Complete. From ordered the destination is required (received
-- through the shared path, then completed). From received it completes only, keeping the
-- existing receipt; a destination, if given, must match it. Already completed: nothing written.
DROP FUNCTION public.receive_and_complete_supply_request(uuid, uuid, text, text);
CREATE FUNCTION public.receive_and_complete_supply_request(
  _organization_id uuid,
  _request_id uuid,
  _staff_visible_note text DEFAULT NULL,
  _internal_note text DEFAULT NULL,
  _inventory_location_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  _request public.supply_requests%ROWTYPE;
  _receipt public.supply_request_receipts%ROWTYPE;
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
  SELECT * INTO _receipt FROM public.supply_request_receipts WHERE supply_request_id = _request_id;

  IF _receipt.id IS NOT NULL AND _inventory_location_id IS NOT NULL
     AND _receipt.inventory_location_id IS DISTINCT FROM _inventory_location_id THEN
    RAISE EXCEPTION 'This request was already received to %. A receiving destination cannot be changed.',
      _receipt.destination_name_snapshot USING ERRCODE = '55000';
  END IF;
  IF _request.status = 'completed' THEN
    RETURN jsonb_build_object('id', _request.id, 'status', _request.status, 'orderedAt', _request.ordered_at,
      'receivedAt', _request.received_at, 'alreadyApplied', true,
      'receipt', CASE WHEN _receipt.id IS NULL THEN NULL ELSE jsonb_build_object(
        'id', _receipt.id, 'inventoryLocationId', _receipt.inventory_location_id,
        'destinationName', _receipt.destination_name_snapshot, 'destinationKind', _receipt.destination_kind,
        'receivedAt', _receipt.received_at) END);
  END IF;
  IF _request.status NOT IN ('ordered', 'received') THEN
    RAISE EXCEPTION 'This request is not awaiting delivery. Refresh the inbox.' USING ERRCODE = '22023';
  END IF;

  IF _request.status = 'ordered' THEN
    IF _inventory_location_id IS NULL THEN
      RAISE EXCEPTION 'Refresh SportSpend and choose a receiving destination to receive this request.'
        USING ERRCODE = '22023';
    END IF;
    PERFORM public.apply_supply_request_receipt(
      _organization_id, _request_id, _inventory_location_id, NULL, NULL, 'receive_and_complete'
    );
    _written := ARRAY['received']::public.supply_request_status[];
  ELSIF _receipt.id IS NULL AND _inventory_location_id IS NOT NULL THEN
    -- Received before receiving destinations were recorded: it completes without one.
    RAISE EXCEPTION 'This request was already received; a receiving destination cannot be added now.'
      USING ERRCODE = '22023';
  END IF;

  _result := public.apply_supply_request_transition(
    _organization_id, _request_id, 'completed', _internal_note, _staff_visible_note
  );
  _written := _written || 'completed'::public.supply_request_status;

  IF cardinality(_written) > 1 THEN
    PERFORM public.mark_supply_request_compound_action(_organization_id, _request_id, 'receive_and_complete', _written);
  END IF;

  SELECT * INTO _receipt FROM public.supply_request_receipts WHERE supply_request_id = _request_id;
  RETURN _result || jsonb_build_object(
    'alreadyApplied', false,
    'compoundAction', CASE WHEN cardinality(_written) > 1 THEN 'receive_and_complete' END,
    'transitions', to_jsonb(_written),
    'receipt', CASE WHEN _receipt.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id', _receipt.id, 'inventoryLocationId', _receipt.inventory_location_id,
      'destinationName', _receipt.destination_name_snapshot, 'destinationKind', _receipt.destination_kind,
      'receivedAt', _receipt.received_at) END
  );
END;
$$;

-- ---------------------------------------------------------------------------------------------
-- The generic lifecycle RPC no longer receives
-- ---------------------------------------------------------------------------------------------

-- Same signature, authorization and behavior as Phase 6C, except that 'received' is refused:
-- receiving goes through receive_supply_request / receive_and_complete_supply_request, which
-- record the destination. approved -> ordered, received -> completed, under review and denial
-- after approval are unchanged.
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
BEGIN
  IF NOT public.has_org_role(
    _organization_id, auth.uid(), ARRAY['owner','admin']::public.org_role[]
  ) THEN
    RAISE EXCEPTION 'Forbidden: administrator access required';
  END IF;

  IF _status = 'received' THEN
    RAISE EXCEPTION 'Use the receiving action to choose a receiving destination.' USING ERRCODE = '55000';
  END IF;

  SELECT * INTO _request
  FROM public.supply_requests
  WHERE id = _request_id AND organization_id = _organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Supply request not found'; END IF;

  IF _request.status IN ('submitted', 'under_review') AND _status IN ('approved', 'denied') THEN
    RAISE EXCEPTION 'Approve or decline this request through the request decision workflow.'
      USING ERRCODE = '42501';
  END IF;

  RETURN public.apply_supply_request_transition(
    _organization_id, _request_id, _status, _internal_note, _staff_visible_note
  );
END;
$$;

-- ---------------------------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.apply_supply_request_receipt(uuid, uuid, uuid, text, text, text)
  FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.list_receiving_destinations(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.list_receiving_destinations(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.list_supply_request_receipts(uuid, uuid[]) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.list_supply_request_receipts(uuid, uuid[]) TO authenticated;
REVOKE ALL ON FUNCTION public.receive_supply_request(uuid, uuid, text, text, uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.receive_supply_request(uuid, uuid, text, text, uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.receive_and_complete_supply_request(uuid, uuid, text, text, uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.receive_and_complete_supply_request(uuid, uuid, text, text, uuid) TO authenticated;

COMMENT ON TABLE public.supply_request_receipts IS
  'Phase 7C receipts: one immutable row per received request (V1): receiving destination (inventory location id plus name and kind snapshots), actor, time, the received history row and the compound action. Destination-only: no inventory effect. Written only by apply_supply_request_receipt.';

COMMIT;
