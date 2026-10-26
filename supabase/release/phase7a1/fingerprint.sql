-- Phase 7A.1 release fingerprint: one read-only SELECT, safe to paste into the Supabase SQL
-- Editor or run with psql. precheck.sql and postcheck.sql end with this exact statement
-- (tests/phase7a1-location-aware-inventory.test.ts keeps the three copies identical).
-- Every row is (section, key, value) so the pre and post outputs can be diffed line by line.

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
