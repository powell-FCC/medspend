REVOKE EXECUTE ON FUNCTION public.adopt_catalog_vendor_product(uuid, uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.adopt_catalog_vendor_product(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.adopt_catalog_vendor_product(uuid, uuid) TO authenticated;
