-- Phase 6B: conservative, auditable product price intelligence.
-- Historical metrics use only posted USD invoice observations already recorded in
-- inventory_price_history. Catalog/reference prices are deliberately excluded.

BEGIN;

-- The existing product/date index finds the product slice. These final columns make
-- the tie-break order used by the RPC explicit and deterministic without a second scan.
CREATE INDEX inventory_price_history_product_observation_order_idx
  ON public.inventory_price_history (
    organization_id, product_id, purchase_date DESC, created_at DESC, id DESC
  );

CREATE FUNCTION public.get_product_price_intelligence(
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
  _product public.products%ROWTYPE;
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

  WITH posted AS MATERIALIZED (
    SELECT
      history.id,
      history.organization_id,
      history.product_id,
      history.vendor_id,
      history.vendor_product_id,
      history.invoice_id,
      history.invoice_item_id,
      history.purchase_date,
      history.quantity,
      history.package_size,
      history.unit_of_measure,
      COALESCE(
        history.unit_price,
        history.extended_price / NULLIF(history.quantity, 0)
      )::numeric AS purchase_price,
      history.extended_price,
      history.created_at,
      invoice.invoice_number,
      invoice.currency_code,
      invoice.posted_at,
      vendor.name AS vendor_name,
      vendor_product.vendor_sku
    FROM public.inventory_price_history history
    JOIN public.invoices invoice
      ON invoice.id = history.invoice_id
     AND invoice.organization_id = history.organization_id
     AND invoice.posted_at IS NOT NULL
    JOIN public.vendors vendor
      ON vendor.id = history.vendor_id
     AND vendor.organization_id = history.organization_id
    LEFT JOIN public.vendor_products vendor_product
      ON vendor_product.id = history.vendor_product_id
     AND vendor_product.organization_id = history.organization_id
     AND vendor_product.product_id = history.product_id
    WHERE history.organization_id = _organization_id
      AND history.product_id = _product_id
  ),
  valid AS MATERIALIZED (
    SELECT
      posted.*,
      row_number() OVER (
        ORDER BY purchase_date DESC, created_at DESC, id DESC
      ) AS product_position,
      row_number() OVER (
        PARTITION BY vendor_id
        ORDER BY purchase_date DESC, created_at DESC, id DESC
      ) AS vendor_position
    FROM posted
    WHERE currency_code = 'USD'
      AND purchase_price IS NOT NULL
      AND purchase_price >= 0
  ),
  summary AS (
    SELECT
      count(*)::integer AS observation_count,
      min(purchase_price) AS historical_low,
      max(purchase_price) AS historical_high,
      max(purchase_price) FILTER (WHERE product_position = 1) AS latest_price,
      max(purchase_date) FILTER (WHERE product_position = 1) AS latest_price_date,
      max(purchase_price) FILTER (WHERE product_position = 2) AS previous_price
    FROM valid
  ),
  coverage AS (
    SELECT
      count(*)::integer AS posted_observation_count,
      count(*) FILTER (WHERE currency_code IS NULL)::integer AS unknown_currency_count,
      count(*) FILTER (WHERE currency_code IS NOT NULL AND currency_code <> 'USD')::integer
        AS non_usd_count,
      count(*) FILTER (WHERE currency_code = 'USD' AND purchase_price IS NULL)::integer
        AS missing_price_count
    FROM posted
  ),
  recent AS (
    SELECT COALESCE(jsonb_agg(
      jsonb_build_object(
        'observationId', observation.id,
        'purchaseDate', observation.purchase_date,
        'vendorId', observation.vendor_id,
        'vendorName', observation.vendor_name,
        'vendorProductId', observation.vendor_product_id,
        'vendorSku', observation.vendor_sku,
        'purchasePrice', observation.purchase_price,
        'currencyCode', 'USD',
        'quantity', observation.quantity,
        'packageDescription', observation.package_size,
        'unitOfMeasure', observation.unit_of_measure,
        'packageEvidenceStatus', 'unverified',
        'invoiceId', observation.invoice_id,
        'invoiceItemId', observation.invoice_item_id,
        'invoiceNumber', observation.invoice_number,
        'postedAt', observation.posted_at,
        'provenanceType', 'posted_invoice_purchase_history'
      ) ORDER BY observation.purchase_date DESC, observation.created_at DESC, observation.id DESC
    ), '[]'::jsonb) AS value
    FROM (
      SELECT * FROM valid
      ORDER BY purchase_date DESC, created_at DESC, id DESC
      LIMIT 20
    ) observation
  ),
  vendor_rollup AS (
    SELECT
      vendor_id,
      max(vendor_name) AS vendor_name,
      count(*)::integer AS observation_count,
      max(purchase_price) FILTER (WHERE vendor_position = 1) AS latest_price,
      max(purchase_date) FILTER (WHERE vendor_position = 1) AS latest_price_date,
      max(purchase_price) FILTER (WHERE vendor_position = 2) AS previous_price,
      min(purchase_price) AS historical_low,
      max(purchase_price) AS historical_high
    FROM valid
    GROUP BY vendor_id
  ),
  vendor_history AS (
    SELECT COALESCE(jsonb_agg(
      jsonb_build_object(
        'vendorId', vendor_row.vendor_id,
        'vendorName', vendor_row.vendor_name,
        'latestPrice', vendor_row.latest_price,
        'latestPriceDate', vendor_row.latest_price_date,
        'previousPrice', vendor_row.previous_price,
        'historicalLow', vendor_row.historical_low,
        'historicalHigh', vendor_row.historical_high,
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
      'latestPrice', summary.latest_price,
      'latestPriceDate', summary.latest_price_date,
      'previousPrice', summary.previous_price,
      'absoluteChange', CASE
        WHEN summary.latest_price IS NULL OR summary.previous_price IS NULL THEN NULL
        ELSE summary.latest_price - summary.previous_price
      END,
      'percentChange', CASE
        WHEN summary.latest_price IS NULL OR summary.previous_price IS NULL
          OR summary.previous_price = 0 THEN NULL
        ELSE ((summary.latest_price - summary.previous_price) / summary.previous_price) * 100
      END,
      'historicalLow', summary.historical_low,
      'historicalHigh', summary.historical_high,
      'observationCount', summary.observation_count
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
      'includedUsdObservationCount', summary.observation_count,
      'excludedUnknownCurrencyCount', coverage.unknown_currency_count,
      'excludedNonUsdCount', coverage.non_usd_count,
      'excludedMissingPriceCount', coverage.missing_price_count
    ),
    'historyLimit', 20,
    'vendorLimit', 12
  ) INTO _result
  FROM summary
  CROSS JOIN coverage
  CROSS JOIN recent
  CROSS JOIN vendor_history;

  RETURN _result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_product_price_intelligence(uuid, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_product_price_intelligence(uuid, uuid)
  TO authenticated;

COMMENT ON FUNCTION public.get_product_price_intelligence(uuid, uuid) IS
  'Admin-only, bounded USD price intelligence for one exact organization product. Uses posted inventory price history only; does not infer package comparability or vendor savings.';

COMMIT;
