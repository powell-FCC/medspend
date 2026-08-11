-- Phase 3A.4.1: rematch unresolved invoice lines whenever vendor identity changes.
CREATE OR REPLACE FUNCTION public.rematch_invoice_vendor_products(
  _organization_id uuid,
  _source_file_id uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _invoice public.invoices%ROWTYPE;
  _matched integer := 0;
BEGIN
  IF NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;

  SELECT * INTO _invoice FROM public.invoices
    WHERE organization_id = _organization_id AND source_file_id = _source_file_id
    FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice review not found'; END IF;
  IF _invoice.posted_at IS NOT NULL OR _invoice.processing_status = 'completed' THEN
    RAISE EXCEPTION 'Completed invoices cannot be changed';
  END IF;

  -- A vendor_product_id records vendor-context provenance. Clear only links whose
  -- remembered mapping is no longer safe; manually confirmed product-only links remain intact.
  UPDATE public.invoice_items AS item
    SET product_id = NULL, vendor_product_id = NULL, review_status = 'pending_review'
  FROM public.vendor_products AS mapping
  WHERE item.organization_id = _organization_id
    AND item.invoice_id = _invoice.id
    AND item.vendor_product_id = mapping.id
    AND (
      _invoice.vendor_id IS NULL
      OR mapping.organization_id <> _organization_id
      OR mapping.vendor_id <> _invoice.vendor_id
      OR mapping.active = false
    );

  IF _invoice.vendor_id IS NULL THEN RETURN 0; END IF;

  UPDATE public.invoice_items AS item
    SET product_id = mapping.product_id,
        vendor_product_id = mapping.id,
        review_status = 'pending_review'
  FROM public.vendor_products AS mapping
  JOIN public.products AS product
    ON product.id = mapping.product_id
   AND product.organization_id = _organization_id
   AND product.active = true
  WHERE item.organization_id = _organization_id
    AND item.invoice_id = _invoice.id
    AND item.product_id IS NULL
    AND nullif(btrim(item.sku), '') IS NOT NULL
    AND mapping.organization_id = _organization_id
    AND mapping.vendor_id = _invoice.vendor_id
    AND mapping.active = true
    AND lower(btrim(mapping.vendor_sku)) = lower(btrim(item.sku));

  GET DIAGNOSTICS _matched = ROW_COUNT;
  RETURN _matched;
END;
$$;

REVOKE ALL ON FUNCTION public.rematch_invoice_vendor_products(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rematch_invoice_vendor_products(uuid, uuid) TO authenticated;
