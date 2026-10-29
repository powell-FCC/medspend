-- Phase 7B.2 rollback-only behavioral verification: owner+admin count history reads. Run
-- against a disposable database after every migration through
-- 20261029120000_phase7b2_inventory_count_history.sql. Every fixture is rolled back; SET
-- CONSTRAINTS ALL IMMEDIATE before the rollback evaluates the deferred quantity invariant
-- for every row this suite touched.

BEGIN;

DO $phase7b2_fixture_guard$
BEGIN
  IF EXISTS (SELECT 1 FROM auth.users
             WHERE id BETWEEN '7b200000-0000-4000-8000-000000000001'::uuid AND '7b200000-0000-4000-8000-000000000099'::uuid)
     OR EXISTS (SELECT 1 FROM public.organizations
             WHERE id BETWEEN '7b200000-0000-4000-8000-000000000101'::uuid AND '7b200000-0000-4000-8000-000000000199'::uuid) THEN
    RAISE EXCEPTION 'Phase 7B.2 rollback-test fixture IDs already exist';
  END IF;
END
$phase7b2_fixture_guard$;

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

CREATE TEMP TABLE phase7b2_values (name text PRIMARY KEY, value jsonb) ON COMMIT DROP;
GRANT ALL ON phase7b2_values TO authenticated, anon;

CREATE FUNCTION pg_temp.val(_name text)
RETURNS jsonb LANGUAGE sql AS $$ SELECT value FROM phase7b2_values WHERE name = _name $$;
CREATE FUNCTION pg_temp.loc(_name text)
RETURNS uuid LANGUAGE sql AS $$ SELECT (value #>> '{}')::uuid FROM phase7b2_values WHERE name = 'loc:' || _name $$;
CREATE FUNCTION pg_temp.sid(_name text)
RETURNS uuid LANGUAGE sql AS $$ SELECT (value->>'sessionId')::uuid FROM phase7b2_values WHERE name = 'count:' || _name $$;
CREATE FUNCTION pg_temp.unassigned(_organization uuid)
RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM public.inventory_locations WHERE organization_id = _organization AND kind = 'unassigned' $$;

-- A complete count of a location as the current user: every countable item at the version
-- on the page, with quantities overridden by item id.
CREATE FUNCTION pg_temp.count(_organization uuid, _location uuid, _overrides jsonb, _key text)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.submit_inventory_count(_organization, _location, (
    SELECT jsonb_agg(jsonb_build_object(
        'inventoryItemId', item->>'inventoryItemId',
        'observedVersion', (item->>'version')::bigint,
        'countedQuantity', coalesce(_overrides->>(item->>'inventoryItemId'), item->>'quantity')))
    FROM jsonb_array_elements(public.get_inventory_count_location(_organization, _location)->'items') item), _key)
$$;

-- Every page of the history for the current user, following the keyset cursor.
CREATE FUNCTION pg_temp.all_pages(_organization uuid, _limit integer, _location uuid DEFAULT NULL,
  _person uuid DEFAULT NULL, _changed boolean DEFAULT false, _from timestamptz DEFAULT NULL, _before timestamptz DEFAULT NULL)
RETURNS uuid[] LANGUAGE plpgsql AS $$
DECLARE
  _ids uuid[] := '{}';
  _after_at timestamptz;
  _after_id uuid;
  _row record;
  _page_rows integer;
BEGIN
  FOR _guard IN 1 .. 500 LOOP
    _page_rows := 0;
    FOR _row IN SELECT * FROM public.list_inventory_count_history(_organization, _location, _person, _changed, _from, _before,
                                                                  _limit, _after_at, _after_id) LOOP
      _ids := _ids || _row.count_session_id;
      _after_at := _row.submitted_at;
      _after_id := _row.count_session_id;
      _page_rows := _page_rows + 1;
    END LOOP;
    IF _page_rows < _limit THEN RETURN _ids; END IF;
  END LOOP;
  RAISE EXCEPTION 'history paging did not finish';
END;
$$;

-- Everything a read must leave alone.
CREATE FUNCTION pg_temp.state(_organization uuid)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT jsonb_build_object(
    'items', (SELECT coalesce(jsonb_agg(to_jsonb(item) ORDER BY id), '[]')
              FROM public.inventory_items item WHERE organization_id = _organization),
    'balances', (SELECT coalesce(jsonb_agg(to_jsonb(balance) ORDER BY inventory_item_id, inventory_location_id), '[]')
                 FROM public.inventory_location_balances balance WHERE organization_id = _organization),
    'sessions', (SELECT coalesce(jsonb_agg(to_jsonb(session) ORDER BY id), '[]')
                 FROM public.inventory_count_sessions session WHERE organization_id = _organization),
    'lines', (SELECT coalesce(jsonb_agg(to_jsonb(line) ORDER BY id), '[]')
              FROM public.inventory_count_lines line WHERE organization_id = _organization),
    'adjustments', (SELECT coalesce(jsonb_agg(to_jsonb(adjustment) ORDER BY id), '[]')
                    FROM public.inventory_adjustments adjustment WHERE organization_id = _organization))
$$;

-- ---------------------------------------------------------------------------------------
-- Fixtures. A: owner 001, admin 002, staff 003, staff 006 (removed later: a former member).
-- B: owner 004, admin 005. 007 belongs to nothing.
-- ---------------------------------------------------------------------------------------
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('7b200000-0000-4000-8000-00000000000' || n)::uuid, 'authenticated', 'authenticated',
  'phase7b2-' || n || '@example.invalid', '', now(), '{}',
  CASE n WHEN 1 THEN '{"full_name": "Olivia Owner"}'::jsonb
         WHEN 3 THEN '{"full_name": "Sam Staff"}'::jsonb
         WHEN 6 THEN '{"full_name": "Fern Former"}'::jsonb
         ELSE '{}'::jsonb END, now(), now()
FROM generate_series(1, 7) n;

INSERT INTO public.organizations (id, name, created_by) VALUES
  ('7b200000-0000-4000-8000-000000000101', 'Phase 7B.2 Organization', '7b200000-0000-4000-8000-000000000001'),
  ('7b200000-0000-4000-8000-000000000102', 'Phase 7B.2 Other Organization', '7b200000-0000-4000-8000-000000000004');

INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES
  ('7b200000-0000-4000-8000-000000000101', '7b200000-0000-4000-8000-000000000001', 'owner', true),
  ('7b200000-0000-4000-8000-000000000101', '7b200000-0000-4000-8000-000000000002', 'admin', true),
  ('7b200000-0000-4000-8000-000000000101', '7b200000-0000-4000-8000-000000000003', 'staff', true),
  ('7b200000-0000-4000-8000-000000000101', '7b200000-0000-4000-8000-000000000006', 'staff', true),
  ('7b200000-0000-4000-8000-000000000102', '7b200000-0000-4000-8000-000000000004', 'owner', true),
  ('7b200000-0000-4000-8000-000000000102', '7b200000-0000-4000-8000-000000000005', 'admin', true);

-- Items start in Unassigned (inserted as postgres), in four different units.
INSERT INTO public.inventory_items (id, organization_id, sku, name, unit, quantity, last_purchase_price, par_level, active) VALUES
  ('7b200000-0000-4000-8000-000000000501', '7b200000-0000-4000-8000-000000000101', 'TAPE-1', 'P7B2 Tape', 'roll', 8, 9.87, 4, true),
  ('7b200000-0000-4000-8000-000000000502', '7b200000-0000-4000-8000-000000000101', 'GAUZE-1', 'P7B2 Gauze', 'box', 4, 3.21, NULL, true),
  ('7b200000-0000-4000-8000-000000000503', '7b200000-0000-4000-8000-000000000101', NULL, 'P7B2 Wrap', 'each', 6, NULL, NULL, true),
  ('7b200000-0000-4000-8000-000000000504', '7b200000-0000-4000-8000-000000000101', 'SAL-1', 'P7B2 Saline', 'bottle', 2.5, NULL, NULL, true),
  ('7b200000-0000-4000-8000-000000000505', '7b200000-0000-4000-8000-000000000101', 'KIT-1', 'P7B2 Archived Kit', 'each', 3, NULL, NULL, true),
  ('7b200000-0000-4000-8000-000000000506', '7b200000-0000-4000-8000-000000000101', 'PRE-1', 'P7B2 Prewrap', 'each', 5, NULL, NULL, true),
  ('7b200000-0000-4000-8000-000000000511', '7b200000-0000-4000-8000-000000000102', 'TAPE-1', 'P7B2 Other Tape', 'roll', 10, NULL, NULL, true);

SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b200000-0000-4000-8000-000000000001');
INSERT INTO phase7b2_values VALUES
  ('loc:cabinet', to_jsonb(public.create_inventory_location('7b200000-0000-4000-8000-000000000101', 'Cabinet'))),
  ('loc:rehab', to_jsonb(public.create_inventory_location('7b200000-0000-4000-8000-000000000101', 'Rehab'))),
  ('loc:closet', to_jsonb(public.create_inventory_location('7b200000-0000-4000-8000-000000000101', 'Closet')));
SELECT public.move_inventory_stock('7b200000-0000-4000-8000-000000000101', ('7b200000-0000-4000-8000-00000000050' || n)::uuid,
  pg_temp.unassigned('7b200000-0000-4000-8000-000000000101'), pg_temp.loc('cabinet'), q, 'fx-' || n)
FROM (VALUES (1, 6::numeric), (2, 4), (3, 6), (4, 2.5), (5, 3), (6, 5)) AS stock(n, q);
SELECT public.move_inventory_stock('7b200000-0000-4000-8000-000000000101', '7b200000-0000-4000-8000-000000000501',
  pg_temp.unassigned('7b200000-0000-4000-8000-000000000101'), pg_temp.loc('rehab'), 2, 'fx-rehab');
SELECT pg_temp.as_user('7b200000-0000-4000-8000-000000000004');
INSERT INTO phase7b2_values VALUES
  ('loc:other', to_jsonb(public.create_inventory_location('7b200000-0000-4000-8000-000000000102', 'Other Cabinet')));
SELECT public.move_inventory_stock('7b200000-0000-4000-8000-000000000102', '7b200000-0000-4000-8000-000000000511',
  pg_temp.unassigned('7b200000-0000-4000-8000-000000000102'), pg_temp.loc('other'), 10, 'fx-other');

-- Real counts through submit_inventory_count.
-- mixed (staff 003, Cabinet): Tape 6 -> 4 roll, Gauze 4 -> 5 box, Wrap 6 -> 3 each,
--   Prewrap 5 -> 9 each, Saline 2.5 -> 2.25 bottle, Archived Kit 3 -> 3 (unchanged).
SELECT pg_temp.as_user('7b200000-0000-4000-8000-000000000003');
INSERT INTO phase7b2_values VALUES ('count:mixed', pg_temp.count('7b200000-0000-4000-8000-000000000101', pg_temp.loc('cabinet'),
  '{"7b200000-0000-4000-8000-000000000501": "4", "7b200000-0000-4000-8000-000000000502": "5",
    "7b200000-0000-4000-8000-000000000503": "3", "7b200000-0000-4000-8000-000000000506": "9",
    "7b200000-0000-4000-8000-000000000504": "2.25"}', 'k-mixed'));
-- matched (owner 001, Cabinet): every quantity matches.
SELECT pg_temp.as_user('7b200000-0000-4000-8000-000000000001');
INSERT INTO phase7b2_values VALUES ('count:matched', pg_temp.count('7b200000-0000-4000-8000-000000000101', pg_temp.loc('cabinet'),
  '{}', 'k-matched'));
-- former (staff 006, Rehab): Tape 2 -> 3 roll. 006 then leaves the organization.
SELECT pg_temp.as_user('7b200000-0000-4000-8000-000000000006');
INSERT INTO phase7b2_values VALUES ('count:former', pg_temp.count('7b200000-0000-4000-8000-000000000101', pg_temp.loc('rehab'),
  '{"7b200000-0000-4000-8000-000000000501": "3"}', 'k-former'));
-- other (owner 004, organization B).
SELECT pg_temp.as_user('7b200000-0000-4000-8000-000000000004');
INSERT INTO phase7b2_values VALUES ('count:other', pg_temp.count('7b200000-0000-4000-8000-000000000102', pg_temp.loc('other'),
  '{"7b200000-0000-4000-8000-000000000511": "7"}', 'k-other'));
RESET ROLE;

-- After the counts: 006 leaves, the kit is archived (its stock moved out first), the tape
-- is renamed and re-unitized, and Closet is archived. History must keep the count-time view.
DELETE FROM public.organization_memberships
WHERE organization_id = '7b200000-0000-4000-8000-000000000101' AND user_id = '7b200000-0000-4000-8000-000000000006';
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b200000-0000-4000-8000-000000000001');
SELECT public.move_inventory_stock('7b200000-0000-4000-8000-000000000101', '7b200000-0000-4000-8000-000000000505',
  pg_temp.loc('cabinet'), pg_temp.unassigned('7b200000-0000-4000-8000-000000000101'), 3, 'fx-kit-out');
RESET ROLE;
UPDATE public.inventory_items SET active = false WHERE id = '7b200000-0000-4000-8000-000000000505';
UPDATE public.inventory_items SET name = 'Renamed Tape', sku = 'TAPE-NEW', unit = 'case'
WHERE id = '7b200000-0000-4000-8000-000000000501';

-- Historical sessions with chosen timestamps (inserted as postgres; the table only guards
-- UPDATE and DELETE). 24 at Closet in January 2026, alternating counters, every third with a
-- correction; two share one timestamp to exercise the id tiebreak.
INSERT INTO public.inventory_count_sessions (id, organization_id, inventory_location_id, counted_by, submitted_at,
  line_count, changed_count, idempotency_key, request_hash)
SELECT ('7b200000-0000-4000-8000-0000000a' || lpad(n::text, 4, '0'))::uuid, '7b200000-0000-4000-8000-000000000101',
  pg_temp.loc('closet'),
  CASE WHEN n % 2 = 0 THEN '7b200000-0000-4000-8000-000000000001'::uuid ELSE '7b200000-0000-4000-8000-000000000003'::uuid END,
  CASE WHEN n = 13 THEN timestamptz '2026-01-12 15:00:00+00' ELSE timestamptz '2026-01-01 15:00:00+00' + (n - 1) * interval '1 day' END,
  1, CASE WHEN n % 3 = 0 THEN 1 ELSE 0 END, 'hist-' || n, repeat('0', 64)
FROM generate_series(1, 24) n;
INSERT INTO public.inventory_count_lines (organization_id, count_session_id, inventory_item_id, inventory_location_id,
  previous_quantity, counted_quantity, delta, observed_version, item_name, item_sku, item_unit, created_at)
SELECT session.organization_id, session.id, '7b200000-0000-4000-8000-000000000503', session.inventory_location_id,
  5, 5 - session.changed_count, -session.changed_count, 1, 'P7B2 Wrap', NULL, 'each', session.submitted_at
FROM public.inventory_count_sessions session
WHERE session.idempotency_key LIKE 'hist-%' AND session.organization_id = '7b200000-0000-4000-8000-000000000101';
UPDATE public.inventory_locations SET active = false WHERE id = pg_temp.loc('closet');

-- ---------------------------------------------------------------------------------------
-- 1. Exact read contracts.
-- ---------------------------------------------------------------------------------------
SELECT pg_temp.assert(pg_get_function_result('public.list_inventory_count_history(uuid, uuid, uuid, boolean, timestamptz, timestamptz, integer, timestamptz, uuid)'::regprocedure)
  = 'TABLE(count_session_id uuid, submitted_at timestamp with time zone, inventory_location_id uuid, location_name text, location_active boolean, counted_by uuid, counted_by_name text, line_count integer, changed_count integer, correction_summary jsonb)',
  'history list contract');
SELECT pg_temp.assert(pg_get_function_arguments('public.list_inventory_count_history(uuid, uuid, uuid, boolean, timestamptz, timestamptz, integer, timestamptz, uuid)'::regprocedure)
  = '_organization_id uuid, _inventory_location_id uuid DEFAULT NULL::uuid, _counted_by uuid DEFAULT NULL::uuid, _changed_only boolean DEFAULT false, _submitted_from timestamp with time zone DEFAULT NULL::timestamp with time zone, _submitted_before timestamp with time zone DEFAULT NULL::timestamp with time zone, _limit integer DEFAULT 50, _after_submitted_at timestamp with time zone DEFAULT NULL::timestamp with time zone, _after_id uuid DEFAULT NULL::uuid',
  'history list arguments');
SELECT pg_temp.assert(pg_get_function_result('public.get_inventory_count_session(uuid, uuid)'::regprocedure) = 'jsonb',
  'session detail returns one JSON value');
SELECT pg_temp.assert(NOT EXISTS (
  SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname IN ('list_inventory_count_history', 'get_inventory_count_session')
    AND (pg_get_functiondef(p.oid) ILIKE '%last_purchase%' OR pg_get_functiondef(p.oid) ILIKE '%price%'
         OR pg_get_functiondef(p.oid) ILIKE '%inventory_adjustments%' OR pg_get_functiondef(p.oid) ILIKE '%email%'
         OR pg_get_functiondef(p.oid) ILIKE '%raw_user_meta%' OR p.provolatile <> 's')),
  'no prices, no adjustments ledger, no auth metadata, read-only volatility');

SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b200000-0000-4000-8000-000000000002');
SELECT pg_temp.assert(
  (SELECT array_agg(key ORDER BY key COLLATE "C") FROM jsonb_object_keys(
     public.get_inventory_count_session('7b200000-0000-4000-8000-000000000101', pg_temp.sid('mixed'))) key)
  = ARRAY['changedCount', 'correctionSummary', 'countedBy', 'countedByName', 'lineCount', 'lines', 'locationActive',
          'locationId', 'locationName', 'sessionId', 'submittedAt'],
  'session detail keys');
SELECT pg_temp.assert(
  (SELECT array_agg(DISTINCT key COLLATE "C" ORDER BY key COLLATE "C") FROM jsonb_array_elements(
     public.get_inventory_count_session('7b200000-0000-4000-8000-000000000101', pg_temp.sid('mixed'))->'lines') line,
     jsonb_object_keys(line) key)
  = ARRAY['countedQuantity', 'delta', 'inventoryItemId', 'itemArchivedNow', 'name', 'previousQuantity', 'sku', 'unit'],
  'session line keys');
SELECT pg_temp.assert(
  (SELECT array_agg(DISTINCT key COLLATE "C" ORDER BY key COLLATE "C") FROM jsonb_array_elements(
     public.get_inventory_count_session('7b200000-0000-4000-8000-000000000101', pg_temp.sid('mixed'))->'correctionSummary') unit,
     jsonb_object_keys(unit) key)
  = ARRAY['changedLines', 'decrease', 'increase', 'netDelta', 'unit'],
  'correction summary keys');
RESET ROLE;

-- ---------------------------------------------------------------------------------------
-- 2. Authorization: owner and admin pass with identical answers; staff, the other
--    organization's owner and admin, a former member, a non-member, a missing user and
--    anon are refused.
-- ---------------------------------------------------------------------------------------
CREATE TEMP TABLE phase7b2_reads (label text, statement text) ON COMMIT DROP;
GRANT ALL ON phase7b2_reads TO authenticated, anon;
INSERT INTO phase7b2_reads VALUES
  ('history', $$SELECT count(*) FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101')$$),
  ('session', format($$SELECT public.get_inventory_count_session('7b200000-0000-4000-8000-000000000101', %L)$$, pg_temp.sid('mixed')));

DO $reads$
DECLARE
  _read record;
  _user uuid;
BEGIN
  FOR _read IN SELECT * FROM phase7b2_reads LOOP
    FOREACH _user IN ARRAY ARRAY['7b200000-0000-4000-8000-000000000001', '7b200000-0000-4000-8000-000000000002']::uuid[] LOOP
      PERFORM pg_temp.as_user(_user);
      EXECUTE _read.statement;
    END LOOP;
    FOREACH _user IN ARRAY ARRAY['7b200000-0000-4000-8000-000000000003', '7b200000-0000-4000-8000-000000000004',
                                 '7b200000-0000-4000-8000-000000000005', '7b200000-0000-4000-8000-000000000006',
                                 '7b200000-0000-4000-8000-000000000007']::uuid[] LOOP
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
  FOR _read IN SELECT * FROM phase7b2_reads LOOP
    PERFORM pg_temp.expect_error(_read.statement, 'permission denied for function');
  END LOOP;
END
$anon$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b200000-0000-4000-8000-000000000001');
INSERT INTO phase7b2_values VALUES
  ('owner_list', (SELECT jsonb_agg(to_jsonb(history)) FROM public.list_inventory_count_history(
     '7b200000-0000-4000-8000-000000000101', _limit => 200) history)),
  ('owner_session', public.get_inventory_count_session('7b200000-0000-4000-8000-000000000101', pg_temp.sid('mixed')));
SELECT pg_temp.as_user('7b200000-0000-4000-8000-000000000002');
SELECT pg_temp.assert(pg_temp.val('owner_list') = (SELECT jsonb_agg(to_jsonb(history)) FROM public.list_inventory_count_history(
  '7b200000-0000-4000-8000-000000000101', _limit => 200) history), 'owner and admin get the same history');
SELECT pg_temp.assert(pg_temp.val('owner_session') =
  public.get_inventory_count_session('7b200000-0000-4000-8000-000000000101', pg_temp.sid('mixed')),
  'owner and admin get the same session detail');

-- Organization isolation: A's admin never sees B's count, by list or by id.
SELECT pg_temp.assert(NOT (pg_temp.val('owner_list') @> jsonb_build_array(jsonb_build_object('count_session_id', pg_temp.sid('other')))),
  'B count absent from A history');
SELECT pg_temp.assert(jsonb_array_length(pg_temp.val('owner_list')) = 27, 'A history: 3 real + 24 historical counts');
SELECT pg_temp.expect_error(format($$SELECT public.get_inventory_count_session('7b200000-0000-4000-8000-000000000101', %L)$$,
  pg_temp.sid('other')), 'Count not found');
SELECT pg_temp.expect_error($$SELECT public.get_inventory_count_session('7b200000-0000-4000-8000-000000000101',
  '7b200000-0000-4000-8000-00000000ffff')$$, 'Count not found');
SELECT pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101',
  pg_temp.loc('other'))), 'filtering A by B location returns nothing');
SELECT pg_temp.as_user('7b200000-0000-4000-8000-000000000005');
SELECT pg_temp.assert((SELECT array_agg(count_session_id) FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000102'))
  = ARRAY[pg_temp.sid('other')], 'B admin sees only B');
SELECT pg_temp.expect_error(format($$SELECT public.get_inventory_count_session('7b200000-0000-4000-8000-000000000102', %L)$$,
  pg_temp.sid('mixed')), 'Count not found');
RESET ROLE;

-- Raw-table access is unchanged: admins and staff still read no count rows directly.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b200000-0000-4000-8000-000000000002');
SELECT pg_temp.assert((SELECT count(*) FROM public.inventory_count_sessions) = 0, 'admin raw sessions: none');
SELECT pg_temp.assert((SELECT count(*) FROM public.inventory_count_lines) = 0, 'admin raw lines: none');
SELECT pg_temp.as_user('7b200000-0000-4000-8000-000000000003');
SELECT pg_temp.assert((SELECT count(*) FROM public.inventory_count_sessions) = 0, 'staff raw sessions: none');
SELECT pg_temp.assert((SELECT count(*) FROM public.inventory_count_lines) = 0, 'staff raw lines: none');
SELECT pg_temp.as_user('7b200000-0000-4000-8000-000000000001');
SELECT pg_temp.assert((SELECT count(*) FROM public.inventory_count_sessions) = 27, 'owner raw sessions: unchanged policy');
RESET ROLE;
SELECT pg_temp.assert(NOT has_table_privilege('anon', 'public.inventory_count_sessions', 'SELECT')
  AND NOT has_table_privilege('anon', 'public.inventory_count_lines', 'SELECT')
  AND NOT has_table_privilege('authenticated', 'public.inventory_count_sessions', 'INSERT')
  AND NOT has_table_privilege('authenticated', 'public.inventory_count_lines', 'UPDATE')
  AND NOT has_table_privilege('authenticated', 'public.inventory_count_sessions', 'DELETE'),
  'count table grants unchanged');
SELECT pg_temp.assert((SELECT array_agg(policyname::text ORDER BY policyname) FROM pg_policies
  WHERE schemaname = 'public' AND tablename IN ('inventory_count_sessions', 'inventory_count_lines'))
  = ARRAY['inventory_count_lines_owner_select', 'inventory_count_sessions_owner_select'], 'count table policies unchanged');

-- ---------------------------------------------------------------------------------------
-- 3. List rows: who, where, how many, and the per-unit correction summary.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b200000-0000-4000-8000-000000000002');
SELECT pg_temp.assert(
  (SELECT jsonb_agg(jsonb_build_array(location_name, location_active, counted_by_name, line_count, changed_count))
   FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101', _limit => 3))
  = '[["Rehab", true, "Former member", 1, 1], ["Cabinet", true, "Olivia Owner", 6, 0], ["Cabinet", true, "Sam Staff", 6, 5]]',
  'newest first, with location, person and counts');
SELECT pg_temp.assert(
  (SELECT correction_summary FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101', _limit => 3)
   WHERE count_session_id = pg_temp.sid('mixed'))
  = '[{"unit": "bottle", "changedLines": 1, "netDelta": -0.25, "increase": 0, "decrease": -0.25},
      {"unit": "box", "changedLines": 1, "netDelta": 1, "increase": 1, "decrease": 0},
      {"unit": "each", "changedLines": 2, "netDelta": 1, "increase": 4, "decrease": -3},
      {"unit": "roll", "changedLines": 1, "netDelta": -2, "increase": 0, "decrease": -2}]'::jsonb,
  'mixed units grouped by count-time unit, never added across units; renamed unit "case" not used');
SELECT pg_temp.assert(
  (SELECT correction_summary FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101', _limit => 3)
   WHERE count_session_id = pg_temp.sid('matched')) = '[]', 'zero-change count has an empty summary');
SELECT pg_temp.assert(
  (SELECT jsonb_agg(DISTINCT location_active) FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101',
     pg_temp.loc('closet'), _limit => 200)) = '[false]', 'archived location flagged as archived now');
SELECT pg_temp.assert(
  (SELECT counted_by FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101', _limit => 1))
  = '7b200000-0000-4000-8000-000000000006', 'former member user id still returned for filtering');

-- ---------------------------------------------------------------------------------------
-- 4. Filters, server-side.
-- ---------------------------------------------------------------------------------------
SELECT pg_temp.assert(
  (SELECT array_agg(count_session_id ORDER BY submitted_at DESC) FROM public.list_inventory_count_history(
     '7b200000-0000-4000-8000-000000000101', pg_temp.loc('cabinet')))
  = ARRAY[pg_temp.sid('matched'), pg_temp.sid('mixed')], 'location filter');
SELECT pg_temp.assert(
  (SELECT count(*) FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101', pg_temp.loc('closet'), _limit => 200)) = 24,
  'archived location history is still readable');
SELECT pg_temp.assert(
  (SELECT array_agg(count_session_id) FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101',
     _counted_by => '7b200000-0000-4000-8000-000000000006')) = ARRAY[pg_temp.sid('former')], 'person filter: former member');
SELECT pg_temp.assert(
  (SELECT count(*) FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101',
     _counted_by => '7b200000-0000-4000-8000-000000000003', _limit => 200)) = 13, 'person filter: staff 003 (1 real + 12 historical)');
SELECT pg_temp.assert(
  (SELECT bool_and(counted_by = '7b200000-0000-4000-8000-000000000001') AND count(*) = 13
   FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101',
     _counted_by => '7b200000-0000-4000-8000-000000000001', _limit => 200)), 'person filter: owner');
SELECT pg_temp.assert(
  (SELECT bool_and(changed_count > 0) AND count(*) = 10
   FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101', _changed_only => true, _limit => 200)),
  'changed-only filter: 2 real + 8 historical');
SELECT pg_temp.assert(
  (SELECT count(*) FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101',
     _submitted_from => '2026-01-05 00:00+00', _submitted_before => '2026-01-10 00:00+00')) = 5,
  'date filter: from inclusive, before exclusive (Jan 5 to Jan 9)');
SELECT pg_temp.assert(
  (SELECT count(*) FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101',
     _submitted_from => '2026-01-05 15:00+00', _submitted_before => '2026-01-06 15:00+00')) = 1,
  'date filter boundaries: a count exactly at the start is in, exactly at the end is out');
SELECT pg_temp.assert(
  (SELECT count(*) FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101',
     _submitted_before => '2026-02-01 00:00+00', _limit => 200)) = 24, 'open-ended before');
SELECT pg_temp.assert(
  (SELECT count(*) FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101',
     _submitted_from => '2026-02-01 00:00+00', _limit => 200)) = 3, 'open-ended from');
SELECT pg_temp.assert(
  (SELECT count(*) FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101', pg_temp.loc('closet'),
     '7b200000-0000-4000-8000-000000000001', true, '2026-01-01 00:00+00', '2026-01-20 00:00+00', 200)) = 3,
  'filters combine: closet, owner, changed, Jan 1 to 19 (days 6, 12, 18)');
SELECT pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101',
  _counted_by => '7b200000-0000-4000-8000-000000000007')), 'unknown person: no rows, no error');

-- Input validation.
SELECT pg_temp.expect_error($$SELECT * FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101', _limit => 0)$$,
  'Page size must be between 1 and 200');
SELECT pg_temp.expect_error($$SELECT * FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101', _limit => 201)$$,
  'Page size must be between 1 and 200');
SELECT pg_temp.expect_error($$SELECT * FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101',
  _after_submitted_at => now())$$, 'An incomplete page cursor was supplied');
SELECT pg_temp.expect_error($$SELECT * FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101',
  _after_id => '7b200000-0000-4000-8000-000000000001')$$, 'An incomplete page cursor was supplied');
SELECT pg_temp.expect_error($$SELECT * FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101',
  _submitted_from => '2026-01-05', _submitted_before => '2026-01-05')$$, 'The start of the date range must be before its end');
SELECT pg_temp.expect_error($$SELECT * FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101',
  _changed_only => NULL)$$, 'Choose whether to show only counts with corrections');

-- ---------------------------------------------------------------------------------------
-- 5. Keyset pagination: every page size walks the same complete, duplicate-free order,
--    including the two counts that share a timestamp; a count submitted mid-walk does not
--    shift later pages.
-- ---------------------------------------------------------------------------------------
INSERT INTO phase7b2_values VALUES ('full_order', (SELECT to_jsonb(array_agg(count_session_id)) FROM
  public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101', _limit => 200)));
SELECT pg_temp.assert(
  (SELECT bool_and(to_jsonb(pg_temp.all_pages('7b200000-0000-4000-8000-000000000101', size)) = pg_temp.val('full_order'))
   FROM unnest(ARRAY[1, 2, 5, 7, 26, 27, 28]) size), 'every page size yields the same order');
SELECT pg_temp.assert(
  (SELECT array_agg(count_session_id ORDER BY count_session_id DESC) FROM public.list_inventory_count_history(
     '7b200000-0000-4000-8000-000000000101', _submitted_from => '2026-01-12', _submitted_before => '2026-01-13'))
  = ARRAY['7b200000-0000-4000-8000-0000000a0013'::uuid, '7b200000-0000-4000-8000-0000000a0012'::uuid]
  AND (SELECT array_agg(count_session_id) FROM public.list_inventory_count_history(
     '7b200000-0000-4000-8000-000000000101', _submitted_from => '2026-01-12', _submitted_before => '2026-01-13'))
  = ARRAY['7b200000-0000-4000-8000-0000000a0013'::uuid, '7b200000-0000-4000-8000-0000000a0012'::uuid],
  'equal timestamps order by id descending');
SELECT pg_temp.assert(
  pg_temp.all_pages('7b200000-0000-4000-8000-000000000101', 1, _from => '2026-01-12', _before => '2026-01-13')
  = ARRAY['7b200000-0000-4000-8000-0000000a0013'::uuid, '7b200000-0000-4000-8000-0000000a0012'::uuid],
  'page size 1 crosses the timestamp tie without skipping or repeating');
SELECT pg_temp.assert(
  pg_temp.all_pages('7b200000-0000-4000-8000-000000000101', 3, pg_temp.loc('closet'), '7b200000-0000-4000-8000-000000000003', true)
  = (SELECT array_agg(count_session_id) FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101',
       pg_temp.loc('closet'), '7b200000-0000-4000-8000-000000000003', true, _limit => 200)),
  'filtered paging matches the filtered single page');

-- A new count lands between page 1 and page 2: page 2 continues from the cursor unchanged.
INSERT INTO phase7b2_values VALUES ('page1_last', (SELECT to_jsonb(history) FROM (
  SELECT * FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101', _limit => 5)
  ORDER BY submitted_at, count_session_id LIMIT 1) history));
SELECT pg_temp.as_user('7b200000-0000-4000-8000-000000000003');
INSERT INTO phase7b2_values VALUES ('count:late', pg_temp.count('7b200000-0000-4000-8000-000000000101', pg_temp.loc('rehab'), '{}', 'k-late'));
SELECT pg_temp.as_user('7b200000-0000-4000-8000-000000000002');
SELECT pg_temp.assert(
  (SELECT to_jsonb(array_agg(count_session_id)) FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101',
     _limit => 200, _after_submitted_at => (pg_temp.val('page1_last')->>'submitted_at')::timestamptz,
     _after_id => (pg_temp.val('page1_last')->>'count_session_id')::uuid))
  = (SELECT jsonb_agg(value ORDER BY ordinality) FROM jsonb_array_elements(pg_temp.val('full_order')) WITH ORDINALITY WHERE ordinality > 5),
  'the rest of the walk is unchanged by a newer count');
SELECT pg_temp.assert(
  (SELECT count_session_id FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101', _limit => 1))
  = pg_temp.sid('late'), 'the newer count is first on a fresh walk');
RESET ROLE;

-- ---------------------------------------------------------------------------------------
-- 6. Session detail: count-time snapshots, recorded/counted/correction, zero-delta lines
--    kept, changed lines first, archived-now separate from count time.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b200000-0000-4000-8000-000000000002');
INSERT INTO phase7b2_values VALUES
  ('mixed_detail', public.get_inventory_count_session('7b200000-0000-4000-8000-000000000101', pg_temp.sid('mixed'))),
  ('matched_detail', public.get_inventory_count_session('7b200000-0000-4000-8000-000000000101', pg_temp.sid('matched'))),
  ('former_detail', public.get_inventory_count_session('7b200000-0000-4000-8000-000000000101', pg_temp.sid('former')));
RESET ROLE;
SELECT pg_temp.assert(pg_temp.val('mixed_detail') - 'lines' - 'submittedAt' - 'correctionSummary' = jsonb_build_object(
  'sessionId', pg_temp.sid('mixed'), 'locationId', pg_temp.loc('cabinet'), 'locationName', 'Cabinet', 'locationActive', true,
  'countedBy', '7b200000-0000-4000-8000-000000000003', 'countedByName', 'Sam Staff', 'lineCount', 6, 'changedCount', 5),
  'mixed header');
SELECT pg_temp.assert((pg_temp.val('mixed_detail')->>'submittedAt')::timestamptz =
  (SELECT submitted_at FROM public.inventory_count_sessions WHERE id = pg_temp.sid('mixed')), 'header timestamp');
SELECT pg_temp.assert(pg_temp.val('mixed_detail')->'correctionSummary' =
  (SELECT row_value->'correction_summary' FROM jsonb_array_elements(pg_temp.val('owner_list')) row_value
   WHERE (row_value->>'count_session_id')::uuid = pg_temp.sid('mixed')), 'detail summary equals list summary');
SELECT pg_temp.assert(
  (SELECT jsonb_agg(jsonb_build_array(line->>'name', line->>'sku', line->>'unit', line->'previousQuantity',
     line->'countedQuantity', line->'delta', line->'itemArchivedNow') ORDER BY position)
   FROM jsonb_array_elements(pg_temp.val('mixed_detail')->'lines') WITH ORDINALITY AS lines(line, position))
  = '[["P7B2 Gauze", "GAUZE-1", "box", 4, 5, 1, false],
      ["P7B2 Prewrap", "PRE-1", "each", 5, 9, 4, false],
      ["P7B2 Saline", "SAL-1", "bottle", 2.5, 2.25, -0.25, false],
      ["P7B2 Tape", "TAPE-1", "roll", 6, 4, -2, false],
      ["P7B2 Wrap", null, "each", 6, 3, -3, false],
      ["P7B2 Archived Kit", "KIT-1", "each", 3, 3, 0, true]]'::jsonb,
  'changed first, then unchanged; snapshots not current name/SKU/unit; fractional exact; kit archived now');
SELECT pg_temp.assert(
  (SELECT jsonb_agg(line->'delta') FROM jsonb_array_elements(pg_temp.val('matched_detail')->'lines') line) = '[0, 0, 0, 0, 0, 0]'
  AND (pg_temp.val('matched_detail')->>'changedCount')::int = 0
  AND pg_temp.val('matched_detail')->'correctionSummary' = '[]'
  AND (pg_temp.val('matched_detail')->>'countedByName') = 'Olivia Owner',
  'zero-change count keeps every line');
SELECT pg_temp.assert(pg_temp.val('former_detail')->>'countedByName' = 'Former member'
  AND pg_temp.val('former_detail')->'lines'->0->>'name' = 'P7B2 Tape'
  AND pg_temp.val('former_detail')->'lines'->0->>'unit' = 'roll', 'former member and snapshot after rename');
SELECT pg_temp.assert(NOT (pg_temp.val('mixed_detail')::text LIKE '%Fern%')
  AND NOT (pg_temp.val('owner_list')::text LIKE '%Fern%')
  AND NOT (pg_temp.val('owner_list')::text LIKE '%example.invalid%')
  AND NOT (pg_temp.val('mixed_detail')::text LIKE '%example.invalid%'), 'no former-member name and no email leaks');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b200000-0000-4000-8000-000000000002');
SELECT pg_temp.assert(public.get_inventory_count_session('7b200000-0000-4000-8000-000000000101', '7b200000-0000-4000-8000-0000000a0024')
  ->>'locationActive' = 'false', 'archived location shown as archived now in detail');
RESET ROLE;

-- ---------------------------------------------------------------------------------------
-- 7. Count lines correspond to their physical_count adjustments under 7A.2 semantics: one
--    per line, zero deltas included, same item, location, amount, author and time.
-- ---------------------------------------------------------------------------------------
SELECT pg_temp.assert(NOT EXISTS (
  SELECT 1 FROM public.inventory_count_lines line
  JOIN public.inventory_count_sessions session ON session.id = line.count_session_id
  LEFT JOIN public.inventory_adjustments adjustment ON adjustment.inventory_count_line_id = line.id
  WHERE session.id IN (pg_temp.sid('mixed'), pg_temp.sid('matched'), pg_temp.sid('former'), pg_temp.sid('late'))
    AND (adjustment.id IS NULL OR adjustment.source_type IS DISTINCT FROM 'physical_count'
         OR adjustment.reason <> 'Physical count' OR adjustment.adjustment_amount <> line.delta
         OR adjustment.inventory_item_id <> line.inventory_item_id
         OR adjustment.inventory_location_id <> line.inventory_location_id
         OR adjustment.created_by <> session.counted_by OR adjustment.created_at <> session.submitted_at)),
  'every real count line has its matching physical_count adjustment');
SELECT pg_temp.assert(
  (SELECT count(*) FROM public.inventory_adjustments adjustment
   JOIN public.inventory_count_lines line ON line.id = adjustment.inventory_count_line_id
   WHERE line.count_session_id = pg_temp.sid('matched') AND adjustment.adjustment_amount = 0) = 6,
  'zero-delta lines still wrote zero physical_count adjustments');
SELECT pg_temp.assert(
  (SELECT bool_and(session.line_count = (SELECT count(*) FROM public.inventory_count_lines line WHERE line.count_session_id = session.id)
     AND session.changed_count = (SELECT count(*) FROM public.inventory_count_lines line
                                  WHERE line.count_session_id = session.id AND line.delta <> 0))
   FROM public.inventory_count_sessions session WHERE session.organization_id = '7b200000-0000-4000-8000-000000000101'),
  'header line and changed counts agree with the lines');

-- ---------------------------------------------------------------------------------------
-- 8. Reads change nothing, and count history stays immutable.
-- ---------------------------------------------------------------------------------------
INSERT INTO phase7b2_values VALUES ('state_before_reads', pg_temp.state('7b200000-0000-4000-8000-000000000101'));
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b200000-0000-4000-8000-000000000001');
SELECT count(*) FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101', _limit => 200);
SELECT public.get_inventory_count_session('7b200000-0000-4000-8000-000000000101', pg_temp.sid('mixed'));
SELECT pg_temp.as_user('7b200000-0000-4000-8000-000000000002');
SELECT count(*) FROM public.list_inventory_count_history('7b200000-0000-4000-8000-000000000101', _changed_only => true);
SELECT pg_temp.expect_error(format($$UPDATE public.inventory_count_sessions SET changed_count = 0 WHERE id = %L$$, pg_temp.sid('mixed')),
  'permission denied');
SELECT pg_temp.as_user('7b200000-0000-4000-8000-000000000001');
SELECT pg_temp.expect_error(format($$DELETE FROM public.inventory_count_lines WHERE count_session_id = %L$$, pg_temp.sid('mixed')),
  'permission denied');
RESET ROLE;
SELECT pg_temp.expect_error(format($$UPDATE public.inventory_count_sessions SET counted_by = '7b200000-0000-4000-8000-000000000001' WHERE id = %L$$,
  pg_temp.sid('mixed')), 'Inventory count history cannot be changed');
SELECT pg_temp.expect_error(format($$UPDATE public.inventory_count_lines SET delta = 0, counted_quantity = previous_quantity WHERE count_session_id = %L$$,
  pg_temp.sid('mixed')), 'Inventory count history cannot be changed');
SELECT pg_temp.assert(pg_temp.state('7b200000-0000-4000-8000-000000000101') = pg_temp.val('state_before_reads'),
  'reads and refused edits left inventory and count history unchanged');
SELECT pg_temp.assert(NOT EXISTS (
  SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname ~ '(edit|delete|reopen|recalculate|update|reassign)_inventory_count'),
  'no count edit, delete, reopen or recalculate function exists');

SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
