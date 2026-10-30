-- Fixture for tests/phase7b4-overview-integration.test.ts. Runs as postgres after every
-- migration, on a local disposable database only; this file commits its rows.
--
-- Organization A has 1200 items left in Unassigned (more than the API row cap), 1100 active
-- storage locations (the first 50 labelled, the first one counted), 20 archived locations
-- still carrying a label, and a few placed items. Organization B is a neighbour.
--   users: 001 owner A, 002 admin A, 003 staff A, 004 owner B, 005 admin B, 009 no membership.

INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('7b4c0000-0000-4000-8000-00000000000' || n)::uuid, 'authenticated', 'authenticated',
  'phase7b4-itest-' || n || '@example.invalid', '', now(), '{}',
  CASE n WHEN 1 THEN '{"full_name": "Integration Owner"}'::jsonb ELSE '{}'::jsonb END, now(), now()
FROM unnest(ARRAY[1, 2, 3, 4, 5, 9]) n;

INSERT INTO public.organizations (id, name, created_by) VALUES
  ('7b4c0000-0000-4000-8000-000000000101', 'Phase 7B.4 Integration A', '7b4c0000-0000-4000-8000-000000000001'),
  ('7b4c0000-0000-4000-8000-000000000102', 'Phase 7B.4 Integration B', '7b4c0000-0000-4000-8000-000000000004');

INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES
  ('7b4c0000-0000-4000-8000-000000000101', '7b4c0000-0000-4000-8000-000000000001', 'owner', true),
  ('7b4c0000-0000-4000-8000-000000000101', '7b4c0000-0000-4000-8000-000000000002', 'admin', true),
  ('7b4c0000-0000-4000-8000-000000000101', '7b4c0000-0000-4000-8000-000000000003', 'staff', true),
  ('7b4c0000-0000-4000-8000-000000000102', '7b4c0000-0000-4000-8000-000000000004', 'owner', true),
  ('7b4c0000-0000-4000-8000-000000000102', '7b4c0000-0000-4000-8000-000000000005', 'admin', true);

INSERT INTO public.inventory_items (organization_id, name, sku, unit, quantity, active)
SELECT '7b4c0000-0000-4000-8000-000000000101', 'Itest Item ' || lpad(n::text, 4, '0'), 'IT-' || n,
  CASE WHEN n % 2 = 0 THEN 'each' ELSE 'box' END, 2, true
FROM generate_series(1, 1203) n;
INSERT INTO public.inventory_items (organization_id, name, sku, unit, quantity, active)
VALUES ('7b4c0000-0000-4000-8000-000000000102', 'Itest Other Item', 'OT-1', 'each', 4, true);

CREATE FUNCTION pg_temp.count(_organization uuid, _location uuid, _key text)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.submit_inventory_count(_organization, _location, (
    SELECT jsonb_agg(jsonb_build_object(
        'inventoryItemId', item->>'inventoryItemId',
        'observedVersion', (item->>'version')::bigint,
        'countedQuantity', item->>'quantity'))
    FROM jsonb_array_elements(public.get_inventory_count_location(_organization, _location)->'items') item), _key)
$$;

DO $fixture$
DECLARE
  _org constant uuid := '7b4c0000-0000-4000-8000-000000000101';
  _unassigned uuid;
  _location uuid;
  _first uuid;
  _n integer;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '7b4c0000-0000-4000-8000-000000000001', true);
  SELECT id INTO _unassigned FROM public.inventory_locations WHERE organization_id = _org AND kind = 'unassigned';
  FOR _n IN 1 .. 1100 LOOP
    _location := public.create_inventory_location(_org, 'Itest Bay ' || lpad(_n::text, 4, '0'), NULL);
    IF _n = 1 THEN _first := _location; END IF;
    IF _n <= 50 THEN PERFORM public.issue_inventory_location_label(_org, _location); END IF;
  END LOOP;
  -- Three items go to Bay 0001 (which is then counted) and Bay 0002 (never counted).
  PERFORM public.move_inventory_stock(_org, item.id, _unassigned, _first, 2, 'itest-first-' || item.id)
  FROM public.inventory_items item WHERE item.organization_id = _org AND item.name = 'Itest Item 0001';
  PERFORM public.move_inventory_stock(_org, item.id, _unassigned,
    (SELECT id FROM public.inventory_locations WHERE organization_id = _org AND name = 'Itest Bay 0002'), 2, 'itest-second-' || item.id)
  FROM public.inventory_items item WHERE item.organization_id = _org AND item.name IN ('Itest Item 0002', 'Itest Item 0003');
  PERFORM pg_temp.count(_org, _first, 'itest-count');
  FOR _n IN 1 .. 20 LOOP
    _location := public.create_inventory_location(_org, 'Itest Old ' || lpad(_n::text, 2, '0'), NULL);
    PERFORM public.issue_inventory_location_label(_org, _location);
    PERFORM public.set_inventory_location_active(_org, _location, false);
  END LOOP;
END
$fixture$;
