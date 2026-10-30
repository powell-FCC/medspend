-- Phase 7B.4: Inventory Overview (read-only).
--
--   * get_inventory_overview: one owner/admin read returning a snapshot of current inventory
--     state and five factual "needs attention" lists, each as {total, rows} with at most
--     _attention_limit rows. Every rule is deterministic and uses current rows only:
--       unassignedStock          items whose Unassigned balance is > 0
--       neverCountedLocations    active storage locations with at least one countable item
--                                (the 7A.2 rule: item active, or quantity > 0) and no
--                                submitted count session
--       neverCountedItems        items countable at one or more active storage locations
--                                that no immutable count line has ever recorded
--       noActiveLabel            active storage locations with no active QR label
--       archivedWithActiveLabel  archived storage locations that still have an active label
--     Unassigned is never part of a count or label rule. Nothing here is time-based: there
--     is no overdue or stale state (count cadence is a later package).
--
-- Quantities in the snapshot are raw recorded quantities summed across every unit; the
-- application labels them as such and never treats them as comparable or as a value.
-- Recent counts, transfers and adjustments on the Overview come from the existing 7B.2 and
-- 7B.3 read functions with a small page size, and the Unassigned workspace uses the existing
-- 7B.1 location stock read, so this migration adds nothing for them.
--
-- Owners and admins get the same contract; staff, other organizations, non-members and anon
-- are refused.
--
-- Additive and safe to apply before the application deploys: one read function and its
-- grants. No table, column, index, policy, grant on a table, existing function or row
-- changes. Existing indexes serve every lookup (see supabase/release/phase7b4/README.md).

BEGIN;

DO $preflight$
BEGIN
  IF pg_catalog.to_regprocedure('public.list_inventory_transfer_history(uuid, uuid, uuid, uuid, timestamptz, timestamptz, integer, timestamptz, uuid)') IS NULL
     OR pg_catalog.to_regprocedure('public.list_inventory_adjustment_history(uuid, uuid, uuid, uuid, text, timestamptz, timestamptz, integer, timestamptz, uuid)') IS NULL THEN
    RAISE EXCEPTION 'Phase 7B.4 requires the Phase 7B.3 inventory activity functions';
  END IF;
  IF pg_catalog.to_regprocedure('public.list_inventory_count_history(uuid, uuid, uuid, boolean, timestamptz, timestamptz, integer, timestamptz, uuid)') IS NULL
     OR pg_catalog.to_regprocedure('public.list_inventory_workspace_location_stock(uuid, uuid, integer, text, uuid)') IS NULL
     OR pg_catalog.to_regprocedure('public.is_org_admin(uuid, uuid)') IS NULL
     OR pg_catalog.to_regclass('public.inventory_location_labels') IS NULL
     OR pg_catalog.to_regclass('public.inventory_count_lines') IS NULL THEN
    RAISE EXCEPTION 'Phase 7B.4 requires Phase 7B.2, 7B.1 and 7A.2';
  END IF;
  IF pg_catalog.to_regprocedure('public.get_inventory_overview(uuid, integer)') IS NOT NULL
     OR EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public' AND p.proname = 'get_inventory_overview') THEN
    RAISE EXCEPTION 'Phase 7B.4 inventory overview function already exists unexpectedly';
  END IF;
END
$preflight$;

-- Raw inventory table grants and policies before this migration, as one hash kept for the
-- postcheck in a transaction-local setting.
DO $snapshot$
BEGIN
  PERFORM set_config('medspend.phase7b4_raw_access', (SELECT md5(string_agg(entry, '|' ORDER BY entry)) FROM (
         SELECT 'acl:' || c.relname || '=' || coalesce(c.relacl::text, '') AS entry
         FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relname IN ('inventory_items', 'inventory_locations', 'inventory_location_balances',
           'inventory_transfers', 'inventory_adjustments', 'inventory_count_sessions', 'inventory_count_lines',
           'inventory_location_labels')
         UNION ALL
         SELECT 'policy:' || tablename || ':' || policyname || '=' || concat_ws('|', cmd, array_to_string(roles, ','), qual, with_check)
         FROM pg_policies
         WHERE schemaname = 'public' AND tablename IN ('inventory_items', 'inventory_locations', 'inventory_location_balances',
           'inventory_transfers', 'inventory_adjustments', 'inventory_count_sessions', 'inventory_count_lines',
           'inventory_location_labels')) raw_access), true);
END
$snapshot$;

-- ---------------------------------------------------------------------------------------
-- Overview. Lists are ordered by lower(name), id and cut at _attention_limit (1..50); each
-- list reports its full total. Index support: inventory_items_org_active_idx,
-- inventory_location_balances_org_idx, inventory_count_sessions_location_submitted_idx,
-- inventory_count_lines_item_location_idx (item ever counted) and
-- inventory_location_labels_active_idx (active labels per location).
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.get_inventory_overview(_organization_id uuid, _attention_limit integer DEFAULT 10)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _result jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_org_admin(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;
  IF _attention_limit IS NULL OR _attention_limit < 1 OR _attention_limit > 50 THEN
    RAISE EXCEPTION 'Attention list size must be between 1 and 50' USING ERRCODE = '22023';
  END IF;

  WITH locations AS (
    SELECT location.id, location.name, location.kind, location.active
    FROM public.inventory_locations location
    WHERE location.organization_id = _organization_id
  ),
  balances AS (
    SELECT balance.inventory_item_id, balance.inventory_location_id, balance.quantity,
      location.kind, location.active AS location_active, item.active AS item_active
    FROM public.inventory_location_balances balance
    JOIN locations location ON location.id = balance.inventory_location_id
    JOIN public.inventory_items item
      ON item.id = balance.inventory_item_id AND item.organization_id = _organization_id
    WHERE balance.organization_id = _organization_id
  ),
  -- The 7A.2 countability rule, at active storage locations only.
  countable AS (
    SELECT balances.inventory_item_id, balances.inventory_location_id
    FROM balances
    WHERE balances.kind = 'storage' AND balances.location_active
      AND (balances.item_active OR balances.quantity > 0)
  ),
  active_labels AS (
    SELECT label.inventory_location_id, count(*)::integer AS label_count
    FROM public.inventory_location_labels label
    WHERE label.organization_id = _organization_id AND label.revoked_at IS NULL
    GROUP BY label.inventory_location_id
  ),
  unassigned_stock AS (
    SELECT item.id, item.name, item.sku, item.unit, item.active, balances.quantity
    FROM balances
    JOIN public.inventory_items item ON item.id = balances.inventory_item_id
    WHERE balances.kind = 'unassigned' AND balances.quantity > 0
  ),
  never_counted_locations AS (
    SELECT location.id, location.name, count(*)::integer AS countable_items
    FROM locations location
    JOIN countable ON countable.inventory_location_id = location.id
    WHERE location.kind = 'storage' AND location.active
      AND NOT EXISTS (SELECT 1 FROM public.inventory_count_sessions session
                      WHERE session.inventory_location_id = location.id
                        AND session.organization_id = _organization_id)
    GROUP BY location.id, location.name
  ),
  -- One index probe per countable item (inventory_count_lines_item_location_idx), so the cost
  -- follows the number of items, not the length of count history. OFFSET 0 keeps the probe a
  -- per-item subplan instead of a hash anti-join that reads every count line ever written.
  -- Item ids are unique, and the candidates are already this organization's items.
  never_counted_items AS (
    SELECT item.id, item.name, item.sku, item.unit, item.active, counted.location_count
    FROM (SELECT countable.inventory_item_id, count(*)::integer AS location_count
          FROM countable GROUP BY countable.inventory_item_id) counted
    JOIN public.inventory_items item ON item.id = counted.inventory_item_id
    WHERE NOT EXISTS (SELECT 1 FROM public.inventory_count_lines line
                      WHERE line.inventory_item_id = counted.inventory_item_id OFFSET 0)
  ),
  no_active_label AS (
    SELECT location.id, location.name
    FROM locations location
    WHERE location.kind = 'storage' AND location.active
      AND NOT EXISTS (SELECT 1 FROM active_labels WHERE active_labels.inventory_location_id = location.id)
  ),
  archived_with_label AS (
    SELECT location.id, location.name, active_labels.label_count
    FROM locations location
    JOIN active_labels ON active_labels.inventory_location_id = location.id
    WHERE location.kind = 'storage' AND NOT location.active
  )
  SELECT jsonb_build_object(
    'snapshot', jsonb_build_object(
      'activeItemCount', (SELECT count(*) FROM public.inventory_items item
                          WHERE item.organization_id = _organization_id AND item.active),
      'itemsInStockCount', (SELECT count(*) FROM public.inventory_items item
                            WHERE item.organization_id = _organization_id AND item.quantity > 0),
      'recordedQuantity', (SELECT trim_scale(coalesce(sum(item.quantity), 0)) FROM public.inventory_items item
                           WHERE item.organization_id = _organization_id),
      'stockedUnitCount', (SELECT count(DISTINCT lower(btrim(item.unit))) FROM public.inventory_items item
                           WHERE item.organization_id = _organization_id AND item.quantity > 0),
      'activeStorageLocationCount', (SELECT count(*) FROM locations WHERE locations.kind = 'storage' AND locations.active),
      'archivedStorageLocationCount', (SELECT count(*) FROM locations WHERE locations.kind = 'storage' AND NOT locations.active),
      'unassignedLocationId', (SELECT locations.id FROM locations WHERE locations.kind = 'unassigned'),
      'unassignedItemCount', (SELECT count(*) FROM unassigned_stock),
      'unassignedQuantity', (SELECT trim_scale(coalesce(sum(unassigned_stock.quantity), 0)) FROM unassigned_stock)),
    'attention', jsonb_build_object(
      'unassignedStock', jsonb_build_object(
        'total', (SELECT count(*) FROM unassigned_stock),
        'rows', coalesce((SELECT jsonb_agg(jsonb_build_object(
            'inventoryItemId', row.id, 'name', row.name, 'sku', row.sku, 'unit', row.unit,
            'itemActive', row.active, 'quantity', trim_scale(row.quantity)) ORDER BY lower(row.name), row.id)
          FROM (SELECT * FROM unassigned_stock ORDER BY lower(unassigned_stock.name), unassigned_stock.id
                LIMIT _attention_limit) row), '[]'::jsonb)),
      'neverCountedLocations', jsonb_build_object(
        'total', (SELECT count(*) FROM never_counted_locations),
        'rows', coalesce((SELECT jsonb_agg(jsonb_build_object(
            'locationId', row.id, 'name', row.name, 'countableItemCount', row.countable_items)
            ORDER BY lower(row.name), row.id)
          FROM (SELECT * FROM never_counted_locations ORDER BY lower(never_counted_locations.name), never_counted_locations.id
                LIMIT _attention_limit) row), '[]'::jsonb)),
      'neverCountedItems', jsonb_build_object(
        'total', (SELECT count(*) FROM never_counted_items),
        'rows', coalesce((SELECT jsonb_agg(jsonb_build_object(
            'inventoryItemId', row.id, 'name', row.name, 'sku', row.sku, 'unit', row.unit,
            'itemActive', row.active, 'locationCount', row.location_count) ORDER BY lower(row.name), row.id)
          FROM (SELECT * FROM never_counted_items ORDER BY lower(never_counted_items.name), never_counted_items.id
                LIMIT _attention_limit) row), '[]'::jsonb)),
      'noActiveLabel', jsonb_build_object(
        'total', (SELECT count(*) FROM no_active_label),
        'rows', coalesce((SELECT jsonb_agg(jsonb_build_object('locationId', row.id, 'name', row.name)
            ORDER BY lower(row.name), row.id)
          FROM (SELECT * FROM no_active_label ORDER BY lower(no_active_label.name), no_active_label.id
                LIMIT _attention_limit) row), '[]'::jsonb)),
      'archivedWithActiveLabel', jsonb_build_object(
        'total', (SELECT count(*) FROM archived_with_label),
        'rows', coalesce((SELECT jsonb_agg(jsonb_build_object(
            'locationId', row.id, 'name', row.name, 'activeLabelCount', row.label_count)
            ORDER BY lower(row.name), row.id)
          FROM (SELECT * FROM archived_with_label ORDER BY lower(archived_with_label.name), archived_with_label.id
                LIMIT _attention_limit) row), '[]'::jsonb))))
  INTO _result;
  RETURN _result;
END;
$$;
REVOKE ALL ON FUNCTION public.get_inventory_overview(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_inventory_overview(uuid, integer) TO authenticated;

COMMENT ON FUNCTION public.get_inventory_overview(uuid, integer) IS
  'Owner/admin: current inventory snapshot and factual needs-attention lists (Unassigned stock, never counted, label state). No time-based rules. Read-only.';

-- ---------------------------------------------------------------------------------------
-- In-migration postcheck. Any failure rolls the whole migration back.
-- ---------------------------------------------------------------------------------------
DO $postcheck$
DECLARE
  _fn regprocedure := 'public.get_inventory_overview(uuid, integer)'::regprocedure;
BEGIN
  IF NOT has_function_privilege('authenticated', _fn, 'EXECUTE')
     OR has_function_privilege('anon', _fn, 'EXECUTE')
     OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
                WHERE p.oid = _fn AND acl.grantee = 0 AND acl.privilege_type = 'EXECUTE')
     OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = _fn)
     OR (SELECT provolatile FROM pg_proc WHERE oid = _fn) <> 's' THEN
    RAISE EXCEPTION 'Phase 7B.4 postcheck: unexpected security, volatility or grants on %', _fn;
  END IF;
  IF current_setting('medspend.phase7b4_raw_access', true) IS DISTINCT FROM (SELECT md5(string_agg(entry, '|' ORDER BY entry)) FROM (
         SELECT 'acl:' || c.relname || '=' || coalesce(c.relacl::text, '') AS entry
         FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relname IN ('inventory_items', 'inventory_locations', 'inventory_location_balances',
           'inventory_transfers', 'inventory_adjustments', 'inventory_count_sessions', 'inventory_count_lines',
           'inventory_location_labels')
         UNION ALL
         SELECT 'policy:' || tablename || ':' || policyname || '=' || concat_ws('|', cmd, array_to_string(roles, ','), qual, with_check)
         FROM pg_policies
         WHERE schemaname = 'public' AND tablename IN ('inventory_items', 'inventory_locations', 'inventory_location_balances',
           'inventory_transfers', 'inventory_adjustments', 'inventory_count_sessions', 'inventory_count_lines',
           'inventory_location_labels')) raw_access) THEN
    RAISE EXCEPTION 'Phase 7B.4 postcheck: raw inventory table access changed';
  END IF;
END
$postcheck$;

COMMIT;
