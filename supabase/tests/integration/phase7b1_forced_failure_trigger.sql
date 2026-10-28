-- TEST-ONLY, disposable database only: never part of a migration or release.
-- Makes issuing a replacement label fail for 'Forced Failure Cabinet' after its earlier
-- labels were revoked in the same transaction, i.e. exactly between the two halves of
-- replace_inventory_location_labels. An ordinary issue still succeeds (nothing at that
-- location was revoked in its own transaction).
CREATE FUNCTION public.phase7b1_itest_fail_replacement() RETURNS trigger
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.inventory_locations
             WHERE id = NEW.inventory_location_id AND name = 'Forced Failure Cabinet')
     AND EXISTS (SELECT 1 FROM public.inventory_location_labels
                 WHERE inventory_location_id = NEW.inventory_location_id AND revoked_at = now()) THEN
    RAISE EXCEPTION 'phase7b1 forced replacement failure';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER phase7b1_itest_fail_replacement BEFORE INSERT ON public.inventory_location_labels
  FOR EACH ROW EXECUTE FUNCTION public.phase7b1_itest_fail_replacement();
