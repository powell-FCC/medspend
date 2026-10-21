-- Phase 7A.1 production precheck. Run BEFORE 20261021120000_phase7a1_location_aware_inventory.sql.
-- Read-only: the whole script runs in a READ ONLY transaction and is rolled back.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F ' | ' \
--     -f supabase/release/phase7a1/precheck.sql > phase7a1_pre.txt
--
-- Any failed assertion stops the release: production does not match the schema the
-- migration was reviewed against. Keep phase7a1_pre.txt for the postcheck diff.

BEGIN READ ONLY;

SELECT 'precheck_at' AS section, now()::text AS value;

DO $phase7a1_precheck$
DECLARE
  _mismatch text;
BEGIN
  -- Nothing from 7A.1 exists yet.
  IF to_regclass('public.inventory_locations') IS NOT NULL
     OR to_regclass('public.inventory_location_balances') IS NOT NULL
     OR to_regclass('public.inventory_transfers') IS NOT NULL THEN
    RAISE EXCEPTION 'precheck: Phase 7A.1 tables already exist';
  END IF;
  IF to_regprocedure('public.move_inventory_stock(uuid,uuid,uuid,uuid,numeric,text)') IS NOT NULL
     OR to_regprocedure('public.adjust_inventory_location_quantity(uuid,uuid,uuid,numeric,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'precheck: Phase 7A.1 functions already exist';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
             AND table_name = 'inventory_adjustments' AND column_name = 'inventory_location_id') THEN
    RAISE EXCEPTION 'precheck: inventory_adjustments.inventory_location_id already exists';
  END IF;

  -- The functions 7A.1 replaces, and the stocking function it relies on, match repository
  -- main f8a60fd (md5 of pg_get_functiondef on a database migrated from that commit).
  FOR _mismatch IN
    SELECT format('%s=%s', expected.name, coalesce((
      SELECT string_agg(md5(pg_get_functiondef(p.oid)), ',') FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = expected.name), 'absent'))
    FROM (VALUES
      ('adjust_inventory_quantity', '40e08ac197652155f5c0b8cc371516c9'),
      ('delete_invoice_permanently', '3da61a09e3846b37aef1f87709f6fe1d'),
      ('post_reviewed_invoice', 'f025bfd35a0671281be0f2aadd63808d'),
      ('receive_invoice_inventory_item', '6d4b6d89960ee8be904fa58b9cf3f3d0'),
      ('stock_catalog_vendor_product', '9b1f4ee7e540f8d297bf6b9ce586e2ca')
    ) AS expected(name, md5)
    WHERE (
      SELECT string_agg(md5(pg_get_functiondef(p.oid)), ',') FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = expected.name
    ) IS DISTINCT FROM expected.md5
  LOOP
    RAISE EXCEPTION 'precheck: function definition differs from repository main: %', _mismatch;
  END LOOP;

  IF (SELECT md5(pg_get_constraintdef(oid)) FROM pg_constraint
      WHERE conrelid = 'public.inventory_adjustments'::regclass
        AND conname = 'inventory_adjustments_source_type_check')
     IS DISTINCT FROM '23ad79bed5998eb825f15626737e1838' THEN
    RAISE EXCEPTION 'precheck: inventory_adjustments_source_type_check differs from main';
  END IF;

  -- Data the backfill relies on.
  IF EXISTS (SELECT 1 FROM public.inventory_items WHERE quantity < 0) THEN
    RAISE EXCEPTION 'precheck: negative inventory quantities exist';
  END IF;
  IF to_regclass('public.inventory_items_id_org_uq') IS NULL THEN
    RAISE EXCEPTION 'precheck: inventory_items_id_org_uq (Phase 5A.7) is missing';
  END IF;
END
$phase7a1_precheck$;

SELECT 'precheck' AS section, 'assertions passed' AS value;

-- Per-organization inventory totals, for a human-readable before/after comparison.
SELECT 'org_total' AS section, organization_id::text AS key,
  count(*)::text || ' items, total ' || sum(quantity)::text AS value
FROM public.inventory_items GROUP BY organization_id ORDER BY organization_id;

\ir fingerprint.sql

ROLLBACK;
