-- Phase 5A.10 production PRECHECK. Run BEFORE 20261107120000_phase5a10_staff_product_discovery.sql.
--
-- Safe for the Supabase SQL Editor: no psql meta-commands, no transaction control, and no
-- writes (one read-only DO block of assertions, then one SELECT). Paste the whole file and run
-- it once. psql users can run the same file:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F ' | ' -f supabase/release/phase5a10/precheck.sql > phase5a10_pre.txt
--
-- Success: the result grid shows the fingerprint rows. Download them as CSV (phase5a10_pre.csv).
-- STOP: any error.
--
-- Pins the current production foundation: Phase 7B.5 (count cadence; its policy rows are
-- reported, never required to be on or off), the Phase 5A.8B search and its helpers, and the
-- request, commitment, budget and catalog functions this phase must not change.

DO $phase5a10_precheck$
DECLARE
  _stage text := 'precheck';
  _mismatch text;
BEGIN
  IF to_regclass('public.staff_saved_products') IS NOT NULL
     OR to_regclass('public.catalog_vendor_product_search_documents') IS NOT NULL
     OR to_regclass('public.catalog_search_terms') IS NOT NULL
     OR EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public' AND p.proname IN (
                  'catalog_search_edit_distance',
                  'catalog_search_text',
                  'catalog_search_token_pattern',
                  'get_staff_product_discovery',
                  'refresh_catalog_vendor_product_search_documents',
                  'remove_staff_saved_product',
                  'save_staff_product',
                  'search_supply_request_products_with_signals',
                  'staff_saved_product_identity_check',
                  'supply_request_product_history',
                  'supply_request_product_identities',
                  'supply_request_product_search',
                  'tg_catalog_products_search_document',
                  'tg_catalog_source_records_search_document',
                  'tg_catalog_vendor_products_search_document',
                  'tg_catalog_vendors_search_document')) THEN
    RAISE EXCEPTION 'precheck: Phase 5A.10 objects already exist';
  END IF;
  IF to_regnamespace('extensions') IS NULL THEN
    RAISE EXCEPTION 'precheck: the extensions schema is missing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_trgm') THEN
    RAISE EXCEPTION 'precheck: pg_trgm is not available on this project';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
             WHERE e.extname = 'pg_trgm' AND n.nspname <> 'extensions') THEN
    RAISE EXCEPTION 'precheck: pg_trgm is installed outside the extensions schema';
  END IF;
  IF to_regclass('public.inventory_count_policies') IS NULL THEN
    RAISE EXCEPTION 'precheck: Phase 7B.5 is not applied';
  END IF;

  -- Every function this phase builds on or must leave alone is exactly as reviewed.
  FOR _mismatch IN
    SELECT format('%s=%s', expected.name, coalesce((
      SELECT md5(pg_get_functiondef(p.oid)) || ' secdef=' || p.prosecdef
        || ' authenticated=' || has_function_privilege('authenticated', p.oid, 'EXECUTE')
        || ' anon=' || has_function_privilege('anon', p.oid, 'EXECUTE')
        || ' public=' || EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
                                 WHERE acl.grantee = 0 AND acl.privilege_type = 'EXECUTE')
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = expected.name ORDER BY p.oid LIMIT 1), 'absent'))
    FROM (VALUES
      ('adopt_catalog_vendor_product', '97ab80c4553e1ea7969a57fa342f5489 secdef=true authenticated=true anon=false public=false'),
      ('apply_supply_request_transition', '847dd999535fc5eafee807a151f6864e secdef=true authenticated=false anon=false public=false'),
      ('cancel_submitted_supply_request', 'f2bcba7dc4c6656a1eb2b69f9ea7c288 secdef=true authenticated=true anon=false public=false'),
      ('catalog_product_normalize_row', 'd2609d906f0f7beaef6ee5dc79849951 secdef=false authenticated=true anon=true public=true'),
      ('catalog_source_record_preserve_raw', '549935be7fc6aedd41471ee67e90a23d secdef=false authenticated=true anon=true public=true'),
      ('catalog_vendor_product_normalize_row', '0ec51c056c5d6cc8bad184dbe29fab66 secdef=false authenticated=true anon=true public=true'),
      ('create_supply_request_commitment', 'd74eab8279a2a5eedc21801a57d14e95 secdef=true authenticated=false anon=false public=false'),
      ('decide_supply_request', '17f05c0ff76d128f2e3a3b7c3126b2f9 secdef=true authenticated=true anon=false public=false'),
      ('get_budget_purchasing_overview', '030540f377c54c1b4df639d12742b593 secdef=true authenticated=true anon=false public=false'),
      ('get_budget_summary', '532a3be364be6c3400fa6a82220dd43a secdef=true authenticated=true anon=false public=false'),
      ('get_catalog_vendor_product_admin_detail', '167900a9a5b152ecb32c7a1dc0ebb30a secdef=true authenticated=true anon=false public=false'),
      ('get_catalog_vendor_product_effective_specifications', '7acbbfc1e1fc19b85893c945547e73f0 secdef=true authenticated=false anon=false public=false'),
      ('get_inventory_count_freshness', '33d75bc94230dc727420a3b365f255e2 secdef=true authenticated=true anon=false public=false'),
      ('get_inventory_count_policy', 'b92cec9a836b641b4d0f58f7eaa82589 secdef=true authenticated=true anon=false public=false'),
      ('get_inventory_overview', '9babd0fab14f87f4654b369a5a6139d0 secdef=true authenticated=true anon=false public=false'),
      ('get_supply_request_budget_impact', 'ea250586548ea090149a54860e47299f secdef=true authenticated=true anon=false public=false'),
      ('get_supply_request_inventory_identities', 'd3b5b1daa159b6f6abe9bdb78fc611ff secdef=true authenticated=true anon=false public=false'),
      ('get_supply_request_product_specifications', '4c914a7769c077c2cfd94e8ed33b2f30 secdef=true authenticated=true anon=false public=false'),
      ('guard_supply_request_lifecycle', '4f2ab5044e84fbdc5b20a668f1910907 secdef=false authenticated=false anon=false public=false'),
      ('inventory_location_count_freshness', '5645de23a132413acedf54b0ee34170c secdef=false authenticated=false anon=false public=false'),
      ('list_staff_supply_request_updates', '956703dc601e8d41206f21c3ea3036c7 secdef=true authenticated=true anon=false public=false'),
      ('match_invoice_item_to_catalog_listing', '2ee3522c5d13d2984d2e3c600dcbe1e8 secdef=true authenticated=true anon=false public=false'),
      ('normalize_catalog_search_text', 'dae180ffa0ede146636a5ebcab7da586 secdef=false authenticated=false anon=false public=false'),
      ('normalize_catalog_sku', '1d1a67bb250b533e5fd7b828c4b39f5a secdef=false authenticated=true anon=true public=true'),
      ('normalize_catalog_sku_match_key', '148ebc3452ed98c1a9f4fbc8a86cdc2d secdef=false authenticated=true anon=true public=true'),
      ('normalize_catalog_text', 'a8ec380073fed24830de4f4c2787af49 secdef=false authenticated=true anon=true public=true'),
      ('post_reviewed_invoice', '4d0240ce910eb2f583a8b79706c7f8e8 secdef=true authenticated=true anon=false public=false'),
      ('release_supply_request_commitment', '7ad455f53c8915248dccfb942be8fd89 secdef=true authenticated=true anon=false public=false'),
      ('replace_supply_request_items', 'c1534f7c30ac82b958217b31556613e4 secdef=true authenticated=false anon=false public=false'),
      ('resolve_supply_request_context', '0df3406783e0910a7dbf7317bdda272a secdef=true authenticated=false anon=false public=false'),
      ('resolve_supply_request_item_costs', '7cbfbf4a8098c0cf79ea6a36ed6e3e51 secdef=true authenticated=false anon=false public=false'),
      ('search_invoice_line_catalog_listings', '8fed4e9e5b207a840989722b92006852 secdef=true authenticated=true anon=false public=false'),
      ('search_supply_request_products', '4b4140d7a3170e6d046f5a9085ff3c46 secdef=true authenticated=true anon=false public=false'),
      ('set_inventory_count_policy', 'bdf3bf80be552f7a9445d2bc03a7fa4d secdef=true authenticated=true anon=false public=false'),
      ('stock_catalog_vendor_product', '9b1f4ee7e540f8d297bf6b9ce586e2ca secdef=true authenticated=true anon=false public=false'),
      ('submit_supply_request', '553071a2c338931011cd0a0cec6bc8ab secdef=true authenticated=true anon=false public=false'),
      ('transition_supply_request', '6430f28ddd75800c8ac3c95bc813d733 secdef=true authenticated=true anon=true public=false'),
      ('update_submitted_supply_request', '6da72bb6d7bf813a3a226545517ef8dd secdef=true authenticated=true anon=false public=false'),
      ('validate_catalog_parent_link_change', 'd03c36b10a3e5751a659eed4115b2e59 secdef=false authenticated=true anon=true public=false')
    ) AS expected(name, value)
    WHERE coalesce((
      SELECT md5(pg_get_functiondef(p.oid)) || ' secdef=' || p.prosecdef
        || ' authenticated=' || has_function_privilege('authenticated', p.oid, 'EXECUTE')
        || ' anon=' || has_function_privilege('anon', p.oid, 'EXECUTE')
        || ' public=' || EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
                                 WHERE acl.grantee = 0 AND acl.privilege_type = 'EXECUTE')
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = expected.name ORDER BY p.oid LIMIT 1), 'absent') IS DISTINCT FROM expected.value
  LOOP
    RAISE EXCEPTION '%: function is missing or differs from the reviewed production state: %', _stage, _mismatch;
  END LOOP;

  IF (SELECT pg_get_function_identity_arguments(p.oid) || ' -> ' || pg_get_function_result(p.oid)
      FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'search_supply_request_products')
     IS DISTINCT FROM '_organization_id uuid, _query text, _limit integer -> TABLE(result_key text, identity_source text, product_name text, manufacturer text, vendor_name text, vendor_sku text, package_display text, package_status text, inventory_item_id uuid, product_id uuid, vendor_product_id uuid, catalog_vendor_product_id uuid)' THEN
    RAISE EXCEPTION '%: search_supply_request_products signature differs', _stage;
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace) <> 124
     OR (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 43
     OR (SELECT count(*) FROM pg_indexes WHERE schemaname = 'public') <> 165
     OR (SELECT count(*) FROM pg_policies WHERE schemaname = 'public') <> 58
     OR (SELECT count(*) FROM pg_trigger tg JOIN pg_class c ON c.oid = tg.tgrelid
         WHERE c.relnamespace = 'public'::regnamespace AND NOT tg.tgisinternal) <> 69 THEN
    RAISE EXCEPTION '%: public object counts differ from the reviewed state (expected functions 124, tables 43, indexes 165, policies 58, triggers 69)', _stage;
  END IF;
END
$phase5a10_precheck$;

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
    -- Invoice posting (the source of Purchased before), must not change.
    ('post_reviewed_invoice'),
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
  -- Organizations, memberships, budgets and inventory: whole rows, must not change.
  SELECT 8, 'rows', 'organizations hash',
    coalesce(md5(string_agg(to_jsonb(o)::text, ',' ORDER BY o.id)), 'empty')
  FROM public.organizations o
  UNION ALL
  SELECT 8, 'rows', 'organization_memberships hash',
    coalesce(md5(string_agg(to_jsonb(m)::text, ',' ORDER BY m.id)), 'empty')
  FROM public.organization_memberships m
  UNION ALL
  SELECT 8, 'rows', 'organization_budgets hash',
    coalesce(md5(string_agg(to_jsonb(b)::text, ',' ORDER BY b.id)), 'empty')
  FROM public.organization_budgets b
  UNION ALL
  SELECT 8, 'rows', 'inventory_items hash',
    coalesce(md5(string_agg(to_jsonb(i)::text, ',' ORDER BY i.id)), 'empty')
  FROM public.inventory_items i
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
