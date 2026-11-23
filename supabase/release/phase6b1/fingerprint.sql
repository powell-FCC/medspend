-- Phase 6B.1 release fingerprint: one read-only SELECT, safe to paste into the Supabase SQL
-- Editor or run with psql. precheck.sql and postcheck.sql end with this exact statement
-- (tests/phase6b1-release-files.test.ts keeps the copies identical). Every row is
-- (section, key, value) so outputs can be diffed line by line. It runs before the migration
-- too: objects that do not exist yet read as 'absent'.

SELECT section, key, value FROM (
  -- Functions this phase adds or changes, and the price, invoice, budget, request, inventory,
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
    -- Added by 6B.1.
    ('price_unit_key'),
    ('price_unit_is_valid'),
    ('price_recency'),
    ('price_catalog_unit_agrees'),
    ('price_package_agreement'),
    ('price_row_is_valid'),
    ('price_observation_rows'),
    ('price_recent_anchors'),
    ('price_name_anchors'),
    ('price_observation_evidence'),
    ('price_product_state'),
    ('list_price_intelligence_products'),
    ('get_price_intelligence_summary'),
    ('get_product_vendor_price_history'),
    ('get_supply_request_price_context'),
    -- Changed by 6B.1 (same signatures and result keys).
    ('get_price_intelligence_overview'),
    ('get_product_price_intelligence'),
    -- Phase 7E financial functions 6B.1 builds on or must leave alone.
    ('financial_assert_access'),
    ('financial_currency_basis'),
    ('financial_spend_rows'),
    ('financial_spend_line_rows'),
    ('get_financial_document_detail'),
    ('get_financial_spend_summary'),
    ('list_financial_product_spend'),
    ('list_financial_vendor_spend'),
    ('remove_posted_financial_document'),
    ('delete_invoice_internal'),
    ('post_reviewed_invoice'),
    ('delete_invoice_permanently'),
    ('get_budget_summary'),
    ('get_supply_request_budget_impact'),
    ('get_budget_purchasing_overview'),
    ('get_budget_lineage'),
    -- Catalog adoption and vendor SKU matching, must not change.
    ('adopt_catalog_vendor_product'),
    ('rematch_invoice_vendor_products'),
    ('confirm_invoice_item_product'),
    ('normalize_catalog_sku'),
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
  FROM (VALUES ('get_price_intelligence_overview'), ('get_product_price_intelligence'), ('price_product_state'),
               ('price_observation_rows'), ('list_price_intelligence_products'), ('get_price_intelligence_summary'),
               ('get_product_vendor_price_history'), ('get_supply_request_price_context')) AS fn(name)
  LEFT JOIN pg_proc p ON p.proname = fn.name AND p.pronamespace = 'public'::regnamespace
  GROUP BY fn.name

  -- Settings the migration relies on.
  UNION ALL
  SELECT 3, 'setting', 'TimeZone', current_setting('TimeZone')

  -- Tables the price reads use or must leave alone: columns and RLS, policies and client grants.
  UNION ALL
  SELECT 4, 'table', t.name,
    coalesce((SELECT md5(string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull, ',' ORDER BY a.attnum))
                || ' rls=' || c.relrowsecurity
              FROM pg_class c JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
              WHERE c.oid = to_regclass('public.' || t.name)
              GROUP BY c.relrowsecurity), 'absent')
  FROM (VALUES ('inventory_price_history'), ('invoices'), ('invoice_items'), ('vendors'), ('vendor_products'),
               ('products'), ('catalog_vendor_products'), ('supply_requests'), ('supply_request_items'),
               ('inventory_items'), ('organization_memberships'), ('financial_document_removals')) AS t(name)
  UNION ALL
  SELECT 4, 'policies', t.name,
    coalesce((SELECT string_agg(policyname, ',' ORDER BY policyname) FROM pg_policies
              WHERE schemaname = 'public' AND tablename = t.name), 'none')
  FROM (VALUES ('inventory_price_history'), ('invoices'), ('invoice_items'), ('vendor_products'),
               ('supply_request_items')) AS t(name)
  UNION ALL
  SELECT 4, 'grants', t.name,
    coalesce((SELECT string_agg(grantee || '=' || privileges, ';' ORDER BY grantee) FROM (
                SELECT grantee, string_agg(privilege_type, ',' ORDER BY privilege_type) AS privileges
                FROM information_schema.role_table_grants
                WHERE table_schema = 'public' AND table_name = t.name
                  AND grantee IN ('anon', 'authenticated', 'service_role', 'PUBLIC')
                GROUP BY grantee) g), 'none')
  FROM (VALUES ('inventory_price_history'), ('invoices'), ('invoice_items'), ('vendor_products'),
               ('supply_request_items')) AS t(name)

  -- Indexes and constraints on the tables the price reads use.
  UNION ALL
  SELECT 5, 'index', c.relname, md5(pg_get_indexdef(ix.indexrelid)) || ' valid=' || ix.indisvalid
  FROM pg_index ix JOIN pg_class c ON c.oid = ix.indexrelid JOIN pg_class t ON t.oid = ix.indrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  WHERE n.nspname = 'public' AND t.relname IN ('inventory_price_history', 'invoices', 'invoice_items',
    'vendor_products', 'products', 'supply_request_items')
  UNION ALL
  SELECT 5, 'constraint', t.relname || '.' || con.conname,
    con.contype::text || ' ' || md5(pg_get_constraintdef(con.oid)) || ' validated=' || con.convalidated
  FROM pg_constraint con JOIN pg_class t ON t.oid = con.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace
  WHERE n.nspname = 'public' AND t.relname IN ('inventory_price_history', 'invoices', 'invoice_items', 'vendor_products')

  -- Triggers on those tables.
  UNION ALL
  SELECT 6, 'trigger', c.relname || '.' || tg.tgname, md5(pg_get_triggerdef(tg.oid)) || ' enabled=' || tg.tgenabled::text
  FROM pg_trigger tg JOIN pg_class c ON c.oid = tg.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND NOT tg.tgisinternal
    AND c.relname IN ('inventory_price_history', 'invoices', 'invoice_items', 'vendor_products', 'products',
      'supply_requests', 'supply_request_items')

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

  -- Data: whole rows of every price, financial, request, inventory, catalog and organization
  -- table, must not change. 6B.1 writes nothing.
  UNION ALL
  SELECT 8, 'rows', t.name || ' hash',
    coalesce((xpath('/row/h/text()', query_to_xml(format(
      'SELECT md5(string_agg(to_jsonb(r)::text, %L ORDER BY to_jsonb(r)::text)) AS h FROM public.%I r', ',', t.name), false, true, '')))[1]::text, 'empty')
  FROM (VALUES ('inventory_price_history'), ('invoices'), ('invoice_items'), ('vendor_invoices'), ('vendors'),
               ('vendor_products'), ('products'), ('product_aliases'), ('catalog_vendor_products'),
               ('organization_budgets'), ('supply_requests'), ('supply_request_items'),
               ('supply_request_commitments'), ('inventory_items'), ('inventory_location_balances'),
               ('inventory_adjustments'), ('inventory_replenishment_rules'), ('financial_document_removals'),
               ('notification_events'), ('organizations'), ('organization_memberships'), ('profiles')) AS t(name)

  -- Price Intelligence per organization, computed by 6B.1's own decision function ('absent'
  -- before the migration): products, USD observations, states, increases and comparisons.
  UNION ALL
  SELECT 9, 'price', o.id::text,
    CASE WHEN to_regprocedure('public.price_product_state(uuid, uuid[], date, boolean)') IS NULL THEN 'absent'
    ELSE (xpath('/row/v/text()', query_to_xml(format($price$
      SELECT 'products=' || count(*)
        || ' | observations=' || coalesce(sum(observation_count), 0)
        || ' | insufficient_identity=' || count(*) FILTER (WHERE state = 'insufficient_identity')
        || ' | multiple_skus=' || count(*) FILTER (WHERE identity_issue = 'multiple_skus')
        || ' | one_purchase=' || count(*) FILTER (WHERE state = 'one_purchase')
        || ' | single_vendor=' || count(*) FILTER (WHERE state = 'single_vendor')
        || ' | comparable=' || count(*) FILTER (WHERE state = 'comparable')
        || ' | missing_package_details=' || count(*) FILTER (WHERE state = 'missing_package_details')
        || ' | incompatible_units=' || count(*) FILTER (WHERE state = 'incompatible_units')
        || ' | same_sku_increases=' || count(*) FILTER (WHERE change_amount > 0)
        || ' | lower_comparable=' || count(*) FILTER (WHERE 'lower_comparable_price_other_vendor' = ANY (signals)) AS v
      FROM public.price_product_state(%L, NULL, (now() AT TIME ZONE 'UTC')::date, false)
    $price$, o.id), false, true, '')))[1]::text END
  FROM public.organizations o
  WHERE EXISTS (SELECT 1 FROM public.inventory_price_history h WHERE h.organization_id = o.id)
) fingerprint
ORDER BY ord, section, key;
