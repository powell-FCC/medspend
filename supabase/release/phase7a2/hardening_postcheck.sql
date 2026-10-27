-- Phase 7A.2-0 production HARDENING POSTCHECK. Run AFTER
-- 20261027120100_phase7a2_staff_inventory_read_hardening.sql, which itself runs only after the
-- 7A.2 application is deployed.
--
-- Safe for the Supabase SQL Editor: no psql meta-commands, no transaction control, and no
-- writes (one read-only DO block of assertions, then one SELECT). psql users:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F ' | ' -f supabase/release/phase7a2/hardening_postcheck.sql > phase7a2_hardened.txt
--   diff phase7a2_post.txt phase7a2_hardened.txt
--
-- Success: the fingerprint rows. Compared with the postcheck output, only
-- 'policies | inventory_items' and 'count | public policies' (unchanged count: one policy
-- replaced by another) may differ, plus any count or label rows written by real use.
-- STOP: any error.

DO $phase7a2_hardening_postcheck$
DECLARE
  _stage text := 'hardening postcheck';
  _bad bigint;
  _mismatch text;
BEGIN
  IF to_regclass('public.inventory_count_sessions') IS NULL THEN
    RAISE EXCEPTION 'hardening postcheck: Phase 7A.2 is not applied';
  END IF;

  -- The 7A.1 foundation is exactly the reviewed production state.
  FOR _mismatch IN
    SELECT format('%s=%s', expected.name, coalesce((
      SELECT string_agg(md5(pg_get_functiondef(p.oid)), ',') FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = expected.name), 'absent'))
    FROM (VALUES
      ('adjust_inventory_location_quantity', 'dac472b1d11b6f94b6315c873c0bfba6'),
      ('adjust_inventory_quantity', 'e9e178ef7fa6dc4e50441b40adc8e1e9'),
      ('apply_inventory_location_delta', 'cad102e48b8e69213e773746fae9723a'),
      ('create_inventory_location', '3662f48a85020f72885b7ea6a48a58d2'),
      ('delete_invoice_permanently', 'ac77d1b05aa44675b295936021189673'),
      ('ensure_inventory_unassigned_location', '71fbdd1a6d3d7a0681bf0148eea30bc7'),
      ('inventory_apply_balance_delta', '83513cd3324f6045147a855bec061b64'),
      ('move_inventory_stock', '70b42f11b495fbdc9a6f06482afabf03'),
      ('post_reviewed_invoice', '4d0240ce910eb2f583a8b79706c7f8e8'),
      ('receive_invoice_inventory_item', 'c843e23a4f8b8c432f26acb5dc885570'),
      ('set_inventory_location_active', 'dd1a39beb2413d5fb5d2d24118d10970'),
      ('stock_catalog_vendor_product', '9b1f4ee7e540f8d297bf6b9ce586e2ca'),
      ('update_inventory_location', 'f1984811549d0f777b985e5a8a4b220b')
    ) AS expected(name, md5)
    WHERE (
      SELECT string_agg(md5(pg_get_functiondef(p.oid)), ',') FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = expected.name
    ) IS DISTINCT FROM expected.md5
  LOOP
    RAISE EXCEPTION '%: Phase 7A.1 function differs from the reviewed production state: %', _stage, _mismatch;
  END LOOP;
  IF (SELECT md5(pg_get_constraintdef(oid)) FROM pg_constraint
      WHERE conrelid = 'public.inventory_adjustments'::regclass AND conname = 'inventory_adjustments_source_type_check')
     IS DISTINCT FROM '094e8bf3ca6e33940e1c8ca6cf2c96be' THEN
    RAISE EXCEPTION '%: inventory_adjustments_source_type_check differs from Phase 7A.1', _stage;
  END IF;
  IF has_function_privilege('anon', 'public.delete_invoice_permanently(uuid, uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.inventory_apply_balance_delta(uuid, uuid, uuid, numeric)', 'EXECUTE') THEN
    RAISE EXCEPTION '%: Phase 7A.1 grants differ from the reviewed production state', _stage;
  END IF;

  -- The quantity invariant holds.
  SELECT count(*) INTO _bad FROM public.inventory_items item
  WHERE item.quantity <> coalesce((SELECT sum(b.quantity) FROM public.inventory_location_balances b
                                   WHERE b.inventory_item_id = item.id), -1);
  IF _bad <> 0 THEN RAISE EXCEPTION '%: % items differ from their location balances', _stage, _bad; END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'inventory_items'
             AND policyname = 'inventory_items_member_select') THEN
    RAISE EXCEPTION 'hardening postcheck: staff can still read inventory_items directly';
  END IF;
  IF (SELECT md5(string_agg(policyname || ':' || cmd || ':' || coalesce(qual, '') || ':' || coalesce(with_check, ''),
        '|' ORDER BY policyname)) FROM pg_policies WHERE schemaname = 'public' AND tablename = 'inventory_items')
     IS DISTINCT FROM 'd6d085b61726889487645d8230978888' THEN
    RAISE EXCEPTION 'hardening postcheck: inventory_items policies differ from the reviewed hardening';
  END IF;
  IF (SELECT md5(pg_get_functiondef('public.get_supply_request_inventory_identities(uuid, uuid[])'::regprocedure)))
     IS DISTINCT FROM 'd3b5b1daa159b6f6abe9bdb78fc611ff' THEN
    RAISE EXCEPTION 'hardening postcheck: get_supply_request_inventory_identities differs from the reviewed migration';
  END IF;
END
$phase7a2_hardening_postcheck$;

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
    -- Added by 7A.2.
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
    ('issue_inventory_location_label'), ('adjust_inventory_quantity'), ('delete_invoice_permanently')) AS fn(name)

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
    ('products'), ('supply_requests'), ('supply_request_items')) AS t(name)
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
    ('inventory_transfers'), ('inventory_count_sessions'), ('inventory_count_lines'), ('inventory_location_labels')) AS t(name)

  -- Data. 7A.2 writes no rows; every line here must match before and after.
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
