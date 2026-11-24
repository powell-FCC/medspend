-- Hotfix: catalog adoption of a same-named catalog variant, and named catalog-match refusals.
--
-- Production (2026-11-24): manual Invoice Review matches to a Henry Schein catalog item were
-- refused with "This catalog item conflicts with a product or vendor SKU mapping ..." even
-- when nothing about the vendor SKU conflicted. Root cause: adopt_catalog_vendor_product
-- refused (23505) whenever an active organization product already used the catalog
-- product's normalized name (products_active_name_uq). The Henry Schein catalog gives most
-- variant families one product name (7,724 of 9,059 catalog products share a name), so once
-- one variant was adopted (e.g. PowerFlex 2.75", SKU 101-2983, catalog product A) every
-- sibling (PowerFlex 2", SKU 613-0167, catalog product B) was refused. The Phase 6C.1
-- resolver hits the same refusal at import and leaves the line for review, so the manual
-- match of that line always failed again, and the message's advice ("choose the existing
-- product") put the sibling's SKU on the wrong product.
--
-- This migration redefines two functions; nothing else changes:
--   * adopt_catalog_vendor_product (last defined in 20261019120000_catalog_vendor_management.sql):
--     when the only same-named active product is linked to a different catalog product, the
--     new product is created as "<catalog name> (<vendor SKU>)". An unlinked same-named
--     product is still refused (it may be the same item), as is a taken qualified name.
--     Every reconciliation refusal keeps its SQLSTATE and message and adds a JSON HINT
--     {conflictType, productId?, vendorProductId?}. One refusal is new by name only: an
--     unlinked product holding the SKU cannot take a catalog identity another product
--     already holds (previously the same 23505 from products_org_catalog_product_uq, now
--     conflictType catalog_product_adopted_elsewhere). No other rule changes: one vendor
--     SKU still maps to one product, existing mappings are reused, contradictions are
--     refused.
--   * match_invoice_item_to_catalog_listing (20261012120000_beta_invoice_manual_catalog_matching.sql):
--     a refused adoption now names the conflict in its message (which still begins with the
--     previous sentence) and returns a JSON HINT whose canMatchExisting is the only
--     authority for offering "Match to <product>": true only when this line's vendor SKU
--     already maps (active, invoice vendor) to an active product that IS the selected
--     catalog identity, or is unlinked with no other product holding it. A SKU mapped to a
--     product of a different catalog item is a contradiction: named, never offered.
--     Return keys unchanged.
--
-- No table, column, index, constraint, grant, or row is changed. Existing products keep
-- their names. Rollback: re-run the adopt_catalog_vendor_product definition from
-- 20261019120000_catalog_vendor_management.sql and the match_invoice_item_to_catalog_listing
-- definition from 20261012120000_beta_invoice_manual_catalog_matching.sql (as CREATE OR
-- REPLACE), with their REVOKE/GRANT/COMMENT statements.

BEGIN;

DO $catalog_name_twin_preflight$
BEGIN
  IF to_regprocedure('public.adopt_catalog_vendor_product(uuid, uuid)') IS NULL
     OR to_regprocedure('public.match_invoice_item_to_catalog_listing(uuid, uuid, uuid, uuid, uuid)') IS NULL
     OR to_regprocedure('public.normalize_catalog_text(text)') IS NULL
     OR to_regprocedure('public.normalize_catalog_sku_match_key(text)') IS NULL
     OR to_regprocedure('public.link_organization_vendor_to_catalog_vendor(uuid, uuid, uuid, timestamptz)') IS NULL THEN
    RAISE EXCEPTION 'The catalog name-twin hotfix requires catalog vendor management and manual catalog matching';
  END IF;
END
$catalog_name_twin_preflight$;

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
  _name_twin public.products%ROWTYPE;
  _catalog_holder public.products%ROWTYPE;
  _product_name text;
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
        USING ERRCODE = '23514',
          HINT = jsonb_build_object('conflictType', 'adoption_inconsistent', 'productId', _organization_product.id, 'vendorProductId', _organization_vendor_product.id)::text;
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
    -- A same-name vendor is never treated as the catalog vendor. Unlinked, it must be
    -- linked explicitly in Catalog Vendors; linked elsewhere, adoption is refused. Neither
    -- case writes anything. The name is only checked so adoption does not create a second
    -- active vendor beside it (vendors_active_name_uq).
    SELECT *
    INTO _organization_vendor
    FROM public.vendors
    WHERE organization_id = _organization_id
      AND active
      AND normalized_name = _catalog_vendor.normalized_name
    ORDER BY created_at, id
    LIMIT 1;

    IF FOUND THEN
      IF _organization_vendor.catalog_vendor_id IS NOT NULL THEN
        RAISE EXCEPTION
          'Active organization vendor % has the same normalized name but links to a different catalog vendor',
          _organization_vendor.id
          USING ERRCODE = '23505',
            HINT = jsonb_build_object('conflictType', 'vendor_conflict')::text;
      END IF;

      RAISE EXCEPTION
        'Organization vendor % is not linked to catalog vendor %; link it in Catalog Vendors before adopting',
        _organization_vendor.id,
        _catalog_vendor.id
        USING ERRCODE = '55000';
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
      USING ERRCODE = '23505',
        HINT = jsonb_build_object('conflictType', 'multiple_sku_mappings')::text;
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
        USING ERRCODE = '23505',
          HINT = jsonb_build_object('conflictType', 'sku_mapped_to_other_listing', 'productId', _organization_vendor_product.product_id, 'vendorProductId', _organization_vendor_product.id)::text;
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
        USING ERRCODE = '23505',
          HINT = jsonb_build_object('conflictType', 'sku_mapped_to_other_product', 'productId', _organization_product.id, 'vendorProductId', _organization_vendor_product.id)::text;
    END IF;

    IF _organization_product.catalog_product_id IS NULL THEN
      -- The SKU's unlinked product can take this catalog identity only if no other product
      -- already holds it (products_org_catalog_product_uq). Otherwise one catalog item would
      -- have two products; refuse by name instead of failing on the constraint.
      SELECT *
      INTO _catalog_holder
      FROM public.products
      WHERE organization_id = _organization_id
        AND catalog_product_id = _catalog_product.id
        AND id <> _organization_product.id
      LIMIT 1;

      IF FOUND THEN
        RAISE EXCEPTION
          'Catalog product % is already organization product %',
          _catalog_product.id,
          _catalog_holder.id
          USING ERRCODE = '23505',
            HINT = jsonb_build_object('conflictType', 'catalog_product_adopted_elsewhere', 'productId', _organization_product.id, 'vendorProductId', _organization_vendor_product.id, 'adoptedProductId', _catalog_holder.id)::text;
      END IF;

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
      -- At most one active product may hold a name (products_active_name_uq). An unlinked
      -- product with the catalog product's name may be this very item, so a person decides.
      -- A product linked to a different catalog product is provably a different item: the
      -- vendor catalog gives whole variant families (sizes, colors) one product name. The
      -- new product then takes that name qualified by the vendor SKU, so the two stay apart.
      _product_name := _catalog_product.name;
      SELECT *
      INTO _name_twin
      FROM public.products
      WHERE organization_id = _organization_id
        AND active
        AND normalized_name = _catalog_product.normalized_name
      LIMIT 1;

      IF FOUND THEN
        IF _name_twin.catalog_product_id IS NULL THEN
          RAISE EXCEPTION
            'An active organization product already uses normalized name %; manual reconciliation is required',
            _catalog_product.normalized_name
            USING ERRCODE = '23505',
              HINT = jsonb_build_object('conflictType', 'name_twin_local', 'productId', _name_twin.id)::text;
        END IF;

        _product_name := _catalog_product.name || ' (' || _catalog_vendor_product.vendor_sku || ')';
        SELECT *
        INTO _name_twin
        FROM public.products
        WHERE organization_id = _organization_id
          AND active
          AND normalized_name = public.normalize_catalog_text(_product_name)
        LIMIT 1;

        IF FOUND THEN
          RAISE EXCEPTION
            'An active organization product already uses normalized name %; manual reconciliation is required',
            public.normalize_catalog_text(_product_name)
            USING ERRCODE = '23505',
              HINT = jsonb_build_object('conflictType', 'name_twin_taken', 'productId', _name_twin.id)::text;
        END IF;
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
        _product_name,
        _verified_unit,
        _adopted_active,
        public.normalize_catalog_text(_product_name),
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

REVOKE ALL ON FUNCTION public.adopt_catalog_vendor_product(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.adopt_catalog_vendor_product(uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.adopt_catalog_vendor_product(uuid, uuid) IS
  'Atomically and idempotently adopts one global catalog vendor listing into an organization catalog. Owner/admin only; never links an existing organization vendor (link it in Catalog Vendors first); inventory is never created or changed. A product named like an active product linked to a different catalog product is created under that name qualified by the vendor SKU; refusals carry a JSON HINT naming the conflict.';


CREATE OR REPLACE FUNCTION public.match_invoice_item_to_catalog_listing(
  _organization_id uuid,
  _source_file_id uuid,
  _invoice_item_id uuid,
  _catalog_vendor_product_id uuid,
  _expected_product_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _invoice public.invoices%ROWTYPE;
  _line public.invoice_items%ROWTYPE;
  _vendor public.vendors%ROWTYPE;
  _listing public.catalog_vendor_products%ROWTYPE;
  _adoption jsonb;
  _confirmation jsonb;
  _product_id uuid;
  _vendor_product_id uuid;
  _adoption_error text;
  _adoption_hint text;
  _conflict jsonb;
  _conflict_type text;
  _conflict_product public.products%ROWTYPE;
  _conflict_vendor_product public.vendor_products%ROWTYPE;
  _adopted_product public.products%ROWTYPE;
  _can_match_existing boolean := false;
  _explanation text;
BEGIN
  IF NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;
  SELECT * INTO _invoice FROM public.invoices
  WHERE organization_id = _organization_id AND source_file_id = _source_file_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice review not found'; END IF;
  IF _invoice.posted_at IS NOT NULL OR _invoice.processing_status = 'completed' THEN
    RAISE EXCEPTION 'Completed invoices cannot be changed';
  END IF;
  IF _invoice.vendor_id IS NULL THEN
    RAISE EXCEPTION 'Select an existing vendor before matching to a vendor catalog';
  END IF;
  SELECT * INTO _vendor FROM public.vendors
  WHERE id = _invoice.vendor_id AND organization_id = _organization_id AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'The invoice vendor is unavailable'; END IF;
  IF _vendor.catalog_vendor_id IS NULL THEN
    RAISE EXCEPTION 'The invoice vendor is not linked to a catalog vendor';
  END IF;

  -- Vendor scope: only a listing of the invoice vendor's own linked catalog vendor.
  SELECT * INTO _listing FROM public.catalog_vendor_products
  WHERE id = _catalog_vendor_product_id;
  IF NOT FOUND OR _listing.catalog_vendor_id IS DISTINCT FROM _vendor.catalog_vendor_id THEN
    RAISE EXCEPTION 'That catalog item does not belong to the invoice vendor''s catalog';
  END IF;
  IF NOT _listing.active
     OR _listing.discontinued
     OR _listing.verification_status = 'rejected'
     OR NOT EXISTS (
       SELECT 1 FROM public.catalog_vendors catalog_vendor
       WHERE catalog_vendor.id = _listing.catalog_vendor_id AND catalog_vendor.active
     )
     OR NOT EXISTS (
       SELECT 1 FROM public.catalog_products catalog_product
       WHERE catalog_product.id = _listing.catalog_product_id
         AND catalog_product.active
         AND catalog_product.verification_status <> 'rejected'
     ) THEN
    RAISE EXCEPTION 'That catalog item is not available to match';
  END IF;

  SELECT * INTO _line FROM public.invoice_items
  WHERE id = _invoice_item_id AND invoice_id = _invoice.id AND organization_id = _organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice line not found'; END IF;
  IF _line.product_id IS DISTINCT FROM _expected_product_id THEN
    RAISE EXCEPTION 'This line''s product match has changed; reload the invoice before changing it';
  END IF;

  -- Existing Phase 5A.5 adoption: idempotent, one organization product per canonical
  -- product, one mapping per listing, and never creates or changes inventory. If it needs
  -- reconciliation (an existing product or vendor SKU mapping conflicts with the listing),
  -- its partial writes roll back and the owner gets a controlled error instead of the
  -- constraint failure.
  BEGIN
    _adoption := public.adopt_catalog_vendor_product(_organization_id, _listing.id);
  EXCEPTION WHEN unique_violation OR check_violation OR foreign_key_violation THEN
    GET STACKED DIAGNOSTICS _adoption_error = MESSAGE_TEXT, _adoption_hint = PG_EXCEPTION_HINT;
    -- Adoption names the conflict in a JSON hint. Anything else (an unexpected constraint)
    -- keeps the general message.
    BEGIN
      _conflict := nullif(_adoption_hint, '')::jsonb;
    EXCEPTION WHEN OTHERS THEN
      _conflict := NULL;
    END;
    IF jsonb_typeof(_conflict) IS DISTINCT FROM 'object' THEN
      _conflict := NULL;
    END IF;
    _conflict_type := coalesce(_conflict->>'conflictType', 'unknown');
    IF _conflict->>'productId' IS NOT NULL THEN
      SELECT * INTO _conflict_product FROM public.products
      WHERE id = (_conflict->>'productId')::uuid AND organization_id = _organization_id;
    END IF;
    IF _conflict->>'vendorProductId' IS NOT NULL THEN
      SELECT * INTO _conflict_vendor_product FROM public.vendor_products
      WHERE id = (_conflict->>'vendorProductId')::uuid AND organization_id = _organization_id;
    END IF;
    IF _conflict->>'adoptedProductId' IS NOT NULL THEN
      SELECT * INTO _adopted_product FROM public.products
      WHERE id = (_conflict->>'adoptedProductId')::uuid AND organization_id = _organization_id;
    END IF;
    -- Matching to the existing product is offered only when it is safe reuse: this line's
    -- own vendor SKU already resolves to the product through an active mapping of the
    -- invoice vendor, AND the product is the selected catalog identity (or is unlinked and
    -- no other product holds that identity). A product linked to a different catalog
    -- product is a genuine contradiction and is never offered; neither is a product that
    -- merely shares a name. This is the only place reuse safety is decided.
    _can_match_existing :=
      _conflict_type IN ('sku_mapped_to_other_product', 'sku_mapped_to_other_listing')
      AND _conflict_product.id IS NOT NULL
      AND _conflict_product.active
      AND _conflict_vendor_product.id IS NOT NULL
      AND _conflict_vendor_product.active
      AND _conflict_vendor_product.vendor_id = _invoice.vendor_id
      AND _conflict_vendor_product.product_id = _conflict_product.id
      AND coalesce(public.normalize_catalog_sku_match_key(_line.sku), '') <> ''
      AND public.normalize_catalog_sku_match_key(_line.sku) = public.normalize_catalog_sku_match_key(_listing.vendor_sku)
      AND (
        _conflict_product.catalog_product_id = _listing.catalog_product_id
        OR (
          _conflict_product.catalog_product_id IS NULL
          AND NOT EXISTS (
            SELECT 1 FROM public.products holder
            WHERE holder.organization_id = _organization_id
              AND holder.catalog_product_id = _listing.catalog_product_id
              AND holder.id <> _conflict_product.id
          )
        )
      );
    _explanation := CASE
      WHEN _conflict_type IN ('sku_mapped_to_other_product', 'sku_mapped_to_other_listing')
           AND _conflict_product.id IS NOT NULL AND _can_match_existing THEN
        format('Vendor SKU %s is already mapped to "%s", which is this catalog item. Match this line to "%s".', _listing.vendor_sku, _conflict_product.name, _conflict_product.name)
      WHEN _conflict_type IN ('sku_mapped_to_other_product', 'sku_mapped_to_other_listing')
           AND _conflict_product.id IS NOT NULL THEN
        format('Vendor SKU %s is already mapped to "%s", which is linked to a different catalog item. Correct that mapping in Catalog first.', _listing.vendor_sku, _conflict_product.name)
      WHEN _conflict_type = 'catalog_product_adopted_elsewhere'
           AND _conflict_product.id IS NOT NULL AND _adopted_product.id IS NOT NULL THEN
        format('Vendor SKU %s is mapped to "%s", but this catalog item is already "%s" in your products. Correct that mapping in Catalog first.', _listing.vendor_sku, _conflict_product.name, _adopted_product.name)
      WHEN _conflict_type = 'name_twin_local' AND _conflict_product.id IS NOT NULL THEN
        format('Your products already has "%s", which is not linked to the catalog. If it is the same item, choose it under Your products; otherwise rename it in Catalog first.', _conflict_product.name)
      WHEN _conflict_type = 'name_twin_taken' AND _conflict_product.id IS NOT NULL THEN
        format('Your products already has "%s". If it is the same item, choose it under Your products; otherwise rename it in Catalog first.', _conflict_product.name)
      WHEN _conflict_type = 'multiple_sku_mappings' THEN
        format('Vendor SKU %s is mapped to more than one of your products. Resolve the duplicate mappings in Catalog first.', _listing.vendor_sku)
      ELSE 'Choose the existing product under Your products, or resolve the conflict in Catalog first.'
    END;
    RAISE EXCEPTION '%', 'This catalog item conflicts with a product or vendor SKU mapping your organization already has, so it cannot be added automatically. ' || _explanation
      USING DETAIL = _adoption_error,
        HINT = jsonb_build_object(
          'conflictType', _conflict_type,
          'productId', _conflict_product.id,
          'productName', _conflict_product.name,
          'vendorProductId', _conflict_vendor_product.id,
          'vendorSku', _listing.vendor_sku,
          'canMatchExisting', _can_match_existing
        )::text;
  END;
  _product_id := (_adoption->>'productId')::uuid;
  _vendor_product_id := (_adoption->>'vendorProductId')::uuid;
  IF (_adoption->>'vendorId')::uuid IS DISTINCT FROM _invoice.vendor_id
     OR NOT EXISTS (
       SELECT 1 FROM public.vendor_products
       WHERE id = _vendor_product_id AND organization_id = _organization_id
         AND vendor_id = _invoice.vendor_id AND product_id = _product_id AND active
     )
     OR NOT EXISTS (
       SELECT 1 FROM public.products
       WHERE id = _product_id AND organization_id = _organization_id AND active
     ) THEN
    RAISE EXCEPTION 'Catalog adoption did not produce an active mapping for the invoice vendor';
  END IF;

  -- The existing manual confirmation decides the vendor SKU mapping, exactly as it does
  -- for any other owner-chosen product: the adopted mapping is reused when the invoice SKU
  -- is the listing's own (separators aside), a different invoice SKU is remembered for the
  -- adopted product, and a catalog-adopted mapping for another product is never changed.
  _confirmation := public.confirm_invoice_item_product(
    _organization_id, _source_file_id, _invoice_item_id, _product_id, true);
  _vendor_product_id := (_confirmation->>'vendorProductId')::uuid;

  RETURN jsonb_build_object(
    'productId', _product_id,
    'vendorProductId', _vendor_product_id,
    'vendorSkuRemembered', _vendor_product_id IS NOT NULL,
    'preservedVendorProductId', (_confirmation->>'preservedVendorProductId')::uuid,
    'catalogVendorProductId', _listing.id,
    'productCreated', coalesce((_adoption->>'productCreated')::boolean, false),
    'vendorProductCreated', coalesce((_adoption->>'vendorProductCreated')::boolean, false),
    'alreadyAdopted', coalesce((_adoption->>'alreadyAdopted')::boolean, false)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.match_invoice_item_to_catalog_listing(uuid, uuid, uuid, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.match_invoice_item_to_catalog_listing(uuid, uuid, uuid, uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.match_invoice_item_to_catalog_listing(uuid, uuid, uuid, uuid, uuid) IS
  'Owner-only manual decision: adopts one listing of the invoice vendor''s linked catalog vendor (existing idempotent adoption, no inventory) and matches the invoice line to it with manual provenance. Never approves, posts, or stocks. A refused adoption raises a reviewer message naming the conflict, with a JSON HINT (conflictType, productId, productName, vendorProductId, vendorSku, canMatchExisting); canMatchExisting is true only for safe reuse of the same catalog identity, never for a SKU mapped to a different catalog item.';

COMMIT;
