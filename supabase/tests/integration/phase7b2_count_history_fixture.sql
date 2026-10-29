-- Fixture for tests/phase7b2-count-history-integration.test.ts. Runs as postgres after every
-- migration, on a local disposable database only; this file commits its rows.
--
-- Organization A has real counts submitted through submit_inventory_count (mixed units, an
-- all-matched count, a count by a member who later leaves, and a 1000-line count), plus 1200
-- historical sessions at an archived closet, so the history is larger than the API row cap
-- (1000). Organization B is a neighbour whose rows must never appear in A's answers.
--   users: 001 owner A, 002 admin A, 003 staff A, 006 staff A (removed after counting),
--          004 owner B, 005 admin B, 009 signed in but a member of nothing.

INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('7b2c0000-0000-4000-8000-00000000000' || n)::uuid, 'authenticated', 'authenticated',
  'phase7b2-itest-' || n || '@example.invalid', '', now(), '{}',
  CASE n WHEN 1 THEN '{"full_name": "Integration Owner"}'::jsonb
         WHEN 3 THEN '{"full_name": "Integration Staff"}'::jsonb
         WHEN 6 THEN '{"full_name": "Integration Former"}'::jsonb
         ELSE '{}'::jsonb END, now(), now()
FROM unnest(ARRAY[1, 2, 3, 4, 5, 6, 9]) n;

INSERT INTO public.organizations (id, name, created_by) VALUES
  ('7b2c0000-0000-4000-8000-000000000101', 'Phase 7B.2 Integration A', '7b2c0000-0000-4000-8000-000000000001'),
  ('7b2c0000-0000-4000-8000-000000000102', 'Phase 7B.2 Integration B', '7b2c0000-0000-4000-8000-000000000004');

INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES
  ('7b2c0000-0000-4000-8000-000000000101', '7b2c0000-0000-4000-8000-000000000001', 'owner', true),
  ('7b2c0000-0000-4000-8000-000000000101', '7b2c0000-0000-4000-8000-000000000002', 'admin', true),
  ('7b2c0000-0000-4000-8000-000000000101', '7b2c0000-0000-4000-8000-000000000003', 'staff', true),
  ('7b2c0000-0000-4000-8000-000000000101', '7b2c0000-0000-4000-8000-000000000006', 'staff', true),
  ('7b2c0000-0000-4000-8000-000000000102', '7b2c0000-0000-4000-8000-000000000004', 'owner', true),
  ('7b2c0000-0000-4000-8000-000000000102', '7b2c0000-0000-4000-8000-000000000005', 'admin', true);

INSERT INTO public.inventory_items (id, organization_id, sku, name, unit, quantity, last_purchase_price, active) VALUES
  ('7b2c0000-0000-4000-8000-000000000501', '7b2c0000-0000-4000-8000-000000000101', 'TAPE-1', 'Itest Tape', 'roll', 8, 9.87, true),
  ('7b2c0000-0000-4000-8000-000000000502', '7b2c0000-0000-4000-8000-000000000101', 'GAUZE-1', 'Itest Gauze', 'box', 4, NULL, true),
  ('7b2c0000-0000-4000-8000-000000000503', '7b2c0000-0000-4000-8000-000000000101', NULL, 'Itest Wrap', 'each', 6, NULL, true),
  ('7b2c0000-0000-4000-8000-000000000504', '7b2c0000-0000-4000-8000-000000000101', 'SAL-1', 'Itest Saline', 'bottle', 2.5, NULL, true),
  ('7b2c0000-0000-4000-8000-000000000505', '7b2c0000-0000-4000-8000-000000000101', 'KIT-1', 'Itest Archived Kit', 'each', 3, NULL, true),
  ('7b2c0000-0000-4000-8000-000000000506', '7b2c0000-0000-4000-8000-000000000101', 'PRE-1', 'Itest Prewrap', 'each', 5, NULL, true),
  ('7b2c0000-0000-4000-8000-000000000511', '7b2c0000-0000-4000-8000-000000000102', 'TAPE-1', 'Itest Other Tape', 'roll', 10, NULL, true);
INSERT INTO public.inventory_items (organization_id, name, sku, unit, quantity, active)
SELECT '7b2c0000-0000-4000-8000-000000000101', 'Itest Bulk ' || lpad(n::text, 4, '0'), 'BULK-' || n, 'each', 1, true
FROM generate_series(1, 1000) n;

-- A complete count of a location as the current user, overriding quantities by item id.
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
  _org constant uuid := '7b2c0000-0000-4000-8000-000000000101';
  _cabinet uuid;
  _rehab uuid;
  _bulk uuid;
  _closet uuid;
  _other uuid;
  _unassigned uuid;
  _item record;
  _bulk_overrides jsonb;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '7b2c0000-0000-4000-8000-000000000001', true);
  _cabinet := public.create_inventory_location(_org, 'Cabinet');
  _rehab := public.create_inventory_location(_org, 'Rehab');
  _bulk := public.create_inventory_location(_org, 'Bulk Shelf');
  _closet := public.create_inventory_location(_org, 'History Closet');
  SELECT id INTO _unassigned FROM public.inventory_locations WHERE organization_id = _org AND kind = 'unassigned';
  PERFORM public.move_inventory_stock(_org, ('7b2c0000-0000-4000-8000-00000000050' || n)::uuid, _unassigned, _cabinet, q, 'fx-' || n)
  FROM (VALUES (1, 6::numeric), (2, 4), (3, 6), (4, 2.5), (5, 3), (6, 5)) AS stock(n, q);
  PERFORM public.move_inventory_stock(_org, '7b2c0000-0000-4000-8000-000000000501', _unassigned, _rehab, 2, 'fx-rehab');
  FOR _item IN SELECT id FROM public.inventory_items WHERE organization_id = _org AND name LIKE 'Itest Bulk %' ORDER BY name LOOP
    PERFORM public.move_inventory_stock(_org, _item.id, _unassigned, _bulk, 1, 'fx-bulk-' || _item.id);
  END LOOP;

  PERFORM set_config('request.jwt.claim.sub', '7b2c0000-0000-4000-8000-000000000003', true);
  PERFORM pg_temp.count(_org, _cabinet,
    '{"7b2c0000-0000-4000-8000-000000000501": "4", "7b2c0000-0000-4000-8000-000000000502": "5",
      "7b2c0000-0000-4000-8000-000000000503": "3", "7b2c0000-0000-4000-8000-000000000506": "9",
      "7b2c0000-0000-4000-8000-000000000504": "2.25"}', 'itest-mixed');
  -- Every tenth bulk item was not on the shelf: 100 corrections of -1 each, 900 matches.
  SELECT jsonb_object_agg(id, '0') INTO _bulk_overrides FROM (
    SELECT id, row_number() OVER (ORDER BY name) AS n FROM public.inventory_items
    WHERE organization_id = _org AND name LIKE 'Itest Bulk %') bulk WHERE n % 10 = 0;
  PERFORM pg_temp.count(_org, _bulk, _bulk_overrides, 'itest-bulk');
  PERFORM set_config('request.jwt.claim.sub', '7b2c0000-0000-4000-8000-000000000001', true);
  PERFORM pg_temp.count(_org, _cabinet, '{}', 'itest-matched');
  PERFORM set_config('request.jwt.claim.sub', '7b2c0000-0000-4000-8000-000000000006', true);
  PERFORM pg_temp.count(_org, _rehab, '{"7b2c0000-0000-4000-8000-000000000501": "3"}', 'itest-former');

  PERFORM set_config('request.jwt.claim.sub', '7b2c0000-0000-4000-8000-000000000004', true);
  _other := public.create_inventory_location('7b2c0000-0000-4000-8000-000000000102', 'Other Cabinet');
  PERFORM public.move_inventory_stock('7b2c0000-0000-4000-8000-000000000102', '7b2c0000-0000-4000-8000-000000000511',
    (SELECT id FROM public.inventory_locations WHERE organization_id = '7b2c0000-0000-4000-8000-000000000102' AND kind = 'unassigned'),
    _other, 10, 'fx-other');
  PERFORM pg_temp.count('7b2c0000-0000-4000-8000-000000000102', _other, '{"7b2c0000-0000-4000-8000-000000000511": "7"}', 'itest-other');

  -- After counting: the kit leaves Cabinet and is archived; the tape is renamed.
  PERFORM set_config('request.jwt.claim.sub', '7b2c0000-0000-4000-8000-000000000001', true);
  PERFORM public.move_inventory_stock(_org, '7b2c0000-0000-4000-8000-000000000505', _cabinet, _unassigned, 3, 'fx-kit-out');
  UPDATE public.inventory_items SET active = false WHERE id = '7b2c0000-0000-4000-8000-000000000505';
  UPDATE public.inventory_items SET name = 'Itest Renamed Tape', sku = 'TAPE-NEW', unit = 'case'
  WHERE id = '7b2c0000-0000-4000-8000-000000000501';

  -- 1200 historical one-line sessions at History Closet, an hour apart from 2025-01-01, each
  -- pair 600/601 sharing a timestamp; every fourth has a correction. Then Closet is archived.
  INSERT INTO public.inventory_count_sessions (id, organization_id, inventory_location_id, counted_by, submitted_at,
    line_count, changed_count, idempotency_key, request_hash)
  SELECT ('7b2c0000-0000-4000-8000-0000000a' || lpad(n::text, 4, '0'))::uuid, _org, _closet,
    CASE WHEN n % 2 = 0 THEN '7b2c0000-0000-4000-8000-000000000001'::uuid ELSE '7b2c0000-0000-4000-8000-000000000003'::uuid END,
    timestamptz '2025-01-01 00:00:00+00' + (CASE WHEN n = 601 THEN 599 ELSE n - 1 END) * interval '1 hour',
    1, CASE WHEN n % 4 = 0 THEN 1 ELSE 0 END, 'itest-hist-' || n, repeat('0', 64)
  FROM generate_series(1, 1200) n;
  INSERT INTO public.inventory_count_lines (organization_id, count_session_id, inventory_item_id, inventory_location_id,
    previous_quantity, counted_quantity, delta, observed_version, item_name, item_sku, item_unit, created_at)
  SELECT _org, session.id, '7b2c0000-0000-4000-8000-000000000503', _closet,
    5, 5 - session.changed_count, -session.changed_count, 1, 'Itest Wrap', NULL, 'each', session.submitted_at
  FROM public.inventory_count_sessions session WHERE session.idempotency_key LIKE 'itest-hist-%';
  UPDATE public.inventory_locations SET active = false WHERE id = _closet;
END
$fixture$;

DELETE FROM public.organization_memberships
WHERE organization_id = '7b2c0000-0000-4000-8000-000000000101' AND user_id = '7b2c0000-0000-4000-8000-000000000006';
