-- Phase 7B.1 rollback-only behavioral verification: owner+admin Inventory workspace reads
-- and atomic QR label replacement. Run against a disposable database after every migration
-- through 20261028120000_phase7b1_inventory_admin_workspace.sql. Every fixture and mutation
-- is rolled back; SET CONSTRAINTS ALL IMMEDIATE before the rollback evaluates the deferred
-- quantity invariant for every row this suite touched.

BEGIN;

DO $phase7b1_fixture_guard$
BEGIN
  IF EXISTS (SELECT 1 FROM auth.users
             WHERE id BETWEEN '7b100000-0000-4000-8000-000000000001'::uuid AND '7b100000-0000-4000-8000-000000000099'::uuid)
     OR EXISTS (SELECT 1 FROM public.organizations
             WHERE id BETWEEN '7b100000-0000-4000-8000-000000000101'::uuid AND '7b100000-0000-4000-8000-000000000199'::uuid) THEN
    RAISE EXCEPTION 'Phase 7B.1 rollback-test fixture IDs already exist';
  END IF;
END
$phase7b1_fixture_guard$;

CREATE FUNCTION pg_temp.expect_error(_statement text, _expected text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE _statement;
  EXCEPTION WHEN OTHERS THEN
    IF position(_expected IN SQLERRM) = 0 THEN
      RAISE EXCEPTION 'Expected error containing "%", got "%" (%)', _expected, SQLERRM, SQLSTATE;
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

CREATE TEMP TABLE phase7b1_values (name text PRIMARY KEY, value jsonb) ON COMMIT DROP;
GRANT ALL ON phase7b1_values TO authenticated, anon;

CREATE FUNCTION pg_temp.val(_name text)
RETURNS jsonb LANGUAGE sql AS $$ SELECT value FROM phase7b1_values WHERE name = _name $$;
CREATE FUNCTION pg_temp.loc(_name text)
RETURNS uuid LANGUAGE sql AS $$ SELECT (value #>> '{}')::uuid FROM phase7b1_values WHERE name = 'loc:' || _name $$;
CREATE FUNCTION pg_temp.unassigned(_organization uuid)
RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM public.inventory_locations WHERE organization_id = _organization AND kind = 'unassigned' $$;
CREATE FUNCTION pg_temp.active_labels(_location uuid)
RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$
  SELECT count(*) FROM public.inventory_location_labels WHERE inventory_location_id = _location AND revoked_at IS NULL $$;
CREATE FUNCTION pg_temp.labels(_location uuid)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_array(id, revoked_at IS NULL) ORDER BY id), '[]')
  FROM public.inventory_location_labels WHERE inventory_location_id = _location $$;

-- Everything a refused mutation must leave alone.
CREATE FUNCTION pg_temp.state(_organization uuid)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT jsonb_build_object(
    'items', (SELECT coalesce(jsonb_agg(to_jsonb(item) - 'updated_at' ORDER BY id), '[]')
              FROM public.inventory_items item WHERE organization_id = _organization),
    'categories', (SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY id), '[]')
                   FROM public.inventory_categories c WHERE organization_id = _organization),
    'locations', (SELECT coalesce(jsonb_agg(jsonb_build_array(id, name, description, kind, active) ORDER BY id), '[]')
                  FROM public.inventory_locations WHERE organization_id = _organization),
    'balances', (SELECT coalesce(jsonb_agg(jsonb_build_array(inventory_item_id, inventory_location_id, quantity, version)
                 ORDER BY inventory_item_id, inventory_location_id), '[]')
                 FROM public.inventory_location_balances WHERE organization_id = _organization),
    'adjustments', (SELECT count(*) FROM public.inventory_adjustments WHERE organization_id = _organization),
    'transfers', (SELECT count(*) FROM public.inventory_transfers WHERE organization_id = _organization),
    'sessions', (SELECT count(*) FROM public.inventory_count_sessions WHERE organization_id = _organization),
    'labels', (SELECT coalesce(jsonb_agg(jsonb_build_array(id, revoked_at IS NULL) ORDER BY id), '[]')
               FROM public.inventory_location_labels WHERE organization_id = _organization))
$$;

-- ---------------------------------------------------------------------------------------
-- Fixtures. A: owner 001, admin 002, staff 003. B: owner 004, admin 005. 007 belongs to
-- nothing.
-- ---------------------------------------------------------------------------------------
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('7b100000-0000-4000-8000-00000000000' || n)::uuid, 'authenticated', 'authenticated',
  'phase7b1-' || n || '@example.invalid', '', now(), '{}',
  CASE WHEN n = 3 THEN '{"full_name": "Staff Counter"}'::jsonb ELSE '{}'::jsonb END, now(), now()
FROM generate_series(1, 7) n;

INSERT INTO public.organizations (id, name, created_by) VALUES
  ('7b100000-0000-4000-8000-000000000101', 'Phase 7B.1 Organization', '7b100000-0000-4000-8000-000000000001'),
  ('7b100000-0000-4000-8000-000000000102', 'Phase 7B.1 Other Organization', '7b100000-0000-4000-8000-000000000004');

INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES
  ('7b100000-0000-4000-8000-000000000101', '7b100000-0000-4000-8000-000000000001', 'owner', true),
  ('7b100000-0000-4000-8000-000000000101', '7b100000-0000-4000-8000-000000000002', 'admin', true),
  ('7b100000-0000-4000-8000-000000000101', '7b100000-0000-4000-8000-000000000003', 'staff', true),
  ('7b100000-0000-4000-8000-000000000102', '7b100000-0000-4000-8000-000000000004', 'owner', true),
  ('7b100000-0000-4000-8000-000000000102', '7b100000-0000-4000-8000-000000000005', 'admin', true);

INSERT INTO public.inventory_categories (organization_id, name) VALUES
  ('7b100000-0000-4000-8000-000000000101', 'Taping'), ('7b100000-0000-4000-8000-000000000101', 'Wound');

-- Stock that predates the workspace. Inserted as postgres; each item starts in Unassigned.
INSERT INTO public.inventory_items (id, organization_id, sku, name, description, unit, quantity, vendor_name,
  manufacturer, category, last_purchase_price, last_purchase_date, par_level, active) VALUES
  ('7b100000-0000-4000-8000-000000000501', '7b100000-0000-4000-8000-000000000101', 'TAPE-1', 'P7B1 Tape', 'Zinc oxide', 'roll', 20,
   'Secret Vendor', 'Tape Co', 'Taping', 9.87, '2026-10-01', 4, true),
  ('7b100000-0000-4000-8000-000000000502', '7b100000-0000-4000-8000-000000000101', 'GAUZE-1', 'P7B1 Gauze', NULL, 'box', 2.75,
   NULL, NULL, 'Wound', 3.21, '2026-10-01', 10, true),
  ('7b100000-0000-4000-8000-000000000503', '7b100000-0000-4000-8000-000000000101', NULL, 'P7B1 Zero Item', NULL, 'each', 1,
   NULL, NULL, NULL, NULL, NULL, NULL, true),
  ('7b100000-0000-4000-8000-000000000504', '7b100000-0000-4000-8000-000000000101', 'ARCH-POS', 'P7B1 Archived Stocked', NULL, 'each', 5,
   NULL, NULL, NULL, NULL, NULL, NULL, true),
  ('7b100000-0000-4000-8000-000000000505', '7b100000-0000-4000-8000-000000000101', 'ARCH-ZERO', 'P7B1 Archived Empty', NULL, 'each', 1,
   NULL, NULL, NULL, NULL, NULL, NULL, true),
  ('7b100000-0000-4000-8000-000000000506', '7b100000-0000-4000-8000-000000000101', 'U-ONLY', 'P7B1 Unassigned Only', NULL, 'each', 4,
   NULL, 'Only Co', NULL, NULL, NULL, 5, true),
  ('7b100000-0000-4000-8000-000000000511', '7b100000-0000-4000-8000-000000000102', 'TAPE-1', 'P7B1 Other Tape', NULL, 'roll', 10,
   NULL, NULL, NULL, 1.11, NULL, NULL, true);

SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b100000-0000-4000-8000-000000000001');
INSERT INTO phase7b1_values VALUES
  ('loc:cabinet', to_jsonb(public.create_inventory_location('7b100000-0000-4000-8000-000000000101', 'Cabinet'))),
  ('loc:rehab', to_jsonb(public.create_inventory_location('7b100000-0000-4000-8000-000000000101', 'Rehab'))),
  ('loc:empty', to_jsonb(public.create_inventory_location('7b100000-0000-4000-8000-000000000101', 'Empty Room'))),
  ('loc:closet', to_jsonb(public.create_inventory_location('7b100000-0000-4000-8000-000000000101', 'Closet')));
SELECT public.move_inventory_stock('7b100000-0000-4000-8000-000000000101', '7b100000-0000-4000-8000-000000000501',
  pg_temp.unassigned('7b100000-0000-4000-8000-000000000101'), pg_temp.loc('cabinet'), 12, 'fx-1');
SELECT public.move_inventory_stock('7b100000-0000-4000-8000-000000000101', '7b100000-0000-4000-8000-000000000501',
  pg_temp.unassigned('7b100000-0000-4000-8000-000000000101'), pg_temp.loc('rehab'), 3, 'fx-2');
SELECT public.move_inventory_stock('7b100000-0000-4000-8000-000000000101', '7b100000-0000-4000-8000-000000000502',
  pg_temp.unassigned('7b100000-0000-4000-8000-000000000101'), pg_temp.loc('cabinet'), 2.75, 'fx-3');
SELECT public.move_inventory_stock('7b100000-0000-4000-8000-000000000101', '7b100000-0000-4000-8000-000000000503',
  pg_temp.unassigned('7b100000-0000-4000-8000-000000000101'), pg_temp.loc('cabinet'), 1, 'fx-4');
SELECT public.move_inventory_stock('7b100000-0000-4000-8000-000000000101', '7b100000-0000-4000-8000-000000000503',
  pg_temp.loc('cabinet'), pg_temp.unassigned('7b100000-0000-4000-8000-000000000101'), 1, 'fx-5');
SELECT public.move_inventory_stock('7b100000-0000-4000-8000-000000000101', '7b100000-0000-4000-8000-000000000504',
  pg_temp.unassigned('7b100000-0000-4000-8000-000000000101'), pg_temp.loc('cabinet'), 5, 'fx-6');
SELECT public.move_inventory_stock('7b100000-0000-4000-8000-000000000101', '7b100000-0000-4000-8000-000000000505',
  pg_temp.unassigned('7b100000-0000-4000-8000-000000000101'), pg_temp.loc('cabinet'), 1, 'fx-7');
SELECT public.move_inventory_stock('7b100000-0000-4000-8000-000000000101', '7b100000-0000-4000-8000-000000000505',
  pg_temp.loc('cabinet'), pg_temp.unassigned('7b100000-0000-4000-8000-000000000101'), 1, 'fx-8');
INSERT INTO phase7b1_values VALUES
  ('cab1', public.issue_inventory_location_label('7b100000-0000-4000-8000-000000000101', pg_temp.loc('cabinet'))),
  ('cab2', public.issue_inventory_location_label('7b100000-0000-4000-8000-000000000101', pg_temp.loc('cabinet'))),
  ('closet', public.issue_inventory_location_label('7b100000-0000-4000-8000-000000000101', pg_temp.loc('closet')));
-- An empty location archived with its label still active (the 7A.2 acceptance shape).
SELECT public.set_inventory_location_active('7b100000-0000-4000-8000-000000000101', pg_temp.loc('closet'), false);
SELECT pg_temp.as_user('7b100000-0000-4000-8000-000000000004');
INSERT INTO phase7b1_values VALUES
  ('loc:other', to_jsonb(public.create_inventory_location('7b100000-0000-4000-8000-000000000102', 'Other Cabinet')));
SELECT public.move_inventory_stock('7b100000-0000-4000-8000-000000000102', '7b100000-0000-4000-8000-000000000511',
  pg_temp.unassigned('7b100000-0000-4000-8000-000000000102'), pg_temp.loc('other'), 10, 'fx-9');
INSERT INTO phase7b1_values VALUES
  ('other_label', public.issue_inventory_location_label('7b100000-0000-4000-8000-000000000102', pg_temp.loc('other')));
-- Staff count the rehab shelf (no change), so it has a last count and a counter.
SELECT pg_temp.as_user('7b100000-0000-4000-8000-000000000003');
SELECT public.submit_inventory_count('7b100000-0000-4000-8000-000000000101', pg_temp.loc('rehab'),
  jsonb_build_array(jsonb_build_object('inventoryItemId', '7b100000-0000-4000-8000-000000000501',
    'observedVersion', (SELECT (item->>'version')::bigint FROM jsonb_array_elements(
      public.get_inventory_count_location('7b100000-0000-4000-8000-000000000101', pg_temp.loc('rehab'))->'items') item),
    'countedQuantity', '3')), 'count-1');
RESET ROLE;
UPDATE public.inventory_items SET active = false
WHERE id IN ('7b100000-0000-4000-8000-000000000504', '7b100000-0000-4000-8000-000000000505');

-- ---------------------------------------------------------------------------------------
-- 1. Exact read contracts: columns and JSON keys. No purchase price or date anywhere.
-- ---------------------------------------------------------------------------------------
SELECT pg_temp.assert(pg_get_function_result('public.list_inventory_workspace_locations(uuid, text, integer, integer, text, uuid)'::regprocedure)
  = 'TABLE(inventory_location_id uuid, name text, description text, kind text, active boolean, sort_group integer, sort_name text, stocked_item_count integer, countable_item_count integer, last_counted_at timestamp with time zone, last_counted_by_name text, active_label_count integer, last_label_issued_at timestamp with time zone)',
  'locations contract');
SELECT pg_temp.assert(pg_get_function_result('public.list_inventory_workspace_location_stock(uuid, uuid, integer, text, uuid)'::regprocedure)
  = 'TABLE(inventory_item_id uuid, name text, sku text, unit text, sort_name text, quantity numeric, item_active boolean, organization_quantity numeric, organization_par_level numeric, organization_stock_status text, last_counted_at timestamp with time zone)',
  'stock contract');
SELECT pg_temp.assert(pg_get_function_result('public.list_inventory_workspace_items(uuid, text, text, text, text, integer, text, uuid)'::regprocedure)
  = 'TABLE(inventory_item_id uuid, name text, description text, sku text, vendor_name text, manufacturer text, category text, unit text, active boolean, sort_name text, quantity numeric, par_level numeric, stock_status text, unassigned_quantity numeric, physical_quantity numeric, physical_location_count integer, single_physical_location_name text)',
  'items contract');
SELECT pg_temp.assert(NOT EXISTS (
  SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname LIKE '%inventory_workspace%'
    AND (pg_get_functiondef(p.oid) ILIKE '%last_purchase%' OR pg_get_functiondef(p.oid) ILIKE '%price%')),
  'no workspace function reads purchase prices or dates');

SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b100000-0000-4000-8000-000000000002');
SELECT pg_temp.assert(
  (SELECT array_agg(key ORDER BY key COLLATE "C") FROM jsonb_object_keys(
     public.get_inventory_workspace_location('7b100000-0000-4000-8000-000000000101', pg_temp.loc('cabinet'))) key)
  = ARRAY['active', 'activeLabelCount', 'archivedStockedItemCount', 'countableItemCount', 'description', 'id', 'kind',
          'lastCountedAt', 'lastCountedByName', 'lastLabelIssuedAt', 'name', 'stockedItemCount'],
  'location detail keys');
SELECT pg_temp.assert(
  (SELECT array_agg(key ORDER BY key COLLATE "C") FROM jsonb_object_keys(
     public.list_inventory_workspace_item_balances('7b100000-0000-4000-8000-000000000101', '7b100000-0000-4000-8000-000000000501')) key)
  = ARRAY['balances', 'inventoryItemId', 'quantity'], 'item balances keys');
SELECT pg_temp.assert(
  (SELECT array_agg(DISTINCT key COLLATE "C" ORDER BY key COLLATE "C") FROM jsonb_array_elements(
     public.list_inventory_workspace_item_balances('7b100000-0000-4000-8000-000000000101', '7b100000-0000-4000-8000-000000000501')->'balances') b,
     jsonb_object_keys(b) key)
  = ARRAY['inventoryLocationId', 'quantity', 'updatedAt', 'version'], 'item balance row keys');

-- ---------------------------------------------------------------------------------------
-- 2. Authorization matrix for every read function: owner and admin of the organization
--    pass; staff, the other organization's owner and admin, a non-member, a missing user
--    and anon are refused.
-- ---------------------------------------------------------------------------------------
CREATE TEMP TABLE phase7b1_reads (label text, statement text) ON COMMIT DROP;
GRANT ALL ON phase7b1_reads TO authenticated, anon;
INSERT INTO phase7b1_reads VALUES
  ('locations', $$SELECT count(*) FROM public.list_inventory_workspace_locations('7b100000-0000-4000-8000-000000000101')$$),
  ('location', format($$SELECT public.get_inventory_workspace_location('7b100000-0000-4000-8000-000000000101', %L)$$, pg_temp.loc('cabinet'))),
  ('stock', format($$SELECT count(*) FROM public.list_inventory_workspace_location_stock('7b100000-0000-4000-8000-000000000101', %L)$$, pg_temp.loc('cabinet'))),
  ('items', $$SELECT count(*) FROM public.list_inventory_workspace_items('7b100000-0000-4000-8000-000000000101')$$),
  ('balances', $$SELECT public.list_inventory_workspace_item_balances('7b100000-0000-4000-8000-000000000101', '7b100000-0000-4000-8000-000000000501')$$);

DO $reads$
DECLARE
  _read record;
  _user uuid;
BEGIN
  FOR _read IN SELECT * FROM phase7b1_reads LOOP
    FOREACH _user IN ARRAY ARRAY['7b100000-0000-4000-8000-000000000001', '7b100000-0000-4000-8000-000000000002']::uuid[] LOOP
      PERFORM pg_temp.as_user(_user);
      EXECUTE _read.statement;
    END LOOP;
    FOREACH _user IN ARRAY ARRAY['7b100000-0000-4000-8000-000000000003', '7b100000-0000-4000-8000-000000000004',
                                 '7b100000-0000-4000-8000-000000000005', '7b100000-0000-4000-8000-000000000007']::uuid[] LOOP
      PERFORM pg_temp.as_user(_user);
      PERFORM pg_temp.expect_error(_read.statement, 'Forbidden: owner or admin access required');
    END LOOP;
    PERFORM pg_temp.as_user(NULL);
    PERFORM pg_temp.expect_error(_read.statement, 'Forbidden: owner or admin access required');
  END LOOP;
END
$reads$;
RESET ROLE;
SET LOCAL ROLE anon;
DO $anon$
DECLARE _read record;
BEGIN
  FOR _read IN SELECT * FROM phase7b1_reads LOOP
    PERFORM pg_temp.expect_error(_read.statement, 'permission denied for function');
  END LOOP;
END
$anon$;
RESET ROLE;

-- A member of another organization cannot reach its rows through their own organization.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b100000-0000-4000-8000-000000000002');
SELECT pg_temp.expect_error(format($$SELECT public.get_inventory_workspace_location('7b100000-0000-4000-8000-000000000101', %L)$$,
  pg_temp.loc('other')), 'Inventory location not found');
SELECT pg_temp.expect_error(format($$SELECT * FROM public.list_inventory_workspace_location_stock('7b100000-0000-4000-8000-000000000101', %L)$$,
  pg_temp.loc('other')), 'Inventory location not found');
SELECT pg_temp.expect_error($$SELECT public.list_inventory_workspace_item_balances('7b100000-0000-4000-8000-000000000101', '7b100000-0000-4000-8000-000000000511')$$,
  'Inventory item not found');
SELECT pg_temp.assert(NOT EXISTS (
  SELECT 1 FROM public.list_inventory_workspace_locations('7b100000-0000-4000-8000-000000000101', 'all', 500) l
  WHERE l.inventory_location_id = pg_temp.loc('other')), 'other organization locations never listed');
SELECT pg_temp.assert(NOT EXISTS (
  SELECT 1 FROM public.list_inventory_workspace_items('7b100000-0000-4000-8000-000000000101', '', '', 'all', 'all', 500) i
  WHERE i.inventory_item_id = '7b100000-0000-4000-8000-000000000511'), 'other organization items never listed');
-- Admins still read no raw location, balance, count or label rows: RLS is unchanged.
SELECT pg_temp.assert((SELECT count(*) FROM public.inventory_locations) = 0, 'admin raw locations hidden');
SELECT pg_temp.assert((SELECT count(*) FROM public.inventory_location_balances) = 0, 'admin raw balances hidden');
SELECT pg_temp.assert((SELECT count(*) FROM public.inventory_count_sessions) = 0, 'admin raw sessions hidden');
SELECT pg_temp.expect_error($$SELECT * FROM public.inventory_location_labels$$, 'permission denied');
RESET ROLE;

-- ---------------------------------------------------------------------------------------
-- 3. Locations: order, factual summaries, the locked countable rule, filters, paging.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b100000-0000-4000-8000-000000000002');
SELECT pg_temp.assert(
  (SELECT jsonb_agg(jsonb_build_array(name, kind, active, sort_group, stocked_item_count, countable_item_count,
     last_counted_by_name, active_label_count, last_counted_at IS NOT NULL, last_label_issued_at IS NOT NULL))
   FROM public.list_inventory_workspace_locations('7b100000-0000-4000-8000-000000000101'))
  = '[["Unassigned", "unassigned", true, 0, 4, null, null, null, false, false],
      ["Cabinet", "storage", true, 1, 3, 4, null, 2, false, true],
      ["Empty Room", "storage", true, 1, 0, 0, null, 0, false, false],
      ["Rehab", "storage", true, 1, 1, 1, "Staff Counter", 0, true, false],
      ["Closet", "storage", false, 2, 0, 0, null, 1, false, true]]'::jsonb,
  'location summaries');
SELECT pg_temp.assert(
  (SELECT array_agg(name) FROM public.list_inventory_workspace_locations('7b100000-0000-4000-8000-000000000101', 'active'))
  = ARRAY['Unassigned', 'Cabinet', 'Empty Room', 'Rehab'], 'active filter keeps Unassigned');
SELECT pg_temp.assert(
  (SELECT array_agg(name) FROM public.list_inventory_workspace_locations('7b100000-0000-4000-8000-000000000101', 'archived'))
  = ARRAY['Closet'], 'archived filter');
SELECT pg_temp.expect_error($$SELECT * FROM public.list_inventory_workspace_locations('7b100000-0000-4000-8000-000000000101', 'deleted')$$,
  'Choose active, archived or all');
SELECT pg_temp.expect_error($$SELECT * FROM public.list_inventory_workspace_locations('7b100000-0000-4000-8000-000000000101', 'all', 501)$$,
  'Page size');
SELECT pg_temp.expect_error($$SELECT * FROM public.list_inventory_workspace_locations('7b100000-0000-4000-8000-000000000101', 'all', 10, 1, NULL, NULL)$$,
  'incomplete page cursor');

-- The countable count is exactly the 7A.2 count page for every active storage location.
DO $countable$
DECLARE _row record;
BEGIN
  FOR _row IN SELECT * FROM public.list_inventory_workspace_locations('7b100000-0000-4000-8000-000000000101', 'active')
              WHERE kind = 'storage' LOOP
    PERFORM pg_temp.assert(_row.countable_item_count = jsonb_array_length(
      public.get_inventory_count_location('7b100000-0000-4000-8000-000000000101', _row.inventory_location_id)->'items'),
      'countable count matches the count page for ' || _row.name);
  END LOOP;
END
$countable$;

-- One row per page walks the same rows in the same order as one large page.
DO $paging$
DECLARE
  _all uuid[];
  _walked uuid[] := '{}';
  _row record;
  _group integer;
  _name text;
  _id uuid;
BEGIN
  SELECT array_agg(inventory_location_id) INTO _all
  FROM public.list_inventory_workspace_locations('7b100000-0000-4000-8000-000000000101', 'all', 500);
  LOOP
    SELECT * INTO _row FROM public.list_inventory_workspace_locations('7b100000-0000-4000-8000-000000000101', 'all', 1, _group, _name, _id);
    EXIT WHEN NOT FOUND;
    _walked := _walked || _row.inventory_location_id;
    _group := _row.sort_group; _name := _row.sort_name; _id := _row.inventory_location_id;
  END LOOP;
  PERFORM pg_temp.assert(_walked = _all AND cardinality(_all) = 5, 'location keyset paging');

  _all := NULL; _walked := '{}'; _name := NULL; _id := NULL;
  SELECT array_agg(inventory_item_id) INTO _all
  FROM public.list_inventory_workspace_location_stock('7b100000-0000-4000-8000-000000000101', pg_temp.loc('cabinet'), 500);
  LOOP
    SELECT * INTO _row FROM public.list_inventory_workspace_location_stock('7b100000-0000-4000-8000-000000000101',
      pg_temp.loc('cabinet'), 1, _name, _id);
    EXIT WHEN NOT FOUND;
    _walked := _walked || _row.inventory_item_id;
    _name := _row.sort_name; _id := _row.inventory_item_id;
  END LOOP;
  PERFORM pg_temp.assert(_walked = _all AND cardinality(_all) = 4, 'stock keyset paging');

  _all := NULL; _walked := '{}'; _name := NULL; _id := NULL;
  SELECT array_agg(inventory_item_id) INTO _all
  FROM public.list_inventory_workspace_items('7b100000-0000-4000-8000-000000000101', '', '', 'all', 'all', 500);
  LOOP
    SELECT * INTO _row FROM public.list_inventory_workspace_items('7b100000-0000-4000-8000-000000000101', '', '', 'all', 'all',
      1, _name, _id);
    EXIT WHEN NOT FOUND;
    _walked := _walked || _row.inventory_item_id;
    _name := _row.sort_name; _id := _row.inventory_item_id;
  END LOOP;
  PERFORM pg_temp.assert(_walked = _all AND cardinality(_all) = 6, 'item keyset paging');
END
$paging$;

-- ---------------------------------------------------------------------------------------
-- 4. Location detail and stock.
-- ---------------------------------------------------------------------------------------
SELECT pg_temp.assert(
  public.get_inventory_workspace_location('7b100000-0000-4000-8000-000000000101', pg_temp.loc('cabinet'))
    - 'id' - 'lastLabelIssuedAt'
  = '{"name": "Cabinet", "description": null, "kind": "storage", "active": true, "stockedItemCount": 3,
      "archivedStockedItemCount": 1, "countableItemCount": 4, "lastCountedAt": null, "lastCountedByName": null,
      "activeLabelCount": 2}'::jsonb, 'cabinet header');
SELECT pg_temp.assert(
  (public.get_inventory_workspace_location('7b100000-0000-4000-8000-000000000101', pg_temp.loc('rehab'))->>'lastCountedByName')
  = 'Staff Counter', 'rehab counted by');
SELECT pg_temp.assert(
  public.get_inventory_workspace_location('7b100000-0000-4000-8000-000000000101',
    pg_temp.unassigned('7b100000-0000-4000-8000-000000000101')) - 'id' - 'description'
  = '{"name": "Unassigned", "kind": "unassigned", "active": true, "stockedItemCount": 4,
      "archivedStockedItemCount": 1, "countableItemCount": null, "lastCountedAt": null, "lastCountedByName": null,
      "activeLabelCount": null, "lastLabelIssuedAt": null}'::jsonb, 'unassigned header');

-- Storage stock follows the countable rule: the zero balance of an active item stays, the
-- archived item with stock is shown as archived, the archived empty one is omitted.
SELECT pg_temp.assert(
  (SELECT jsonb_agg(jsonb_build_array(name, quantity, item_active, organization_quantity, organization_par_level,
     organization_stock_status, last_counted_at IS NOT NULL))
   FROM public.list_inventory_workspace_location_stock('7b100000-0000-4000-8000-000000000101', pg_temp.loc('cabinet')))
  = '[["P7B1 Archived Stocked", 5, false, 5, null, "inactive", false],
      ["P7B1 Gauze", 2.75, true, 2.75, 10, "critical", false],
      ["P7B1 Tape", 12, true, 20, 4, "healthy", false],
      ["P7B1 Zero Item", 0, true, 1, null, "healthy", false]]'::jsonb, 'cabinet stock');
SELECT pg_temp.assert(
  (SELECT jsonb_agg(jsonb_build_array(name, quantity, last_counted_at IS NOT NULL))
   FROM public.list_inventory_workspace_location_stock('7b100000-0000-4000-8000-000000000101', pg_temp.loc('rehab')))
  = '[["P7B1 Tape", 3, true]]'::jsonb, 'rehab stock with its count');
-- Unassigned lists what it holds, never zero rows.
SELECT pg_temp.assert(
  (SELECT jsonb_agg(jsonb_build_array(name, quantity, last_counted_at))
   FROM public.list_inventory_workspace_location_stock('7b100000-0000-4000-8000-000000000101',
     pg_temp.unassigned('7b100000-0000-4000-8000-000000000101')))
  = '[["P7B1 Archived Empty", 1, null], ["P7B1 Tape", 5, null], ["P7B1 Unassigned Only", 4, null], ["P7B1 Zero Item", 1, null]]'::jsonb,
  'unassigned stock');
SELECT pg_temp.assert(NOT EXISTS (
  SELECT 1 FROM public.list_inventory_workspace_location_stock('7b100000-0000-4000-8000-000000000101', pg_temp.loc('empty'))),
  'empty location has no stock rows');

-- ---------------------------------------------------------------------------------------
-- 5. Items: summaries and server-side filters.
-- ---------------------------------------------------------------------------------------
SELECT pg_temp.assert(
  (SELECT jsonb_agg(jsonb_build_array(name, active, quantity, stock_status, unassigned_quantity, physical_quantity,
     physical_location_count, single_physical_location_name))
   FROM public.list_inventory_workspace_items('7b100000-0000-4000-8000-000000000101', '', '', 'all'))
  = '[["P7B1 Archived Empty", false, 1, "inactive", 1, 0, 0, null],
      ["P7B1 Archived Stocked", false, 5, "inactive", 0, 5, 1, "Cabinet"],
      ["P7B1 Gauze", true, 2.75, "critical", 0, 2.75, 1, "Cabinet"],
      ["P7B1 Tape", true, 20, "healthy", 5, 15, 2, null],
      ["P7B1 Unassigned Only", true, 4, "low", 4, 0, 0, null],
      ["P7B1 Zero Item", true, 1, "healthy", 1, 0, 0, null]]'::jsonb, 'item summaries');
SELECT pg_temp.assert(
  (SELECT jsonb_agg(jsonb_build_array(name, description, sku, vendor_name, manufacturer, category, unit, par_level))
   FROM public.list_inventory_workspace_items('7b100000-0000-4000-8000-000000000101', 'tape'))
  = '[["P7B1 Tape", "Zinc oxide", "TAPE-1", "Secret Vendor", "Tape Co", "Taping", "roll", 4]]'::jsonb, 'item identity');
SELECT pg_temp.assert((SELECT array_agg(name) FROM public.list_inventory_workspace_items('7b100000-0000-4000-8000-000000000101', 'GAUZE-'))
  = ARRAY['P7B1 Gauze'], 'search by sku');
SELECT pg_temp.assert((SELECT array_agg(name) FROM public.list_inventory_workspace_items('7b100000-0000-4000-8000-000000000101', 'secret'))
  = ARRAY['P7B1 Tape'], 'search by vendor');
SELECT pg_temp.assert((SELECT array_agg(name) FROM public.list_inventory_workspace_items('7b100000-0000-4000-8000-000000000101', 'only co'))
  = ARRAY['P7B1 Unassigned Only'], 'search by manufacturer');
SELECT pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.list_inventory_workspace_items('7b100000-0000-4000-8000-000000000101', '%')),
  'search has no wildcards');
SELECT pg_temp.assert((SELECT array_agg(name) FROM public.list_inventory_workspace_items('7b100000-0000-4000-8000-000000000101', '', 'Wound'))
  = ARRAY['P7B1 Gauze'], 'category filter');
SELECT pg_temp.assert((SELECT array_agg(name) FROM public.list_inventory_workspace_items('7b100000-0000-4000-8000-000000000101', '', '', 'archived'))
  = ARRAY['P7B1 Archived Empty', 'P7B1 Archived Stocked'], 'archived filter');
SELECT pg_temp.assert((SELECT count(*) FROM public.list_inventory_workspace_items('7b100000-0000-4000-8000-000000000101')) = 4,
  'active by default');
SELECT pg_temp.assert((SELECT array_agg(name) FROM public.list_inventory_workspace_items('7b100000-0000-4000-8000-000000000101', '', '', 'all', 'low'))
  = ARRAY['P7B1 Gauze', 'P7B1 Unassigned Only'], 'organization-level low stock filter');

-- Item balances: every balance row, quantities summing to the organization total.
SELECT pg_temp.assert(
  (SELECT jsonb_agg(jsonb_build_array(b->>'inventoryLocationId', (b->>'quantity')::numeric) ORDER BY b->>'inventoryLocationId')
   FROM jsonb_array_elements(public.list_inventory_workspace_item_balances('7b100000-0000-4000-8000-000000000101',
     '7b100000-0000-4000-8000-000000000501')->'balances') b)
  = (SELECT jsonb_agg(jsonb_build_array(x.id::text, x.q) ORDER BY x.id::text) FROM (VALUES
      (pg_temp.unassigned('7b100000-0000-4000-8000-000000000101'), 5::numeric),
      (pg_temp.loc('cabinet'), 12::numeric), (pg_temp.loc('rehab'), 3::numeric)) x(id, q)),
  'item balances');
RESET ROLE;

-- ---------------------------------------------------------------------------------------
-- 6. Atomic Replace labels.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
-- Only the owner may replace.
DO $replace_refused$
DECLARE _user uuid;
BEGIN
  FOREACH _user IN ARRAY ARRAY['7b100000-0000-4000-8000-000000000002', '7b100000-0000-4000-8000-000000000003',
                               '7b100000-0000-4000-8000-000000000004', '7b100000-0000-4000-8000-000000000005',
                               '7b100000-0000-4000-8000-000000000007']::uuid[] LOOP
    PERFORM pg_temp.as_user(_user);
    PERFORM pg_temp.expect_error(format($$SELECT public.replace_inventory_location_labels('7b100000-0000-4000-8000-000000000101', %L)$$,
      pg_temp.loc('cabinet')), 'Forbidden: owner access required');
  END LOOP;
END
$replace_refused$;
SELECT pg_temp.as_user('7b100000-0000-4000-8000-000000000001');
SELECT pg_temp.expect_error(format($$SELECT public.replace_inventory_location_labels('7b100000-0000-4000-8000-000000000101', %L)$$,
  pg_temp.unassigned('7b100000-0000-4000-8000-000000000101')), 'Unassigned is not a physical location');
SELECT pg_temp.expect_error(format($$SELECT public.replace_inventory_location_labels('7b100000-0000-4000-8000-000000000101', %L)$$,
  pg_temp.loc('other')), 'Inventory location not found');
-- An archived location keeps its labels when Replace is refused.
SELECT pg_temp.expect_error(format($$SELECT public.replace_inventory_location_labels('7b100000-0000-4000-8000-000000000101', %L)$$,
  pg_temp.loc('closet')), 'Restore Closet before issuing a QR label');
SELECT pg_temp.assert(pg_temp.active_labels(pg_temp.loc('closet')) = 1, 'refused replace leaves the archived label');
RESET ROLE;

-- Forced failure after authorization and revocation, while issuing: nothing commits.
INSERT INTO phase7b1_values VALUES ('cabinet_labels_before', pg_temp.labels(pg_temp.loc('cabinet')));
CREATE FUNCTION public.phase7b1_fail_label_insert() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'phase7b1 forced label insert failure'; END; $$;
CREATE TRIGGER phase7b1_fail_label_insert BEFORE INSERT ON public.inventory_location_labels
  FOR EACH ROW EXECUTE FUNCTION public.phase7b1_fail_label_insert();
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b100000-0000-4000-8000-000000000001');
SELECT pg_temp.expect_error(format($$SELECT public.replace_inventory_location_labels('7b100000-0000-4000-8000-000000000101', %L)$$,
  pg_temp.loc('cabinet')), 'phase7b1 forced label insert failure');
RESET ROLE;
DROP TRIGGER phase7b1_fail_label_insert ON public.inventory_location_labels;
DROP FUNCTION public.phase7b1_fail_label_insert();
SELECT pg_temp.assert(pg_temp.labels(pg_temp.loc('cabinet')) = pg_temp.val('cabinet_labels_before'),
  'failed replace leaves every label exactly as before');
SELECT pg_temp.assert(pg_temp.active_labels(pg_temp.loc('cabinet')) = 2, 'both earlier labels still active');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b100000-0000-4000-8000-000000000003');
SELECT pg_temp.assert(public.resolve_inventory_count_label(pg_temp.val('cab1')->>'token')->>'status' = 'available',
  'old label still works after a failed replace');
RESET ROLE;

-- Success: every earlier label revoked, exactly one new one, token shown once and hashed.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b100000-0000-4000-8000-000000000001');
INSERT INTO phase7b1_values VALUES
  ('replaced', public.replace_inventory_location_labels('7b100000-0000-4000-8000-000000000101', pg_temp.loc('cabinet')));
RESET ROLE;
SELECT pg_temp.assert(
  (SELECT array_agg(key ORDER BY key COLLATE "C") FROM jsonb_object_keys(pg_temp.val('replaced')) key)
  = ARRAY['issuedAt', 'labelId', 'locationId', 'locationName', 'revokedCount', 'token'], 'replace result keys');
SELECT pg_temp.assert((pg_temp.val('replaced')->>'revokedCount')::int = 2, 'two labels revoked');
SELECT pg_temp.assert(pg_temp.val('replaced')->>'token' ~ '^[A-Za-z0-9_-]{43}$', 'token format');
SELECT pg_temp.assert(pg_temp.active_labels(pg_temp.loc('cabinet')) = 1, 'exactly one active label');
SELECT pg_temp.assert(
  (SELECT token_hash FROM public.inventory_location_labels WHERE id = (pg_temp.val('replaced')->>'labelId')::uuid)
  = encode(extensions.digest(pg_temp.val('replaced')->>'token', 'sha256'), 'hex'), 'only the hash is stored');
SELECT pg_temp.assert(NOT EXISTS (
  SELECT 1 FROM public.inventory_location_labels label
  WHERE label.inventory_location_id = pg_temp.loc('cabinet') AND label.revoked_at IS NULL
    AND label.id <> (pg_temp.val('replaced')->>'labelId')::uuid), 'the new label is the only active one');
SELECT pg_temp.assert(
  (SELECT bool_and(revoked_by = '7b100000-0000-4000-8000-000000000001') FROM public.inventory_location_labels
   WHERE inventory_location_id = pg_temp.loc('cabinet') AND revoked_at IS NOT NULL), 'revoked by the owner');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b100000-0000-4000-8000-000000000003');
SELECT pg_temp.assert(public.resolve_inventory_count_label(pg_temp.val('cab1')->>'token')->>'status' = 'replaced', 'old label 1 replaced');
SELECT pg_temp.assert(public.resolve_inventory_count_label(pg_temp.val('cab2')->>'token')->>'status' = 'replaced', 'old label 2 replaced');
SELECT pg_temp.assert(public.resolve_inventory_count_label(pg_temp.val('replaced')->>'token')->>'status' = 'available', 'new label works');
SELECT pg_temp.as_user('7b100000-0000-4000-8000-000000000002');
SELECT pg_temp.assert(
  (public.get_inventory_workspace_location('7b100000-0000-4000-8000-000000000101', pg_temp.loc('cabinet'))->>'activeLabelCount')::int = 1,
  'workspace shows one active label');
-- Replace with no active labels issues one and revokes none.
SELECT pg_temp.as_user('7b100000-0000-4000-8000-000000000001');
SELECT pg_temp.assert((public.replace_inventory_location_labels('7b100000-0000-4000-8000-000000000101', pg_temp.loc('empty'))->>'revokedCount')::int = 0,
  'replace on an unlabeled location');
SELECT pg_temp.assert(pg_temp.active_labels(pg_temp.loc('empty')) = 1, 'unlabeled location now has one label');
RESET ROLE;

-- ---------------------------------------------------------------------------------------
-- 7. Revoke-only, including archived locations. Restoring never revives a revoked label.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b100000-0000-4000-8000-000000000001');
SELECT pg_temp.assert(public.revoke_inventory_location_labels('7b100000-0000-4000-8000-000000000101', pg_temp.loc('closet')) = 1,
  'revoke the archived location label');
SELECT pg_temp.assert(pg_temp.active_labels(pg_temp.loc('closet')) = 0, 'archived location ends with zero labels');
SELECT pg_temp.assert(public.revoke_inventory_location_labels('7b100000-0000-4000-8000-000000000101', pg_temp.loc('closet')) = 0,
  'revoke again is a no-op');
SELECT public.set_inventory_location_active('7b100000-0000-4000-8000-000000000101', pg_temp.loc('closet'), true);
SELECT pg_temp.assert(pg_temp.active_labels(pg_temp.loc('closet')) = 0, 'restore issues nothing');
SELECT pg_temp.as_user('7b100000-0000-4000-8000-000000000003');
SELECT pg_temp.assert(public.resolve_inventory_count_label(pg_temp.val('closet')->>'token')->>'status' = 'replaced',
  'restoring does not reactivate a revoked label');
RESET ROLE;

-- ---------------------------------------------------------------------------------------
-- 8. Admins cannot change inventory through any path the workspace reaches.
-- ---------------------------------------------------------------------------------------
INSERT INTO phase7b1_values VALUES ('state_before_admin', pg_temp.state('7b100000-0000-4000-8000-000000000101'));
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b100000-0000-4000-8000-000000000002');
SELECT pg_temp.expect_error($$SELECT public.create_inventory_location('7b100000-0000-4000-8000-000000000101', 'Admin Cabinet')$$, 'Forbidden');
SELECT pg_temp.expect_error(format($$SELECT public.update_inventory_location('7b100000-0000-4000-8000-000000000101', %L, 'Renamed', NULL)$$,
  pg_temp.loc('cabinet')), 'Forbidden');
SELECT pg_temp.expect_error(format($$SELECT public.set_inventory_location_active('7b100000-0000-4000-8000-000000000101', %L, false)$$,
  pg_temp.loc('empty')), 'Forbidden');
SELECT pg_temp.expect_error(format($$SELECT public.set_inventory_location_active('7b100000-0000-4000-8000-000000000101', %L, true)$$,
  pg_temp.loc('closet')), 'Forbidden');
SELECT pg_temp.expect_error(format($$SELECT public.move_inventory_stock('7b100000-0000-4000-8000-000000000101',
  '7b100000-0000-4000-8000-000000000501', %L, %L, 1, 'admin-move')$$, pg_temp.loc('cabinet'), pg_temp.loc('rehab')), 'Forbidden');
SELECT pg_temp.expect_error(format($$SELECT public.adjust_inventory_location_quantity('7b100000-0000-4000-8000-000000000101',
  '7b100000-0000-4000-8000-000000000501', %L, -1, 'Damaged')$$, pg_temp.loc('cabinet')), 'Forbidden');
SELECT pg_temp.expect_error($$SELECT public.adjust_inventory_quantity('7b100000-0000-4000-8000-000000000101',
  '7b100000-0000-4000-8000-000000000501', 1, 'Correction')$$, 'Forbidden');
SELECT pg_temp.expect_error(format($$SELECT public.issue_inventory_location_label('7b100000-0000-4000-8000-000000000101', %L)$$,
  pg_temp.loc('cabinet')), 'Forbidden');
SELECT pg_temp.expect_error(format($$SELECT public.revoke_inventory_location_labels('7b100000-0000-4000-8000-000000000101', %L)$$,
  pg_temp.loc('cabinet')), 'Forbidden');
SELECT pg_temp.expect_error(format($$SELECT public.replace_inventory_location_labels('7b100000-0000-4000-8000-000000000101', %L)$$,
  pg_temp.loc('cabinet')), 'Forbidden');
-- Direct writes, as the item and category forms would send them.
SELECT pg_temp.expect_error($$INSERT INTO public.inventory_items (organization_id, name, unit, quantity)
  VALUES ('7b100000-0000-4000-8000-000000000101', 'Admin Item', 'each', 0)$$, 'row-level security');
UPDATE public.inventory_items SET name = 'Admin Renamed', par_level = 99
WHERE id = '7b100000-0000-4000-8000-000000000501';
UPDATE public.inventory_items SET active = false WHERE id = '7b100000-0000-4000-8000-000000000501';
SELECT pg_temp.expect_error($$INSERT INTO public.inventory_categories (organization_id, name)
  VALUES ('7b100000-0000-4000-8000-000000000101', 'Admin Category')$$, 'row-level security');
UPDATE public.inventory_categories SET name = 'Admin Renamed' WHERE organization_id = '7b100000-0000-4000-8000-000000000101';
DELETE FROM public.inventory_categories WHERE organization_id = '7b100000-0000-4000-8000-000000000101';
SELECT pg_temp.expect_error($$INSERT INTO public.inventory_locations (organization_id, name)
  VALUES ('7b100000-0000-4000-8000-000000000101', 'Admin Direct')$$, 'permission denied');
SELECT pg_temp.expect_error($$UPDATE public.inventory_location_balances SET quantity = 0$$, 'permission denied');
SELECT pg_temp.expect_error($$INSERT INTO public.inventory_adjustments (organization_id, inventory_item_id, adjustment_amount,
  previous_quantity, new_quantity, reason, created_by) VALUES ('7b100000-0000-4000-8000-000000000101',
  '7b100000-0000-4000-8000-000000000501', 1, 20, 21, 'Correction', '7b100000-0000-4000-8000-000000000002')$$, 'permission denied');
RESET ROLE;
SELECT pg_temp.assert(pg_temp.state('7b100000-0000-4000-8000-000000000101') = pg_temp.val('state_before_admin'),
  'every admin mutation attempt left inventory unchanged');

SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
