-- Post-5A.8 staff request search display enrichment.
--
-- Expose only an unambiguous, source-backed variant for catalog identities that
-- the existing unified search already returned. This does not alter catalog,
-- inventory, adoption, or request identity data.
BEGIN;

CREATE OR REPLACE FUNCTION public.get_supply_request_product_specifications(
  _organization_id uuid,
  _catalog_vendor_product_ids uuid[]
)
RETURNS TABLE (
  catalog_vendor_product_id uuid,
  specification text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;
  IF _organization_id IS NULL THEN
    RAISE EXCEPTION 'organization_id is required' USING ERRCODE = '22004';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.organization_memberships membership
    WHERE membership.organization_id = _organization_id
      AND membership.user_id = auth.uid()
      AND membership.active = true
  ) THEN
    RAISE EXCEPTION 'Not a member of this organization' USING ERRCODE = '42501';
  END IF;
  IF COALESCE(cardinality(_catalog_vendor_product_ids), 0) > 50 THEN
    RAISE EXCEPTION 'At most 50 catalog products may be described at once'
      USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT
    catalog_vendor_product.id,
    min(btrim(source_record.raw_variant)) AS specification
  FROM public.catalog_vendor_products catalog_vendor_product
  JOIN public.catalog_products catalog_product
    ON catalog_product.id = catalog_vendor_product.catalog_product_id
   AND catalog_product.active = true
   AND catalog_product.verification_status = 'verified'
  JOIN public.catalog_vendors catalog_vendor
    ON catalog_vendor.id = catalog_vendor_product.catalog_vendor_id
   AND catalog_vendor.active = true
  JOIN public.catalog_source_records source_record
    ON source_record.matched_catalog_vendor_product_id = catalog_vendor_product.id
   AND source_record.catalog_vendor_id = catalog_vendor_product.catalog_vendor_id
   AND source_record.resolution_status IN ('matched', 'verified_match')
   AND nullif(btrim(source_record.raw_variant), '') IS NOT NULL
  WHERE catalog_vendor_product.id = ANY(
      COALESCE(_catalog_vendor_product_ids, ARRAY[]::uuid[])
    )
    AND catalog_vendor_product.active = true
    AND catalog_vendor_product.discontinued = false
    AND catalog_vendor_product.verification_status = 'verified'
  GROUP BY catalog_vendor_product.id
  HAVING count(DISTINCT btrim(source_record.raw_variant)) = 1
  ORDER BY catalog_vendor_product.id;
END;
$$;

REVOKE ALL ON FUNCTION public.get_supply_request_product_specifications(uuid, uuid[])
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_supply_request_product_specifications(uuid, uuid[])
  FROM anon;
GRANT EXECUTE ON FUNCTION public.get_supply_request_product_specifications(uuid, uuid[])
  TO authenticated;

COMMIT;
