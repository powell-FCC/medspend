-- Fixture for tests/phase7b3-activity-integration.test.ts. Runs as postgres after every
-- migration, on a local disposable database only; this file commits its rows.
--
-- Organization A has real moves and manual adjustments (some by an owner who later leaves),
-- a real physical count at Training Room (writing physical_count adjustments), and 1200
-- historical transfers plus 1200 historical manual adjustments interleaved with 600 invoice
-- receipts, so each history is larger than the API row cap (1000). Organization B is a
-- neighbour whose rows must never appear in A's answers.
--   users: 001 owner A, 002 admin A, 003 staff A, 006 owner A (removed afterwards),
--          004 owner B, 005 admin B, 009 signed in but a member of nothing.

INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('7b3c0000-0000-4000-8000-00000000000' || n)::uuid, 'authenticated', 'authenticated',
  'phase7b3-itest-' || n || '@example.invalid', '', now(), '{}',
  CASE n WHEN 1 THEN '{"full_name": "Integration Owner"}'::jsonb
         WHEN 2 THEN '{"full_name": "Integration Admin"}'::jsonb
         WHEN 3 THEN '{"full_name": "Integration Staff"}'::jsonb
         WHEN 6 THEN '{"full_name": "Integration Former"}'::jsonb
         ELSE '{}'::jsonb END, now(), now()
FROM unnest(ARRAY[1, 2, 3, 4, 5, 6, 9]) n;

INSERT INTO public.organizations (id, name, created_by) VALUES
  ('7b3c0000-0000-4000-8000-000000000101', 'Phase 7B.3 Integration A', '7b3c0000-0000-4000-8000-000000000001'),
  ('7b3c0000-0000-4000-8000-000000000102', 'Phase 7B.3 Integration B', '7b3c0000-0000-4000-8000-000000000004');

INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES
  ('7b3c0000-0000-4000-8000-000000000101', '7b3c0000-0000-4000-8000-000000000001', 'owner', true),
  ('7b3c0000-0000-4000-8000-000000000101', '7b3c0000-0000-4000-8000-000000000002', 'admin', true),
  ('7b3c0000-0000-4000-8000-000000000101', '7b3c0000-0000-4000-8000-000000000003', 'staff', true),
  ('7b3c0000-0000-4000-8000-000000000101', '7b3c0000-0000-4000-8000-000000000006', 'owner', true),
  ('7b3c0000-0000-4000-8000-000000000102', '7b3c0000-0000-4000-8000-000000000004', 'owner', true),
  ('7b3c0000-0000-4000-8000-000000000102', '7b3c0000-0000-4000-8000-000000000005', 'admin', true);

INSERT INTO public.inventory_items (id, organization_id, sku, name, unit, quantity, last_purchase_price, active) VALUES
  ('7b3c0000-0000-4000-8000-000000000501', '7b3c0000-0000-4000-8000-000000000101', 'WRAP-4', 'Itest Elastic Wrap', 'each', 30, 4.56, true),
  ('7b3c0000-0000-4000-8000-000000000502', '7b3c0000-0000-4000-8000-000000000101', 'TAPE-1', 'Itest Tape', 'roll', 12, NULL, true),
  ('7b3c0000-0000-4000-8000-000000000511', '7b3c0000-0000-4000-8000-000000000102', 'TAPE-1', 'Itest Other Tape', 'roll', 10, NULL, true);

CREATE FUNCTION pg_temp.count(_organization uuid, _location uuid, _overrides jsonb, _key text)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.submit_inventory_count(_organization, _location, (
    SELECT jsonb_agg(jsonb_build_object(
        'inventoryItemId', item->>'inventoryItemId',
        'observedVersion', (item->>'version')::bigint,
        'countedQuantity', coalesce(_overrides->>(item->>'inventoryItemId'), item->>'quantity')))
    FROM jsonb_array_elements(public.get_inventory_count_location(_organization, _location)->'items') item), _key)
$$;

DO $fixture$
DECLARE
  _org constant uuid := '7b3c0000-0000-4000-8000-000000000101';
  _training uuid;
  _stadium uuid;
  _unassigned uuid;
  _other uuid;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '7b3c0000-0000-4000-8000-000000000001', true);
  _training := public.create_inventory_location(_org, 'Training Room');
  _stadium := public.create_inventory_location(_org, 'Stadium');
  SELECT id INTO _unassigned FROM public.inventory_locations WHERE organization_id = _org AND kind = 'unassigned';
  PERFORM public.move_inventory_stock(_org, '7b3c0000-0000-4000-8000-000000000501', _unassigned, _training, 24, 'itest-wrap-in');
  PERFORM public.move_inventory_stock(_org, '7b3c0000-0000-4000-8000-000000000501', _training, _stadium, 6, 'itest-wrap-out');
  PERFORM public.adjust_inventory_location_quantity(_org, '7b3c0000-0000-4000-8000-000000000501', _training, -3, 'Damaged');

  PERFORM set_config('request.jwt.claim.sub', '7b3c0000-0000-4000-8000-000000000006', true);
  PERFORM public.move_inventory_stock(_org, '7b3c0000-0000-4000-8000-000000000502', _unassigned, _stadium, 4, 'itest-tape');
  PERFORM public.adjust_inventory_location_quantity(_org, '7b3c0000-0000-4000-8000-000000000502', _stadium, 2, 'Correction');

  -- Staff count Training: Wrap 15 -> 13. A count correction, never a manual adjustment.
  PERFORM set_config('request.jwt.claim.sub', '7b3c0000-0000-4000-8000-000000000003', true);
  PERFORM pg_temp.count(_org, _training, '{"7b3c0000-0000-4000-8000-000000000501": "13"}', 'itest-count');

  PERFORM set_config('request.jwt.claim.sub', '7b3c0000-0000-4000-8000-000000000004', true);
  _other := public.create_inventory_location('7b3c0000-0000-4000-8000-000000000102', 'Other Cabinet');
  PERFORM public.move_inventory_stock('7b3c0000-0000-4000-8000-000000000102', '7b3c0000-0000-4000-8000-000000000511',
    (SELECT id FROM public.inventory_locations WHERE organization_id = '7b3c0000-0000-4000-8000-000000000102' AND kind = 'unassigned'),
    _other, 10, 'itest-other');
  PERFORM public.adjust_inventory_location_quantity('7b3c0000-0000-4000-8000-000000000102',
    '7b3c0000-0000-4000-8000-000000000511', _other, -1, 'Damaged');

  -- 1200 historical transfers and 1200 manual adjustments, an hour apart from 2025-01-01;
  -- rows 600/601 share a timestamp. Odd rows go Stadium -> Training, even Training -> Stadium.
  -- Receipts every other hour must never appear in the adjustment history.
  INSERT INTO public.inventory_transfers (id, organization_id, inventory_item_id, from_inventory_location_id,
    to_inventory_location_id, quantity, idempotency_key, created_by, created_at)
  SELECT ('7b3c0000-0000-4000-8000-0000000a' || lpad(n::text, 4, '0'))::uuid, _org,
    CASE WHEN n % 3 = 0 THEN '7b3c0000-0000-4000-8000-000000000502'::uuid ELSE '7b3c0000-0000-4000-8000-000000000501'::uuid END,
    CASE WHEN n % 2 = 0 THEN _training ELSE _stadium END, CASE WHEN n % 2 = 0 THEN _stadium ELSE _training END,
    1 + n % 3, 'itest-hist-' || n,
    CASE WHEN n % 4 = 0 THEN '7b3c0000-0000-4000-8000-000000000006'::uuid ELSE '7b3c0000-0000-4000-8000-000000000001'::uuid END,
    timestamptz '2025-01-01 00:00:00+00' + (CASE WHEN n = 601 THEN 599 ELSE n - 1 END) * interval '1 hour'
  FROM generate_series(1, 1200) n;
  INSERT INTO public.inventory_adjustments (id, organization_id, inventory_item_id, inventory_location_id,
    adjustment_amount, previous_quantity, new_quantity, reason, created_by, created_at, source_type)
  SELECT ('7b3c0000-0000-4000-8000-0000000b' || lpad(n::text, 4, '0'))::uuid, _org,
    CASE WHEN n % 3 = 0 THEN '7b3c0000-0000-4000-8000-000000000502'::uuid ELSE '7b3c0000-0000-4000-8000-000000000501'::uuid END,
    CASE WHEN n % 2 = 0 THEN _training ELSE _stadium END,
    CASE WHEN n % 5 = 0 THEN 0 WHEN n % 2 = 0 THEN -1 ELSE 2 END, 20,
    CASE WHEN n % 5 = 0 THEN 20 WHEN n % 2 = 0 THEN 19 ELSE 22 END,
    (ARRAY['Manual adjustment', 'Damaged', 'Expired', 'Correction'])[1 + n % 4],
    CASE WHEN n % 4 = 0 THEN '7b3c0000-0000-4000-8000-000000000006'::uuid ELSE '7b3c0000-0000-4000-8000-000000000001'::uuid END,
    timestamptz '2025-01-01 00:00:00+00' + (CASE WHEN n = 601 THEN 599 ELSE n - 1 END) * interval '1 hour', 'manual'
  FROM generate_series(1, 1200) n;
  INSERT INTO public.inventory_adjustments (organization_id, inventory_item_id, inventory_location_id,
    adjustment_amount, previous_quantity, new_quantity, reason, created_by, created_at, source_type)
  SELECT _org, '7b3c0000-0000-4000-8000-000000000502', _unassigned, 1, 20, 21, 'Invoice received',
    '7b3c0000-0000-4000-8000-000000000001', timestamptz '2025-01-01 00:30:00+00' + (2 * n) * interval '1 hour', 'invoice'
  FROM generate_series(0, 599) n;
END
$fixture$;

DELETE FROM public.organization_memberships
WHERE organization_id = '7b3c0000-0000-4000-8000-000000000101' AND user_id = '7b3c0000-0000-4000-8000-000000000006';
