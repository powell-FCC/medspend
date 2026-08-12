-- Phase 4A.3.1: staff identity and request-context stabilization only.

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, email, full_name)
  VALUES (
    NEW.id,
    NEW.email,
    nullif(btrim(coalesce(
      NEW.raw_user_meta_data->>'full_name',
      NEW.raw_user_meta_data->>'display_name',
      NEW.raw_user_meta_data->>'name',
      concat_ws(' ', NEW.raw_user_meta_data->>'first_name', NEW.raw_user_meta_data->>'last_name')
    )), '')
  )
  ON CONFLICT (id) DO UPDATE SET
    email = coalesce(EXCLUDED.email, public.profiles.email),
    full_name = coalesce(nullif(public.profiles.full_name, ''), EXCLUDED.full_name);
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.validate_organization_context_defaults()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.default_team_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.teams
    WHERE id = NEW.default_team_id AND organization_id = NEW.organization_id
  ) THEN
    RAISE EXCEPTION 'Selected team is unavailable for this organization';
  END IF;
  IF NEW.default_location_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.locations
    WHERE id = NEW.default_location_id AND organization_id = NEW.organization_id
  ) THEN
    RAISE EXCEPTION 'Selected location is unavailable for this organization';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER organization_memberships_validate_context
  BEFORE INSERT OR UPDATE OF organization_id, default_team_id, default_location_id
  ON public.organization_memberships
  FOR EACH ROW EXECUTE FUNCTION public.validate_organization_context_defaults();

CREATE TRIGGER organization_invites_validate_context
  BEFORE INSERT OR UPDATE OF organization_id, default_team_id, default_location_id
  ON public.organization_invites
  FOR EACH ROW EXECUTE FUNCTION public.validate_organization_context_defaults();

CREATE OR REPLACE FUNCTION public.list_organization_member_identities(_organization_id uuid)
RETURNS TABLE(user_id uuid, display_name text, email text, default_team_name text, default_location_name text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    membership.user_id,
    coalesce(
      nullif(btrim(profile.full_name), ''),
      nullif(btrim(concat_ws(' ', auth_user.raw_user_meta_data->>'first_name', auth_user.raw_user_meta_data->>'last_name')), ''),
      nullif(btrim(coalesce(
        auth_user.raw_user_meta_data->>'display_name',
        auth_user.raw_user_meta_data->>'full_name',
        auth_user.raw_user_meta_data->>'name'
      )), ''),
      nullif(btrim(profile.email), ''),
      nullif(btrim(auth_user.email), ''),
      'Member ' || left(membership.user_id::text, 8)
    ),
    coalesce(nullif(btrim(profile.email), ''), nullif(btrim(auth_user.email), '')),
    default_team.name,
    default_location.name
  FROM public.organization_memberships membership
  LEFT JOIN public.profiles profile ON profile.id = membership.user_id
  LEFT JOIN auth.users auth_user ON auth_user.id = membership.user_id
  LEFT JOIN public.teams default_team
    ON default_team.id = membership.default_team_id
    AND default_team.organization_id = membership.organization_id
    AND default_team.active = true
  LEFT JOIN public.locations default_location
    ON default_location.id = membership.default_location_id
    AND default_location.organization_id = membership.organization_id
    AND default_location.active = true
  WHERE membership.organization_id = _organization_id
    AND membership.active = true
    AND public.is_org_admin(_organization_id, auth.uid());
$$;

REVOKE ALL ON FUNCTION public.list_organization_member_identities(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_organization_member_identities(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.accept_invitation(_raw_token text)
RETURNS TABLE(organization_id uuid, role public.org_role, route text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
#variable_conflict use_column
DECLARE
  _uid uuid := auth.uid();
  _email text;
  _metadata jsonb;
  _hash text;
  _inv public.organization_invites%ROWTYPE;
BEGIN
  IF _uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF _raw_token IS NULL OR length(_raw_token) < 16 THEN RAISE EXCEPTION 'invalid token'; END IF;

  SELECT u.email, u.raw_user_meta_data INTO _email, _metadata FROM auth.users u WHERE u.id = _uid;
  _hash := encode(extensions.digest(_raw_token, 'sha256'), 'hex');
  SELECT * INTO _inv FROM public.organization_invites i WHERE i.token_hash = _hash;
  IF NOT FOUND THEN RAISE EXCEPTION 'invitation not found'; END IF;
  IF _inv.revoked_at IS NOT NULL THEN RAISE EXCEPTION 'invitation revoked'; END IF;
  IF _inv.accepted_at IS NOT NULL THEN RAISE EXCEPTION 'invitation already accepted'; END IF;
  IF _inv.expires_at < now() THEN RAISE EXCEPTION 'invitation expired'; END IF;
  IF lower(_inv.invited_email) <> lower(coalesce(_email, '')) THEN RAISE EXCEPTION 'email does not match invitation'; END IF;

  INSERT INTO public.profiles (id, email, full_name)
  VALUES (
    _uid,
    _email,
    coalesce(
      nullif(btrim(_inv.invited_name), ''),
      nullif(btrim(coalesce(_metadata->>'full_name', _metadata->>'display_name', _metadata->>'name')) , ''),
      nullif(btrim(concat_ws(' ', _metadata->>'first_name', _metadata->>'last_name')), '')
    )
  )
  ON CONFLICT (id) DO UPDATE SET
    email = coalesce(EXCLUDED.email, public.profiles.email),
    full_name = coalesce(nullif(public.profiles.full_name, ''), EXCLUDED.full_name);

  INSERT INTO public.organization_memberships AS membership (
    organization_id, user_id, role, active, invited_by, default_team_id, default_location_id, joined_at
  ) VALUES (
    _inv.organization_id, _uid, _inv.invited_role, true, _inv.invited_by,
    _inv.default_team_id, _inv.default_location_id, now()
  )
  ON CONFLICT (organization_id, user_id) DO UPDATE SET
    role = EXCLUDED.role,
    active = true,
    default_team_id = coalesce(EXCLUDED.default_team_id, membership.default_team_id),
    default_location_id = coalesce(EXCLUDED.default_location_id, membership.default_location_id),
    updated_at = now();

  UPDATE public.organization_invites invitation SET accepted_at = now() WHERE invitation.id = _inv.id;
  organization_id := _inv.organization_id;
  role := _inv.invited_role;
  route := CASE WHEN _inv.invited_role IN ('owner','admin') THEN '/dashboard' ELSE '/staff' END;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.accept_invitation(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.accept_invitation(text) TO authenticated;
