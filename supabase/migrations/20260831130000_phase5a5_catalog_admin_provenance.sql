-- Phase 5A.5 Catalog Admin UI prerequisite: expose narrowly scoped catalog
-- provenance without granting clients access to service-role-only audit tables.

CREATE OR REPLACE FUNCTION public.get_catalog_vendor_product_admin_detail(
  _organization_id uuid,
  _catalog_vendor_product_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _detail jsonb;
BEGIN
  IF _organization_id IS NULL OR _catalog_vendor_product_id IS NULL THEN
    RAISE EXCEPTION 'organization_id and catalog_vendor_product_id are required'
      USING ERRCODE = '22004';
  END IF;

  IF NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Only organization owners and admins can view catalog provenance'
      USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'catalogVendorProductId', catalog_vendor_product.id,
    'product', jsonb_build_object(
      'id', catalog_product.id,
      'name', catalog_product.name,
      'manufacturer', catalog_product.manufacturer,
      'description', catalog_product.description,
      'active', catalog_product.active,
      'verificationStatus', catalog_product.verification_status
    ),
    'vendor', jsonb_build_object(
      'id', catalog_vendor.id,
      'name', catalog_vendor.name,
      'website', catalog_vendor.website,
      'active', catalog_vendor.active,
      'vendorSku', catalog_vendor_product.vendor_sku,
      'normalizedVendorSku', catalog_vendor_product.normalized_vendor_sku,
      'manufacturerSku', catalog_vendor_product.manufacturer_sku
    ),
    'package', jsonb_build_object(
      'rawDescription', catalog_vendor_product.package_description,
      'verifiedQuantity', CASE
        WHEN catalog_vendor_product.package_status = 'verified'
          THEN catalog_vendor_product.package_quantity
        ELSE NULL
      END,
      'verifiedUnit', CASE
        WHEN catalog_vendor_product.package_status = 'verified'
          THEN catalog_vendor_product.package_unit
        ELSE NULL
      END,
      'status', catalog_vendor_product.package_status
    ),
    'lifecycle', jsonb_build_object(
      'active', catalog_vendor_product.active,
      'discontinued', catalog_vendor_product.discontinued,
      'verificationStatus', catalog_vendor_product.verification_status
    ),
    'provenance', COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'sourceName', import_batch.source_name,
            'sourceVersion', import_batch.source_version,
            'sourcePage', source_record.source_page,
            'rawVendorSku', source_record.raw_vendor_sku,
            'rawProductName', source_record.raw_product_name,
            'rawVariant', source_record.raw_variant,
            'rawPackage', source_record.raw_package
          )
          ORDER BY import_batch.created_at DESC, source_record.source_ordinal
        )
        FROM public.catalog_source_records source_record
        JOIN public.catalog_import_batches import_batch
          ON import_batch.id = source_record.import_batch_id
         AND import_batch.catalog_vendor_id = source_record.catalog_vendor_id
        WHERE source_record.matched_catalog_vendor_product_id = catalog_vendor_product.id
      ),
      '[]'::jsonb
    ),
    'verificationOverrides', COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'overrideType', verification_override.override_type,
            'evidenceStatus', verification_override.evidence_status,
            'productionRule', verification_override.production_rule,
            'sourceVendorSku', verification_override.source_vendor_sku,
            'verifiedVendorSku', verification_override.verified_vendor_sku,
            'effectiveFrom', verification_override.effective_from,
            'sourceName', import_batch.source_name,
            'sourceVersion', import_batch.source_version
          )
          ORDER BY verification_override.effective_from DESC, verification_override.id
        )
        FROM public.catalog_verification_overrides verification_override
        LEFT JOIN public.catalog_import_batches import_batch
          ON import_batch.id = verification_override.import_batch_id
         AND import_batch.catalog_vendor_id = verification_override.catalog_vendor_id
        WHERE verification_override.catalog_vendor_product_id = catalog_vendor_product.id
          AND verification_override.active
          AND (
            verification_override.effective_to IS NULL
            OR verification_override.effective_to > now()
          )
      ),
      '[]'::jsonb
    )
  )
  INTO _detail
  FROM public.catalog_vendor_products catalog_vendor_product
  JOIN public.catalog_products catalog_product
    ON catalog_product.id = catalog_vendor_product.catalog_product_id
  JOIN public.catalog_vendors catalog_vendor
    ON catalog_vendor.id = catalog_vendor_product.catalog_vendor_id
  WHERE catalog_vendor_product.id = _catalog_vendor_product_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Catalog vendor product % does not exist', _catalog_vendor_product_id
      USING ERRCODE = 'P0002';
  END IF;

  RETURN _detail;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_catalog_vendor_product_admin_detail(uuid, uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_catalog_vendor_product_admin_detail(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_catalog_vendor_product_admin_detail(uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.get_catalog_vendor_product_admin_detail(uuid, uuid) IS
  'Returns sanitized global catalog identity, source provenance, and active verification decisions for one organization owner/admin.';
