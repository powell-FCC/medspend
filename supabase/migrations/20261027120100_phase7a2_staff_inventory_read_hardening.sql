-- Phase 7A.2-0: staff inventory read hardening.
--
-- inventory_items_member_select (Phase 2C) let every organization member, staff included,
-- read active inventory_items rows directly through the API, every column: purchase
-- prices and dates, par levels, organization quantities. Staff need none of that. Their
-- request screens now read item identities through get_supply_request_inventory_identities
-- (20261027120000) and counts go through the count functions, so direct reads close to
-- staff here.
--
-- Owners keep inventory_items_owner_all. Admins keep exactly what they had: active rows.
--
-- Apply AFTER the application that uses get_supply_request_inventory_identities is
-- deployed. Applied earlier, the previously deployed application would show staff request
-- lines without their inventory names until it deploys.

BEGIN;

DO $preflight$
BEGIN
  IF pg_catalog.to_regprocedure('public.get_supply_request_inventory_identities(uuid, uuid[])') IS NULL THEN
    RAISE EXCEPTION 'Phase 7A.2-0 requires get_supply_request_inventory_identities from 20261027120000';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'inventory_items'
                 AND policyname = 'inventory_items_member_select') THEN
    RAISE EXCEPTION 'Phase 7A.2-0 expected inventory_items_member_select; already hardened?';
  END IF;
END
$preflight$;

DROP POLICY inventory_items_member_select ON public.inventory_items;
CREATE POLICY inventory_items_admin_select ON public.inventory_items FOR SELECT TO authenticated
  USING (active = true AND public.has_org_role(organization_id, auth.uid(), ARRAY['admin']::public.org_role[]));

COMMIT;
