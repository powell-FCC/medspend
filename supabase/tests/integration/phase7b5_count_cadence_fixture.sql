-- Fixture for tests/phase7b5-count-cadence-integration.test.ts. Runs as postgres after every
-- migration, on a local disposable database only; this file commits its rows.
--
-- Organization A: 300 active storage locations (L001..L300) each holding two countable items;
-- L001..L280 have 100 submitted counts each (28,000 sessions), the newest one
-- ((n - 1) % 60) days + 12 hours ago, older ones a week apart; L281..L300 were never counted.
-- Three active locations hold nothing (nothing to count) and five archived locations have
-- counts. No count cadence policy exists yet. Organization B is a neighbour with its own
-- counted location.
--   users: 001 owner A, 002 admin A, 003 staff A, 004 owner B, 005 admin B,
--          009 signed in but a member of nothing.

INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('7b5c0000-0000-4000-8000-00000000000' || n)::uuid, 'authenticated', 'authenticated',
  'phase7b5-itest-' || n || '@example.invalid', '', now(), '{}',
  CASE n WHEN 1 THEN '{"full_name": "Integration Owner"}'::jsonb ELSE '{}'::jsonb END, now(), now()
FROM unnest(ARRAY[1, 2, 3, 4, 5, 9]) n;

INSERT INTO public.organizations (id, name, created_by) VALUES
  ('7b5c0000-0000-4000-8000-000000000101', 'Phase 7B.5 Integration A', '7b5c0000-0000-4000-8000-000000000001'),
  ('7b5c0000-0000-4000-8000-000000000102', 'Phase 7B.5 Integration B', '7b5c0000-0000-4000-8000-000000000004');
INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES
  ('7b5c0000-0000-4000-8000-000000000101', '7b5c0000-0000-4000-8000-000000000001', 'owner', true),
  ('7b5c0000-0000-4000-8000-000000000101', '7b5c0000-0000-4000-8000-000000000002', 'admin', true),
  ('7b5c0000-0000-4000-8000-000000000101', '7b5c0000-0000-4000-8000-000000000003', 'staff', true),
  ('7b5c0000-0000-4000-8000-000000000102', '7b5c0000-0000-4000-8000-000000000004', 'owner', true),
  ('7b5c0000-0000-4000-8000-000000000102', '7b5c0000-0000-4000-8000-000000000005', 'admin', true);

INSERT INTO public.inventory_items (id, organization_id, sku, name, unit, quantity, active) VALUES
  ('7b5c0000-0000-4000-8000-000000000501', '7b5c0000-0000-4000-8000-000000000101', 'TAPE-1', 'Itest Tape', 'roll', 2000, true),
  ('7b5c0000-0000-4000-8000-000000000502', '7b5c0000-0000-4000-8000-000000000101', 'GAUZE-1', 'Itest Gauze', 'box', 2000, true),
  ('7b5c0000-0000-4000-8000-000000000511', '7b5c0000-0000-4000-8000-000000000102', 'TAPE-1', 'Itest Other Tape', 'roll', 10, true);

DO $fixture$
DECLARE
  _org constant uuid := '7b5c0000-0000-4000-8000-000000000101';
  _unassigned uuid;
  _location uuid;
  _other uuid;
  _n integer;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '7b5c0000-0000-4000-8000-000000000001', true);
  SELECT id INTO _unassigned FROM public.inventory_locations WHERE organization_id = _org AND kind = 'unassigned';
  FOR _n IN 1 .. 300 LOOP
    _location := public.create_inventory_location(_org, 'L' || lpad(_n::text, 3, '0'));
    PERFORM public.move_inventory_stock(_org, '7b5c0000-0000-4000-8000-000000000501', _unassigned, _location, 1, 'fx-t-' || _n);
    PERFORM public.move_inventory_stock(_org, '7b5c0000-0000-4000-8000-000000000502', _unassigned, _location, 1, 'fx-g-' || _n);
  END LOOP;
  FOR _n IN 1 .. 3 LOOP
    PERFORM public.create_inventory_location(_org, 'Empty ' || _n);
  END LOOP;
  FOR _n IN 1 .. 5 LOOP
    _location := public.create_inventory_location(_org, 'Archived ' || _n);
    INSERT INTO public.inventory_count_sessions (organization_id, inventory_location_id, counted_by, submitted_at,
      line_count, changed_count, idempotency_key, request_hash)
    VALUES (_org, _location, '7b5c0000-0000-4000-8000-000000000003', now() - interval '200 days', 1, 0, 'arch-' || _n, repeat('0', 64));
    PERFORM public.set_inventory_location_active(_org, _location, false);
  END LOOP;

  INSERT INTO public.inventory_count_sessions (organization_id, inventory_location_id, counted_by, submitted_at,
    line_count, changed_count, idempotency_key, request_hash)
  SELECT _org, location.id, '7b5c0000-0000-4000-8000-000000000003',
    now() - make_interval(days => (substr(location.name, 2)::integer - 1) % 60, hours => 12) - (k * interval '7 days'),
    2, 0, 'hist-' || location.name || '-' || k, repeat('0', 64)
  FROM public.inventory_locations location, generate_series(0, 99) k
  WHERE location.organization_id = _org AND location.name ~ '^L[0-9]{3}$' AND substr(location.name, 2)::integer <= 280;

  PERFORM set_config('request.jwt.claim.sub', '7b5c0000-0000-4000-8000-000000000004', true);
  _other := public.create_inventory_location('7b5c0000-0000-4000-8000-000000000102', 'Other Cabinet');
  PERFORM public.move_inventory_stock('7b5c0000-0000-4000-8000-000000000102', '7b5c0000-0000-4000-8000-000000000511',
    (SELECT id FROM public.inventory_locations WHERE organization_id = '7b5c0000-0000-4000-8000-000000000102' AND kind = 'unassigned'),
    _other, 10, 'fx-other');
  INSERT INTO public.inventory_count_sessions (organization_id, inventory_location_id, counted_by, submitted_at,
    line_count, changed_count, idempotency_key, request_hash)
  VALUES ('7b5c0000-0000-4000-8000-000000000102', _other, '7b5c0000-0000-4000-8000-000000000004', now() - interval '400 days',
    1, 0, 'other', repeat('0', 64));
END
$fixture$;

ANALYZE public.inventory_count_sessions;
ANALYZE public.inventory_locations;
ANALYZE public.inventory_location_balances;
