-- Phase 3A.4: explicit owner-controlled product identity decisions. Posting remains unchanged.
CREATE OR REPLACE FUNCTION public.confirm_invoice_item_product(
  _organization_id uuid,
  _source_file_id uuid,
  _invoice_item_id uuid,
  _product_id uuid,
  _remember_vendor_sku boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _invoice public.invoices%ROWTYPE;
  _line public.invoice_items%ROWTYPE;
  _vendor_product_id uuid;
BEGIN
  IF NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;
  SELECT * INTO _invoice FROM public.invoices
    WHERE organization_id = _organization_id AND source_file_id = _source_file_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice review not found'; END IF;
  IF _invoice.posted_at IS NOT NULL OR _invoice.processing_status = 'completed' THEN
    RAISE EXCEPTION 'Completed invoices cannot be changed';
  END IF;
  PERFORM 1 FROM public.products
    WHERE id = _product_id AND organization_id = _organization_id AND active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'Selected product is unavailable'; END IF;
  SELECT * INTO _line FROM public.invoice_items
    WHERE id = _invoice_item_id AND invoice_id = _invoice.id AND organization_id = _organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice line not found'; END IF;

  IF _remember_vendor_sku AND nullif(btrim(_line.sku), '') IS NOT NULL THEN
    IF _invoice.vendor_id IS NULL THEN RAISE EXCEPTION 'Select an existing vendor before remembering a vendor SKU'; END IF;
    SELECT id INTO _vendor_product_id FROM public.vendor_products
      WHERE organization_id = _organization_id AND vendor_id = _invoice.vendor_id
        AND lower(btrim(vendor_sku)) = lower(btrim(_line.sku))
      ORDER BY active DESC, created_at LIMIT 1 FOR UPDATE;
    IF _vendor_product_id IS NULL THEN
      INSERT INTO public.vendor_products
        (organization_id, vendor_id, product_id, vendor_sku, package_size, unit_of_measure)
      VALUES
        (_organization_id, _invoice.vendor_id, _product_id, btrim(_line.sku),
         nullif(btrim(_line.package_size), ''), nullif(btrim(_line.unit_of_measure), ''))
      RETURNING id INTO _vendor_product_id;
    ELSE
      UPDATE public.vendor_products SET product_id = _product_id,
        package_size = coalesce(nullif(btrim(_line.package_size), ''), package_size),
        unit_of_measure = coalesce(nullif(btrim(_line.unit_of_measure), ''), unit_of_measure), active = true
      WHERE id = _vendor_product_id;
    END IF;
  END IF;
  UPDATE public.invoice_items SET product_id = _product_id,
    vendor_product_id = _vendor_product_id, review_status = 'pending_review'
  WHERE id = _line.id;
  RETURN jsonb_build_object('productId', _product_id, 'vendorProductId', _vendor_product_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.unlink_invoice_item_product(
  _organization_id uuid,
  _source_file_id uuid,
  _invoice_item_id uuid,
  _forget_mapping boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _invoice public.invoices%ROWTYPE;
  _line public.invoice_items%ROWTYPE;
BEGIN
  IF NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;
  SELECT * INTO _invoice FROM public.invoices
    WHERE organization_id = _organization_id AND source_file_id = _source_file_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice review not found'; END IF;
  IF _invoice.posted_at IS NOT NULL OR _invoice.processing_status = 'completed' THEN
    RAISE EXCEPTION 'Completed invoices cannot be changed';
  END IF;
  SELECT * INTO _line FROM public.invoice_items
    WHERE id = _invoice_item_id AND invoice_id = _invoice.id AND organization_id = _organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice line not found'; END IF;
  IF _forget_mapping AND _line.vendor_product_id IS NOT NULL THEN
    UPDATE public.vendor_products SET active = false
      WHERE id = _line.vendor_product_id AND organization_id = _organization_id;
  END IF;
  UPDATE public.invoice_items SET product_id = NULL, vendor_product_id = NULL,
    review_status = 'pending_review' WHERE id = _line.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_product_from_invoice_item(
  _organization_id uuid,
  _source_file_id uuid,
  _invoice_item_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _invoice public.invoices%ROWTYPE;
  _line public.invoice_items%ROWTYPE;
  _product_id uuid;
  _vendor_product_id uuid;
  _category_id uuid;
BEGIN
  IF NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;
  SELECT * INTO _invoice FROM public.invoices
    WHERE organization_id = _organization_id AND source_file_id = _source_file_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice review not found'; END IF;
  IF _invoice.posted_at IS NOT NULL OR _invoice.processing_status = 'completed' THEN
    RAISE EXCEPTION 'Completed invoices cannot be changed';
  END IF;
  IF _invoice.vendor_id IS NULL THEN RAISE EXCEPTION 'Select an existing vendor before creating a product'; END IF;
  SELECT * INTO _line FROM public.invoice_items
    WHERE id = _invoice_item_id AND invoice_id = _invoice.id AND organization_id = _organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice line not found'; END IF;
  IF _line.product_id IS NOT NULL THEN
    RETURN jsonb_build_object('productId', _line.product_id, 'vendorProductId', _line.vendor_product_id);
  END IF;
  IF nullif(btrim(_line.category), '') IS NOT NULL THEN
    SELECT id INTO _category_id FROM public.product_categories
      WHERE organization_id = _organization_id AND active = true
        AND normalized_name = public.normalize_catalog_text(_line.category) LIMIT 1;
  END IF;
  INSERT INTO public.products
    (organization_id, name, description, category_id, manufacturer, preferred_vendor_id,
     unit, unit_of_measure, pack_size, approved, active, staff_requestable)
  VALUES
    (_organization_id, btrim(_line.description), btrim(_line.description), _category_id,
     nullif(btrim(_line.manufacturer), ''), _invoice.vendor_id,
     coalesce(nullif(btrim(_line.unit_of_measure), ''), 'each'),
     coalesce(nullif(btrim(_line.unit_of_measure), ''), 'each'),
     nullif(btrim(_line.package_size), ''), true, true, true)
  RETURNING id INTO _product_id;
  IF nullif(btrim(_line.sku), '') IS NOT NULL THEN
    INSERT INTO public.vendor_products
      (organization_id, vendor_id, product_id, vendor_sku, package_size, unit_of_measure)
    VALUES
      (_organization_id, _invoice.vendor_id, _product_id, btrim(_line.sku),
       nullif(btrim(_line.package_size), ''), nullif(btrim(_line.unit_of_measure), ''))
    ON CONFLICT DO NOTHING RETURNING id INTO _vendor_product_id;
    IF _vendor_product_id IS NULL THEN
      RAISE EXCEPTION 'This vendor SKU already maps to another product; choose or correct that match instead';
    END IF;
  END IF;
  UPDATE public.invoice_items SET product_id = _product_id,
    vendor_product_id = _vendor_product_id, review_status = 'pending_review'
  WHERE id = _line.id;
  RETURN jsonb_build_object('productId', _product_id, 'vendorProductId', _vendor_product_id);
END;
$$;

REVOKE ALL ON FUNCTION public.confirm_invoice_item_product(uuid, uuid, uuid, uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.unlink_invoice_item_product(uuid, uuid, uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_product_from_invoice_item(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.confirm_invoice_item_product(uuid, uuid, uuid, uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.unlink_invoice_item_product(uuid, uuid, uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_product_from_invoice_item(uuid, uuid, uuid) TO authenticated;
