-- Phase 5A.4C: allow held verification overrides to identify their subject by
-- verified vendor SKU without inventing source or promoted-product links.

ALTER TABLE public.catalog_verification_overrides
  DROP CONSTRAINT catalog_verification_overrides_identity_present,
  ADD CONSTRAINT catalog_verification_overrides_identity_present CHECK (
    source_record_id IS NOT NULL
    OR normalized_source_vendor_sku IS NOT NULL
    OR normalized_verified_vendor_sku IS NOT NULL
    OR catalog_vendor_product_id IS NOT NULL
  );
