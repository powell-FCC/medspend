-- Phase 2C inventory management core. No extraction or purchasing automation.

ALTER TABLE public.inventory_items RENAME COLUMN current_stock TO quantity;
ALTER TABLE public.inventory_items RENAME COLUMN unit_of_measure TO unit;
UPDATE public.inventory_items SET unit = 'each' WHERE unit IS NULL OR btrim(unit) = '';
ALTER TABLE public.inventory_items
  ADD COLUMN manufacturer text,
  ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE public.inventory_items ALTER COLUMN unit SET NOT NULL;
ALTER TABLE public.inventory_items ALTER COLUMN par_level DROP NOT NULL;
ALTER TABLE public.inventory_items ALTER COLUMN par_level DROP DEFAULT;
CREATE TRIGGER inventory_items_updated_at BEFORE UPDATE ON public.inventory_items
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

DROP POLICY inventory_items_member_select ON public.inventory_items;
CREATE POLICY inventory_items_member_select ON public.inventory_items FOR SELECT TO authenticated
  USING (active = true AND public.is_org_member(organization_id, auth.uid()));

CREATE TABLE public.inventory_categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name text NOT NULL CHECK (btrim(name) <> ''),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, name)
);
ALTER TABLE public.inventory_categories ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.inventory_categories TO authenticated;
GRANT ALL ON public.inventory_categories TO service_role;
CREATE POLICY inventory_categories_member_select ON public.inventory_categories FOR SELECT TO authenticated
  USING (public.is_org_member(organization_id, auth.uid()));
CREATE POLICY inventory_categories_owner_write ON public.inventory_categories FOR ALL TO authenticated
  USING (public.has_org_role(organization_id, auth.uid(), ARRAY['owner']::public.org_role[]))
  WITH CHECK (public.has_org_role(organization_id, auth.uid(), ARRAY['owner']::public.org_role[]));

CREATE TABLE public.inventory_adjustments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  inventory_item_id uuid NOT NULL REFERENCES public.inventory_items(id) ON DELETE CASCADE,
  adjustment_amount numeric NOT NULL,
  previous_quantity numeric NOT NULL,
  new_quantity numeric NOT NULL CHECK (new_quantity >= 0),
  reason text NOT NULL CHECK (reason IN ('Invoice received', 'Manual adjustment', 'Damaged', 'Expired', 'Correction')),
  created_by uuid NOT NULL REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (new_quantity = previous_quantity + adjustment_amount)
);
CREATE INDEX inventory_adjustments_item_created_idx ON public.inventory_adjustments (inventory_item_id, created_at DESC);
CREATE INDEX inventory_adjustments_org_created_idx ON public.inventory_adjustments (organization_id, created_at DESC);
ALTER TABLE public.inventory_adjustments ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT ON public.inventory_adjustments TO authenticated;
GRANT ALL ON public.inventory_adjustments TO service_role;
CREATE POLICY inventory_adjustments_owner_select ON public.inventory_adjustments FOR SELECT TO authenticated
  USING (public.has_org_role(organization_id, auth.uid(), ARRAY['owner']::public.org_role[]));
CREATE POLICY inventory_adjustments_owner_insert ON public.inventory_adjustments FOR INSERT TO authenticated
  WITH CHECK (
    created_by = auth.uid()
    AND public.has_org_role(organization_id, auth.uid(), ARRAY['owner']::public.org_role[])
  );

CREATE OR REPLACE FUNCTION public.adjust_inventory_quantity(
  _organization_id uuid,
  _inventory_item_id uuid,
  _adjustment_amount numeric,
  _reason text
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _previous numeric;
  _new numeric;
BEGIN
  IF NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;
  IF _reason NOT IN ('Invoice received', 'Manual adjustment', 'Damaged', 'Expired', 'Correction') THEN
    RAISE EXCEPTION 'Invalid adjustment reason';
  END IF;
  SELECT quantity INTO _previous FROM public.inventory_items
    WHERE id = _inventory_item_id AND organization_id = _organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Inventory item not found'; END IF;
  _new := _previous + _adjustment_amount;
  IF _new < 0 THEN RAISE EXCEPTION 'Quantity cannot be negative'; END IF;
  UPDATE public.inventory_items SET quantity = _new WHERE id = _inventory_item_id;
  INSERT INTO public.inventory_adjustments
    (organization_id, inventory_item_id, adjustment_amount, previous_quantity, new_quantity, reason, created_by)
  VALUES (_organization_id, _inventory_item_id, _adjustment_amount, _previous, _new, _reason, auth.uid());
  RETURN _new;
END;
$$;
GRANT EXECUTE ON FUNCTION public.adjust_inventory_quantity(uuid, uuid, numeric, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.receive_invoice_inventory_item(
  _organization_id uuid,
  _sku text,
  _name text,
  _vendor_name text,
  _quantity numeric,
  _unit text,
  _category text,
  _unit_price numeric
)
RETURNS TABLE (inventory_item_id uuid, created boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _item public.inventory_items%ROWTYPE;
BEGIN
  IF NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;
  IF _quantity <= 0 THEN RAISE EXCEPTION 'Received quantity must be positive'; END IF;

  SELECT * INTO _item FROM public.inventory_items
  WHERE organization_id = _organization_id AND active = true AND (
    (nullif(btrim(_sku), '') IS NOT NULL AND lower(sku) = lower(btrim(_sku)))
    OR (lower(coalesce(vendor_name, '')) = lower(coalesce(btrim(_vendor_name), '')) AND lower(name) = lower(btrim(_name)))
    OR lower(regexp_replace(name, '[^a-z0-9]+', '', 'g')) = lower(regexp_replace(btrim(_name), '[^a-z0-9]+', '', 'g'))
  )
  ORDER BY
    CASE WHEN nullif(btrim(_sku), '') IS NOT NULL AND lower(sku) = lower(btrim(_sku)) THEN 1
         WHEN lower(coalesce(vendor_name, '')) = lower(coalesce(btrim(_vendor_name), '')) AND lower(name) = lower(btrim(_name)) THEN 2
         ELSE 3 END
  LIMIT 1 FOR UPDATE;

  IF FOUND THEN
    PERFORM public.adjust_inventory_quantity(_organization_id, _item.id, _quantity, 'Invoice received');
    RETURN QUERY SELECT _item.id, false;
  ELSE
    INSERT INTO public.inventory_items
      (organization_id, sku, name, vendor_name, quantity, unit, category, last_purchase_price, active)
    VALUES (_organization_id, nullif(btrim(_sku), ''), btrim(_name), nullif(btrim(_vendor_name), ''),
      _quantity, btrim(_unit), nullif(btrim(_category), ''), _unit_price, true)
    RETURNING * INTO _item;
    INSERT INTO public.inventory_adjustments
      (organization_id, inventory_item_id, adjustment_amount, previous_quantity, new_quantity, reason, created_by)
    VALUES (_organization_id, _item.id, _quantity, 0, _quantity, 'Invoice received', auth.uid());
    RETURN QUERY SELECT _item.id, true;
  END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION public.receive_invoice_inventory_item(uuid, text, text, text, numeric, text, text, numeric) TO authenticated;

INSERT INTO public.inventory_categories (organization_id, name)
SELECT organization.id, category.name
FROM public.organizations organization
CROSS JOIN (VALUES ('PPE'), ('Syringes'), ('Needles'), ('Dressings'), ('Medication Supplies'), ('Equipment'), ('Other')) category(name)
ON CONFLICT (organization_id, name) DO NOTHING;
