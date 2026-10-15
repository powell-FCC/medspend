-- Budget & Purchasing command center: read-only, organization-scoped aggregation.
--
-- Nothing here writes data or adds tables. Financial totals reuse get_budget_summary
-- (Phase 6A.1/6A.2) per budget, so spent/committed/available keep exactly one definition.
-- Price comparisons read the same posted USD inventory_price_history observations as
-- Phase 6B and add only conservative same-unit comparability rules (documented below).
-- Every function requires owner/admin membership of the requested organization;
-- invoice-level detail stays owner-only, matching the existing invoice screens.

BEGIN;

CREATE FUNCTION public.get_budget_purchasing_overview(_organization_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _is_owner boolean;
  _result jsonb;
BEGIN
  IF _organization_id IS NULL THEN
    RAISE EXCEPTION 'organization_id is required' USING ERRCODE = '22004';
  END IF;
  IF NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;
  _is_owner := COALESCE(
    public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]),
    false
  );

  WITH budget_rows AS (
    SELECT summary.*
    FROM public.organization_budgets budget
    CROSS JOIN LATERAL public.get_budget_summary(_organization_id, budget.id) summary
    WHERE budget.organization_id = _organization_id
      AND budget.active = true
  ),
  active_commitments AS (
    SELECT commitment.amount, commitment.pricing_status, request.status AS request_status
    FROM public.supply_request_commitments commitment
    JOIN public.supply_requests request
      ON request.id = commitment.supply_request_id
     AND request.organization_id = commitment.organization_id
    WHERE commitment.organization_id = _organization_id
      AND commitment.status = 'active'
  ),
  recent_invoices AS (
    -- Same posted-invoice total resolution and spend date as get_budget_summary.
    SELECT
      invoice.id,
      invoice.source_file_id,
      invoice.vendor_name,
      invoice.invoice_number,
      COALESCE(invoice.invoice_date, invoice.posted_at::date) AS spend_date,
      COALESCE(
        invoice.invoice_total,
        invoice.total_amount,
        invoice.total,
        (SELECT SUM(item.total_price) FROM public.invoice_items item
          WHERE item.invoice_id = invoice.id AND item.organization_id = invoice.organization_id),
        0
      )::numeric AS amount
    FROM public.invoices invoice
    WHERE _is_owner
      AND invoice.organization_id = _organization_id
      AND invoice.posted_at IS NOT NULL
    ORDER BY COALESCE(invoice.invoice_date, invoice.posted_at::date) DESC,
      invoice.posted_at DESC, invoice.id DESC
    LIMIT 8
  )
  SELECT jsonb_build_object(
    'organizationId', _organization_id,
    'viewerIsOwner', _is_owner,
    'budgets', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'budgetId', budget_row.budget_id,
        'budgetName', budget_row.budget_name,
        'periodStart', budget_row.period_start,
        'periodEnd', budget_row.period_end,
        'budgetAmount', budget_row.budget_amount,
        'actualSpend', budget_row.actual_spend,
        'committedSpend', budget_row.committed_spend,
        'availableAmount', budget_row.available_amount,
        'postedInvoiceCount', budget_row.posted_invoice_count,
        'activeCommitmentCount', budget_row.active_commitment_count,
        'incompleteCommitmentCount', budget_row.incomplete_commitment_count
      ) ORDER BY budget_row.period_start DESC, budget_row.period_end DESC, budget_row.budget_id)
      FROM budget_rows budget_row
    ), '[]'::jsonb),
    'attention', jsonb_build_object(
      'awaitingApprovalCount', (
        SELECT count(*) FROM public.supply_requests request
        WHERE request.organization_id = _organization_id
          AND request.status IN ('submitted', 'under_review')
      ),
      -- Received/completed requests intentionally keep their commitment until an admin
      -- releases it. Once the purchase is invoiced those dollars are counted twice
      -- until released, so they are surfaced rather than silently netted.
      'commitmentsToSettleCount', (
        SELECT count(*) FROM active_commitments
        WHERE request_status IN ('received', 'completed')
      ),
      'commitmentsToSettleAmount', (
        SELECT COALESCE(SUM(amount), 0) FROM active_commitments
        WHERE request_status IN ('received', 'completed')
      ),
      'unpricedCommitmentCount', (
        SELECT count(*) FROM active_commitments WHERE pricing_status <> 'fully_priced'
      ),
      'invoiceReviewCount', CASE WHEN _is_owner THEN (
        SELECT count(*) FROM public.invoice_processing_jobs job
        WHERE job.organization_id = _organization_id
          AND job.status = 'review_required'
      ) END
    ),
    'recentPurchases', CASE WHEN _is_owner THEN COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'invoiceId', recent.id,
        'sourceFileId', recent.source_file_id,
        'vendorName', recent.vendor_name,
        'invoiceNumber', recent.invoice_number,
        'spendDate', recent.spend_date,
        'amount', recent.amount
      ) ORDER BY recent.spend_date DESC, recent.id DESC)
      FROM recent_invoices recent
    ), '[]'::jsonb) END
  ) INTO _result;

  RETURN _result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_budget_purchasing_overview(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_budget_purchasing_overview(uuid) TO authenticated;

COMMENT ON FUNCTION public.get_budget_purchasing_overview(uuid) IS
  'Admin-only, read-only command-center overview. Budget rows come from get_budget_summary; invoice-level detail is returned to owners only.';

-- Traceability for one budget period: the active commitments and posted invoices that
-- make up its committed and spent totals, using the same period rules as
-- get_budget_summary. Lists are bounded; totals are over the full period.
CREATE FUNCTION public.get_budget_lineage(_organization_id uuid, _budget_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _budget public.organization_budgets%ROWTYPE;
  _is_owner boolean;
  _result jsonb;
BEGIN
  IF _organization_id IS NULL OR _budget_id IS NULL THEN
    RAISE EXCEPTION 'organization_id and budget_id are required' USING ERRCODE = '22004';
  END IF;
  IF NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO _budget FROM public.organization_budgets budget
  WHERE budget.id = _budget_id AND budget.organization_id = _organization_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Budget not found' USING ERRCODE = 'P0002';
  END IF;
  _is_owner := COALESCE(
    public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]),
    false
  );

  WITH commitments AS (
    SELECT commitment.*, request.status AS request_status
    FROM public.supply_request_commitments commitment
    JOIN public.supply_requests request
      ON request.id = commitment.supply_request_id
     AND request.organization_id = commitment.organization_id
    WHERE commitment.organization_id = _organization_id
      AND commitment.status = 'active'
      AND commitment.committed_at::date BETWEEN _budget.period_start AND _budget.period_end
  ),
  listed_commitments AS (
    SELECT * FROM commitments
    ORDER BY committed_at DESC, id DESC
    LIMIT 50
  ),
  posted AS (
    SELECT
      invoice.id,
      invoice.source_file_id,
      invoice.vendor_name,
      invoice.invoice_number,
      COALESCE(invoice.invoice_date, invoice.posted_at::date) AS spend_date,
      COALESCE(
        invoice.invoice_total,
        invoice.total_amount,
        invoice.total,
        (SELECT SUM(item.total_price) FROM public.invoice_items item
          WHERE item.invoice_id = invoice.id AND item.organization_id = invoice.organization_id),
        0
      )::numeric AS amount
    FROM public.invoices invoice
    WHERE _is_owner
      AND invoice.organization_id = _organization_id
      AND invoice.posted_at IS NOT NULL
      AND COALESCE(invoice.invoice_date, invoice.posted_at::date)
        BETWEEN _budget.period_start AND _budget.period_end
  ),
  listed_posted AS (
    SELECT * FROM posted ORDER BY spend_date DESC, id DESC LIMIT 50
  )
  SELECT jsonb_build_object(
    'budgetId', _budget.id,
    'commitmentCount', (SELECT count(*) FROM commitments),
    'commitmentTotal', (SELECT COALESCE(SUM(amount), 0) FROM commitments),
    'commitments', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'requestId', listed.supply_request_id,
        'requestStatus', listed.request_status,
        'committedAt', listed.committed_at,
        'amount', listed.amount,
        'pricingStatus', listed.pricing_status,
        'itemCount', listed.total_item_count,
        'itemLabel', (
          SELECT COALESCE(product.name, NULLIF(btrim(item.free_text_item), ''), 'Catalog item')
          FROM public.supply_request_items item
          LEFT JOIN public.products product
            ON product.id = item.product_id AND product.organization_id = item.organization_id
          WHERE item.supply_request_id = listed.supply_request_id
            AND item.organization_id = listed.organization_id
          ORDER BY item.created_at, item.id
          LIMIT 1
        )
      ) ORDER BY listed.committed_at DESC, listed.id DESC)
      FROM listed_commitments listed
    ), '[]'::jsonb),
    'postedInvoiceCount', CASE WHEN _is_owner THEN (SELECT count(*) FROM posted) END,
    'postedTotal', CASE WHEN _is_owner THEN (SELECT COALESCE(SUM(amount), 0) FROM posted) END,
    'postedInvoices', CASE WHEN _is_owner THEN COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'invoiceId', listed.id,
        'sourceFileId', listed.source_file_id,
        'vendorName', listed.vendor_name,
        'invoiceNumber', listed.invoice_number,
        'spendDate', listed.spend_date,
        'amount', listed.amount
      ) ORDER BY listed.spend_date DESC, listed.id DESC)
      FROM listed_posted listed
    ), '[]'::jsonb) END,
    'listLimit', 50
  ) INTO _result;

  RETURN _result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_budget_lineage(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_budget_lineage(uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.get_budget_lineage(uuid, uuid) IS
  'Admin-only, read-only budget traceability: active commitments (and, for owners, posted invoices) inside one budget period, using get_budget_summary period rules.';

-- Organization-wide price comparison table.
--
-- Observations: posted, USD, priced rows of inventory_price_history for this
-- organization only (exactly the Phase 6B "valid" set; catalog/list prices excluded).
-- Current: each product's most recent observation (purchase_date, created_at, id).
-- Comparable unit: normalized unit_of_measure (required) plus normalized package_size
-- (NULL matches NULL only for the same vendor).
-- Previous / 90-day average: same product, same vendor, same comparable unit.
-- Alternative: another vendor's latest observation of the same product with the same
-- unit of measure AND the same recorded package size (both required).
CREATE FUNCTION public.get_price_intelligence_overview(_organization_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _result jsonb;
BEGIN
  IF _organization_id IS NULL THEN
    RAISE EXCEPTION 'organization_id is required' USING ERRCODE = '22004';
  END IF;
  IF NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;

  WITH valid AS MATERIALIZED (
    SELECT
      history.id,
      history.product_id,
      history.vendor_id,
      history.invoice_id,
      history.purchase_date,
      history.created_at,
      history.quantity,
      history.unit_of_measure,
      history.package_size,
      NULLIF(lower(regexp_replace(btrim(history.unit_of_measure), '\s+', ' ', 'g')), '')
        AS uom_key,
      NULLIF(lower(regexp_replace(btrim(history.package_size), '\s+', ' ', 'g')), '')
        AS package_key,
      COALESCE(
        history.unit_price,
        history.extended_price / NULLIF(history.quantity, 0)
      )::numeric AS price,
      invoice.invoice_number,
      vendor.name AS vendor_name
    FROM public.inventory_price_history history
    JOIN public.invoices invoice
      ON invoice.id = history.invoice_id
     AND invoice.organization_id = history.organization_id
     AND invoice.posted_at IS NOT NULL
    JOIN public.vendors vendor
      ON vendor.id = history.vendor_id
     AND vendor.organization_id = history.organization_id
    WHERE history.organization_id = _organization_id
      AND invoice.currency_code = 'USD'
      AND COALESCE(history.unit_price, history.extended_price / NULLIF(history.quantity, 0))
        IS NOT NULL
  ),
  sequenced AS MATERIALIZED (
    SELECT
      valid.*,
      row_number() OVER (
        PARTITION BY product_id
        ORDER BY purchase_date DESC, created_at DESC, id DESC
      ) AS product_position,
      row_number() OVER (
        PARTITION BY product_id, vendor_id, uom_key, package_key
        ORDER BY purchase_date DESC, created_at DESC, id DESC
      ) AS unit_position,
      lag(price) OVER unit_history AS previous_price,
      lag(purchase_date) OVER unit_history AS previous_date,
      lag(invoice_id) OVER unit_history AS previous_invoice_id,
      lag(invoice_number) OVER unit_history AS previous_invoice_number,
      avg(price) OVER unit_window AS window_average,
      count(*) OVER unit_window AS window_count
    FROM valid
    WINDOW
      unit_history AS (
        PARTITION BY product_id, vendor_id, uom_key, package_key
        ORDER BY purchase_date, created_at, id
      ),
      unit_window AS (
        PARTITION BY product_id, vendor_id, uom_key, package_key
        ORDER BY purchase_date
        RANGE BETWEEN interval '89 days' PRECEDING AND CURRENT ROW
      )
  ),
  current_rows AS (
    SELECT * FROM sequenced WHERE product_position = 1
  ),
  bounded AS (
    SELECT * FROM current_rows
    ORDER BY purchase_date DESC, created_at DESC, id DESC
    LIMIT 500
  ),
  alternatives AS (
    SELECT DISTINCT ON (current_row.product_id)
      current_row.product_id,
      other.vendor_id,
      other.vendor_name,
      other.price,
      other.purchase_date,
      other.invoice_id,
      other.invoice_number,
      other.unit_of_measure,
      other.package_size,
      count(*) OVER (PARTITION BY current_row.product_id) AS comparable_vendor_count
    FROM bounded current_row
    JOIN sequenced other
      ON other.product_id = current_row.product_id
     AND other.vendor_id <> current_row.vendor_id
     AND other.unit_position = 1
     -- "=" never matches NULL, so an unrecorded unit or package has no alternative.
     AND other.uom_key = current_row.uom_key
     AND other.package_key = current_row.package_key
    ORDER BY current_row.product_id, other.price, other.purchase_date DESC, other.vendor_id
  )
  SELECT jsonb_build_object(
    'organizationId', _organization_id,
    'currencyCode', 'USD',
    'averageWindowDays', 90,
    'productLimit', 500,
    'productCount', (SELECT count(*) FROM current_rows),
    'rows', COALESCE(jsonb_agg(jsonb_build_object(
      'productId', cur.product_id,
      'productName', product.name,
      'comparability', CASE WHEN cur.uom_key IS NULL THEN 'missing_unit_of_measure' ELSE 'comparable' END,
      'current', jsonb_build_object(
        'observationId', cur.id,
        'vendorId', cur.vendor_id,
        'vendorName', cur.vendor_name,
        'price', cur.price,
        'purchaseDate', cur.purchase_date,
        'quantity', cur.quantity,
        'unitOfMeasure', cur.unit_of_measure,
        'packageSize', cur.package_size,
        'invoiceId', cur.invoice_id,
        'invoiceNumber', cur.invoice_number
      ),
      'previous', CASE WHEN cur.uom_key IS NOT NULL AND cur.previous_price IS NOT NULL THEN
        jsonb_build_object(
          'price', cur.previous_price,
          'purchaseDate', cur.previous_date,
          'invoiceId', cur.previous_invoice_id,
          'invoiceNumber', cur.previous_invoice_number
        ) END,
      'absoluteChange', CASE WHEN cur.uom_key IS NOT NULL AND cur.previous_price IS NOT NULL
        THEN cur.price - cur.previous_price END,
      'percentChange', CASE WHEN cur.uom_key IS NOT NULL AND cur.previous_price > 0
        THEN ((cur.price - cur.previous_price) / cur.previous_price) * 100 END,
      'recentAverage', CASE WHEN cur.uom_key IS NOT NULL THEN jsonb_build_object(
          'average', cur.window_average,
          'observationCount', cur.window_count,
          'windowStart', cur.purchase_date - 89,
          'windowEnd', cur.purchase_date
        ) END,
      'bestAlternative', CASE WHEN alternative.product_id IS NOT NULL THEN jsonb_build_object(
          'vendorId', alternative.vendor_id,
          'vendorName', alternative.vendor_name,
          'price', alternative.price,
          'purchaseDate', alternative.purchase_date,
          'invoiceId', alternative.invoice_id,
          'invoiceNumber', alternative.invoice_number,
          'unitOfMeasure', alternative.unit_of_measure,
          'packageSize', alternative.package_size,
          'comparableVendorCount', alternative.comparable_vendor_count
        ) END,
      'unitSavings', CASE WHEN alternative.price < cur.price
        THEN cur.price - alternative.price END
    ) ORDER BY cur.purchase_date DESC, cur.created_at DESC, cur.id DESC), '[]'::jsonb)
  ) INTO _result
  FROM bounded cur
  JOIN public.products product
    ON product.id = cur.product_id
   AND product.organization_id = _organization_id
  LEFT JOIN alternatives alternative ON alternative.product_id = cur.product_id;

  RETURN _result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_price_intelligence_overview(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_price_intelligence_overview(uuid) TO authenticated;

COMMENT ON FUNCTION public.get_price_intelligence_overview(uuid) IS
  'Admin-only, read-only, organization-private price comparison over posted USD purchase observations. Compares only same-product, same-unit observations; never uses catalog/list prices.';

COMMIT;
