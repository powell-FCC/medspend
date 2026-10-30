-- Phase 7B.3: Inventory activity history: transfers and manual adjustments (read-only).
--
--   * list_inventory_transfer_history: stock moves between locations, newest first, filtered
--     by location (either side), item, person and date in the database, keyset paged on
--     (created_at DESC, id DESC).
--   * list_inventory_adjustment_history: manual quantity adjustments only, same paging and
--     filters plus reason. Physical-count corrections (source_type 'physical_count') stay in
--     Counts (7B.2) and are never returned here. Invoice receipts (source_type 'invoice', and
--     pre-provenance rows whose reason is 'Invoice received') are excluded too: they belong to
--     their invoice, are removed when the invoice is deleted, and the future receiving
--     packages own them. A row is "manual" when source_type = 'manual', or when it predates
--     adjustment provenance (source_type IS NULL) and is not a receipt.
--
-- previous_quantity / new_quantity on inventory_adjustments are the item's ORGANIZATION
-- total before and after the change (all locations), not the location's balance; the schema
-- stores no per-location before/after. They are returned as stored. No item or location name
-- snapshot exists on either table, so names are current display identities.
--
-- Owners and admins get the same contract; staff, other organizations, non-members and anon
-- are refused. The acting person is resolved through list_organization_member_identities, as
-- in 7B.1/7B.2: no current membership means "Former member".
--
-- Additive: two read functions, their grants, and four indexes whose need was shown with
-- query plans (see supabase/release/phase7b3/README.md). Three are on inventory_transfers,
-- which had only an item index, so every organization or location page read the whole
-- organization's transfer history and sorted it. One is a partial index on
-- inventory_adjustments limited to manual rows: physical-count corrections (one row per
-- changed count line) dominate that table, and the existing organization index made every
-- page step over them. Count submissions never write the partial index. Location and item
-- adjustment pages are already served by the existing location and item indexes. No table,
-- column, policy, grant on a table, existing function or row changes.

BEGIN;

DO $preflight$
BEGIN
  IF pg_catalog.to_regclass('public.inventory_transfers') IS NULL
     OR pg_catalog.to_regprocedure('public.move_inventory_stock(uuid, uuid, uuid, uuid, numeric, text)') IS NULL THEN
    RAISE EXCEPTION 'Phase 7B.3 requires the Phase 7A.1 location-aware inventory foundation';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conrelid = 'public.inventory_adjustments'::regclass
                   AND conname = 'inventory_adjustments_physical_count_check') THEN
    RAISE EXCEPTION 'Phase 7B.3 requires the Phase 7A.2 physical-count adjustment constraint';
  END IF;
  IF pg_catalog.to_regprocedure('public.list_inventory_count_history(uuid, uuid, uuid, boolean, timestamptz, timestamptz, integer, timestamptz, uuid)') IS NULL
     OR pg_catalog.to_regprocedure('public.is_org_admin(uuid, uuid)') IS NULL
     OR pg_catalog.to_regprocedure('public.list_organization_member_identities(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Phase 7B.3 requires Phase 7B.2 count history, is_org_admin and list_organization_member_identities';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.proname IN (
               'list_inventory_transfer_history', 'list_inventory_adjustment_history'))
     OR pg_catalog.to_regclass('public.inventory_transfers_org_created_idx') IS NOT NULL
     OR pg_catalog.to_regclass('public.inventory_transfers_from_created_idx') IS NOT NULL
     OR pg_catalog.to_regclass('public.inventory_transfers_to_created_idx') IS NOT NULL
     OR pg_catalog.to_regclass('public.inventory_adjustments_manual_org_created_idx') IS NOT NULL THEN
    RAISE EXCEPTION 'Phase 7B.3 activity history objects already exist unexpectedly';
  END IF;
END
$preflight$;

-- Raw inventory table grants and policies before this migration, as one hash kept for the
-- postcheck in a transaction-local setting. (inventory_adjustments already carries broad
-- default-privilege grants on some projects, limited by its owner-only SELECT policy; this
-- migration leaves them alone.)
DO $snapshot$
BEGIN
  PERFORM set_config('medspend.phase7b3_raw_access', (SELECT md5(string_agg(entry, '|' ORDER BY entry)) FROM (
         SELECT 'acl:' || c.relname || '=' || coalesce(c.relacl::text, '') AS entry
         FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relname IN ('inventory_items', 'inventory_locations', 'inventory_location_balances',
           'inventory_transfers', 'inventory_adjustments', 'inventory_count_sessions', 'inventory_count_lines')
         UNION ALL
         SELECT 'policy:' || tablename || ':' || policyname || '=' || concat_ws('|', cmd, array_to_string(roles, ','), qual, with_check)
         FROM pg_policies
         WHERE schemaname = 'public' AND tablename IN ('inventory_items', 'inventory_locations', 'inventory_location_balances',
           'inventory_transfers', 'inventory_adjustments', 'inventory_count_sessions', 'inventory_count_lines')) raw_access), true);
END
$snapshot$;

-- ---------------------------------------------------------------------------------------
-- Indexes. Each matches one ordered scan below: equality on the leading column, then
-- (created_at DESC, id DESC), the keyset order.
-- ---------------------------------------------------------------------------------------
CREATE INDEX inventory_transfers_org_created_idx
  ON public.inventory_transfers (organization_id, created_at DESC, id DESC);
CREATE INDEX inventory_transfers_from_created_idx
  ON public.inventory_transfers (from_inventory_location_id, created_at DESC, id DESC);
CREATE INDEX inventory_transfers_to_created_idx
  ON public.inventory_transfers (to_inventory_location_id, created_at DESC, id DESC);
CREATE INDEX inventory_adjustments_manual_org_created_idx
  ON public.inventory_adjustments (organization_id, created_at DESC, id DESC)
  WHERE (source_type = 'manual' OR (source_type IS NULL AND reason <> 'Invoice received'));

-- ---------------------------------------------------------------------------------------
-- Transfer history. Newest first. Filters (all optional, combined with AND):
--   _inventory_location_id  transfers out of OR into this location
--   _inventory_item_id      one item
--   _created_by             one person (user id)
--   _created_from           created_at >= this (inclusive)
--   _created_before         created_at <  this (exclusive)
-- Keyset cursor: (_after_created_at, _after_id) from the previous page's last row.
--
-- The location filter is two ordered scans (out, in) merged; a move never has the same
-- location on both sides, so nothing is returned twice. plan_cache_mode forces a plan per
-- call, so a NULL filter folds away instead of hiding the index behind "IS NULL OR".
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.list_inventory_transfer_history(
  _organization_id uuid,
  _inventory_location_id uuid DEFAULT NULL,
  _inventory_item_id uuid DEFAULT NULL,
  _created_by uuid DEFAULT NULL,
  _created_from timestamptz DEFAULT NULL,
  _created_before timestamptz DEFAULT NULL,
  _limit integer DEFAULT 50,
  _after_created_at timestamptz DEFAULT NULL,
  _after_id uuid DEFAULT NULL
)
RETURNS TABLE (
  transfer_id uuid,
  created_at timestamptz,
  inventory_item_id uuid,
  item_name text,
  item_sku text,
  item_unit text,
  quantity numeric,
  from_location_id uuid,
  from_location_name text,
  to_location_id uuid,
  to_location_name text,
  created_by uuid,
  created_by_name text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET plan_cache_mode = force_custom_plan
AS $$
#variable_conflict use_column
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_org_admin(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;
  IF _limit IS NULL OR _limit < 1 OR _limit > 200 THEN
    RAISE EXCEPTION 'Page size must be between 1 and 200' USING ERRCODE = '22023';
  END IF;
  IF (_after_id IS NULL) <> (_after_created_at IS NULL) THEN
    RAISE EXCEPTION 'An incomplete page cursor was supplied' USING ERRCODE = '22023';
  END IF;
  IF _created_from IS NOT NULL AND _created_before IS NOT NULL AND _created_from >= _created_before THEN
    RAISE EXCEPTION 'The start of the date range must be before its end' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  WITH page AS (
    SELECT candidate.* FROM (
      (SELECT transfer.id, transfer.created_at, transfer.inventory_item_id, transfer.quantity,
         transfer.from_inventory_location_id, transfer.to_inventory_location_id, transfer.created_by
       FROM public.inventory_transfers transfer
       WHERE _inventory_location_id IS NULL
         AND transfer.organization_id = _organization_id
         AND (_inventory_item_id IS NULL OR transfer.inventory_item_id = _inventory_item_id)
         AND (_created_by IS NULL OR transfer.created_by = _created_by)
         AND (_created_from IS NULL OR transfer.created_at >= _created_from)
         AND (_created_before IS NULL OR transfer.created_at < _created_before)
         AND (_after_id IS NULL OR (transfer.created_at, transfer.id) < (_after_created_at, _after_id))
       ORDER BY transfer.created_at DESC, transfer.id DESC
       LIMIT _limit)
      UNION ALL
      (SELECT transfer.id, transfer.created_at, transfer.inventory_item_id, transfer.quantity,
         transfer.from_inventory_location_id, transfer.to_inventory_location_id, transfer.created_by
       FROM public.inventory_transfers transfer
       WHERE transfer.from_inventory_location_id = _inventory_location_id
         AND transfer.organization_id = _organization_id
         AND (_inventory_item_id IS NULL OR transfer.inventory_item_id = _inventory_item_id)
         AND (_created_by IS NULL OR transfer.created_by = _created_by)
         AND (_created_from IS NULL OR transfer.created_at >= _created_from)
         AND (_created_before IS NULL OR transfer.created_at < _created_before)
         AND (_after_id IS NULL OR (transfer.created_at, transfer.id) < (_after_created_at, _after_id))
       ORDER BY transfer.created_at DESC, transfer.id DESC
       LIMIT _limit)
      UNION ALL
      (SELECT transfer.id, transfer.created_at, transfer.inventory_item_id, transfer.quantity,
         transfer.from_inventory_location_id, transfer.to_inventory_location_id, transfer.created_by
       FROM public.inventory_transfers transfer
       WHERE transfer.to_inventory_location_id = _inventory_location_id
         AND transfer.organization_id = _organization_id
         AND (_inventory_item_id IS NULL OR transfer.inventory_item_id = _inventory_item_id)
         AND (_created_by IS NULL OR transfer.created_by = _created_by)
         AND (_created_from IS NULL OR transfer.created_at >= _created_from)
         AND (_created_before IS NULL OR transfer.created_at < _created_before)
         AND (_after_id IS NULL OR (transfer.created_at, transfer.id) < (_after_created_at, _after_id))
       ORDER BY transfer.created_at DESC, transfer.id DESC
       LIMIT _limit)
    ) candidate
    ORDER BY candidate.created_at DESC, candidate.id DESC
    LIMIT _limit
  ),
  identities AS (
    SELECT identity.user_id, identity.display_name
    FROM public.list_organization_member_identities(_organization_id) identity
    WHERE identity.user_id IN (SELECT page.created_by FROM page)
  )
  SELECT page.id, page.created_at, page.inventory_item_id, item.name, item.sku, item.unit,
    trim_scale(page.quantity), page.from_inventory_location_id, from_location.name,
    page.to_inventory_location_id, to_location.name, page.created_by,
    coalesce(identities.display_name, 'Former member')
  FROM page
  JOIN public.inventory_items item
    ON item.id = page.inventory_item_id AND item.organization_id = _organization_id
  JOIN public.inventory_locations from_location
    ON from_location.id = page.from_inventory_location_id AND from_location.organization_id = _organization_id
  JOIN public.inventory_locations to_location
    ON to_location.id = page.to_inventory_location_id AND to_location.organization_id = _organization_id
  LEFT JOIN identities ON identities.user_id = page.created_by
  ORDER BY page.created_at DESC, page.id DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.list_inventory_transfer_history(uuid, uuid, uuid, uuid, timestamptz, timestamptz, integer, timestamptz, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_inventory_transfer_history(uuid, uuid, uuid, uuid, timestamptz, timestamptz, integer, timestamptz, uuid) TO authenticated;

-- ---------------------------------------------------------------------------------------
-- Manual adjustment history. Newest first. Filters as for transfers, plus _reason (one
-- stored reason). _inventory_location_id matches the adjusted location; rows written before
-- Phase 7A.1 have no location and appear only unfiltered by location. 'Physical count' is
-- not a reason this history holds, so asking for it is refused rather than answered empty.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.list_inventory_adjustment_history(
  _organization_id uuid,
  _inventory_location_id uuid DEFAULT NULL,
  _inventory_item_id uuid DEFAULT NULL,
  _created_by uuid DEFAULT NULL,
  _reason text DEFAULT NULL,
  _created_from timestamptz DEFAULT NULL,
  _created_before timestamptz DEFAULT NULL,
  _limit integer DEFAULT 50,
  _after_created_at timestamptz DEFAULT NULL,
  _after_id uuid DEFAULT NULL
)
RETURNS TABLE (
  adjustment_id uuid,
  created_at timestamptz,
  inventory_item_id uuid,
  item_name text,
  item_sku text,
  item_unit text,
  inventory_location_id uuid,
  location_name text,
  previous_quantity numeric,
  adjustment_amount numeric,
  new_quantity numeric,
  reason text,
  source_type text,
  created_by uuid,
  created_by_name text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET plan_cache_mode = force_custom_plan
AS $$
#variable_conflict use_column
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_org_admin(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;
  IF _reason IS NOT NULL AND _reason NOT IN ('Manual adjustment', 'Damaged', 'Expired', 'Correction', 'Invoice received') THEN
    RAISE EXCEPTION 'Unknown adjustment reason. Physical count corrections are shown in Counts.' USING ERRCODE = '22023';
  END IF;
  IF _limit IS NULL OR _limit < 1 OR _limit > 200 THEN
    RAISE EXCEPTION 'Page size must be between 1 and 200' USING ERRCODE = '22023';
  END IF;
  IF (_after_id IS NULL) <> (_after_created_at IS NULL) THEN
    RAISE EXCEPTION 'An incomplete page cursor was supplied' USING ERRCODE = '22023';
  END IF;
  IF _created_from IS NOT NULL AND _created_before IS NOT NULL AND _created_from >= _created_before THEN
    RAISE EXCEPTION 'The start of the date range must be before its end' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  WITH page AS (
    SELECT adjustment.id, adjustment.created_at, adjustment.inventory_item_id,
      adjustment.inventory_location_id, adjustment.previous_quantity, adjustment.adjustment_amount,
      adjustment.new_quantity, adjustment.reason, adjustment.source_type, adjustment.created_by
    FROM public.inventory_adjustments adjustment
    WHERE adjustment.organization_id = _organization_id
      -- Manual rows only; this exact predicate is the partial index's predicate.
      AND (adjustment.source_type = 'manual' OR (adjustment.source_type IS NULL AND adjustment.reason <> 'Invoice received'))
      AND (_inventory_location_id IS NULL OR adjustment.inventory_location_id = _inventory_location_id)
      AND (_inventory_item_id IS NULL OR adjustment.inventory_item_id = _inventory_item_id)
      AND (_created_by IS NULL OR adjustment.created_by = _created_by)
      AND (_reason IS NULL OR adjustment.reason = _reason)
      AND (_created_from IS NULL OR adjustment.created_at >= _created_from)
      AND (_created_before IS NULL OR adjustment.created_at < _created_before)
      AND (_after_id IS NULL OR (adjustment.created_at, adjustment.id) < (_after_created_at, _after_id))
    ORDER BY adjustment.created_at DESC, adjustment.id DESC
    LIMIT _limit
  ),
  identities AS (
    SELECT identity.user_id, identity.display_name
    FROM public.list_organization_member_identities(_organization_id) identity
    WHERE identity.user_id IN (SELECT page.created_by FROM page)
  )
  SELECT page.id, page.created_at, page.inventory_item_id, item.name, item.sku, item.unit,
    page.inventory_location_id, location.name, trim_scale(page.previous_quantity),
    trim_scale(page.adjustment_amount), trim_scale(page.new_quantity), page.reason,
    page.source_type, page.created_by, coalesce(identities.display_name, 'Former member')
  FROM page
  JOIN public.inventory_items item
    ON item.id = page.inventory_item_id AND item.organization_id = _organization_id
  LEFT JOIN public.inventory_locations location
    ON location.id = page.inventory_location_id AND location.organization_id = _organization_id
  LEFT JOIN identities ON identities.user_id = page.created_by
  ORDER BY page.created_at DESC, page.id DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.list_inventory_adjustment_history(uuid, uuid, uuid, uuid, text, timestamptz, timestamptz, integer, timestamptz, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_inventory_adjustment_history(uuid, uuid, uuid, uuid, text, timestamptz, timestamptz, integer, timestamptz, uuid) TO authenticated;

COMMENT ON FUNCTION public.list_inventory_transfer_history(uuid, uuid, uuid, uuid, timestamptz, timestamptz, integer, timestamptz, uuid) IS
  'Owner/admin: stock moves between inventory locations, filtered server-side (location matches either side). Keyset paged. Read-only.';
COMMENT ON FUNCTION public.list_inventory_adjustment_history(uuid, uuid, uuid, uuid, text, timestamptz, timestamptz, integer, timestamptz, uuid) IS
  'Owner/admin: manual inventory adjustments (never physical-count corrections or invoice receipts), filtered server-side. Keyset paged. Read-only.';

-- ---------------------------------------------------------------------------------------
-- In-migration postcheck. Any failure rolls the whole migration back.
-- ---------------------------------------------------------------------------------------
DO $postcheck$
DECLARE
  _fn regprocedure;
BEGIN
  FOREACH _fn IN ARRAY ARRAY[
    'public.list_inventory_transfer_history(uuid, uuid, uuid, uuid, timestamptz, timestamptz, integer, timestamptz, uuid)'::regprocedure,
    'public.list_inventory_adjustment_history(uuid, uuid, uuid, uuid, text, timestamptz, timestamptz, integer, timestamptz, uuid)'::regprocedure]
  LOOP
    IF NOT has_function_privilege('authenticated', _fn, 'EXECUTE')
       OR has_function_privilege('anon', _fn, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
                  WHERE p.oid = _fn AND acl.grantee = 0 AND acl.privilege_type = 'EXECUTE')
       OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = _fn)
       OR (SELECT provolatile FROM pg_proc WHERE oid = _fn) <> 's' THEN
      RAISE EXCEPTION 'Phase 7B.3 postcheck: unexpected security, volatility or grants on %', _fn;
    END IF;
  END LOOP;
  IF current_setting('medspend.phase7b3_raw_access', true) IS DISTINCT FROM (SELECT md5(string_agg(entry, '|' ORDER BY entry)) FROM (
         SELECT 'acl:' || c.relname || '=' || coalesce(c.relacl::text, '') AS entry
         FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relname IN ('inventory_items', 'inventory_locations', 'inventory_location_balances',
           'inventory_transfers', 'inventory_adjustments', 'inventory_count_sessions', 'inventory_count_lines')
         UNION ALL
         SELECT 'policy:' || tablename || ':' || policyname || '=' || concat_ws('|', cmd, array_to_string(roles, ','), qual, with_check)
         FROM pg_policies
         WHERE schemaname = 'public' AND tablename IN ('inventory_items', 'inventory_locations', 'inventory_location_balances',
           'inventory_transfers', 'inventory_adjustments', 'inventory_count_sessions', 'inventory_count_lines')) raw_access) THEN
    RAISE EXCEPTION 'Phase 7B.3 postcheck: raw inventory table access changed';
  END IF;
END
$postcheck$;

COMMIT;
