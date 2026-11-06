-- Phase 7B.5: Count cadence (optional, organization-level).
--
--   * inventory_count_policies: at most one row per organization (organization_id is the
--     primary key): enabled, interval_days (1..365). No row means cadence is off. Nobody reads
--     or writes the table directly; RLS is on with no policies and no client grants.
--   * inventory_location_count_freshness(org, as_of): the ONE place freshness is decided, for
--     every storage location of the organization. Internal (no client EXECUTE).
--   * get_inventory_count_policy / get_inventory_count_freshness: owner+admin reads.
--   * set_inventory_count_policy: owner only.
--
-- Freshness, with the reconciliation time = the newest submitted count's submitted_at:
--   not_applicable   archived storage location or Unassigned (never scheduled)
--   nothing_to_count active storage location with no countable item (7A.2 rule)
--   never_counted    active, countable, no submitted count
--   counted          cadence off: counted at least once (no schedule is inferred)
--   current          cadence on: as_of < next_due_at
--   due              cadence on: next_due_at <= as_of < next_due_at + 1 day
--   overdue          cadence on: as_of >= next_due_at + 1 day
-- next_due_at = last_counted_at + interval_days days (cadence on only). Timestamps throughout:
-- the schema has no organization time zone, so "due" is the 24 hours from the moment the
-- interval elapses, not a calendar day. Nothing here infers that stock is wrong or missing.
--
-- Additive: one table (with its primary key index), four functions and their grants. No
-- existing table, column, index, policy, grant on a table, existing function or row changes;
-- 7A.2 count submission, 7B.2 count history, 7B.3 activity and the 7B.4 overview are untouched.
-- Existing indexes serve every lookup (inventory_count_sessions_location_submitted_idx for the
-- newest count per location; see supabase/release/phase7b5/README.md).

BEGIN;

DO $preflight$
BEGIN
  IF pg_catalog.to_regprocedure('public.get_inventory_overview(uuid, integer)') IS NULL
     OR pg_catalog.to_regprocedure('public.list_inventory_count_history(uuid, uuid, uuid, boolean, timestamptz, timestamptz, integer, timestamptz, uuid)') IS NULL
     OR pg_catalog.to_regprocedure('public.inventory_countable_balances(uuid, uuid)') IS NULL
     OR pg_catalog.to_regprocedure('public.is_org_admin(uuid, uuid)') IS NULL
     OR pg_catalog.to_regprocedure('public.has_org_role(uuid, uuid, public.org_role[])') IS NULL
     OR pg_catalog.to_regprocedure('public.list_organization_member_identities(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Phase 7B.5 requires Phase 7B.4, 7B.2, 7A.2 and the organization role helpers';
  END IF;
  IF pg_catalog.to_regclass('public.inventory_count_policies') IS NOT NULL
     OR EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public' AND p.proname IN (
                  'inventory_location_count_freshness', 'get_inventory_count_policy',
                  'set_inventory_count_policy', 'get_inventory_count_freshness')) THEN
    RAISE EXCEPTION 'Phase 7B.5 count cadence objects already exist unexpectedly';
  END IF;
END
$preflight$;

-- Raw inventory table grants and policies before this migration, as one hash kept for the
-- postcheck in a transaction-local setting.
DO $snapshot$
BEGIN
  PERFORM set_config('medspend.phase7b5_raw_access', (SELECT md5(string_agg(entry, '|' ORDER BY entry)) FROM (
         SELECT 'acl:' || c.relname || '=' || coalesce(c.relacl::text, '') AS entry
         FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relname IN ('inventory_items', 'inventory_locations', 'inventory_location_balances',
           'inventory_transfers', 'inventory_adjustments', 'inventory_count_sessions', 'inventory_count_lines',
           'inventory_location_labels', 'organizations')
         UNION ALL
         SELECT 'policy:' || tablename || ':' || policyname || '=' || concat_ws('|', cmd, array_to_string(roles, ','), qual, with_check)
         FROM pg_policies
         WHERE schemaname = 'public' AND tablename IN ('inventory_items', 'inventory_locations', 'inventory_location_balances',
           'inventory_transfers', 'inventory_adjustments', 'inventory_count_sessions', 'inventory_count_lines',
           'inventory_location_labels', 'organizations')) raw_access), true);
END
$snapshot$;

-- ---------------------------------------------------------------------------------------
-- The policy. 365 days is the upper bound: a yearly count is the longest reconciliation
-- cycle that still describes a schedule; anything longer is effectively "off". The stored
-- interval is kept while cadence is off, so turning it back on restores the last value.
-- ---------------------------------------------------------------------------------------
CREATE TABLE public.inventory_count_policies (
  organization_id uuid PRIMARY KEY REFERENCES public.organizations(id) ON DELETE CASCADE,
  enabled boolean NOT NULL DEFAULT false,
  interval_days integer CHECK (interval_days BETWEEN 1 AND 365),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  CONSTRAINT inventory_count_policies_enabled_interval_check CHECK (NOT enabled OR interval_days IS NOT NULL)
);
ALTER TABLE public.inventory_count_policies ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inventory_count_policies FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.inventory_count_policies TO service_role;

-- ---------------------------------------------------------------------------------------
-- Freshness for every storage location of an organization at _as_of. Internal: callers check
-- the role first. The newest count per location is one probe of
-- inventory_count_sessions_location_submitted_idx; countable items use the 7A.2 rule.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.inventory_location_count_freshness(_organization_id uuid, _as_of timestamptz)
RETURNS TABLE (
  inventory_location_id uuid,
  name text,
  active boolean,
  countable_item_count integer,
  last_counted_at timestamptz,
  next_due_at timestamptz,
  state text
)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  WITH policy AS (
    SELECT coalesce(bool_or(p.enabled), false) AS enabled, max(p.interval_days) AS interval_days
    FROM public.inventory_count_policies p
    WHERE p.organization_id = _organization_id
  ),
  located AS (
    SELECT location.id, location.name, location.active,
      CASE WHEN location.active THEN
        (SELECT count(*)::integer FROM public.inventory_countable_balances(_organization_id, location.id)) END AS countable,
      (SELECT session.submitted_at FROM public.inventory_count_sessions session
       WHERE session.inventory_location_id = location.id AND session.organization_id = _organization_id
       ORDER BY session.submitted_at DESC LIMIT 1) AS last_counted_at
    FROM public.inventory_locations location
    WHERE location.organization_id = _organization_id AND location.kind = 'storage'
  ),
  scheduled AS (
    SELECT located.*, policy.enabled,
      CASE WHEN policy.enabled AND located.active AND located.countable > 0
        THEN located.last_counted_at + make_interval(days => policy.interval_days) END AS due_at
    FROM located CROSS JOIN policy
  )
  SELECT scheduled.id, scheduled.name, scheduled.active, scheduled.countable, scheduled.last_counted_at,
    scheduled.due_at,
    CASE
      WHEN NOT scheduled.active THEN 'not_applicable'
      WHEN scheduled.countable = 0 THEN 'nothing_to_count'
      WHEN scheduled.last_counted_at IS NULL THEN 'never_counted'
      WHEN NOT scheduled.enabled THEN 'counted'
      WHEN _as_of < scheduled.due_at THEN 'current'
      WHEN _as_of < scheduled.due_at + interval '1 day' THEN 'due'
      ELSE 'overdue'
    END
  FROM scheduled;
$$;
REVOKE ALL ON FUNCTION public.inventory_location_count_freshness(uuid, timestamptz) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------------------
-- The policy as owners and admins see it. No row: cadence off, no interval.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.get_inventory_count_policy(_organization_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _policy public.inventory_count_policies%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_org_admin(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO _policy FROM public.inventory_count_policies WHERE organization_id = _organization_id;
  RETURN jsonb_build_object(
    'configured', FOUND,
    'enabled', coalesce(_policy.enabled, false),
    'intervalDays', _policy.interval_days,
    'updatedAt', _policy.updated_at,
    'updatedByName', CASE WHEN _policy.updated_by IS NOT NULL THEN coalesce((
      SELECT identity.display_name FROM public.list_organization_member_identities(_organization_id) identity
      WHERE identity.user_id = _policy.updated_by), 'Former member') END);
END;
$$;
REVOKE ALL ON FUNCTION public.get_inventory_count_policy(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_inventory_count_policy(uuid) TO authenticated;

-- ---------------------------------------------------------------------------------------
-- Owner: set the policy. Turning cadence on requires 1..365 days. Turning it off may omit
-- the interval (the stored one is kept); a supplied interval is validated either way. Invalid
-- values are refused, never coerced.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.set_inventory_count_policy(_organization_id uuid, _enabled boolean, _interval_days integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required' USING ERRCODE = '42501';
  END IF;
  IF _enabled IS NULL THEN
    RAISE EXCEPTION 'Choose whether count cadence is on' USING ERRCODE = '22023';
  END IF;
  IF _enabled AND _interval_days IS NULL THEN
    RAISE EXCEPTION 'Choose how many days between counts' USING ERRCODE = '22023';
  END IF;
  IF _interval_days IS NOT NULL AND (_interval_days < 1 OR _interval_days > 365) THEN
    RAISE EXCEPTION 'Count every 1 to 365 days' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.inventory_count_policies AS policy (organization_id, enabled, interval_days, updated_by)
  VALUES (_organization_id, _enabled, _interval_days, auth.uid())
  ON CONFLICT (organization_id) DO UPDATE
  SET enabled = EXCLUDED.enabled,
      interval_days = coalesce(EXCLUDED.interval_days, policy.interval_days),
      updated_at = now(),
      updated_by = auth.uid();

  RETURN public.get_inventory_count_policy(_organization_id);
END;
$$;
REVOKE ALL ON FUNCTION public.set_inventory_count_policy(uuid, boolean, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_inventory_count_policy(uuid, boolean, integer) TO authenticated;

-- ---------------------------------------------------------------------------------------
-- Freshness as owners and admins see it, evaluated at now(). One JSON value:
--   policy        {enabled, intervalDays}
--   evaluatedAt   the time states were computed for
--   summary       counts per state over active storage locations
--   attention     {total, rows}: due and overdue locations (cadence on only), most overdue
--                 first, at most _limit rows. Never-counted locations stay in the 7B.4 list.
--   nextDue       the soonest next_due_at among current locations (cadence on only)
--   location      the requested location's row when _inventory_location_id is given
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.get_inventory_count_freshness(
  _organization_id uuid,
  _inventory_location_id uuid DEFAULT NULL,
  _limit integer DEFAULT 10
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _now timestamptz := now();
  _kind text;
  _result jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_org_admin(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;
  IF _limit IS NULL OR _limit < 1 OR _limit > 50 THEN
    RAISE EXCEPTION 'Attention list size must be between 1 and 50' USING ERRCODE = '22023';
  END IF;
  IF _inventory_location_id IS NOT NULL THEN
    SELECT kind INTO _kind FROM public.inventory_locations
    WHERE id = _inventory_location_id AND organization_id = _organization_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Inventory location not found' USING ERRCODE = 'P0002'; END IF;
  END IF;

  WITH freshness AS (
    SELECT * FROM public.inventory_location_count_freshness(_organization_id, _now)
  ),
  policy AS (
    SELECT coalesce(bool_or(p.enabled), false) AS enabled, max(p.interval_days) AS interval_days
    FROM public.inventory_count_policies p WHERE p.organization_id = _organization_id
  ),
  attention AS (
    SELECT * FROM freshness WHERE freshness.state IN ('due', 'overdue')
  )
  SELECT jsonb_build_object(
    'policy', (SELECT jsonb_build_object('enabled', policy.enabled,
                 'intervalDays', CASE WHEN policy.enabled THEN policy.interval_days END) FROM policy),
    'evaluatedAt', _now,
    'summary', jsonb_build_object(
      'current', (SELECT count(*) FROM freshness WHERE state = 'current'),
      'due', (SELECT count(*) FROM freshness WHERE state = 'due'),
      'overdue', (SELECT count(*) FROM freshness WHERE state = 'overdue'),
      'neverCounted', (SELECT count(*) FROM freshness WHERE state = 'never_counted'),
      'counted', (SELECT count(*) FROM freshness WHERE state = 'counted'),
      'nothingToCount', (SELECT count(*) FROM freshness WHERE state = 'nothing_to_count')),
    'attention', jsonb_build_object(
      'total', (SELECT count(*) FROM attention),
      'rows', coalesce((SELECT jsonb_agg(jsonb_build_object(
          'locationId', row.inventory_location_id, 'name', row.name, 'state', row.state,
          'lastCountedAt', row.last_counted_at, 'nextDueAt', row.next_due_at)
          ORDER BY row.next_due_at, lower(row.name), row.inventory_location_id)
        FROM (SELECT * FROM attention ORDER BY attention.next_due_at, lower(attention.name), attention.inventory_location_id
              LIMIT _limit) row), '[]'::jsonb)),
    'nextDue', (SELECT jsonb_build_object('locationId', row.inventory_location_id, 'name', row.name, 'nextDueAt', row.next_due_at)
                FROM freshness row WHERE row.state = 'current'
                ORDER BY row.next_due_at, lower(row.name), row.inventory_location_id LIMIT 1),
    'location', CASE
      WHEN _inventory_location_id IS NULL THEN NULL
      WHEN _kind <> 'storage' THEN jsonb_build_object('locationId', _inventory_location_id, 'state', 'not_applicable',
        'lastCountedAt', NULL, 'nextDueAt', NULL, 'countableItemCount', NULL)
      ELSE (SELECT jsonb_build_object('locationId', row.inventory_location_id, 'state', row.state,
              'lastCountedAt', row.last_counted_at, 'nextDueAt', row.next_due_at,
              'countableItemCount', row.countable_item_count)
            FROM freshness row WHERE row.inventory_location_id = _inventory_location_id) END)
  INTO _result;
  RETURN _result;
END;
$$;
REVOKE ALL ON FUNCTION public.get_inventory_count_freshness(uuid, uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_inventory_count_freshness(uuid, uuid, integer) TO authenticated;

COMMENT ON TABLE public.inventory_count_policies IS
  'Optional organization count cadence (Phase 7B.5). No row = off. Read and written only through owner/admin RPCs.';
COMMENT ON FUNCTION public.inventory_location_count_freshness(uuid, timestamptz) IS
  'Internal: count freshness state per storage location at a given time. The single freshness rule.';
COMMENT ON FUNCTION public.get_inventory_count_policy(uuid) IS
  'Owner/admin: the organization count cadence policy. Read-only.';
COMMENT ON FUNCTION public.set_inventory_count_policy(uuid, boolean, integer) IS
  'Owner: turn count cadence on or off and set the interval (1..365 days).';
COMMENT ON FUNCTION public.get_inventory_count_freshness(uuid, uuid, integer) IS
  'Owner/admin: count freshness summary, due/overdue locations and one location''s state. Read-only.';

-- ---------------------------------------------------------------------------------------
-- In-migration postcheck. Any failure rolls the whole migration back.
-- ---------------------------------------------------------------------------------------
DO $postcheck$
DECLARE
  _fn regprocedure;
BEGIN
  FOREACH _fn IN ARRAY ARRAY[
    'public.get_inventory_count_policy(uuid)'::regprocedure,
    'public.set_inventory_count_policy(uuid, boolean, integer)'::regprocedure,
    'public.get_inventory_count_freshness(uuid, uuid, integer)'::regprocedure]
  LOOP
    IF NOT has_function_privilege('authenticated', _fn, 'EXECUTE')
       OR has_function_privilege('anon', _fn, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
                  WHERE p.oid = _fn AND acl.grantee = 0 AND acl.privilege_type = 'EXECUTE')
       OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = _fn) THEN
      RAISE EXCEPTION 'Phase 7B.5 postcheck: unexpected security or grants on %', _fn;
    END IF;
  END LOOP;
  IF (SELECT provolatile FROM pg_proc WHERE oid = 'public.get_inventory_count_policy(uuid)'::regprocedure) <> 's'
     OR (SELECT provolatile FROM pg_proc WHERE oid = 'public.get_inventory_count_freshness(uuid, uuid, integer)'::regprocedure) <> 's'
     OR (SELECT provolatile FROM pg_proc WHERE oid = 'public.inventory_location_count_freshness(uuid, timestamptz)'::regprocedure) <> 's' THEN
    RAISE EXCEPTION 'Phase 7B.5 postcheck: read functions must be STABLE';
  END IF;
  IF has_function_privilege('authenticated', 'public.inventory_location_count_freshness(uuid, timestamptz)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.inventory_location_count_freshness(uuid, timestamptz)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Phase 7B.5 postcheck: the freshness helper must not be client-callable';
  END IF;
  IF has_table_privilege('authenticated', 'public.inventory_count_policies', 'SELECT')
     OR has_table_privilege('authenticated', 'public.inventory_count_policies', 'INSERT')
     OR has_table_privilege('authenticated', 'public.inventory_count_policies', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.inventory_count_policies', 'DELETE')
     OR has_table_privilege('anon', 'public.inventory_count_policies', 'SELECT')
     OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.inventory_count_policies'::regclass)
     OR EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'inventory_count_policies') THEN
    RAISE EXCEPTION 'Phase 7B.5 postcheck: the policy table must have no client access';
  END IF;
  IF current_setting('medspend.phase7b5_raw_access', true) IS DISTINCT FROM (SELECT md5(string_agg(entry, '|' ORDER BY entry)) FROM (
         SELECT 'acl:' || c.relname || '=' || coalesce(c.relacl::text, '') AS entry
         FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relname IN ('inventory_items', 'inventory_locations', 'inventory_location_balances',
           'inventory_transfers', 'inventory_adjustments', 'inventory_count_sessions', 'inventory_count_lines',
           'inventory_location_labels', 'organizations')
         UNION ALL
         SELECT 'policy:' || tablename || ':' || policyname || '=' || concat_ws('|', cmd, array_to_string(roles, ','), qual, with_check)
         FROM pg_policies
         WHERE schemaname = 'public' AND tablename IN ('inventory_items', 'inventory_locations', 'inventory_location_balances',
           'inventory_transfers', 'inventory_adjustments', 'inventory_count_sessions', 'inventory_count_lines',
           'inventory_location_labels', 'organizations')) raw_access) THEN
    RAISE EXCEPTION 'Phase 7B.5 postcheck: existing table access changed';
  END IF;
END
$postcheck$;

COMMIT;
