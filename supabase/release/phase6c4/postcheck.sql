-- Phase 6C.4 production POSTCHECK. Run AFTER 20261109120000_phase6c4_batch_invoice_intake.sql.
--
-- Safe for the Supabase SQL Editor: no psql meta-commands, no transaction control, and no
-- writes (one read-only DO block of assertions, then one SELECT). Paste the whole file and run
-- it once. psql users:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F ' | ' -f supabase/release/phase6c4/postcheck.sql > phase6c4_post.txt
--
-- Success: the result grid shows the fingerprint rows. Download them as CSV (phase6c4_post.csv)
-- and compare with the precheck (README.md lists the only lines that may differ).
-- STOP: any error.

DO $phase6c4_postcheck$
DECLARE
  _stage text := 'postcheck';
  _mismatch text;
BEGIN
  -- The new functions, exactly as reviewed (owner-only client RPCs; two internal helpers).
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
      ('create_invoice_upload_batch', '9950f42a67c3dc033e8d03f17c6bf11d secdef=true authenticated=true anon=false public=false'),
      ('fail_invoice_batch_segment', 'feab01aaf080a9c910978fa440a734b3 secdef=true authenticated=true anon=false public=false'),
      ('get_invoice_source_provenance', '568c956d64b85309c1adb0718387f3ec secdef=true authenticated=true anon=false public=false'),
      ('get_invoice_upload_batch', 'cf8be7a19e3c5e4060ac1561d64e9970 secdef=true authenticated=true anon=false public=false'),
      ('invoice_batch_identity_key', '200233809f09a5a003edaec7cabcff4a secdef=false authenticated=false anon=false public=false'),
      ('invoice_batch_name_key', '5238eb882efe17f86545935654c00a94 secdef=false authenticated=false anon=false public=false'),
      ('list_invoice_upload_batches', '859238d8575f82905e8dea3c450fefce secdef=true authenticated=true anon=false public=false'),
      ('register_invoice_batch_segment', '5f22dde6d4d1748c2957733a546d28b9 secdef=true authenticated=true anon=false public=false'),
      ('release_invoice_batch_segment', '554c71486e1ae6f8dac49ea021cffcde secdef=true authenticated=true anon=false public=false')
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
    RAISE EXCEPTION '%: Phase 6C.4 function is missing or differs from the reviewed migration: %', _stage, _mismatch;
  END LOOP;

  -- Everything the precheck pinned is unchanged.
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
      ('apply_invoice_exact_product_identities', '9a702cb321adf16959785744f45cc20a secdef=false authenticated=false anon=false public=false'),
      ('confirm_invoice_item_product', '2781c677f24e44bce204bf88ccf9aca5 secdef=true authenticated=true anon=false public=false'),
      ('confirm_invoice_item_product_expected', '1d1f4bb36c6708c96452db204acfe7a1 secdef=true authenticated=true anon=false public=false'),
      ('create_invoice_processing_job', '24dc19d1b0570d5e8d3087f42e9a97e7 secdef=true authenticated=true anon=true public=true'),
      ('create_product_from_invoice_item', '336b6af064df8b5b876cd5811fe397ac secdef=true authenticated=true anon=false public=false'),
      ('create_supply_request_commitment', 'd74eab8279a2a5eedc21801a57d14e95 secdef=true authenticated=false anon=false public=false'),
      ('decide_supply_request', '17f05c0ff76d128f2e3a3b7c3126b2f9 secdef=true authenticated=true anon=false public=false'),
      ('delete_invoice_permanently', 'ac77d1b05aa44675b295936021189673 secdef=true authenticated=true anon=false public=false'),
      ('find_invoice_line_exact_identity', '6a45cddafe9ee69a022bb3591a0f025a secdef=false authenticated=false anon=false public=false'),
      ('forget_invoice_vendor_signatures', '778f69e7ca8e04937c1726f0a73a07d5 secdef=true authenticated=true anon=true public=false'),
      ('get_budget_purchasing_overview', '030540f377c54c1b4df639d12742b593 secdef=true authenticated=true anon=false public=false'),
      ('get_budget_summary', '532a3be364be6c3400fa6a82220dd43a secdef=true authenticated=true anon=false public=false'),
      ('get_inventory_overview', '9babd0fab14f87f4654b369a5a6139d0 secdef=true authenticated=true anon=false public=false'),
      ('get_staff_product_discovery', '23d77961bc0a891358e3f0682d78f758 secdef=true authenticated=true anon=false public=false'),
      ('guard_invoice_item_match_provenance', '4d45bef0ba1bd2cf61c7ba44c8715812 secdef=false authenticated=false anon=false public=false'),
      ('has_org_role', '74e88af6a0991e147a488ad4294b0bde secdef=true authenticated=true anon=true public=true'),
      ('invalidate_derived_invoice_totals', '26540281bc8602da1df414e98270cf9b secdef=false authenticated=false anon=false public=false'),
      ('is_org_admin', '554b45fe26b7c8acb3fca8e21f4ebe50 secdef=true authenticated=true anon=true public=true'),
      ('is_org_member', 'e365ab5bd1dcf38722d2cd23c475afe9 secdef=true authenticated=true anon=true public=true'),
      ('match_invoice_item_to_catalog_listing', '2ee3522c5d13d2984d2e3c600dcbe1e8 secdef=true authenticated=true anon=false public=false'),
      ('move_inventory_stock', '70b42f11b495fbdc9a6f06482afabf03 secdef=true authenticated=true anon=false public=false'),
      ('persist_invoice_document_identity', '1e8abdd96c421295039136a615c863db secdef=true authenticated=true anon=true public=false'),
      ('post_reviewed_invoice', '4d0240ce910eb2f583a8b79706c7f8e8 secdef=true authenticated=true anon=false public=false'),
      ('receive_invoice_inventory_item', 'c843e23a4f8b8c432f26acb5dc885570 secdef=true authenticated=true anon=false public=false'),
      ('refresh_catalog_vendor_product_search_documents', 'ee62f1b49263dfef20452e40f6992a4d secdef=true authenticated=false anon=false public=false'),
      ('release_supply_request_commitment', '7ad455f53c8915248dccfb942be8fd89 secdef=true authenticated=true anon=false public=false'),
      ('rematch_invoice_vendor_products', 'cb4bcb1f7f183a350afd196cc62bd1a8 secdef=true authenticated=true anon=false public=false'),
      ('remember_invoice_vendor_signatures', '4d9653286caeb28784b540387b34ac5e secdef=true authenticated=true anon=true public=false'),
      ('remove_staff_saved_product', 'eb416cf398248e3cdfdeb72b9b8de4b9 secdef=true authenticated=true anon=false public=false'),
      ('resolve_invoice_exact_product_identities', 'e245853a555367c01bb466d21ecb5dc8 secdef=true authenticated=true anon=false public=false'),
      ('save_staff_product', 'bca0e5a3e675357882721b37eae19bbd secdef=true authenticated=true anon=false public=false'),
      ('search_invoice_line_catalog_listings', '8fed4e9e5b207a840989722b92006852 secdef=true authenticated=true anon=false public=false'),
      ('search_supply_request_products', 'b322b0915414c552f67d78cb72d9b8dd secdef=true authenticated=true anon=false public=false'),
      ('search_supply_request_products_with_signals', 'a217371fb25320f669b505077d7f8a76 secdef=true authenticated=true anon=false public=false'),
      ('seed_structured_invoice_draft', 'abbc357df8f2ac89d31a48eb51a5232a secdef=true authenticated=true anon=true public=false'),
      ('set_inventory_count_policy', 'bdf3bf80be552f7a9445d2bc03a7fa4d secdef=true authenticated=true anon=false public=false'),
      ('submit_supply_request', '553071a2c338931011cd0a0cec6bc8ab secdef=true authenticated=true anon=false public=false'),
      ('supply_request_product_search', '2dc49f38f7f89e4aa0c00374b1f4f6dc secdef=true authenticated=false anon=false public=false'),
      ('tg_set_updated_at', '494198e1eb8f9c98c4cf075ed9d79bb9 secdef=false authenticated=true anon=true public=true'),
      ('unlink_invoice_item_product', 'eecc3663d5f5c6d2f8801175fc58a026 secdef=true authenticated=true anon=false public=false')
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
    RAISE EXCEPTION '%: function changed during the migration: %', _stage, _mismatch;
  END LOOP;

  -- New tables: exact columns, RLS on, no policies, service_role SELECT only, empty.
  IF (SELECT md5(string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull, ',' ORDER BY a.attnum)) || ' rls=' || bool_and(c.relrowsecurity)
      FROM pg_class c JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
      WHERE c.oid = to_regclass('public.invoice_upload_batches')) IS DISTINCT FROM 'a6d04dceed3df48fdd1726e08dd4b323 rls=true'
     OR (SELECT md5(string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull, ',' ORDER BY a.attnum)) || ' rls=' || bool_and(c.relrowsecurity)
      FROM pg_class c JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
      WHERE c.oid = to_regclass('public.invoice_upload_batch_segments')) IS DISTINCT FROM '214a2989f8719ee06363487e338619eb rls=true' THEN
    RAISE EXCEPTION '%: Phase 6C.4 tables differ from the reviewed migration', _stage;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename IN ('invoice_upload_batches', 'invoice_upload_batch_segments'))
     OR EXISTS (SELECT 1 FROM information_schema.role_table_grants WHERE table_schema = 'public'
                AND table_name IN ('invoice_upload_batches', 'invoice_upload_batch_segments')
                AND (grantee IN ('anon', 'authenticated', 'PUBLIC') OR (grantee = 'service_role' AND privilege_type <> 'SELECT'))) THEN
    RAISE EXCEPTION '%: Phase 6C.4 tables must have no policies and no client grants', _stage;
  END IF;
  IF EXISTS (SELECT 1 FROM public.invoice_upload_batches) OR EXISTS (SELECT 1 FROM public.invoice_upload_batch_segments) THEN
    RAISE EXCEPTION '%: Phase 6C.4 tables are not empty', _stage;
  END IF;
  FOR _mismatch IN
    SELECT expected.name FROM (VALUES
      ('invoice_upload_batch_segments_identity_uq', '7f79d2130523d8f8dd806b3da146dc69 valid=true'),
      ('invoice_upload_batch_segments_index_uq', '15f5d1751cb6c29cb65421808e9ca0b7 valid=true'),
      ('invoice_upload_batch_segments_org_identity_idx', '6c62e542dd81494af02a8a14b603902c valid=true'),
      ('invoice_upload_batch_segments_pkey', '3c15137a8578bccbfa9d6aa984998664 valid=true'),
      ('invoice_upload_batch_segments_source_file_id_key', 'd091c6091673c1802a0bd27c6c4b656d valid=true'),
      ('invoice_upload_batches_id_org_uq', '7a5caddd796e698fa27e5b3b63847c33 valid=true'),
      ('invoice_upload_batches_org_content_uq', '9436962c509606ae70401ce4127530a6 valid=true'),
      ('invoice_upload_batches_org_created_idx', '1c393928b8fb9e6ad7128faf869c3bdd valid=true'),
      ('invoice_upload_batches_pkey', 'b0c4f713457a244b87c551a4068f18ff valid=true'),
      ('invoice_upload_batches_storage_path_key', '158efaefdf4cbda8e1810ae4d07e9938 valid=true')
    ) AS expected(name, value)
    WHERE (SELECT md5(pg_get_indexdef(ix.indexrelid)) || ' valid=' || ix.indisvalid FROM pg_index ix
           JOIN pg_class c ON c.oid = ix.indexrelid JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'public' AND c.relname = expected.name) IS DISTINCT FROM expected.value
  LOOP
    RAISE EXCEPTION '%: index is missing or differs: %', _stage, _mismatch;
  END LOOP;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace) <> 149
     OR (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 48
     OR (SELECT count(*) FROM pg_indexes WHERE schemaname = 'public') <> 181
     OR (SELECT count(*) FROM pg_policies WHERE schemaname = 'public') <> 58
     OR (SELECT count(*) FROM pg_trigger tg JOIN pg_class c ON c.oid = tg.tgrelid
         WHERE c.relnamespace = 'public'::regnamespace AND NOT tg.tgisinternal) <> 76 THEN
    RAISE EXCEPTION '%: public object counts differ from the reviewed state (expected functions 149, tables 48, indexes 181, policies 58, triggers 76)', _stage;
  END IF;
END
$phase6c4_postcheck$;

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
    ('set_inventory_count_policy')
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
               ('invoices'), ('invoice_items'), ('inventory_items'), ('inventory_adjustments'), ('inventory_price_history')) AS t(name)
  UNION ALL
  SELECT 4, 'policies', t.name,
    coalesce((SELECT string_agg(policyname, ',' ORDER BY policyname) FROM pg_policies
              WHERE schemaname = 'public' AND tablename = t.name), 'none')
  FROM (VALUES ('invoice_upload_batches'), ('invoice_upload_batch_segments'), ('vendor_invoices'), ('invoice_processing_jobs'),
               ('invoices'), ('invoice_items'), ('inventory_items'), ('inventory_adjustments'), ('inventory_price_history')) AS t(name)
  UNION ALL
  SELECT 4, 'grants', t.name,
    coalesce((SELECT string_agg(grantee || '=' || privileges, ';' ORDER BY grantee) FROM (
                SELECT grantee, string_agg(privilege_type, ',' ORDER BY privilege_type) AS privileges
                FROM information_schema.role_table_grants
                WHERE table_schema = 'public' AND table_name = t.name
                  AND grantee IN ('anon', 'authenticated', 'service_role', 'PUBLIC')
                GROUP BY grantee) g), 'none')
  FROM (VALUES ('invoice_upload_batches'), ('invoice_upload_batch_segments'), ('vendor_invoices'), ('invoice_processing_jobs'),
               ('invoices'), ('invoice_items'), ('inventory_items'), ('inventory_adjustments'), ('inventory_price_history')) AS t(name)

  -- Invoice file storage: the bucket and its owner-only policies, must not change.
  UNION ALL
  SELECT 4, 'storage', 'bucket vendor-invoices',
    coalesce((SELECT 'public=' || public || ' limit=' || coalesce(file_size_limit::text, 'null') || ' types=' || coalesce(array_to_string(allowed_mime_types, ','), 'null')
              FROM storage.buckets WHERE id = 'vendor-invoices'), 'absent')
  UNION ALL
  SELECT 4, 'storage', 'policy ' || policyname, md5(concat_ws(':', cmd, roles::text, qual, with_check))
  FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname LIKE 'vendor_invoices_storage%'

  -- Indexes and triggers on the new and the invoice tables.
  UNION ALL
  SELECT 5, 'index', c.relname, md5(pg_get_indexdef(ix.indexrelid)) || ' valid=' || ix.indisvalid
  FROM pg_index ix JOIN pg_class c ON c.oid = ix.indexrelid JOIN pg_class t ON t.oid = ix.indrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  WHERE n.nspname = 'public' AND t.relname IN ('invoice_upload_batches', 'invoice_upload_batch_segments', 'vendor_invoices',
    'invoice_processing_jobs', 'invoices', 'invoice_items', 'inventory_price_history')
  UNION ALL
  SELECT 6, 'trigger', c.relname || '.' || tg.tgname, md5(pg_get_triggerdef(tg.oid)) || ' enabled=' || tg.tgenabled::text
  FROM pg_trigger tg JOIN pg_class c ON c.oid = tg.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND NOT tg.tgisinternal
    AND c.relname IN ('invoice_upload_batches', 'invoice_upload_batch_segments', 'vendor_invoices', 'invoice_processing_jobs',
      'invoices', 'invoice_items', 'inventory_items', 'inventory_adjustments', 'inventory_price_history')

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

  -- Data: invoices, inventory, prices, requests, budgets, organizations: whole rows, must not
  -- change. The new tables are empty.
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
