-- Phase 7D rollback-only behavioral verification: replenishment rules, the live calculation,
-- the read functions and the transfer source marker. Run against a disposable database after
-- every migration through 20261113120000_phase7d_inventory_replenishment.sql. Every fixture is
-- rolled back; SET CONSTRAINTS ALL IMMEDIATE before the rollback evaluates the deferred quantity
-- invariant.

BEGIN;

DO $phase7d_fixture_guard$
BEGIN
  IF EXISTS (SELECT 1 FROM auth.users
             WHERE id BETWEEN '7d000000-0000-4000-8000-000000000001'::uuid AND '7d000000-0000-4000-8000-000000000099'::uuid)
     OR EXISTS (SELECT 1 FROM public.organizations
             WHERE id BETWEEN '7d000000-0000-4000-8000-000000000101'::uuid AND '7d000000-0000-4000-8000-000000000199'::uuid) THEN
    RAISE EXCEPTION 'Phase 7D rollback-test fixture IDs already exist';
  END IF;
END
$phase7d_fixture_guard$;

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

CREATE TEMP TABLE phase7d_values (name text PRIMARY KEY, value jsonb) ON COMMIT DROP;
GRANT ALL ON phase7d_values TO authenticated, anon;
CREATE FUNCTION pg_temp.val(_name text)
RETURNS jsonb LANGUAGE sql AS $$ SELECT value FROM phase7d_values WHERE name = _name $$;
CREATE FUNCTION pg_temp.loc(_name text)
RETURNS uuid LANGUAGE sql AS $$ SELECT (value #>> '{}')::uuid FROM phase7d_values WHERE name = 'loc:' || _name $$;
CREATE FUNCTION pg_temp.unassigned()
RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM public.inventory_locations WHERE organization_id = '7d000000-0000-4000-8000-000000000101' AND kind = 'unassigned' $$;
CREATE FUNCTION pg_temp.item(_n integer)
RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('7d000000-0000-4000-8000-000000000' || _n)::uuid $$;
-- The calculation for one (item, location), straight from the internal function (as postgres).
CREATE FUNCTION pg_temp.calc(_item integer, _location text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT to_jsonb(r) FROM public.inventory_replenishment_rows('7d000000-0000-4000-8000-000000000101') r
  WHERE r.inventory_item_id = pg_temp.item(_item) AND r.inventory_location_id = pg_temp.loc(_location) $$;
CREATE FUNCTION pg_temp.all_calc()
RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.rule_id), '[]')
  FROM public.inventory_replenishment_rows('7d000000-0000-4000-8000-000000000101') r $$;
CREATE FUNCTION pg_temp.rule_id(_item integer, _location text)
RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM public.inventory_replenishment_rules
  WHERE inventory_item_id = pg_temp.item(_item) AND inventory_location_id = pg_temp.loc(_location) $$;
CREATE FUNCTION pg_temp.rule_ts(_item integer, _location text)
RETURNS timestamptz LANGUAGE sql SECURITY DEFINER AS $$
  SELECT updated_at FROM public.inventory_replenishment_rules
  WHERE inventory_item_id = pg_temp.item(_item) AND inventory_location_id = pg_temp.loc(_location) $$;
CREATE FUNCTION pg_temp.donor_names(_row jsonb)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(string_agg((d->>'name') || '=' || (d->>'spareQuantity'), ',' ORDER BY o), '')
  FROM jsonb_array_elements(_row->'donors') WITH ORDINALITY AS e(d, o) $$;
CREATE FUNCTION pg_temp.donor_takes(_row jsonb)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(string_agg((d->>'name') || '=' || (d->>'moveQuantity'), ',' ORDER BY o), '')
  FROM jsonb_array_elements(_row->'donors') WITH ORDINALITY AS e(d, o) $$;
CREATE FUNCTION pg_temp.put(_item integer, _location uuid, _quantity numeric)
RETURNS void LANGUAGE sql AS $$
  SELECT public.adjust_inventory_location_quantity('7d000000-0000-4000-8000-000000000101', pg_temp.item(_item),
    _location, _quantity, 'Correction')::text WHERE true $$;
-- Everything a read or a rule write must leave alone.
CREATE FUNCTION pg_temp.state()
RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT jsonb_build_object(
    'items', (SELECT md5(coalesce(string_agg(id::text || ':' || quantity::text || ':' || active::text, ',' ORDER BY id), '')) FROM public.inventory_items),
    'balances', (SELECT md5(coalesce(string_agg(to_jsonb(b)::text, ',' ORDER BY inventory_item_id, inventory_location_id), ''))
                 FROM public.inventory_location_balances b),
    'locations', (SELECT md5(coalesce(string_agg(to_jsonb(l)::text, ',' ORDER BY id), '')) FROM public.inventory_locations l),
    'adjustments', (SELECT md5(coalesce(string_agg(to_jsonb(a)::text, ',' ORDER BY id), '')) FROM public.inventory_adjustments a),
    'transfers', (SELECT md5(coalesce(string_agg(to_jsonb(t)::text, ',' ORDER BY id), '')) FROM public.inventory_transfers t),
    'counts', (SELECT count(*) FROM public.inventory_count_sessions),
    'requests', (SELECT md5(coalesce(string_agg(to_jsonb(r)::text, ',' ORDER BY id), '')) FROM public.supply_requests r),
    'request_items', (SELECT md5(coalesce(string_agg(to_jsonb(r)::text, ',' ORDER BY id), '')) FROM public.supply_request_items r),
    'request_updates', (SELECT count(*) FROM public.supply_request_updates),
    'commitments', (SELECT md5(coalesce(string_agg(to_jsonb(c)::text, ',' ORDER BY id), '')) FROM public.supply_request_commitments c),
    'receipts', (SELECT count(*) FROM public.supply_request_receipts),
    'invoices', (SELECT count(*) FROM public.invoices),
    'notifications', (SELECT count(*) FROM public.notification_events),
    'count_policies', (SELECT md5(coalesce(string_agg(to_jsonb(p)::text, ',' ORDER BY organization_id), '')) FROM public.inventory_count_policies p))
$$;

-- ---------------------------------------------------------------------------------------
-- Fixtures. A: owner 001, admin 002, staff 003. B: owner 004. 007 belongs to nothing.
-- Items of A (unit): 501 Tape (roll), 502 Gauze (BX), 503 Wrap (roll), 504 Pads (each),
-- 505 Ice (bag), 506 Spray (can, archived later), 507 Strips (each), 508 Saline (L).
-- ---------------------------------------------------------------------------------------
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('7d000000-0000-4000-8000-00000000000' || n)::uuid, 'authenticated', 'authenticated',
  'phase7d-' || n || '@example.invalid', '', now(), '{}', '{}', now(), now()
FROM unnest(ARRAY[1, 2, 3, 4, 7]) n;

INSERT INTO public.organizations (id, name, created_by) VALUES
  ('7d000000-0000-4000-8000-000000000101', 'Phase 7D Organization', '7d000000-0000-4000-8000-000000000001'),
  ('7d000000-0000-4000-8000-000000000102', 'Phase 7D Other Organization', '7d000000-0000-4000-8000-000000000004');
INSERT INTO public.teams (id, organization_id, name) VALUES
  ('7d000000-0000-4000-8000-000000000201', '7d000000-0000-4000-8000-000000000101', 'First Team');
INSERT INTO public.locations (id, organization_id, name) VALUES
  ('7d000000-0000-4000-8000-000000000301', '7d000000-0000-4000-8000-000000000101', 'Training Ground');
INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES
  ('7d000000-0000-4000-8000-000000000101', '7d000000-0000-4000-8000-000000000001', 'owner', true),
  ('7d000000-0000-4000-8000-000000000101', '7d000000-0000-4000-8000-000000000002', 'admin', true),
  ('7d000000-0000-4000-8000-000000000101', '7d000000-0000-4000-8000-000000000003', 'staff', true),
  ('7d000000-0000-4000-8000-000000000102', '7d000000-0000-4000-8000-000000000004', 'owner', true);

INSERT INTO public.inventory_items (id, organization_id, name, unit, quantity, active, par_level) VALUES
  ('7d000000-0000-4000-8000-000000000501', '7d000000-0000-4000-8000-000000000101', 'P7D Tape', 'roll', 0, true, 3),
  ('7d000000-0000-4000-8000-000000000502', '7d000000-0000-4000-8000-000000000101', 'P7D Gauze', 'BX', 0, true, NULL),
  ('7d000000-0000-4000-8000-000000000503', '7d000000-0000-4000-8000-000000000101', 'P7D Wrap', 'roll', 0, true, NULL),
  ('7d000000-0000-4000-8000-000000000504', '7d000000-0000-4000-8000-000000000101', 'P7D Pads', 'each', 0, true, 50),
  ('7d000000-0000-4000-8000-000000000505', '7d000000-0000-4000-8000-000000000101', 'P7D Ice', 'bag', 0, true, NULL),
  ('7d000000-0000-4000-8000-000000000506', '7d000000-0000-4000-8000-000000000101', 'P7D Spray', 'can', 0, true, NULL),
  ('7d000000-0000-4000-8000-000000000507', '7d000000-0000-4000-8000-000000000101', 'P7D Strips', 'each', 0, true, NULL),
  ('7d000000-0000-4000-8000-000000000508', '7d000000-0000-4000-8000-000000000101', 'P7D Saline', 'L', 0, true, NULL),
  ('7d000000-0000-4000-8000-000000000511', '7d000000-0000-4000-8000-000000000102', 'P7D Other Tape', 'roll', 0, true, NULL);

SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000001');
INSERT INTO phase7d_values
SELECT 'loc:' || key, to_jsonb(public.create_inventory_location('7d000000-0000-4000-8000-000000000101', label))
FROM (VALUES ('first', 'First Team ATR'), ('fcc2', 'FCC2 ATR'), ('academy', 'Academy ATR'), ('bench', 'Bench'),
             ('old', 'Old Room')) AS l(key, label);
INSERT INTO phase7d_values VALUES ('loc:unassigned', to_jsonb(pg_temp.unassigned()));
-- Tape: Unassigned 20, First 2, FCC2 20.
SELECT pg_temp.put(501, pg_temp.unassigned(), 20), pg_temp.put(501, pg_temp.loc('first'), 2), pg_temp.put(501, pg_temp.loc('fcc2'), 20);
-- Gauze: Unassigned 3, First 1, FCC2 10, Academy 10 (FCC2 and Academy tie on spare).
SELECT pg_temp.put(502, pg_temp.unassigned(), 3), pg_temp.put(502, pg_temp.loc('first'), 1),
       pg_temp.put(502, pg_temp.loc('fcc2'), 10), pg_temp.put(502, pg_temp.loc('academy'), 10);
-- Wrap: Unassigned 1, First a balance row at 0, FCC2 6.
SELECT pg_temp.put(503, pg_temp.unassigned(), 1), pg_temp.put(503, pg_temp.loc('first'), 1), pg_temp.put(503, pg_temp.loc('fcc2'), 6);
SELECT public.adjust_inventory_location_quantity('7d000000-0000-4000-8000-000000000101', pg_temp.item(503), pg_temp.loc('first'), -1, 'Damaged');
-- Ice: First 5. Strips: one in each of Unassigned, FCC2, Academy, Bench. Saline: First 1.5, Unassigned 0.25.
SELECT pg_temp.put(505, pg_temp.loc('first'), 5);
SELECT pg_temp.put(507, l, 1) FROM unnest(ARRAY[pg_temp.unassigned(), pg_temp.loc('fcc2'), pg_temp.loc('academy'), pg_temp.loc('bench')]) l;
SELECT pg_temp.put(508, pg_temp.loc('first'), 1.5), pg_temp.put(508, pg_temp.unassigned(), 0.25);
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000004');
SELECT public.adjust_inventory_location_quantity('7d000000-0000-4000-8000-000000000102', pg_temp.item(511),
  (SELECT id FROM public.list_receiving_destinations('7d000000-0000-4000-8000-000000000102') WHERE kind = 'unassigned'), 5, 'Correction');
RESET ROLE;
SELECT pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.inventory_location_balances
  WHERE inventory_item_id = pg_temp.item(504) AND quantity <> 0) AND NOT EXISTS (SELECT 1 FROM public.inventory_location_balances
  WHERE inventory_item_id = pg_temp.item(501) AND inventory_location_id = pg_temp.loc('academy')),
  'Pads have no stock anywhere; Tape has no balance row at Academy');

-- Requests: an ordered inventory-backed Tape request, a submitted inventory-backed Tape request,
-- and an ordered free-text request. Only the first is "open" for the note.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000003');
INSERT INTO phase7d_values VALUES
  ('req:ordered', to_jsonb(public.submit_supply_request('7d000000-0000-4000-8000-000000000101', 'reorder',
     '7d000000-0000-4000-8000-000000000201', '7d000000-0000-4000-8000-000000000301', 'tape',
     jsonb_build_array(jsonb_build_object('inventoryItemId', pg_temp.item(501), 'quantity', 4))))),
  ('req:submitted', to_jsonb(public.submit_supply_request('7d000000-0000-4000-8000-000000000101', 'reorder',
     '7d000000-0000-4000-8000-000000000201', '7d000000-0000-4000-8000-000000000301', 'tape again',
     jsonb_build_array(jsonb_build_object('inventoryItemId', pg_temp.item(501), 'quantity', 2))))),
  ('req:freetext', to_jsonb(public.submit_supply_request('7d000000-0000-4000-8000-000000000101', 'reorder',
     '7d000000-0000-4000-8000-000000000201', '7d000000-0000-4000-8000-000000000301', 'free',
     jsonb_build_array(jsonb_build_object('freeTextItem', 'P7D Pads (any brand)', 'quantity', 9)))));
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000002');
SELECT public.decide_supply_request('7d000000-0000-4000-8000-000000000101', (pg_temp.val(n) #>> '{}')::uuid, 'approved', NULL, NULL,
  (SELECT updated_at FROM public.supply_requests WHERE id = (pg_temp.val(n) #>> '{}')::uuid))
FROM unnest(ARRAY['req:ordered', 'req:freetext']) n;
SELECT public.transition_supply_request('7d000000-0000-4000-8000-000000000101', (pg_temp.val(n) #>> '{}')::uuid, 'ordered')
FROM unnest(ARRAY['req:ordered', 'req:freetext']) n;
-- A physical count of First Team ATR (no changes), so items there have a last count.
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000003');
SELECT public.submit_inventory_count('7d000000-0000-4000-8000-000000000101', pg_temp.loc('first'), (
  SELECT jsonb_agg(jsonb_build_object('inventoryItemId', item->>'inventoryItemId', 'observedVersion', (item->>'version')::bigint,
    'countedQuantity', item->>'quantity'))
  FROM jsonb_array_elements(public.get_inventory_count_location('7d000000-0000-4000-8000-000000000101', pg_temp.loc('first'))->'items') item),
  'p7d-first-count');
RESET ROLE;

INSERT INTO phase7d_values VALUES ('before_rules', pg_temp.state());

-- ---------------------------------------------------------------------------------------
-- 1. Rule writes: owner only, validation, Unassigned, cross-organization.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000002');
SELECT pg_temp.expect_error(format('SELECT public.set_inventory_replenishment_rule(%L, %L, %L, 5, 10)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(501), pg_temp.loc('first')), 'Forbidden: owner access required', '42501');
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000003');
SELECT pg_temp.expect_error(format('SELECT public.set_inventory_replenishment_rule(%L, %L, %L, 5, 10)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(501), pg_temp.loc('first')), 'Forbidden: owner access required', '42501');
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000007');
SELECT pg_temp.expect_error(format('SELECT public.set_inventory_replenishment_rule(%L, %L, %L, 5, 10)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(501), pg_temp.loc('first')), 'Forbidden: owner access required', '42501');
-- Owner of B against A's item and location, and A's owner against B's item.
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000004');
SELECT pg_temp.expect_error(format('SELECT public.set_inventory_replenishment_rule(%L, %L, %L, 5, 10)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(501), pg_temp.loc('first')), 'Forbidden: owner access required', '42501');
SELECT pg_temp.expect_error(format('SELECT public.set_inventory_replenishment_rule(%L, %L, %L, 5, 10)',
  '7d000000-0000-4000-8000-000000000102', pg_temp.item(501), pg_temp.loc('first')), 'Inventory item not found', 'P0002');
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000001');
SELECT pg_temp.expect_error(format('SELECT public.set_inventory_replenishment_rule(%L, %L, %L, 5, 10)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(511), pg_temp.loc('first')), 'Inventory item not found', 'P0002');
SELECT pg_temp.expect_error(format('SELECT public.set_inventory_replenishment_rule(%L, %L, %L, 5, 10)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(501), (SELECT id FROM public.list_receiving_destinations('7d000000-0000-4000-8000-000000000101') LIMIT 0)),
  'Choose an inventory item and a location', '22023');
SELECT pg_temp.expect_error(format('SELECT public.set_inventory_replenishment_rule(%L, %L, %L, 5, 10)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(501), pg_temp.loc('unassigned')), 'Unassigned cannot have a replenishment rule', '22023');
-- Numeric validation.
SELECT pg_temp.expect_error(format('SELECT public.set_inventory_replenishment_rule(%L, %L, %L, -1, 10)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(501), pg_temp.loc('first')), 'Minimum must be zero or more', '22023');
SELECT pg_temp.expect_error(format('SELECT public.set_inventory_replenishment_rule(%L, %L, %L, 0, 0)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(501), pg_temp.loc('first')), 'Target must be greater than zero', '22023');
SELECT pg_temp.expect_error(format('SELECT public.set_inventory_replenishment_rule(%L, %L, %L, 6, 5)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(501), pg_temp.loc('first')), 'Target must be at least the Minimum', '22023');
SELECT pg_temp.expect_error(format('SELECT public.set_inventory_replenishment_rule(%L, %L, %L, 1, 1.0000001)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(501), pg_temp.loc('first')), 'up to six decimal places', '22023');
SELECT pg_temp.expect_error(format('SELECT public.set_inventory_replenishment_rule(%L, %L, %L, 1, 1000000001)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(501), pg_temp.loc('first')), 'at most 1,000,000,000', '22023');
SELECT pg_temp.expect_error(format('SELECT public.set_inventory_replenishment_rule(%L, %L, %L, NULL, 10)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(501), pg_temp.loc('first')), 'Enter a Minimum and a Target', '22023');

-- The rules used below. Target equal to Minimum is allowed (Ice at 5/5 would be "par only").
SELECT public.set_inventory_replenishment_rule('7d000000-0000-4000-8000-000000000101', pg_temp.item(i), pg_temp.loc(l), mn, tg)
FROM (VALUES (501, 'first', 5, 10), (501, 'fcc2', 5, 20), (501, 'academy', 3, 6), (502, 'first', 4, 10),
             (503, 'first', 2, 10), (503, 'fcc2', 4, 8), (504, 'first', 3, 6), (505, 'first', 5, 8),
             (506, 'first', 1, 2), (507, 'first', 1, 4), (508, 'first', 2.5, 7.25), (505, 'old', 1, 2),
             (502, 'fcc2', 1, 2)) AS r(i, l, mn, tg);
SELECT pg_temp.eq((public.set_inventory_replenishment_rule('7d000000-0000-4000-8000-000000000101', pg_temp.item(505),
  pg_temp.loc('fcc2'), 5, 5)->>'created')::boolean, true, 'Target may equal Minimum');
RESET ROLE;
SELECT pg_temp.eq((SELECT count(*) FROM public.inventory_replenishment_rules WHERE organization_id = '7d000000-0000-4000-8000-000000000101'),
  14::bigint, 'fourteen rules created');
SELECT pg_temp.eq((SELECT minimum_quantity::text || '/' || target_quantity::text FROM public.inventory_replenishment_rules
  WHERE id = pg_temp.rule_id(508, 'first')), '2.5/7.25', 'decimal Minimum and Target are stored exactly');
SELECT pg_temp.assert((SELECT bool_and(created_by = '7d000000-0000-4000-8000-000000000001' AND updated_by = created_by AND enabled)
  FROM public.inventory_replenishment_rules), 'rules record their creator and start enabled');
-- Direct table access is closed; the guard refuses Unassigned and identity changes even as postgres.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000001');
SELECT pg_temp.expect_error('SELECT * FROM public.inventory_replenishment_rules', 'permission denied for table inventory_replenishment_rules');
SELECT pg_temp.expect_error(format('INSERT INTO public.inventory_replenishment_rules (organization_id, inventory_item_id, inventory_location_id, minimum_quantity, target_quantity) VALUES (%L, %L, %L, 1, 2)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(505), pg_temp.loc('bench')), 'permission denied');
RESET ROLE;
SELECT pg_temp.expect_error(format('INSERT INTO public.inventory_replenishment_rules (organization_id, inventory_item_id, inventory_location_id, minimum_quantity, target_quantity) VALUES (%L, %L, %L, 1, 2)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(505), pg_temp.loc('unassigned')), 'Unassigned cannot have one', '22023');
SELECT pg_temp.expect_error(format('UPDATE public.inventory_replenishment_rules SET inventory_location_id = %L WHERE id = %L',
  pg_temp.loc('bench'), pg_temp.rule_id(505, 'first')), 'item and location cannot change', '42501');
SELECT pg_temp.expect_error(format('INSERT INTO public.inventory_replenishment_rules (organization_id, inventory_item_id, inventory_location_id, minimum_quantity, target_quantity) VALUES (%L, %L, %L, 3, 2)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(505), pg_temp.loc('bench')), 'inventory_replenishment_rules_target_minimum_check');
SELECT pg_temp.expect_error(format('INSERT INTO public.inventory_replenishment_rules (organization_id, inventory_item_id, inventory_location_id, minimum_quantity, target_quantity) VALUES (%L, %L, %L, 1, 2)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(511), pg_temp.loc('bench')), 'inventory_replenishment_rules_item_org_fk');

-- ---------------------------------------------------------------------------------------
-- 2. Duplicate create, edits with stale protection, disable / re-enable.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000001');
SELECT pg_temp.expect_error(format('SELECT public.set_inventory_replenishment_rule(%L, %L, %L, 9, 99)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(501), pg_temp.loc('first')), 'P7D Tape already has a replenishment rule at First Team ATR', '23505');
RESET ROLE;
SELECT pg_temp.eq((SELECT minimum_quantity::text || '/' || target_quantity::text FROM public.inventory_replenishment_rules
  WHERE id = pg_temp.rule_id(501, 'first')), '5/10', 'a duplicate create never overwrites');
INSERT INTO phase7d_values VALUES ('ice_ts', to_jsonb(pg_temp.rule_ts(505, 'fcc2')));
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000001');
SELECT public.set_inventory_replenishment_rule('7d000000-0000-4000-8000-000000000101', pg_temp.item(505), pg_temp.loc('fcc2'),
  4, 9, (pg_temp.val('ice_ts') #>> '{}')::timestamptz);
SELECT pg_temp.expect_error(format('SELECT public.set_inventory_replenishment_rule(%L, %L, %L, 1, 2, %L)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(505), pg_temp.loc('fcc2'), pg_temp.val('ice_ts') #>> '{}'),
  'This replenishment rule changed since you opened it. Reload and try again.', '55000');
SELECT pg_temp.expect_error(format('SELECT public.set_inventory_replenishment_rule(%L, %L, %L, 1, 2, %L)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(505), pg_temp.loc('bench'), now()), 'Replenishment rule not found', 'P0002');
RESET ROLE;
SELECT pg_temp.eq((SELECT minimum_quantity::text || '/' || target_quantity::text FROM public.inventory_replenishment_rules
  WHERE id = pg_temp.rule_id(505, 'fcc2')), '4/9', 'the stale edit changed nothing');
SELECT pg_temp.assert(pg_temp.rule_ts(505, 'fcc2') > (pg_temp.val('ice_ts') #>> '{}')::timestamptz, 'an edit moves updated_at');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000002');
SELECT pg_temp.expect_error(format('SELECT public.set_inventory_replenishment_rule_enabled(%L, %L, false, %L)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.rule_id(505, 'fcc2'), pg_temp.rule_ts(505, 'fcc2')), 'Forbidden: owner access required', '42501');
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000001');
SELECT pg_temp.expect_error(format('SELECT public.set_inventory_replenishment_rule_enabled(%L, %L, false, %L)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.rule_id(505, 'fcc2'), pg_temp.val('ice_ts') #>> '{}'),
  'changed since you opened it', '55000');
SELECT pg_temp.expect_error(format('SELECT public.set_inventory_replenishment_rule_enabled(%L, %L, false, NULL)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.rule_id(505, 'fcc2')), 'the version you saw are required', '22023');
SELECT pg_temp.expect_error(format('SELECT public.set_inventory_replenishment_rule_enabled(%L, %L, false, %L)',
  '7d000000-0000-4000-8000-000000000102', pg_temp.rule_id(505, 'fcc2'), pg_temp.rule_ts(505, 'fcc2')), 'Forbidden', '42501');
SELECT pg_temp.eq((public.set_inventory_replenishment_rule_enabled('7d000000-0000-4000-8000-000000000101', pg_temp.rule_id(505, 'fcc2'),
  false, pg_temp.rule_ts(505, 'fcc2'))->>'changed')::boolean, true, 'owner disables');
SELECT pg_temp.eq((public.set_inventory_replenishment_rule_enabled('7d000000-0000-4000-8000-000000000101', pg_temp.rule_id(505, 'fcc2'),
  false, pg_temp.rule_ts(505, 'fcc2'))->>'changed')::boolean, false, 'disabling again is a no-op');
-- Gauze at FCC2 stays disabled for the rest of the suite.
SELECT public.set_inventory_replenishment_rule_enabled('7d000000-0000-4000-8000-000000000101', pg_temp.rule_id(502, 'fcc2'),
  false, pg_temp.rule_ts(502, 'fcc2'));
RESET ROLE;
SELECT pg_temp.eq((SELECT count(*) FROM public.inventory_replenishment_rules WHERE NOT enabled), 2::bigint, 'disabled rules are kept');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000001');
SELECT pg_temp.eq((public.set_inventory_replenishment_rule_enabled('7d000000-0000-4000-8000-000000000101', pg_temp.rule_id(505, 'fcc2'),
  true, pg_temp.rule_ts(505, 'fcc2'))->>'enabled')::boolean, true, 'owner re-enables');
RESET ROLE;

-- ---------------------------------------------------------------------------------------
-- 3. The calculation.
-- ---------------------------------------------------------------------------------------
-- Tape at First: 2 <= 5, shortage 8; Unassigned 20 + FCC2 (20 - its Minimum 5 = 15) = 35.
SELECT pg_temp.eq(pg_temp.calc(501, 'first')->>'category', 'move_available', 'Tape@First category');
SELECT pg_temp.eq(pg_temp.calc(501, 'first')->>'shortage_quantity', '8', 'Tape@First shortage');
SELECT pg_temp.eq(pg_temp.calc(501, 'first')->>'available_quantity', '35', 'Tape@First available');
SELECT pg_temp.eq(pg_temp.calc(501, 'first')->>'move_quantity', '8', 'Tape@First move');
SELECT pg_temp.eq(pg_temp.calc(501, 'first')->>'external_quantity', '0', 'Tape@First external');
SELECT pg_temp.eq(pg_temp.donor_names(pg_temp.calc(501, 'first')), 'Unassigned=20,FCC2 ATR=15',
  'Unassigned first; a donor keeps its own Minimum');
SELECT pg_temp.eq(pg_temp.calc(501, 'first')->>'organization_quantity', '42', 'organization total');
SELECT pg_temp.eq(pg_temp.calc(501, 'first')->>'unassigned_quantity', '20', 'Unassigned quantity');
SELECT pg_temp.eq((pg_temp.calc(501, 'first')->>'not_stocked_here')::boolean, false, 'Tape is stocked at First');
-- Two short locations of one item: each sees the full spare and the other.
SELECT pg_temp.eq((pg_temp.calc(501, 'first')->>'other_short_location_count')::int, 1, 'Tape short elsewhere (First)');
SELECT pg_temp.eq(pg_temp.calc(501, 'academy')->>'category', 'move_available', 'Tape@Academy category');
SELECT pg_temp.eq((pg_temp.calc(501, 'academy')->>'not_stocked_here')::boolean, true, 'no balance row at Academy');
SELECT pg_temp.eq(pg_temp.calc(501, 'academy')->>'current_quantity', '0', 'no balance row reads as 0');
SELECT pg_temp.eq(pg_temp.calc(501, 'academy')->>'shortage_quantity', '6', 'Tape@Academy shortage');
SELECT pg_temp.eq((pg_temp.calc(501, 'academy')->>'other_short_location_count')::int, 1, 'Tape short elsewhere (Academy)');
SELECT pg_temp.eq(pg_temp.donor_names(pg_temp.calc(501, 'academy')), 'Unassigned=20,FCC2 ATR=15', 'same donors for Academy');
SELECT pg_temp.eq(pg_temp.calc(501, 'fcc2')->>'category', 'ok', 'Tape@FCC2 above Minimum');
SELECT pg_temp.eq(pg_temp.calc(501, 'fcc2')->>'shortage_quantity', '0', 'ok has no shortage');
SELECT pg_temp.eq(pg_temp.calc(501, 'fcc2')->>'available_quantity', '20', 'a location never counts its own spare (35 - 15)');
SELECT pg_temp.eq(pg_temp.calc(501, 'fcc2')->'donors', '[]'::jsonb, 'ok has no donors');
SELECT pg_temp.eq((pg_temp.calc(501, 'fcc2')->>'other_short_location_count')::int, 0, 'ok has no short-elsewhere note');
-- Gauze at First: Unassigned (3) before larger donors; FCC2's rule is disabled so its Minimum is
-- ignored (spare 10); Academy and FCC2 tie at 10 and sort by name.
SELECT pg_temp.eq(pg_temp.calc(502, 'first')->>'category', 'move_available', 'Gauze@First category');
SELECT pg_temp.eq(pg_temp.donor_names(pg_temp.calc(502, 'first')), 'Unassigned=3,Academy ATR=10,FCC2 ATR=10',
  'Unassigned first even when smaller; equal spare sorts by name; a location without an enabled rule donates to zero');
SELECT pg_temp.eq(pg_temp.donor_takes(pg_temp.calc(502, 'first')), 'Unassigned=3,Academy ATR=6,FCC2 ATR=0',
  'the move is taken from donors in order');
SELECT pg_temp.eq(pg_temp.donor_takes(pg_temp.calc(501, 'first')), 'Unassigned=8,FCC2 ATR=0', 'Unassigned covers Tape alone');
SELECT pg_temp.eq(pg_temp.calc(502, 'fcc2')->>'category', 'inactive', 'a disabled rule is inactive');
SELECT pg_temp.eq(pg_temp.calc(502, 'fcc2')->>'inactive_reason', 'disabled', 'disabled reason');
-- Wrap at First: 0 <= 2, shortage 10; Unassigned 1 + FCC2 (6 - 4) = 3: partly covered.
SELECT pg_temp.eq(pg_temp.calc(503, 'first')->>'category', 'partly_covered', 'Wrap@First category');
SELECT pg_temp.eq((pg_temp.calc(503, 'first')->>'not_stocked_here')::boolean, false, 'a zero balance row is stocked here');
SELECT pg_temp.eq(pg_temp.calc(503, 'first')->>'move_quantity', '3', 'Wrap move');
SELECT pg_temp.eq(pg_temp.calc(503, 'first')->>'external_quantity', '7', 'Wrap external');
SELECT pg_temp.eq(pg_temp.donor_names(pg_temp.calc(503, 'first')), 'Unassigned=1,FCC2 ATR=2', 'FCC2 never drops below its Minimum');
SELECT pg_temp.eq(pg_temp.donor_takes(pg_temp.calc(503, 'first')), 'Unassigned=1,FCC2 ATR=2', 'partly covered takes every spare');
-- Pads: nothing anywhere: needs purchasing. Ice: exactly at Minimum counts as below.
SELECT pg_temp.eq(pg_temp.calc(504, 'first')->>'category', 'needs_purchasing', 'Pads category');
SELECT pg_temp.eq(pg_temp.calc(504, 'first')->>'external_quantity', '6', 'Pads external');
SELECT pg_temp.eq((pg_temp.calc(504, 'first')->>'not_stocked_here')::boolean, true, 'Pads not stocked here');
SELECT pg_temp.eq(pg_temp.calc(505, 'first')->>'category', 'needs_purchasing', 'Ice at its Minimum is below');
SELECT pg_temp.eq(pg_temp.calc(505, 'first')->>'shortage_quantity', '3', 'Ice shortage');
-- Ice at FCC2 (re-enabled, 4/9, no stock): First holds 5 but its own Minimum is 5, so it has
-- nothing to spare.
SELECT pg_temp.eq(pg_temp.calc(505, 'fcc2')->>'category', 'needs_purchasing', 'Ice@FCC2: First keeps its Minimum');
SELECT pg_temp.eq(pg_temp.donor_names(pg_temp.calc(505, 'fcc2')), '', 'no donors for Ice@FCC2');
-- Strips: four donors with one each; at most three are returned, Unassigned first, then by name.
SELECT pg_temp.eq(pg_temp.calc(507, 'first')->>'category', 'move_available', 'Strips category');
SELECT pg_temp.eq(pg_temp.calc(507, 'first')->>'available_quantity', '4', 'Strips available counts every donor');
SELECT pg_temp.eq(pg_temp.donor_names(pg_temp.calc(507, 'first')), 'Unassigned=1,Academy ATR=1,Bench=1', 'at most three donors');
-- Saline: decimals end to end. 1.5 <= 2.5, shortage 7.25 - 1.5 = 5.75; Unassigned 0.25.
SELECT pg_temp.eq(pg_temp.calc(508, 'first')->>'category', 'partly_covered', 'Saline category');
SELECT pg_temp.eq(pg_temp.calc(508, 'first')->>'shortage_quantity', '5.75', 'Saline shortage');
SELECT pg_temp.eq(pg_temp.calc(508, 'first')->>'move_quantity', '0.25', 'Saline move');
SELECT pg_temp.eq(pg_temp.calc(508, 'first')->>'external_quantity', '5.5', 'Saline external');
SELECT pg_temp.eq(pg_temp.calc(508, 'first')->>'minimum_quantity', '2.5', 'Saline Minimum');
-- Disabling FCC2's Wrap rule removes its Minimum from the donor calculation.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000001');
SELECT public.set_inventory_replenishment_rule_enabled('7d000000-0000-4000-8000-000000000101', pg_temp.rule_id(503, 'fcc2'),
  false, pg_temp.rule_ts(503, 'fcc2'));
RESET ROLE;
SELECT pg_temp.eq(pg_temp.calc(503, 'first')->>'move_quantity', '7', 'without its rule FCC2 donates all 6');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000001');
SELECT public.set_inventory_replenishment_rule_enabled('7d000000-0000-4000-8000-000000000101', pg_temp.rule_id(503, 'fcc2'),
  true, pg_temp.rule_ts(503, 'fcc2'));
RESET ROLE;
SELECT pg_temp.eq(pg_temp.calc(503, 'first')->>'move_quantity', '3', 'the re-enabled Minimum applies again');

-- par_level is not an input: changing it changes no calculated value.
INSERT INTO phase7d_values VALUES ('calc_before_par', pg_temp.all_calc());
SELECT set_config('medspend.inventory_sync', 'off', true);
UPDATE public.inventory_items SET par_level = 1000 WHERE id = pg_temp.item(501);
UPDATE public.inventory_items SET par_level = 0 WHERE id = pg_temp.item(504);
UPDATE public.inventory_items SET par_level = NULL WHERE id = pg_temp.item(505);
SELECT pg_temp.eq(pg_temp.all_calc(), pg_temp.val('calc_before_par'), 'par_level does not affect replenishment');
SELECT pg_temp.assert(position('par_level' IN pg_get_functiondef(p.oid)) = 0, 'no par_level in ' || p.proname)
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('inventory_replenishment_rows',
  'list_inventory_replenishment', 'get_inventory_replenishment_summary', 'list_inventory_location_replenishment_rules',
  'set_inventory_replenishment_rule', 'set_inventory_replenishment_rule_enabled', 'move_inventory_stock');
UPDATE public.inventory_items SET par_level = 3 WHERE id = pg_temp.item(501);
UPDATE public.inventory_items SET par_level = 50 WHERE id = pg_temp.item(504);

-- ---------------------------------------------------------------------------------------
-- 4. Reads: owner and admin; staff, outsiders and anon refused; paging and views.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000003');
SELECT pg_temp.expect_error($$SELECT * FROM public.list_inventory_replenishment('7d000000-0000-4000-8000-000000000101')$$,
  'Forbidden: owner or admin access required', '42501');
SELECT pg_temp.expect_error($$SELECT public.get_inventory_replenishment_summary('7d000000-0000-4000-8000-000000000101')$$,
  'Forbidden: owner or admin access required', '42501');
SELECT pg_temp.expect_error(format('SELECT * FROM public.list_inventory_location_replenishment_rules(%L, %L)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.loc('first')), 'Forbidden: owner or admin access required', '42501');
SELECT pg_temp.expect_error($$SELECT * FROM public.inventory_replenishment_rows('7d000000-0000-4000-8000-000000000101')$$,
  'permission denied for function inventory_replenishment_rows');
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000004');
SELECT pg_temp.expect_error($$SELECT * FROM public.list_inventory_replenishment('7d000000-0000-4000-8000-000000000101')$$,
  'Forbidden', '42501');
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000002');
SELECT pg_temp.expect_error($$SELECT * FROM public.list_inventory_replenishment('7d000000-0000-4000-8000-000000000101', 'low')$$,
  'Choose attention, ok, inactive or all', '22023');
SELECT pg_temp.expect_error($$SELECT * FROM public.list_inventory_replenishment('7d000000-0000-4000-8000-000000000101', 'attention', NULL, 501)$$,
  'Page size must be between 1 and 500', '22023');
SELECT pg_temp.expect_error($$SELECT * FROM public.list_inventory_replenishment('7d000000-0000-4000-8000-000000000101', 'attention', NULL, 10, 1)$$,
  'An incomplete page cursor was supplied', '22023');
-- Attention: move available (Gauze, Strips, Tape x2), partly covered (Saline, Wrap), needs
-- purchasing (Ice, Ice@FCC2, Pads, Spray).
SELECT pg_temp.eq((SELECT string_agg(category || ':' || item_name || '@' || location_name, ' ' ORDER BY sort_rank, sort_item, sort_location, rule_id)
  FROM public.list_inventory_replenishment('7d000000-0000-4000-8000-000000000101', 'attention')),
  'move_available:P7D Gauze@First Team ATR move_available:P7D Strips@First Team ATR move_available:P7D Tape@Academy ATR '
  || 'move_available:P7D Tape@First Team ATR partly_covered:P7D Saline@First Team ATR partly_covered:P7D Wrap@First Team ATR '
  || 'needs_purchasing:P7D Ice@FCC2 ATR needs_purchasing:P7D Ice@First Team ATR needs_purchasing:P7D Ice@Old Room '
  || 'needs_purchasing:P7D Pads@First Team ATR needs_purchasing:P7D Spray@First Team ATR', 'attention order');
SELECT pg_temp.eq((SELECT string_agg(item_name || '@' || location_name, ' ' ORDER BY sort_item, sort_location)
  FROM public.list_inventory_replenishment('7d000000-0000-4000-8000-000000000101', 'ok')),
  'P7D Tape@FCC2 ATR P7D Wrap@FCC2 ATR', 'ok view');
SELECT pg_temp.eq((SELECT string_agg(item_name || '@' || location_name || ':' || inactive_reason, ' ')
  FROM public.list_inventory_replenishment('7d000000-0000-4000-8000-000000000101', 'inactive')),
  'P7D Gauze@FCC2 ATR:disabled', 'inactive view');
-- Paging: three at a time through the attention view gives the same order.
INSERT INTO phase7d_values SELECT 'page1', jsonb_agg(to_jsonb(p) ORDER BY sort_rank, sort_item, sort_location, rule_id)
  FROM public.list_inventory_replenishment('7d000000-0000-4000-8000-000000000101', 'attention', NULL, 3) p;
INSERT INTO phase7d_values SELECT 'page2', jsonb_agg(to_jsonb(p) ORDER BY sort_rank, sort_item, sort_location, rule_id)
  FROM public.list_inventory_replenishment('7d000000-0000-4000-8000-000000000101', 'attention', NULL, 3,
    (pg_temp.val('page1')->2->>'sort_rank')::int, pg_temp.val('page1')->2->>'sort_item',
    pg_temp.val('page1')->2->>'sort_location', (pg_temp.val('page1')->2->>'rule_id')::uuid) p;
SELECT pg_temp.eq((SELECT string_agg(e->>'item_name' || '@' || (e->>'location_name'), ' ') FROM jsonb_array_elements(pg_temp.val('page1') || pg_temp.val('page2')) e),
  'P7D Gauze@First Team ATR P7D Strips@First Team ATR P7D Tape@Academy ATR P7D Tape@First Team ATR P7D Saline@First Team ATR P7D Wrap@First Team ATR',
  'cursor paging continues in order');
-- Location filter, and the location page list (every state, by item name, paged).
SELECT pg_temp.eq((SELECT count(*) FROM public.list_inventory_replenishment('7d000000-0000-4000-8000-000000000101', 'all', pg_temp.loc('fcc2'))),
  4::bigint, 'FCC2 has four rules in all states');
SELECT pg_temp.eq((SELECT string_agg(r->>'item_name' || ':' || (r->>'category'), ' ')
  FROM public.list_inventory_location_replenishment_rules('7d000000-0000-4000-8000-000000000101', pg_temp.loc('fcc2')) r),
  'P7D Gauze:inactive P7D Ice:needs_purchasing P7D Tape:ok P7D Wrap:ok', 'location rules by item name, every state');
SELECT pg_temp.eq((SELECT string_agg(r->>'item_name', ' ')
  FROM public.list_inventory_location_replenishment_rules('7d000000-0000-4000-8000-000000000101', pg_temp.loc('fcc2'), 2,
    'p7d ice', (SELECT (r2->>'rule_id')::uuid FROM public.list_inventory_location_replenishment_rules('7d000000-0000-4000-8000-000000000101', pg_temp.loc('fcc2')) r2
                WHERE r2->>'item_name' = 'P7D Ice')) r),
  'P7D Tape P7D Wrap', 'location rules page after a cursor');
SELECT pg_temp.eq((SELECT count(*) FROM public.list_inventory_location_replenishment_rules('7d000000-0000-4000-8000-000000000101', pg_temp.loc('unassigned'))),
  0::bigint, 'Unassigned has no rules');
SELECT pg_temp.expect_error(format('SELECT * FROM public.list_inventory_location_replenishment_rules(%L, %L)',
  '7d000000-0000-4000-8000-000000000102', pg_temp.loc('first')), 'Forbidden', '42501');
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000001');
SELECT pg_temp.expect_error(format('SELECT * FROM public.list_inventory_location_replenishment_rules(%L, %L)',
  '7d000000-0000-4000-8000-000000000101', '7d000000-0000-4000-8000-000000000999'), 'Inventory location not found', 'P0002');
-- Summary: 14 rules, 1 disabled. Active items 8 (Tape..Saline), all with an active rule.
-- Active storage locations: First, FCC2, Academy, Bench, Old Room; Bench has no rule.
INSERT INTO phase7d_values VALUES ('summary', public.get_inventory_replenishment_summary('7d000000-0000-4000-8000-000000000101'));
RESET ROLE;
SELECT pg_temp.eq(pg_temp.val('summary')->'rules', '{"total": 14, "active": 13, "inactive": 1, "disabled": 1}'::jsonb, 'rule summary');
SELECT pg_temp.eq(pg_temp.val('summary')->'categories',
  '{"moveAvailable": 4, "partlyCovered": 2, "needsPurchasing": 5, "ok": 2, "inactive": 1}'::jsonb, 'category summary');
SELECT pg_temp.eq((pg_temp.val('summary')->'categories'->>'moveAvailable')::int
  + (pg_temp.val('summary')->'categories'->>'partlyCovered')::int + (pg_temp.val('summary')->'categories'->>'needsPurchasing')::int
  + (pg_temp.val('summary')->'categories'->>'ok')::int + (pg_temp.val('summary')->'categories'->>'inactive')::int, 14,
  'every rule has exactly one category');
SELECT pg_temp.eq(pg_temp.val('summary')->'items', '{"active": 8, "withRule": 8, "withoutRule": 0}'::jsonb, 'item coverage');
SELECT pg_temp.eq(pg_temp.val('summary')->'locations', '{"activeStorage": 5, "withRule": 4, "withoutRule": 1}'::jsonb, 'location coverage');
SELECT pg_temp.eq((pg_temp.val('summary')->>'notStockedHere')::int, 6,
  'not stocked here: Tape@Academy, Pads, Spray, Strips@First, Ice@FCC2, Ice@Old Room');

-- ---------------------------------------------------------------------------------------
-- 5. Rule writes and reads changed nothing else: no balance, total, adjustment, transfer,
--    count, request, commitment, receipt, invoice or notification.
-- ---------------------------------------------------------------------------------------
SELECT pg_temp.eq(pg_temp.state(), pg_temp.val('before_rules'), 'rule writes and reads have no side effects');

-- ---------------------------------------------------------------------------------------
-- 6. Open-request note: organization level, inventory-backed approved/ordered lines only,
--    never subtracted.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000002');
INSERT INTO phase7d_values SELECT 'list:' || item_name || '@' || location_name, to_jsonb(r)
FROM public.list_inventory_replenishment('7d000000-0000-4000-8000-000000000101', 'all') r;
RESET ROLE;
SELECT pg_temp.eq((pg_temp.val('list:P7D Tape@First Team ATR')->>'open_request_count')::int, 1, 'one open Tape request (the submitted one is not open)');
SELECT pg_temp.eq((pg_temp.val('list:P7D Tape@First Team ATR')->>'open_ordered_request_count')::int, 1, 'it is ordered');
SELECT pg_temp.eq((pg_temp.val('list:P7D Tape@First Team ATR')->>'open_approved_request_count')::int, 0, 'none approved only');
SELECT pg_temp.eq((pg_temp.val('list:P7D Tape@Academy ATR')->>'open_request_count')::int, 1, 'the note is organization level');
SELECT pg_temp.eq(pg_temp.val('list:P7D Tape@First Team ATR')->>'shortage_quantity', '8', 'the open request is never subtracted');
SELECT pg_temp.eq(pg_temp.val('list:P7D Tape@First Team ATR')->>'category', 'move_available', 'and never changes the category');
SELECT pg_temp.eq((pg_temp.val('list:P7D Pads@First Team ATR')->>'open_request_count')::int, 0, 'a free-text request is not counted');
SELECT pg_temp.eq(pg_temp.val('list:P7D Pads@First Team ATR')->>'external_quantity', '6', 'Pads still need purchasing');

-- ---------------------------------------------------------------------------------------
-- 7. Count freshness is context only.
-- ---------------------------------------------------------------------------------------
SELECT pg_temp.assert((pg_temp.val('list:P7D Tape@First Team ATR')->>'last_counted_at') IS NOT NULL, 'Tape@First has a last count');
SELECT pg_temp.eq(pg_temp.val('list:P7D Tape@First Team ATR')->>'location_count_state', 'counted', 'cadence off: counted');
SELECT pg_temp.assert((pg_temp.val('list:P7D Tape@Academy ATR')->>'last_counted_at') IS NULL, 'not counted here yet');
SELECT pg_temp.eq(pg_temp.val('list:P7D Tape@Academy ATR')->>'location_count_state', 'never_counted', 'Academy never counted');
SELECT pg_temp.assert((pg_temp.val('list:P7D Pads@First Team ATR')->>'last_counted_at') IS NULL,
  'an item without a balance row at a counted location was not counted there');
INSERT INTO phase7d_values VALUES ('calc_before_cadence', pg_temp.all_calc());
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000001');
SELECT public.set_inventory_count_policy('7d000000-0000-4000-8000-000000000101', true, 30);
RESET ROLE;
INSERT INTO public.inventory_count_sessions (id, organization_id, inventory_location_id, counted_by, submitted_at,
  line_count, changed_count, idempotency_key, request_hash)
VALUES ('7d000000-0000-4000-8000-000000000901', '7d000000-0000-4000-8000-000000000101', pg_temp.loc('academy'),
  '7d000000-0000-4000-8000-000000000003', '2025-01-01 10:00+00', 1, 0, 'p7d-old-academy', repeat('0', 64));
INSERT INTO public.inventory_count_lines (organization_id, count_session_id, inventory_item_id, inventory_location_id,
  previous_quantity, counted_quantity, delta, observed_version, item_name, item_unit, created_at)
VALUES ('7d000000-0000-4000-8000-000000000101', '7d000000-0000-4000-8000-000000000901', pg_temp.item(501),
  pg_temp.loc('academy'), 0, 0, 0, 1, 'P7D Tape', 'roll', '2025-01-01 10:00+00');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000002');
SELECT pg_temp.eq((SELECT location_count_state || ' ' || last_counted_at::date::text || ' ' || category || ' ' || shortage_quantity
  FROM public.list_inventory_replenishment('7d000000-0000-4000-8000-000000000101', 'all', pg_temp.loc('academy'))
  WHERE item_name = 'P7D Tape'), 'overdue 2025-01-01 move_available 6', 'an overdue count warns but changes nothing');
SELECT pg_temp.eq((SELECT location_count_state FROM public.list_inventory_replenishment('7d000000-0000-4000-8000-000000000101', 'all', pg_temp.loc('first'))
  WHERE item_name = 'P7D Tape'), 'current', 'cadence on: First is current');
RESET ROLE;
SELECT pg_temp.eq(pg_temp.all_calc(), pg_temp.val('calc_before_cadence'), 'freshness and cadence never change the calculation');

-- ---------------------------------------------------------------------------------------
-- 8. Archived items and locations make rules inactive; creation and re-enable are refused.
-- ---------------------------------------------------------------------------------------
UPDATE public.inventory_items SET active = false WHERE id = pg_temp.item(506);
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000001');
SELECT public.set_inventory_location_active('7d000000-0000-4000-8000-000000000101', pg_temp.loc('old'), false);
RESET ROLE;
SELECT pg_temp.eq(pg_temp.calc(506, 'first')->>'category' || '/' || (pg_temp.calc(506, 'first')->>'inactive_reason'),
  'inactive/item_archived', 'archived item: inactive');
SELECT pg_temp.eq(pg_temp.calc(505, 'old')->>'category' || '/' || (pg_temp.calc(505, 'old')->>'inactive_reason'),
  'inactive/location_archived', 'archived location: inactive');
SELECT pg_temp.eq(pg_temp.calc(506, 'first')->>'shortage_quantity', '0', 'inactive rules have no shortage');
SELECT pg_temp.eq((SELECT count(*) FROM public.inventory_replenishment_rules WHERE id IN (pg_temp.rule_id(506, 'first'), pg_temp.rule_id(505, 'old'))),
  2::bigint, 'archiving keeps the rules');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000001');
SELECT pg_temp.expect_error(format('SELECT public.set_inventory_replenishment_rule(%L, %L, %L, 1, 2)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(506), pg_temp.loc('fcc2')), 'P7D Spray is archived', '55000');
SELECT pg_temp.expect_error(format('SELECT public.set_inventory_replenishment_rule(%L, %L, %L, 1, 2)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(501), pg_temp.loc('old')), 'Old Room is archived', '55000');
SELECT pg_temp.expect_error(format('SELECT public.set_inventory_replenishment_rule(%L, %L, %L, 1, 3, %L)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(506), pg_temp.loc('first'), pg_temp.rule_ts(506, 'first')), 'P7D Spray is archived', '55000');
SELECT public.set_inventory_replenishment_rule_enabled('7d000000-0000-4000-8000-000000000101', pg_temp.rule_id(506, 'first'),
  false, pg_temp.rule_ts(506, 'first'));
SELECT pg_temp.expect_error(format('SELECT public.set_inventory_replenishment_rule_enabled(%L, %L, true, %L)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.rule_id(506, 'first'), pg_temp.rule_ts(506, 'first')),
  'its replenishment rule cannot be turned on', '55000');
SELECT public.set_inventory_replenishment_rule_enabled('7d000000-0000-4000-8000-000000000101', pg_temp.rule_id(505, 'old'),
  false, pg_temp.rule_ts(505, 'old'));
SELECT pg_temp.expect_error(format('SELECT public.set_inventory_replenishment_rule_enabled(%L, %L, true, %L)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.rule_id(505, 'old'), pg_temp.rule_ts(505, 'old')),
  'Old Room is archived', '55000');
INSERT INTO phase7d_values VALUES ('summary2', public.get_inventory_replenishment_summary('7d000000-0000-4000-8000-000000000101'));
RESET ROLE;
SELECT pg_temp.eq(pg_temp.val('summary2')->'items', '{"active": 7, "withRule": 7, "withoutRule": 0}'::jsonb, 'archived items leave coverage');
SELECT pg_temp.eq(pg_temp.val('summary2')->'locations', '{"activeStorage": 4, "withRule": 3, "withoutRule": 1}'::jsonb, 'archived locations leave coverage');

-- ---------------------------------------------------------------------------------------
-- 9. Transfer source marker: manual by default (old callers too), replenishment when asked,
--    unknown refused, replays keep the first source.
-- ---------------------------------------------------------------------------------------
SELECT pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.inventory_transfers WHERE source <> 'manual'), 'existing transfers are manual');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000002');
SELECT pg_temp.expect_error(format('SELECT public.move_inventory_stock(%L, %L, %L, %L, 1, %L, %L)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(501), pg_temp.unassigned(), pg_temp.loc('first'), 'p7d-admin', 'replenishment'),
  'Forbidden: owner access required', '42501');
SELECT pg_temp.as_user('7d000000-0000-4000-8000-000000000001');
-- An old caller: six positional arguments, then six named arguments (what PostgREST sends).
SELECT public.move_inventory_stock('7d000000-0000-4000-8000-000000000101', pg_temp.item(501), pg_temp.unassigned(),
  pg_temp.loc('fcc2'), 1, 'p7d-m1');
SELECT public.move_inventory_stock(_organization_id => '7d000000-0000-4000-8000-000000000101', _inventory_item_id => pg_temp.item(501),
  _from_inventory_location_id => pg_temp.unassigned(), _to_inventory_location_id => pg_temp.loc('fcc2'), _quantity => 1,
  _idempotency_key => 'p7d-m2');
SELECT pg_temp.expect_error(format('SELECT public.move_inventory_stock(%L, %L, %L, %L, 1, %L, %L)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(501), pg_temp.unassigned(), pg_temp.loc('first'), 'p7d-bad', 'automatic'),
  'Unknown move source', '22023');
SELECT pg_temp.expect_error(format('SELECT public.move_inventory_stock(%L, %L, %L, %L, 1, %L, NULL)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(501), pg_temp.unassigned(), pg_temp.loc('first'), 'p7d-null'),
  'Unknown move source', '22023');
-- The recommendation for Tape@First: move 8 from Unassigned, confirmed by the owner.
SELECT pg_temp.eq((public.move_inventory_stock('7d000000-0000-4000-8000-000000000101', pg_temp.item(501), pg_temp.unassigned(),
  pg_temp.loc('first'), 8, 'p7d-rep', 'replenishment')->>'replayed')::boolean, false, 'the replenishment move runs');
SELECT pg_temp.eq((public.move_inventory_stock('7d000000-0000-4000-8000-000000000101', pg_temp.item(501), pg_temp.unassigned(),
  pg_temp.loc('first'), 8, 'p7d-rep', 'manual')->>'replayed')::boolean, true, 'a replay with another source is the same move');
SELECT pg_temp.expect_error(format('SELECT public.move_inventory_stock(%L, %L, %L, %L, 7, %L, %L)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(501), pg_temp.unassigned(), pg_temp.loc('first'), 'p7d-rep', 'replenishment'),
  'already used for a different move', '23505');
SELECT pg_temp.expect_error(format('SELECT public.move_inventory_stock(%L, %L, %L, %L, 100, %L, %L)',
  '7d000000-0000-4000-8000-000000000101', pg_temp.item(501), pg_temp.unassigned(), pg_temp.loc('first'), 'p7d-too-much', 'replenishment'),
  'cannot go below zero', '23514');
RESET ROLE;
SELECT pg_temp.eq((SELECT string_agg(idempotency_key || '=' || source, ',' ORDER BY idempotency_key) FROM public.inventory_transfers
  WHERE idempotency_key LIKE 'p7d-%'), 'p7d-m1=manual,p7d-m2=manual,p7d-rep=replenishment',
  'old callers are manual; the replay kept replenishment; refused moves wrote nothing');
SELECT pg_temp.eq((SELECT quantity FROM public.inventory_location_balances WHERE inventory_item_id = pg_temp.item(501)
  AND inventory_location_id = pg_temp.unassigned()), 10::numeric, 'Unassigned gave 1 + 1 + 8');
SELECT pg_temp.eq(pg_temp.calc(501, 'first')->>'category', 'ok', 'after the move Tape@First is ok');
SELECT pg_temp.eq(pg_temp.calc(501, 'first')->>'current_quantity', '10', 'Tape@First holds its Target');
SELECT pg_temp.eq(pg_temp.donor_names(pg_temp.calc(501, 'academy')), 'Unassigned=10,FCC2 ATR=17,First Team ATR=5', 'donors follow live balances (First now spares 10 - 5)');
SELECT pg_temp.eq((pg_temp.calc(501, 'academy')->>'other_short_location_count')::int, 0, 'Academy is now the only short Tape location');

SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
