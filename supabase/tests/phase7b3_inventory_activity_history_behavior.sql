-- Phase 7B.3 rollback-only behavioral verification: owner+admin transfer and manual
-- adjustment history. Run against a disposable database after every migration through
-- 20261029140000_phase7b3_inventory_activity_history.sql. Every fixture is rolled back; SET
-- CONSTRAINTS ALL IMMEDIATE before the rollback evaluates the deferred quantity invariant
-- for every row this suite touched.

BEGIN;

DO $phase7b3_fixture_guard$
BEGIN
  IF EXISTS (SELECT 1 FROM auth.users
             WHERE id BETWEEN '7b300000-0000-4000-8000-000000000001'::uuid AND '7b300000-0000-4000-8000-000000000099'::uuid)
     OR EXISTS (SELECT 1 FROM public.organizations
             WHERE id BETWEEN '7b300000-0000-4000-8000-000000000101'::uuid AND '7b300000-0000-4000-8000-000000000199'::uuid) THEN
    RAISE EXCEPTION 'Phase 7B.3 rollback-test fixture IDs already exist';
  END IF;
END
$phase7b3_fixture_guard$;

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

CREATE TEMP TABLE phase7b3_values (name text PRIMARY KEY, value jsonb) ON COMMIT DROP;
GRANT ALL ON phase7b3_values TO authenticated, anon;

CREATE FUNCTION pg_temp.val(_name text)
RETURNS jsonb LANGUAGE sql AS $$ SELECT value FROM phase7b3_values WHERE name = _name $$;
CREATE FUNCTION pg_temp.loc(_name text)
RETURNS uuid LANGUAGE sql AS $$ SELECT (value #>> '{}')::uuid FROM phase7b3_values WHERE name = 'loc:' || _name $$;
CREATE FUNCTION pg_temp.unassigned(_organization uuid)
RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM public.inventory_locations WHERE organization_id = _organization AND kind = 'unassigned' $$;

-- A complete count of a location as the current user, quantities overridden by item id.
CREATE FUNCTION pg_temp.count(_organization uuid, _location uuid, _overrides jsonb, _key text)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.submit_inventory_count(_organization, _location, (
    SELECT jsonb_agg(jsonb_build_object(
        'inventoryItemId', item->>'inventoryItemId',
        'observedVersion', (item->>'version')::bigint,
        'countedQuantity', coalesce(_overrides->>(item->>'inventoryItemId'), item->>'quantity')))
    FROM jsonb_array_elements(public.get_inventory_count_location(_organization, _location)->'items') item), _key)
$$;

-- Every page of transfer history for the current user, following the keyset cursor.
CREATE FUNCTION pg_temp.transfer_pages(_organization uuid, _limit integer, _location uuid DEFAULT NULL,
  _item uuid DEFAULT NULL, _person uuid DEFAULT NULL, _from timestamptz DEFAULT NULL, _before timestamptz DEFAULT NULL)
RETURNS uuid[] LANGUAGE plpgsql AS $$
DECLARE
  _ids uuid[] := '{}';
  _after_at timestamptz;
  _after_id uuid;
  _row record;
  _page_rows integer;
BEGIN
  FOR _guard IN 1 .. 1000 LOOP
    _page_rows := 0;
    FOR _row IN SELECT * FROM public.list_inventory_transfer_history(_organization, _location, _item, _person, _from, _before,
                                                                     _limit, _after_at, _after_id) LOOP
      _ids := _ids || _row.transfer_id;
      _after_at := _row.created_at;
      _after_id := _row.transfer_id;
      _page_rows := _page_rows + 1;
    END LOOP;
    IF _page_rows < _limit THEN RETURN _ids; END IF;
  END LOOP;
  RAISE EXCEPTION 'transfer paging did not finish';
END;
$$;

CREATE FUNCTION pg_temp.adjustment_pages(_organization uuid, _limit integer, _location uuid DEFAULT NULL,
  _item uuid DEFAULT NULL, _person uuid DEFAULT NULL, _reason text DEFAULT NULL, _from timestamptz DEFAULT NULL,
  _before timestamptz DEFAULT NULL)
RETURNS uuid[] LANGUAGE plpgsql AS $$
DECLARE
  _ids uuid[] := '{}';
  _after_at timestamptz;
  _after_id uuid;
  _row record;
  _page_rows integer;
BEGIN
  FOR _guard IN 1 .. 1000 LOOP
    _page_rows := 0;
    FOR _row IN SELECT * FROM public.list_inventory_adjustment_history(_organization, _location, _item, _person, _reason,
                                                                       _from, _before, _limit, _after_at, _after_id) LOOP
      _ids := _ids || _row.adjustment_id;
      _after_at := _row.created_at;
      _after_id := _row.adjustment_id;
      _page_rows := _page_rows + 1;
    END LOOP;
    IF _page_rows < _limit THEN RETURN _ids; END IF;
  END LOOP;
  RAISE EXCEPTION 'adjustment paging did not finish';
END;
$$;

-- The expected answers, straight from the tables (as postgres), newest first.
CREATE FUNCTION pg_temp.expected_transfers(_organization uuid, _where text DEFAULT 'true')
RETURNS uuid[] LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE _ids uuid[];
BEGIN
  EXECUTE format('SELECT coalesce(array_agg(t.id ORDER BY t.created_at DESC, t.id DESC), ''{}'')
                  FROM public.inventory_transfers t WHERE t.organization_id = %L AND (%s)', _organization, _where)
  INTO _ids;
  RETURN _ids;
END;
$$;
CREATE FUNCTION pg_temp.expected_adjustments(_organization uuid, _where text DEFAULT 'true')
RETURNS uuid[] LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE _ids uuid[];
BEGIN
  EXECUTE format('SELECT coalesce(array_agg(a.id ORDER BY a.created_at DESC, a.id DESC), ''{}'')
                  FROM public.inventory_adjustments a WHERE a.organization_id = %L
                    AND (a.source_type = ''manual'' OR (a.source_type IS NULL AND a.reason <> ''Invoice received''))
                    AND (%s)', _organization, _where)
  INTO _ids;
  RETURN _ids;
END;
$$;

-- Everything a read must leave alone.
CREATE FUNCTION pg_temp.state(_organization uuid)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT jsonb_build_object(
    'items', (SELECT coalesce(jsonb_agg(to_jsonb(item) ORDER BY id), '[]')
              FROM public.inventory_items item WHERE organization_id = _organization),
    'locations', (SELECT coalesce(jsonb_agg(to_jsonb(location) ORDER BY id), '[]')
                  FROM public.inventory_locations location WHERE organization_id = _organization),
    'balances', (SELECT coalesce(jsonb_agg(to_jsonb(balance) ORDER BY inventory_item_id, inventory_location_id), '[]')
                 FROM public.inventory_location_balances balance WHERE organization_id = _organization),
    'transfers', (SELECT coalesce(jsonb_agg(to_jsonb(transfer) ORDER BY id), '[]')
                  FROM public.inventory_transfers transfer WHERE organization_id = _organization),
    'adjustments', (SELECT coalesce(jsonb_agg(to_jsonb(adjustment) ORDER BY id), '[]')
                    FROM public.inventory_adjustments adjustment WHERE organization_id = _organization),
    'sessions', (SELECT coalesce(jsonb_agg(to_jsonb(session) ORDER BY id), '[]')
                 FROM public.inventory_count_sessions session WHERE organization_id = _organization),
    'lines', (SELECT coalesce(jsonb_agg(to_jsonb(line) ORDER BY id), '[]')
              FROM public.inventory_count_lines line WHERE organization_id = _organization))
$$;

-- ---------------------------------------------------------------------------------------
-- Fixtures. A: owner 001, admin 002, staff 003, owner 006 (removed later: a former member).
-- B: owner 004, admin 005. 007 belongs to nothing.
-- ---------------------------------------------------------------------------------------
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('7b300000-0000-4000-8000-00000000000' || n)::uuid, 'authenticated', 'authenticated',
  'phase7b3-' || n || '@example.invalid', '', now(), '{}',
  CASE n WHEN 1 THEN '{"full_name": "Olivia Owner"}'::jsonb
         WHEN 2 THEN '{"full_name": "Adam Admin"}'::jsonb
         WHEN 3 THEN '{"full_name": "Sam Staff"}'::jsonb
         WHEN 6 THEN '{"full_name": "Fern Former"}'::jsonb
         ELSE '{}'::jsonb END, now(), now()
FROM generate_series(1, 7) n;

INSERT INTO public.organizations (id, name, created_by) VALUES
  ('7b300000-0000-4000-8000-000000000101', 'Phase 7B.3 Organization', '7b300000-0000-4000-8000-000000000001'),
  ('7b300000-0000-4000-8000-000000000102', 'Phase 7B.3 Other Organization', '7b300000-0000-4000-8000-000000000004');

INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES
  ('7b300000-0000-4000-8000-000000000101', '7b300000-0000-4000-8000-000000000001', 'owner', true),
  ('7b300000-0000-4000-8000-000000000101', '7b300000-0000-4000-8000-000000000002', 'admin', true),
  ('7b300000-0000-4000-8000-000000000101', '7b300000-0000-4000-8000-000000000003', 'staff', true),
  ('7b300000-0000-4000-8000-000000000101', '7b300000-0000-4000-8000-000000000006', 'owner', true),
  ('7b300000-0000-4000-8000-000000000102', '7b300000-0000-4000-8000-000000000004', 'owner', true),
  ('7b300000-0000-4000-8000-000000000102', '7b300000-0000-4000-8000-000000000005', 'admin', true);

-- Items start in Unassigned (inserted as postgres).
INSERT INTO public.inventory_items (id, organization_id, sku, name, unit, quantity, last_purchase_price, active) VALUES
  ('7b300000-0000-4000-8000-000000000501', '7b300000-0000-4000-8000-000000000101', 'WRAP-4', 'Elastic Wrap 4"', 'each', 30, 4.56, true),
  ('7b300000-0000-4000-8000-000000000502', '7b300000-0000-4000-8000-000000000101', 'TAPE-1', 'P7B3 Tape', 'roll', 12, NULL, true),
  ('7b300000-0000-4000-8000-000000000503', '7b300000-0000-4000-8000-000000000101', NULL, 'P7B3 Gauze', 'box', 8.5, NULL, true),
  ('7b300000-0000-4000-8000-000000000511', '7b300000-0000-4000-8000-000000000102', 'TAPE-1', 'P7B3 Other Tape', 'roll', 10, NULL, true);

SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b300000-0000-4000-8000-000000000001');
INSERT INTO phase7b3_values VALUES
  ('loc:training', to_jsonb(public.create_inventory_location('7b300000-0000-4000-8000-000000000101', 'Training Room'))),
  ('loc:stadium', to_jsonb(public.create_inventory_location('7b300000-0000-4000-8000-000000000101', 'Stadium'))),
  ('loc:closet', to_jsonb(public.create_inventory_location('7b300000-0000-4000-8000-000000000101', 'Closet')));
-- Real moves by the owner: Wrap Unassigned -> Training 24, Training -> Stadium 6; Tape
-- Unassigned -> Stadium 4.
INSERT INTO phase7b3_values VALUES
  ('mv:wrap-in', public.move_inventory_stock('7b300000-0000-4000-8000-000000000101', '7b300000-0000-4000-8000-000000000501',
     pg_temp.unassigned('7b300000-0000-4000-8000-000000000101'), pg_temp.loc('training'), 24, 'mv-wrap-in')),
  ('mv:wrap-out', public.move_inventory_stock('7b300000-0000-4000-8000-000000000101', '7b300000-0000-4000-8000-000000000501',
     pg_temp.loc('training'), pg_temp.loc('stadium'), 6, 'mv-wrap-out')),
  ('mv:tape', public.move_inventory_stock('7b300000-0000-4000-8000-000000000101', '7b300000-0000-4000-8000-000000000502',
     pg_temp.unassigned('7b300000-0000-4000-8000-000000000101'), pg_temp.loc('stadium'), 4, 'mv-tape'));
-- Real manual adjustments by the owner: Wrap at Training -3 Damaged (org total 30 -> 27),
-- Tape at Stadium +2 Correction (12 -> 14), Gauze at Unassigned +0.25 Manual adjustment.
INSERT INTO phase7b3_values VALUES
  ('adj:damaged', public.adjust_inventory_location_quantity('7b300000-0000-4000-8000-000000000101',
     '7b300000-0000-4000-8000-000000000501', pg_temp.loc('training'), -3, 'Damaged')),
  ('adj:correction', public.adjust_inventory_location_quantity('7b300000-0000-4000-8000-000000000101',
     '7b300000-0000-4000-8000-000000000502', pg_temp.loc('stadium'), 2, 'Correction')),
  ('adj:unassigned', public.adjust_inventory_location_quantity('7b300000-0000-4000-8000-000000000101',
     '7b300000-0000-4000-8000-000000000503', pg_temp.unassigned('7b300000-0000-4000-8000-000000000101'), 0.25, 'Manual adjustment'));
-- Owner 006 moves Gauze to Training and records it Expired, then leaves the organization.
SELECT pg_temp.as_user('7b300000-0000-4000-8000-000000000006');
INSERT INTO phase7b3_values VALUES
  ('mv:former', public.move_inventory_stock('7b300000-0000-4000-8000-000000000101', '7b300000-0000-4000-8000-000000000503',
     pg_temp.unassigned('7b300000-0000-4000-8000-000000000101'), pg_temp.loc('training'), 2, 'mv-former')),
  ('adj:former', public.adjust_inventory_location_quantity('7b300000-0000-4000-8000-000000000101',
     '7b300000-0000-4000-8000-000000000503', pg_temp.loc('training'), -1, 'Expired'));
-- Staff 003 counts Training: Wrap 15 -> 13, Gauze 1 -> 1. This writes physical_count
-- adjustments, which belong to Counts only.
SELECT pg_temp.as_user('7b300000-0000-4000-8000-000000000003');
INSERT INTO phase7b3_values VALUES ('count:training', pg_temp.count('7b300000-0000-4000-8000-000000000101', pg_temp.loc('training'),
  '{"7b300000-0000-4000-8000-000000000501": "13"}', 'k-training'));
-- Organization B.
SELECT pg_temp.as_user('7b300000-0000-4000-8000-000000000004');
INSERT INTO phase7b3_values VALUES
  ('loc:other', to_jsonb(public.create_inventory_location('7b300000-0000-4000-8000-000000000102', 'Other Cabinet')));
SELECT public.move_inventory_stock('7b300000-0000-4000-8000-000000000102', '7b300000-0000-4000-8000-000000000511',
  pg_temp.unassigned('7b300000-0000-4000-8000-000000000102'), pg_temp.loc('other'), 10, 'mv-other');
SELECT public.adjust_inventory_location_quantity('7b300000-0000-4000-8000-000000000102',
  '7b300000-0000-4000-8000-000000000511', pg_temp.loc('other'), -1, 'Damaged');
RESET ROLE;

DELETE FROM public.organization_memberships
WHERE organization_id = '7b300000-0000-4000-8000-000000000101' AND user_id = '7b300000-0000-4000-8000-000000000006';

-- Rows only older code paths wrote (inserted as postgres; the ledger has no update guard
-- for inserts). Location-less rows predate Phase 7A.1, so the default-location trigger is
-- bypassed for them. None of these change a balance; reads do not care.
INSERT INTO public.inventory_adjustments (id, organization_id, inventory_item_id, inventory_location_id, adjustment_amount,
  previous_quantity, new_quantity, reason, created_by, created_at, source_type)
VALUES
  -- An invoice receipt (excluded: it belongs to its invoice).
  ('7b300000-0000-4000-8000-0000000c0001', '7b300000-0000-4000-8000-000000000101', '7b300000-0000-4000-8000-000000000502',
   pg_temp.unassigned('7b300000-0000-4000-8000-000000000101'), 5, 0, 5, 'Invoice received',
   '7b300000-0000-4000-8000-000000000001', timestamptz '2025-06-01 12:00:00+00', 'invoice'),
  -- A pre-provenance receipt (NULL source, 'Invoice received'; excluded).
  ('7b300000-0000-4000-8000-0000000c0002', '7b300000-0000-4000-8000-000000000101', '7b300000-0000-4000-8000-000000000502',
   pg_temp.unassigned('7b300000-0000-4000-8000-000000000101'), 3, 5, 8, 'Invoice received',
   '7b300000-0000-4000-8000-000000000001', timestamptz '2025-06-02 12:00:00+00', NULL),
  -- An owner's manual adjustment whose stored reason is 'Invoice received' (included as stored).
  ('7b300000-0000-4000-8000-0000000c0003', '7b300000-0000-4000-8000-000000000101', '7b300000-0000-4000-8000-000000000502',
   pg_temp.unassigned('7b300000-0000-4000-8000-000000000101'), 1, 8, 9, 'Invoice received',
   '7b300000-0000-4000-8000-000000000001', timestamptz '2025-06-03 12:00:00+00', 'manual');
ALTER TABLE public.inventory_adjustments DISABLE TRIGGER inventory_adjustments_default_location;
INSERT INTO public.inventory_adjustments (id, organization_id, inventory_item_id, inventory_location_id, adjustment_amount,
  previous_quantity, new_quantity, reason, created_by, created_at, source_type)
VALUES
  -- Pre-7A.1, pre-provenance manual rows: no location, NULL source. Included. One is zero.
  ('7b300000-0000-4000-8000-0000000c0004', '7b300000-0000-4000-8000-000000000101', '7b300000-0000-4000-8000-000000000503',
   NULL, -2, 10.5, 8.5, 'Damaged', '7b300000-0000-4000-8000-000000000001', timestamptz '2025-05-01 12:00:00+00', NULL),
  ('7b300000-0000-4000-8000-0000000c0005', '7b300000-0000-4000-8000-000000000101', '7b300000-0000-4000-8000-000000000503',
   NULL, 0, 10.5, 10.5, 'Correction', '7b300000-0000-4000-8000-000000000001', timestamptz '2025-04-30 12:00:00+00', NULL);
ALTER TABLE public.inventory_adjustments ENABLE TRIGGER inventory_adjustments_default_location;

-- Historical transfers and manual adjustments with chosen timestamps for paging and date
-- filters: 230 of each in 2026-01 .. 2026-08, alternating direction / reason / person; pairs
-- share a timestamp so the id tiebreak matters.
INSERT INTO public.inventory_transfers (id, organization_id, inventory_item_id, from_inventory_location_id,
  to_inventory_location_id, quantity, idempotency_key, created_by, created_at)
SELECT ('7b300000-0000-4000-8000-0000000a' || lpad(n::text, 4, '0'))::uuid, '7b300000-0000-4000-8000-000000000101',
  CASE WHEN n % 3 = 0 THEN '7b300000-0000-4000-8000-000000000502'::uuid ELSE '7b300000-0000-4000-8000-000000000501'::uuid END,
  CASE WHEN n % 2 = 0 THEN pg_temp.loc('training') ELSE pg_temp.loc('stadium') END,
  CASE WHEN n % 2 = 0 THEN pg_temp.loc('stadium') ELSE CASE WHEN n % 5 = 0 THEN pg_temp.loc('closet') ELSE pg_temp.loc('training') END END,
  1 + (n % 4) + CASE WHEN n = 7 THEN 0.25 ELSE 0 END, 'hist-' || n,
  CASE WHEN n % 4 = 0 THEN '7b300000-0000-4000-8000-000000000006'::uuid ELSE '7b300000-0000-4000-8000-000000000001'::uuid END,
  timestamptz '2026-01-01 12:00:00+00' + ((n + 1) / 2) * interval '1 day'
FROM generate_series(1, 230) n;
INSERT INTO public.inventory_adjustments (id, organization_id, inventory_item_id, inventory_location_id, adjustment_amount,
  previous_quantity, new_quantity, reason, created_by, created_at, source_type)
SELECT ('7b300000-0000-4000-8000-0000000b' || lpad(n::text, 4, '0'))::uuid, '7b300000-0000-4000-8000-000000000101',
  CASE WHEN n % 3 = 0 THEN '7b300000-0000-4000-8000-000000000502'::uuid ELSE '7b300000-0000-4000-8000-000000000501'::uuid END,
  CASE WHEN n % 2 = 0 THEN pg_temp.loc('training') ELSE pg_temp.loc('stadium') END,
  CASE WHEN n % 2 = 0 THEN -1 ELSE 2 END, 20, CASE WHEN n % 2 = 0 THEN 19 ELSE 22 END,
  (ARRAY['Manual adjustment', 'Damaged', 'Expired', 'Correction'])[1 + n % 4],
  CASE WHEN n % 4 = 0 THEN '7b300000-0000-4000-8000-000000000006'::uuid ELSE '7b300000-0000-4000-8000-000000000001'::uuid END,
  timestamptz '2026-01-01 12:00:00+00' + ((n + 1) / 2) * interval '1 day', 'manual'
FROM generate_series(1, 230) n;
-- Interleaved receipts with the same timestamps must never appear.
INSERT INTO public.inventory_adjustments (organization_id, inventory_item_id, inventory_location_id, adjustment_amount,
  previous_quantity, new_quantity, reason, created_by, created_at, source_type)
SELECT '7b300000-0000-4000-8000-000000000101', '7b300000-0000-4000-8000-000000000502',
  pg_temp.loc('stadium'), 1, 20, 21, 'Invoice received', '7b300000-0000-4000-8000-000000000001',
  timestamptz '2026-01-01 12:00:00+00' + n * interval '1 day', 'invoice'
FROM generate_series(1, 115) n;
UPDATE public.inventory_locations SET active = false WHERE id = pg_temp.loc('closet');

-- ---------------------------------------------------------------------------------------
-- 1. Exact read contracts.
-- ---------------------------------------------------------------------------------------
SELECT pg_temp.assert(pg_get_function_result('public.list_inventory_transfer_history(uuid, uuid, uuid, uuid, timestamptz, timestamptz, integer, timestamptz, uuid)'::regprocedure)
  = 'TABLE(transfer_id uuid, created_at timestamp with time zone, inventory_item_id uuid, item_name text, item_sku text, item_unit text, quantity numeric, from_location_id uuid, from_location_name text, to_location_id uuid, to_location_name text, created_by uuid, created_by_name text)',
  'transfer history contract');
SELECT pg_temp.assert(pg_get_function_arguments('public.list_inventory_transfer_history(uuid, uuid, uuid, uuid, timestamptz, timestamptz, integer, timestamptz, uuid)'::regprocedure)
  = '_organization_id uuid, _inventory_location_id uuid DEFAULT NULL::uuid, _inventory_item_id uuid DEFAULT NULL::uuid, _created_by uuid DEFAULT NULL::uuid, _created_from timestamp with time zone DEFAULT NULL::timestamp with time zone, _created_before timestamp with time zone DEFAULT NULL::timestamp with time zone, _limit integer DEFAULT 50, _after_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone, _after_id uuid DEFAULT NULL::uuid',
  'transfer history arguments');
SELECT pg_temp.assert(pg_get_function_result('public.list_inventory_adjustment_history(uuid, uuid, uuid, uuid, text, timestamptz, timestamptz, integer, timestamptz, uuid)'::regprocedure)
  = 'TABLE(adjustment_id uuid, created_at timestamp with time zone, inventory_item_id uuid, item_name text, item_sku text, item_unit text, inventory_location_id uuid, location_name text, previous_quantity numeric, adjustment_amount numeric, new_quantity numeric, reason text, source_type text, created_by uuid, created_by_name text)',
  'adjustment history contract');
SELECT pg_temp.assert(pg_get_function_arguments('public.list_inventory_adjustment_history(uuid, uuid, uuid, uuid, text, timestamptz, timestamptz, integer, timestamptz, uuid)'::regprocedure)
  = '_organization_id uuid, _inventory_location_id uuid DEFAULT NULL::uuid, _inventory_item_id uuid DEFAULT NULL::uuid, _created_by uuid DEFAULT NULL::uuid, _reason text DEFAULT NULL::text, _created_from timestamp with time zone DEFAULT NULL::timestamp with time zone, _created_before timestamp with time zone DEFAULT NULL::timestamp with time zone, _limit integer DEFAULT 50, _after_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone, _after_id uuid DEFAULT NULL::uuid',
  'adjustment history arguments');
SELECT pg_temp.assert(NOT EXISTS (
  SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname IN ('list_inventory_transfer_history', 'list_inventory_adjustment_history')
    AND (pg_get_functiondef(p.oid) ILIKE '%last_purchase%' OR pg_get_functiondef(p.oid) ILIKE '%price%'
         OR pg_get_functiondef(p.oid) ILIKE '%source_invoice%' OR pg_get_functiondef(p.oid) ILIKE '%email%'
         OR pg_get_functiondef(p.oid) ILIKE '%raw_user_meta%' OR pg_get_functiondef(p.oid) ILIKE '%idempotency%'
         OR p.provolatile <> 's' OR NOT p.prosecdef
         OR NOT (p.proconfig @> ARRAY['plan_cache_mode=force_custom_plan']))),
  'no prices, invoice internals, idempotency keys or auth metadata; STABLE SECURITY DEFINER with custom plans');
SELECT pg_temp.assert(
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname IN ('list_inventory_transfer_history', 'list_inventory_adjustment_history')) = 2,
  'exactly one overload of each');

-- ---------------------------------------------------------------------------------------
-- 2. Authorization: owner and admin pass with identical answers; staff, the other
--    organization's owner and admin, the former member, a non-member, a missing user and
--    anon are refused.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b300000-0000-4000-8000-000000000001');
INSERT INTO phase7b3_values VALUES
  ('owner:transfers', (SELECT jsonb_agg(to_jsonb(row) ORDER BY row.created_at DESC, row.transfer_id DESC)
     FROM public.list_inventory_transfer_history('7b300000-0000-4000-8000-000000000101', _limit => 200) row)),
  ('owner:adjustments', (SELECT jsonb_agg(to_jsonb(row) ORDER BY row.created_at DESC, row.adjustment_id DESC)
     FROM public.list_inventory_adjustment_history('7b300000-0000-4000-8000-000000000101', _limit => 200) row));
SELECT pg_temp.as_user('7b300000-0000-4000-8000-000000000002');
SELECT pg_temp.assert(pg_temp.val('owner:transfers') = (SELECT jsonb_agg(to_jsonb(row) ORDER BY row.created_at DESC, row.transfer_id DESC)
     FROM public.list_inventory_transfer_history('7b300000-0000-4000-8000-000000000101', _limit => 200) row),
  'admin transfer history is identical to the owner''s');
SELECT pg_temp.assert(pg_temp.val('owner:adjustments') = (SELECT jsonb_agg(to_jsonb(row) ORDER BY row.created_at DESC, row.adjustment_id DESC)
     FROM public.list_inventory_adjustment_history('7b300000-0000-4000-8000-000000000101', _limit => 200) row),
  'admin adjustment history is identical to the owner''s');
SELECT pg_temp.assert(jsonb_array_length(pg_temp.val('owner:transfers')) = 200
  AND jsonb_array_length(pg_temp.val('owner:adjustments')) = 200, 'a 200-row page is full');

CREATE FUNCTION pg_temp.expect_refused(_user_id uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.as_user(_user_id);
  PERFORM pg_temp.expect_error(
    $q$SELECT * FROM public.list_inventory_transfer_history('7b300000-0000-4000-8000-000000000101')$q$, 'owner or admin access required');
  PERFORM pg_temp.expect_error(
    $q$SELECT * FROM public.list_inventory_adjustment_history('7b300000-0000-4000-8000-000000000101')$q$, 'owner or admin access required');
END;
$$;
-- Staff, B's owner and admin, the former member, a non-member and no user at all.
SELECT pg_temp.expect_refused(user_id)
FROM (VALUES ('7b300000-0000-4000-8000-000000000003'::uuid), ('7b300000-0000-4000-8000-000000000004'::uuid),
             ('7b300000-0000-4000-8000-000000000005'::uuid), ('7b300000-0000-4000-8000-000000000006'::uuid),
             ('7b300000-0000-4000-8000-000000000007'::uuid), (NULL::uuid)) AS refused(user_id);
-- Organization B's owner reads only B.
SELECT pg_temp.as_user('7b300000-0000-4000-8000-000000000004');
SELECT pg_temp.assert((SELECT count(*) FROM public.list_inventory_transfer_history('7b300000-0000-4000-8000-000000000102')) = 1
  AND (SELECT count(*) FROM public.list_inventory_adjustment_history('7b300000-0000-4000-8000-000000000102')) = 1,
  'organization B sees only its own history');
-- A's location asked about inside B's organization returns nothing.
SELECT pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.list_inventory_transfer_history('7b300000-0000-4000-8000-000000000102', pg_temp.loc('training')))
  AND NOT EXISTS (SELECT 1 FROM public.list_inventory_adjustment_history('7b300000-0000-4000-8000-000000000102', pg_temp.loc('training')))
  AND NOT EXISTS (SELECT 1 FROM public.list_inventory_transfer_history('7b300000-0000-4000-8000-000000000102', _inventory_item_id => '7b300000-0000-4000-8000-000000000501')),
  'another organization''s location or item yields nothing');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.expect_error($$SELECT * FROM public.list_inventory_transfer_history('7b300000-0000-4000-8000-000000000101')$$, 'permission denied');
SELECT pg_temp.expect_error($$SELECT * FROM public.list_inventory_adjustment_history('7b300000-0000-4000-8000-000000000101')$$, 'permission denied');
RESET ROLE;
SELECT pg_temp.assert(NOT has_function_privilege('anon', 'public.list_inventory_transfer_history(uuid, uuid, uuid, uuid, timestamptz, timestamptz, integer, timestamptz, uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.list_inventory_adjustment_history(uuid, uuid, uuid, uuid, text, timestamptz, timestamptz, integer, timestamptz, uuid)', 'EXECUTE'),
  'anon has no EXECUTE');
-- Staff raw-table reads still return nothing; admins still have no raw transfer rows.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b300000-0000-4000-8000-000000000003');
SELECT pg_temp.assert((SELECT count(*) FROM public.inventory_transfers) = 0 AND (SELECT count(*) FROM public.inventory_adjustments) = 0,
  'staff raw inventory history reads stay empty');
SELECT pg_temp.as_user('7b300000-0000-4000-8000-000000000002');
SELECT pg_temp.assert((SELECT count(*) FROM public.inventory_transfers) = 0 AND (SELECT count(*) FROM public.inventory_adjustments) = 0,
  'admin raw inventory history reads stay empty (RLS not broadened)');
RESET ROLE;

-- ---------------------------------------------------------------------------------------
-- 3. Transfers: one real move, field by field; filters; paging.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b300000-0000-4000-8000-000000000002');
SELECT pg_temp.assert((
  SELECT row.inventory_item_id = '7b300000-0000-4000-8000-000000000501' AND row.item_name = 'Elastic Wrap 4"'
     AND row.item_sku = 'WRAP-4' AND row.item_unit = 'each' AND row.quantity = 6
     AND row.from_location_id = pg_temp.loc('training') AND row.from_location_name = 'Training Room'
     AND row.to_location_id = pg_temp.loc('stadium') AND row.to_location_name = 'Stadium'
     AND row.created_by = '7b300000-0000-4000-8000-000000000001' AND row.created_by_name = 'Olivia Owner'
     AND row.created_at = now()
  FROM public.list_inventory_transfer_history('7b300000-0000-4000-8000-000000000101') row
  WHERE row.transfer_id = (pg_temp.val('mv:wrap-out')->>'transferId')::uuid), 'transfer row fields');
SELECT pg_temp.assert((
  SELECT row.created_by_name = 'Former member' AND row.from_location_name = 'Unassigned'
  FROM public.list_inventory_transfer_history('7b300000-0000-4000-8000-000000000101') row
  WHERE row.transfer_id = (pg_temp.val('mv:former')->>'transferId')::uuid), 'former member and Unassigned on a transfer');
SELECT pg_temp.assert(pg_temp.transfer_pages('7b300000-0000-4000-8000-000000000101', 50)
  = pg_temp.expected_transfers('7b300000-0000-4000-8000-000000000101'), 'all transfers, newest first');
SELECT pg_temp.assert(cardinality(pg_temp.expected_transfers('7b300000-0000-4000-8000-000000000101')) = 234, 'fixture size');
-- Location filter: OUT and IN, both sides, no duplicates.
SELECT pg_temp.assert(pg_temp.transfer_pages('7b300000-0000-4000-8000-000000000101', 7, pg_temp.loc('training'))
  = pg_temp.expected_transfers('7b300000-0000-4000-8000-000000000101',
      format('t.from_inventory_location_id = %L OR t.to_inventory_location_id = %L', pg_temp.loc('training'), pg_temp.loc('training'))),
  'location filter matches either side');
SELECT pg_temp.assert((pg_temp.val('mv:wrap-out')->>'transferId')::uuid = ANY (pg_temp.transfer_pages('7b300000-0000-4000-8000-000000000101', 50, pg_temp.loc('training')))
  AND (pg_temp.val('mv:wrap-in')->>'transferId')::uuid = ANY (pg_temp.transfer_pages('7b300000-0000-4000-8000-000000000101', 50, pg_temp.loc('training'))),
  'Training shows its transfer out (from side) and its transfer in (to side)');
SELECT pg_temp.assert((SELECT count(*) = count(DISTINCT id) FROM unnest(pg_temp.transfer_pages('7b300000-0000-4000-8000-000000000101', 3, pg_temp.loc('stadium'))) id),
  'no transfer returned twice');
SELECT pg_temp.assert(pg_temp.transfer_pages('7b300000-0000-4000-8000-000000000101', 11, pg_temp.loc('closet'))
  = pg_temp.expected_transfers('7b300000-0000-4000-8000-000000000101', format('t.to_inventory_location_id = %L', pg_temp.loc('closet')))
  AND cardinality(pg_temp.transfer_pages('7b300000-0000-4000-8000-000000000101', 11, pg_temp.loc('closet'))) = 23,
  'an archived location keeps its history');
SELECT pg_temp.assert(pg_temp.transfer_pages('7b300000-0000-4000-8000-000000000101', 50, pg_temp.unassigned('7b300000-0000-4000-8000-000000000101'))
  = pg_temp.expected_transfers('7b300000-0000-4000-8000-000000000101',
      format('t.from_inventory_location_id = %L', pg_temp.unassigned('7b300000-0000-4000-8000-000000000101')))
  AND cardinality(pg_temp.transfer_pages('7b300000-0000-4000-8000-000000000101', 50, pg_temp.unassigned('7b300000-0000-4000-8000-000000000101'))) = 3,
  'Unassigned participates in transfers');
-- Item, person, date, combined.
SELECT pg_temp.assert(pg_temp.transfer_pages('7b300000-0000-4000-8000-000000000101', 13, NULL, '7b300000-0000-4000-8000-000000000502')
  = pg_temp.expected_transfers('7b300000-0000-4000-8000-000000000101', $$t.inventory_item_id = '7b300000-0000-4000-8000-000000000502'$$),
  'item filter');
SELECT pg_temp.assert(pg_temp.transfer_pages('7b300000-0000-4000-8000-000000000101', 13, NULL, NULL, '7b300000-0000-4000-8000-000000000006')
  = pg_temp.expected_transfers('7b300000-0000-4000-8000-000000000101', $$t.created_by = '7b300000-0000-4000-8000-000000000006'$$)
  AND cardinality(pg_temp.transfer_pages('7b300000-0000-4000-8000-000000000101', 13, NULL, NULL, '7b300000-0000-4000-8000-000000000006')) = 58,
  'person filter, including a former member');
SELECT pg_temp.assert(pg_temp.transfer_pages('7b300000-0000-4000-8000-000000000101', 9, NULL, NULL, NULL,
    timestamptz '2026-02-01 00:00:00+00', timestamptz '2026-03-01 00:00:00+00')
  = pg_temp.expected_transfers('7b300000-0000-4000-8000-000000000101',
      $$t.created_at >= '2026-02-01 00:00:00+00' AND t.created_at < '2026-03-01 00:00:00+00'$$)
  AND cardinality(pg_temp.transfer_pages('7b300000-0000-4000-8000-000000000101', 9, NULL, NULL, NULL,
    timestamptz '2026-02-01 00:00:00+00', timestamptz '2026-03-01 00:00:00+00')) = 56,
  'half-open date range');
SELECT pg_temp.assert(pg_temp.transfer_pages('7b300000-0000-4000-8000-000000000101', 4, pg_temp.loc('training'),
    '7b300000-0000-4000-8000-000000000501', '7b300000-0000-4000-8000-000000000001', timestamptz '2026-01-15 00:00:00+00', NULL)
  = pg_temp.expected_transfers('7b300000-0000-4000-8000-000000000101', format(
      '(t.from_inventory_location_id = %L OR t.to_inventory_location_id = %L) AND t.inventory_item_id = %L AND t.created_by = %L AND t.created_at >= %L',
      pg_temp.loc('training'), pg_temp.loc('training'), '7b300000-0000-4000-8000-000000000501',
      '7b300000-0000-4000-8000-000000000001', '2026-01-15 00:00:00+00')),
  'all filters together');
-- Boundaries: the start is inclusive and the end exclusive, to the instant.
SELECT pg_temp.assert((SELECT array_agg(row.transfer_id ORDER BY row.transfer_id)
  FROM public.list_inventory_transfer_history('7b300000-0000-4000-8000-000000000101',
    _created_from => '2026-01-02 12:00:00+00', _created_before => '2026-01-03 12:00:00+00') row)
  = ARRAY['7b300000-0000-4000-8000-0000000a0001', '7b300000-0000-4000-8000-0000000a0002']::uuid[],
  'transfer date boundaries are [from, before)');
SELECT pg_temp.assert((SELECT array_agg(row.adjustment_id ORDER BY row.adjustment_id)
  FROM public.list_inventory_adjustment_history('7b300000-0000-4000-8000-000000000101',
    _created_from => '2026-01-02 12:00:00+00', _created_before => '2026-01-03 12:00:00+00') row)
  = ARRAY['7b300000-0000-4000-8000-0000000b0001', '7b300000-0000-4000-8000-0000000b0002']::uuid[],
  'adjustment date boundaries are [from, before)');
-- A page holds exactly the requested number of rows, for each filter path.
SELECT pg_temp.assert((SELECT count(*) FROM public.list_inventory_transfer_history('7b300000-0000-4000-8000-000000000101', _limit => 5)) = 5
  AND (SELECT count(*) FROM public.list_inventory_transfer_history('7b300000-0000-4000-8000-000000000101', pg_temp.loc('training'), _limit => 5)) = 5
  AND (SELECT count(*) FROM public.list_inventory_adjustment_history('7b300000-0000-4000-8000-000000000101', _limit => 5)) = 5,
  'page size is exact');
-- Fractional quantities are exact.
SELECT pg_temp.assert((SELECT row.quantity::text FROM public.list_inventory_transfer_history('7b300000-0000-4000-8000-000000000101',
    _created_from => '2026-01-05 12:00:00+00', _created_before => '2026-01-05 12:00:01+00') row
  WHERE row.transfer_id = '7b300000-0000-4000-8000-0000000a0007') = '4.25', 'fractional transfer quantity');
-- Paging is stable at every page size, including 1 and a shared timestamp.
SELECT pg_temp.assert(bool_and(pg_temp.transfer_pages('7b300000-0000-4000-8000-000000000101', size)
  = pg_temp.expected_transfers('7b300000-0000-4000-8000-000000000101')), 'paging stable for every page size')
FROM unnest(ARRAY[1, 2, 7, 49, 50, 200]) size;
SELECT pg_temp.assert(cardinality(pg_temp.expected_transfers('7b300000-0000-4000-8000-000000000101',
  $$t.created_at = '2026-01-02 12:00:00+00'$$)) = 2, 'fixture has a shared timestamp');
-- Validation.
SELECT pg_temp.expect_error($$SELECT * FROM public.list_inventory_transfer_history('7b300000-0000-4000-8000-000000000101', _limit => 0)$$, 'Page size');
SELECT pg_temp.expect_error($$SELECT * FROM public.list_inventory_transfer_history('7b300000-0000-4000-8000-000000000101', _limit => 201)$$, 'Page size');
SELECT pg_temp.expect_error($$SELECT * FROM public.list_inventory_transfer_history('7b300000-0000-4000-8000-000000000101', _after_created_at => now())$$, 'incomplete page cursor');
SELECT pg_temp.expect_error($$SELECT * FROM public.list_inventory_transfer_history('7b300000-0000-4000-8000-000000000101',
  _created_from => '2026-02-01', _created_before => '2026-02-01')$$, 'start of the date range');
RESET ROLE;

-- ---------------------------------------------------------------------------------------
-- 4. Adjustments: manual only, field by field; exclusions; filters; paging.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b300000-0000-4000-8000-000000000001');
-- Wrap: org total 30 -> 27 at Training (stored before/after are organization totals).
SELECT pg_temp.assert((
  SELECT row.item_name = 'Elastic Wrap 4"' AND row.item_sku = 'WRAP-4' AND row.item_unit = 'each'
     AND row.inventory_location_id = pg_temp.loc('training') AND row.location_name = 'Training Room'
     AND row.previous_quantity = 30 AND row.adjustment_amount = -3 AND row.new_quantity = 27
     AND row.reason = 'Damaged' AND row.source_type = 'manual'
     AND row.created_by = '7b300000-0000-4000-8000-000000000001' AND row.created_by_name = 'Olivia Owner'
  FROM public.list_inventory_adjustment_history('7b300000-0000-4000-8000-000000000101', _reason => 'Damaged',
    _created_from => now()) row), 'negative manual adjustment fields');
SELECT pg_temp.assert((
  SELECT row.previous_quantity = 12 AND row.adjustment_amount = 2 AND row.new_quantity = 14 AND row.reason = 'Correction'
  FROM public.list_inventory_adjustment_history('7b300000-0000-4000-8000-000000000101', pg_temp.loc('stadium'),
    _created_from => now()) row), 'positive manual adjustment fields');
SELECT pg_temp.assert((
  SELECT row.adjustment_amount::text = '0.25' AND row.previous_quantity::text = '8.5' AND row.new_quantity::text = '8.75'
     AND row.location_name = 'Unassigned'
  FROM public.list_inventory_adjustment_history('7b300000-0000-4000-8000-000000000101',
    pg_temp.unassigned('7b300000-0000-4000-8000-000000000101'), _created_from => now()) row), 'fractional adjustment at Unassigned, trimmed scale');
SELECT pg_temp.assert((
  SELECT row.adjustment_amount::text = '0' AND row.inventory_location_id IS NULL AND row.location_name IS NULL
     AND row.source_type IS NULL AND row.reason = 'Correction'
  FROM public.list_inventory_adjustment_history('7b300000-0000-4000-8000-000000000101',
    _created_before => '2025-05-01 00:00:00+00') row
  WHERE row.adjustment_id = '7b300000-0000-4000-8000-0000000c0005'), 'zero, location-less pre-provenance adjustment as stored');
SELECT pg_temp.assert((
  SELECT row.created_by_name = 'Former member' AND row.reason = 'Expired' AND row.location_name = 'Training Room'
  FROM public.list_inventory_adjustment_history('7b300000-0000-4000-8000-000000000101', _created_by => '7b300000-0000-4000-8000-000000000006',
    _created_from => now()) row), 'former member adjustment');
-- Exclusions: physical counts and invoice receipts never appear; manual 'Invoice received'
-- and pre-provenance manual rows do.
-- (Section 4 runs as the owner, whose raw ledger read RLS allows.)
SELECT pg_temp.assert((SELECT count(*) FROM public.inventory_adjustments WHERE organization_id = '7b300000-0000-4000-8000-000000000101'
  AND source_type = 'physical_count') = 2, 'the count wrote two physical_count adjustments (one zero)');
SELECT pg_temp.assert(NOT EXISTS (
  SELECT 1 FROM unnest(pg_temp.adjustment_pages('7b300000-0000-4000-8000-000000000101', 50)) returned(adjustment_id)
  JOIN public.inventory_adjustments a ON a.id = returned.adjustment_id
  WHERE a.source_type = 'physical_count' OR a.reason = 'Physical count'), 'no physical_count adjustment in generic history');
SELECT pg_temp.assert(NOT EXISTS (
  SELECT 1 FROM public.list_inventory_adjustment_history('7b300000-0000-4000-8000-000000000101', pg_temp.loc('training'),
    '7b300000-0000-4000-8000-000000000501', _created_from => now()) row WHERE row.reason <> 'Damaged'),
  'Training Wrap shows only the manual Damaged row, not the count correction');
SELECT pg_temp.assert(NOT ('7b300000-0000-4000-8000-0000000c0001'::uuid = ANY (pg_temp.adjustment_pages('7b300000-0000-4000-8000-000000000101', 50)))
  AND NOT ('7b300000-0000-4000-8000-0000000c0002'::uuid = ANY (pg_temp.adjustment_pages('7b300000-0000-4000-8000-000000000101', 50)))
  AND '7b300000-0000-4000-8000-0000000c0003'::uuid = ANY (pg_temp.adjustment_pages('7b300000-0000-4000-8000-000000000101', 50))
  AND '7b300000-0000-4000-8000-0000000c0004'::uuid = ANY (pg_temp.adjustment_pages('7b300000-0000-4000-8000-000000000101', 50)),
  'invoice receipts excluded; manual and pre-provenance rows included');
SELECT pg_temp.assert(pg_temp.adjustment_pages('7b300000-0000-4000-8000-000000000101', 50)
  = pg_temp.expected_adjustments('7b300000-0000-4000-8000-000000000101')
  AND cardinality(pg_temp.expected_adjustments('7b300000-0000-4000-8000-000000000101')) = 237, 'all manual adjustments, newest first');
SELECT pg_temp.assert((SELECT count(*) FROM public.inventory_adjustments WHERE organization_id = '7b300000-0000-4000-8000-000000000101') = 356,
  'the ledger also holds 119 rows the history excludes (2 count, 117 receipts)');
-- Physical counts stay in Counts.
SELECT pg_temp.assert((
  SELECT row.changed_count = 1 AND row.correction_summary = '[{"unit": "each", "netDelta": -2, "decrease": -2, "increase": 0, "changedLines": 1}]'::jsonb
  FROM public.list_inventory_count_history('7b300000-0000-4000-8000-000000000101') row
  WHERE row.count_session_id = (pg_temp.val('count:training')->>'sessionId')::uuid),
  'the count correction is still in count history');
SELECT pg_temp.expect_error($$SELECT * FROM public.list_inventory_adjustment_history('7b300000-0000-4000-8000-000000000101', _reason => 'Physical count')$$,
  'Physical count corrections are shown in Counts');
SELECT pg_temp.expect_error($$SELECT * FROM public.list_inventory_adjustment_history('7b300000-0000-4000-8000-000000000101', _reason => 'Shrink')$$,
  'Unknown adjustment reason');
-- Filters.
SELECT pg_temp.assert(pg_temp.adjustment_pages('7b300000-0000-4000-8000-000000000101', 9, pg_temp.loc('training'))
  = pg_temp.expected_adjustments('7b300000-0000-4000-8000-000000000101', format('a.inventory_location_id = %L', pg_temp.loc('training'))),
  'location filter');
SELECT pg_temp.assert(pg_temp.adjustment_pages('7b300000-0000-4000-8000-000000000101', 9, NULL, '7b300000-0000-4000-8000-000000000503')
  = pg_temp.expected_adjustments('7b300000-0000-4000-8000-000000000101', $$a.inventory_item_id = '7b300000-0000-4000-8000-000000000503'$$)
  AND cardinality(pg_temp.adjustment_pages('7b300000-0000-4000-8000-000000000101', 9, NULL, '7b300000-0000-4000-8000-000000000503')) = 4,
  'item filter');
SELECT pg_temp.assert(pg_temp.adjustment_pages('7b300000-0000-4000-8000-000000000101', 9, NULL, NULL, '7b300000-0000-4000-8000-000000000006')
  = pg_temp.expected_adjustments('7b300000-0000-4000-8000-000000000101', $$a.created_by = '7b300000-0000-4000-8000-000000000006'$$),
  'person filter');
SELECT pg_temp.assert(bool_and(pg_temp.adjustment_pages('7b300000-0000-4000-8000-000000000101', 17, NULL, NULL, NULL, reason)
  = pg_temp.expected_adjustments('7b300000-0000-4000-8000-000000000101', format('a.reason = %L', reason))), 'reason filter')
FROM unnest(ARRAY['Manual adjustment', 'Damaged', 'Expired', 'Correction', 'Invoice received']) reason;
SELECT pg_temp.assert(cardinality(pg_temp.adjustment_pages('7b300000-0000-4000-8000-000000000101', 17, NULL, NULL, NULL, 'Invoice received')) = 1,
  'only the manual row with a stored Invoice received reason');
SELECT pg_temp.assert(pg_temp.adjustment_pages('7b300000-0000-4000-8000-000000000101', 6, NULL, NULL, NULL, NULL,
    timestamptz '2026-02-01 00:00:00+00', timestamptz '2026-03-01 00:00:00+00')
  = pg_temp.expected_adjustments('7b300000-0000-4000-8000-000000000101',
      $$a.created_at >= '2026-02-01 00:00:00+00' AND a.created_at < '2026-03-01 00:00:00+00'$$), 'date range');
SELECT pg_temp.assert(bool_and(pg_temp.adjustment_pages('7b300000-0000-4000-8000-000000000101', size)
  = pg_temp.expected_adjustments('7b300000-0000-4000-8000-000000000101')), 'paging stable for every page size')
FROM unnest(ARRAY[1, 2, 7, 49, 50, 200]) size;
SELECT pg_temp.expect_error($$SELECT * FROM public.list_inventory_adjustment_history('7b300000-0000-4000-8000-000000000101', _limit => 0)$$, 'Page size');
SELECT pg_temp.expect_error($$SELECT * FROM public.list_inventory_adjustment_history('7b300000-0000-4000-8000-000000000101', _after_id => gen_random_uuid())$$, 'incomplete page cursor');
SELECT pg_temp.expect_error($$SELECT * FROM public.list_inventory_adjustment_history('7b300000-0000-4000-8000-000000000101',
  _created_from => '2026-03-01', _created_before => '2026-02-01')$$, 'start of the date range');
RESET ROLE;

-- ---------------------------------------------------------------------------------------
-- 5. Reads change nothing.
-- ---------------------------------------------------------------------------------------
INSERT INTO phase7b3_values VALUES ('state_before_reads', pg_temp.state('7b300000-0000-4000-8000-000000000101'));
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7b300000-0000-4000-8000-000000000001');
SELECT count(*) FROM public.list_inventory_transfer_history('7b300000-0000-4000-8000-000000000101', _limit => 200);
SELECT count(*) FROM public.list_inventory_adjustment_history('7b300000-0000-4000-8000-000000000101', _limit => 200);
SELECT pg_temp.as_user('7b300000-0000-4000-8000-000000000002');
SELECT count(*) FROM public.list_inventory_transfer_history('7b300000-0000-4000-8000-000000000101', pg_temp.loc('training'));
SELECT count(*) FROM public.list_inventory_adjustment_history('7b300000-0000-4000-8000-000000000101', _reason => 'Damaged');
RESET ROLE;
SELECT pg_temp.assert(pg_temp.state('7b300000-0000-4000-8000-000000000101') = pg_temp.val('state_before_reads'),
  'reads left inventory, transfers, adjustments and counts unchanged');

SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
