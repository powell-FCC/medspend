-- Phase 7F.1A release fingerprint: one read-only SELECT, safe to paste into the Supabase SQL
-- Editor or run with psql. precheck.sql and postcheck.sql end with this exact statement
-- (tests/phase7f1a-release-files.test.ts keeps the copies identical). Every row is
-- (section, key, value) so outputs can be diffed line by line. It runs before the migration
-- too: objects that do not exist yet read as 'absent' or are simply not listed.

SELECT section, key, value FROM (
  -- Functions this phase changes, and the catalog, search, adoption, invoice-matching,
  -- request, price and role functions it must leave alone: body hash, SECURITY DEFINER, and
  -- who may execute it.
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
    -- Changed by 7F.1A (same signatures, catalog scope added).
    ('supply_request_product_search'),
    ('supply_request_product_identities'),
    -- Staff search and discovery around them, must not change.
    ('search_supply_request_products'),
    ('search_supply_request_products_with_signals'),
    ('get_staff_product_discovery'),
    ('save_staff_product'),
    ('remove_staff_saved_product'),
    ('staff_saved_product_identity_check'),
    ('supply_request_product_history'),
    ('refresh_catalog_vendor_product_search_documents'),
    ('tg_catalog_vendor_products_search_document'),
    ('tg_catalog_products_search_document'),
    ('tg_catalog_vendors_search_document'),
    ('tg_catalog_source_records_search_document'),
    ('catalog_search_text'),
    ('catalog_search_token_pattern'),
    ('catalog_search_edit_distance'),
    ('normalize_catalog_search_text'),
    ('get_catalog_vendor_product_effective_specifications'),
    ('get_catalog_vendor_product_admin_detail'),
    ('get_supply_request_product_specifications'),
    -- Catalog identity, adoption and vendor linking, must not change.
    ('normalize_catalog_text'),
    ('normalize_catalog_sku'),
    ('normalize_catalog_sku_match_key'),
    ('catalog_normalize_row'),
    ('catalog_product_normalize_row'),
    ('catalog_vendor_product_normalize_row'),
    ('catalog_source_record_normalize_row'),
    ('catalog_source_record_preserve_raw'),
    ('adopt_catalog_vendor_product'),
    ('link_organization_vendor_to_catalog_vendor'),
    ('guard_vendor_catalog_link'),
    ('get_organization_vendor_catalog_coverage'),
    -- Invoice identity and matching, must not change.
    ('match_invoice_item_to_catalog_listing'),
    ('apply_invoice_exact_product_identities'),
    ('search_invoice_line_catalog_listings'),
    ('rematch_invoice_vendor_products'),
    ('confirm_invoice_item_product'),
    ('confirm_invoice_item_product_expected'),
    ('post_reviewed_invoice'),
    -- Requests, must not change.
    ('submit_supply_request'),
    ('decide_supply_request'),
    ('resolve_supply_request_item_costs'),
    -- 6B.1 Price Intelligence, must not change.
    ('price_unit_key'),
    ('price_unit_is_valid'),
    ('price_recency'),
    ('price_catalog_unit_agrees'),
    ('price_package_agreement'),
    ('price_catalog_package_agreement'),
    ('price_row_is_valid'),
    ('price_observation_rows'),
    ('price_recent_anchors'),
    ('price_name_anchors'),
    ('price_observation_evidence'),
    ('price_product_state'),
    ('price_summary_flagged_invoices'),
    ('price_summary_groups'),
    ('price_summary_product_states'),
    ('list_price_intelligence_products'),
    ('get_price_intelligence_summary'),
    ('get_product_vendor_price_history'),
    ('get_supply_request_price_context'),
    ('get_price_intelligence_overview'),
    ('get_product_price_intelligence'),
    -- Roles and shared triggers, must not change.
    ('has_org_role'),
    ('is_org_admin'),
    ('is_org_member'),
    ('tg_set_updated_at')
  ) AS fn(name)

  UNION ALL
  SELECT 2, 'overloads', fn.name, count(p.oid)::text
  FROM (VALUES ('supply_request_product_search'), ('supply_request_product_identities'),
               ('search_supply_request_products'), ('search_supply_request_products_with_signals')) AS fn(name)
  LEFT JOIN pg_proc p ON p.proname = fn.name AND p.pronamespace = 'public'::regnamespace
  GROUP BY fn.name

  -- Server version: the migration uses UNIQUE NULLS NOT DISTINCT (PostgreSQL 15+).
  UNION ALL
  SELECT 3, 'setting', 'server_version_num', CASE WHEN current_setting('server_version_num')::integer >= 150000 THEN '>=150000' ELSE current_setting('server_version_num') END

  -- Catalog, identity and request tables: columns and RLS, policies and client grants.
  UNION ALL
  SELECT 4, 'table', t.name,
    coalesce((SELECT md5(string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull, ',' ORDER BY a.attnum))
                || ' rls=' || c.relrowsecurity
              FROM pg_class c JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
              WHERE c.oid = to_regclass('public.' || t.name)
              GROUP BY c.relrowsecurity), 'absent')
  FROM (VALUES ('catalog_vendors'), ('catalog_categories'), ('catalog_products'), ('catalog_vendor_products'),
               ('catalog_import_batches'), ('catalog_source_records'), ('catalog_verification_overrides'),
               ('catalog_vendor_product_search_documents'), ('catalog_search_terms'),
               ('catalog_brands'), ('catalog_product_families'), ('catalog_concepts'), ('catalog_concept_synonyms'),
               ('catalog_product_concepts'), ('catalog_certification_types'), ('catalog_product_certifications'),
               ('catalog_bundle_components'),
               ('vendors'), ('vendor_products'), ('products'), ('product_aliases'), ('vendor_identity_signatures'),
               ('invoice_items'), ('inventory_price_history'), ('supply_requests'), ('supply_request_items'),
               ('staff_saved_products')) AS t(name)
  UNION ALL
  SELECT 4, 'policies', c.relname,
    coalesce((SELECT string_agg(policyname || ':' || cmd || ':' || array_to_string(roles, '+'), ',' ORDER BY policyname)
              FROM pg_policies WHERE schemaname = 'public' AND tablename = c.relname), 'none')
  FROM pg_class c
  WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
    AND (c.relname LIKE 'catalog\_%' OR c.relname IN ('vendors', 'vendor_products', 'products', 'invoice_items',
      'inventory_price_history', 'supply_request_items', 'vendor_identity_signatures'))
  UNION ALL
  SELECT 4, 'grants', c.relname,
    coalesce((SELECT string_agg(grantee || '=' || privileges, ';' ORDER BY grantee) FROM (
                SELECT grantee, string_agg(privilege_type, ',' ORDER BY privilege_type) AS privileges
                FROM information_schema.role_table_grants
                WHERE table_schema = 'public' AND table_name = c.relname
                  AND grantee IN ('anon', 'authenticated', 'service_role', 'PUBLIC')
                GROUP BY grantee) g), 'none')
  FROM pg_class c
  WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
    AND (c.relname LIKE 'catalog\_%' OR c.relname IN ('vendors', 'vendor_products', 'products', 'invoice_items',
      'inventory_price_history', 'supply_request_items', 'vendor_identity_signatures'))

  -- Indexes and constraints on those tables.
  UNION ALL
  SELECT 5, 'index', c.relname, md5(pg_get_indexdef(ix.indexrelid)) || ' valid=' || ix.indisvalid
  FROM pg_index ix JOIN pg_class c ON c.oid = ix.indexrelid JOIN pg_class t ON t.oid = ix.indrelid
  WHERE t.relnamespace = 'public'::regnamespace
    AND (t.relname LIKE 'catalog\_%' OR t.relname IN ('vendors', 'vendor_products', 'products', 'product_aliases',
      'invoice_items', 'inventory_price_history', 'supply_request_items', 'vendor_identity_signatures', 'staff_saved_products'))
  UNION ALL
  SELECT 5, 'constraint', t.relname || '.' || con.conname,
    con.contype::text || ' ' || md5(pg_get_constraintdef(con.oid)) || ' validated=' || con.convalidated
  FROM pg_constraint con JOIN pg_class t ON t.oid = con.conrelid
  WHERE t.relnamespace = 'public'::regnamespace
    AND (t.relname LIKE 'catalog\_%' OR t.relname IN ('vendors', 'vendor_products', 'products', 'product_aliases',
      'invoice_items', 'inventory_price_history', 'supply_request_items', 'vendor_identity_signatures', 'staff_saved_products'))

  -- Triggers on those tables.
  UNION ALL
  SELECT 6, 'trigger', c.relname || '.' || tg.tgname, md5(pg_get_triggerdef(tg.oid)) || ' enabled=' || tg.tgenabled::text
  FROM pg_trigger tg JOIN pg_class c ON c.oid = tg.tgrelid
  WHERE c.relnamespace = 'public'::regnamespace AND NOT tg.tgisinternal
    AND (c.relname LIKE 'catalog\_%' OR c.relname IN ('vendors', 'vendor_products', 'products', 'product_aliases',
      'invoice_items', 'inventory_price_history', 'supply_requests', 'supply_request_items', 'vendor_identity_signatures'))

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

  -- Data: whole rows of every catalog, identity, invoice, price, request, inventory, budget
  -- and organization table, must not change. The three catalog tables that gain columns are
  -- hashed WITHOUT the new columns (removing an absent key is a no-op before the migration),
  -- so their existing values must be byte-identical.
  UNION ALL
  SELECT 8, 'rows', t.name || ' hash',
    coalesce((xpath('/row/h/text()', query_to_xml(format(
      'SELECT md5(string_agg(j, %L ORDER BY j)) AS h FROM (SELECT (to_jsonb(r) - %L::text[])::text AS j FROM public.%I r) s',
      ',', t.drop_keys, t.name), false, true, '')))[1]::text, 'empty')
  FROM (VALUES
    ('catalog_products', '{brand_id,normalized_mpn,gtin,family_id,attributes,product_kind,purchase_restriction}'),
    ('catalog_vendor_products', '{listing_url,last_seen_batch_id,last_seen_at,availability_status,availability_observed_at}'),
    ('catalog_import_batches', '{source_type,effective_date}'),
    ('catalog_vendors', '{}'), ('catalog_categories', '{}'), ('catalog_source_records', '{}'),
    ('catalog_verification_overrides', '{}'), ('catalog_vendor_product_search_documents', '{}'),
    ('catalog_search_terms', '{}'),
    ('vendors', '{}'), ('vendor_products', '{}'), ('products', '{}'), ('product_aliases', '{}'),
    ('vendor_identity_signatures', '{}'), ('vendor_invoices', '{}'), ('invoices', '{}'), ('invoice_items', '{}'),
    ('inventory_price_history', '{}'), ('supply_requests', '{}'), ('supply_request_items', '{}'),
    ('supply_request_commitments', '{}'), ('supply_request_commitment_items', '{}'), ('staff_saved_products', '{}'),
    ('inventory_items', '{}'), ('inventory_location_balances', '{}'), ('inventory_adjustments', '{}'),
    ('organization_budgets', '{}'), ('organizations', '{}'), ('organization_memberships', '{}'), ('profiles', '{}')
  ) AS t(name, drop_keys)

  -- Catalog shape and the new metadata ('absent' before the migration).
  UNION ALL
  SELECT 9, 'catalog', 'listings per catalog vendor',
    coalesce((SELECT string_agg(v.name || '=' || (SELECT count(*) FROM public.catalog_vendor_products l WHERE l.catalog_vendor_id = v.id), '; ' ORDER BY v.name)
              FROM public.catalog_vendors v), 'none')
  UNION ALL
  SELECT 9, 'catalog', 'catalog products', (SELECT count(*) FROM public.catalog_products)::text
  UNION ALL
  SELECT 9, 'catalog', 'new metadata',
    CASE WHEN to_regclass('public.catalog_brands') IS NULL THEN 'absent'
    ELSE (xpath('/row/v/text()', query_to_xml($meta$
      SELECT 'brands=' || (SELECT count(*) FROM public.catalog_brands)
        || ' concepts=' || (SELECT count(*) FROM public.catalog_concepts)
        || ' synonyms=' || (SELECT count(*) FROM public.catalog_concept_synonyms)
        || ' product_concepts=' || (SELECT count(*) FROM public.catalog_product_concepts)
        || ' families=' || (SELECT count(*) FROM public.catalog_product_families)
        || ' certification_types=' || (SELECT string_agg(code, '+' ORDER BY code) FROM public.catalog_certification_types)
        || ' certifications=' || (SELECT count(*) FROM public.catalog_product_certifications)
        || ' bundle_components=' || (SELECT count(*) FROM public.catalog_bundle_components)
        || ' products_kind_single=' || (SELECT count(*) FROM public.catalog_products WHERE product_kind = 'single')
        || ' products_restriction_unknown=' || (SELECT count(*) FROM public.catalog_products WHERE purchase_restriction = 'unknown')
        || ' products_attributes_empty=' || (SELECT count(*) FROM public.catalog_products WHERE attributes = '{}'::jsonb)
        || ' products_with_brand_family_mpn_gtin=' || (SELECT count(*) FROM public.catalog_products
             WHERE brand_id IS NOT NULL OR family_id IS NOT NULL OR normalized_mpn IS NOT NULL OR gtin IS NOT NULL)
        || ' listings_with_url_seen_availability=' || (SELECT count(*) FROM public.catalog_vendor_products
             WHERE listing_url IS NOT NULL OR last_seen_batch_id IS NOT NULL OR availability_status IS NOT NULL)
        || ' batches_with_source_type_or_date=' || (SELECT count(*) FROM public.catalog_import_batches
             WHERE source_type IS NOT NULL OR effective_date IS NOT NULL) AS v
    $meta$, false, true, '')))[1]::text END

  -- Which catalog vendors each organization's staff search may show after 7F.1A: the
  -- catalog vendors linked to an ACTIVE organization vendor.
  UNION ALL
  SELECT 10, 'catalog scope', o.id::text,
    coalesce((SELECT string_agg(DISTINCT cv.name, '; ' ORDER BY cv.name)
              FROM public.vendors v JOIN public.catalog_vendors cv ON cv.id = v.catalog_vendor_id
              WHERE v.organization_id = o.id AND v.active), 'none')
  FROM public.organizations o
) fingerprint
ORDER BY ord, section, key;
