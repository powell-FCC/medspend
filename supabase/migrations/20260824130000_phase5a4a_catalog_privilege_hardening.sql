-- Phase 5A.4A corrective migration: make global catalog table privileges explicit.
-- RLS policies remain unchanged; this migration only adjusts table-level ACLs.

-- Supabase projects may grant broad privileges on new public tables through
-- database-level default privileges. Remove all client-role access first so
-- the grants below define the complete intended client-facing permission set.
REVOKE ALL PRIVILEGES ON TABLE
  public.catalog_vendors,
  public.catalog_categories,
  public.catalog_products,
  public.catalog_vendor_products,
  public.catalog_import_batches,
  public.catalog_source_records,
  public.catalog_verification_overrides
FROM PUBLIC;

REVOKE ALL PRIVILEGES ON TABLE
  public.catalog_vendors,
  public.catalog_categories,
  public.catalog_products,
  public.catalog_vendor_products,
  public.catalog_import_batches,
  public.catalog_source_records,
  public.catalog_verification_overrides
FROM anon;

REVOKE ALL PRIVILEGES ON TABLE
  public.catalog_vendors,
  public.catalog_categories,
  public.catalog_products,
  public.catalog_vendor_products,
  public.catalog_import_batches,
  public.catalog_source_records,
  public.catalog_verification_overrides
FROM authenticated;

-- Authenticated users may read only the four intended global catalog tables.
GRANT SELECT ON TABLE
  public.catalog_vendors,
  public.catalog_categories,
  public.catalog_products,
  public.catalog_vendor_products
TO authenticated;

-- The service role retains full platform-administration access to the catalog.
GRANT ALL PRIVILEGES ON TABLE
  public.catalog_vendors,
  public.catalog_categories,
  public.catalog_products,
  public.catalog_vendor_products
TO service_role;

-- Provenance and audit records are service-role-only and intentionally
-- non-deletable/non-truncatable at the table-privilege layer.
REVOKE ALL PRIVILEGES ON TABLE
  public.catalog_import_batches,
  public.catalog_source_records,
  public.catalog_verification_overrides
FROM service_role;

GRANT SELECT, INSERT, UPDATE ON TABLE
  public.catalog_import_batches,
  public.catalog_source_records,
  public.catalog_verification_overrides
TO service_role;
