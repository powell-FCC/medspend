
-- =========================================
-- ENUMS
-- =========================================
CREATE TYPE public.org_role AS ENUM ('owner', 'admin', 'staff');
CREATE TYPE public.supply_request_type AS ENUM ('reorder', 'low_stock', 'out_of_stock', 'new_item');
CREATE TYPE public.supply_request_status AS ENUM ('submitted', 'under_review', 'approved', 'ordered', 'received', 'completed', 'denied');

-- =========================================
-- updated_at helper
-- =========================================
CREATE OR REPLACE FUNCTION public.tg_set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

-- =========================================
-- PROFILES
-- =========================================
CREATE TABLE public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name TEXT,
  email TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.profiles TO authenticated;
GRANT ALL ON public.profiles TO service_role;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "profiles_select_own" ON public.profiles FOR SELECT TO authenticated USING (auth.uid() = id);
CREATE POLICY "profiles_update_own" ON public.profiles FOR UPDATE TO authenticated USING (auth.uid() = id) WITH CHECK (auth.uid() = id);
CREATE POLICY "profiles_insert_own" ON public.profiles FOR INSERT TO authenticated WITH CHECK (auth.uid() = id);
CREATE TRIGGER profiles_updated_at BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

-- New-user trigger: create profile row
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, email, full_name)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.raw_user_meta_data->>'name', '')
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- =========================================
-- ORGANIZATIONS
-- =========================================
CREATE TABLE public.organizations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.organizations TO authenticated;
GRANT ALL ON public.organizations TO service_role;
ALTER TABLE public.organizations ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER organizations_updated_at BEFORE UPDATE ON public.organizations FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

-- =========================================
-- MEMBERSHIPS
-- =========================================
CREATE TABLE public.organization_memberships (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role public.org_role NOT NULL,
  active BOOLEAN NOT NULL DEFAULT true,
  invited_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  default_team_id UUID,
  default_location_id UUID,
  joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (organization_id, user_id)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.organization_memberships TO authenticated;
GRANT ALL ON public.organization_memberships TO service_role;
ALTER TABLE public.organization_memberships ENABLE ROW LEVEL SECURITY;
CREATE INDEX ix_om_user ON public.organization_memberships (user_id) WHERE active;
CREATE INDEX ix_om_org ON public.organization_memberships (organization_id) WHERE active;
CREATE TRIGGER om_updated_at BEFORE UPDATE ON public.organization_memberships FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

-- =========================================
-- ROLE HELPERS (security definer, no recursion)
-- =========================================
CREATE OR REPLACE FUNCTION public.is_org_member(_org UUID, _user UUID)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.organization_memberships
    WHERE organization_id = _org AND user_id = _user AND active = true
  );
$$;

CREATE OR REPLACE FUNCTION public.has_org_role(_org UUID, _user UUID, _roles public.org_role[])
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.organization_memberships
    WHERE organization_id = _org AND user_id = _user AND active = true AND role = ANY (_roles)
  );
$$;

CREATE OR REPLACE FUNCTION public.is_org_admin(_org UUID, _user UUID)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.has_org_role(_org, _user, ARRAY['owner','admin']::public.org_role[]);
$$;

-- Memberships policies (after helpers exist)
CREATE POLICY "om_select_own" ON public.organization_memberships FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.is_org_admin(organization_id, auth.uid()));
-- No direct insert/update/delete from clients; RPCs use service role.

-- Organizations policies
CREATE POLICY "org_select_member" ON public.organizations FOR SELECT TO authenticated
  USING (public.is_org_member(id, auth.uid()));
CREATE POLICY "org_update_owner" ON public.organizations FOR UPDATE TO authenticated
  USING (public.has_org_role(id, auth.uid(), ARRAY['owner']::public.org_role[]))
  WITH CHECK (public.has_org_role(id, auth.uid(), ARRAY['owner']::public.org_role[]));
-- Insert only through RPC (service role).

-- =========================================
-- LOCATIONS
-- =========================================
CREATE TABLE public.locations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.locations TO authenticated;
GRANT ALL ON public.locations TO service_role;
ALTER TABLE public.locations ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER locations_updated_at BEFORE UPDATE ON public.locations FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();
CREATE POLICY "loc_select_member" ON public.locations FOR SELECT TO authenticated USING (public.is_org_member(organization_id, auth.uid()));
CREATE POLICY "loc_write_admin" ON public.locations FOR ALL TO authenticated
  USING (public.is_org_admin(organization_id, auth.uid()))
  WITH CHECK (public.is_org_admin(organization_id, auth.uid()));

-- =========================================
-- TEAMS
-- =========================================
CREATE TABLE public.teams (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.teams TO authenticated;
GRANT ALL ON public.teams TO service_role;
ALTER TABLE public.teams ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER teams_updated_at BEFORE UPDATE ON public.teams FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();
CREATE POLICY "team_select_member" ON public.teams FOR SELECT TO authenticated USING (public.is_org_member(organization_id, auth.uid()));
CREATE POLICY "team_write_admin" ON public.teams FOR ALL TO authenticated
  USING (public.is_org_admin(organization_id, auth.uid()))
  WITH CHECK (public.is_org_admin(organization_id, auth.uid()));

-- FK from memberships to team/location (now that tables exist)
ALTER TABLE public.organization_memberships
  ADD CONSTRAINT om_default_team_fk FOREIGN KEY (default_team_id) REFERENCES public.teams(id) ON DELETE SET NULL;
ALTER TABLE public.organization_memberships
  ADD CONSTRAINT om_default_location_fk FOREIGN KEY (default_location_id) REFERENCES public.locations(id) ON DELETE SET NULL;

-- =========================================
-- VENDORS
-- =========================================
CREATE TABLE public.vendors (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.vendors TO authenticated;
GRANT ALL ON public.vendors TO service_role;
ALTER TABLE public.vendors ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER vendors_updated_at BEFORE UPDATE ON public.vendors FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();
-- Only admins/owners can read vendors (may include pricing negotiations); staff should not see vendor data
CREATE POLICY "vendor_admin_all" ON public.vendors FOR ALL TO authenticated
  USING (public.is_org_admin(organization_id, auth.uid()))
  WITH CHECK (public.is_org_admin(organization_id, auth.uid()));

-- =========================================
-- PRODUCTS
-- =========================================
CREATE TABLE public.products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  unit TEXT,
  approved BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.products TO authenticated;
GRANT ALL ON public.products TO service_role;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER products_updated_at BEFORE UPDATE ON public.products FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();
-- Staff read approved products only; admins full
CREATE POLICY "product_select_member" ON public.products FOR SELECT TO authenticated
  USING (public.is_org_member(organization_id, auth.uid()) AND (approved OR public.is_org_admin(organization_id, auth.uid())));
CREATE POLICY "product_write_admin" ON public.products FOR ALL TO authenticated
  USING (public.is_org_admin(organization_id, auth.uid()))
  WITH CHECK (public.is_org_admin(organization_id, auth.uid()));

-- =========================================
-- PRODUCT ALIASES
-- =========================================
CREATE TABLE public.product_aliases (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  alias TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.product_aliases TO authenticated;
GRANT ALL ON public.product_aliases TO service_role;
ALTER TABLE public.product_aliases ENABLE ROW LEVEL SECURITY;
CREATE POLICY "alias_select_member" ON public.product_aliases FOR SELECT TO authenticated USING (public.is_org_member(organization_id, auth.uid()));
CREATE POLICY "alias_write_admin" ON public.product_aliases FOR ALL TO authenticated
  USING (public.is_org_admin(organization_id, auth.uid()))
  WITH CHECK (public.is_org_admin(organization_id, auth.uid()));

-- =========================================
-- INVITATIONS
-- =========================================
CREATE TABLE public.organization_invites (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  invited_email TEXT NOT NULL,
  invited_name TEXT,
  invited_role public.org_role NOT NULL DEFAULT 'staff',
  default_team_id UUID REFERENCES public.teams(id) ON DELETE SET NULL,
  default_location_id UUID REFERENCES public.locations(id) ON DELETE SET NULL,
  token_hash TEXT NOT NULL UNIQUE,
  expires_at TIMESTAMPTZ NOT NULL,
  accepted_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ,
  invited_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.organization_invites TO authenticated;
GRANT ALL ON public.organization_invites TO service_role;
ALTER TABLE public.organization_invites ENABLE ROW LEVEL SECURITY;
CREATE POLICY "invite_admin_all" ON public.organization_invites FOR ALL TO authenticated
  USING (public.is_org_admin(organization_id, auth.uid()))
  WITH CHECK (public.is_org_admin(organization_id, auth.uid()));

-- =========================================
-- SUPPLY REQUESTS
-- =========================================
CREATE TABLE public.supply_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  requested_by UUID NOT NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  team_id UUID REFERENCES public.teams(id) ON DELETE SET NULL,
  location_id UUID REFERENCES public.locations(id) ON DELETE SET NULL,
  product_id UUID REFERENCES public.products(id) ON DELETE SET NULL,
  free_text_item TEXT,
  request_type public.supply_request_type NOT NULL,
  quantity NUMERIC,
  notes TEXT,
  status public.supply_request_status NOT NULL DEFAULT 'submitted',
  assigned_to UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  vendor_id UUID REFERENCES public.vendors(id) ON DELETE SET NULL,
  ordered_at TIMESTAMPTZ,
  received_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.supply_requests TO authenticated;
GRANT ALL ON public.supply_requests TO service_role;
ALTER TABLE public.supply_requests ENABLE ROW LEVEL SECURITY;
CREATE INDEX ix_sr_org ON public.supply_requests (organization_id);
CREATE INDEX ix_sr_requester ON public.supply_requests (requested_by);
CREATE TRIGGER sr_updated_at BEFORE UPDATE ON public.supply_requests FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

CREATE POLICY "sr_select_own_or_admin" ON public.supply_requests FOR SELECT TO authenticated
  USING (requested_by = auth.uid() OR public.is_org_admin(organization_id, auth.uid()));
CREATE POLICY "sr_insert_member" ON public.supply_requests FOR INSERT TO authenticated
  WITH CHECK (
    requested_by = auth.uid()
    AND public.is_org_member(organization_id, auth.uid())
  );
CREATE POLICY "sr_update_admin" ON public.supply_requests FOR UPDATE TO authenticated
  USING (public.is_org_admin(organization_id, auth.uid()))
  WITH CHECK (public.is_org_admin(organization_id, auth.uid()));
CREATE POLICY "sr_delete_admin" ON public.supply_requests FOR DELETE TO authenticated
  USING (public.is_org_admin(organization_id, auth.uid()));

-- =========================================
-- SUPPLY REQUEST UPDATES
-- =========================================
CREATE TABLE public.supply_request_updates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  supply_request_id UUID NOT NULL REFERENCES public.supply_requests(id) ON DELETE CASCADE,
  author_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  status_from public.supply_request_status,
  status_to public.supply_request_status,
  internal_note TEXT,
  staff_visible_note TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.supply_request_updates TO authenticated;
GRANT ALL ON public.supply_request_updates TO service_role;
ALTER TABLE public.supply_request_updates ENABLE ROW LEVEL SECURITY;
CREATE INDEX ix_sru_req ON public.supply_request_updates (supply_request_id);

CREATE POLICY "sru_select_visibility" ON public.supply_request_updates FOR SELECT TO authenticated
  USING (
    public.is_org_admin(organization_id, auth.uid())
    OR (
      staff_visible_note IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM public.supply_requests r
        WHERE r.id = supply_request_updates.supply_request_id
          AND r.requested_by = auth.uid()
      )
    )
  );
CREATE POLICY "sru_write_admin" ON public.supply_request_updates FOR ALL TO authenticated
  USING (public.is_org_admin(organization_id, auth.uid()))
  WITH CHECK (public.is_org_admin(organization_id, auth.uid()));

-- =========================================
-- INVOICES (placeholder for Phase 2)
-- =========================================
CREATE TABLE public.invoices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  vendor_id UUID REFERENCES public.vendors(id) ON DELETE SET NULL,
  invoice_number TEXT,
  total NUMERIC,
  invoice_date DATE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.invoices TO authenticated;
GRANT ALL ON public.invoices TO service_role;
ALTER TABLE public.invoices ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER invoices_updated_at BEFORE UPDATE ON public.invoices FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();
CREATE POLICY "inv_admin_all" ON public.invoices FOR ALL TO authenticated
  USING (public.is_org_admin(organization_id, auth.uid()))
  WITH CHECK (public.is_org_admin(organization_id, auth.uid()));

CREATE TABLE public.invoice_line_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  invoice_id UUID NOT NULL REFERENCES public.invoices(id) ON DELETE CASCADE,
  product_id UUID REFERENCES public.products(id) ON DELETE SET NULL,
  description TEXT,
  quantity NUMERIC,
  unit_price NUMERIC,
  line_total NUMERIC,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.invoice_line_items TO authenticated;
GRANT ALL ON public.invoice_line_items TO service_role;
ALTER TABLE public.invoice_line_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "ili_admin_all" ON public.invoice_line_items FOR ALL TO authenticated
  USING (public.is_org_admin(organization_id, auth.uid()))
  WITH CHECK (public.is_org_admin(organization_id, auth.uid()));

-- =========================================
-- RPCs
-- =========================================

-- Create organization + owner membership atomically
CREATE OR REPLACE FUNCTION public.create_organization(_name TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid UUID := auth.uid();
  _org_id UUID;
BEGIN
  IF _uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;
  IF _name IS NULL OR btrim(_name) = '' THEN
    RAISE EXCEPTION 'name required';
  END IF;

  INSERT INTO public.organizations (name, created_by)
  VALUES (btrim(_name), _uid)
  RETURNING id INTO _org_id;

  INSERT INTO public.organization_memberships (organization_id, user_id, role, active, joined_at)
  VALUES (_org_id, _uid, 'owner', true, now());

  RETURN _org_id;
END;
$$;
REVOKE ALL ON FUNCTION public.create_organization(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_organization(TEXT) TO authenticated;

-- Create invitation: returns raw token (only time it is exposed)
CREATE OR REPLACE FUNCTION public.create_invitation(
  _organization_id UUID,
  _invited_email TEXT,
  _invited_name TEXT,
  _invited_role public.org_role,
  _default_team_id UUID,
  _default_location_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  _uid UUID := auth.uid();
  _raw TEXT;
  _hash TEXT;
BEGIN
  IF _uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF NOT public.is_org_admin(_organization_id, _uid) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF _invited_email IS NULL OR btrim(_invited_email) = '' THEN
    RAISE EXCEPTION 'email required';
  END IF;

  _raw := encode(extensions.gen_random_bytes(24), 'hex');
  _hash := encode(extensions.digest(_raw, 'sha256'), 'hex');

  INSERT INTO public.organization_invites (
    organization_id, invited_email, invited_name, invited_role,
    default_team_id, default_location_id, token_hash, expires_at, invited_by
  ) VALUES (
    _organization_id,
    lower(btrim(_invited_email)),
    _invited_name,
    COALESCE(_invited_role, 'staff'),
    _default_team_id,
    _default_location_id,
    _hash,
    now() + interval '14 days',
    _uid
  );

  RETURN _raw;
END;
$$;
REVOKE ALL ON FUNCTION public.create_invitation(UUID, TEXT, TEXT, public.org_role, UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_invitation(UUID, TEXT, TEXT, public.org_role, UUID, UUID) TO authenticated;

-- Accept invitation: does NOT create an organization; joins the exact org_id on the invite
CREATE OR REPLACE FUNCTION public.accept_invitation(_raw_token TEXT)
RETURNS TABLE(organization_id UUID, role public.org_role, route TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
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

  SELECT email INTO _email FROM auth.users WHERE id = _uid;
  _hash := encode(extensions.digest(_raw_token, 'sha256'), 'hex');

  SELECT * INTO _inv FROM public.organization_invites WHERE token_hash = _hash;
  IF NOT FOUND THEN RAISE EXCEPTION 'invitation not found'; END IF;
  IF _inv.revoked_at IS NOT NULL THEN RAISE EXCEPTION 'invitation revoked'; END IF;
  IF _inv.accepted_at IS NOT NULL THEN RAISE EXCEPTION 'invitation already accepted'; END IF;
  IF _inv.expires_at < now() THEN RAISE EXCEPTION 'invitation expired'; END IF;
  IF lower(_inv.invited_email) <> lower(COALESCE(_email, '')) THEN
    RAISE EXCEPTION 'email does not match invitation';
  END IF;

  INSERT INTO public.organization_memberships (
    organization_id, user_id, role, active, invited_by, default_team_id, default_location_id, joined_at
  ) VALUES (
    _inv.organization_id, _uid, _inv.invited_role, true, _inv.invited_by,
    _inv.default_team_id, _inv.default_location_id, now()
  )
  ON CONFLICT (organization_id, user_id) DO UPDATE
    SET role = EXCLUDED.role,
        active = true,
        default_team_id = COALESCE(EXCLUDED.default_team_id, public.organization_memberships.default_team_id),
        default_location_id = COALESCE(EXCLUDED.default_location_id, public.organization_memberships.default_location_id),
        updated_at = now();

  UPDATE public.organization_invites SET accepted_at = now() WHERE id = _inv.id;

  organization_id := _inv.organization_id;
  role := _inv.invited_role;
  route := CASE WHEN _inv.invited_role IN ('owner','admin') THEN '/dashboard' ELSE '/staff' END;
  RETURN NEXT;
END;
$$;
REVOKE ALL ON FUNCTION public.accept_invitation(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.accept_invitation(TEXT) TO authenticated;

-- Revoke invitation
CREATE OR REPLACE FUNCTION public.revoke_invitation(_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid UUID := auth.uid();
  _org UUID;
BEGIN
  IF _uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT organization_id INTO _org FROM public.organization_invites WHERE id = _id;
  IF _org IS NULL THEN RAISE EXCEPTION 'not found'; END IF;
  IF NOT public.is_org_admin(_org, _uid) THEN RAISE EXCEPTION 'forbidden'; END IF;
  UPDATE public.organization_invites SET revoked_at = now() WHERE id = _id AND revoked_at IS NULL;
END;
$$;
REVOKE ALL ON FUNCTION public.revoke_invitation(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.revoke_invitation(UUID) TO authenticated;

-- pgcrypto for gen_random_bytes/digest
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
