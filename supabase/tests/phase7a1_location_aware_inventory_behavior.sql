-- Phase 7A.1 rollback-only behavioral verification: location-aware inventory foundation.
-- Run against a disposable database after 20261021120000_phase7a1_location_aware_inventory.sql.
-- Every fixture and mutation happens inside this transaction and is rolled back. The suite
-- ends with SET CONSTRAINTS ALL IMMEDIATE so the deferred quantity invariant is evaluated
-- for every row this suite touched before the rollback.

BEGIN;

DO $phase7a1_fixture_guard$
BEGIN
  IF EXISTS (
    SELECT 1 FROM auth.users
    WHERE id BETWEEN '7a100000-0000-4000-8000-000000000001'::uuid AND '7a100000-0000-4000-8000-000000000099'::uuid
  ) OR EXISTS (
    SELECT 1 FROM public.organizations
    WHERE id BETWEEN '7a100000-0000-4000-8000-000000000101'::uuid AND '7a100000-0000-4000-8000-000000000199'::uuid
  ) THEN
    RAISE EXCEPTION 'Phase 7A.1 rollback-test fixture IDs already exist';
  END IF;
END
$phase7a1_fixture_guard$;

CREATE FUNCTION pg_temp.expect_error(_statement text, _expected text)
RETURNS void
LANGUAGE plpgsql
AS $$
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
RETURNS void
LANGUAGE sql
AS $$ SELECT pg_catalog.set_config('request.jwt.claim.sub', _user_id::text, true) $$;

-- Balance for one item at one location (NULL when no row exists). Run as postgres.
CREATE FUNCTION pg_temp.qty(_item uuid, _location uuid)
RETURNS numeric
LANGUAGE sql
AS $$ SELECT quantity FROM public.inventory_location_balances
      WHERE inventory_item_id = _item AND inventory_location_id = _location $$;

CREATE FUNCTION pg_temp.total(_item uuid)
RETURNS numeric
LANGUAGE sql
AS $$ SELECT quantity FROM public.inventory_items WHERE id = _item $$;

-- Security definer so the id resolves even where RLS hides the row from the current user.
CREATE FUNCTION pg_temp.unassigned(_organization uuid)
RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
AS $$ SELECT id FROM public.inventory_locations WHERE organization_id = _organization AND kind = 'unassigned' $$;

CREATE FUNCTION pg_temp.assert(_condition boolean, _message text)
RETURNS void
LANGUAGE plpgsql
AS $$ BEGIN IF _condition IS NOT TRUE THEN RAISE EXCEPTION 'Check failed: %', _message; END IF; END; $$;

-- Everything a refused or foreign mutation must leave alone, for one organization.
CREATE FUNCTION pg_temp.inventory_state(_organization uuid)
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT jsonb_build_object(
    'items', (SELECT coalesce(jsonb_agg(jsonb_build_array(id, quantity, active) ORDER BY id), '[]')
              FROM public.inventory_items WHERE organization_id = _organization),
    'balances', (SELECT coalesce(jsonb_agg(jsonb_build_array(inventory_item_id, inventory_location_id, quantity, version)
                 ORDER BY inventory_item_id, inventory_location_id), '[]')
                 FROM public.inventory_location_balances WHERE organization_id = _organization),
    'locations', (SELECT coalesce(jsonb_agg(jsonb_build_array(id, name, kind, active) ORDER BY id), '[]')
                  FROM public.inventory_locations WHERE organization_id = _organization),
    'adjustments', (SELECT count(*) FROM public.inventory_adjustments WHERE organization_id = _organization),
    'transfers', (SELECT count(*) FROM public.inventory_transfers WHERE organization_id = _organization))
$$;

CREATE TEMP TABLE phase7a1_snapshots (name text PRIMARY KEY, value jsonb) ON COMMIT DROP;
GRANT ALL ON phase7a1_snapshots TO authenticated;

-- ---------------------------------------------------------------------------------------
-- Fixtures. Organization A: owner, admin, staff. Organization B: owner.
-- ---------------------------------------------------------------------------------------
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
VALUES
  ('7a100000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'phase7a1-owner@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('7a100000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'phase7a1-admin@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('7a100000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'phase7a1-staff@example.invalid', '', now(), '{}', '{}', now(), now()),
  ('7a100000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'phase7a1-other-owner@example.invalid', '', now(), '{}', '{}', now(), now());

INSERT INTO public.organizations (id, name, created_by)
VALUES
  ('7a100000-0000-4000-8000-000000000101', 'Phase 7A.1 Organization', '7a100000-0000-4000-8000-000000000001'),
  ('7a100000-0000-4000-8000-000000000102', 'Phase 7A.1 Other Organization', '7a100000-0000-4000-8000-000000000004');

INSERT INTO public.organization_memberships (id, organization_id, user_id, role, active)
VALUES
  ('7a100000-0000-4000-8000-000000000131', '7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000001', 'owner', true),
  ('7a100000-0000-4000-8000-000000000132', '7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000002', 'admin', true),
  ('7a100000-0000-4000-8000-000000000133', '7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000003', 'staff', true),
  ('7a100000-0000-4000-8000-000000000134', '7a100000-0000-4000-8000-000000000102', '7a100000-0000-4000-8000-000000000004', 'owner', true);

INSERT INTO public.vendors (id, organization_id, name, normalized_name, active)
VALUES
  ('7a100000-0000-4000-8000-000000000301', '7a100000-0000-4000-8000-000000000101', 'Phase 7A.1 Vendor', 'phase 7a.1 vendor', true),
  ('7a100000-0000-4000-8000-000000000302', '7a100000-0000-4000-8000-000000000102', 'Phase 7A.1 Vendor', 'phase 7a.1 vendor', true);

INSERT INTO public.products (id, organization_id, name, normalized_name, unit_of_measure, approved, active, staff_requestable)
VALUES
  ('7a100000-0000-4000-8000-000000000401', '7a100000-0000-4000-8000-000000000101', 'Phase 7A.1 Athletic Tape', 'x', 'roll', true, true, true),
  ('7a100000-0000-4000-8000-000000000402', '7a100000-0000-4000-8000-000000000101', 'Phase 7A.1 Gauze', 'x', 'box', true, true, true),
  ('7a100000-0000-4000-8000-000000000403', '7a100000-0000-4000-8000-000000000101', 'Phase 7A.1 Empty Item', 'x', 'each', true, true, true),
  ('7a100000-0000-4000-8000-000000000404', '7a100000-0000-4000-8000-000000000101', 'Phase 7A.1 New Receipt', 'x', 'each', true, true, true),
  ('7a100000-0000-4000-8000-000000000405', '7a100000-0000-4000-8000-000000000102', 'Phase 7A.1 Other Tape', 'x', 'roll', true, true, true);

-- Fixture items carry stock that predates locations, as production rows do.
INSERT INTO public.inventory_items (id, organization_id, product_id, sku, name, unit, quantity, vendor_name, active)
VALUES
  ('7a100000-0000-4000-8000-000000000501', '7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000401', 'TAPE-1', 'Phase 7A.1 Athletic Tape', 'roll', 100, 'Phase 7A.1 Vendor', true),
  ('7a100000-0000-4000-8000-000000000502', '7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000402', 'GAUZE-1', 'Phase 7A.1 Gauze', 'box', 2.75, 'Phase 7A.1 Vendor', true),
  ('7a100000-0000-4000-8000-000000000503', '7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000403', NULL, 'Phase 7A.1 Empty Item', 'each', 0, NULL, true),
  ('7a100000-0000-4000-8000-000000000505', '7a100000-0000-4000-8000-000000000102', '7a100000-0000-4000-8000-000000000405', 'TAPE-1', 'Phase 7A.1 Other Tape', 'roll', 40, 'Phase 7A.1 Vendor', true);

INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type)
VALUES
  ('7a100000-0000-4000-8000-000000000601', '7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000001', '7a100000-0000-4000-8000-000000000101/phase7a1-1.pdf', 'phase7a1-1.pdf', 1024, 'application/pdf'),
  ('7a100000-0000-4000-8000-000000000602', '7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000001', '7a100000-0000-4000-8000-000000000101/phase7a1-2.pdf', 'phase7a1-2.pdf', 1024, 'application/pdf'),
  ('7a100000-0000-4000-8000-000000000603', '7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000001', '7a100000-0000-4000-8000-000000000101/phase7a1-3.pdf', 'phase7a1-3.pdf', 1024, 'application/pdf');

INSERT INTO public.invoices (id, organization_id, source_file_id, vendor_id, vendor_name, invoice_number, processing_status, invoice_date)
VALUES
  ('7a100000-0000-4000-8000-000000000701', '7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000601', '7a100000-0000-4000-8000-000000000301', 'Phase 7A.1 Vendor', '7A1-1', 'review_required', '2026-10-01'),
  ('7a100000-0000-4000-8000-000000000702', '7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000602', '7a100000-0000-4000-8000-000000000301', 'Phase 7A.1 Vendor', '7A1-2', 'review_required', '2026-10-02'),
  ('7a100000-0000-4000-8000-000000000703', '7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000603', '7a100000-0000-4000-8000-000000000301', 'Phase 7A.1 Vendor', '7A1-3', 'review_required', '2026-10-03');

INSERT INTO public.invoice_items (id, invoice_id, organization_id, line_number, sku, description, quantity, unit_of_measure, unit_price, total_price, product_id)
VALUES
  ('7a100000-0000-4000-8000-000000000801', '7a100000-0000-4000-8000-000000000701', '7a100000-0000-4000-8000-000000000101', 1, 'TAPE-1', 'Phase 7A.1 Athletic Tape', 25, 'roll', 2, 50, '7a100000-0000-4000-8000-000000000401'),
  ('7a100000-0000-4000-8000-000000000802', '7a100000-0000-4000-8000-000000000701', '7a100000-0000-4000-8000-000000000101', 2, 'NEW-1', 'Phase 7A.1 New Receipt', 1.5, 'each', 4, 6, '7a100000-0000-4000-8000-000000000404'),
  ('7a100000-0000-4000-8000-000000000803', '7a100000-0000-4000-8000-000000000702', '7a100000-0000-4000-8000-000000000101', 1, 'TAPE-1', 'Phase 7A.1 Athletic Tape', 5, 'roll', 2, 10, '7a100000-0000-4000-8000-000000000401'),
  ('7a100000-0000-4000-8000-000000000804', '7a100000-0000-4000-8000-000000000703', '7a100000-0000-4000-8000-000000000101', 1, 'GAUZE-1', 'Phase 7A.1 Gauze', 1.25, 'box', 3, 3.75, '7a100000-0000-4000-8000-000000000402');

INSERT INTO phase7a1_snapshots VALUES ('org_b_start', pg_temp.inventory_state('7a100000-0000-4000-8000-000000000102'));

-- ---------------------------------------------------------------------------------------
-- 1-6. Unassigned and backfill-equivalent seeding.
-- ---------------------------------------------------------------------------------------
DO $check_unassigned$
BEGIN
  PERFORM pg_temp.assert((SELECT count(*) FROM public.inventory_locations
    WHERE organization_id = '7a100000-0000-4000-8000-000000000101' AND kind = 'unassigned') = 1,
    'organization A has exactly one Unassigned');
  PERFORM pg_temp.assert((SELECT count(*) FROM public.inventory_locations
    WHERE organization_id = '7a100000-0000-4000-8000-000000000102' AND kind = 'unassigned') = 1,
    'organization B has exactly one Unassigned');
  PERFORM pg_temp.assert(pg_temp.unassigned('7a100000-0000-4000-8000-000000000101')
    <> pg_temp.unassigned('7a100000-0000-4000-8000-000000000102'), 'Unassigned is per organization');
  PERFORM pg_temp.assert((SELECT name FROM public.inventory_locations
    WHERE id = pg_temp.unassigned('7a100000-0000-4000-8000-000000000101')) = 'Unassigned', 'Unassigned name');
  -- New items start with all stock in Unassigned, including zero and fractional quantities.
  PERFORM pg_temp.assert(pg_temp.qty('7a100000-0000-4000-8000-000000000501', pg_temp.unassigned('7a100000-0000-4000-8000-000000000101')) = 100, 'tape seeded to Unassigned');
  PERFORM pg_temp.assert(pg_temp.qty('7a100000-0000-4000-8000-000000000502', pg_temp.unassigned('7a100000-0000-4000-8000-000000000101')) = 2.75, 'fractional quantity preserved exactly');
  PERFORM pg_temp.assert(pg_temp.qty('7a100000-0000-4000-8000-000000000503', pg_temp.unassigned('7a100000-0000-4000-8000-000000000101')) = 0, 'zero item has a zero Unassigned balance');
  PERFORM pg_temp.assert(pg_temp.qty('7a100000-0000-4000-8000-000000000505', pg_temp.unassigned('7a100000-0000-4000-8000-000000000102')) = 40, 'tenant B seeded separately');
  PERFORM pg_temp.assert((SELECT count(*) FROM public.inventory_location_balances
    WHERE inventory_item_id = '7a100000-0000-4000-8000-000000000501') = 1, 'one balance row per seeded item');
END
$check_unassigned$;

-- A brand-new organization receives its Unassigned location immediately.
INSERT INTO public.organizations (id, name, created_by)
VALUES ('7a100000-0000-4000-8000-000000000103', 'Phase 7A.1 New Organization', '7a100000-0000-4000-8000-000000000004');
SELECT pg_temp.assert(pg_temp.unassigned('7a100000-0000-4000-8000-000000000103') IS NOT NULL, 'new organization gets Unassigned');

-- A second Unassigned cannot be created, even by the database owner.
SELECT pg_temp.expect_error($$
  INSERT INTO public.inventory_locations (organization_id, name, kind)
  VALUES ('7a100000-0000-4000-8000-000000000101', 'Second Unassigned', 'unassigned')
$$, 'inventory_locations_org_unassigned_uq');

-- ---------------------------------------------------------------------------------------
-- Location administration (owner only) and Unassigned protection.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000001');
INSERT INTO phase7a1_snapshots VALUES
  ('l1', to_jsonb(public.create_inventory_location('7a100000-0000-4000-8000-000000000101', 'Training Room Cabinet A', 'Main training room'))),
  ('l2', to_jsonb(public.create_inventory_location('7a100000-0000-4000-8000-000000000101', 'Away Medical Cart'))),
  ('l3', to_jsonb(public.create_inventory_location('7a100000-0000-4000-8000-000000000101', 'Academy Storage'))),
  ('l4', to_jsonb(public.create_inventory_location('7a100000-0000-4000-8000-000000000101', 'Empty Bin')));
SELECT pg_temp.expect_error($$SELECT public.create_inventory_location('7a100000-0000-4000-8000-000000000101', '  training room cabinet a ')$$,
  'An inventory location with that name already exists');
SELECT pg_temp.expect_error($$SELECT public.create_inventory_location('7a100000-0000-4000-8000-000000000101', 'unassigned')$$,
  'An inventory location with that name already exists');
SELECT pg_temp.expect_error($$SELECT public.create_inventory_location('7a100000-0000-4000-8000-000000000101', '   ')$$,
  'Enter a location name');

CREATE FUNCTION pg_temp.loc(_name text)
RETURNS uuid
LANGUAGE sql
AS $$ SELECT (value #>> '{}')::uuid FROM phase7a1_snapshots WHERE name = _name $$;

SELECT public.update_inventory_location('7a100000-0000-4000-8000-000000000101', pg_temp.loc('l3'), 'Academy Supply Room', 'Renamed');
SELECT pg_temp.expect_error(format($$SELECT public.update_inventory_location('7a100000-0000-4000-8000-000000000101', %L, 'Renamed Unassigned')$$,
  pg_temp.unassigned('7a100000-0000-4000-8000-000000000101')), 'The Unassigned inventory location is protected');
SELECT pg_temp.expect_error(format($$SELECT public.set_inventory_location_active('7a100000-0000-4000-8000-000000000101', %L, false)$$,
  pg_temp.unassigned('7a100000-0000-4000-8000-000000000101')), 'The Unassigned inventory location is protected and cannot be archived');

-- Staff and admin cannot administer locations; neither can another organization's owner.
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000003');
SELECT pg_temp.expect_error($$SELECT public.create_inventory_location('7a100000-0000-4000-8000-000000000101', 'Staff Closet')$$, 'Forbidden: owner access required');
SELECT pg_temp.expect_error(format($$SELECT public.update_inventory_location('7a100000-0000-4000-8000-000000000101', %L, 'Staff rename')$$, pg_temp.loc('l1')), 'Forbidden: owner access required');
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000002');
SELECT pg_temp.expect_error($$SELECT public.create_inventory_location('7a100000-0000-4000-8000-000000000101', 'Admin Closet')$$, 'Forbidden: owner access required');
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000004');
SELECT pg_temp.expect_error($$SELECT public.create_inventory_location('7a100000-0000-4000-8000-000000000101', 'Foreign Closet')$$, 'Forbidden: owner access required');
SELECT pg_temp.expect_error(format($$SELECT public.update_inventory_location('7a100000-0000-4000-8000-000000000102', %L, 'Hijack')$$, pg_temp.loc('l1')), 'Inventory location not found');
-- Direct table writes are not granted to application roles.
SELECT pg_temp.expect_error($$INSERT INTO public.inventory_locations (organization_id, name) VALUES ('7a100000-0000-4000-8000-000000000102', 'Direct')$$, 'permission denied');
RESET ROLE;

-- Unassigned is protected below the RPCs too.
SELECT pg_temp.expect_error(format($$UPDATE public.inventory_locations SET name = 'Renamed' WHERE id = %L$$,
  pg_temp.unassigned('7a100000-0000-4000-8000-000000000101')), 'The Unassigned inventory location is protected');
SELECT pg_temp.expect_error(format($$DELETE FROM public.inventory_locations WHERE id = %L$$,
  pg_temp.unassigned('7a100000-0000-4000-8000-000000000101')), 'The Unassigned inventory location cannot be deleted');
SELECT pg_temp.expect_error(format($$UPDATE public.inventory_locations SET kind = 'unassigned' WHERE id = %L$$, pg_temp.loc('l1')),
  'kind cannot change');
SELECT pg_temp.expect_error(format($$UPDATE public.inventory_locations SET kind = 'storage' WHERE id = %L$$,
  pg_temp.unassigned('7a100000-0000-4000-8000-000000000101')), 'kind cannot change');
SELECT pg_temp.assert((SELECT name FROM public.inventory_locations WHERE id = pg_temp.loc('l3')) = 'Academy Supply Room', 'owner rename applied');

-- ---------------------------------------------------------------------------------------
-- 7-8, 17, 20. Moves: the same product in several physical locations; totals unchanged.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000001');
INSERT INTO phase7a1_snapshots VALUES ('move1', public.move_inventory_stock('7a100000-0000-4000-8000-000000000101',
  '7a100000-0000-4000-8000-000000000501', pg_temp.unassigned('7a100000-0000-4000-8000-000000000101'), pg_temp.loc('l1'), 60, 'move-1'));
INSERT INTO phase7a1_snapshots VALUES ('move2', public.move_inventory_stock('7a100000-0000-4000-8000-000000000101',
  '7a100000-0000-4000-8000-000000000501', pg_temp.unassigned('7a100000-0000-4000-8000-000000000101'), pg_temp.loc('l2'), 20, 'move-2'));
RESET ROLE;

DO $check_moves$
DECLARE
  _u uuid := pg_temp.unassigned('7a100000-0000-4000-8000-000000000101');
BEGIN
  PERFORM pg_temp.assert(pg_temp.qty('7a100000-0000-4000-8000-000000000501', pg_temp.loc('l1')) = 60, 'Training Room holds 60');
  PERFORM pg_temp.assert(pg_temp.qty('7a100000-0000-4000-8000-000000000501', pg_temp.loc('l2')) = 20, 'Away Cart holds 20');
  PERFORM pg_temp.assert(pg_temp.qty('7a100000-0000-4000-8000-000000000501', _u) = 20, 'Unassigned holds 20');
  PERFORM pg_temp.assert(pg_temp.total('7a100000-0000-4000-8000-000000000501') = 100, 'moves preserve the organization total');
  PERFORM pg_temp.assert((SELECT value ->> 'itemQuantity' FROM phase7a1_snapshots WHERE name = 'move2')::numeric = 100, 'move returns the unchanged total');
  PERFORM pg_temp.assert((SELECT count(*) FROM public.inventory_transfers WHERE organization_id = '7a100000-0000-4000-8000-000000000101') = 2, 'two transfer rows');
  PERFORM pg_temp.assert(NOT EXISTS (
    SELECT 1 FROM public.inventory_transfers WHERE organization_id = '7a100000-0000-4000-8000-000000000101'
      AND (created_by <> '7a100000-0000-4000-8000-000000000001' OR from_inventory_location_id <> _u)), 'transfers record actor and source');
  PERFORM pg_temp.assert((SELECT quantity FROM public.inventory_transfers WHERE idempotency_key = 'move-1') = 60, 'transfer records quantity');
  PERFORM pg_temp.assert((SELECT to_inventory_location_id FROM public.inventory_transfers WHERE idempotency_key = 'move-1') = pg_temp.loc('l1'), 'transfer records destination');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.inventory_adjustments WHERE inventory_item_id = '7a100000-0000-4000-8000-000000000501'),
    'moves write no total-changing history');
END
$check_moves$;

-- ---------------------------------------------------------------------------------------
-- 12, 15. Receiving lands only in Unassigned (the brief's worked example: 60/20/20 + 25).
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000003');
SELECT pg_temp.expect_error($$SELECT public.post_reviewed_invoice('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000601')$$,
  'Forbidden: owner access required');
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000001');
INSERT INTO phase7a1_snapshots VALUES ('post1', public.post_reviewed_invoice('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000601'));
RESET ROLE;

DO $check_receiving$
DECLARE
  _u uuid := pg_temp.unassigned('7a100000-0000-4000-8000-000000000101');
  _new_item uuid;
  _receipt public.inventory_adjustments%ROWTYPE;
BEGIN
  PERFORM pg_temp.assert(pg_temp.qty('7a100000-0000-4000-8000-000000000501', pg_temp.loc('l1')) = 60, 'receiving leaves Training Room alone');
  PERFORM pg_temp.assert(pg_temp.qty('7a100000-0000-4000-8000-000000000501', pg_temp.loc('l2')) = 20, 'receiving leaves Away Cart alone');
  PERFORM pg_temp.assert(pg_temp.qty('7a100000-0000-4000-8000-000000000501', _u) = 45, 'receipt of 25 lands in Unassigned (20 + 25)');
  PERFORM pg_temp.assert(pg_temp.total('7a100000-0000-4000-8000-000000000501') = 125, 'organization total 125');

  SELECT * INTO _receipt FROM public.inventory_adjustments WHERE source_invoice_item_id = '7a100000-0000-4000-8000-000000000801';
  PERFORM pg_temp.assert(_receipt.inventory_location_id = _u, 'receipt history names Unassigned');
  PERFORM pg_temp.assert(_receipt.source_type = 'invoice' AND _receipt.reason = 'Invoice received'
    AND _receipt.source_invoice_id = '7a100000-0000-4000-8000-000000000701'
    AND _receipt.idempotency_key = 'invoice-item:7a100000-0000-4000-8000-000000000801', 'receipt provenance preserved');
  PERFORM pg_temp.assert(_receipt.previous_quantity = 100 AND _receipt.new_quantity = 125 AND _receipt.adjustment_amount = 25,
    'receipt snapshots stay organization-total based');
  PERFORM pg_temp.assert(_receipt.created_by = '7a100000-0000-4000-8000-000000000001', 'receipt actor recorded');

  SELECT id INTO _new_item FROM public.inventory_items WHERE product_id = '7a100000-0000-4000-8000-000000000404';
  PERFORM pg_temp.assert(_new_item IS NOT NULL AND pg_temp.total(_new_item) = 1.5, 'new receipt item created with fractional quantity');
  PERFORM pg_temp.assert(pg_temp.qty(_new_item, _u) = 1.5
    AND (SELECT count(*) FROM public.inventory_location_balances WHERE inventory_item_id = _new_item) = 1,
    'new receipt item stock only in Unassigned');
  PERFORM pg_temp.assert((SELECT count(*) FROM public.inventory_price_history WHERE invoice_id = '7a100000-0000-4000-8000-000000000701') = 2,
    'price history still written once per line');
  PERFORM pg_temp.assert((SELECT processing_status FROM public.invoices WHERE id = '7a100000-0000-4000-8000-000000000701') = 'completed', 'invoice completed');
END
$check_receiving$;

-- 16. A repeat post is idempotent: nothing moves.
INSERT INTO phase7a1_snapshots VALUES ('before_repost', pg_temp.inventory_state('7a100000-0000-4000-8000-000000000101'));
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000001');
SELECT pg_temp.assert((public.post_reviewed_invoice('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000601') ->> 'alreadyCompleted')::boolean,
  'repeat posting reports alreadyCompleted');
RESET ROLE;
SELECT pg_temp.assert(pg_temp.inventory_state('7a100000-0000-4000-8000-000000000101') = (SELECT value FROM phase7a1_snapshots WHERE name = 'before_repost'),
  'repeat posting changed nothing');

-- ---------------------------------------------------------------------------------------
-- 18-19, 21-25. More moves: physical to physical, back to Unassigned, refusals, idempotency.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000001');
SELECT public.move_inventory_stock('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501',
  pg_temp.loc('l1'), pg_temp.loc('l3'), 10, 'move-3');
SELECT public.move_inventory_stock('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501',
  pg_temp.loc('l2'), pg_temp.unassigned('7a100000-0000-4000-8000-000000000101'), 5, 'move-4');
-- Fractional moves are exact.
SELECT public.move_inventory_stock('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000502',
  pg_temp.unassigned('7a100000-0000-4000-8000-000000000101'), pg_temp.loc('l1'), 1.125, 'move-gauze');
INSERT INTO phase7a1_snapshots VALUES ('before_refused_moves', pg_temp.inventory_state('7a100000-0000-4000-8000-000000000101'));

-- Insufficient stock: Away Cart now has 15.
SELECT pg_temp.expect_error(format($$SELECT public.move_inventory_stock('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', %L, %L, 15.5, 'move-short')$$,
  pg_temp.loc('l2'), pg_temp.loc('l1')), 'it cannot go below zero');
SELECT pg_temp.expect_error(format($$SELECT public.move_inventory_stock('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000503', %L, %L, 1, 'move-empty')$$,
  pg_temp.unassigned('7a100000-0000-4000-8000-000000000101'), pg_temp.loc('l1')), 'it cannot go below zero');
SELECT pg_temp.expect_error(format($$SELECT public.move_inventory_stock('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', %L, %L, 0, 'move-zero')$$,
  pg_temp.loc('l2'), pg_temp.loc('l1')), 'Move a quantity greater than zero');
SELECT pg_temp.expect_error(format($$SELECT public.move_inventory_stock('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', %L, %L, -3, 'move-negative')$$,
  pg_temp.loc('l2'), pg_temp.loc('l1')), 'Move a quantity greater than zero');
SELECT pg_temp.expect_error(format($$SELECT public.move_inventory_stock('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', %L, %L, 1, 'move-same')$$,
  pg_temp.loc('l2'), pg_temp.loc('l2')), 'Choose two different locations');
SELECT pg_temp.expect_error(format($$SELECT public.move_inventory_stock('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', %L, %L, 1, '  ')$$,
  pg_temp.loc('l2'), pg_temp.loc('l1')), 'A move request key is required');
-- Cross-organization item, source and destination.
SELECT pg_temp.expect_error(format($$SELECT public.move_inventory_stock('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000505', %L, %L, 1, 'move-foreign-item')$$,
  pg_temp.unassigned('7a100000-0000-4000-8000-000000000101'), pg_temp.loc('l1')), 'Inventory item not found');
SELECT pg_temp.expect_error(format($$SELECT public.move_inventory_stock('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', %L, %L, 1, 'move-foreign-source')$$,
  pg_temp.unassigned('7a100000-0000-4000-8000-000000000102'), pg_temp.loc('l1')), 'Source location not found');
SELECT pg_temp.expect_error(format($$SELECT public.move_inventory_stock('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', %L, %L, 1, 'move-foreign-destination')$$,
  pg_temp.loc('l1'), pg_temp.unassigned('7a100000-0000-4000-8000-000000000102')), 'Destination location not found');

-- 25. Retry with the same key and payload: no second mutation. Same key, other payload: refused.
SELECT pg_temp.assert((public.move_inventory_stock('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501',
  pg_temp.loc('l1'), pg_temp.loc('l3'), 10, 'move-3') ->> 'replayed')::boolean, 'identical retry is replayed');
SELECT pg_temp.expect_error(format($$SELECT public.move_inventory_stock('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', %L, %L, 11, 'move-3')$$,
  pg_temp.loc('l1'), pg_temp.loc('l3')), 'already used for a different move');

-- Staff, admin and a foreign owner cannot move stock.
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000003');
SELECT pg_temp.expect_error(format($$SELECT public.move_inventory_stock('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', %L, %L, 1, 'move-staff')$$,
  pg_temp.loc('l1'), pg_temp.loc('l2')), 'Forbidden: owner access required');
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000002');
SELECT pg_temp.expect_error(format($$SELECT public.move_inventory_stock('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', %L, %L, 1, 'move-admin')$$,
  pg_temp.loc('l1'), pg_temp.loc('l2')), 'Forbidden: owner access required');
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000004');
SELECT pg_temp.expect_error(format($$SELECT public.move_inventory_stock('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', %L, %L, 1, 'move-foreign-owner')$$,
  pg_temp.loc('l1'), pg_temp.loc('l2')), 'Forbidden: owner access required');
RESET ROLE;

DO $check_more_moves$
DECLARE
  _u uuid := pg_temp.unassigned('7a100000-0000-4000-8000-000000000101');
BEGIN
  PERFORM pg_temp.assert(pg_temp.inventory_state('7a100000-0000-4000-8000-000000000101')
    = (SELECT value FROM phase7a1_snapshots WHERE name = 'before_refused_moves'), 'refused moves and replays changed nothing');
  PERFORM pg_temp.assert(pg_temp.qty('7a100000-0000-4000-8000-000000000501', pg_temp.loc('l1')) = 50, 'Training Room 50');
  PERFORM pg_temp.assert(pg_temp.qty('7a100000-0000-4000-8000-000000000501', pg_temp.loc('l2')) = 15, 'Away Cart 15');
  PERFORM pg_temp.assert(pg_temp.qty('7a100000-0000-4000-8000-000000000501', pg_temp.loc('l3')) = 10, 'Academy 10 (three physical locations)');
  PERFORM pg_temp.assert(pg_temp.qty('7a100000-0000-4000-8000-000000000501', _u) = 50, 'Unassigned 50');
  PERFORM pg_temp.assert(pg_temp.total('7a100000-0000-4000-8000-000000000501') = 125, 'total still 125');
  PERFORM pg_temp.assert(pg_temp.qty('7a100000-0000-4000-8000-000000000502', _u) = 1.625
    AND pg_temp.qty('7a100000-0000-4000-8000-000000000502', pg_temp.loc('l1')) = 1.125
    AND pg_temp.total('7a100000-0000-4000-8000-000000000502') = 2.75, 'fractional move exact');
  PERFORM pg_temp.assert((SELECT count(*) FROM public.inventory_transfers WHERE idempotency_key = 'move-3') = 1, 'replay wrote no second transfer');
END
$check_more_moves$;

-- ---------------------------------------------------------------------------------------
-- 26-27 and amendment 1. Manual adjustment: the deployed four-argument call adjusts
-- Unassigned; the location-aware call changes only the chosen location.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000001');
SELECT pg_temp.assert(public.adjust_inventory_quantity('7a100000-0000-4000-8000-000000000101',
  '7a100000-0000-4000-8000-000000000501', 3, 'Manual adjustment') = 128, 'four-argument call returns the new organization total');
-- Named-argument form, exactly as the deployed app calls it through PostgREST.
SELECT pg_temp.assert(public.adjust_inventory_quantity(_organization_id => '7a100000-0000-4000-8000-000000000101',
  _inventory_item_id => '7a100000-0000-4000-8000-000000000501', _adjustment_amount => -1, _reason => 'Damaged') = 127,
  'named four-argument call still resolves');
SELECT pg_temp.expect_error($$SELECT public.adjust_inventory_quantity('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', -500, 'Correction')$$,
  'Quantity cannot be negative');
-- Total is 127 but Unassigned holds 52: the compatibility call never borrows from shelves.
SELECT pg_temp.expect_error($$SELECT public.adjust_inventory_quantity('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', -60, 'Correction')$$,
  'Unassigned has only 52');
SELECT pg_temp.expect_error($$SELECT public.adjust_inventory_quantity('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', 1, 'Stolen')$$,
  'Invalid adjustment reason');

-- Location-aware adjustment.
INSERT INTO phase7a1_snapshots VALUES ('adjust_l1', public.adjust_inventory_location_quantity('7a100000-0000-4000-8000-000000000101',
  '7a100000-0000-4000-8000-000000000501', pg_temp.loc('l1'), -2.5, 'Damaged'));
SELECT pg_temp.expect_error(format($$SELECT public.adjust_inventory_location_quantity('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', %L, -48, 'Correction')$$,
  pg_temp.loc('l1')), 'Training Room Cabinet A has only 47.5');
SELECT pg_temp.expect_error(format($$SELECT public.adjust_inventory_location_quantity('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', %L, 0, 'Correction')$$,
  pg_temp.loc('l1')), 'Enter a non-zero adjustment');
SELECT pg_temp.expect_error(format($$SELECT public.adjust_inventory_location_quantity('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', %L, 1, 'Invoice received')$$,
  pg_temp.loc('l1')), 'Invalid adjustment reason');
SELECT pg_temp.expect_error($$SELECT public.adjust_inventory_location_quantity('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', NULL, 1, 'Correction')$$,
  'Choose an inventory location');
SELECT pg_temp.expect_error(format($$SELECT public.adjust_inventory_location_quantity('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', %L, 1, 'Correction')$$,
  pg_temp.unassigned('7a100000-0000-4000-8000-000000000102')), 'Inventory location not found');
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000003');
SELECT pg_temp.expect_error($$SELECT public.adjust_inventory_quantity('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', 1, 'Correction')$$,
  'Forbidden: owner access required');
SELECT pg_temp.expect_error(format($$SELECT public.adjust_inventory_location_quantity('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', %L, 1, 'Correction')$$,
  pg_temp.loc('l1')), 'Forbidden: owner access required');
RESET ROLE;

DO $check_adjustments$
DECLARE
  _u uuid := pg_temp.unassigned('7a100000-0000-4000-8000-000000000101');
  _row public.inventory_adjustments%ROWTYPE;
BEGIN
  PERFORM pg_temp.assert(pg_temp.qty('7a100000-0000-4000-8000-000000000501', _u) = 52, 'compatibility adjustments changed Unassigned (50 + 3 - 1)');
  PERFORM pg_temp.assert(pg_temp.qty('7a100000-0000-4000-8000-000000000501', pg_temp.loc('l1')) = 47.5, 'location adjustment changed only Training Room');
  PERFORM pg_temp.assert(pg_temp.qty('7a100000-0000-4000-8000-000000000501', pg_temp.loc('l2')) = 15
    AND pg_temp.qty('7a100000-0000-4000-8000-000000000501', pg_temp.loc('l3')) = 10, 'other locations untouched');
  PERFORM pg_temp.assert(pg_temp.total('7a100000-0000-4000-8000-000000000501') = 124.5, 'total moved by the same delta');
  PERFORM pg_temp.assert((SELECT value ->> 'locationQuantity' FROM phase7a1_snapshots WHERE name = 'adjust_l1')::numeric = 47.5, 'location adjust returns location quantity');

  SELECT * INTO _row FROM public.inventory_adjustments
  WHERE inventory_item_id = '7a100000-0000-4000-8000-000000000501' AND reason = 'Manual adjustment';
  PERFORM pg_temp.assert(_row.inventory_location_id = _u AND _row.source_type = 'manual'
    AND _row.previous_quantity = 125 AND _row.new_quantity = 128, 'compatibility adjustment history');
  SELECT * INTO _row FROM public.inventory_adjustments
  WHERE inventory_item_id = '7a100000-0000-4000-8000-000000000501' AND adjustment_amount = -2.5;
  PERFORM pg_temp.assert(_row.inventory_location_id = pg_temp.loc('l1') AND _row.reason = 'Damaged'
    AND _row.created_by = '7a100000-0000-4000-8000-000000000001', 'location adjustment history');
END
$check_adjustments$;

-- ---------------------------------------------------------------------------------------
-- Amendment 2. Legacy receive_invoice_inventory_item: owner only, never PUBLIC/anon,
-- receives into Unassigned through the canonical mutation.
-- ---------------------------------------------------------------------------------------
SELECT pg_temp.assert(NOT has_function_privilege('anon', 'public.receive_invoice_inventory_item(uuid, text, text, text, numeric, text, text, numeric)', 'EXECUTE'),
  'anon cannot execute legacy receive');
SELECT pg_temp.assert(NOT EXISTS (
  SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
  WHERE p.oid = 'public.receive_invoice_inventory_item(uuid, text, text, text, numeric, text, text, numeric)'::regprocedure
    AND acl.grantee = 0 AND acl.privilege_type = 'EXECUTE'), 'PUBLIC cannot execute legacy receive');
INSERT INTO phase7a1_snapshots VALUES ('before_legacy', pg_temp.inventory_state('7a100000-0000-4000-8000-000000000101'));
SET LOCAL ROLE anon;
SELECT pg_temp.expect_error($$SELECT * FROM public.receive_invoice_inventory_item('7a100000-0000-4000-8000-000000000101', 'TAPE-1', 'Phase 7A.1 Athletic Tape', 'Phase 7A.1 Vendor', 5, 'roll', NULL, 1)$$,
  'permission denied');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000003');
SELECT pg_temp.expect_error($$SELECT * FROM public.receive_invoice_inventory_item('7a100000-0000-4000-8000-000000000101', 'TAPE-1', 'Phase 7A.1 Athletic Tape', 'Phase 7A.1 Vendor', 5, 'roll', NULL, 1)$$,
  'Forbidden: owner access required');
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000002');
SELECT pg_temp.expect_error($$SELECT * FROM public.receive_invoice_inventory_item('7a100000-0000-4000-8000-000000000101', 'TAPE-1', 'Phase 7A.1 Athletic Tape', 'Phase 7A.1 Vendor', 5, 'roll', NULL, 1)$$,
  'Forbidden: owner access required');
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000004');
SELECT pg_temp.expect_error($$SELECT * FROM public.receive_invoice_inventory_item('7a100000-0000-4000-8000-000000000101', 'TAPE-1', 'Phase 7A.1 Athletic Tape', 'Phase 7A.1 Vendor', 5, 'roll', NULL, 1)$$,
  'Forbidden: owner access required');
RESET ROLE;
SELECT pg_temp.assert(pg_temp.inventory_state('7a100000-0000-4000-8000-000000000101') = (SELECT value FROM phase7a1_snapshots WHERE name = 'before_legacy'),
  'refused legacy receives changed nothing');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000001');
SELECT pg_temp.assert(NOT (SELECT created FROM public.receive_invoice_inventory_item('7a100000-0000-4000-8000-000000000101', 'TAPE-1', 'Phase 7A.1 Athletic Tape', 'Phase 7A.1 Vendor', 5, 'roll', NULL, 1)),
  'owner legacy receive matches the existing item');
INSERT INTO phase7a1_snapshots
SELECT 'legacy_new', to_jsonb(inventory_item_id) FROM public.receive_invoice_inventory_item('7a100000-0000-4000-8000-000000000101', NULL, 'Phase 7A.1 Legacy Splint', NULL, 2.5, 'each', NULL, 9);
RESET ROLE;
DO $check_legacy$
DECLARE
  _u uuid := pg_temp.unassigned('7a100000-0000-4000-8000-000000000101');
  _new uuid := (SELECT (value #>> '{}')::uuid FROM phase7a1_snapshots WHERE name = 'legacy_new');
BEGIN
  PERFORM pg_temp.assert(pg_temp.qty('7a100000-0000-4000-8000-000000000501', _u) = 57 AND pg_temp.total('7a100000-0000-4000-8000-000000000501') = 129.5,
    'legacy receive lands in Unassigned');
  PERFORM pg_temp.assert(pg_temp.total(_new) = 2.5 AND pg_temp.qty(_new, _u) = 2.5, 'legacy new item lands in Unassigned');
  PERFORM pg_temp.assert((SELECT count(*) FROM public.inventory_adjustments WHERE inventory_item_id = _new
    AND inventory_location_id = _u AND adjustment_amount = 2.5 AND previous_quantity = 0 AND reason = 'Invoice received') = 1,
    'legacy new item history');
END
$check_legacy$;

-- ---------------------------------------------------------------------------------------
-- Amendment 3. Direct writes cannot drift the models.
-- ---------------------------------------------------------------------------------------
INSERT INTO phase7a1_snapshots VALUES ('before_direct', pg_temp.inventory_state('7a100000-0000-4000-8000-000000000101'));
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000001');
SELECT pg_temp.expect_error($$UPDATE public.inventory_items SET quantity = 999 WHERE id = '7a100000-0000-4000-8000-000000000501'$$,
  'Inventory quantity can only change through an inventory location mutation');
SELECT pg_temp.expect_error($$INSERT INTO public.inventory_items (organization_id, name, unit, quantity) VALUES ('7a100000-0000-4000-8000-000000000101', 'Phase 7A.1 Smuggled', 'each', 5)$$,
  'New inventory items start at zero');
SELECT pg_temp.expect_error($$UPDATE public.inventory_location_balances SET quantity = 999 WHERE inventory_item_id = '7a100000-0000-4000-8000-000000000501'$$,
  'permission denied');
SELECT pg_temp.expect_error(format($$INSERT INTO public.inventory_location_balances (organization_id, inventory_item_id, inventory_location_id, quantity) VALUES ('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000503', %L, 5)$$,
  pg_temp.loc('l4')), 'permission denied');
SELECT pg_temp.expect_error($$DELETE FROM public.inventory_location_balances WHERE inventory_item_id = '7a100000-0000-4000-8000-000000000501'$$,
  'permission denied');
SELECT pg_temp.expect_error($$INSERT INTO public.inventory_transfers (organization_id, inventory_item_id, from_inventory_location_id, to_inventory_location_id, quantity, idempotency_key, created_by) VALUES ('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', '7a100000-0000-4000-8000-000000000501', '7a100000-0000-4000-8000-000000000502', 1, 'x', '7a100000-0000-4000-8000-000000000001')$$,
  'permission denied');
SELECT pg_temp.expect_error($$INSERT INTO public.inventory_adjustments (organization_id, inventory_item_id, adjustment_amount, previous_quantity, new_quantity, reason, created_by) VALUES ('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', 1, 0, 1, 'Correction', '7a100000-0000-4000-8000-000000000001')$$,
  'permission denied');
-- The internal primitives are not client-executable.
SELECT pg_temp.expect_error(format($$SELECT public.inventory_apply_balance_delta('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', %L, 5)$$, pg_temp.loc('l1')),
  'permission denied');
SELECT pg_temp.expect_error(format($$SELECT public.apply_inventory_location_delta('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', %L, 5, 'Correction', 'manual')$$, pg_temp.loc('l1')),
  'permission denied');
-- Non-quantity edits by the owner still work (item edit dialog), and catalog-style zero inserts
-- seed a zero Unassigned balance through the canonical seeding trigger.
UPDATE public.inventory_items SET par_level = 12 WHERE id = '7a100000-0000-4000-8000-000000000501';
INSERT INTO public.inventory_items (id, organization_id, name, unit, quantity)
VALUES ('7a100000-0000-4000-8000-000000000506', '7a100000-0000-4000-8000-000000000101', 'Phase 7A.1 Owner Created', 'each', 0);
-- Owners read only their own organization's location data; staff and admin read none.
SELECT pg_temp.assert((SELECT count(*) FROM public.inventory_locations) = 5, 'owner A sees exactly A locations');
SELECT pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.inventory_location_balances WHERE organization_id <> '7a100000-0000-4000-8000-000000000101'), 'owner A sees no foreign balances');
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000003');
SELECT pg_temp.assert((SELECT count(*) FROM public.inventory_locations) = 0
  AND (SELECT count(*) FROM public.inventory_location_balances) = 0
  AND (SELECT count(*) FROM public.inventory_transfers) = 0, 'staff reads no location data');
-- Staff has no inventory update policy: a direct write matches no rows (checked below).
UPDATE public.inventory_items SET quantity = 1 WHERE id = '7a100000-0000-4000-8000-000000000501';
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000002');
SELECT pg_temp.assert((SELECT count(*) FROM public.inventory_location_balances) = 0, 'admin reads no balances (inventory is owner-only)');
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000004');
SELECT pg_temp.assert((SELECT count(*) FROM public.inventory_locations) = 1, 'owner B sees only B Unassigned');
RESET ROLE;

-- Even the database owner cannot write a balance or a summary without the primitive.
SELECT pg_temp.expect_error($$UPDATE public.inventory_location_balances SET quantity = 1 WHERE inventory_item_id = '7a100000-0000-4000-8000-000000000501'$$,
  'Inventory location balances can only change through an inventory location mutation');
SELECT pg_temp.expect_error($$UPDATE public.inventory_items SET quantity = 1 WHERE id = '7a100000-0000-4000-8000-000000000501'$$,
  'Inventory quantity can only change through an inventory location mutation');

-- 11 (amendment). A transaction that drifts the models fails as a whole: the deferred check
-- aborts it and every earlier write in it is undone.
DO $check_invariant_rollback$
BEGIN
  BEGIN
    UPDATE public.inventory_items SET name = 'Phase 7A.1 Drift Attempt' WHERE id = '7a100000-0000-4000-8000-000000000502';
    PERFORM set_config('medspend.inventory_sync', 'on', true);
    UPDATE public.inventory_items SET quantity = quantity + 1 WHERE id = '7a100000-0000-4000-8000-000000000502';
    PERFORM set_config('medspend.inventory_sync', 'off', true);
    SET CONSTRAINTS public.inventory_items_balance_invariant IMMEDIATE;
    RAISE EXCEPTION 'drift was not detected';
  EXCEPTION WHEN check_violation THEN
    IF position('Inventory invariant violated' IN SQLERRM) = 0 THEN RAISE; END IF;
  END;
  SET CONSTRAINTS public.inventory_items_balance_invariant DEFERRED;
  PERFORM pg_temp.assert((SELECT name FROM public.inventory_items WHERE id = '7a100000-0000-4000-8000-000000000502') = 'Phase 7A.1 Gauze',
    'earlier write in the failed unit was rolled back');
  PERFORM pg_temp.assert(pg_temp.total('7a100000-0000-4000-8000-000000000502') = 2.75, 'drifted quantity rolled back');
END
$check_invariant_rollback$;

DO $check_direct$
DECLARE
  _before jsonb := (SELECT value FROM phase7a1_snapshots WHERE name = 'before_direct');
  _after jsonb := pg_temp.inventory_state('7a100000-0000-4000-8000-000000000101');
BEGIN
  PERFORM pg_temp.assert(pg_temp.qty('7a100000-0000-4000-8000-000000000506', pg_temp.unassigned('7a100000-0000-4000-8000-000000000101')) = 0,
    'owner-created zero item seeded a zero Unassigned balance');
  PERFORM pg_temp.assert((_after -> 'adjustments') = (_before -> 'adjustments') AND (_after -> 'transfers') = (_before -> 'transfers'),
    'refused direct writes left no history');
  PERFORM pg_temp.assert(pg_temp.total('7a100000-0000-4000-8000-000000000501') = 129.5, 'direct writes did not change the tape total');
END
$check_direct$;

-- ---------------------------------------------------------------------------------------
-- 11, 13. Archive rules cannot strand stock.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000001');
SELECT pg_temp.expect_error(format($$SELECT public.set_inventory_location_active('7a100000-0000-4000-8000-000000000101', %L, false)$$, pg_temp.loc('l3')),
  'Move all stock out of Academy Supply Room before archiving it');
SELECT public.move_inventory_stock('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501',
  pg_temp.loc('l3'), pg_temp.unassigned('7a100000-0000-4000-8000-000000000101'), 10, 'move-empty-academy');
SELECT public.set_inventory_location_active('7a100000-0000-4000-8000-000000000101', pg_temp.loc('l3'), false);
SELECT public.set_inventory_location_active('7a100000-0000-4000-8000-000000000101', pg_temp.loc('l4'), false);
SELECT pg_temp.expect_error(format($$SELECT public.move_inventory_stock('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', %L, %L, 1, 'move-to-archived')$$,
  pg_temp.loc('l1'), pg_temp.loc('l3')), 'Academy Supply Room is archived and cannot receive stock');
SELECT pg_temp.expect_error(format($$SELECT public.adjust_inventory_location_quantity('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', %L, 1, 'Correction')$$,
  pg_temp.loc('l3')), 'Academy Supply Room is archived and cannot receive stock');
SELECT public.set_inventory_location_active('7a100000-0000-4000-8000-000000000101', pg_temp.loc('l3'), true);
RESET ROLE;
SELECT pg_temp.assert((SELECT active FROM public.inventory_locations WHERE id = pg_temp.loc('l3')), 'restored location is active');
SELECT pg_temp.assert(NOT (SELECT active FROM public.inventory_locations WHERE id = pg_temp.loc('l4')), 'empty location archived');
-- Archiving below the RPC is guarded by the trigger as well.
SELECT pg_temp.expect_error(format($$UPDATE public.inventory_locations SET active = false WHERE id = %L$$, pg_temp.loc('l1')),
  'Move all stock out of Training Room Cabinet A before archiving it');

-- ---------------------------------------------------------------------------------------
-- 28-31, I, J. Invoice deletion.
-- ---------------------------------------------------------------------------------------
-- Post invoice 702 (5 tape) and 703 (1.25 gauze) so there are receipts to delete.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000001');
SELECT public.post_reviewed_invoice('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000602');
SELECT public.post_reviewed_invoice('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000603');
RESET ROLE;
SELECT pg_temp.assert(pg_temp.total('7a100000-0000-4000-8000-000000000501') = 134.5
  AND pg_temp.qty('7a100000-0000-4000-8000-000000000501', pg_temp.unassigned('7a100000-0000-4000-8000-000000000101')) = 72,
  'second receipt in Unassigned (57 + 10 back from Academy + 5)');

-- I. Move nearly all Unassigned tape to a shelf; deleting the 5-roll invoice now needs 3
-- back in Unassigned and says so. Nothing changes.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000001');
SELECT public.move_inventory_stock('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501',
  pg_temp.unassigned('7a100000-0000-4000-8000-000000000101'), pg_temp.loc('l3'), 70, 'move-drain-unassigned');
RESET ROLE;
INSERT INTO phase7a1_snapshots VALUES ('before_short_delete', pg_temp.inventory_state('7a100000-0000-4000-8000-000000000101'));
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000001');
SELECT pg_temp.expect_error($$SELECT public.delete_invoice_permanently('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000602')$$,
  'Move 3 roll of Phase 7A.1 Athletic Tape back to Unassigned before deleting this invoice.');
RESET ROLE;
SELECT pg_temp.assert(pg_temp.inventory_state('7a100000-0000-4000-8000-000000000101') = (SELECT value FROM phase7a1_snapshots WHERE name = 'before_short_delete'),
  'refused deletion changed nothing');
SELECT pg_temp.assert(EXISTS (SELECT 1 FROM public.invoices WHERE id = '7a100000-0000-4000-8000-000000000702'), 'refused deletion kept the invoice');

-- After moving stock back, deletion works and removes the receipt from Unassigned only.
-- A physical count dated before the receipt does not block it.
INSERT INTO public.inventory_adjustments (organization_id, inventory_item_id, inventory_location_id, adjustment_amount,
  previous_quantity, new_quantity, reason, created_by, source_type, created_at)
VALUES ('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', pg_temp.loc('l2'), 0,
  0, 0, 'Correction', '7a100000-0000-4000-8000-000000000001', 'physical_count', now() - interval '1 day');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000001');
SELECT public.move_inventory_stock('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501',
  pg_temp.loc('l3'), pg_temp.unassigned('7a100000-0000-4000-8000-000000000101'), 3, 'move-refill-unassigned');
INSERT INTO phase7a1_snapshots VALUES ('delete_702', public.delete_invoice_permanently('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000602'));
RESET ROLE;
DO $check_delete$
DECLARE
  _u uuid := pg_temp.unassigned('7a100000-0000-4000-8000-000000000101');
BEGIN
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.invoices WHERE id = '7a100000-0000-4000-8000-000000000702'), 'invoice deleted');
  PERFORM pg_temp.assert(pg_temp.total('7a100000-0000-4000-8000-000000000501') = 129.5, 'total back to 129.5');
  PERFORM pg_temp.assert(pg_temp.qty('7a100000-0000-4000-8000-000000000501', _u) = 0, 'receipt removed from Unassigned (5 - 5)');
  PERFORM pg_temp.assert(pg_temp.qty('7a100000-0000-4000-8000-000000000501', pg_temp.loc('l1')) = 47.5
    AND pg_temp.qty('7a100000-0000-4000-8000-000000000501', pg_temp.loc('l2')) = 15
    AND pg_temp.qty('7a100000-0000-4000-8000-000000000501', pg_temp.loc('l3')) = 67, 'shelves untouched by deletion');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.inventory_adjustments WHERE source_invoice_id = '7a100000-0000-4000-8000-000000000702'),
    'deleted invoice receipt rows removed');
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM public.inventory_adjustments WHERE source_invoice_id = '7a100000-0000-4000-8000-000000000701'),
    'other invoice receipts untouched');
END
$check_delete$;

-- J. A physical count at any location after the receipt blocks deleting that invoice.
INSERT INTO public.inventory_adjustments (organization_id, inventory_item_id, inventory_location_id, adjustment_amount,
  previous_quantity, new_quantity, reason, created_by, source_type)
VALUES ('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000502', pg_temp.loc('l1'), 0,
  4, 4, 'Correction', '7a100000-0000-4000-8000-000000000001', 'physical_count');
INSERT INTO phase7a1_snapshots VALUES ('before_checkpoint_delete', pg_temp.inventory_state('7a100000-0000-4000-8000-000000000101'));
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000001');
SELECT pg_temp.expect_error($$SELECT public.delete_invoice_permanently('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000603')$$,
  'This invoice cannot be deleted because Phase 7A.1 Gauze was physically counted after it was received.');
RESET ROLE;
SELECT pg_temp.assert(pg_temp.inventory_state('7a100000-0000-4000-8000-000000000101') = (SELECT value FROM phase7a1_snapshots WHERE name = 'before_checkpoint_delete'),
  'checkpoint-blocked deletion changed nothing');

-- Grants on the destructive deletion function: authenticated only, never anon or PUBLIC.
SELECT pg_temp.assert(has_function_privilege('authenticated', 'public.delete_invoice_permanently(uuid, uuid)', 'EXECUTE'),
  'authenticated retains EXECUTE on delete_invoice_permanently');
SELECT pg_temp.assert(NOT has_function_privilege('anon', 'public.delete_invoice_permanently(uuid, uuid)', 'EXECUTE'),
  'anon cannot EXECUTE delete_invoice_permanently');
SELECT pg_temp.assert(NOT EXISTS (
  SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
  WHERE p.oid = 'public.delete_invoice_permanently(uuid, uuid)'::regprocedure
    AND acl.grantee = 0 AND acl.privilege_type = 'EXECUTE'), 'PUBLIC cannot EXECUTE delete_invoice_permanently');
INSERT INTO phase7a1_snapshots VALUES ('before_refused_deletes', pg_temp.inventory_state('7a100000-0000-4000-8000-000000000101'));
SET LOCAL ROLE anon;
SELECT pg_temp.expect_error($$SELECT public.delete_invoice_permanently('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000601')$$,
  'permission denied for function delete_invoice_permanently');
RESET ROLE;

-- Authenticated non-owners (staff, admin, another organization's owner) are still refused
-- by the function's own owner check, and nothing changes.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000003');
SELECT pg_temp.expect_error($$SELECT public.delete_invoice_permanently('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000601')$$,
  'Forbidden: owner access required');
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000002');
SELECT pg_temp.expect_error($$SELECT public.delete_invoice_permanently('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000601')$$,
  'Forbidden: owner access required');
SELECT pg_temp.as_user('7a100000-0000-4000-8000-000000000004');
SELECT pg_temp.expect_error($$SELECT public.delete_invoice_permanently('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000601')$$,
  'Forbidden: owner access required');
RESET ROLE;
SELECT pg_temp.assert(pg_temp.inventory_state('7a100000-0000-4000-8000-000000000101') = (SELECT value FROM phase7a1_snapshots WHERE name = 'before_refused_deletes')
  AND EXISTS (SELECT 1 FROM public.invoices WHERE id = '7a100000-0000-4000-8000-000000000701'), 'refused deletions changed nothing');

-- ---------------------------------------------------------------------------------------
-- 5, 10. Tenant isolation: organization B is untouched by everything above.
-- ---------------------------------------------------------------------------------------
SELECT pg_temp.assert(pg_temp.inventory_state('7a100000-0000-4000-8000-000000000102') = (SELECT value FROM phase7a1_snapshots WHERE name = 'org_b_start'),
  'organization B inventory unchanged');
-- Composite keys reject a balance that pairs an item with another organization's location.
SELECT pg_temp.expect_error(format($$
  DO $x$ BEGIN
    PERFORM set_config('medspend.inventory_sync', 'on', true);
    INSERT INTO public.inventory_location_balances (organization_id, inventory_item_id, inventory_location_id, quantity)
    VALUES ('7a100000-0000-4000-8000-000000000101', '7a100000-0000-4000-8000-000000000501', %L, 0);
  END $x$
$$, pg_temp.unassigned('7a100000-0000-4000-8000-000000000102')), 'violates foreign key constraint');

-- ---------------------------------------------------------------------------------------
-- Final: evaluate every pending deferred invariant check, then a global proof.
-- ---------------------------------------------------------------------------------------
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.assert(NOT EXISTS (
  SELECT 1 FROM public.inventory_items item
  WHERE item.quantity <> coalesce((SELECT sum(b.quantity) FROM public.inventory_location_balances b WHERE b.inventory_item_id = item.id), -1)
), 'every item equals the sum of its location balances');
SELECT pg_temp.assert(NOT EXISTS (
  SELECT 1 FROM public.organizations o
  WHERE (SELECT count(*) FROM public.inventory_locations l WHERE l.organization_id = o.id AND l.kind = 'unassigned') <> 1
), 'every organization has exactly one Unassigned');

SELECT 'phase7a1_location_aware_inventory_behavior: all checks passed' AS result;

ROLLBACK;
