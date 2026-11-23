-- Phase 6B.1 rollback-only behavioral verification: price observations, same-SKU change, SKU
-- identity, unit and package rules, cross-vendor comparison, state precedence, recency, order
-- confirmations, currency, the list/summary/detail/request-context RPCs, the old RPCs' keys and
-- fixed logic, access and read-only behaviour. Run against a disposable database after every
-- migration through 20261123120000_phase6b1_multi_vendor_intelligence.sql. Everything is rolled
-- back. Dates are relative to the transaction's UTC day so boundaries are exact.

BEGIN;

DO $phase6b1_fixture_guard$
BEGIN
  IF EXISTS (SELECT 1 FROM auth.users
             WHERE id BETWEEN '6b100000-0000-4000-8000-000000000001'::uuid AND '6b100000-0000-4000-8000-000000000099'::uuid)
     OR EXISTS (SELECT 1 FROM public.organizations
             WHERE id BETWEEN '6b100000-0000-4000-8000-000000000101'::uuid AND '6b100000-0000-4000-8000-000000000199'::uuid) THEN
    RAISE EXCEPTION 'Phase 6B.1 rollback-test fixture IDs already exist';
  END IF;
END
$phase6b1_fixture_guard$;

CREATE FUNCTION pg_temp.expect_error(_statement text, _expected text, _sqlstate text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE _statement;
  EXCEPTION WHEN OTHERS THEN
    IF position(_expected IN SQLERRM) = 0 OR (_sqlstate IS NOT NULL AND SQLSTATE <> _sqlstate) THEN
      RAISE EXCEPTION 'Expected error containing "%" (%), got "%" (%)', _expected, _sqlstate, SQLERRM, SQLSTATE;
    END IF;
    RETURN;
  END;
  RAISE EXCEPTION 'Statement unexpectedly succeeded; expected "%": %', _expected, _statement;
END;
$$;
CREATE FUNCTION pg_temp.as_user(_user_id uuid)
RETURNS void LANGUAGE sql AS $$ SELECT pg_catalog.set_config('request.jwt.claim.sub', coalesce(_user_id::text, ''), true) $$;
CREATE FUNCTION pg_temp.assert(_condition boolean, _message text)
RETURNS void LANGUAGE plpgsql AS $$ BEGIN IF _condition IS NOT TRUE THEN RAISE EXCEPTION 'Check failed: %', _message; END IF; END; $$;
CREATE FUNCTION pg_temp.eq(_actual anyelement, _expected anyelement, _message text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF _actual IS DISTINCT FROM _expected THEN
    RAISE EXCEPTION 'Check failed: % (expected %, got %)', _message, _expected, _actual;
  END IF;
END;
$$;
CREATE TEMP TABLE phase6b1_values (name text PRIMARY KEY, value jsonb) ON COMMIT DROP;
GRANT ALL ON phase6b1_values TO authenticated, anon, service_role;
CREATE FUNCTION pg_temp.keep(_name text, _value jsonb)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO phase6b1_values VALUES (_name, _value) ON CONFLICT (name) DO UPDATE SET value = EXCLUDED.value $$;
CREATE FUNCTION pg_temp.val(_name text)
RETURNS jsonb LANGUAGE sql AS $$ SELECT value FROM phase6b1_values WHERE name = _name $$;
CREATE FUNCTION pg_temp.today()
RETURNS date LANGUAGE sql STABLE AS $$ SELECT (now() AT TIME ZONE 'UTC')::date $$;
CREATE FUNCTION pg_temp.state()
RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT jsonb_build_object(
    'invoices', (SELECT md5(coalesce(string_agg(to_jsonb(i)::text, ',' ORDER BY id), '')) FROM public.invoices i),
    'items', (SELECT md5(coalesce(string_agg(to_jsonb(i)::text, ',' ORDER BY id), '')) FROM public.invoice_items i),
    'history', (SELECT md5(coalesce(string_agg(to_jsonb(h)::text, ',' ORDER BY id), '')) FROM public.inventory_price_history h),
    'products', (SELECT md5(coalesce(string_agg(to_jsonb(p)::text, ',' ORDER BY id), '')) FROM public.products p),
    'vendors', (SELECT md5(coalesce(string_agg(to_jsonb(v)::text, ',' ORDER BY id), '')) FROM public.vendors v),
    'mappings', (SELECT md5(coalesce(string_agg(to_jsonb(m)::text, ',' ORDER BY id), '')) FROM public.vendor_products m),
    'requests', (SELECT md5(coalesce(string_agg(to_jsonb(r)::text, ',' ORDER BY id), '')) FROM public.supply_requests r),
    'request_items', (SELECT md5(coalesce(string_agg(to_jsonb(r)::text, ',' ORDER BY id), '')) FROM public.supply_request_items r),
    'commitments', (SELECT md5(coalesce(string_agg(to_jsonb(c)::text, ',' ORDER BY id), '')) FROM public.supply_request_commitments c),
    'inventory', (SELECT md5(coalesce(string_agg(to_jsonb(i)::text, ',' ORDER BY id), '')) FROM public.inventory_items i),
    'rules', (SELECT count(*) FROM public.inventory_replenishment_rules))
$$;

-- ---------------------------------------------------------------------------------------
-- Fixtures. Organization A: owner 001, admin 002, staff 003, removed admin 005.
-- Organization B: owner 004. 007 belongs to nothing.
-- ---------------------------------------------------------------------------------------
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('6b100000-0000-4000-8000-00000000000' || n)::uuid, 'authenticated', 'authenticated',
  'phase6b1-' || n || '@example.invalid', '', now(), '{}', '{}', now(), now()
FROM unnest(ARRAY[1, 2, 3, 4, 5, 7]) n;

INSERT INTO public.organizations (id, name, created_by) VALUES
  ('6b100000-0000-4000-8000-000000000101', 'Phase 6B.1 Organization', '6b100000-0000-4000-8000-000000000001'),
  ('6b100000-0000-4000-8000-000000000102', 'Phase 6B.1 Other Organization', '6b100000-0000-4000-8000-000000000004');
INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES
  ('6b100000-0000-4000-8000-000000000101', '6b100000-0000-4000-8000-000000000001', 'owner', true),
  ('6b100000-0000-4000-8000-000000000101', '6b100000-0000-4000-8000-000000000002', 'admin', true),
  ('6b100000-0000-4000-8000-000000000101', '6b100000-0000-4000-8000-000000000003', 'staff', true),
  ('6b100000-0000-4000-8000-000000000101', '6b100000-0000-4000-8000-000000000005', 'admin', false),
  ('6b100000-0000-4000-8000-000000000102', '6b100000-0000-4000-8000-000000000004', 'owner', true);

INSERT INTO public.catalog_vendors (id, name, normalized_name) VALUES
  ('6b100000-0000-4000-8000-000000000251', 'P6B1 Catalog Vendor One', 'p6b1 catalog vendor one'),
  ('6b100000-0000-4000-8000-000000000252', 'P6B1 Catalog Vendor Two', 'p6b1 catalog vendor two');
INSERT INTO public.vendors (id, organization_id, name, active, catalog_vendor_id) VALUES
  ('6b100000-0000-4000-8000-000000000301', '6b100000-0000-4000-8000-000000000101', 'P6B1 Henry Schein', true, '6b100000-0000-4000-8000-000000000251'),
  ('6b100000-0000-4000-8000-000000000302', '6b100000-0000-4000-8000-000000000101', 'P6B1 Vendor Two', true, '6b100000-0000-4000-8000-000000000252'),
  ('6b100000-0000-4000-8000-000000000303', '6b100000-0000-4000-8000-000000000101', 'P6B1 Vendor Three', true, NULL),
  ('6b100000-0000-4000-8000-000000000304', '6b100000-0000-4000-8000-000000000102', 'P6B1 Other Vendor', true, NULL);

-- Products are looked up by name.
INSERT INTO public.products (organization_id, name, approved, active, staff_requestable)
SELECT '6b100000-0000-4000-8000-000000000101', 'P6B1 ' || name, true, true, true
FROM unnest(ARRAY[
  'Ammex Glove', 'Eco-Flex Tape', 'Leukotape', 'Mediproxen', 'Protex', 'Tape 950', 'No SKU', 'No Unit',
  'Clean Rising', 'Clean Stale Anchor', 'One Purchase', 'Never Purchased',
  'MV Lower', 'MV Equal', 'MV Higher', 'MV Three', 'MV Incompatible Third', 'MV All Incompatible',
  'MV Stale Alternative', 'MV Stale Anchor', 'MV Package Null', 'MV Package One', 'MV Package Mismatch',
  'MV Catalog', 'MV Catalog Disagree', 'MV Catalog Source Only', 'MV Catalog Quantity', 'MV Malformed',
  'MV Ambiguous', 'MV Non USD', 'MV Age 180', 'MV Age 181', 'Increase Age 180', 'Increase Age 181',
  'Age 90', 'Age 91', 'Age 180', 'Age 181', 'MV Order Confirmation', 'Ambiguous Repeat']) name;
INSERT INTO public.products (organization_id, name, approved, active, staff_requestable)
VALUES ('6b100000-0000-4000-8000-000000000102', 'P6B1 Other Org Tape', true, true, true);

CREATE FUNCTION pg_temp.pid(_name text)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT id FROM public.products WHERE name = 'P6B1 ' || _name $$;
CREATE FUNCTION pg_temp.vendor(_n integer)
RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('6b100000-0000-4000-8000-00000000030' || _n)::uuid $$;

-- A vendor SKU mapping, optionally linked to a catalog listing.
CREATE FUNCTION pg_temp.map(_product text, _vendor integer, _sku text, _catalog_listing uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE _id uuid;
BEGIN
  INSERT INTO public.vendor_products (organization_id, vendor_id, product_id, vendor_sku, catalog_vendor_product_id)
  VALUES (CASE WHEN _product = 'Other Org Tape' THEN '6b100000-0000-4000-8000-000000000102'::uuid
               ELSE '6b100000-0000-4000-8000-000000000101'::uuid END,
          pg_temp.vendor(_vendor), pg_temp.pid(_product), _sku, _catalog_listing)
  RETURNING id INTO _id;
  RETURN _id;
END;
$$;

-- One posted observation: a document with one line and its price history row. _order sets
-- created_at so same-day observations have a known order (higher = newer).
CREATE FUNCTION pg_temp.obs(
  _product text, _vendor integer, _sku text, _unit text, _package text, _price numeric,
  _quantity numeric, _age integer, _order integer DEFAULT 0, _document_type text DEFAULT 'INVOICE',
  _no_invoice_date boolean DEFAULT false, _currency text DEFAULT NULL, _map boolean DEFAULT true,
  _number text DEFAULT NULL, _also_invoice_number text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
  _org uuid := CASE WHEN _product = 'Other Org Tape' THEN '6b100000-0000-4000-8000-000000000102'::uuid
                    ELSE '6b100000-0000-4000-8000-000000000101'::uuid END;
  _invoice uuid := gen_random_uuid();
  _item uuid := gen_random_uuid();
  _history uuid := gen_random_uuid();
  _mapping uuid;
  _day date := pg_temp.today() - _age;
BEGIN
  IF _map AND _sku IS NOT NULL THEN
    SELECT id INTO _mapping FROM public.vendor_products
    WHERE organization_id = _org AND vendor_id = pg_temp.vendor(_vendor) AND upper(btrim(vendor_sku)) = upper(btrim(_sku));
    IF _mapping IS NULL THEN _mapping := pg_temp.map(_product, _vendor, _sku); END IF;
  END IF;
  PERFORM set_config('sportspend.financial_context', 'post', true);
  INSERT INTO public.invoices (id, organization_id, vendor_id, vendor_name, document_type, invoice_number, order_number,
    invoice_date, posted_at, processing_status, currency_code, invoice_total, total_amount, total)
  VALUES (_invoice, _org, pg_temp.vendor(_vendor), 'Extracted vendor', _document_type,
    CASE WHEN _document_type = 'ORDER_CONFIRMATION' THEN _also_invoice_number ELSE COALESCE(_number, 'INV-' || left(_invoice::text, 8)) END,
    CASE WHEN _document_type = 'ORDER_CONFIRMATION' THEN COALESCE(_number, 'OC-' || left(_invoice::text, 8)) END,
    CASE WHEN _no_invoice_date THEN NULL ELSE _day END, (_day::timestamp + interval '12 hours') AT TIME ZONE 'UTC',
    'completed', _currency, _price * _quantity, _price * _quantity, _price * _quantity);
  INSERT INTO public.invoice_items (id, invoice_id, organization_id, line_number, description, sku, quantity,
    unit_of_measure, package_size, unit_price, total_price, product_id, vendor_product_id, review_status)
  VALUES (_item, _invoice, _org, 1, _product, _sku, _quantity, _unit, _package, _price, _price * _quantity,
    pg_temp.pid(_product), _mapping, 'approved');
  INSERT INTO public.inventory_price_history (id, organization_id, product_id, vendor_id, vendor_product_id,
    invoice_id, invoice_item_id, purchase_date, quantity, package_size, unit_of_measure, unit_price, extended_price, created_at)
  VALUES (_history, _org, pg_temp.pid(_product), pg_temp.vendor(_vendor), _mapping, _invoice, _item, _day, _quantity,
    _package, _unit, _price, _price * _quantity, now() + make_interval(secs => _order));
  PERFORM set_config('sportspend.financial_context', '', true);
  RETURN _history;
END;
$$;

-- Catalog listings for the package-agreement fixtures.
INSERT INTO public.catalog_products (id, name, normalized_name) VALUES
  ('6b100000-0000-4000-8000-000000000261', 'P6B1 Catalog Gauze', 'p6b1 catalog gauze'),
  ('6b100000-0000-4000-8000-000000000262', 'P6B1 Catalog Wrap', 'p6b1 catalog wrap'),
  ('6b100000-0000-4000-8000-000000000263', 'P6B1 Catalog Spray', 'p6b1 catalog spray'),
  ('6b100000-0000-4000-8000-000000000264', 'P6B1 Catalog Pads', 'p6b1 catalog pads');
UPDATE public.products SET catalog_product_id = '6b100000-0000-4000-8000-000000000261' WHERE id = pg_temp.pid('MV Catalog');
UPDATE public.products SET catalog_product_id = '6b100000-0000-4000-8000-000000000262' WHERE id = pg_temp.pid('MV Catalog Disagree');
UPDATE public.products SET catalog_product_id = '6b100000-0000-4000-8000-000000000263' WHERE id = pg_temp.pid('MV Catalog Source Only');
UPDATE public.products SET catalog_product_id = '6b100000-0000-4000-8000-000000000264' WHERE id = pg_temp.pid('MV Catalog Quantity');
INSERT INTO public.catalog_vendor_products (id, catalog_product_id, catalog_vendor_id, vendor_sku, normalized_vendor_sku,
  package_description, package_quantity, package_unit, package_status) VALUES
  ('6b100000-0000-4000-8000-000000000271', '6b100000-0000-4000-8000-000000000261', '6b100000-0000-4000-8000-000000000251', 'CAT-G1', 'CAT-G1', '12/box', 12, 'item', 'verified'),
  ('6b100000-0000-4000-8000-000000000272', '6b100000-0000-4000-8000-000000000261', '6b100000-0000-4000-8000-000000000252', 'CAT-G2', 'CAT-G2', '12/Box', 12, 'item', 'verified'),
  ('6b100000-0000-4000-8000-000000000273', '6b100000-0000-4000-8000-000000000262', '6b100000-0000-4000-8000-000000000251', 'CAT-W1', 'CAT-W1', '200/box', 200, 'item', 'verified'),
  ('6b100000-0000-4000-8000-000000000274', '6b100000-0000-4000-8000-000000000262', '6b100000-0000-4000-8000-000000000252', 'CAT-W2', 'CAT-W2', '200/box', 200, 'item', 'verified'),
  ('6b100000-0000-4000-8000-000000000275', '6b100000-0000-4000-8000-000000000263', '6b100000-0000-4000-8000-000000000251', 'CAT-S1', 'CAT-S1', '1/each', 1, 'item', 'verified'),
  ('6b100000-0000-4000-8000-000000000276', '6b100000-0000-4000-8000-000000000263', '6b100000-0000-4000-8000-000000000252', 'CAT-S2', 'CAT-S2', 'ea', 1, 'item', 'source_only'),
  ('6b100000-0000-4000-8000-000000000277', '6b100000-0000-4000-8000-000000000264', '6b100000-0000-4000-8000-000000000251', 'CAT-P1', 'CAT-P1', '12/box', 12, 'item', 'verified'),
  ('6b100000-0000-4000-8000-000000000278', '6b100000-0000-4000-8000-000000000264', '6b100000-0000-4000-8000-000000000252', 'CAT-P2', 'CAT-P2', '10/box', 10, 'item', 'verified');
SELECT pg_temp.map('MV Catalog', 1, 'CAT-G1', '6b100000-0000-4000-8000-000000000271');
SELECT pg_temp.map('MV Catalog', 2, 'CAT-G2', '6b100000-0000-4000-8000-000000000272');
SELECT pg_temp.map('MV Catalog Disagree', 1, 'CAT-W1', '6b100000-0000-4000-8000-000000000273');
SELECT pg_temp.map('MV Catalog Disagree', 2, 'CAT-W2', '6b100000-0000-4000-8000-000000000274');
SELECT pg_temp.map('MV Catalog Source Only', 1, 'CAT-S1', '6b100000-0000-4000-8000-000000000275');
SELECT pg_temp.map('MV Catalog Source Only', 2, 'CAT-S2', '6b100000-0000-4000-8000-000000000276');
SELECT pg_temp.map('MV Catalog Quantity', 1, 'CAT-P1', '6b100000-0000-4000-8000-000000000277');
SELECT pg_temp.map('MV Catalog Quantity', 2, 'CAT-P2', '6b100000-0000-4000-8000-000000000278');

-- FC Cincinnati production shapes (all vendor 1, no currency recorded).
SELECT pg_temp.obs('Ammex Glove', 1, '398-0144', 'BX', NULL, 6.08, 3, 10, 1);
SELECT pg_temp.obs('Ammex Glove', 1, '398-0145', 'BX', NULL, 6.23, 3, 10, 2);
SELECT pg_temp.obs('Eco-Flex Tape', 1, '134-4998', 'CA', NULL, 39.62, 2, 14, 1);
SELECT pg_temp.obs('Eco-Flex Tape', 1, '735-0022', 'CA', NULL, 35.44, 2, 14, 2);
SELECT pg_temp.obs('Eco-Flex Tape', 1, '135-0459', 'CA', NULL, 39.64, 2, 10, 1);
SELECT pg_temp.obs('Leukotape', 1, '911-3665', 'RL', NULL, 7.29, 5, 200);
SELECT pg_temp.obs('Leukotape', 1, '911-3665', 'RL', NULL, 7.29, 8, 100);
SELECT pg_temp.obs('Mediproxen', 1, '151-9200', 'BX', NULL, 16.85, 3, 150);
SELECT pg_temp.obs('Mediproxen', 1, '151-9200', 'Bx', NULL, 16.85, 2, 40, 0, 'ORDER_CONFIRMATION', true);
SELECT pg_temp.obs('Protex', 1, '124-6100', 'EA', NULL, 13.49, 2, 300);
SELECT pg_temp.obs('Protex', 1, '124-6100', 'EA)', NULL, 167.88, 1, 130);
SELECT pg_temp.map('Tape 950', 1, '134-8646');
SELECT pg_temp.map('Tape 950', 1, '134-8647');
SELECT pg_temp.obs('Tape 950', 1, '134-8646', 'BX', NULL, 63.23, 1, 20);
SELECT pg_temp.obs('No SKU', 1, NULL, 'BX', NULL, 5, 1, 20);
SELECT pg_temp.obs('No SKU', 1, NULL, 'BX', NULL, 6, 1, 10);
SELECT pg_temp.obs('No Unit', 1, 'NU-1', NULL, NULL, 5, 1, 20);
SELECT pg_temp.obs('No Unit', 1, 'NU-1', NULL, NULL, 6, 1, 10);
SELECT pg_temp.obs('Clean Rising', 1, 'CR-1', 'ea', NULL, 10, 1, 50);
SELECT pg_temp.obs('Clean Rising', 1, 'CR-1', 'ea', NULL, 11, 1, 30);
SELECT pg_temp.obs('Clean Rising', 1, 'CR-1', ' EA ', NULL, 12, 1, 20);
SELECT pg_temp.obs('Clean Stale Anchor', 1, 'CS-1', 'ea', NULL, 10, 1, 400);
SELECT pg_temp.obs('Clean Stale Anchor', 1, 'CS-1', 'ea', NULL, 12, 1, 200);
SELECT pg_temp.obs('One Purchase', 1, 'OP-1', 'ea', NULL, 4, 1, 5);

-- Synthetic multi-vendor fixtures. The anchor (last purchase) is always the vendor-1 row.
SELECT pg_temp.obs('MV Lower', 2, 'L-2', 'bx', '12/box', 9, 1, 30);
SELECT pg_temp.obs('MV Lower', 1, 'L-1', 'BX', '12/Box', 10, 1, 20);
SELECT pg_temp.obs('MV Equal', 2, 'E-2', 'bx', '12/box', 10, 1, 30);
SELECT pg_temp.obs('MV Equal', 1, 'E-1', 'bx', '12/box', 10, 1, 20);
SELECT pg_temp.obs('MV Higher', 2, 'H-2', 'bx', '12/box', 11, 1, 30);
SELECT pg_temp.obs('MV Higher', 1, 'H-1', 'bx', '12/box', 10, 1, 20);
SELECT pg_temp.obs('MV Three', 2, 'T-2', 'bx', '12/box', 9.5, 1, 30);
SELECT pg_temp.obs('MV Three', 3, 'T-3', 'bx', '12/box', 9, 1, 40);
SELECT pg_temp.obs('MV Three', 1, 'T-1', 'bx', '12/box', 10, 1, 20);
SELECT pg_temp.obs('MV Incompatible Third', 2, 'I-2', 'bx', '12/box', 9, 1, 30);
SELECT pg_temp.obs('MV Incompatible Third', 3, 'I-3', 'ca', '12/box', 8, 1, 30);
SELECT pg_temp.obs('MV Incompatible Third', 1, 'I-1', 'bx', '12/box', 10, 1, 20);
SELECT pg_temp.obs('MV All Incompatible', 2, 'A-2', 'ca', '12/box', 9, 1, 30);
SELECT pg_temp.obs('MV All Incompatible', 1, 'A-1', 'bx', '12/box', 10, 1, 20);
SELECT pg_temp.obs('MV Stale Alternative', 2, 'SA-2', 'bx', '12/box', 9, 1, 200);
SELECT pg_temp.obs('MV Stale Alternative', 1, 'SA-1', 'bx', '12/box', 10, 1, 20);
SELECT pg_temp.obs('MV Stale Anchor', 2, 'SN-2', 'bx', '12/box', 9, 1, 250);
SELECT pg_temp.obs('MV Stale Anchor', 1, 'SN-1', 'bx', '12/box', 10, 1, 200);
SELECT pg_temp.obs('MV Package Null', 2, 'PN-2', 'bx', NULL, 9, 1, 30);
SELECT pg_temp.obs('MV Package Null', 1, 'PN-1', 'bx', NULL, 10, 1, 20);
SELECT pg_temp.obs('MV Package One', 2, 'PO-2', 'bx', NULL, 9, 1, 30);
SELECT pg_temp.obs('MV Package One', 1, 'PO-1', 'bx', '12/box', 10, 1, 20);
SELECT pg_temp.obs('MV Package Mismatch', 2, 'PM-2', 'bx', '10/box', 9, 1, 30);
SELECT pg_temp.obs('MV Package Mismatch', 1, 'PM-1', 'bx', '12/box', 10, 1, 20);
SELECT pg_temp.obs('MV Catalog', 2, 'CAT-G2', 'BX', NULL, 9, 1, 30);
SELECT pg_temp.obs('MV Catalog', 1, 'CAT-G1', 'bx', NULL, 10, 1, 20);
SELECT pg_temp.obs('MV Catalog Disagree', 2, 'CAT-W2', 'bt', NULL, 9, 1, 30);
SELECT pg_temp.obs('MV Catalog Disagree', 1, 'CAT-W1', 'bt', NULL, 10, 1, 20);
SELECT pg_temp.obs('MV Catalog Source Only', 2, 'CAT-S2', 'ea', NULL, 9, 1, 30);
SELECT pg_temp.obs('MV Catalog Source Only', 1, 'CAT-S1', 'ea', NULL, 10, 1, 20);
SELECT pg_temp.obs('MV Catalog Quantity', 2, 'CAT-P2', 'bx', NULL, 9, 1, 30);
SELECT pg_temp.obs('MV Catalog Quantity', 1, 'CAT-P1', 'bx', NULL, 10, 1, 20);
SELECT pg_temp.obs('MV Malformed', 2, 'M-2', 'bx)', '12/box', 9, 1, 30);
SELECT pg_temp.obs('MV Malformed', 1, 'M-1', 'bx', '12/box', 10, 1, 20);
SELECT pg_temp.obs('MV Ambiguous', 2, 'AM-2a', 'bx', '12/box', 9, 1, 30);
SELECT pg_temp.obs('MV Ambiguous', 2, 'AM-2b', 'bx', '12/box', 9.1, 1, 25);
SELECT pg_temp.obs('MV Ambiguous', 1, 'AM-1', 'bx', '12/box', 10, 1, 20);
SELECT pg_temp.obs('MV Non USD', 2, 'N-2', 'bx', '12/box', 5, 1, 30, 0, 'INVOICE', false, 'CAD');
SELECT pg_temp.obs('MV Non USD', 1, 'N-1', 'bx', '12/box', 10, 1, 20, 0, 'INVOICE', false, 'USD');
SELECT pg_temp.obs('MV Age 180', 2, 'G-2', 'bx', '12/box', 9, 1, 180);
SELECT pg_temp.obs('MV Age 180', 1, 'G-1', 'bx', '12/box', 10, 1, 10);
SELECT pg_temp.obs('MV Age 181', 2, 'K-2', 'bx', '12/box', 9, 1, 181);
SELECT pg_temp.obs('MV Age 181', 1, 'K-1', 'bx', '12/box', 10, 1, 10);
SELECT pg_temp.obs('Increase Age 180', 1, 'IA-1', 'ea', NULL, 10, 1, 300);
SELECT pg_temp.obs('Increase Age 180', 1, 'IA-1', 'ea', NULL, 11, 1, 180);
SELECT pg_temp.obs('Increase Age 181', 1, 'IB-1', 'ea', NULL, 10, 1, 300);
SELECT pg_temp.obs('Increase Age 181', 1, 'IB-1', 'ea', NULL, 11, 1, 181);
SELECT pg_temp.obs('Age 90', 1, 'AG-90', 'ea', NULL, 1, 1, 90);
SELECT pg_temp.obs('Age 91', 1, 'AG-91', 'ea', NULL, 1, 1, 91);
SELECT pg_temp.obs('Age 180', 1, 'AG-180', 'ea', NULL, 1, 1, 180);
SELECT pg_temp.obs('Age 181', 1, 'AG-181', 'ea', NULL, 1, 1, 181);
SELECT pg_temp.obs('MV Order Confirmation', 2, 'OC-2', 'bx', '12/box', 9, 1, 30, 0, 'ORDER_CONFIRMATION', true, NULL, true, 'SO-77', 'INV-ON-OC');
SELECT pg_temp.obs('MV Order Confirmation', 1, 'OC-1', 'bx', '12/box', 10, 1, 20);
-- Ambiguous product whose last-purchase SKU was bought twice: still no product-level change.
SELECT pg_temp.obs('Ambiguous Repeat', 1, 'AR-B', 'ea', NULL, 5, 1, 60);
SELECT pg_temp.obs('Ambiguous Repeat', 1, 'AR-A', 'ea', NULL, 10, 1, 40);
SELECT pg_temp.obs('Ambiguous Repeat', 1, 'AR-A', 'ea', NULL, 12, 1, 20);
-- Organization B: never visible to A.
SELECT pg_temp.obs('Other Org Tape', 4, 'OT-1', 'bx', '12/box', 1, 1, 5);

-- An inventory item for the replenishment link, and a product-less one.
INSERT INTO public.inventory_items (id, organization_id, product_id, name, unit, quantity) VALUES
  ('6b100000-0000-4000-8000-000000000601', '6b100000-0000-4000-8000-000000000101', pg_temp.pid('Clean Rising'), 'Clean Rising', 'ea', 0),
  ('6b100000-0000-4000-8000-000000000602', '6b100000-0000-4000-8000-000000000101', NULL, 'Loose item', 'ea', 0),
  ('6b100000-0000-4000-8000-000000000603', '6b100000-0000-4000-8000-000000000102', pg_temp.pid('Other Org Tape'), 'Other', 'ea', 0);

-- A request with every resolution path.
INSERT INTO public.supply_requests (id, organization_id, requested_by, request_type, quantity, status) VALUES
  ('6b100000-0000-4000-8000-000000000701', '6b100000-0000-4000-8000-000000000101', '6b100000-0000-4000-8000-000000000003', 'reorder', 1, 'submitted');
INSERT INTO public.supply_request_items (id, organization_id, supply_request_id, quantity, product_id, vendor_product_id,
  inventory_item_id, catalog_vendor_product_id, free_text_item, created_at) VALUES
  ('6b100000-0000-4000-8000-000000000711', '6b100000-0000-4000-8000-000000000101', '6b100000-0000-4000-8000-000000000701', 1,
    pg_temp.pid('MV Lower'), NULL, NULL, NULL, NULL, now()),
  ('6b100000-0000-4000-8000-000000000712', '6b100000-0000-4000-8000-000000000101', '6b100000-0000-4000-8000-000000000701', 1,
    NULL, (SELECT id FROM public.vendor_products WHERE vendor_sku = '398-0144'), NULL, NULL, NULL, now() + interval '1 second'),
  ('6b100000-0000-4000-8000-000000000713', '6b100000-0000-4000-8000-000000000101', '6b100000-0000-4000-8000-000000000701', 1,
    pg_temp.pid('Ammex Glove'), NULL, NULL, NULL, NULL, now() + interval '2 seconds'),
  ('6b100000-0000-4000-8000-000000000714', '6b100000-0000-4000-8000-000000000101', '6b100000-0000-4000-8000-000000000701', 1,
    NULL, NULL, NULL, NULL, 'Something new', now() + interval '3 seconds'),
  ('6b100000-0000-4000-8000-000000000715', '6b100000-0000-4000-8000-000000000101', '6b100000-0000-4000-8000-000000000701', 1,
    NULL, NULL, '6b100000-0000-4000-8000-000000000601', NULL, NULL, now() + interval '4 seconds'),
  ('6b100000-0000-4000-8000-000000000716', '6b100000-0000-4000-8000-000000000101', '6b100000-0000-4000-8000-000000000701', 1,
    pg_temp.pid('Never Purchased'), NULL, NULL, NULL, NULL, now() + interval '5 seconds'),
  ('6b100000-0000-4000-8000-000000000717', '6b100000-0000-4000-8000-000000000101', '6b100000-0000-4000-8000-000000000701', 1,
    NULL, NULL, NULL, '6b100000-0000-4000-8000-000000000271', NULL, now() + interval '6 seconds'),
  ('6b100000-0000-4000-8000-000000000718', '6b100000-0000-4000-8000-000000000101', '6b100000-0000-4000-8000-000000000701', 1,
    NULL, (SELECT id FROM public.vendor_products WHERE vendor_sku = 'L-2'), NULL, NULL, NULL, now() + interval '7 seconds');
INSERT INTO public.supply_requests (id, organization_id, requested_by, request_type, quantity, status) VALUES
  ('6b100000-0000-4000-8000-000000000702', '6b100000-0000-4000-8000-000000000102', '6b100000-0000-4000-8000-000000000004', 'reorder', 1, 'submitted');

SELECT pg_temp.keep('before', pg_temp.state());

-- ---------------------------------------------------------------------------------------
-- Internal helpers: exact semantics.
-- ---------------------------------------------------------------------------------------
SELECT pg_temp.eq(public.price_unit_key('  Bx '), 'bx', 'unit key trims and lowercases');
SELECT pg_temp.eq(public.price_unit_key('   '), NULL::text, 'blank unit key is NULL');
SELECT pg_temp.eq(public.price_unit_is_valid('EA'), true, 'EA is valid');
SELECT pg_temp.eq(public.price_unit_is_valid(' ea '), true, 'spaces around a unit are trimmed');
SELECT pg_temp.eq(public.price_unit_is_valid('EA)'), false, 'EA) is malformed');
SELECT pg_temp.eq(public.price_unit_is_valid('pk 10'), false, 'pk 10 is malformed');
SELECT pg_temp.eq(public.price_unit_is_valid('ea/2'), false, 'ea/2 is malformed');
SELECT pg_temp.eq(public.price_unit_is_valid('abcdefghijk'), false, 'eleven letters is malformed');
SELECT pg_temp.eq(public.price_unit_is_valid(NULL), false, 'missing unit is not valid');
SELECT pg_temp.eq(public.price_recency(pg_temp.today() - 90, pg_temp.today()), 'recent', '90 days is recent');
SELECT pg_temp.eq(public.price_recency(pg_temp.today() - 91, pg_temp.today()), 'aging', '91 days is aging');
SELECT pg_temp.eq(public.price_recency(pg_temp.today() - 180, pg_temp.today()), 'aging', '180 days is aging');
SELECT pg_temp.eq(public.price_recency(pg_temp.today() - 181, pg_temp.today()), 'stale', '181 days is stale');
SELECT pg_temp.eq(public.price_recency(pg_temp.today() + 5, pg_temp.today()), 'recent', 'future dates are age 0');
SELECT pg_temp.eq(public.price_catalog_unit_agrees(1, 'ea', 'ea'), true, 'quantity 1 agrees with ea');
SELECT pg_temp.eq(public.price_catalog_unit_agrees(1, 'ea', 'bt'), false, 'quantity 1 never agrees with bt');
SELECT pg_temp.eq(public.price_catalog_unit_agrees(200, '200/box', 'bx'), true, '200/box agrees with bx');
SELECT pg_temp.eq(public.price_catalog_unit_agrees(200, '200/box', 'bt'), false, '200/box never agrees with bt');
SELECT pg_temp.eq(public.price_catalog_unit_agrees(6, '6/pkg', 'pk'), true, '6/pkg agrees with pk');
SELECT pg_temp.eq(public.price_catalog_unit_agrees(6, '6/pkg', 'bx'), false, '6/pkg never agrees with bx');
SELECT pg_temp.eq(public.price_catalog_unit_agrees(12, '12 per box', 'bx'), false, 'no slash, no agreement');
SELECT pg_temp.eq(public.price_catalog_unit_agrees(12, '12/carton', 'ca'), false, 'unmapped container never agrees');
SELECT pg_temp.eq(public.price_package_agreement('bx', '12/box', ' 12/BOX ', NULL, NULL), true, 'matching package text agrees');
SELECT pg_temp.eq(public.price_package_agreement('bx', '12/box', '10/box', '6b100000-0000-4000-8000-000000000271', '6b100000-0000-4000-8000-000000000272'),
  false, 'differing package text never agrees, even with agreeing catalog packages');
SELECT pg_temp.eq(public.price_package_agreement('bx', NULL, NULL, NULL, NULL), false, 'no package evidence never agrees');

-- ---------------------------------------------------------------------------------------
-- States, changes, comparisons (the internal decision, read as the owner would see it).
-- ---------------------------------------------------------------------------------------
CREATE TEMP TABLE phase6b1_states ON COMMIT DROP AS
SELECT replace(p.name, 'P6B1 ', '') AS name, s.*
FROM public.price_product_state('6b100000-0000-4000-8000-000000000101', NULL, pg_temp.today()) s
JOIN public.products p ON p.id = s.product_id;
CREATE FUNCTION pg_temp.st(_name text)
RETURNS phase6b1_states LANGUAGE sql STABLE AS $$ SELECT * FROM phase6b1_states WHERE name = _name $$;

SELECT pg_temp.eq((SELECT count(*) FROM phase6b1_states), 39::bigint, 'every purchased product has one state (Never Purchased has none)');
SELECT pg_temp.assert(NOT EXISTS (SELECT 1 FROM phase6b1_states WHERE name = 'Never Purchased'), 'a product without observations has no state');

-- FC Cincinnati regression: the two false increases disappear.
SELECT pg_temp.eq((pg_temp.st('Ammex Glove')).state, 'insufficient_identity', 'Ammex Large/X-Large: insufficient identity');
SELECT pg_temp.eq((pg_temp.st('Ammex Glove')).identity_issue, 'multiple_skus', 'Ammex: several SKUs from one vendor');
SELECT pg_temp.eq((pg_temp.st('Ammex Glove')).change_amount, NULL::numeric, 'Ammex: no product-level change');
SELECT pg_temp.eq((pg_temp.st('Ammex Glove')).prior, NULL::jsonb, 'Ammex: no prior');
SELECT pg_temp.assert(NOT 'same_sku_price_increased' = ANY ((pg_temp.st('Ammex Glove')).signals), 'Ammex: no increase signal');
SELECT pg_temp.eq((pg_temp.st('Ammex Glove')).anchor ->> 'sku', '398-0145', 'Ammex: last purchase is the newer X-Large line');
SELECT pg_temp.eq((pg_temp.st('Eco-Flex Tape')).state, 'insufficient_identity', 'Eco-Flex colors: insufficient identity');
SELECT pg_temp.eq((pg_temp.st('Eco-Flex Tape')).change_amount, NULL::numeric, 'Eco-Flex: no change');
SELECT pg_temp.eq((pg_temp.st('Leukotape')).state, 'single_vendor', 'Leukotape: single vendor');
SELECT pg_temp.eq((pg_temp.st('Leukotape')).change_amount, 0::numeric, 'Leukotape: no change');
SELECT pg_temp.eq((pg_temp.st('Leukotape')).prior ->> 'price', '7.29', 'Leukotape: prior same SKU');
SELECT pg_temp.eq((pg_temp.st('Mediproxen')).state, 'single_vendor', 'Mediproxen: single vendor');
SELECT pg_temp.eq((pg_temp.st('Mediproxen')).change_amount, 0::numeric, 'Mediproxen: BX and Bx are one unit; no change');
SELECT pg_temp.eq((pg_temp.st('Mediproxen')).anchor ->> 'documentType', 'ORDER_CONFIRMATION', 'Mediproxen: last purchase is the order confirmation');
SELECT pg_temp.eq((pg_temp.st('Mediproxen')).anchor ->> 'dateBasis', 'posting_date', 'Mediproxen: dated by posting');
SELECT pg_temp.eq((pg_temp.st('Mediproxen')).anchor ->> 'documentNumber', (SELECT order_number FROM public.invoices i
  JOIN public.inventory_price_history h ON h.invoice_id = i.id WHERE h.id = ((pg_temp.st('Mediproxen')).anchor ->> 'observationId')::uuid),
  'order confirmations show their order number');
SELECT pg_temp.eq((pg_temp.st('Protex')).state, 'insufficient_identity', 'Protex: EA) is malformed');
SELECT pg_temp.eq((pg_temp.st('Protex')).identity_issue, 'malformed_unit', 'Protex: malformed unit');
SELECT pg_temp.eq((pg_temp.st('Protex')).change_amount, NULL::numeric, 'Protex: EA) never compares to EA');

SELECT pg_temp.eq((pg_temp.st('Ambiguous Repeat')).state, 'insufficient_identity', 'ambiguous product with a repeated SKU');
SELECT pg_temp.eq((pg_temp.st('Ambiguous Repeat')).change_amount, NULL::numeric, 'insufficient identity: no product-level change even for a repeated SKU');
SELECT pg_temp.eq((pg_temp.st('Ambiguous Repeat')).prior, NULL::jsonb, 'insufficient identity: no prior');

-- Incomplete or ambiguous SKUs, missing units.
SELECT pg_temp.eq((pg_temp.st('Tape 950')).state, 'insufficient_identity', 'two mapped SKUs, one purchased: insufficient identity');
SELECT pg_temp.eq((pg_temp.st('Tape 950')).identity_issue, 'multiple_skus', 'unpurchased mapping counts');
SELECT pg_temp.eq((pg_temp.st('No SKU')).identity_issue, 'missing_sku', 'no mapping and no line SKU: missing SKU');
SELECT pg_temp.eq((pg_temp.st('No SKU')).change_amount, NULL::numeric, 'missing SKU: no change');
SELECT pg_temp.eq((pg_temp.st('No Unit')).identity_issue, 'missing_unit', 'missing unit');
SELECT pg_temp.eq((pg_temp.st('No Unit')).change_amount, NULL::numeric, 'missing unit: no change');

-- Same-SKU change.
SELECT pg_temp.eq((pg_temp.st('Clean Rising')).state, 'single_vendor', 'clean history: single vendor');
SELECT pg_temp.eq((pg_temp.st('Clean Rising')).change_amount, 1::numeric, 'newest (12) against the one before (11)');
SELECT pg_temp.eq(round((pg_temp.st('Clean Rising')).change_percent, 4), 9.0909::numeric, 'percent change');
SELECT pg_temp.assert('same_sku_price_increased' = ANY ((pg_temp.st('Clean Rising')).signals), 'recent increase signals');
SELECT pg_temp.eq((pg_temp.st('Clean Rising')).stale, false, 'recent anchor is not stale');
SELECT pg_temp.eq((pg_temp.st('Clean Stale Anchor')).change_amount, 2::numeric, 'history is still shown for a stale anchor');
SELECT pg_temp.assert(NOT 'same_sku_price_increased' = ANY ((pg_temp.st('Clean Stale Anchor')).signals), 'stale anchor: no increase signal');
SELECT pg_temp.eq((pg_temp.st('Clean Stale Anchor')).stale, true, 'stale anchor is marked');
SELECT pg_temp.assert('price_data_stale' = ANY ((pg_temp.st('Clean Stale Anchor')).signals), 'stale signal');
SELECT pg_temp.assert('same_sku_price_increased' = ANY ((pg_temp.st('Increase Age 180')).signals), 'anchor at 180 days still signals');
SELECT pg_temp.assert(NOT 'same_sku_price_increased' = ANY ((pg_temp.st('Increase Age 181')).signals), 'anchor at 181 days does not');
SELECT pg_temp.eq((pg_temp.st('One Purchase')).state, 'one_purchase', 'one observation');

-- Cross-vendor comparison.
SELECT pg_temp.eq((pg_temp.st('MV Lower')).state, 'comparable', 'A $10/bx vs B $9/bx: comparable');
SELECT pg_temp.eq((pg_temp.st('MV Lower')).lowest ->> 'vendorId', pg_temp.vendor(2)::text, 'lowest comparable purchase price is vendor 2');
SELECT pg_temp.eq(((pg_temp.st('MV Lower')).lowest ->> 'price')::numeric, 9::numeric, 'lowest is $9');
SELECT pg_temp.eq((pg_temp.st('MV Lower')).difference, 1::numeric, 'difference per comparable invoiced unit');
SELECT pg_temp.eq((pg_temp.st('MV Lower')).comparable_vendor_count, 2, 'two comparable vendors');
SELECT pg_temp.assert('lower_comparable_price_other_vendor' = ANY ((pg_temp.st('MV Lower')).signals), 'lower-price signal');
SELECT pg_temp.eq((pg_temp.st('MV Equal')).state, 'comparable', 'equal prices: comparable');
SELECT pg_temp.eq((pg_temp.st('MV Equal')).lowest ->> 'vendorId', pg_temp.vendor(1)::text, 'a tie ranks the last purchase');
SELECT pg_temp.assert(NOT 'lower_comparable_price_other_vendor' = ANY ((pg_temp.st('MV Equal')).signals), 'equal: no signal (strictly lower only)');
SELECT pg_temp.eq((pg_temp.st('MV Higher')).lowest ->> 'vendorId', pg_temp.vendor(1)::text, 'B higher: the last purchase is lowest');
SELECT pg_temp.eq((pg_temp.st('MV Higher')).difference, -1::numeric, 'negative difference when the last purchase is cheaper');
SELECT pg_temp.assert(NOT 'lower_comparable_price_other_vendor' = ANY ((pg_temp.st('MV Higher')).signals), 'B higher: no signal');
SELECT pg_temp.eq((pg_temp.st('MV Three')).lowest ->> 'vendorId', pg_temp.vendor(3)::text, 'three vendors: the lowest of all');
SELECT pg_temp.eq((pg_temp.st('MV Three')).comparable_vendor_count, 3, 'three comparable vendors');
SELECT pg_temp.eq((pg_temp.st('MV Incompatible Third')).state, 'comparable', 'one compatible pair is enough');
SELECT pg_temp.eq((pg_temp.st('MV Incompatible Third')).lowest ->> 'vendorId', pg_temp.vendor(2)::text, 'the cheaper incompatible vendor is never ranked');
SELECT pg_temp.eq((pg_temp.st('MV Incompatible Third')).comparable_vendor_count, 2, 'incompatible vendor excluded');
SELECT pg_temp.eq((pg_temp.st('MV All Incompatible')).state, 'incompatible_units', 'no shared unit');
SELECT pg_temp.eq((pg_temp.st('MV All Incompatible')).lowest, NULL::jsonb, 'incompatible: no ranking');
SELECT pg_temp.assert('multiple_vendors_not_comparable' = ANY ((pg_temp.st('MV All Incompatible')).signals), 'not-comparable signal');
SELECT pg_temp.eq((pg_temp.st('MV Stale Alternative')).state, 'comparable', 'structurally comparable stale pair stays Comparable');
SELECT pg_temp.eq((pg_temp.st('MV Stale Alternative')).stale, true, 'with the Stale marker');
SELECT pg_temp.eq((pg_temp.st('MV Stale Alternative')).comparison_withheld, 'stale', 'numbers withheld because of age');
SELECT pg_temp.eq((pg_temp.st('MV Stale Alternative')).lowest, NULL::jsonb, 'stale: no lowest comparable purchase price');
SELECT pg_temp.eq((pg_temp.st('MV Stale Alternative')).difference, NULL::numeric, 'stale: no difference');
SELECT pg_temp.assert(NOT 'lower_comparable_price_other_vendor' = ANY ((pg_temp.st('MV Stale Alternative')).signals), 'stale: no signal');
SELECT pg_temp.eq((pg_temp.st('MV Stale Alternative')).comparable_vendor_count, 0, 'stale: no comparable vendors are counted');
SELECT pg_temp.eq((pg_temp.st('MV Stale Alternative')).alternative, NULL::jsonb, 'stale: no alternative');
SELECT pg_temp.eq((pg_temp.st('MV Stale Anchor')).state, 'comparable', 'stale anchor: still Comparable');
SELECT pg_temp.eq((pg_temp.st('MV Stale Anchor')).stale, true, 'stale anchor marked');
SELECT pg_temp.eq((pg_temp.st('MV Stale Anchor')).lowest, NULL::jsonb, 'stale anchor: no ranking');
SELECT pg_temp.eq((pg_temp.st('MV Package Null')).state, 'missing_package_details', 'both packages NULL');
SELECT pg_temp.assert('package_details_missing' = ANY ((pg_temp.st('MV Package Null')).signals), 'package signal');
SELECT pg_temp.eq((pg_temp.st('MV Package One')).state, 'missing_package_details', 'one package NULL');
SELECT pg_temp.eq((pg_temp.st('MV Package Mismatch')).state, 'missing_package_details', 'mismatched package quantities');
SELECT pg_temp.eq((pg_temp.st('MV Catalog')).state, 'comparable', 'verified catalog packages that agree with the invoiced unit');
SELECT pg_temp.eq((pg_temp.st('MV Catalog')).difference, 1::numeric, 'catalog-proven comparison has numbers');
SELECT pg_temp.eq((pg_temp.st('MV Catalog Disagree')).state, 'missing_package_details', 'catalog 200/box against an invoiced bt');
SELECT pg_temp.eq((pg_temp.st('MV Catalog Source Only')).state, 'missing_package_details', 'source-only catalog package');
SELECT pg_temp.eq((pg_temp.st('MV Catalog Quantity')).state, 'missing_package_details', 'catalog quantities differ');
SELECT pg_temp.eq((pg_temp.st('MV Malformed')).state, 'insufficient_identity', 'a malformed vendor unit');
SELECT pg_temp.assert('multiple_vendors_not_comparable' = ANY ((pg_temp.st('MV Malformed')).signals), 'malformed with two vendors');
SELECT pg_temp.eq((pg_temp.st('MV Ambiguous')).state, 'insufficient_identity', 'one vendor with two SKUs');
SELECT pg_temp.eq((pg_temp.st('MV Ambiguous')).lowest, NULL::jsonb, 'ambiguous: no ranking');
SELECT pg_temp.eq((pg_temp.st('MV Non USD')).state, 'one_purchase', 'explicit non-USD excluded; explicit USD included');
SELECT pg_temp.eq((pg_temp.st('MV Non USD')).vendor_count, 1, 'the CAD vendor is not observed in USD');
SELECT pg_temp.assert('lower_comparable_price_other_vendor' = ANY ((pg_temp.st('MV Age 180')).signals), 'alternative at 180 days ranks');
SELECT pg_temp.eq((pg_temp.st('MV Age 181')).lowest, NULL::jsonb, 'alternative at 181 days never ranks');
SELECT pg_temp.eq((pg_temp.st('MV Age 181')).comparison_withheld, 'stale', 'alternative at 181 days: withheld');
SELECT pg_temp.assert(NOT 'lower_comparable_price_other_vendor' = ANY ((pg_temp.st('MV Age 181')).signals), 'no signal at 181');
SELECT pg_temp.eq((pg_temp.st('MV Order Confirmation')).alternative ->> 'documentType', 'ORDER_CONFIRMATION', 'an order confirmation can be the alternative, labelled');
SELECT pg_temp.eq((pg_temp.st('MV Order Confirmation')).alternative ->> 'dateBasis', 'posting_date', 'its posting date basis is shown');
SELECT pg_temp.eq((pg_temp.st('MV Order Confirmation')).alternative ->> 'documentNumber', 'SO-77', 'an order confirmation shows its order number, not an invoice number');
SELECT pg_temp.eq((pg_temp.st('Age 90')).anchor ->> 'recency', 'recent', 'age 90 recent');
SELECT pg_temp.eq((pg_temp.st('Age 91')).anchor ->> 'recency', 'aging', 'age 91 aging');
SELECT pg_temp.eq((pg_temp.st('Age 180')).stale, false, 'age 180 not stale');
SELECT pg_temp.eq((pg_temp.st('Age 181')).stale, true, 'age 181 stale');
SELECT pg_temp.eq((pg_temp.st('Age 181')).anchor ->> 'recency', 'stale', 'age 181 recency');

-- Precedence: a one-observation product with an ambiguous SKU is insufficient, not one purchase.
SELECT pg_temp.eq((pg_temp.st('Tape 950')).observation_count, 1, 'Tape 950 has one observation');

-- ---------------------------------------------------------------------------------------
-- RPCs as the owner: summary, list (keyset, filters, sorts), detail, request context.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('6b100000-0000-4000-8000-000000000001');
SELECT pg_temp.keep('summary', public.get_price_intelligence_summary('6b100000-0000-4000-8000-000000000101'));
RESET ROLE;
SELECT pg_temp.eq((pg_temp.val('summary') ->> 'productCount')::int, 39, 'summary product count');
SELECT pg_temp.eq((pg_temp.val('summary') -> 'states' ->> 'insufficient_identity')::int,
  (SELECT count(*)::int FROM phase6b1_states WHERE state = 'insufficient_identity'), 'summary state count');
SELECT pg_temp.eq((pg_temp.val('summary') -> 'states' ->> 'comparable')::int,
  (SELECT count(*)::int FROM phase6b1_states WHERE state = 'comparable'), 'summary comparable count');
SELECT pg_temp.eq((pg_temp.val('summary') -> 'signals' ->> 'lower_comparable_price_other_vendor')::int,
  (SELECT count(*)::int FROM phase6b1_states WHERE 'lower_comparable_price_other_vendor' = ANY (signals)), 'summary signal count');
SELECT pg_temp.eq((pg_temp.val('summary') ->> 'staleCount')::int,
  (SELECT count(*)::int FROM phase6b1_states WHERE stale), 'summary stale count');
SELECT pg_temp.eq((pg_temp.val('summary') -> 'coverage' ->> 'excludedNonUsdCount')::int, 1, 'non-USD reported in coverage');
SELECT pg_temp.eq((pg_temp.val('summary') -> 'coverage' ->> 'orderConfirmationCount')::int, 2, 'order confirmations counted');
SELECT pg_temp.eq((pg_temp.val('summary') -> 'coverage' ->> 'datedByPostingCount')::int, 2, 'posting-dated observations counted');
SELECT pg_temp.eq(jsonb_array_length(pg_temp.val('summary') -> 'vendors'), 1, 'only vendor 1 is a last-purchase vendor');
SELECT pg_temp.eq((pg_temp.val('summary') ->> 'vendorCount')::int, 3, 'three vendors observed in USD');

-- Keyset pagination, recent order: pages of 5, every product exactly once, newest first.
CREATE FUNCTION pg_temp.walk(_sort text, _filter text, _limit integer, _scan integer, _vendor uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  _cursor jsonb := NULL;
  _page jsonb;
  _rows jsonb := '[]'::jsonb;
  _calls integer := 0;
BEGIN
  LOOP
    _page := public.list_price_intelligence_products('6b100000-0000-4000-8000-000000000101', _sort, _filter, _vendor, _cursor, _limit, _scan);
    _rows := _rows || (_page -> 'rows');
    _calls := _calls + 1;
    IF jsonb_array_length(_page -> 'rows') > _limit THEN RAISE EXCEPTION 'page over limit'; END IF;
    EXIT WHEN (_page ->> 'exhausted')::boolean;
    _cursor := _page -> 'nextCursor';
    IF _calls > 200 THEN RAISE EXCEPTION 'pagination did not terminate'; END IF;
  END LOOP;
  RETURN jsonb_build_object('rows', _rows, 'calls', _calls);
END;
$$;
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('6b100000-0000-4000-8000-000000000001');
SELECT pg_temp.keep('recent', pg_temp.walk('recent', 'all', 5, 5));
SELECT pg_temp.keep('byname', pg_temp.walk('product', 'all', 7, 7));
SELECT pg_temp.keep('insufficient', pg_temp.walk('recent', 'insufficient_identity', 2, 3));
SELECT pg_temp.keep('lower', pg_temp.walk('product', 'lower_comparable_price_other_vendor', 1, 4));
SELECT pg_temp.keep('stalefilter', pg_temp.walk('recent', 'stale', 50, 2000));
SELECT pg_temp.keep('increase', pg_temp.walk('recent', 'same_sku_price_increased', 50, 2000));
SELECT pg_temp.keep('vendor2', pg_temp.walk('recent', 'all', 50, 50, pg_temp.vendor(2)));
SELECT pg_temp.keep('first', public.list_price_intelligence_products('6b100000-0000-4000-8000-000000000101'));
RESET ROLE;
SELECT pg_temp.eq(jsonb_array_length(pg_temp.val('recent') -> 'rows'), 39, 'recent walk returns every product');
SELECT pg_temp.eq((SELECT count(DISTINCT r ->> 'productId') FROM jsonb_array_elements(pg_temp.val('recent') -> 'rows') r), 39::bigint, 'no duplicates across pages');
SELECT pg_temp.assert((SELECT bool_and(a.d >= b.d) FROM (
  SELECT r -> 'lastPurchase' ->> 'purchaseDate' AS d, n
  FROM jsonb_array_elements(pg_temp.val('recent') -> 'rows') WITH ORDINALITY x(r, n)) a
  JOIN (SELECT r -> 'lastPurchase' ->> 'purchaseDate' AS d, n
  FROM jsonb_array_elements(pg_temp.val('recent') -> 'rows') WITH ORDINALITY x(r, n)) b ON b.n = a.n + 1), 'recent order is newest first');
SELECT pg_temp.eq((pg_temp.val('recent') ->> 'calls')::int, 8, 'pages of five: eight calls');
SELECT pg_temp.eq(jsonb_array_length(pg_temp.val('byname') -> 'rows'), 39, 'name walk returns every product');
SELECT pg_temp.eq((SELECT array_agg(r ->> 'productName' ORDER BY n) FROM jsonb_array_elements(pg_temp.val('byname') -> 'rows') WITH ORDINALITY x(r, n)),
  (SELECT array_agg(p.name ORDER BY p.normalized_name, p.id) FROM public.products p JOIN phase6b1_states s ON s.product_id = p.id), 'name order');
SELECT pg_temp.eq((SELECT array_agg(r ->> 'productId' ORDER BY r ->> 'productId') FROM jsonb_array_elements(pg_temp.val('insufficient') -> 'rows') r),
  (SELECT array_agg(product_id::text ORDER BY product_id::text) FROM phase6b1_states WHERE state = 'insufficient_identity'),
  'state filter with a scan budget finds exactly the insufficient products');
SELECT pg_temp.eq((SELECT array_agg(r ->> 'productId' ORDER BY r ->> 'productId') FROM jsonb_array_elements(pg_temp.val('lower') -> 'rows') r),
  (SELECT array_agg(product_id::text ORDER BY product_id::text) FROM phase6b1_states WHERE 'lower_comparable_price_other_vendor' = ANY (signals)),
  'signal filter, one per page, product order');
SELECT pg_temp.eq((SELECT array_agg(replace(r ->> 'productName', 'P6B1 ', '') ORDER BY r ->> 'productName') FROM jsonb_array_elements(pg_temp.val('lower') -> 'rows') r),
  ARRAY['MV Age 180', 'MV Catalog', 'MV Incompatible Third', 'MV Lower', 'MV Order Confirmation', 'MV Three'], 'exactly these products have a lower comparable price');
SELECT pg_temp.eq(jsonb_array_length(pg_temp.val('stalefilter') -> 'rows'),
  (SELECT count(*)::int FROM phase6b1_states WHERE stale), 'stale filter');
SELECT pg_temp.eq((SELECT array_agg(replace(r ->> 'productName', 'P6B1 ', '') ORDER BY r ->> 'productName') FROM jsonb_array_elements(pg_temp.val('increase') -> 'rows') r),
  ARRAY['Clean Rising', 'Increase Age 180'], 'same-SKU increases: only valid same-SKU history');
SELECT pg_temp.eq(jsonb_array_length(pg_temp.val('vendor2') -> 'rows'), 0, 'vendor filter: no product was last bought from vendor 2');
SELECT pg_temp.eq(jsonb_array_length(pg_temp.val('first') -> 'rows'), 39, 'default page holds 50');
SELECT pg_temp.eq((pg_temp.val('first') ->> 'exhausted')::boolean, true, 'one page is the whole list');
SELECT pg_temp.assert((SELECT bool_and(r ? 'lastPurchase' AND r ? 'signals' AND r ? 'state' AND NOT r ? 'unitSavings' AND NOT r ? 'bestAlternative')
  FROM jsonb_array_elements(pg_temp.val('first') -> 'rows') r), 'list rows carry no savings fields');

-- Bad inputs.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('6b100000-0000-4000-8000-000000000001');
SELECT pg_temp.expect_error($$SELECT public.list_price_intelligence_products('6b100000-0000-4000-8000-000000000101', 'savings')$$, 'sort must be', '22023');
SELECT pg_temp.expect_error($$SELECT public.list_price_intelligence_products('6b100000-0000-4000-8000-000000000101', 'recent', 'savings')$$, 'Unknown price intelligence filter', '22023');
SELECT pg_temp.expect_error($$SELECT public.list_price_intelligence_products('6b100000-0000-4000-8000-000000000101', 'recent', 'all', NULL, NULL, 101)$$, 'limit must be', '22023');
SELECT pg_temp.expect_error($$SELECT public.list_price_intelligence_products('6b100000-0000-4000-8000-000000000101', 'recent', 'all', NULL, '{"purchaseDate":"x"}')$$, 'Invalid price intelligence cursor', '22023');
SELECT pg_temp.expect_error($$SELECT public.list_price_intelligence_products('6b100000-0000-4000-8000-000000000101', 'product', 'all', NULL, '{"productId":"6b100000-0000-4000-8000-000000000101"}')$$, 'Invalid price intelligence cursor', '22023');
SELECT pg_temp.expect_error($$SELECT public.get_product_vendor_price_history('6b100000-0000-4000-8000-000000000101')$$, 'exactly one', '22023');
RESET ROLE;

-- Detail.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('6b100000-0000-4000-8000-000000000001');
SELECT pg_temp.keep('ammex', public.get_product_vendor_price_history('6b100000-0000-4000-8000-000000000101', pg_temp.pid('Ammex Glove')));
SELECT pg_temp.keep('three', public.get_product_vendor_price_history('6b100000-0000-4000-8000-000000000101', pg_temp.pid('MV Incompatible Third')));
SELECT pg_temp.keep('stalealt', public.get_product_vendor_price_history('6b100000-0000-4000-8000-000000000101', pg_temp.pid('MV Stale Alternative')));
SELECT pg_temp.keep('catalog', public.get_product_vendor_price_history('6b100000-0000-4000-8000-000000000101', pg_temp.pid('MV Catalog')));
SELECT pg_temp.keep('rising1', public.get_product_vendor_price_history('6b100000-0000-4000-8000-000000000101', NULL, '6b100000-0000-4000-8000-000000000601', NULL, 2));
SELECT pg_temp.keep('rising2', public.get_product_vendor_price_history('6b100000-0000-4000-8000-000000000101', pg_temp.pid('Clean Rising'), NULL, pg_temp.val('rising1') -> 'nextCursor', 2));
SELECT pg_temp.keep('never', public.get_product_vendor_price_history('6b100000-0000-4000-8000-000000000101', pg_temp.pid('Never Purchased')));
SELECT pg_temp.keep('medi', public.get_product_vendor_price_history('6b100000-0000-4000-8000-000000000101', pg_temp.pid('Mediproxen')));
RESET ROLE;
SELECT pg_temp.eq(pg_temp.val('ammex') ->> 'state', 'insufficient_identity', 'detail state');
SELECT pg_temp.eq((SELECT array_agg(s ->> 'sku' ORDER BY s ->> 'sku') FROM jsonb_array_elements(pg_temp.val('ammex') -> 'identity' -> 'skus') s),
  ARRAY['398-0144', '398-0145'], 'detail lists the SKU identities involved');
SELECT pg_temp.eq(pg_temp.val('ammex') -> 'priorSameSku', 'null'::jsonb, 'detail: no prior across SKUs');
SELECT pg_temp.eq(jsonb_array_length(pg_temp.val('ammex') -> 'observations'), 2, 'both source observations remain visible');
SELECT pg_temp.eq((pg_temp.val('ammex') ->> 'canOpenSourceDocument')::boolean, true, 'owners may open the source document');
SELECT pg_temp.eq(pg_temp.val('ammex') -> 'vendors' -> 0 ->> 'comparisonStatus', 'last_purchase', 'anchor vendor row');
SELECT pg_temp.eq((SELECT v ->> 'comparisonStatus' FROM jsonb_array_elements(pg_temp.val('three') -> 'vendors') v
  WHERE v ->> 'vendorId' = pg_temp.vendor(3)::text), 'incompatible_units', 'vendor three is incompatible');
SELECT pg_temp.eq((SELECT v ->> 'comparisonStatus' FROM jsonb_array_elements(pg_temp.val('three') -> 'vendors') v
  WHERE v ->> 'vendorId' = pg_temp.vendor(2)::text), 'comparable', 'vendor two is comparable');
SELECT pg_temp.eq((SELECT v -> 'checks' ->> 'packageBasis' FROM jsonb_array_elements(pg_temp.val('three') -> 'vendors') v
  WHERE v ->> 'vendorId' = pg_temp.vendor(2)::text), 'package_text', 'evidence names the package basis');
SELECT pg_temp.eq((SELECT v -> 'checks' ->> 'packageBasis' FROM jsonb_array_elements(pg_temp.val('catalog') -> 'vendors') v
  WHERE v ->> 'vendorId' = pg_temp.vendor(2)::text), 'catalog', 'catalog package basis');
SELECT pg_temp.eq((SELECT v ->> 'comparisonStatus' FROM jsonb_array_elements(pg_temp.val('stalealt') -> 'vendors') v
  WHERE v ->> 'vendorId' = pg_temp.vendor(2)::text), 'comparable_stale', 'stale alternative status');
SELECT pg_temp.eq(pg_temp.val('stalealt') -> 'lowestComparable', 'null'::jsonb, 'stale: no lowest in detail');
SELECT pg_temp.eq(pg_temp.val('stalealt') ->> 'comparisonWithheld', 'stale', 'stale: withheld in detail');
SELECT pg_temp.eq(pg_temp.val('rising1') ->> 'productId', pg_temp.pid('Clean Rising')::text, 'detail resolves an inventory item');
SELECT pg_temp.eq(jsonb_array_length(pg_temp.val('rising1') -> 'observations'), 2, 'first observation page');
SELECT pg_temp.eq(jsonb_array_length(pg_temp.val('rising2') -> 'observations'), 1, 'second observation page');
SELECT pg_temp.eq(pg_temp.val('rising2') -> 'nextCursor', 'null'::jsonb, 'last page has no cursor');
SELECT pg_temp.eq((SELECT count(DISTINCT o ->> 'observationId') FROM jsonb_array_elements((pg_temp.val('rising1') -> 'observations') || (pg_temp.val('rising2') -> 'observations')) o),
  3::bigint, 'observation pages do not overlap');
SELECT pg_temp.eq(pg_temp.val('rising1') -> 'vendors' -> 0 -> 'priorSameSku' ->> 'price', '11', 'vendor prior same SKU');
SELECT pg_temp.eq((pg_temp.val('rising1') -> 'vendors' -> 0 ->> 'purchaseCount')::int, 3, 'purchase count');
SELECT pg_temp.eq(pg_temp.val('rising1') -> 'vendors' -> 0 ->> 'firstPurchaseDate', (pg_temp.today() - 50)::text, 'first purchase date');
SELECT pg_temp.eq(pg_temp.val('never') ->> 'state', NULL::text, 'never purchased: no state');
SELECT pg_temp.eq(jsonb_array_length(pg_temp.val('never') -> 'observations'), 0, 'never purchased: no observations');
SELECT pg_temp.eq(pg_temp.val('medi') -> 'observations' -> 0 ->> 'documentType', 'ORDER_CONFIRMATION', 'source list labels the order confirmation');
SELECT pg_temp.eq(pg_temp.val('medi') -> 'observations' -> 0 ->> 'dateBasis', 'posting_date', 'and its posting date');
SELECT pg_temp.eq(pg_temp.val('medi') -> 'observations' -> 1 ->> 'dateBasis', 'invoice_date', 'invoices keep the invoice date');

-- Request context.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('6b100000-0000-4000-8000-000000000002');
SELECT pg_temp.keep('context', public.get_supply_request_price_context('6b100000-0000-4000-8000-000000000101', '6b100000-0000-4000-8000-000000000701'));
RESET ROLE;
CREATE FUNCTION pg_temp.ctx(_item text)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT i FROM jsonb_array_elements(pg_temp.val('context') -> 'items') i WHERE i ->> 'itemId' = '6b100000-0000-4000-8000-000000000' || _item $$;
SELECT pg_temp.eq(pg_temp.ctx('711') ->> 'status', 'last_purchase', 'product item: last purchase');
SELECT pg_temp.eq(pg_temp.ctx('711') -> 'lastPurchase' ->> 'price', '10', 'product item: the last purchase price');
SELECT pg_temp.eq(pg_temp.ctx('711') -> 'lowerComparable' ->> 'vendorId', pg_temp.vendor(2)::text, 'product item: lower comparable from vendor 2');
SELECT pg_temp.eq(pg_temp.ctx('712') -> 'lastPurchase' ->> 'sku', '398-0144', 'SKU item: that SKU''s last purchase');
SELECT pg_temp.eq(pg_temp.ctx('712') -> 'lastPurchase' ->> 'price', '6.08', 'SKU item: its own price');
SELECT pg_temp.eq(pg_temp.ctx('713') ->> 'status', 'several_skus', 'ambiguous product without a SKU');
SELECT pg_temp.eq(pg_temp.ctx('713') -> 'lastPurchase', 'null'::jsonb, 'several SKUs: no price shown');
SELECT pg_temp.eq(pg_temp.ctx('714') ->> 'status', 'unresolved', 'free text: unresolved');
SELECT pg_temp.eq(pg_temp.ctx('715') ->> 'productId', pg_temp.pid('Clean Rising')::text, 'inventory item resolves its product');
SELECT pg_temp.eq(pg_temp.ctx('716') ->> 'status', 'no_history', 'never purchased: no history');
SELECT pg_temp.eq(pg_temp.ctx('717') ->> 'productId', pg_temp.pid('MV Catalog')::text, 'catalog listing resolves through its adoption');
SELECT pg_temp.eq(pg_temp.ctx('718') -> 'lastPurchase' ->> 'vendorId', pg_temp.vendor(2)::text, 'vendor-2 SKU item shows vendor 2''s purchase');
SELECT pg_temp.eq(pg_temp.ctx('718') -> 'lowerComparable', 'null'::jsonb, 'the signal is only shown against the last purchase');

-- ---------------------------------------------------------------------------------------
-- Old RPCs: exact keys, fixed logic.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('6b100000-0000-4000-8000-000000000001');
SELECT pg_temp.keep('old_overview', public.get_price_intelligence_overview('6b100000-0000-4000-8000-000000000101'));
SELECT pg_temp.keep('old_ammex', public.get_product_price_intelligence('6b100000-0000-4000-8000-000000000101', pg_temp.pid('Ammex Glove')));
SELECT pg_temp.keep('old_rising', public.get_product_price_intelligence('6b100000-0000-4000-8000-000000000101', pg_temp.pid('Clean Rising')));
SELECT pg_temp.keep('old_never', public.get_product_price_intelligence('6b100000-0000-4000-8000-000000000101', pg_temp.pid('Never Purchased')));
RESET ROLE;
CREATE FUNCTION pg_temp.keys(_value jsonb)
RETURNS text[] LANGUAGE sql IMMUTABLE AS $$ SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(_value) k $$;
SELECT pg_temp.eq(pg_temp.keys(pg_temp.val('old_overview')),
  ARRAY['averageWindowDays', 'currencyCode', 'organizationId', 'productCount', 'productLimit', 'rows'], 'old overview keys');
SELECT pg_temp.eq((SELECT DISTINCT pg_temp.keys(r) FROM jsonb_array_elements(pg_temp.val('old_overview') -> 'rows') r),
  ARRAY['absoluteChange', 'bestAlternative', 'comparability', 'current', 'percentChange', 'previous', 'productId', 'productName', 'recentAverage', 'unitSavings'],
  'old overview row keys');
SELECT pg_temp.eq((SELECT DISTINCT pg_temp.keys(r -> 'current') FROM jsonb_array_elements(pg_temp.val('old_overview') -> 'rows') r),
  ARRAY['invoiceId', 'invoiceNumber', 'observationId', 'packageSize', 'price', 'purchaseDate', 'quantity', 'unitOfMeasure', 'vendorId', 'vendorName'],
  'old overview current keys');
SELECT pg_temp.eq((SELECT DISTINCT pg_temp.keys(r -> 'previous') FROM jsonb_array_elements(pg_temp.val('old_overview') -> 'rows') r WHERE r -> 'previous' <> 'null'),
  ARRAY['invoiceId', 'invoiceNumber', 'price', 'purchaseDate'], 'old overview previous keys');
SELECT pg_temp.eq((SELECT DISTINCT pg_temp.keys(r -> 'bestAlternative') FROM jsonb_array_elements(pg_temp.val('old_overview') -> 'rows') r WHERE r -> 'bestAlternative' <> 'null'),
  ARRAY['comparableVendorCount', 'invoiceId', 'invoiceNumber', 'packageSize', 'price', 'purchaseDate', 'unitOfMeasure', 'vendorId', 'vendorName'], 'old overview alternative keys');
SELECT pg_temp.eq((pg_temp.val('old_overview') ->> 'productCount')::int, 39, 'old overview product count');
SELECT pg_temp.assert((SELECT bool_and(r -> 'unitSavings' = 'null' AND r -> 'recentAverage' = 'null')
  FROM jsonb_array_elements(pg_temp.val('old_overview') -> 'rows') r), 'old savings and average are always null');
SELECT pg_temp.eq((SELECT count(*) FROM jsonb_array_elements(pg_temp.val('old_overview') -> 'rows') r WHERE (r ->> 'absoluteChange')::numeric > 0),
  4::bigint, 'old overview increases are same-SKU history only: Clean Rising, Clean Stale Anchor, Increase Age 180 and 181');
SELECT pg_temp.eq((SELECT r -> 'absoluteChange' FROM jsonb_array_elements(pg_temp.val('old_overview') -> 'rows') r
  WHERE r ->> 'productId' = pg_temp.pid('Ammex Glove')::text), 'null'::jsonb, 'old overview: Ammex false increase gone');
SELECT pg_temp.eq((SELECT r -> 'absoluteChange' FROM jsonb_array_elements(pg_temp.val('old_overview') -> 'rows') r
  WHERE r ->> 'productId' = pg_temp.pid('Eco-Flex Tape')::text), 'null'::jsonb, 'old overview: Eco-Flex false increase gone');
SELECT pg_temp.eq((SELECT r -> 'bestAlternative' ->> 'vendorId' FROM jsonb_array_elements(pg_temp.val('old_overview') -> 'rows') r
  WHERE r ->> 'productId' = pg_temp.pid('MV Lower')::text), pg_temp.vendor(2)::text, 'old overview alternative only when strictly comparable');
SELECT pg_temp.eq((SELECT r -> 'bestAlternative' FROM jsonb_array_elements(pg_temp.val('old_overview') -> 'rows') r
  WHERE r ->> 'productId' = pg_temp.pid('MV Package Null')::text), 'null'::jsonb, 'old overview: no alternative without package proof');
SELECT pg_temp.eq((SELECT r ->> 'comparability' FROM jsonb_array_elements(pg_temp.val('old_overview') -> 'rows') r
  WHERE r ->> 'productId' = pg_temp.pid('Protex')::text), 'missing_unit_of_measure', 'old overview: malformed unit shown as unit problem');
SELECT pg_temp.eq(pg_temp.keys(pg_temp.val('old_ammex')),
  ARRAY['coverage', 'currencyCode', 'historyLimit', 'organizationId', 'packageComparability', 'productId', 'productName', 'recentPurchases', 'summary', 'vendorHistory', 'vendorLimit'],
  'old detail keys');
SELECT pg_temp.eq(pg_temp.keys(pg_temp.val('old_ammex') -> 'summary'),
  ARRAY['absoluteChange', 'historicalHigh', 'historicalLow', 'latestPrice', 'latestPriceDate', 'observationCount', 'percentChange', 'previousPrice'], 'old detail summary keys');
SELECT pg_temp.eq(pg_temp.keys(pg_temp.val('old_ammex') -> 'recentPurchases' -> 0),
  ARRAY['currencyCode', 'invoiceId', 'invoiceItemId', 'invoiceNumber', 'observationId', 'packageDescription', 'packageEvidenceStatus', 'postedAt', 'provenanceType',
        'purchaseDate', 'purchasePrice', 'quantity', 'unitOfMeasure', 'vendorId', 'vendorName', 'vendorProductId', 'vendorSku'], 'old detail purchase keys');
SELECT pg_temp.eq(pg_temp.keys(pg_temp.val('old_ammex') -> 'vendorHistory' -> 0),
  ARRAY['historicalHigh', 'historicalLow', 'latestPrice', 'latestPriceDate', 'observationCount', 'previousPrice', 'vendorId', 'vendorName'], 'old detail vendor keys');
SELECT pg_temp.eq(pg_temp.keys(pg_temp.val('old_ammex') -> 'coverage'),
  ARRAY['excludedMissingPriceCount', 'excludedNonUsdCount', 'excludedUnknownCurrencyCount', 'includedUsdObservationCount', 'postedObservationCount'], 'old detail coverage keys');
SELECT pg_temp.eq(pg_temp.val('old_ammex') -> 'summary' -> 'previousPrice', 'null'::jsonb, 'old detail: previous price never crosses SKUs');
SELECT pg_temp.eq(pg_temp.val('old_ammex') -> 'summary' -> 'absoluteChange', 'null'::jsonb, 'old detail: no Ammex change');
SELECT pg_temp.eq(pg_temp.val('old_ammex') -> 'vendorHistory' -> 0 -> 'previousPrice', 'null'::jsonb, 'old detail vendor: no previous across SKUs');
SELECT pg_temp.eq((pg_temp.val('old_ammex') -> 'summary' ->> 'historicalLow')::numeric, 6.23, 'old detail low/high stay within the last purchase''s SKU');
SELECT pg_temp.eq((pg_temp.val('old_rising') -> 'summary' ->> 'previousPrice')::numeric, 11::numeric, 'old detail: same-SKU previous');
SELECT pg_temp.eq((pg_temp.val('old_rising') -> 'summary' ->> 'absoluteChange')::numeric, 1::numeric, 'old detail: same-SKU change');
SELECT pg_temp.eq((pg_temp.val('old_never') -> 'summary' ->> 'observationCount')::int, 0, 'old detail with no history');
SELECT pg_temp.eq(pg_temp.val('old_never') -> 'summary' -> 'latestPrice', 'null'::jsonb, 'old detail with no history: no price');

-- ---------------------------------------------------------------------------------------
-- Access. Owner and admin read; staff, removed members, non-members and anon are refused;
-- another organization's objects are not found; internal helpers are not callable.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION pg_temp.calls(_org text)
RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY[
    format('SELECT public.list_price_intelligence_products(%L)', _org),
    format('SELECT public.get_price_intelligence_summary(%L)', _org),
    format('SELECT public.get_product_vendor_price_history(%L, %L)', _org, (SELECT id FROM public.products WHERE name = 'P6B1 Clean Rising')),
    format('SELECT public.get_supply_request_price_context(%L, %L)', _org, '6b100000-0000-4000-8000-000000000701'),
    format('SELECT public.get_price_intelligence_overview(%L)', _org),
    format('SELECT public.get_product_price_intelligence(%L, %L)', _org, (SELECT id FROM public.products WHERE name = 'P6B1 Clean Rising'))]
$$;
CREATE TEMP TABLE phase6b1_calls ON COMMIT DROP AS SELECT unnest(pg_temp.calls('6b100000-0000-4000-8000-000000000101')) AS statement;
GRANT SELECT ON phase6b1_calls TO authenticated, anon;
DO $access$
DECLARE _call record; _user uuid; _result jsonb;
BEGIN
  SET LOCAL ROLE authenticated;
  FOREACH _user IN ARRAY ARRAY['6b100000-0000-4000-8000-000000000001', '6b100000-0000-4000-8000-000000000002']::uuid[] LOOP
    PERFORM pg_temp.as_user(_user);
    FOR _call IN SELECT statement FROM phase6b1_calls LOOP
      EXECUTE _call.statement INTO _result;
      IF _result IS NULL THEN RAISE EXCEPTION 'no result for % as %', _call.statement, _user; END IF;
    END LOOP;
  END LOOP;
  FOREACH _user IN ARRAY ARRAY['6b100000-0000-4000-8000-000000000003', '6b100000-0000-4000-8000-000000000005',
                               '6b100000-0000-4000-8000-000000000007', '6b100000-0000-4000-8000-000000000004']::uuid[] LOOP
    PERFORM pg_temp.as_user(_user);
    FOR _call IN SELECT statement FROM phase6b1_calls LOOP
      PERFORM pg_temp.expect_error(_call.statement, 'Forbidden', '42501');
    END LOOP;
  END LOOP;
  PERFORM pg_temp.as_user(NULL);
  FOR _call IN SELECT statement FROM phase6b1_calls LOOP
    PERFORM pg_temp.expect_error(_call.statement, 'Forbidden', '42501');
  END LOOP;
  RESET ROLE;
  SET LOCAL ROLE anon;
  FOR _call IN SELECT statement FROM phase6b1_calls LOOP
    PERFORM pg_temp.expect_error(_call.statement, 'permission denied', '42501');
  END LOOP;
  RESET ROLE;
END
$access$;

-- Another organization's objects through one's own organization: not found, never leaked.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('6b100000-0000-4000-8000-000000000004');
SELECT pg_temp.expect_error(format('SELECT public.get_product_vendor_price_history(%L, %L)', '6b100000-0000-4000-8000-000000000102', pg_temp.pid('Clean Rising')), 'Product not found', 'P0002');
SELECT pg_temp.expect_error(format('SELECT public.get_product_vendor_price_history(%L, NULL, %L)', '6b100000-0000-4000-8000-000000000102', '6b100000-0000-4000-8000-000000000601'), 'Product not found', 'P0002');
SELECT pg_temp.expect_error(format('SELECT public.get_supply_request_price_context(%L, %L)', '6b100000-0000-4000-8000-000000000102', '6b100000-0000-4000-8000-000000000701'), 'Request not found', 'P0002');
SELECT pg_temp.expect_error(format('SELECT public.get_product_price_intelligence(%L, %L)', '6b100000-0000-4000-8000-000000000102', pg_temp.pid('Clean Rising')), 'Product not found', 'P0002');
SELECT pg_temp.keep('b_summary', public.get_price_intelligence_summary('6b100000-0000-4000-8000-000000000102'));
SELECT pg_temp.keep('b_list', public.list_price_intelligence_products('6b100000-0000-4000-8000-000000000102'));
RESET ROLE;
SELECT pg_temp.eq((pg_temp.val('b_summary') ->> 'productCount')::int, 1, 'organization B sees only its own product');
SELECT pg_temp.eq(pg_temp.val('b_list') -> 'rows' -> 0 ->> 'productName', 'P6B1 Other Org Tape', 'organization B list');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('6b100000-0000-4000-8000-000000000001');
SELECT pg_temp.expect_error(format('SELECT public.get_product_vendor_price_history(%L, %L)', '6b100000-0000-4000-8000-000000000101', pg_temp.pid('Other Org Tape')), 'Product not found', 'P0002');
SELECT pg_temp.expect_error(format('SELECT public.get_product_vendor_price_history(%L, NULL, %L)', '6b100000-0000-4000-8000-000000000101', '6b100000-0000-4000-8000-000000000602'), 'Product not found', 'P0002');
SELECT pg_temp.expect_error(format('SELECT public.get_supply_request_price_context(%L, %L)', '6b100000-0000-4000-8000-000000000101', '6b100000-0000-4000-8000-000000000702'), 'Request not found', 'P0002');
-- Admins are told they cannot open the source document (the 7E boundary).
SELECT pg_temp.as_user('6b100000-0000-4000-8000-000000000002');
SELECT pg_temp.keep('admin_detail', public.get_product_vendor_price_history('6b100000-0000-4000-8000-000000000101', pg_temp.pid('Clean Rising')));
SELECT pg_temp.expect_error(format('SELECT public.get_financial_document_detail(%L, %L)', '6b100000-0000-4000-8000-000000000101',
  (SELECT invoice_id FROM public.inventory_price_history WHERE product_id = pg_temp.pid('Clean Rising') LIMIT 1)), 'owner access required', '42501');
RESET ROLE;
SELECT pg_temp.eq((pg_temp.val('admin_detail') ->> 'canOpenSourceDocument')::boolean, false, 'admins cannot open source documents');
SELECT pg_temp.eq((pg_temp.val('admin_detail') ->> 'viewerIsOwner')::boolean, false, 'admin is not the owner');
SELECT pg_temp.assert((pg_temp.val('admin_detail') -> 'observations' -> 0) ? 'documentNumber', 'admins still see the source line reference');

DO $helpers$
DECLARE _fn text;
BEGIN
  FOREACH _fn IN ARRAY ARRAY['public.price_unit_key(text)', 'public.price_unit_is_valid(text)', 'public.price_recency(date, date)',
    'public.price_catalog_unit_agrees(numeric, text, text)', 'public.price_package_agreement(text, text, text, uuid, uuid)',
    'public.price_observation_rows(uuid, uuid[])', 'public.price_observation_evidence(uuid, uuid, date)', 'public.price_row_is_valid(numeric, numeric, numeric, text)',
    'public.price_recent_anchors(uuid, uuid, date, timestamptz, uuid, integer)', 'public.price_name_anchors(uuid, uuid, text, uuid, integer)',
    'public.price_product_state(uuid, uuid[], date, boolean)'] LOOP
    IF has_function_privilege('authenticated', _fn, 'EXECUTE') OR has_function_privilege('anon', _fn, 'EXECUTE')
       OR has_function_privilege('service_role', _fn, 'EXECUTE') THEN
      RAISE EXCEPTION 'internal helper % is executable by a client role', _fn;
    END IF;
  END LOOP;
  FOREACH _fn IN ARRAY ARRAY['public.list_price_intelligence_products(uuid, text, text, uuid, jsonb, integer, integer)',
    'public.get_price_intelligence_summary(uuid)', 'public.get_product_vendor_price_history(uuid, uuid, uuid, jsonb, integer)',
    'public.get_supply_request_price_context(uuid, uuid)'] LOOP
    IF NOT has_function_privilege('authenticated', _fn, 'EXECUTE') OR has_function_privilege('anon', _fn, 'EXECUTE') THEN
      RAISE EXCEPTION 'client RPC % has the wrong grants', _fn;
    END IF;
    IF (SELECT provolatile FROM pg_proc WHERE oid = _fn::regprocedure) <> 's' THEN
      RAISE EXCEPTION '% must be STABLE (read-only)', _fn;
    END IF;
  END LOOP;
END
$helpers$;
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('6b100000-0000-4000-8000-000000000001');
SELECT pg_temp.expect_error('SELECT public.price_product_state(''6b100000-0000-4000-8000-000000000101'', NULL, current_date)', 'permission denied', '42501');
SELECT pg_temp.expect_error('SELECT * FROM public.price_observation_rows(''6b100000-0000-4000-8000-000000000101'', NULL)', 'permission denied', '42501');
RESET ROLE;

-- ---------------------------------------------------------------------------------------
-- Read-only: nothing changed.
-- ---------------------------------------------------------------------------------------
SELECT pg_temp.eq(pg_temp.state(), pg_temp.val('before'), 'no business row changed after every call');

-- Posted-document removal while history is read, and its cascade, run across real
-- transactions in supabase/tests/phase6b1_race_check.sh.

SELECT 'phase6b1_multi_vendor_behavior: all checks passed' AS result;
ROLLBACK;
