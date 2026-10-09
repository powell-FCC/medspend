-- Phase 6C.1: invoice exact-match auto-resolution.
--
-- Automate certainty, surface ambiguity. After extraction, an invoice line is linked to
-- a product without a click only when the invoice vendor plus the line's vendor SKU
-- identifies exactly one product:
--
--   1. an existing organization vendor mapping (vendor_products) for this vendor;
--   2. otherwise, one verified global catalog listing for the catalog vendor that this
--      organization vendor is already explicitly linked to (vendors.catalog_vendor_id),
--      adopted through the existing adopt_catalog_vendor_product RPC.
--
-- At each tier the authoritative SKU (normalize_catalog_sku: trim + uppercase) is tried
-- first. Only when that finds nothing, and only when the invoice SKU itself contains no
-- separators, the existing vendor-scoped separator-insensitive key
-- (normalize_catalog_sku_match_key) may be used, and only if exactly one row shares it.
-- Stored and canonical SKUs are never rewritten. Any ambiguity is left for human review.
--
-- Descriptions, manufacturers, package text, and units never resolve identity. Human
-- decisions (manual matches and manual unlinks) are never changed by the resolver.
-- Resolution never stocks inventory, posts or approves an invoice, or touches requests,
-- commitments, purchasing, receiving, or price intelligence.
--
-- Posting becomes the authoritative identity boundary: post_reviewed_invoice refuses any
-- invoice with an unlinked line, and its legacy identity inference (vendor-agnostic
-- inventory SKU lookup, product-name lookup, product creation, and creating or repointing
-- a vendor-SKU mapping the review left unset) is removed. Inventory accounting is unchanged.

BEGIN;

DO $phase6c1_preflight$
BEGIN
  IF to_regprocedure('public.adopt_catalog_vendor_product(uuid, uuid)') IS NULL
     OR to_regprocedure('public.normalize_catalog_sku(text)') IS NULL
     OR to_regprocedure('public.normalize_catalog_sku_match_key(text)') IS NULL
     OR to_regprocedure('public.rematch_invoice_vendor_products(uuid, uuid)') IS NULL
     OR to_regprocedure('public.confirm_invoice_item_product(uuid, uuid, uuid, uuid, boolean)') IS NULL
     OR to_regprocedure('public.unlink_invoice_item_product(uuid, uuid, uuid, boolean)') IS NULL
     OR to_regprocedure('public.create_product_from_invoice_item(uuid, uuid, uuid)') IS NULL
     OR to_regprocedure('public.post_reviewed_invoice(uuid, uuid)') IS NULL THEN
    RAISE EXCEPTION 'Phase 6C.1 requires the Phase 2D, 3A.4, 3A.4.1, 5A.4A, and 5A.5 invoice and catalog functions';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'vendors' AND column_name = 'catalog_vendor_id'
  ) THEN
    RAISE EXCEPTION 'Phase 6C.1 requires vendors.catalog_vendor_id (Phase 5A.4A)';
  END IF;
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'invoice_items' AND column_name = 'product_match_source'
  ) THEN
    RAISE EXCEPTION 'Phase 6C.1 has already been applied (invoice_items.product_match_source exists)';
  END IF;
END
$phase6c1_preflight$;

-- Provenance: why does this line point at its product?
--   NULL                          never decided (legacy links made before 6C.1 also stay NULL)
--   manual                        an owner chose the product
--   manual_cleared                an owner removed the match; the resolver must leave the line alone
--   org_vendor_sku                organization vendor mapping, authoritative SKU
--   org_vendor_sku_match_key      organization vendor mapping, separator-insensitive key
--   catalog_vendor_sku            verified global catalog listing, authoritative SKU
--   catalog_vendor_sku_match_key  verified global catalog listing, separator-insensitive key
ALTER TABLE public.invoice_items
  ADD COLUMN product_match_source text,
  ADD COLUMN product_match_decided_at timestamptz,
  ADD CONSTRAINT invoice_items_product_match_source_check CHECK (
    product_match_source IS NULL OR product_match_source IN (
      'manual', 'manual_cleared',
      'org_vendor_sku', 'org_vendor_sku_match_key',
      'catalog_vendor_sku', 'catalog_vendor_sku_match_key'
    )
  ),
  ADD CONSTRAINT invoice_items_product_match_source_consistent CHECK (
    product_match_source IS NULL
    OR product_match_source = 'manual_cleared'
    OR (product_match_source = 'manual' AND product_id IS NOT NULL)
    OR (
      product_match_source IN (
        'org_vendor_sku', 'org_vendor_sku_match_key',
        'catalog_vendor_sku', 'catalog_vendor_sku_match_key'
      )
      AND product_id IS NOT NULL
      AND vendor_product_id IS NOT NULL
      AND product_match_decided_at IS NOT NULL
    )
  );

COMMENT ON COLUMN public.invoice_items.product_match_source IS
  'Phase 6C.1 identity provenance. manual/manual_cleared are human decisions the resolver never changes; the other values record which exact vendor-SKU tier resolved the line.';
COMMENT ON COLUMN public.invoice_items.product_match_decided_at IS
  'When the current product_match_source decision was made.';

-- API writes (the owner-only invoice_items RLS policy) cannot forge machine provenance.
-- Any client change to a line's product link is a human decision. Correcting the SKU of
-- an unlinked line makes it eligible for exact resolution again. SECURITY DEFINER RPCs
-- run as the function owner and set provenance explicitly.
CREATE FUNCTION public.guard_invoice_item_match_provenance()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF current_user IN ('authenticated', 'anon') THEN
    IF TG_OP = 'INSERT'
       OR NEW.product_id IS DISTINCT FROM OLD.product_id
       OR NEW.vendor_product_id IS DISTINCT FROM OLD.vendor_product_id THEN
      NEW.product_match_source := CASE WHEN NEW.product_id IS NULL THEN NULL ELSE 'manual' END;
      NEW.product_match_decided_at := CASE WHEN NEW.product_id IS NULL THEN NULL ELSE now() END;
    ELSIF NEW.product_id IS NULL AND NEW.sku IS DISTINCT FROM OLD.sku THEN
      NEW.product_match_source := NULL;
      NEW.product_match_decided_at := NULL;
    ELSE
      NEW.product_match_source := OLD.product_match_source;
      NEW.product_match_decided_at := OLD.product_match_decided_at;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.guard_invoice_item_match_provenance() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER invoice_items_match_provenance_guard
  BEFORE INSERT OR UPDATE ON public.invoice_items
  FOR EACH ROW EXECUTE FUNCTION public.guard_invoice_item_match_provenance();

-- Pure decision: which single identity, if any, does this vendor + SKU name?
-- decision is 'resolve' (existing organization mapping), 'adopt' (one verified catalog
-- listing), or 'review' (reason says why). It never writes.
CREATE FUNCTION public.find_invoice_line_exact_identity(
  _organization_id uuid,
  _vendor_id uuid,
  _sku text
)
RETURNS TABLE (
  decision text,
  reason text,
  match_source text,
  vendor_product_id uuid,
  product_id uuid,
  catalog_vendor_product_id uuid
)
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
  _strict text := public.normalize_catalog_sku(_sku);
  _key text := public.normalize_catalog_sku_match_key(_sku);
  _separator_free boolean;
  _use_key boolean := false;
  _count bigint;
  _mapping public.vendor_products%ROWTYPE;
  _catalog_vendor_id uuid;
  _listing public.catalog_vendor_products%ROWTYPE;
BEGIN
  IF _organization_id IS NULL OR _vendor_id IS NULL THEN
    RETURN QUERY SELECT 'review'::text, 'no_vendor'::text, NULL::text, NULL::uuid, NULL::uuid, NULL::uuid;
    RETURN;
  END IF;
  IF _strict = '' OR _key = '' THEN
    RETURN QUERY SELECT 'review'::text, 'no_sku'::text, NULL::text, NULL::uuid, NULL::uuid, NULL::uuid;
    RETURN;
  END IF;
  -- The separator-insensitive key is only a fallback for an invoice SKU that is already
  -- bare (letters and digits only), e.g. invoice 3980143 for catalog 398-0143.
  _separator_free := _strict = _key;

  -- Tier 1: this organization's mappings for this vendor. Inactive rows count: an owner
  -- who deactivated ("forgot") a mapping made a decision this tier must not route around.
  SELECT count(*) INTO _count
  FROM public.vendor_products mapping
  WHERE mapping.organization_id = _organization_id
    AND mapping.vendor_id = _vendor_id
    AND public.normalize_catalog_sku(mapping.vendor_sku) = _strict;

  IF _count = 0 AND _separator_free THEN
    _use_key := true;
    SELECT count(*) INTO _count
    FROM public.vendor_products mapping
    WHERE mapping.organization_id = _organization_id
      AND mapping.vendor_id = _vendor_id
      AND public.normalize_catalog_sku_match_key(mapping.vendor_sku) = _key;
  END IF;

  IF _count > 1 THEN
    RETURN QUERY SELECT 'review'::text, 'ambiguous_organization_mapping'::text, NULL::text, NULL::uuid, NULL::uuid, NULL::uuid;
    RETURN;
  END IF;

  IF _count = 1 THEN
    SELECT mapping.* INTO STRICT _mapping
    FROM public.vendor_products mapping
    WHERE mapping.organization_id = _organization_id
      AND mapping.vendor_id = _vendor_id
      AND CASE WHEN _use_key
        THEN public.normalize_catalog_sku_match_key(mapping.vendor_sku) = _key
        ELSE public.normalize_catalog_sku(mapping.vendor_sku) = _strict
      END;
    IF NOT _mapping.active THEN
      RETURN QUERY SELECT 'review'::text, 'inactive_organization_mapping'::text, NULL::text, NULL::uuid, NULL::uuid, NULL::uuid;
      RETURN;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.products product
      WHERE product.id = _mapping.product_id
        AND product.organization_id = _organization_id
        AND product.active
    ) THEN
      RETURN QUERY SELECT 'review'::text, 'inactive_organization_product'::text, NULL::text, NULL::uuid, NULL::uuid, NULL::uuid;
      RETURN;
    END IF;
    RETURN QUERY SELECT
      'resolve'::text,
      NULL::text,
      CASE WHEN _use_key THEN 'org_vendor_sku_match_key' ELSE 'org_vendor_sku' END,
      _mapping.id,
      _mapping.product_id,
      _mapping.catalog_vendor_product_id;
    RETURN;
  END IF;

  -- Tier 2: the verified global catalog, only through an explicit vendor link.
  SELECT vendor.catalog_vendor_id INTO _catalog_vendor_id
  FROM public.vendors vendor
  WHERE vendor.id = _vendor_id AND vendor.organization_id = _organization_id;

  IF _catalog_vendor_id IS NULL THEN
    RETURN QUERY SELECT 'review'::text, 'vendor_not_linked_to_catalog'::text, NULL::text, NULL::uuid, NULL::uuid, NULL::uuid;
    RETURN;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.catalog_vendors catalog_vendor
    WHERE catalog_vendor.id = _catalog_vendor_id AND catalog_vendor.active
  ) THEN
    RETURN QUERY SELECT 'review'::text, 'catalog_vendor_inactive'::text, NULL::text, NULL::uuid, NULL::uuid, NULL::uuid;
    RETURN;
  END IF;

  -- An organization mapping that differs only by separators (e.g. a remembered 3980143
  -- when the invoice says 398-0143) is a conflict, never a reason to adopt a second row.
  IF EXISTS (
    SELECT 1 FROM public.vendor_products mapping
    WHERE mapping.organization_id = _organization_id
      AND mapping.vendor_id = _vendor_id
      AND public.normalize_catalog_sku_match_key(mapping.vendor_sku) = _key
  ) THEN
    RETURN QUERY SELECT 'review'::text, 'organization_mapping_conflict'::text, NULL::text, NULL::uuid, NULL::uuid, NULL::uuid;
    RETURN;
  END IF;

  _use_key := false;
  SELECT count(*) INTO _count
  FROM public.catalog_vendor_products listing
  WHERE listing.catalog_vendor_id = _catalog_vendor_id
    AND listing.normalized_vendor_sku = _strict;

  IF _count = 0 AND _separator_free THEN
    _use_key := true;
    SELECT count(*) INTO _count
    FROM public.catalog_vendor_products listing
    WHERE listing.catalog_vendor_id = _catalog_vendor_id
      AND listing.vendor_sku_match_key = _key;
  END IF;

  IF _count = 0 THEN
    RETURN QUERY SELECT 'review'::text, 'no_exact_identity'::text, NULL::text, NULL::uuid, NULL::uuid, NULL::uuid;
    RETURN;
  END IF;
  IF _count > 1 THEN
    RETURN QUERY SELECT 'review'::text, 'ambiguous_catalog_listing'::text, NULL::text, NULL::uuid, NULL::uuid, NULL::uuid;
    RETURN;
  END IF;

  SELECT listing.* INTO STRICT _listing
  FROM public.catalog_vendor_products listing
  WHERE listing.catalog_vendor_id = _catalog_vendor_id
    AND CASE WHEN _use_key
      THEN listing.vendor_sku_match_key = _key
      ELSE listing.normalized_vendor_sku = _strict
    END;

  IF NOT _listing.active
     OR _listing.discontinued
     OR _listing.verification_status <> 'verified'
     OR NOT EXISTS (
       SELECT 1 FROM public.catalog_products catalog_product
       WHERE catalog_product.id = _listing.catalog_product_id
         AND catalog_product.active
         AND catalog_product.verification_status = 'verified'
     ) THEN
    RETURN QUERY SELECT 'review'::text, 'catalog_listing_not_authoritative'::text, NULL::text, NULL::uuid, NULL::uuid, NULL::uuid;
    RETURN;
  END IF;

  RETURN QUERY SELECT
    'adopt'::text,
    NULL::text,
    CASE WHEN _use_key THEN 'catalog_vendor_sku_match_key' ELSE 'catalog_vendor_sku' END,
    NULL::uuid,
    NULL::uuid,
    _listing.id;
END;
$$;

REVOKE ALL ON FUNCTION public.find_invoice_line_exact_identity(uuid, uuid, text) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.find_invoice_line_exact_identity(uuid, uuid, text) IS
  'Phase 6C.1 private decision helper. Vendor-scoped exact SKU identity only; never uses descriptions, manufacturers, package text, or units.';

-- Applies the decisions to one draft invoice. Callers own authorization and the invoice
-- row lock. Only lines with no product and no recorded decision are considered, so
-- reruns are no-ops for resolved lines and human decisions are never revisited.
CREATE FUNCTION public.apply_invoice_exact_product_identities(
  _organization_id uuid,
  _invoice_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  _invoice public.invoices%ROWTYPE;
  _line public.invoice_items%ROWTYPE;
  _decision record;
  _adoption jsonb;
  _vendor_product_id uuid;
  _product_id uuid;
  _organization_resolved integer := 0;
  _catalog_resolved integer := 0;
  _adopted integer := 0;
  _review integer := 0;
  _reasons jsonb := '{}'::jsonb;
BEGIN
  SELECT * INTO _invoice FROM public.invoices
  WHERE id = _invoice_id AND organization_id = _organization_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice review not found'; END IF;
  IF _invoice.posted_at IS NOT NULL OR _invoice.processing_status = 'completed' THEN
    RETURN jsonb_build_object('invoiceId', _invoice.id, 'skipped', 'completed');
  END IF;
  IF _invoice.vendor_id IS NULL THEN
    RETURN jsonb_build_object('invoiceId', _invoice.id, 'skipped', 'no_vendor');
  END IF;
  PERFORM 1 FROM public.vendors
  WHERE id = _invoice.vendor_id AND organization_id = _organization_id AND active;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('invoiceId', _invoice.id, 'skipped', 'vendor_unavailable');
  END IF;

  FOR _line IN
    SELECT * FROM public.invoice_items
    WHERE invoice_id = _invoice.id
      AND organization_id = _organization_id
      AND product_id IS NULL
      AND product_match_source IS NULL
    ORDER BY line_number NULLS LAST, created_at, id
    FOR UPDATE
  LOOP
    SELECT * INTO _decision
    FROM public.find_invoice_line_exact_identity(_organization_id, _invoice.vendor_id, _line.sku);

    IF _decision.decision = 'resolve' THEN
      UPDATE public.invoice_items SET
        product_id = _decision.product_id,
        vendor_product_id = _decision.vendor_product_id,
        product_match_source = _decision.match_source,
        product_match_decided_at = now()
      WHERE id = _line.id AND product_id IS NULL AND product_match_source IS NULL;
      _organization_resolved := _organization_resolved + 1;
    ELSIF _decision.decision = 'adopt' THEN
      BEGIN
        -- Existing Phase 5A.5 adoption: idempotent, per-organization advisory lock,
        -- unique adoption links, and never creates or changes inventory.
        _adoption := public.adopt_catalog_vendor_product(_organization_id, _decision.catalog_vendor_product_id);
        _vendor_product_id := (_adoption->>'vendorProductId')::uuid;
        _product_id := (_adoption->>'productId')::uuid;
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
        UPDATE public.invoice_items SET
          product_id = _product_id,
          vendor_product_id = _vendor_product_id,
          product_match_source = _decision.match_source,
          product_match_decided_at = now()
        WHERE id = _line.id AND product_id IS NULL AND product_match_source IS NULL;
        _catalog_resolved := _catalog_resolved + 1;
        IF (_adoption->>'vendorProductCreated')::boolean THEN _adopted := _adopted + 1; END IF;
      EXCEPTION WHEN OTHERS THEN
        -- Adoption needs reconciliation (e.g. a same-name local product). Its partial
        -- writes are rolled back with this block; the line stays for human review.
        _review := _review + 1;
        _reasons := jsonb_set(_reasons, ARRAY['catalog_adoption_requires_review'],
          to_jsonb(coalesce((_reasons->>'catalog_adoption_requires_review')::integer, 0) + 1));
      END;
    ELSE
      _review := _review + 1;
      _reasons := jsonb_set(_reasons, ARRAY[_decision.reason],
        to_jsonb(coalesce((_reasons->>_decision.reason)::integer, 0) + 1));
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'invoiceId', _invoice.id,
    'resolvedFromOrganizationMapping', _organization_resolved,
    'resolvedFromCatalog', _catalog_resolved,
    'adoptedCatalogProducts', _adopted,
    'needsReview', _review,
    'reviewReasons', _reasons
  );
END;
$$;

REVOKE ALL ON FUNCTION public.apply_invoice_exact_product_identities(uuid, uuid) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.resolve_invoice_exact_product_identities(
  _organization_id uuid,
  _source_file_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _invoice public.invoices%ROWTYPE;
BEGIN
  IF NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;
  -- The same invoice row lock as confirm, unlink, rematch, and posting: concurrent
  -- resolution of one invoice is serialized and the second pass finds nothing to do.
  SELECT * INTO _invoice FROM public.invoices
  WHERE organization_id = _organization_id AND source_file_id = _source_file_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice review not found'; END IF;
  RETURN public.apply_invoice_exact_product_identities(_organization_id, _invoice.id);
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_invoice_exact_product_identities(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolve_invoice_exact_product_identities(uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.resolve_invoice_exact_product_identities(uuid, uuid) IS
  'Phase 6C.1: owner-only, idempotent exact vendor-SKU product identity resolution for one draft invoice. Never approves, posts, or stocks.';

-- Phase 3A.4.1 rematch, unchanged except that cleared links lose their provenance and
-- matching now goes through the Phase 6C.1 resolver (unique, provenance-recording,
-- manual-decision-preserving) instead of an unconstrained UPDATE ... FROM.
CREATE OR REPLACE FUNCTION public.rematch_invoice_vendor_products(
  _organization_id uuid,
  _source_file_id uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _invoice public.invoices%ROWTYPE;
  _result jsonb;
BEGIN
  IF NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;

  SELECT * INTO _invoice FROM public.invoices
    WHERE organization_id = _organization_id AND source_file_id = _source_file_id
    FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice review not found'; END IF;
  IF _invoice.posted_at IS NOT NULL OR _invoice.processing_status = 'completed' THEN
    RAISE EXCEPTION 'Completed invoices cannot be changed';
  END IF;

  -- A vendor_product_id records vendor-context provenance. Clear only links whose
  -- remembered mapping is no longer safe; manually confirmed product-only links remain intact.
  UPDATE public.invoice_items AS item
    SET product_id = NULL, vendor_product_id = NULL, review_status = 'pending_review',
        product_match_source = NULL, product_match_decided_at = NULL
  FROM public.vendor_products AS mapping
  WHERE item.organization_id = _organization_id
    AND item.invoice_id = _invoice.id
    AND item.vendor_product_id = mapping.id
    AND (
      _invoice.vendor_id IS NULL
      OR mapping.organization_id <> _organization_id
      OR mapping.vendor_id <> _invoice.vendor_id
      OR mapping.active = false
    );

  IF _invoice.vendor_id IS NULL THEN RETURN 0; END IF;

  _result := public.apply_invoice_exact_product_identities(_organization_id, _invoice.id);
  RETURN coalesce((_result->>'resolvedFromOrganizationMapping')::integer, 0)
    + coalesce((_result->>'resolvedFromCatalog')::integer, 0);
END;
$$;

-- Phase 3A.4 human decisions, unchanged except that they now record provenance.
CREATE OR REPLACE FUNCTION public.confirm_invoice_item_product(
  _organization_id uuid,
  _source_file_id uuid,
  _invoice_item_id uuid,
  _product_id uuid,
  _remember_vendor_sku boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _invoice public.invoices%ROWTYPE;
  _line public.invoice_items%ROWTYPE;
  _vendor_product_id uuid;
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
  PERFORM 1 FROM public.products
    WHERE id = _product_id AND organization_id = _organization_id AND active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'Selected product is unavailable'; END IF;
  SELECT * INTO _line FROM public.invoice_items
    WHERE id = _invoice_item_id AND invoice_id = _invoice.id AND organization_id = _organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice line not found'; END IF;

  IF _remember_vendor_sku AND nullif(btrim(_line.sku), '') IS NOT NULL THEN
    IF _invoice.vendor_id IS NULL THEN RAISE EXCEPTION 'Select an existing vendor before remembering a vendor SKU'; END IF;
    SELECT id INTO _vendor_product_id FROM public.vendor_products
      WHERE organization_id = _organization_id AND vendor_id = _invoice.vendor_id
        AND lower(btrim(vendor_sku)) = lower(btrim(_line.sku))
      ORDER BY active DESC, created_at LIMIT 1 FOR UPDATE;
    IF _vendor_product_id IS NULL THEN
      INSERT INTO public.vendor_products
        (organization_id, vendor_id, product_id, vendor_sku, package_size, unit_of_measure)
      VALUES
        (_organization_id, _invoice.vendor_id, _product_id, btrim(_line.sku),
         nullif(btrim(_line.package_size), ''), nullif(btrim(_line.unit_of_measure), ''))
      RETURNING id INTO _vendor_product_id;
    ELSE
      UPDATE public.vendor_products SET product_id = _product_id,
        package_size = coalesce(nullif(btrim(_line.package_size), ''), package_size),
        unit_of_measure = coalesce(nullif(btrim(_line.unit_of_measure), ''), unit_of_measure), active = true
      WHERE id = _vendor_product_id;
    END IF;
  END IF;
  UPDATE public.invoice_items SET product_id = _product_id,
    vendor_product_id = _vendor_product_id, review_status = 'pending_review',
    product_match_source = 'manual', product_match_decided_at = now()
  WHERE id = _line.id;
  RETURN jsonb_build_object('productId', _product_id, 'vendorProductId', _vendor_product_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.unlink_invoice_item_product(
  _organization_id uuid,
  _source_file_id uuid,
  _invoice_item_id uuid,
  _forget_mapping boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _invoice public.invoices%ROWTYPE;
  _line public.invoice_items%ROWTYPE;
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
  SELECT * INTO _line FROM public.invoice_items
    WHERE id = _invoice_item_id AND invoice_id = _invoice.id AND organization_id = _organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice line not found'; END IF;
  IF _forget_mapping AND _line.vendor_product_id IS NOT NULL THEN
    UPDATE public.vendor_products SET active = false
      WHERE id = _line.vendor_product_id AND organization_id = _organization_id;
  END IF;
  -- An owner's unlink is a decision: the resolver must not re-link this line.
  UPDATE public.invoice_items SET product_id = NULL, vendor_product_id = NULL,
    review_status = 'pending_review',
    product_match_source = 'manual_cleared', product_match_decided_at = now()
  WHERE id = _line.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_product_from_invoice_item(
  _organization_id uuid,
  _source_file_id uuid,
  _invoice_item_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _invoice public.invoices%ROWTYPE;
  _line public.invoice_items%ROWTYPE;
  _product_id uuid;
  _vendor_product_id uuid;
  _category_id uuid;
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
  IF _invoice.vendor_id IS NULL THEN RAISE EXCEPTION 'Select an existing vendor before creating a product'; END IF;
  SELECT * INTO _line FROM public.invoice_items
    WHERE id = _invoice_item_id AND invoice_id = _invoice.id AND organization_id = _organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice line not found'; END IF;
  IF _line.product_id IS NOT NULL THEN
    RETURN jsonb_build_object('productId', _line.product_id, 'vendorProductId', _line.vendor_product_id);
  END IF;
  IF nullif(btrim(_line.category), '') IS NOT NULL THEN
    SELECT id INTO _category_id FROM public.product_categories
      WHERE organization_id = _organization_id AND active = true
        AND normalized_name = public.normalize_catalog_text(_line.category) LIMIT 1;
  END IF;
  INSERT INTO public.products
    (organization_id, name, description, category_id, manufacturer, preferred_vendor_id,
     unit, unit_of_measure, pack_size, approved, active, staff_requestable)
  VALUES
    (_organization_id, btrim(_line.description), btrim(_line.description), _category_id,
     nullif(btrim(_line.manufacturer), ''), _invoice.vendor_id,
     coalesce(nullif(btrim(_line.unit_of_measure), ''), 'each'),
     coalesce(nullif(btrim(_line.unit_of_measure), ''), 'each'),
     nullif(btrim(_line.package_size), ''), true, true, true)
  RETURNING id INTO _product_id;
  IF nullif(btrim(_line.sku), '') IS NOT NULL THEN
    INSERT INTO public.vendor_products
      (organization_id, vendor_id, product_id, vendor_sku, package_size, unit_of_measure)
    VALUES
      (_organization_id, _invoice.vendor_id, _product_id, btrim(_line.sku),
       nullif(btrim(_line.package_size), ''), nullif(btrim(_line.unit_of_measure), ''))
    ON CONFLICT DO NOTHING RETURNING id INTO _vendor_product_id;
    IF _vendor_product_id IS NULL THEN
      RAISE EXCEPTION 'This vendor SKU already maps to another product; choose or correct that match instead';
    END IF;
  END IF;
  UPDATE public.invoice_items SET product_id = _product_id,
    vendor_product_id = _vendor_product_id, review_status = 'pending_review',
    product_match_source = 'manual', product_match_decided_at = now()
  WHERE id = _line.id;
  RETURN jsonb_build_object('productId', _product_id, 'vendorProductId', _vendor_product_id);
END;
$$;

-- Phase 2D posting, hardened as the identity boundary. Every line must already carry the
-- product identity the owner reviewed; posting never infers, creates, or remembers one.
-- Removed relative to Phase 2D:
--   * vendor-SKU mapping lookup for lines without a product;
--   * organization inventory lookup by SKU alone (not vendor scoped);
--   * product lookup by normalized description;
--   * product (and category) creation from the line;
--   * finding, creating, or repointing a vendor-SKU mapping when the reviewed line has no
--     vendor_product_id (e.g. a match confirmed with rememberVendorSku = false).
-- Vendor resolution, the completed-invoice no-op, mapping package/unit refresh for a
-- reviewed mapping, inventory quantities, adjustments, price history, and invoice
-- completion are unchanged.
CREATE OR REPLACE FUNCTION public.post_reviewed_invoice(
  _organization_id uuid,
  _source_file_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _invoice public.invoices%ROWTYPE;
  _line public.invoice_items%ROWTYPE;
  _vendor_id uuid;
  _vendor_name text;
  _product_id uuid;
  _vendor_product_id uuid;
  _mapping public.vendor_products%ROWTYPE;
  _inventory public.inventory_items%ROWTYPE;
  _previous numeric;
  _new numeric;
  _created integer := 0;
  _updated integer := 0;
  _line_count integer;
  _unresolved integer;
BEGIN
  IF NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;

  SELECT * INTO _invoice
  FROM public.invoices
  WHERE organization_id = _organization_id AND source_file_id = _source_file_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice review not found'; END IF;
  IF _invoice.posted_at IS NOT NULL OR _invoice.processing_status = 'completed' THEN
    RETURN jsonb_build_object('invoiceId', _invoice.id, 'createdInventoryItems', 0,
      'updatedInventoryItems', 0, 'alreadyCompleted', true);
  END IF;

  -- Identity gate, before any write. Lock every line first so a concurrent direct API
  -- edit cannot unlink a line between this check and the posting loop.
  PERFORM 1 FROM public.invoice_items
  WHERE invoice_id = _invoice.id AND organization_id = _organization_id
  FOR UPDATE;
  SELECT count(*) INTO _unresolved FROM public.invoice_items
  WHERE invoice_id = _invoice.id AND organization_id = _organization_id AND product_id IS NULL;
  IF _unresolved > 0 THEN
    RAISE EXCEPTION 'Match or create a product for every invoice line before approval (% unresolved)', _unresolved
      USING ERRCODE = '23502';
  END IF;

  _vendor_id := _invoice.vendor_id;
  _vendor_name := nullif(btrim(_invoice.vendor_name), '');
  IF _vendor_id IS NOT NULL THEN
    SELECT name INTO _vendor_name FROM public.vendors
      WHERE id = _vendor_id AND organization_id = _organization_id AND active = true;
    IF NOT FOUND THEN RAISE EXCEPTION 'Selected vendor is unavailable'; END IF;
  ELSIF _vendor_name IS NOT NULL THEN
    SELECT id INTO _vendor_id FROM public.vendors
      WHERE organization_id = _organization_id
        AND normalized_name = public.normalize_catalog_text(_vendor_name) AND active = true
      LIMIT 1;
    IF _vendor_id IS NULL THEN
      INSERT INTO public.vendors (organization_id, name, normalized_name)
      VALUES (_organization_id, _vendor_name, public.normalize_catalog_text(_vendor_name))
      RETURNING id INTO _vendor_id;
    END IF;
  ELSE
    RAISE EXCEPTION 'Vendor is required before approval';
  END IF;

  SELECT count(*) INTO _line_count FROM public.invoice_items
    WHERE invoice_id = _invoice.id AND organization_id = _organization_id;
  IF _line_count = 0 THEN RAISE EXCEPTION 'Add at least one line item before approval'; END IF;

  FOR _line IN
    SELECT * FROM public.invoice_items
    WHERE invoice_id = _invoice.id AND organization_id = _organization_id
    ORDER BY line_number NULLS LAST, created_at
    FOR UPDATE
  LOOP
    _product_id := _line.product_id;
    _vendor_product_id := _line.vendor_product_id;
    IF _product_id IS NULL THEN
      RAISE EXCEPTION 'Match or create a product for every invoice line before approval' USING ERRCODE = '23502';
    END IF;

    -- A reviewed mapping must belong to this organization and invoice vendor, be active,
    -- and name the same product as the line. It never replaces the line's product.
    IF _vendor_product_id IS NOT NULL THEN
      SELECT * INTO _mapping FROM public.vendor_products
        WHERE id = _vendor_product_id AND organization_id = _organization_id
          AND vendor_id = _vendor_id AND active = true;
      IF NOT FOUND THEN RAISE EXCEPTION 'A selected vendor product is unavailable'; END IF;
      IF _mapping.product_id IS DISTINCT FROM _product_id THEN
        RAISE EXCEPTION 'A selected vendor product maps to a different product than the invoice line';
      END IF;

      UPDATE public.vendor_products SET
        product_id = _product_id,
        package_size = coalesce(nullif(btrim(_line.package_size), ''), package_size),
        unit_of_measure = coalesce(nullif(btrim(_line.unit_of_measure), ''), unit_of_measure),
        active = true
      WHERE id = _vendor_product_id AND organization_id = _organization_id AND vendor_id = _vendor_id;
    END IF;

    SELECT * INTO _inventory FROM public.inventory_items
    WHERE organization_id = _organization_id AND product_id = _product_id
    LIMIT 1 FOR UPDATE;

    IF _inventory.id IS NULL THEN
      INSERT INTO public.inventory_items
        (organization_id, product_id, sku, name, description, category, manufacturer,
         unit, quantity, vendor_name, last_purchase_price, last_purchase_date, active)
      VALUES
        (_organization_id, _product_id, nullif(btrim(_line.sku), ''), btrim(_line.description),
         btrim(_line.description), nullif(btrim(_line.category), ''),
         nullif(btrim(_line.manufacturer), ''), coalesce(nullif(btrim(_line.unit_of_measure), ''), 'each'),
         0, _vendor_name, _line.unit_price, coalesce(_invoice.invoice_date, current_date), true)
      RETURNING * INTO _inventory;
      _created := _created + 1;
    ELSE
      _updated := _updated + 1;
    END IF;

    _previous := _inventory.quantity;
    _new := _previous + _line.quantity;
    UPDATE public.inventory_items SET
      quantity = _new,
      sku = coalesce(nullif(btrim(_line.sku), ''), sku),
      category = coalesce(nullif(btrim(_line.category), ''), category),
      manufacturer = coalesce(nullif(btrim(_line.manufacturer), ''), manufacturer),
      vendor_name = _vendor_name,
      last_purchase_price = coalesce(_line.unit_price, last_purchase_price),
      last_purchase_date = coalesce(_invoice.invoice_date, current_date),
      active = true
    WHERE id = _inventory.id;

    INSERT INTO public.inventory_adjustments
      (organization_id, inventory_item_id, adjustment_amount, previous_quantity, new_quantity,
       reason, created_by, source_type, source_invoice_id, source_invoice_item_id, idempotency_key)
    VALUES
      (_organization_id, _inventory.id, _line.quantity, _previous, _new,
       'Invoice received', auth.uid(), 'invoice', _invoice.id, _line.id, 'invoice-item:' || _line.id::text);

    INSERT INTO public.inventory_price_history
      (organization_id, product_id, vendor_id, vendor_product_id, invoice_id, invoice_item_id,
       purchase_date, quantity, package_size, unit_of_measure, unit_price, extended_price)
    VALUES
      (_organization_id, _product_id, _vendor_id, _vendor_product_id, _invoice.id, _line.id,
       coalesce(_invoice.invoice_date, current_date), _line.quantity, nullif(btrim(_line.package_size), ''),
       nullif(btrim(_line.unit_of_measure), ''), _line.unit_price, _line.total_price);

    UPDATE public.invoice_items SET product_id = _product_id,
      vendor_product_id = _vendor_product_id, review_status = 'approved'
    WHERE id = _line.id;
  END LOOP;

  UPDATE public.invoices SET vendor_id = _vendor_id, vendor_name = _vendor_name,
    invoice_total = coalesce(invoice_total, total_amount, total),
    total_amount = coalesce(total_amount, invoice_total, total),
    total = coalesce(total, total_amount, invoice_total),
    processing_status = 'completed', reviewed_by = auth.uid(), reviewed_at = now(), posted_at = now()
  WHERE id = _invoice.id;

  UPDATE public.invoice_processing_jobs SET status = 'completed'
  WHERE invoice_id = _source_file_id AND organization_id = _organization_id;

  RETURN jsonb_build_object('invoiceId', _invoice.id, 'createdInventoryItems', _created,
    'updatedInventoryItems', _updated, 'alreadyCompleted', false);
END;
$$;

-- CREATE OR REPLACE keeps existing grants; restate them and close the default anon grant.
REVOKE ALL ON FUNCTION public.rematch_invoice_vendor_products(uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.confirm_invoice_item_product(uuid, uuid, uuid, uuid, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.unlink_invoice_item_product(uuid, uuid, uuid, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_product_from_invoice_item(uuid, uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.post_reviewed_invoice(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rematch_invoice_vendor_products(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_invoice_item_product(uuid, uuid, uuid, uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.unlink_invoice_item_product(uuid, uuid, uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_product_from_invoice_item(uuid, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.post_reviewed_invoice(uuid, uuid) TO authenticated;

COMMIT;
