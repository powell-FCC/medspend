-- Phase 2A: organization catalog. Forward-only; Phase 1 objects remain compatible.

CREATE OR REPLACE FUNCTION public.normalize_catalog_text(_value text)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE SET search_path = public AS $$
  SELECT btrim(regexp_replace(lower(COALESCE(_value, '')), '[^a-z0-9]+', ' ', 'g'));
$$;

CREATE TABLE public.product_categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name text NOT NULL,
  normalized_name text NOT NULL,
  parent_category_id uuid REFERENCES public.product_categories(id) ON DELETE SET NULL,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT product_categories_name_present CHECK (btrim(name) <> ''),
  CONSTRAINT product_categories_parent_not_self CHECK (parent_category_id IS NULL OR parent_category_id <> id)
);
CREATE UNIQUE INDEX product_categories_active_name_uq
  ON public.product_categories (organization_id, normalized_name) WHERE active;
CREATE INDEX product_categories_org_idx ON public.product_categories (organization_id, active, name);

ALTER TABLE public.vendors
  ADD COLUMN normalized_name text,
  ADD COLUMN account_number text,
  ADD COLUMN contact_name text,
  ADD COLUMN email text,
  ADD COLUMN phone text,
  ADD COLUMN website text,
  ADD COLUMN notes text,
  ADD COLUMN active boolean NOT NULL DEFAULT true;
UPDATE public.vendors SET normalized_name = public.normalize_catalog_text(name);
ALTER TABLE public.vendors ALTER COLUMN normalized_name SET NOT NULL;
CREATE UNIQUE INDEX vendors_active_name_uq
  ON public.vendors (organization_id, normalized_name) WHERE active;
CREATE INDEX vendors_org_search_idx ON public.vendors (organization_id, active, normalized_name);

ALTER TABLE public.products
  ADD COLUMN normalized_name text,
  ADD COLUMN description text,
  ADD COLUMN category_id uuid REFERENCES public.product_categories(id) ON DELETE SET NULL,
  ADD COLUMN preferred_vendor_id uuid REFERENCES public.vendors(id) ON DELETE SET NULL,
  ADD COLUMN manufacturer text,
  ADD COLUMN vendor_item_number text,
  ADD COLUMN internal_item_code text,
  ADD COLUMN unit_of_measure text,
  ADD COLUMN pack_size text,
  ADD COLUMN active boolean NOT NULL DEFAULT true,
  ADD COLUMN staff_requestable boolean NOT NULL DEFAULT true;
UPDATE public.products SET
  normalized_name = public.normalize_catalog_text(name),
  unit_of_measure = unit,
  staff_requestable = approved;
ALTER TABLE public.products ALTER COLUMN normalized_name SET NOT NULL;
CREATE UNIQUE INDEX products_active_name_uq
  ON public.products (organization_id, normalized_name) WHERE active;
CREATE INDEX products_org_search_idx ON public.products (organization_id, active, staff_requestable, normalized_name);

ALTER TABLE public.product_aliases
  ADD COLUMN normalized_alias text;
UPDATE public.product_aliases SET normalized_alias = public.normalize_catalog_text(alias);
ALTER TABLE public.product_aliases ALTER COLUMN normalized_alias SET NOT NULL;
CREATE UNIQUE INDEX product_aliases_product_alias_uq
  ON public.product_aliases (product_id, normalized_alias);
CREATE INDEX product_aliases_org_search_idx ON public.product_aliases (organization_id, normalized_alias);

CREATE OR REPLACE FUNCTION public.catalog_normalize_row()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_TABLE_NAME = 'product_aliases' THEN
    NEW.alias := btrim(NEW.alias);
    NEW.normalized_alias := public.normalize_catalog_text(NEW.alias);
  ELSE
    NEW.name := btrim(NEW.name);
    NEW.normalized_name := public.normalize_catalog_text(NEW.name);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER product_categories_normalize BEFORE INSERT OR UPDATE OF name
  ON public.product_categories FOR EACH ROW EXECUTE FUNCTION public.catalog_normalize_row();
CREATE TRIGGER vendors_normalize BEFORE INSERT OR UPDATE OF name
  ON public.vendors FOR EACH ROW EXECUTE FUNCTION public.catalog_normalize_row();
CREATE TRIGGER products_normalize BEFORE INSERT OR UPDATE OF name
  ON public.products FOR EACH ROW EXECUTE FUNCTION public.catalog_normalize_row();
CREATE TRIGGER product_aliases_normalize BEFORE INSERT OR UPDATE OF alias
  ON public.product_aliases FOR EACH ROW EXECUTE FUNCTION public.catalog_normalize_row();
CREATE TRIGGER product_categories_updated_at BEFORE UPDATE ON public.product_categories
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

CREATE OR REPLACE FUNCTION public.seed_product_categories(_organization_id uuid)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  INSERT INTO public.product_categories (organization_id, name, normalized_name)
  SELECT _organization_id, name, public.normalize_catalog_text(name)
  FROM unnest(ARRAY[
    'Athletic Tape','Bracing','Rehabilitation','First Aid','Wound Care',
    'Emergency Equipment','Pharmaceuticals','Hydration','Nutrition','Recovery',
    'PPE','Office','Other'
  ]) AS seed(name)
  ON CONFLICT DO NOTHING;
$$;
REVOKE ALL ON FUNCTION public.seed_product_categories(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.seed_categories_for_new_org()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.seed_product_categories(NEW.id);
  RETURN NEW;
END;
$$;
CREATE TRIGGER organizations_seed_product_categories
  AFTER INSERT ON public.organizations FOR EACH ROW EXECUTE FUNCTION public.seed_categories_for_new_org();
SELECT public.seed_product_categories(id) FROM public.organizations;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.product_categories TO authenticated;
GRANT ALL ON public.product_categories TO service_role;
ALTER TABLE public.product_categories ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS product_select_member ON public.products;
DROP POLICY IF EXISTS product_write_admin ON public.products;
DROP POLICY IF EXISTS alias_select_member ON public.product_aliases;
DROP POLICY IF EXISTS alias_write_admin ON public.product_aliases;
DROP POLICY IF EXISTS vendor_admin_all ON public.vendors;

CREATE POLICY category_select_member ON public.product_categories FOR SELECT TO authenticated
  USING (public.is_org_admin(organization_id, auth.uid()) OR
    (active AND public.is_org_member(organization_id, auth.uid())));
CREATE POLICY category_write_admin ON public.product_categories FOR ALL TO authenticated
  USING (public.is_org_admin(organization_id, auth.uid()))
  WITH CHECK (public.is_org_admin(organization_id, auth.uid()));

CREATE POLICY vendor_admin_all ON public.vendors FOR ALL TO authenticated
  USING (public.is_org_admin(organization_id, auth.uid()))
  WITH CHECK (public.is_org_admin(organization_id, auth.uid()));

CREATE POLICY product_select_catalog ON public.products FOR SELECT TO authenticated
  USING (public.is_org_admin(organization_id, auth.uid()) OR
    (active AND staff_requestable AND public.is_org_member(organization_id, auth.uid())));
CREATE POLICY product_write_admin ON public.products FOR ALL TO authenticated
  USING (public.is_org_admin(organization_id, auth.uid()))
  WITH CHECK (public.is_org_admin(organization_id, auth.uid()));

CREATE POLICY alias_select_catalog ON public.product_aliases FOR SELECT TO authenticated
  USING (public.is_org_admin(organization_id, auth.uid()) OR EXISTS (
    SELECT 1 FROM public.products p
    WHERE p.id = product_aliases.product_id
      AND p.organization_id = product_aliases.organization_id
      AND p.active AND p.staff_requestable
      AND public.is_org_member(p.organization_id, auth.uid())
  ));
CREATE POLICY alias_write_admin ON public.product_aliases FOR ALL TO authenticated
  USING (public.is_org_admin(organization_id, auth.uid()))
  WITH CHECK (public.is_org_admin(organization_id, auth.uid()));

-- Prevent references from crossing organization boundaries.
CREATE UNIQUE INDEX product_categories_id_org_uq ON public.product_categories (id, organization_id);
CREATE UNIQUE INDEX vendors_id_org_uq ON public.vendors (id, organization_id);
CREATE UNIQUE INDEX products_id_org_uq ON public.products (id, organization_id);
ALTER TABLE public.product_categories ADD CONSTRAINT product_categories_parent_org_fk
  FOREIGN KEY (parent_category_id, organization_id)
  REFERENCES public.product_categories(id, organization_id);
ALTER TABLE public.products ADD CONSTRAINT products_category_org_fk
  FOREIGN KEY (category_id, organization_id)
  REFERENCES public.product_categories(id, organization_id);
ALTER TABLE public.products ADD CONSTRAINT products_vendor_org_fk
  FOREIGN KEY (preferred_vendor_id, organization_id)
  REFERENCES public.vendors(id, organization_id);
ALTER TABLE public.product_aliases ADD CONSTRAINT product_aliases_product_org_fk
  FOREIGN KEY (product_id, organization_id)
  REFERENCES public.products(id, organization_id) ON DELETE CASCADE;
