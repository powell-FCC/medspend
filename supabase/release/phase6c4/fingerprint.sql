-- Phase 6C.4 release fingerprint: one read-only SELECT, safe to paste into the Supabase SQL
-- Editor or run with psql. precheck.sql and postcheck.sql end with this exact statement
-- (tests/phase6c4-release-files.test.ts keeps the copies identical). Every row is
-- (section, key, value) so outputs can be diffed line by line. It runs before the migration
-- too: objects that do not exist yet read as 'absent'.

SELECT section, key, value FROM (
  -- Functions this phase adds, and the invoice, 5A.10, request, budget and inventory functions
  -- it must leave alone: body hash, SECURITY DEFINER, and who may execute it.
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
    -- Added by 6C.4.
    ('create_invoice_upload_batch'),
    ('fail_invoice_batch_segment'),
    ('get_invoice_source_provenance'),
    ('get_invoice_upload_batch'),
    ('invoice_batch_identity_key'),
    ('invoice_batch_name_key'),
    ('list_invoice_upload_batches'),
    ('register_invoice_batch_segment'),
    ('release_invoice_batch_segment'),
    -- Invoice upload, extraction, review, matching, posting and deletion, must not change.
    ('apply_invoice_exact_product_identities'),
    ('confirm_invoice_item_product'),
    ('confirm_invoice_item_product_expected'),
    ('create_invoice_processing_job'),
    ('create_product_from_invoice_item'),
    ('delete_invoice_permanently'),
    ('find_invoice_line_exact_identity'),
    ('forget_invoice_vendor_signatures'),
    ('guard_invoice_item_match_provenance'),
    ('invalidate_derived_invoice_totals'),
    ('match_invoice_item_to_catalog_listing'),
    ('persist_invoice_document_identity'),
    ('post_reviewed_invoice'),
    ('receive_invoice_inventory_item'),
    ('rematch_invoice_vendor_products'),
    ('remember_invoice_vendor_signatures'),
    ('resolve_invoice_exact_product_identities'),
    ('search_invoice_line_catalog_listings'),
    ('seed_structured_invoice_draft'),
    ('unlink_invoice_item_product'),
    -- Organization role helpers, must not change.
    ('has_org_role'),
    ('is_org_admin'),
    ('is_org_member'),
    ('tg_set_updated_at'),
    -- 5A.10 product discovery, must not change.
    ('get_staff_product_discovery'),
    ('remove_staff_saved_product'),
    ('save_staff_product'),
    ('search_supply_request_products'),
    ('search_supply_request_products_with_signals'),
    ('supply_request_product_search'),
    ('refresh_catalog_vendor_product_search_documents'),
    -- Requests, budgets and inventory touched by posting, must not change.
    ('submit_supply_request'),
    ('decide_supply_request'),
    ('create_supply_request_commitment'),
    ('release_supply_request_commitment'),
    ('get_budget_summary'),
    ('get_budget_purchasing_overview'),
    ('get_inventory_overview'),
    ('move_inventory_stock'),
    ('set_inventory_count_policy'),
    -- Request workflow, must not change.
    ('apply_supply_request_transition'),
    ('transition_supply_request'),
    ('guard_supply_request_lifecycle'),
    ('replace_supply_request_items'),
    ('update_submitted_supply_request'),
    ('cancel_submitted_supply_request'),
    ('resolve_supply_request_context'),
    ('resolve_supply_request_item_costs'),
    ('get_supply_request_budget_impact'),
    ('get_supply_request_inventory_identities'),
    ('get_supply_request_product_specifications'),
    ('supply_request_product_history'),
    ('supply_request_product_identities'),
    ('list_staff_supply_request_updates'),
    -- Catalog and search, must not change.
    ('adopt_catalog_vendor_product'),
    ('stock_catalog_vendor_product'),
    ('get_catalog_vendor_product_admin_detail'),
    ('get_catalog_vendor_product_effective_specifications'),
    ('validate_catalog_parent_link_change'),
    -- Catalog normalization and search helpers, must not change.
    ('catalog_product_normalize_row'),
    ('catalog_vendor_product_normalize_row'),
    ('catalog_source_record_preserve_raw'),
    ('catalog_search_text'),
    ('catalog_search_token_pattern'),
    ('catalog_search_edit_distance'),
    ('normalize_catalog_text'),
    ('normalize_catalog_search_text'),
    ('normalize_catalog_sku'),
    ('normalize_catalog_sku_match_key'),
    -- Catalog search-document trigger functions, must not change.
    ('tg_catalog_products_search_document'),
    ('tg_catalog_vendor_products_search_document'),
    ('tg_catalog_source_records_search_document'),
    ('tg_catalog_vendors_search_document'),
    -- Inventory count cadence and 5A.10 Saved Items, must not change.
    ('get_inventory_count_policy'),
    ('get_inventory_count_freshness'),
    ('inventory_location_count_freshness'),
    ('staff_saved_product_identity_check')
  ) AS fn(name)

  UNION ALL
  SELECT 2, 'overloads', fn.name, count(p.oid)::text
  FROM (VALUES ('create_invoice_upload_batch'), ('register_invoice_batch_segment'), ('fail_invoice_batch_segment'),
               ('release_invoice_batch_segment'), ('get_invoice_upload_batch'), ('list_invoice_upload_batches'),
               ('get_invoice_source_provenance'), ('post_reviewed_invoice'), ('delete_invoice_permanently'),
               ('seed_structured_invoice_draft')) AS fn(name)
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
  FROM (VALUES ('invoice_upload_batches'), ('invoice_upload_batch_segments'), ('vendor_invoices'), ('invoice_processing_jobs'),
               ('invoices'), ('invoice_items'), ('inventory_items'), ('inventory_adjustments'), ('inventory_price_history'),
               ('invoice_extraction_runs'), ('invoice_extraction_candidates'), ('invoice_line_items'), ('vendor_identity_signatures'),
               ('vendors'), ('staff_saved_products'), ('catalog_search_terms'), ('catalog_vendor_product_search_documents')) AS t(name)
  UNION ALL
  SELECT 4, 'policies', t.name,
    coalesce((SELECT string_agg(policyname, ',' ORDER BY policyname) FROM pg_policies
              WHERE schemaname = 'public' AND tablename = t.name), 'none')
  FROM (VALUES ('invoice_upload_batches'), ('invoice_upload_batch_segments'), ('vendor_invoices'), ('invoice_processing_jobs'),
               ('invoices'), ('invoice_items'), ('inventory_items'), ('inventory_adjustments'), ('inventory_price_history'),
               ('invoice_extraction_runs'), ('invoice_extraction_candidates'), ('invoice_line_items'), ('vendor_identity_signatures'),
               ('vendors'), ('staff_saved_products'), ('catalog_search_terms'), ('catalog_vendor_product_search_documents')) AS t(name)
  UNION ALL
  SELECT 4, 'grants', t.name,
    coalesce((SELECT string_agg(grantee || '=' || privileges, ';' ORDER BY grantee) FROM (
                SELECT grantee, string_agg(privilege_type, ',' ORDER BY privilege_type) AS privileges
                FROM information_schema.role_table_grants
                WHERE table_schema = 'public' AND table_name = t.name
                  AND grantee IN ('anon', 'authenticated', 'service_role', 'PUBLIC')
                GROUP BY grantee) g), 'none')
  FROM (VALUES ('invoice_upload_batches'), ('invoice_upload_batch_segments'), ('vendor_invoices'), ('invoice_processing_jobs'),
               ('invoices'), ('invoice_items'), ('inventory_items'), ('inventory_adjustments'), ('inventory_price_history'),
               ('invoice_extraction_runs'), ('invoice_extraction_candidates'), ('invoice_line_items'), ('vendor_identity_signatures'),
               ('vendors'), ('staff_saved_products'), ('catalog_search_terms'), ('catalog_vendor_product_search_documents')) AS t(name)

  -- Invoice file storage: the bucket and its owner-only policies, must not change.
  UNION ALL
  SELECT 4, 'storage', 'bucket vendor-invoices',
    coalesce((SELECT 'public=' || public || ' limit=' || coalesce(file_size_limit::text, 'null') || ' types=' || coalesce(array_to_string(allowed_mime_types, ','), 'null')
              FROM storage.buckets WHERE id = 'vendor-invoices'), 'absent')
  UNION ALL
  SELECT 4, 'storage', 'policy ' || policyname, md5(concat_ws(':', cmd, roles::text, qual, with_check))
  FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname LIKE 'vendor_invoices_storage%'

  -- Constraints on the new, the invoice and the 5A.10 tables (primary, unique, foreign and check
  -- keys), including invoices.source_file_id (UNIQUE, ON DELETE SET NULL) and
  -- vendor_invoices.storage_path (UNIQUE), the one-file / one-invoice identity 6C.4 builds on.
  UNION ALL
  SELECT 5, 'constraint', t.relname || '.' || con.conname,
    con.contype::text || ' ' || md5(pg_get_constraintdef(con.oid)) || ' validated=' || con.convalidated
  FROM pg_constraint con JOIN pg_class t ON t.oid = con.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace
  WHERE n.nspname = 'public' AND t.relname IN ('invoice_upload_batches', 'invoice_upload_batch_segments', 'vendor_invoices',
    'invoice_processing_jobs', 'invoices', 'invoice_items', 'invoice_extraction_runs', 'invoice_extraction_candidates',
    'invoice_line_items', 'vendor_identity_signatures', 'vendors', 'staff_saved_products', 'catalog_search_terms',
    'catalog_vendor_product_search_documents')

  -- Indexes and triggers on the new, the invoice and the 5A.10 tables.
  UNION ALL
  SELECT 5, 'index', c.relname, md5(pg_get_indexdef(ix.indexrelid)) || ' valid=' || ix.indisvalid
  FROM pg_index ix JOIN pg_class c ON c.oid = ix.indexrelid JOIN pg_class t ON t.oid = ix.indrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  WHERE n.nspname = 'public' AND t.relname IN ('invoice_upload_batches', 'invoice_upload_batch_segments', 'vendor_invoices',
    'invoice_processing_jobs', 'invoices', 'invoice_items', 'inventory_price_history', 'invoice_extraction_runs',
    'invoice_extraction_candidates', 'invoice_line_items', 'vendor_identity_signatures', 'vendors', 'staff_saved_products',
    'catalog_search_terms', 'catalog_vendor_product_search_documents')
  UNION ALL
  SELECT 6, 'trigger', c.relname || '.' || tg.tgname, md5(pg_get_triggerdef(tg.oid)) || ' enabled=' || tg.tgenabled::text
  FROM pg_trigger tg JOIN pg_class c ON c.oid = tg.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND NOT tg.tgisinternal
    AND c.relname IN ('invoice_upload_batches', 'invoice_upload_batch_segments', 'vendor_invoices', 'invoice_processing_jobs',
      'invoices', 'invoice_items', 'inventory_items', 'inventory_adjustments', 'inventory_price_history',
      'invoice_extraction_runs', 'invoice_extraction_candidates', 'invoice_line_items', 'vendor_identity_signatures', 'vendors',
      'staff_saved_products', 'catalog_search_terms', 'catalog_vendor_product_search_documents')

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

  -- Data: invoices and the invoice pipeline, vendors, inventory (items, balances, adjustments,
  -- transfers, counts), prices, requests and their items, commitments, budgets, organizations,
  -- memberships and the catalog: whole rows, must not change. The new tables are empty.
  UNION ALL
  SELECT 8, 'rows', 'vendor_invoices hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.vendor_invoices r
  UNION ALL
  SELECT 8, 'rows', 'invoice_processing_jobs hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.invoice_processing_jobs r
  UNION ALL
  SELECT 8, 'rows', 'invoices hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.invoices r
  UNION ALL
  SELECT 8, 'rows', 'invoice_items hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.invoice_items r
  UNION ALL
  SELECT 8, 'rows', 'inventory_items hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.inventory_items r
  UNION ALL
  SELECT 8, 'rows', 'inventory_adjustments hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.inventory_adjustments r
  UNION ALL
  SELECT 8, 'rows', 'inventory_price_history hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.inventory_price_history r
  UNION ALL
  SELECT 8, 'rows', 'supply_requests hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.supply_requests r
  UNION ALL
  SELECT 8, 'rows', 'supply_request_commitments hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.supply_request_commitments r
  UNION ALL
  SELECT 8, 'rows', 'organization_budgets hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.organization_budgets r
  UNION ALL
  SELECT 8, 'rows', 'organizations hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.organizations r
  UNION ALL
  SELECT 8, 'rows', 'organization_memberships hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.organization_memberships r
  UNION ALL
  SELECT 8, 'rows', 'products hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.products r
  UNION ALL
  SELECT 8, 'rows', 'vendor_products hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.vendor_products r
  UNION ALL
  SELECT 8, 'rows', 'supply_request_items hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.supply_request_items r
  UNION ALL
  SELECT 8, 'rows', 'catalog_products hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.catalog_products r
  UNION ALL
  SELECT 8, 'rows', 'catalog_vendor_products hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.catalog_vendor_products r
  UNION ALL
  SELECT 8, 'rows', 'catalog_vendors hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.catalog_vendors r
  UNION ALL
  SELECT 8, 'rows', 'catalog_source_records hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.catalog_source_records r
  UNION ALL
  SELECT 8, 'rows', 'product_aliases hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.product_aliases r
  UNION ALL
  SELECT 8, 'rows', 'inventory_location_balances hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.inventory_item_id, r.inventory_location_id)), 'empty') FROM public.inventory_location_balances r
  UNION ALL
  SELECT 8, 'rows', 'inventory_transfers hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.inventory_transfers r
  UNION ALL
  SELECT 8, 'rows', 'inventory_count_sessions hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.inventory_count_sessions r
  UNION ALL
  SELECT 8, 'rows', 'inventory_count_lines hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.inventory_count_lines r
  UNION ALL
  SELECT 8, 'rows', 'invoice_extraction_runs hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.invoice_extraction_runs r
  UNION ALL
  SELECT 8, 'rows', 'invoice_extraction_candidates hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.invoice_extraction_candidates r
  UNION ALL
  SELECT 8, 'rows', 'invoice_line_items hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.invoice_line_items r
  UNION ALL
  SELECT 8, 'rows', 'vendor_identity_signatures hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.vendor_identity_signatures r
  UNION ALL
  SELECT 8, 'rows', 'vendors hash', coalesce(md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)), 'empty') FROM public.vendors r
  UNION ALL
  SELECT 8, 'rows', 'staff_saved_products count', count(*)::text FROM public.staff_saved_products
  UNION ALL
  SELECT 8, 'rows', 'inventory_count_policies',
    coalesce((SELECT string_agg(organization_id || ' enabled=' || enabled || ' interval=' || coalesce(interval_days::text, 'null'), ';' ORDER BY organization_id)
              FROM public.inventory_count_policies), 'none')
  UNION ALL
  SELECT 8, 'rows', t.name || ' count',
    CASE WHEN to_regclass('public.' || t.name) IS NULL THEN 'absent'
      ELSE (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM public.%I', t.name), false, true, '')))[1]::text END
  FROM (VALUES ('invoice_upload_batches'), ('invoice_upload_batch_segments')) AS t(name)
) fingerprint
ORDER BY ord, section, key;
