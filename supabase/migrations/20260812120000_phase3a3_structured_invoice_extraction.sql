-- Phase 3A.3: atomically persist a canonical extraction and seed only a pristine review draft.
CREATE OR REPLACE FUNCTION public.seed_structured_invoice_draft(
  _organization_id uuid,
  _source_file_id uuid,
  _extraction jsonb,
  _provider text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _job public.invoice_processing_jobs%ROWTYPE;
  _invoice public.invoices%ROWTYPE;
  _item jsonb;
  _line integer := 0;
  _pristine boolean;
BEGIN
  IF NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;

  SELECT * INTO _job FROM public.invoice_processing_jobs
  WHERE invoice_id = _source_file_id AND organization_id = _organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice processing job not found'; END IF;
  IF _job.extraction_result IS NOT NULL THEN RETURN false; END IF;

  SELECT * INTO _invoice FROM public.invoices
  WHERE source_file_id = _source_file_id AND organization_id = _organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice review draft not found'; END IF;
  IF _invoice.processing_status = 'completed' OR _invoice.posted_at IS NOT NULL THEN RETURN false; END IF;

  _pristine := _invoice.vendor_name IS NULL
    AND _invoice.invoice_number IS NULL
    AND _invoice.invoice_date IS NULL
    AND _invoice.purchase_order_number IS NULL
    AND _invoice.subtotal IS NULL
    AND _invoice.tax_amount IS NULL
    AND _invoice.shipping_amount IS NULL
    AND _invoice.invoice_total IS NULL
    AND NOT EXISTS (SELECT 1 FROM public.invoice_items WHERE invoice_id = _invoice.id);

  UPDATE public.invoice_processing_jobs SET
    extraction_result = _extraction, extraction_provider = _provider,
    extraction_error = NULL, status = 'review_required'
  WHERE id = _job.id;

  IF NOT _pristine THEN RETURN false; END IF;

  UPDATE public.invoices SET
    vendor_name = NULLIF(_extraction #>> '{header,vendor,value}', ''),
    invoice_number = NULLIF(_extraction #>> '{header,invoiceNumber,value}', ''),
    invoice_date = NULLIF(_extraction #>> '{header,invoiceDate,value}', '')::date,
    purchase_order_number = NULLIF(_extraction #>> '{header,purchaseOrder,value}', ''),
    subtotal = NULLIF(_extraction #>> '{header,subtotal,value}', '')::numeric,
    tax_amount = NULLIF(_extraction #>> '{header,tax,value}', '')::numeric,
    shipping_amount = NULLIF(_extraction #>> '{header,shipping,value}', '')::numeric,
    invoice_total = NULLIF(_extraction #>> '{header,total,value}', '')::numeric,
    total_amount = NULLIF(_extraction #>> '{header,total,value}', '')::numeric,
    total = NULLIF(_extraction #>> '{header,total,value}', '')::numeric,
    processing_status = 'review_required'
  WHERE id = _invoice.id;

  FOR _item IN SELECT value FROM jsonb_array_elements(COALESCE(_extraction->'items', '[]'::jsonb)) LOOP
    _line := _line + 1;
    INSERT INTO public.invoice_items (
      invoice_id, organization_id, line_number, sku, description, manufacturer, category,
      quantity, unit_of_measure, unit_price, total_price, review_status
    ) VALUES (
      _invoice.id, _organization_id, _line,
      NULLIF(_item #>> '{sku,value}', ''), _item #>> '{description,value}',
      NULLIF(_item #>> '{manufacturer,value}', ''), NULLIF(_item #>> '{suggestedCategory,value}', ''),
      (_item #>> '{quantity,value}')::numeric, COALESCE(NULLIF(_item #>> '{unit,value}', ''), 'each'),
      (_item #>> '{unitPrice,value}')::numeric, (_item #>> '{lineTotal,value}')::numeric, 'pending_review'
    );
  END LOOP;
  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.seed_structured_invoice_draft(uuid, uuid, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.seed_structured_invoice_draft(uuid, uuid, jsonb, text) TO authenticated;
