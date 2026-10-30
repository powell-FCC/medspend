-- Phase 7B.4 production POSTCHECK. Run AFTER 20261030120000_phase7b4_inventory_overview.sql.
--
-- Safe for the Supabase SQL Editor: no psql meta-commands, no transaction control, and no
-- writes (one read-only DO block of assertions, then one SELECT). Paste the whole file and run
-- it once. psql users can run the same file:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F ' | ' -f supabase/release/phase7b4/postcheck.sql > phase7b4_post.txt
--
-- Success: the result grid shows the fingerprint rows (phase7b4_post.csv). Compare them with
-- phase7b4_pre.csv; README.md lists the only lines that may differ.
-- STOP: any error.

DO $phase7b4_postcheck$
DECLARE
  _stage text := 'postcheck';
  _bad bigint;
  _mismatch text;
BEGIN
  -- The 7B.4 overview read: reviewed body, SECURITY DEFINER, STABLE, fixed search_path,
  -- callable by signed-in users only (the owner-or-admin check is inside), never by PUBLIC
  -- or anon, and exactly one overload.
  FOR _mismatch IN
    SELECT format('%s=%s', expected.name, coalesce((
      SELECT string_agg(md5(pg_get_functiondef(p.oid)) || ' secdef=' || p.prosecdef
        || ' authenticated=' || has_function_privilege('authenticated', p.oid, 'EXECUTE')
        || ' anon=' || has_function_privilege('anon', p.oid, 'EXECUTE'), ',')
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = expected.name), 'absent'))
    FROM (VALUES
      ('get_inventory_overview', '9babd0fab14f87f4654b369a5a6139d0 secdef=true authenticated=true anon=false')
    ) AS expected(name, value)
    WHERE (
      SELECT string_agg(md5(pg_get_functiondef(p.oid)) || ' secdef=' || p.prosecdef
        || ' authenticated=' || has_function_privilege('authenticated', p.oid, 'EXECUTE')
        || ' anon=' || has_function_privilege('anon', p.oid, 'EXECUTE'), ',')
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = expected.name
    ) IS DISTINCT FROM expected.value
  LOOP
    RAISE EXCEPTION '%: Phase 7B.4 function is missing or differs from the reviewed state: %', _stage, _mismatch;
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace,
               aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
             WHERE n.nspname = 'public' AND p.proname IN (
               'get_inventory_overview')
               AND (acl.grantee = 0 AND acl.privilege_type = 'EXECUTE' OR p.provolatile <> 's')) THEN
    RAISE EXCEPTION '%: a Phase 7B.4 read function is executable by PUBLIC or not STABLE', _stage;
  END IF;
  IF NOT coalesce((SELECT p.proconfig @> ARRAY['search_path=public'] FROM pg_proc p
                   WHERE p.oid = 'public.get_inventory_overview(uuid, integer)'::regprocedure), false)
     OR (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.proname = 'get_inventory_overview') <> 1 THEN
    RAISE EXCEPTION 'postcheck: the Phase 7B.4 function lost its search_path or has extra overloads';
  END IF;

  -- Phase 7B.3 is applied exactly as reviewed (the hashes and settings its production
  -- postcheck pinned), with its four indexes valid.
  FOR _mismatch IN
    SELECT format('%s=%s', expected.name, coalesce((
      SELECT string_agg(md5(pg_get_functiondef(p.oid)) || ' secdef=' || p.prosecdef
        || ' authenticated=' || has_function_privilege('authenticated', p.oid, 'EXECUTE')
        || ' anon=' || has_function_privilege('anon', p.oid, 'EXECUTE'), ',')
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = expected.name), 'absent'))
    FROM (VALUES
      ('list_inventory_adjustment_history', '91feed7b530af4840f976b2afdff1365 secdef=true authenticated=true anon=false'),
      ('list_inventory_transfer_history', '3eab2bd18e8e7cf85c1ea7d8ae07c9ad secdef=true authenticated=true anon=false')
    ) AS expected(name, value)
    WHERE (
      SELECT string_agg(md5(pg_get_functiondef(p.oid)) || ' secdef=' || p.prosecdef
        || ' authenticated=' || has_function_privilege('authenticated', p.oid, 'EXECUTE')
        || ' anon=' || has_function_privilege('anon', p.oid, 'EXECUTE'), ',')
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = expected.name
    ) IS DISTINCT FROM expected.value
  LOOP
    RAISE EXCEPTION '%: Phase 7B.3 function is missing or differs from the reviewed state: %', _stage, _mismatch;
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace,
               aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
             WHERE n.nspname = 'public' AND p.proname IN (
               'list_inventory_adjustment_history',
               'list_inventory_transfer_history')
               AND (acl.grantee = 0 AND acl.privilege_type = 'EXECUTE' OR p.provolatile <> 's')) THEN
    RAISE EXCEPTION '%: a Phase 7B.3 read function is executable by PUBLIC or not STABLE', _stage;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.proname IN ('list_inventory_adjustment_history', 'list_inventory_transfer_history')
               AND NOT coalesce(p.proconfig @> ARRAY['plan_cache_mode=force_custom_plan', 'search_path=public'], false)) THEN
    RAISE EXCEPTION '%: a Phase 7B.3 function lost its search_path or plan_cache_mode setting', _stage;
  END IF;
  FOR _mismatch IN
    SELECT expected.name FROM (VALUES
      ('inventory_adjustments_manual_org_created_idx', 'CREATE INDEX inventory_adjustments_manual_org_created_idx ON public.inventory_adjustments USING btree (organization_id, created_at DESC, id DESC) WHERE ((source_type = ''manual''::text) OR ((source_type IS NULL) AND (reason <> ''Invoice received''::text)))'),
      ('inventory_transfers_from_created_idx', 'CREATE INDEX inventory_transfers_from_created_idx ON public.inventory_transfers USING btree (from_inventory_location_id, created_at DESC, id DESC)'),
      ('inventory_transfers_org_created_idx', 'CREATE INDEX inventory_transfers_org_created_idx ON public.inventory_transfers USING btree (organization_id, created_at DESC, id DESC)'),
      ('inventory_transfers_to_created_idx', 'CREATE INDEX inventory_transfers_to_created_idx ON public.inventory_transfers USING btree (to_inventory_location_id, created_at DESC, id DESC)')
    ) AS expected(name, definition)
    WHERE NOT EXISTS (SELECT 1 FROM pg_index ix JOIN pg_class c ON c.oid = ix.indexrelid
                      JOIN pg_namespace n ON n.oid = c.relnamespace
                      WHERE n.nspname = 'public' AND c.relname = expected.name
                        AND pg_get_indexdef(ix.indexrelid) = expected.definition AND ix.indisvalid AND ix.indisready)
  LOOP
    RAISE EXCEPTION '%: Phase 7B.3 index is missing, differs or is not valid: %', _stage, _mismatch;
  END LOOP;
  IF (SELECT string_agg(c.relname, ',' ORDER BY c.relname) FROM pg_index ix
      JOIN pg_class c ON c.oid = ix.indexrelid JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND ix.indrelid IN ('public.inventory_transfers'::regclass, 'public.inventory_adjustments'::regclass))
     IS DISTINCT FROM 'inventory_adjustments_count_line_uq,inventory_adjustments_idempotency_uq,inventory_adjustments_invoice_item_receipt_uq,inventory_adjustments_item_created_idx,inventory_adjustments_location_idx,inventory_adjustments_manual_org_created_idx,inventory_adjustments_org_created_idx,inventory_adjustments_pkey,inventory_transfers_from_created_idx,inventory_transfers_idempotency_uq,inventory_transfers_item_created_idx,inventory_transfers_org_created_idx,inventory_transfers_pkey,inventory_transfers_to_created_idx' THEN
    RAISE EXCEPTION '%: indexes on inventory_transfers / inventory_adjustments differ from the reviewed state', _stage;
  END IF;

  -- Phase 7B.2 is applied exactly as reviewed.
  FOR _mismatch IN
    SELECT format('%s=%s', expected.name, coalesce((
      SELECT string_agg(md5(pg_get_functiondef(p.oid)) || ' secdef=' || p.prosecdef
        || ' authenticated=' || has_function_privilege('authenticated', p.oid, 'EXECUTE')
        || ' anon=' || has_function_privilege('anon', p.oid, 'EXECUTE'), ',')
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = expected.name), 'absent'))
    FROM (VALUES
      ('get_inventory_count_session', '282766d69a86d3b4d31be35de847cacb secdef=true authenticated=true anon=false'),
      ('list_inventory_count_history', 'c9197911f5a4242c1d36a20b622de164 secdef=true authenticated=true anon=false')
    ) AS expected(name, value)
    WHERE (
      SELECT string_agg(md5(pg_get_functiondef(p.oid)) || ' secdef=' || p.prosecdef
        || ' authenticated=' || has_function_privilege('authenticated', p.oid, 'EXECUTE')
        || ' anon=' || has_function_privilege('anon', p.oid, 'EXECUTE'), ',')
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = expected.name
    ) IS DISTINCT FROM expected.value
  LOOP
    RAISE EXCEPTION '%: Phase 7B.2 function is missing or differs from the reviewed state: %', _stage, _mismatch;
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace,
               aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
             WHERE n.nspname = 'public' AND p.proname IN (
               'get_inventory_count_session',
               'list_inventory_count_history')
               AND (acl.grantee = 0 AND acl.privilege_type = 'EXECUTE' OR p.provolatile <> 's')) THEN
    RAISE EXCEPTION '%: a Phase 7B.2 read function is executable by PUBLIC or not STABLE', _stage;
  END IF;

  -- Phase 7B.1 is applied exactly as reviewed (the hashes its production postcheck pinned):
  -- SECURITY DEFINER (the stock status helper is a plain immutable expression), callable by
  -- signed-in users only, never by PUBLIC or anon.
  FOR _mismatch IN
    SELECT format('%s=%s', expected.name, coalesce((
      SELECT string_agg(md5(pg_get_functiondef(p.oid)) || ' secdef=' || p.prosecdef
        || ' authenticated=' || has_function_privilege('authenticated', p.oid, 'EXECUTE')
        || ' anon=' || has_function_privilege('anon', p.oid, 'EXECUTE'), ',')
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = expected.name), 'absent'))
    FROM (VALUES
      ('get_inventory_workspace_location', '2c863ab0fcb7e795b185a74483c030cd secdef=true authenticated=true anon=false'),
      ('inventory_workspace_stock_status', 'e2406754ec184cd92fe48da81cb6c142 secdef=false authenticated=false anon=false'),
      ('list_inventory_workspace_item_balances', '7788179b0694e6eab4cd40e320aff054 secdef=true authenticated=true anon=false'),
      ('list_inventory_workspace_items', 'c39f8e63fb919d24cf7b5d6380f7d4d7 secdef=true authenticated=true anon=false'),
      ('list_inventory_workspace_location_stock', '38e67adb2ecec43d6874a584fa753369 secdef=true authenticated=true anon=false'),
      ('list_inventory_workspace_locations', '98a199c42fd221b830bdd8ae89e1637d secdef=true authenticated=true anon=false'),
      ('replace_inventory_location_labels', 'aaef90c0474fea071ea9f04cbb08b338 secdef=true authenticated=true anon=false')
    ) AS expected(name, value)
    WHERE (
      SELECT string_agg(md5(pg_get_functiondef(p.oid)) || ' secdef=' || p.prosecdef
        || ' authenticated=' || has_function_privilege('authenticated', p.oid, 'EXECUTE')
        || ' anon=' || has_function_privilege('anon', p.oid, 'EXECUTE'), ',')
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = expected.name
    ) IS DISTINCT FROM expected.value
  LOOP
    RAISE EXCEPTION '%: Phase 7B.1 function is missing or differs from the reviewed production state: %', _stage, _mismatch;
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace,
               aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
             WHERE n.nspname = 'public' AND p.proname IN (
               'get_inventory_workspace_location',
               'inventory_workspace_stock_status',
               'list_inventory_workspace_item_balances',
               'list_inventory_workspace_items',
               'list_inventory_workspace_location_stock',
               'list_inventory_workspace_locations',
               'replace_inventory_location_labels')
               AND acl.grantee = 0 AND acl.privilege_type = 'EXECUTE') THEN
    RAISE EXCEPTION '%: a Phase 7B.1 function is executable by PUBLIC', _stage;
  END IF;

  -- The 7A.1 and 7A.2 inventory functions and the role helpers are exactly the reviewed
  -- production state (7A.2's production postcheck pinned the same 7A.2 hashes).
  FOR _mismatch IN
    SELECT format('%s=%s', expected.name, coalesce((
      SELECT string_agg(md5(pg_get_functiondef(p.oid)) || ' secdef=' || p.prosecdef
        || ' authenticated=' || has_function_privilege('authenticated', p.oid, 'EXECUTE')
        || ' anon=' || has_function_privilege('anon', p.oid, 'EXECUTE'), ',')
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = expected.name), 'absent'))
    FROM (VALUES
      ('adjust_inventory_location_quantity', 'dac472b1d11b6f94b6315c873c0bfba6 secdef=true authenticated=true anon=false'),
      ('adjust_inventory_quantity', 'e9e178ef7fa6dc4e50441b40adc8e1e9 secdef=true authenticated=true anon=false'),
      ('apply_inventory_location_delta', 'cad102e48b8e69213e773746fae9723a secdef=true authenticated=false anon=false'),
      ('create_inventory_location', '3662f48a85020f72885b7ea6a48a58d2 secdef=true authenticated=true anon=false'),
      ('delete_invoice_permanently', 'ac77d1b05aa44675b295936021189673 secdef=true authenticated=true anon=false'),
      ('ensure_inventory_unassigned_location', '71fbdd1a6d3d7a0681bf0148eea30bc7 secdef=true authenticated=false anon=false'),
      ('inventory_apply_balance_delta', '83513cd3324f6045147a855bec061b64 secdef=true authenticated=false anon=false'),
      ('move_inventory_stock', '70b42f11b495fbdc9a6f06482afabf03 secdef=true authenticated=true anon=false'),
      ('post_reviewed_invoice', '4d0240ce910eb2f583a8b79706c7f8e8 secdef=true authenticated=true anon=false'),
      ('receive_invoice_inventory_item', 'c843e23a4f8b8c432f26acb5dc885570 secdef=true authenticated=true anon=false'),
      ('set_inventory_location_active', 'dd1a39beb2413d5fb5d2d24118d10970 secdef=true authenticated=true anon=false'),
      ('stock_catalog_vendor_product', '9b1f4ee7e540f8d297bf6b9ce586e2ca secdef=true authenticated=true anon=false'),
      ('update_inventory_location', 'f1984811549d0f777b985e5a8a4b220b secdef=true authenticated=true anon=false'),
      ('get_inventory_count_location', '0fd16ffd8bd7b4ba838d07bee4f225de secdef=true authenticated=true anon=false'),
      ('get_supply_request_inventory_identities', 'd3b5b1daa159b6f6abe9bdb78fc611ff secdef=true authenticated=true anon=false'),
      ('inventory_count_replay', 'c93caf62d0404579028eb933c8977694 secdef=true authenticated=false anon=false'),
      ('inventory_count_summary', '6945c76972d2996c5b94d7dc4833db94 secdef=true authenticated=false anon=false'),
      ('inventory_countable_balances', '65d36774df5c82cddb47932d09639723 secdef=true authenticated=false anon=false'),
      ('issue_inventory_location_label', 'e5c9048bca2db27f605e835e350baba5 secdef=true authenticated=true anon=false'),
      ('list_countable_inventory_locations', '9c299a5e832f36e63ad5f3c464dbeba8 secdef=true authenticated=true anon=false'),
      ('list_inventory_location_count_status', 'd9bdb8ed2ede83f259992e254486a572 secdef=true authenticated=true anon=false'),
      ('resolve_inventory_count_label', '312170c722991590b2f332ab435bb939 secdef=true authenticated=true anon=false'),
      ('revoke_inventory_location_labels', 'fe6f45eab789980465c4c8534736d435 secdef=true authenticated=true anon=false'),
      ('submit_inventory_count', '2559d2e249abc188c88be2cba4f5a256 secdef=true authenticated=true anon=false'),
      ('tg_guard_inventory_count_history', 'c4de3b57765ceb7430467ff14ffe4446 secdef=false authenticated=false anon=false'),
      ('tg_guard_inventory_location_label', '141dc82163e9bacc931aefeb31f11c07 secdef=false authenticated=false anon=false'),
      ('has_org_role', '74e88af6a0991e147a488ad4294b0bde secdef=true authenticated=true anon=true'),
      ('is_org_admin', '554b45fe26b7c8acb3fca8e21f4ebe50 secdef=true authenticated=true anon=true'),
      ('is_org_member', 'e365ab5bd1dcf38722d2cd23c475afe9 secdef=true authenticated=true anon=true'),
      ('list_organization_member_identities', '564e24eab910035bc2f316a4eb69287c secdef=true authenticated=true anon=false')
    ) AS expected(name, value)
    WHERE (
      SELECT string_agg(md5(pg_get_functiondef(p.oid)) || ' secdef=' || p.prosecdef
        || ' authenticated=' || has_function_privilege('authenticated', p.oid, 'EXECUTE')
        || ' anon=' || has_function_privilege('anon', p.oid, 'EXECUTE'), ',')
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = expected.name
    ) IS DISTINCT FROM expected.value
  LOOP
    RAISE EXCEPTION '%: function differs from the reviewed production state: %', _stage, _mismatch;
  END LOOP;

  -- Raw inventory table access is the reviewed owner-only state, and 7B.4 must leave it so.
  FOR _mismatch IN
    SELECT format('%s=%s', expected.name, coalesce((
      SELECT md5(string_agg(policyname || ':' || cmd || ':' || coalesce(qual, '') || ':' || coalesce(with_check, ''),
        '|' ORDER BY policyname)) FROM pg_policies WHERE schemaname = 'public' AND tablename = expected.name), 'none'))
    FROM (VALUES
      ('inventory_items', 'd6d085b61726889487645d8230978888'),
      ('inventory_adjustments', '098b947f5b67500480ffc279b160404e'),
      ('inventory_locations', '60a70818372a5df674205ee24e32df9c'),
      ('inventory_location_balances', '0df7a8965dd4c0b7eed50c7bc99fb336'),
      ('inventory_transfers', 'db99d07b8614efa9116fb4fec78ce42c'),
      ('inventory_count_sessions', '578d5341505080758c62fc66968a2d24'),
      ('inventory_count_lines', '2786b6824b2f19fc0943e11ba80156ae'),
      ('inventory_location_labels', 'none')
    ) AS expected(name, value)
    WHERE coalesce((
      SELECT md5(string_agg(policyname || ':' || cmd || ':' || coalesce(qual, '') || ':' || coalesce(with_check, ''),
        '|' ORDER BY policyname)) FROM pg_policies WHERE schemaname = 'public' AND tablename = expected.name), 'none')
      IS DISTINCT FROM expected.value
  LOOP
    RAISE EXCEPTION '%: inventory policies differ from the reviewed state: %', _stage, _mismatch;
  END LOOP;
  IF has_table_privilege('authenticated', 'public.inventory_location_labels', 'SELECT')
     OR has_table_privilege('authenticated', 'public.inventory_locations', 'INSERT')
     OR has_table_privilege('authenticated', 'public.inventory_locations', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.inventory_location_balances', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.inventory_transfers', 'INSERT')
     OR has_table_privilege('authenticated', 'public.inventory_count_sessions', 'INSERT')
     OR has_table_privilege('authenticated', 'public.inventory_adjustments', 'INSERT')
     OR has_table_privilege('anon', 'public.inventory_locations', 'SELECT') THEN
    RAISE EXCEPTION '%: raw inventory table grants differ from the reviewed state', _stage;
  END IF;

  -- The quantity invariant holds.
  SELECT count(*) INTO _bad FROM public.inventory_items item
  WHERE item.quantity <> coalesce((SELECT sum(b.quantity) FROM public.inventory_location_balances b
                                   WHERE b.inventory_item_id = item.id), -1);
  IF _bad <> 0 THEN RAISE EXCEPTION '%: % items differ from their location balances', _stage, _bad; END IF;
  IF to_regprocedure('extensions.gen_random_bytes(integer)') IS NULL
     OR to_regprocedure('extensions.digest(text, text)') IS NULL THEN
    RAISE EXCEPTION '%: pgcrypto (extensions schema) is required', _stage;
  END IF;
END
$phase7b4_postcheck$;

SELECT section, key, value FROM (
  -- Functions this phase adds, the 7B.3, 7B.2, 7B.1, 7A.2 and 7A.1 functions it builds on, and
  -- neighbours it must leave alone: body hash, SECURITY DEFINER, and who may execute it.
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
    -- Added by 7B.4.
    ('get_inventory_overview'),
    -- 7B.3, must not change.
    ('list_inventory_adjustment_history'),
    ('list_inventory_transfer_history'),
    -- 7B.2, must not change.
    ('get_inventory_count_session'),
    ('list_inventory_count_history'),
    -- 7B.1, must not change.
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
    -- Authorization helpers 7B.4 relies on, must not change.
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
    ('list_inventory_count_history'), ('get_inventory_count_session'),
    ('list_inventory_transfer_history'), ('list_inventory_adjustment_history'), ('get_inventory_overview'),
    ('adjust_inventory_quantity'), ('delete_invoice_permanently')) AS fn(name)

  UNION ALL
  SELECT 3, 'constraint', c.name,
    coalesce((SELECT md5(pg_get_constraintdef(con.oid)) FROM pg_constraint con
      WHERE con.conrelid = 'public.inventory_adjustments'::regclass AND con.conname = c.name), 'absent')
  FROM (VALUES ('inventory_adjustments_source_type_check'), ('inventory_adjustments_reason_check'),
    ('inventory_adjustments_physical_count_check'), ('inventory_adjustments_count_line_fk')) AS c(name)

  -- Every index on the two history tables (7B.3 added four; 7B.4 adds none), and the label
  -- and count indexes the overview reads through.
  UNION ALL
  SELECT 3, 'index', i.name,
    coalesce((SELECT md5(pg_get_indexdef(ix.indexrelid)) || ' valid=' || ix.indisvalid FROM pg_index ix
      JOIN pg_class c ON c.oid = ix.indexrelid JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relname = i.name), 'absent')
  FROM (VALUES
    ('inventory_adjustments_count_line_uq'),
    ('inventory_adjustments_idempotency_uq'),
    ('inventory_adjustments_invoice_item_receipt_uq'),
    ('inventory_adjustments_item_created_idx'),
    ('inventory_adjustments_location_idx'),
    ('inventory_adjustments_manual_org_created_idx'),
    ('inventory_adjustments_org_created_idx'),
    ('inventory_adjustments_pkey'),
    ('inventory_transfers_from_created_idx'),
    ('inventory_transfers_idempotency_uq'),
    ('inventory_transfers_item_created_idx'),
    ('inventory_transfers_org_created_idx'),
    ('inventory_transfers_pkey'),
    ('inventory_transfers_to_created_idx'),
    ('inventory_count_lines_item_location_idx'),
    ('inventory_count_sessions_location_submitted_idx'),
    ('inventory_location_balances_org_idx'),
    ('inventory_location_labels_active_idx')
  ) AS i(name)

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

  -- Data. 7B.4 writes no rows; every line here must match before and after.
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
