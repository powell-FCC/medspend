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
-- Additive: two new functions. No table, column, or existing function is changed.
-- Rollback: DROP FUNCTION public.match_invoice_item_to_catalog_listing(uuid, uuid, uuid, uuid, uuid);
--           DROP FUNCTION public.search_invoice_line_catalog_listings(uuid, uuid, text, integer);

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
  -- reconciliation it raises, and this whole decision rolls back.
  _adoption := public.adopt_catalog_vendor_product(_organization_id, _listing.id);
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

  IF public.normalize_catalog_sku_match_key(_line.sku) <> ''
     AND public.normalize_catalog_sku_match_key(_line.sku) = public.normalize_catalog_sku_match_key(_listing.vendor_sku)
     AND NOT EXISTS (
       SELECT 1 FROM public.vendor_products
       WHERE organization_id = _organization_id AND vendor_id = _invoice.vendor_id
         AND lower(btrim(vendor_sku)) = lower(btrim(_line.sku))
         AND id <> _vendor_product_id
     ) THEN
    -- The invoice SKU is the listing's own SKU (at most separators differ): the adopted
    -- mapping already is this line's vendor identity. No second mapping is created.
    UPDATE public.invoice_items SET product_id = _product_id,
      vendor_product_id = _vendor_product_id, review_status = 'pending_review',
      product_match_source = 'manual', product_match_decided_at = now()
    WHERE id = _line.id;
  ELSE
    -- A different invoice SKU: the existing manual confirmation remembers that SKU for
    -- the adopted product, exactly as it does for any other owner-chosen product.
    _confirmation := public.confirm_invoice_item_product(
      _organization_id, _source_file_id, _invoice_item_id, _product_id, true);
    _vendor_product_id := (_confirmation->>'vendorProductId')::uuid;
  END IF;

  RETURN jsonb_build_object(
    'productId', _product_id,
    'vendorProductId', _vendor_product_id,
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

COMMIT;
