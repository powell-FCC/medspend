-- Phase 7B.1 release fingerprint: one read-only SELECT, safe to paste into the Supabase SQL
-- Editor or run with psql. precheck.sql and postcheck.sql end with this exact statement
-- (tests/phase7b1-inventory-admin-workspace.test.ts keeps the copies identical). Every row is
-- (section, key, value) so outputs can be diffed line by line.

SELECT section, key, value FROM (
  -- Functions this phase adds, the 7A.1 functions it builds on, and neighbours it must
  -- leave alone: body hash, SECURITY DEFINER, and who may execute it.
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
    -- Added by 7B.1.
    ('get_inventory_workspace_location'),
    ('inventory_workspace_stock_status'),
    ('list_inventory_workspace_item_balances'),
    ('list_inventory_workspace_items'),
    ('list_inventory_workspace_location_stock'),
    ('list_inventory_workspace_locations'),
    ('replace_inventory_location_labels'),
    -- 7A.2, must not change.
    ('get_inventory_count_location'),
    ('get_supply_request_inventory_identities'),
    ('inventory_count_replay'),
    ('inventory_count_summary'),
    ('inventory_countable_balances'),
    ('issue_inventory_location_label'),
    ('list_countable_inventory_locations'),
    ('list_inventory_location_count_status'),
    ('resolve_inventory_count_label'),
    ('revoke_inventory_location_labels'),
    ('submit_inventory_count'),
    ('tg_guard_inventory_count_history'),
    ('tg_guard_inventory_location_label'),
    -- 7A.1, must not change.
    ('adjust_inventory_location_quantity'),
    ('adjust_inventory_quantity'),
    ('apply_inventory_location_delta'),
    ('create_inventory_location'),
    ('delete_invoice_permanently'),
    ('ensure_inventory_unassigned_location'),
    ('inventory_apply_balance_delta'),
    ('move_inventory_stock'),
    ('post_reviewed_invoice'),
    ('receive_invoice_inventory_item'),
    ('set_inventory_location_active'),
    ('update_inventory_location'),
    -- Authorization helpers 7B.1 relies on, must not change.
    ('has_org_role'),
    ('is_org_admin'),
    ('is_org_member'),
    ('list_organization_member_identities'),
    -- Neighbours, must not change.
    ('stock_catalog_vendor_product'),
    ('search_supply_request_products'),
    ('submit_supply_request'),
    ('replace_supply_request_items'),
    ('resolve_supply_request_item_costs'),
    ('decide_supply_request'),
    ('get_budget_summary'),
    ('get_supply_request_budget_impact')
  ) AS fn(name)

  UNION ALL
  SELECT 2, 'overloads', fn.name,
    (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = fn.name)::text
  FROM (VALUES ('submit_inventory_count'), ('get_inventory_count_location'), ('resolve_inventory_count_label'),
    ('issue_inventory_location_label'), ('revoke_inventory_location_labels'), ('replace_inventory_location_labels'),
    ('list_inventory_workspace_locations'), ('list_inventory_workspace_items'), ('list_inventory_workspace_location_stock'),
    ('adjust_inventory_quantity'), ('delete_invoice_permanently')) AS fn(name)

  UNION ALL
  SELECT 3, 'constraint', c.name,
    coalesce((SELECT md5(pg_get_constraintdef(con.oid)) FROM pg_constraint con
      WHERE con.conrelid = 'public.inventory_adjustments'::regclass AND con.conname = c.name), 'absent')
  FROM (VALUES ('inventory_adjustments_source_type_check'), ('inventory_adjustments_reason_check'),
    ('inventory_adjustments_physical_count_check'), ('inventory_adjustments_count_line_fk')) AS c(name)

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

  -- Policies, triggers and grants per table.
  UNION ALL
  SELECT 5, 'policies', t.name,
    coalesce((SELECT md5(string_agg(policyname || ':' || cmd || ':' || coalesce(qual, '') || ':' || coalesce(with_check, ''),
      '|' ORDER BY policyname)) FROM pg_policies WHERE schemaname = 'public' AND tablename = t.name), 'none')
  FROM (VALUES ('inventory_items'), ('inventory_adjustments'), ('inventory_locations'), ('inventory_location_balances'),
    ('inventory_transfers'), ('inventory_count_sessions'), ('inventory_count_lines'), ('inventory_location_labels'),
    ('inventory_categories'), ('organization_memberships'), ('products'), ('supply_requests'), ('supply_request_items')) AS t(name)
  UNION ALL
  SELECT 6, 'triggers', t.name,
    coalesce((SELECT md5(string_agg(tr.tgname || ':' || pg_get_triggerdef(tr.oid), '|' ORDER BY tr.tgname))
      FROM pg_trigger tr JOIN pg_class c ON c.oid = tr.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relname = t.name AND NOT tr.tgisinternal), 'none')
  FROM (VALUES ('inventory_items'), ('inventory_adjustments'), ('inventory_locations'), ('inventory_location_balances'),
    ('inventory_count_sessions'), ('inventory_count_lines'), ('inventory_location_labels'), ('organizations')) AS t(name)
  UNION ALL
  SELECT 7, 'grants', t.name,
    coalesce((SELECT string_agg(grantee || '=' || privilege_type, ',' ORDER BY grantee, privilege_type)
      FROM information_schema.role_table_grants
      WHERE table_schema = 'public' AND table_name = t.name
        AND grantee IN ('anon', 'authenticated', 'service_role')), 'none')
  FROM (VALUES ('inventory_items'), ('inventory_adjustments'), ('inventory_locations'), ('inventory_location_balances'),
    ('inventory_transfers'), ('inventory_count_sessions'), ('inventory_count_lines'), ('inventory_location_labels'),
    ('inventory_categories')) AS t(name)

  -- Data. 7B.1 writes no rows; every line here must match before and after.
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
  SELECT 8, 'rows', 'inventory_location_balances hash',
    coalesce(md5(string_agg(concat_ws(':', inventory_item_id, inventory_location_id, quantity, version), ',' ORDER BY inventory_item_id, inventory_location_id)), 'empty')
  FROM public.inventory_location_balances
  UNION ALL
  SELECT 8, 'rows', 'inventory_locations hash',
    coalesce(md5(string_agg(concat_ws(':', id, organization_id, name, kind, active), ',' ORDER BY id)), 'empty')
  FROM public.inventory_locations
  UNION ALL
  SELECT 8, 'rows', 'inventory_transfers count', count(*)::text FROM public.inventory_transfers
  UNION ALL
  SELECT 8, 'rows', 'inventory_adjustments count', count(*)::text FROM public.inventory_adjustments
  UNION ALL
  SELECT 8, 'rows', 'inventory_adjustments hash',
    coalesce(md5(string_agg(concat_ws(':', id, inventory_item_id, inventory_location_id, adjustment_amount, previous_quantity, new_quantity,
      reason, source_type, source_invoice_id, source_invoice_item_id, idempotency_key, created_by, created_at), ',' ORDER BY id)), 'empty')
  FROM public.inventory_adjustments
  UNION ALL
  SELECT 8, 'rows', 'inventory_transfers hash',
    coalesce(md5(string_agg(concat_ws(':', id, inventory_item_id, from_inventory_location_id, to_inventory_location_id, quantity,
      idempotency_key, created_by, created_at), ',' ORDER BY id)), 'empty')
  FROM public.inventory_transfers
  UNION ALL
  SELECT 8, 'rows', 'inventory_count_sessions hash',
    coalesce(md5(string_agg(concat_ws(':', id, inventory_location_id, counted_by, submitted_at, line_count, changed_count), ',' ORDER BY id)), 'empty')
  FROM public.inventory_count_sessions
  UNION ALL
  SELECT 8, 'rows', 'inventory_count_lines hash',
    coalesce(md5(string_agg(concat_ws(':', id, count_session_id, inventory_item_id, previous_quantity, counted_quantity, delta), ',' ORDER BY id)), 'empty')
  FROM public.inventory_count_lines
  UNION ALL
  SELECT 8, 'rows', 'inventory_location_labels hash',
    coalesce(md5(string_agg(concat_ws(':', id, inventory_location_id, token_hash, created_by, created_at, revoked_at, revoked_by), ',' ORDER BY id)), 'empty')
  FROM public.inventory_location_labels
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
  SELECT 8, 'rows', 'organization_budgets hash',
    coalesce(md5(string_agg(to_jsonb(b)::text, ',' ORDER BY b.id)), 'empty')
  FROM public.organization_budgets b
  UNION ALL
  SELECT 8, 'rows', 'supply_requests hash',
    coalesce(md5(string_agg(id::text || ':' || status::text || ':' || coalesce(location_id::text, ''), ',' ORDER BY id)), 'empty')
  FROM public.supply_requests
  UNION ALL
  SELECT 8, 'rows', 'supply_request_items hash',
    coalesce(md5(string_agg(id::text || ':' || supply_request_id::text || ':' || quantity::text, ',' ORDER BY id)), 'empty')
  FROM public.supply_request_items
  UNION ALL
  SELECT 8, 'rows', 'supply_request_commitments hash',
    coalesce(md5(string_agg(id::text || ':' || status::text || ':' || amount::text, ',' ORDER BY id)), 'empty')
  FROM public.supply_request_commitments
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
