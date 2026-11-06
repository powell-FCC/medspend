-- Phase 7B.5 rollback-only behavioral verification: optional count cadence policy and count
-- freshness. Run against a disposable database after every migration through
-- 20261106120000_phase7b5_inventory_count_cadence.sql. Every fixture is rolled back; SET
-- CONSTRAINTS ALL IMMEDIATE before the rollback evaluates the deferred quantity invariant.

BEGIN;

DO $phase7b5_fixture_guard$
BEGIN
  IF EXISTS (SELECT 1 FROM auth.users
             WHERE id BETWEEN '7b500000-0000-4000-8000-000000000001'::uuid AND '7b500000-0000-4000-8000-000000000099'::uuid)
     OR EXISTS (SELECT 1 FROM public.organizations
             WHERE id BETWEEN '7b500000-0000-4000-8000-000000000101'::uuid AND '7b500000-0000-4000-8000-000000000199'::uuid) THEN
    RAISE EXCEPTION 'Phase 7B.5 rollback-test fixture IDs already exist';
  END IF;
END
$phase7b5_fixture_guard$;

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

CREATE TEMP TABLE phase7b5_values (name text PRIMARY KEY, value jsonb) ON COMMIT DROP;
GRANT ALL ON phase7b5_values TO authenticated, anon;
CREATE FUNCTION pg_temp.val(_name text)
RETURNS jsonb LANGUAGE sql AS $$ SELECT value FROM phase7b5_values WHERE name = _name $$;
CREATE FUNCTION pg_temp.loc(_name text)
RETURNS uuid LANGUAGE sql AS $$ SELECT (value #>> '{}')::uuid FROM phase7b5_values WHERE name = 'loc:' || _name $$;
CREATE FUNCTION pg_temp.unassigned(_organization uuid)
RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM public.inventory_locations WHERE organization_id = _organization AND kind = 'unassigned' $$;
-- The state of one location at a chosen time (internal function, called as postgres).
CREATE FUNCTION pg_temp.state_at(_location uuid, _as_of timestamptz)
RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT state FROM public.inventory_location_count_freshness('7b500000-0000-4000-8000-000000000101', _as_of)
  WHERE inventory_location_id = _location $$;
CREATE FUNCTION pg_temp.row_at(_location uuid, _as_of timestamptz)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT to_jsonb(f) FROM public.inventory_location_count_freshness('7b500000-0000-4000-8000-000000000101', _as_of) f
  WHERE inventory_location_id = _location $$;
-- A historical submitted count (inserted as postgres; the tables only guard UPDATE/DELETE).
CREATE FUNCTION pg_temp.past_count(_location uuid, _at timestamptz, _key text)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.inventory_count_sessions (organization_id, inventory_location_id, counted_by, submitted_at,
    line_count, changed_count, idempotency_key, request_hash)
  VALUES ('7b500000-0000-4000-8000-000000000101', _location, '7b500000-0000-4000-8000-000000000003', _at, 1, 0, _key, repeat('0', 64)) $$;
-- Everything a read or refused write must leave alone.
CREATE FUNCTION pg_temp.state(_organization uuid)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT jsonb_build_object(
    'policy', (SELECT to_jsonb(p) FROM public.inventory_count_policies p WHERE organization_id = _organization),
    'items', (SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY id), '[]') FROM public.inventory_items i WHERE organization_id = _organization),
    'balances', (SELECT coalesce(jsonb_agg(to_jsonb(b) ORDER BY inventory_item_id, inventory_location_id), '[]')
                 FROM public.inventory_location_balances b WHERE organization_id = _organization),
    'sessions', (SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY id), '[]') FROM public.inventory_count_sessions s WHERE organization_id = _organization),
    'adjustments', (SELECT count(*) FROM public.inventory_adjustments WHERE organization_id = _organization),
    'transfers', (SELECT count(*) FROM public.inventory_transfers WHERE organization_id = _organization))
$$;

-- ---------------------------------------------------------------------------------------
-- Fixtures. A: owner 001, admin 002, staff 003, second owner 008 (removed later: a former
-- member). B: owner 004, admin 005. 007 belongs to nothing.
-- ---------------------------------------------------------------------------------------
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('7b500000-0000-4000-8000-00000000000' || n)::uuid, 'authenticated', 'authenticated',
  'phase7b5-' || n || '@example.invalid', '', now(), '{}',
  CASE n WHEN 1 THEN '{"full_name": "Olivia Owner"}'::jsonb WHEN 8 THEN '{"full_name": "Otto Formerowner"}'::jsonb ELSE '{}'::jsonb END,
  now(), now()
FROM unnest(ARRAY[1, 2, 3, 4, 5, 7, 8]) n;

INSERT INTO public.organizations (id, name, created_by) VALUES
  ('7b500000-0000-4000-8000-000000000101', 'Phase 7B.5 Organization', '7b500000-0000-4000-8000-000000000001'),
  ('7b500000-0000-4000-8000-000000000102', 'Phase 7B.5 Other Organization', '7b500000-0000-4000-8000-000000000004');
INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES
  ('7b500000-0000-4000-8000-000000000101', '7b500000-0000-4000-8000-000000000001', 'owner', true),
  ('7b500000-0000-4000-8000-000000000101', '7b500000-0000-4000-8000-000000000002', 'admin', true),
  ('7b500000-0000-4000-8000-000000000101', '7b500000-0000-4000-8000-000000000003', 'staff', true),
  ('7b500000-0000-4000-8000-000000000101', '7b500000-0000-4000-8000-000000000008', 'owner', true),
  ('7b500000-0000-4000-8000-000000000102', '7b500000-0000-4000-8000-000000000004', 'owner', true),
  ('7b500000-0000-4000-8000-000000000102', '7b500000-0000-4000-8000-000000000005', 'admin', true);

INSERT INTO public.inventory_items (id, organization_id, sku, name, unit, quantity, active) VALUES
  ('7b500000-0000-4000-8000-000000000501', '7b500000-0000-4000-8000-000000000101', 'TAPE-1', 'P7B5 Tape', 'roll', 20, true),
  ('7b500000-0000-4000-8000-000000000502', '7b500000-0000-4000-8000-000000000101', 'GAUZE-1', 'P7B5 Gauze', 'box', 4, true),
  ('7b500000-0000-4000-8000-000000000511', '7b500000-0000-4000-8000-000000000102', 'TAPE-1', 'P7B5 Other Tape', 'roll', 5, true);

-- Storage locations of A: cabinet (counted twice), rehab (never counted), cart (counted at a
-- chosen instant for the boundary checks), closet (counted long ago), empty (nothing
-- countable), old (archived after being counted). B has one counted location.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b500000-0000-4000-8000-000000000001');
INSERT INTO phase7b5_values
SELECT 'loc:' || n, to_jsonb(public.create_inventory_location('7b500000-0000-4000-8000-000000000101', initcap(n)))
FROM unnest(ARRAY['cabinet', 'rehab', 'cart', 'closet', 'empty', 'old']) n;
SELECT public.move_inventory_stock('7b500000-0000-4000-8000-000000000101', '7b500000-0000-4000-8000-000000000501',
  pg_temp.unassigned('7b500000-0000-4000-8000-000000000101'), pg_temp.loc(n), 2, 'fx-' || n)
FROM unnest(ARRAY['cabinet', 'rehab', 'cart', 'closet', 'old']) n;
SELECT pg_temp.as_user('7b500000-0000-4000-8000-000000000004');
INSERT INTO phase7b5_values VALUES ('loc:other', to_jsonb(public.create_inventory_location('7b500000-0000-4000-8000-000000000102', 'Other Cabinet')));
SELECT public.move_inventory_stock('7b500000-0000-4000-8000-000000000102', '7b500000-0000-4000-8000-000000000511',
  pg_temp.unassigned('7b500000-0000-4000-8000-000000000102'), pg_temp.loc('other'), 5, 'fx-other');
RESET ROLE;
-- "empty" holds nothing: the gauze stays in Unassigned, and the 7A.2 rule counts only items
-- with a balance row at the location. Make that explicit by giving it no balance at all.
SELECT pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.inventory_location_balances WHERE inventory_location_id = pg_temp.loc('empty')),
  'empty location has no balance rows');

SELECT pg_temp.past_count(pg_temp.loc('cabinet'), '2026-01-01 10:00+00', 'cab-old');
SELECT pg_temp.past_count(pg_temp.loc('cabinet'), '2026-03-01 10:00+00', 'cab-new');
SELECT pg_temp.past_count(pg_temp.loc('cart'), '2026-02-01 12:00+00', 'cart');
SELECT pg_temp.past_count(pg_temp.loc('closet'), '2025-06-01 08:00+00', 'closet');
SELECT pg_temp.past_count(pg_temp.loc('old'), '2026-02-15 08:00+00', 'old');
INSERT INTO public.inventory_count_sessions (organization_id, inventory_location_id, counted_by, submitted_at,
  line_count, changed_count, idempotency_key, request_hash)
VALUES ('7b500000-0000-4000-8000-000000000102', pg_temp.loc('other'), '7b500000-0000-4000-8000-000000000004',
  '2025-01-01 00:00+00', 1, 0, 'other', repeat('0', 64));
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b500000-0000-4000-8000-000000000001');
SELECT public.move_inventory_stock('7b500000-0000-4000-8000-000000000101', '7b500000-0000-4000-8000-000000000501',
  pg_temp.loc('old'), pg_temp.unassigned('7b500000-0000-4000-8000-000000000101'), 2, 'fx-old-out');
SELECT public.set_inventory_location_active('7b500000-0000-4000-8000-000000000101', pg_temp.loc('old'), false);
RESET ROLE;

-- ---------------------------------------------------------------------------------------
-- 1. Structure: table, constraints, no client access, exact contracts.
-- ---------------------------------------------------------------------------------------
SELECT pg_temp.assert((SELECT array_agg(column_name::text ORDER BY ordinal_position) FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'inventory_count_policies')
  = ARRAY['organization_id', 'enabled', 'interval_days', 'created_at', 'updated_at', 'updated_by'], 'policy table columns');
SELECT pg_temp.assert((SELECT array_agg(conname::text ORDER BY conname) FROM pg_constraint
  WHERE conrelid = 'public.inventory_count_policies'::regclass)
  = ARRAY['inventory_count_policies_enabled_interval_check', 'inventory_count_policies_interval_days_check',
          'inventory_count_policies_organization_id_fkey', 'inventory_count_policies_pkey', 'inventory_count_policies_updated_by_fkey'],
  'policy table constraints');
SELECT pg_temp.assert(NOT has_table_privilege('authenticated', 'public.inventory_count_policies', 'SELECT')
  AND NOT has_table_privilege('authenticated', 'public.inventory_count_policies', 'INSERT')
  AND NOT has_table_privilege('authenticated', 'public.inventory_count_policies', 'UPDATE')
  AND NOT has_table_privilege('authenticated', 'public.inventory_count_policies', 'DELETE')
  AND NOT has_table_privilege('anon', 'public.inventory_count_policies', 'SELECT')
  AND (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.inventory_count_policies'::regclass)
  AND NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'inventory_count_policies'), 'no client access to the policy table');
SELECT pg_temp.assert(pg_get_function_result('public.inventory_location_count_freshness(uuid, timestamptz)'::regprocedure)
  = 'TABLE(inventory_location_id uuid, name text, active boolean, countable_item_count integer, last_counted_at timestamp with time zone, next_due_at timestamp with time zone, state text)',
  'freshness helper contract');
SELECT pg_temp.assert(NOT has_function_privilege('authenticated', 'public.inventory_location_count_freshness(uuid, timestamptz)', 'EXECUTE'),
  'freshness helper is internal');
SELECT pg_temp.assert(pg_get_function_arguments('public.set_inventory_count_policy(uuid, boolean, integer)'::regprocedure)
  = '_organization_id uuid, _enabled boolean, _interval_days integer', 'set policy arguments');
SELECT pg_temp.assert(pg_get_function_arguments('public.get_inventory_count_freshness(uuid, uuid, integer)'::regprocedure)
  = '_organization_id uuid, _inventory_location_id uuid DEFAULT NULL::uuid, _limit integer DEFAULT 10', 'freshness arguments');
SELECT pg_temp.assert(NOT EXISTS (
  SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname IN ('inventory_location_count_freshness', 'get_inventory_count_policy',
    'set_inventory_count_policy', 'get_inventory_count_freshness')
    AND (pg_get_functiondef(p.oid) ~* 'price|last_purchase|email|raw_user_meta|inventory_adjustments|inventory_transfers'
         OR pg_get_functiondef(p.oid) ~* '\m(shrink|waste|loss|stale|missing|consum)')),
  'no prices, auth metadata, ledgers or judgement words in cadence functions');

-- ---------------------------------------------------------------------------------------
-- 2. Authorization. Reads: owner and admin pass; staff, other organization, non-member,
--    missing user and anon refused. Write: owner only.
-- ---------------------------------------------------------------------------------------
CREATE TEMP TABLE phase7b5_reads (statement text) ON COMMIT DROP;
GRANT ALL ON phase7b5_reads TO authenticated, anon;
INSERT INTO phase7b5_reads VALUES
  ($$SELECT public.get_inventory_count_policy('7b500000-0000-4000-8000-000000000101')$$),
  ($$SELECT public.get_inventory_count_freshness('7b500000-0000-4000-8000-000000000101')$$);
DO $reads$
DECLARE _read record; _user uuid;
BEGIN
  FOR _read IN SELECT * FROM phase7b5_reads LOOP
    FOREACH _user IN ARRAY ARRAY['7b500000-0000-4000-8000-000000000001', '7b500000-0000-4000-8000-000000000002']::uuid[] LOOP
      PERFORM pg_temp.as_user(_user); EXECUTE _read.statement;
    END LOOP;
    FOREACH _user IN ARRAY ARRAY['7b500000-0000-4000-8000-000000000003', '7b500000-0000-4000-8000-000000000004',
                                 '7b500000-0000-4000-8000-000000000005', '7b500000-0000-4000-8000-000000000007']::uuid[] LOOP
      PERFORM pg_temp.as_user(_user);
      PERFORM pg_temp.expect_error(_read.statement, 'Forbidden: owner or admin access required');
    END LOOP;
    PERFORM pg_temp.as_user(NULL);
    PERFORM pg_temp.expect_error(_read.statement, 'Forbidden: owner or admin access required');
  END LOOP;
END
$reads$;
SET LOCAL ROLE authenticated;
DO $writes$
DECLARE _user uuid;
BEGIN
  FOREACH _user IN ARRAY ARRAY['7b500000-0000-4000-8000-000000000002', '7b500000-0000-4000-8000-000000000003',
                               '7b500000-0000-4000-8000-000000000004', '7b500000-0000-4000-8000-000000000005',
                               '7b500000-0000-4000-8000-000000000007']::uuid[] LOOP
    PERFORM pg_temp.as_user(_user);
    PERFORM pg_temp.expect_error($$SELECT public.set_inventory_count_policy('7b500000-0000-4000-8000-000000000101', true, 30)$$,
      'Forbidden: owner access required');
  END LOOP;
  PERFORM pg_temp.as_user(NULL);
  PERFORM pg_temp.expect_error($$SELECT public.set_inventory_count_policy('7b500000-0000-4000-8000-000000000101', true, 30)$$,
    'Forbidden: owner access required');
  -- Direct table access is refused for every signed-in role.
  PERFORM pg_temp.as_user('7b500000-0000-4000-8000-000000000001');
  PERFORM pg_temp.expect_error($$SELECT * FROM public.inventory_count_policies$$, 'permission denied');
  PERFORM pg_temp.expect_error($$INSERT INTO public.inventory_count_policies (organization_id, enabled, interval_days)
    VALUES ('7b500000-0000-4000-8000-000000000101', true, 30)$$, 'permission denied');
  PERFORM pg_temp.expect_error($$SELECT public.inventory_location_count_freshness('7b500000-0000-4000-8000-000000000101', now())$$,
    'permission denied');
END
$writes$;
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.expect_error($$SELECT public.get_inventory_count_policy('7b500000-0000-4000-8000-000000000101')$$, 'permission denied for function');
SELECT pg_temp.expect_error($$SELECT public.get_inventory_count_freshness('7b500000-0000-4000-8000-000000000101')$$, 'permission denied for function');
SELECT pg_temp.expect_error($$SELECT public.set_inventory_count_policy('7b500000-0000-4000-8000-000000000101', true, 30)$$, 'permission denied for function');
RESET ROLE;
SELECT pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.inventory_count_policies), 'refused writes created no policy');

-- ---------------------------------------------------------------------------------------
-- 3. Policy reads and writes: default off, validation, kept interval, former member name.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b500000-0000-4000-8000-000000000002');
SELECT pg_temp.assert(public.get_inventory_count_policy('7b500000-0000-4000-8000-000000000101')
  = '{"configured": false, "enabled": false, "intervalDays": null, "updatedAt": null, "updatedByName": null}', 'no row: off');
SELECT pg_temp.as_user('7b500000-0000-4000-8000-000000000001');
SELECT pg_temp.expect_error($$SELECT public.set_inventory_count_policy('7b500000-0000-4000-8000-000000000101', true, 0)$$, 'Count every 1 to 365 days');
SELECT pg_temp.expect_error($$SELECT public.set_inventory_count_policy('7b500000-0000-4000-8000-000000000101', true, -7)$$, 'Count every 1 to 365 days');
SELECT pg_temp.expect_error($$SELECT public.set_inventory_count_policy('7b500000-0000-4000-8000-000000000101', true, 366)$$, 'Count every 1 to 365 days');
SELECT pg_temp.expect_error($$SELECT public.set_inventory_count_policy('7b500000-0000-4000-8000-000000000101', false, 0)$$, 'Count every 1 to 365 days');
SELECT pg_temp.expect_error($$SELECT public.set_inventory_count_policy('7b500000-0000-4000-8000-000000000101', true, NULL)$$, 'Choose how many days between counts');
SELECT pg_temp.expect_error($$SELECT public.set_inventory_count_policy('7b500000-0000-4000-8000-000000000101', NULL, 30)$$, 'Choose whether count cadence is on');
RESET ROLE;
SELECT pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.inventory_count_policies), 'invalid values were refused, not coerced');
-- The table refuses invalid rows even without the function.
SELECT pg_temp.expect_error($$INSERT INTO public.inventory_count_policies (organization_id, enabled, interval_days)
  VALUES ('7b500000-0000-4000-8000-000000000102', true, NULL)$$, 'inventory_count_policies_enabled_interval_check');
SELECT pg_temp.expect_error($$INSERT INTO public.inventory_count_policies (organization_id, enabled, interval_days)
  VALUES ('7b500000-0000-4000-8000-000000000102', false, 400)$$, 'inventory_count_policies_interval_days_check');

SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b500000-0000-4000-8000-000000000008');
SELECT pg_temp.assert(public.set_inventory_count_policy('7b500000-0000-4000-8000-000000000101', true, 1) - 'updatedAt'
  = '{"configured": true, "enabled": true, "intervalDays": 1, "updatedByName": "Otto Formerowner"}', 'lower bound 1 accepted');
SELECT pg_temp.assert((public.set_inventory_count_policy('7b500000-0000-4000-8000-000000000101', true, 365)->>'intervalDays')::int = 365,
  'upper bound 365 accepted');
SELECT pg_temp.assert(public.set_inventory_count_policy('7b500000-0000-4000-8000-000000000101', false, NULL) - 'updatedAt'
  = '{"configured": true, "enabled": false, "intervalDays": 365, "updatedByName": "Otto Formerowner"}',
  'turning off without an interval keeps the stored one');
RESET ROLE;
SELECT pg_temp.assert((SELECT count(*) FROM public.inventory_count_policies WHERE organization_id = '7b500000-0000-4000-8000-000000000101') = 1,
  'one policy row per organization');
SELECT pg_temp.as_user(NULL);
DELETE FROM public.organization_memberships WHERE user_id = '7b500000-0000-4000-8000-000000000008';
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b500000-0000-4000-8000-000000000002');
SELECT pg_temp.assert(public.get_inventory_count_policy('7b500000-0000-4000-8000-000000000101')->>'updatedByName' = 'Former member',
  'former member resolved without exposing their name');
-- B's policy is B's: A's owner cannot set it, and A's setting is invisible to B.
SELECT pg_temp.as_user('7b500000-0000-4000-8000-000000000001');
SELECT pg_temp.expect_error($$SELECT public.set_inventory_count_policy('7b500000-0000-4000-8000-000000000102', true, 7)$$, 'Forbidden: owner access required');
SELECT pg_temp.as_user('7b500000-0000-4000-8000-000000000005');
SELECT pg_temp.assert((public.get_inventory_count_policy('7b500000-0000-4000-8000-000000000102')->>'configured')::boolean = false,
  'organization isolation');
RESET ROLE;

-- ---------------------------------------------------------------------------------------
-- 4. Freshness with cadence OFF: factual only. No due, overdue or current anywhere; never
--    counted stays available; no next due date is inferred.
-- ---------------------------------------------------------------------------------------
SELECT pg_temp.assert((SELECT jsonb_object_agg(name, state ORDER BY name) FROM public.inventory_location_count_freshness(
    '7b500000-0000-4000-8000-000000000101', '2027-12-31 00:00+00'))
  = '{"Cabinet": "counted", "Cart": "counted", "Closet": "counted", "Empty": "nothing_to_count", "Old": "not_applicable", "Rehab": "never_counted"}',
  'cadence off: factual states only, Unassigned excluded');
SELECT pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.inventory_location_count_freshness('7b500000-0000-4000-8000-000000000101', '2027-12-31')
  WHERE next_due_at IS NOT NULL), 'cadence off: no due date inferred');
SELECT pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.inventory_location_count_freshness('7b500000-0000-4000-8000-000000000101', now())
  WHERE inventory_location_id = pg_temp.unassigned('7b500000-0000-4000-8000-000000000101')), 'Unassigned never appears');
SELECT pg_temp.assert((SELECT jsonb_object_agg(name, state) FROM public.inventory_location_count_freshness(
    '7b500000-0000-4000-8000-000000000102', '2027-12-31')) = '{"Other Cabinet": "counted"}', 'cadence off in B too (no row)');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b500000-0000-4000-8000-000000000002');
INSERT INTO phase7b5_values VALUES ('off', public.get_inventory_count_freshness('7b500000-0000-4000-8000-000000000101'));
RESET ROLE;
SELECT pg_temp.assert(pg_temp.val('off') - 'evaluatedAt' = '{"policy": {"enabled": false, "intervalDays": null},
  "summary": {"current": 0, "due": 0, "overdue": 0, "neverCounted": 1, "counted": 3, "nothingToCount": 1},
  "attention": {"total": 0, "rows": []}, "nextDue": null, "location": null}', 'cadence off: RPC is factual');

-- ---------------------------------------------------------------------------------------
-- 5. Freshness with cadence ON (30 days): exact boundaries, newest count wins, archived and
--    empty locations never scheduled.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b500000-0000-4000-8000-000000000001');
SELECT public.set_inventory_count_policy('7b500000-0000-4000-8000-000000000101', true, 30);
RESET ROLE;
-- Cart: counted 2026-02-01 12:00 UTC, due 2026-03-03 12:00 UTC, overdue from 2026-03-04 12:00 UTC.
SELECT pg_temp.assert(pg_temp.row_at(pg_temp.loc('cart'), '2026-02-10') - 'state' - 'inventory_location_id'
  = '{"name": "Cart", "active": true, "countable_item_count": 1, "last_counted_at": "2026-02-01T12:00:00+00:00", "next_due_at": "2026-03-03T12:00:00+00:00"}',
  'next_due_at = last count + 30 days');
SELECT pg_temp.assert(pg_temp.state_at(pg_temp.loc('cart'), '2026-03-03 11:59:59.999999+00') = 'current', 'one microsecond before due: current');
SELECT pg_temp.assert(pg_temp.state_at(pg_temp.loc('cart'), '2026-03-03 12:00:00+00') = 'due', 'exactly at next_due_at: due');
SELECT pg_temp.assert(pg_temp.state_at(pg_temp.loc('cart'), '2026-03-04 11:59:59.999999+00') = 'due', 'last instant of the due day: due');
SELECT pg_temp.assert(pg_temp.state_at(pg_temp.loc('cart'), '2026-03-04 12:00:00+00') = 'overdue', 'one day past next_due_at: overdue');
SELECT pg_temp.assert(pg_temp.state_at(pg_temp.loc('cart'), '2027-01-01') = 'overdue', 'long past: overdue');
-- Cabinet: the newer of two counts (2026-03-01) decides.
SELECT pg_temp.assert((pg_temp.row_at(pg_temp.loc('cabinet'), '2026-03-15')->>'next_due_at')::timestamptz = '2026-03-31 10:00+00',
  'newest count decides');
SELECT pg_temp.assert(pg_temp.state_at(pg_temp.loc('cabinet'), '2026-03-15') = 'current', 'cabinet current mid-cycle');
SELECT pg_temp.assert(pg_temp.state_at(pg_temp.loc('closet'), '2026-03-15') = 'overdue', 'closet overdue');
SELECT pg_temp.assert(pg_temp.state_at(pg_temp.loc('rehab'), '2026-03-15') = 'never_counted'
  AND pg_temp.row_at(pg_temp.loc('rehab'), '2026-03-15')->'next_due_at' = 'null', 'never counted has no due date');
SELECT pg_temp.assert(pg_temp.state_at(pg_temp.loc('empty'), '2026-03-15') = 'nothing_to_count', 'nothing to count is never due');
SELECT pg_temp.assert(pg_temp.state_at(pg_temp.loc('old'), '2027-01-01') = 'not_applicable'
  AND pg_temp.row_at(pg_temp.loc('old'), '2027-01-01')->'next_due_at' = 'null', 'archived location is never scheduled');
-- A count before as_of but recorded later in the table still wins by submitted_at, not row order.
SELECT pg_temp.past_count(pg_temp.loc('cart'), '2026-01-15 00:00+00', 'cart-older-inserted-later');
SELECT pg_temp.assert(pg_temp.state_at(pg_temp.loc('cart'), '2026-03-03 12:00:00+00') = 'due', 'insertion order does not matter');
-- B's cadence is still off: A's policy does not leak.
SELECT pg_temp.assert((SELECT state FROM public.inventory_location_count_freshness('7b500000-0000-4000-8000-000000000102', '2027-12-31')) = 'counted',
  'policy is per organization');
-- A different interval moves every due date; one day is valid.
UPDATE public.inventory_count_policies SET interval_days = 1 WHERE organization_id = '7b500000-0000-4000-8000-000000000101';
SELECT pg_temp.assert(pg_temp.state_at(pg_temp.loc('cabinet'), '2026-03-02 09:59:59+00') = 'current'
  AND pg_temp.state_at(pg_temp.loc('cabinet'), '2026-03-02 10:00:00+00') = 'due'
  AND pg_temp.state_at(pg_temp.loc('cabinet'), '2026-03-03 10:00:00+00') = 'overdue', '1-day cadence boundaries');
UPDATE public.inventory_count_policies SET interval_days = 30 WHERE organization_id = '7b500000-0000-4000-8000-000000000101';

-- ---------------------------------------------------------------------------------------
-- 6. The RPC at now(): contract, owner = admin, attention ordering, location lookups.
-- ---------------------------------------------------------------------------------------
-- Real "now" fixtures: a count due within the day, one overdue, one current.
SELECT pg_temp.past_count(pg_temp.loc('cart'), now() - interval '30 days' - interval '1 hour', 'cart-due-now');
SELECT pg_temp.past_count(pg_temp.loc('cabinet'), now() - interval '2 days', 'cab-current-now');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b500000-0000-4000-8000-000000000001');
INSERT INTO phase7b5_values VALUES ('owner_on', public.get_inventory_count_freshness('7b500000-0000-4000-8000-000000000101'));
SELECT pg_temp.as_user('7b500000-0000-4000-8000-000000000002');
SELECT pg_temp.assert(public.get_inventory_count_freshness('7b500000-0000-4000-8000-000000000101') = pg_temp.val('owner_on'),
  'owner and admin get the same freshness');
RESET ROLE;
SELECT pg_temp.assert((SELECT array_agg(key ORDER BY key COLLATE "C") FROM jsonb_object_keys(pg_temp.val('owner_on')) key)
  = ARRAY['attention', 'evaluatedAt', 'location', 'nextDue', 'policy', 'summary'], 'freshness keys');
SELECT pg_temp.assert(pg_temp.val('owner_on')->'policy' = '{"enabled": true, "intervalDays": 30}'
  AND pg_temp.val('owner_on')->'summary' = '{"current": 1, "due": 1, "overdue": 1, "neverCounted": 1, "counted": 0, "nothingToCount": 1}',
  'summary at now');
SELECT pg_temp.assert((SELECT jsonb_agg(jsonb_build_array(row->>'name', row->>'state')) FROM jsonb_array_elements(pg_temp.val('owner_on')->'attention'->'rows') row)
  = '[["Closet", "overdue"], ["Cart", "due"]]' AND (pg_temp.val('owner_on')->'attention'->>'total')::int = 2,
  'attention: due and overdue only, most overdue first; never counted is not duplicated here');
SELECT pg_temp.assert(pg_temp.val('owner_on')->'nextDue'->>'name' = 'Cabinet'
  AND (pg_temp.val('owner_on')->'nextDue'->>'nextDueAt')::timestamptz = (now() - interval '2 days') + interval '30 days', 'next due among current');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b500000-0000-4000-8000-000000000002');
SELECT pg_temp.assert(public.get_inventory_count_freshness('7b500000-0000-4000-8000-000000000101', NULL, 1)->'attention'->'rows'->0->>'name' = 'Closet'
  AND (public.get_inventory_count_freshness('7b500000-0000-4000-8000-000000000101', NULL, 1)->'attention'->>'total')::int = 2, 'limit cuts rows, not total');
SELECT pg_temp.assert((public.get_inventory_count_freshness('7b500000-0000-4000-8000-000000000101', pg_temp.loc('cart'))->'location')
  - 'lastCountedAt' - 'nextDueAt' =jsonb_build_object('locationId', pg_temp.loc('cart'), 'state', 'due', 'countableItemCount', 1), 'one location');
SELECT pg_temp.assert(public.get_inventory_count_freshness('7b500000-0000-4000-8000-000000000101', pg_temp.unassigned('7b500000-0000-4000-8000-000000000101'))->'location'
  = jsonb_build_object('locationId', pg_temp.unassigned('7b500000-0000-4000-8000-000000000101'), 'state', 'not_applicable',
      'lastCountedAt', NULL, 'nextDueAt', NULL, 'countableItemCount', NULL), 'Unassigned: not applicable, no dates');
SELECT pg_temp.assert(public.get_inventory_count_freshness('7b500000-0000-4000-8000-000000000101', pg_temp.loc('old'))->'location'->>'state' = 'not_applicable',
  'archived: not applicable');
SELECT pg_temp.expect_error(format($$SELECT public.get_inventory_count_freshness('7b500000-0000-4000-8000-000000000101', %L)$$, pg_temp.loc('other')),
  'Inventory location not found');
SELECT pg_temp.expect_error($$SELECT public.get_inventory_count_freshness('7b500000-0000-4000-8000-000000000101', NULL, 0)$$, 'Attention list size must be between 1 and 50');
SELECT pg_temp.expect_error($$SELECT public.get_inventory_count_freshness('7b500000-0000-4000-8000-000000000101', NULL, 51)$$, 'Attention list size must be between 1 and 50');
RESET ROLE;

-- ---------------------------------------------------------------------------------------
-- 7. Counting is unchanged, and a new count makes the location current.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b500000-0000-4000-8000-000000000003');
SELECT public.submit_inventory_count('7b500000-0000-4000-8000-000000000101', pg_temp.loc('closet'), (
  SELECT jsonb_agg(jsonb_build_object('inventoryItemId', item->>'inventoryItemId', 'observedVersion', (item->>'version')::bigint,
    'countedQuantity', item->>'quantity'))
  FROM jsonb_array_elements(public.get_inventory_count_location('7b500000-0000-4000-8000-000000000101', pg_temp.loc('closet'))->'items') item),
  'p7b5-closet-now');
SELECT pg_temp.as_user('7b500000-0000-4000-8000-000000000001');
SELECT pg_temp.assert(public.get_inventory_count_freshness('7b500000-0000-4000-8000-000000000101', pg_temp.loc('closet'))->'location'->>'state' = 'current',
  'a submitted count makes the location current');
RESET ROLE;
SELECT pg_temp.assert((SELECT count(*) FROM public.inventory_adjustments a JOIN public.inventory_count_lines l ON l.id = a.inventory_count_line_id
  WHERE l.inventory_location_id = pg_temp.loc('closet') AND a.source_type = 'physical_count') = 1,
  'the 7A.2 physical_count ledger row is still written');

-- ---------------------------------------------------------------------------------------
-- 8. Reads change nothing; the overview and history functions are untouched.
-- ---------------------------------------------------------------------------------------
INSERT INTO phase7b5_values VALUES ('before_reads', pg_temp.state('7b500000-0000-4000-8000-000000000101'));
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b500000-0000-4000-8000-000000000002');
SELECT public.get_inventory_count_policy('7b500000-0000-4000-8000-000000000101');
SELECT public.get_inventory_count_freshness('7b500000-0000-4000-8000-000000000101', pg_temp.loc('cart'), 50);
RESET ROLE;
SELECT pg_temp.assert(pg_temp.state('7b500000-0000-4000-8000-000000000101') = pg_temp.val('before_reads'), 'reads changed nothing');
SELECT pg_temp.assert(NOT (pg_get_functiondef('public.get_inventory_overview(uuid, integer)'::regprocedure) ~* 'cadence|count_polic|freshness'),
  'the 7B.4 overview function is untouched');

SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
