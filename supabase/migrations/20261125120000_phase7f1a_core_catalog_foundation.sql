-- Phase 7F.1A: Core multi-vendor catalog foundation.
--
-- Additive only. Establishes global catalog identity, search grouping and provenance
-- structures for future catalogs (Klean, Thorne, Momentous, Collins, Medco), and scopes
-- staff catalog search to the catalog vendors an organization uses. No vendor adapter, no
-- import, no offer or price, no request-semantics change and no backfill.
--
-- New global tables (platform facts only; authenticated read, service-role write):
--   * catalog_brands            brand / manufacturer identity, separate from sellers
--                               (catalog_vendors). Unique normalized name; never merged
--                               automatically.
--   * catalog_concepts          requester search grouping ("Creatine Monohydrate"). A
--                               concept is NOT product identity: two products in one
--                               concept are still different exact products.
--   * catalog_concept_synonyms  extra search words for a concept.
--   * catalog_product_concepts  many-to-many exact product <-> concept with assignment
--                               provenance (manual | imported | deterministic_rule).
--                               Nothing in the database assigns concepts; in particular a
--                               product name is never used to infer a concept.
--   * catalog_product_families  explicit, source-proven groups of branded variants
--                               (Klean Isolate -> flavors). Never inferred from names.
--   * catalog_certification_types / catalog_product_certifications
--                               certification facts on the exact catalog product, each
--                               with an evidence reference and verified_at. Never
--                               inferred from a brand.
--   * catalog_bundle_components bundle composition metadata only. Bundles are never
--                               exploded into inventory.
--
-- New nullable / defaulted columns (no row is rewritten: constant defaults are catalog
-- metadata in PostgreSQL 11+):
--   * catalog_products: brand_id, normalized_mpn, gtin, family_id, attributes (jsonb,
--     default '{}'), product_kind (default 'single'), purchase_restriction (default
--     'unknown'). MPN and GTIN are lookup evidence, deliberately NOT unique: a match is
--     evidence for a later, reviewed cross-vendor link, never an automatic merge.
--   * catalog_vendor_products: listing_url, last_seen_batch_id, last_seen_at,
--     availability_status, availability_observed_at. Availability is what a source said
--     at a time, never real-time stock; the existing discontinued flag is unchanged and
--     still decides search eligibility.
--   * catalog_import_batches: source_type, effective_date (NULL on the existing Henry
--     Schein batch; nothing is backfilled).
--
-- Pricing boundary: catalog_vendor_products.source_catalog_price is readable by every
-- authenticated user of every organization (RLS USING (true)). It must never hold
-- account-specific, wholesale, quoted or otherwise confidential prices. Organization
-- prices belong to organization-scoped tables (Phase 7F.1B), never to a global table.
-- The column is kept only for deployed compatibility.
--
-- Organization catalog visibility: an organization uses a catalog vendor exactly when it
-- has an ACTIVE organization vendor linked to it (vendors.catalog_vendor_id). That link is
-- unique per organization (vendors_org_catalog_vendor_uq), can only be set through
-- link_organization_vendor_to_catalog_vendor (owner/admin), and can never be repointed
-- (guard_vendor_catalog_link). No new enablement table is needed. Staff request search
-- (supply_request_product_search, and through it search_supply_request_products and
-- search_supply_request_products_with_signals) and discovery identities
-- (supply_request_product_identities, used by get_staff_product_discovery and
-- save_staff_product) now only return global listings of those catalog vendors; owners
-- and admins follow the same rule there. Everything else in those functions (signatures,
-- tiers, ranking, typo correction, organization products) is byte-for-byte the Phase
-- 5A.10 definition. Global catalog identity tables stay authenticated-readable as before;
-- this is a search scope, not a secrecy boundary.
--
-- Rollback (no data depends on the new objects until 7F.1B):
--   re-run the Phase 5A.10 definitions of supply_request_product_search and
--   supply_request_product_identities; then DROP the new tables (catalog_bundle_components,
--   catalog_product_certifications, catalog_certification_types, catalog_product_concepts,
--   catalog_concept_synonyms, catalog_concepts) and the new columns, then
--   catalog_product_families and catalog_brands.

BEGIN;

DO $preflight$
DECLARE
  _missing text;
BEGIN
  SELECT pg_catalog.string_agg(name, ', ')
  INTO _missing
  FROM pg_catalog.unnest(ARRAY[
    'public.catalog_vendors', 'public.catalog_products', 'public.catalog_vendor_products',
    'public.catalog_import_batches', 'public.catalog_source_records', 'public.vendors',
    'public.catalog_vendor_product_search_documents'
  ]) name
  WHERE pg_catalog.to_regclass(name) IS NULL;
  IF _missing IS NOT NULL THEN
    RAISE EXCEPTION 'Phase 7F.1A requires %', _missing;
  END IF;
  IF pg_catalog.to_regprocedure('public.supply_request_product_search(uuid, text, integer)') IS NULL
     OR pg_catalog.to_regprocedure('public.supply_request_product_identities(uuid, uuid[], uuid[], uuid[])') IS NULL
     OR pg_catalog.to_regprocedure('public.normalize_catalog_text(text)') IS NULL
     OR pg_catalog.to_regprocedure('public.normalize_catalog_sku(text)') IS NULL
     OR pg_catalog.to_regprocedure('public.tg_set_updated_at()') IS NULL
     OR pg_catalog.to_regprocedure('public.link_organization_vendor_to_catalog_vendor(uuid, uuid, uuid, timestamptz)') IS NULL
     OR pg_catalog.to_regprocedure('public.price_product_state(uuid, uuid[], date, boolean)') IS NULL THEN
    RAISE EXCEPTION 'Phase 7F.1A requires Phase 5A.10, the catalog vendor link and Phase 6B.1';
  END IF;
  IF pg_catalog.to_regclass('public.vendors_org_catalog_vendor_uq') IS NULL
     OR pg_catalog.to_regclass('public.catalog_import_batches_id_vendor_uq') IS NULL THEN
    RAISE EXCEPTION 'Phase 7F.1A requires vendors_org_catalog_vendor_uq and catalog_import_batches_id_vendor_uq';
  END IF;
  SELECT pg_catalog.string_agg(name, ', ')
  INTO _missing
  FROM pg_catalog.unnest(ARRAY[
    'public.catalog_brands', 'public.catalog_concepts', 'public.catalog_concept_synonyms',
    'public.catalog_product_concepts', 'public.catalog_product_families',
    'public.catalog_certification_types', 'public.catalog_product_certifications',
    'public.catalog_bundle_components'
  ]) name
  WHERE pg_catalog.to_regclass(name) IS NOT NULL;
  IF _missing IS NOT NULL THEN
    RAISE EXCEPTION 'Phase 7F.1A objects already exist unexpectedly: %', _missing;
  END IF;
  SELECT pg_catalog.string_agg(c.table_name || '.' || c.column_name, ', ')
  INTO _missing
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND (c.table_name, c.column_name) IN (
      ('catalog_products', 'brand_id'), ('catalog_products', 'normalized_mpn'),
      ('catalog_products', 'gtin'), ('catalog_products', 'family_id'),
      ('catalog_products', 'attributes'), ('catalog_products', 'product_kind'),
      ('catalog_products', 'purchase_restriction'),
      ('catalog_vendor_products', 'listing_url'), ('catalog_vendor_products', 'last_seen_batch_id'),
      ('catalog_vendor_products', 'last_seen_at'), ('catalog_vendor_products', 'availability_status'),
      ('catalog_vendor_products', 'availability_observed_at'),
      ('catalog_import_batches', 'source_type'), ('catalog_import_batches', 'effective_date')
    );
  IF _missing IS NOT NULL THEN
    RAISE EXCEPTION 'Phase 7F.1A columns already exist unexpectedly: %', _missing;
  END IF;
END
$preflight$;

-- ---------------------------------------------------------------------------------------
-- Brands
-- ---------------------------------------------------------------------------------------

CREATE TABLE public.catalog_brands (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  normalized_name text GENERATED ALWAYS AS (public.normalize_catalog_text(name)) STORED,
  manufacturer_name text,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT catalog_brands_name_present CHECK (pg_catalog.btrim(name) <> '' AND normalized_name <> ''),
  CONSTRAINT catalog_brands_manufacturer_name_present CHECK (
    manufacturer_name IS NULL OR pg_catalog.btrim(manufacturer_name) <> ''
  ),
  CONSTRAINT catalog_brands_normalized_name_uq UNIQUE (normalized_name)
);
CREATE TRIGGER catalog_brands_updated_at
  BEFORE UPDATE ON public.catalog_brands
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();
COMMENT ON TABLE public.catalog_brands IS
  'Phase 7F.1A global brand / manufacturer identity, separate from sellers (catalog_vendors). One row per normalized name; brands are never merged automatically. Platform-written only.';

-- ---------------------------------------------------------------------------------------
-- Families (explicit, source-proven variant groups)
-- ---------------------------------------------------------------------------------------

CREATE TABLE public.catalog_product_families (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  brand_id uuid REFERENCES public.catalog_brands(id) ON DELETE RESTRICT,
  name text NOT NULL,
  normalized_name text GENERATED ALWAYS AS (public.normalize_catalog_text(name)) STORED,
  description text,
  import_batch_id uuid REFERENCES public.catalog_import_batches(id) ON DELETE RESTRICT,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT catalog_product_families_name_present CHECK (pg_catalog.btrim(name) <> '' AND normalized_name <> ''),
  CONSTRAINT catalog_product_families_brand_name_uq UNIQUE NULLS NOT DISTINCT (brand_id, normalized_name)
);
CREATE INDEX catalog_product_families_import_batch_idx
  ON public.catalog_product_families (import_batch_id) WHERE import_batch_id IS NOT NULL;
CREATE TRIGGER catalog_product_families_updated_at
  BEFORE UPDATE ON public.catalog_product_families
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();
COMMENT ON TABLE public.catalog_product_families IS
  'Phase 7F.1A optional group of branded variants that a source explicitly proves belong together (flavors, sizes). Membership is set explicitly by an import; never inferred from matching names. A family is not product identity.';

-- ---------------------------------------------------------------------------------------
-- Exact product (catalog_products) additions
-- ---------------------------------------------------------------------------------------

ALTER TABLE public.catalog_products
  ADD COLUMN brand_id uuid REFERENCES public.catalog_brands(id) ON DELETE RESTRICT,
  ADD COLUMN normalized_mpn text,
  ADD COLUMN gtin text,
  ADD COLUMN family_id uuid REFERENCES public.catalog_product_families(id) ON DELETE RESTRICT,
  ADD COLUMN attributes jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN product_kind text NOT NULL DEFAULT 'single',
  ADD COLUMN purchase_restriction text NOT NULL DEFAULT 'unknown',
  ADD CONSTRAINT catalog_products_normalized_mpn_format CHECK (
    normalized_mpn IS NULL
    OR (normalized_mpn <> '' AND normalized_mpn = public.normalize_catalog_sku(normalized_mpn))
  ),
  ADD CONSTRAINT catalog_products_mpn_requires_brand CHECK (normalized_mpn IS NULL OR brand_id IS NOT NULL),
  ADD CONSTRAINT catalog_products_gtin_format CHECK (gtin IS NULL OR gtin ~ '^([0-9]{8}|[0-9]{12,14})$'),
  ADD CONSTRAINT catalog_products_attributes_object CHECK (
    pg_catalog.jsonb_typeof(attributes) = 'object'
    AND NOT (attributes ?| ARRAY['certification', 'certifications', 'certified'])
  ),
  ADD CONSTRAINT catalog_products_product_kind_check CHECK (product_kind IN ('single', 'bundle')),
  ADD CONSTRAINT catalog_products_purchase_restriction_check CHECK (
    purchase_restriction IN ('none', 'licensed_professional', 'prescription', 'restricted', 'unknown')
  );

CREATE INDEX catalog_products_brand_mpn_idx
  ON public.catalog_products (brand_id, normalized_mpn) WHERE brand_id IS NOT NULL;
CREATE INDEX catalog_products_gtin_idx
  ON public.catalog_products (gtin) WHERE gtin IS NOT NULL;
CREATE INDEX catalog_products_family_idx
  ON public.catalog_products (family_id) WHERE family_id IS NOT NULL;
-- Lets catalog_bundle_components require that its bundle is a bundle (composite FK).
CREATE UNIQUE INDEX catalog_products_id_kind_uq
  ON public.catalog_products (id, product_kind);

COMMENT ON COLUMN public.catalog_products.brand_id IS
  'Phase 7F.1A brand of this exact product. Optional; never inferred from a vendor or a name.';
COMMENT ON COLUMN public.catalog_products.normalized_mpn IS
  'Phase 7F.1A manufacturer part number (normalize_catalog_sku form), scoped by brand. Lookup evidence only: deliberately not unique, never an automatic merge key.';
COMMENT ON COLUMN public.catalog_products.gtin IS
  'Phase 7F.1A GTIN/UPC/EAN digits as printed by the source. Lookup evidence only: deliberately not unique, never an automatic merge key.';
COMMENT ON COLUMN public.catalog_products.family_id IS
  'Phase 7F.1A explicit family membership set by an import. Never inferred from names. Henry Schein products have none.';
COMMENT ON COLUMN public.catalog_products.attributes IS
  'Phase 7F.1A structured variant attributes (JSON object). V1 keys, validated by the shared importer: size, flavor, color, side, width, length, net_weight, servings, count, model, body_region. Certifications never go here (catalog_product_certifications).';
COMMENT ON COLUMN public.catalog_products.product_kind IS
  'Phase 7F.1A single | bundle. A bundle is purchasable as itself; components are metadata only (catalog_bundle_components).';
COMMENT ON COLUMN public.catalog_products.purchase_restriction IS
  'Phase 7F.1A source-reported purchase restriction: none | licensed_professional | prescription | restricted | unknown (default). Metadata only; no credentialing or enforcement.';

-- ---------------------------------------------------------------------------------------
-- Concepts
-- ---------------------------------------------------------------------------------------

CREATE TABLE public.catalog_concepts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  normalized_name text GENERATED ALWAYS AS (public.normalize_catalog_text(name)) STORED,
  description text,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT catalog_concepts_name_present CHECK (pg_catalog.btrim(name) <> '' AND normalized_name <> ''),
  CONSTRAINT catalog_concepts_normalized_name_uq UNIQUE (normalized_name)
);
CREATE TRIGGER catalog_concepts_updated_at
  BEFORE UPDATE ON public.catalog_concepts
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();
COMMENT ON TABLE public.catalog_concepts IS
  'Phase 7F.1A requester search grouping (for example Creatine Monohydrate). NOT product identity: products in one concept remain different exact products. Platform-curated.';

CREATE TABLE public.catalog_concept_synonyms (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  concept_id uuid NOT NULL REFERENCES public.catalog_concepts(id) ON DELETE CASCADE,
  synonym text NOT NULL,
  normalized_synonym text GENERATED ALWAYS AS (public.normalize_catalog_text(synonym)) STORED,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT catalog_concept_synonyms_present CHECK (pg_catalog.btrim(synonym) <> '' AND normalized_synonym <> ''),
  CONSTRAINT catalog_concept_synonyms_concept_synonym_uq UNIQUE (concept_id, normalized_synonym)
);
CREATE INDEX catalog_concept_synonyms_normalized_idx
  ON public.catalog_concept_synonyms (normalized_synonym);
COMMENT ON TABLE public.catalog_concept_synonyms IS
  'Phase 7F.1A additional search words for a concept. A word may belong to more than one concept (for example "tape"); it is unique within a concept.';

CREATE TABLE public.catalog_product_concepts (
  catalog_product_id uuid NOT NULL REFERENCES public.catalog_products(id) ON DELETE CASCADE,
  concept_id uuid NOT NULL REFERENCES public.catalog_concepts(id) ON DELETE CASCADE,
  assignment_source text NOT NULL,
  import_batch_id uuid REFERENCES public.catalog_import_batches(id) ON DELETE RESTRICT,
  source_record_id uuid REFERENCES public.catalog_source_records(id) ON DELETE RESTRICT,
  rule_key text,
  assigned_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (catalog_product_id, concept_id),
  CONSTRAINT catalog_product_concepts_source_check CHECK (
    assignment_source IN ('manual', 'imported', 'deterministic_rule')
  ),
  CONSTRAINT catalog_product_concepts_imported_provenance CHECK (
    assignment_source <> 'imported' OR import_batch_id IS NOT NULL
  ),
  CONSTRAINT catalog_product_concepts_rule_provenance CHECK (
    (assignment_source = 'deterministic_rule') = (rule_key IS NOT NULL)
    AND (rule_key IS NULL OR rule_key ~ '^[a-z][a-z0-9_.:-]{2,80}$')
  )
);
CREATE INDEX catalog_product_concepts_concept_idx
  ON public.catalog_product_concepts (concept_id, catalog_product_id);
CREATE TRIGGER catalog_product_concepts_updated_at
  BEFORE UPDATE ON public.catalog_product_concepts
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();
COMMENT ON TABLE public.catalog_product_concepts IS
  'Phase 7F.1A many-to-many exact product <-> concept, with provenance: manual (assigned_by when a person), imported (import_batch_id required) or deterministic_rule (rule_key required). The database never assigns concepts, and never from product names.';

-- ---------------------------------------------------------------------------------------
-- Certifications
-- ---------------------------------------------------------------------------------------

CREATE TABLE public.catalog_certification_types (
  code text PRIMARY KEY,
  name text NOT NULL,
  issuing_body text,
  description text,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT catalog_certification_types_code_format CHECK (code ~ '^[a-z][a-z0-9_]{2,62}$'),
  CONSTRAINT catalog_certification_types_name_present CHECK (pg_catalog.btrim(name) <> '')
);
CREATE TRIGGER catalog_certification_types_updated_at
  BEFORE UPDATE ON public.catalog_certification_types
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();
COMMENT ON TABLE public.catalog_certification_types IS
  'Phase 7F.1A certification programs (reference data).';

INSERT INTO public.catalog_certification_types (code, name, issuing_body, description)
VALUES (
  'nsf_certified_for_sport',
  'NSF Certified for Sport',
  'NSF',
  'Third-party certification for sport nutrition products. Applies to a specific exact product, never to a brand.'
);

CREATE TABLE public.catalog_product_certifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  catalog_product_id uuid NOT NULL REFERENCES public.catalog_products(id) ON DELETE CASCADE,
  certification_code text NOT NULL REFERENCES public.catalog_certification_types(code) ON DELETE RESTRICT,
  import_batch_id uuid REFERENCES public.catalog_import_batches(id) ON DELETE RESTRICT,
  source_record_id uuid REFERENCES public.catalog_source_records(id) ON DELETE RESTRICT,
  evidence_url text,
  evidence_reference text,
  verified_at timestamptz NOT NULL,
  expires_at timestamptz,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT catalog_product_certifications_evidence_present CHECK (
    import_batch_id IS NOT NULL
    OR source_record_id IS NOT NULL
    OR NULLIF(pg_catalog.btrim(evidence_url), '') IS NOT NULL
    OR NULLIF(pg_catalog.btrim(evidence_reference), '') IS NOT NULL
  ),
  CONSTRAINT catalog_product_certifications_evidence_url_format CHECK (
    evidence_url IS NULL OR evidence_url ~ '^https?://'
  ),
  CONSTRAINT catalog_product_certifications_expiry_order CHECK (expires_at IS NULL OR expires_at > verified_at)
);
CREATE UNIQUE INDEX catalog_product_certifications_active_uq
  ON public.catalog_product_certifications (catalog_product_id, certification_code) WHERE active;
CREATE INDEX catalog_product_certifications_code_idx
  ON public.catalog_product_certifications (certification_code, catalog_product_id) WHERE active;
CREATE TRIGGER catalog_product_certifications_updated_at
  BEFORE UPDATE ON public.catalog_product_certifications
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();
COMMENT ON TABLE public.catalog_product_certifications IS
  'Phase 7F.1A certification of one exact catalog product (variant), with an evidence reference, verified_at and optional expires_at. Never inferred from a brand. Superseded facts are kept inactive.';

-- ---------------------------------------------------------------------------------------
-- Bundles (metadata only)
-- ---------------------------------------------------------------------------------------

CREATE TABLE public.catalog_bundle_components (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bundle_catalog_product_id uuid NOT NULL,
  bundle_kind text GENERATED ALWAYS AS ('bundle') STORED,
  ordinal integer NOT NULL,
  component_catalog_product_id uuid REFERENCES public.catalog_products(id) ON DELETE RESTRICT,
  component_text text,
  quantity numeric,
  import_batch_id uuid REFERENCES public.catalog_import_batches(id) ON DELETE RESTRICT,
  source_record_id uuid REFERENCES public.catalog_source_records(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT catalog_bundle_components_bundle_fk
    FOREIGN KEY (bundle_catalog_product_id, bundle_kind)
    REFERENCES public.catalog_products (id, product_kind) ON UPDATE RESTRICT ON DELETE CASCADE,
  CONSTRAINT catalog_bundle_components_ordinal_positive CHECK (ordinal > 0),
  CONSTRAINT catalog_bundle_components_component_present CHECK (
    component_catalog_product_id IS NOT NULL OR NULLIF(pg_catalog.btrim(component_text), '') IS NOT NULL
  ),
  CONSTRAINT catalog_bundle_components_not_self CHECK (
    component_catalog_product_id IS DISTINCT FROM bundle_catalog_product_id
  ),
  CONSTRAINT catalog_bundle_components_quantity_positive CHECK (quantity IS NULL OR quantity > 0),
  CONSTRAINT catalog_bundle_components_ordinal_uq UNIQUE (bundle_catalog_product_id, ordinal)
);
CREATE INDEX catalog_bundle_components_component_idx
  ON public.catalog_bundle_components (component_catalog_product_id)
  WHERE component_catalog_product_id IS NOT NULL;
CREATE TRIGGER catalog_bundle_components_updated_at
  BEFORE UPDATE ON public.catalog_bundle_components
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();
COMMENT ON TABLE public.catalog_bundle_components IS
  'Phase 7F.1A bundle composition metadata. The bundle must be a catalog product with product_kind = bundle. A component is a catalog product or unresolved source text. Never exploded into inventory or receipts.';

-- ---------------------------------------------------------------------------------------
-- Global listing (catalog_vendor_products) additions
-- ---------------------------------------------------------------------------------------

ALTER TABLE public.catalog_vendor_products
  ADD COLUMN listing_url text,
  ADD COLUMN last_seen_batch_id uuid,
  ADD COLUMN last_seen_at timestamptz,
  ADD COLUMN availability_status text,
  ADD COLUMN availability_observed_at timestamptz,
  ADD CONSTRAINT catalog_vendor_products_listing_url_format CHECK (listing_url IS NULL OR listing_url ~ '^https?://'),
  ADD CONSTRAINT catalog_vendor_products_last_seen_batch_fk
    FOREIGN KEY (last_seen_batch_id, catalog_vendor_id)
    REFERENCES public.catalog_import_batches (id, catalog_vendor_id) ON DELETE RESTRICT,
  ADD CONSTRAINT catalog_vendor_products_last_seen_consistent CHECK (
    (last_seen_batch_id IS NULL) = (last_seen_at IS NULL)
  ),
  ADD CONSTRAINT catalog_vendor_products_availability_status_check CHECK (
    availability_status IS NULL
    OR availability_status IN ('in_stock', 'out_of_stock', 'backorder', 'discontinued', 'unknown')
  ),
  ADD CONSTRAINT catalog_vendor_products_availability_observed CHECK (
    (availability_status IS NULL) = (availability_observed_at IS NULL)
  );

CREATE INDEX catalog_vendor_products_last_seen_batch_idx
  ON public.catalog_vendor_products (last_seen_batch_id) WHERE last_seen_batch_id IS NOT NULL;

COMMENT ON COLUMN public.catalog_vendor_products.source_catalog_price IS
  'Public catalog list price only. Readable by every authenticated user of every organization: NEVER store account-specific, wholesale, quoted, promotional or otherwise confidential prices here. Organization pricing belongs in organization-scoped tables (Phase 7F.1B). Kept for deployed compatibility.';
COMMENT ON COLUMN public.catalog_vendor_products.listing_url IS
  'Phase 7F.1A public product page of this listing, when the source gives one.';
COMMENT ON COLUMN public.catalog_vendor_products.last_seen_batch_id IS
  'Phase 7F.1A most recent import batch of this catalog vendor that contained the listing. A listing missing from a later batch is never deleted.';
COMMENT ON COLUMN public.catalog_vendor_products.availability_status IS
  'Phase 7F.1A availability as a source reported it at availability_observed_at: in_stock | out_of_stock | backorder | discontinued | unknown. Never real-time stock. The discontinued column alone still decides search eligibility.';

-- ---------------------------------------------------------------------------------------
-- Provenance (catalog_import_batches) additions
-- ---------------------------------------------------------------------------------------

ALTER TABLE public.catalog_import_batches
  ADD COLUMN source_type text,
  ADD COLUMN effective_date date,
  ADD CONSTRAINT catalog_import_batches_source_type_check CHECK (
    source_type IS NULL OR source_type IN ('xlsx', 'csv', 'pdf', 'website', 'api', 'manual')
  );
COMMENT ON COLUMN public.catalog_import_batches.source_type IS
  'Phase 7F.1A kind of source: xlsx | csv | pdf | website | api | manual. NULL on batches imported before 7F.1A.';
COMMENT ON COLUMN public.catalog_import_batches.effective_date IS
  'Phase 7F.1A date the source states it is effective from, only when the source states one. NULL otherwise; never guessed.';

-- ---------------------------------------------------------------------------------------
-- Privileges: global platform facts. Authenticated read, service-role write, no anon.
-- ---------------------------------------------------------------------------------------

ALTER TABLE public.catalog_brands ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalog_product_families ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalog_concepts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalog_concept_synonyms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalog_product_concepts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalog_certification_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalog_product_certifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalog_bundle_components ENABLE ROW LEVEL SECURITY;

REVOKE ALL PRIVILEGES ON TABLE
  public.catalog_brands, public.catalog_product_families, public.catalog_concepts,
  public.catalog_concept_synonyms, public.catalog_product_concepts,
  public.catalog_certification_types, public.catalog_product_certifications,
  public.catalog_bundle_components
FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT ON TABLE
  public.catalog_brands, public.catalog_product_families, public.catalog_concepts,
  public.catalog_concept_synonyms, public.catalog_product_concepts,
  public.catalog_certification_types, public.catalog_product_certifications,
  public.catalog_bundle_components
TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE
  public.catalog_brands, public.catalog_product_families, public.catalog_concepts,
  public.catalog_concept_synonyms, public.catalog_product_concepts,
  public.catalog_certification_types, public.catalog_product_certifications,
  public.catalog_bundle_components
TO service_role;

CREATE POLICY catalog_brands_authenticated_select
  ON public.catalog_brands FOR SELECT TO authenticated USING (true);
CREATE POLICY catalog_product_families_authenticated_select
  ON public.catalog_product_families FOR SELECT TO authenticated USING (true);
CREATE POLICY catalog_concepts_authenticated_select
  ON public.catalog_concepts FOR SELECT TO authenticated USING (true);
CREATE POLICY catalog_concept_synonyms_authenticated_select
  ON public.catalog_concept_synonyms FOR SELECT TO authenticated USING (true);
CREATE POLICY catalog_product_concepts_authenticated_select
  ON public.catalog_product_concepts FOR SELECT TO authenticated USING (true);
CREATE POLICY catalog_certification_types_authenticated_select
  ON public.catalog_certification_types FOR SELECT TO authenticated USING (true);
CREATE POLICY catalog_product_certifications_authenticated_select
  ON public.catalog_product_certifications FOR SELECT TO authenticated USING (true);
CREATE POLICY catalog_bundle_components_authenticated_select
  ON public.catalog_bundle_components FOR SELECT TO authenticated USING (true);

-- ---------------------------------------------------------------------------------------
-- Organization catalog scope for staff request search and discovery.
-- The two definitions below are the Phase 5A.10 definitions with only the marked
-- "Phase 7F.1A" scope additions.
-- ---------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.supply_request_product_search(
  _organization_id uuid,
  _query text,
  _limit integer
)
RETURNS TABLE (
  result_key text,
  identity_source text,
  product_name text,
  manufacturer text,
  vendor_name text,
  vendor_sku text,
  package_display text,
  package_status text,
  inventory_item_id uuid,
  product_id uuid,
  vendor_product_id uuid,
  catalog_vendor_product_id uuid,
  variant_detail text,
  unit text,
  pack_size text,
  match_tier integer,
  is_saved boolean,
  approved_request_count integer,
  last_approved_at timestamptz,
  purchase_count integer,
  last_purchased_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET plan_cache_mode = force_custom_plan
AS $$
DECLARE
  _uid uuid := auth.uid();
  _raw_query text := pg_catalog.btrim(COALESCE(_query, ''));
  _normalized_text text;
  _normalized_sku text;
  _sku_key text;
  _sku_partial boolean;
  _tokens text[];
  _patterns text[];
  _fuzzy_patterns text[];
  _phrase_pattern text;
  _first_word text;
  _last_word text;
  _corrected boolean := false;
  _index_patterns text[];
  _p1 text;
  _p2 text;
  _p3 text;
  _p4 text;
  _token text;
  _corrections text[];
  _limit_edits integer;
  _bounded_limit integer := LEAST(GREATEST(COALESCE(_limit, 20), 1), 50);
  -- Phase 7F.1A: catalog vendors this organization uses.
  _enabled_catalog_vendor_ids uuid[];
BEGIN
  IF _uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;
  IF _organization_id IS NULL THEN
    RAISE EXCEPTION 'organization_id is required' USING ERRCODE = '22004';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.organization_memberships membership
    WHERE membership.organization_id = _organization_id
      AND membership.user_id = _uid
      AND membership.active = true
  ) THEN
    RAISE EXCEPTION 'Not a member of this organization' USING ERRCODE = '42501';
  END IF;
  IF pg_catalog.length(_raw_query) > 120 THEN
    RAISE EXCEPTION 'Search query cannot exceed 120 characters' USING ERRCODE = '22001';
  END IF;

  -- Phase 7F.1A: an organization uses a catalog vendor exactly when one of its active
  -- vendors is linked to it. Global listings of any other catalog vendor are never results.
  SELECT COALESCE(pg_catalog.array_agg(DISTINCT organization_vendor.catalog_vendor_id), ARRAY[]::uuid[])
  INTO _enabled_catalog_vendor_ids
  FROM public.vendors organization_vendor
  WHERE organization_vendor.organization_id = _organization_id
    AND organization_vendor.active = true
    AND organization_vendor.catalog_vendor_id IS NOT NULL;

  _normalized_text := public.catalog_search_text(_raw_query);
  IF pg_catalog.length(_normalized_text) < 2 THEN
    RETURN;
  END IF;
  _normalized_sku := public.normalize_catalog_sku(_raw_query);
  _sku_key := public.normalize_catalog_sku_match_key(_raw_query);
  _sku_partial := pg_catalog.length(_sku_key) >= 4 AND _sku_key ~ '[0-9]';

  SELECT pg_catalog.array_agg(token.value ORDER BY token.first_position)
  INTO _tokens
  FROM (
    SELECT split.value, pg_catalog.min(split.position) AS first_position
    FROM pg_catalog.regexp_split_to_table(_normalized_text, ' ') WITH ORDINALITY AS split(value, position)
    WHERE split.value <> ''
    GROUP BY split.value
  ) token;
  _tokens := _tokens[1:8];
  _patterns := ARRAY(SELECT public.catalog_search_token_pattern(token) FROM pg_catalog.unnest(_tokens) token);
  -- The whole query as one phrase, with the token rule's boundaries at both ends.
  _first_word := pg_catalog.split_part(_normalized_text, ' ', 1);
  _last_word := pg_catalog.regexp_replace(_normalized_text, '^.* ', '');
  _phrase_pattern :=
    CASE
      WHEN pg_catalog.length(_first_word) <= 2 THEN ' '
      WHEN _first_word ~ '^[0-9]' THEN '[^0-9/]'
      ELSE ''
    END
    || _normalized_text
    || CASE
         WHEN _last_word ~ '[0-9]$' THEN '[^0-9/]'
         WHEN pg_catalog.length(_last_word) = 1 THEN ' '
         ELSE ''
       END;

  -- Typo correction: only a letter-only word of 4+ letters that occurs nowhere in the
  -- searchable text of this organization and the global catalog.
  _fuzzy_patterns := _patterns;
  FOR _i IN 1 .. pg_catalog.cardinality(_tokens) LOOP
    _token := _tokens[_i];
    CONTINUE WHEN _token !~ '^[a-z]{4,40}$';
    -- A letter-only word "occurs" in the global catalog when it is part of a catalog word
    -- (the vocabulary holds every letter-only document word of 4+ letters). Checking the
    -- vocabulary keeps a missing word from scanning every document.
    CONTINUE WHEN EXISTS (
      SELECT 1 FROM public.catalog_search_terms terms
      WHERE pg_catalog.strpos(terms.term, _token) > 0
    );
    CONTINUE WHEN EXISTS (
      SELECT 1 FROM public.products organization_product
      WHERE organization_product.organization_id = _organization_id
        AND organization_product.active AND organization_product.staff_requestable
        AND (' ' || public.catalog_search_text(pg_catalog.concat_ws(' ',
              organization_product.name, organization_product.manufacturer, organization_product.description,
              organization_product.pack_size, organization_product.unit_of_measure)) || ' ') ~ _patterns[_i]
    );
    CONTINUE WHEN EXISTS (
      SELECT 1 FROM public.inventory_items inventory
      WHERE inventory.organization_id = _organization_id AND inventory.active
        AND (' ' || public.catalog_search_text(pg_catalog.concat_ws(' ',
              inventory.name, inventory.manufacturer, inventory.vendor_name, inventory.description,
              inventory.category, inventory.unit)) || ' ') ~ _patterns[_i]
    );
    CONTINUE WHEN EXISTS (
      SELECT 1 FROM public.product_aliases alias
      WHERE alias.organization_id = _organization_id
        AND (' ' || public.catalog_search_text(alias.alias) || ' ') ~ _patterns[_i]
    );

    _limit_edits := CASE WHEN pg_catalog.length(_token) >= 8 THEN 2 ELSE 1 END;
    SELECT pg_catalog.array_agg(candidate.term ORDER BY candidate.distance, candidate.term)
    INTO _corrections
    FROM (
      SELECT vocabulary.term,
        public.catalog_search_edit_distance(_token, vocabulary.term, _limit_edits) AS distance
      FROM (
        SELECT terms.term::text AS term
        FROM public.catalog_search_terms terms
        WHERE terms.term >= pg_catalog.left(_token, 1) COLLATE "C"
          AND terms.term < pg_catalog.chr(pg_catalog.ascii(pg_catalog.left(_token, 1)) + 1) COLLATE "C"
          AND pg_catalog.length(terms.term) BETWEEN pg_catalog.length(_token) - _limit_edits
                                                AND pg_catalog.length(_token) + _limit_edits
        UNION
        SELECT local_word.word
        FROM (
          SELECT pg_catalog.regexp_split_to_table(public.catalog_search_text(pg_catalog.concat_ws(' ',
                   organization_product.name, organization_product.manufacturer)), ' ') AS word
          FROM public.products organization_product
          WHERE organization_product.organization_id = _organization_id
            AND organization_product.active AND organization_product.staff_requestable
          UNION
          SELECT pg_catalog.regexp_split_to_table(public.catalog_search_text(pg_catalog.concat_ws(' ',
                   inventory.name, inventory.manufacturer)), ' ')
          FROM public.inventory_items inventory
          WHERE inventory.organization_id = _organization_id AND inventory.active
          UNION
          SELECT pg_catalog.regexp_split_to_table(public.catalog_search_text(alias.alias), ' ')
          FROM public.product_aliases alias
          WHERE alias.organization_id = _organization_id
        ) local_word
        WHERE local_word.word ~ '^[a-z]{4,40}$'
          AND pg_catalog.left(local_word.word, 1) = pg_catalog.left(_token, 1)
          AND pg_catalog.length(local_word.word) BETWEEN pg_catalog.length(_token) - _limit_edits
                                                     AND pg_catalog.length(_token) + _limit_edits
      ) vocabulary
      WHERE vocabulary.term <> _token
    ) candidate
    WHERE candidate.distance <= _limit_edits;

    IF COALESCE(pg_catalog.cardinality(_corrections), 0) > 0 THEN
      _corrections := _corrections[1:3];
      _fuzzy_patterns[_i] := '(' || pg_catalog.array_to_string(_corrections, '|') || ')';
      _corrected := true;
    END IF;
  END LOOP;

  -- Index probes: the (up to) four longest token patterns. Every token is still checked
  -- when the candidates are scored.
  _index_patterns := ARRAY(
    SELECT pattern.value
    FROM ROWS FROM (pg_catalog.unnest(_fuzzy_patterns), pg_catalog.unnest(_tokens)) WITH ORDINALITY AS pattern(value, token, position)
    ORDER BY pg_catalog.length(pattern.token) DESC, pattern.position
    LIMIT 4
  );
  _p1 := _index_patterns[1];
  _p2 := _index_patterns[2];
  _p3 := _index_patterns[3];
  _p4 := _index_patterns[4];

  RETURN QUERY
  WITH organization_aliases AS MATERIALIZED (
    SELECT alias.product_id,
      pg_catalog.string_agg(' ' || public.catalog_search_text(alias.alias) || ' ', '|'
        ORDER BY alias.normalized_alias) AS alias_text
    FROM public.product_aliases alias
    WHERE alias.organization_id = _organization_id
    GROUP BY alias.product_id
  ),
  organization_adoptions AS MATERIALIZED (
    SELECT
      organization_vendor_product.id AS vendor_product_id,
      organization_vendor_product.product_id,
      organization_vendor_product.catalog_vendor_product_id,
      organization_vendor_product.vendor_sku,
      organization_vendor_product.manufacturer_sku,
      organization_vendor_product.package_size,
      organization_vendor_product.unit_of_measure AS vendor_unit,
      organization_product.name AS product_name,
      organization_product.manufacturer,
      organization_product.description,
      organization_product.pack_size,
      organization_product.unit_of_measure,
      organization_vendor.name AS vendor_name,
      inventory.id AS inventory_item_id,
      ' ' || public.catalog_search_text(organization_product.name) || ' ' AS name_text,
      pg_catalog.array_remove(ARRAY[
        public.normalize_catalog_sku(organization_vendor_product.vendor_sku),
        public.normalize_catalog_sku(organization_vendor_product.manufacturer_sku)
      ], '') AS skus,
      pg_catalog.array_remove(ARRAY[
        public.normalize_catalog_sku_match_key(organization_vendor_product.vendor_sku),
        public.normalize_catalog_sku_match_key(organization_vendor_product.manufacturer_sku)
      ], '') AS sku_keys,
      public.catalog_search_text(pg_catalog.concat_ws(' ',
        organization_product.name,
        organization_product.manufacturer,
        organization_vendor.name,
        organization_product.description,
        organization_vendor_product.vendor_sku,
        organization_vendor_product.manufacturer_sku,
        organization_vendor_product.package_size,
        organization_product.pack_size,
        organization_product.unit_of_measure,
        organization_vendor_product.unit_of_measure)) || ' ' AS search_text
    FROM public.vendor_products organization_vendor_product
    JOIN public.products organization_product
      ON organization_product.id = organization_vendor_product.product_id
     AND organization_product.organization_id = organization_vendor_product.organization_id
     AND organization_product.active = true
     AND organization_product.staff_requestable = true
    JOIN public.vendors organization_vendor
      ON organization_vendor.id = organization_vendor_product.vendor_id
     AND organization_vendor.organization_id = organization_vendor_product.organization_id
     AND organization_vendor.active = true
    LEFT JOIN public.inventory_items inventory
      ON inventory.organization_id = organization_vendor_product.organization_id
     AND inventory.product_id = organization_vendor_product.product_id
     AND inventory.active = true
    WHERE organization_vendor_product.organization_id = _organization_id
      AND organization_vendor_product.active = true
      AND organization_vendor_product.catalog_vendor_product_id IS NOT NULL
  ),
  unscoped_global_hits AS (
    SELECT doc.catalog_vendor_product_id
    FROM public.catalog_vendor_product_search_documents doc
    WHERE doc.document ~ _p1
      AND (_p2 IS NULL OR doc.document ~ _p2)
      AND (_p3 IS NULL OR doc.document ~ _p3)
      AND (_p4 IS NULL OR doc.document ~ _p4)
    UNION
    -- Exact SKUs through the existing per-vendor unique and match-key indexes.
    SELECT catalog_vendor_product.id
    FROM public.catalog_vendors catalog_vendor
    JOIN public.catalog_vendor_products catalog_vendor_product
      ON catalog_vendor_product.catalog_vendor_id = catalog_vendor.id
     AND catalog_vendor_product.normalized_vendor_sku = _normalized_sku
    UNION
    SELECT catalog_vendor_product.id
    FROM public.catalog_vendors catalog_vendor
    JOIN public.catalog_vendor_products catalog_vendor_product
      ON catalog_vendor_product.catalog_vendor_id = catalog_vendor.id
     AND catalog_vendor_product.vendor_sku_match_key = _sku_key
    WHERE _sku_key <> ''
    UNION
    SELECT catalog_vendor_product.id
    FROM public.catalog_vendor_products catalog_vendor_product
    WHERE catalog_vendor_product.normalized_manufacturer_sku = _normalized_sku
    UNION
    SELECT doc.catalog_vendor_product_id
    FROM public.catalog_vendor_product_search_documents doc
    WHERE _sku_partial AND doc.document ~ pg_catalog.lower(_sku_key)
    UNION
    SELECT adoption.catalog_vendor_product_id FROM organization_adoptions adoption
  ),
  -- Phase 7F.1A: only listings of catalog vendors this organization uses. An organization
  -- that uses none never scans the global catalog.
  global_hits AS MATERIALIZED (
    SELECT hit.catalog_vendor_product_id
    FROM unscoped_global_hits hit
    JOIN public.catalog_vendor_products scoped_listing
      ON scoped_listing.id = hit.catalog_vendor_product_id
    WHERE pg_catalog.cardinality(_enabled_catalog_vendor_ids) > 0
      AND scoped_listing.catalog_vendor_id = ANY(_enabled_catalog_vendor_ids)
  ),
  global_candidates AS (
    SELECT
      CASE
        WHEN adoption.product_id IS NOT NULL
          THEN 'organization-product:' || adoption.product_id::text
        ELSE 'catalog-vendor-product:' || catalog_vendor_product.id::text
      END AS identity_key,
      CASE
        WHEN adoption.inventory_item_id IS NOT NULL THEN 'inventory'
        WHEN adoption.vendor_product_id IS NOT NULL THEN 'organization_catalog'
        ELSE 'global_catalog'
      END AS identity_source,
      COALESCE(adoption.product_name, catalog_product.name) AS product_name,
      COALESCE(adoption.manufacturer, catalog_product.manufacturer) AS manufacturer,
      COALESCE(adoption.vendor_name, catalog_vendor.name) AS vendor_name,
      catalog_vendor_product.vendor_sku,
      CASE catalog_vendor_product.package_status
        WHEN 'verified' THEN pg_catalog.concat_ws(
          ' ',
          catalog_vendor_product.package_quantity::text,
          catalog_vendor_product.package_unit
        )
        WHEN 'source_only' THEN COALESCE(
          catalog_vendor_product.package_description,
          'Source package text unavailable'
        )
        ELSE 'Unknown'
      END AS package_display,
      catalog_vendor_product.package_status,
      adoption.inventory_item_id,
      adoption.product_id,
      adoption.vendor_product_id,
      catalog_vendor_product.id AS catalog_vendor_product_id,
      COALESCE(adoption.description, catalog_product.description) AS description,
      COALESCE(adoption.unit_of_measure, adoption.vendor_unit) AS unit,
      COALESCE(NULLIF(pg_catalog.btrim(adoption.package_size), ''), NULLIF(pg_catalog.btrim(adoption.pack_size), '')) AS pack_size,
      COALESCE(adoption.skus, ARRAY[]::text[]) AS organization_skus,
      COALESCE(adoption.sku_keys, ARRAY[]::text[]) AS organization_sku_keys,
      doc.sku_values AS global_skus,
      doc.sku_keys AS global_sku_keys,
      CASE WHEN adoption.name_text IS NULL THEN ARRAY[doc.name_text]
           ELSE ARRAY[adoption.name_text, doc.name_text] END AS names,
      organization_alias.alias_text,
      doc.document
        || COALESCE(adoption.search_text, '')
        || COALESCE(pg_catalog.replace(organization_alias.alias_text, '|', ''), '') AS search_text,
      CASE
        WHEN adoption.inventory_item_id IS NOT NULL THEN 0
        WHEN adoption.vendor_product_id IS NOT NULL THEN 1
        ELSE 3
      END AS source_priority
    FROM global_hits hit
    JOIN public.catalog_vendor_products catalog_vendor_product
      ON catalog_vendor_product.id = hit.catalog_vendor_product_id
     AND catalog_vendor_product.active = true
     AND catalog_vendor_product.discontinued = false
    JOIN public.catalog_vendor_product_search_documents doc
      ON doc.catalog_vendor_product_id = catalog_vendor_product.id
    JOIN public.catalog_products catalog_product
      ON catalog_product.id = catalog_vendor_product.catalog_product_id
     AND catalog_product.active = true
    JOIN public.catalog_vendors catalog_vendor
      ON catalog_vendor.id = catalog_vendor_product.catalog_vendor_id
     AND catalog_vendor.active = true
    LEFT JOIN organization_adoptions adoption
      ON adoption.catalog_vendor_product_id = catalog_vendor_product.id
    LEFT JOIN organization_aliases organization_alias
      ON organization_alias.product_id = adoption.product_id
  ),
  local_vendor_candidates AS (
    SELECT
      'organization-product:' || organization_product.id::text AS identity_key,
      CASE WHEN inventory.id IS NOT NULL THEN 'inventory' ELSE 'organization_catalog' END AS identity_source,
      organization_product.name AS product_name,
      organization_product.manufacturer,
      organization_vendor.name AS vendor_name,
      organization_vendor_product.vendor_sku,
      'Unknown'::text AS package_display,
      'unknown'::text AS package_status,
      inventory.id AS inventory_item_id,
      organization_product.id AS product_id,
      organization_vendor_product.id AS vendor_product_id,
      NULL::uuid AS catalog_vendor_product_id,
      organization_product.description,
      COALESCE(organization_product.unit_of_measure, organization_vendor_product.unit_of_measure) AS unit,
      COALESCE(NULLIF(pg_catalog.btrim(organization_vendor_product.package_size), ''), NULLIF(pg_catalog.btrim(organization_product.pack_size), '')) AS pack_size,
      pg_catalog.array_remove(ARRAY[
        public.normalize_catalog_sku(organization_vendor_product.vendor_sku),
        public.normalize_catalog_sku(organization_vendor_product.manufacturer_sku)
      ], '') AS organization_skus,
      pg_catalog.array_remove(ARRAY[
        public.normalize_catalog_sku_match_key(organization_vendor_product.vendor_sku),
        public.normalize_catalog_sku_match_key(organization_vendor_product.manufacturer_sku)
      ], '') AS organization_sku_keys,
      ARRAY[]::text[] AS global_skus,
      ARRAY[]::text[] AS global_sku_keys,
      ARRAY[' ' || public.catalog_search_text(organization_product.name) || ' '] AS names,
      organization_alias.alias_text,
      ' ' || public.catalog_search_text(pg_catalog.concat_ws(' ',
        organization_product.name,
        organization_product.manufacturer,
        organization_product.description,
        organization_product.pack_size,
        organization_product.vendor_item_number,
        organization_product.internal_item_code,
        organization_product.unit_of_measure,
        organization_vendor.name,
        organization_vendor_product.vendor_sku,
        organization_vendor_product.manufacturer_sku,
        organization_vendor_product.package_size,
        organization_vendor_product.unit_of_measure)) || ' '
        || COALESCE(pg_catalog.replace(organization_alias.alias_text, '|', ''), '') AS search_text,
      CASE WHEN inventory.id IS NOT NULL THEN 0 ELSE 1 END AS source_priority
    FROM public.vendor_products organization_vendor_product
    JOIN public.products organization_product
      ON organization_product.id = organization_vendor_product.product_id
     AND organization_product.organization_id = organization_vendor_product.organization_id
     AND organization_product.active = true
     AND organization_product.staff_requestable = true
    JOIN public.vendors organization_vendor
      ON organization_vendor.id = organization_vendor_product.vendor_id
     AND organization_vendor.organization_id = organization_vendor_product.organization_id
     AND organization_vendor.active = true
    LEFT JOIN public.inventory_items inventory
      ON inventory.organization_id = organization_product.organization_id
     AND inventory.product_id = organization_product.id
     AND inventory.active = true
    LEFT JOIN organization_aliases organization_alias
      ON organization_alias.product_id = organization_product.id
    WHERE organization_vendor_product.organization_id = _organization_id
      AND organization_vendor_product.active = true
      AND organization_vendor_product.catalog_vendor_product_id IS NULL
  ),
  local_product_candidates AS (
    SELECT
      'organization-product:' || organization_product.id::text AS identity_key,
      CASE WHEN inventory.id IS NOT NULL THEN 'inventory' ELSE 'organization_product' END AS identity_source,
      organization_product.name AS product_name,
      organization_product.manufacturer,
      NULL::text AS vendor_name,
      NULL::text AS vendor_sku,
      'Unknown'::text AS package_display,
      'unknown'::text AS package_status,
      inventory.id AS inventory_item_id,
      organization_product.id AS product_id,
      NULL::uuid AS vendor_product_id,
      NULL::uuid AS catalog_vendor_product_id,
      organization_product.description,
      organization_product.unit_of_measure AS unit,
      NULLIF(pg_catalog.btrim(organization_product.pack_size), '') AS pack_size,
      pg_catalog.array_remove(ARRAY[
        public.normalize_catalog_sku(organization_product.vendor_item_number),
        public.normalize_catalog_sku(organization_product.internal_item_code)
      ], '') AS organization_skus,
      pg_catalog.array_remove(ARRAY[
        public.normalize_catalog_sku_match_key(organization_product.vendor_item_number),
        public.normalize_catalog_sku_match_key(organization_product.internal_item_code)
      ], '') AS organization_sku_keys,
      ARRAY[]::text[] AS global_skus,
      ARRAY[]::text[] AS global_sku_keys,
      ARRAY[' ' || public.catalog_search_text(organization_product.name) || ' '] AS names,
      organization_alias.alias_text,
      ' ' || public.catalog_search_text(pg_catalog.concat_ws(' ',
        organization_product.name,
        organization_product.manufacturer,
        organization_product.description,
        organization_product.pack_size,
        organization_product.vendor_item_number,
        organization_product.internal_item_code,
        organization_product.unit_of_measure)) || ' '
        || COALESCE(pg_catalog.replace(organization_alias.alias_text, '|', ''), '') AS search_text,
      CASE WHEN inventory.id IS NOT NULL THEN 0 ELSE 2 END AS source_priority
    FROM public.products organization_product
    LEFT JOIN public.inventory_items inventory
      ON inventory.organization_id = organization_product.organization_id
     AND inventory.product_id = organization_product.id
     AND inventory.active = true
    LEFT JOIN organization_aliases organization_alias
      ON organization_alias.product_id = organization_product.id
    WHERE organization_product.organization_id = _organization_id
      AND organization_product.active = true
      AND organization_product.staff_requestable = true
  ),
  unlinked_inventory_candidates AS (
    SELECT
      'inventory:' || inventory.id::text AS identity_key,
      'inventory'::text AS identity_source,
      inventory.name AS product_name,
      inventory.manufacturer,
      inventory.vendor_name,
      inventory.sku AS vendor_sku,
      'Unknown'::text AS package_display,
      'unknown'::text AS package_status,
      inventory.id AS inventory_item_id,
      NULL::uuid AS product_id,
      NULL::uuid AS vendor_product_id,
      NULL::uuid AS catalog_vendor_product_id,
      inventory.description,
      inventory.unit,
      NULL::text AS pack_size,
      pg_catalog.array_remove(ARRAY[public.normalize_catalog_sku(inventory.sku)], '') AS organization_skus,
      pg_catalog.array_remove(ARRAY[public.normalize_catalog_sku_match_key(inventory.sku)], '') AS organization_sku_keys,
      ARRAY[]::text[] AS global_skus,
      ARRAY[]::text[] AS global_sku_keys,
      ARRAY[' ' || public.catalog_search_text(inventory.name) || ' '] AS names,
      NULL::text AS alias_text,
      ' ' || public.catalog_search_text(pg_catalog.concat_ws(' ',
        inventory.name,
        inventory.manufacturer,
        inventory.vendor_name,
        inventory.sku,
        inventory.description,
        inventory.category,
        inventory.unit)) || ' ' AS search_text,
      0 AS source_priority
    FROM public.inventory_items inventory
    WHERE inventory.organization_id = _organization_id
      AND inventory.active = true
      AND inventory.product_id IS NULL
  ),
  candidates AS (
    SELECT * FROM global_candidates
    UNION ALL
    SELECT * FROM local_vendor_candidates
    UNION ALL
    SELECT * FROM local_product_candidates
    UNION ALL
    SELECT * FROM unlinked_inventory_candidates
  ),
  scored AS MATERIALIZED (
    SELECT
      candidate.*,
      CASE
        WHEN _normalized_sku = ANY(candidate.organization_skus)
             OR (pg_catalog.length(_sku_key) >= 3 AND _sku_key = ANY(candidate.organization_sku_keys)) THEN 0
        WHEN _normalized_sku = ANY(candidate.global_skus)
             OR (pg_catalog.length(_sku_key) >= 3 AND _sku_key = ANY(candidate.global_sku_keys)) THEN 1
        WHEN EXISTS (SELECT 1 FROM pg_catalog.unnest(candidate.names) name WHERE name = ' ' || _normalized_text || ' ')
             OR pg_catalog.strpos('|' || COALESCE(candidate.alias_text, '') || '|', '| ' || _normalized_text || ' |') > 0 THEN 2
        WHEN _sku_partial AND EXISTS (
               SELECT 1 FROM pg_catalog.unnest(candidate.organization_sku_keys || candidate.global_sku_keys) sku_key
               WHERE pg_catalog.strpos(sku_key, _sku_key) > 0
             ) THEN 3
        WHEN EXISTS (SELECT 1 FROM pg_catalog.unnest(candidate.names) name WHERE name ~ _phrase_pattern)
             OR COALESCE(candidate.alias_text, '') ~ _phrase_pattern THEN 4
        WHEN EXISTS (
               SELECT 1 FROM pg_catalog.unnest(candidate.names || COALESCE(pg_catalog.string_to_array(candidate.alias_text, '|'), ARRAY[]::text[])) name
               WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.unnest(_patterns) pattern WHERE name !~ pattern)
             ) THEN 5
        WHEN NOT EXISTS (SELECT 1 FROM pg_catalog.unnest(_patterns) pattern WHERE candidate.search_text !~ pattern) THEN 6
        WHEN _corrected
             AND NOT EXISTS (SELECT 1 FROM pg_catalog.unnest(_fuzzy_patterns) pattern WHERE candidate.search_text !~ pattern) THEN 7
        ELSE 99
      END AS match_rank
    FROM candidates candidate
  ),
  deduplicated AS MATERIALIZED (
    SELECT
      scored.*,
      pg_catalog.row_number() OVER (
        PARTITION BY scored.identity_key
        ORDER BY
          scored.match_rank,
          scored.source_priority,
          scored.catalog_vendor_product_id NULLS LAST,
          scored.vendor_product_id NULLS LAST,
          scored.inventory_item_id NULLS LAST,
          pg_catalog.lower(scored.product_name),
          COALESCE(scored.vendor_sku, ''),
          scored.identity_key
      ) AS identity_rank
    FROM scored
    WHERE scored.match_rank < 99
  ),
  matched AS MATERIALIZED (
    SELECT * FROM deduplicated WHERE deduplicated.identity_rank = 1
  ),
  history AS MATERIALIZED (
    SELECT * FROM public.supply_request_product_history(_organization_id)
  ),
  signal_links AS (
    SELECT matched.identity_key, history.signal, history.event_id, history.event_at
    FROM matched JOIN history ON history.product_id = matched.product_id
    UNION
    SELECT matched.identity_key, history.signal, history.event_id, history.event_at
    FROM matched JOIN history ON history.catalog_vendor_product_id = matched.catalog_vendor_product_id
    UNION
    SELECT matched.identity_key, history.signal, history.event_id, history.event_at
    FROM matched JOIN history ON history.inventory_item_id = matched.inventory_item_id
  ),
  signals AS (
    SELECT signal_links.identity_key,
      pg_catalog.count(DISTINCT signal_links.event_id) FILTER (WHERE signal_links.signal = 'approved')::integer AS approved_count,
      pg_catalog.max(signal_links.event_at) FILTER (WHERE signal_links.signal = 'approved') AS last_approved,
      pg_catalog.count(DISTINCT signal_links.event_id) FILTER (WHERE signal_links.signal = 'purchased')::integer AS purchase_count,
      pg_catalog.max(signal_links.event_at) FILTER (WHERE signal_links.signal = 'purchased') AS last_purchased
    FROM signal_links
    GROUP BY signal_links.identity_key
  ),
  saved AS (
    SELECT DISTINCT matched.identity_key
    FROM matched
    JOIN public.staff_saved_products saved_product
      ON saved_product.organization_id = _organization_id
     AND saved_product.user_id = _uid
     AND (saved_product.product_id = matched.product_id
          OR saved_product.catalog_vendor_product_id = matched.catalog_vendor_product_id
          OR saved_product.inventory_item_id = matched.inventory_item_id)
  )
  SELECT
    matched.identity_key,
    matched.identity_source,
    matched.product_name,
    matched.manufacturer,
    matched.vendor_name,
    matched.vendor_sku,
    matched.package_display,
    matched.package_status,
    matched.inventory_item_id,
    matched.product_id,
    matched.vendor_product_id,
    matched.catalog_vendor_product_id,
    CASE
      -- A short description is the variant (size, color, sterility); one the name already
      -- says is not repeated.
      WHEN pg_catalog.length(pg_catalog.btrim(matched.description)) BETWEEN 1 AND 80
       AND pg_catalog.strpos(' ' || public.catalog_search_text(matched.product_name) || ' ',
                             ' ' || public.catalog_search_text(matched.description) || ' ') = 0
        THEN pg_catalog.btrim(matched.description)
    END,
    NULLIF(pg_catalog.btrim(matched.unit), ''),
    matched.pack_size,
    matched.match_rank,
    saved.identity_key IS NOT NULL,
    COALESCE(signals.approved_count, 0),
    signals.last_approved,
    COALESCE(signals.purchase_count, 0),
    signals.last_purchased
  FROM matched
  LEFT JOIN signals ON signals.identity_key = matched.identity_key
  LEFT JOIN saved ON saved.identity_key = matched.identity_key
  ORDER BY
    matched.match_rank,
    (saved.identity_key IS NOT NULL) DESC,
    COALESCE(signals.approved_count, 0) DESC,
    COALESCE(signals.purchase_count, 0) DESC,
    matched.source_priority,
    GREATEST(signals.last_approved, signals.last_purchased) DESC NULLS LAST,
    pg_catalog.lower(matched.product_name),
    COALESCE(matched.vendor_name, ''),
    COALESCE(matched.vendor_sku, ''),
    matched.identity_key
  LIMIT _bounded_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.supply_request_product_search(uuid, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.supply_request_product_search(uuid, text, integer) FROM anon, authenticated;

COMMENT ON FUNCTION public.supply_request_product_search(uuid, text, integer) IS
  'Phase 5A.10 internal search: deterministic relevance tiers first, then Saved and organization history inside a tier. Phase 7F.1A: global listings only of catalog vendors the organization uses (an active linked organization vendor).';

CREATE OR REPLACE FUNCTION public.supply_request_product_identities(
  _organization_id uuid,
  _product_ids uuid[],
  _catalog_vendor_product_ids uuid[],
  _inventory_item_ids uuid[]
)
RETURNS TABLE (
  result_key text,
  identity_source text,
  product_name text,
  manufacturer text,
  vendor_name text,
  vendor_sku text,
  package_display text,
  package_status text,
  inventory_item_id uuid,
  product_id uuid,
  vendor_product_id uuid,
  catalog_vendor_product_id uuid,
  variant_detail text,
  unit text,
  pack_size text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH requested_catalog AS (
    -- A catalog identity is shown through its organization product once adopted.
    SELECT catalog_vendor_product_id FROM pg_catalog.unnest(COALESCE(_catalog_vendor_product_ids, ARRAY[]::uuid[])) catalog_vendor_product_id
    UNION
    SELECT vendor_product.catalog_vendor_product_id
    FROM public.vendor_products vendor_product
    WHERE vendor_product.organization_id = _organization_id
      AND vendor_product.active = true
      AND vendor_product.product_id = ANY(COALESCE(_product_ids, ARRAY[]::uuid[]))
      AND vendor_product.catalog_vendor_product_id IS NOT NULL
  ),
  adoptions AS (
    SELECT
      organization_vendor_product.id AS vendor_product_id,
      organization_vendor_product.product_id,
      organization_vendor_product.catalog_vendor_product_id,
      organization_vendor_product.package_size,
      organization_vendor_product.unit_of_measure AS vendor_unit,
      organization_product.name AS product_name,
      organization_product.manufacturer,
      organization_product.description,
      organization_product.pack_size,
      organization_product.unit_of_measure,
      organization_vendor.name AS vendor_name,
      inventory.id AS inventory_item_id
    FROM public.vendor_products organization_vendor_product
    JOIN public.products organization_product
      ON organization_product.id = organization_vendor_product.product_id
     AND organization_product.organization_id = organization_vendor_product.organization_id
     AND organization_product.active = true
     AND organization_product.staff_requestable = true
    JOIN public.vendors organization_vendor
      ON organization_vendor.id = organization_vendor_product.vendor_id
     AND organization_vendor.organization_id = organization_vendor_product.organization_id
     AND organization_vendor.active = true
    LEFT JOIN public.inventory_items inventory
      ON inventory.organization_id = organization_vendor_product.organization_id
     AND inventory.product_id = organization_vendor_product.product_id
     AND inventory.active = true
    WHERE organization_vendor_product.organization_id = _organization_id
      AND organization_vendor_product.active = true
      AND organization_vendor_product.catalog_vendor_product_id IN (SELECT catalog_vendor_product_id FROM requested_catalog)
  ),
  candidates AS (
    SELECT
      CASE WHEN adoption.product_id IS NOT NULL
        THEN 'organization-product:' || adoption.product_id::text
        ELSE 'catalog-vendor-product:' || catalog_vendor_product.id::text END AS identity_key,
      CASE
        WHEN adoption.inventory_item_id IS NOT NULL THEN 'inventory'
        WHEN adoption.vendor_product_id IS NOT NULL THEN 'organization_catalog'
        ELSE 'global_catalog'
      END AS identity_source,
      COALESCE(adoption.product_name, catalog_product.name) AS product_name,
      COALESCE(adoption.manufacturer, catalog_product.manufacturer) AS manufacturer,
      COALESCE(adoption.vendor_name, catalog_vendor.name) AS vendor_name,
      catalog_vendor_product.vendor_sku,
      CASE catalog_vendor_product.package_status
        WHEN 'verified' THEN pg_catalog.concat_ws(' ', catalog_vendor_product.package_quantity::text, catalog_vendor_product.package_unit)
        WHEN 'source_only' THEN COALESCE(catalog_vendor_product.package_description, 'Source package text unavailable')
        ELSE 'Unknown'
      END AS package_display,
      catalog_vendor_product.package_status,
      adoption.inventory_item_id,
      adoption.product_id,
      adoption.vendor_product_id,
      catalog_vendor_product.id AS catalog_vendor_product_id,
      COALESCE(adoption.description, catalog_product.description) AS description,
      COALESCE(adoption.unit_of_measure, adoption.vendor_unit) AS unit,
      COALESCE(NULLIF(pg_catalog.btrim(adoption.package_size), ''), NULLIF(pg_catalog.btrim(adoption.pack_size), '')) AS pack_size,
      CASE
        WHEN adoption.inventory_item_id IS NOT NULL THEN 0
        WHEN adoption.vendor_product_id IS NOT NULL THEN 1
        ELSE 3
      END AS source_priority
    FROM requested_catalog requested
    JOIN public.catalog_vendor_products catalog_vendor_product
      ON catalog_vendor_product.id = requested.catalog_vendor_product_id
     AND catalog_vendor_product.active = true
     AND catalog_vendor_product.discontinued = false
    JOIN public.catalog_products catalog_product
      ON catalog_product.id = catalog_vendor_product.catalog_product_id
     AND catalog_product.active = true
    JOIN public.catalog_vendors catalog_vendor
      ON catalog_vendor.id = catalog_vendor_product.catalog_vendor_id
     AND catalog_vendor.active = true
     -- Phase 7F.1A: only catalog vendors this organization uses.
     AND EXISTS (
       SELECT 1 FROM public.vendors organization_vendor
       WHERE organization_vendor.organization_id = _organization_id
         AND organization_vendor.active = true
         AND organization_vendor.catalog_vendor_id = catalog_vendor.id
     )
    LEFT JOIN adoptions adoption
      ON adoption.catalog_vendor_product_id = catalog_vendor_product.id
    UNION ALL
    SELECT
      'organization-product:' || organization_product.id::text,
      CASE WHEN inventory.id IS NOT NULL THEN 'inventory'
           WHEN organization_vendor_product.id IS NOT NULL THEN 'organization_catalog'
           ELSE 'organization_product' END,
      organization_product.name,
      organization_product.manufacturer,
      organization_vendor.name,
      organization_vendor_product.vendor_sku,
      'Unknown'::text,
      'unknown'::text,
      inventory.id,
      organization_product.id,
      organization_vendor_product.id,
      NULL::uuid,
      organization_product.description,
      COALESCE(organization_product.unit_of_measure, organization_vendor_product.unit_of_measure),
      COALESCE(NULLIF(pg_catalog.btrim(organization_vendor_product.package_size), ''), NULLIF(pg_catalog.btrim(organization_product.pack_size), '')),
      CASE WHEN inventory.id IS NOT NULL THEN 0
           WHEN organization_vendor_product.id IS NOT NULL THEN 1
           ELSE 2 END
    FROM public.products organization_product
    LEFT JOIN public.vendor_products organization_vendor_product
      ON organization_vendor_product.organization_id = organization_product.organization_id
     AND organization_vendor_product.product_id = organization_product.id
     AND organization_vendor_product.active = true
     AND organization_vendor_product.catalog_vendor_product_id IS NULL
     AND EXISTS (
       SELECT 1 FROM public.vendors organization_vendor_check
       WHERE organization_vendor_check.id = organization_vendor_product.vendor_id
         AND organization_vendor_check.organization_id = organization_vendor_product.organization_id
         AND organization_vendor_check.active = true
     )
    LEFT JOIN public.vendors organization_vendor
      ON organization_vendor.id = organization_vendor_product.vendor_id
     AND organization_vendor.organization_id = organization_vendor_product.organization_id
    LEFT JOIN public.inventory_items inventory
      ON inventory.organization_id = organization_product.organization_id
     AND inventory.product_id = organization_product.id
     AND inventory.active = true
    WHERE organization_product.organization_id = _organization_id
      AND organization_product.active = true
      AND organization_product.staff_requestable = true
      AND (
        organization_product.id = ANY(COALESCE(_product_ids, ARRAY[]::uuid[]))
        OR inventory.id = ANY(COALESCE(_inventory_item_ids, ARRAY[]::uuid[]))
      )
    UNION ALL
    SELECT
      'inventory:' || inventory.id::text,
      'inventory'::text,
      inventory.name,
      inventory.manufacturer,
      inventory.vendor_name,
      inventory.sku,
      'Unknown'::text,
      'unknown'::text,
      inventory.id,
      NULL::uuid,
      NULL::uuid,
      NULL::uuid,
      inventory.description,
      inventory.unit,
      NULL::text,
      0
    FROM public.inventory_items inventory
    WHERE inventory.organization_id = _organization_id
      AND inventory.active = true
      AND inventory.product_id IS NULL
      AND inventory.id = ANY(COALESCE(_inventory_item_ids, ARRAY[]::uuid[]))
  ),
  ranked AS (
    SELECT candidates.*,
      pg_catalog.row_number() OVER (
        PARTITION BY candidates.identity_key
        ORDER BY candidates.source_priority,
          candidates.catalog_vendor_product_id NULLS LAST,
          candidates.vendor_product_id NULLS LAST,
          candidates.inventory_item_id NULLS LAST,
          COALESCE(candidates.vendor_sku, '')
      ) AS identity_rank
    FROM candidates
  )
  SELECT ranked.identity_key, ranked.identity_source, ranked.product_name, ranked.manufacturer,
    ranked.vendor_name, ranked.vendor_sku, ranked.package_display, ranked.package_status,
    ranked.inventory_item_id, ranked.product_id, ranked.vendor_product_id,
    ranked.catalog_vendor_product_id,
    CASE
      -- A short description is the variant (size, color, sterility); one the name already
      -- says is not repeated.
      WHEN pg_catalog.length(pg_catalog.btrim(ranked.description)) BETWEEN 1 AND 80
       AND pg_catalog.strpos(' ' || public.catalog_search_text(ranked.product_name) || ' ',
                             ' ' || public.catalog_search_text(ranked.description) || ' ') = 0
        THEN pg_catalog.btrim(ranked.description)
    END,
    NULLIF(pg_catalog.btrim(ranked.unit), ''),
    ranked.pack_size
  FROM ranked
  WHERE ranked.identity_rank = 1;
$$;

REVOKE ALL ON FUNCTION public.supply_request_product_identities(uuid, uuid[], uuid[], uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.supply_request_product_identities(uuid, uuid[], uuid[], uuid[]) FROM anon, authenticated;

COMMENT ON FUNCTION public.supply_request_product_identities(uuid, uuid[], uuid[], uuid[]) IS
  'Phase 5A.10 discovery identity resolution under the eligibility rules of search. Phase 7F.1A: global listings only of catalog vendors the organization uses.';

COMMIT;
