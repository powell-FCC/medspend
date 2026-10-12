-- Beta hardening: manual invoice matching against the invoice vendor's linked catalog.
--
-- Phase 6C.1 links a line automatically only when vendor + SKU names exactly one verified
-- identity. Everything else is left for an owner, whose manual recovery could previously
-- reach only products the organization had already adopted. These two owner-only RPCs let
-- the reviewer search, and explicitly choose from, the global catalog of the catalog
-- vendor that the invoice vendor is already linked to (vendors.catalog_vendor_id).
--
-- The 6C.1 rules are unchanged and reused:
--   * vendor-scoped only: the catalog vendor comes from the invoice's own vendor link,
--     never from the caller and never from a vendor name;
--   * the separator-insensitive key is a lookup aid inside that one catalog vendor;
--   * adoption goes through the existing adopt_catalog_vendor_product RPC (idempotent,
--     never creates or changes inventory);
--   * the decision is recorded as 'manual', which the resolver never revisits;
--   * nothing here approves or posts an invoice.
--
-- It also closes two gaps in manual review:
--   * confirm_invoice_item_product (Phase 3A.4, last defined in Phase 6C.1) is redefined so
--     that an explicit re-match never repoints, and never shadows with a separator-variant
--     row, a vendor SKU mapping that came from catalog adoption. Before, re-matching a line
--     whose SKU was an adopted catalog SKU failed on the catalog-link trigger (exact SKU)
--     or silently created a second mapping for the same SKU (SKU printed without
--     separators). Everything else about the function is unchanged.
--   * a trigger on invoice_items withdraws a calculated (never printed) subtotal or total
--     the moment an owner adds, removes, or re-prices a line, so a calculated amount can
--     never outlive the lines it was calculated from. The application recalculates it.
--
-- No table or column is changed. Phase 6C.1's migration file is not edited.
-- Rollback: DROP TRIGGER invoice_items_invalidate_derived_totals ON public.invoice_items;
--           DROP FUNCTION public.invalidate_derived_invoice_totals();
--           DROP FUNCTION public.match_invoice_item_to_catalog_listing(uuid, uuid, uuid, uuid, uuid);
--           DROP FUNCTION public.search_invoice_line_catalog_listings(uuid, uuid, text, integer);
--           then re-run the CREATE OR REPLACE FUNCTION public.confirm_invoice_item_product
--           statement from 20261010120000_phase6c1_invoice_exact_match_auto_resolution.sql.

BEGIN;

DO $beta_manual_catalog_preflight$
BEGIN
  IF to_regprocedure('public.resolve_invoice_exact_product_identities(uuid, uuid)') IS NULL
     OR to_regprocedure('public.adopt_catalog_vendor_product(uuid, uuid)') IS NULL
     OR to_regprocedure('public.confirm_invoice_item_product(uuid, uuid, uuid, uuid, boolean)') IS NULL THEN
    RAISE EXCEPTION 'Manual catalog matching requires Phase 5A.5 adoption and Phase 6C.1 invoice identity functions';
  END IF;
  IF to_regprocedure('public.match_invoice_item_to_catalog_listing(uuid, uuid, uuid, uuid, uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'Manual catalog matching has already been applied';
  END IF;
END
$beta_manual_catalog_preflight$;

-- Read-only search of the linked catalog vendor's listings by vendor SKU or product name.
-- A listing is offered only if choosing it would adopt into an active product: the listing
-- and its canonical product are active, not discontinued, and not rejected. Unverified
-- listings are offered (and labelled) because a person, not the resolver, decides here.
CREATE FUNCTION public.search_invoice_line_catalog_listings(
  _organization_id uuid,
  _source_file_id uuid,
  _query text,
  _limit integer DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _invoice public.invoices%ROWTYPE;
  _catalog_vendor_id uuid;
  _catalog_vendor public.catalog_vendors%ROWTYPE;
  _text text := btrim(coalesce(_query, ''));
  _strict text;
  _key text;
  _name_pattern text;
  _results jsonb;
BEGIN
  IF NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;
  SELECT * INTO _invoice FROM public.invoices
  WHERE organization_id = _organization_id AND source_file_id = _source_file_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice review not found'; END IF;

  IF _invoice.vendor_id IS NULL THEN
    RETURN jsonb_build_object('available', false, 'reason', 'no_vendor', 'catalogVendorName', NULL, 'results', '[]'::jsonb);
  END IF;
  SELECT vendor.catalog_vendor_id INTO _catalog_vendor_id
  FROM public.vendors vendor
  WHERE vendor.id = _invoice.vendor_id AND vendor.organization_id = _organization_id AND vendor.active;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('available', false, 'reason', 'vendor_unavailable', 'catalogVendorName', NULL, 'results', '[]'::jsonb);
  END IF;
  -- No explicit link, no catalog. Vendors are never linked by name.
  IF _catalog_vendor_id IS NULL THEN
    RETURN jsonb_build_object('available', false, 'reason', 'vendor_not_linked_to_catalog', 'catalogVendorName', NULL, 'results', '[]'::jsonb);
  END IF;
  SELECT * INTO _catalog_vendor FROM public.catalog_vendors WHERE id = _catalog_vendor_id;
  IF NOT FOUND OR NOT _catalog_vendor.active THEN
    RETURN jsonb_build_object('available', false, 'reason', 'catalog_vendor_inactive', 'catalogVendorName', _catalog_vendor.name, 'results', '[]'::jsonb);
  END IF;

  IF length(_text) < 2 THEN
    RETURN jsonb_build_object('available', true, 'reason', NULL, 'catalogVendorName', _catalog_vendor.name, 'results', '[]'::jsonb);
  END IF;

  _strict := public.normalize_catalog_sku(_text);
  _key := public.normalize_catalog_sku_match_key(_text);
  -- normalize_catalog_text leaves only [a-z0-9 ], so the pattern needs no LIKE escaping.
  _name_pattern := public.normalize_catalog_text(_text);

  SELECT coalesce(jsonb_agg(to_jsonb(candidate) - 'rank' - 'normalized_name' - 'normalized_vendor_sku'
                            ORDER BY candidate.rank, candidate.normalized_name, candidate.normalized_vendor_sku, candidate."catalogVendorProductId"), '[]'::jsonb)
  INTO _results
  FROM (
    SELECT
      listing.id AS "catalogVendorProductId",
      listing.vendor_sku AS "vendorSku",
      catalog_product.name AS "name",
      catalog_product.manufacturer AS "manufacturer",
      listing.package_description AS "packageDescription",
      (listing.verification_status = 'verified' AND catalog_product.verification_status = 'verified') AS "verified",
      (
        SELECT product.id FROM public.products product
        WHERE product.organization_id = _organization_id
          AND product.catalog_product_id = listing.catalog_product_id
        ORDER BY product.created_at, product.id LIMIT 1
      ) AS "organizationProductId",
      CASE
        WHEN listing.normalized_vendor_sku = _strict THEN 0
        WHEN _key <> '' AND listing.vendor_sku_match_key = _key THEN 1
        WHEN length(_key) >= 3 AND listing.vendor_sku_match_key LIKE _key || '%' THEN 2
        ELSE 3
      END AS rank,
      catalog_product.normalized_name,
      listing.normalized_vendor_sku
    FROM public.catalog_vendor_products listing
    JOIN public.catalog_products catalog_product ON catalog_product.id = listing.catalog_product_id
    WHERE listing.catalog_vendor_id = _catalog_vendor_id
      AND listing.active
      AND NOT listing.discontinued
      AND listing.verification_status <> 'rejected'
      AND catalog_product.active
      AND catalog_product.verification_status <> 'rejected'
      AND (
        listing.normalized_vendor_sku = _strict
        OR (_key <> '' AND listing.vendor_sku_match_key = _key)
        OR (length(_key) >= 3 AND listing.vendor_sku_match_key LIKE _key || '%')
        OR (length(_name_pattern) >= 2 AND catalog_product.normalized_name LIKE '%' || _name_pattern || '%')
      )
    ORDER BY rank, catalog_product.normalized_name, listing.normalized_vendor_sku, listing.id
    LIMIT least(greatest(coalesce(_limit, 20), 1), 50)
  ) candidate;

  RETURN jsonb_build_object('available', true, 'reason', NULL, 'catalogVendorName', _catalog_vendor.name, 'results', _results);
END;
$$;

REVOKE ALL ON FUNCTION public.search_invoice_line_catalog_listings(uuid, uuid, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.search_invoice_line_catalog_listings(uuid, uuid, text, integer) TO authenticated;

COMMENT ON FUNCTION public.search_invoice_line_catalog_listings(uuid, uuid, text, integer) IS
  'Owner-only, read-only search of the global catalog listings of the catalog vendor that the invoice vendor is explicitly linked to. Never searches another vendor.';

-- Phase 3A.4 manual confirmation as defined in Phase 6C.1, with one change: what happens
-- to the vendor SKU mapping when the owner asks to remember the SKU.
--
--   * No mapping for this SKU: one is created (unchanged).
--   * A mapping for this SKU that the owner remembered by hand: it is pointed at the chosen
--     product (unchanged; this is what "remember" has always meant).
--   * A mapping for this SKU that came from catalog adoption and names another product: it
--     is left exactly as it is. The line is matched to the chosen product for this invoice
--     only (no vendor_product_id), and the result says which mapping was preserved. The
--     same applies when the invoice SKU differs from the adopted SKU only by separators;
--     no second mapping is created for it.
--   * The adopted mapping already names the chosen product: it is reused.
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
  _mapping public.vendor_products%ROWTYPE;
  _preserved_vendor_product_id uuid;
  _key text;
  _adopted_count bigint;
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
    SELECT * INTO _mapping FROM public.vendor_products
      WHERE organization_id = _organization_id AND vendor_id = _invoice.vendor_id
        AND lower(btrim(vendor_sku)) = lower(btrim(_line.sku))
      ORDER BY active DESC, created_at LIMIT 1 FOR UPDATE;
    IF FOUND THEN
      IF _mapping.product_id = _product_id OR _mapping.catalog_vendor_product_id IS NULL THEN
        UPDATE public.vendor_products SET product_id = _product_id,
          package_size = coalesce(nullif(btrim(_line.package_size), ''), package_size),
          unit_of_measure = coalesce(nullif(btrim(_line.unit_of_measure), ''), unit_of_measure), active = true
        WHERE id = _mapping.id;
        _vendor_product_id := _mapping.id;
      ELSE
        -- A catalog-adopted mapping names a different product: never repointed.
        _preserved_vendor_product_id := _mapping.id;
      END IF;
    ELSE
      -- No mapping stores this exact SKU. A catalog-adopted mapping that differs from it
      -- only by separators (invoice 3240025, catalog 324-0025) is the same vendor SKU.
      _key := public.normalize_catalog_sku_match_key(_line.sku);
      SELECT count(*) INTO _adopted_count FROM public.vendor_products
        WHERE organization_id = _organization_id AND vendor_id = _invoice.vendor_id
          AND catalog_vendor_product_id IS NOT NULL
          AND _key <> '' AND public.normalize_catalog_sku_match_key(vendor_sku) = _key;
      IF _adopted_count = 0 THEN
        INSERT INTO public.vendor_products
          (organization_id, vendor_id, product_id, vendor_sku, package_size, unit_of_measure)
        VALUES
          (_organization_id, _invoice.vendor_id, _product_id, btrim(_line.sku),
           nullif(btrim(_line.package_size), ''), nullif(btrim(_line.unit_of_measure), ''))
        RETURNING id INTO _vendor_product_id;
      ELSE
        SELECT * INTO _mapping FROM public.vendor_products
          WHERE organization_id = _organization_id AND vendor_id = _invoice.vendor_id
            AND catalog_vendor_product_id IS NOT NULL
            AND public.normalize_catalog_sku_match_key(vendor_sku) = _key
          ORDER BY active DESC, created_at, id LIMIT 1 FOR UPDATE;
        IF _adopted_count = 1 AND _mapping.active AND _mapping.product_id = _product_id THEN
          -- The one adopted mapping for this SKU already names the chosen product.
          _vendor_product_id := _mapping.id;
        ELSE
          -- It names another product (or is ambiguous or deactivated): left untouched, and
          -- no separator-variant row is created to shadow it.
          _preserved_vendor_product_id := _mapping.id;
        END IF;
      END IF;
    END IF;
  END IF;
  UPDATE public.invoice_items SET product_id = _product_id,
    vendor_product_id = _vendor_product_id, review_status = 'pending_review',
    product_match_source = 'manual', product_match_decided_at = now()
  WHERE id = _line.id;
  RETURN jsonb_build_object('productId', _product_id, 'vendorProductId', _vendor_product_id,
    'vendorSkuRemembered', _vendor_product_id IS NOT NULL,
    'preservedVendorProductId', _preserved_vendor_product_id);
END;
$$;

-- CREATE OR REPLACE keeps the Phase 6C.1 grants; restate them.
REVOKE ALL ON FUNCTION public.confirm_invoice_item_product(uuid, uuid, uuid, uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirm_invoice_item_product(uuid, uuid, uuid, uuid, boolean) TO authenticated;

-- One explicit owner decision: adopt the chosen listing if needed and match the line to it.
-- Atomic under the same invoice row lock as confirm, unlink, resolve, and posting.
--
-- _expected_product_id is the product the reviewer saw on the line (NULL for an unmatched
-- line). If the line now points anywhere else, nothing is written: an existing match is
-- only ever replaced by a caller that named it.
CREATE FUNCTION public.match_invoice_item_to_catalog_listing(
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
    GET STACKED DIAGNOSTICS _adoption_error = MESSAGE_TEXT;
    RAISE EXCEPTION 'This catalog item conflicts with a product or vendor SKU mapping your organization already has, so it cannot be added automatically. Choose the existing product under Your products, or resolve the conflict in Catalog first.'
      USING DETAIL = _adoption_error;
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
  'Owner-only manual decision: adopts one listing of the invoice vendor''s linked catalog vendor (existing idempotent adoption, no inventory) and matches the invoice line to it with manual provenance. Never approves, posts, or stocks.';

-- A calculated subtotal or total (extraction source 'Derived') is valid only for the line
-- items it was calculated from. When an owner adds, removes, or re-prices a line through
-- the API, the calculated amount is withdrawn in the same statement: it goes back to blank
-- and unreviewed. The application then recalculates it with the same rules used at
-- extraction. Printed and owner-entered amounts (any other source) are never touched.
--
-- Like the Phase 6C.1 provenance guard, this acts only on API-role writes. SECURITY
-- DEFINER functions (draft seeding, posting, deletion) run as the function owner and are
-- skipped; none of them change line amounts on a draft with calculated totals.
CREATE FUNCTION public.invalidate_derived_invoice_totals()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  _invoice_ids uuid[];
  _invoice_id uuid;
  _invoice public.invoices%ROWTYPE;
  _extraction jsonb;
  _subtotal boolean;
  _total boolean;
  _withdrawn constant jsonb := '{"value": null, "confidence": 0, "source": "Derived", "reviewed": false}';
BEGIN
  IF current_user NOT IN ('authenticated', 'anon') THEN RETURN NULL; END IF;
  IF TG_OP = 'INSERT' THEN
    _invoice_ids := ARRAY[NEW.invoice_id];
  ELSIF TG_OP = 'DELETE' THEN
    _invoice_ids := ARRAY[OLD.invoice_id];
  ELSIF NEW.invoice_id IS DISTINCT FROM OLD.invoice_id THEN
    _invoice_ids := ARRAY[OLD.invoice_id, NEW.invoice_id];
  ELSIF NEW.quantity IS DISTINCT FROM OLD.quantity
        OR NEW.unit_price IS DISTINCT FROM OLD.unit_price
        OR NEW.total_price IS DISTINCT FROM OLD.total_price THEN
    _invoice_ids := ARRAY[NEW.invoice_id];
  ELSE
    RETURN NULL;
  END IF;

  FOREACH _invoice_id IN ARRAY _invoice_ids LOOP
    SELECT * INTO _invoice FROM public.invoices WHERE id = _invoice_id FOR UPDATE;
    CONTINUE WHEN NOT FOUND OR _invoice.source_file_id IS NULL
      OR _invoice.posted_at IS NOT NULL OR _invoice.processing_status = 'completed';
    SELECT extraction_result INTO _extraction FROM public.invoice_processing_jobs
    WHERE invoice_id = _invoice.source_file_id AND organization_id = _invoice.organization_id
    FOR UPDATE;
    CONTINUE WHEN NOT FOUND OR _extraction IS NULL;
    _subtotal := coalesce(_extraction #>> '{header,subtotal,source}' = 'Derived', false);
    _total := coalesce(_extraction #>> '{header,total,source}' = 'Derived', false);
    CONTINUE WHEN NOT (_subtotal OR _total);

    IF _subtotal THEN _extraction := jsonb_set(_extraction, '{header,subtotal}', _withdrawn); END IF;
    IF _total THEN _extraction := jsonb_set(_extraction, '{header,total}', _withdrawn); END IF;
    UPDATE public.invoice_processing_jobs SET extraction_result = _extraction
    WHERE invoice_id = _invoice.source_file_id AND organization_id = _invoice.organization_id;
    UPDATE public.invoices SET
      subtotal = CASE WHEN _subtotal THEN NULL ELSE subtotal END,
      invoice_total = CASE WHEN _total THEN NULL ELSE invoice_total END,
      total_amount = CASE WHEN _total THEN NULL ELSE total_amount END,
      total = CASE WHEN _total THEN NULL ELSE total END
    WHERE id = _invoice.id;
  END LOOP;
  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.invalidate_derived_invoice_totals() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER invoice_items_invalidate_derived_totals
  AFTER INSERT OR UPDATE OR DELETE ON public.invoice_items
  FOR EACH ROW EXECUTE FUNCTION public.invalidate_derived_invoice_totals();

COMMENT ON FUNCTION public.invalidate_derived_invoice_totals() IS
  'Withdraws a calculated (extraction source Derived) invoice subtotal or total when an API-role write adds, removes, or re-prices a line. Never touches printed or owner-entered amounts.';

COMMIT;
