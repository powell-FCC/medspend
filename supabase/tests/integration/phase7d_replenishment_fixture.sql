-- Fixture for tests/phase7d-replenishment-integration.test.ts. Runs as postgres after every
-- migration, on a local disposable database only; this file commits its rows.
--
-- Organization A at the agreed large shape: 2,000 active items, 20 active storage locations
-- (L01..L20) plus Unassigned, a rule for every item at every storage location (40,000 rules),
-- balances everywhere, and 5 submitted full counts per location (10,000 count sessions'
-- worth of lines: 200,000 count lines). Two ordered inventory-backed requests (items 1 and 2)
-- and one ordered free-text request. Organization B is a neighbour with one rule.
--   users: 001 owner A, 002 admin A, 003 staff A, 004 owner B, 009 signed in, member of nothing.
-- Quantities: Unassigned i % 7; location k: (i * k) % 13. Rule at (i, k): Minimum (i + k) % 5,
-- Target Minimum + 5.

BEGIN;

INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('7d1c0000-0000-4000-8000-00000000000' || n)::uuid, 'authenticated', 'authenticated',
  'phase7d-itest-' || n || '@example.invalid', '', now(), '{}', '{}', now(), now()
FROM unnest(ARRAY[1, 2, 3, 4, 9]) n;

INSERT INTO public.organizations (id, name, created_by) VALUES
  ('7d1c0000-0000-4000-8000-000000000101', 'Phase 7D Integration A', '7d1c0000-0000-4000-8000-000000000001'),
  ('7d1c0000-0000-4000-8000-000000000102', 'Phase 7D Integration B', '7d1c0000-0000-4000-8000-000000000004');
INSERT INTO public.teams (id, organization_id, name) VALUES
  ('7d1c0000-0000-4000-8000-000000000201', '7d1c0000-0000-4000-8000-000000000101', 'First Team');
INSERT INTO public.locations (id, organization_id, name) VALUES
  ('7d1c0000-0000-4000-8000-000000000301', '7d1c0000-0000-4000-8000-000000000101', 'Training Ground');
INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES
  ('7d1c0000-0000-4000-8000-000000000101', '7d1c0000-0000-4000-8000-000000000001', 'owner', true),
  ('7d1c0000-0000-4000-8000-000000000101', '7d1c0000-0000-4000-8000-000000000002', 'admin', true),
  ('7d1c0000-0000-4000-8000-000000000101', '7d1c0000-0000-4000-8000-000000000003', 'staff', true),
  ('7d1c0000-0000-4000-8000-000000000102', '7d1c0000-0000-4000-8000-000000000004', 'owner', true);

-- Items (quantity 0; the 7A.1 trigger seeds a zero Unassigned balance) and locations.
INSERT INTO public.inventory_items (id, organization_id, name, unit, quantity, active)
SELECT ('7d1c0000-0000-4000-9000-' || lpad(i::text, 12, '0'))::uuid, '7d1c0000-0000-4000-8000-000000000101',
  'Item ' || lpad(i::text, 4, '0'), CASE WHEN i % 3 = 0 THEN 'BX' ELSE 'each' END, 0, true
FROM generate_series(1, 2000) i;
INSERT INTO public.inventory_items (id, organization_id, name, unit, quantity, active) VALUES
  ('7d1c0000-0000-4000-8000-000000000511', '7d1c0000-0000-4000-8000-000000000102', 'Other Tape', 'roll', 0, true);
INSERT INTO public.inventory_locations (id, organization_id, name, kind, active)
SELECT ('7d1c0000-0000-4000-a000-' || lpad(k::text, 12, '0'))::uuid, '7d1c0000-0000-4000-8000-000000000101',
  'L' || lpad(k::text, 2, '0'), 'storage', true
FROM generate_series(1, 20) k;
INSERT INTO public.inventory_locations (id, organization_id, name, kind, active) VALUES
  ('7d1c0000-0000-4000-8000-000000000611', '7d1c0000-0000-4000-8000-000000000102', 'Other ATR', 'storage', true);

-- Balances, written the way inventory_apply_balance_delta does (sync flag on), then the item
-- totals; the deferred invariant checks the sums at commit.
SELECT set_config('medspend.inventory_sync', 'on', false);
UPDATE public.inventory_location_balances balance SET quantity = (substr(balance.inventory_item_id::text, 25)::int) % 7
FROM public.inventory_locations location
WHERE location.id = balance.inventory_location_id AND location.kind = 'unassigned'
  AND balance.organization_id = '7d1c0000-0000-4000-8000-000000000101';
INSERT INTO public.inventory_location_balances (organization_id, inventory_item_id, inventory_location_id, quantity)
SELECT '7d1c0000-0000-4000-8000-000000000101', ('7d1c0000-0000-4000-9000-' || lpad(i::text, 12, '0'))::uuid,
  ('7d1c0000-0000-4000-a000-' || lpad(k::text, 12, '0'))::uuid, (i * k) % 13
FROM generate_series(1, 2000) i CROSS JOIN generate_series(1, 20) k;
INSERT INTO public.inventory_location_balances (organization_id, inventory_item_id, inventory_location_id, quantity)
VALUES ('7d1c0000-0000-4000-8000-000000000102', '7d1c0000-0000-4000-8000-000000000511', '7d1c0000-0000-4000-8000-000000000611', 4);
UPDATE public.inventory_location_balances SET quantity = 1
WHERE inventory_item_id = '7d1c0000-0000-4000-8000-000000000511'
  AND inventory_location_id = (SELECT id FROM public.inventory_locations
                               WHERE organization_id = '7d1c0000-0000-4000-8000-000000000102' AND kind = 'unassigned');
UPDATE public.inventory_items item SET quantity = totals.quantity
FROM (SELECT inventory_item_id, sum(quantity) AS quantity FROM public.inventory_location_balances GROUP BY 1) totals
WHERE totals.inventory_item_id = item.id;
SELECT set_config('medspend.inventory_sync', 'off', false);

-- Rules for every item at every storage location of A, and one in B.
INSERT INTO public.inventory_replenishment_rules (organization_id, inventory_item_id, inventory_location_id,
  minimum_quantity, target_quantity, created_by, updated_by)
SELECT '7d1c0000-0000-4000-8000-000000000101', ('7d1c0000-0000-4000-9000-' || lpad(i::text, 12, '0'))::uuid,
  ('7d1c0000-0000-4000-a000-' || lpad(k::text, 12, '0'))::uuid, (i + k) % 5, (i + k) % 5 + 5,
  '7d1c0000-0000-4000-8000-000000000001', '7d1c0000-0000-4000-8000-000000000001'
FROM generate_series(1, 2000) i CROSS JOIN generate_series(1, 20) k;
INSERT INTO public.inventory_replenishment_rules (organization_id, inventory_item_id, inventory_location_id,
  minimum_quantity, target_quantity)
VALUES ('7d1c0000-0000-4000-8000-000000000102', '7d1c0000-0000-4000-8000-000000000511', '7d1c0000-0000-4000-8000-000000000611', 5, 10);

-- Count history: 5 full counts per location, a week apart, the newest 3 days ago.
INSERT INTO public.inventory_count_sessions (id, organization_id, inventory_location_id, counted_by, submitted_at,
  line_count, changed_count, idempotency_key, request_hash)
SELECT ('7d1c0000-0000-4000-b000-' || lpad((k * 10 + s)::text, 12, '0'))::uuid, '7d1c0000-0000-4000-8000-000000000101',
  ('7d1c0000-0000-4000-a000-' || lpad(k::text, 12, '0'))::uuid, '7d1c0000-0000-4000-8000-000000000003',
  now() - interval '3 days' - (s - 1) * interval '7 days', 2000, 0, 'itest-' || k || '-' || s, repeat('0', 64)
FROM generate_series(1, 20) k CROSS JOIN generate_series(1, 5) s;
INSERT INTO public.inventory_count_lines (organization_id, count_session_id, inventory_item_id, inventory_location_id,
  previous_quantity, counted_quantity, delta, observed_version, item_name, item_unit, created_at)
SELECT '7d1c0000-0000-4000-8000-000000000101', ('7d1c0000-0000-4000-b000-' || lpad((k * 10 + s)::text, 12, '0'))::uuid,
  ('7d1c0000-0000-4000-9000-' || lpad(i::text, 12, '0'))::uuid, ('7d1c0000-0000-4000-a000-' || lpad(k::text, 12, '0'))::uuid,
  (i * k) % 13, (i * k) % 13, 0, 1, 'Item ' || lpad(i::text, 4, '0'), CASE WHEN i % 3 = 0 THEN 'BX' ELSE 'each' END,
  now() - interval '3 days' - (s - 1) * interval '7 days'
FROM generate_series(1, 2000) i CROSS JOIN generate_series(1, 20) k CROSS JOIN generate_series(1, 5) s;

-- Requests: two ordered inventory-backed (items 1 and 2), one ordered free-text.
SELECT set_config('request.jwt.claim.sub', '7d1c0000-0000-4000-8000-000000000003', false);
SELECT set_config('itest.r' || n, public.submit_supply_request('7d1c0000-0000-4000-8000-000000000101', 'reorder',
  '7d1c0000-0000-4000-8000-000000000201', '7d1c0000-0000-4000-8000-000000000301', 'itest',
  CASE WHEN n = 3 THEN jsonb_build_array(jsonb_build_object('freeTextItem', 'Item 0001 (any)', 'quantity', 5))
       ELSE jsonb_build_array(jsonb_build_object('inventoryItemId', '7d1c0000-0000-4000-9000-' || lpad(n::text, 12, '0'), 'quantity', 3)) END)::text, false)
FROM generate_series(1, 3) n;
SELECT set_config('request.jwt.claim.sub', '7d1c0000-0000-4000-8000-000000000002', false);
SELECT public.decide_supply_request('7d1c0000-0000-4000-8000-000000000101', current_setting('itest.r' || n)::uuid, 'approved', NULL, NULL,
  (SELECT updated_at FROM public.supply_requests WHERE id = current_setting('itest.r' || n)::uuid))
FROM generate_series(1, 3) n;
SELECT public.transition_supply_request('7d1c0000-0000-4000-8000-000000000101', current_setting('itest.r' || n)::uuid, 'ordered')
FROM generate_series(1, 3) n;
SELECT set_config('request.jwt.claim.sub', '', false);

COMMIT;
ANALYZE public.inventory_items, public.inventory_locations, public.inventory_location_balances,
  public.inventory_replenishment_rules, public.inventory_count_sessions, public.inventory_count_lines,
  public.supply_requests, public.supply_request_items;
