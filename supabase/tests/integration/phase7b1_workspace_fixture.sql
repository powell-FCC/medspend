-- Fixture for tests/phase7b1-workspace-integration.test.ts. Runs as postgres after every
-- migration, on a local disposable database only; this file commits its rows.
--
-- Organization A is larger than the API row cap (1000): 1100 items, 2250+ balance rows,
-- 1100 items at one storage location and 200+ locations. Organization B is a neighbour
-- whose rows must never appear in A's answers.
--   users: 001 owner A, 002 admin A, 003 staff A, 004 owner B, 005 admin B,
--          009 signed in but a member of nothing.

INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('7b1c0000-0000-4000-8000-00000000000' || n)::uuid, 'authenticated', 'authenticated',
  'phase7b1-itest-' || n || '@example.invalid', '', now(), '{}',
  CASE WHEN n = 3 THEN '{"full_name": "Integration Staff"}'::jsonb ELSE '{}'::jsonb END, now(), now()
FROM unnest(ARRAY[1, 2, 3, 4, 5, 9]) n;

INSERT INTO public.organizations (id, name, created_by) VALUES
  ('7b1c0000-0000-4000-8000-000000000101', 'Phase 7B.1 Integration A', '7b1c0000-0000-4000-8000-000000000001'),
  ('7b1c0000-0000-4000-8000-000000000102', 'Phase 7B.1 Integration B', '7b1c0000-0000-4000-8000-000000000004');

INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES
  ('7b1c0000-0000-4000-8000-000000000101', '7b1c0000-0000-4000-8000-000000000001', 'owner', true),
  ('7b1c0000-0000-4000-8000-000000000101', '7b1c0000-0000-4000-8000-000000000002', 'admin', true),
  ('7b1c0000-0000-4000-8000-000000000101', '7b1c0000-0000-4000-8000-000000000003', 'staff', true),
  ('7b1c0000-0000-4000-8000-000000000102', '7b1c0000-0000-4000-8000-000000000004', 'owner', true),
  ('7b1c0000-0000-4000-8000-000000000102', '7b1c0000-0000-4000-8000-000000000005', 'admin', true);

-- 1100 items in A, each with 10 units in Unassigned (inserted as postgres; the seeding
-- trigger creates the Unassigned balance). Every 7th item has a par it is below.
INSERT INTO public.inventory_items (organization_id, name, sku, unit, quantity, par_level,
  vendor_name, last_purchase_price, last_purchase_date, active)
SELECT '7b1c0000-0000-4000-8000-000000000101', format('Item %s', lpad(n::text, 4, '0')), format('SKU-%s', n),
  'each', 10, CASE WHEN n % 7 = 0 THEN 50 END, 'Hidden Vendor', 12.34, '2026-10-01', true
FROM generate_series(1, 1100) n;
INSERT INTO public.inventory_items (organization_id, name, sku, unit, quantity, last_purchase_price, active)
VALUES ('7b1c0000-0000-4000-8000-000000000102', 'Other Org Item', 'SKU-B', 'each', 5, 1.11, true);

DO $fixture$
DECLARE
  _org uuid := '7b1c0000-0000-4000-8000-000000000101';
  _unassigned uuid;
  _bulk uuid;
  _side uuid;
  _item record;
  _n integer := 0;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '7b1c0000-0000-4000-8000-000000000001', true);
  SELECT id INTO _unassigned FROM public.inventory_locations WHERE organization_id = _org AND kind = 'unassigned';
  _bulk := public.create_inventory_location(_org, 'Bulk Cabinet');
  _side := public.create_inventory_location(_org, 'Side Cart');
  PERFORM public.create_inventory_location(_org, 'Forced Failure Cabinet');
  PERFORM public.create_inventory_location(_org, 'Retired Closet');
  FOR _n IN 1..205 LOOP
    PERFORM public.create_inventory_location(_org, format('Empty Shelf %s', lpad(_n::text, 3, '0')));
  END LOOP;
  PERFORM public.set_inventory_location_active(_org,
    (SELECT id FROM public.inventory_locations WHERE organization_id = _org AND name = 'Retired Closet'), false);

  _n := 0;
  FOR _item IN SELECT id FROM public.inventory_items WHERE organization_id = _org ORDER BY name LOOP
    _n := _n + 1;
    -- Every third item moves entirely to the bulk cabinet; the rest leave 6 in Unassigned.
    PERFORM public.move_inventory_stock(_org, _item.id, _unassigned, _bulk,
      CASE WHEN _n % 3 = 0 THEN 10 ELSE 4 END, format('fx-bulk-%s', _n));
    IF _n <= 50 AND _n % 3 <> 0 THEN
      PERFORM public.move_inventory_stock(_org, _item.id, _unassigned, _side, 1, format('fx-side-%s', _n));
    END IF;
  END LOOP;

  PERFORM set_config('request.jwt.claim.sub', '7b1c0000-0000-4000-8000-000000000004', true);
  PERFORM public.create_inventory_location('7b1c0000-0000-4000-8000-000000000102', 'Other Org Cabinet');
END
$fixture$;
