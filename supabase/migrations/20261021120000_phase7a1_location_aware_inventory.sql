-- Phase 7A.1: location-aware inventory foundation.
--
-- inventory_location_balances becomes the canonical per-location quantity store.
-- inventory_items.quantity stays as the organization-total summary that every existing
-- read path uses, and the database keeps it equal to the sum of the item's balances:
--   * only inventory_apply_balance_delta() may change either quantity (guard triggers);
--   * a deferred constraint trigger re-checks the sum for every touched item at commit.
--
-- Existing stock has no physical-location history, so the backfill puts all of it in each
-- organization's protected Unassigned location. Every receiving path keeps landing in
-- Unassigned. Historical inventory_adjustments keep inventory_location_id NULL, meaning
-- "organization-level history from before locations existed". Nothing in budgets,
-- invoices, prices, catalog or the request lifecycle changes.
--
-- Safe to apply before the application deploys: every RPC signature the deployed app calls
-- keeps working, including the four-argument adjust_inventory_quantity.

BEGIN;

-- Hold off every inventory writer (posting, deletion, adjustment) for the few statements
-- between the quantity snapshot and the backfill.
LOCK TABLE public.inventory_items, public.inventory_adjustments IN SHARE ROW EXCLUSIVE MODE;

DO $preflight$
BEGIN
  IF pg_catalog.to_regclass('public.inventory_locations') IS NOT NULL
     OR pg_catalog.to_regclass('public.inventory_location_balances') IS NOT NULL
     OR pg_catalog.to_regclass('public.inventory_transfers') IS NOT NULL THEN
    RAISE EXCEPTION 'Phase 7A.1 inventory location tables already exist unexpectedly';
  END IF;
  IF pg_catalog.to_regclass('public.inventory_items_id_org_uq') IS NULL THEN
    RAISE EXCEPTION 'Phase 7A.1 requires inventory_items_id_org_uq from Phase 5A.7';
  END IF;
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'inventory_adjustments'
      AND column_name = 'inventory_location_id'
  ) THEN
    RAISE EXCEPTION 'Phase 7A.1 inventory_adjustments.inventory_location_id already exists unexpectedly';
  END IF;
  IF EXISTS (SELECT 1 FROM public.inventory_items WHERE quantity < 0) THEN
    RAISE EXCEPTION 'Phase 7A.1 found negative inventory quantities; resolve them before migrating';
  END IF;
END
$preflight$;

-- Snapshot every item quantity so the end of this migration can prove nothing changed.
CREATE TEMP TABLE phase7a1_pre_quantities ON COMMIT DROP AS
  SELECT id, organization_id, quantity FROM public.inventory_items;
CREATE TEMP TABLE phase7a1_pre_counts ON COMMIT DROP AS
  SELECT
    (SELECT count(*) FROM public.inventory_items) AS items,
    (SELECT count(*) FROM public.inventory_adjustments) AS adjustments;

-- ---------------------------------------------------------------------------------------
-- Physical inventory locations. Deliberately separate from public.locations, which are
-- organization sites and supply-request destinations.
-- ---------------------------------------------------------------------------------------
CREATE TABLE public.inventory_locations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name text NOT NULL CHECK (btrim(name) <> '' AND char_length(name) <= 120),
  description text CHECK (description IS NULL OR char_length(description) <= 500),
  kind text NOT NULL DEFAULT 'storage' CHECK (kind IN ('unassigned', 'storage')),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (kind <> 'unassigned' OR active)
);
CREATE UNIQUE INDEX inventory_locations_id_org_uq ON public.inventory_locations (id, organization_id);
CREATE UNIQUE INDEX inventory_locations_org_name_uq ON public.inventory_locations (organization_id, lower(btrim(name)));
CREATE UNIQUE INDEX inventory_locations_org_unassigned_uq ON public.inventory_locations (organization_id)
  WHERE kind = 'unassigned';
CREATE TRIGGER inventory_locations_updated_at BEFORE UPDATE ON public.inventory_locations
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

-- ---------------------------------------------------------------------------------------
-- Canonical per-location balances.
-- ---------------------------------------------------------------------------------------
CREATE TABLE public.inventory_location_balances (
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  inventory_item_id uuid NOT NULL,
  inventory_location_id uuid NOT NULL,
  quantity numeric NOT NULL DEFAULT 0 CHECK (quantity >= 0),
  version bigint NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (inventory_item_id, inventory_location_id),
  FOREIGN KEY (inventory_item_id, organization_id)
    REFERENCES public.inventory_items(id, organization_id) ON DELETE CASCADE,
  FOREIGN KEY (inventory_location_id, organization_id)
    REFERENCES public.inventory_locations(id, organization_id)
);
CREATE INDEX inventory_location_balances_location_idx
  ON public.inventory_location_balances (inventory_location_id, inventory_item_id);
CREATE INDEX inventory_location_balances_org_idx
  ON public.inventory_location_balances (organization_id);

-- ---------------------------------------------------------------------------------------
-- Stock moves. They never change an organization total, so they stay out of
-- inventory_adjustments, whose amounts invoice deletion sums.
-- ---------------------------------------------------------------------------------------
CREATE TABLE public.inventory_transfers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  inventory_item_id uuid NOT NULL,
  from_inventory_location_id uuid NOT NULL,
  to_inventory_location_id uuid NOT NULL,
  quantity numeric NOT NULL CHECK (quantity > 0),
  idempotency_key text NOT NULL CHECK (btrim(idempotency_key) <> '' AND char_length(idempotency_key) <= 200),
  created_by uuid NOT NULL REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (from_inventory_location_id <> to_inventory_location_id),
  FOREIGN KEY (inventory_item_id, organization_id)
    REFERENCES public.inventory_items(id, organization_id) ON DELETE CASCADE,
  FOREIGN KEY (from_inventory_location_id, organization_id)
    REFERENCES public.inventory_locations(id, organization_id),
  FOREIGN KEY (to_inventory_location_id, organization_id)
    REFERENCES public.inventory_locations(id, organization_id)
);
CREATE UNIQUE INDEX inventory_transfers_idempotency_uq
  ON public.inventory_transfers (organization_id, idempotency_key);
CREATE INDEX inventory_transfers_item_created_idx
  ON public.inventory_transfers (inventory_item_id, created_at DESC);

-- ---------------------------------------------------------------------------------------
-- Location context on total-changing history. NULL marks pre-7A.1 organization-level rows.
-- 'physical_count' is reserved for Phase 7A.2; nothing writes it yet, but invoice deletion
-- already refuses to replay across one.
-- ---------------------------------------------------------------------------------------
ALTER TABLE public.inventory_adjustments ADD COLUMN inventory_location_id uuid;
ALTER TABLE public.inventory_adjustments ADD CONSTRAINT inventory_adjustments_location_org_fk
  FOREIGN KEY (inventory_location_id, organization_id)
  REFERENCES public.inventory_locations(id, organization_id);
CREATE INDEX inventory_adjustments_location_idx
  ON public.inventory_adjustments (inventory_location_id, inventory_item_id, created_at DESC)
  WHERE inventory_location_id IS NOT NULL;
ALTER TABLE public.inventory_adjustments DROP CONSTRAINT inventory_adjustments_source_type_check;
ALTER TABLE public.inventory_adjustments ADD CONSTRAINT inventory_adjustments_source_type_check
  CHECK (source_type IN ('invoice', 'manual', 'system', 'physical_count'));

-- ---------------------------------------------------------------------------------------
-- RLS and grants. Owners read; nobody writes directly. Every write goes through the
-- SECURITY DEFINER functions below.
-- ---------------------------------------------------------------------------------------
ALTER TABLE public.inventory_locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_location_balances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_transfers ENABLE ROW LEVEL SECURITY;
-- Supabase's default privileges grant ALL on new public tables to anon, authenticated and
-- service_role; take every one back before granting reads.
REVOKE ALL ON public.inventory_locations, public.inventory_location_balances, public.inventory_transfers
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.inventory_locations, public.inventory_location_balances, public.inventory_transfers
  TO authenticated;
GRANT SELECT ON public.inventory_locations, public.inventory_location_balances, public.inventory_transfers
  TO service_role;
CREATE POLICY inventory_locations_owner_select ON public.inventory_locations FOR SELECT TO authenticated
  USING (public.has_org_role(organization_id, auth.uid(), ARRAY['owner']::public.org_role[]));
CREATE POLICY inventory_location_balances_owner_select ON public.inventory_location_balances FOR SELECT TO authenticated
  USING (public.has_org_role(organization_id, auth.uid(), ARRAY['owner']::public.org_role[]));
CREATE POLICY inventory_transfers_owner_select ON public.inventory_transfers FOR SELECT TO authenticated
  USING (public.has_org_role(organization_id, auth.uid(), ARRAY['owner']::public.org_role[]));

-- Ledger rows must come from a quantity mutation. A hand-written row would change no balance
-- and would corrupt invoice-deletion replay, so the direct owner insert path is closed.
-- The deployed app never inserts adjustments directly.
DROP POLICY inventory_adjustments_owner_insert ON public.inventory_adjustments;
REVOKE INSERT ON public.inventory_adjustments FROM anon, authenticated;

-- ---------------------------------------------------------------------------------------
-- Unassigned.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.ensure_inventory_unassigned_location(_organization_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _id uuid;
BEGIN
  SELECT id INTO _id FROM public.inventory_locations
  WHERE organization_id = _organization_id AND kind = 'unassigned';
  IF FOUND THEN RETURN _id; END IF;

  INSERT INTO public.inventory_locations (organization_id, name, description, kind)
  VALUES (_organization_id, 'Unassigned',
    'Stock the organization holds that has not been placed in a physical location yet.', 'unassigned')
  ON CONFLICT (organization_id) WHERE kind = 'unassigned' DO NOTHING
  RETURNING id INTO _id;

  IF _id IS NULL THEN
    SELECT id INTO _id FROM public.inventory_locations
    WHERE organization_id = _organization_id AND kind = 'unassigned';
  END IF;
  RETURN _id;
END;
$$;

CREATE FUNCTION public.tg_seed_inventory_unassigned_location()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.ensure_inventory_unassigned_location(NEW.id);
  RETURN NEW;
END;
$$;
CREATE TRIGGER organizations_seed_inventory_unassigned AFTER INSERT ON public.organizations
  FOR EACH ROW EXECUTE FUNCTION public.tg_seed_inventory_unassigned_location();

-- Unassigned can never be renamed, described, archived, re-kinded or deleted, and no
-- location can become Unassigned after creation. Storage locations archive only when empty.
CREATE FUNCTION public.tg_guard_inventory_location()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.kind = 'unassigned' AND EXISTS (SELECT 1 FROM public.organizations WHERE id = OLD.organization_id) THEN
      RAISE EXCEPTION 'The Unassigned inventory location cannot be deleted' USING ERRCODE = '42501';
    END IF;
    RETURN OLD;
  END IF;

  IF NEW.organization_id IS DISTINCT FROM OLD.organization_id THEN
    RAISE EXCEPTION 'Inventory locations cannot move between organizations' USING ERRCODE = '42501';
  END IF;
  IF NEW.kind IS DISTINCT FROM OLD.kind THEN
    RAISE EXCEPTION 'An inventory location''s kind cannot change' USING ERRCODE = '42501';
  END IF;
  IF OLD.kind = 'unassigned' AND (NEW.name IS DISTINCT FROM OLD.name
      OR NEW.description IS DISTINCT FROM OLD.description OR NEW.active IS DISTINCT FROM OLD.active) THEN
    RAISE EXCEPTION 'The Unassigned inventory location is protected and cannot be changed' USING ERRCODE = '42501';
  END IF;
  IF OLD.active AND NOT NEW.active AND EXISTS (
    SELECT 1 FROM public.inventory_location_balances
    WHERE inventory_location_id = OLD.id AND quantity <> 0
  ) THEN
    RAISE EXCEPTION 'Move all stock out of % before archiving it', OLD.name USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER inventory_locations_guard BEFORE UPDATE OR DELETE ON public.inventory_locations
  FOR EACH ROW EXECUTE FUNCTION public.tg_guard_inventory_location();

CREATE FUNCTION public.tg_guard_inventory_location_insert()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.kind = 'unassigned' AND current_user IN ('anon', 'authenticated', 'service_role') THEN
    RAISE EXCEPTION 'Only the system creates the Unassigned inventory location' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER inventory_locations_guard_insert BEFORE INSERT ON public.inventory_locations
  FOR EACH ROW EXECUTE FUNCTION public.tg_guard_inventory_location_insert();

-- ---------------------------------------------------------------------------------------
-- The quantity boundary. inventory_apply_balance_delta() is the only code that changes a
-- balance or inventory_items.quantity; it sets a transaction-local flag the guard triggers
-- require. Clients cannot set that flag: PostgREST exposes only public-schema functions.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.tg_guard_inventory_item_quantity()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF current_setting('medspend.inventory_sync', true) IS DISTINCT FROM 'on' THEN
    IF TG_OP = 'UPDATE' AND NEW.quantity IS DISTINCT FROM OLD.quantity THEN
      RAISE EXCEPTION 'Inventory quantity can only change through an inventory location mutation'
        USING ERRCODE = '42501';
    END IF;
    IF TG_OP = 'INSERT' AND NEW.quantity <> 0 AND current_user IN ('anon', 'authenticated', 'service_role') THEN
      RAISE EXCEPTION 'New inventory items start at zero; add stock through an inventory location mutation'
        USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER inventory_items_guard_quantity BEFORE INSERT OR UPDATE ON public.inventory_items
  FOR EACH ROW EXECUTE FUNCTION public.tg_guard_inventory_item_quantity();

-- Every inventory item has an Unassigned balance from birth, carrying the inserted quantity
-- (zero for every application path).
CREATE FUNCTION public.tg_seed_inventory_item_balance()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _previous text := current_setting('medspend.inventory_sync', true);
BEGIN
  PERFORM set_config('medspend.inventory_sync', 'on', true);
  INSERT INTO public.inventory_location_balances
    (organization_id, inventory_item_id, inventory_location_id, quantity)
  VALUES (NEW.organization_id, NEW.id, public.ensure_inventory_unassigned_location(NEW.organization_id), NEW.quantity)
  ON CONFLICT (inventory_item_id, inventory_location_id) DO NOTHING;
  PERFORM set_config('medspend.inventory_sync', coalesce(_previous, 'off'), true);
  RETURN NEW;
END;
$$;
CREATE TRIGGER inventory_items_seed_balance AFTER INSERT ON public.inventory_items
  FOR EACH ROW EXECUTE FUNCTION public.tg_seed_inventory_item_balance();

CREATE FUNCTION public.tg_guard_inventory_location_balance()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF current_setting('medspend.inventory_sync', true) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'Inventory location balances can only change through an inventory location mutation'
      USING ERRCODE = '42501';
  END IF;
  IF TG_OP = 'UPDATE' AND (NEW.organization_id IS DISTINCT FROM OLD.organization_id
      OR NEW.inventory_item_id IS DISTINCT FROM OLD.inventory_item_id
      OR NEW.inventory_location_id IS DISTINCT FROM OLD.inventory_location_id) THEN
    RAISE EXCEPTION 'Inventory location balance identity cannot change' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER inventory_location_balances_guard BEFORE INSERT OR UPDATE ON public.inventory_location_balances
  FOR EACH ROW EXECUTE FUNCTION public.tg_guard_inventory_location_balance();

-- Commit-time proof of the invariant for every touched item. A mismatch aborts the whole
-- transaction, whoever wrote it.
CREATE FUNCTION public.tg_check_inventory_balance_invariant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _item_id uuid;
  _quantity numeric;
  _balance numeric;
BEGIN
  IF TG_TABLE_NAME = 'inventory_items' THEN
    _item_id := NEW.id;
  ELSIF TG_OP = 'DELETE' THEN
    _item_id := OLD.inventory_item_id;
  ELSE
    _item_id := NEW.inventory_item_id;
  END IF;
  SELECT quantity INTO _quantity FROM public.inventory_items WHERE id = _item_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT coalesce(sum(quantity), 0) INTO _balance
  FROM public.inventory_location_balances WHERE inventory_item_id = _item_id;
  IF _quantity <> _balance THEN
    RAISE EXCEPTION 'Inventory invariant violated for item %: quantity % but location balances sum to %',
      _item_id, _quantity, _balance USING ERRCODE = '23514';
  END IF;
  RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER inventory_items_balance_invariant
  AFTER INSERT OR UPDATE OF quantity ON public.inventory_items
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
  EXECUTE FUNCTION public.tg_check_inventory_balance_invariant();
CREATE CONSTRAINT TRIGGER inventory_location_balances_invariant
  AFTER INSERT OR UPDATE OR DELETE ON public.inventory_location_balances
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
  EXECUTE FUNCTION public.tg_check_inventory_balance_invariant();

-- New history rows always name a location; a row without one is booked to Unassigned.
CREATE FUNCTION public.tg_default_inventory_adjustment_location()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.inventory_location_id IS NULL THEN
    NEW.inventory_location_id := public.ensure_inventory_unassigned_location(NEW.organization_id);
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER inventory_adjustments_default_location BEFORE INSERT ON public.inventory_adjustments
  FOR EACH ROW EXECUTE FUNCTION public.tg_default_inventory_adjustment_location();

-- Low-level primitive: change one balance and the organization summary by the same delta.
-- Writes no history; callers record the event. Locks the item row first, so every quantity
-- change to one item is serialized on that row.
CREATE FUNCTION public.inventory_apply_balance_delta(
  _organization_id uuid,
  _inventory_item_id uuid,
  _inventory_location_id uuid,
  _delta numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _item public.inventory_items%ROWTYPE;
  _location public.inventory_locations%ROWTYPE;
  _balance public.inventory_location_balances%ROWTYPE;
  _previous_sync text := current_setting('medspend.inventory_sync', true);
BEGIN
  IF _delta IS NULL THEN RAISE EXCEPTION 'An inventory quantity change is required' USING ERRCODE = '22023'; END IF;

  SELECT * INTO _item FROM public.inventory_items
  WHERE id = _inventory_item_id AND organization_id = _organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Inventory item not found' USING ERRCODE = 'P0002'; END IF;

  -- A share lock holds off a concurrent archive until this change commits; archiving then
  -- sees the stock and refuses.
  SELECT * INTO _location FROM public.inventory_locations
  WHERE id = _inventory_location_id AND organization_id = _organization_id
  FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Inventory location not found' USING ERRCODE = 'P0002'; END IF;
  IF _delta > 0 AND NOT _location.active THEN
    RAISE EXCEPTION '% is archived and cannot receive stock', _location.name USING ERRCODE = '55000';
  END IF;

  PERFORM set_config('medspend.inventory_sync', 'on', true);

  INSERT INTO public.inventory_location_balances (organization_id, inventory_item_id, inventory_location_id, quantity)
  VALUES (_organization_id, _inventory_item_id, _inventory_location_id, 0)
  ON CONFLICT (inventory_item_id, inventory_location_id) DO NOTHING;

  SELECT * INTO _balance FROM public.inventory_location_balances
  WHERE inventory_item_id = _inventory_item_id AND inventory_location_id = _inventory_location_id
  FOR UPDATE;

  IF _balance.quantity + _delta < 0 THEN
    RAISE EXCEPTION '% has only % % of %; it cannot go below zero',
      _location.name, trim_scale(_balance.quantity), _item.unit, _item.name USING ERRCODE = '23514';
  END IF;

  UPDATE public.inventory_location_balances
  SET quantity = quantity + _delta, version = version + 1, updated_at = now()
  WHERE inventory_item_id = _inventory_item_id AND inventory_location_id = _inventory_location_id
  RETURNING * INTO _balance;

  UPDATE public.inventory_items SET quantity = quantity + _delta
  WHERE id = _inventory_item_id
  RETURNING * INTO _item;

  PERFORM set_config('medspend.inventory_sync', coalesce(_previous_sync, 'off'), true);

  RETURN jsonb_build_object(
    'inventoryItemId', _item.id,
    'inventoryLocationId', _location.id,
    'itemQuantity', _item.quantity,
    'itemPreviousQuantity', _item.quantity - _delta,
    'locationQuantity', _balance.quantity,
    'locationVersion', _balance.version
  );
END;
$$;

-- Canonical total-changing mutation: balance + summary + one history row, atomically.
-- Authorization belongs to the caller; this function is not executable by clients.
CREATE FUNCTION public.apply_inventory_location_delta(
  _organization_id uuid,
  _inventory_item_id uuid,
  _inventory_location_id uuid,
  _delta numeric,
  _reason text,
  _source_type text,
  _source_invoice_id uuid DEFAULT NULL,
  _source_invoice_item_id uuid DEFAULT NULL,
  _idempotency_key text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _location_id uuid := coalesce(_inventory_location_id, public.ensure_inventory_unassigned_location(_organization_id));
  _result jsonb;
BEGIN
  _result := public.inventory_apply_balance_delta(_organization_id, _inventory_item_id, _location_id, _delta);

  INSERT INTO public.inventory_adjustments
    (organization_id, inventory_item_id, inventory_location_id, adjustment_amount, previous_quantity,
     new_quantity, reason, created_by, source_type, source_invoice_id, source_invoice_item_id, idempotency_key)
  VALUES
    (_organization_id, _inventory_item_id, _location_id, _delta, (_result->>'itemPreviousQuantity')::numeric,
     (_result->>'itemQuantity')::numeric, _reason, auth.uid(), _source_type, _source_invoice_id,
     _source_invoice_item_id, _idempotency_key);

  RETURN _result;
END;
$$;

REVOKE ALL ON FUNCTION public.ensure_inventory_unassigned_location(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.inventory_apply_balance_delta(uuid, uuid, uuid, numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.apply_inventory_location_delta(uuid, uuid, uuid, numeric, text, text, uuid, uuid, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.tg_seed_inventory_unassigned_location() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.tg_guard_inventory_location() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.tg_guard_inventory_location_insert() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.tg_guard_inventory_item_quantity() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.tg_seed_inventory_item_balance() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.tg_guard_inventory_location_balance() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.tg_check_inventory_balance_invariant() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.tg_default_inventory_adjustment_location() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------------------
-- Backfill: one Unassigned per organization, every current quantity into it. No physical
-- history is invented and no adjustment rows are written.
-- ---------------------------------------------------------------------------------------
DO $backfill$
DECLARE
  _organization record;
BEGIN
  FOR _organization IN SELECT id FROM public.organizations ORDER BY id LOOP
    PERFORM public.ensure_inventory_unassigned_location(_organization.id);
  END LOOP;

  PERFORM set_config('medspend.inventory_sync', 'on', true);
  INSERT INTO public.inventory_location_balances
    (organization_id, inventory_item_id, inventory_location_id, quantity)
  SELECT item.organization_id, item.id, location.id, item.quantity
  FROM public.inventory_items item
  JOIN public.inventory_locations location
    ON location.organization_id = item.organization_id AND location.kind = 'unassigned';
  PERFORM set_config('medspend.inventory_sync', 'off', true);
END
$backfill$;

-- ---------------------------------------------------------------------------------------
-- Manual adjustment.
-- ---------------------------------------------------------------------------------------

-- Compatibility boundary for the deployed application: same signature, same owner check,
-- same reasons, same return value (the new organization total). It adjusts Unassigned.
CREATE OR REPLACE FUNCTION public.adjust_inventory_quantity(
  _organization_id uuid,
  _inventory_item_id uuid,
  _adjustment_amount numeric,
  _reason text
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _previous numeric;
  _result jsonb;
BEGIN
  IF NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;
  IF _reason NOT IN ('Invoice received', 'Manual adjustment', 'Damaged', 'Expired', 'Correction') THEN
    RAISE EXCEPTION 'Invalid adjustment reason';
  END IF;
  SELECT quantity INTO _previous FROM public.inventory_items
    WHERE id = _inventory_item_id AND organization_id = _organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Inventory item not found'; END IF;
  IF _previous + _adjustment_amount < 0 THEN RAISE EXCEPTION 'Quantity cannot be negative'; END IF;

  _result := public.apply_inventory_location_delta(
    _organization_id, _inventory_item_id, NULL, _adjustment_amount, _reason, 'manual');
  RETURN (_result->>'itemQuantity')::numeric;
END;
$$;
REVOKE ALL ON FUNCTION public.adjust_inventory_quantity(uuid, uuid, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.adjust_inventory_quantity(uuid, uuid, numeric, text) TO authenticated;

-- Location-aware adjustment for the 7A.1 application. Changes only the chosen location;
-- never borrows from another one.
CREATE FUNCTION public.adjust_inventory_location_quantity(
  _organization_id uuid,
  _inventory_item_id uuid,
  _inventory_location_id uuid,
  _adjustment_amount numeric,
  _reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required' USING ERRCODE = '42501';
  END IF;
  IF _reason IS NULL OR _reason NOT IN ('Manual adjustment', 'Damaged', 'Expired', 'Correction') THEN
    RAISE EXCEPTION 'Invalid adjustment reason' USING ERRCODE = '22023';
  END IF;
  IF _adjustment_amount IS NULL OR _adjustment_amount = 0 THEN
    RAISE EXCEPTION 'Enter a non-zero adjustment' USING ERRCODE = '22023';
  END IF;
  IF _inventory_location_id IS NULL THEN
    RAISE EXCEPTION 'Choose an inventory location' USING ERRCODE = '22023';
  END IF;

  RETURN public.apply_inventory_location_delta(
    _organization_id, _inventory_item_id, _inventory_location_id, _adjustment_amount, _reason, 'manual');
END;
$$;
REVOKE ALL ON FUNCTION public.adjust_inventory_location_quantity(uuid, uuid, uuid, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.adjust_inventory_location_quantity(uuid, uuid, uuid, numeric, text) TO authenticated;

-- ---------------------------------------------------------------------------------------
-- Legacy receiving helper (Phase 2C). The application never calls it. It already required
-- the owner role internally; it now also refuses PUBLIC/anon at the grant level, matches
-- owner-only invoice posting, and receives into Unassigned through the canonical mutation.
-- ---------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.receive_invoice_inventory_item(
  _organization_id uuid,
  _sku text,
  _name text,
  _vendor_name text,
  _quantity numeric,
  _unit text,
  _category text,
  _unit_price numeric
)
RETURNS TABLE (inventory_item_id uuid, created boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _item public.inventory_items%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;
  IF _quantity IS NULL OR _quantity <= 0 THEN RAISE EXCEPTION 'Received quantity must be positive'; END IF;

  SELECT * INTO _item FROM public.inventory_items
  WHERE organization_id = _organization_id AND active = true AND (
    (nullif(btrim(_sku), '') IS NOT NULL AND lower(sku) = lower(btrim(_sku)))
    OR (lower(coalesce(vendor_name, '')) = lower(coalesce(btrim(_vendor_name), '')) AND lower(name) = lower(btrim(_name)))
    OR lower(regexp_replace(name, '[^a-z0-9]+', '', 'g')) = lower(regexp_replace(btrim(_name), '[^a-z0-9]+', '', 'g'))
  )
  ORDER BY
    CASE WHEN nullif(btrim(_sku), '') IS NOT NULL AND lower(sku) = lower(btrim(_sku)) THEN 1
         WHEN lower(coalesce(vendor_name, '')) = lower(coalesce(btrim(_vendor_name), '')) AND lower(name) = lower(btrim(_name)) THEN 2
         ELSE 3 END
  LIMIT 1 FOR UPDATE;

  IF FOUND THEN
    PERFORM public.apply_inventory_location_delta(_organization_id, _item.id, NULL, _quantity, 'Invoice received', NULL);
    RETURN QUERY SELECT _item.id, false;
  ELSE
    INSERT INTO public.inventory_items
      (organization_id, sku, name, vendor_name, quantity, unit, category, last_purchase_price, active)
    VALUES (_organization_id, nullif(btrim(_sku), ''), btrim(_name), nullif(btrim(_vendor_name), ''),
      0, btrim(_unit), nullif(btrim(_category), ''), _unit_price, true)
    RETURNING * INTO _item;
    PERFORM public.apply_inventory_location_delta(_organization_id, _item.id, NULL, _quantity, 'Invoice received', NULL);
    RETURN QUERY SELECT _item.id, true;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.receive_invoice_inventory_item(uuid, text, text, text, numeric, text, text, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.receive_invoice_inventory_item(uuid, text, text, text, numeric, text, text, numeric) TO authenticated;

-- ---------------------------------------------------------------------------------------
-- Stock moves.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.move_inventory_stock(
  _organization_id uuid,
  _inventory_item_id uuid,
  _from_inventory_location_id uuid,
  _to_inventory_location_id uuid,
  _quantity numeric,
  _idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _key text := btrim(coalesce(_idempotency_key, ''));
  _item public.inventory_items%ROWTYPE;
  _existing public.inventory_transfers%ROWTYPE;
  _from public.inventory_locations%ROWTYPE;
  _to public.inventory_locations%ROWTYPE;
  _transfer public.inventory_transfers%ROWTYPE;
  _from_result jsonb;
  _to_result jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required' USING ERRCODE = '42501';
  END IF;
  IF _key = '' OR char_length(_key) > 200 THEN
    RAISE EXCEPTION 'A move request key is required' USING ERRCODE = '22023';
  END IF;
  IF _quantity IS NULL OR _quantity <= 0 THEN
    RAISE EXCEPTION 'Move a quantity greater than zero' USING ERRCODE = '22023';
  END IF;
  IF _from_inventory_location_id IS NULL OR _to_inventory_location_id IS NULL THEN
    RAISE EXCEPTION 'Choose where the stock comes from and where it goes' USING ERRCODE = '22023';
  END IF;
  IF _from_inventory_location_id = _to_inventory_location_id THEN
    RAISE EXCEPTION 'Choose two different locations' USING ERRCODE = '22023';
  END IF;

  -- The item row serializes every quantity change to this item, including retries of
  -- this same request.
  SELECT * INTO _item FROM public.inventory_items
  WHERE id = _inventory_item_id AND organization_id = _organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Inventory item not found' USING ERRCODE = 'P0002'; END IF;

  SELECT * INTO _existing FROM public.inventory_transfers
  WHERE organization_id = _organization_id AND idempotency_key = _key;
  IF FOUND THEN
    IF _existing.inventory_item_id = _inventory_item_id
       AND _existing.from_inventory_location_id = _from_inventory_location_id
       AND _existing.to_inventory_location_id = _to_inventory_location_id
       AND _existing.quantity = _quantity THEN
      RETURN jsonb_build_object('transferId', _existing.id, 'replayed', true,
        'itemQuantity', _item.quantity,
        'fromQuantity', (SELECT quantity FROM public.inventory_location_balances
          WHERE inventory_item_id = _inventory_item_id AND inventory_location_id = _from_inventory_location_id),
        'toQuantity', (SELECT quantity FROM public.inventory_location_balances
          WHERE inventory_item_id = _inventory_item_id AND inventory_location_id = _to_inventory_location_id));
    END IF;
    RAISE EXCEPTION 'This move request key was already used for a different move' USING ERRCODE = '23505';
  END IF;

  -- Lock order everywhere: item, then locations (share), then balances in location-id order.
  PERFORM 1 FROM public.inventory_locations
  WHERE id IN (_from_inventory_location_id, _to_inventory_location_id) AND organization_id = _organization_id
  ORDER BY id FOR SHARE;
  SELECT * INTO _from FROM public.inventory_locations
  WHERE id = _from_inventory_location_id AND organization_id = _organization_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Source location not found' USING ERRCODE = 'P0002'; END IF;
  SELECT * INTO _to FROM public.inventory_locations
  WHERE id = _to_inventory_location_id AND organization_id = _organization_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Destination location not found' USING ERRCODE = 'P0002'; END IF;
  IF NOT _to.active THEN
    RAISE EXCEPTION '% is archived and cannot receive stock', _to.name USING ERRCODE = '55000';
  END IF;

  -- Lock both balances in location-id order before changing either.
  PERFORM set_config('medspend.inventory_sync', 'on', true);
  INSERT INTO public.inventory_location_balances (organization_id, inventory_item_id, inventory_location_id, quantity)
  VALUES (_organization_id, _inventory_item_id, _to.id, 0)
  ON CONFLICT (inventory_item_id, inventory_location_id) DO NOTHING;
  PERFORM set_config('medspend.inventory_sync', 'off', true);
  PERFORM 1 FROM public.inventory_location_balances
  WHERE inventory_item_id = _inventory_item_id AND inventory_location_id IN (_from.id, _to.id)
  ORDER BY inventory_location_id FOR UPDATE;

  _from_result := public.inventory_apply_balance_delta(_organization_id, _inventory_item_id, _from.id, -_quantity);
  _to_result := public.inventory_apply_balance_delta(_organization_id, _inventory_item_id, _to.id, _quantity);

  INSERT INTO public.inventory_transfers
    (organization_id, inventory_item_id, from_inventory_location_id, to_inventory_location_id,
     quantity, idempotency_key, created_by)
  VALUES (_organization_id, _inventory_item_id, _from.id, _to.id, _quantity, _key, auth.uid())
  RETURNING * INTO _transfer;

  RETURN jsonb_build_object('transferId', _transfer.id, 'replayed', false,
    'itemQuantity', (_to_result->>'itemQuantity')::numeric,
    'fromQuantity', (_from_result->>'locationQuantity')::numeric,
    'toQuantity', (_to_result->>'locationQuantity')::numeric);
END;
$$;
REVOKE ALL ON FUNCTION public.move_inventory_stock(uuid, uuid, uuid, uuid, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.move_inventory_stock(uuid, uuid, uuid, uuid, numeric, text) TO authenticated;

-- ---------------------------------------------------------------------------------------
-- Minimal owner location administration.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.create_inventory_location(
  _organization_id uuid,
  _name text,
  _description text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(_name), '') IS NULL OR char_length(btrim(_name)) > 120 THEN
    RAISE EXCEPTION 'Enter a location name of up to 120 characters' USING ERRCODE = '22023';
  END IF;
  PERFORM public.ensure_inventory_unassigned_location(_organization_id);
  BEGIN
    INSERT INTO public.inventory_locations (organization_id, name, description, kind)
    VALUES (_organization_id, btrim(_name), nullif(btrim(_description), ''), 'storage')
    RETURNING id INTO _id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'An inventory location with that name already exists' USING ERRCODE = '23505';
  END;
  RETURN _id;
END;
$$;
REVOKE ALL ON FUNCTION public.create_inventory_location(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_inventory_location(uuid, text, text) TO authenticated;

CREATE FUNCTION public.update_inventory_location(
  _organization_id uuid,
  _inventory_location_id uuid,
  _name text,
  _description text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(_name), '') IS NULL OR char_length(btrim(_name)) > 120 THEN
    RAISE EXCEPTION 'Enter a location name of up to 120 characters' USING ERRCODE = '22023';
  END IF;
  BEGIN
    UPDATE public.inventory_locations
    SET name = btrim(_name), description = nullif(btrim(_description), '')
    WHERE id = _inventory_location_id AND organization_id = _organization_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'An inventory location with that name already exists' USING ERRCODE = '23505';
  END;
  IF NOT FOUND THEN RAISE EXCEPTION 'Inventory location not found' USING ERRCODE = 'P0002'; END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.update_inventory_location(uuid, uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_inventory_location(uuid, uuid, text, text) TO authenticated;

CREATE FUNCTION public.set_inventory_location_active(
  _organization_id uuid,
  _inventory_location_id uuid,
  _active boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _location public.inventory_locations%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required' USING ERRCODE = '42501';
  END IF;
  IF _active IS NULL THEN RAISE EXCEPTION 'Choose archive or restore' USING ERRCODE = '22023'; END IF;
  SELECT * INTO _location FROM public.inventory_locations
  WHERE id = _inventory_location_id AND organization_id = _organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Inventory location not found' USING ERRCODE = 'P0002'; END IF;
  IF _location.kind = 'unassigned' THEN
    RAISE EXCEPTION 'The Unassigned inventory location is protected and cannot be archived' USING ERRCODE = '42501';
  END IF;
  -- Lock the location's balances so no move can land between the emptiness check and archive.
  PERFORM 1 FROM public.inventory_location_balances
  WHERE inventory_location_id = _location.id ORDER BY inventory_item_id FOR UPDATE;
  UPDATE public.inventory_locations SET active = _active WHERE id = _location.id;
END;
$$;
REVOKE ALL ON FUNCTION public.set_inventory_location_active(uuid, uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_inventory_location_active(uuid, uuid, boolean) TO authenticated;

-- ---------------------------------------------------------------------------------------
-- post_reviewed_invoice: the current body (20261012120000_beta_invoice_manual_catalog_matching)
-- with only its quantity write and receipt row replaced by the canonical mutation.
-- ---------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.post_reviewed_invoice(_organization_id uuid, _source_file_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public
AS $function$
DECLARE
  _invoice public.invoices%ROWTYPE;
  _line public.invoice_items%ROWTYPE;
  _vendor_id uuid;
  _vendor_name text;
  _product_id uuid;
  _vendor_product_id uuid;
  _mapping public.vendor_products%ROWTYPE;
  _inventory public.inventory_items%ROWTYPE;
  _inventory_sku text;
  _candidate_sku text;
  _created integer := 0;
  _updated integer := 0;
  _line_count integer;
  _unresolved integer;
BEGIN
  IF NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;

  SELECT * INTO _invoice
  FROM public.invoices
  WHERE organization_id = _organization_id AND source_file_id = _source_file_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice review not found'; END IF;
  IF _invoice.posted_at IS NOT NULL OR _invoice.processing_status = 'completed' THEN
    RETURN jsonb_build_object('invoiceId', _invoice.id, 'createdInventoryItems', 0,
      'updatedInventoryItems', 0, 'alreadyCompleted', true);
  END IF;

  -- Identity gate, before any write. Lock every line first so a concurrent direct API
  -- edit cannot unlink a line between this check and the posting loop.
  PERFORM 1 FROM public.invoice_items
  WHERE invoice_id = _invoice.id AND organization_id = _organization_id
  FOR UPDATE;
  SELECT count(*) INTO _unresolved FROM public.invoice_items
  WHERE invoice_id = _invoice.id AND organization_id = _organization_id AND product_id IS NULL;
  IF _unresolved > 0 THEN
    RAISE EXCEPTION 'Match or create a product for every invoice line before approval (% unresolved)', _unresolved
      USING ERRCODE = '23502';
  END IF;

  _vendor_id := _invoice.vendor_id;
  _vendor_name := nullif(btrim(_invoice.vendor_name), '');
  IF _vendor_id IS NOT NULL THEN
    SELECT name INTO _vendor_name FROM public.vendors
      WHERE id = _vendor_id AND organization_id = _organization_id AND active = true;
    IF NOT FOUND THEN RAISE EXCEPTION 'Selected vendor is unavailable'; END IF;
  ELSIF _vendor_name IS NOT NULL THEN
    SELECT id INTO _vendor_id FROM public.vendors
      WHERE organization_id = _organization_id
        AND normalized_name = public.normalize_catalog_text(_vendor_name) AND active = true
      LIMIT 1;
    IF _vendor_id IS NULL THEN
      INSERT INTO public.vendors (organization_id, name, normalized_name)
      VALUES (_organization_id, _vendor_name, public.normalize_catalog_text(_vendor_name))
      RETURNING id INTO _vendor_id;
    END IF;
  ELSE
    RAISE EXCEPTION 'Vendor is required before approval';
  END IF;

  SELECT count(*) INTO _line_count FROM public.invoice_items
    WHERE invoice_id = _invoice.id AND organization_id = _organization_id;
  IF _line_count = 0 THEN RAISE EXCEPTION 'Add at least one line item before approval'; END IF;

  FOR _line IN
    SELECT * FROM public.invoice_items
    WHERE invoice_id = _invoice.id AND organization_id = _organization_id
    ORDER BY line_number NULLS LAST, created_at
    FOR UPDATE
  LOOP
    _product_id := _line.product_id;
    _vendor_product_id := _line.vendor_product_id;
    IF _product_id IS NULL THEN
      RAISE EXCEPTION 'Match or create a product for every invoice line before approval' USING ERRCODE = '23502';
    END IF;

    -- A reviewed mapping must belong to this organization and invoice vendor, be active,
    -- and name the same product as the line. It never replaces the line's product.
    IF _vendor_product_id IS NOT NULL THEN
      SELECT * INTO _mapping FROM public.vendor_products
        WHERE id = _vendor_product_id AND organization_id = _organization_id
          AND vendor_id = _vendor_id AND active = true;
      IF NOT FOUND THEN RAISE EXCEPTION 'A selected vendor product is unavailable'; END IF;
      IF _mapping.product_id IS DISTINCT FROM _product_id THEN
        RAISE EXCEPTION 'A selected vendor product maps to a different product than the invoice line';
      END IF;

      UPDATE public.vendor_products SET
        product_id = _product_id,
        package_size = coalesce(nullif(btrim(_line.package_size), ''), package_size),
        unit_of_measure = coalesce(nullif(btrim(_line.unit_of_measure), ''), unit_of_measure),
        active = true
      WHERE id = _vendor_product_id AND organization_id = _organization_id AND vendor_id = _vendor_id;
    END IF;

    SELECT * INTO _inventory FROM public.inventory_items
    WHERE organization_id = _organization_id AND product_id = _product_id
    LIMIT 1 FOR UPDATE;

    -- The SKU on an inventory item is a label; one item per vendor may carry a given SKU.
    -- This product's item takes the line's SKU, or keeps its own, whichever no other
    -- product's item already carries for this vendor. Otherwise it carries none. The other
    -- item is never touched, and the receipt is recorded against this line's product.
    _inventory_sku := NULL;
    FOREACH _candidate_sku IN ARRAY ARRAY[nullif(btrim(_line.sku), ''), _inventory.sku] LOOP
      IF _candidate_sku IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.inventory_items other
        WHERE other.organization_id = _organization_id
          AND lower(other.vendor_name) = lower(_vendor_name)
          AND lower(other.sku) = lower(_candidate_sku)
          AND other.id IS DISTINCT FROM _inventory.id
      ) THEN
        _inventory_sku := _candidate_sku;
        EXIT;
      END IF;
    END LOOP;

    IF _inventory.id IS NULL THEN
      INSERT INTO public.inventory_items
        (organization_id, product_id, sku, name, description, category, manufacturer,
         unit, quantity, vendor_name, last_purchase_price, last_purchase_date, active)
      VALUES
        (_organization_id, _product_id, _inventory_sku, btrim(_line.description),
         btrim(_line.description), nullif(btrim(_line.category), ''),
         nullif(btrim(_line.manufacturer), ''), coalesce(nullif(btrim(_line.unit_of_measure), ''), 'each'),
         0, _vendor_name, _line.unit_price, coalesce(_invoice.invoice_date, current_date), true)
      RETURNING * INTO _inventory;
      _created := _created + 1;
    ELSE
      _updated := _updated + 1;
    END IF;

    UPDATE public.inventory_items SET
      sku = _inventory_sku,
      category = coalesce(nullif(btrim(_line.category), ''), category),
      manufacturer = coalesce(nullif(btrim(_line.manufacturer), ''), manufacturer),
      vendor_name = _vendor_name,
      last_purchase_price = coalesce(_line.unit_price, last_purchase_price),
      last_purchase_date = coalesce(_invoice.invoice_date, current_date),
      active = true
    WHERE id = _inventory.id;

    -- Phase 7A.1: every receipt lands in Unassigned through the canonical mutation, which
    -- writes the same 'Invoice received' row with the same provenance and idempotency key.
    PERFORM public.apply_inventory_location_delta(
      _organization_id, _inventory.id, NULL, _line.quantity, 'Invoice received', 'invoice',
      _invoice.id, _line.id, 'invoice-item:' || _line.id::text);

    INSERT INTO public.inventory_price_history
      (organization_id, product_id, vendor_id, vendor_product_id, invoice_id, invoice_item_id,
       purchase_date, quantity, package_size, unit_of_measure, unit_price, extended_price)
    VALUES
      (_organization_id, _product_id, _vendor_id, _vendor_product_id, _invoice.id, _line.id,
       coalesce(_invoice.invoice_date, current_date), _line.quantity, nullif(btrim(_line.package_size), ''),
       nullif(btrim(_line.unit_of_measure), ''), _line.unit_price, _line.total_price);

    UPDATE public.invoice_items SET product_id = _product_id,
      vendor_product_id = _vendor_product_id, review_status = 'approved'
    WHERE id = _line.id;
  END LOOP;

  UPDATE public.invoices SET vendor_id = _vendor_id, vendor_name = _vendor_name,
    invoice_total = coalesce(invoice_total, total_amount, total),
    total_amount = coalesce(total_amount, invoice_total, total),
    total = coalesce(total, total_amount, invoice_total),
    processing_status = 'completed', reviewed_by = auth.uid(), reviewed_at = now(), posted_at = now()
  WHERE id = _invoice.id;

  UPDATE public.invoice_processing_jobs SET status = 'completed'
  WHERE invoice_id = _source_file_id AND organization_id = _organization_id;

  RETURN jsonb_build_object('invoiceId', _invoice.id, 'createdInventoryItems', _created,
    'updatedInventoryItems', _updated, 'alreadyCompleted', false);
END;
$function$;
REVOKE ALL ON FUNCTION public.post_reviewed_invoice(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_reviewed_invoice(uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------------------------
-- delete_invoice_permanently: the current body (20260817120000_phase3a6_safe_invoice_deletion)
-- plus the physical-count checkpoint guard, the Unassigned sufficiency check, and the
-- summary write replaced by the canonical balance primitive. Surviving adjustment
-- snapshots stay organization-total based.
-- ---------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_invoice_permanently(_organization_id uuid, _source_file_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public
AS $function$
DECLARE
  _source public.vendor_invoices%ROWTYPE;
  _invoice public.invoices%ROWTYPE;
  _invoice_found boolean;
  _job_status text;
  _inventory public.inventory_items%ROWTYPE;
  _adjustment public.inventory_adjustments%ROWTYPE;
  _latest_price numeric;
  _latest_date date;
  _latest_vendor_name text;
  _receipt_quantity numeric;
  _remaining_adjustments numeric;
  _reconstructed_quantity numeric;
  _running_quantity numeric;
  _unassigned_location_id uuid;
  _unassigned_quantity numeric;
  _price_records integer := 0;
  _adjustment_records integer := 0;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_org_role(
    _organization_id, auth.uid(), ARRAY['owner']::public.org_role[]
  ) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;

  -- The source row serializes two deletion attempts for the same upload.
  SELECT * INTO _source
  FROM public.vendor_invoices
  WHERE id = _source_file_id AND organization_id = _organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Document not found'; END IF;

  IF _source.storage_path IS NULL
    OR split_part(_source.storage_path, '/', 1) <> _organization_id::text THEN
    RAISE EXCEPTION 'Document source file ownership could not be verified';
  END IF;

  -- Posting locks the invoice before its inventory records. Preserve that order here.
  SELECT * INTO _invoice
  FROM public.invoices
  WHERE source_file_id = _source_file_id AND organization_id = _organization_id
  FOR UPDATE;
  _invoice_found := FOUND;

  SELECT status INTO _job_status
  FROM public.invoice_processing_jobs
  WHERE invoice_id = _source_file_id AND organization_id = _organization_id;

  IF _job_status = 'processing' OR EXISTS (
    SELECT 1 FROM public.invoice_extraction_runs
    WHERE vendor_invoice_id = _source_file_id
      AND organization_id = _organization_id
      AND status IN ('queued', 'processing')
  ) THEN
    RAISE EXCEPTION 'This document is currently being processed. Try again when processing is complete.';
  END IF;

  IF _invoice_found THEN
    -- Prevent review/posting changes and establish a stable set of line identities.
    PERFORM 1 FROM public.invoice_items
    WHERE invoice_id = _invoice.id AND organization_id = _organization_id
    ORDER BY id FOR UPDATE;

    -- Completed invoices must have the exact provenance written by post_reviewed_invoice.
    -- Historical or externally-mutated rows without complete provenance cannot be reversed safely.
    IF (_invoice.posted_at IS NOT NULL OR _invoice.processing_status = 'completed') AND (
      NOT EXISTS (
        SELECT 1 FROM public.invoice_items item
        WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id
      ) OR EXISTS (
        SELECT 1 FROM public.invoice_items item
        WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id
          AND (
            (SELECT count(*) FROM public.inventory_adjustments adjustment
             WHERE adjustment.organization_id = _organization_id
               AND adjustment.source_invoice_id = _invoice.id
               AND adjustment.source_invoice_item_id = item.id
               AND adjustment.source_type = 'invoice'
               AND adjustment.adjustment_amount = item.quantity) <> 1
            OR
            (SELECT count(*) FROM public.inventory_price_history history
             WHERE history.organization_id = _organization_id
               AND history.invoice_id = _invoice.id
               AND history.invoice_item_id = item.id) <> 1
          )
      )
    ) THEN
      RAISE EXCEPTION 'This posted invoice cannot be deleted safely because its inventory provenance is incomplete. No changes were made.';
    END IF;

    -- Lock every affected stock record deterministically before calculating any reversal.
    PERFORM 1 FROM public.inventory_items inventory
    WHERE inventory.organization_id = _organization_id
      AND EXISTS (
        SELECT 1 FROM public.inventory_adjustments adjustment
        WHERE adjustment.organization_id = _organization_id
          AND adjustment.inventory_item_id = inventory.id
          AND (
            adjustment.source_invoice_id = _invoice.id
            OR adjustment.source_invoice_item_id IN (
              SELECT item.id FROM public.invoice_items item
              WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id
            )
          )
      )
    ORDER BY inventory.id FOR UPDATE;

    FOR _inventory IN
      SELECT inventory.* FROM public.inventory_items inventory
      WHERE inventory.organization_id = _organization_id
        AND EXISTS (
          SELECT 1 FROM public.inventory_adjustments adjustment
          WHERE adjustment.organization_id = _organization_id
            AND adjustment.inventory_item_id = inventory.id
            AND (
              adjustment.source_invoice_id = _invoice.id
              OR adjustment.source_invoice_item_id IN (
                SELECT item.id FROM public.invoice_items item
                WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id
              )
            )
        )
      ORDER BY inventory.id
    LOOP
      SELECT coalesce(sum(adjustment.adjustment_amount), 0)
      INTO _receipt_quantity
      FROM public.inventory_adjustments adjustment
      WHERE adjustment.organization_id = _organization_id
        AND adjustment.inventory_item_id = _inventory.id
        AND (
          adjustment.source_invoice_id = _invoice.id
          OR adjustment.source_invoice_item_id IN (
            SELECT item.id FROM public.invoice_items item
            WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id
          )
        );

      _reconstructed_quantity := _inventory.quantity - _receipt_quantity;
      IF _receipt_quantity < 0 OR _reconstructed_quantity < 0 THEN
        RAISE EXCEPTION 'This invoice cannot be deleted safely because removing its inventory receipts would make % inventory negative. Correct the affected inventory first, then try again.', _inventory.name;
      END IF;

      -- Phase 7A.1: a physical count is an absolute checkpoint. Replaying relative history
      -- across one would corrupt stock, so a receipt counted over cannot be deleted.
      IF EXISTS (
        SELECT 1 FROM public.inventory_adjustments counted
        WHERE counted.organization_id = _organization_id
          AND counted.inventory_item_id = _inventory.id
          AND counted.source_type = 'physical_count'
          AND counted.created_at >= (
            SELECT min(receipt.created_at) FROM public.inventory_adjustments receipt
            WHERE receipt.organization_id = _organization_id
              AND receipt.inventory_item_id = _inventory.id
              AND (
                receipt.source_invoice_id = _invoice.id
                OR receipt.source_invoice_item_id IN (
                  SELECT item.id FROM public.invoice_items item
                  WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id
                )
              )
          )
      ) THEN
        RAISE EXCEPTION 'This invoice cannot be deleted because % was physically counted after it was received. Correct the inventory with an adjustment instead.', _inventory.name
          USING ERRCODE = '55000';
      END IF;

      -- Phase 7A.1: receipts always land in Unassigned, so the reversal comes only from
      -- Unassigned. Stock already moved to a physical location is never pulled back silently.
      _unassigned_location_id := public.ensure_inventory_unassigned_location(_organization_id);
      SELECT balance.quantity INTO _unassigned_quantity
      FROM public.inventory_location_balances balance
      WHERE balance.inventory_item_id = _inventory.id
        AND balance.inventory_location_id = _unassigned_location_id
      FOR UPDATE;
      _unassigned_quantity := coalesce(_unassigned_quantity, 0);
      IF _unassigned_quantity < _receipt_quantity THEN
        RAISE EXCEPTION 'Move % % of % back to Unassigned before deleting this invoice.',
          trim_scale(_receipt_quantity - _unassigned_quantity), _inventory.unit, _inventory.name
          USING ERRCODE = '55000';
      END IF;

      -- Rebuild balance snapshots for all surviving adjustments. The baseline captures stock
      -- that predates the adjustment ledger; adjustment amounts and ordering never change.
      SELECT coalesce(sum(adjustment.adjustment_amount), 0)
      INTO _remaining_adjustments
      FROM public.inventory_adjustments adjustment
      WHERE adjustment.organization_id = _organization_id
        AND adjustment.inventory_item_id = _inventory.id
        AND NOT (
          coalesce(adjustment.source_invoice_id = _invoice.id, false)
          OR coalesce(adjustment.source_invoice_item_id IN (
            SELECT item.id FROM public.invoice_items item
            WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id
          ), false)
        );

      _running_quantity := _reconstructed_quantity - _remaining_adjustments;
      IF _running_quantity < 0 THEN
        RAISE EXCEPTION 'This invoice cannot be deleted safely because the remaining inventory history for % would begin below zero. Correct the affected inventory first, then try again.', _inventory.name;
      END IF;

      FOR _adjustment IN
        SELECT adjustment.* FROM public.inventory_adjustments adjustment
        WHERE adjustment.organization_id = _organization_id
          AND adjustment.inventory_item_id = _inventory.id
          AND NOT (
            coalesce(adjustment.source_invoice_id = _invoice.id, false)
            OR coalesce(adjustment.source_invoice_item_id IN (
              SELECT item.id FROM public.invoice_items item
              WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id
            ), false)
          )
        ORDER BY adjustment.created_at, adjustment.id
        FOR UPDATE
      LOOP
        IF _running_quantity + _adjustment.adjustment_amount < 0 THEN
          RAISE EXCEPTION 'This invoice cannot be deleted safely because the remaining inventory history for % would become negative. Correct the affected inventory first, then try again.', _inventory.name;
        END IF;
        UPDATE public.inventory_adjustments SET
          previous_quantity = _running_quantity,
          new_quantity = _running_quantity + _adjustment.adjustment_amount
        WHERE id = _adjustment.id AND organization_id = _organization_id;
        _running_quantity := _running_quantity + _adjustment.adjustment_amount;
      END LOOP;

      IF _running_quantity <> _reconstructed_quantity THEN
        RAISE EXCEPTION 'Invoice deletion could not reconstruct inventory history safely. No changes were made.';
      END IF;

      -- Remove the receipt from Unassigned and the organization total together. Deletion
      -- removes the receipt rows below rather than writing a reversing row.
      PERFORM public.inventory_apply_balance_delta(
        _organization_id, _inventory.id, _unassigned_location_id, -_receipt_quantity);
      IF (SELECT quantity FROM public.inventory_items WHERE id = _inventory.id) <> _reconstructed_quantity THEN
        RAISE EXCEPTION 'Invoice deletion could not reconstruct inventory history safely. No changes were made.';
      END IF;
    END LOOP;

    SELECT count(*) INTO _adjustment_records
    FROM public.inventory_adjustments adjustment
    WHERE adjustment.organization_id = _organization_id
      AND (adjustment.source_invoice_id = _invoice.id OR adjustment.source_invoice_item_id IN (
        SELECT item.id FROM public.invoice_items item
        WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id
      ));

    SELECT count(*) INTO _price_records
    FROM public.inventory_price_history history
    WHERE history.organization_id = _organization_id
      AND (history.invoice_id = _invoice.id OR history.invoice_item_id IN (
        SELECT item.id FROM public.invoice_items item
        WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id
      ));

    -- Provenance rows must be explicitly removed before their non-cascading invoice FKs.
    DELETE FROM public.inventory_adjustments adjustment
    WHERE adjustment.organization_id = _organization_id
      AND (adjustment.source_invoice_id = _invoice.id OR adjustment.source_invoice_item_id IN (
        SELECT item.id FROM public.invoice_items item
        WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id
      ));

    DELETE FROM public.inventory_price_history history
    WHERE history.organization_id = _organization_id
      AND (history.invoice_id = _invoice.id OR history.invoice_item_id IN (
        SELECT item.id FROM public.invoice_items item
        WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id
      ));

    -- Rebuild denormalized purchase fields only for stock touched by the deleted invoice.
    FOR _inventory IN
      SELECT inventory.* FROM public.inventory_items inventory
      WHERE inventory.organization_id = _organization_id
        AND inventory.product_id IN (
          SELECT DISTINCT item.product_id FROM public.invoice_items item
          WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id
            AND item.product_id IS NOT NULL
        )
      ORDER BY inventory.id FOR UPDATE
    LOOP
      SELECT history.unit_price, history.purchase_date, vendor.name
      INTO _latest_price, _latest_date, _latest_vendor_name
      FROM public.inventory_price_history history
      JOIN public.vendors vendor
        ON vendor.id = history.vendor_id AND vendor.organization_id = history.organization_id
      WHERE history.organization_id = _organization_id
        AND history.product_id = _inventory.product_id
      ORDER BY history.purchase_date DESC, history.created_at DESC, history.id DESC
      LIMIT 1;

      UPDATE public.inventory_items SET
        last_purchase_price = _latest_price,
        last_purchase_date = _latest_date,
        vendor_name = _latest_vendor_name
      WHERE id = _inventory.id AND organization_id = _organization_id;
    END LOOP;

    -- Canonical products, vendors, mappings, signatures, and inventory items are preserved.
    -- invoice_items and legacy invoice_line_items cascade from this invoice-owned row.
    DELETE FROM public.invoices
    WHERE id = _invoice.id AND organization_id = _organization_id;
  END IF;

  -- Processing jobs, extraction runs, and candidates cascade from the source upload.
  DELETE FROM public.vendor_invoices
  WHERE id = _source_file_id AND organization_id = _organization_id;

  RETURN jsonb_build_object(
    'sourceFileId', _source.id,
    'storagePath', _source.storage_path,
    'filename', _source.original_filename,
    'documentType', CASE WHEN _invoice_found THEN _invoice.document_type ELSE 'UNKNOWN' END,
    'posted', CASE WHEN _invoice_found THEN (_invoice.posted_at IS NOT NULL OR _invoice.processing_status = 'completed') ELSE false END,
    'removedAdjustmentCount', _adjustment_records,
    'removedPriceHistoryCount', _price_records
  );
END;
$function$;
REVOKE ALL ON FUNCTION public.delete_invoice_permanently(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_invoice_permanently(uuid, uuid) TO authenticated;

COMMENT ON TABLE public.inventory_locations IS
  'Physical inventory storage locations (cabinets, carts, rooms). Separate from public.locations, which are organization sites and request destinations. Exactly one protected kind=unassigned row per organization.';
COMMENT ON TABLE public.inventory_location_balances IS
  'Canonical per-location inventory quantities. inventory_items.quantity is kept equal to their sum by inventory_apply_balance_delta and verified at commit.';
COMMENT ON TABLE public.inventory_transfers IS
  'Stock moves between inventory locations. Moves never change an organization total.';
COMMENT ON COLUMN public.inventory_adjustments.inventory_location_id IS
  'Location whose balance this total-changing event changed. NULL only for organization-level history written before Phase 7A.1.';
COMMENT ON FUNCTION public.apply_inventory_location_delta(uuid, uuid, uuid, numeric, text, text, uuid, uuid, text) IS
  'Canonical total-changing inventory mutation: one location balance, the organization summary and one history row. Not client-executable; callers authorize.';
COMMENT ON FUNCTION public.inventory_apply_balance_delta(uuid, uuid, uuid, numeric) IS
  'Lowest-level quantity primitive. The only code allowed to change inventory_location_balances or inventory_items.quantity. Writes no history.';
COMMENT ON FUNCTION public.adjust_inventory_quantity(uuid, uuid, numeric, text) IS
  'Compatibility adjustment for the pre-7A.1 application. Owner only; adjusts the Unassigned location.';
COMMENT ON FUNCTION public.adjust_inventory_location_quantity(uuid, uuid, uuid, numeric, text) IS
  'Owner-only manual adjustment of one inventory location. Never borrows from another location.';
COMMENT ON FUNCTION public.move_inventory_stock(uuid, uuid, uuid, uuid, numeric, text) IS
  'Owner-only idempotent stock move between two inventory locations of one organization.';

-- ---------------------------------------------------------------------------------------
-- In-migration postcheck. Any failure rolls the whole migration back.
-- ---------------------------------------------------------------------------------------
SET CONSTRAINTS public.inventory_items_balance_invariant, public.inventory_location_balances_invariant IMMEDIATE;

DO $postcheck$
DECLARE
  _bad bigint;
BEGIN
  IF (SELECT count(*) FROM public.inventory_items) <> (SELECT items FROM phase7a1_pre_counts)
     OR (SELECT count(*) FROM public.inventory_adjustments) <> (SELECT adjustments FROM phase7a1_pre_counts) THEN
    RAISE EXCEPTION 'Phase 7A.1 postcheck: inventory item or adjustment count changed';
  END IF;

  SELECT count(*) INTO _bad
  FROM phase7a1_pre_quantities pre
  LEFT JOIN public.inventory_items item ON item.id = pre.id
  WHERE item.id IS NULL OR item.quantity <> pre.quantity OR item.organization_id <> pre.organization_id;
  IF _bad <> 0 THEN RAISE EXCEPTION 'Phase 7A.1 postcheck: % inventory items changed quantity', _bad; END IF;

  SELECT count(*) INTO _bad
  FROM public.inventory_items item
  WHERE item.quantity <> coalesce((
    SELECT sum(balance.quantity) FROM public.inventory_location_balances balance
    WHERE balance.inventory_item_id = item.id), -1);
  IF _bad <> 0 THEN RAISE EXCEPTION 'Phase 7A.1 postcheck: % items do not equal their location balances', _bad; END IF;

  SELECT count(*) INTO _bad
  FROM public.inventory_location_balances balance
  JOIN public.inventory_locations location ON location.id = balance.inventory_location_id
  WHERE location.kind <> 'unassigned';
  IF _bad <> 0 THEN RAISE EXCEPTION 'Phase 7A.1 postcheck: backfill placed stock outside Unassigned'; END IF;

  SELECT count(*) INTO _bad
  FROM public.organizations organization
  WHERE (SELECT count(*) FROM public.inventory_locations location
         WHERE location.organization_id = organization.id AND location.kind = 'unassigned') <> 1;
  IF _bad <> 0 THEN RAISE EXCEPTION 'Phase 7A.1 postcheck: % organizations lack exactly one Unassigned', _bad; END IF;

  IF EXISTS (SELECT 1 FROM public.inventory_adjustments WHERE inventory_location_id IS NOT NULL)
     OR EXISTS (SELECT 1 FROM public.inventory_transfers) THEN
    RAISE EXCEPTION 'Phase 7A.1 postcheck: the migration must not write inventory history';
  END IF;
END
$postcheck$;

SET CONSTRAINTS public.inventory_items_balance_invariant, public.inventory_location_balances_invariant DEFERRED;

COMMIT;
