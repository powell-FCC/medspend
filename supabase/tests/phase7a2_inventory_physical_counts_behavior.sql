-- Phase 7A.2 rollback-only behavioral verification: QR labels and physical counts.
-- Run against a disposable database after every migration through
-- 20261027120100_phase7a2_staff_inventory_read_hardening.sql. Every fixture and mutation is
-- rolled back; SET CONSTRAINTS ALL IMMEDIATE before the rollback evaluates the deferred
-- quantity invariant for every row this suite touched.

BEGIN;

DO $phase7a2_fixture_guard$
BEGIN
  IF EXISTS (SELECT 1 FROM auth.users
             WHERE id BETWEEN '7a200000-0000-4000-8000-000000000001'::uuid AND '7a200000-0000-4000-8000-000000000099'::uuid)
     OR EXISTS (SELECT 1 FROM public.organizations
             WHERE id BETWEEN '7a200000-0000-4000-8000-000000000101'::uuid AND '7a200000-0000-4000-8000-000000000199'::uuid) THEN
    RAISE EXCEPTION 'Phase 7A.2 rollback-test fixture IDs already exist';
  END IF;
END
$phase7a2_fixture_guard$;

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
RETURNS void LANGUAGE sql AS $$ SELECT pg_catalog.set_config('request.jwt.claim.sub', _user_id::text, true) $$;

CREATE FUNCTION pg_temp.assert(_condition boolean, _message text)
RETURNS void LANGUAGE plpgsql AS $$ BEGIN IF _condition IS NOT TRUE THEN RAISE EXCEPTION 'Check failed: %', _message; END IF; END; $$;

CREATE TEMP TABLE phase7a2_values (name text PRIMARY KEY, value jsonb) ON COMMIT DROP;
GRANT ALL ON phase7a2_values TO authenticated, anon;

CREATE FUNCTION pg_temp.val(_name text)
RETURNS jsonb LANGUAGE sql AS $$ SELECT value FROM phase7a2_values WHERE name = _name $$;
CREATE FUNCTION pg_temp.loc(_name text)
RETURNS uuid LANGUAGE sql AS $$ SELECT (value #>> '{}')::uuid FROM phase7a2_values WHERE name = 'loc:' || _name $$;

CREATE FUNCTION pg_temp.qty(_item uuid, _location uuid)
RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$
  SELECT quantity FROM public.inventory_location_balances WHERE inventory_item_id = _item AND inventory_location_id = _location $$;
CREATE FUNCTION pg_temp.ver(_item uuid, _location uuid)
RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$
  SELECT version FROM public.inventory_location_balances WHERE inventory_item_id = _item AND inventory_location_id = _location $$;
CREATE FUNCTION pg_temp.total(_item uuid)
RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$ SELECT quantity FROM public.inventory_items WHERE id = _item $$;
CREATE FUNCTION pg_temp.unassigned(_organization uuid)
RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM public.inventory_locations WHERE organization_id = _organization AND kind = 'unassigned' $$;

-- Everything a refused count must leave alone.
CREATE FUNCTION pg_temp.state(_organization uuid)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT jsonb_build_object(
    'items', (SELECT coalesce(jsonb_agg(jsonb_build_array(id, quantity, active) ORDER BY id), '[]')
              FROM public.inventory_items WHERE organization_id = _organization),
    'balances', (SELECT coalesce(jsonb_agg(jsonb_build_array(inventory_item_id, inventory_location_id, quantity, version)
                 ORDER BY inventory_item_id, inventory_location_id), '[]')
                 FROM public.inventory_location_balances WHERE organization_id = _organization),
    'adjustments', (SELECT count(*) FROM public.inventory_adjustments WHERE organization_id = _organization),
    'sessions', (SELECT count(*) FROM public.inventory_count_sessions WHERE organization_id = _organization),
    'lines', (SELECT count(*) FROM public.inventory_count_lines WHERE organization_id = _organization),
    'labels', (SELECT coalesce(jsonb_agg(jsonb_build_array(id, revoked_at IS NULL) ORDER BY id), '[]')
               FROM public.inventory_location_labels WHERE organization_id = _organization))
$$;

-- The count page for a location, as the current user sees it.
CREATE FUNCTION pg_temp.page(_organization uuid, _location uuid)
RETURNS jsonb LANGUAGE sql AS $$ SELECT public.get_inventory_count_location(_organization, _location) $$;

-- A submission payload that confirms the page exactly, with optional overrides by item id.
CREATE FUNCTION pg_temp.lines(_page jsonb, _overrides jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE sql AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'inventoryItemId', item->>'inventoryItemId',
      'observedVersion', (item->>'version')::bigint,
      'countedQuantity', coalesce(_overrides->(item->>'inventoryItemId'), to_jsonb((item->>'quantity')::text)))), '[]')
  FROM jsonb_array_elements(_page->'items') item
$$;

CREATE FUNCTION pg_temp.page_ids(_page jsonb)
RETURNS text[] LANGUAGE sql AS $$
  SELECT coalesce(array_agg(item->>'inventoryItemId' ORDER BY item->>'inventoryItemId'), '{}')
  FROM jsonb_array_elements(_page->'items') item $$;

-- ---------------------------------------------------------------------------------------
-- Fixtures. A: owner 001, admin 002, staff 003, multi-org staff 006. B: owner 004,
-- staff 005, multi-org staff 006. 007 belongs to nothing.
-- ---------------------------------------------------------------------------------------
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('7a200000-0000-4000-8000-00000000000' || n)::uuid, 'authenticated', 'authenticated',
  'phase7a2-' || n || '@example.invalid', '', now(), '{}', '{}', now(), now()
FROM generate_series(1, 7) n;

INSERT INTO public.organizations (id, name, created_by) VALUES
  ('7a200000-0000-4000-8000-000000000101', 'Phase 7A.2 Organization', '7a200000-0000-4000-8000-000000000001'),
  ('7a200000-0000-4000-8000-000000000102', 'Phase 7A.2 Other Organization', '7a200000-0000-4000-8000-000000000004');

INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES
  ('7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000001', 'owner', true),
  ('7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000002', 'admin', true),
  ('7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000003', 'staff', true),
  ('7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000006', 'staff', true),
  ('7a200000-0000-4000-8000-000000000102', '7a200000-0000-4000-8000-000000000004', 'owner', true),
  ('7a200000-0000-4000-8000-000000000102', '7a200000-0000-4000-8000-000000000005', 'staff', true),
  ('7a200000-0000-4000-8000-000000000102', '7a200000-0000-4000-8000-000000000006', 'staff', true);

INSERT INTO public.products (id, organization_id, name, normalized_name, unit_of_measure, approved, active, staff_requestable) VALUES
  ('7a200000-0000-4000-8000-000000000401', '7a200000-0000-4000-8000-000000000101', 'Phase 7A.2 Athletic Tape', 'x', 'roll', true, true, true);

-- Stock that predates the count, as production rows do. Inserted as postgres; every item
-- starts with its quantity in Unassigned.
INSERT INTO public.inventory_items (id, organization_id, product_id, sku, name, unit, quantity, vendor_name,
  manufacturer, last_purchase_price, last_purchase_date, par_level, active) VALUES
  ('7a200000-0000-4000-8000-000000000501', '7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000401',
   'TAPE-1', 'Phase 7A.2 Athletic Tape', 'roll', 20, 'Secret Vendor', 'Tape Co', 9.87, '2026-10-01', 4, true),
  ('7a200000-0000-4000-8000-000000000502', '7a200000-0000-4000-8000-000000000101', NULL,
   'GAUZE-1', 'Phase 7A.2 Gauze', 'box', 2.75, 'Secret Vendor', NULL, 3.21, '2026-10-01', NULL, true),
  ('7a200000-0000-4000-8000-000000000503', '7a200000-0000-4000-8000-000000000101', NULL,
   NULL, 'Phase 7A.2 Zero Item', 'each', 1, NULL, NULL, NULL, NULL, NULL, true),
  ('7a200000-0000-4000-8000-000000000504', '7a200000-0000-4000-8000-000000000101', NULL,
   'ARCH-POS', 'Phase 7A.2 Archived Stocked', 'each', 5, NULL, NULL, NULL, NULL, NULL, true),
  ('7a200000-0000-4000-8000-000000000505', '7a200000-0000-4000-8000-000000000101', NULL,
   'ARCH-ZERO', 'Phase 7A.2 Archived Empty', 'each', 1, NULL, NULL, NULL, NULL, NULL, true),
  ('7a200000-0000-4000-8000-000000000506', '7a200000-0000-4000-8000-000000000101', NULL,
   'NEW-1', 'Phase 7A.2 Late Arrival', 'each', 4, NULL, NULL, NULL, NULL, NULL, true),
  ('7a200000-0000-4000-8000-000000000507', '7a200000-0000-4000-8000-000000000101', NULL,
   'ELSEWHERE', 'Phase 7A.2 Elsewhere', 'each', 2, NULL, NULL, NULL, NULL, NULL, true),
  ('7a200000-0000-4000-8000-000000000511', '7a200000-0000-4000-8000-000000000102', NULL,
   'TAPE-1', 'Phase 7A.2 Other Tape', 'roll', 10, NULL, NULL, 1.11, NULL, NULL, true);

-- Locations and stock placement through the owner functions.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000001');
INSERT INTO phase7a2_values VALUES
  ('loc:cabinet', to_jsonb(public.create_inventory_location('7a200000-0000-4000-8000-000000000101', 'Cabinet A'))),
  ('loc:rehab', to_jsonb(public.create_inventory_location('7a200000-0000-4000-8000-000000000101', 'Rehab Closet'))),
  ('loc:cart', to_jsonb(public.create_inventory_location('7a200000-0000-4000-8000-000000000101', 'Away Cart')));
SELECT public.move_inventory_stock('7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000501',
  pg_temp.unassigned('7a200000-0000-4000-8000-000000000101'), pg_temp.loc('cabinet'), 12, 'fx-1');
SELECT public.move_inventory_stock('7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000502',
  pg_temp.unassigned('7a200000-0000-4000-8000-000000000101'), pg_temp.loc('cabinet'), 2.75, 'fx-2');
-- The zero item was stocked here once and ran out: its balance row stays at zero.
SELECT public.move_inventory_stock('7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000503',
  pg_temp.unassigned('7a200000-0000-4000-8000-000000000101'), pg_temp.loc('cabinet'), 1, 'fx-3');
SELECT public.move_inventory_stock('7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000503',
  pg_temp.loc('cabinet'), pg_temp.unassigned('7a200000-0000-4000-8000-000000000101'), 1, 'fx-4');
SELECT public.move_inventory_stock('7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000504',
  pg_temp.unassigned('7a200000-0000-4000-8000-000000000101'), pg_temp.loc('cabinet'), 5, 'fx-5');
SELECT public.move_inventory_stock('7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000505',
  pg_temp.unassigned('7a200000-0000-4000-8000-000000000101'), pg_temp.loc('cabinet'), 1, 'fx-6');
SELECT public.move_inventory_stock('7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000505',
  pg_temp.loc('cabinet'), pg_temp.unassigned('7a200000-0000-4000-8000-000000000101'), 1, 'fx-7');
SELECT public.move_inventory_stock('7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000507',
  pg_temp.unassigned('7a200000-0000-4000-8000-000000000101'), pg_temp.loc('rehab'), 2, 'fx-8');
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000004');
INSERT INTO phase7a2_values VALUES
  ('loc:other', to_jsonb(public.create_inventory_location('7a200000-0000-4000-8000-000000000102', 'Other Cabinet')));
SELECT public.move_inventory_stock('7a200000-0000-4000-8000-000000000102', '7a200000-0000-4000-8000-000000000511',
  pg_temp.unassigned('7a200000-0000-4000-8000-000000000102'), pg_temp.loc('other'), 10, 'fx-9');
RESET ROLE;
-- Archive two items after placing them (archiving never required zero stock).
UPDATE public.inventory_items SET active = false
WHERE id IN ('7a200000-0000-4000-8000-000000000504', '7a200000-0000-4000-8000-000000000505');

-- ---------------------------------------------------------------------------------------
-- 1. Labels: owners issue; tokens are opaque; only hashes are stored.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000001');
INSERT INTO phase7a2_values VALUES
  ('label1', public.issue_inventory_location_label('7a200000-0000-4000-8000-000000000101', pg_temp.loc('cabinet'))),
  ('label2', public.issue_inventory_location_label('7a200000-0000-4000-8000-000000000101', pg_temp.loc('cabinet'))),
  ('label_cart', public.issue_inventory_location_label('7a200000-0000-4000-8000-000000000101', pg_temp.loc('cart')));
SELECT pg_temp.expect_error(format($$SELECT public.issue_inventory_location_label('7a200000-0000-4000-8000-000000000101', %L)$$,
  pg_temp.unassigned('7a200000-0000-4000-8000-000000000101')), 'Unassigned is not a physical location');
SELECT pg_temp.expect_error(format($$SELECT public.issue_inventory_location_label('7a200000-0000-4000-8000-000000000102', %L)$$,
  pg_temp.loc('other')), 'Forbidden: owner access required');
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000002');
SELECT pg_temp.expect_error(format($$SELECT public.issue_inventory_location_label('7a200000-0000-4000-8000-000000000101', %L)$$,
  pg_temp.loc('cabinet')), 'Forbidden: owner access required');
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000003');
SELECT pg_temp.expect_error(format($$SELECT public.issue_inventory_location_label('7a200000-0000-4000-8000-000000000101', %L)$$,
  pg_temp.loc('cabinet')), 'Forbidden: owner access required');
SELECT pg_temp.expect_error(format($$SELECT public.revoke_inventory_location_labels('7a200000-0000-4000-8000-000000000101', %L)$$,
  pg_temp.loc('cabinet')), 'Forbidden: owner access required');
SELECT pg_temp.expect_error($$SELECT * FROM public.inventory_location_labels$$, 'permission denied');
SELECT pg_temp.expect_error($$SELECT * FROM public.list_inventory_location_count_status('7a200000-0000-4000-8000-000000000101')$$,
  'Forbidden: owner access required');
RESET ROLE;

DO $check_labels$
DECLARE
  _token text := pg_temp.val('label1')->>'token';
BEGIN
  PERFORM pg_temp.assert(_token ~ '^[A-Za-z0-9_-]{43}$', 'token is 43 base64url characters');
  PERFORM pg_temp.assert(_token <> pg_temp.val('label2')->>'token', 'every label has its own token');
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM public.inventory_location_labels
    WHERE id = (pg_temp.val('label1')->>'labelId')::uuid AND token_hash = encode(sha256(convert_to(_token, 'UTF8')), 'hex')),
    'only the SHA-256 hash of the token is stored');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.inventory_location_labels label
    WHERE to_jsonb(label)::text LIKE '%' || _token || '%'), 'the raw token is stored nowhere');
  PERFORM pg_temp.assert(position('7a200000' IN _token) = 0, 'token carries no identifiers');
  PERFORM pg_temp.assert((SELECT count(*) FROM public.inventory_location_labels
    WHERE inventory_location_id = pg_temp.loc('cabinet') AND revoked_at IS NULL) = 2, 'two active labels for one location');
END
$check_labels$;

-- ---------------------------------------------------------------------------------------
-- 2. Resolution: membership first; nothing leaks to outsiders.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000003');
SELECT pg_temp.assert(public.resolve_inventory_count_label(pg_temp.val('label1')->>'token')
  = jsonb_build_object('status', 'available', 'organizationId', '7a200000-0000-4000-8000-000000000101',
      'locationId', pg_temp.loc('cabinet'), 'locationName', 'Cabinet A'), 'staff member resolves own label');
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000006');
SELECT pg_temp.assert(public.resolve_inventory_count_label(pg_temp.val('label1')->>'token')->>'organizationId'
  = '7a200000-0000-4000-8000-000000000101', 'multi-organization member resolves to the label''s organization');
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000004');
SELECT pg_temp.assert(public.resolve_inventory_count_label(pg_temp.val('label1')->>'token') = '{"status": "unavailable"}',
  'another organization''s owner learns nothing');
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000007');
SELECT pg_temp.assert(public.resolve_inventory_count_label(pg_temp.val('label1')->>'token') = '{"status": "unavailable"}',
  'a non-member learns nothing');
SELECT pg_temp.assert(public.resolve_inventory_count_label('not-a-token') = '{"status": "unavailable"}', 'malformed token');
SELECT pg_temp.assert(public.resolve_inventory_count_label(repeat('A', 43)) = '{"status": "unavailable"}', 'unknown token');
SELECT pg_temp.assert(public.resolve_inventory_count_label(NULL) = '{"status": "unavailable"}', 'missing token');
SELECT pg_temp.as_user(NULL);
SELECT pg_temp.expect_error(format($$SELECT public.resolve_inventory_count_label(%L)$$, pg_temp.val('label1')->>'token'),
  'Sign in to open this inventory location');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.expect_error(format($$SELECT public.resolve_inventory_count_label(%L)$$, pg_temp.val('label1')->>'token'),
  'permission denied');
SELECT pg_temp.expect_error($$SELECT public.get_inventory_count_location('7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000101')$$,
  'permission denied');
SELECT pg_temp.expect_error($$SELECT public.submit_inventory_count('7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000101', '[]', 'k')$$,
  'permission denied');
RESET ROLE;

-- Archiving suspends labels; restoring brings them back; revoking is permanent.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000001');
SELECT public.set_inventory_location_active('7a200000-0000-4000-8000-000000000101', pg_temp.loc('cart'), false);
SELECT pg_temp.expect_error(format($$SELECT public.issue_inventory_location_label('7a200000-0000-4000-8000-000000000101', %L)$$,
  pg_temp.loc('cart')), 'Restore Away Cart before issuing a QR label');
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000003');
SELECT pg_temp.assert(public.resolve_inventory_count_label(pg_temp.val('label_cart')->>'token') = '{"status": "location_unavailable"}',
  'archived location''s label is unavailable to members');
SELECT pg_temp.expect_error(format($$SELECT public.get_inventory_count_location('7a200000-0000-4000-8000-000000000101', %L)$$,
  pg_temp.loc('cart')), 'not available for counting');
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000004');
SELECT pg_temp.assert(public.resolve_inventory_count_label(pg_temp.val('label_cart')->>'token') = '{"status": "unavailable"}',
  'archived location stays opaque to outsiders');
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000001');
SELECT public.set_inventory_location_active('7a200000-0000-4000-8000-000000000101', pg_temp.loc('cart'), true);
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000003');
SELECT pg_temp.assert(public.resolve_inventory_count_label(pg_temp.val('label_cart')->>'token')->>'status' = 'available',
  'restored location''s label works again');
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000001');
SELECT pg_temp.assert(public.revoke_inventory_location_labels('7a200000-0000-4000-8000-000000000101', pg_temp.loc('cart')) = 1,
  'revoke all for one location');
SELECT pg_temp.assert(public.revoke_inventory_location_labels('7a200000-0000-4000-8000-000000000101', pg_temp.loc('cart')) = 0,
  'revoking again revokes nothing');
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000003');
SELECT pg_temp.assert(public.resolve_inventory_count_label(pg_temp.val('label_cart')->>'token') = '{"status": "replaced"}',
  'revoked label tells members it was replaced');
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000004');
SELECT pg_temp.assert(public.resolve_inventory_count_label(pg_temp.val('label_cart')->>'token') = '{"status": "unavailable"}',
  'revoked label stays opaque to outsiders');
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000001');
SELECT pg_temp.assert((SELECT count(*) FROM public.list_inventory_location_count_status('7a200000-0000-4000-8000-000000000101')
  WHERE inventory_location_id = pg_temp.loc('cabinet') AND active_label_count = 2) = 1, 'owner status lists active labels');
RESET ROLE;

-- Labels and history cannot be edited directly, even by the table owner.
SELECT pg_temp.expect_error(format($$UPDATE public.inventory_location_labels SET inventory_location_id = %L WHERE id = %L$$,
  pg_temp.loc('rehab'), pg_temp.val('label1')->>'labelId'), 'can only be revoked, once');
SELECT pg_temp.expect_error(format($$DELETE FROM public.inventory_location_labels WHERE id = %L$$,
  pg_temp.val('label1')->>'labelId'), 'revoked, not deleted');
SELECT pg_temp.expect_error(format($$UPDATE public.inventory_location_labels SET revoked_at = now() + interval '1 day' WHERE inventory_location_id = %L$$,
  pg_temp.loc('cart')), 'can only be revoked, once');

-- ---------------------------------------------------------------------------------------
-- 3. The count page: the countable rule and staff-safe fields only.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000003');
INSERT INTO phase7a2_values VALUES ('page1', pg_temp.page('7a200000-0000-4000-8000-000000000101', pg_temp.loc('cabinet')));
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000005');
SELECT pg_temp.expect_error(format($$SELECT public.get_inventory_count_location('7a200000-0000-4000-8000-000000000101', %L)$$,
  pg_temp.loc('cabinet')), 'Forbidden: organization membership required');
SELECT pg_temp.expect_error(format($$SELECT public.get_inventory_count_location('7a200000-0000-4000-8000-000000000102', %L)$$,
  pg_temp.loc('cabinet')), 'not available for counting');
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000003');
SELECT pg_temp.expect_error(format($$SELECT public.get_inventory_count_location('7a200000-0000-4000-8000-000000000101', %L)$$,
  pg_temp.unassigned('7a200000-0000-4000-8000-000000000101')), 'not available for counting');
SELECT pg_temp.assert((SELECT array_agg(name ORDER BY name) FROM public.list_countable_inventory_locations('7a200000-0000-4000-8000-000000000101'))
  = ARRAY['Away Cart', 'Cabinet A', 'Rehab Closet'], 'fallback list: active storage locations only, no Unassigned');
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000002');
SELECT pg_temp.assert(jsonb_array_length(pg_temp.page('7a200000-0000-4000-8000-000000000101', pg_temp.loc('cabinet'))->'items') = 4,
  'admins can open counts');
RESET ROLE;

DO $check_page$
DECLARE
  _page jsonb := pg_temp.val('page1');
  _item jsonb;
BEGIN
  PERFORM pg_temp.assert(pg_temp.page_ids(_page) = ARRAY[
      '7a200000-0000-4000-8000-000000000501', '7a200000-0000-4000-8000-000000000502',
      '7a200000-0000-4000-8000-000000000503', '7a200000-0000-4000-8000-000000000504'],
    'countable: active stocked, active zero, archived stocked; not archived zero or other locations');
  PERFORM pg_temp.assert((SELECT array_agg(key ORDER BY key) FROM jsonb_object_keys(_page) key) = ARRAY['items', 'location'],
    'page has only location and items');
  PERFORM pg_temp.assert((SELECT array_agg(key ORDER BY key) FROM jsonb_object_keys(_page->'location') key)
    = ARRAY['id', 'lastCountedAt', 'name'], 'location fields');
  FOR _item IN SELECT value FROM jsonb_array_elements(_page->'items') LOOP
    PERFORM pg_temp.assert((SELECT array_agg(key ORDER BY key) FROM jsonb_object_keys(_item) key)
      = ARRAY['archived', 'inventoryItemId', 'manufacturer', 'name', 'quantity', 'sku', 'unit', 'version'],
      'item fields are exactly the staff-safe set');
  END LOOP;
  PERFORM pg_temp.assert(position('Secret Vendor' IN _page::text) = 0 AND position('9.87' IN _page::text) = 0
    AND position('3.21' IN _page::text) = 0, 'no vendor or price leaks into the page');
  PERFORM pg_temp.assert((SELECT (item->>'quantity')::numeric FROM jsonb_array_elements(_page->'items') item
    WHERE item->>'inventoryItemId' = '7a200000-0000-4000-8000-000000000502') = 2.75, 'fractional quantity preserved');
  PERFORM pg_temp.assert((SELECT (item->>'quantity')::numeric = 0 AND NOT (item->>'archived')::boolean
    FROM jsonb_array_elements(_page->'items') item WHERE item->>'inventoryItemId' = '7a200000-0000-4000-8000-000000000503'),
    'active zero-balance item is countable');
  PERFORM pg_temp.assert((SELECT (item->>'quantity')::numeric = 5 AND (item->>'archived')::boolean
    FROM jsonb_array_elements(_page->'items') item WHERE item->>'inventoryItemId' = '7a200000-0000-4000-8000-000000000504'),
    'archived item with stock is countable and flagged');
  PERFORM pg_temp.assert(_page->'location'->>'lastCountedAt' IS NULL, 'never counted');
END
$check_page$;

-- ---------------------------------------------------------------------------------------
-- 4. Invalid submissions are refused and change nothing.
-- ---------------------------------------------------------------------------------------
INSERT INTO phase7a2_values VALUES ('before_invalid', pg_temp.state('7a200000-0000-4000-8000-000000000101'));
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000003');
CREATE FUNCTION pg_temp.submit(_lines jsonb, _key text, _location uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.submit_inventory_count('7a200000-0000-4000-8000-000000000101', coalesce(_location, pg_temp.loc('cabinet')), _lines, _key) $$;
SELECT pg_temp.expect_error($$SELECT pg_temp.submit('[]', 'bad-1')$$, 'A count must include every item at the location');
SELECT pg_temp.expect_error($$SELECT pg_temp.submit(NULL, 'bad-2')$$, 'A count must include every item at the location');
SELECT pg_temp.expect_error($$SELECT pg_temp.submit(pg_temp.lines(pg_temp.val('page1')), '  ')$$, 'A count request key is required');
-- Incomplete: one item left off.
SELECT pg_temp.expect_error($$SELECT pg_temp.submit((SELECT jsonb_agg(line) FROM jsonb_array_elements(pg_temp.lines(pg_temp.val('page1'))) line
  WHERE line->>'inventoryItemId' <> '7a200000-0000-4000-8000-000000000503'), 'bad-3')$$, 'Inventory changed while you were counting');
-- Extra: an item from another location of the same organization.
SELECT pg_temp.expect_error($$SELECT pg_temp.submit(pg_temp.lines(pg_temp.val('page1')) || jsonb_build_array(jsonb_build_object(
  'inventoryItemId', '7a200000-0000-4000-8000-000000000507', 'observedVersion', 2, 'countedQuantity', '2')), 'bad-4')$$,
  'Inventory changed while you were counting');
-- Extra: another organization's item.
SELECT pg_temp.expect_error($$SELECT pg_temp.submit(pg_temp.lines(pg_temp.val('page1')) || jsonb_build_array(jsonb_build_object(
  'inventoryItemId', '7a200000-0000-4000-8000-000000000511', 'observedVersion', 2, 'countedQuantity', '10')), 'bad-5')$$,
  'Inventory changed while you were counting');
-- The archived empty item is not countable here.
SELECT pg_temp.expect_error($$SELECT pg_temp.submit(pg_temp.lines(pg_temp.val('page1')) || jsonb_build_array(jsonb_build_object(
  'inventoryItemId', '7a200000-0000-4000-8000-000000000505', 'observedVersion', 3, 'countedQuantity', '0')), 'bad-6')$$,
  'Inventory changed while you were counting');
SELECT pg_temp.expect_error($$SELECT pg_temp.submit(pg_temp.lines(pg_temp.val('page1')) || (pg_temp.lines(pg_temp.val('page1'))->0), 'bad-7')$$,
  'Each item can be counted only once');
SELECT pg_temp.expect_error($$SELECT pg_temp.submit(pg_temp.lines(pg_temp.val('page1'), '{"7a200000-0000-4000-8000-000000000501": "-1"}'), 'bad-8')$$,
  'Quantities must be zero or more');
SELECT pg_temp.expect_error($$SELECT pg_temp.submit(pg_temp.lines(pg_temp.val('page1'), '{"7a200000-0000-4000-8000-000000000501": -1}'), 'bad-9')$$,
  'Quantities must be zero or more');
SELECT pg_temp.expect_error($$SELECT pg_temp.submit(pg_temp.lines(pg_temp.val('page1'), '{"7a200000-0000-4000-8000-000000000501": "abc"}'), 'bad-10')$$,
  'Quantities must be zero or more');
SELECT pg_temp.expect_error($$SELECT pg_temp.submit(pg_temp.lines(pg_temp.val('page1'), '{"7a200000-0000-4000-8000-000000000501": ""}'), 'bad-11')$$,
  'Enter a quantity for every item');
SELECT pg_temp.expect_error($$SELECT pg_temp.submit(pg_temp.lines(pg_temp.val('page1'), '{"7a200000-0000-4000-8000-000000000501": null}'), 'bad-12')$$,
  'Enter a quantity for every item');
SELECT pg_temp.expect_error($$SELECT pg_temp.submit(pg_temp.lines(pg_temp.val('page1'), '{"7a200000-0000-4000-8000-000000000501": "NaN"}'), 'bad-13')$$,
  'Quantities must be zero or more');
SELECT pg_temp.expect_error($$SELECT pg_temp.submit(pg_temp.lines(pg_temp.val('page1'), '{"7a200000-0000-4000-8000-000000000501": "1e3"}'), 'bad-14')$$,
  'Quantities must be zero or more');
SELECT pg_temp.expect_error($$SELECT pg_temp.submit(pg_temp.lines(pg_temp.val('page1'), '{"7a200000-0000-4000-8000-000000000501": "1.1234567"}'), 'bad-15')$$,
  'up to six decimal places');
SELECT pg_temp.expect_error($$SELECT pg_temp.submit(pg_temp.lines(pg_temp.val('page1'), '{"7a200000-0000-4000-8000-000000000501": "1000000001"}'), 'bad-16')$$,
  'at most 1,000,000,000');
SELECT pg_temp.expect_error($$SELECT pg_temp.submit('[{"inventoryItemId": "nope", "observedVersion": 1, "countedQuantity": "1"}]', 'bad-17')$$,
  'Invalid count line');
SELECT pg_temp.expect_error($$SELECT pg_temp.submit('[{"inventoryItemId": "7a200000-0000-4000-8000-000000000501", "observedVersion": 0, "countedQuantity": "1"}]', 'bad-18')$$,
  'Invalid count line');
SELECT pg_temp.expect_error($$SELECT pg_temp.submit('["x"]', 'bad-19')$$, 'Invalid count line');
SELECT pg_temp.expect_error(format($$SELECT pg_temp.submit(pg_temp.lines(pg_temp.val('page1')), 'bad-20', %L)$$,
  pg_temp.unassigned('7a200000-0000-4000-8000-000000000101')), 'not available for counting');
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000005');
SELECT pg_temp.expect_error($$SELECT pg_temp.submit(pg_temp.lines(pg_temp.val('page1')), 'bad-21')$$,
  'Forbidden: organization membership required');
SELECT pg_temp.expect_error(format($$SELECT public.submit_inventory_count('7a200000-0000-4000-8000-000000000102', %L, pg_temp.lines(pg_temp.val('page1')), 'bad-22')$$,
  pg_temp.loc('cabinet')), 'not available for counting');
RESET ROLE;
SELECT pg_temp.assert(pg_temp.state('7a200000-0000-4000-8000-000000000101') = pg_temp.val('before_invalid'),
  'refused counts changed nothing');

-- ---------------------------------------------------------------------------------------
-- 5. A complete count: negative, zero, positive-from-zero and fractional lines.
-- ---------------------------------------------------------------------------------------
INSERT INTO phase7a2_values VALUES ('totals_before', jsonb_build_object(
  'tape', pg_temp.total('7a200000-0000-4000-8000-000000000501'), 'gauze', pg_temp.total('7a200000-0000-4000-8000-000000000502'),
  'zero', pg_temp.total('7a200000-0000-4000-8000-000000000503'), 'arch', pg_temp.total('7a200000-0000-4000-8000-000000000504')));
INSERT INTO phase7a2_values VALUES ('versions_before', (SELECT jsonb_object_agg(item->>'inventoryItemId', (item->>'version')::bigint)
  FROM jsonb_array_elements(pg_temp.val('page1')->'items') item));
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000003');
INSERT INTO phase7a2_values VALUES ('count1', pg_temp.submit(pg_temp.lines(pg_temp.val('page1'), jsonb_build_object(
  '7a200000-0000-4000-8000-000000000501', '9',
  '7a200000-0000-4000-8000-000000000502', 2.75,
  '7a200000-0000-4000-8000-000000000503', '3.000',
  '7a200000-0000-4000-8000-000000000504', '5.5')), 'count-1'));
-- Staff see none of the history tables directly.
SELECT pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.inventory_count_sessions), 'staff cannot read count sessions');
SELECT pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.inventory_count_lines), 'staff cannot read count lines');
SELECT pg_temp.expect_error($$INSERT INTO public.inventory_count_sessions (organization_id, inventory_location_id, counted_by, submitted_at,
  line_count, changed_count, idempotency_key, request_hash) VALUES ('7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000101',
  '7a200000-0000-4000-8000-000000000003', now(), 1, 0, 'x', repeat('a', 64))$$, 'permission denied');
SELECT pg_temp.expect_error($$INSERT INTO public.inventory_adjustments (organization_id, inventory_item_id, adjustment_amount, previous_quantity,
  new_quantity, reason, created_by, source_type) VALUES ('7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000501', 0, 9, 9,
  'Physical count', '7a200000-0000-4000-8000-000000000003', 'physical_count')$$, 'permission denied');
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000001');
SELECT pg_temp.assert((SELECT count(*) FROM public.inventory_count_sessions WHERE organization_id = '7a200000-0000-4000-8000-000000000101') = 1,
  'owners read count history');
RESET ROLE;

DO $check_count1$
DECLARE
  _summary jsonb := pg_temp.val('count1');
  _before jsonb := pg_temp.val('totals_before');
  _versions jsonb := pg_temp.val('versions_before');
  _session public.inventory_count_sessions%ROWTYPE;
  _cab uuid := pg_temp.loc('cabinet');
BEGIN
  SELECT * INTO _session FROM public.inventory_count_sessions WHERE id = (_summary->>'sessionId')::uuid;
  PERFORM pg_temp.assert(_summary->>'locationName' = 'Cabinet A' AND (_summary->>'lineCount')::int = 4
    AND (_summary->>'changedCount')::int = 3 AND NOT (_summary->>'replayed')::boolean, 'summary');
  PERFORM pg_temp.assert(_session.counted_by = '7a200000-0000-4000-8000-000000000003'
    AND _session.inventory_location_id = _cab AND _session.line_count = 4 AND _session.changed_count = 3
    AND _session.idempotency_key = 'count-1' AND _session.request_hash ~ '^[0-9a-f]{64}$', 'session actor, location, counts');

  -- Lines: previous, counted, delta, observed version and snapshots, for every item.
  PERFORM pg_temp.assert((SELECT jsonb_agg(jsonb_build_array(inventory_item_id, previous_quantity, counted_quantity, delta, item_name, item_sku, item_unit)
      ORDER BY inventory_item_id) FROM public.inventory_count_lines WHERE count_session_id = _session.id)
    = jsonb_build_array(
        jsonb_build_array('7a200000-0000-4000-8000-000000000501', 12, 9, -3, 'Phase 7A.2 Athletic Tape', 'TAPE-1', 'roll'),
        jsonb_build_array('7a200000-0000-4000-8000-000000000502', 2.75, 2.75, 0.00, 'Phase 7A.2 Gauze', 'GAUZE-1', 'box'),
        jsonb_build_array('7a200000-0000-4000-8000-000000000503', 0, 3, 3, 'Phase 7A.2 Zero Item', NULL, 'each'),
        jsonb_build_array('7a200000-0000-4000-8000-000000000504', 5, 5.5, 0.5, 'Phase 7A.2 Archived Stocked', 'ARCH-POS', 'each')),
    'lines record previous, counted and delta for every item, unchanged included');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.inventory_count_lines line
    WHERE line.count_session_id = _session.id
      AND (line.observed_version <> (_versions->>line.inventory_item_id::text)::bigint
           OR line.created_at <> _session.submitted_at OR line.inventory_location_id <> _cab)), 'observed versions and timestamps');

  -- Balances: absolute at the counted values, versions moved for every line (zero included).
  PERFORM pg_temp.assert(pg_temp.qty('7a200000-0000-4000-8000-000000000501', _cab) = 9
    AND pg_temp.qty('7a200000-0000-4000-8000-000000000502', _cab) = 2.75
    AND pg_temp.qty('7a200000-0000-4000-8000-000000000503', _cab) = 3
    AND pg_temp.qty('7a200000-0000-4000-8000-000000000504', _cab) = 5.5, 'location balances are the counted values');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM jsonb_each_text(_versions) v
    WHERE pg_temp.ver(v.key::uuid, _cab) <> v.value::bigint + 1), 'every counted balance version moved by one, unchanged included');

  -- Organization totals move by the deltas only.
  PERFORM pg_temp.assert(pg_temp.total('7a200000-0000-4000-8000-000000000501') = (_before->>'tape')::numeric - 3
    AND pg_temp.total('7a200000-0000-4000-8000-000000000502') = (_before->>'gauze')::numeric
    AND pg_temp.total('7a200000-0000-4000-8000-000000000503') = (_before->>'zero')::numeric + 3
    AND pg_temp.total('7a200000-0000-4000-8000-000000000504') = (_before->>'arch')::numeric + 0.5, 'organization totals adjust by deltas');
  PERFORM pg_temp.assert(pg_temp.qty('7a200000-0000-4000-8000-000000000501', pg_temp.unassigned('7a200000-0000-4000-8000-000000000101')) = 8,
    'other locations untouched');

  -- One physical_count ledger row per line, zero included, linked uniquely.
  PERFORM pg_temp.assert((SELECT count(*) FROM public.inventory_adjustments adjustment
    JOIN public.inventory_count_lines line ON line.id = adjustment.inventory_count_line_id
    WHERE line.count_session_id = _session.id
      AND adjustment.source_type = 'physical_count' AND adjustment.reason = 'Physical count'
      AND adjustment.adjustment_amount = line.delta AND adjustment.inventory_item_id = line.inventory_item_id
      AND adjustment.inventory_location_id = _cab AND adjustment.created_by = '7a200000-0000-4000-8000-000000000003'
      AND adjustment.created_at = _session.submitted_at
      AND adjustment.new_quantity = adjustment.previous_quantity + adjustment.adjustment_amount) = 4,
    'four physical_count adjustments, one per line, zero delta included');
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM public.inventory_adjustments
    WHERE inventory_item_id = '7a200000-0000-4000-8000-000000000502' AND source_type = 'physical_count' AND adjustment_amount = 0),
    'zero-delta checkpoint exists in the ledger');
END
$check_count1$;

-- The schema enforces the ledger link.
SELECT pg_temp.expect_error($$INSERT INTO public.inventory_adjustments (organization_id, inventory_item_id, adjustment_amount, previous_quantity,
  new_quantity, reason, created_by, source_type) VALUES ('7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000501', 0, 9, 9,
  'Physical count', '7a200000-0000-4000-8000-000000000003', 'physical_count')$$, 'inventory_adjustments_physical_count_check');
SELECT pg_temp.expect_error($$INSERT INTO public.inventory_adjustments (organization_id, inventory_item_id, adjustment_amount, previous_quantity,
  new_quantity, reason, created_by, source_type) VALUES ('7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000501', 0, 9, 9,
  'Physical count', '7a200000-0000-4000-8000-000000000003', 'manual')$$, 'inventory_adjustments_physical_count_check');
SELECT pg_temp.expect_error(format($$INSERT INTO public.inventory_adjustments (organization_id, inventory_item_id, inventory_location_id, adjustment_amount,
  previous_quantity, new_quantity, reason, created_by, source_type, inventory_count_line_id)
  SELECT organization_id, inventory_item_id, inventory_location_id, 0, 9, 9, 'Physical count', '7a200000-0000-4000-8000-000000000003',
    'physical_count', id FROM public.inventory_count_lines WHERE count_session_id = %L AND inventory_item_id = '7a200000-0000-4000-8000-000000000501'$$,
  pg_temp.val('count1')->>'sessionId'), 'inventory_adjustments_count_line_uq');
SELECT pg_temp.expect_error(format($$UPDATE public.inventory_count_sessions SET changed_count = 0 WHERE id = %L$$,
  pg_temp.val('count1')->>'sessionId'), 'Inventory count history cannot be changed');
SELECT pg_temp.expect_error(format($$DELETE FROM public.inventory_count_lines WHERE count_session_id = %L$$,
  pg_temp.val('count1')->>'sessionId'), 'Inventory count history cannot be deleted');

-- ---------------------------------------------------------------------------------------
-- 6. Idempotency: identical replays return the original result; anything else is refused.
-- ---------------------------------------------------------------------------------------
INSERT INTO phase7a2_values VALUES ('after_count1', pg_temp.state('7a200000-0000-4000-8000-000000000101'));
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000003');
-- Same count, quantities spelled differently and lines in a different order.
INSERT INTO phase7a2_values VALUES ('replay1', pg_temp.submit((SELECT jsonb_agg(line ORDER BY line->>'inventoryItemId' DESC)
  FROM jsonb_array_elements(pg_temp.lines(pg_temp.val('page1'), jsonb_build_object(
    '7a200000-0000-4000-8000-000000000501', 9.0,
    '7a200000-0000-4000-8000-000000000502', '2.7500',
    '7a200000-0000-4000-8000-000000000503', 3,
    '7a200000-0000-4000-8000-000000000504', '5.50'))) line), 'count-1'));
SELECT pg_temp.expect_error($$SELECT pg_temp.submit(pg_temp.lines(pg_temp.val('page1'), jsonb_build_object(
    '7a200000-0000-4000-8000-000000000501', '8', '7a200000-0000-4000-8000-000000000502', '2.75',
    '7a200000-0000-4000-8000-000000000503', '3', '7a200000-0000-4000-8000-000000000504', '5.5')), 'count-1')$$,
  'This count request key was already used for a different count');
SELECT pg_temp.expect_error(format($$SELECT pg_temp.submit(pg_temp.lines(pg_temp.val('page1')), 'count-1', %L)$$, pg_temp.loc('rehab')),
  'This count request key was already used for a different count');
-- The same key from another member of the organization replays too; it is one request.
RESET ROLE;
SELECT pg_temp.assert((pg_temp.val('replay1')->>'replayed')::boolean
  AND pg_temp.val('replay1')->>'sessionId' = pg_temp.val('count1')->>'sessionId'
  AND (pg_temp.val('replay1') - 'replayed') = (pg_temp.val('count1') - 'replayed'), 'replay returns the original summary');
SELECT pg_temp.assert(pg_temp.state('7a200000-0000-4000-8000-000000000101') = pg_temp.val('after_count1'),
  'replays and refused reuse wrote nothing');

-- ---------------------------------------------------------------------------------------
-- 7. Stale counts: versions and item sets.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000003');
-- The page from before count-1 is now stale, even for a different key (zero-delta lines moved versions too).
SELECT pg_temp.expect_error($$SELECT pg_temp.submit(pg_temp.lines(pg_temp.val('page1')), 'stale-1')$$,
  'Inventory changed while you were counting. Reload this location and confirm the quantities again.');
INSERT INTO phase7a2_values VALUES ('page2', pg_temp.page('7a200000-0000-4000-8000-000000000101', pg_temp.loc('cabinet')));
-- Owner adjustment at this location after the page loaded.
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000001');
SELECT public.adjust_inventory_location_quantity('7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000501',
  pg_temp.loc('cabinet'), -1, 'Damaged');
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000003');
SELECT pg_temp.expect_error($$SELECT pg_temp.submit(pg_temp.lines(pg_temp.val('page2')), 'stale-2')$$, 'Inventory changed while you were counting');
INSERT INTO phase7a2_values VALUES ('page3', pg_temp.page('7a200000-0000-4000-8000-000000000101', pg_temp.loc('cabinet')));
-- A move out of this location.
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000001');
SELECT public.move_inventory_stock('7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000502',
  pg_temp.loc('cabinet'), pg_temp.loc('rehab'), 0.25, 'stale-move-out');
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000003');
SELECT pg_temp.expect_error($$SELECT pg_temp.submit(pg_temp.lines(pg_temp.val('page3')), 'stale-3')$$, 'Inventory changed while you were counting');
INSERT INTO phase7a2_values VALUES ('page4', pg_temp.page('7a200000-0000-4000-8000-000000000101', pg_temp.loc('cabinet')));
-- A new item arrives at this location: the old item set is incomplete.
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000001');
SELECT public.move_inventory_stock('7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000506',
  pg_temp.unassigned('7a200000-0000-4000-8000-000000000101'), pg_temp.loc('cabinet'), 4, 'stale-new-item');
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000003');
SELECT pg_temp.expect_error($$SELECT pg_temp.submit(pg_temp.lines(pg_temp.val('page4')), 'stale-4')$$, 'Inventory changed while you were counting');
INSERT INTO phase7a2_values VALUES ('page5', pg_temp.page('7a200000-0000-4000-8000-000000000101', pg_temp.loc('cabinet')));
SELECT pg_temp.assert(cardinality(pg_temp.page_ids(pg_temp.val('page5'))) = 5, 'the new item joined the count');
-- An item is archived after the page loaded while it has stock: it stays countable, but
-- archiving one without stock removes it from the set.
RESET ROLE;
UPDATE public.inventory_items SET active = false WHERE id = '7a200000-0000-4000-8000-000000000503';
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000003');
SELECT pg_temp.assert(pg_temp.page_ids(pg_temp.page('7a200000-0000-4000-8000-000000000101', pg_temp.loc('cabinet')))
  = pg_temp.page_ids(pg_temp.val('page5')), 'archiving a stocked item keeps it countable');
RESET ROLE;
UPDATE public.inventory_items SET active = true WHERE id = '7a200000-0000-4000-8000-000000000503';
-- Nothing stale: a receipt (lands in Unassigned) does not affect a storage-location count.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000001');
SELECT public.adjust_inventory_location_quantity('7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000501',
  pg_temp.unassigned('7a200000-0000-4000-8000-000000000101'), 1, 'Correction');
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000003');
INSERT INTO phase7a2_values VALUES ('count2', pg_temp.submit(pg_temp.lines(pg_temp.val('page5'), jsonb_build_object(
  '7a200000-0000-4000-8000-000000000503', '0', '7a200000-0000-4000-8000-000000000504', '0')), 'count-2'));
RESET ROLE;

-- ---------------------------------------------------------------------------------------
-- 8. Countability after counting: active zero stays; archived zero drops; overage at zero.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000003');
INSERT INTO phase7a2_values VALUES ('page6', pg_temp.page('7a200000-0000-4000-8000-000000000101', pg_temp.loc('cabinet')));
RESET ROLE;
DO $check_after_count2$
DECLARE
  _page jsonb := pg_temp.val('page6');
BEGIN
  PERFORM pg_temp.assert('7a200000-0000-4000-8000-000000000503' = ANY (pg_temp.page_ids(_page)),
    'active item confirmed at zero stays countable');
  PERFORM pg_temp.assert(NOT ('7a200000-0000-4000-8000-000000000504' = ANY (pg_temp.page_ids(_page))),
    'archived item counted down to zero drops off');
  PERFORM pg_temp.assert((pg_temp.val('count2')->>'changedCount')::int = 2 AND (pg_temp.val('count2')->>'lineCount')::int = 5,
    'second count summary');
  PERFORM pg_temp.assert(_page->'location'->>'lastCountedAt' IS NOT NULL, 'last counted time reported');
END
$check_after_count2$;
-- Unrecorded stock found against a zero system balance.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000003');
INSERT INTO phase7a2_values VALUES ('count3', pg_temp.submit(pg_temp.lines(pg_temp.val('page6'), jsonb_build_object(
  '7a200000-0000-4000-8000-000000000503', '0.125')), 'count-3'));
RESET ROLE;
SELECT pg_temp.assert(pg_temp.qty('7a200000-0000-4000-8000-000000000503', pg_temp.loc('cabinet')) = 0.125,
  'overage entered against a zero system balance');

-- ---------------------------------------------------------------------------------------
-- 9. Checkpoints and invoice deletion.
-- ---------------------------------------------------------------------------------------
INSERT INTO public.vendors (id, organization_id, name, normalized_name, active) VALUES
  ('7a200000-0000-4000-8000-000000000301', '7a200000-0000-4000-8000-000000000101', 'Phase 7A.2 Vendor', 'phase 7a.2 vendor', true);
INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type) VALUES
  ('7a200000-0000-4000-8000-000000000601', '7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000001', '7a200000-0000-4000-8000-000000000101/phase7a2-1.pdf', '1.pdf', 1, 'application/pdf'),
  ('7a200000-0000-4000-8000-000000000602', '7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000001', '7a200000-0000-4000-8000-000000000101/phase7a2-2.pdf', '2.pdf', 1, 'application/pdf');
INSERT INTO public.invoices (id, organization_id, source_file_id, vendor_id, vendor_name, invoice_number, processing_status, invoice_date) VALUES
  ('7a200000-0000-4000-8000-000000000701', '7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000601', '7a200000-0000-4000-8000-000000000301', 'Phase 7A.2 Vendor', '7A2-1', 'review_required', '2026-10-20'),
  ('7a200000-0000-4000-8000-000000000702', '7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000602', '7a200000-0000-4000-8000-000000000301', 'Phase 7A.2 Vendor', '7A2-2', 'review_required', '2026-10-21');
INSERT INTO public.invoice_items (id, invoice_id, organization_id, line_number, sku, description, quantity, unit_of_measure, unit_price, total_price, product_id) VALUES
  ('7a200000-0000-4000-8000-000000000801', '7a200000-0000-4000-8000-000000000701', '7a200000-0000-4000-8000-000000000101', 1, 'TAPE-1', 'Phase 7A.2 Athletic Tape', 6, 'roll', 2, 12, '7a200000-0000-4000-8000-000000000401'),
  ('7a200000-0000-4000-8000-000000000802', '7a200000-0000-4000-8000-000000000702', '7a200000-0000-4000-8000-000000000101', 1, 'TAPE-1', 'Phase 7A.2 Athletic Tape', 2, 'roll', 2, 4, '7a200000-0000-4000-8000-000000000401');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000001');
SELECT public.post_reviewed_invoice('7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000601');
-- Receipt -> zero-change count of the received item at a storage location.
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000003');
INSERT INTO phase7a2_values VALUES ('page7', pg_temp.page('7a200000-0000-4000-8000-000000000101', pg_temp.loc('cabinet')));
RESET ROLE;
INSERT INTO phase7a2_values VALUES ('tape_before_zero_count', jsonb_build_object(
  'total', pg_temp.total('7a200000-0000-4000-8000-000000000501'),
  'qty', pg_temp.qty('7a200000-0000-4000-8000-000000000501', pg_temp.loc('cabinet')),
  'version', pg_temp.ver('7a200000-0000-4000-8000-000000000501', pg_temp.loc('cabinet')),
  'sessions', (SELECT count(*) FROM public.inventory_count_sessions WHERE organization_id = '7a200000-0000-4000-8000-000000000101'),
  'adjustments', (SELECT count(*) FROM public.inventory_adjustments WHERE organization_id = '7a200000-0000-4000-8000-000000000101')));
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000003');
INSERT INTO phase7a2_values VALUES ('count4', pg_temp.submit(pg_temp.lines(pg_temp.val('page7')), 'count-4'));
RESET ROLE;
DO $check_zero_checkpoint$
DECLARE
  _before jsonb := pg_temp.val('tape_before_zero_count');
  _lines integer := jsonb_array_length(pg_temp.val('page7')->'items');
BEGIN
  PERFORM pg_temp.assert((pg_temp.val('count4')->>'changedCount')::int = 0, 'an all-unchanged count');
  PERFORM pg_temp.assert(pg_temp.qty('7a200000-0000-4000-8000-000000000501', pg_temp.loc('cabinet')) = (_before->>'qty')::numeric,
    'zero-delta count leaves the location quantity');
  PERFORM pg_temp.assert(pg_temp.total('7a200000-0000-4000-8000-000000000501') = (_before->>'total')::numeric,
    'zero-delta count leaves the organization total');
  PERFORM pg_temp.assert(pg_temp.ver('7a200000-0000-4000-8000-000000000501', pg_temp.loc('cabinet')) = (_before->>'version')::bigint + 1,
    'zero-delta count bumps the balance version');
  PERFORM pg_temp.assert((SELECT count(*) FROM public.inventory_count_sessions WHERE organization_id = '7a200000-0000-4000-8000-000000000101')
    = (_before->>'sessions')::int + 1, 'zero-delta count creates a session');
  PERFORM pg_temp.assert((SELECT count(*) FROM public.inventory_count_lines WHERE count_session_id = (pg_temp.val('count4')->>'sessionId')::uuid
    AND delta = 0) = _lines, 'zero-delta count creates every line');
  PERFORM pg_temp.assert((SELECT count(*) FROM public.inventory_adjustments WHERE organization_id = '7a200000-0000-4000-8000-000000000101')
    = (_before->>'adjustments')::int + _lines, 'zero-delta count creates a checkpoint row per line');
END
$check_zero_checkpoint$;
INSERT INTO phase7a2_values VALUES ('before_checkpoint_delete', pg_temp.state('7a200000-0000-4000-8000-000000000101'));
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000001');
SELECT pg_temp.expect_error($$SELECT public.delete_invoice_permanently('7a200000-0000-4000-8000-000000000101', '7a200000-0000-4000-8000-000000000601')$$,
  'This invoice cannot be deleted because Phase 7A.2 Athletic Tape was physically counted after it was received.');
RESET ROLE;
SELECT pg_temp.assert(pg_temp.state('7a200000-0000-4000-8000-000000000101') = pg_temp.val('before_checkpoint_delete'),
  'a zero-delta checkpoint blocks deleting the earlier receipt and nothing changes');
-- A receipt posted after the latest count still deletes normally. Inside this single
-- transaction every receipt shares now(), which precedes the count's clock time, so that
-- case runs across real transactions in phase7a2_race_check.sh (scenario 9).

-- ---------------------------------------------------------------------------------------
-- 10. Staff inventory read hardening (Phase 7A.2-0).
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000003');
SELECT pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.inventory_items), 'staff can no longer read inventory_items directly');
SELECT pg_temp.assert((SELECT array_agg(id ORDER BY id) FROM public.get_supply_request_inventory_identities(
    '7a200000-0000-4000-8000-000000000101', ARRAY['7a200000-0000-4000-8000-000000000501', '7a200000-0000-4000-8000-000000000505',
    '7a200000-0000-4000-8000-000000000511']::uuid[]))
  = ARRAY['7a200000-0000-4000-8000-000000000501']::uuid[], 'staff identities: active items of their organization only');
SELECT pg_temp.assert((SELECT array_agg(key ORDER BY key) FROM public.get_supply_request_inventory_identities(
    '7a200000-0000-4000-8000-000000000101', ARRAY['7a200000-0000-4000-8000-000000000501']::uuid[]) identity,
    jsonb_object_keys(to_jsonb(identity)) key)
  = ARRAY['active', 'id', 'manufacturer', 'name', 'sku', 'unit', 'vendor_name'],
  'staff identities carry display fields only: no price, purchase date, par level or quantity');
SELECT pg_temp.assert((SELECT name = 'Phase 7A.2 Athletic Tape' AND sku = 'TAPE-1' AND unit = 'roll'
  FROM public.get_supply_request_inventory_identities('7a200000-0000-4000-8000-000000000101',
    ARRAY['7a200000-0000-4000-8000-000000000501']::uuid[])), 'staff identity values');
SELECT pg_temp.expect_error($$SELECT * FROM public.get_supply_request_inventory_identities('7a200000-0000-4000-8000-000000000102', ARRAY['7a200000-0000-4000-8000-000000000511']::uuid[])$$,
  'Forbidden: organization membership required');
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000002');
SELECT pg_temp.assert((SELECT count(*) FROM public.inventory_items WHERE organization_id = '7a200000-0000-4000-8000-000000000101')
  = 5, 'admins still read active inventory rows');
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000001');
SELECT pg_temp.assert((SELECT count(*) FROM public.inventory_items WHERE organization_id = '7a200000-0000-4000-8000-000000000101') = 7,
  'owners still read every inventory row');
SELECT pg_temp.assert((SELECT count(*) FROM public.get_supply_request_inventory_identities('7a200000-0000-4000-8000-000000000101',
  ARRAY['7a200000-0000-4000-8000-000000000505']::uuid[])) = 1, 'owners see archived identities too');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.expect_error($$SELECT * FROM public.get_supply_request_inventory_identities('7a200000-0000-4000-8000-000000000101', ARRAY[]::uuid[])$$,
  'permission denied');
RESET ROLE;

-- ---------------------------------------------------------------------------------------
-- 11. Grants.
-- ---------------------------------------------------------------------------------------
DO $check_grants$
DECLARE
  _fn text;
BEGIN
  FOREACH _fn IN ARRAY ARRAY['public.inventory_countable_balances(uuid, uuid)', 'public.inventory_count_summary(uuid, boolean)',
    'public.inventory_count_replay(public.inventory_count_sessions, uuid, text)', 'public.tg_guard_inventory_count_history()',
    'public.tg_guard_inventory_location_label()'] LOOP
    PERFORM pg_temp.assert(NOT has_function_privilege('authenticated', _fn, 'EXECUTE')
      AND NOT has_function_privilege('anon', _fn, 'EXECUTE'), _fn || ' is internal');
  END LOOP;
  FOREACH _fn IN ARRAY ARRAY['public.issue_inventory_location_label(uuid, uuid)', 'public.revoke_inventory_location_labels(uuid, uuid)',
    'public.list_inventory_location_count_status(uuid)', 'public.resolve_inventory_count_label(text)',
    'public.list_countable_inventory_locations(uuid)', 'public.get_inventory_count_location(uuid, uuid)',
    'public.submit_inventory_count(uuid, uuid, jsonb, text)', 'public.get_supply_request_inventory_identities(uuid, uuid[])'] LOOP
    PERFORM pg_temp.assert(has_function_privilege('authenticated', _fn, 'EXECUTE')
      AND NOT has_function_privilege('anon', _fn, 'EXECUTE')
      AND NOT EXISTS (SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
        WHERE p.oid = _fn::regprocedure AND acl.grantee = 0), _fn || ' is authenticated-only');
  END LOOP;
  PERFORM pg_temp.assert(NOT has_table_privilege('authenticated', 'public.inventory_location_labels', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.inventory_count_sessions', 'INSERT')
    AND NOT has_table_privilege('authenticated', 'public.inventory_count_lines', 'UPDATE')
    AND NOT has_table_privilege('service_role', 'public.inventory_count_lines', 'INSERT')
    AND NOT has_table_privilege('anon', 'public.inventory_count_sessions', 'SELECT'), 'no direct writes, no label reads');
END
$check_grants$;

-- ---------------------------------------------------------------------------------------
-- 12. Another organization counts independently; deleting a counted item (postgres only;
-- no application role can delete inventory items) cascades through its count history.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000004');
SELECT public.issue_inventory_location_label('7a200000-0000-4000-8000-000000000102', pg_temp.loc('other'));
SELECT pg_temp.as_user('7a200000-0000-4000-8000-000000000005');
SELECT public.submit_inventory_count('7a200000-0000-4000-8000-000000000102', pg_temp.loc('other'),
  pg_temp.lines(public.get_inventory_count_location('7a200000-0000-4000-8000-000000000102', pg_temp.loc('other'))), 'count-1');
RESET ROLE;
SELECT pg_temp.assert((SELECT count(*) FROM public.inventory_count_sessions WHERE idempotency_key = 'count-1') = 2,
  'idempotency keys are scoped per organization');
SET CONSTRAINTS ALL IMMEDIATE;
DELETE FROM public.inventory_items WHERE id = '7a200000-0000-4000-8000-000000000511';
SELECT pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.inventory_count_lines WHERE inventory_item_id = '7a200000-0000-4000-8000-000000000511')
  AND NOT EXISTS (SELECT 1 FROM public.inventory_adjustments WHERE inventory_item_id = '7a200000-0000-4000-8000-000000000511'),
  'deleting an item cascades its count lines and ledger rows');

SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
