-- Phase 6B.1: Multi-Vendor Intelligence V1.
--
-- Product rules (locked 2026-11-22):
--   * A price observation is one posted invoice or order-confirmation line already recorded in
--     inventory_price_history. Nothing is copied or persisted: every figure is derived on read.
--     Catalog/list prices are never used. No current, market or recommended price exists.
--   * Currency: the Phase 7E rule. No currency recorded = USD (legacy); explicit USD included;
--     explicit non-USD excluded and reported in coverage; nothing is converted.
--   * SKU identity = upper(btrim(mapping SKU, else the posted line SKU)) within one vendor.
--     Unit key = lower(btrim(unit)); a unit is valid only when the key matches ^[a-z]{1,10}$.
--     Package key = lower(btrim(package text)). No synonyms, no base-unit normalization.
--   * Same-SKU change: same product, vendor, SKU identity and valid unit key, USD basis, valid
--     price, quantity > 0; newest against the observation before it, ordered by
--     purchase_date DESC, created_at DESC, id DESC. Never across SKU, vendor or unit.
--   * Insufficient identity: a vendor has more than one SKU identity for the product (observed
--     SKUs plus its active SKU mappings), an observation has no SKU, or the last purchase / a
--     vendor's latest observation has a missing or malformed unit. No change is shown.
--   * Cross-vendor: each vendor is represented by its latest observation. A pair is structurally
--     comparable when the unit keys are valid and equal and the package is proven equal
--     (matching non-null package text, or verified catalog packages of equal quantity and unit
--     that agree with the invoiced unit). Numbers (lowest comparable purchase price, difference,
--     the lower-price signal) only exist against the last purchase, with both observations
--     180 UTC days old or less. A structurally comparable stale pair stays "Comparable" with the
--     Stale marker and withheld numbers.
--   * States, in precedence: insufficient_identity, one_purchase, single_vendor, comparable,
--     missing_package_details, incompatible_units. Stale is a separate marker.
--   * Recency (UTC days since the purchase date, floored at 0): 0-90 recent, 91-180 aging,
--     over 180 stale. Order confirmations are observations, always labelled, dated by posting
--     when no invoice date exists, never deduplicated and never weighted.
--   * Access: owners and admins read (is_org_admin). Staff, anon and non-members are refused.
--     Only owners are told they may open the source document (the owner-only 7E drill-down).
--     Nothing here writes.
--
-- get_price_intelligence_overview and get_product_price_intelligence keep their exact JSON keys
-- (the deployed app parses them strictly). They now follow the rules above: savings and the
-- 90-day average are always null, and changes never cross SKU, vendor or unit.

BEGIN;

DO $preflight$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.proname IN (
               'price_unit_key', 'price_unit_is_valid', 'price_recency', 'price_catalog_unit_agrees',
               'price_catalog_package_agreement',
               'price_package_agreement', 'price_row_is_valid', 'price_observation_rows',
               'price_observation_evidence', 'price_recent_anchors', 'price_name_anchors',
               'price_summary_product_states', 'price_summary_groups', 'price_summary_flagged_invoices',
               'price_product_state', 'list_price_intelligence_products',
               'get_price_intelligence_summary', 'get_product_vendor_price_history',
               'get_supply_request_price_context'))
     OR pg_catalog.to_regclass('public.inventory_price_history_product_vendor_order_idx') IS NOT NULL
     OR pg_catalog.to_regclass('public.inventory_price_history_org_recent_idx') IS NOT NULL THEN
    RAISE EXCEPTION 'Phase 6B.1 multi-vendor intelligence objects already exist unexpectedly';
  END IF;

  IF pg_catalog.to_regclass('public.financial_document_removals') IS NULL
     OR pg_catalog.to_regprocedure('public.financial_assert_access(uuid, boolean)') IS NULL
     OR pg_catalog.to_regprocedure('public.get_financial_document_detail(uuid, uuid)') IS NULL THEN
    RAISE EXCEPTION 'Phase 6B.1 requires Phase 7E (financial_document_removals / financial_assert_access)';
  END IF;

  IF pg_catalog.to_regprocedure('public.get_price_intelligence_overview(uuid)') IS NULL
     OR pg_catalog.to_regprocedure('public.get_product_price_intelligence(uuid, uuid)') IS NULL THEN
    RAISE EXCEPTION 'Phase 6B.1 requires the Phase 6B price intelligence functions';
  END IF;

  IF current_setting('TimeZone') NOT IN ('UTC', 'Etc/UTC') THEN
    RAISE EXCEPTION 'Phase 6B.1 expects the database TimeZone to be UTC (found %)', current_setting('TimeZone');
  END IF;
END
$preflight$;

-- Per product, then vendor, newest first: serves vendor representatives and per-vendor history.
CREATE INDEX inventory_price_history_product_vendor_order_idx
  ON public.inventory_price_history (
    organization_id, product_id, vendor_id, purchase_date DESC, created_at DESC, id DESC
  );

-- Newest first across the organization: the keyset walk of the "most recent purchase" list.
CREATE INDEX inventory_price_history_org_recent_idx
  ON public.inventory_price_history (organization_id, purchase_date DESC, created_at DESC, id DESC);

-- ---------------------------------------------------------------------------------------
-- Internal helpers (no client EXECUTE). SQL without SET clauses so the planner can inline
-- them; every reference is schema-qualified.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.price_unit_key(_unit text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT NULLIF(lower(btrim(_unit)), '')
$$;
REVOKE ALL ON FUNCTION public.price_unit_key(text) FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION public.price_unit_key(text) IS
  'Phase 6B.1 unit key: trim and lowercase only. No synonyms.';

CREATE FUNCTION public.price_unit_is_valid(_unit text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT COALESCE(lower(btrim(_unit)) ~ '^[a-z]{1,10}$', false)
$$;
REVOKE ALL ON FUNCTION public.price_unit_is_valid(text) FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION public.price_unit_is_valid(text) IS
  'Phase 6B.1: a unit is comparable only when its key is 1-10 letters (EA), so EA) or pk 10 never compare.';

CREATE FUNCTION public.price_recency(_purchase_date date, _today date)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT CASE
    WHEN _purchase_date IS NULL OR _today IS NULL THEN NULL
    WHEN GREATEST(_today - _purchase_date, 0) <= 90 THEN 'recent'
    WHEN GREATEST(_today - _purchase_date, 0) <= 180 THEN 'aging'
    ELSE 'stale'
  END
$$;
REVOKE ALL ON FUNCTION public.price_recency(date, date) FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION public.price_recency(date, date) IS
  'Phase 6B.1 recency in UTC days, floored at 0: recent (0-90), aging (91-180), stale (over 180).';

CREATE FUNCTION public.price_catalog_unit_agrees(_quantity numeric, _description text, _unit_key text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT COALESCE(CASE
    WHEN _quantity IS NULL OR _unit_key IS NULL THEN false
    WHEN _quantity = 1 THEN _unit_key IN ('ea', 'each')
    WHEN position('/' IN COALESCE(_description, '')) = 0 THEN false
    ELSE (CASE lower(btrim(split_part(_description, '/', 2)))
      WHEN 'box' THEN 'bx'
      WHEN 'case' THEN 'ca'
      WHEN 'pkg' THEN 'pk'
      WHEN 'pk' THEN 'pk'
      WHEN 'roll' THEN 'rl'
      WHEN 'bottle' THEN 'bt'
      WHEN 'bag' THEN 'bg'
      WHEN 'jar' THEN 'jr'
      WHEN 'tube' THEN 'tb'
      WHEN 'can' THEN 'cn'
    END) = _unit_key
  END, false)
$$;
REVOKE ALL ON FUNCTION public.price_catalog_unit_agrees(numeric, text, text) FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION public.price_catalog_unit_agrees(numeric, text, text) IS
  'Phase 6B.1: a verified catalog package agrees with the invoiced unit only for quantity 1 sold as ea/each, or when the container word after "/" maps through a fixed table to the invoiced unit.';

CREATE FUNCTION public.price_catalog_package_agreement(
  _unit_key text,
  _catalog_vendor_product_a uuid,
  _catalog_vendor_product_b uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE((
    SELECT a.package_quantity = b.package_quantity
      AND lower(btrim(a.package_unit)) = lower(btrim(b.package_unit))
      AND public.price_catalog_unit_agrees(a.package_quantity, a.package_description, _unit_key)
      AND public.price_catalog_unit_agrees(b.package_quantity, b.package_description, _unit_key)
    FROM public.catalog_vendor_products a
    CROSS JOIN public.catalog_vendor_products b
    WHERE a.id = _catalog_vendor_product_a
      AND b.id = _catalog_vendor_product_b
      AND a.package_status = 'verified'
      AND b.package_status = 'verified'
      AND a.package_quantity IS NOT NULL
      AND b.package_quantity IS NOT NULL
      AND NULLIF(btrim(a.package_unit), '') IS NOT NULL
      AND NULLIF(btrim(b.package_unit), '') IS NOT NULL
  ), false)
$$;
REVOKE ALL ON FUNCTION public.price_catalog_package_agreement(text, uuid, uuid) FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION public.price_catalog_package_agreement(text, uuid, uuid) IS
  'Phase 6B.1: verified catalog packages of equal quantity and unit that both agree with the invoiced unit. Used by price_package_agreement when a package text is missing.';

-- Inlinable (no sub-select): the catalog lookup runs only when a package text is missing.
CREATE FUNCTION public.price_package_agreement(
  _unit_key text,
  _package_a text,
  _package_b text,
  _catalog_vendor_product_a uuid,
  _catalog_vendor_product_b uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT CASE
    WHEN NULLIF(lower(btrim(_package_a)), '') IS NOT NULL AND NULLIF(lower(btrim(_package_b)), '') IS NOT NULL
      THEN lower(btrim(_package_a)) = lower(btrim(_package_b))
    WHEN _catalog_vendor_product_a IS NULL OR _catalog_vendor_product_b IS NULL THEN false
    ELSE public.price_catalog_package_agreement(_unit_key, _catalog_vendor_product_a, _catalog_vendor_product_b)
  END
$$;
REVOKE ALL ON FUNCTION public.price_package_agreement(text, text, text, uuid, uuid) FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION public.price_package_agreement(text, text, text, uuid, uuid) IS
  'Phase 6B.1: package equality is proven only by matching non-null package text, or (when either text is missing) by verified catalog packages of equal quantity and unit that both agree with the invoiced unit. Differing package texts never agree.';

-- A price observation is usable in USD figures: a price at or above zero, a positive quantity,
-- and USD or no currency recorded (the Phase 7E rule).
CREATE FUNCTION public.price_row_is_valid(_unit_price numeric, _extended_price numeric, _quantity numeric, _currency_code text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT (COALESCE(_unit_price, _extended_price / NULLIF(_quantity, 0)) >= 0
    AND _quantity > 0
    AND (_currency_code IS NULL OR btrim(_currency_code) = '' OR upper(btrim(_currency_code)) = 'USD')) IS TRUE
$$;
REVOKE ALL ON FUNCTION public.price_row_is_valid(numeric, numeric, numeric, text) FROM PUBLIC, anon, authenticated, service_role;

-- Every posted observation with its source line and document. "valid" = usable in USD figures.
CREATE FUNCTION public.price_observation_rows(_organization_id uuid, _product_ids uuid[])
RETURNS TABLE (
  observation_id uuid,
  organization_id uuid,
  product_id uuid,
  vendor_id uuid,
  vendor_name text,
  vendor_product_id uuid,
  catalog_vendor_product_id uuid,
  sku_key text,
  sku_display text,
  invoice_id uuid,
  invoice_item_id uuid,
  line_number integer,
  document_type text,
  document_number text,
  invoice_number text,
  date_basis text,
  purchase_date date,
  created_at timestamptz,
  quantity numeric,
  unit_raw text,
  unit_key text,
  unit_valid boolean,
  package_raw text,
  price numeric,
  line_amount numeric,
  currency_basis text,
  valid boolean
)
LANGUAGE sql
STABLE
AS $$
  -- Line and vendor fields are scalar subqueries so a caller that does not use them (the state
  -- pass) never reads invoice_items or vendors; FKs guarantee both rows exist.
  SELECT
    history.id,
    history.organization_id,
    history.product_id,
    history.vendor_id,
    (SELECT vendor.name FROM public.vendors vendor WHERE vendor.id = history.vendor_id),
    history.vendor_product_id,
    mapping.catalog_vendor_product_id,
    NULLIF(upper(btrim(COALESCE(NULLIF(btrim(mapping.vendor_sku), ''),
      (SELECT item.sku FROM public.invoice_items item WHERE item.id = history.invoice_item_id)))), ''),
    COALESCE(
      NULLIF(btrim((SELECT item.sku FROM public.invoice_items item WHERE item.id = history.invoice_item_id)), ''),
      NULLIF(btrim(mapping.vendor_sku), '')),
    history.invoice_id,
    history.invoice_item_id,
    (SELECT item.line_number FROM public.invoice_items item WHERE item.id = history.invoice_item_id),
    COALESCE(NULLIF(btrim(invoice.document_type), ''), 'UNKNOWN'),
    CASE WHEN invoice.document_type = 'ORDER_CONFIRMATION'
      THEN COALESCE(NULLIF(btrim(invoice.order_number), ''), NULLIF(btrim(invoice.invoice_number), ''))
      ELSE COALESCE(NULLIF(btrim(invoice.invoice_number), ''), NULLIF(btrim(invoice.order_number), ''))
    END,
    invoice.invoice_number,
    CASE WHEN invoice.invoice_date IS NULL THEN 'posting_date' ELSE 'invoice_date' END,
    history.purchase_date,
    history.created_at,
    history.quantity,
    history.unit_of_measure,
    NULLIF(lower(btrim(history.unit_of_measure)), ''),
    COALESCE(lower(btrim(history.unit_of_measure)) ~ '^[a-z]{1,10}$', false),
    NULLIF(btrim(history.package_size), ''),
    COALESCE(history.unit_price, history.extended_price / NULLIF(history.quantity, 0))::numeric,
    COALESCE(history.extended_price,
      (SELECT item.total_price FROM public.invoice_items item WHERE item.id = history.invoice_item_id)),
    CASE
      WHEN invoice.currency_code IS NULL OR btrim(invoice.currency_code) = '' THEN 'legacy_usd'
      WHEN upper(btrim(invoice.currency_code)) = 'USD' THEN 'usd'
      ELSE 'other'
    END,
    public.price_row_is_valid(history.unit_price, history.extended_price, history.quantity, invoice.currency_code)
  -- Two branches, so a product list is read through the product index (an "IS NULL OR = ANY"
  -- predicate would force a scan of the whole organization).
  FROM (
    SELECT all_rows.* FROM public.inventory_price_history all_rows
    WHERE all_rows.organization_id = _organization_id AND _product_ids IS NULL
    UNION ALL
    SELECT listed.* FROM public.inventory_price_history listed
    WHERE listed.organization_id = _organization_id AND listed.product_id = ANY (_product_ids)
  ) history
  JOIN public.invoices invoice
    ON invoice.id = history.invoice_id
   AND invoice.organization_id = history.organization_id
   AND invoice.posted_at IS NOT NULL
  LEFT JOIN public.vendor_products mapping
    ON mapping.id = history.vendor_product_id
   AND mapping.organization_id = history.organization_id
$$;
REVOKE ALL ON FUNCTION public.price_observation_rows(uuid, uuid[]) FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION public.price_observation_rows(uuid, uuid[]) IS
  'Phase 6B.1 single definition of a historical price observation (posted invoice/order-confirmation line). Internal.';

-- Last purchases (each product's newest valid observation) newest first, after a keyset cursor:
-- an ordered walk of inventory_price_history_org_recent_idx that keeps a row only when no newer
-- valid observation of its product exists. Reads only as far as the page needs.
CREATE FUNCTION public.price_recent_anchors(
  _organization_id uuid,
  _vendor_id uuid,
  _after_date date,
  _after_created_at timestamptz,
  _after_id uuid,
  _limit integer
)
RETURNS TABLE (
  scan_position bigint,
  product_id uuid,
  product_name text,
  normalized_name text,
  vendor_id uuid,
  purchase_date date,
  created_at timestamptz,
  observation_id uuid
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    row_number() OVER (ORDER BY walk.purchase_date DESC, walk.created_at DESC, walk.id DESC),
    walk.product_id, product.name, product.normalized_name, walk.vendor_id,
    walk.purchase_date, walk.created_at, walk.id
  FROM (
    SELECT history.product_id, history.vendor_id, history.purchase_date, history.created_at, history.id
    FROM public.inventory_price_history history
    JOIN public.invoices invoice
      ON invoice.id = history.invoice_id
     AND invoice.organization_id = history.organization_id
     AND invoice.posted_at IS NOT NULL
    WHERE history.organization_id = _organization_id
      AND (history.purchase_date, history.created_at, history.id)
        < (COALESCE(_after_date, 'infinity'::date), COALESCE(_after_created_at, 'infinity'::timestamptz),
           COALESCE(_after_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid))
      AND public.price_row_is_valid(history.unit_price, history.extended_price, history.quantity, invoice.currency_code)
      AND NOT EXISTS (
        SELECT 1
        FROM public.inventory_price_history newer
        JOIN public.invoices newer_invoice
          ON newer_invoice.id = newer.invoice_id
         AND newer_invoice.organization_id = newer.organization_id
         AND newer_invoice.posted_at IS NOT NULL
        WHERE newer.organization_id = _organization_id
          AND newer.product_id = history.product_id
          AND (newer.purchase_date, newer.created_at, newer.id) > (history.purchase_date, history.created_at, history.id)
          AND public.price_row_is_valid(newer.unit_price, newer.extended_price, newer.quantity, newer_invoice.currency_code)
      )
      AND (_vendor_id IS NULL OR history.vendor_id = _vendor_id)
    ORDER BY history.purchase_date DESC, history.created_at DESC, history.id DESC
    LIMIT _limit
  ) walk
  JOIN public.products product
    ON product.id = walk.product_id
   AND product.organization_id = _organization_id
$$;
REVOKE ALL ON FUNCTION public.price_recent_anchors(uuid, uuid, date, timestamptz, uuid, integer) FROM PUBLIC, anon, authenticated, service_role;

-- Products with a last purchase in name order after a keyset cursor; each product's last
-- purchase is one index probe, made only for the products the page reads.
CREATE FUNCTION public.price_name_anchors(
  _organization_id uuid,
  _vendor_id uuid,
  _after_name text,
  _after_product_id uuid,
  _limit integer
)
RETURNS TABLE (
  scan_position bigint,
  product_id uuid,
  product_name text,
  normalized_name text,
  vendor_id uuid,
  purchase_date date,
  created_at timestamptz,
  observation_id uuid
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    row_number() OVER (ORDER BY listed.normalized_name, listed.id),
    listed.id, listed.name, listed.normalized_name, listed.vendor_id,
    listed.purchase_date, listed.created_at, listed.observation_id
  FROM (
    SELECT product.id, product.name, product.normalized_name,
      anchor.vendor_id, anchor.purchase_date, anchor.created_at, anchor.id AS observation_id
    FROM (
      -- Sorted first (OFFSET 0 keeps it a separate step), so the per-product probe below stops
      -- at the page limit instead of running for every product.
      SELECT candidate.id, candidate.name, candidate.normalized_name
      FROM public.products candidate
      WHERE candidate.organization_id = _organization_id
        AND (_after_name IS NULL OR (candidate.normalized_name, candidate.id) > (_after_name, _after_product_id))
      ORDER BY candidate.normalized_name, candidate.id
      OFFSET 0
    ) product
    CROSS JOIN LATERAL (
      SELECT history.vendor_id, history.purchase_date, history.created_at, history.id
      FROM public.inventory_price_history history
      JOIN public.invoices invoice
        ON invoice.id = history.invoice_id
       AND invoice.organization_id = history.organization_id
       AND invoice.posted_at IS NOT NULL
      WHERE history.organization_id = _organization_id
        AND history.product_id = product.id
        AND public.price_row_is_valid(history.unit_price, history.extended_price, history.quantity, invoice.currency_code)
      ORDER BY history.purchase_date DESC, history.created_at DESC, history.id DESC
      LIMIT 1
    ) anchor
    WHERE _vendor_id IS NULL OR anchor.vendor_id = _vendor_id
    ORDER BY product.normalized_name, product.id
    LIMIT _limit
  ) listed
$$;
REVOKE ALL ON FUNCTION public.price_name_anchors(uuid, uuid, text, uuid, integer) FROM PUBLIC, anon, authenticated, service_role;

-- One observation as shown to people: source document, line, date basis, age and amounts.
CREATE FUNCTION public.price_observation_evidence(_organization_id uuid, _observation_id uuid, _today date)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  SELECT jsonb_build_object(
    'observationId', o.observation_id,
    'vendorId', o.vendor_id,
    'vendorName', o.vendor_name,
    'vendorProductId', o.vendor_product_id,
    'sku', o.sku_display,
    'documentType', o.document_type,
    'documentNumber', o.document_number,
    'invoiceNumber', o.invoice_number,
    'dateBasis', o.date_basis,
    'purchaseDate', o.purchase_date,
    'ageDays', GREATEST(_today - o.purchase_date, 0),
    'recency', public.price_recency(o.purchase_date, _today),
    'quantity', o.quantity,
    'unitOfMeasure', o.unit_raw,
    'unitValid', o.unit_valid,
    'packageSize', o.package_raw,
    'price', o.price,
    'lineAmount', o.line_amount,
    'invoiceId', o.invoice_id,
    'invoiceItemId', o.invoice_item_id,
    'lineNumber', o.line_number
  )
  FROM public.price_observation_rows(_organization_id, NULL) o
  WHERE o.observation_id = _observation_id
$$;
REVOKE ALL ON FUNCTION public.price_observation_evidence(uuid, uuid, date) FROM PUBLIC, anon, authenticated, service_role;

-- The whole Phase 6B.1 decision for a set of products (NULL = every product): state, markers,
-- evidence and signals. One row per product with at least one valid observation. One pass:
-- window functions give each observation its product, vendor and same-SKU positions; per-vendor
-- and then per-product aggregates replace joins, so the cost grows linearly with observations.
-- Vendor pairs are only ever compared within one product's (small) set of vendors.
-- _with_evidence = false skips building the evidence objects (counts and filters only).
CREATE FUNCTION public.price_product_state(
  _organization_id uuid,
  _product_ids uuid[],
  _today date,
  _with_evidence boolean DEFAULT true
)
RETURNS TABLE (
  product_id uuid,
  state text,
  stale boolean,
  identity_issue text,
  observation_count integer,
  vendor_count integer,
  anchor jsonb,
  prior jsonb,
  change_amount numeric,
  change_percent numeric,
  lowest jsonb,
  alternative jsonb,
  difference numeric,
  comparable_vendor_count integer,
  comparison_withheld text,
  signals text[],
  anchor_vendor_id uuid
)
LANGUAGE sql
STABLE
AS $$
  -- Same-SKU groups: one row per product, vendor, SKU identity and unit key, holding its two
  -- newest observations. One sort serves every ordered aggregate.
  WITH same_sku AS (
    SELECT
      o.product_id, o.vendor_id, o.sku_key, o.unit_key,
      count(*)::integer AS observation_count,
      (array_agg(o.observation_id ORDER BY o.purchase_date DESC, o.created_at DESC, o.observation_id DESC))[1:2] AS ids,
      (array_agg(o.price ORDER BY o.purchase_date DESC, o.created_at DESC, o.observation_id DESC))[1:2] AS prices,
      (array_agg(o.purchase_date ORDER BY o.purchase_date DESC, o.created_at DESC, o.observation_id DESC))[1] AS newest_date,
      (array_agg(o.created_at ORDER BY o.purchase_date DESC, o.created_at DESC, o.observation_id DESC))[1] AS newest_created_at,
      (array_agg(o.unit_valid ORDER BY o.purchase_date DESC, o.created_at DESC, o.observation_id DESC))[1] AS unit_valid,
      (array_agg(o.package_raw ORDER BY o.purchase_date DESC, o.created_at DESC, o.observation_id DESC))[1] AS package_raw,
      (array_agg(o.catalog_vendor_product_id ORDER BY o.purchase_date DESC, o.created_at DESC, o.observation_id DESC))[1] AS catalog_id
    FROM public.price_observation_rows(_organization_id, _product_ids) o
    WHERE o.valid
    GROUP BY o.product_id, o.vendor_id, o.sku_key, o.unit_key
  ),
  -- Vendors: the representative is the vendor's newest observation; its prior is the next
  -- newest observation in the same same-SKU group.
  per_vendor AS (
    SELECT
      g.product_id,
      g.vendor_id,
      sum(g.observation_count)::integer AS observation_count,
      bool_or(g.sku_key IS NULL) AS missing_sku,
      min(g.sku_key) AS min_sku_key,
      max(g.sku_key) AS max_sku_key,
      (array_agg(g.ids[1] ORDER BY g.newest_date DESC, g.newest_created_at DESC, g.ids[1] DESC))[1] AS rep_id,
      (array_agg(g.prices[1] ORDER BY g.newest_date DESC, g.newest_created_at DESC, g.ids[1] DESC))[1] AS rep_price,
      (array_agg(g.unit_key ORDER BY g.newest_date DESC, g.newest_created_at DESC, g.ids[1] DESC))[1] AS rep_unit_key,
      (array_agg(g.unit_valid ORDER BY g.newest_date DESC, g.newest_created_at DESC, g.ids[1] DESC))[1] AS rep_unit_valid,
      (array_agg(g.package_raw ORDER BY g.newest_date DESC, g.newest_created_at DESC, g.ids[1] DESC))[1] AS rep_package,
      (array_agg(g.catalog_id ORDER BY g.newest_date DESC, g.newest_created_at DESC, g.ids[1] DESC))[1] AS rep_catalog,
      (array_agg(g.newest_date ORDER BY g.newest_date DESC, g.newest_created_at DESC, g.ids[1] DESC))[1] AS rep_date,
      (array_agg(g.newest_created_at ORDER BY g.newest_date DESC, g.newest_created_at DESC, g.ids[1] DESC))[1] AS rep_created_at,
      (array_agg(g.ids[2] ORDER BY g.newest_date DESC, g.newest_created_at DESC, g.ids[1] DESC))[1] AS rep_prior_id,
      (array_agg(g.prices[2] ORDER BY g.newest_date DESC, g.newest_created_at DESC, g.ids[1] DESC))[1] AS rep_prior_price
    FROM same_sku g
    GROUP BY g.product_id, g.vendor_id
  ),
  per_vendor_identity AS (
    SELECT
      v.*,
      GREATEST(_today - v.rep_date, 0) <= 180 AS rep_fresh,
      -- More than one SKU identity among the vendor's observed SKUs and its active mappings.
      (v.min_sku_key IS DISTINCT FROM v.max_sku_key
       OR (SELECT count(DISTINCT key) FROM (
             SELECT upper(btrim(mapping.vendor_sku)) AS key
             FROM public.vendor_products mapping
             WHERE mapping.organization_id = _organization_id
               AND mapping.product_id = v.product_id
               AND mapping.vendor_id = v.vendor_id
               AND mapping.active
               AND NULLIF(btrim(mapping.vendor_sku), '') IS NOT NULL
             UNION
             SELECT v.min_sku_key WHERE v.min_sku_key IS NOT NULL
           ) keys) > 1) AS multiple_skus
    FROM per_vendor v
  ),
  per_product AS (
    SELECT
      v.product_id,
      sum(v.observation_count)::integer AS observation_count,
      count(*)::integer AS vendor_count,
      bool_or(v.multiple_skus) AS multiple_skus,
      bool_or(v.missing_sku) AS missing_sku,
      bool_or(v.rep_unit_key IS NULL) AS missing_unit,
      bool_or(v.rep_unit_key IS NOT NULL AND NOT v.rep_unit_valid) AS malformed_unit,
      -- The last purchase is the newest vendor representative.
      (array_agg(v.vendor_id ORDER BY v.rep_date DESC, v.rep_created_at DESC, v.rep_id DESC))[1] AS anchor_vendor_id,
      (array_agg(v.rep_id ORDER BY v.rep_date DESC, v.rep_created_at DESC, v.rep_id DESC))[1] AS anchor_id,
      (array_agg(v.rep_price ORDER BY v.rep_date DESC, v.rep_created_at DESC, v.rep_id DESC))[1] AS anchor_price,
      (array_agg(v.rep_unit_key ORDER BY v.rep_date DESC, v.rep_created_at DESC, v.rep_id DESC))[1] AS anchor_unit_key,
      (array_agg(v.rep_unit_valid ORDER BY v.rep_date DESC, v.rep_created_at DESC, v.rep_id DESC))[1] AS anchor_unit_valid,
      (array_agg(v.rep_package ORDER BY v.rep_date DESC, v.rep_created_at DESC, v.rep_id DESC))[1] AS anchor_package,
      (array_agg(v.rep_catalog ORDER BY v.rep_date DESC, v.rep_created_at DESC, v.rep_id DESC))[1] AS anchor_catalog,
      (array_agg(v.rep_fresh ORDER BY v.rep_date DESC, v.rep_created_at DESC, v.rep_id DESC))[1] AS anchor_fresh,
      (array_agg(v.rep_prior_id ORDER BY v.rep_date DESC, v.rep_created_at DESC, v.rep_id DESC))[1] AS prior_id,
      (array_agg(v.rep_prior_price ORDER BY v.rep_date DESC, v.rep_created_at DESC, v.rep_id DESC))[1] AS prior_price,
      jsonb_agg(jsonb_build_object(
        'vendorId', v.vendor_id, 'observationId', v.rep_id, 'price', v.rep_price,
        'unitKey', v.rep_unit_key, 'unitValid', v.rep_unit_valid, 'package', v.rep_package,
        'catalog', v.rep_catalog, 'date', v.rep_date, 'fresh', v.rep_fresh)) AS reps
    FROM per_vendor_identity v
    GROUP BY v.product_id
  ),
  compared AS (
    SELECT
      p.*,
      pairs.any_same_unit,
      pairs.any_pass,
      matches.match_count,
      matches.fresh_count,
      matches.cheapest_id,
      matches.cheapest_price
    FROM per_product p
    LEFT JOIN LATERAL (
      SELECT
        bool_or((a ->> 'unitValid')::boolean AND (b ->> 'unitValid')::boolean
          AND a ->> 'unitKey' = b ->> 'unitKey') AS any_same_unit,
        bool_or((a ->> 'unitValid')::boolean AND (b ->> 'unitValid')::boolean
          AND a ->> 'unitKey' = b ->> 'unitKey'
          AND public.price_package_agreement(a ->> 'unitKey', a ->> 'package', b ->> 'package',
            (a ->> 'catalog')::uuid, (b ->> 'catalog')::uuid)) AS any_pass
      FROM jsonb_array_elements(p.reps) a
      JOIN jsonb_array_elements(p.reps) b ON b ->> 'vendorId' > a ->> 'vendorId'
      WHERE p.vendor_count > 1
    ) pairs ON true
    LEFT JOIN LATERAL (
      SELECT
        count(*)::integer AS match_count,
        (count(*) FILTER (WHERE (r ->> 'fresh')::boolean AND p.anchor_fresh))::integer AS fresh_count,
        (array_agg((r ->> 'observationId')::uuid
          ORDER BY (r ->> 'price')::numeric, r ->> 'date' DESC, r ->> 'vendorId')
          FILTER (WHERE (r ->> 'fresh')::boolean AND p.anchor_fresh))[1] AS cheapest_id,
        min((r ->> 'price')::numeric) FILTER (WHERE (r ->> 'fresh')::boolean AND p.anchor_fresh) AS cheapest_price
      FROM jsonb_array_elements(p.reps) r
      WHERE p.vendor_count > 1
        AND (r ->> 'vendorId')::uuid <> p.anchor_vendor_id
        AND p.anchor_unit_valid AND (r ->> 'unitValid')::boolean
        AND p.anchor_unit_key = r ->> 'unitKey'
        AND public.price_package_agreement(p.anchor_unit_key, p.anchor_package, r ->> 'package',
          p.anchor_catalog, (r ->> 'catalog')::uuid)
    ) matches ON true
  ),
  stated AS (
    SELECT
      c.*,
      CASE
        WHEN c.multiple_skus THEN 'multiple_skus'
        WHEN c.missing_sku THEN 'missing_sku'
        WHEN c.missing_unit THEN 'missing_unit'
        WHEN c.malformed_unit THEN 'malformed_unit'
      END AS identity_issue,
      CASE
        WHEN c.multiple_skus OR c.missing_sku OR c.missing_unit OR c.malformed_unit THEN 'insufficient_identity'
        WHEN c.observation_count = 1 THEN 'one_purchase'
        WHEN c.vendor_count = 1 THEN 'single_vendor'
        WHEN COALESCE(c.any_pass, false) THEN 'comparable'
        WHEN COALESCE(c.any_same_unit, false) THEN 'missing_package_details'
        ELSE 'incompatible_units'
      END AS state
    FROM compared c
  ),
  decided AS (
    SELECT
      stated.*,
      (stated.state = 'comparable' AND COALESCE(stated.fresh_count, 0) > 0) AS numbers,
      CASE
        WHEN stated.state <> 'comparable' OR COALESCE(stated.fresh_count, 0) > 0 THEN NULL
        WHEN COALESCE(stated.match_count, 0) > 0 THEN 'stale'
        ELSE 'last_purchase_not_comparable'
      END AS withheld,
      CASE WHEN stated.state <> 'insufficient_identity' AND stated.prior_id IS NOT NULL
        AND stated.anchor_unit_valid
        THEN stated.anchor_price - stated.prior_price END AS change
    FROM stated
  ),
  marked AS (
    SELECT
      decided.*,
      (NOT decided.anchor_fresh OR decided.withheld IS NOT DISTINCT FROM 'stale') AS is_stale
    FROM decided
  )
  SELECT
    marked.product_id,
    marked.state,
    marked.is_stale,
    marked.identity_issue,
    marked.observation_count,
    marked.vendor_count,
    CASE WHEN _with_evidence THEN public.price_observation_evidence(_organization_id, marked.anchor_id, _today) END,
    CASE WHEN _with_evidence AND marked.change IS NOT NULL
      THEN public.price_observation_evidence(_organization_id, marked.prior_id, _today) END,
    marked.change,
    CASE WHEN marked.change IS NOT NULL AND marked.prior_price > 0
      THEN (marked.change / marked.prior_price) * 100 END,
    CASE WHEN _with_evidence AND marked.numbers THEN public.price_observation_evidence(_organization_id,
      CASE WHEN marked.anchor_price <= marked.cheapest_price THEN marked.anchor_id ELSE marked.cheapest_id END, _today)
    END,
    CASE WHEN _with_evidence AND marked.numbers
      THEN public.price_observation_evidence(_organization_id, marked.cheapest_id, _today) END,
    CASE WHEN marked.numbers THEN marked.anchor_price - marked.cheapest_price END,
    CASE WHEN marked.numbers THEN marked.fresh_count + 1 ELSE 0 END,
    marked.withheld,
    array_remove(ARRAY[
      CASE WHEN marked.numbers AND marked.anchor_price > marked.cheapest_price
        THEN 'lower_comparable_price_other_vendor' END,
      CASE WHEN marked.change > 0 AND marked.anchor_fresh THEN 'same_sku_price_increased' END,
      CASE WHEN marked.is_stale THEN 'price_data_stale' END,
      CASE WHEN marked.state = 'missing_package_details' THEN 'package_details_missing' END,
      CASE WHEN marked.vendor_count >= 2 AND marked.state IN ('insufficient_identity', 'incompatible_units')
        THEN 'multiple_vendors_not_comparable' END
    ], NULL),
    marked.anchor_vendor_id
  FROM marked
$$;
REVOKE ALL ON FUNCTION public.price_product_state(uuid, uuid[], date, boolean) FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION public.price_product_state(uuid, uuid[], date, boolean) IS
  'Phase 6B.1 state, markers, evidence and signals per product (NULL = all products). Internal; the only implementation of the comparison rules.';

-- The summary's counting path: the same rules as price_product_state, executed for counts
-- only. One hash-aggregated pass over the organization's price history (no sort, no evidence,
-- coverage folded in); each vendor's latest valid observation through
-- inventory_price_history_product_vendor_order_idx; the same-SKU prior looked up only where
-- the increase signal can fire (a recent last purchase with sufficient identity). Returns one
-- row per product with any posted observation: state, stale, signals and coverage partials
-- (state is NULL for a product whose observations are all excluded, e.g. non-USD).
-- The behaviour suite and the 1M benchmark assert it equals price_product_state per product.
-- The organization's invoices that are unposted, non-USD, order confirmations or undated:
-- usually few. Every other observation is posted, USD-basis, an invoice, and dated.
CREATE FUNCTION public.price_summary_flagged_invoices(_organization_id uuid)
RETURNS TABLE (id uuid, posted boolean, usd_basis boolean, order_confirmation boolean, dated_by_posting boolean)
LANGUAGE sql
STABLE
AS $$
    SELECT invoice.id,
      invoice.posted_at IS NOT NULL AS posted,
      (invoice.currency_code IS NULL OR btrim(invoice.currency_code) = ''
        OR upper(btrim(invoice.currency_code)) = 'USD') AS usd_basis,
      COALESCE(invoice.document_type = 'ORDER_CONFIRMATION', false) AS order_confirmation,
      invoice.invoice_date IS NULL AS dated_by_posting
    FROM public.invoices invoice
    WHERE invoice.organization_id = _organization_id
      AND (invoice.posted_at IS NULL
        OR NOT (invoice.currency_code IS NULL OR btrim(invoice.currency_code) = ''
                OR upper(btrim(invoice.currency_code)) = 'USD')
        OR invoice.document_type = 'ORDER_CONFIRMATION'
        OR invoice.invoice_date IS NULL)
$$;
REVOKE ALL ON FUNCTION public.price_summary_flagged_invoices(uuid) FROM PUBLIC, anon, authenticated, service_role;

-- The summary's one pass over an organization's price history: identity groups keyed by
-- product, vendor, mapping, unit and the observation's flags, with counts and the unmapped
-- lines' SKU range. Its own function so the planner settings below apply to this statement
-- only: tens of thousands of groups hash in memory, where a sort would order (and spill) every
-- observation.
CREATE FUNCTION public.price_summary_groups(_organization_id uuid)
RETURNS TABLE (
  product_id uuid,
  vendor_id uuid,
  vendor_product_id uuid,
  unit_of_measure text,
  posted boolean,
  usd_basis boolean,
  valid boolean,
  order_confirmation boolean,
  dated_by_posting boolean,
  package_missing boolean,
  price_missing boolean,
  n bigint,
  no_sku_n bigint,
  min_line_sku_key text,
  max_line_sku_key text
)
LANGUAGE sql
STABLE
SET enable_sort = off
SET work_mem = '32MB'
AS $$
  WITH flagged AS MATERIALIZED (
    SELECT * FROM public.price_summary_flagged_invoices(_organization_id)
  ),
  classified AS (
    SELECT
      history.product_id, history.vendor_id, history.vendor_product_id, history.unit_of_measure,
      CASE WHEN history.vendor_product_id IS NULL
        THEN NULLIF(upper(btrim((SELECT item.sku FROM public.invoice_items item WHERE item.id = history.invoice_item_id))), '')
      END AS line_sku_key,
      -- The observation's flags as one small key (decoded below): 1 posted, 2 USD basis,
      -- 4 valid (price_row_is_valid), 8 order confirmation, 16 dated by posting, 32 package
      -- missing, 64 price missing.
      ((CASE WHEN flag.posted IS NOT FALSE THEN 1 ELSE 0 END)
       + (CASE WHEN flag.usd_basis IS NOT FALSE THEN 2 ELSE 0 END)
       + (CASE WHEN flag.posted IS NOT FALSE AND flag.usd_basis IS NOT FALSE
            AND COALESCE(history.unit_price, history.extended_price / NULLIF(history.quantity, 0)) >= 0
            AND history.quantity > 0 THEN 4 ELSE 0 END)
       + (CASE WHEN flag.order_confirmation THEN 8 ELSE 0 END)
       + (CASE WHEN flag.dated_by_posting THEN 16 ELSE 0 END)
       + (CASE WHEN NULLIF(btrim(history.package_size), '') IS NULL THEN 32 ELSE 0 END)
       + (CASE WHEN COALESCE(history.unit_price, history.extended_price / NULLIF(history.quantity, 0)) IS NULL THEN 64 ELSE 0 END)
      )::smallint AS flags
    FROM public.inventory_price_history history
    LEFT JOIN flagged flag ON flag.id = history.invoice_id
    WHERE history.organization_id = _organization_id
  ),
  -- Identity groups on plain columns (product, vendor, mapping, unit and the row's flags): each
  -- observation does three aggregate steps, and every count below is a sum over groups. An
  -- unmapped line's SKU is carried as min/max: more than one distinct key <=> min <> max.
  groups AS (
    SELECT
      c.product_id, c.vendor_id, c.vendor_product_id, c.unit_of_measure, c.flags,
      count(*) AS n,
      count(*) FILTER (WHERE c.vendor_product_id IS NULL AND c.line_sku_key IS NULL) AS no_sku_n,
      min(c.line_sku_key) AS min_line_sku_key,
      max(c.line_sku_key) AS max_line_sku_key
    FROM classified c
    GROUP BY c.product_id, c.vendor_id, c.vendor_product_id, c.unit_of_measure, c.flags
  )
  SELECT g.product_id, g.vendor_id, g.vendor_product_id, g.unit_of_measure,
    (g.flags & 1) <> 0, (g.flags & 2) <> 0, (g.flags & 4) <> 0, (g.flags & 8) <> 0,
    (g.flags & 16) <> 0, (g.flags & 32) <> 0, (g.flags & 64) <> 0,
    g.n, g.no_sku_n, g.min_line_sku_key, g.max_line_sku_key
  FROM groups g
$$;
REVOKE ALL ON FUNCTION public.price_summary_groups(uuid) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.price_summary_product_states(_organization_id uuid, _today date)
RETURNS TABLE (
  product_id uuid,
  state text,
  stale boolean,
  signals text[],
  anchor_vendor_id uuid,
  valid_vendor_ids uuid[],
  observation_count integer,
  posted_count integer,
  non_usd_count integer,
  missing_price_count integer,
  order_confirmation_count integer,
  dated_by_posting_count integer,
  missing_package_count integer,
  unit_problem_count integer
)
LANGUAGE sql
STABLE
AS $$
  WITH groups AS MATERIALIZED (
    SELECT * FROM public.price_summary_groups(_organization_id)
  ),
  keyed AS (
    SELECT g.*,
      CASE WHEN g.vendor_product_id IS NOT NULL THEN upper(btrim(mapping.vendor_sku)) ELSE g.min_line_sku_key END AS min_sku_key,
      CASE WHEN g.vendor_product_id IS NOT NULL THEN upper(btrim(mapping.vendor_sku)) ELSE g.max_line_sku_key END AS max_sku_key,
      public.price_unit_is_valid(g.unit_of_measure) AS unit_valid
    FROM groups g
    LEFT JOIN public.vendor_products mapping
      ON mapping.id = g.vendor_product_id AND mapping.organization_id = _organization_id
  ),
  per_vendor AS (
    SELECT
      k.product_id, k.vendor_id,
      (COALESCE(sum(k.n) FILTER (WHERE k.valid), 0))::integer AS valid_n,
      COALESCE(bool_or(k.no_sku_n > 0) FILTER (WHERE k.valid), false) AS missing_sku,
      min(k.min_sku_key) FILTER (WHERE k.valid) AS min_sku_key,
      max(k.max_sku_key) FILTER (WHERE k.valid) AS max_sku_key,
      (COALESCE(sum(k.n) FILTER (WHERE k.posted), 0))::integer AS posted_n,
      (COALESCE(sum(k.n) FILTER (WHERE k.posted AND NOT k.usd_basis), 0))::integer AS non_usd_n,
      (COALESCE(sum(k.n) FILTER (WHERE k.posted AND k.usd_basis AND k.price_missing), 0))::integer AS missing_price_n,
      (COALESCE(sum(k.n) FILTER (WHERE k.valid AND k.order_confirmation), 0))::integer AS oc_n,
      (COALESCE(sum(k.n) FILTER (WHERE k.valid AND k.dated_by_posting), 0))::integer AS posting_n,
      (COALESCE(sum(k.n) FILTER (WHERE k.valid AND k.package_missing), 0))::integer AS missing_package_n,
      (COALESCE(sum(k.n) FILTER (WHERE k.valid AND NOT k.unit_valid), 0))::integer AS unit_problem_n
    FROM keyed k
    GROUP BY k.product_id, k.vendor_id
  ),
  -- Active mapping SKU identities per product and vendor, counted once.
  mapping_keys AS (
    SELECT mapping.product_id, mapping.vendor_id,
      count(DISTINCT upper(btrim(mapping.vendor_sku))) AS key_count,
      min(upper(btrim(mapping.vendor_sku))) AS min_key
    FROM public.vendor_products mapping
    WHERE mapping.organization_id = _organization_id
      AND mapping.active
      AND NULLIF(btrim(mapping.vendor_sku), '') IS NOT NULL
    GROUP BY mapping.product_id, mapping.vendor_id
  ),
  -- Each vendor's representative: its latest valid observation, and the valid observation
  -- before it (one index probe for both).
  probed AS (
    SELECT
      v.product_id, v.vendor_id, v.valid_n, v.missing_sku, v.min_sku_key, v.max_sku_key,
      top.ids, top.dates, top.created, top.units, top.packages, top.mappings, top.items, top.prices
    FROM per_vendor v
    CROSS JOIN LATERAL (
      SELECT
        array_agg(candidate.id ORDER BY candidate.purchase_date DESC, candidate.created_at DESC, candidate.id DESC) AS ids,
        array_agg(candidate.purchase_date ORDER BY candidate.purchase_date DESC, candidate.created_at DESC, candidate.id DESC) AS dates,
        array_agg(candidate.created_at ORDER BY candidate.purchase_date DESC, candidate.created_at DESC, candidate.id DESC) AS created,
        array_agg(candidate.unit_of_measure ORDER BY candidate.purchase_date DESC, candidate.created_at DESC, candidate.id DESC) AS units,
        array_agg(candidate.package_size ORDER BY candidate.purchase_date DESC, candidate.created_at DESC, candidate.id DESC) AS packages,
        array_agg(candidate.vendor_product_id ORDER BY candidate.purchase_date DESC, candidate.created_at DESC, candidate.id DESC) AS mappings,
        array_agg(candidate.invoice_item_id ORDER BY candidate.purchase_date DESC, candidate.created_at DESC, candidate.id DESC) AS items,
        array_agg(candidate.price ORDER BY candidate.purchase_date DESC, candidate.created_at DESC, candidate.id DESC) AS prices
      FROM (
        SELECT history.id, history.purchase_date, history.created_at, history.unit_of_measure, history.package_size,
          history.vendor_product_id, history.invoice_item_id,
          COALESCE(history.unit_price, history.extended_price / NULLIF(history.quantity, 0)) AS price
        FROM public.inventory_price_history history
        JOIN public.invoices invoice
          ON invoice.id = history.invoice_id
         AND invoice.organization_id = history.organization_id
         AND invoice.posted_at IS NOT NULL
        WHERE history.organization_id = _organization_id
          AND history.product_id = v.product_id
          AND history.vendor_id = v.vendor_id
          AND public.price_row_is_valid(history.unit_price, history.extended_price, history.quantity, invoice.currency_code)
        ORDER BY history.purchase_date DESC, history.created_at DESC, history.id DESC
        LIMIT 2
      ) candidate
    ) top
    WHERE v.valid_n > 0
  ),
  reps AS MATERIALIZED (
    SELECT
      p.product_id, p.vendor_id, p.valid_n, p.missing_sku,
      -- More than one SKU identity among the vendor's observed SKUs and its active mappings
      -- (the same rule as price_product_state).
      (p.min_sku_key IS DISTINCT FROM p.max_sku_key
       OR COALESCE(mk.key_count, 0) > 1
       OR (mk.key_count = 1 AND p.min_sku_key IS NOT NULL AND mk.min_key <> p.min_sku_key)) AS multiple_skus,
      p.ids[1] AS rep_id, p.dates[1] AS rep_date, p.created[1] AS rep_created_at, p.prices[1] AS rep_price,
      public.price_unit_key(p.units[1]) AS rep_unit_key,
      public.price_unit_is_valid(p.units[1]) AS rep_unit_valid,
      NULLIF(btrim(p.packages[1]), '') AS rep_package,
      mapping.catalog_vendor_product_id AS rep_catalog,
      NULLIF(upper(btrim(COALESCE(mapping.vendor_sku,
        (SELECT item.sku FROM public.invoice_items item WHERE item.id = p.items[1])))), '') AS rep_sku_key,
      GREATEST(_today - p.dates[1], 0) <= 180 AS rep_fresh,
      -- The next observation is the same-SKU prior when it has the same mapping and unit key
      -- (otherwise the prior is looked up below, if the increase signal can apply).
      CASE WHEN p.ids[2] IS NOT NULL AND p.mappings[1] IS NOT NULL
        AND p.mappings[2] = p.mappings[1]
        AND public.price_unit_key(p.units[2]) IS NOT DISTINCT FROM public.price_unit_key(p.units[1])
        THEN p.prices[2] END AS next_same_sku_price,
      p.ids[2] IS NULL AS no_earlier
    FROM probed p
    LEFT JOIN mapping_keys mk ON mk.product_id = p.product_id AND mk.vendor_id = p.vendor_id
    LEFT JOIN public.vendor_products mapping
      ON mapping.id = p.mappings[1] AND mapping.organization_id = _organization_id
  ),
  per_product AS (
    SELECT
      r.product_id,
      sum(r.valid_n)::integer AS observation_count,
      count(*)::integer AS vendor_count,
      array_agg(r.vendor_id) AS valid_vendor_ids,
      bool_or(r.multiple_skus) AS multiple_skus,
      bool_or(r.missing_sku) AS missing_sku,
      bool_or(r.rep_unit_key IS NULL) AS missing_unit,
      bool_or(r.rep_unit_key IS NOT NULL AND NOT r.rep_unit_valid) AS malformed_unit
    FROM reps r
    GROUP BY r.product_id
  ),
  anchors AS (
    SELECT DISTINCT ON (r.product_id) r.*
    FROM reps r
    ORDER BY r.product_id, r.rep_date DESC, r.rep_created_at DESC, r.rep_id DESC
  ),
  -- Vendor pairs, only for products with two or more vendors.
  pairs AS (
    SELECT a.product_id,
      bool_or(a.rep_unit_valid AND b.rep_unit_valid AND a.rep_unit_key = b.rep_unit_key) AS any_same_unit,
      bool_or(a.rep_unit_valid AND b.rep_unit_valid AND a.rep_unit_key = b.rep_unit_key
        AND public.price_package_agreement(a.rep_unit_key, a.rep_package, b.rep_package, a.rep_catalog, b.rep_catalog)) AS any_pass
    FROM reps a
    JOIN reps b ON b.product_id = a.product_id AND b.vendor_id > a.vendor_id
    GROUP BY a.product_id
  ),
  matches AS (
    SELECT anchor.product_id,
      count(*)::integer AS match_count,
      (count(*) FILTER (WHERE other.rep_fresh AND anchor.rep_fresh))::integer AS fresh_count,
      min(other.rep_price) FILTER (WHERE other.rep_fresh AND anchor.rep_fresh) AS cheapest_price
    FROM anchors anchor
    JOIN reps other ON other.product_id = anchor.product_id AND other.vendor_id <> anchor.vendor_id
    WHERE anchor.rep_unit_valid AND other.rep_unit_valid AND anchor.rep_unit_key = other.rep_unit_key
      AND public.price_package_agreement(anchor.rep_unit_key, anchor.rep_package, other.rep_package,
        anchor.rep_catalog, other.rep_catalog)
    GROUP BY anchor.product_id
  ),
  stated AS (
    SELECT
      p.*, a.vendor_id AS anchor_vendor_id, a.rep_id AS anchor_id, a.rep_date AS anchor_date,
      a.rep_created_at AS anchor_created_at, a.rep_price AS anchor_price, a.rep_fresh AS anchor_fresh,
      a.rep_unit_key AS anchor_unit_key, a.rep_unit_valid AS anchor_unit_valid, a.rep_sku_key AS anchor_sku_key,
      a.next_same_sku_price AS anchor_next_same_sku_price, a.no_earlier AS anchor_no_earlier,
      COALESCE(m.match_count, 0) AS match_count, COALESCE(m.fresh_count, 0) AS fresh_count, m.cheapest_price,
      CASE
        WHEN p.multiple_skus OR p.missing_sku OR p.missing_unit OR p.malformed_unit THEN 'insufficient_identity'
        WHEN p.observation_count = 1 THEN 'one_purchase'
        WHEN p.vendor_count = 1 THEN 'single_vendor'
        WHEN COALESCE(pr.any_pass, false) THEN 'comparable'
        WHEN COALESCE(pr.any_same_unit, false) THEN 'missing_package_details'
        ELSE 'incompatible_units'
      END AS state
    FROM per_product p
    JOIN anchors a ON a.product_id = p.product_id
    LEFT JOIN pairs pr ON pr.product_id = p.product_id
    LEFT JOIN matches m ON m.product_id = p.product_id
  ),
  decided AS (
    SELECT s.*,
      (s.state = 'comparable' AND s.fresh_count > 0) AS numbers,
      CASE
        WHEN s.state <> 'comparable' OR s.fresh_count > 0 THEN NULL
        WHEN s.match_count > 0 THEN 'stale'
        ELSE 'last_purchase_not_comparable'
      END AS withheld,
      -- The same-SKU increase signal can only fire for a recent last purchase with sufficient
      -- identity, so the prior observation is looked up only there.
      CASE WHEN s.state <> 'insufficient_identity' AND s.anchor_fresh AND s.anchor_unit_valid THEN CASE
        WHEN s.anchor_next_same_sku_price IS NOT NULL THEN s.anchor_price > s.anchor_next_same_sku_price
        WHEN s.anchor_no_earlier THEN NULL
        ELSE (
        SELECT s.anchor_price > COALESCE(earlier.unit_price, earlier.extended_price / NULLIF(earlier.quantity, 0))
        FROM public.inventory_price_history earlier
        JOIN public.invoices invoice
          ON invoice.id = earlier.invoice_id
         AND invoice.organization_id = earlier.organization_id
         AND invoice.posted_at IS NOT NULL
        LEFT JOIN public.vendor_products mapping
          ON mapping.id = earlier.vendor_product_id AND mapping.organization_id = earlier.organization_id
        WHERE earlier.organization_id = _organization_id
          AND earlier.product_id = s.product_id
          AND earlier.vendor_id = s.anchor_vendor_id
          AND (earlier.purchase_date, earlier.created_at, earlier.id) < (s.anchor_date, s.anchor_created_at, s.anchor_id)
          AND public.price_row_is_valid(earlier.unit_price, earlier.extended_price, earlier.quantity, invoice.currency_code)
          AND public.price_unit_key(earlier.unit_of_measure) = s.anchor_unit_key
          AND NULLIF(upper(btrim(COALESCE(mapping.vendor_sku,
                (SELECT item.sku FROM public.invoice_items item WHERE item.id = earlier.invoice_item_id)))), '') = s.anchor_sku_key
        ORDER BY earlier.purchase_date DESC, earlier.created_at DESC, earlier.id DESC
        LIMIT 1) END END AS increased
    FROM stated s
  ),
  final AS (
    SELECT d.*,
      (NOT d.anchor_fresh OR d.withheld IS NOT DISTINCT FROM 'stale') AS is_stale
    FROM decided d
  ),
  coverage AS (
    SELECT v.product_id,
      sum(v.posted_n)::integer AS posted_n, sum(v.non_usd_n)::integer AS non_usd_n,
      sum(v.missing_price_n)::integer AS missing_price_n, sum(v.oc_n)::integer AS oc_n,
      sum(v.posting_n)::integer AS posting_n, sum(v.missing_package_n)::integer AS missing_package_n,
      COALESCE(sum(v.unit_problem_n), 0)::integer AS unit_problem_n
    FROM per_vendor v
    GROUP BY v.product_id
  )
  SELECT
    c.product_id,
    f.state,
    f.is_stale,
    CASE WHEN f.product_id IS NOT NULL THEN array_remove(ARRAY[
      CASE WHEN f.numbers AND f.anchor_price > f.cheapest_price THEN 'lower_comparable_price_other_vendor' END,
      CASE WHEN f.increased THEN 'same_sku_price_increased' END,
      CASE WHEN f.is_stale THEN 'price_data_stale' END,
      CASE WHEN f.state = 'missing_package_details' THEN 'package_details_missing' END,
      CASE WHEN f.vendor_count >= 2 AND f.state IN ('insufficient_identity', 'incompatible_units')
        THEN 'multiple_vendors_not_comparable' END
    ], NULL) END,
    f.anchor_vendor_id,
    f.valid_vendor_ids,
    COALESCE(f.observation_count, 0),
    c.posted_n, c.non_usd_n, c.missing_price_n, c.oc_n, c.posting_n, c.missing_package_n, c.unit_problem_n
  FROM coverage c
  LEFT JOIN final f ON f.product_id = c.product_id
$$;
REVOKE ALL ON FUNCTION public.price_summary_product_states(uuid, date) FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION public.price_summary_product_states(uuid, date) IS
  'Phase 6B.1 summary counting path: price_product_state''s rules executed for counts only (no evidence). Internal; asserted equal to price_product_state per product.';

-- ---------------------------------------------------------------------------------------
-- Price Intelligence list (keyset, scan budget).
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.list_price_intelligence_products(
  _organization_id uuid,
  _sort text DEFAULT 'recent',
  _filter text DEFAULT 'all',
  _vendor_id uuid DEFAULT NULL,
  _cursor jsonb DEFAULT NULL,
  _limit integer DEFAULT 50,
  _scan_limit integer DEFAULT 1000
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _today date := (now() AT TIME ZONE 'UTC')::date;
  _scan integer;
  _cursor_date date;
  _cursor_created timestamptz;
  _cursor_observation uuid;
  _cursor_name text;
  _cursor_product uuid;
  _result jsonb;
BEGIN
  PERFORM public.financial_assert_access(_organization_id, false);
  IF _sort IS NULL OR _sort NOT IN ('recent', 'product') THEN
    RAISE EXCEPTION 'sort must be recent or product' USING ERRCODE = '22023';
  END IF;
  IF _filter IS NULL OR _filter NOT IN (
      'all', 'insufficient_identity', 'one_purchase', 'single_vendor', 'comparable',
      'missing_package_details', 'incompatible_units', 'stale',
      'lower_comparable_price_other_vendor', 'same_sku_price_increased', 'price_data_stale',
      'package_details_missing', 'multiple_vendors_not_comparable') THEN
    RAISE EXCEPTION 'Unknown price intelligence filter' USING ERRCODE = '22023';
  END IF;
  IF _limit IS NULL OR _limit < 1 OR _limit > 100 THEN
    RAISE EXCEPTION 'limit must be between 1 and 100' USING ERRCODE = '22023';
  END IF;
  IF _scan_limit IS NULL OR _scan_limit < _limit OR _scan_limit > 5000 THEN
    RAISE EXCEPTION 'scan_limit must be between limit and 5000' USING ERRCODE = '22023';
  END IF;
  -- Without a filter every scanned product is returned, so scan one page (plus one to know
  -- whether another page exists).
  _scan := CASE WHEN _filter = 'all' THEN _limit + 1 ELSE _scan_limit END;

  IF _cursor IS NOT NULL AND _cursor <> 'null'::jsonb THEN
    BEGIN
      IF _sort = 'recent' THEN
        _cursor_date := (_cursor ->> 'purchaseDate')::date;
        _cursor_created := (_cursor ->> 'createdAt')::timestamptz;
        _cursor_observation := (_cursor ->> 'observationId')::uuid;
        IF _cursor_date IS NULL OR _cursor_created IS NULL OR _cursor_observation IS NULL THEN
          RAISE EXCEPTION 'incomplete';
        END IF;
      ELSE
        _cursor_name := _cursor ->> 'normalizedName';
        _cursor_product := (_cursor ->> 'productId')::uuid;
        IF _cursor_name IS NULL OR _cursor_product IS NULL THEN
          RAISE EXCEPTION 'incomplete';
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'Invalid price intelligence cursor' USING ERRCODE = '22023';
    END;
  END IF;

  WITH scanned AS MATERIALIZED (
    SELECT * FROM public.price_recent_anchors(
      _organization_id, _vendor_id, _cursor_date, _cursor_created, _cursor_observation, _scan)
    WHERE _sort = 'recent'
    UNION ALL
    SELECT * FROM public.price_name_anchors(
      _organization_id, _vendor_id, _cursor_name, _cursor_product, _scan)
    WHERE _sort = 'product'
  ),
  -- Filters need only states and signals; evidence is built for the returned page alone.
  states AS MATERIALIZED (
    SELECT * FROM public.price_product_state(
      _organization_id, (SELECT array_agg(scanned.product_id) FROM scanned), _today, false)
  ),
  matched AS MATERIALIZED (
    SELECT scanned.*, states.state, states.stale, states.signals,
      row_number() OVER (ORDER BY scanned.scan_position) AS match_position
    FROM scanned
    JOIN states ON states.product_id = scanned.product_id
    WHERE _filter = 'all'
       OR states.state = _filter
       OR (_filter = 'stale' AND states.stale)
       OR _filter = ANY (states.signals)
  ),
  page AS MATERIALIZED (
    SELECT * FROM matched WHERE match_position <= _limit
  ),
  page_states AS MATERIALIZED (
    SELECT page.match_position, page.product_name, full_state.*
    FROM public.price_product_state(
      _organization_id, (SELECT array_agg(page.product_id) FROM page), _today, true) full_state
    JOIN page ON page.product_id = full_state.product_id
  ),
  bounds AS (
    SELECT
      (SELECT count(*) FROM scanned) AS scanned_count,
      (SELECT count(*) FROM matched) AS matched_count,
      (SELECT max(scan_position) FROM page) AS last_page_position,
      (SELECT max(scan_position) FROM scanned) AS last_scan_position
  ),
  next_row AS (
    SELECT scanned.* FROM scanned, bounds
    WHERE scanned.scan_position = CASE
      WHEN bounds.matched_count > _limit THEN bounds.last_page_position
      WHEN bounds.scanned_count >= _scan THEN
        CASE WHEN _filter = 'all' THEN bounds.last_page_position ELSE bounds.last_scan_position END
    END
  )
  SELECT jsonb_build_object(
    'organizationId', _organization_id,
    'currencyCode', 'USD',
    'asOf', _today,
    'sort', _sort,
    'filter', _filter,
    'vendorId', _vendor_id,
    'rows', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'productId', page.product_id,
        'productName', page.product_name,
        'state', page.state,
        'stale', page.stale,
        'identityIssue', page.identity_issue,
        'observationCount', page.observation_count,
        'vendorsObserved', page.vendor_count,
        'lastPurchase', page.anchor,
        'priorSameSku', page.prior,
        'changeAmount', page.change_amount,
        'changePercent', page.change_percent,
        'lowestComparable', page.lowest,
        'comparableAlternative', page.alternative,
        'differencePerUnit', page.difference,
        'comparableVendorCount', page.comparable_vendor_count,
        'comparisonWithheld', page.comparison_withheld,
        'signals', to_jsonb(page.signals)
      ) ORDER BY page.match_position)
      FROM page_states page
    ), '[]'::jsonb),
    'scanned', (SELECT scanned_count FROM bounds),
    'nextCursor', (
      SELECT CASE WHEN _sort = 'recent'
        THEN jsonb_build_object('purchaseDate', next_row.purchase_date, 'createdAt', next_row.created_at,
          'observationId', next_row.observation_id)
        ELSE jsonb_build_object('normalizedName', next_row.normalized_name, 'productId', next_row.product_id)
      END
      FROM next_row
    ),
    'exhausted', NOT EXISTS (SELECT 1 FROM next_row)
  ) INTO _result;

  RETURN _result;
END;
$$;
REVOKE ALL ON FUNCTION public.list_price_intelligence_products(uuid, text, text, uuid, jsonb, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_price_intelligence_products(uuid, text, text, uuid, jsonb, integer, integer) TO authenticated;
COMMENT ON FUNCTION public.list_price_intelligence_products(uuid, text, text, uuid, jsonb, integer, integer) IS
  'Phase 6B.1 Price Intelligence list for owners and admins: keyset pages by last purchase (recent) or product name; filters scan at most scan_limit products per call and return a cursor to continue.';

-- ---------------------------------------------------------------------------------------
-- Summary: counts for filter chips, the vendor filter and coverage.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.get_price_intelligence_summary(_organization_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _today date := (now() AT TIME ZONE 'UTC')::date;
  _result jsonb;
BEGIN
  PERFORM public.financial_assert_access(_organization_id, false);

  -- One pass: per-product state, signals and coverage from the summary counting path.
  WITH products AS MATERIALIZED (
    SELECT * FROM public.price_summary_product_states(_organization_id, _today)
  ),
  states AS (
    SELECT * FROM products WHERE state IS NOT NULL
  ),
  signal_counts AS (
    SELECT code, count(*)::integer AS n
    FROM states, unnest(states.signals) code
    GROUP BY code
  ),
  state_counts AS (
    SELECT states.state, count(*)::integer AS n FROM states GROUP BY states.state
  )
  SELECT jsonb_build_object(
    'organizationId', _organization_id,
    'currencyCode', 'USD',
    'asOf', _today,
    'productCount', (SELECT count(*) FROM states),
    'observationCount', (SELECT COALESCE(sum(observation_count), 0) FROM states),
    'vendorCount', (SELECT count(DISTINCT vendor) FROM states, unnest(states.valid_vendor_ids) vendor),
    'staleCount', (SELECT count(*) FROM states WHERE stale),
    'states', jsonb_build_object(
      'insufficient_identity', COALESCE((SELECT n FROM state_counts WHERE state = 'insufficient_identity'), 0),
      'one_purchase', COALESCE((SELECT n FROM state_counts WHERE state = 'one_purchase'), 0),
      'single_vendor', COALESCE((SELECT n FROM state_counts WHERE state = 'single_vendor'), 0),
      'comparable', COALESCE((SELECT n FROM state_counts WHERE state = 'comparable'), 0),
      'missing_package_details', COALESCE((SELECT n FROM state_counts WHERE state = 'missing_package_details'), 0),
      'incompatible_units', COALESCE((SELECT n FROM state_counts WHERE state = 'incompatible_units'), 0)
    ),
    'signals', jsonb_build_object(
      'lower_comparable_price_other_vendor', COALESCE((SELECT n FROM signal_counts WHERE code = 'lower_comparable_price_other_vendor'), 0),
      'same_sku_price_increased', COALESCE((SELECT n FROM signal_counts WHERE code = 'same_sku_price_increased'), 0),
      'price_data_stale', COALESCE((SELECT n FROM signal_counts WHERE code = 'price_data_stale'), 0),
      'package_details_missing', COALESCE((SELECT n FROM signal_counts WHERE code = 'package_details_missing'), 0),
      'multiple_vendors_not_comparable', COALESCE((SELECT n FROM signal_counts WHERE code = 'multiple_vendors_not_comparable'), 0)
    ),
    'vendors', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('vendorId', v.vendor_id, 'vendorName', v.vendor_name,
          'lastPurchaseProductCount', v.n) ORDER BY v.vendor_name, v.vendor_id)
      FROM (
        SELECT states.anchor_vendor_id AS vendor_id, vendor.name AS vendor_name, count(*)::integer AS n
        FROM states
        JOIN public.vendors vendor
          ON vendor.id = states.anchor_vendor_id AND vendor.organization_id = _organization_id
        GROUP BY states.anchor_vendor_id, vendor.name
      ) v
    ), '[]'::jsonb),
    'coverage', jsonb_build_object(
      'postedObservationCount', (SELECT COALESCE(sum(posted_count), 0) FROM products),
      'excludedNonUsdCount', (SELECT COALESCE(sum(non_usd_count), 0) FROM products),
      'excludedMissingPriceCount', (SELECT COALESCE(sum(missing_price_count), 0) FROM products),
      'orderConfirmationCount', (SELECT COALESCE(sum(order_confirmation_count), 0) FROM products),
      'datedByPostingCount', (SELECT COALESCE(sum(dated_by_posting_count), 0) FROM products),
      'missingPackageCount', (SELECT COALESCE(sum(missing_package_count), 0) FROM products),
      'missingOrMalformedUnitCount', (SELECT COALESCE(sum(unit_problem_count), 0) FROM products)
    )
  ) INTO _result;

  RETURN _result;
END;
$$;
REVOKE ALL ON FUNCTION public.get_price_intelligence_summary(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_price_intelligence_summary(uuid) TO authenticated;
COMMENT ON FUNCTION public.get_price_intelligence_summary(uuid) IS
  'Phase 6B.1 Price Intelligence counts per state and signal, vendors for the filter, and observation coverage. Owners and admins.';

-- ---------------------------------------------------------------------------------------
-- Product vendor history (product detail): vendors, identity, comparison evidence, sources.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.get_product_vendor_price_history(
  _organization_id uuid,
  _product_id uuid DEFAULT NULL,
  _inventory_item_id uuid DEFAULT NULL,
  _cursor jsonb DEFAULT NULL,
  _limit integer DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _today date := (now() AT TIME ZONE 'UTC')::date;
  _is_owner boolean;
  _product public.products%ROWTYPE;
  _resolved uuid;
  _cursor_date date;
  _cursor_created timestamptz;
  _cursor_observation uuid;
  _state record;
  _result jsonb;
BEGIN
  _is_owner := public.financial_assert_access(_organization_id, false);
  IF (_product_id IS NULL) = (_inventory_item_id IS NULL) THEN
    RAISE EXCEPTION 'Provide exactly one of product_id or inventory_item_id' USING ERRCODE = '22023';
  END IF;
  IF _limit IS NULL OR _limit < 1 OR _limit > 100 THEN
    RAISE EXCEPTION 'limit must be between 1 and 100' USING ERRCODE = '22023';
  END IF;

  IF _inventory_item_id IS NOT NULL THEN
    SELECT item.product_id INTO _resolved
    FROM public.inventory_items item
    WHERE item.id = _inventory_item_id AND item.organization_id = _organization_id;
    IF _resolved IS NULL THEN
      RAISE EXCEPTION 'Product not found' USING ERRCODE = 'P0002';
    END IF;
  ELSE
    _resolved := _product_id;
  END IF;

  SELECT * INTO _product FROM public.products product
  WHERE product.id = _resolved AND product.organization_id = _organization_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found' USING ERRCODE = 'P0002';
  END IF;

  IF _cursor IS NOT NULL AND _cursor <> 'null'::jsonb THEN
    BEGIN
      _cursor_date := (_cursor ->> 'purchaseDate')::date;
      _cursor_created := (_cursor ->> 'createdAt')::timestamptz;
      _cursor_observation := (_cursor ->> 'observationId')::uuid;
      IF _cursor_date IS NULL OR _cursor_created IS NULL OR _cursor_observation IS NULL THEN
        RAISE EXCEPTION 'incomplete';
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'Invalid observation cursor' USING ERRCODE = '22023';
    END;
  END IF;

  SELECT * INTO _state FROM public.price_product_state(_organization_id, ARRAY[_product.id], _today);

  WITH obs AS MATERIALIZED (
    SELECT o.*,
      row_number() OVER (PARTITION BY o.vendor_id
        ORDER BY o.purchase_date DESC, o.created_at DESC, o.observation_id DESC) AS vendor_position
    FROM public.price_observation_rows(_organization_id, ARRAY[_product.id]) o
    WHERE o.valid
  ),
  anchor AS (
    SELECT * FROM obs ORDER BY purchase_date DESC, created_at DESC, observation_id DESC LIMIT 1
  ),
  mapped AS (
    SELECT mapping.vendor_id, upper(btrim(mapping.vendor_sku)) AS sku_key, btrim(mapping.vendor_sku) AS sku
    FROM public.vendor_products mapping
    WHERE mapping.organization_id = _organization_id AND mapping.product_id = _product.id
      AND mapping.active AND NULLIF(btrim(mapping.vendor_sku), '') IS NOT NULL
      AND mapping.vendor_id IN (SELECT vendor_id FROM obs)
  ),
  skus AS (
    SELECT s.vendor_id, s.sku_key, max(s.sku) AS sku, bool_or(s.observed) AS observed, bool_or(s.mapped) AS mapped
    FROM (
      SELECT obs.vendor_id, obs.sku_key, obs.sku_display AS sku, true AS observed, false AS mapped FROM obs
      UNION ALL
      SELECT mapped.vendor_id, mapped.sku_key, mapped.sku, false, true FROM mapped
    ) s
    GROUP BY s.vendor_id, s.sku_key
  ),
  vendor_skus AS (
    SELECT skus.vendor_id, count(skus.sku_key) AS sku_count, bool_or(skus.sku_key IS NULL AND skus.observed) AS missing_sku
    FROM skus GROUP BY skus.vendor_id
  ),
  vendors AS (
    SELECT
      rep.vendor_id,
      rep.vendor_name,
      rep.observation_id,
      rep.price,
      rep.unit_key,
      rep.unit_valid,
      rep.package_raw,
      rep.catalog_vendor_product_id,
      rep.sku_key,
      rep.purchase_date,
      (SELECT count(*) FROM obs o WHERE o.vendor_id = rep.vendor_id)::integer AS purchase_count,
      (SELECT min(o.purchase_date) FROM obs o WHERE o.vendor_id = rep.vendor_id) AS first_purchase_date,
      vendor_skus.sku_count,
      vendor_skus.missing_sku,
      (SELECT jsonb_agg(jsonb_build_object('sku', skus.sku, 'observed', skus.observed, 'mapped', skus.mapped)
          ORDER BY skus.sku NULLS LAST)
       FROM skus WHERE skus.vendor_id = rep.vendor_id) AS sku_list,
      (SELECT jsonb_build_object('observationId', o.observation_id, 'price', o.price, 'purchaseDate', o.purchase_date,
          'dateBasis', o.date_basis, 'documentType', o.document_type, 'documentNumber', o.document_number,
          'invoiceId', o.invoice_id, 'lineNumber', o.line_number)
       FROM obs o
       WHERE o.vendor_id = rep.vendor_id AND o.vendor_position > 1 AND o.sku_key = rep.sku_key
         AND o.unit_key = rep.unit_key AND o.unit_valid AND rep.unit_valid AND vendor_skus.sku_count = 1
       ORDER BY o.purchase_date DESC, o.created_at DESC, o.observation_id DESC LIMIT 1) AS prior
    FROM obs rep
    JOIN vendor_skus ON vendor_skus.vendor_id = rep.vendor_id
    WHERE rep.vendor_position = 1
  ),
  compared AS (
    SELECT v.*,
      (SELECT a.vendor_id FROM anchor a) = v.vendor_id AS is_anchor,
      v.unit_valid AND a.unit_valid AND v.unit_key = a.unit_key AS same_unit,
      (v.unit_valid AND a.unit_valid AND v.unit_key = a.unit_key AND v.vendor_id <> a.vendor_id
        AND public.price_package_agreement(a.unit_key, a.package_raw, v.package_raw,
          a.catalog_vendor_product_id, v.catalog_vendor_product_id)) AS package_agrees,
      CASE
        WHEN NULLIF(lower(btrim(a.package_raw)), '') IS NOT NULL AND NULLIF(lower(btrim(v.package_raw)), '') IS NOT NULL
          THEN 'package_text'
        ELSE 'catalog'
      END AS package_basis,
      (GREATEST(_today - v.purchase_date, 0) <= 180 AND GREATEST(_today - a.purchase_date, 0) <= 180) AS both_recent
    FROM vendors v CROSS JOIN anchor a
  ),
  vendor_rows AS (
    SELECT compared.*,
      CASE
        WHEN compared.is_anchor THEN 'last_purchase'
        WHEN _state.state = 'insufficient_identity' OR compared.sku_count > 1 OR compared.missing_sku
          OR NOT compared.unit_valid THEN 'insufficient_identity'
        WHEN NOT compared.same_unit THEN 'incompatible_units'
        WHEN NOT compared.package_agrees THEN 'missing_package_details'
        WHEN NOT compared.both_recent THEN 'comparable_stale'
        ELSE 'comparable'
      END AS comparison_status
    FROM compared
  ),
  page AS (
    SELECT * FROM obs
    WHERE _cursor_date IS NULL
       OR (obs.purchase_date, obs.created_at, obs.observation_id) < (_cursor_date, _cursor_created, _cursor_observation)
    ORDER BY purchase_date DESC, created_at DESC, observation_id DESC
    LIMIT _limit + 1
  ),
  page_numbered AS (
    SELECT page.*, row_number() OVER (ORDER BY purchase_date DESC, created_at DESC, observation_id DESC) AS position
    FROM page
  )
  SELECT jsonb_build_object(
    'organizationId', _organization_id,
    'productId', _product.id,
    'productName', _product.name,
    'currencyCode', 'USD',
    'asOf', _today,
    'viewerIsOwner', _is_owner,
    'canOpenSourceDocument', _is_owner,
    'state', _state.state,
    'stale', _state.stale,
    'identityIssue', _state.identity_issue,
    'observationCount', COALESCE(_state.observation_count, 0),
    'vendorsObserved', COALESCE(_state.vendor_count, 0),
    'lastPurchase', _state.anchor,
    'priorSameSku', _state.prior,
    'changeAmount', _state.change_amount,
    'changePercent', _state.change_percent,
    'lowestComparable', _state.lowest,
    'comparableAlternative', _state.alternative,
    'differencePerUnit', _state.difference,
    'comparableVendorCount', COALESCE(_state.comparable_vendor_count, 0),
    'comparisonWithheld', _state.comparison_withheld,
    'signals', COALESCE(to_jsonb(_state.signals), '[]'::jsonb),
    'vendors', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'vendorId', r.vendor_id,
        'vendorName', r.vendor_name,
        'skus', r.sku_list,
        'lastPurchase', (SELECT jsonb_build_object(
            'observationId', o.observation_id, 'sku', o.sku_display, 'price', o.price,
            'unitOfMeasure', o.unit_raw, 'unitValid', o.unit_valid, 'packageSize', o.package_raw,
            'purchaseDate', o.purchase_date, 'dateBasis', o.date_basis,
            'ageDays', GREATEST(_today - o.purchase_date, 0),
            'recency', public.price_recency(o.purchase_date, _today),
            'documentType', o.document_type, 'documentNumber', o.document_number,
            'invoiceId', o.invoice_id, 'lineNumber', o.line_number)
          FROM obs o WHERE o.observation_id = r.observation_id),
        'priorSameSku', r.prior,
        'purchaseCount', r.purchase_count,
        'firstPurchaseDate', r.first_purchase_date,
        'lastPurchaseDate', r.purchase_date,
        'comparisonStatus', r.comparison_status,
        'checks', CASE WHEN r.is_anchor THEN NULL ELSE jsonb_build_object(
          'singleSku', r.sku_count = 1 AND NOT r.missing_sku,
          'sameUnit', r.same_unit,
          'packageAgreement', r.package_agrees,
          'packageBasis', CASE WHEN r.package_agrees THEN r.package_basis END,
          'bothRecent', r.both_recent,
          'usdBasis', true) END
      ) ORDER BY r.is_anchor DESC, r.purchase_date DESC, r.vendor_name, r.vendor_id)
      FROM (SELECT * FROM vendor_rows ORDER BY is_anchor DESC, purchase_date DESC, vendor_name, vendor_id LIMIT 25) r
    ), '[]'::jsonb),
    'vendorLimit', 25,
    'identity', CASE WHEN _state.state = 'insufficient_identity' THEN jsonb_build_object(
      'issue', _state.identity_issue,
      'skus', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('vendorId', skus.vendor_id,
            'vendorName', (SELECT max(o.vendor_name) FROM obs o WHERE o.vendor_id = skus.vendor_id),
            'sku', skus.sku, 'observed', skus.observed, 'mapped', skus.mapped)
          ORDER BY skus.vendor_id, skus.sku NULLS LAST)
        FROM skus
      ), '[]'::jsonb)) END,
    'observations', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'observationId', p.observation_id,
        'vendorId', p.vendor_id,
        'vendorName', p.vendor_name,
        'sku', p.sku_display,
        'documentType', p.document_type,
        'documentNumber', p.document_number,
        'dateBasis', p.date_basis,
        'purchaseDate', p.purchase_date,
        'ageDays', GREATEST(_today - p.purchase_date, 0),
        'recency', public.price_recency(p.purchase_date, _today),
        'quantity', p.quantity,
        'unitOfMeasure', p.unit_raw,
        'unitValid', p.unit_valid,
        'packageSize', p.package_raw,
        'price', p.price,
        'lineAmount', p.line_amount,
        'invoiceId', p.invoice_id,
        'invoiceItemId', p.invoice_item_id,
        'lineNumber', p.line_number
      ) ORDER BY p.position)
      FROM page_numbered p WHERE p.position <= _limit
    ), '[]'::jsonb),
    'nextCursor', (
      SELECT jsonb_build_object('purchaseDate', p.purchase_date, 'createdAt', p.created_at, 'observationId', p.observation_id)
      FROM page_numbered p
      WHERE p.position = _limit AND EXISTS (SELECT 1 FROM page_numbered q WHERE q.position = _limit + 1)
    ),
    'coverage', (
      SELECT jsonb_build_object(
        'postedObservationCount', count(*),
        'excludedNonUsdCount', count(*) FILTER (WHERE o.currency_basis = 'other'),
        'excludedMissingPriceCount', count(*) FILTER (WHERE o.currency_basis <> 'other' AND o.price IS NULL))
      FROM public.price_observation_rows(_organization_id, ARRAY[_product.id]) o
    )
  ) INTO _result;

  RETURN _result;
END;
$$;
REVOKE ALL ON FUNCTION public.get_product_vendor_price_history(uuid, uuid, uuid, jsonb, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_product_vendor_price_history(uuid, uuid, uuid, jsonb, integer) TO authenticated;
COMMENT ON FUNCTION public.get_product_vendor_price_history(uuid, uuid, uuid, jsonb, integer) IS
  'Phase 6B.1 product vendor history for owners and admins: state, observed vendors, SKU identities, comparison checks and keyset-paged source observations. Accepts a product or an inventory item.';

-- ---------------------------------------------------------------------------------------
-- Request review: read-only last-purchase context per request line.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.get_supply_request_price_context(_organization_id uuid, _request_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _today date := (now() AT TIME ZONE 'UTC')::date;
  _product_ids uuid[];
  _result jsonb;
BEGIN
  PERFORM public.financial_assert_access(_organization_id, false);
  IF _request_id IS NULL THEN
    RAISE EXCEPTION 'request_id is required' USING ERRCODE = '22004';
  END IF;
  PERFORM 1 FROM public.supply_requests request
  WHERE request.id = _request_id AND request.organization_id = _organization_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found' USING ERRCODE = 'P0002';
  END IF;

  WITH items AS MATERIALIZED (
    SELECT
      item.id AS item_id,
      item.created_at,
      COALESCE(item.product_id, direct_mapping.product_id, inventory.product_id, adopted.product_id) AS product_id,
      COALESCE(direct_mapping.vendor_id, adopted.vendor_id) AS sku_vendor_id,
      NULLIF(upper(btrim(COALESCE(direct_mapping.vendor_sku, adopted.vendor_sku))), '') AS sku_key
    FROM public.supply_request_items item
    LEFT JOIN public.vendor_products direct_mapping
      ON direct_mapping.id = item.vendor_product_id AND direct_mapping.organization_id = _organization_id
    LEFT JOIN public.inventory_items inventory
      ON inventory.id = item.inventory_item_id AND inventory.organization_id = _organization_id
    LEFT JOIN LATERAL (
      SELECT mapping.product_id, mapping.vendor_id, mapping.vendor_sku
      FROM public.vendor_products mapping
      WHERE item.catalog_vendor_product_id IS NOT NULL
        AND mapping.organization_id = _organization_id
        AND mapping.catalog_vendor_product_id = item.catalog_vendor_product_id
      ORDER BY mapping.created_at, mapping.id
      LIMIT 1
    ) adopted ON true
    WHERE item.supply_request_id = _request_id AND item.organization_id = _organization_id
  )
  SELECT array_agg(DISTINCT product_id) FILTER (WHERE product_id IS NOT NULL) INTO _product_ids FROM items;

  WITH items AS MATERIALIZED (
    SELECT
      item.id AS item_id,
      item.created_at,
      COALESCE(item.product_id, direct_mapping.product_id, inventory.product_id, adopted.product_id) AS product_id,
      COALESCE(direct_mapping.vendor_id, adopted.vendor_id) AS sku_vendor_id,
      NULLIF(upper(btrim(COALESCE(direct_mapping.vendor_sku, adopted.vendor_sku))), '') AS sku_key
    FROM public.supply_request_items item
    LEFT JOIN public.vendor_products direct_mapping
      ON direct_mapping.id = item.vendor_product_id AND direct_mapping.organization_id = _organization_id
    LEFT JOIN public.inventory_items inventory
      ON inventory.id = item.inventory_item_id AND inventory.organization_id = _organization_id
    LEFT JOIN LATERAL (
      SELECT mapping.product_id, mapping.vendor_id, mapping.vendor_sku
      FROM public.vendor_products mapping
      WHERE item.catalog_vendor_product_id IS NOT NULL
        AND mapping.organization_id = _organization_id
        AND mapping.catalog_vendor_product_id = item.catalog_vendor_product_id
      ORDER BY mapping.created_at, mapping.id
      LIMIT 1
    ) adopted ON true
    WHERE item.supply_request_id = _request_id AND item.organization_id = _organization_id
  ),
  states AS MATERIALIZED (
    SELECT * FROM public.price_product_state(_organization_id, _product_ids, _today)
  ),
  obs AS MATERIALIZED (
    SELECT * FROM public.price_observation_rows(_organization_id, _product_ids) WHERE valid
  ),
  resolved AS (
    SELECT items.*, states.state, states.anchor, states.signals, states.alternative,
      (SELECT jsonb_build_object(
          'observationId', o.observation_id, 'vendorId', o.vendor_id, 'vendorName', o.vendor_name,
          'sku', o.sku_display, 'price', o.price, 'unitOfMeasure', o.unit_raw, 'packageSize', o.package_raw,
          'purchaseDate', o.purchase_date, 'dateBasis', o.date_basis,
          'recency', public.price_recency(o.purchase_date, _today),
          'documentType', o.document_type, 'documentNumber', o.document_number)
       FROM obs o
       WHERE items.sku_key IS NOT NULL AND o.product_id = items.product_id
         AND o.vendor_id = items.sku_vendor_id AND o.sku_key = items.sku_key
       ORDER BY o.purchase_date DESC, o.created_at DESC, o.observation_id DESC LIMIT 1) AS sku_purchase
    FROM items
    LEFT JOIN states ON states.product_id = items.product_id
  )
  SELECT jsonb_build_object(
    'organizationId', _organization_id,
    'requestId', _request_id,
    'currencyCode', 'USD',
    'asOf', _today,
    'items', COALESCE(jsonb_agg(jsonb_build_object(
      'itemId', r.item_id,
      'productId', r.product_id,
      'status', CASE
        WHEN r.product_id IS NULL THEN 'unresolved'
        WHEN r.sku_purchase IS NOT NULL THEN 'last_purchase'
        WHEN r.state IS NULL THEN 'no_history'
        WHEN r.state = 'insufficient_identity' THEN 'several_skus'
        ELSE 'last_purchase'
      END,
      'lastPurchase', CASE
        WHEN r.product_id IS NULL THEN NULL
        WHEN r.sku_purchase IS NOT NULL THEN r.sku_purchase
        WHEN r.state IS NULL OR r.state = 'insufficient_identity' THEN NULL
        ELSE jsonb_build_object(
          'observationId', r.anchor -> 'observationId', 'vendorId', r.anchor -> 'vendorId',
          'vendorName', r.anchor -> 'vendorName', 'sku', r.anchor -> 'sku', 'price', r.anchor -> 'price',
          'unitOfMeasure', r.anchor -> 'unitOfMeasure', 'packageSize', r.anchor -> 'packageSize',
          'purchaseDate', r.anchor -> 'purchaseDate', 'dateBasis', r.anchor -> 'dateBasis',
          'recency', r.anchor -> 'recency', 'documentType', r.anchor -> 'documentType',
          'documentNumber', r.anchor -> 'documentNumber')
      END,
      'lowerComparable', CASE
        WHEN 'lower_comparable_price_other_vendor' = ANY (COALESCE(r.signals, ARRAY[]::text[]))
          AND (r.sku_purchase IS NULL OR r.sku_purchase -> 'observationId' = r.anchor -> 'observationId')
        THEN jsonb_build_object(
          'vendorId', r.alternative -> 'vendorId', 'vendorName', r.alternative -> 'vendorName',
          'sku', r.alternative -> 'sku', 'price', r.alternative -> 'price',
          'unitOfMeasure', r.alternative -> 'unitOfMeasure', 'packageSize', r.alternative -> 'packageSize',
          'purchaseDate', r.alternative -> 'purchaseDate', 'dateBasis', r.alternative -> 'dateBasis',
          'documentType', r.alternative -> 'documentType', 'documentNumber', r.alternative -> 'documentNumber')
      END
    ) ORDER BY r.created_at, r.item_id), '[]'::jsonb)
  ) INTO _result
  FROM resolved r;

  RETURN _result;
END;
$$;
REVOKE ALL ON FUNCTION public.get_supply_request_price_context(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_supply_request_price_context(uuid, uuid) TO authenticated;
COMMENT ON FUNCTION public.get_supply_request_price_context(uuid, uuid) IS
  'Phase 6B.1 read-only purchase history context for request review (owners and admins). Never assigns a vendor or changes the request.';

-- ---------------------------------------------------------------------------------------
-- Existing RPCs: same signatures and JSON keys, Phase 6B.1 rules.
-- ---------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_price_intelligence_overview(_organization_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _today date := (now() AT TIME ZONE 'UTC')::date;
  _product_count integer;
  _product_ids uuid[];
  _result jsonb;
BEGIN
  IF _organization_id IS NULL THEN
    RAISE EXCEPTION 'organization_id is required' USING ERRCODE = '22004';
  END IF;
  IF NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;

  SELECT count(*) INTO _product_count
  FROM public.products product
  WHERE product.organization_id = _organization_id
    AND EXISTS (
      SELECT 1 FROM public.inventory_price_history history
      JOIN public.invoices invoice
        ON invoice.id = history.invoice_id
       AND invoice.organization_id = history.organization_id
       AND invoice.posted_at IS NOT NULL
      WHERE history.organization_id = _organization_id
        AND history.product_id = product.id
        AND public.price_row_is_valid(history.unit_price, history.extended_price, history.quantity, invoice.currency_code));
  SELECT array_agg(recent.product_id) INTO _product_ids
  FROM public.price_recent_anchors(_organization_id, NULL, NULL, NULL, NULL, 500) recent;

  SELECT jsonb_build_object(
    'organizationId', _organization_id,
    'currencyCode', 'USD',
    'averageWindowDays', 90,
    'productLimit', 500,
    'productCount', _product_count,
    'rows', COALESCE(jsonb_agg(jsonb_build_object(
      'productId', state.product_id,
      'productName', product.name,
      'comparability', CASE WHEN (state.anchor ->> 'unitValid')::boolean
        THEN 'comparable' ELSE 'missing_unit_of_measure' END,
      'current', jsonb_build_object(
        'observationId', state.anchor -> 'observationId',
        'vendorId', state.anchor -> 'vendorId',
        'vendorName', state.anchor -> 'vendorName',
        'price', state.anchor -> 'price',
        'purchaseDate', state.anchor -> 'purchaseDate',
        'quantity', state.anchor -> 'quantity',
        'unitOfMeasure', state.anchor -> 'unitOfMeasure',
        'packageSize', state.anchor -> 'packageSize',
        'invoiceId', state.anchor -> 'invoiceId',
        'invoiceNumber', state.anchor -> 'invoiceNumber'
      ),
      'previous', CASE WHEN state.prior IS NOT NULL THEN jsonb_build_object(
          'price', state.prior -> 'price',
          'purchaseDate', state.prior -> 'purchaseDate',
          'invoiceId', state.prior -> 'invoiceId',
          'invoiceNumber', state.prior -> 'invoiceNumber'
        ) END,
      'absoluteChange', state.change_amount,
      'percentChange', state.change_percent,
      -- Phase 6B.1: the 90-day average and savings are no longer reported.
      'recentAverage', NULL,
      'bestAlternative', CASE WHEN state.alternative IS NOT NULL THEN jsonb_build_object(
          'vendorId', state.alternative -> 'vendorId',
          'vendorName', state.alternative -> 'vendorName',
          'price', state.alternative -> 'price',
          'purchaseDate', state.alternative -> 'purchaseDate',
          'invoiceId', state.alternative -> 'invoiceId',
          'invoiceNumber', state.alternative -> 'invoiceNumber',
          'unitOfMeasure', state.alternative -> 'unitOfMeasure',
          'packageSize', state.alternative -> 'packageSize',
          'comparableVendorCount', state.comparable_vendor_count - 1
        ) END,
      'unitSavings', NULL
    ) ORDER BY state.anchor ->> 'purchaseDate' DESC, state.anchor ->> 'observationId' DESC), '[]'::jsonb)
  ) INTO _result
  FROM public.price_product_state(_organization_id, _product_ids, _today) state
  JOIN public.products product
    ON product.id = state.product_id
   AND product.organization_id = _organization_id;

  RETURN _result;
END;
$$;
REVOKE ALL ON FUNCTION public.get_price_intelligence_overview(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_price_intelligence_overview(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_product_price_intelligence(
  _organization_id uuid,
  _product_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _today date := (now() AT TIME ZONE 'UTC')::date;
  _product public.products%ROWTYPE;
  _state record;
  _result jsonb;
BEGIN
  IF _organization_id IS NULL OR _product_id IS NULL THEN
    RAISE EXCEPTION 'organization_id and product_id are required' USING ERRCODE = '22004';
  END IF;

  IF NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO _product
  FROM public.products product
  WHERE product.id = _product_id
    AND product.organization_id = _organization_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found' USING ERRCODE = 'P0002';
  END IF;

  SELECT * INTO _state FROM public.price_product_state(_organization_id, ARRAY[_product_id], _today);

  WITH posted AS MATERIALIZED (
    SELECT * FROM public.price_observation_rows(_organization_id, ARRAY[_product_id])
  ),
  valid AS MATERIALIZED (
    SELECT posted.*,
      row_number() OVER (PARTITION BY vendor_id
        ORDER BY purchase_date DESC, created_at DESC, observation_id DESC) AS vendor_position
    FROM posted WHERE posted.valid
  ),
  -- Same-SKU history only: each figure is limited to the observation's own vendor, SKU and unit.
  anchor_group AS (
    SELECT v.price FROM valid v
    WHERE _state.anchor IS NOT NULL
      AND v.vendor_id = (_state.anchor ->> 'vendorId')::uuid
      AND v.sku_key IS NOT DISTINCT FROM (SELECT a.sku_key FROM valid a WHERE a.observation_id = (_state.anchor ->> 'observationId')::uuid)
      AND v.unit_key IS NOT DISTINCT FROM (SELECT a.unit_key FROM valid a WHERE a.observation_id = (_state.anchor ->> 'observationId')::uuid)
  ),
  vendor_rollup AS (
    SELECT rep.vendor_id, rep.vendor_name, rep.price AS latest_price, rep.purchase_date AS latest_price_date,
      (SELECT count(*) FROM valid o WHERE o.vendor_id = rep.vendor_id)::integer AS observation_count,
      (SELECT count(DISTINCT o.sku_key) FROM valid o WHERE o.vendor_id = rep.vendor_id) AS sku_count,
      (SELECT bool_or(o.sku_key IS NULL) FROM valid o WHERE o.vendor_id = rep.vendor_id) AS missing_sku,
      (SELECT min(o.price) FROM valid o WHERE o.vendor_id = rep.vendor_id
         AND o.sku_key IS NOT DISTINCT FROM rep.sku_key AND o.unit_key IS NOT DISTINCT FROM rep.unit_key) AS historical_low,
      (SELECT max(o.price) FROM valid o WHERE o.vendor_id = rep.vendor_id
         AND o.sku_key IS NOT DISTINCT FROM rep.sku_key AND o.unit_key IS NOT DISTINCT FROM rep.unit_key) AS historical_high,
      (SELECT o.price FROM valid o WHERE o.vendor_id = rep.vendor_id AND o.vendor_position > 1
         AND o.sku_key = rep.sku_key AND o.unit_key = rep.unit_key AND o.unit_valid AND rep.unit_valid
       ORDER BY o.purchase_date DESC, o.created_at DESC, o.observation_id DESC LIMIT 1) AS prior_price,
      (SELECT count(*) FROM public.vendor_products mapping
       WHERE mapping.organization_id = _organization_id AND mapping.product_id = _product_id
         AND mapping.vendor_id = rep.vendor_id AND mapping.active
         AND NULLIF(btrim(mapping.vendor_sku), '') IS NOT NULL
         AND upper(btrim(mapping.vendor_sku)) IS DISTINCT FROM rep.sku_key) AS other_mapped_skus
    FROM valid rep WHERE rep.vendor_position = 1
  ),
  coverage AS (
    SELECT
      count(*)::integer AS posted_observation_count,
      count(*) FILTER (WHERE currency_basis = 'other')::integer AS non_usd_count,
      count(*) FILTER (WHERE currency_basis <> 'other' AND price IS NULL)::integer AS missing_price_count
    FROM posted
  ),
  recent AS (
    SELECT COALESCE(jsonb_agg(
      jsonb_build_object(
        'observationId', observation.observation_id,
        'purchaseDate', observation.purchase_date,
        'vendorId', observation.vendor_id,
        'vendorName', observation.vendor_name,
        'vendorProductId', observation.vendor_product_id,
        'vendorSku', observation.mapping_sku,
        'purchasePrice', observation.price,
        'currencyCode', 'USD',
        'quantity', observation.quantity,
        'packageDescription', observation.package_raw,
        'unitOfMeasure', observation.unit_raw,
        'packageEvidenceStatus', 'unverified',
        'invoiceId', observation.invoice_id,
        'invoiceItemId', observation.invoice_item_id,
        'invoiceNumber', observation.invoice_number,
        'postedAt', observation.posted_at,
        'provenanceType', 'posted_invoice_purchase_history'
      ) ORDER BY observation.purchase_date DESC, observation.created_at DESC, observation.observation_id DESC
    ), '[]'::jsonb) AS value
    FROM (
      SELECT valid.*, mapping.vendor_sku AS mapping_sku, invoice.posted_at
      FROM valid
      JOIN public.invoices invoice ON invoice.id = valid.invoice_id
      LEFT JOIN public.vendor_products mapping
        ON mapping.id = valid.vendor_product_id AND mapping.product_id = _product_id
      ORDER BY valid.purchase_date DESC, valid.created_at DESC, valid.observation_id DESC
      LIMIT 20
    ) observation
  ),
  vendor_history AS (
    SELECT COALESCE(jsonb_agg(
      jsonb_build_object(
        'vendorId', vendor_row.vendor_id,
        'vendorName', vendor_row.vendor_name,
        'latestPrice', vendor_row.latest_price,
        'latestPriceDate', vendor_row.latest_price_date,
        'previousPrice', CASE WHEN vendor_row.sku_count = 1 AND NOT vendor_row.missing_sku
          AND vendor_row.other_mapped_skus = 0 THEN vendor_row.prior_price END,
        'historicalLow', COALESCE(vendor_row.historical_low, vendor_row.latest_price),
        'historicalHigh', COALESCE(vendor_row.historical_high, vendor_row.latest_price),
        'observationCount', vendor_row.observation_count
      ) ORDER BY vendor_row.latest_price_date DESC, vendor_row.vendor_id
    ), '[]'::jsonb) AS value
    FROM (
      SELECT * FROM vendor_rollup
      ORDER BY latest_price_date DESC, vendor_id
      LIMIT 12
    ) vendor_row
  )
  SELECT jsonb_build_object(
    'organizationId', _organization_id,
    'productId', _product_id,
    'productName', _product.name,
    'currencyCode', 'USD',
    'summary', jsonb_build_object(
      'latestPrice', (_state.anchor ->> 'price')::numeric,
      'latestPriceDate', _state.anchor ->> 'purchaseDate',
      'previousPrice', (_state.prior ->> 'price')::numeric,
      'absoluteChange', _state.change_amount,
      'percentChange', _state.change_percent,
      'historicalLow', (SELECT min(price) FROM anchor_group),
      'historicalHigh', (SELECT max(price) FROM anchor_group),
      'observationCount', (SELECT count(*) FROM valid)::integer
    ),
    'recentPurchases', recent.value,
    'vendorHistory', vendor_history.value,
    'packageComparability', jsonb_build_object(
      'status', 'not_verified',
      'normalizedUnitEconomicsAvailable', false,
      'reason', 'Historical purchases do not snapshot verified package quantity and unit metadata.'
    ),
    'coverage', jsonb_build_object(
      'postedObservationCount', coverage.posted_observation_count,
      'includedUsdObservationCount', (SELECT count(*) FROM valid)::integer,
      'excludedUnknownCurrencyCount', 0,
      'excludedNonUsdCount', coverage.non_usd_count,
      'excludedMissingPriceCount', coverage.missing_price_count
    ),
    'historyLimit', 20,
    'vendorLimit', 12
  ) INTO _result
  FROM coverage
  CROSS JOIN recent
  CROSS JOIN vendor_history;

  RETURN _result;
END;
$$;
REVOKE ALL ON FUNCTION public.get_product_price_intelligence(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_product_price_intelligence(uuid, uuid) TO authenticated;

COMMIT;
