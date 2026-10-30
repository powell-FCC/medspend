-- Phase 7B.4 rollback-only behavioral verification: the owner+admin Inventory Overview.
-- Run against a disposable database after every migration through
-- 20261030120000_phase7b4_inventory_overview.sql. Every fixture is rolled back; SET
-- CONSTRAINTS ALL IMMEDIATE before the rollback evaluates the deferred quantity invariant
-- for every row this suite touched.

BEGIN;

DO $phase7b4_fixture_guard$
BEGIN
  IF EXISTS (SELECT 1 FROM auth.users
             WHERE id BETWEEN '7b400000-0000-4000-8000-000000000001'::uuid AND '7b400000-0000-4000-8000-000000000099'::uuid)
     OR EXISTS (SELECT 1 FROM public.organizations
             WHERE id BETWEEN '7b400000-0000-4000-8000-000000000101'::uuid AND '7b400000-0000-4000-8000-000000000199'::uuid) THEN
    RAISE EXCEPTION 'Phase 7B.4 rollback-test fixture IDs already exist';
  END IF;
END
$phase7b4_fixture_guard$;

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

CREATE TEMP TABLE phase7b4_values (name text PRIMARY KEY, value jsonb) ON COMMIT DROP;
GRANT ALL ON phase7b4_values TO authenticated, anon;

CREATE FUNCTION pg_temp.val(_name text)
RETURNS jsonb LANGUAGE sql AS $$ SELECT value FROM phase7b4_values WHERE name = _name $$;
CREATE FUNCTION pg_temp.loc(_name text)
RETURNS uuid LANGUAGE sql AS $$ SELECT (value #>> '{}')::uuid FROM phase7b4_values WHERE name = 'loc:' || _name $$;
CREATE FUNCTION pg_temp.unassigned(_organization uuid)
RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM public.inventory_locations WHERE organization_id = _organization AND kind = 'unassigned' $$;

-- The names in one attention list, in order.
CREATE FUNCTION pg_temp.names(_overview jsonb, _list text)
RETURNS text[] LANGUAGE sql AS $$
  SELECT coalesce(array_agg(row->>'name' ORDER BY ordinality), '{}')
  FROM jsonb_array_elements(_overview->'attention'->_list->'rows') WITH ORDINALITY AS t(row, ordinality) $$;
CREATE FUNCTION pg_temp.total(_overview jsonb, _list text)
RETURNS integer LANGUAGE sql AS $$ SELECT (_overview->'attention'->_list->>'total')::integer $$;

CREATE FUNCTION pg_temp.count(_organization uuid, _location uuid, _key text)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.submit_inventory_count(_organization, _location, (
    SELECT jsonb_agg(jsonb_build_object(
        'inventoryItemId', item->>'inventoryItemId',
        'observedVersion', (item->>'version')::bigint,
        'countedQuantity', item->>'quantity'))
    FROM jsonb_array_elements(public.get_inventory_count_location(_organization, _location)->'items') item), _key)
$$;

-- Everything a read must leave alone.
CREATE FUNCTION pg_temp.state(_organization uuid)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT jsonb_build_object(
    'items', (SELECT coalesce(jsonb_agg(to_jsonb(item) ORDER BY id), '[]') FROM public.inventory_items item WHERE organization_id = _organization),
    'locations', (SELECT coalesce(jsonb_agg(to_jsonb(location) ORDER BY id), '[]') FROM public.inventory_locations location WHERE organization_id = _organization),
    'balances', (SELECT coalesce(jsonb_agg(to_jsonb(balance) ORDER BY inventory_item_id, inventory_location_id), '[]')
                 FROM public.inventory_location_balances balance WHERE organization_id = _organization),
    'labels', (SELECT coalesce(jsonb_agg(to_jsonb(label) ORDER BY id), '[]') FROM public.inventory_location_labels label WHERE organization_id = _organization),
    'transfers', (SELECT coalesce(jsonb_agg(to_jsonb(transfer) ORDER BY id), '[]') FROM public.inventory_transfers transfer WHERE organization_id = _organization),
    'adjustments', (SELECT coalesce(jsonb_agg(to_jsonb(adjustment) ORDER BY id), '[]') FROM public.inventory_adjustments adjustment WHERE organization_id = _organization),
    'sessions', (SELECT coalesce(jsonb_agg(to_jsonb(session) ORDER BY id), '[]') FROM public.inventory_count_sessions session WHERE organization_id = _organization),
    'lines', (SELECT coalesce(jsonb_agg(to_jsonb(line) ORDER BY id), '[]') FROM public.inventory_count_lines line WHERE organization_id = _organization))
$$;

-- ---------------------------------------------------------------------------------------
-- Fixtures. A: owner 001, admin 002, staff 003, owner 006 (removed later: a former member).
-- B: owner 004, admin 005. 007 belongs to nothing.
-- ---------------------------------------------------------------------------------------
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('7b400000-0000-4000-8000-00000000000' || n)::uuid, 'authenticated', 'authenticated',
  'phase7b4-' || n || '@example.invalid', '', now(), '{}',
  CASE n WHEN 1 THEN '{"full_name": "Olivia Owner"}'::jsonb WHEN 3 THEN '{"full_name": "Sam Staff"}'::jsonb
         ELSE '{}'::jsonb END, now(), now()
FROM generate_series(1, 7) n;

INSERT INTO public.organizations (id, name, created_by) VALUES
  ('7b400000-0000-4000-8000-000000000101', 'Phase 7B.4 Organization', '7b400000-0000-4000-8000-000000000001'),
  ('7b400000-0000-4000-8000-000000000102', 'Phase 7B.4 Other Organization', '7b400000-0000-4000-8000-000000000004');

INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES
  ('7b400000-0000-4000-8000-000000000101', '7b400000-0000-4000-8000-000000000001', 'owner', true),
  ('7b400000-0000-4000-8000-000000000101', '7b400000-0000-4000-8000-000000000002', 'admin', true),
  ('7b400000-0000-4000-8000-000000000101', '7b400000-0000-4000-8000-000000000003', 'staff', true),
  ('7b400000-0000-4000-8000-000000000101', '7b400000-0000-4000-8000-000000000006', 'owner', true),
  ('7b400000-0000-4000-8000-000000000102', '7b400000-0000-4000-8000-000000000004', 'owner', true),
  ('7b400000-0000-4000-8000-000000000102', '7b400000-0000-4000-8000-000000000005', 'admin', true);

-- Items start in Unassigned (inserted as postgres).
--   Tape    active, 10 roll   -> 6 to Shelf (counted), 4 to Cart
--   Gauze   active, 3 box     -> all to Cart (never counted)
--   Wrap    active, 5 each    -> stays in Unassigned
--   Saline  active, 0 bottle  -> a zero Unassigned balance only
--   Old Kit 2 each            -> to Cart, then archived with stock (still countable)
--   Spare   1 each            -> to Cart, adjusted to 0 there, archived (a zero balance at
--                                Cart that is not countable)
INSERT INTO public.inventory_items (id, organization_id, sku, name, unit, quantity, last_purchase_price, active) VALUES
  ('7b400000-0000-4000-8000-000000000501', '7b400000-0000-4000-8000-000000000101', 'TAPE-1', 'P7B4 Tape', 'roll', 10, 9.87, true),
  ('7b400000-0000-4000-8000-000000000502', '7b400000-0000-4000-8000-000000000101', 'GAUZE-1', 'P7B4 Gauze', 'box', 3, NULL, true),
  ('7b400000-0000-4000-8000-000000000503', '7b400000-0000-4000-8000-000000000101', NULL, 'P7B4 Wrap', 'each', 5, NULL, true),
  ('7b400000-0000-4000-8000-000000000504', '7b400000-0000-4000-8000-000000000101', 'SAL-1', 'P7B4 Saline', 'bottle', 0, NULL, true),
  ('7b400000-0000-4000-8000-000000000505', '7b400000-0000-4000-8000-000000000101', 'KIT-1', 'P7B4 Old Kit', 'each', 2, NULL, true),
  ('7b400000-0000-4000-8000-000000000506', '7b400000-0000-4000-8000-000000000101', NULL, 'P7B4 Spare', 'each', 1, NULL, true),
  ('7b400000-0000-4000-8000-000000000511', '7b400000-0000-4000-8000-000000000102', 'TAPE-1', 'P7B4 Other Tape', 'roll', 7, NULL, true);

SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b400000-0000-4000-8000-000000000001');
INSERT INTO phase7b4_values VALUES
  ('loc:shelf', to_jsonb(public.create_inventory_location('7b400000-0000-4000-8000-000000000101', 'Shelf', NULL))),
  ('loc:cart', to_jsonb(public.create_inventory_location('7b400000-0000-4000-8000-000000000101', 'Cart', NULL))),
  ('loc:bay', to_jsonb(public.create_inventory_location('7b400000-0000-4000-8000-000000000101', 'Empty Bay', NULL))),
  ('loc:closet', to_jsonb(public.create_inventory_location('7b400000-0000-4000-8000-000000000101', 'Closet', NULL))),
  ('loc:oldroom', to_jsonb(public.create_inventory_location('7b400000-0000-4000-8000-000000000101', 'Old Room', NULL)));
SELECT public.move_inventory_stock('7b400000-0000-4000-8000-000000000101', '7b400000-0000-4000-8000-000000000501',
  pg_temp.unassigned('7b400000-0000-4000-8000-000000000101'), pg_temp.loc('shelf'), 6, 'mv-tape-shelf');
SELECT public.move_inventory_stock('7b400000-0000-4000-8000-000000000101', '7b400000-0000-4000-8000-000000000501',
  pg_temp.unassigned('7b400000-0000-4000-8000-000000000101'), pg_temp.loc('cart'), 4, 'mv-tape-cart');
SELECT public.move_inventory_stock('7b400000-0000-4000-8000-000000000101', '7b400000-0000-4000-8000-000000000502',
  pg_temp.unassigned('7b400000-0000-4000-8000-000000000101'), pg_temp.loc('cart'), 3, 'mv-gauze-cart');
SELECT public.move_inventory_stock('7b400000-0000-4000-8000-000000000101', '7b400000-0000-4000-8000-000000000505',
  pg_temp.unassigned('7b400000-0000-4000-8000-000000000101'), pg_temp.loc('cart'), 2, 'mv-kit-cart');
SELECT public.move_inventory_stock('7b400000-0000-4000-8000-000000000101', '7b400000-0000-4000-8000-000000000506',
  pg_temp.unassigned('7b400000-0000-4000-8000-000000000101'), pg_temp.loc('cart'), 1, 'mv-spare-cart');
SELECT public.adjust_inventory_location_quantity('7b400000-0000-4000-8000-000000000101',
  '7b400000-0000-4000-8000-000000000506', pg_temp.loc('cart'), -1, 'Expired');
-- Closet briefly holds Gauze, so after archiving it keeps a zero balance of an active,
-- never-counted item. Archived locations are not countable, so Gauze stays at 1 location.
SELECT public.move_inventory_stock('7b400000-0000-4000-8000-000000000101', '7b400000-0000-4000-8000-000000000502',
  pg_temp.loc('cart'), pg_temp.loc('closet'), 1, 'mv-gauze-closet');
SELECT public.move_inventory_stock('7b400000-0000-4000-8000-000000000101', '7b400000-0000-4000-8000-000000000502',
  pg_temp.loc('closet'), pg_temp.loc('cart'), 1, 'mv-gauze-closet-back');
-- Labels: Shelf has one; Closet gets one and is then archived with it; Old Room had one,
-- revoked, then archived.
SELECT public.issue_inventory_location_label('7b400000-0000-4000-8000-000000000101', pg_temp.loc('shelf'));
SELECT public.issue_inventory_location_label('7b400000-0000-4000-8000-000000000101', pg_temp.loc('closet'));
SELECT public.issue_inventory_location_label('7b400000-0000-4000-8000-000000000101', pg_temp.loc('oldroom'));
SELECT public.revoke_inventory_location_labels('7b400000-0000-4000-8000-000000000101', pg_temp.loc('oldroom'));
SELECT public.set_inventory_location_active('7b400000-0000-4000-8000-000000000101', pg_temp.loc('closet'), false);
SELECT public.set_inventory_location_active('7b400000-0000-4000-8000-000000000101', pg_temp.loc('oldroom'), false);
-- Staff count Shelf (Tape only), matching.
SELECT pg_temp.as_user('7b400000-0000-4000-8000-000000000003');
INSERT INTO phase7b4_values VALUES ('count:shelf', pg_temp.count('7b400000-0000-4000-8000-000000000101', pg_temp.loc('shelf'), 'k-shelf'));
-- A manual adjustment at Cart by owner 006, who then leaves.
SELECT pg_temp.as_user('7b400000-0000-4000-8000-000000000006');
SELECT public.adjust_inventory_location_quantity('7b400000-0000-4000-8000-000000000101',
  '7b400000-0000-4000-8000-000000000502', pg_temp.loc('cart'), -1, 'Damaged');
-- Organization B: one storage location, never counted, unlabelled.
SELECT pg_temp.as_user('7b400000-0000-4000-8000-000000000004');
INSERT INTO phase7b4_values VALUES
  ('loc:other', to_jsonb(public.create_inventory_location('7b400000-0000-4000-8000-000000000102', 'Other Cabinet', NULL)));
SELECT public.move_inventory_stock('7b400000-0000-4000-8000-000000000102', '7b400000-0000-4000-8000-000000000511',
  pg_temp.unassigned('7b400000-0000-4000-8000-000000000102'), pg_temp.loc('other'), 3, 'mv-other');
RESET ROLE;
DELETE FROM public.organization_memberships
WHERE organization_id = '7b400000-0000-4000-8000-000000000101' AND user_id = '7b400000-0000-4000-8000-000000000006';
-- Old Kit and Spare are archived (Old Kit keeps 2 at Cart).
UPDATE public.inventory_items SET active = false
WHERE id IN ('7b400000-0000-4000-8000-000000000505', '7b400000-0000-4000-8000-000000000506');
-- Recent-history fixtures with chosen timestamps (as postgres): 7 one-line counts of Tape at
-- Shelf a day apart, 7 manual adjustments and 2 invoice receipts. The real counts supply the
-- physical_count adjustment rows.
INSERT INTO public.inventory_count_sessions (id, organization_id, inventory_location_id, counted_by, submitted_at,
  line_count, changed_count, idempotency_key, request_hash)
SELECT ('7b400000-0000-4000-8000-0000000a000' || n)::uuid, '7b400000-0000-4000-8000-000000000101', pg_temp.loc('shelf'),
  '7b400000-0000-4000-8000-000000000003', timestamptz '2026-01-01 12:00:00+00' + n * interval '1 day', 1, 0,
  'hist-' || n, repeat('0', 64)
FROM generate_series(1, 7) n;
INSERT INTO public.inventory_count_lines (organization_id, count_session_id, inventory_item_id, inventory_location_id,
  previous_quantity, counted_quantity, delta, observed_version, item_name, item_sku, item_unit, created_at)
SELECT session.organization_id, session.id, '7b400000-0000-4000-8000-000000000501', session.inventory_location_id,
  6, 6, 0, 1, 'P7B4 Tape', 'TAPE-1', 'roll', session.submitted_at
FROM public.inventory_count_sessions session WHERE session.idempotency_key LIKE 'hist-%'
  AND session.organization_id = '7b400000-0000-4000-8000-000000000101';
INSERT INTO public.inventory_adjustments (id, organization_id, inventory_item_id, inventory_location_id, adjustment_amount,
  previous_quantity, new_quantity, reason, created_by, created_at, source_type)
SELECT ('7b400000-0000-4000-8000-0000000b000' || n)::uuid, '7b400000-0000-4000-8000-000000000101',
  '7b400000-0000-4000-8000-000000000501', pg_temp.loc('shelf'), 1, 20, 21, 'Correction',
  '7b400000-0000-4000-8000-000000000001', timestamptz '2026-01-01 12:00:00+00' + n * interval '1 day', 'manual'
FROM generate_series(1, 7) n;
INSERT INTO public.inventory_adjustments (organization_id, inventory_item_id, inventory_location_id, adjustment_amount,
  previous_quantity, new_quantity, reason, created_by, created_at, source_type)
SELECT '7b400000-0000-4000-8000-000000000101', '7b400000-0000-4000-8000-000000000501',
  pg_temp.unassigned('7b400000-0000-4000-8000-000000000101'), 1, 20, 21, 'Invoice received',
  '7b400000-0000-4000-8000-000000000001', now() + n * interval '1 minute', 'invoice'
FROM generate_series(1, 2) n;

-- ---------------------------------------------------------------------------------------
-- 1. Contract.
-- ---------------------------------------------------------------------------------------
SELECT pg_temp.assert(pg_get_function_result('public.get_inventory_overview(uuid, integer)'::regprocedure) = 'jsonb'
  AND pg_get_function_arguments('public.get_inventory_overview(uuid, integer)'::regprocedure)
    = '_organization_id uuid, _attention_limit integer DEFAULT 10', 'overview contract');
SELECT pg_temp.assert((SELECT p.provolatile = 's' AND p.prosecdef AND p.proconfig @> ARRAY['search_path=public']
    AND pg_get_functiondef(p.oid) !~* '(price|last_purchase|email|raw_user_meta|insert into|update public|delete from)'
  FROM pg_proc p WHERE p.oid = 'public.get_inventory_overview(uuid, integer)'::regprocedure),
  'STABLE SECURITY DEFINER, fixed search_path, no prices, auth metadata or writes');
SELECT pg_temp.assert(NOT has_function_privilege('anon', 'public.get_inventory_overview(uuid, integer)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.get_inventory_overview(uuid, integer)', 'EXECUTE')
  AND NOT EXISTS (SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
                  WHERE p.oid = 'public.get_inventory_overview(uuid, integer)'::regprocedure
                    AND acl.grantee = 0 AND acl.privilege_type = 'EXECUTE'),
  'authenticated EXECUTE only');

-- ---------------------------------------------------------------------------------------
-- 2. Authorization.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b400000-0000-4000-8000-000000000001');
INSERT INTO phase7b4_values VALUES ('owner', public.get_inventory_overview('7b400000-0000-4000-8000-000000000101'));
SELECT pg_temp.as_user('7b400000-0000-4000-8000-000000000002');
SELECT pg_temp.assert(public.get_inventory_overview('7b400000-0000-4000-8000-000000000101') = pg_temp.val('owner'),
  'admin overview is identical to the owner''s');
SELECT pg_temp.assert(
  (SELECT array_agg(key ORDER BY key COLLATE "C") FROM jsonb_object_keys(pg_temp.val('owner')) key) = ARRAY['attention', 'snapshot']
  AND (SELECT array_agg(key ORDER BY key COLLATE "C") FROM jsonb_object_keys(pg_temp.val('owner')->'attention') key)
    = ARRAY['archivedWithActiveLabel', 'neverCountedItems', 'neverCountedLocations', 'noActiveLabel', 'unassignedStock']
  AND (SELECT array_agg(key ORDER BY key COLLATE "C") FROM jsonb_object_keys(pg_temp.val('owner')->'snapshot') key)
    = ARRAY['activeItemCount', 'activeStorageLocationCount', 'archivedStorageLocationCount', 'itemsInStockCount',
            'recordedQuantity', 'stockedUnitCount', 'unassignedItemCount', 'unassignedLocationId', 'unassignedQuantity'],
  'overview keys');
CREATE FUNCTION pg_temp.expect_refused(_user_id uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.as_user(_user_id);
  PERFORM pg_temp.expect_error(
    $q$SELECT public.get_inventory_overview('7b400000-0000-4000-8000-000000000101')$q$, 'owner or admin access required');
END;
$$;
-- Staff, B's owner and admin, the former member, a non-member and no user at all.
SELECT pg_temp.expect_refused(user_id)
FROM (VALUES ('7b400000-0000-4000-8000-000000000003'::uuid), ('7b400000-0000-4000-8000-000000000004'::uuid),
             ('7b400000-0000-4000-8000-000000000005'::uuid), ('7b400000-0000-4000-8000-000000000006'::uuid),
             ('7b400000-0000-4000-8000-000000000007'::uuid), (NULL::uuid)) AS refused(user_id);
SELECT pg_temp.as_user('7b400000-0000-4000-8000-000000000001');
SELECT pg_temp.expect_error($$SELECT public.get_inventory_overview('7b400000-0000-4000-8000-000000000101', 0)$$, 'between 1 and 50');
SELECT pg_temp.expect_error($$SELECT public.get_inventory_overview('7b400000-0000-4000-8000-000000000101', 51)$$, 'between 1 and 50');
SELECT pg_temp.expect_error($$SELECT public.get_inventory_overview('7b400000-0000-4000-8000-000000000101', NULL)$$, 'between 1 and 50');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.expect_error($$SELECT public.get_inventory_overview('7b400000-0000-4000-8000-000000000101')$$, 'permission denied');
RESET ROLE;
-- Raw tables stay closed to admins and staff.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b400000-0000-4000-8000-000000000002');
SELECT pg_temp.assert((SELECT count(*) FROM public.inventory_location_balances) = 0
  AND (SELECT count(*) FROM public.inventory_count_lines) = 0 AND (SELECT count(*) FROM public.inventory_locations) = 0,
  'admin raw inventory reads stay empty (RLS not broadened)');
SELECT pg_temp.as_user('7b400000-0000-4000-8000-000000000003');
SELECT pg_temp.assert((SELECT count(*) FROM public.inventory_location_balances) = 0, 'staff raw balance reads stay empty');
RESET ROLE;

-- ---------------------------------------------------------------------------------------
-- 3. Snapshot.
-- ---------------------------------------------------------------------------------------
SELECT pg_temp.assert(pg_temp.val('owner')->'snapshot' = jsonb_build_object(
    'activeItemCount', 4, 'itemsInStockCount', 4, 'recordedQuantity', 19, 'stockedUnitCount', 3,
    'activeStorageLocationCount', 3, 'archivedStorageLocationCount', 2,
    'unassignedLocationId', pg_temp.unassigned('7b400000-0000-4000-8000-000000000101'),
    'unassignedItemCount', 1, 'unassignedQuantity', 5),
  'snapshot: 4 active of 6 items, 4 with stock, raw 9+2+5+2+0+0 = 19 in 3 units, 3 active and 2 archived storage locations, Wrap in Unassigned');

-- ---------------------------------------------------------------------------------------
-- 4. Stock in Unassigned: a positive balance only; zero balances never appear.
-- ---------------------------------------------------------------------------------------
SELECT pg_temp.assert(pg_temp.names(pg_temp.val('owner'), 'unassignedStock') = ARRAY['P7B4 Wrap']
  AND (pg_temp.val('owner')->'attention'->'unassignedStock'->'rows'->0) = jsonb_build_object(
    'inventoryItemId', '7b400000-0000-4000-8000-000000000503', 'name', 'P7B4 Wrap', 'sku', NULL, 'unit', 'each',
    'itemActive', true, 'quantity', 5),
  'only Wrap (5 each) is in Unassigned; Saline''s zero balance and moved-out items are not');
SELECT pg_temp.assert(NOT ('Unassigned' = ANY (pg_temp.names(pg_temp.val('owner'), 'neverCountedLocations')
    || pg_temp.names(pg_temp.val('owner'), 'noActiveLabel') || pg_temp.names(pg_temp.val('owner'), 'archivedWithActiveLabel'))),
  'Unassigned is never part of a count or label rule');

-- ---------------------------------------------------------------------------------------
-- 5. Never counted.
-- ---------------------------------------------------------------------------------------
SELECT pg_temp.assert(pg_temp.names(pg_temp.val('owner'), 'neverCountedLocations') = ARRAY['Cart']
  AND (pg_temp.val('owner')->'attention'->'neverCountedLocations'->'rows'->0->>'countableItemCount')::integer = 3,
  'Cart (3 countable items; archived Spare at 0 is not one) was never counted; Shelf was; Empty Bay has nothing to count; archived Closet (a zero Gauze balance) is not listed');
SELECT pg_temp.assert(pg_temp.names(pg_temp.val('owner'), 'neverCountedItems') = ARRAY['P7B4 Gauze', 'P7B4 Old Kit']
  AND (SELECT bool_and(row->>'locationCount' = '1') FROM jsonb_array_elements(pg_temp.val('owner')->'attention'->'neverCountedItems'->'rows') row)
  AND (pg_temp.val('owner')->'attention'->'neverCountedItems'->'rows'->1->>'itemActive') = 'false',
  'Gauze and archived-with-stock Old Kit were never counted; Tape has a count line; Wrap is only in Unassigned; archived Spare at 0 is not countable');

-- ---------------------------------------------------------------------------------------
-- 6. Labels.
-- ---------------------------------------------------------------------------------------
SELECT pg_temp.assert(pg_temp.names(pg_temp.val('owner'), 'noActiveLabel') = ARRAY['Cart', 'Empty Bay'],
  'active storage locations without an active label; Shelf has one');
SELECT pg_temp.assert(pg_temp.names(pg_temp.val('owner'), 'archivedWithActiveLabel') = ARRAY['Closet']
  AND (pg_temp.val('owner')->'attention'->'archivedWithActiveLabel'->'rows'->0->>'activeLabelCount')::integer = 1,
  'Closet was archived with an active label; Old Room''s label was revoked first');

-- ---------------------------------------------------------------------------------------
-- 7. Bounded lists keep their totals; changes show up on the next read.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b400000-0000-4000-8000-000000000001');
SELECT pg_temp.assert(pg_temp.names(public.get_inventory_overview('7b400000-0000-4000-8000-000000000101', 1), 'noActiveLabel') = ARRAY['Cart']
  AND pg_temp.total(public.get_inventory_overview('7b400000-0000-4000-8000-000000000101', 1), 'noActiveLabel') = 2
  AND pg_temp.total(public.get_inventory_overview('7b400000-0000-4000-8000-000000000101', 1), 'neverCountedItems') = 2,
  'a list of one still reports its full total');
-- Counting Cart clears both never-counted lists; a label on Cart clears it from no-label.
SELECT pg_temp.count('7b400000-0000-4000-8000-000000000101', pg_temp.loc('cart'), 'k-cart');
SELECT public.issue_inventory_location_label('7b400000-0000-4000-8000-000000000101', pg_temp.loc('cart'));
SELECT pg_temp.assert(pg_temp.total(public.get_inventory_overview('7b400000-0000-4000-8000-000000000101'), 'neverCountedLocations') = 0
  AND pg_temp.total(public.get_inventory_overview('7b400000-0000-4000-8000-000000000101'), 'neverCountedItems') = 0
  AND pg_temp.names(public.get_inventory_overview('7b400000-0000-4000-8000-000000000101'), 'noActiveLabel') = ARRAY['Empty Bay'],
  'a submitted count and an issued label clear their attention rows');
-- Moving Wrap out of Unassigned clears it; the zero balance left behind does not appear.
SELECT public.move_inventory_stock('7b400000-0000-4000-8000-000000000101', '7b400000-0000-4000-8000-000000000503',
  pg_temp.unassigned('7b400000-0000-4000-8000-000000000101'), pg_temp.loc('shelf'), 5, 'mv-wrap-shelf');
SELECT pg_temp.assert(pg_temp.total(public.get_inventory_overview('7b400000-0000-4000-8000-000000000101'), 'unassignedStock') = 0
  AND (public.get_inventory_overview('7b400000-0000-4000-8000-000000000101')->'snapshot'->>'unassignedItemCount')::integer = 0,
  'an empty Unassigned needs no attention');
-- Wrap is now at Shelf but never counted there or anywhere: it becomes a never-counted item.
SELECT pg_temp.assert(pg_temp.names(public.get_inventory_overview('7b400000-0000-4000-8000-000000000101'), 'neverCountedItems') = ARRAY['P7B4 Wrap'],
  'an item placed in a counted location is still never counted until a count records it');
RESET ROLE;

-- ---------------------------------------------------------------------------------------
-- 8. Unassigned cannot gain counts or labels.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b400000-0000-4000-8000-000000000001');
SELECT pg_temp.expect_error(format($$SELECT public.issue_inventory_location_label(%L, %L)$$,
  '7b400000-0000-4000-8000-000000000101', pg_temp.unassigned('7b400000-0000-4000-8000-000000000101')), 'Unassigned');
SELECT pg_temp.expect_error(format($$SELECT public.get_inventory_count_location(%L, %L)$$,
  '7b400000-0000-4000-8000-000000000101', pg_temp.unassigned('7b400000-0000-4000-8000-000000000101')),
  'not available for counting');
RESET ROLE;

-- ---------------------------------------------------------------------------------------
-- 9. Organizations are isolated.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b400000-0000-4000-8000-000000000005');
SELECT pg_temp.assert((SELECT
    pg_temp.names(o, 'neverCountedLocations') = ARRAY['Other Cabinet'] AND pg_temp.names(o, 'noActiveLabel') = ARRAY['Other Cabinet']
    AND pg_temp.names(o, 'neverCountedItems') = ARRAY['P7B4 Other Tape'] AND pg_temp.names(o, 'unassignedStock') = ARRAY['P7B4 Other Tape']
    AND pg_temp.total(o, 'archivedWithActiveLabel') = 0 AND (o->'snapshot'->>'activeItemCount')::integer = 1
    AND (o->'snapshot'->>'recordedQuantity')::numeric = 7
  FROM (SELECT public.get_inventory_overview('7b400000-0000-4000-8000-000000000102') o) b),
  'organization B sees only its own state');
RESET ROLE;

-- ---------------------------------------------------------------------------------------
-- 10. Recent activity comes from the existing reads with a page of five, newest first.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b400000-0000-4000-8000-000000000002');
SELECT pg_temp.assert((SELECT array_agg(row.submitted_at ORDER BY ordinality) = (SELECT array_agg(x ORDER BY x DESC) FROM unnest(array_agg(row.submitted_at)) x)
    AND count(*) = 5
  FROM public.list_inventory_count_history('7b400000-0000-4000-8000-000000000101', _limit => 5) WITH ORDINALITY AS row),
  'five counts, newest first');
SELECT pg_temp.assert((SELECT count(*) = 5 AND bool_and(row.created_at = now())
  FROM public.list_inventory_transfer_history('7b400000-0000-4000-8000-000000000101', _limit => 5) row),
  'five transfers, newest first');
SELECT pg_temp.assert((SELECT array_agg(row.reason ORDER BY row.reason) = ARRAY['Correction', 'Correction', 'Correction', 'Damaged', 'Expired']
    AND (array_agg(row.created_at ORDER BY ordinality))[1:2] = ARRAY[now(), now()]
    AND (array_agg(row.created_at ORDER BY ordinality))[3] = timestamptz '2026-01-08 12:00:00+00'
    AND bool_and(row.source_type = 'manual')
  FROM public.list_inventory_adjustment_history('7b400000-0000-4000-8000-000000000101', _limit => 5) WITH ORDINALITY AS row),
  'five manual adjustments, newest first: no physical_count rows from the counts, no invoice receipts');
RESET ROLE;
SELECT pg_temp.assert((SELECT count(*) FROM public.inventory_adjustments WHERE organization_id = '7b400000-0000-4000-8000-000000000101'
  AND source_type = 'physical_count') >= 2 AND (SELECT count(*) FROM public.inventory_adjustments
  WHERE organization_id = '7b400000-0000-4000-8000-000000000101' AND source_type = 'invoice') = 2,
  'the fixture does hold physical-count and invoice rows to exclude');

-- ---------------------------------------------------------------------------------------
-- 11. Reads change nothing.
-- ---------------------------------------------------------------------------------------
INSERT INTO phase7b4_values VALUES ('state_before_reads', pg_temp.state('7b400000-0000-4000-8000-000000000101'));
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b400000-0000-4000-8000-000000000001');
SELECT public.get_inventory_overview('7b400000-0000-4000-8000-000000000101', 50);
SELECT pg_temp.as_user('7b400000-0000-4000-8000-000000000002');
SELECT public.get_inventory_overview('7b400000-0000-4000-8000-000000000101');
RESET ROLE;
SELECT pg_temp.assert(pg_temp.state('7b400000-0000-4000-8000-000000000101') = pg_temp.val('state_before_reads'),
  'overview reads left inventory, labels, history and counts unchanged');

SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
