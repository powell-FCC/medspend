-- Phase 6B.1 integration / benchmark fixture. Disposable local database only (loaded by
-- supabase/tests/run_phase6b1_price_integration.sh after every migration).
--
-- Club (6b1c...0101): owner 001, admin 002, staff 003. 5,000 products, 8 vendors, 50,000
--   posted documents x 5 lines = 250,000 price observations.
-- University (6b1c...0102): owner 004. 25,000 products, 12 vendors, 200,000 documents x 5 lines
--   = 1,000,000 observations.
-- Shape, per organization:
--   * every line is bought from the document's vendor; a product's primary vendor is
--     product mod vendors, and 30% of products are also bought from the next vendor
--     (multi-vendor);
--   * one SKU per product and vendor, except every 20th product, whose primary vendor sells it
--     under two SKUs (insufficient identity);
--   * unit bx / ea / ca by product, and 2% of products invoiced as "ea)" (malformed);
--   * half the products carry package text "12/box" on every line (comparable when two vendors
--     share the unit), the rest none (missing package details);
--   * documents spread over three years (two thirds older than 180 days), every 25th an order
--     confirmation with no invoice date; 1% in CAD (excluded).
-- Rows are written directly in the posting context, as post_reviewed_invoice writes them.

SET client_min_messages = warning;
SELECT set_config('sportspend.financial_context', 'post', false);

INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('6b1c0000-0000-4000-8000-00000000000' || n)::uuid, 'authenticated', 'authenticated',
  'phase6b1-itest-' || n || '@example.invalid', '', now(), '{}', '{}', now(), now()
FROM unnest(ARRAY[1, 2, 3, 4]) n;
INSERT INTO public.organizations (id, name, created_by) VALUES
  ('6b1c0000-0000-4000-8000-000000000101', 'Phase 6B.1 Club', '6b1c0000-0000-4000-8000-000000000001'),
  ('6b1c0000-0000-4000-8000-000000000102', 'Phase 6B.1 University', '6b1c0000-0000-4000-8000-000000000004');
INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES
  ('6b1c0000-0000-4000-8000-000000000101', '6b1c0000-0000-4000-8000-000000000001', 'owner', true),
  ('6b1c0000-0000-4000-8000-000000000101', '6b1c0000-0000-4000-8000-000000000002', 'admin', true),
  ('6b1c0000-0000-4000-8000-000000000101', '6b1c0000-0000-4000-8000-000000000003', 'staff', true),
  ('6b1c0000-0000-4000-8000-000000000102', '6b1c0000-0000-4000-8000-000000000004', 'owner', true);

DO $fixture$
DECLARE
  _org uuid;
  _o integer;
  _products integer;
  _vendors integer;
  _documents integer;
BEGIN
  FOR _o, _products, _vendors, _documents IN
    SELECT * FROM (VALUES (1, 5000, 8, 50000), (2, 25000, 12, 200000)) s
  LOOP
    _org := ('6b1c0000-0000-4000-8000-00000000010' || _o)::uuid;

    INSERT INTO public.vendors (id, organization_id, name, active)
    SELECT md5('v' || _o || ':' || v)::uuid, _org, 'Vendor ' || _o || '-' || lpad(v::text, 2, '0'), true
    FROM generate_series(0, _vendors - 1) v;

    INSERT INTO public.products (id, organization_id, name, approved, active, staff_requestable)
    SELECT md5('p' || _o || ':' || p)::uuid, _org, 'Product ' || _o || '-' || lpad(p::text, 5, '0'), true, true, true
    FROM generate_series(0, _products - 1) p;

    INSERT INTO public.invoices (id, organization_id, vendor_id, vendor_name, document_type, invoice_number, order_number,
      invoice_date, posted_at, processing_status, currency_code, invoice_total, total_amount, total)
    SELECT md5('i' || _o || ':' || n)::uuid, _org, md5('v' || _o || ':' || (n % _vendors))::uuid, 'Vendor',
      CASE WHEN n % 25 = 0 THEN 'ORDER_CONFIRMATION' ELSE 'INVOICE' END,
      CASE WHEN n % 25 = 0 THEN NULL ELSE 'INV-' || _o || '-' || n END,
      CASE WHEN n % 25 = 0 THEN 'SO-' || _o || '-' || n END,
      CASE WHEN n % 25 = 0 THEN NULL ELSE (now() AT TIME ZONE 'UTC')::date - (n * 7919 % 1095) END,
      ((now() AT TIME ZONE 'UTC')::date - (n * 7919 % 1095))::timestamp AT TIME ZONE 'UTC' + interval '12 hours',
      'completed', CASE WHEN n % 100 = 7 THEN 'CAD' END, 100, 100, 100
    FROM generate_series(1, _documents) n;

    -- Lines: line j of document n is product k*V + v (bought from its primary vendor v), or, for
    -- three in ten lines, product k*V + (v - 1) when that product is multi-vendor.
    CREATE TEMP TABLE fixture_lines ON COMMIT DROP AS
    SELECT n, j, v, md5('l' || _o || ':' || n || ':' || j)::uuid AS line_id,
      CASE WHEN (n + j) % 10 < 3 AND (((n * 31 + j * 17) % (_products / _vendors)) * _vendors + (v + _vendors - 1) % _vendors) % 10 < 3
        THEN ((n * 31 + j * 17) % (_products / _vendors)) * _vendors + (v + _vendors - 1) % _vendors
        ELSE ((n * 31 + j * 17) % (_products / _vendors)) * _vendors + v
      END AS p
    FROM (SELECT n, n % _vendors AS v FROM generate_series(1, _documents) n) d
    CROSS JOIN generate_series(1, 5) j;

    INSERT INTO public.vendor_products (organization_id, vendor_id, product_id, vendor_sku, active)
    SELECT DISTINCT _org, md5('v' || _o || ':' || l.v)::uuid, md5('p' || _o || ':' || l.p)::uuid,
      'S' || _o || '-' || l.p || '-' || l.v || CASE WHEN l.p % 20 = 0 AND l.p % _vendors = l.v AND l.n % 2 = 0 THEN 'b' ELSE '' END,
      true
    FROM fixture_lines l;

    INSERT INTO public.invoice_items (id, invoice_id, organization_id, line_number, description, sku, quantity,
      unit_of_measure, package_size, unit_price, total_price, product_id, review_status)
    SELECT l.line_id, md5('i' || _o || ':' || l.n)::uuid, _org, l.j, 'Line',
      'S' || _o || '-' || l.p || '-' || l.v || CASE WHEN l.p % 20 = 0 AND l.p % _vendors = l.v AND l.n % 2 = 0 THEN 'b' ELSE '' END,
      1 + l.j,
      CASE WHEN l.p % 50 = 1 THEN 'ea)' WHEN l.p % 3 = 0 THEN 'bx' WHEN l.p % 3 = 1 THEN 'ea' ELSE 'ca' END,
      CASE WHEN l.p % 2 = 0 THEN '12/box' END,
      5 + (l.p % 40) + (l.n % 7) * 0.25 + l.v * 0.1, (5 + (l.p % 40)) * (1 + l.j),
      md5('p' || _o || ':' || l.p)::uuid, 'approved'
    FROM fixture_lines l;

    INSERT INTO public.inventory_price_history (organization_id, product_id, vendor_id, vendor_product_id, invoice_id,
      invoice_item_id, purchase_date, quantity, package_size, unit_of_measure, unit_price, extended_price, created_at)
    SELECT _org, item.product_id, invoice.vendor_id, mapping.id, invoice.id, item.id,
      COALESCE(invoice.invoice_date, (invoice.posted_at AT TIME ZONE 'UTC')::date), item.quantity,
      item.package_size, item.unit_of_measure, item.unit_price, item.total_price,
      invoice.posted_at + make_interval(secs => item.line_number)
    FROM public.invoice_items item
    JOIN public.invoices invoice ON invoice.id = item.invoice_id
    JOIN public.vendor_products mapping
      ON mapping.organization_id = _org AND mapping.vendor_id = invoice.vendor_id
     AND mapping.product_id = item.product_id AND mapping.vendor_sku = item.sku
    WHERE item.organization_id = _org;

    DROP TABLE fixture_lines;
  END LOOP;
END
$fixture$;

-- One request per organization with ten product lines, for the request-review context.
INSERT INTO public.supply_requests (id, organization_id, requested_by, request_type, quantity, status)
SELECT ('6b1c0000-0000-4000-8000-00000000070' || o)::uuid, ('6b1c0000-0000-4000-8000-00000000010' || o)::uuid,
  CASE o WHEN 1 THEN '6b1c0000-0000-4000-8000-000000000003'::uuid ELSE '6b1c0000-0000-4000-8000-000000000004'::uuid END,
  'reorder', 1, 'submitted'
FROM generate_series(1, 2) o;
INSERT INTO public.supply_request_items (organization_id, supply_request_id, quantity, product_id)
SELECT ('6b1c0000-0000-4000-8000-00000000010' || o)::uuid, ('6b1c0000-0000-4000-8000-00000000070' || o)::uuid, 1,
  md5('p' || o || ':' || p)::uuid
FROM generate_series(1, 2) o CROSS JOIN generate_series(0, 9) p;

SELECT set_config('sportspend.financial_context', '', false);
ANALYZE public.invoices;
ANALYZE public.invoice_items;
ANALYZE public.inventory_price_history;
ANALYZE public.vendor_products;
ANALYZE public.products;
