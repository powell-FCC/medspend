-- Phase 7C release fingerprint: one read-only SELECT, safe to paste into the Supabase SQL
-- Editor or run with psql. precheck.sql and postcheck.sql end with this exact statement
-- (tests/phase7c-release-files.test.ts keeps the copies identical). Every row is
-- (section, key, value) so outputs can be diffed line by line. It runs before the migration
-- too: objects that do not exist yet read as 'absent'.

SELECT section, key, value FROM (
  -- Functions this phase adds or changes, and the request, notification, role, budget, invoice,
  -- inventory, batch intake and discovery functions it must leave alone: body hash, SECURITY
  -- DEFINER, and who may execute it.
  SELECT 1 AS ord, 'function' AS section, fn.name AS key,
    coalesce((
      SELECT md5(pg_get_functiondef(p.oid)) || ' secdef=' || p.prosecdef
        || ' authenticated=' || has_function_privilege('authenticated', p.oid, 'EXECUTE')
        || ' anon=' || has_function_privilege('anon', p.oid, 'EXECUTE')
        || ' service_role=' || has_function_privilege('service_role', p.oid, 'EXECUTE')
        || ' public=' || EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
                                 WHERE acl.grantee = 0 AND acl.privilege_type = 'EXECUTE')
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = fn.name
      ORDER BY p.oid LIMIT 1
    ), 'absent') AS value
  FROM (VALUES
    -- Added by 7C.
    ('guard_supply_request_receipt_immutable'),
    ('list_receiving_destinations'),
    ('list_supply_request_receipts'),
    -- Changed by 7C: the receive path now requires and records a destination; the generic
    -- transition refuses 'received'.
    ('apply_supply_request_receipt'),
    ('receive_supply_request'),
    ('receive_and_complete_supply_request'),
    ('transition_supply_request'),
    -- 7C.0 workflow profiles, must not change.
    ('approve_and_order_supply_request'),
    ('get_organization_request_workflow_settings'),
    ('get_request_workflow_profile'),
    ('guard_supply_request_update_compound_action'),
    ('list_staff_supply_request_updates'),
    ('mark_supply_request_compound_action'),
    ('organization_request_workflow_profile'),
    ('update_organization_request_workflow_settings'),
    -- Request lifecycle, must not change (compound actions call these, they are not edited).
    ('submit_supply_request'),
    ('decide_supply_request'),
    ('apply_supply_request_transition'),
    ('guard_supply_request_lifecycle'),
    ('replace_supply_request_items'),
    ('update_submitted_supply_request'),
    ('cancel_submitted_supply_request'),
    ('resolve_supply_request_context'),
    ('resolve_supply_request_item_costs'),
    ('create_supply_request_commitment'),
    ('release_supply_request_commitment'),
    -- 6C.3 notifications and the canonical digest, must not change.
    ('capture_supply_request_decision_notification'),
    ('capture_supply_request_submitted_notification'),
    ('claim_notification_deliveries'),
    ('complete_notification_delivery'),
    ('dispatch_notification_events'),
    ('enqueue_due_notification_digests'),
    ('get_organization_notification_settings'),
    ('guard_notification_sending_boundary'),
    ('notification_approver_digest_content'),
    ('notification_request_items'),
    ('set_organization_notification_sending'),
    ('update_organization_notification_settings'),
    -- Organization role helpers (profile authority uses is_org_admin), must not change.
    ('has_org_role'),
    ('is_org_admin'),
    ('is_org_member'),
    ('tg_set_updated_at'),
    -- Budgets, invoices and inventory, must not change.
    ('get_budget_summary'),
    ('get_budget_purchasing_overview'),
    ('get_supply_request_budget_impact'),
    ('post_reviewed_invoice'),
    ('delete_invoice_permanently'),
    ('get_inventory_overview'),
    ('move_inventory_stock'),
    ('inventory_apply_balance_delta'),
    ('apply_inventory_location_delta'),
    ('adjust_inventory_quantity'),
    ('adjust_inventory_location_quantity'),
    ('set_inventory_location_active'),
    ('ensure_inventory_unassigned_location'),
    ('list_inventory_workspace_locations'),
    ('get_inventory_count_policy'),
    ('set_inventory_count_policy'),
    -- 6C.4 batch intake and 5A.10 discovery, must not change.
    ('create_invoice_upload_batch'),
    ('register_invoice_batch_segment'),
    ('get_invoice_upload_batch'),
    ('list_invoice_upload_batches'),
    ('search_supply_request_products_with_signals'),
    ('get_staff_product_discovery')
  ) AS fn(name)

  UNION ALL
  SELECT 2, 'overloads', fn.name, count(p.oid)::text
  FROM (VALUES ('apply_supply_request_receipt'), ('receive_and_complete_supply_request'), ('receive_supply_request'),
               ('list_receiving_destinations'), ('list_supply_request_receipts'), ('approve_and_order_supply_request'),
               ('submit_supply_request'), ('decide_supply_request'), ('transition_supply_request'), ('is_org_admin')) AS fn(name)
  LEFT JOIN pg_proc p ON p.proname = fn.name AND p.pronamespace = 'public'::regnamespace
  GROUP BY fn.name

  -- Tables: columns and RLS, policies and client grants.
  UNION ALL
  SELECT 4, 'table', t.name,
    coalesce((SELECT md5(string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull, ',' ORDER BY a.attnum))
                || ' rls=' || c.relrowsecurity
              FROM pg_class c JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
              WHERE c.oid = to_regclass('public.' || t.name)
              GROUP BY c.relrowsecurity), 'absent')
  FROM (VALUES ('supply_request_receipts'), ('organization_request_workflow_settings'), ('notification_events'),
               ('supply_requests'), ('supply_request_updates'), ('supply_request_items'), ('supply_request_commitments'),
               ('inventory_locations'), ('inventory_items'), ('inventory_location_balances'), ('inventory_transfers'),
               ('inventory_adjustments'), ('invoices'), ('organizations'), ('organization_memberships'), ('profiles'),
               ('organization_budgets')) AS t(name)
  UNION ALL
  SELECT 4, 'policies', t.name,
    coalesce((SELECT string_agg(policyname, ',' ORDER BY policyname) FROM pg_policies
              WHERE schemaname = 'public' AND tablename = t.name), 'none')
  FROM (VALUES ('supply_request_receipts'), ('organization_request_workflow_settings'), ('notification_events'),
               ('supply_requests'), ('supply_request_updates'), ('supply_request_items'), ('supply_request_commitments'),
               ('inventory_locations'), ('inventory_items'), ('inventory_location_balances'), ('inventory_transfers'),
               ('inventory_adjustments'), ('invoices'), ('organizations'), ('organization_memberships'), ('profiles'),
               ('organization_budgets')) AS t(name)
  UNION ALL
  SELECT 4, 'grants', t.name,
    coalesce((SELECT string_agg(grantee || '=' || privileges, ';' ORDER BY grantee) FROM (
                SELECT grantee, string_agg(privilege_type, ',' ORDER BY privilege_type) AS privileges
                FROM information_schema.role_table_grants
                WHERE table_schema = 'public' AND table_name = t.name
                  AND grantee IN ('anon', 'authenticated', 'service_role', 'PUBLIC')
                GROUP BY grantee) g), 'none')
  FROM (VALUES ('supply_request_receipts'), ('organization_request_workflow_settings'), ('notification_events'),
               ('supply_requests'), ('supply_request_updates'), ('supply_request_items'), ('supply_request_commitments'),
               ('inventory_locations'), ('inventory_items'), ('inventory_location_balances'), ('inventory_transfers'),
               ('inventory_adjustments'), ('invoices'), ('organizations'), ('organization_memberships'), ('profiles'),
               ('organization_budgets')) AS t(name)

  -- Constraints and indexes on the new tables and the request tables they hang off.
  UNION ALL
  SELECT 5, 'constraint', t.relname || '.' || con.conname,
    con.contype::text || ' ' || md5(pg_get_constraintdef(con.oid)) || ' validated=' || con.convalidated
  FROM pg_constraint con JOIN pg_class t ON t.oid = con.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace
  WHERE n.nspname = 'public' AND t.relname IN ('supply_request_receipts', 'supply_requests', 'supply_request_updates',
    'supply_request_items', 'inventory_locations', 'inventory_location_balances', 'organization_memberships')
  UNION ALL
  SELECT 5, 'index', c.relname, md5(pg_get_indexdef(ix.indexrelid)) || ' valid=' || ix.indisvalid
  FROM pg_index ix JOIN pg_class c ON c.oid = ix.indexrelid JOIN pg_class t ON t.oid = ix.indrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  WHERE n.nspname = 'public' AND t.relname IN ('supply_request_receipts', 'supply_requests', 'supply_request_updates',
    'supply_request_items', 'inventory_locations', 'inventory_location_balances', 'organization_memberships')

  -- Triggers on the new table, the request tables and inventory locations (7C adds the receipt
  -- immutability trigger).
  UNION ALL
  SELECT 6, 'trigger', c.relname || '.' || tg.tgname, md5(pg_get_triggerdef(tg.oid)) || ' enabled=' || tg.tgenabled::text
  FROM pg_trigger tg JOIN pg_class c ON c.oid = tg.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND NOT tg.tgisinternal
    AND c.relname IN ('supply_request_receipts', 'supply_requests', 'supply_request_updates', 'supply_request_items',
      'inventory_locations', 'inventory_items', 'inventory_location_balances', 'organization_memberships', 'organizations')

  -- Counts across public.
  UNION ALL
  SELECT 7, 'count', 'public functions', count(*)::text FROM pg_proc WHERE pronamespace = 'public'::regnamespace
  UNION ALL
  SELECT 7, 'count', 'public tables', count(*)::text FROM pg_tables WHERE schemaname = 'public'
  UNION ALL
  SELECT 7, 'count', 'public indexes', count(*)::text FROM pg_indexes WHERE schemaname = 'public'
  UNION ALL
  SELECT 7, 'count', 'public policies', count(*)::text FROM pg_policies WHERE schemaname = 'public'
  UNION ALL
  SELECT 7, 'count', 'public triggers', count(*)::text FROM pg_trigger tg JOIN pg_class c ON c.oid = tg.tgrelid
  WHERE c.relnamespace = 'public'::regnamespace AND NOT tg.tgisinternal

  -- Data: requests, history, items, commitments, notification events, workflow settings,
  -- organizations, memberships, profiles, budgets, invoices and every inventory table: whole rows,
  -- must not change. The new receipts table is empty after the migration.
  UNION ALL
  SELECT 8, 'rows', t.name || ' hash',
    coalesce((xpath('/row/h/text()', query_to_xml(format(
      'SELECT md5(string_agg(to_jsonb(r)::text, %L ORDER BY to_jsonb(r)::text)) AS h FROM public.%I r', ',', t.name), false, true, '')))[1]::text, 'empty')
  FROM (VALUES ('supply_requests'), ('supply_request_updates'), ('supply_request_items'), ('supply_request_commitments'),
               ('notification_events'), ('notification_deliveries'), ('organization_request_workflow_settings'),
               ('organizations'), ('organization_memberships'), ('profiles'), ('organization_budgets'), ('invoices'),
               ('inventory_items'), ('inventory_locations'), ('inventory_location_balances'), ('inventory_adjustments'),
               ('inventory_transfers')) AS t(name)
  UNION ALL
  SELECT 8, 'rows', 'supply_request_receipts count',
    CASE WHEN to_regclass('public.supply_request_receipts') IS NULL THEN 'absent'
      ELSE (xpath('/row/c/text()', query_to_xml('SELECT count(*) AS c FROM public.supply_request_receipts', false, true, '')))[1]::text END
) fingerprint
ORDER BY ord, section, key;
