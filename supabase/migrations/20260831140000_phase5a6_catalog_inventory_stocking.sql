-- Phase 5A.6: atomic organization inventory stocking from an adopted catalog identity.
--
-- This migration intentionally creates no inventory rows. It adds only the
-- owner/admin RPC required to create one zero-quantity stock row from an
-- already-adopted organization catalog product.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class index_relation
    JOIN pg_catalog.pg_namespace index_namespace
      ON index_namespace.oid = index_relation.relnamespace
    JOIN pg_catalog.pg_index index_definition
      ON index_definition.indexrelid = index_relation.oid
    WHERE index_namespace.nspname = 'public'
      AND index_relation.relname = 'inventory_items_org_product_uq'
      AND index_definition.indisunique
      AND index_definition.indisvalid
      AND index_definition.indisready
      AND pg_catalog.pg_get_indexdef(index_relation.oid) =
        'CREATE UNIQUE INDEX inventory_items_org_product_uq ON public.inventory_items USING btree (organization_id, product_id) WHERE (product_id IS NOT NULL)'
  ) THEN
    RAISE EXCEPTION
      'Phase 5A.6 requires the exact inventory_items organization-product uniqueness guarantee';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.stock_catalog_vendor_product(
  _organization_id uuid,
  _catalog_vendor_product_id uuid,
  _unit text DEFAULT NULL,
  _par_level numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _catalog_vendor_product public.catalog_vendor_products%ROWTYPE;
  _catalog_vendor public.catalog_vendors%ROWTYPE;
  _catalog_product public.catalog_products%ROWTYPE;
  _organization_vendor_product public.vendor_products%ROWTYPE;
  _organization_vendor public.vendors%ROWTYPE;
  _organization_product public.products%ROWTYPE;
  _inventory public.inventory_items%ROWTYPE;
  _requested_unit text := nullif(btrim(_unit), '');
  _inventory_unit text;
  _inventory_created boolean := false;
BEGIN
  IF _organization_id IS NULL OR _catalog_vendor_product_id IS NULL THEN
    RAISE EXCEPTION 'organization_id and catalog_vendor_product_id are required'
      USING ERRCODE = '22004';
  END IF;

  IF NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Only organization owners and admins can stock catalog products'
      USING ERRCODE = '42501';
  END IF;

  IF _par_level IS NOT NULL AND _par_level < 0 THEN
    RAISE EXCEPTION 'Par level cannot be negative'
      USING ERRCODE = '22023';
  END IF;

  IF _requested_unit IS NOT NULL AND length(_requested_unit) > 80 THEN
    RAISE EXCEPTION 'Inventory unit cannot exceed 80 characters'
      USING ERRCODE = '22001';
  END IF;

  SELECT *
  INTO _catalog_vendor_product
  FROM public.catalog_vendor_products
  WHERE id = _catalog_vendor_product_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Catalog vendor product % does not exist', _catalog_vendor_product_id
      USING ERRCODE = 'P0002';
  END IF;

  SELECT *
  INTO STRICT _catalog_vendor
  FROM public.catalog_vendors
  WHERE id = _catalog_vendor_product.catalog_vendor_id;

  SELECT *
  INTO STRICT _catalog_product
  FROM public.catalog_products
  WHERE id = _catalog_vendor_product.catalog_product_id;

  SELECT *
  INTO _organization_vendor_product
  FROM public.vendor_products
  WHERE organization_id = _organization_id
    AND catalog_vendor_product_id = _catalog_vendor_product.id
  ORDER BY created_at, id
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Adopt this catalog product before adding it to inventory'
      USING ERRCODE = '55000';
  END IF;

  SELECT *
  INTO STRICT _organization_vendor
  FROM public.vendors
  WHERE id = _organization_vendor_product.vendor_id
    AND organization_id = _organization_id
  FOR UPDATE;

  SELECT *
  INTO STRICT _organization_product
  FROM public.products
  WHERE id = _organization_vendor_product.product_id
    AND organization_id = _organization_id
  FOR UPDATE;

  IF _organization_vendor.catalog_vendor_id IS DISTINCT FROM _catalog_vendor.id
     OR _organization_product.catalog_product_id IS DISTINCT FROM _catalog_product.id THEN
    RAISE EXCEPTION 'The organization catalog adoption has mismatched vendor or product parents'
      USING ERRCODE = '23514';
  END IF;

  -- Serialize every catalog listing that resolves to the same organization
  -- product, including listings from different catalog vendors.
  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      'catalog-inventory:' || _organization_id::text || ':' || _organization_product.id::text,
      0
    )
  );

  SELECT *
  INTO _inventory
  FROM public.inventory_items
  WHERE organization_id = _organization_id
    AND product_id = _organization_product.id
  ORDER BY created_at, id
  LIMIT 1
  FOR UPDATE;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'organizationId', _organization_id,
      'catalogVendorProductId', _catalog_vendor_product.id,
      'vendorProductId', _organization_vendor_product.id,
      'productId', _organization_product.id,
      'inventoryItemId', _inventory.id,
      'inventoryCreated', false,
      'alreadyStocked', true,
      'quantity', _inventory.quantity,
      'parLevel', _inventory.par_level,
      'unit', _inventory.unit,
      'active', _inventory.active
    );
  END IF;

  IF _catalog_vendor_product.discontinued
     OR NOT _catalog_vendor_product.active
     OR NOT _catalog_vendor.active
     OR NOT _catalog_product.active
     OR NOT _organization_vendor.active
     OR NOT _organization_product.active
     OR NOT _organization_vendor_product.active THEN
    RAISE EXCEPTION 'Inactive or discontinued catalog products cannot create new active inventory'
      USING ERRCODE = '55000';
  END IF;

  _inventory_unit := CASE
    WHEN _catalog_vendor_product.package_status = 'verified'
      THEN COALESCE(_requested_unit, nullif(btrim(_catalog_vendor_product.package_unit), ''))
    ELSE _requested_unit
  END;

  IF _inventory_unit IS NULL THEN
    RAISE EXCEPTION 'An explicit inventory unit is required for source-only or unknown packages'
      USING ERRCODE = '22023';
  END IF;

  BEGIN
    INSERT INTO public.inventory_items (
      organization_id,
      product_id,
      sku,
      name,
      description,
      category,
      manufacturer,
      unit,
      quantity,
      par_level,
      vendor_name,
      active
    )
    VALUES (
      _organization_id,
      _organization_product.id,
      _organization_vendor_product.vendor_sku,
      _organization_product.name,
      _organization_product.description,
      NULL,
      _organization_product.manufacturer,
      _inventory_unit,
      0,
      _par_level,
      _organization_vendor.name,
      true
    )
    RETURNING * INTO _inventory;
    _inventory_created := true;
  EXCEPTION
    WHEN unique_violation THEN
      -- The unique organization-product index is the final concurrency guard.
      -- Reuse only the row for this exact organization product; a different
      -- vendor/SKU collision remains an error and is never silently linked.
      SELECT *
      INTO _inventory
      FROM public.inventory_items
      WHERE organization_id = _organization_id
        AND product_id = _organization_product.id
      ORDER BY created_at, id
      LIMIT 1
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE;
      END IF;
  END;

  RETURN jsonb_build_object(
    'organizationId', _organization_id,
    'catalogVendorProductId', _catalog_vendor_product.id,
    'vendorProductId', _organization_vendor_product.id,
    'productId', _organization_product.id,
    'inventoryItemId', _inventory.id,
    'inventoryCreated', _inventory_created,
    'alreadyStocked', NOT _inventory_created,
    'quantity', _inventory.quantity,
    'parLevel', _inventory.par_level,
    'unit', _inventory.unit,
    'active', _inventory.active
  );
END;
$$;

REVOKE ALL ON FUNCTION public.stock_catalog_vendor_product(uuid, uuid, text, numeric) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.stock_catalog_vendor_product(uuid, uuid, text, numeric) FROM anon;
GRANT EXECUTE ON FUNCTION public.stock_catalog_vendor_product(uuid, uuid, text, numeric) TO authenticated;

COMMENT ON FUNCTION public.stock_catalog_vendor_product(uuid, uuid, text, numeric) IS
  'Idempotently creates one zero-quantity inventory row for an already-adopted organization catalog product. Owner/admin only; never creates catalog identities or inventory movements.';
