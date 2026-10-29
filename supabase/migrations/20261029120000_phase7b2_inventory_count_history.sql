-- Phase 7B.2: Count history and corrections (read-only).
--
--   * list_inventory_count_history: submitted physical counts, newest first, filtered by
--     location, person, date and "has corrections" in the database, keyset paged on
--     (submitted_at DESC, id DESC). Each row carries its correction summary grouped by the
--     count-time unit snapshot; incompatible units are never added together.
--   * get_inventory_count_session: one count with every immutable line (changed lines
--     first), using the count-time name, SKU and unit snapshots. The current archived state
--     of each item is returned separately; the schema does not record archived-at-count-time.
--
-- Owners and admins get the same contract; staff, other organizations, non-members and anon
-- are refused. The counted-by person is resolved through list_organization_member_identities,
-- as in 7B.1: no current membership means "Former member".
--
-- Additive and safe to apply before the application deploys: two new read functions and
-- their grants. No table, column, index, policy, grant on a table, existing function or row
-- changes. The immutable inventory_count_sessions / inventory_count_lines rows are the
-- canonical record; inventory_adjustments is not read here.

BEGIN;

DO $preflight$
BEGIN
  IF pg_catalog.to_regclass('public.inventory_count_sessions') IS NULL
     OR pg_catalog.to_regclass('public.inventory_count_lines') IS NULL
     OR pg_catalog.to_regprocedure('public.submit_inventory_count(uuid, uuid, jsonb, text)') IS NULL THEN
    RAISE EXCEPTION 'Phase 7B.2 requires the Phase 7A.2 inventory count foundation';
  END IF;
  IF pg_catalog.to_regprocedure('public.list_inventory_workspace_locations(uuid, text, integer, integer, text, uuid)') IS NULL
     OR pg_catalog.to_regprocedure('public.is_org_admin(uuid, uuid)') IS NULL
     OR pg_catalog.to_regprocedure('public.list_organization_member_identities(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Phase 7B.2 requires the Phase 7B.1 inventory workspace, is_org_admin and list_organization_member_identities';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.proname IN (
               'list_inventory_count_history', 'get_inventory_count_session')) THEN
    RAISE EXCEPTION 'Phase 7B.2 count history functions already exist unexpectedly';
  END IF;
END
$preflight$;

-- ---------------------------------------------------------------------------------------
-- Count history. Newest first. Filters (all optional, combined with AND):
--   _inventory_location_id  one location
--   _counted_by             one person (user id)
--   _changed_only           only counts with at least one correction
--   _submitted_from         submitted_at >= this (inclusive)
--   _submitted_before       submitted_at <  this (exclusive)
-- Keyset cursor: (_after_submitted_at, _after_id) from the previous page's last row.
--
-- correction_summary is a JSON array, one element per count-time unit among CHANGED lines,
-- ordered by unit: {unit, changedLines, netDelta, increase, decrease}. increase is the sum of
-- positive deltas and decrease the sum of negative ones (<= 0), so a net of zero still shows
-- what moved. An unchanged count has an empty array.
--
-- Index support: inventory_count_sessions_org_submitted_idx (organization_id, submitted_at
-- DESC) and inventory_count_sessions_location_submitted_idx (inventory_location_id,
-- submitted_at DESC) order the scan; lines are read per session through the UNIQUE
-- (count_session_id, inventory_item_id) index.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.list_inventory_count_history(
  _organization_id uuid,
  _inventory_location_id uuid DEFAULT NULL,
  _counted_by uuid DEFAULT NULL,
  _changed_only boolean DEFAULT false,
  _submitted_from timestamptz DEFAULT NULL,
  _submitted_before timestamptz DEFAULT NULL,
  _limit integer DEFAULT 50,
  _after_submitted_at timestamptz DEFAULT NULL,
  _after_id uuid DEFAULT NULL
)
RETURNS TABLE (
  count_session_id uuid,
  submitted_at timestamptz,
  inventory_location_id uuid,
  location_name text,
  location_active boolean,
  counted_by uuid,
  counted_by_name text,
  line_count integer,
  changed_count integer,
  correction_summary jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_org_admin(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;
  IF _changed_only IS NULL THEN
    RAISE EXCEPTION 'Choose whether to show only counts with corrections' USING ERRCODE = '22023';
  END IF;
  IF _limit IS NULL OR _limit < 1 OR _limit > 200 THEN
    RAISE EXCEPTION 'Page size must be between 1 and 200' USING ERRCODE = '22023';
  END IF;
  IF (_after_id IS NULL) <> (_after_submitted_at IS NULL) THEN
    RAISE EXCEPTION 'An incomplete page cursor was supplied' USING ERRCODE = '22023';
  END IF;
  IF _submitted_from IS NOT NULL AND _submitted_before IS NOT NULL AND _submitted_from >= _submitted_before THEN
    RAISE EXCEPTION 'The start of the date range must be before its end' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  WITH page AS (
    SELECT session.id, session.submitted_at, session.inventory_location_id, session.counted_by,
      session.line_count, session.changed_count
    FROM public.inventory_count_sessions session
    WHERE session.organization_id = _organization_id
      AND (_inventory_location_id IS NULL OR session.inventory_location_id = _inventory_location_id)
      AND (_counted_by IS NULL OR session.counted_by = _counted_by)
      AND (NOT _changed_only OR session.changed_count > 0)
      AND (_submitted_from IS NULL OR session.submitted_at >= _submitted_from)
      AND (_submitted_before IS NULL OR session.submitted_at < _submitted_before)
      AND (_after_id IS NULL OR (session.submitted_at, session.id) < (_after_submitted_at, _after_id))
    ORDER BY session.submitted_at DESC, session.id DESC
    LIMIT _limit
  ),
  identities AS (
    SELECT identity.user_id, identity.display_name
    FROM public.list_organization_member_identities(_organization_id) identity
    WHERE identity.user_id IN (SELECT page.counted_by FROM page)
  )
  SELECT page.id, page.submitted_at, page.inventory_location_id, location.name, location.active,
    page.counted_by, coalesce(identities.display_name, 'Former member'), page.line_count, page.changed_count,
    CASE WHEN page.changed_count = 0 THEN '[]'::jsonb ELSE coalesce((
      SELECT jsonb_agg(jsonb_build_object(
          'unit', by_unit.unit,
          'changedLines', by_unit.changed_lines,
          'netDelta', by_unit.net_delta,
          'increase', by_unit.increase,
          'decrease', by_unit.decrease)
        ORDER BY by_unit.unit COLLATE "C")
      FROM (
        SELECT line.item_unit AS unit, count(*)::integer AS changed_lines,
          trim_scale(sum(line.delta)) AS net_delta,
          trim_scale(coalesce(sum(line.delta) FILTER (WHERE line.delta > 0), 0)) AS increase,
          trim_scale(coalesce(sum(line.delta) FILTER (WHERE line.delta < 0), 0)) AS decrease
        FROM public.inventory_count_lines line
        WHERE line.count_session_id = page.id AND line.organization_id = _organization_id
          AND line.delta <> 0
        GROUP BY line.item_unit
      ) by_unit), '[]'::jsonb) END
  FROM page
  JOIN public.inventory_locations location
    ON location.id = page.inventory_location_id AND location.organization_id = _organization_id
  LEFT JOIN identities ON identities.user_id = page.counted_by
  ORDER BY page.submitted_at DESC, page.id DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.list_inventory_count_history(uuid, uuid, uuid, boolean, timestamptz, timestamptz, integer, timestamptz, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_inventory_count_history(uuid, uuid, uuid, boolean, timestamptz, timestamptz, integer, timestamptz, uuid) TO authenticated;

-- ---------------------------------------------------------------------------------------
-- One count: header plus every line, as a single JSON value (never row-capped). The line
-- set is bounded: submit_inventory_count, the only writer, accepts at most 1000 lines.
-- Lines: changed first, then unchanged, each by count-time name. name, sku and unit are the
-- count-time snapshots; itemArchivedNow is the item's CURRENT state only.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.get_inventory_count_session(_organization_id uuid, _count_session_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _session public.inventory_count_sessions%ROWTYPE;
  _location public.inventory_locations%ROWTYPE;
  _counted_by_name text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_org_admin(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO _session FROM public.inventory_count_sessions
  WHERE id = _count_session_id AND organization_id = _organization_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Count not found' USING ERRCODE = 'P0002'; END IF;
  SELECT * INTO _location FROM public.inventory_locations
  WHERE id = _session.inventory_location_id AND organization_id = _organization_id;
  SELECT coalesce((SELECT identity.display_name
                   FROM public.list_organization_member_identities(_organization_id) identity
                   WHERE identity.user_id = _session.counted_by), 'Former member')
  INTO _counted_by_name;

  RETURN jsonb_build_object(
    'sessionId', _session.id,
    'submittedAt', _session.submitted_at,
    'locationId', _location.id,
    'locationName', _location.name,
    'locationActive', _location.active,
    'countedBy', _session.counted_by,
    'countedByName', _counted_by_name,
    'lineCount', _session.line_count,
    'changedCount', _session.changed_count,
    'correctionSummary', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
          'unit', by_unit.unit,
          'changedLines', by_unit.changed_lines,
          'netDelta', by_unit.net_delta,
          'increase', by_unit.increase,
          'decrease', by_unit.decrease)
        ORDER BY by_unit.unit COLLATE "C")
      FROM (
        SELECT line.item_unit AS unit, count(*)::integer AS changed_lines,
          trim_scale(sum(line.delta)) AS net_delta,
          trim_scale(coalesce(sum(line.delta) FILTER (WHERE line.delta > 0), 0)) AS increase,
          trim_scale(coalesce(sum(line.delta) FILTER (WHERE line.delta < 0), 0)) AS decrease
        FROM public.inventory_count_lines line
        WHERE line.count_session_id = _session.id AND line.organization_id = _organization_id
          AND line.delta <> 0
        GROUP BY line.item_unit
      ) by_unit), '[]'::jsonb),
    'lines', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
          'inventoryItemId', line.inventory_item_id,
          'name', line.item_name,
          'sku', line.item_sku,
          'unit', line.item_unit,
          'previousQuantity', trim_scale(line.previous_quantity),
          'countedQuantity', trim_scale(line.counted_quantity),
          'delta', trim_scale(line.delta),
          'itemArchivedNow', NOT item.active)
        ORDER BY (line.delta = 0), lower(line.item_name), line.inventory_item_id)
      FROM public.inventory_count_lines line
      JOIN public.inventory_items item
        ON item.id = line.inventory_item_id AND item.organization_id = line.organization_id
      WHERE line.count_session_id = _session.id AND line.organization_id = _organization_id), '[]'::jsonb)
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_inventory_count_session(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_inventory_count_session(uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.list_inventory_count_history(uuid, uuid, uuid, boolean, timestamptz, timestamptz, integer, timestamptz, uuid) IS
  'Owner/admin: submitted physical counts with per-unit correction summaries, filtered server-side. Keyset paged. Read-only.';
COMMENT ON FUNCTION public.get_inventory_count_session(uuid, uuid) IS
  'Owner/admin: one submitted physical count with every count-time line snapshot. Read-only.';

-- ---------------------------------------------------------------------------------------
-- In-migration postcheck. Any failure rolls the whole migration back.
-- ---------------------------------------------------------------------------------------
DO $postcheck$
DECLARE
  _fn regprocedure;
BEGIN
  FOREACH _fn IN ARRAY ARRAY[
    'public.list_inventory_count_history(uuid, uuid, uuid, boolean, timestamptz, timestamptz, integer, timestamptz, uuid)'::regprocedure,
    'public.get_inventory_count_session(uuid, uuid)'::regprocedure]
  LOOP
    IF NOT has_function_privilege('authenticated', _fn, 'EXECUTE')
       OR has_function_privilege('anon', _fn, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
                  WHERE p.oid = _fn AND acl.grantee = 0 AND acl.privilege_type = 'EXECUTE')
       OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = _fn)
       OR (SELECT provolatile FROM pg_proc WHERE oid = _fn) <> 's' THEN
      RAISE EXCEPTION 'Phase 7B.2 postcheck: unexpected security, volatility or grants on %', _fn;
    END IF;
  END LOOP;
  IF has_table_privilege('anon', 'public.inventory_count_sessions', 'SELECT')
     OR has_table_privilege('anon', 'public.inventory_count_lines', 'SELECT')
     OR has_table_privilege('authenticated', 'public.inventory_count_sessions', 'INSERT')
     OR has_table_privilege('authenticated', 'public.inventory_count_lines', 'INSERT')
     OR EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                AND tablename IN ('inventory_locations', 'inventory_location_balances', 'inventory_transfers',
                                  'inventory_count_sessions', 'inventory_count_lines', 'inventory_adjustments')
                AND qual LIKE '%admin%') THEN
    RAISE EXCEPTION 'Phase 7B.2 postcheck: raw inventory table access changed';
  END IF;
END
$postcheck$;

COMMIT;
