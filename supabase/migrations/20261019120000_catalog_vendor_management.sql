-- Beta hardening: explicit organization-vendor catalog linking and catalog coverage.
--
-- Phase 6C.1 reaches the global catalog only through vendors.catalog_vendor_id and refuses
-- to infer that link. Until now there was no deliberate way to set it, and an owner/admin
-- could PATCH the column directly through the API with no checks beyond the Phase 5A.5
-- adoption-consistency trigger. This migration adds:
--
--   * guard_vendor_catalog_link (trigger): API-role writes (authenticated/anon) can no longer
--     set or change vendors.catalog_vendor_id directly, and no caller may repoint an existing
--     non-null link to a different catalog vendor in one write. SECURITY DEFINER RPCs run as
--     the function owner, so Phase 5A.5 adoption keeps its existing NULL -> vendor behavior.
--   * link_organization_vendor_to_catalog_vendor (owner/admin RPC): NULL -> one explicitly
--     chosen, existing, active catalog vendor, with a stale-write token. It never matches
--     names, never creates catalog vendors, and refuses an already-linked vendor unless the
--     request names the same catalog vendor (idempotent no-op).
--   * get_organization_vendor_catalog_coverage (owner/admin, SECURITY INVOKER, read-only):
--     classifies the organization's own vendor SKU mappings for one linked vendor against
--     that catalog vendor's listings, using the Phase 5A.4A SKU keys.
--
-- Nothing here writes to any catalog_* table. Global catalog promotion is intentionally not
-- implemented: catalog writes remain service-role only because no platform catalog-admin
-- permission exists yet (see 20260824120000_phase5a4a_global_catalog_schema.sql).
--
-- No table, column, index, or constraint is changed and no data is modified.
-- Rollback: DROP FUNCTION public.get_organization_vendor_catalog_coverage(uuid, uuid);
--           DROP FUNCTION public.link_organization_vendor_to_catalog_vendor(uuid, uuid, uuid, timestamptz);
--           DROP TRIGGER vendors_guard_catalog_link ON public.vendors;
--           DROP FUNCTION public.guard_vendor_catalog_link();

BEGIN;

DO $catalog_vendor_management_preflight$
BEGIN
  IF to_regprocedure('public.adopt_catalog_vendor_product(uuid, uuid)') IS NULL
     OR to_regprocedure('public.find_invoice_line_exact_identity(uuid, uuid, text)') IS NULL
     OR to_regprocedure('public.normalize_catalog_sku_match_key(text)') IS NULL THEN
    RAISE EXCEPTION 'Catalog vendor management requires Phase 5A.5 adoption and Phase 6C.1 identity functions';
  END IF;
  IF to_regprocedure('public.link_organization_vendor_to_catalog_vendor(uuid, uuid, uuid, timestamptz)') IS NOT NULL THEN
    RAISE EXCEPTION 'Catalog vendor management has already been applied';
  END IF;
END
$catalog_vendor_management_preflight$;

-- Like the Phase 6C.1 provenance guard, the first rule acts only on API-role writes.
-- The second rule applies to every caller: a link that already names a catalog vendor
-- decides which listings invoices resolve against, so it is never swapped in place.
CREATE FUNCTION public.guard_vendor_catalog_link()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF current_user IN ('authenticated', 'anon') AND (
    (TG_OP = 'INSERT' AND NEW.catalog_vendor_id IS NOT NULL)
    OR (TG_OP = 'UPDATE' AND NEW.catalog_vendor_id IS DISTINCT FROM OLD.catalog_vendor_id)
  ) THEN
    RAISE EXCEPTION 'Catalog vendor links can only be set through catalog vendor management'
      USING ERRCODE = '42501';
  END IF;

  IF TG_OP = 'UPDATE'
     AND OLD.catalog_vendor_id IS NOT NULL
     AND NEW.catalog_vendor_id IS NOT NULL
     AND NEW.catalog_vendor_id <> OLD.catalog_vendor_id THEN
    RAISE EXCEPTION 'An existing catalog vendor link cannot be repointed to a different catalog vendor'
      USING ERRCODE = '55000';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.guard_vendor_catalog_link() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER vendors_guard_catalog_link
  BEFORE INSERT OR UPDATE OF catalog_vendor_id ON public.vendors
  FOR EACH ROW EXECUTE FUNCTION public.guard_vendor_catalog_link();

-- Establishes NULL -> catalog vendor only. The caller names both rows by id; nothing is
-- inferred from names. _expected_updated_at is the vendor row's updated_at as loaded, so a
-- vendor renamed, archived, or linked by someone else since then is refused.
CREATE FUNCTION public.link_organization_vendor_to_catalog_vendor(
  _organization_id uuid,
  _vendor_id uuid,
  _catalog_vendor_id uuid,
  _expected_updated_at timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _vendor public.vendors%ROWTYPE;
  _catalog_vendor public.catalog_vendors%ROWTYPE;
BEGIN
  IF _organization_id IS NULL OR _vendor_id IS NULL OR _catalog_vendor_id IS NULL
     OR _expected_updated_at IS NULL THEN
    RAISE EXCEPTION 'organization, vendor, catalog vendor, and expected version are required'
      USING ERRCODE = '22004';
  END IF;

  IF auth.uid() IS NULL OR NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Only organization owners and admins can link catalog vendors'
      USING ERRCODE = '42501';
  END IF;

  -- Same lock as adopt_catalog_vendor_product, which can also link a vendor.
  PERFORM pg_advisory_xact_lock(
    hashtextextended('catalog-adoption:' || _organization_id::text, 0)
  );

  SELECT * INTO _vendor
  FROM public.vendors
  WHERE id = _vendor_id AND organization_id = _organization_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Organization vendor not found' USING ERRCODE = 'P0002';
  END IF;

  SELECT * INTO _catalog_vendor
  FROM public.catalog_vendors
  WHERE id = _catalog_vendor_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Catalog vendor not found' USING ERRCODE = 'P0002';
  END IF;

  IF _vendor.catalog_vendor_id = _catalog_vendor.id THEN
    RETURN jsonb_build_object(
      'organizationId', _organization_id,
      'vendorId', _vendor.id,
      'catalogVendorId', _catalog_vendor.id,
      'catalogVendorName', _catalog_vendor.name,
      'alreadyLinked', true,
      'updatedAt', _vendor.updated_at
    );
  END IF;

  IF _vendor.catalog_vendor_id IS NOT NULL THEN
    RAISE EXCEPTION 'Organization vendor is already linked to a different catalog vendor'
      USING ERRCODE = '55000';
  END IF;

  IF _vendor.updated_at IS DISTINCT FROM _expected_updated_at THEN
    RAISE EXCEPTION 'Organization vendor changed since it was loaded'
      USING ERRCODE = '40001';
  END IF;

  IF NOT _catalog_vendor.active THEN
    RAISE EXCEPTION 'Catalog vendor is inactive' USING ERRCODE = '55000';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.vendors other
    WHERE other.organization_id = _organization_id
      AND other.catalog_vendor_id = _catalog_vendor.id
      AND other.id <> _vendor.id
  ) THEN
    RAISE EXCEPTION 'Another organization vendor is already linked to this catalog vendor'
      USING ERRCODE = '23505';
  END IF;

  UPDATE public.vendors
  SET catalog_vendor_id = _catalog_vendor.id
  WHERE id = _vendor.id AND organization_id = _organization_id
  RETURNING * INTO _vendor;

  RETURN jsonb_build_object(
    'organizationId', _organization_id,
    'vendorId', _vendor.id,
    'catalogVendorId', _catalog_vendor.id,
    'catalogVendorName', _catalog_vendor.name,
    'alreadyLinked', false,
    'updatedAt', _vendor.updated_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.link_organization_vendor_to_catalog_vendor(uuid, uuid, uuid, timestamptz)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.link_organization_vendor_to_catalog_vendor(uuid, uuid, uuid, timestamptz)
  TO authenticated;

COMMENT ON FUNCTION public.link_organization_vendor_to_catalog_vendor(uuid, uuid, uuid, timestamptz) IS
  'Owner/admin only. Links an unlinked organization vendor to one explicitly chosen, active catalog vendor. Never infers by name, never repoints an existing link, never writes catalog data.';

-- Read-only. Runs with the caller's privileges, so vendor_products/products RLS (owner/admin
-- of that organization) applies in addition to the explicit checks.
--
-- Each of the organization's mappings for the vendor is classified against the linked
-- catalog vendor only:
--   linked                -> the mapping already points at a listing (catalog adoption)
--   exact                 -> a listing has the same normalize_catalog_sku value
--   separator_equivalent  -> exactly one listing has the same separator-free match key
--   ambiguous             -> several listings share that match key
--   not_cataloged         -> none of the above
-- Separator equivalence is checked in both directions here (unlike 6C.1 auto-resolution,
-- which only falls back for bare invoice SKUs) because "represented" must be conservative:
-- a separator variant of a listed SKU is not new catalog coverage. Descriptions,
-- manufacturers, and package text never decide the status. Listing state (inactive,
-- discontinued, unverified, rejected) does not change the status; it is reported as is.
-- Summary counts cover active mappings; inactive ("forgotten") mappings are counted apart.
CREATE FUNCTION public.get_organization_vendor_catalog_coverage(
  _organization_id uuid,
  _vendor_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  _vendor public.vendors%ROWTYPE;
  _catalog_vendor public.catalog_vendors%ROWTYPE;
  _result jsonb;
BEGIN
  IF _organization_id IS NULL OR _vendor_id IS NULL THEN
    RAISE EXCEPTION 'organization and vendor are required' USING ERRCODE = '22004';
  END IF;

  IF auth.uid() IS NULL OR NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Only organization owners and admins can review catalog coverage'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO _vendor
  FROM public.vendors
  WHERE id = _vendor_id AND organization_id = _organization_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Organization vendor not found' USING ERRCODE = 'P0002';
  END IF;

  IF _vendor.catalog_vendor_id IS NULL THEN
    RETURN jsonb_build_object(
      'vendorId', _vendor.id,
      'vendorName', _vendor.name,
      'linked', false,
      'catalogVendor', NULL,
      'summary', NULL,
      'rows', '[]'::jsonb,
      'truncated', false
    );
  END IF;

  SELECT * INTO STRICT _catalog_vendor
  FROM public.catalog_vendors
  WHERE id = _vendor.catalog_vendor_id;

  WITH mapping AS (
    SELECT
      vendor_product.id,
      vendor_product.vendor_sku,
      vendor_product.manufacturer_sku,
      vendor_product.package_size,
      vendor_product.unit_of_measure,
      vendor_product.active,
      vendor_product.created_at,
      vendor_product.catalog_vendor_product_id,
      product.id AS product_id,
      product.name AS product_name,
      product.manufacturer,
      product.active AS product_active,
      public.normalize_catalog_sku(vendor_product.vendor_sku) AS strict_sku,
      nullif(public.normalize_catalog_sku_match_key(vendor_product.vendor_sku), '') AS sku_key
    FROM public.vendor_products vendor_product
    JOIN public.products product
      ON product.id = vendor_product.product_id
     AND product.organization_id = vendor_product.organization_id
    WHERE vendor_product.organization_id = _organization_id
      AND vendor_product.vendor_id = _vendor.id
  ),
  classified AS (
    SELECT
      mapping.*,
      CASE
        WHEN adopted.id IS NOT NULL THEN 'linked'
        WHEN exact.id IS NOT NULL THEN 'exact'
        WHEN keyed.match_count = 1 THEN 'separator_equivalent'
        WHEN keyed.match_count > 1 THEN 'ambiguous'
        ELSE 'not_cataloged'
      END AS status,
      COALESCE(adopted.id, exact.id, CASE WHEN keyed.match_count = 1 THEN keyed.listing_id END)
        AS listing_id
    FROM mapping
    LEFT JOIN public.catalog_vendor_products adopted
      ON adopted.id = mapping.catalog_vendor_product_id
     AND adopted.catalog_vendor_id = _catalog_vendor.id
    LEFT JOIN public.catalog_vendor_products exact
      ON exact.catalog_vendor_id = _catalog_vendor.id
     AND exact.normalized_vendor_sku = mapping.strict_sku
    LEFT JOIN LATERAL (
      SELECT count(*) AS match_count, min(listing.id::text)::uuid AS listing_id
      FROM public.catalog_vendor_products listing
      WHERE listing.catalog_vendor_id = _catalog_vendor.id
        AND mapping.sku_key IS NOT NULL
        AND listing.vendor_sku_match_key = mapping.sku_key
    ) keyed ON true
  ),
  described AS (
    SELECT
      classified.*,
      CASE WHEN listing.id IS NULL THEN NULL ELSE jsonb_build_object(
        'id', listing.id,
        'vendorSku', listing.vendor_sku,
        'productName', catalog_product.name,
        'verificationStatus', listing.verification_status,
        'active', listing.active,
        'discontinued', listing.discontinued
      ) END AS listing
    FROM classified
    LEFT JOIN public.catalog_vendor_products listing ON listing.id = classified.listing_id
    LEFT JOIN public.catalog_products catalog_product ON catalog_product.id = listing.catalog_product_id
  ),
  ordered AS (
    SELECT described.*, row_number() OVER (
      ORDER BY (status = 'not_cataloged') DESC, NOT active, strict_sku, id
    ) AS position
    FROM described
  )
  SELECT jsonb_build_object(
    'vendorId', _vendor.id,
    'vendorName', _vendor.name,
    'linked', true,
    'catalogVendor', jsonb_build_object(
      'id', _catalog_vendor.id,
      'name', _catalog_vendor.name,
      'active', _catalog_vendor.active
    ),
    'summary', jsonb_build_object(
      'mapped', count(*) FILTER (WHERE active),
      'represented', count(*) FILTER (WHERE active AND status <> 'not_cataloged'),
      'notRepresented', count(*) FILTER (WHERE active AND status = 'not_cataloged'),
      'inactiveMappings', count(*) FILTER (WHERE NOT active)
    ),
    'rows', COALESCE(jsonb_agg(jsonb_build_object(
      'vendorProductId', id,
      'vendorSku', vendor_sku,
      'manufacturerSku', manufacturer_sku,
      'packageSize', package_size,
      'unitOfMeasure', unit_of_measure,
      'mappingActive', active,
      'mappingCreatedAt', created_at,
      'productId', product_id,
      'productName', product_name,
      'manufacturer', manufacturer,
      'productActive', product_active,
      'status', status,
      'listing', listing
    ) ORDER BY position) FILTER (WHERE position <= 1000), '[]'::jsonb),
    'truncated', count(*) > 1000
  )
  INTO _result
  FROM ordered;

  RETURN _result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_organization_vendor_catalog_coverage(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_organization_vendor_catalog_coverage(uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.get_organization_vendor_catalog_coverage(uuid, uuid) IS
  'Owner/admin only, read-only. Classifies one organization vendor''s private SKU mappings against its linked catalog vendor by exact and separator-free SKU keys. Never writes and never promotes.';

COMMIT;
