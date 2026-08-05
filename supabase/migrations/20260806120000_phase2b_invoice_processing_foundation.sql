-- Phase 2B invoice processing foundation. No OCR or extraction is performed.

CREATE TABLE public.invoice_processing_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  invoice_id uuid NOT NULL UNIQUE REFERENCES public.vendor_invoices(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'uploaded'
    CHECK (status IN ('uploaded', 'processing', 'review_required', 'completed', 'failed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX invoice_processing_jobs_org_created_idx
  ON public.invoice_processing_jobs (organization_id, created_at DESC);
CREATE TRIGGER invoice_processing_jobs_updated_at
  BEFORE UPDATE ON public.invoice_processing_jobs
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

ALTER TABLE public.invoice_processing_jobs ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE ON public.invoice_processing_jobs TO authenticated;
GRANT ALL ON public.invoice_processing_jobs TO service_role;

CREATE POLICY invoice_processing_jobs_owner_select ON public.invoice_processing_jobs
  FOR SELECT TO authenticated
  USING (public.has_org_role(organization_id, auth.uid(), ARRAY['owner']::public.org_role[]));
CREATE POLICY invoice_processing_jobs_owner_insert ON public.invoice_processing_jobs
  FOR INSERT TO authenticated
  WITH CHECK (public.has_org_role(organization_id, auth.uid(), ARRAY['owner']::public.org_role[]));
CREATE POLICY invoice_processing_jobs_owner_update ON public.invoice_processing_jobs
  FOR UPDATE TO authenticated
  USING (public.has_org_role(organization_id, auth.uid(), ARRAY['owner']::public.org_role[]))
  WITH CHECK (public.has_org_role(organization_id, auth.uid(), ARRAY['owner']::public.org_role[]));

ALTER TABLE public.invoices
  ADD COLUMN vendor_name text,
  ADD COLUMN invoice_total numeric,
  ADD COLUMN source_file_id uuid UNIQUE REFERENCES public.vendor_invoices(id) ON DELETE SET NULL,
  ADD COLUMN processing_status text NOT NULL DEFAULT 'uploaded'
    CHECK (processing_status IN ('uploaded', 'processing', 'review_required', 'completed', 'failed'));

CREATE INDEX invoices_org_created_idx ON public.invoices (organization_id, created_at DESC);

CREATE TABLE public.invoice_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id uuid NOT NULL REFERENCES public.invoices(id) ON DELETE CASCADE,
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  sku text,
  description text NOT NULL,
  quantity numeric NOT NULL CHECK (quantity > 0),
  unit_price numeric CHECK (unit_price >= 0),
  total_price numeric CHECK (total_price >= 0),
  unit_of_measure text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX invoice_items_invoice_idx ON public.invoice_items (invoice_id);
CREATE INDEX invoice_items_org_idx ON public.invoice_items (organization_id);
ALTER TABLE public.invoice_items ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.invoice_items TO authenticated;
GRANT ALL ON public.invoice_items TO service_role;

CREATE POLICY invoice_items_owner_all ON public.invoice_items
  FOR ALL TO authenticated
  USING (public.has_org_role(organization_id, auth.uid(), ARRAY['owner']::public.org_role[]))
  WITH CHECK (public.has_org_role(organization_id, auth.uid(), ARRAY['owner']::public.org_role[]));

CREATE TABLE public.inventory_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  sku text,
  name text NOT NULL,
  description text,
  category text,
  unit_of_measure text,
  current_stock numeric NOT NULL DEFAULT 0 CHECK (current_stock >= 0),
  par_level numeric NOT NULL DEFAULT 0 CHECK (par_level >= 0),
  last_purchase_price numeric CHECK (last_purchase_price >= 0),
  last_purchase_date date,
  vendor_name text,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX inventory_items_org_active_idx ON public.inventory_items (organization_id, active);
CREATE INDEX inventory_items_org_category_idx ON public.inventory_items (organization_id, category);
CREATE INDEX inventory_items_search_idx ON public.inventory_items
  USING gin (to_tsvector('simple', coalesce(sku, '') || ' ' || name || ' ' || coalesce(description, '') || ' ' || coalesce(category, '') || ' ' || coalesce(vendor_name, '')));
CREATE UNIQUE INDEX inventory_items_org_vendor_sku_unique
  ON public.inventory_items (organization_id, lower(vendor_name), lower(sku))
  WHERE vendor_name IS NOT NULL AND sku IS NOT NULL;

ALTER TABLE public.inventory_items ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE ON public.inventory_items TO authenticated;
GRANT ALL ON public.inventory_items TO service_role;

CREATE POLICY inventory_items_owner_all ON public.inventory_items
  FOR ALL TO authenticated
  USING (public.has_org_role(organization_id, auth.uid(), ARRAY['owner']::public.org_role[]))
  WITH CHECK (public.has_org_role(organization_id, auth.uid(), ARRAY['owner']::public.org_role[]));

CREATE POLICY inventory_items_member_select ON public.inventory_items
  FOR SELECT TO authenticated
  USING (public.is_org_member(organization_id, auth.uid()));

CREATE OR REPLACE FUNCTION public.create_invoice_processing_job()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.invoice_processing_jobs (organization_id, invoice_id, status)
  VALUES (NEW.organization_id, NEW.id, 'uploaded')
  ON CONFLICT (invoice_id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE TRIGGER vendor_invoice_create_processing_job
  AFTER INSERT ON public.vendor_invoices
  FOR EACH ROW EXECUTE FUNCTION public.create_invoice_processing_job();

INSERT INTO public.invoice_processing_jobs (organization_id, invoice_id, status)
SELECT organization_id, id, 'uploaded'
FROM public.vendor_invoices
ON CONFLICT (invoice_id) DO NOTHING;
