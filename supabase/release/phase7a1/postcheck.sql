-- Phase 7A.1 production postcheck. Run AFTER the migration and BEFORE the application
-- deploy. Read-only; rolled back.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F ' | ' \
--     -f supabase/release/phase7a1/postcheck.sql > phase7a1_post.txt
--   diff phase7a1_pre.txt phase7a1_post.txt
--
-- The only expected fingerprint differences are listed in README.md. In particular the
-- inventory item quantity hash, organization totals hash and adjustment hash must be
-- identical: the migration changes no quantity and writes or removes no history.
--
-- If the old application served traffic between the migration and this check, receipts or
-- adjustments may legitimately have been added; the invariant assertions below still must
-- pass, and new history rows must all name a location.

BEGIN READ ONLY;

SELECT 'postcheck_at' AS section, now()::text AS value;

DO $phase7a1_postcheck$
DECLARE
  _bad bigint;
  _mismatch text;
BEGIN
  IF to_regclass('public.inventory_locations') IS NULL
     OR to_regclass('public.inventory_location_balances') IS NULL
     OR to_regclass('public.inventory_transfers') IS NULL THEN
    RAISE EXCEPTION 'postcheck: Phase 7A.1 tables are missing';
  END IF;

  -- The invariant: every item equals the sum of its location balances.
  SELECT count(*) INTO _bad FROM public.inventory_items item
  WHERE item.quantity <> coalesce((SELECT sum(b.quantity) FROM public.inventory_location_balances b
                                   WHERE b.inventory_item_id = item.id), -1);
  IF _bad <> 0 THEN RAISE EXCEPTION 'postcheck: % items differ from their location balances', _bad; END IF;

  -- Every balance belongs to its item's organization and its location's organization.
  SELECT count(*) INTO _bad FROM public.inventory_location_balances b
  JOIN public.inventory_items i ON i.id = b.inventory_item_id
  JOIN public.inventory_locations l ON l.id = b.inventory_location_id
  WHERE i.organization_id <> b.organization_id OR l.organization_id <> b.organization_id;
  IF _bad <> 0 THEN RAISE EXCEPTION 'postcheck: % balances cross organizations', _bad; END IF;

  -- Exactly one protected Unassigned per organization, active.
  SELECT count(*) INTO _bad FROM public.organizations o
  WHERE (SELECT count(*) FROM public.inventory_locations l
         WHERE l.organization_id = o.id AND l.kind = 'unassigned' AND l.active) <> 1;
  IF _bad <> 0 THEN RAISE EXCEPTION 'postcheck: % organizations lack exactly one Unassigned', _bad; END IF;

  -- Before the app deploys, no physical location, transfer or non-Unassigned stock exists.
  IF EXISTS (SELECT 1 FROM public.inventory_locations WHERE kind <> 'unassigned') THEN
    RAISE EXCEPTION 'postcheck: physical locations exist before the application deploy';
  END IF;
  IF EXISTS (SELECT 1 FROM public.inventory_transfers) THEN
    RAISE EXCEPTION 'postcheck: transfers exist before the application deploy';
  END IF;
  -- Historical adjustments keep a NULL location; anything written since names Unassigned.
  IF EXISTS (SELECT 1 FROM public.inventory_adjustments a JOIN public.inventory_locations l
             ON l.id = a.inventory_location_id WHERE l.kind <> 'unassigned') THEN
    RAISE EXCEPTION 'postcheck: adjustments name a non-Unassigned location';
  END IF;

  -- Replaced and new functions carry the reviewed bodies.
  FOR _mismatch IN
    SELECT format('%s=%s', expected.name, coalesce((
      SELECT string_agg(md5(pg_get_functiondef(p.oid)), ',') FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = expected.name), 'absent'))
    FROM (VALUES
      ('adjust_inventory_location_quantity', 'dac472b1d11b6f94b6315c873c0bfba6'),
      ('adjust_inventory_quantity', 'e9e178ef7fa6dc4e50441b40adc8e1e9'),
      ('apply_inventory_location_delta', 'cad102e48b8e69213e773746fae9723a'),
      ('create_inventory_location', '3662f48a85020f72885b7ea6a48a58d2'),
      ('delete_invoice_permanently', 'ac77d1b05aa44675b295936021189673'),
      ('ensure_inventory_unassigned_location', '71fbdd1a6d3d7a0681bf0148eea30bc7'),
      ('inventory_apply_balance_delta', '83513cd3324f6045147a855bec061b64'),
      ('move_inventory_stock', '70b42f11b495fbdc9a6f06482afabf03'),
      ('post_reviewed_invoice', '4d0240ce910eb2f583a8b79706c7f8e8'),
      ('receive_invoice_inventory_item', 'c843e23a4f8b8c432f26acb5dc885570'),
      ('set_inventory_location_active', 'dd1a39beb2413d5fb5d2d24118d10970'),
      ('stock_catalog_vendor_product', '9b1f4ee7e540f8d297bf6b9ce586e2ca'),
      ('update_inventory_location', 'f1984811549d0f777b985e5a8a4b220b')
    ) AS expected(name, md5)
    WHERE (
      SELECT string_agg(md5(pg_get_functiondef(p.oid)), ',') FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = expected.name
    ) IS DISTINCT FROM expected.md5
  LOOP
    RAISE EXCEPTION 'postcheck: function definition differs from the reviewed migration: %', _mismatch;
  END LOOP;

  -- Grants: internal primitives are not client-executable; RPCs are authenticated-only.
  IF has_function_privilege('authenticated', 'public.inventory_apply_balance_delta(uuid,uuid,uuid,numeric)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.apply_inventory_location_delta(uuid,uuid,uuid,numeric,text,text,uuid,uuid,text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.ensure_inventory_unassigned_location(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'postcheck: an internal inventory primitive is client-executable';
  END IF;
  IF has_function_privilege('anon', 'public.receive_invoice_inventory_item(uuid,text,text,text,numeric,text,text,numeric)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.adjust_inventory_quantity(uuid,uuid,numeric,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.move_inventory_stock(uuid,uuid,uuid,uuid,numeric,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.adjust_inventory_quantity(uuid,uuid,numeric,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.move_inventory_stock(uuid,uuid,uuid,uuid,numeric,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'postcheck: inventory RPC grants are wrong';
  END IF;
  IF has_table_privilege('authenticated', 'public.inventory_location_balances', 'INSERT')
     OR has_table_privilege('authenticated', 'public.inventory_location_balances', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.inventory_location_balances', 'DELETE')
     OR has_table_privilege('authenticated', 'public.inventory_locations', 'INSERT')
     OR has_table_privilege('authenticated', 'public.inventory_transfers', 'INSERT')
     OR has_table_privilege('authenticated', 'public.inventory_adjustments', 'INSERT')
     OR has_table_privilege('anon', 'public.inventory_adjustments', 'INSERT')
     OR has_table_privilege('service_role', 'public.inventory_location_balances', 'UPDATE')
     OR has_table_privilege('service_role', 'public.inventory_location_balances', 'INSERT')
     OR has_table_privilege('service_role', 'public.inventory_transfers', 'INSERT')
     OR has_table_privilege('anon', 'public.inventory_location_balances', 'SELECT') THEN
    RAISE EXCEPTION 'postcheck: direct inventory write grants exist';
  END IF;

  -- The compatibility signature is still the only adjust_inventory_quantity.
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = 'adjust_inventory_quantity') <> 1
     OR to_regprocedure('public.adjust_inventory_quantity(uuid,uuid,numeric,text)') IS NULL THEN
    RAISE EXCEPTION 'postcheck: adjust_inventory_quantity signature changed';
  END IF;

  -- The deferred invariant triggers are installed.
  IF (SELECT count(*) FROM pg_trigger WHERE tgname IN ('inventory_items_balance_invariant', 'inventory_location_balances_invariant')
      AND tgdeferrable AND tginitdeferred) <> 2 THEN
    RAISE EXCEPTION 'postcheck: deferred invariant triggers are missing';
  END IF;
END
$phase7a1_postcheck$;

SELECT 'postcheck' AS section, 'assertions passed' AS value;

SELECT 'org_total' AS section, organization_id::text AS key,
  count(*)::text || ' items, total ' || sum(quantity)::text AS value
FROM public.inventory_items GROUP BY organization_id ORDER BY organization_id;

\ir fingerprint.sql

ROLLBACK;
