-- Phase 5A.4A: platform-owned global catalog registry.
-- Additive only: no catalog data is imported and organization behavior is unchanged.

CREATE OR REPLACE FUNCTION public.normalize_catalog_sku(_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = public
AS $$
  SELECT upper(btrim(COALESCE(_value, '')));
$$;

COMMENT ON FUNCTION public.normalize_catalog_sku(text) IS
  'Authoritative vendor-SKU normalization: trim surrounding whitespace and uppercase while preserving punctuation and interior whitespace.';

CREATE OR REPLACE FUNCTION public.normalize_catalog_sku_match_key(_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = public
AS $$
  SELECT regexp_replace(upper(btrim(COALESCE(_value, ''))), '[^A-Z0-9]+', '', 'g');
$$;

COMMENT ON FUNCTION public.normalize_catalog_sku_match_key(text) IS
  'Non-authoritative SKU lookup key. Removes separators and punctuation, so collisions are allowed and must remain vendor-scoped.';

CREATE TABLE public.catalog_vendors (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  normalized_name text NOT NULL,
  website text,
  domain text,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT catalog_vendors_name_present CHECK (btrim(name) <> ''),
  CONSTRAINT catalog_vendors_normalized_name_present CHECK (btrim(normalized_name) <> ''),
  CONSTRAINT catalog_vendors_normalized_name_uq UNIQUE (normalized_name)
);

CREATE TRIGGER catalog_vendors_normalize
  BEFORE INSERT OR UPDATE OF name ON public.catalog_vendors
  FOR EACH ROW EXECUTE FUNCTION public.catalog_normalize_row();
CREATE TRIGGER catalog_vendors_updated_at
  BEFORE UPDATE ON public.catalog_vendors
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

CREATE TABLE public.catalog_categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  normalized_name text NOT NULL,
  parent_category_id uuid REFERENCES public.catalog_categories(id) ON DELETE SET NULL,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT catalog_categories_name_present CHECK (btrim(name) <> ''),
  CONSTRAINT catalog_categories_normalized_name_present CHECK (btrim(normalized_name) <> ''),
  CONSTRAINT catalog_categories_parent_not_self CHECK (
    parent_category_id IS NULL OR parent_category_id <> id
  )
);

CREATE UNIQUE INDEX catalog_categories_active_name_uq
  ON public.catalog_categories (normalized_name) WHERE active;
CREATE TRIGGER catalog_categories_normalize
  BEFORE INSERT OR UPDATE OF name ON public.catalog_categories
  FOR EACH ROW EXECUTE FUNCTION public.catalog_normalize_row();
CREATE TRIGGER catalog_categories_updated_at
  BEFORE UPDATE ON public.catalog_categories
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

CREATE TABLE public.catalog_products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  normalized_name text NOT NULL,
  description text,
  manufacturer text,
  normalized_manufacturer text,
  catalog_category_id uuid REFERENCES public.catalog_categories(id) ON DELETE SET NULL,
  active boolean NOT NULL DEFAULT true,
  verification_status text NOT NULL DEFAULT 'pending'
    CHECK (verification_status IN ('pending', 'verified', 'needs_review', 'rejected')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT catalog_products_name_present CHECK (btrim(name) <> ''),
  CONSTRAINT catalog_products_normalized_name_present CHECK (btrim(normalized_name) <> '')
);

CREATE OR REPLACE FUNCTION public.catalog_product_normalize_row()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.name := btrim(NEW.name);
  NEW.normalized_name := public.normalize_catalog_text(NEW.name);
  NEW.manufacturer := nullif(btrim(NEW.manufacturer), '');
  NEW.normalized_manufacturer := nullif(public.normalize_catalog_text(NEW.manufacturer), '');
  RETURN NEW;
END;
$$;

CREATE INDEX catalog_products_active_name_idx
  ON public.catalog_products (normalized_name) WHERE active;
CREATE INDEX catalog_products_active_manufacturer_idx
  ON public.catalog_products (normalized_manufacturer)
  WHERE active AND normalized_manufacturer IS NOT NULL;
CREATE TRIGGER catalog_products_normalize
  BEFORE INSERT OR UPDATE OF name, manufacturer ON public.catalog_products
  FOR EACH ROW EXECUTE FUNCTION public.catalog_product_normalize_row();
CREATE TRIGGER catalog_products_updated_at
  BEFORE UPDATE ON public.catalog_products
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

CREATE TABLE public.catalog_vendor_products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  catalog_product_id uuid NOT NULL REFERENCES public.catalog_products(id) ON DELETE RESTRICT,
  catalog_vendor_id uuid NOT NULL REFERENCES public.catalog_vendors(id) ON DELETE RESTRICT,
  vendor_sku text NOT NULL,
  normalized_vendor_sku text NOT NULL,
  vendor_sku_match_key text,
  manufacturer_sku text,
  normalized_manufacturer_sku text,
  package_description text,
  package_quantity numeric,
  package_unit text,
  package_status text NOT NULL DEFAULT 'unknown'
    CHECK (package_status IN ('verified', 'source_only', 'unknown')),
  source_catalog_price numeric,
  currency_code text,
  active boolean NOT NULL DEFAULT true,
  discontinued boolean NOT NULL DEFAULT false,
  verification_status text NOT NULL DEFAULT 'pending'
    CHECK (verification_status IN ('pending', 'verified', 'needs_review', 'rejected')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT catalog_vendor_products_vendor_sku_present CHECK (btrim(vendor_sku) <> ''),
  CONSTRAINT catalog_vendor_products_normalized_vendor_sku_present CHECK (
    btrim(normalized_vendor_sku) <> ''
  ),
  CONSTRAINT catalog_vendor_products_vendor_sku_uq
    UNIQUE (catalog_vendor_id, normalized_vendor_sku),
  CONSTRAINT catalog_vendor_products_package_quantity_positive CHECK (
    package_quantity IS NULL OR package_quantity > 0
  ),
  CONSTRAINT catalog_vendor_products_verified_package_complete CHECK (
    package_status <> 'verified'
    OR (package_quantity IS NOT NULL AND nullif(btrim(package_unit), '') IS NOT NULL)
  ),
  CONSTRAINT catalog_vendor_products_source_catalog_price_nonnegative CHECK (
    source_catalog_price IS NULL OR source_catalog_price >= 0
  ),
  CONSTRAINT catalog_vendor_products_currency_code_format CHECK (
    currency_code IS NULL OR currency_code ~ '^[A-Z]{3}$'
  ),
  CONSTRAINT catalog_vendor_products_discontinued_not_active CHECK (
    NOT discontinued OR NOT active
  )
);

CREATE OR REPLACE FUNCTION public.catalog_vendor_product_normalize_row()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.normalized_vendor_sku := public.normalize_catalog_sku(NEW.vendor_sku);
  NEW.vendor_sku_match_key := nullif(public.normalize_catalog_sku_match_key(NEW.vendor_sku), '');
  NEW.manufacturer_sku := nullif(btrim(NEW.manufacturer_sku), '');
  NEW.normalized_manufacturer_sku := nullif(public.normalize_catalog_sku(NEW.manufacturer_sku), '');
  NEW.package_description := nullif(btrim(NEW.package_description), '');
  NEW.package_unit := nullif(btrim(NEW.package_unit), '');
  NEW.currency_code := nullif(upper(btrim(NEW.currency_code)), '');
  RETURN NEW;
END;
$$;

CREATE UNIQUE INDEX catalog_vendor_products_id_vendor_uq
  ON public.catalog_vendor_products (id, catalog_vendor_id);
CREATE INDEX catalog_vendor_products_catalog_product_idx
  ON public.catalog_vendor_products (catalog_product_id);
CREATE INDEX catalog_vendor_products_vendor_sku_match_idx
  ON public.catalog_vendor_products (catalog_vendor_id, vendor_sku_match_key)
  WHERE vendor_sku_match_key IS NOT NULL;
CREATE INDEX catalog_vendor_products_manufacturer_sku_idx
  ON public.catalog_vendor_products (normalized_manufacturer_sku)
  WHERE normalized_manufacturer_sku IS NOT NULL;
CREATE TRIGGER catalog_vendor_products_normalize
  BEFORE INSERT OR UPDATE
  ON public.catalog_vendor_products
  FOR EACH ROW EXECUTE FUNCTION public.catalog_vendor_product_normalize_row();
CREATE TRIGGER catalog_vendor_products_updated_at
  BEFORE UPDATE ON public.catalog_vendor_products
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

CREATE TABLE public.catalog_import_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  catalog_vendor_id uuid NOT NULL REFERENCES public.catalog_vendors(id) ON DELETE RESTRICT,
  source_name text NOT NULL,
  source_version text NOT NULL,
  artifact_name text,
  artifact_sha256 text,
  source_uri text,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'processing', 'completed', 'failed', 'cancelled')),
  raw_record_count integer NOT NULL DEFAULT 0 CHECK (raw_record_count >= 0),
  unique_key_count integer NOT NULL DEFAULT 0 CHECK (unique_key_count >= 0),
  matched_record_count integer NOT NULL DEFAULT 0 CHECK (matched_record_count >= 0),
  unmatched_record_count integer NOT NULL DEFAULT 0 CHECK (unmatched_record_count >= 0),
  warning_count integer NOT NULL DEFAULT 0 CHECK (warning_count >= 0),
  error_count integer NOT NULL DEFAULT 0 CHECK (error_count >= 0),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata) = 'object'),
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT catalog_import_batches_source_name_present CHECK (btrim(source_name) <> ''),
  CONSTRAINT catalog_import_batches_source_version_present CHECK (btrim(source_version) <> ''),
  CONSTRAINT catalog_import_batches_sha256_format CHECK (
    artifact_sha256 IS NULL OR artifact_sha256 ~ '^[0-9A-Fa-f]{64}$'
  ),
  CONSTRAINT catalog_import_batches_timestamp_order CHECK (
    completed_at IS NULL OR started_at IS NULL OR completed_at >= started_at
  )
);

CREATE UNIQUE INDEX catalog_import_batches_id_vendor_uq
  ON public.catalog_import_batches (id, catalog_vendor_id);
CREATE UNIQUE INDEX catalog_import_batches_vendor_artifact_uq
  ON public.catalog_import_batches (catalog_vendor_id, lower(artifact_sha256))
  WHERE artifact_sha256 IS NOT NULL;
CREATE INDEX catalog_import_batches_vendor_created_idx
  ON public.catalog_import_batches (catalog_vendor_id, created_at DESC);
CREATE TRIGGER catalog_import_batches_updated_at
  BEFORE UPDATE ON public.catalog_import_batches
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

CREATE TABLE public.catalog_source_records (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  import_batch_id uuid NOT NULL,
  catalog_vendor_id uuid NOT NULL,
  source_ordinal integer NOT NULL CHECK (source_ordinal > 0),
  raw_vendor_sku text,
  normalized_raw_vendor_sku text,
  raw_vendor_sku_match_key text,
  raw_product_name text,
  raw_category text,
  raw_subsection text,
  raw_variant text,
  raw_package text,
  source_page text,
  raw_data jsonb NOT NULL CHECK (jsonb_typeof(raw_data) = 'object'),
  matched_catalog_vendor_product_id uuid,
  resolution_status text NOT NULL DEFAULT 'pending'
    CHECK (resolution_status IN ('pending', 'matched', 'verified_match', 'unkeyed', 'conflict', 'ignored')),
  resolved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT catalog_source_records_batch_vendor_fk
    FOREIGN KEY (import_batch_id, catalog_vendor_id)
    REFERENCES public.catalog_import_batches(id, catalog_vendor_id) ON DELETE RESTRICT,
  CONSTRAINT catalog_source_records_match_vendor_fk
    FOREIGN KEY (matched_catalog_vendor_product_id, catalog_vendor_id)
    REFERENCES public.catalog_vendor_products(id, catalog_vendor_id) ON DELETE RESTRICT,
  CONSTRAINT catalog_source_records_resolution_match CHECK (
    (resolution_status IN ('matched', 'verified_match') AND matched_catalog_vendor_product_id IS NOT NULL)
    OR (resolution_status NOT IN ('matched', 'verified_match') AND matched_catalog_vendor_product_id IS NULL)
  ),
  CONSTRAINT catalog_source_records_unkeyed_match_verified CHECK (
    normalized_raw_vendor_sku IS NOT NULL OR resolution_status <> 'matched'
  ),
  CONSTRAINT catalog_source_records_resolved_at_consistent CHECK (
    (resolution_status = 'pending' AND resolved_at IS NULL)
    OR (resolution_status <> 'pending' AND resolved_at IS NOT NULL)
  ),
  CONSTRAINT catalog_source_records_batch_ordinal_uq
    UNIQUE (import_batch_id, source_ordinal)
);

CREATE OR REPLACE FUNCTION public.catalog_source_record_normalize_row()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.normalized_raw_vendor_sku := nullif(public.normalize_catalog_sku(NEW.raw_vendor_sku), '');
  NEW.raw_vendor_sku_match_key := nullif(public.normalize_catalog_sku_match_key(NEW.raw_vendor_sku), '');
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.catalog_source_record_preserve_raw()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Catalog source records are immutable and cannot be deleted';
  END IF;

  IF ROW(
    NEW.import_batch_id,
    NEW.catalog_vendor_id,
    NEW.source_ordinal,
    NEW.raw_vendor_sku,
    NEW.normalized_raw_vendor_sku,
    NEW.raw_vendor_sku_match_key,
    NEW.raw_product_name,
    NEW.raw_category,
    NEW.raw_subsection,
    NEW.raw_variant,
    NEW.raw_package,
    NEW.source_page,
    NEW.raw_data
  ) IS DISTINCT FROM ROW(
    OLD.import_batch_id,
    OLD.catalog_vendor_id,
    OLD.source_ordinal,
    OLD.raw_vendor_sku,
    OLD.normalized_raw_vendor_sku,
    OLD.raw_vendor_sku_match_key,
    OLD.raw_product_name,
    OLD.raw_category,
    OLD.raw_subsection,
    OLD.raw_variant,
    OLD.raw_package,
    OLD.source_page,
    OLD.raw_data
  ) THEN
    RAISE EXCEPTION 'Raw catalog source fields are immutable; record a verification override instead';
  END IF;

  RETURN NEW;
END;
$$;

CREATE UNIQUE INDEX catalog_source_records_id_vendor_uq
  ON public.catalog_source_records (id, catalog_vendor_id);
CREATE INDEX catalog_source_records_vendor_sku_idx
  ON public.catalog_source_records (catalog_vendor_id, normalized_raw_vendor_sku)
  WHERE normalized_raw_vendor_sku IS NOT NULL;
CREATE INDEX catalog_source_records_vendor_sku_match_idx
  ON public.catalog_source_records (catalog_vendor_id, raw_vendor_sku_match_key)
  WHERE raw_vendor_sku_match_key IS NOT NULL;
CREATE INDEX catalog_source_records_match_idx
  ON public.catalog_source_records (matched_catalog_vendor_product_id)
  WHERE matched_catalog_vendor_product_id IS NOT NULL;
CREATE TRIGGER catalog_source_records_normalize
  BEFORE INSERT OR UPDATE OF raw_vendor_sku ON public.catalog_source_records
  FOR EACH ROW EXECUTE FUNCTION public.catalog_source_record_normalize_row();
CREATE TRIGGER catalog_source_records_preserve_raw
  BEFORE UPDATE OR DELETE ON public.catalog_source_records
  FOR EACH ROW EXECUTE FUNCTION public.catalog_source_record_preserve_raw();
CREATE TRIGGER catalog_source_records_updated_at
  BEFORE UPDATE ON public.catalog_source_records
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

CREATE TABLE public.catalog_verification_overrides (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  catalog_vendor_id uuid NOT NULL REFERENCES public.catalog_vendors(id) ON DELETE RESTRICT,
  import_batch_id uuid,
  source_record_id uuid,
  catalog_vendor_product_id uuid,
  source_vendor_sku text,
  normalized_source_vendor_sku text,
  verified_vendor_sku text,
  normalized_verified_vendor_sku text,
  override_type text NOT NULL
    CHECK (override_type IN ('sku_correction', 'purchasing_status', 'identity_decision', 'package_normalization', 'source_disposition', 'other')),
  evidence_status text NOT NULL DEFAULT 'pending'
    CHECK (evidence_status IN ('pending', 'verified', 'rejected')),
  production_rule text NOT NULL CHECK (btrim(production_rule) <> ''),
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(evidence) = 'object'),
  notes text,
  active boolean NOT NULL DEFAULT true,
  effective_from timestamptz NOT NULL DEFAULT now(),
  effective_to timestamptz,
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT catalog_verification_overrides_batch_vendor_fk
    FOREIGN KEY (import_batch_id, catalog_vendor_id)
    REFERENCES public.catalog_import_batches(id, catalog_vendor_id) ON DELETE RESTRICT,
  CONSTRAINT catalog_verification_overrides_source_vendor_fk
    FOREIGN KEY (source_record_id, catalog_vendor_id)
    REFERENCES public.catalog_source_records(id, catalog_vendor_id) ON DELETE RESTRICT,
  CONSTRAINT catalog_verification_overrides_product_vendor_fk
    FOREIGN KEY (catalog_vendor_product_id, catalog_vendor_id)
    REFERENCES public.catalog_vendor_products(id, catalog_vendor_id) ON DELETE RESTRICT,
  CONSTRAINT catalog_verification_overrides_identity_present CHECK (
    source_record_id IS NOT NULL
    OR normalized_source_vendor_sku IS NOT NULL
    OR catalog_vendor_product_id IS NOT NULL
  ),
  CONSTRAINT catalog_verification_overrides_sku_correction_complete CHECK (
    override_type <> 'sku_correction'
    OR (normalized_source_vendor_sku IS NOT NULL AND normalized_verified_vendor_sku IS NOT NULL)
  ),
  CONSTRAINT catalog_verification_overrides_effective_order CHECK (
    effective_to IS NULL OR effective_to > effective_from
  )
);

CREATE OR REPLACE FUNCTION public.catalog_verification_override_normalize_row()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.normalized_source_vendor_sku := nullif(public.normalize_catalog_sku(NEW.source_vendor_sku), '');
  NEW.normalized_verified_vendor_sku := nullif(public.normalize_catalog_sku(NEW.verified_vendor_sku), '');
  RETURN NEW;
END;
$$;

CREATE INDEX catalog_verification_overrides_source_sku_idx
  ON public.catalog_verification_overrides (
    catalog_vendor_id,
    normalized_source_vendor_sku,
    override_type
  ) WHERE active AND normalized_source_vendor_sku IS NOT NULL;
CREATE INDEX catalog_verification_overrides_product_idx
  ON public.catalog_verification_overrides (catalog_vendor_product_id)
  WHERE active AND catalog_vendor_product_id IS NOT NULL;
CREATE TRIGGER catalog_verification_overrides_normalize
  BEFORE INSERT OR UPDATE OF source_vendor_sku, verified_vendor_sku
  ON public.catalog_verification_overrides
  FOR EACH ROW EXECUTE FUNCTION public.catalog_verification_override_normalize_row();
CREATE TRIGGER catalog_verification_overrides_updated_at
  BEFORE UPDATE ON public.catalog_verification_overrides
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

-- Global catalog rows are directly readable but platform-owned. Import/audit data remains
-- service-role-only until MedSpend has an explicit platform-admin permission model.
ALTER TABLE public.catalog_vendors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalog_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalog_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalog_vendor_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalog_import_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalog_source_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalog_verification_overrides ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON public.catalog_vendors TO authenticated;
GRANT SELECT ON public.catalog_categories TO authenticated;
GRANT SELECT ON public.catalog_products TO authenticated;
GRANT SELECT ON public.catalog_vendor_products TO authenticated;
GRANT ALL ON public.catalog_vendors TO service_role;
GRANT ALL ON public.catalog_categories TO service_role;
GRANT ALL ON public.catalog_products TO service_role;
GRANT ALL ON public.catalog_vendor_products TO service_role;
GRANT SELECT, INSERT, UPDATE ON public.catalog_import_batches TO service_role;
GRANT SELECT, INSERT, UPDATE ON public.catalog_source_records TO service_role;
GRANT SELECT, INSERT, UPDATE ON public.catalog_verification_overrides TO service_role;

CREATE POLICY catalog_vendors_authenticated_select
  ON public.catalog_vendors FOR SELECT TO authenticated USING (true);
CREATE POLICY catalog_categories_authenticated_select
  ON public.catalog_categories FOR SELECT TO authenticated USING (true);
CREATE POLICY catalog_products_authenticated_select
  ON public.catalog_products FOR SELECT TO authenticated USING (true);
CREATE POLICY catalog_vendor_products_authenticated_select
  ON public.catalog_vendor_products FOR SELECT TO authenticated USING (true);

-- Optional adoption links. No rows are backfilled and no current query path is changed.
ALTER TABLE public.products
  ADD COLUMN catalog_product_id uuid,
  ADD CONSTRAINT products_catalog_product_fk
    FOREIGN KEY (catalog_product_id) REFERENCES public.catalog_products(id) ON DELETE SET NULL;
ALTER TABLE public.vendors
  ADD COLUMN catalog_vendor_id uuid,
  ADD CONSTRAINT vendors_catalog_vendor_fk
    FOREIGN KEY (catalog_vendor_id) REFERENCES public.catalog_vendors(id) ON DELETE SET NULL;
ALTER TABLE public.vendor_products
  ADD COLUMN catalog_vendor_product_id uuid,
  ADD CONSTRAINT vendor_products_catalog_vendor_product_fk
    FOREIGN KEY (catalog_vendor_product_id)
    REFERENCES public.catalog_vendor_products(id) ON DELETE SET NULL;

CREATE INDEX products_catalog_product_idx
  ON public.products (catalog_product_id, organization_id)
  WHERE catalog_product_id IS NOT NULL;
CREATE INDEX vendors_catalog_vendor_idx
  ON public.vendors (catalog_vendor_id, organization_id)
  WHERE catalog_vendor_id IS NOT NULL;
CREATE INDEX vendor_products_catalog_vendor_product_idx
  ON public.vendor_products (catalog_vendor_product_id, organization_id)
  WHERE catalog_vendor_product_id IS NOT NULL;

COMMENT ON TABLE public.catalog_vendors IS
  'Platform-owned vendor identities shared by all organizations.';
COMMENT ON TABLE public.catalog_categories IS
  'Platform taxonomy; vendor source sections remain provenance rather than defining this hierarchy.';
COMMENT ON TABLE public.catalog_products IS
  'Conservative platform canonical product identities. Similar rows are not automatically merged.';
COMMENT ON TABLE public.catalog_vendor_products IS
  'Vendor-specific platform listings identified by vendor and normalized vendor SKU.';
COMMENT ON COLUMN public.catalog_vendor_products.vendor_sku IS
  'Exact vendor-facing SKU. Derived normalization and match keys must not overwrite this value.';
COMMENT ON COLUMN public.catalog_vendor_products.normalized_vendor_sku IS
  'Conservative vendor-scoped uniqueness key that preserves punctuation.';
COMMENT ON COLUMN public.catalog_vendor_products.vendor_sku_match_key IS
  'Non-unique vendor-scoped lookup key. Future invoice resolution should prefer exact normalized SKU, then this match key, then verified aliases/signatures, then broader candidate matching.';
COMMENT ON COLUMN public.catalog_vendor_products.package_status IS
  'Only verified package rows are eligible for normalized unit-cost calculations.';
COMMENT ON COLUMN public.catalog_vendor_products.source_catalog_price IS
  'Non-transactional source/list/MSRP-style catalog price. Actual purchase prices remain authoritative only in invoice and inventory_price_history flows.';
COMMENT ON TABLE public.catalog_import_batches IS
  'Repeatable import ledger with artifact identity and QA counts; it does not contain organization data.';
COMMENT ON TABLE public.catalog_source_records IS
  'Occurrence-level source provenance. Raw fields cannot be changed or rows deleted; only resolution metadata may change.';
COMMENT ON COLUMN public.catalog_source_records.source_ordinal IS
  'Deterministic one-based occurrence position within an import batch; repeated vendor SKUs retain distinct ordinals.';
COMMENT ON TABLE public.catalog_verification_overrides IS
  'Audited production decisions applied without changing raw catalog source records.';
COMMENT ON COLUMN public.products.catalog_product_id IS
  'Optional link from an organization-owned product to a platform canonical product.';
COMMENT ON COLUMN public.vendors.catalog_vendor_id IS
  'Optional link from an organization-owned vendor/account to a platform vendor identity.';
COMMENT ON COLUMN public.vendor_products.catalog_vendor_product_id IS
  'Optional link from an organization-owned vendor mapping to a platform vendor listing.';
