-- Phase 7E release fingerprint: one read-only SELECT, safe to paste into the Supabase SQL
-- Editor or run with psql. precheck.sql and postcheck.sql end with this exact statement
-- (tests/phase7e-release-files.test.ts keeps the copies identical). Every row is
-- (section, key, value) so outputs can be diffed line by line. It runs before the migration
-- too: objects that do not exist yet read as 'absent'.

SELECT section, key, value FROM (
  -- Functions this phase adds or changes, and the invoice, budget, request, inventory, count,
  -- notification, role and discovery functions it must leave alone: body hash, SECURITY
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
    -- Added by 7E.
    ('tg_financial_document_removals_append_only'),
    ('financial_currency_basis'),
    ('financial_context_is'),
    ('tg_guard_organization_budget_overlap'),
    ('tg_guard_posted_invoice'),
    ('tg_guard_posted_invoice_item'),
    ('delete_invoice_internal'),
    ('financial_spend_rows'),
    ('financial_spend_line_rows'),
    ('financial_commitment_rows'),
    ('remove_posted_financial_document'),
    ('vendor_invoice_storage_deletable'),
    ('financial_possible_duplicate_ids'),
    ('financial_outside_budget_ids'),
    ('financial_assert_range'),
    ('financial_assert_access'),
    ('get_financial_spend_summary'),
    ('get_financial_spend_series'),
    ('list_financial_vendor_spend'),
    ('list_financial_product_spend'),
    ('list_financial_commitments'),
    ('financial_spend_row_json'),
    ('list_financial_spend_documents'),
    ('get_financial_document_detail'),
    ('list_financial_product_lines'),
    ('list_financial_document_removals'),
    -- Changed by 7E (same signatures and result shapes).
    ('post_reviewed_invoice'),
    ('delete_invoice_permanently'),
    ('get_budget_summary'),
    ('get_supply_request_budget_impact'),
    ('get_budget_purchasing_overview'),
    ('get_budget_lineage'),
    ('get_price_intelligence_overview'),
    ('get_product_price_intelligence'),
    -- Invoice review, matching and intake, must not change.
    ('persist_invoice_document_identity'),
    ('confirm_invoice_item_product_expected'),
    ('match_invoice_item_to_catalog_listing'),
    ('search_invoice_line_catalog_listings'),
    ('invalidate_derived_invoice_totals'),
    ('guard_invoice_item_match_provenance'),
    ('create_invoice_upload_batch'),
    ('register_invoice_batch_segment'),
    ('get_invoice_upload_batch'),
    ('list_invoice_upload_batches'),
    -- Requests and commitments, must not change.
    ('submit_supply_request'),
    ('decide_supply_request'),
    ('transition_supply_request'),
    ('apply_supply_request_transition'),
    ('guard_supply_request_lifecycle'),
    ('resolve_supply_request_item_costs'),
    ('create_supply_request_commitment'),
    ('release_supply_request_commitment'),
    ('receive_supply_request'),
    ('receive_and_complete_supply_request'),
    ('approve_and_order_supply_request'),
    ('apply_supply_request_receipt'),
    -- 6C.3 notifications, must not change.
    ('notification_approver_digest_content'),
    ('dispatch_notification_events'),
    ('capture_supply_request_submitted_notification'),
    ('capture_supply_request_decision_notification'),
    -- Organization role helpers, must not change.
    ('has_org_role'),
    ('is_org_admin'),
    ('is_org_member'),
    ('tg_set_updated_at'),
    -- Inventory, counts and 7D replenishment, must not change.
    ('inventory_apply_balance_delta'),
    ('apply_inventory_location_delta'),
    ('adjust_inventory_location_quantity'),
    ('ensure_inventory_unassigned_location'),
    ('tg_check_inventory_balance_invariant'),
    ('move_inventory_stock'),
    ('submit_inventory_count'),
    ('get_inventory_overview'),
    ('inventory_replenishment_rows'),
    ('list_inventory_replenishment'),
    ('get_inventory_replenishment_summary'),
    ('set_inventory_replenishment_rule'),
    ('tg_guard_inventory_replenishment_rule'),
    -- 5A.10 discovery, must not change.
    ('search_supply_request_products_with_signals'),
    ('get_staff_product_discovery')
  ) AS fn(name)

  UNION ALL
  SELECT 2, 'overloads', fn.name, count(p.oid)::text
  FROM (VALUES ('post_reviewed_invoice'), ('delete_invoice_permanently'), ('get_budget_summary'),
               ('get_supply_request_budget_impact'), ('get_budget_purchasing_overview'), ('get_budget_lineage'),
               ('get_price_intelligence_overview'), ('get_product_price_intelligence'), ('financial_spend_rows'),
               ('get_financial_spend_summary'), ('remove_posted_financial_document'), ('move_inventory_stock')) AS fn(name)
  LEFT JOIN pg_proc p ON p.proname = fn.name AND p.pronamespace = 'public'::regnamespace
  GROUP BY fn.name

  -- Settings the migration relies on.
  UNION ALL
  SELECT 3, 'setting', 'TimeZone', current_setting('TimeZone')

  -- Tables: columns and RLS, policies and client grants.
  UNION ALL
  SELECT 4, 'table', t.name,
    coalesce((SELECT md5(string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull, ',' ORDER BY a.attnum))
                || ' rls=' || c.relrowsecurity
              FROM pg_class c JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
              WHERE c.oid = to_regclass('public.' || t.name)
              GROUP BY c.relrowsecurity), 'absent')
  FROM (VALUES ('financial_document_removals'), ('invoices'), ('invoice_items'), ('vendor_invoices'),
               ('invoice_processing_jobs'), ('organization_budgets'), ('inventory_price_history'),
               ('supply_requests'), ('supply_request_items'), ('supply_request_commitments'),
               ('inventory_items'), ('inventory_location_balances'), ('inventory_adjustments'),
               ('inventory_transfers'), ('inventory_replenishment_rules'), ('organizations'),
               ('organization_memberships'), ('profiles'), ('vendors'), ('products')) AS t(name)
  UNION ALL
  SELECT 4, 'policies', t.name,
    coalesce((SELECT string_agg(policyname, ',' ORDER BY policyname) FROM pg_policies
              WHERE schemaname = 'public' AND tablename = t.name), 'none')
  FROM (VALUES ('financial_document_removals'), ('invoices'), ('invoice_items'), ('vendor_invoices'),
               ('organization_budgets'), ('inventory_price_history'), ('supply_request_commitments')) AS t(name)
  UNION ALL
  SELECT 4, 'grants', t.name,
    coalesce((SELECT string_agg(grantee || '=' || privileges, ';' ORDER BY grantee) FROM (
                SELECT grantee, string_agg(privilege_type, ',' ORDER BY privilege_type) AS privileges
                FROM information_schema.role_table_grants
                WHERE table_schema = 'public' AND table_name = t.name
                  AND grantee IN ('anon', 'authenticated', 'service_role', 'PUBLIC')
                GROUP BY grantee) g), 'none')
  FROM (VALUES ('financial_document_removals'), ('invoices'), ('invoice_items'), ('vendor_invoices'),
               ('organization_budgets'), ('inventory_price_history'), ('supply_request_commitments')) AS t(name)
  -- The vendor-invoices storage policies (7E narrows the owner delete policy).
  UNION ALL
  SELECT 4, 'storage policy', pol.polname, pol.polcmd::text || ' ' || md5(coalesce(pg_get_expr(pol.polqual, pol.polrelid), '')
    || '|' || coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), ''))
  FROM pg_policy pol
  WHERE pol.polrelid = to_regclass('storage.objects') AND pol.polname LIKE 'vendor_invoices_storage_%'

  -- Constraints and indexes on the financial tables.
  UNION ALL
  SELECT 5, 'constraint', t.relname || '.' || con.conname,
    con.contype::text || ' ' || md5(pg_get_constraintdef(con.oid)) || ' validated=' || con.convalidated
  FROM pg_constraint con JOIN pg_class t ON t.oid = con.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace
  WHERE n.nspname = 'public' AND t.relname IN ('financial_document_removals', 'invoices', 'invoice_items',
    'vendor_invoices', 'organization_budgets', 'supply_request_commitments')
  UNION ALL
  SELECT 5, 'index', c.relname, md5(pg_get_indexdef(ix.indexrelid)) || ' valid=' || ix.indisvalid
  FROM pg_index ix JOIN pg_class c ON c.oid = ix.indexrelid JOIN pg_class t ON t.oid = ix.indrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  WHERE n.nspname = 'public' AND t.relname IN ('financial_document_removals', 'invoices', 'invoice_items',
    'vendor_invoices', 'organization_budgets', 'supply_request_commitments')

  -- Triggers on the financial tables.
  UNION ALL
  SELECT 6, 'trigger', c.relname || '.' || tg.tgname, md5(pg_get_triggerdef(tg.oid)) || ' enabled=' || tg.tgenabled::text
  FROM pg_trigger tg JOIN pg_class c ON c.oid = tg.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND NOT tg.tgisinternal
    AND c.relname IN ('financial_document_removals', 'invoices', 'invoice_items', 'vendor_invoices',
      'organization_budgets', 'supply_request_commitments', 'supply_requests', 'inventory_items',
      'inventory_location_balances', 'inventory_adjustments')

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

  -- Data: whole rows of every financial, request, inventory and organization table, must not
  -- change. The removals table is empty after the migration.
  UNION ALL
  SELECT 8, 'rows', t.name || ' hash',
    coalesce((xpath('/row/h/text()', query_to_xml(format(
      'SELECT md5(string_agg(to_jsonb(r)::text, %L ORDER BY to_jsonb(r)::text)) AS h FROM public.%I r', ',', t.name), false, true, '')))[1]::text, 'empty')
  FROM (VALUES ('invoices'), ('invoice_items'), ('vendor_invoices'), ('invoice_processing_jobs'),
               ('organization_budgets'), ('inventory_price_history'), ('supply_requests'), ('supply_request_items'),
               ('supply_request_commitments'), ('inventory_items'), ('inventory_location_balances'),
               ('inventory_adjustments'), ('inventory_transfers'), ('inventory_replenishment_rules'),
               ('notification_events'), ('organizations'), ('organization_memberships'), ('profiles'),
               ('vendors'), ('products')) AS t(name)
  UNION ALL
  SELECT 8, 'rows', 'financial_document_removals count',
    CASE WHEN to_regclass('public.financial_document_removals') IS NULL THEN 'absent'
      ELSE (xpath('/row/c/text()', query_to_xml('SELECT count(*) AS c FROM public.financial_document_removals', false, true, '')))[1]::text END
  UNION ALL
  -- Posted documents 7E would exclude from spend (expected 0 each: the migration refuses to run
  -- over posted credit memos or statements, and other currencies would change budget figures).
  SELECT 8, 'rows', 'posted ' || k.kind,
    (SELECT count(*)::text FROM public.invoices i WHERE i.posted_at IS NOT NULL AND CASE k.kind
       WHEN 'credit memos' THEN i.document_type = 'CREDIT_MEMO'
       WHEN 'statements' THEN i.document_type = 'STATEMENT'
       ELSE i.currency_code IS NOT NULL AND upper(i.currency_code) <> 'USD' END)
  FROM (VALUES ('credit memos'), ('statements'), ('in another currency')) AS k(kind)

  -- Every active budget's actual spend by the pre-7E formula (header total by invoice date or
  -- posting day): identical before and after; the postcheck also proves 7E's Spent equals it.
  UNION ALL
  SELECT 9, 'budget', b.id::text,
    b.name || ' | ' || b.period_start || '..' || b.period_end || ' | amount=' || b.amount
      || ' | actual=' || coalesce((
        SELECT sum(coalesce(i.invoice_total, i.total_amount, i.total,
          (SELECT sum(item.total_price) FROM public.invoice_items item
            WHERE item.invoice_id = i.id AND item.organization_id = i.organization_id), 0))
        FROM public.invoices i
        WHERE i.organization_id = b.organization_id AND i.posted_at IS NOT NULL
          AND coalesce(i.invoice_date, (i.posted_at AT TIME ZONE 'UTC')::date) BETWEEN b.period_start AND b.period_end), 0)
      || ' | documents=' || (
        SELECT count(*) FROM public.invoices i
        WHERE i.organization_id = b.organization_id AND i.posted_at IS NOT NULL
          AND coalesce(i.invoice_date, (i.posted_at AT TIME ZONE 'UTC')::date) BETWEEN b.period_start AND b.period_end)
  FROM public.organization_budgets b
  WHERE b.active
) fingerprint
ORDER BY ord, section, key;
