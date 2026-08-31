-- Phase 5A.5: safe, idempotent organization adoption of global catalog listings.
--
-- This migration intentionally does not adopt any rows by itself. It adds the
-- database invariants and one atomic RPC required by the Catalog admin UI.

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.vendors
    WHERE catalog_vendor_id IS NOT NULL
    GROUP BY organization_id, catalog_vendor_id
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION
      'Cannot enforce catalog vendor adoption uniqueness: duplicate organization catalog vendor links exist';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.products
    WHERE catalog_product_id IS NOT NULL
    GROUP BY organization_id, catalog_product_id
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION
      'Cannot enforce catalog product adoption uniqueness: duplicate organization catalog product links exist';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.vendor_products
    WHERE catalog_vendor_product_id IS NOT NULL
    GROUP BY organization_id, catalog_vendor_product_id
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION
      'Cannot enforce catalog vendor-product adoption uniqueness: duplicate organization catalog vendor-product links exist';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.vendor_products organization_vendor_product
    JOIN public.catalog_vendor_products catalog_vendor_product
      ON catalog_vendor_product.id = organization_vendor_product.catalog_vendor_product_id
    JOIN public.vendors organization_vendor
      ON organization_vendor.id = organization_vendor_product.vendor_id
     AND organization_vendor.organization_id = organization_vendor_product.organization_id
    JOIN public.products organization_product
      ON organization_product.id = organization_vendor_product.product_id
     AND organization_product.organization_id = organization_vendor_product.organization_id
    WHERE organization_vendor_product.catalog_vendor_product_id IS NOT NULL
      AND (
        organization_vendor.catalog_vendor_id IS DISTINCT FROM catalog_vendor_product.catalog_vendor_id
        OR organization_product.catalog_product_id IS DISTINCT FROM catalog_vendor_product.catalog_product_id
      )
  ) THEN
    RAISE EXCEPTION
      'Cannot enforce catalog adoption consistency: an organization vendor-product link has mismatched vendor or product parents';
  END IF;
END;
$$;

CREATE UNIQUE INDEX vendors_org_catalog_vendor_uq
  ON public.vendors (organization_id, catalog_vendor_id)
  WHERE catalog_vendor_id IS NOT NULL;

CREATE UNIQUE INDEX products_org_catalog_product_uq
  ON public.products (organization_id, catalog_product_id)
  WHERE catalog_product_id IS NOT NULL;

CREATE UNIQUE INDEX vendor_products_org_catalog_vendor_product_uq
  ON public.vendor_products (organization_id, catalog_vendor_product_id)
  WHERE catalog_vendor_product_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.validate_vendor_product_catalog_link()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  _catalog_vendor_id uuid;
  _catalog_product_id uuid;
BEGIN
  IF NEW.catalog_vendor_product_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT catalog_vendor_id, catalog_product_id
  INTO _catalog_vendor_id, _catalog_product_id
  FROM public.catalog_vendor_products
  WHERE id = NEW.catalog_vendor_product_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Catalog vendor product % does not exist', NEW.catalog_vendor_product_id
      USING ERRCODE = '23503';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.vendors
    WHERE id = NEW.vendor_id
      AND organization_id = NEW.organization_id
      AND catalog_vendor_id = _catalog_vendor_id
  ) THEN
    RAISE EXCEPTION
      'Organization vendor % is not linked to catalog vendor %',
      NEW.vendor_id,
      _catalog_vendor_id
      USING ERRCODE = '23514';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.products
    WHERE id = NEW.product_id
      AND organization_id = NEW.organization_id
      AND catalog_product_id = _catalog_product_id
  ) THEN
    RAISE EXCEPTION
      'Organization product % is not linked to catalog product %',
      NEW.product_id,
      _catalog_product_id
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.validate_vendor_product_catalog_link() FROM PUBLIC;

CREATE TRIGGER vendor_products_validate_catalog_link
  BEFORE INSERT OR UPDATE OF organization_id, vendor_id, product_id, catalog_vendor_product_id
  ON public.vendor_products
  FOR EACH ROW EXECUTE FUNCTION public.validate_vendor_product_catalog_link();

CREATE OR REPLACE FUNCTION public.validate_catalog_parent_link_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF TG_TABLE_NAME = 'vendors' THEN
    IF NEW.catalog_vendor_id IS DISTINCT FROM OLD.catalog_vendor_id
       AND EXISTS (
         SELECT 1
         FROM public.vendor_products organization_vendor_product
         JOIN public.catalog_vendor_products catalog_vendor_product
           ON catalog_vendor_product.id = organization_vendor_product.catalog_vendor_product_id
         WHERE organization_vendor_product.organization_id = OLD.organization_id
           AND organization_vendor_product.vendor_id = OLD.id
           AND organization_vendor_product.catalog_vendor_product_id IS NOT NULL
           AND catalog_vendor_product.catalog_vendor_id IS DISTINCT FROM NEW.catalog_vendor_id
       ) THEN
      RAISE EXCEPTION
        'Catalog vendor link cannot conflict with an adopted vendor product'
        USING ERRCODE = '23514';
    END IF;
  ELSIF TG_TABLE_NAME = 'products' THEN
    IF NEW.catalog_product_id IS DISTINCT FROM OLD.catalog_product_id
       AND EXISTS (
         SELECT 1
         FROM public.vendor_products organization_vendor_product
         JOIN public.catalog_vendor_products catalog_vendor_product
           ON catalog_vendor_product.id = organization_vendor_product.catalog_vendor_product_id
         WHERE organization_vendor_product.organization_id = OLD.organization_id
           AND organization_vendor_product.product_id = OLD.id
           AND organization_vendor_product.catalog_vendor_product_id IS NOT NULL
           AND catalog_vendor_product.catalog_product_id IS DISTINCT FROM NEW.catalog_product_id
       ) THEN
      RAISE EXCEPTION
        'Catalog product link cannot conflict with an adopted vendor product'
        USING ERRCODE = '23514';
    END IF;
  ELSIF TG_TABLE_NAME = 'catalog_vendor_products' THEN
    IF (
      NEW.catalog_vendor_id IS DISTINCT FROM OLD.catalog_vendor_id
      OR NEW.catalog_product_id IS DISTINCT FROM OLD.catalog_product_id
    ) AND EXISTS (
      SELECT 1
      FROM public.vendor_products organization_vendor_product
      JOIN public.vendors organization_vendor
        ON organization_vendor.id = organization_vendor_product.vendor_id
       AND organization_vendor.organization_id = organization_vendor_product.organization_id
      JOIN public.products organization_product
        ON organization_product.id = organization_vendor_product.product_id
       AND organization_product.organization_id = organization_vendor_product.organization_id
      WHERE organization_vendor_product.catalog_vendor_product_id = OLD.id
        AND (
          organization_vendor.catalog_vendor_id IS DISTINCT FROM NEW.catalog_vendor_id
          OR organization_product.catalog_product_id IS DISTINCT FROM NEW.catalog_product_id
        )
    ) THEN
      RAISE EXCEPTION
        'Catalog vendor-product parents cannot conflict with an organization adoption'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.validate_catalog_parent_link_change() FROM PUBLIC;

CREATE TRIGGER vendors_validate_catalog_link_change
  BEFORE UPDATE OF catalog_vendor_id ON public.vendors
  FOR EACH ROW EXECUTE FUNCTION public.validate_catalog_parent_link_change();

CREATE TRIGGER products_validate_catalog_link_change
  BEFORE UPDATE OF catalog_product_id ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.validate_catalog_parent_link_change();

CREATE TRIGGER catalog_vendor_products_validate_parent_link_change
  BEFORE UPDATE OF catalog_vendor_id, catalog_product_id ON public.catalog_vendor_products
  FOR EACH ROW EXECUTE FUNCTION public.validate_catalog_parent_link_change();

-- Recheck after all consistency triggers are installed. The index and trigger
-- DDL locks are held through the migration transaction, so this closes the
-- interval in which a concurrent writer could have raced the initial preflight.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.vendor_products organization_vendor_product
    JOIN public.catalog_vendor_products catalog_vendor_product
      ON catalog_vendor_product.id = organization_vendor_product.catalog_vendor_product_id
    JOIN public.vendors organization_vendor
      ON organization_vendor.id = organization_vendor_product.vendor_id
     AND organization_vendor.organization_id = organization_vendor_product.organization_id
    JOIN public.products organization_product
      ON organization_product.id = organization_vendor_product.product_id
     AND organization_product.organization_id = organization_vendor_product.organization_id
    WHERE organization_vendor_product.catalog_vendor_product_id IS NOT NULL
      AND (
        organization_vendor.catalog_vendor_id IS DISTINCT FROM catalog_vendor_product.catalog_vendor_id
        OR organization_product.catalog_product_id IS DISTINCT FROM catalog_vendor_product.catalog_product_id
      )
  ) THEN
    RAISE EXCEPTION
      'Cannot enforce catalog adoption consistency: an organization vendor-product link has mismatched vendor or product parents';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.adopt_catalog_vendor_product(
  _organization_id uuid,
  _catalog_vendor_product_id uuid
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
  _organization_vendor public.vendors%ROWTYPE;
  _organization_product public.products%ROWTYPE;
  _organization_vendor_product public.vendor_products%ROWTYPE;
  _already_adopted boolean := false;
  _vendor_created boolean := false;
  _product_created boolean := false;
  _vendor_product_created boolean := false;
  _candidate_count bigint := 0;
  _adopted_active boolean;
  _vendor_product_active boolean;
  _verified_unit text;
BEGIN
  IF _organization_id IS NULL OR _catalog_vendor_product_id IS NULL THEN
    RAISE EXCEPTION 'organization_id and catalog_vendor_product_id are required'
      USING ERRCODE = '22004';
  END IF;

  IF NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Only organization owners and admins can adopt catalog products'
      USING ERRCODE = '42501';
  END IF;

  -- Serialize catalog adoption within one organization. This closes races where
  -- two different listings need to create or link the same local vendor/product.
  PERFORM pg_advisory_xact_lock(
    hashtextextended('catalog-adoption:' || _organization_id::text, 0)
  );

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

  _adopted_active :=
    _catalog_vendor.active
    AND _catalog_product.active
    AND _catalog_vendor_product.active
    AND NOT _catalog_vendor_product.discontinued;
  _verified_unit := CASE
    WHEN _catalog_vendor_product.package_status = 'verified'
      THEN _catalog_vendor_product.package_unit
    ELSE NULL
  END;

  SELECT *
  INTO _organization_vendor_product
  FROM public.vendor_products
  WHERE organization_id = _organization_id
    AND catalog_vendor_product_id = _catalog_vendor_product.id
  ORDER BY created_at, id
  LIMIT 1
  FOR UPDATE;
  _already_adopted := FOUND;

  IF _already_adopted THEN
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
      RAISE EXCEPTION
        'Existing catalog adoption % has mismatched vendor or product parents',
        _organization_vendor_product.id
        USING ERRCODE = '23514';
    END IF;

    RETURN jsonb_build_object(
      'organizationId', _organization_id,
      'catalogVendorProductId', _catalog_vendor_product.id,
      'vendorId', _organization_vendor.id,
      'productId', _organization_product.id,
      'vendorProductId', _organization_vendor_product.id,
      'vendorCreated', false,
      'productCreated', false,
      'vendorProductCreated', false,
      'alreadyAdopted', true
    );
  END IF;

  SELECT *
  INTO _organization_vendor
  FROM public.vendors
  WHERE organization_id = _organization_id
    AND catalog_vendor_id = _catalog_vendor.id
  ORDER BY created_at, id
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    SELECT *
    INTO _organization_vendor
    FROM public.vendors
    WHERE organization_id = _organization_id
      AND active
      AND normalized_name = _catalog_vendor.normalized_name
    ORDER BY created_at, id
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
      IF _organization_vendor.catalog_vendor_id IS NOT NULL
         AND _organization_vendor.catalog_vendor_id <> _catalog_vendor.id THEN
        RAISE EXCEPTION
          'Active organization vendor % has the same normalized name but links to a different catalog vendor',
          _organization_vendor.id
          USING ERRCODE = '23505';
      END IF;

      IF _organization_vendor.catalog_vendor_id IS NULL THEN
        UPDATE public.vendors
        SET catalog_vendor_id = _catalog_vendor.id
        WHERE id = _organization_vendor.id
        RETURNING * INTO _organization_vendor;
      END IF;
    ELSE
      INSERT INTO public.vendors (
        organization_id,
        name,
        normalized_name,
        website,
        active,
        catalog_vendor_id
      )
      VALUES (
        _organization_id,
        _catalog_vendor.name,
        _catalog_vendor.normalized_name,
        _catalog_vendor.website,
        _catalog_vendor.active,
        _catalog_vendor.id
      )
      RETURNING * INTO _organization_vendor;
      _vendor_created := true;
    END IF;
  END IF;

  -- A reused inactive local vendor is an organization override. New child rows
  -- must respect that local operational state even when the global row is active.
  _adopted_active := _adopted_active AND _organization_vendor.active;

  SELECT count(*)
  INTO _candidate_count
  FROM public.vendor_products
  WHERE organization_id = _organization_id
    AND vendor_id = _organization_vendor.id
    AND lower(btrim(vendor_sku)) = lower(btrim(_catalog_vendor_product.vendor_sku));

  IF _candidate_count > 1 THEN
    RAISE EXCEPTION
      'Multiple organization vendor products use exact vendor SKU % for vendor %; manual reconciliation is required',
      _catalog_vendor_product.vendor_sku,
      _organization_vendor.id
      USING ERRCODE = '23505';
  END IF;

  IF _candidate_count = 1 THEN
    SELECT *
    INTO STRICT _organization_vendor_product
    FROM public.vendor_products
    WHERE organization_id = _organization_id
      AND vendor_id = _organization_vendor.id
      AND lower(btrim(vendor_sku)) = lower(btrim(_catalog_vendor_product.vendor_sku))
    FOR UPDATE;

    IF _organization_vendor_product.catalog_vendor_product_id IS NOT NULL
       AND _organization_vendor_product.catalog_vendor_product_id <> _catalog_vendor_product.id THEN
      RAISE EXCEPTION
        'Organization vendor product % already links to a different catalog vendor product',
        _organization_vendor_product.id
        USING ERRCODE = '23505';
    END IF;

    SELECT *
    INTO STRICT _organization_product
    FROM public.products
    WHERE id = _organization_vendor_product.product_id
      AND organization_id = _organization_id
    FOR UPDATE;

    IF _organization_product.catalog_product_id IS NOT NULL
       AND _organization_product.catalog_product_id <> _catalog_product.id THEN
      RAISE EXCEPTION
        'Organization product % already links to a different catalog product',
        _organization_product.id
        USING ERRCODE = '23505';
    END IF;

    IF _organization_product.catalog_product_id IS NULL THEN
      UPDATE public.products
      SET catalog_product_id = _catalog_product.id
      WHERE id = _organization_product.id
      RETURNING * INTO _organization_product;
    END IF;

    UPDATE public.vendor_products
    SET catalog_vendor_product_id = _catalog_vendor_product.id
    WHERE id = _organization_vendor_product.id
    RETURNING * INTO _organization_vendor_product;
  ELSE
    SELECT *
    INTO _organization_product
    FROM public.products
    WHERE organization_id = _organization_id
      AND catalog_product_id = _catalog_product.id
    ORDER BY created_at, id
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
      IF EXISTS (
        SELECT 1
        FROM public.products
        WHERE organization_id = _organization_id
          AND active
          AND normalized_name = _catalog_product.normalized_name
      ) THEN
        RAISE EXCEPTION
          'An active organization product already uses normalized name %; manual reconciliation is required',
          _catalog_product.normalized_name
          USING ERRCODE = '23505';
      END IF;

      INSERT INTO public.products (
        organization_id,
        name,
        unit,
        approved,
        normalized_name,
        description,
        preferred_vendor_id,
        manufacturer,
        vendor_item_number,
        unit_of_measure,
        pack_size,
        active,
        staff_requestable,
        catalog_product_id
      )
      VALUES (
        _organization_id,
        _catalog_product.name,
        _verified_unit,
        _adopted_active,
        _catalog_product.normalized_name,
        _catalog_product.description,
        _organization_vendor.id,
        _catalog_product.manufacturer,
        _catalog_vendor_product.vendor_sku,
        _verified_unit,
        _catalog_vendor_product.package_description,
        _adopted_active,
        _adopted_active,
        _catalog_product.id
      )
      RETURNING * INTO _organization_product;
      _product_created := true;
    END IF;

    _vendor_product_active := _adopted_active AND _organization_product.active;

    INSERT INTO public.vendor_products (
      organization_id,
      vendor_id,
      product_id,
      vendor_sku,
      manufacturer_sku,
      package_size,
      unit_of_measure,
      active,
      catalog_vendor_product_id
    )
    VALUES (
      _organization_id,
      _organization_vendor.id,
      _organization_product.id,
      _catalog_vendor_product.vendor_sku,
      _catalog_vendor_product.manufacturer_sku,
      _catalog_vendor_product.package_description,
      _verified_unit,
      _vendor_product_active,
      _catalog_vendor_product.id
    )
    RETURNING * INTO _organization_vendor_product;
    _vendor_product_created := true;
  END IF;

  RETURN jsonb_build_object(
    'organizationId', _organization_id,
    'catalogVendorProductId', _catalog_vendor_product.id,
    'vendorId', _organization_vendor.id,
    'productId', _organization_product.id,
    'vendorProductId', _organization_vendor_product.id,
    'vendorCreated', _vendor_created,
    'productCreated', _product_created,
    'vendorProductCreated', _vendor_product_created,
    'alreadyAdopted', false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.adopt_catalog_vendor_product(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.adopt_catalog_vendor_product(uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.adopt_catalog_vendor_product(uuid, uuid) IS
  'Atomically and idempotently adopts one global catalog vendor listing into an organization catalog. Owner/admin only; inventory is never created or changed.';
