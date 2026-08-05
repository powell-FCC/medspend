-- Owner invoice upload infrastructure. No parsing or extraction occurs in this phase.

CREATE TABLE public.vendor_invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  uploaded_by uuid NOT NULL REFERENCES auth.users(id),
  storage_path text NOT NULL UNIQUE,
  original_filename text NOT NULL,
  file_size bigint NOT NULL CHECK (file_size > 0 AND file_size <= 26214400),
  mime_type text NOT NULL CHECK (mime_type = 'application/pdf'),
  status text NOT NULL DEFAULT 'uploaded' CHECK (status = 'uploaded'),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vendor_invoices_filename_present CHECK (btrim(original_filename) <> '')
);

CREATE INDEX vendor_invoices_org_created_idx
  ON public.vendor_invoices (organization_id, created_at DESC);

GRANT SELECT, INSERT ON public.vendor_invoices TO authenticated;
GRANT ALL ON public.vendor_invoices TO service_role;
ALTER TABLE public.vendor_invoices ENABLE ROW LEVEL SECURITY;

CREATE POLICY vendor_invoices_owner_select ON public.vendor_invoices
  FOR SELECT TO authenticated
  USING (public.has_org_role(
    organization_id,
    auth.uid(),
    ARRAY['owner']::public.org_role[]
  ));

CREATE POLICY vendor_invoices_owner_insert ON public.vendor_invoices
  FOR INSERT TO authenticated
  WITH CHECK (
    uploaded_by = auth.uid()
    AND public.has_org_role(
      organization_id,
      auth.uid(),
      ARRAY['owner']::public.org_role[]
    )
  );

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('vendor-invoices', 'vendor-invoices', false, 26214400, ARRAY['application/pdf'])
ON CONFLICT (id) DO UPDATE SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

CREATE POLICY vendor_invoices_storage_owner_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'vendor-invoices'
    AND EXISTS (
      SELECT 1
      FROM public.organization_memberships membership
      WHERE membership.organization_id::text = (storage.foldername(name))[1]
        AND membership.user_id = auth.uid()
        AND membership.role = 'owner'
        AND membership.active = true
    )
  );

CREATE POLICY vendor_invoices_storage_owner_select ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'vendor-invoices'
    AND EXISTS (
      SELECT 1
      FROM public.organization_memberships membership
      WHERE membership.organization_id::text = (storage.foldername(name))[1]
        AND membership.user_id = auth.uid()
        AND membership.role = 'owner'
        AND membership.active = true
    )
  );
