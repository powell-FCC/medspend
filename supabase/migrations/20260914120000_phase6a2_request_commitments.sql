-- Phase 6A.2: immutable request commitments and organization-level budget impact.
-- There is deliberately no request-to-invoice matching. A commitment remains active
-- until denial or an explicit, audited admin release replaces it with actual spend
-- (or records that the obligation no longer exists).

BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS supply_request_items_id_org_uq
  ON public.supply_request_items (id, organization_id);

CREATE TABLE public.supply_request_commitments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  supply_request_id uuid NOT NULL UNIQUE,
  amount numeric NOT NULL CHECK (amount >= 0),
  currency_code text NOT NULL DEFAULT 'USD' CHECK (currency_code = 'USD'),
  total_item_count integer NOT NULL CHECK (total_item_count >= 0),
  priced_item_count integer NOT NULL CHECK (
    priced_item_count >= 0 AND priced_item_count <= total_item_count
  ),
  pricing_status text NOT NULL CHECK (
    pricing_status IN ('fully_priced', 'partially_priced', 'unpriced')
  ),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'released')),
  committed_at timestamptz NOT NULL DEFAULT now(),
  committed_by uuid,
  released_at timestamptz,
  released_by uuid,
  release_kind text CHECK (
    release_kind IS NULL OR release_kind IN ('denied', 'settled', 'cancelled', 'adjustment', 'other')
  ),
  release_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT supply_request_commitments_request_org_fk
    FOREIGN KEY (supply_request_id, organization_id)
    REFERENCES public.supply_requests(id, organization_id) ON DELETE RESTRICT,
  CONSTRAINT supply_request_commitments_pricing_consistency_check CHECK (
    (pricing_status = 'unpriced' AND priced_item_count = 0 AND amount = 0)
    OR (pricing_status = 'fully_priced' AND total_item_count > 0
        AND priced_item_count = total_item_count)
    OR (pricing_status = 'partially_priced' AND priced_item_count > 0
        AND priced_item_count < total_item_count)
  ),
  CONSTRAINT supply_request_commitments_release_state_check CHECK (
    (status = 'active' AND released_at IS NULL AND released_by IS NULL
      AND release_kind IS NULL AND release_reason IS NULL)
    OR (status = 'released' AND released_at IS NOT NULL
      AND release_kind IS NOT NULL AND nullif(btrim(release_reason), '') IS NOT NULL)
  )
);

CREATE UNIQUE INDEX supply_request_commitments_id_org_uq
  ON public.supply_request_commitments (id, organization_id);
CREATE INDEX supply_request_commitments_org_active_date_idx
  ON public.supply_request_commitments (organization_id, committed_at)
  WHERE status = 'active';

CREATE TABLE public.supply_request_commitment_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  commitment_id uuid NOT NULL,
  supply_request_item_id uuid NOT NULL UNIQUE,
  quantity_snapshot integer NOT NULL CHECK (quantity_snapshot > 0),
  unit_cost_snapshot numeric,
  line_amount_snapshot numeric,
  currency_code text,
  price_source text NOT NULL CHECK (
    price_source IN (
      'vendor_purchase_history',
      'inventory_last_purchase',
      'product_purchase_history',
      'catalog_source_price',
      'unpriced'
    )
  ),
  price_reference_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT supply_request_commitment_items_commitment_org_fk
    FOREIGN KEY (commitment_id, organization_id)
    REFERENCES public.supply_request_commitments(id, organization_id) ON DELETE RESTRICT,
  CONSTRAINT supply_request_commitment_items_request_item_org_fk
    FOREIGN KEY (supply_request_item_id, organization_id)
    REFERENCES public.supply_request_items(id, organization_id) ON DELETE RESTRICT,
  CONSTRAINT supply_request_commitment_items_price_check CHECK (
    (price_source = 'unpriced' AND unit_cost_snapshot IS NULL
      AND line_amount_snapshot IS NULL AND currency_code IS NULL
      AND price_reference_id IS NULL)
    OR (price_source <> 'unpriced' AND unit_cost_snapshot >= 0
      AND line_amount_snapshot = unit_cost_snapshot * quantity_snapshot
      AND currency_code = 'USD' AND price_reference_id IS NOT NULL)
  )
);

CREATE INDEX supply_request_commitment_items_commitment_idx
  ON public.supply_request_commitment_items (commitment_id);

ALTER TABLE public.supply_request_commitments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supply_request_commitment_items ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON public.supply_request_commitments TO authenticated;
GRANT SELECT ON public.supply_request_commitment_items TO authenticated;
GRANT ALL ON public.supply_request_commitments TO service_role;
GRANT ALL ON public.supply_request_commitment_items TO service_role;

CREATE POLICY supply_request_commitments_admin_select
  ON public.supply_request_commitments FOR SELECT TO authenticated
  USING (public.is_org_admin(organization_id, auth.uid()));
CREATE POLICY supply_request_commitment_items_admin_select
  ON public.supply_request_commitment_items FOR SELECT TO authenticated
  USING (public.is_org_admin(organization_id, auth.uid()));

-- Resolve a current estimate for each request line. Purchase observations are
-- preferred to mutable inventory metadata, which is preferred to a USD catalog
-- source/list price. This helper is private and its result is only historical truth
-- after it has been copied into the immutable snapshot tables.
CREATE FUNCTION public.resolve_supply_request_item_costs(
  _organization_id uuid,
  _request_id uuid
)
RETURNS TABLE (
  supply_request_item_id uuid,
  quantity integer,
  unit_cost numeric,
  line_amount numeric,
  price_source text,
  price_reference_id uuid
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    item.id,
    item.quantity,
    price.unit_cost,
    price.unit_cost * item.quantity,
    COALESCE(price.price_source, 'unpriced'),
    price.price_reference_id
  FROM public.supply_request_items item
  LEFT JOIN LATERAL (
    SELECT candidate.unit_cost, candidate.price_source, candidate.price_reference_id
    FROM (
      SELECT
        history.unit_cost,
        'vendor_purchase_history'::text AS price_source,
        history.invoice_item_id AS price_reference_id,
        1 AS priority
      FROM LATERAL (
        SELECT
          candidate.invoice_item_id,
          COALESCE(candidate.unit_price, candidate.extended_price / NULLIF(candidate.quantity, 0)) AS unit_cost
        FROM public.inventory_price_history candidate
        WHERE item.vendor_product_id IS NOT NULL
          AND candidate.organization_id = item.organization_id
          AND candidate.vendor_product_id = item.vendor_product_id
          AND COALESCE(candidate.unit_price, candidate.extended_price / NULLIF(candidate.quantity, 0)) IS NOT NULL
        ORDER BY candidate.purchase_date DESC, candidate.created_at DESC, candidate.id DESC
        LIMIT 1
      ) history

      UNION ALL

      SELECT inventory.last_purchase_price, 'inventory_last_purchase', inventory.id, 2
      FROM public.inventory_items inventory
      WHERE item.inventory_item_id IS NOT NULL
        AND inventory.id = item.inventory_item_id
        AND inventory.organization_id = item.organization_id
        AND inventory.last_purchase_price IS NOT NULL

      UNION ALL

      SELECT
        history.unit_cost,
        'product_purchase_history',
        history.invoice_item_id,
        3
      FROM LATERAL (
        SELECT
          candidate.invoice_item_id,
          COALESCE(candidate.unit_price, candidate.extended_price / NULLIF(candidate.quantity, 0)) AS unit_cost
        FROM public.inventory_price_history candidate
        WHERE item.product_id IS NOT NULL
          AND candidate.organization_id = item.organization_id
          AND candidate.product_id = item.product_id
          AND COALESCE(candidate.unit_price, candidate.extended_price / NULLIF(candidate.quantity, 0)) IS NOT NULL
        ORDER BY candidate.purchase_date DESC, candidate.created_at DESC, candidate.id DESC
        LIMIT 1
      ) history

      UNION ALL

      SELECT catalog.source_catalog_price, 'catalog_source_price', catalog.id, 4
      FROM public.catalog_vendor_products catalog
      WHERE item.catalog_vendor_product_id IS NOT NULL
        AND catalog.id = item.catalog_vendor_product_id
        AND catalog.source_catalog_price IS NOT NULL
        AND catalog.currency_code = 'USD'
    ) candidate
    WHERE candidate.unit_cost >= 0
    ORDER BY candidate.priority
    LIMIT 1
  ) price ON true
  WHERE item.organization_id = _organization_id
    AND item.supply_request_id = _request_id
  ORDER BY item.created_at, item.id
$$;

REVOKE ALL ON FUNCTION public.resolve_supply_request_item_costs(uuid, uuid)
  FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.create_supply_request_commitment(
  _organization_id uuid,
  _request_id uuid,
  _committed_at timestamptz DEFAULT now(),
  _committed_by uuid DEFAULT auth.uid()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _request public.supply_requests%ROWTYPE;
  _commitment public.supply_request_commitments%ROWTYPE;
  _already_committed boolean;
BEGIN
  SELECT * INTO _request
  FROM public.supply_requests
  WHERE id = _request_id AND organization_id = _organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Supply request not found' USING ERRCODE = 'P0002'; END IF;
  IF _request.status NOT IN ('approved', 'ordered', 'received', 'completed') THEN
    RAISE EXCEPTION 'Only an approved request can become committed' USING ERRCODE = '22023';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.supply_request_commitments commitment
    WHERE commitment.supply_request_id = _request_id
      AND commitment.organization_id = _organization_id
  ) INTO _already_committed;

  WITH estimates AS MATERIALIZED (
    SELECT * FROM public.resolve_supply_request_item_costs(_organization_id, _request_id)
  ),
  totals AS (
    SELECT
      COUNT(*)::integer AS total_item_count,
      COUNT(unit_cost)::integer AS priced_item_count,
      COALESCE(SUM(line_amount), 0)::numeric AS amount
    FROM estimates
  ),
  inserted_commitment AS (
    INSERT INTO public.supply_request_commitments (
      organization_id, supply_request_id, amount, total_item_count,
      priced_item_count, pricing_status, committed_at, committed_by
    )
    SELECT
      _organization_id,
      _request_id,
      totals.amount,
      totals.total_item_count,
      totals.priced_item_count,
      CASE
        WHEN totals.priced_item_count = 0 THEN 'unpriced'
        WHEN totals.priced_item_count = totals.total_item_count THEN 'fully_priced'
        ELSE 'partially_priced'
      END,
      COALESCE(_committed_at, now()),
      _committed_by
    FROM totals
    ON CONFLICT (supply_request_id) DO NOTHING
    RETURNING id, organization_id
  )
  INSERT INTO public.supply_request_commitment_items (
    organization_id, commitment_id, supply_request_item_id, quantity_snapshot,
    unit_cost_snapshot, line_amount_snapshot, currency_code, price_source,
    price_reference_id
  )
  SELECT
    inserted_commitment.organization_id,
    inserted_commitment.id,
    estimates.supply_request_item_id,
    estimates.quantity,
    estimates.unit_cost,
    estimates.line_amount,
    CASE WHEN estimates.unit_cost IS NULL THEN NULL ELSE 'USD' END,
    estimates.price_source,
    estimates.price_reference_id
  FROM inserted_commitment
  CROSS JOIN estimates;

  SELECT * INTO _commitment
  FROM public.supply_request_commitments
  WHERE supply_request_id = _request_id AND organization_id = _organization_id;

  RETURN jsonb_build_object(
    'id', _commitment.id,
    'status', _commitment.status,
    'amount', _commitment.amount,
    'pricingStatus', _commitment.pricing_status,
    'alreadyCommitted', _already_committed
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_supply_request_commitment(uuid, uuid, timestamptz, uuid)
  FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.supply_request_commitment_parent_immutable()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.organization_id IS DISTINCT FROM OLD.organization_id
     OR NEW.supply_request_id IS DISTINCT FROM OLD.supply_request_id
     OR NEW.amount IS DISTINCT FROM OLD.amount
     OR NEW.currency_code IS DISTINCT FROM OLD.currency_code
     OR NEW.total_item_count IS DISTINCT FROM OLD.total_item_count
     OR NEW.priced_item_count IS DISTINCT FROM OLD.priced_item_count
     OR NEW.pricing_status IS DISTINCT FROM OLD.pricing_status
     OR NEW.committed_at IS DISTINCT FROM OLD.committed_at
     OR NEW.committed_by IS DISTINCT FROM OLD.committed_by
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'Committed financial snapshots are immutable';
  END IF;
  IF OLD.status = 'released' AND NEW IS DISTINCT FROM OLD THEN
    RAISE EXCEPTION 'Released commitments are immutable';
  END IF;
  IF OLD.status = 'active' AND NEW.status = 'released' THEN
    IF NEW.released_at IS NULL OR NEW.release_kind IS NULL
       OR nullif(btrim(NEW.release_reason), '') IS NULL THEN
      RAISE EXCEPTION 'Commitment release metadata is required';
    END IF;
    RETURN NEW;
  END IF;
  IF NEW IS DISTINCT FROM OLD THEN
    RAISE EXCEPTION 'Commitment state can only move from active to released';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER supply_request_commitment_parent_immutable
  BEFORE UPDATE ON public.supply_request_commitments
  FOR EACH ROW EXECUTE FUNCTION public.supply_request_commitment_parent_immutable();

CREATE FUNCTION public.supply_request_commitment_item_immutable()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  RAISE EXCEPTION 'Committed item snapshots are immutable';
END;
$$;

CREATE TRIGGER supply_request_commitment_item_immutable
  BEFORE UPDATE OR DELETE ON public.supply_request_commitment_items
  FOR EACH ROW EXECUTE FUNCTION public.supply_request_commitment_item_immutable();

CREATE FUNCTION public.release_supply_request_commitment(
  _organization_id uuid,
  _request_id uuid,
  _release_kind text,
  _release_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _request public.supply_requests%ROWTYPE;
  _commitment public.supply_request_commitments%ROWTYPE;
BEGIN
  IF NOT public.is_org_admin(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: administrator access required' USING ERRCODE = '42501';
  END IF;
  IF _release_kind NOT IN ('denied', 'settled', 'cancelled', 'adjustment', 'other') THEN
    RAISE EXCEPTION 'Choose a valid commitment release reason' USING ERRCODE = '22023';
  END IF;
  IF nullif(btrim(_release_reason), '') IS NULL OR length(_release_reason) > 1000 THEN
    RAISE EXCEPTION 'A release explanation of at most 1000 characters is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO _request
  FROM public.supply_requests
  WHERE id = _request_id AND organization_id = _organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Supply request not found' USING ERRCODE = 'P0002'; END IF;
  IF _release_kind = 'denied' AND _request.status <> 'denied' THEN
    RAISE EXCEPTION 'Denied releases require a denied request' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO _commitment
  FROM public.supply_request_commitments
  WHERE supply_request_id = _request_id AND organization_id = _organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'This request has no commitment' USING ERRCODE = 'P0002'; END IF;
  IF _commitment.status = 'released' THEN
    RETURN jsonb_build_object(
      'id', _commitment.id, 'status', _commitment.status, 'alreadyReleased', true
    );
  END IF;

  UPDATE public.supply_request_commitments
  SET status = 'released',
      released_at = now(),
      released_by = auth.uid(),
      release_kind = _release_kind,
      release_reason = btrim(_release_reason)
  WHERE id = _commitment.id;

  RETURN jsonb_build_object(
    'id', _commitment.id, 'status', 'released', 'alreadyReleased', false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.release_supply_request_commitment(uuid, uuid, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.release_supply_request_commitment(uuid, uuid, text, text)
  TO authenticated;

-- Replace the lifecycle function so commitment changes share the same request lock and
-- transaction as the audited status transition. Received/completed intentionally do not
-- release commitments.
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

REVOKE ALL ON FUNCTION public.transition_supply_request(
  uuid, uuid, public.supply_request_status, text, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.transition_supply_request(
  uuid, uuid, public.supply_request_status, text, text
) TO authenticated;

-- Preserve Phase 5A.9 decision semantics. Approval now gains commitment creation from
-- transition_supply_request while the same request row remains locked.
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

REVOKE ALL ON FUNCTION public.decide_supply_request(uuid, uuid, public.supply_request_status, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.decide_supply_request(uuid, uuid, public.supply_request_status, text, text)
  TO authenticated;

-- Historical prices at approval cannot be reconstructed safely. Represent every
-- request that demonstrably reached approval as an explicit unpriced snapshot.
WITH historical AS (
  SELECT
    request.id AS supply_request_id,
    request.organization_id,
    COALESCE(approved.created_at, request.ordered_at, request.received_at, request.updated_at) AS committed_at,
    approved.author_id AS committed_by,
    COUNT(item.id)::integer AS total_item_count,
    request.status,
    denied.created_at AS released_at,
    denied.author_id AS released_by
  FROM public.supply_requests request
  LEFT JOIN LATERAL (
    SELECT update_row.created_at, update_row.author_id
    FROM public.supply_request_updates update_row
    WHERE update_row.supply_request_id = request.id
      AND update_row.organization_id = request.organization_id
      AND update_row.status_to = 'approved'
    ORDER BY update_row.created_at, update_row.id
    LIMIT 1
  ) approved ON true
  LEFT JOIN LATERAL (
    SELECT update_row.created_at, update_row.author_id
    FROM public.supply_request_updates update_row
    WHERE update_row.supply_request_id = request.id
      AND update_row.organization_id = request.organization_id
      AND update_row.status_to = 'denied'
    ORDER BY update_row.created_at DESC, update_row.id DESC
    LIMIT 1
  ) denied ON true
  LEFT JOIN public.supply_request_items item
    ON item.supply_request_id = request.id
   AND item.organization_id = request.organization_id
  WHERE request.status IN ('approved', 'ordered', 'received', 'completed')
     OR (request.status = 'denied' AND approved.created_at IS NOT NULL)
  GROUP BY request.id, request.organization_id, approved.created_at, approved.author_id,
    request.ordered_at, request.received_at, request.updated_at, request.status,
    denied.created_at, denied.author_id
)
INSERT INTO public.supply_request_commitments (
  organization_id, supply_request_id, amount, total_item_count, priced_item_count,
  pricing_status, status, committed_at, committed_by, released_at, released_by,
  release_kind, release_reason
)
SELECT
  historical.organization_id,
  historical.supply_request_id,
  0,
  historical.total_item_count,
  0,
  'unpriced',
  CASE WHEN historical.status = 'denied' THEN 'released' ELSE 'active' END,
  historical.committed_at,
  historical.committed_by,
  CASE WHEN historical.status = 'denied' THEN COALESCE(historical.released_at, historical.committed_at) END,
  CASE WHEN historical.status = 'denied' THEN historical.released_by END,
  CASE WHEN historical.status = 'denied' THEN 'denied' END,
  CASE WHEN historical.status = 'denied' THEN 'Historical request was denied after approval' END
FROM historical
ON CONFLICT (supply_request_id) DO NOTHING;

INSERT INTO public.supply_request_commitment_items (
  organization_id, commitment_id, supply_request_item_id, quantity_snapshot,
  price_source
)
SELECT item.organization_id, commitment.id, item.id, item.quantity, 'unpriced'
FROM public.supply_request_items item
JOIN public.supply_request_commitments commitment
  ON commitment.supply_request_id = item.supply_request_id
 AND commitment.organization_id = item.organization_id
ON CONFLICT (supply_request_item_id) DO NOTHING;

-- PostgreSQL requires a drop/recreate to add result columns. This happens inside the
-- migration transaction; all Phase 6A.1 invoice resolution and access rules remain.
DROP FUNCTION public.get_budget_summary(uuid, uuid);
CREATE FUNCTION public.get_budget_summary(
  _organization_id uuid,
  _budget_id uuid
)
RETURNS TABLE (
  budget_id uuid,
  budget_name text,
  period_start date,
  period_end date,
  budget_amount numeric,
  actual_spend numeric,
  committed_spend numeric,
  available_amount numeric,
  remaining_amount numeric,
  posted_invoice_count bigint,
  active_commitment_count bigint,
  incomplete_commitment_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_org_admin(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required';
  END IF;

  RETURN QUERY
  WITH posted_invoices AS (
    SELECT
      invoice.id,
      invoice.organization_id,
      COALESCE(
        invoice.invoice_total,
        invoice.total_amount,
        invoice.total,
        (
          SELECT SUM(item.total_price)
          FROM public.invoice_items item
          WHERE item.invoice_id = invoice.id
            AND item.organization_id = invoice.organization_id
        ),
        0
      )::numeric AS resolved_total,
      COALESCE(invoice.invoice_date, invoice.posted_at::date) AS spend_date
    FROM public.invoices invoice
    WHERE invoice.organization_id = _organization_id
      AND invoice.posted_at IS NOT NULL
  ),
  budget_totals AS (
    SELECT
      budget.id,
      budget.name,
      budget.period_start,
      budget.period_end,
      budget.amount,
      COALESCE((SELECT SUM(invoice.resolved_total) FROM posted_invoices invoice
        WHERE invoice.spend_date BETWEEN budget.period_start AND budget.period_end), 0)::numeric AS actual_spend,
      COALESCE((SELECT SUM(commitment.amount) FROM public.supply_request_commitments commitment
        WHERE commitment.organization_id = budget.organization_id
          AND commitment.status = 'active'
          AND commitment.committed_at::date BETWEEN budget.period_start AND budget.period_end), 0)::numeric AS committed_spend,
      (SELECT COUNT(*) FROM posted_invoices invoice
        WHERE invoice.spend_date BETWEEN budget.period_start AND budget.period_end)::bigint AS posted_invoice_count,
      (SELECT COUNT(*) FROM public.supply_request_commitments commitment
        WHERE commitment.organization_id = budget.organization_id
          AND commitment.status = 'active'
          AND commitment.committed_at::date BETWEEN budget.period_start AND budget.period_end)::bigint AS active_commitment_count,
      (SELECT COUNT(*) FROM public.supply_request_commitments commitment
        WHERE commitment.organization_id = budget.organization_id
          AND commitment.status = 'active'
          AND commitment.pricing_status <> 'fully_priced'
          AND commitment.committed_at::date BETWEEN budget.period_start AND budget.period_end)::bigint AS incomplete_commitment_count
    FROM public.organization_budgets budget
    WHERE budget.organization_id = _organization_id
      AND budget.id = _budget_id
  )
  SELECT
    totals.id,
    totals.name,
    totals.period_start,
    totals.period_end,
    totals.amount,
    totals.actual_spend,
    totals.committed_spend,
    (totals.amount - totals.actual_spend - totals.committed_spend)::numeric,
    (totals.amount - totals.actual_spend)::numeric,
    totals.posted_invoice_count,
    totals.active_commitment_count,
    totals.incomplete_commitment_count
  FROM budget_totals totals;
END;
$$;

REVOKE ALL ON FUNCTION public.get_budget_summary(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_budget_summary(uuid, uuid) TO authenticated;

CREATE FUNCTION public.get_supply_request_budget_impact(
  _organization_id uuid,
  _request_id uuid
)
RETURNS TABLE (
  request_id uuid,
  request_status public.supply_request_status,
  estimated_amount numeric,
  pricing_status text,
  total_item_count integer,
  priced_item_count integer,
  commitment_status text,
  commitment_release_reason text,
  budget_id uuid,
  budget_name text,
  budget_amount numeric,
  actual_spend numeric,
  committed_spend numeric,
  available_amount numeric,
  projected_available_after_approval numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_org_admin(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: administrator access required' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.supply_requests request
    WHERE request.id = _request_id AND request.organization_id = _organization_id
  ) THEN
    RAISE EXCEPTION 'Supply request not found' USING ERRCODE = 'P0002';
  END IF;

  RETURN QUERY
  WITH live_estimates AS MATERIALIZED (
    SELECT * FROM public.resolve_supply_request_item_costs(_organization_id, _request_id)
  ),
  live_total AS (
    SELECT
      COUNT(*)::integer AS total_item_count,
      COUNT(unit_cost)::integer AS priced_item_count,
      COALESCE(SUM(line_amount), 0)::numeric AS amount
    FROM live_estimates
  ),
  request_cost AS (
    SELECT
      request.id,
      request.status AS lifecycle_status,
      COALESCE(commitment.amount, live.amount) AS amount,
      COALESCE(commitment.total_item_count, live.total_item_count) AS total_item_count,
      COALESCE(commitment.priced_item_count, live.priced_item_count) AS priced_item_count,
      COALESCE(commitment.pricing_status, CASE
        WHEN live.priced_item_count = 0 THEN 'unpriced'
        WHEN live.priced_item_count = live.total_item_count THEN 'fully_priced'
        ELSE 'partially_priced'
      END) AS pricing_status,
      commitment.status AS commitment_status,
      commitment.release_reason
    FROM public.supply_requests request
    CROSS JOIN live_total live
    LEFT JOIN public.supply_request_commitments commitment
      ON commitment.supply_request_id = request.id
     AND commitment.organization_id = request.organization_id
    WHERE request.id = _request_id AND request.organization_id = _organization_id
  ),
  selected_budget AS (
    SELECT budget.*
    FROM public.organization_budgets budget
    WHERE budget.organization_id = _organization_id
      AND budget.active = true
      AND current_date BETWEEN budget.period_start AND budget.period_end
    ORDER BY budget.period_start DESC, budget.period_end DESC, budget.id
    LIMIT 1
  ),
  budget_values AS (
    SELECT
      budget.*,
      COALESCE((
        SELECT SUM(COALESCE(
          invoice.invoice_total,
          invoice.total_amount,
          invoice.total,
          (SELECT SUM(item.total_price) FROM public.invoice_items item
            WHERE item.invoice_id = invoice.id AND item.organization_id = invoice.organization_id),
          0
        ))
        FROM public.invoices invoice
        WHERE invoice.organization_id = budget.organization_id
          AND invoice.posted_at IS NOT NULL
          AND COALESCE(invoice.invoice_date, invoice.posted_at::date)
            BETWEEN budget.period_start AND budget.period_end
      ), 0)::numeric AS actual_spend,
      COALESCE((
        SELECT SUM(commitment.amount)
        FROM public.supply_request_commitments commitment
        WHERE commitment.organization_id = budget.organization_id
          AND commitment.status = 'active'
          AND commitment.committed_at::date BETWEEN budget.period_start AND budget.period_end
      ), 0)::numeric AS committed_spend
    FROM selected_budget budget
  )
  SELECT
    cost.id,
    cost.lifecycle_status,
    cost.amount,
    cost.pricing_status,
    cost.total_item_count,
    cost.priced_item_count,
    cost.commitment_status,
    cost.release_reason,
    budget.id,
    budget.name,
    budget.amount,
    budget.actual_spend,
    budget.committed_spend,
    CASE WHEN budget.id IS NULL THEN NULL
      ELSE budget.amount - budget.actual_spend - budget.committed_spend END,
    CASE
      WHEN budget.id IS NULL OR cost.pricing_status = 'unpriced' THEN NULL
      WHEN cost.commitment_status = 'active'
        THEN budget.amount - budget.actual_spend - budget.committed_spend
      WHEN cost.lifecycle_status IN ('submitted', 'under_review')
        THEN budget.amount - budget.actual_spend - budget.committed_spend - cost.amount
      ELSE NULL
    END
  FROM request_cost cost
  LEFT JOIN budget_values budget ON true;
END;
$$;

REVOKE ALL ON FUNCTION public.get_supply_request_budget_impact(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_supply_request_budget_impact(uuid, uuid) TO authenticated;

COMMIT;
