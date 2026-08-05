-- Allow an owner upload client to remove an object when metadata insertion fails.

CREATE POLICY vendor_invoices_storage_owner_delete ON storage.objects
  FOR DELETE TO authenticated
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
