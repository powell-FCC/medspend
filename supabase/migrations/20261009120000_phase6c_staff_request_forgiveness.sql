-- Phase 6C: staff request forgiveness.
--
-- A requester may correct their own request while it is still 'submitted'. The
-- request keeps its ID and status; there is no draft state and no regression.
-- Admin review ('under_review') or any later status makes the request read-only.
--
-- Submission and editing share one context helper and one line helper, so both paths
-- apply exactly the Phase 5A.7 identity, quantity, team, and location rules. Neither
-- path touches commitments, budgets, purchasing, receiving, invoices, or pricing.
--
-- Because a submitted request can now change, an admin approve/decline must name the
-- request version (supply_requests.updated_at) it reviewed. A decision made from a
-- stale screen is rejected before any lifecycle, audit, or commitment write.
--
-- decide_supply_request is the only path for approval and denial of a pending request:
-- transition_supply_request refuses submitted/under_review -> approved/denied, and
-- direct table writes can no longer set or change a request's status.

BEGIN;

DO $phase6c_preflight$
BEGIN
  IF pg_catalog.to_regprocedure(
    'public.submit_supply_request(uuid,public.supply_request_type,uuid,uuid,text,jsonb)'
  ) IS NULL THEN
    RAISE EXCEPTION 'Phase 6C requires the existing submit_supply_request RPC signature';
  END IF;
  IF pg_catalog.to_regprocedure(
    'public.list_staff_supply_request_updates(uuid,uuid[])'
  ) IS NULL THEN
    RAISE EXCEPTION 'Phase 6C requires the existing list_staff_supply_request_updates RPC';
  END IF;
  IF pg_catalog.to_regprocedure(
    'public.decide_supply_request(uuid,uuid,public.supply_request_status,text,text)'
  ) IS NULL THEN
    RAISE EXCEPTION 'Phase 6C requires the existing Phase 6A.2 decide_supply_request RPC';
  END IF;
  IF pg_catalog.to_regprocedure(
    'public.transition_supply_request(uuid,uuid,public.supply_request_status,text,text)'
  ) IS NULL THEN
    RAISE EXCEPTION 'Phase 6C requires the existing Phase 6A.2 transition_supply_request RPC';
  END IF;
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'supply_request_updates'
      AND column_name = 'event_kind'
  ) THEN
    RAISE EXCEPTION 'Phase 6C supply_request_updates.event_kind already exists unexpectedly';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc procedure
    JOIN pg_catalog.pg_namespace procedure_namespace
      ON procedure_namespace.oid = procedure.pronamespace
    WHERE procedure_namespace.nspname = 'public'
      AND procedure.proname IN (
        'update_submitted_supply_request',
        'resolve_supply_request_context',
        'replace_supply_request_items',
        'apply_supply_request_transition',
        'guard_supply_request_lifecycle'
      )
  ) THEN
    RAISE EXCEPTION 'Phase 6C request edit functions already exist unexpectedly';
  END IF;
END
$phase6c_preflight$;

-- Requester edits reuse the existing audited update history. A requester edit carries
-- no lifecycle status and can never carry an admin note.
ALTER TABLE public.supply_request_updates
  ADD COLUMN event_kind text,
  ADD CONSTRAINT supply_request_updates_event_kind_check CHECK (
    event_kind IS NULL
    OR (
      event_kind = 'requester_edited'
      AND status_from IS NULL
      AND status_to IS NULL
      AND internal_note IS NULL
      AND staff_visible_note IS NULL
    )
  );

-- Shared request context: active membership, membership defaults, and active
-- organization-owned team/location. Unchanged from the Phase 5A.7 submission rules.
CREATE FUNCTION public.resolve_supply_request_context(
  _organization_id uuid,
  _requester_id uuid,
  _team_id uuid,
  _location_id uuid,
  OUT team_id uuid,
  OUT location_id uuid
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _membership public.organization_memberships%ROWTYPE;
BEGIN
  IF _requester_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  SELECT *
  INTO _membership
  FROM public.organization_memberships membership
  WHERE membership.organization_id = _organization_id
    AND membership.user_id = _requester_id
    AND membership.active = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Not a member of this organization' USING ERRCODE = '42501';
  END IF;

  team_id := coalesce(_team_id, _membership.default_team_id);
  location_id := coalesce(_location_id, _membership.default_location_id);
  IF team_id IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.teams team
    WHERE team.id = resolve_supply_request_context.team_id
      AND team.organization_id = _organization_id
      AND team.active = true
  ) THEN
    RAISE EXCEPTION 'Select an available team for this request';
  END IF;
  IF location_id IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.locations location
    WHERE location.id = resolve_supply_request_context.location_id
      AND location.organization_id = _organization_id
      AND location.active = true
  ) THEN
    RAISE EXCEPTION 'Select an available location for this request';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_supply_request_context(uuid, uuid, uuid, uuid)
  FROM PUBLIC, anon, authenticated;

-- Shared line validation. Replaces the complete line set of one request atomically
-- inside the caller's transaction. For a new request there are no lines to remove.
-- The per-line rules are the Phase 5A.7 submit_supply_request rules, unchanged.
CREATE FUNCTION public.replace_supply_request_items(
  _organization_id uuid,
  _request_id uuid,
  _items jsonb
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _item jsonb;
  _inventory public.inventory_items%ROWTYPE;
  _vendor_product public.vendor_products%ROWTYPE;
  _product public.products%ROWTYPE;
  _catalog_vendor_product public.catalog_vendor_products%ROWTYPE;
  _inventory_item_id uuid;
  _vendor_product_id uuid;
  _product_id uuid;
  _catalog_vendor_product_id uuid;
  _free_text text;
  _quantity numeric;
  _unit text;
  _first_product_id uuid;
  _first_free_text text;
  _first_quantity integer;
  _line_count integer := 0;
BEGIN
  IF _items IS NULL
     OR jsonb_typeof(_items) <> 'array'
     OR jsonb_array_length(_items) = 0 THEN
    RAISE EXCEPTION 'Add at least one item to the request';
  END IF;

  -- Request lines referenced by a commitment snapshot are protected by
  -- ON DELETE RESTRICT; callers only reach this point for uncommitted requests.
  DELETE FROM public.supply_request_items
  WHERE organization_id = _organization_id
    AND supply_request_id = _request_id;

  FOR _item IN SELECT value FROM jsonb_array_elements(_items)
  LOOP
    IF jsonb_typeof(_item) <> 'object' THEN
      RAISE EXCEPTION 'Each request line must be an object';
    END IF;

    _inventory_item_id := nullif(_item->>'inventoryItemId', '')::uuid;
    _vendor_product_id := nullif(_item->>'vendorProductId', '')::uuid;
    _product_id := nullif(_item->>'productId', '')::uuid;
    _catalog_vendor_product_id := nullif(_item->>'catalogVendorProductId', '')::uuid;
    _free_text := nullif(btrim(_item->>'freeTextItem'), '');
    _unit := NULL;

    BEGIN
      _quantity := (_item->>'quantity')::numeric;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'Each requested quantity must be a positive whole number';
    END;
    IF _quantity IS NULL OR _quantity <= 0 OR _quantity <> trunc(_quantity) THEN
      RAISE EXCEPTION 'Each requested quantity must be a positive whole number';
    END IF;

    IF _free_text IS NOT NULL AND (
      _inventory_item_id IS NOT NULL
      OR _vendor_product_id IS NOT NULL
      OR _product_id IS NOT NULL
      OR _catalog_vendor_product_id IS NOT NULL
    ) THEN
      RAISE EXCEPTION 'A custom request line cannot include structured identity IDs'
        USING ERRCODE = '22023';
    END IF;
    IF _free_text IS NULL
       AND _inventory_item_id IS NULL
       AND _vendor_product_id IS NULL
       AND _product_id IS NULL
       AND _catalog_vendor_product_id IS NULL THEN
      RAISE EXCEPTION 'Each line must contain a structured identity or one custom item'
        USING ERRCODE = '22023';
    END IF;

    IF _inventory_item_id IS NOT NULL THEN
      SELECT *
      INTO _inventory
      FROM public.inventory_items
      WHERE id = _inventory_item_id
        AND organization_id = _organization_id
        AND active = true;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'A selected inventory item is unavailable for this organization'
          USING ERRCODE = 'P0002';
      END IF;

      IF _inventory.product_id IS NULL THEN
        IF _product_id IS NOT NULL OR _vendor_product_id IS NOT NULL
           OR _catalog_vendor_product_id IS NOT NULL THEN
          RAISE EXCEPTION 'The selected inventory item has no proven product identity chain'
            USING ERRCODE = '22023';
        END IF;
      ELSIF _product_id IS NOT NULL AND _product_id <> _inventory.product_id THEN
        RAISE EXCEPTION 'The selected inventory item does not belong to the supplied product'
          USING ERRCODE = '22023';
      ELSE
        _product_id := _inventory.product_id;
      END IF;
      _unit := _inventory.unit;
    END IF;

    IF _vendor_product_id IS NOT NULL THEN
      SELECT vendor_product.*
      INTO _vendor_product
      FROM public.vendor_products vendor_product
      JOIN public.vendors vendor
        ON vendor.id = vendor_product.vendor_id
       AND vendor.organization_id = vendor_product.organization_id
       AND vendor.active = true
      WHERE vendor_product.id = _vendor_product_id
        AND vendor_product.organization_id = _organization_id
        AND vendor_product.active = true;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'A selected vendor product is unavailable for this organization'
          USING ERRCODE = 'P0002';
      END IF;

      IF _product_id IS NOT NULL AND _product_id <> _vendor_product.product_id THEN
        RAISE EXCEPTION 'The selected vendor product does not belong to the supplied product'
          USING ERRCODE = '22023';
      END IF;
      _product_id := _vendor_product.product_id;

      IF _vendor_product.catalog_vendor_product_id IS NOT NULL THEN
        IF _catalog_vendor_product_id IS NOT NULL
           AND _catalog_vendor_product_id <> _vendor_product.catalog_vendor_product_id THEN
          RAISE EXCEPTION 'The selected vendor product does not link to the supplied global catalog identity'
            USING ERRCODE = '22023';
        END IF;
        _catalog_vendor_product_id := _vendor_product.catalog_vendor_product_id;
      ELSIF _catalog_vendor_product_id IS NOT NULL THEN
        RAISE EXCEPTION 'The selected vendor product has no proven global catalog link'
          USING ERRCODE = '22023';
      END IF;
    END IF;

    IF _product_id IS NOT NULL THEN
      SELECT *
      INTO _product
      FROM public.products
      WHERE id = _product_id
        AND organization_id = _organization_id
        AND active = true
        AND staff_requestable = true;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'A selected product is unavailable for this organization'
          USING ERRCODE = 'P0002';
      END IF;
      IF _unit IS NULL THEN
        _unit := _product.unit_of_measure;
      END IF;
    END IF;

    IF _catalog_vendor_product_id IS NOT NULL THEN
      SELECT catalog_vendor_product.*
      INTO _catalog_vendor_product
      FROM public.catalog_vendor_products catalog_vendor_product
      JOIN public.catalog_products catalog_product
        ON catalog_product.id = catalog_vendor_product.catalog_product_id
       AND catalog_product.active = true
      JOIN public.catalog_vendors catalog_vendor
        ON catalog_vendor.id = catalog_vendor_product.catalog_vendor_id
       AND catalog_vendor.active = true
      WHERE catalog_vendor_product.id = _catalog_vendor_product_id
        AND catalog_vendor_product.active = true
        AND catalog_vendor_product.discontinued = false;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'A selected global catalog product is unavailable'
          USING ERRCODE = 'P0002';
      END IF;

      IF _vendor_product_id IS NULL AND (
        _product_id IS NOT NULL OR _inventory_item_id IS NOT NULL
      ) THEN
        RAISE EXCEPTION 'A local product cannot claim an unproven global catalog identity'
          USING ERRCODE = '22023';
      END IF;
    END IF;

    INSERT INTO public.supply_request_items (
      organization_id,
      supply_request_id,
      product_id,
      inventory_item_id,
      vendor_product_id,
      catalog_vendor_product_id,
      free_text_item,
      quantity,
      unit
    ) VALUES (
      _organization_id,
      _request_id,
      _product_id,
      _inventory_item_id,
      _vendor_product_id,
      _catalog_vendor_product_id,
      _free_text,
      _quantity::integer,
      _unit
    );
    _line_count := _line_count + 1;

    IF _first_quantity IS NULL THEN
      _first_product_id := _product_id;
      _first_free_text := _free_text;
      _first_quantity := _quantity::integer;
    END IF;
  END LOOP;

  -- Preserve the established first-line compatibility mirror. A global-only or
  -- unlinked-inventory first line intentionally leaves both legacy identity fields null.
  UPDATE public.supply_requests
  SET product_id = _first_product_id,
      free_text_item = _first_free_text,
      quantity = _first_quantity
  WHERE id = _request_id
    AND organization_id = _organization_id;

  RETURN _line_count;
END;
$$;

REVOKE ALL ON FUNCTION public.replace_supply_request_items(uuid, uuid, jsonb)
  FROM PUBLIC, anon, authenticated;

-- Same signature, same validation order, same errors. Submission now delegates to the
-- helpers shared with requester editing.
CREATE OR REPLACE FUNCTION public.submit_supply_request(
  _organization_id uuid,
  _request_type public.supply_request_type,
  _team_id uuid,
  _location_id uuid,
  _notes text,
  _items jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid uuid := auth.uid();
  _context record;
  _request_id uuid;
BEGIN
  SELECT *
  INTO _context
  FROM public.resolve_supply_request_context(_organization_id, _uid, _team_id, _location_id);

  INSERT INTO public.supply_requests (
    organization_id,
    requested_by,
    request_type,
    team_id,
    location_id,
    notes,
    status
  ) VALUES (
    _organization_id,
    _uid,
    _request_type,
    _context.team_id,
    _context.location_id,
    nullif(btrim(_notes), ''),
    'submitted'
  )
  RETURNING id INTO _request_id;

  PERFORM public.replace_supply_request_items(_organization_id, _request_id, _items);

  RETURN _request_id;
END;
$$;

REVOKE ALL ON FUNCTION public.submit_supply_request(
  uuid, public.supply_request_type, uuid, uuid, text, jsonb
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.submit_supply_request(
  uuid, public.supply_request_type, uuid, uuid, text, jsonb
) FROM anon;
GRANT EXECUTE ON FUNCTION public.submit_supply_request(
  uuid, public.supply_request_type, uuid, uuid, text, jsonb
) TO authenticated;

-- The requester edit boundary. The request row lock is the same lock taken by
-- transition_supply_request, decide_supply_request, and commitment creation, so an
-- edit and an admin transition serialize: whichever commits second sees the other.
CREATE FUNCTION public.update_submitted_supply_request(
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

REVOKE ALL ON FUNCTION public.update_submitted_supply_request(
  uuid, uuid, public.supply_request_type, uuid, uuid, text, jsonb
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_submitted_supply_request(
  uuid, uuid, public.supply_request_type, uuid, uuid, text, jsonb
) TO authenticated;

-- Staff-safe projection gains requester edit events. Internal notes stay excluded.
-- PostgreSQL requires a drop/recreate to add a result column; this runs inside the
-- migration transaction with the original access rules restored.
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
    SELECT u.id, u.supply_request_id, u.status_from, u.status_to, u.staff_visible_note,
      u.event_kind, u.created_at
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

-- Canonical lifecycle. The Phase 6A.2 transition body moves verbatim into a private
-- helper so decide_supply_request can still run its decision transitions (including
-- 6A.2 commitment creation and denial release) without a public route to them.
CREATE FUNCTION public.apply_supply_request_transition(
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

  IF _status = 'approved' THEN
    PERFORM public.create_supply_request_commitment(
      _organization_id, _request.id, now(), auth.uid()
    );
  ELSIF _status = 'denied' AND EXISTS (
    SELECT 1 FROM public.supply_request_commitments commitment
    WHERE commitment.supply_request_id = _request.id
      AND commitment.organization_id = _organization_id
      AND commitment.status = 'active'
  ) THEN
    PERFORM public.release_supply_request_commitment(
      _organization_id, _request.id, 'denied', 'Request denied through request lifecycle'
    );
  END IF;

  SELECT * INTO _request FROM public.supply_requests WHERE id = _request.id;
  RETURN jsonb_build_object(
    'id', _request.id,
    'status', _request.status,
    'orderedAt', _request.ordered_at,
    'receivedAt', _request.received_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.apply_supply_request_transition(
  uuid, uuid, public.supply_request_status, text, text
) FROM PUBLIC, anon, authenticated;

-- The public lifecycle RPC keeps its signature and its operational steps
-- (submitted -> under_review, approved -> ordered -> received -> completed, and
-- denial after approval), but a pending request can only be approved or denied
-- through decide_supply_request, which enforces the reviewed-version check.
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

REVOKE ALL ON FUNCTION public.transition_supply_request(
  uuid, uuid, public.supply_request_status, text, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.transition_supply_request(
  uuid, uuid, public.supply_request_status, text, text
) TO authenticated;

-- Direct API writes (PostgREST runs them as authenticated/anon) can no longer create a
-- request in, or move a request to, any lifecycle status. The lifecycle RPCs are
-- SECURITY DEFINER, so their writes run as the function owner and are unaffected.
-- Other columns keep their existing grants and RLS policies.
CREATE FUNCTION public.guard_supply_request_lifecycle()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF current_user IN ('authenticated', 'anon') THEN
    IF TG_OP = 'INSERT' AND NEW.status IS DISTINCT FROM 'submitted' THEN
      RAISE EXCEPTION 'New requests must start as submitted' USING ERRCODE = '42501';
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status THEN
      RAISE EXCEPTION 'Request status can only change through the request lifecycle workflow'
        USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.guard_supply_request_lifecycle() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER supply_requests_lifecycle_guard
  BEFORE INSERT OR UPDATE OF status ON public.supply_requests
  FOR EACH ROW EXECUTE FUNCTION public.guard_supply_request_lifecycle();

-- Optimistic concurrency for admin decisions. supply_requests.updated_at is the version:
-- sr_updated_at bumps it on every request write, including requester edits (which always
-- update the parent row) and every lifecycle transition. Phase 6A.2 semantics are
-- otherwise unchanged: same lock, same authorization, same same-decision retry result,
-- same terminal-state error, same commitment creation inside the (now private)
-- transition body.
-- The version parameter is appended so existing named arguments keep their meaning; a
-- missing version is treated as stale, so no caller can decide without naming what it
-- reviewed. Adding a parameter requires a drop/recreate inside this transaction.
DROP FUNCTION public.decide_supply_request(
  uuid, uuid, public.supply_request_status, text, text
);
CREATE FUNCTION public.decide_supply_request(
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
  -- Checked under the row lock, before any transition, audit row, or commitment.
  IF _expected_updated_at IS NULL OR _request.updated_at IS DISTINCT FROM _expected_updated_at THEN
    RAISE EXCEPTION 'This request changed while you were reviewing it. Refresh the request and review the latest details before making a decision.'
      USING ERRCODE = '40001';
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
