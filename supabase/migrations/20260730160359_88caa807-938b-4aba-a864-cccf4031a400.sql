ALTER TABLE public.teams ADD COLUMN IF NOT EXISTS active boolean NOT NULL DEFAULT true;
ALTER TABLE public.locations ADD COLUMN IF NOT EXISTS active boolean NOT NULL DEFAULT true;

DROP POLICY IF EXISTS team_select_member ON public.teams;
CREATE POLICY team_select_member ON public.teams FOR SELECT TO authenticated
  USING (is_org_member(organization_id, auth.uid()) AND (active OR is_org_admin(organization_id, auth.uid())));

DROP POLICY IF EXISTS loc_select_member ON public.locations;
CREATE POLICY loc_select_member ON public.locations FOR SELECT TO authenticated
  USING (is_org_member(organization_id, auth.uid()) AND (active OR is_org_admin(organization_id, auth.uid())));

DROP TRIGGER IF EXISTS teams_set_updated_at ON public.teams;
CREATE TRIGGER teams_set_updated_at BEFORE UPDATE ON public.teams
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();
DROP TRIGGER IF EXISTS locations_set_updated_at ON public.locations;
CREATE TRIGGER locations_set_updated_at BEFORE UPDATE ON public.locations
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();