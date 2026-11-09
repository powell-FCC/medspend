-- Fixture for tests/phase5a10-discovery-integration.test.ts. Runs as postgres after every
-- migration, on a local disposable database only; this file commits its rows.
--
--   users: 001 owner A, 002 admin A, 003 staff A, 004 staff A and staff B, 005 owner B,
--          007 former staff A (inactive membership), 009 signed in but a member of nothing.
--
-- A small, hand-checked catalog (vendor "Fixture Medical") with organization history, then a
-- synthetic catalog of 100,000 catalog vendor products across four more vendors for scale,
-- plus 3,000 approved and 600 denied organization A requests and 400 posted invoices.

INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('5a10c000-0000-4000-8000-000000000' || lpad(n::text, 3, '0'))::uuid, 'authenticated', 'authenticated',
  'phase5a10-itest-' || n || '@example.invalid', '', now(), '{}', '{}', now(), now()
FROM unnest(ARRAY[1, 2, 3, 4, 5, 7, 9]) n;

INSERT INTO public.organizations (id, name, created_by) VALUES
  ('5a10c000-0000-4000-8000-000000000101', 'Phase 5A.10 Integration A', '5a10c000-0000-4000-8000-000000000001'),
  ('5a10c000-0000-4000-8000-000000000102', 'Phase 5A.10 Integration B', '5a10c000-0000-4000-8000-000000000005');
INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES
  ('5a10c000-0000-4000-8000-000000000101', '5a10c000-0000-4000-8000-000000000001', 'owner', true),
  ('5a10c000-0000-4000-8000-000000000101', '5a10c000-0000-4000-8000-000000000002', 'admin', true),
  ('5a10c000-0000-4000-8000-000000000101', '5a10c000-0000-4000-8000-000000000003', 'staff', true),
  ('5a10c000-0000-4000-8000-000000000101', '5a10c000-0000-4000-8000-000000000004', 'staff', true),
  ('5a10c000-0000-4000-8000-000000000102', '5a10c000-0000-4000-8000-000000000004', 'staff', true),
  ('5a10c000-0000-4000-8000-000000000102', '5a10c000-0000-4000-8000-000000000005', 'owner', true),
  ('5a10c000-0000-4000-8000-000000000101', '5a10c000-0000-4000-8000-000000000007', 'staff', false);

-- Hand-checked catalog.
INSERT INTO public.catalog_vendors (id, name, normalized_name, active)
VALUES ('5a10c000-0000-4000-8000-000000000201', 'Fixture Medical', 'fixture medical', true);
INSERT INTO public.catalog_products (id, name, normalized_name, description, manufacturer, active, verification_status) VALUES
  ('5a10c000-0000-4000-8000-000000000301', 'Fixture Athletic Tape', 'x', '2" x 15 yd', 'Fixture Mfg', true, 'verified'),
  ('5a10c000-0000-4000-8000-000000000302', 'Fixture Athletic Tape', 'x', '3" x 15 yd', 'Fixture Mfg', true, 'verified'),
  ('5a10c000-0000-4000-8000-000000000303', 'Fixture Athletic Tape', 'x', '1/2" x 10 yd', 'Fixture Mfg', true, 'verified'),
  ('5a10c000-0000-4000-8000-000000000304', 'Fixture Tape Athletic Bulk Pack', 'x', NULL, 'Fixture Mfg', true, 'verified');
INSERT INTO public.catalog_vendor_products (id, catalog_product_id, catalog_vendor_id, vendor_sku,
  normalized_vendor_sku, package_quantity, package_unit, package_status, active, discontinued, verification_status) VALUES
  ('5a10c000-0000-4000-8000-000000000401', '5a10c000-0000-4000-8000-000000000301', '5a10c000-0000-4000-8000-000000000201', 'FX-2000', 'x', 24, 'roll', 'verified', true, false, 'verified'),
  ('5a10c000-0000-4000-8000-000000000402', '5a10c000-0000-4000-8000-000000000302', '5a10c000-0000-4000-8000-000000000201', 'FX-3000', 'x', 16, 'roll', 'verified', true, false, 'verified'),
  ('5a10c000-0000-4000-8000-000000000403', '5a10c000-0000-4000-8000-000000000303', '5a10c000-0000-4000-8000-000000000201', 'FX-0500', 'x', 48, 'roll', 'verified', true, false, 'verified'),
  ('5a10c000-0000-4000-8000-000000000404', '5a10c000-0000-4000-8000-000000000304', '5a10c000-0000-4000-8000-000000000201', 'FX-BULK', 'x', NULL, NULL, 'unknown', true, false, 'verified');
INSERT INTO public.products (id, organization_id, name, description, active, staff_requestable) VALUES
  ('5a10c000-0000-4000-8000-000000000501', '5a10c000-0000-4000-8000-000000000101', 'Fixture Ice Bag', 'Large', true, true),
  ('5a10c000-0000-4000-8000-000000000511', '5a10c000-0000-4000-8000-000000000102', 'Fixture Ice Bag', 'Organization B', true, true);

-- History on the hand-checked catalog: 404 (Bulk Pack) approved 6 times, 402 approved twice,
-- 401 denied 5 times; organization B approved 401 five times.
INSERT INTO public.supply_requests (id, organization_id, requested_by, request_type, status, created_at)
SELECT ('5a10c000-0000-4000-8000-0000000007' || lpad(n::text, 2, '0'))::uuid,
  CASE WHEN n >= 40 THEN '5a10c000-0000-4000-8000-000000000102' ELSE '5a10c000-0000-4000-8000-000000000101' END::uuid,
  CASE WHEN n >= 40 THEN '5a10c000-0000-4000-8000-000000000005' ELSE '5a10c000-0000-4000-8000-000000000004' END::uuid,
  'reorder',
  (CASE WHEN n BETWEEN 20 AND 24 THEN 'denied' ELSE 'approved' END)::public.supply_request_status,
  now() - (n || ' days')::interval
FROM unnest(ARRAY[1, 2, 3, 4, 5, 6, 11, 12, 20, 21, 22, 23, 24, 40, 41, 42, 43, 44]) n;
INSERT INTO public.supply_request_items (organization_id, supply_request_id, catalog_vendor_product_id, quantity)
SELECT request.organization_id, request.id,
  CASE
    WHEN request.id::text ~ '0000000007(0[1-6])$' THEN '5a10c000-0000-4000-8000-000000000404'
    WHEN request.id::text ~ '0000000007(11|12)$' THEN '5a10c000-0000-4000-8000-000000000402'
    ELSE '5a10c000-0000-4000-8000-000000000401'
  END::uuid, 1
FROM public.supply_requests request
WHERE request.id::text LIKE '5a10c000-0000-4000-8000-0000000007%';
INSERT INTO public.invoices (id, organization_id, invoice_number, invoice_date, posted_at, processing_status, document_type) VALUES
  ('5a10c000-0000-4000-8000-000000000801', '5a10c000-0000-4000-8000-000000000101', 'A-1', current_date - 3, now() - interval '2 days', 'completed', 'INVOICE'),
  ('5a10c000-0000-4000-8000-000000000811', '5a10c000-0000-4000-8000-000000000102', 'B-1', current_date - 3, now() - interval '2 days', 'completed', 'INVOICE');
INSERT INTO public.invoice_items (invoice_id, organization_id, description, quantity, product_id) VALUES
  ('5a10c000-0000-4000-8000-000000000801', '5a10c000-0000-4000-8000-000000000101', 'Ice bag', 2, '5a10c000-0000-4000-8000-000000000501'),
  ('5a10c000-0000-4000-8000-000000000811', '5a10c000-0000-4000-8000-000000000102', 'Ice bag B', 2, '5a10c000-0000-4000-8000-000000000511');

-- Synthetic scale catalog: 100,000 products, one catalog vendor product each, four vendors,
-- realistic multi-word names with size and color variants. One INSERT statement per table,
-- so the statement trigger builds every search document once.
INSERT INTO public.catalog_vendors (id, name, normalized_name, active)
SELECT ('5a10c000-0000-4000-8000-0000000002' || lpad(v::text, 2, '0'))::uuid,
  (ARRAY['Summit Sports Supply', 'Northline Medical', 'Peak Athletic Health', 'Harbor Clinical'])[v - 1],
  'x' || v, true
FROM generate_series(2, 5) v;

INSERT INTO public.catalog_products (id, name, normalized_name, description, manufacturer, active, verification_status)
SELECT
  ('5a10c001-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
  (ARRAY['Pro', 'Elite', 'Classic', 'Ultra', 'Team', 'Clinic', 'Trainer', 'Field', 'Premium', 'Basic',
         'Flex', 'Sport', 'Active', 'Core', 'Max', 'Prime', 'Endura', 'Swift', 'Guard', 'Shield',
         'Victory', 'Champion', 'Rapid', 'Steady', 'Comfort', 'Secure', 'Vital', 'Motion', 'Recover', 'Strong',
         'Legacy', 'Summit', 'Apex', 'Fusion', 'Pulse', 'Stride', 'Anchor'])[1 + n % 37]
  || ' ' ||
  (ARRAY['Athletic Tape', 'Elastic Bandage', 'Nitrile Exam Gloves', 'Cold Pack', 'Gauze Sponge',
         'Prewrap', 'Heel Cup', 'Ankle Brace', 'Kinesiology Tape', 'Alcohol Prep Pad',
         'Adhesive Bandage', 'Foam Padding', 'Knee Sleeve', 'Wrist Support', 'Ice Bag',
         'Hydrocolloid Blister Pad', 'Trauma Shears', 'Cotton Tipped Applicator', 'Exam Table Paper', 'Face Mask',
         'Compression Sleeve', 'Moleskin', 'Splint', 'Sling', 'Thermometer Cover',
         'Antiseptic Wipe', 'Tongue Depressor', 'Cohesive Wrap', 'Underwrap', 'Skin Lubricant',
         'Electrode Pad', 'Massage Lotion', 'Finger Splint', 'Nasal Plug', 'Eye Pad',
         'Burn Gel', 'Hot Pack', 'Lacrosse Ball', 'Resistance Band', 'Foam Roller'])[1 + (n / 37) % 40] AS name,
  'x',
  (ARRAY['1"', '1.5"', '2"', '3"', '4"', '6"', 'Small', 'Medium', 'Large', 'X-Large',
         '1/2"', '3/4"', '10 yd', '15 yd', '5 yd', '4" x 4"', '2" x 2"', '25 mm', '50 mm', 'One Size',
         'Youth', 'Adult', 'Bulk'])[1 + n % 23]
  || ', ' ||
  (ARRAY['White', 'Black', 'Beige', 'Blue', 'Red', 'Green', 'Pink', 'Tan', 'Clear', 'Navy', 'Grey'])[1 + (n / 23) % 11],
  (ARRAY['Acme Health', 'Rivera Labs', 'Brightline', 'Kestrel Medical', 'Oakmont', 'Delta Care', 'Hanover', 'Sterling'])[1 + n % 8],
  true, 'verified'
FROM generate_series(1, 100000) n;

INSERT INTO public.catalog_vendor_products (id, catalog_product_id, catalog_vendor_id, vendor_sku, normalized_vendor_sku,
  manufacturer_sku, package_quantity, package_unit, package_status, active, discontinued, verification_status)
SELECT
  ('5a10c002-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
  ('5a10c001-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
  ('5a10c000-0000-4000-8000-0000000002' || lpad((2 + n % 4)::text, 2, '0'))::uuid,
  (ARRAY['SS', 'NL', 'PA', 'HC'])[1 + n % 4] || '-' || lpad(n::text, 6, '0'),
  'x',
  CASE WHEN n % 3 = 0 THEN 'M' || lpad((n * 7)::text, 8, '0') END,
  (ARRAY[1, 6, 12, 24, 48, 100])[1 + n % 6], (ARRAY['each', 'roll', 'box', 'case', 'pair', 'pack'])[1 + n % 6],
  'verified', n % 50 <> 0, n % 50 = 0, 'verified'
FROM generate_series(1, 100000) n;

-- Organization A scale history: 3,000 approved requests (three lines each) and 600 denied
-- requests on the synthetic catalog, and 400 posted invoices.
INSERT INTO public.products (id, organization_id, name, active, staff_requestable)
SELECT ('5a10c003-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, '5a10c000-0000-4000-8000-000000000101',
  'Scale Product ' || n, true, true
FROM generate_series(1, 400) n;
INSERT INTO public.supply_requests (id, organization_id, requested_by, request_type, status, created_at)
SELECT ('5a10c004-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, '5a10c000-0000-4000-8000-000000000101',
  '5a10c000-0000-4000-8000-000000000004', 'reorder',
  (CASE WHEN n > 3000 THEN 'denied' ELSE 'completed' END)::public.supply_request_status,
  now() - ((n % 365) || ' days')::interval
FROM generate_series(1, 3600) n;
INSERT INTO public.supply_request_items (organization_id, supply_request_id, catalog_vendor_product_id, quantity)
SELECT '5a10c000-0000-4000-8000-000000000101', ('5a10c004-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
  ('5a10c002-0000-4000-8000-' || lpad((1 + ((n * 37 + line * 1009) % 2000) * 50 + line)::text, 12, '0'))::uuid, 1
FROM generate_series(1, 3600) n, generate_series(1, 3) line;
INSERT INTO public.invoices (id, organization_id, invoice_number, invoice_date, posted_at, processing_status, document_type)
SELECT ('5a10c005-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, '5a10c000-0000-4000-8000-000000000101',
  'S-' || n, current_date - (n % 200), now() - ((n % 200) || ' days')::interval, 'completed', 'INVOICE'
FROM generate_series(1, 400) n;
INSERT INTO public.invoice_items (invoice_id, organization_id, description, quantity, product_id)
SELECT ('5a10c005-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, '5a10c000-0000-4000-8000-000000000101',
  'Scale line', 1, ('5a10c003-0000-4000-8000-' || lpad((1 + (n * 13 + line) % 400)::text, 12, '0'))::uuid
FROM generate_series(1, 400) n, generate_series(1, 2) line;

-- Staff 003 has 40 Saved Items on the synthetic catalog (the saved-boost plan).
INSERT INTO public.staff_saved_products (organization_id, user_id, catalog_vendor_product_id)
SELECT '5a10c000-0000-4000-8000-000000000101', '5a10c000-0000-4000-8000-000000000003',
  ('5a10c002-0000-4000-8000-' || lpad((n * 2477 % 99000 + 1)::text, 12, '0'))::uuid
FROM generate_series(1, 40) n
WHERE (n * 2477 % 99000 + 1) % 50 <> 0;

ANALYZE;
