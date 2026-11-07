-- Phase 5A.10 release fingerprint: one read-only SELECT, safe to paste into the Supabase SQL
-- Editor or run with psql. precheck.sql and postcheck.sql end with this exact statement
-- (tests/phase5a10-staff-product-discovery.test.ts keeps the copies identical). Every row is
-- (section, key, value) so outputs can be diffed line by line. It runs before the migration
-- too: tables that do not exist yet read as 'absent'.

SELECT section, key, value FROM (
  -- Functions this phase adds or replaces, the 5A.8B search helpers and 7B.5 functions it
  -- builds on, and request / catalog / budget neighbours it must leave alone: body hash,
  -- SECURITY DEFINER, and who may execute it.
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
    -- Added by 5A.10.
    ('catalog_search_edit_distance'),
    ('catalog_search_text'),
    ('catalog_search_token_pattern'),
    ('get_staff_product_discovery'),
    ('refresh_catalog_vendor_product_search_documents'),
    ('remove_staff_saved_product'),
    ('save_staff_product'),
    ('search_supply_request_products_with_signals'),
    ('staff_saved_product_identity_check'),
    ('supply_request_product_history'),
    ('supply_request_product_identities'),
    ('supply_request_product_search'),
    ('tg_catalog_products_search_document'),
    ('tg_catalog_source_records_search_document'),
    ('tg_catalog_vendor_products_search_document'),
    ('tg_catalog_vendors_search_document'),
    -- Replaced by 5A.10 (same signature and columns, new ranking).
    ('search_supply_request_products'),
    -- 5A.8B search helpers, must not change.
    ('get_catalog_vendor_product_effective_specifications'),
    ('get_supply_request_product_specifications'),
    ('normalize_catalog_search_text'),
    ('normalize_catalog_sku'),
    ('normalize_catalog_sku_match_key'),
    ('normalize_catalog_text'),
    -- Request workflow, commitments and budgets, must not change.
    ('apply_supply_request_transition'),
    ('cancel_submitted_supply_request'),
    ('create_supply_request_commitment'),
    ('decide_supply_request'),
    ('get_supply_request_budget_impact'),
    ('get_supply_request_inventory_identities'),
    ('guard_supply_request_lifecycle'),
    ('list_staff_supply_request_updates'),
    ('release_supply_request_commitment'),
    ('replace_supply_request_items'),
    ('resolve_supply_request_context'),
    ('resolve_supply_request_item_costs'),
    ('submit_supply_request'),
    ('transition_supply_request'),
    ('update_submitted_supply_request'),
    ('get_budget_summary'),
    ('get_budget_purchasing_overview'),
    -- Catalog administration and invoice matching, must not change.
    ('adopt_catalog_vendor_product'),
    ('catalog_product_normalize_row'),
    ('catalog_source_record_preserve_raw'),
    ('catalog_vendor_product_normalize_row'),
    ('get_catalog_vendor_product_admin_detail'),
    ('match_invoice_item_to_catalog_listing'),
    ('search_invoice_line_catalog_listings'),
    ('stock_catalog_vendor_product'),
    ('validate_catalog_parent_link_change'),
    -- 7B.5, must not change (cadence stays as configured; nothing here reads or writes it).
    ('get_inventory_count_freshness'),
    ('get_inventory_count_policy'),
    ('inventory_location_count_freshness'),
    ('set_inventory_count_policy'),
    ('get_inventory_overview')
  ) AS fn(name)

  UNION ALL
  SELECT 2, 'overloads', fn.name, count(p.oid)::text
  FROM (VALUES ('search_supply_request_products'), ('search_supply_request_products_with_signals'),
               ('get_staff_product_discovery'), ('save_staff_product'), ('remove_staff_saved_product')) AS fn(name)
  LEFT JOIN pg_proc p ON p.proname = fn.name
   AND p.pronamespace = 'public'::regnamespace
  GROUP BY fn.name

  UNION ALL
  SELECT 2, 'signature', 'search_supply_request_products',
    coalesce((SELECT pg_get_function_identity_arguments(p.oid) || ' -> ' || pg_get_function_result(p.oid)
              FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'search_supply_request_products'
              ORDER BY p.oid LIMIT 1), 'absent')

  -- Extension: pg_trgm must live in the extensions schema.
  UNION ALL
  SELECT 3, 'extension', 'pg_trgm',
    coalesce((SELECT e.extversion || ' schema=' || n.nspname FROM pg_extension e
              JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'pg_trgm'), 'absent')

  -- New tables: column list, RLS, policies and grants.
  UNION ALL
  SELECT 4, 'table', t.name,
    coalesce((SELECT md5(string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull, ',' ORDER BY a.attnum))
                || ' rls=' || c.relrowsecurity
              FROM pg_class c JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
              WHERE c.oid = to_regclass('public.' || t.name)
              GROUP BY c.relrowsecurity), 'absent')
  FROM (VALUES ('catalog_search_terms'), ('catalog_vendor_product_search_documents'), ('staff_saved_products')) AS t(name)
  UNION ALL
  SELECT 4, 'policies', t.name,
    coalesce((SELECT string_agg(policyname, ',' ORDER BY policyname) FROM pg_policies
              WHERE schemaname = 'public' AND tablename = t.name), 'none')
  FROM (VALUES ('catalog_search_terms'), ('catalog_vendor_product_search_documents'), ('staff_saved_products'),
               ('catalog_products'), ('catalog_vendor_products'), ('products'), ('product_aliases'),
               ('supply_requests'), ('supply_request_items'), ('invoices'), ('invoice_items')) AS t(name)
  UNION ALL
  SELECT 4, 'grants', t.name,
    coalesce((SELECT string_agg(grantee || '=' || privileges, ';' ORDER BY grantee) FROM (
                SELECT grantee, string_agg(privilege_type, ',' ORDER BY privilege_type) AS privileges
                FROM information_schema.role_table_grants
                WHERE table_schema = 'public' AND table_name = t.name
                  AND grantee IN ('anon', 'authenticated', 'service_role', 'PUBLIC')
                GROUP BY grantee) g), 'none')
  FROM (VALUES ('catalog_search_terms'), ('catalog_vendor_product_search_documents'), ('staff_saved_products'),
               ('product_aliases'), ('supply_requests'), ('supply_request_items'), ('invoice_items')) AS t(name)

  -- Indexes on the new tables and on the catalog tables the search reads.
  UNION ALL
  SELECT 5, 'index', c.relname, md5(pg_get_indexdef(ix.indexrelid)) || ' valid=' || ix.indisvalid
  FROM pg_index ix JOIN pg_class c ON c.oid = ix.indexrelid JOIN pg_class t ON t.oid = ix.indrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  WHERE n.nspname = 'public' AND t.relname IN ('catalog_search_terms', 'catalog_vendor_product_search_documents',
    'staff_saved_products', 'catalog_products', 'catalog_vendor_products', 'catalog_vendors', 'catalog_source_records',
    'products', 'vendor_products', 'product_aliases', 'supply_request_items', 'invoice_items')

  -- Triggers on the catalog tables (5A.10 adds six statement triggers).
  UNION ALL
  SELECT 6, 'trigger', c.relname || '.' || tg.tgname, md5(pg_get_triggerdef(tg.oid)) || ' enabled=' || tg.tgenabled::text
  FROM pg_trigger tg JOIN pg_class c ON c.oid = tg.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND NOT tg.tgisinternal
    AND c.relname IN ('catalog_products', 'catalog_vendor_products', 'catalog_vendors', 'catalog_source_records')

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

  -- Data: the catalog, organization products, requests and invoices are unchanged; the new
  -- tables hold one document per catalog vendor product and no Saved Items.
  UNION ALL
  SELECT 8, 'rows', 'catalog_products hash',
    coalesce(md5(string_agg(concat_ws(':', id, name, normalized_name, description, manufacturer, active, verification_status, updated_at), ',' ORDER BY id)), 'empty')
  FROM public.catalog_products
  UNION ALL
  SELECT 8, 'rows', 'catalog_vendor_products hash',
    coalesce(md5(string_agg(concat_ws(':', id, catalog_product_id, catalog_vendor_id, vendor_sku, manufacturer_sku, package_description,
      package_quantity, package_unit, package_status, active, discontinued, verification_status, updated_at), ',' ORDER BY id)), 'empty')
  FROM public.catalog_vendor_products
  UNION ALL
  SELECT 8, 'rows', 'catalog_vendors hash',
    coalesce(md5(string_agg(concat_ws(':', id, name, active, updated_at), ',' ORDER BY id)), 'empty')
  FROM public.catalog_vendors
  UNION ALL
  SELECT 8, 'rows', 'catalog_source_records hash',
    coalesce(md5(string_agg(concat_ws(':', id, matched_catalog_vendor_product_id, resolution_status, raw_variant, updated_at), ',' ORDER BY id)), 'empty')
  FROM public.catalog_source_records
  UNION ALL
  SELECT 8, 'rows', 'products hash',
    coalesce(md5(string_agg(concat_ws(':', id, organization_id, name, active, staff_requestable, catalog_product_id, updated_at), ',' ORDER BY id)), 'empty')
  FROM public.products
  UNION ALL
  SELECT 8, 'rows', 'vendor_products hash',
    coalesce(md5(string_agg(concat_ws(':', id, organization_id, product_id, vendor_id, vendor_sku, catalog_vendor_product_id, active, updated_at), ',' ORDER BY id)), 'empty')
  FROM public.vendor_products
  UNION ALL
  SELECT 8, 'rows', 'product_aliases hash',
    coalesce(md5(string_agg(concat_ws(':', id, product_id, alias), ',' ORDER BY id)), 'empty')
  FROM public.product_aliases
  UNION ALL
  SELECT 8, 'rows', 'supply_requests hash',
    coalesce(md5(string_agg(concat_ws(':', id, status, requested_by, updated_at), ',' ORDER BY id)), 'empty')
  FROM public.supply_requests
  UNION ALL
  SELECT 8, 'rows', 'supply_request_items hash',
    coalesce(md5(string_agg(concat_ws(':', id, supply_request_id, product_id, catalog_vendor_product_id, inventory_item_id, quantity), ',' ORDER BY id)), 'empty')
  FROM public.supply_request_items
  UNION ALL
  SELECT 8, 'rows', 'supply_request_commitments hash',
    coalesce(md5(string_agg(id::text || ':' || status::text || ':' || amount::text, ',' ORDER BY id)), 'empty')
  FROM public.supply_request_commitments
  UNION ALL
  SELECT 8, 'rows', 'invoices hash',
    coalesce(md5(string_agg(concat_ws(':', id, processing_status, posted_at, document_type, total_amount), ',' ORDER BY id)), 'empty')
  FROM public.invoices
  UNION ALL
  SELECT 8, 'rows', 'invoice_items hash',
    coalesce(md5(string_agg(concat_ws(':', id, invoice_id, product_id, vendor_product_id, quantity, total_price), ',' ORDER BY id)), 'empty')
  FROM public.invoice_items
  UNION ALL
  SELECT 8, 'rows', 'inventory_count_policies',
    coalesce((SELECT string_agg(organization_id || ' enabled=' || enabled || ' interval=' || coalesce(interval_days::text, 'null'), ';' ORDER BY organization_id)
              FROM public.inventory_count_policies), 'none')
  UNION ALL
  SELECT 8, 'rows', 'catalog_vendor_products count', count(*)::text FROM public.catalog_vendor_products
  UNION ALL
  SELECT 8, 'rows', t.name || ' count',
    CASE WHEN to_regclass('public.' || t.name) IS NULL THEN 'absent'
      ELSE (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM public.%I', t.name), false, true, '')))[1]::text END
  FROM (VALUES ('catalog_search_terms'), ('catalog_vendor_product_search_documents'), ('staff_saved_products')) AS t(name)
) fingerprint
ORDER BY ord, section, key;
