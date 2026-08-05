-- Phase 2C.5, Migration 1: additive data-model expansion only.
-- No OCR, extraction worker, application cutover, backfill, or destructive change.

-- Canonical product relationship for stock records. Existing identity columns remain intact.
ALTER TABLE public.inventory_items ADD COLUMN product_id uuid;
ALTER TABLE public.inventory_items ADD CONSTRAINT inventory_items_product_org_fk
  FOREIGN KEY (product_id, organization_id)
  REFERENCES public.products(id, organization_id) NOT VALID;
CREATE INDEX inventory_items_org_product_idx
  ON public.inventory_items (organization_id, product_id) WHERE product_id IS NOT NULL;

-- Composite keys support organization-consistent references without changing primary keys.
CREATE UNIQUE INDEX vendor_invoices_id_org_uq ON public.vendor_invoices (id, organization_id);
CREATE UNIQUE INDEX invoice_processing_jobs_id_org_uq ON public.invoice_processing_jobs (id, organization_id);
CREATE UNIQUE INDEX invoices_id_org_uq ON public.invoices (id, organization_id);
CREATE UNIQUE INDEX invoice_items_id_org_uq ON public.invoice_items (id, organization_id);

-- Canonical vendor-specific product identifiers.
CREATE TABLE public.vendor_products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  vendor_id uuid NOT NULL,
  product_id uuid NOT NULL,
  vendor_sku text NOT NULL CHECK (btrim(vendor_sku) <> ''),
  manufacturer_sku text,
  package_size text,
  unit_of_measure text,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vendor_products_vendor_org_fk FOREIGN KEY (vendor_id, organization_id)
    REFERENCES public.vendors(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT vendor_products_product_org_fk FOREIGN KEY (product_id, organization_id)
    REFERENCES public.products(id, organization_id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX vendor_products_id_org_uq ON public.vendor_products (id, organization_id);
CREATE UNIQUE INDEX vendor_products_active_vendor_sku_uq
  ON public.vendor_products (organization_id, vendor_id, lower(btrim(vendor_sku))) WHERE active;
CREATE INDEX vendor_products_org_product_idx ON public.vendor_products (organization_id, product_id);
CREATE TRIGGER vendor_products_updated_at BEFORE UPDATE ON public.vendor_products
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();
ALTER TABLE public.vendor_products ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.vendor_products TO authenticated;
GRANT ALL ON public.vendor_products TO service_role;
CREATE POLICY vendor_products_admin_all ON public.vendor_products FOR ALL TO authenticated
  USING (public.is_org_admin(organization_id, auth.uid()))
  WITH CHECK (public.is_org_admin(organization_id, auth.uid()));

-- Canonical invoice header preparation. Existing vendor_id, invoice_number, invoice_date,
-- total, invoice_total, and vendor_name columns are deliberately preserved.
ALTER TABLE public.invoices
  ADD COLUMN purchase_order_number text,
  ADD COLUMN subtotal numeric CHECK (subtotal >= 0),
  ADD COLUMN tax_amount numeric CHECK (tax_amount >= 0),
  ADD COLUMN shipping_amount numeric CHECK (shipping_amount >= 0),
  ADD COLUMN total_amount numeric CHECK (total_amount >= 0),
  ADD COLUMN currency_code text CHECK (currency_code IS NULL OR currency_code ~ '^[A-Z]{3}$'),
  ADD COLUMN payment_terms text,
  ADD COLUMN reviewed_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN reviewed_at timestamptz,
  ADD COLUMN posted_at timestamptz;

-- Canonical invoice line preparation. Existing sku and unit_of_measure columns are reused.
ALTER TABLE public.invoice_items
  ADD COLUMN product_id uuid,
  ADD COLUMN vendor_product_id uuid,
  ADD COLUMN line_number integer CHECK (line_number > 0),
  ADD COLUMN manufacturer text,
  ADD COLUMN package_size text,
  ADD COLUMN review_status text NOT NULL DEFAULT 'pending_review'
    CHECK (review_status IN ('pending_review', 'approved', 'rejected', 'manual'));
ALTER TABLE public.invoice_items ADD CONSTRAINT invoice_items_product_org_fk
  FOREIGN KEY (product_id, organization_id)
  REFERENCES public.products(id, organization_id) NOT VALID;
ALTER TABLE public.invoice_items ADD CONSTRAINT invoice_items_vendor_product_org_fk
  FOREIGN KEY (vendor_product_id, organization_id)
  REFERENCES public.vendor_products(id, organization_id) NOT VALID;
CREATE INDEX invoice_items_org_product_idx
  ON public.invoice_items (organization_id, product_id) WHERE product_id IS NOT NULL;
CREATE INDEX invoice_items_org_vendor_product_idx
  ON public.invoice_items (organization_id, vendor_product_id) WHERE vendor_product_id IS NOT NULL;
CREATE INDEX invoice_items_invoice_line_idx ON public.invoice_items (invoice_id, line_number);

-- Adjustment provenance is nullable so all existing adjustment rows remain valid.
ALTER TABLE public.inventory_adjustments
  ADD COLUMN source_type text CHECK (source_type IN ('invoice', 'manual', 'system')),
  ADD COLUMN source_invoice_id uuid,
  ADD COLUMN source_invoice_item_id uuid,
  ADD COLUMN idempotency_key text;
ALTER TABLE public.inventory_adjustments ADD CONSTRAINT inventory_adjustments_source_invoice_org_fk
  FOREIGN KEY (source_invoice_id, organization_id)
  REFERENCES public.invoices(id, organization_id) NOT VALID;
ALTER TABLE public.inventory_adjustments ADD CONSTRAINT inventory_adjustments_source_item_org_fk
  FOREIGN KEY (source_invoice_item_id, organization_id)
  REFERENCES public.invoice_items(id, organization_id) NOT VALID;
CREATE UNIQUE INDEX inventory_adjustments_idempotency_uq
  ON public.inventory_adjustments (organization_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;
CREATE UNIQUE INDEX inventory_adjustments_invoice_item_receipt_uq
  ON public.inventory_adjustments (source_invoice_item_id)
  WHERE source_type = 'invoice' AND source_invoice_item_id IS NOT NULL;

-- Immutable purchase-price observations. Population begins only after application cutover.
CREATE TABLE public.inventory_price_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  product_id uuid NOT NULL,
  vendor_id uuid NOT NULL,
  vendor_product_id uuid,
  invoice_id uuid NOT NULL,
  invoice_item_id uuid NOT NULL UNIQUE,
  purchase_date date NOT NULL,
  quantity numeric NOT NULL CHECK (quantity > 0),
  package_size text,
  unit_of_measure text,
  unit_price numeric CHECK (unit_price >= 0),
  extended_price numeric CHECK (extended_price >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT inventory_price_history_product_org_fk FOREIGN KEY (product_id, organization_id)
    REFERENCES public.products(id, organization_id),
  CONSTRAINT inventory_price_history_vendor_org_fk FOREIGN KEY (vendor_id, organization_id)
    REFERENCES public.vendors(id, organization_id),
  CONSTRAINT inventory_price_history_vendor_product_org_fk FOREIGN KEY (vendor_product_id, organization_id)
    REFERENCES public.vendor_products(id, organization_id),
  CONSTRAINT inventory_price_history_invoice_org_fk FOREIGN KEY (invoice_id, organization_id)
    REFERENCES public.invoices(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT inventory_price_history_invoice_item_org_fk FOREIGN KEY (invoice_item_id, organization_id)
    REFERENCES public.invoice_items(id, organization_id) ON DELETE CASCADE
);
CREATE INDEX inventory_price_history_product_date_idx
  ON public.inventory_price_history (organization_id, product_id, purchase_date DESC);
CREATE INDEX inventory_price_history_vendor_date_idx
  ON public.inventory_price_history (organization_id, vendor_id, purchase_date DESC);
ALTER TABLE public.inventory_price_history ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.inventory_price_history TO authenticated;
GRANT ALL ON public.inventory_price_history TO service_role;
CREATE POLICY inventory_price_history_owner_select ON public.inventory_price_history
  FOR SELECT TO authenticated
  USING (public.has_org_role(organization_id, auth.uid(), ARRAY['owner']::public.org_role[]));

-- Durable, provider-neutral extraction staging. Nothing writes these tables in this phase.
CREATE TABLE public.invoice_extraction_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  vendor_invoice_id uuid NOT NULL,
  processing_job_id uuid NOT NULL,
  attempt_number integer NOT NULL DEFAULT 1 CHECK (attempt_number > 0),
  status text NOT NULL DEFAULT 'queued'
    CHECK (status IN ('queued', 'processing', 'succeeded', 'failed', 'cancelled')),
  extractor_name text,
  extractor_version text,
  schema_version text NOT NULL DEFAULT '1',
  raw_result jsonb,
  error_code text,
  error_message text,
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (vendor_invoice_id, attempt_number),
  CONSTRAINT invoice_extraction_runs_source_org_fk FOREIGN KEY (vendor_invoice_id, organization_id)
    REFERENCES public.vendor_invoices(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT invoice_extraction_runs_job_org_fk FOREIGN KEY (processing_job_id, organization_id)
    REFERENCES public.invoice_processing_jobs(id, organization_id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX invoice_extraction_runs_id_org_uq
  ON public.invoice_extraction_runs (id, organization_id);
CREATE INDEX invoice_extraction_runs_org_created_idx
  ON public.invoice_extraction_runs (organization_id, created_at DESC);
CREATE INDEX invoice_extraction_runs_job_idx ON public.invoice_extraction_runs (processing_job_id);
CREATE TRIGGER invoice_extraction_runs_updated_at BEFORE UPDATE ON public.invoice_extraction_runs
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();
ALTER TABLE public.invoice_extraction_runs ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.invoice_extraction_runs TO authenticated;
GRANT ALL ON public.invoice_extraction_runs TO service_role;
CREATE POLICY invoice_extraction_runs_owner_select ON public.invoice_extraction_runs
  FOR SELECT TO authenticated
  USING (public.has_org_role(organization_id, auth.uid(), ARRAY['owner']::public.org_role[]));

CREATE TABLE public.invoice_extraction_candidates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  extraction_run_id uuid NOT NULL,
  candidate_type text NOT NULL CHECK (candidate_type IN ('header', 'line_item')),
  line_number integer CHECK (line_number IS NULL OR line_number > 0),
  field_data jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(field_data) = 'object'),
  confidence_data jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(confidence_data) = 'object'),
  source_data jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(source_data) = 'object'),
  review_status text NOT NULL DEFAULT 'pending_review'
    CHECK (review_status IN ('pending_review', 'approved', 'rejected', 'edited')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT invoice_extraction_candidates_run_org_fk FOREIGN KEY (extraction_run_id, organization_id)
    REFERENCES public.invoice_extraction_runs(id, organization_id) ON DELETE CASCADE,
  CHECK ((candidate_type = 'header' AND line_number IS NULL)
    OR (candidate_type = 'line_item' AND line_number IS NOT NULL))
);
CREATE INDEX invoice_extraction_candidates_run_idx
  ON public.invoice_extraction_candidates (extraction_run_id, candidate_type, line_number);
CREATE INDEX invoice_extraction_candidates_org_review_idx
  ON public.invoice_extraction_candidates (organization_id, review_status);
CREATE TRIGGER invoice_extraction_candidates_updated_at BEFORE UPDATE ON public.invoice_extraction_candidates
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();
ALTER TABLE public.invoice_extraction_candidates ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.invoice_extraction_candidates TO authenticated;
GRANT ALL ON public.invoice_extraction_candidates TO service_role;
CREATE POLICY invoice_extraction_candidates_owner_select ON public.invoice_extraction_candidates
  FOR SELECT TO authenticated
  USING (public.has_org_role(organization_id, auth.uid(), ARRAY['owner']::public.org_role[]));
