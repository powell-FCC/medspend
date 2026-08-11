-- Phase 3A.5: semantic document identity and organization-scoped remembered vendor signatures.
ALTER TABLE public.invoices
  ADD COLUMN document_type text NOT NULL DEFAULT 'UNKNOWN'
    CHECK (document_type IN ('INVOICE','ORDER_CONFIRMATION','PURCHASE_ORDER','CREDIT_MEMO','STATEMENT','UNKNOWN')),
  ADD COLUMN order_number text,
  ADD COLUMN order_date date,
  ADD COLUMN vendor_identity_reviewed boolean NOT NULL DEFAULT false;

CREATE TABLE public.vendor_identity_signatures (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  vendor_id uuid NOT NULL,
  signature_type text NOT NULL CHECK (signature_type IN ('SELLER_NAME','EMAIL_DOMAIN','WEB_DOMAIN','PHONE','DOCUMENT_PHRASE')),
  normalized_value text NOT NULL CHECK (btrim(normalized_value) <> ''),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vendor_identity_signatures_vendor_org_fk FOREIGN KEY (vendor_id, organization_id)
    REFERENCES public.vendors(id, organization_id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX vendor_identity_signatures_active_value_uq
  ON public.vendor_identity_signatures (organization_id, signature_type, normalized_value) WHERE active;
CREATE INDEX vendor_identity_signatures_vendor_idx
  ON public.vendor_identity_signatures (organization_id, vendor_id) WHERE active;
CREATE TRIGGER vendor_identity_signatures_updated_at BEFORE UPDATE ON public.vendor_identity_signatures
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();
ALTER TABLE public.vendor_identity_signatures ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.vendor_identity_signatures TO authenticated;
GRANT ALL ON public.vendor_identity_signatures TO service_role;
CREATE POLICY vendor_identity_signatures_owner_all ON public.vendor_identity_signatures
  FOR ALL TO authenticated
  USING (public.has_org_role(organization_id, auth.uid(), ARRAY['owner']::public.org_role[]))
  WITH CHECK (public.has_org_role(organization_id, auth.uid(), ARRAY['owner']::public.org_role[]));

CREATE OR REPLACE FUNCTION public.persist_invoice_document_identity(
  _organization_id uuid, _source_file_id uuid, _document_type text, _order_number text, _order_date date
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;
  IF _document_type NOT IN ('INVOICE','ORDER_CONFIRMATION','PURCHASE_ORDER','CREDIT_MEMO','STATEMENT','UNKNOWN') THEN
    RAISE EXCEPTION 'Invalid document type';
  END IF;
  UPDATE public.invoices SET
    document_type = CASE WHEN document_type = 'UNKNOWN' THEN _document_type ELSE document_type END,
    order_number = COALESCE(order_number, NULLIF(btrim(_order_number), '')),
    order_date = COALESCE(order_date, _order_date)
  WHERE organization_id = _organization_id AND source_file_id = _source_file_id
    AND processing_status <> 'completed' AND posted_at IS NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.remember_invoice_vendor_signatures(
  _organization_id uuid, _source_file_id uuid, _vendor_id uuid, _evidence jsonb
)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _invoice public.invoices%ROWTYPE; _item jsonb; _existing uuid; _count integer := 0; _type text; _value text; _confidence numeric;
BEGIN
  IF NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;
  SELECT * INTO _invoice FROM public.invoices WHERE organization_id = _organization_id AND source_file_id = _source_file_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice review not found'; END IF;
  IF _invoice.processing_status = 'completed' OR _invoice.posted_at IS NOT NULL THEN RAISE EXCEPTION 'Completed invoices cannot be changed'; END IF;
  PERFORM 1 FROM public.vendors WHERE id = _vendor_id AND organization_id = _organization_id AND active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'Selected vendor is unavailable'; END IF;
  FOR _item IN SELECT value FROM jsonb_array_elements(COALESCE(_evidence, '[]'::jsonb)) LOOP
    _type := _item->>'type'; _value := btrim(_item->>'normalizedValue'); _confidence := COALESCE((_item->>'confidence')::numeric, 0);
    IF _type NOT IN ('SELLER_NAME','EMAIL_DOMAIN','WEB_DOMAIN','PHONE','DOCUMENT_PHRASE') OR _value = '' THEN CONTINUE; END IF;
    IF (_type IN ('EMAIL_DOMAIN','WEB_DOMAIN') AND _confidence < 90)
      OR (_type = 'SELLER_NAME' AND _confidence < 90)
      OR (_type = 'PHONE' AND _confidence < 95)
      OR (_type = 'DOCUMENT_PHRASE' AND _confidence < 85) THEN CONTINUE; END IF;
    SELECT id INTO _existing FROM public.vendor_identity_signatures
      WHERE organization_id = _organization_id AND signature_type = _type AND normalized_value = _value
      ORDER BY active DESC, created_at LIMIT 1 FOR UPDATE;
    IF _existing IS NULL THEN
      INSERT INTO public.vendor_identity_signatures (organization_id, vendor_id, signature_type, normalized_value)
      VALUES (_organization_id, _vendor_id, _type, _value);
    ELSE
      UPDATE public.vendor_identity_signatures SET vendor_id = _vendor_id, active = true WHERE id = _existing;
    END IF;
    _count := _count + 1;
  END LOOP;
  RETURN _count;
END;
$$;

CREATE OR REPLACE FUNCTION public.forget_invoice_vendor_signatures(
  _organization_id uuid, _source_file_id uuid
)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _invoice public.invoices%ROWTYPE; _evidence jsonb; _count integer := 0;
BEGIN
  IF NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;
  SELECT * INTO _invoice FROM public.invoices
    WHERE organization_id = _organization_id AND source_file_id = _source_file_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice review not found'; END IF;
  IF _invoice.processing_status = 'completed' OR _invoice.posted_at IS NOT NULL THEN RAISE EXCEPTION 'Completed invoices cannot be changed'; END IF;
  SELECT extraction_result->'vendorEvidence' INTO _evidence FROM public.invoice_processing_jobs
    WHERE organization_id = _organization_id AND invoice_id = _source_file_id FOR UPDATE;
  UPDATE public.vendor_identity_signatures AS signature SET active = false
  WHERE signature.organization_id = _organization_id AND signature.active = true
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(_evidence, '[]'::jsonb)) item
      WHERE item->>'type' = signature.signature_type AND item->>'normalizedValue' = signature.normalized_value);
  GET DIAGNOSTICS _count = ROW_COUNT;
  RETURN _count;
END;
$$;

REVOKE ALL ON FUNCTION public.persist_invoice_document_identity(uuid, uuid, text, text, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.remember_invoice_vendor_signatures(uuid, uuid, uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.forget_invoice_vendor_signatures(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.persist_invoice_document_identity(uuid, uuid, text, text, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remember_invoice_vendor_signatures(uuid, uuid, uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forget_invoice_vendor_signatures(uuid, uuid) TO authenticated;
