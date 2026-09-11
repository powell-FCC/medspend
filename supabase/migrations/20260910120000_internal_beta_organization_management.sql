-- Internal-beta Settings controls. Reuse active flags; never delete history.
-- Direct membership writes remain denied by RLS. Structure writes retain their
-- existing organization-admin policies, but clients must archive instead of delete.
REVOKE DELETE ON public.organization_memberships, public.teams, public.locations FROM authenticated;
REVOKE UPDATE ON public.teams, public.locations FROM authenticated;
GRANT UPDATE (name, active) ON public.teams, public.locations TO authenticated;

-- The legacy requester SELECT policy only checked identity. Deactivated members
-- must also lose direct API access to their requests (and dependent line/update reads).
CREATE POLICY supply_requests_active_membership_select ON public.supply_requests
  AS RESTRICTIVE FOR SELECT TO authenticated
  USING (public.is_org_member(organization_id, auth.uid()));

-- Cover legacy invitation upserts as well as the new management RPC. Serialize
-- owner changes per organization so simultaneous removals cannot remove all owners.
CREATE FUNCTION public.protect_organization_membership()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND (
    NEW.organization_id IS DISTINCT FROM OLD.organization_id OR NEW.user_id IS DISTINCT FROM OLD.user_id
  ) THEN
    RAISE EXCEPTION 'Membership identity cannot be changed' USING ERRCODE = '22023';
  END IF;

  -- Write the serialization row: a lock alone would permit stale owner counts
  -- under REPEATABLE READ. Concurrent transactions must see the write or abort.
  UPDATE public.organizations SET updated_at = now() WHERE id = OLD.organization_id;
  IF OLD.active AND OLD.role = 'owner' AND (
    TG_OP = 'DELETE' OR NOT NEW.active OR NEW.role <> 'owner'
  ) AND NOT EXISTS (
    SELECT 1 FROM public.organization_memberships
    WHERE organization_id = OLD.organization_id AND id <> OLD.id AND active AND role = 'owner'
  ) THEN
    RAISE EXCEPTION 'Keep at least one active owner' USING ERRCODE = '22023';
  END IF;

  IF OLD.user_id = auth.uid() THEN
    IF TG_OP = 'DELETE' OR (OLD.active AND (NOT NEW.active OR NEW.role <> OLD.role)) THEN
      RAISE EXCEPTION 'You cannot change your own role or deactivate yourself' USING ERRCODE = '22023';
    END IF;
    IF NOT OLD.active AND NEW.active THEN
      RAISE EXCEPTION 'Ask an owner or admin to reactivate your membership' USING ERRCODE = '42501';
    END IF;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.protect_organization_membership() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER organization_memberships_protect_access
  BEFORE UPDATE OF organization_id, user_id, role, active OR DELETE ON public.organization_memberships
  FOR EACH ROW EXECUTE FUNCTION public.protect_organization_membership();

CREATE FUNCTION public.update_organization_member(
  _organization_id uuid, _membership_id uuid, _changes jsonb
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  _member public.organization_memberships%ROWTYPE;
  _role public.org_role;
  _active boolean;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_org_admin(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden' USING ERRCODE = '42501';
  END IF;
  -- Acquire before reading the target or rechecking the actor's current access.
  UPDATE public.organizations SET updated_at = now() WHERE id = _organization_id;
  IF NOT public.is_org_admin(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO _member FROM public.organization_memberships
    WHERE id = _membership_id AND organization_id = _organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Member not found in this organization' USING ERRCODE = '22023'; END IF;

  IF _changes IS NULL OR jsonb_typeof(_changes) <> 'object' OR _changes = '{}'::jsonb THEN
    RAISE EXCEPTION 'Choose a change' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_object_keys(_changes) key
    WHERE key NOT IN ('role', 'active', 'default_team_id', 'default_location_id')) THEN
    RAISE EXCEPTION 'Unsupported member field' USING ERRCODE = '22023';
  END IF;
  IF (_changes ? 'role' AND (jsonb_typeof(_changes->'role') <> 'string'
      OR _changes->>'role' NOT IN ('owner', 'admin', 'staff')))
    OR (_changes ? 'active' AND jsonb_typeof(_changes->'active') <> 'boolean') THEN
    RAISE EXCEPTION 'Invalid role or active status' USING ERRCODE = '22023';
  END IF;
  _role := CASE WHEN _changes ? 'role' THEN (_changes->>'role')::public.org_role ELSE _member.role END;
  _active := CASE WHEN _changes ? 'active' THEN (_changes->>'active')::boolean ELSE _member.active END;
  IF (_member.role = 'owner' OR _role = 'owner') AND NOT public.has_org_role(
    _organization_id, auth.uid(), ARRAY['owner']::public.org_role[]
  ) THEN
    RAISE EXCEPTION 'Only owners can manage owners' USING ERRCODE = '42501';
  END IF;

  UPDATE public.organization_memberships SET
    role = _role,
    active = _active,
    default_team_id = CASE WHEN _changes ? 'default_team_id'
      THEN (_changes->>'default_team_id')::uuid ELSE default_team_id END,
    default_location_id = CASE WHEN _changes ? 'default_location_id'
      THEN (_changes->>'default_location_id')::uuid ELSE default_location_id END
  WHERE id = _membership_id AND organization_id = _organization_id;

  IF NOT _active THEN
    -- Existing links must not silently restore access after deactivation.
    UPDATE public.organization_invites SET revoked_at = now()
    WHERE organization_id = _organization_id AND accepted_at IS NULL AND revoked_at IS NULL
      AND lower(invited_email) = (SELECT lower(email) FROM auth.users WHERE id = _member.user_id);
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.update_organization_member(uuid, uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_organization_member(uuid, uuid, jsonb) TO authenticated;

-- New defaults must be active. Unchanged defaults can survive old archived data.
-- Share locks serialize new defaults with archive cleanup below.
CREATE OR REPLACE FUNCTION public.validate_organization_context_defaults()
RETURNS trigger
LANGUAGE plpgsql SET search_path = public
AS $$
DECLARE
  _team_changed boolean := TG_OP = 'INSERT';
  _location_changed boolean := TG_OP = 'INSERT';
BEGIN
  IF TG_OP = 'UPDATE' THEN
    _team_changed := NEW.default_team_id IS DISTINCT FROM OLD.default_team_id
      OR NEW.organization_id IS DISTINCT FROM OLD.organization_id;
    _location_changed := NEW.default_location_id IS DISTINCT FROM OLD.default_location_id
      OR NEW.organization_id IS DISTINCT FROM OLD.organization_id;
  END IF;
  IF NEW.default_team_id IS NOT NULL THEN
    PERFORM 1 FROM public.teams WHERE id = NEW.default_team_id AND organization_id = NEW.organization_id
      AND (NOT _team_changed OR active) FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Selected team is unavailable for this organization' USING ERRCODE = '22023'; END IF;
  END IF;
  IF NEW.default_location_id IS NOT NULL THEN
    PERFORM 1 FROM public.locations WHERE id = NEW.default_location_id AND organization_id = NEW.organization_id
      AND (NOT _location_changed OR active) FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Selected location is unavailable for this organization' USING ERRCODE = '22023'; END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE FUNCTION public.clear_archived_organization_defaults()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  -- Clear only workflow defaults, never request/invoice foreign keys.
  IF TG_TABLE_NAME = 'teams' THEN
    UPDATE public.organization_memberships SET default_team_id = NULL
      WHERE organization_id = NEW.organization_id AND default_team_id = NEW.id;
    UPDATE public.organization_invites SET default_team_id = NULL
      WHERE organization_id = NEW.organization_id AND default_team_id = NEW.id;
  ELSE
    UPDATE public.organization_memberships SET default_location_id = NULL
      WHERE organization_id = NEW.organization_id AND default_location_id = NEW.id;
    UPDATE public.organization_invites SET default_location_id = NULL
      WHERE organization_id = NEW.organization_id AND default_location_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.clear_archived_organization_defaults() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER teams_clear_archived_defaults AFTER UPDATE OF active ON public.teams
  FOR EACH ROW WHEN (OLD.active AND NOT NEW.active) EXECUTE FUNCTION public.clear_archived_organization_defaults();
CREATE TRIGGER locations_clear_archived_defaults AFTER UPDATE OF active ON public.locations
  FOR EACH ROW WHEN (OLD.active AND NOT NEW.active) EXECUTE FUNCTION public.clear_archived_organization_defaults();

-- Deactivated members still have names in Settings and historical request views.
-- Keep the existing return shape, organization boundary, and admin-only access.
CREATE OR REPLACE FUNCTION public.list_organization_member_identities(_organization_id uuid)
RETURNS TABLE(user_id uuid, display_name text, email text, default_team_name text, default_location_name text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT membership.user_id,
    coalesce(
      nullif(btrim(profile.full_name), ''),
      nullif(btrim(concat_ws(' ', auth_user.raw_user_meta_data->>'first_name', auth_user.raw_user_meta_data->>'last_name')), ''),
      nullif(btrim(coalesce(auth_user.raw_user_meta_data->>'display_name', auth_user.raw_user_meta_data->>'full_name', auth_user.raw_user_meta_data->>'name')), ''),
      nullif(btrim(profile.email), ''), nullif(btrim(auth_user.email), ''),
      'Member ' || left(membership.user_id::text, 8)
    ),
    coalesce(nullif(btrim(profile.email), ''), nullif(btrim(auth_user.email), '')),
    default_team.name, default_location.name
  FROM public.organization_memberships membership
  LEFT JOIN public.profiles profile ON profile.id = membership.user_id
  LEFT JOIN auth.users auth_user ON auth_user.id = membership.user_id
  LEFT JOIN public.teams default_team ON default_team.id = membership.default_team_id
    AND default_team.organization_id = membership.organization_id AND default_team.active
  LEFT JOIN public.locations default_location ON default_location.id = membership.default_location_id
    AND default_location.organization_id = membership.organization_id AND default_location.active
  WHERE membership.organization_id = _organization_id
    AND public.is_org_admin(_organization_id, auth.uid());
$$;
REVOKE ALL ON FUNCTION public.list_organization_member_identities(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_organization_member_identities(uuid) TO authenticated;
