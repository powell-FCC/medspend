CREATE OR REPLACE FUNCTION public.accept_invitation(_raw_token text)
 RETURNS TABLE(organization_id uuid, role org_role, route text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
#variable_conflict use_column
DECLARE
  _uid UUID := auth.uid();
  _email TEXT;
  _hash TEXT;
  _inv public.organization_invites%ROWTYPE;
BEGIN
  IF _uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF _raw_token IS NULL OR length(_raw_token) < 16 THEN
    RAISE EXCEPTION 'invalid token';
  END IF;

  SELECT u.email INTO _email FROM auth.users u WHERE u.id = _uid;
  _hash := encode(extensions.digest(_raw_token, 'sha256'), 'hex');

  SELECT * INTO _inv FROM public.organization_invites i WHERE i.token_hash = _hash;
  IF NOT FOUND THEN RAISE EXCEPTION 'invitation not found'; END IF;
  IF _inv.revoked_at IS NOT NULL THEN RAISE EXCEPTION 'invitation revoked'; END IF;
  IF _inv.accepted_at IS NOT NULL THEN RAISE EXCEPTION 'invitation already accepted'; END IF;
  IF _inv.expires_at < now() THEN RAISE EXCEPTION 'invitation expired'; END IF;
  IF lower(_inv.invited_email) <> lower(COALESCE(_email, '')) THEN
    RAISE EXCEPTION 'email does not match invitation';
  END IF;

  INSERT INTO public.organization_memberships AS m (
    organization_id, user_id, role, active, invited_by, default_team_id, default_location_id, joined_at
  ) VALUES (
    _inv.organization_id, _uid, _inv.invited_role, true, _inv.invited_by,
    _inv.default_team_id, _inv.default_location_id, now()
  )
  ON CONFLICT (organization_id, user_id) DO UPDATE
    SET role = EXCLUDED.role,
        active = true,
        default_team_id = COALESCE(EXCLUDED.default_team_id, m.default_team_id),
        default_location_id = COALESCE(EXCLUDED.default_location_id, m.default_location_id),
        updated_at = now();

  UPDATE public.organization_invites i SET accepted_at = now() WHERE i.id = _inv.id;

  organization_id := _inv.organization_id;
  role := _inv.invited_role;
  route := CASE WHEN _inv.invited_role IN ('owner','admin') THEN '/dashboard' ELSE '/staff' END;
  RETURN NEXT;
END;
$function$;