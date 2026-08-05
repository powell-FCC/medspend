-- Phase 2D: manual invoice review and atomic inventory posting.
-- No OCR, AI extraction, parsing, destructive schema changes, or RLS changes.

ALTER TABLE public.invoice_items
  ADD COLUMN category text,
  ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();

CREATE TRIGGER invoice_items_updated_at BEFORE UPDATE ON public.invoice_items
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

-- One stock record per canonical product. All pre-consolidation rows have a null product_id.
CREATE UNIQUE INDEX inventory_items_org_product_uq
  ON public.inventory_items (organization_id, product_id)
  WHERE product_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.post_reviewed_invoice(
  _organization_id uuid,
  _source_file_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _invoice public.invoices%ROWTYPE;
  _line public.invoice_items%ROWTYPE;
  _vendor_id uuid;
  _vendor_name text;
  _product_id uuid;
  _vendor_product_id uuid;
  _inventory public.inventory_items%ROWTYPE;
  _category_id uuid;
  _previous numeric;
  _new numeric;
  _created integer := 0;
  _updated integer := 0;
  _line_count integer;
BEGIN
  IF NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;

  SELECT * INTO _invoice
  FROM public.invoices
  WHERE organization_id = _organization_id AND source_file_id = _source_file_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice review not found'; END IF;
  IF _invoice.posted_at IS NOT NULL OR _invoice.processing_status = 'completed' THEN
    RETURN jsonb_build_object('invoiceId', _invoice.id, 'createdInventoryItems', 0,
      'updatedInventoryItems', 0, 'alreadyCompleted', true);
  END IF;

  _vendor_id := _invoice.vendor_id;
  _vendor_name := nullif(btrim(_invoice.vendor_name), '');
  IF _vendor_id IS NOT NULL THEN
    SELECT name INTO _vendor_name FROM public.vendors
      WHERE id = _vendor_id AND organization_id = _organization_id AND active = true;
    IF NOT FOUND THEN RAISE EXCEPTION 'Selected vendor is unavailable'; END IF;
  ELSIF _vendor_name IS NOT NULL THEN
    SELECT id INTO _vendor_id FROM public.vendors
      WHERE organization_id = _organization_id
        AND normalized_name = public.normalize_catalog_text(_vendor_name) AND active = true
      LIMIT 1;
    IF _vendor_id IS NULL THEN
      INSERT INTO public.vendors (organization_id, name, normalized_name)
      VALUES (_organization_id, _vendor_name, public.normalize_catalog_text(_vendor_name))
      RETURNING id INTO _vendor_id;
    END IF;
  ELSE
    RAISE EXCEPTION 'Vendor is required before approval';
  END IF;

  SELECT count(*) INTO _line_count FROM public.invoice_items
    WHERE invoice_id = _invoice.id AND organization_id = _organization_id;
  IF _line_count = 0 THEN RAISE EXCEPTION 'Add at least one line item before approval'; END IF;

  FOR _line IN
    SELECT * FROM public.invoice_items
    WHERE invoice_id = _invoice.id AND organization_id = _organization_id
    ORDER BY line_number NULLS LAST, created_at
    FOR UPDATE
  LOOP
    _product_id := _line.product_id;
    _vendor_product_id := _line.vendor_product_id;
    _category_id := NULL;

    IF _vendor_product_id IS NOT NULL THEN
      SELECT product_id INTO _product_id FROM public.vendor_products
        WHERE id = _vendor_product_id AND organization_id = _organization_id
          AND vendor_id = _vendor_id AND active = true;
      IF NOT FOUND THEN RAISE EXCEPTION 'A selected vendor product is unavailable'; END IF;
    END IF;

    IF _product_id IS NULL AND nullif(btrim(_line.sku), '') IS NOT NULL THEN
      SELECT id, product_id INTO _vendor_product_id, _product_id
      FROM public.vendor_products
      WHERE organization_id = _organization_id AND vendor_id = _vendor_id
        AND lower(vendor_sku) = lower(btrim(_line.sku)) AND active = true
      LIMIT 1;
    END IF;

    IF _product_id IS NULL AND nullif(btrim(_line.sku), '') IS NOT NULL THEN
      SELECT * INTO _inventory FROM public.inventory_items
      WHERE organization_id = _organization_id AND lower(sku) = lower(btrim(_line.sku))
      ORDER BY active DESC, created_at LIMIT 1 FOR UPDATE;
      IF FOUND THEN _product_id := _inventory.product_id; END IF;
    ELSE
      _inventory := NULL;
    END IF;

    IF _product_id IS NULL THEN
      SELECT id INTO _product_id FROM public.products
      WHERE organization_id = _organization_id AND active = true
        AND normalized_name = public.normalize_catalog_text(_line.description)
      LIMIT 1;
    END IF;

    IF nullif(btrim(_line.category), '') IS NOT NULL THEN
      SELECT id INTO _category_id FROM public.product_categories
      WHERE organization_id = _organization_id AND active = true
        AND normalized_name = public.normalize_catalog_text(_line.category)
      LIMIT 1;
    END IF;

    IF _product_id IS NULL THEN
      INSERT INTO public.products
        (organization_id, name, normalized_name, description, category_id, manufacturer,
         preferred_vendor_id, vendor_item_number, unit, unit_of_measure, pack_size,
         approved, active, staff_requestable)
      VALUES
        (_organization_id, btrim(_line.description), public.normalize_catalog_text(_line.description),
         btrim(_line.description), _category_id, nullif(btrim(_line.manufacturer), ''),
         _vendor_id, nullif(btrim(_line.sku), ''), coalesce(nullif(btrim(_line.unit_of_measure), ''), 'each'),
         coalesce(nullif(btrim(_line.unit_of_measure), ''), 'each'), nullif(btrim(_line.package_size), ''),
         true, true, true)
      RETURNING id INTO _product_id;
    END IF;

    IF nullif(btrim(_line.sku), '') IS NOT NULL AND _vendor_product_id IS NULL THEN
      SELECT id INTO _vendor_product_id FROM public.vendor_products
      WHERE organization_id = _organization_id AND vendor_id = _vendor_id
        AND lower(vendor_sku) = lower(btrim(_line.sku)) AND active = true
      LIMIT 1;
      IF _vendor_product_id IS NULL THEN
        INSERT INTO public.vendor_products
          (organization_id, vendor_id, product_id, vendor_sku, manufacturer_sku,
           package_size, unit_of_measure)
        VALUES
          (_organization_id, _vendor_id, _product_id, btrim(_line.sku),
           NULL, nullif(btrim(_line.package_size), ''),
           nullif(btrim(_line.unit_of_measure), ''))
        RETURNING id INTO _vendor_product_id;
      END IF;
    END IF;

    IF _vendor_product_id IS NOT NULL THEN
      UPDATE public.vendor_products SET
        product_id = _product_id,
        package_size = coalesce(nullif(btrim(_line.package_size), ''), package_size),
        unit_of_measure = coalesce(nullif(btrim(_line.unit_of_measure), ''), unit_of_measure),
        active = true
      WHERE id = _vendor_product_id AND organization_id = _organization_id AND vendor_id = _vendor_id;
    END IF;

    IF _inventory.id IS NULL OR (_inventory.product_id IS NOT NULL AND _inventory.product_id IS DISTINCT FROM _product_id) THEN
      SELECT * INTO _inventory FROM public.inventory_items
      WHERE organization_id = _organization_id AND product_id = _product_id
      LIMIT 1 FOR UPDATE;
    END IF;

    IF _inventory.id IS NULL THEN
      INSERT INTO public.inventory_items
        (organization_id, product_id, sku, name, description, category, manufacturer,
         unit, quantity, vendor_name, last_purchase_price, last_purchase_date, active)
      VALUES
        (_organization_id, _product_id, nullif(btrim(_line.sku), ''), btrim(_line.description),
         btrim(_line.description), nullif(btrim(_line.category), ''),
         nullif(btrim(_line.manufacturer), ''), coalesce(nullif(btrim(_line.unit_of_measure), ''), 'each'),
         0, _vendor_name, _line.unit_price, coalesce(_invoice.invoice_date, current_date), true)
      RETURNING * INTO _inventory;
      _created := _created + 1;
    ELSE
      IF _inventory.product_id IS NULL THEN
        UPDATE public.inventory_items SET product_id = _product_id WHERE id = _inventory.id;
      END IF;
      _updated := _updated + 1;
    END IF;

    _previous := _inventory.quantity;
    _new := _previous + _line.quantity;
    UPDATE public.inventory_items SET
      quantity = _new,
      sku = coalesce(nullif(btrim(_line.sku), ''), sku),
      category = coalesce(nullif(btrim(_line.category), ''), category),
      manufacturer = coalesce(nullif(btrim(_line.manufacturer), ''), manufacturer),
      vendor_name = _vendor_name,
      last_purchase_price = coalesce(_line.unit_price, last_purchase_price),
      last_purchase_date = coalesce(_invoice.invoice_date, current_date),
      active = true
    WHERE id = _inventory.id;

    INSERT INTO public.inventory_adjustments
      (organization_id, inventory_item_id, adjustment_amount, previous_quantity, new_quantity,
       reason, created_by, source_type, source_invoice_id, source_invoice_item_id, idempotency_key)
    VALUES
      (_organization_id, _inventory.id, _line.quantity, _previous, _new,
       'Invoice received', auth.uid(), 'invoice', _invoice.id, _line.id, 'invoice-item:' || _line.id::text);

    INSERT INTO public.inventory_price_history
      (organization_id, product_id, vendor_id, vendor_product_id, invoice_id, invoice_item_id,
       purchase_date, quantity, package_size, unit_of_measure, unit_price, extended_price)
    VALUES
      (_organization_id, _product_id, _vendor_id, _vendor_product_id, _invoice.id, _line.id,
       coalesce(_invoice.invoice_date, current_date), _line.quantity, nullif(btrim(_line.package_size), ''),
       nullif(btrim(_line.unit_of_measure), ''), _line.unit_price, _line.total_price);

    UPDATE public.invoice_items SET product_id = _product_id,
      vendor_product_id = _vendor_product_id, review_status = 'approved'
    WHERE id = _line.id;
  END LOOP;

  UPDATE public.invoices SET vendor_id = _vendor_id, vendor_name = _vendor_name,
    invoice_total = coalesce(invoice_total, total_amount, total),
    total_amount = coalesce(total_amount, invoice_total, total),
    total = coalesce(total, total_amount, invoice_total),
    processing_status = 'completed', reviewed_by = auth.uid(), reviewed_at = now(), posted_at = now()
  WHERE id = _invoice.id;

  UPDATE public.invoice_processing_jobs SET status = 'completed'
  WHERE invoice_id = _source_file_id AND organization_id = _organization_id;

  RETURN jsonb_build_object('invoiceId', _invoice.id, 'createdInventoryItems', _created,
    'updatedInventoryItems', _updated, 'alreadyCompleted', false);
END;
$$;

REVOKE ALL ON FUNCTION public.post_reviewed_invoice(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.post_reviewed_invoice(uuid, uuid) TO authenticated;
