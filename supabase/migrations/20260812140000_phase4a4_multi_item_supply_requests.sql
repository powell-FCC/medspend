-- Phase 4A.4: additive multi-item supply requests. Parent lifecycle remains unchanged.

CREATE UNIQUE INDEX IF NOT EXISTS supply_requests_id_org_uq
  ON public.supply_requests (id, organization_id);

CREATE TABLE public.supply_request_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  supply_request_id uuid NOT NULL,
  product_id uuid,
  free_text_item text,
  quantity integer NOT NULL CHECK (quantity > 0),
  unit text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT supply_request_items_request_org_fk
    FOREIGN KEY (supply_request_id, organization_id)
    REFERENCES public.supply_requests(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT supply_request_items_product_org_fk
    FOREIGN KEY (product_id, organization_id)
    REFERENCES public.products(id, organization_id),
  CONSTRAINT supply_request_items_identity_check CHECK (
    (product_id IS NOT NULL AND free_text_item IS NULL)
    OR (product_id IS NULL AND nullif(btrim(free_text_item), '') IS NOT NULL)
  )
);

CREATE INDEX supply_request_items_request_idx
  ON public.supply_request_items (supply_request_id, created_at);
CREATE INDEX supply_request_items_org_product_idx
  ON public.supply_request_items (organization_id, product_id)
  WHERE product_id IS NOT NULL;
CREATE TRIGGER supply_request_items_updated_at
  BEFORE UPDATE ON public.supply_request_items
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

ALTER TABLE public.supply_request_items ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.supply_request_items TO authenticated;
GRANT ALL ON public.supply_request_items TO service_role;

CREATE POLICY supply_request_items_select_own_or_admin
  ON public.supply_request_items FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.supply_requests request
    WHERE request.id = supply_request_items.supply_request_id
      AND request.organization_id = supply_request_items.organization_id
      AND (request.requested_by = auth.uid()
        OR public.is_org_admin(request.organization_id, auth.uid()))
  ));

-- Backfill one child line for every historical parent that still carries legacy item data.
INSERT INTO public.supply_request_items (
  organization_id, supply_request_id, product_id, free_text_item, quantity, unit, created_at, updated_at
)
SELECT
  request.organization_id,
  request.id,
  request.product_id,
  CASE WHEN request.product_id IS NULL THEN request.free_text_item ELSE NULL END,
  request.quantity::integer,
  product.unit_of_measure,
  request.created_at,
  request.updated_at
FROM public.supply_requests request
LEFT JOIN public.products product
  ON product.id = request.product_id AND product.organization_id = request.organization_id
WHERE request.quantity IS NOT NULL
  AND request.quantity > 0
  AND request.quantity = trunc(request.quantity)
  AND (request.product_id IS NOT NULL OR nullif(btrim(request.free_text_item), '') IS NOT NULL)
  AND NOT EXISTS (
    SELECT 1 FROM public.supply_request_items item WHERE item.supply_request_id = request.id
  );

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
  _membership public.organization_memberships%ROWTYPE;
  _request_id uuid;
  _item jsonb;
  _product public.products%ROWTYPE;
  _product_id uuid;
  _free_text text;
  _quantity numeric;
  _unit text;
  _first_product_id uuid;
  _first_free_text text;
  _first_quantity integer;
BEGIN
  IF _uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO _membership FROM public.organization_memberships
  WHERE organization_id = _organization_id AND user_id = _uid AND active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'Not a member of this organization'; END IF;

  _team_id := coalesce(_team_id, _membership.default_team_id);
  _location_id := coalesce(_location_id, _membership.default_location_id);
  IF _team_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.teams WHERE id = _team_id AND organization_id = _organization_id AND active = true
  ) THEN RAISE EXCEPTION 'Select an available team for this request'; END IF;
  IF _location_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.locations WHERE id = _location_id AND organization_id = _organization_id AND active = true
  ) THEN RAISE EXCEPTION 'Select an available location for this request'; END IF;
  IF _items IS NULL OR jsonb_typeof(_items) <> 'array' OR jsonb_array_length(_items) = 0 THEN
    RAISE EXCEPTION 'Add at least one item to the request';
  END IF;

  INSERT INTO public.supply_requests (
    organization_id, requested_by, request_type, team_id, location_id, notes, status
  ) VALUES (
    _organization_id, _uid, _request_type, _team_id, _location_id,
    nullif(btrim(_notes), ''), 'submitted'
  ) RETURNING id INTO _request_id;

  FOR _item IN SELECT value FROM jsonb_array_elements(_items)
  LOOP
    _product_id := nullif(_item->>'productId', '')::uuid;
    _free_text := nullif(btrim(_item->>'freeTextItem'), '');
    BEGIN
      _quantity := (_item->>'quantity')::numeric;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'Each requested quantity must be a positive whole number';
    END;
    IF _quantity IS NULL OR _quantity <= 0 OR _quantity <> trunc(_quantity) THEN
      RAISE EXCEPTION 'Each requested quantity must be a positive whole number';
    END IF;
    IF (_product_id IS NULL) = (_free_text IS NULL) THEN
      RAISE EXCEPTION 'Each line must contain one catalog product or one custom item';
    END IF;

    _unit := NULL;
    IF _product_id IS NOT NULL THEN
      SELECT * INTO _product FROM public.products
      WHERE id = _product_id AND organization_id = _organization_id
        AND active = true AND staff_requestable = true;
      IF NOT FOUND THEN RAISE EXCEPTION 'A selected product is unavailable for this organization'; END IF;
      _unit := _product.unit_of_measure;
    END IF;

    INSERT INTO public.supply_request_items (
      organization_id, supply_request_id, product_id, free_text_item, quantity, unit
    ) VALUES (
      _organization_id, _request_id, _product_id, _free_text, _quantity::integer, _unit
    );

    IF _first_quantity IS NULL THEN
      _first_product_id := _product_id;
      _first_free_text := _free_text;
      _first_quantity := _quantity::integer;
    END IF;
  END LOOP;

  -- Populate legacy columns from the first line for safe compatibility with older clients.
  UPDATE public.supply_requests SET
    product_id = _first_product_id,
    free_text_item = _first_free_text,
    quantity = _first_quantity
  WHERE id = _request_id;

  RETURN _request_id;
END;
$$;

REVOKE ALL ON FUNCTION public.submit_supply_request(uuid, public.supply_request_type, uuid, uuid, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_supply_request(uuid, public.supply_request_type, uuid, uuid, text, jsonb) TO authenticated;
