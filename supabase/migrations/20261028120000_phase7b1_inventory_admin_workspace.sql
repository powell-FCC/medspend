-- Phase 7B.1: Inventory admin workspace reads and atomic QR label replacement.
--
--   * Owner+admin READ functions for the Inventory workspace: locations, one location,
--     a location's stock, items with a location summary, and one item's balances. Admins
--     reach inventory locations, balances, counts and labels only through these; raw-table
--     RLS stays owner-only and no grant changes. None of them returns purchase prices or
--     dates. List functions page by keyset, so no result depends on the API row cap.
--   * replace_inventory_location_labels: revoke every active label for a storage location
--     and issue exactly one replacement in ONE transaction, reusing
--     issue_inventory_location_label for token generation and its checks. Owner only.
--
-- Additive and safe to apply before the application deploys: no table, column, policy,
-- grant on a table, existing function or row changes. The Phase 7A.2 count, label and
-- countable-item semantics are reused, not redefined.

BEGIN;

DO $preflight$
BEGIN
  IF pg_catalog.to_regprocedure('public.inventory_countable_balances(uuid, uuid)') IS NULL
     OR pg_catalog.to_regprocedure('public.issue_inventory_location_label(uuid, uuid)') IS NULL
     OR pg_catalog.to_regprocedure('public.revoke_inventory_location_labels(uuid, uuid)') IS NULL
     OR pg_catalog.to_regclass('public.inventory_count_lines') IS NULL THEN
    RAISE EXCEPTION 'Phase 7B.1 requires the Phase 7A.2 inventory count and label foundation';
  END IF;
  IF pg_catalog.to_regprocedure('public.is_org_admin(uuid, uuid)') IS NULL
     OR pg_catalog.to_regprocedure('public.list_organization_member_identities(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Phase 7B.1 requires is_org_admin and list_organization_member_identities';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.proname IN (
               'inventory_workspace_stock_status', 'list_inventory_workspace_locations',
               'get_inventory_workspace_location', 'list_inventory_workspace_location_stock',
               'list_inventory_workspace_items', 'list_inventory_workspace_item_balances',
               'replace_inventory_location_labels')) THEN
    RAISE EXCEPTION 'Phase 7B.1 workspace functions already exist unexpectedly';
  END IF;
END
$preflight$;

-- ---------------------------------------------------------------------------------------
-- Organization-level stock status of one item: its organization quantity against its
-- organization par. The same rule as getInventoryStatus in src/inventory/status.ts. It is
-- never a location threshold; SportSpend has no location-level par.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.inventory_workspace_stock_status(_quantity numeric, _par_level numeric, _active boolean)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT CASE
    WHEN NOT _active THEN 'inactive'
    WHEN _par_level IS NULL OR _par_level <= 0 OR _quantity > _par_level THEN 'healthy'
    WHEN _quantity <= _par_level * 0.5 THEN 'critical'
    ELSE 'low'
  END;
$$;
REVOKE ALL ON FUNCTION public.inventory_workspace_stock_status(numeric, numeric, boolean) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------------------
-- Locations. Unassigned first, then active storage locations, then archived ones, each by
-- name. Keyset cursor: (_after_sort_group, _after_name, _after_id) from the previous page's
-- last row. Count, label and last-counted fields are NULL for Unassigned: it is not a
-- physical location, is never counted and has no labels.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.list_inventory_workspace_locations(
  _organization_id uuid,
  _status text DEFAULT 'all',
  _limit integer DEFAULT 200,
  _after_sort_group integer DEFAULT NULL,
  _after_name text DEFAULT NULL,
  _after_id uuid DEFAULT NULL
)
RETURNS TABLE (
  inventory_location_id uuid,
  name text,
  description text,
  kind text,
  active boolean,
  sort_group integer,
  sort_name text,
  stocked_item_count integer,
  countable_item_count integer,
  last_counted_at timestamptz,
  last_counted_by_name text,
  active_label_count integer,
  last_label_issued_at timestamptz
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
  IF _status IS NULL OR _status NOT IN ('active', 'archived', 'all') THEN
    RAISE EXCEPTION 'Choose active, archived or all locations' USING ERRCODE = '22023';
  END IF;
  IF _limit IS NULL OR _limit < 1 OR _limit > 500 THEN
    RAISE EXCEPTION 'Page size must be between 1 and 500' USING ERRCODE = '22023';
  END IF;
  IF (_after_id IS NULL) <> (_after_sort_group IS NULL) OR (_after_id IS NULL) <> (_after_name IS NULL) THEN
    RAISE EXCEPTION 'An incomplete page cursor was supplied' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  WITH page AS (
    SELECT location.*,
      CASE WHEN location.kind = 'unassigned' THEN 0 WHEN location.active THEN 1 ELSE 2 END AS group_key,
      lower(location.name) AS name_key
    FROM public.inventory_locations location
    WHERE location.organization_id = _organization_id
      AND (_status = 'all' OR (_status = 'active') = location.active)
      AND (_after_id IS NULL OR
           (CASE WHEN location.kind = 'unassigned' THEN 0 WHEN location.active THEN 1 ELSE 2 END,
            lower(location.name), location.id) > (_after_sort_group, _after_name, _after_id))
    ORDER BY group_key, name_key, location.id
    LIMIT _limit
  ),
  last_session AS (
    SELECT DISTINCT ON (session.inventory_location_id) session.inventory_location_id, session.submitted_at, session.counted_by
    FROM public.inventory_count_sessions session
    WHERE session.organization_id = _organization_id
      AND session.inventory_location_id IN (SELECT page.id FROM page WHERE page.kind = 'storage')
    ORDER BY session.inventory_location_id, session.submitted_at DESC, session.id DESC
  ),
  identities AS (
    SELECT identity.user_id, identity.display_name
    FROM public.list_organization_member_identities(_organization_id) identity
    WHERE identity.user_id IN (SELECT last_session.counted_by FROM last_session)
  )
  SELECT page.id, page.name, page.description, page.kind, page.active, page.group_key, page.name_key,
    (SELECT count(*)::integer FROM public.inventory_location_balances balance
     WHERE balance.organization_id = _organization_id AND balance.inventory_location_id = page.id
       AND balance.quantity > 0),
    CASE WHEN page.kind = 'storage' THEN
      (SELECT count(*)::integer FROM public.inventory_countable_balances(_organization_id, page.id)) END,
    last_session.submitted_at,
    CASE WHEN last_session.counted_by IS NOT NULL THEN coalesce(identities.display_name, 'Former member') END,
    CASE WHEN page.kind = 'storage' THEN
      (SELECT count(*)::integer FROM public.inventory_location_labels label
       WHERE label.organization_id = _organization_id AND label.inventory_location_id = page.id
         AND label.revoked_at IS NULL) END,
    CASE WHEN page.kind = 'storage' THEN
      (SELECT max(label.created_at) FROM public.inventory_location_labels label
       WHERE label.organization_id = _organization_id AND label.inventory_location_id = page.id
         AND label.revoked_at IS NULL) END
  FROM page
  LEFT JOIN last_session ON last_session.inventory_location_id = page.id
  LEFT JOIN identities ON identities.user_id = last_session.counted_by
  ORDER BY page.group_key, page.name_key, page.id;
END;
$$;
REVOKE ALL ON FUNCTION public.list_inventory_workspace_locations(uuid, text, integer, integer, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_inventory_workspace_locations(uuid, text, integer, integer, text, uuid) TO authenticated;

-- ---------------------------------------------------------------------------------------
-- One location's detail header. A single JSON value, never row-capped.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.get_inventory_workspace_location(_organization_id uuid, _inventory_location_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _location public.inventory_locations%ROWTYPE;
  _storage boolean;
  _session public.inventory_count_sessions%ROWTYPE;
  _counted_by_name text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_org_admin(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO _location FROM public.inventory_locations
  WHERE id = _inventory_location_id AND organization_id = _organization_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Inventory location not found' USING ERRCODE = 'P0002'; END IF;
  _storage := _location.kind = 'storage';

  IF _storage THEN
    SELECT * INTO _session FROM public.inventory_count_sessions
    WHERE organization_id = _organization_id AND inventory_location_id = _location.id
    ORDER BY submitted_at DESC, id DESC LIMIT 1;
    IF FOUND THEN
      SELECT coalesce((SELECT identity.display_name
                       FROM public.list_organization_member_identities(_organization_id) identity
                       WHERE identity.user_id = _session.counted_by), 'Former member')
      INTO _counted_by_name;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'id', _location.id,
    'name', _location.name,
    'description', _location.description,
    'kind', _location.kind,
    'active', _location.active,
    'stockedItemCount', (SELECT count(*) FROM public.inventory_location_balances balance
                         WHERE balance.organization_id = _organization_id
                           AND balance.inventory_location_id = _location.id AND balance.quantity > 0),
    'archivedStockedItemCount', (SELECT count(*) FROM public.inventory_location_balances balance
                                 JOIN public.inventory_items item
                                   ON item.id = balance.inventory_item_id AND item.organization_id = balance.organization_id
                                 WHERE balance.organization_id = _organization_id
                                   AND balance.inventory_location_id = _location.id
                                   AND balance.quantity > 0 AND NOT item.active),
    'countableItemCount', CASE WHEN _storage THEN
      (SELECT count(*) FROM public.inventory_countable_balances(_organization_id, _location.id)) END,
    'lastCountedAt', _session.submitted_at,
    'lastCountedByName', _counted_by_name,
    'activeLabelCount', CASE WHEN _storage THEN
      (SELECT count(*) FROM public.inventory_location_labels label
       WHERE label.organization_id = _organization_id AND label.inventory_location_id = _location.id
         AND label.revoked_at IS NULL) END,
    'lastLabelIssuedAt', CASE WHEN _storage THEN
      (SELECT max(label.created_at) FROM public.inventory_location_labels label
       WHERE label.organization_id = _organization_id AND label.inventory_location_id = _location.id
         AND label.revoked_at IS NULL) END
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_inventory_workspace_location(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_inventory_workspace_location(uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------------------------
-- A location's stock. A storage location lists its countable items (the locked 7A.2 rule,
-- so zero balances of active items appear); Unassigned lists items it holds (quantity > 0).
-- Par and status are the item's ORGANIZATION-level values. Keyset cursor:
-- (_after_name, _after_id) from the previous page's last row (sort_name, inventory_item_id).
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.list_inventory_workspace_location_stock(
  _organization_id uuid,
  _inventory_location_id uuid,
  _limit integer DEFAULT 100,
  _after_name text DEFAULT NULL,
  _after_id uuid DEFAULT NULL
)
RETURNS TABLE (
  inventory_item_id uuid,
  name text,
  sku text,
  unit text,
  sort_name text,
  quantity numeric,
  item_active boolean,
  organization_quantity numeric,
  organization_par_level numeric,
  organization_stock_status text,
  last_counted_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _location public.inventory_locations%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_org_admin(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;
  IF _limit IS NULL OR _limit < 1 OR _limit > 500 THEN
    RAISE EXCEPTION 'Page size must be between 1 and 500' USING ERRCODE = '22023';
  END IF;
  IF (_after_id IS NULL) <> (_after_name IS NULL) THEN
    RAISE EXCEPTION 'An incomplete page cursor was supplied' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO _location FROM public.inventory_locations
  WHERE id = _inventory_location_id AND organization_id = _organization_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Inventory location not found' USING ERRCODE = 'P0002'; END IF;

  RETURN QUERY
  SELECT item.id, item.name, item.sku, item.unit, lower(item.name), balance.quantity, item.active,
    item.quantity, item.par_level,
    public.inventory_workspace_stock_status(item.quantity, item.par_level, item.active),
    CASE WHEN _location.kind = 'storage' THEN
      (SELECT max(line.created_at) FROM public.inventory_count_lines line
       WHERE line.inventory_item_id = item.id AND line.inventory_location_id = _location.id
         AND line.organization_id = _organization_id) END
  FROM public.inventory_location_balances balance
  JOIN public.inventory_items item
    ON item.id = balance.inventory_item_id AND item.organization_id = balance.organization_id
  WHERE balance.organization_id = _organization_id
    AND balance.inventory_location_id = _location.id
    AND CASE WHEN _location.kind = 'storage'
             THEN item.active OR balance.quantity > 0
             ELSE balance.quantity > 0 END
    AND (_after_id IS NULL OR (lower(item.name), item.id) > (_after_name, _after_id))
  ORDER BY lower(item.name), item.id
  LIMIT _limit;
END;
$$;
REVOKE ALL ON FUNCTION public.list_inventory_workspace_location_stock(uuid, uuid, integer, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_inventory_workspace_location_stock(uuid, uuid, integer, text, uuid) TO authenticated;

-- ---------------------------------------------------------------------------------------
-- Items with where their stock is. Search, category, status and organization-level
-- stock filters run here, not in the browser. Fields are the item identity the Items table
-- and the owner's edit form need (the form rewrites every field it shows); no purchase
-- price or date. Keyset cursor: (_after_name, _after_id).
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.list_inventory_workspace_items(
  _organization_id uuid,
  _search text DEFAULT '',
  _category text DEFAULT '',
  _status text DEFAULT 'active',
  _stock_status text DEFAULT 'all',
  _limit integer DEFAULT 100,
  _after_name text DEFAULT NULL,
  _after_id uuid DEFAULT NULL
)
RETURNS TABLE (
  inventory_item_id uuid,
  name text,
  description text,
  sku text,
  vendor_name text,
  manufacturer text,
  category text,
  unit text,
  active boolean,
  sort_name text,
  quantity numeric,
  par_level numeric,
  stock_status text,
  unassigned_quantity numeric,
  physical_quantity numeric,
  physical_location_count integer,
  single_physical_location_name text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _needle text := lower(btrim(coalesce(_search, '')));
  _category_filter text := btrim(coalesce(_category, ''));
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_org_admin(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;
  IF _status IS NULL OR _status NOT IN ('active', 'archived', 'all') THEN
    RAISE EXCEPTION 'Choose active, archived or all items' USING ERRCODE = '22023';
  END IF;
  IF _stock_status IS NULL OR _stock_status NOT IN ('all', 'low') THEN
    RAISE EXCEPTION 'Choose all or low stock' USING ERRCODE = '22023';
  END IF;
  IF _limit IS NULL OR _limit < 1 OR _limit > 500 THEN
    RAISE EXCEPTION 'Page size must be between 1 and 500' USING ERRCODE = '22023';
  END IF;
  IF (_after_id IS NULL) <> (_after_name IS NULL) THEN
    RAISE EXCEPTION 'An incomplete page cursor was supplied' USING ERRCODE = '22023';
  END IF;
  IF char_length(_needle) > 120 OR char_length(_category_filter) > 120 THEN
    RAISE EXCEPTION 'Search and category are limited to 120 characters' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  WITH page AS (
    SELECT item.*
    FROM public.inventory_items item
    WHERE item.organization_id = _organization_id
      AND (_status = 'all' OR (_status = 'active') = item.active)
      AND (_category_filter = '' OR item.category = _category_filter)
      AND (_needle = ''
           OR position(_needle IN lower(item.name)) > 0
           OR position(_needle IN lower(coalesce(item.sku, ''))) > 0
           OR position(_needle IN lower(coalesce(item.vendor_name, ''))) > 0
           OR position(_needle IN lower(coalesce(item.manufacturer, ''))) > 0)
      AND (_stock_status = 'all'
           OR public.inventory_workspace_stock_status(item.quantity, item.par_level, item.active) IN ('low', 'critical'))
      AND (_after_id IS NULL OR (lower(item.name), item.id) > (_after_name, _after_id))
    ORDER BY lower(item.name), item.id
    LIMIT _limit
  )
  SELECT page.id, page.name, page.description, page.sku, page.vendor_name, page.manufacturer, page.category,
    page.unit, page.active, lower(page.name), page.quantity, page.par_level,
    public.inventory_workspace_stock_status(page.quantity, page.par_level, page.active),
    coalesce(placed.unassigned_quantity, 0), coalesce(placed.physical_quantity, 0),
    coalesce(placed.physical_location_count, 0),
    CASE WHEN placed.physical_location_count = 1 THEN placed.first_physical_location_name END
  FROM page
  LEFT JOIN LATERAL (
    SELECT
      sum(balance.quantity) FILTER (WHERE location.kind = 'unassigned') AS unassigned_quantity,
      sum(balance.quantity) FILTER (WHERE location.kind = 'storage') AS physical_quantity,
      (count(*) FILTER (WHERE location.kind = 'storage' AND balance.quantity > 0))::integer AS physical_location_count,
      min(location.name) FILTER (WHERE location.kind = 'storage' AND balance.quantity > 0) AS first_physical_location_name
    FROM public.inventory_location_balances balance
    JOIN public.inventory_locations location
      ON location.id = balance.inventory_location_id AND location.organization_id = balance.organization_id
    WHERE balance.inventory_item_id = page.id AND balance.organization_id = _organization_id
  ) placed ON true
  ORDER BY lower(page.name), page.id;
END;
$$;
REVOKE ALL ON FUNCTION public.list_inventory_workspace_items(uuid, text, text, text, text, integer, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_inventory_workspace_items(uuid, text, text, text, text, integer, text, uuid) TO authenticated;

-- ---------------------------------------------------------------------------------------
-- One item's quantity at every location that has a balance row for it, for the owner's
-- Move and Adjust dialogs. A single JSON value, never row-capped; an item cannot have more
-- balance rows than its organization has locations.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.list_inventory_workspace_item_balances(_organization_id uuid, _inventory_item_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _item public.inventory_items%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_org_admin(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO _item FROM public.inventory_items
  WHERE id = _inventory_item_id AND organization_id = _organization_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Inventory item not found' USING ERRCODE = 'P0002'; END IF;

  RETURN jsonb_build_object(
    'inventoryItemId', _item.id,
    'quantity', _item.quantity,
    'balances', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
          'inventoryLocationId', balance.inventory_location_id,
          'quantity', balance.quantity,
          'version', balance.version,
          'updatedAt', balance.updated_at)
        ORDER BY balance.inventory_location_id)
      FROM public.inventory_location_balances balance
      WHERE balance.organization_id = _organization_id AND balance.inventory_item_id = _item.id), '[]'::jsonb)
  );
END;
$$;
REVOKE ALL ON FUNCTION public.list_inventory_workspace_item_balances(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_inventory_workspace_item_balances(uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------------------------
-- Atomic Replace labels (owner). One call, one transaction: lock the location, revoke every
-- active label, then issue exactly one replacement through issue_inventory_location_label
-- (same owner check, eligibility rules, 32-byte token and SHA-256-only storage). If issuing
-- fails, the revocation rolls back with it. The location row lock (FOR UPDATE) serializes
-- concurrent replacements, so a location never ends with two replacement labels.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.replace_inventory_location_labels(_organization_id uuid, _inventory_location_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _location public.inventory_locations%ROWTYPE;
  _revoked integer;
  _issued jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO _location FROM public.inventory_locations
  WHERE id = _inventory_location_id AND organization_id = _organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Inventory location not found' USING ERRCODE = 'P0002'; END IF;
  IF _location.kind <> 'storage' THEN
    RAISE EXCEPTION 'Unassigned is not a physical location and has no QR label' USING ERRCODE = '22023';
  END IF;
  IF NOT _location.active THEN
    RAISE EXCEPTION 'Restore % before issuing a QR label for it', _location.name USING ERRCODE = '55000';
  END IF;

  UPDATE public.inventory_location_labels
  SET revoked_at = now(), revoked_by = auth.uid()
  WHERE organization_id = _organization_id AND inventory_location_id = _location.id
    AND revoked_at IS NULL;
  GET DIAGNOSTICS _revoked = ROW_COUNT;

  _issued := public.issue_inventory_location_label(_organization_id, _location.id);
  RETURN _issued || jsonb_build_object('revokedCount', _revoked);
END;
$$;
REVOKE ALL ON FUNCTION public.replace_inventory_location_labels(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.replace_inventory_location_labels(uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.list_inventory_workspace_locations(uuid, text, integer, integer, text, uuid) IS
  'Owner/admin Inventory workspace: locations with stock, countable, label and last-count summaries. Keyset paged.';
COMMENT ON FUNCTION public.list_inventory_workspace_location_stock(uuid, uuid, integer, text, uuid) IS
  'Owner/admin Inventory workspace: one location''s stock with organization-level par status. Keyset paged.';
COMMENT ON FUNCTION public.list_inventory_workspace_items(uuid, text, text, text, text, integer, text, uuid) IS
  'Owner/admin Inventory workspace: items with location summaries, filtered server-side. Keyset paged. No prices.';
COMMENT ON FUNCTION public.replace_inventory_location_labels(uuid, uuid) IS
  'Owner: revoke every active QR label for a storage location and issue one replacement, atomically.';

-- ---------------------------------------------------------------------------------------
-- In-migration postcheck. Any failure rolls the whole migration back.
-- ---------------------------------------------------------------------------------------
DO $postcheck$
DECLARE
  _fn regprocedure;
BEGIN
  FOREACH _fn IN ARRAY ARRAY[
    'public.list_inventory_workspace_locations(uuid, text, integer, integer, text, uuid)'::regprocedure,
    'public.get_inventory_workspace_location(uuid, uuid)'::regprocedure,
    'public.list_inventory_workspace_location_stock(uuid, uuid, integer, text, uuid)'::regprocedure,
    'public.list_inventory_workspace_items(uuid, text, text, text, text, integer, text, uuid)'::regprocedure,
    'public.list_inventory_workspace_item_balances(uuid, uuid)'::regprocedure,
    'public.replace_inventory_location_labels(uuid, uuid)'::regprocedure]
  LOOP
    IF NOT has_function_privilege('authenticated', _fn, 'EXECUTE')
       OR has_function_privilege('anon', _fn, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
                  WHERE p.oid = _fn AND acl.grantee = 0 AND acl.privilege_type = 'EXECUTE')
       OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = _fn) THEN
      RAISE EXCEPTION 'Phase 7B.1 postcheck: unexpected security or grants on %', _fn;
    END IF;
  END LOOP;
  IF has_function_privilege('authenticated', 'public.inventory_workspace_stock_status(numeric, numeric, boolean)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.inventory_workspace_stock_status(numeric, numeric, boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Phase 7B.1 postcheck: the stock status helper must not be client-callable';
  END IF;
  IF has_table_privilege('authenticated', 'public.inventory_location_labels', 'SELECT')
     OR has_table_privilege('anon', 'public.inventory_locations', 'SELECT')
     OR EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                AND tablename IN ('inventory_locations', 'inventory_location_balances', 'inventory_transfers',
                                  'inventory_count_sessions', 'inventory_count_lines', 'inventory_adjustments')
                AND qual LIKE '%admin%') THEN
    RAISE EXCEPTION 'Phase 7B.1 postcheck: raw inventory table access changed';
  END IF;
END
$postcheck$;

COMMIT;
