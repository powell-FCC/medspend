-- Phase 7A.1 production PRECHECK. Run BEFORE 20261021120000_phase7a1_location_aware_inventory.sql.
--
-- Safe for the Supabase SQL Editor: no psql meta-commands, no transaction control, and no
-- writes (one read-only DO block of assertions, then one SELECT). Paste the whole file and run
-- it once. psql users can run the same file:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F ' | ' -f supabase/release/phase7a1/precheck.sql > phase7a1_pre.txt
--
-- Success: the result grid shows the fingerprint rows (section | key | value), ending with
-- one 'org_total' row per organization that has inventory. Save them (SQL Editor: download
-- as CSV) for the postcheck comparison.
-- STOP: any error. In particular "precheck: Phase 7A.1 tables already exist" means the
-- migration was already applied; do not apply it again.

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

  -- Objects the migration depends on, drops or must not collide with.
  IF to_regclass('public.inventory_items') IS NULL OR to_regclass('public.inventory_adjustments') IS NULL
     OR to_regclass('public.organizations') IS NULL OR to_regclass('public.inventory_items_org_product_uq') IS NULL THEN
    RAISE EXCEPTION 'precheck: an inventory table or index the migration relies on is missing';
  END IF;
  IF to_regprocedure('public.has_org_role(uuid,uuid,public.org_role[])') IS NULL
     OR to_regprocedure('public.tg_set_updated_at()') IS NULL
     OR to_regprocedure('pg_catalog.trim_scale(numeric)') IS NULL THEN
    RAISE EXCEPTION 'precheck: a helper function the migration calls is missing';
  END IF;
  IF (SELECT format_type(atttypid, atttypmod) || ':' || attnotnull FROM pg_attribute
      WHERE attrelid = 'public.inventory_items'::regclass AND attname = 'quantity' AND NOT attisdropped)
     IS DISTINCT FROM 'numeric:true' THEN
    RAISE EXCEPTION 'precheck: inventory_items.quantity is not NOT NULL numeric';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'inventory_adjustments'
                 AND policyname = 'inventory_adjustments_owner_insert') THEN
    RAISE EXCEPTION 'precheck: policy inventory_adjustments_owner_insert (dropped by 7A.1) is missing';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE NOT tgisinternal AND tgname IN (
      'inventory_items_guard_quantity', 'inventory_items_seed_balance', 'inventory_items_balance_invariant',
      'inventory_adjustments_default_location', 'organizations_seed_inventory_unassigned')) THEN
    RAISE EXCEPTION 'precheck: a Phase 7A.1 trigger already exists';
  END IF;
  -- The deployed adjust RPC has exactly the signature the old app calls.
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = 'adjust_inventory_quantity') <> 1
     OR to_regprocedure('public.adjust_inventory_quantity(uuid,uuid,numeric,text)') IS NULL THEN
    RAISE EXCEPTION 'precheck: adjust_inventory_quantity is not the single deployed signature';
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

-- Fingerprint (identical to fingerprint.sql). This must stay the last statement.
SELECT section, key, value FROM (
  -- Functions this phase adds or replaces, and the neighbours it must leave alone:
  -- body hash, SECURITY DEFINER, and who may execute it.
  SELECT 1 AS ord, 'function' AS section, fn.name AS key,
    coalesce((
      SELECT md5(pg_get_functiondef(p.oid)) || ' secdef=' || p.prosecdef
        || ' authenticated=' || has_function_privilege('authenticated', p.oid, 'EXECUTE')
        || ' anon=' || has_function_privilege('anon', p.oid, 'EXECUTE')
        || ' public=' || EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
                                 WHERE acl.grantee = 0 AND acl.privilege_type = 'EXECUTE')
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = fn.name
      ORDER BY p.oid LIMIT 1
    ), 'absent') AS value
  FROM (VALUES
    -- Added by 7A.1.
    ('adjust_inventory_location_quantity'),
    ('apply_inventory_location_delta'),
    ('create_inventory_location'),
    ('ensure_inventory_unassigned_location'),
    ('inventory_apply_balance_delta'),
    ('move_inventory_stock'),
    ('set_inventory_location_active'),
    ('update_inventory_location'),
    -- Replaced by 7A.1.
    ('adjust_inventory_quantity'),
    ('delete_invoice_permanently'),
    ('post_reviewed_invoice'),
    ('receive_invoice_inventory_item'),
    -- Must not change.
    ('stock_catalog_vendor_product'),
    ('rematch_invoice_vendor_products'),
    ('confirm_invoice_item_product'),
    ('match_invoice_item_to_catalog_listing'),
    ('create_product_from_invoice_item'),
    ('search_supply_request_products'),
    ('submit_supply_request'),
    ('replace_supply_request_items'),
    ('resolve_supply_request_item_costs'),
    ('create_supply_request_commitment'),
    ('decide_supply_request'),
    ('get_budget_summary'),
    ('get_budget_purchasing_overview'),
    ('get_supply_request_budget_impact')
  ) AS fn(name)

  -- Overload counts (no second signature left behind; the deployed four-argument
  -- adjust_inventory_quantity must stay the only one).
  UNION ALL
  SELECT 2, 'overloads', fn.name,
    (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = fn.name)::text
  FROM (VALUES ('adjust_inventory_quantity'), ('receive_invoice_inventory_item'),
    ('post_reviewed_invoice'), ('delete_invoice_permanently'), ('move_inventory_stock'),
    ('adjust_inventory_location_quantity')) AS fn(name)

  UNION ALL
  SELECT 3, 'constraint', 'inventory_adjustments_source_type_check',
    coalesce((SELECT md5(pg_get_constraintdef(c.oid)) FROM pg_constraint c
      WHERE c.conrelid = 'public.inventory_adjustments'::regclass
        AND c.conname = 'inventory_adjustments_source_type_check'), 'absent')

  -- Schema object counts in public.
  UNION ALL
  SELECT 4, 'count', 'public functions', count(*)::text
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public'
  UNION ALL
  SELECT 4, 'count', 'public tables', count(*)::text
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
  UNION ALL
  SELECT 4, 'count', 'public indexes', count(*)::text FROM pg_indexes WHERE schemaname = 'public'
  UNION ALL
  SELECT 4, 'count', 'public policies', count(*)::text FROM pg_policies WHERE schemaname = 'public'
  UNION ALL
  SELECT 4, 'count', 'public triggers', count(*)::text
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND NOT t.tgisinternal

  -- Policies, triggers and grants per table: inventory tables change in documented ways;
  -- every other table here must be identical.
  UNION ALL
  SELECT 5, 'policies', t.name,
    coalesce((SELECT md5(string_agg(policyname || ':' || cmd || ':' || coalesce(qual, '') || ':' || coalesce(with_check, ''),
      '|' ORDER BY policyname)) FROM pg_policies WHERE schemaname = 'public' AND tablename = t.name), 'none')
  FROM (VALUES ('inventory_items'), ('inventory_adjustments'), ('inventory_categories'),
    ('inventory_price_history'), ('invoices'), ('invoice_items'), ('vendor_invoices'),
    ('products'), ('vendors'), ('vendor_products'), ('locations'), ('organization_budgets'),
    ('supply_requests'), ('supply_request_items'), ('supply_request_commitments')) AS t(name)
  UNION ALL
  SELECT 6, 'triggers', t.name,
    coalesce((SELECT md5(string_agg(tr.tgname || ':' || pg_get_triggerdef(tr.oid), '|' ORDER BY tr.tgname))
      FROM pg_trigger tr JOIN pg_class c ON c.oid = tr.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relname = t.name AND NOT tr.tgisinternal), 'none')
  FROM (VALUES ('inventory_items'), ('inventory_adjustments'), ('inventory_price_history'),
    ('invoices'), ('invoice_items'), ('organizations'), ('locations'), ('organization_budgets'),
    ('supply_requests'), ('supply_request_items')) AS t(name)
  UNION ALL
  SELECT 7, 'grants', t.name,
    coalesce((SELECT string_agg(grantee || '=' || privilege_type, ',' ORDER BY grantee, privilege_type)
      FROM information_schema.role_table_grants
      WHERE table_schema = 'public' AND table_name = t.name
        AND grantee IN ('anon', 'authenticated', 'service_role')), 'none')
  FROM (VALUES ('inventory_items'), ('inventory_adjustments'), ('inventory_locations'),
    ('inventory_location_balances'), ('inventory_transfers'), ('locations')) AS t(name)

  -- Data. The inventory item hash covers every id, organization and quantity, so an
  -- identical line proves no quantity changed. The adjustment hash covers every amount,
  -- snapshot and invoice-provenance column.
  UNION ALL
  SELECT 8, 'rows', 'inventory_items count', count(*)::text FROM public.inventory_items
  UNION ALL
  SELECT 8, 'rows', 'inventory_items quantity hash',
    coalesce(md5(string_agg(id::text || ':' || organization_id::text || ':' || quantity::text || ':' || active::text, ',' ORDER BY id)), 'empty')
  FROM public.inventory_items
  UNION ALL
  SELECT 8, 'rows', 'inventory organization totals hash',
    coalesce(md5(string_agg(organization_id::text || '=' || total::text, ',' ORDER BY organization_id)), 'empty')
  FROM (SELECT organization_id, sum(quantity) AS total FROM public.inventory_items GROUP BY 1) totals
  UNION ALL
  SELECT 8, 'rows', 'inventory_adjustments count', count(*)::text FROM public.inventory_adjustments
  UNION ALL
  SELECT 8, 'rows', 'inventory_adjustments hash',
    coalesce(md5(string_agg(concat_ws(':', id, inventory_item_id, adjustment_amount, previous_quantity, new_quantity,
      reason, source_type, source_invoice_id, source_invoice_item_id, idempotency_key, created_by, created_at), ',' ORDER BY id)), 'empty')
  FROM public.inventory_adjustments
  UNION ALL
  SELECT 8, 'rows', 'inventory_price_history hash',
    coalesce(md5(string_agg(concat_ws(':', id, product_id, vendor_id, invoice_id, invoice_item_id, quantity, unit_price, extended_price),
      ',' ORDER BY id)), 'empty')
  FROM public.inventory_price_history
  UNION ALL
  SELECT 8, 'rows', 'invoices hash',
    coalesce(md5(string_agg(concat_ws(':', id, processing_status, posted_at, invoice_total, total_amount, total), ',' ORDER BY id)), 'empty')
  FROM public.invoices
  UNION ALL
  SELECT 8, 'rows', 'invoice_items hash',
    coalesce(md5(string_agg(concat_ws(':', id, invoice_id, product_id, vendor_product_id, quantity, unit_price, total_price, review_status),
      ',' ORDER BY id)), 'empty')
  FROM public.invoice_items
  UNION ALL
  SELECT 8, 'rows', 'organization_budgets hash',
    coalesce(md5(string_agg(to_jsonb(b)::text, ',' ORDER BY b.id)), 'empty')
  FROM public.organization_budgets b
  UNION ALL
  SELECT 8, 'rows', 'supply_requests hash',
    coalesce(md5(string_agg(id::text || ':' || status::text || ':' || coalesce(location_id::text, ''), ',' ORDER BY id)), 'empty')
  FROM public.supply_requests
  UNION ALL
  SELECT 8, 'rows', 'supply_request_commitments hash',
    coalesce(md5(string_agg(id::text || ':' || status::text || ':' || amount::text, ',' ORDER BY id)), 'empty')
  FROM public.supply_request_commitments
  UNION ALL
  SELECT 8, 'rows', 'supply_request_items hash',
    coalesce(md5(string_agg(id::text || ':' || supply_request_id::text || ':' || quantity::text, ',' ORDER BY id)), 'empty')
  FROM public.supply_request_items
  UNION ALL
  SELECT 8, 'rows', 'supply_request_commitment_items hash',
    coalesce(md5(string_agg(to_jsonb(ci)::text, ',' ORDER BY ci.id)), 'empty')
  FROM public.supply_request_commitment_items ci
  UNION ALL
  SELECT 8, 'rows', 'locations (sites) hash',
    coalesce(md5(string_agg(id::text || ':' || name || ':' || active::text, ',' ORDER BY id)), 'empty')
  FROM public.locations

  -- Per-organization inventory totals, readable at a glance.
  UNION ALL
  SELECT 9, 'org_total', organization_id::text, count(*)::text || ' items, total ' || sum(quantity)::text
  FROM public.inventory_items GROUP BY organization_id
) fingerprint
ORDER BY ord, section, key;
