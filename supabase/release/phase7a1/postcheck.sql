-- Phase 7A.1 production POSTCHECK. Run AFTER the migration and BEFORE the application deploy.
--
-- Safe for the Supabase SQL Editor: no psql meta-commands, no transaction control, and no
-- writes (one read-only DO block of assertions, then one SELECT). Paste the whole file and run
-- it once. psql users can run the same file:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F ' | ' -f supabase/release/phase7a1/postcheck.sql > phase7a1_post.txt
--   diff phase7a1_pre.txt phase7a1_post.txt
--
-- Success: the result grid shows the fingerprint rows. Compare them with the precheck rows;
-- only the lines listed in README.md may differ. Every 'rows' and 'org_total' line must be
-- identical (no quantity, history, invoice, budget or request change).
-- STOP: any error, or any other differing line. If the old application served traffic between
-- the migration and this check, receipts may legitimately change inventory lines; the
-- assertions must still pass.

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

  -- delete_invoice_permanently: authenticated only; never anon or PUBLIC.
  IF NOT has_function_privilege('authenticated', 'public.delete_invoice_permanently(uuid,uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.delete_invoice_permanently(uuid,uuid)', 'EXECUTE')
     OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
                WHERE p.oid = 'public.delete_invoice_permanently(uuid,uuid)'::regprocedure
                  AND acl.grantee = 0 AND acl.privilege_type = 'EXECUTE') THEN
    RAISE EXCEPTION 'postcheck: delete_invoice_permanently grants are not authenticated-only';
  END IF;

  -- Expected columns, constraints and indexes.
  IF (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND (table_name, column_name) IN (
        ('inventory_locations', 'kind'), ('inventory_locations', 'active'), ('inventory_location_balances', 'quantity'),
        ('inventory_location_balances', 'version'), ('inventory_transfers', 'idempotency_key'),
        ('inventory_adjustments', 'inventory_location_id'))) <> 6 THEN
    RAISE EXCEPTION 'postcheck: an expected Phase 7A.1 column is missing';
  END IF;
  IF (SELECT count(*) FROM pg_indexes WHERE schemaname = 'public' AND indexname IN (
        'inventory_locations_id_org_uq', 'inventory_locations_org_name_uq', 'inventory_locations_org_unassigned_uq',
        'inventory_location_balances_pkey', 'inventory_location_balances_location_idx', 'inventory_location_balances_org_idx',
        'inventory_transfers_idempotency_uq', 'inventory_transfers_item_created_idx', 'inventory_adjustments_location_idx')) <> 9 THEN
    RAISE EXCEPTION 'postcheck: an expected Phase 7A.1 index is missing';
  END IF;
  IF (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'public.inventory_adjustments'::regclass
      AND conname = 'inventory_adjustments_source_type_check') NOT LIKE '%physical_count%'
     OR NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'inventory_adjustments_location_org_fk') THEN
    RAISE EXCEPTION 'postcheck: inventory_adjustments constraints are not the Phase 7A.1 ones';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'inventory_adjustments'
             AND policyname = 'inventory_adjustments_owner_insert')
     OR (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND policyname IN (
           'inventory_locations_owner_select', 'inventory_location_balances_owner_select', 'inventory_transfers_owner_select')) <> 3 THEN
    RAISE EXCEPTION 'postcheck: inventory policies are not the Phase 7A.1 ones';
  END IF;
  IF (SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgname IN (
        'inventory_items_guard_quantity', 'inventory_items_seed_balance', 'inventory_location_balances_guard',
        'inventory_adjustments_default_location', 'organizations_seed_inventory_unassigned',
        'inventory_locations_guard', 'inventory_locations_guard_insert', 'inventory_locations_updated_at')) <> 8 THEN
    RAISE EXCEPTION 'postcheck: a Phase 7A.1 guard or seeding trigger is missing';
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
