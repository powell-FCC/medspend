-- Phase 7D: Replenishment V1 (location-level Minimum / Target, computed live).
--
--   * inventory_replenishment_rules: at most one rule per inventory item x storage location, with
--     minimum_quantity (>= 0) and target_quantity (> 0, >= minimum). Rules are never deleted by
--     the application: they are disabled, and a rule whose item or location is archived is
--     operationally inactive. Unassigned can never have a rule (guard trigger). RLS on, no
--     policies, service_role SELECT only; every client read and write goes through the functions
--     below.
--   * inventory_transfers.source: 'manual' (default, every existing row and every old caller) or
--     'replenishment' (a move the owner confirmed from a replenishment recommendation). Nothing
--     else about transfers changes.
--   * move_inventory_stock gains a trailing _source text DEFAULT 'manual'. Same authorization,
--     idempotency, validation, locking and balance semantics; an idempotent replay keeps the
--     first stored source.
--   * set_inventory_replenishment_rule / set_inventory_replenishment_rule_enabled: owner only.
--   * inventory_replenishment_rows(org): internal (no client EXECUTE), the ONE place the
--     replenishment calculation lives.
--   * list_inventory_replenishment / get_inventory_replenishment_summary /
--     list_inventory_location_replenishment_rules: owner + admin reads.
--
-- The calculation, for each enabled rule whose item is active and whose location is an active
-- storage location:
--   current        balance at (item, rule location); 0 and not_stocked_here when no row exists
--   below minimum  current <= minimum
--   shortage       target - current when below minimum, else 0
--   spare          Unassigned: its whole balance. Another active storage location:
--                  max(0, balance - that location's enabled minimum), minimum 0 without a rule.
--                  The rule's own location never donates to itself.
--   available      sum of spare over every other active location
--   move           min(shortage, available);  external = shortage - move
--   category       ok (not below minimum) | move_available (move = shortage) |
--                  partly_covered (0 < move < shortage) | needs_purchasing (move = 0)
-- Disabled rules and rules whose item or location is archived are 'inactive'. Donors are ordered
-- Unassigned first, then the greatest spare, then name and id. Count freshness, the
-- organization-level open-request note (approved/ordered request lines carrying this
-- inventory_item_id) and the other-short-location count are context only: none of them changes a
-- quantity or a category. inventory_items.par_level is not read anywhere in this phase.
--
-- Additive: one table (three indexes, one trigger), one column with its check, one changed
-- function (move_inventory_stock, re-created with the extra argument) and six new functions. No
-- row is written; no balance, item, adjustment, transfer, request, receipt, commitment, invoice
-- or notification changes.

BEGIN;

DO $preflight$
BEGIN
  -- A rerun is refused here first: 7D drops the six-argument move_inventory_stock, so the
  -- dependency check below would otherwise report a misleading missing prerequisite.
  IF pg_catalog.to_regclass('public.inventory_replenishment_rules') IS NOT NULL
     OR EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'inventory_transfers' AND column_name = 'source')
     OR EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public' AND p.proname IN (
                  'tg_guard_inventory_replenishment_rule', 'set_inventory_replenishment_rule',
                  'set_inventory_replenishment_rule_enabled', 'inventory_replenishment_rows',
                  'list_inventory_replenishment', 'get_inventory_replenishment_summary',
                  'list_inventory_location_replenishment_rules', 'inventory_replenishment_rule_json')) THEN
    RAISE EXCEPTION 'Phase 7D replenishment objects already exist unexpectedly';
  END IF;
  IF pg_catalog.to_regclass('public.supply_request_receipts') IS NULL
     OR pg_catalog.to_regprocedure('public.list_receiving_destinations(uuid)') IS NULL
     OR pg_catalog.to_regprocedure('public.inventory_location_count_freshness(uuid, timestamptz)') IS NULL
     OR pg_catalog.to_regprocedure('public.move_inventory_stock(uuid, uuid, uuid, uuid, numeric, text)') IS NULL
     OR pg_catalog.to_regprocedure('public.inventory_apply_balance_delta(uuid, uuid, uuid, numeric)') IS NULL
     OR pg_catalog.to_regprocedure('public.is_org_admin(uuid, uuid)') IS NULL
     OR pg_catalog.to_regprocedure('public.has_org_role(uuid, uuid, public.org_role[])') IS NULL
     OR pg_catalog.to_regprocedure('public.tg_set_updated_at()') IS NULL THEN
    RAISE EXCEPTION 'Phase 7D requires Phase 7C, 7B.5, 7A.1 and the organization role helpers';
  END IF;
END
$preflight$;

-- Inventory and transfer state before this migration, as one hash kept for the in-migration
-- postcheck in a transaction-local setting (no temp table).
DO $snapshot$
BEGIN
  PERFORM set_config('medspend.phase7d_inventory', (SELECT md5(concat_ws('|',
    (SELECT md5(coalesce(string_agg(id::text || ':' || quantity::text || ':' || coalesce(par_level::text, '-'), ',' ORDER BY id), ''))
       FROM public.inventory_items),
    (SELECT md5(coalesce(string_agg(inventory_item_id::text || '/' || inventory_location_id::text || ':' || quantity::text
       || ':' || version::text, ',' ORDER BY inventory_item_id, inventory_location_id), ''))
       FROM public.inventory_location_balances),
    (SELECT count(*)::text FROM public.inventory_adjustments),
    (SELECT md5(coalesce(string_agg(id::text, ',' ORDER BY id), '')) FROM public.inventory_transfers)))), true);
END
$snapshot$;

-- ---------------------------------------------------------------------------------------
-- Rules. Quantity limits follow physical counts: at most 1,000,000,000 with up to six decimal
-- places.
-- ---------------------------------------------------------------------------------------
CREATE TABLE public.inventory_replenishment_rules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  inventory_item_id uuid NOT NULL,
  inventory_location_id uuid NOT NULL,
  minimum_quantity numeric NOT NULL
    CONSTRAINT inventory_replenishment_rules_minimum_check
      CHECK (minimum_quantity >= 0 AND minimum_quantity <= 1000000000 AND scale(trim_scale(minimum_quantity)) <= 6),
  target_quantity numeric NOT NULL
    CONSTRAINT inventory_replenishment_rules_target_check
      CHECK (target_quantity > 0 AND target_quantity <= 1000000000 AND scale(trim_scale(target_quantity)) <= 6),
  enabled boolean NOT NULL DEFAULT true,
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT inventory_replenishment_rules_target_minimum_check CHECK (target_quantity >= minimum_quantity),
  CONSTRAINT inventory_replenishment_rules_item_location_key UNIQUE (inventory_item_id, inventory_location_id),
  CONSTRAINT inventory_replenishment_rules_item_org_fk FOREIGN KEY (inventory_item_id, organization_id)
    REFERENCES public.inventory_items(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT inventory_replenishment_rules_location_org_fk FOREIGN KEY (inventory_location_id, organization_id)
    REFERENCES public.inventory_locations(id, organization_id)
);
CREATE INDEX inventory_replenishment_rules_org_location_idx
  ON public.inventory_replenishment_rules (organization_id, inventory_location_id);
CREATE INDEX inventory_replenishment_rules_location_idx
  ON public.inventory_replenishment_rules (inventory_location_id);
ALTER TABLE public.inventory_replenishment_rules ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inventory_replenishment_rules FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.inventory_replenishment_rules TO service_role;

-- Identity is fixed at creation; a rule never belongs to Unassigned (or any non-storage
-- location). updated_at follows every change.
CREATE FUNCTION public.tg_guard_inventory_replenishment_rule()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND (NEW.id IS DISTINCT FROM OLD.id
      OR NEW.organization_id IS DISTINCT FROM OLD.organization_id
      OR NEW.inventory_item_id IS DISTINCT FROM OLD.inventory_item_id
      OR NEW.inventory_location_id IS DISTINCT FROM OLD.inventory_location_id
      OR NEW.created_at IS DISTINCT FROM OLD.created_at) THEN
    RAISE EXCEPTION 'A replenishment rule''s item and location cannot change' USING ERRCODE = '42501';
  END IF;
  IF TG_OP = 'INSERT' AND NOT EXISTS (
    SELECT 1 FROM public.inventory_locations location
    WHERE location.id = NEW.inventory_location_id AND location.organization_id = NEW.organization_id
      AND location.kind = 'storage') THEN
    RAISE EXCEPTION 'Replenishment rules apply to storage locations only; Unassigned cannot have one'
      USING ERRCODE = '22023';
  END IF;
  -- updated_at is the optimistic version: it moves when the rule itself changes, not when a
  -- deleted user's id is cleared from created_by / updated_by.
  IF TG_OP = 'UPDATE' AND (NEW.minimum_quantity, NEW.target_quantity, NEW.enabled)
      IS DISTINCT FROM (OLD.minimum_quantity, OLD.target_quantity, OLD.enabled) THEN
    NEW.updated_at := greatest(clock_timestamp(), OLD.updated_at + interval '1 microsecond');
  ELSIF TG_OP = 'UPDATE' THEN
    NEW.updated_at := OLD.updated_at;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.tg_guard_inventory_replenishment_rule() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER inventory_replenishment_rules_guard BEFORE INSERT OR UPDATE ON public.inventory_replenishment_rules
  FOR EACH ROW EXECUTE FUNCTION public.tg_guard_inventory_replenishment_rule();

-- ---------------------------------------------------------------------------------------
-- Transfer source marker. A constant default: no table rewrite, every existing row is 'manual'.
-- ---------------------------------------------------------------------------------------
ALTER TABLE public.inventory_transfers
  ADD COLUMN source text NOT NULL DEFAULT 'manual'
    CONSTRAINT inventory_transfers_source_check CHECK (source IN ('manual', 'replenishment'));

-- ---------------------------------------------------------------------------------------
-- move_inventory_stock: the 7A.1 body with one trailing argument. Callers that pass six
-- arguments (positionally or by name, including an app loaded before the deploy) resolve to
-- this function through the default. The replay match ignores the source: a replay is the same
-- move, and the first stored source stays.
-- ---------------------------------------------------------------------------------------
DROP FUNCTION public.move_inventory_stock(uuid, uuid, uuid, uuid, numeric, text);
CREATE FUNCTION public.move_inventory_stock(
  _organization_id uuid,
  _inventory_item_id uuid,
  _from_inventory_location_id uuid,
  _to_inventory_location_id uuid,
  _quantity numeric,
  _idempotency_key text,
  _source text DEFAULT 'manual'
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
  IF _source IS NULL OR _source NOT IN ('manual', 'replenishment') THEN
    RAISE EXCEPTION 'Unknown move source' USING ERRCODE = '22023';
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
     quantity, idempotency_key, created_by, source)
  VALUES (_organization_id, _inventory_item_id, _from.id, _to.id, _quantity, _key, auth.uid(), _source)
  RETURNING * INTO _transfer;

  RETURN jsonb_build_object('transferId', _transfer.id, 'replayed', false,
    'itemQuantity', (_to_result->>'itemQuantity')::numeric,
    'fromQuantity', (_from_result->>'locationQuantity')::numeric,
    'toQuantity', (_to_result->>'locationQuantity')::numeric);
END;
$$;
REVOKE ALL ON FUNCTION public.move_inventory_stock(uuid, uuid, uuid, uuid, numeric, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.move_inventory_stock(uuid, uuid, uuid, uuid, numeric, text, text) TO authenticated;

-- ---------------------------------------------------------------------------------------
-- Rule writes (owner only). Stale screens get SQLSTATE 55000, never 40001 (PostgREST retries
-- 40001).
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.inventory_replenishment_rule_json(_rule public.inventory_replenishment_rules)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT jsonb_build_object('ruleId', _rule.id, 'inventoryItemId', _rule.inventory_item_id,
    'inventoryLocationId', _rule.inventory_location_id, 'minimumQuantity', trim_scale(_rule.minimum_quantity),
    'targetQuantity', trim_scale(_rule.target_quantity), 'enabled', _rule.enabled, 'updatedAt', _rule.updated_at);
$$;
REVOKE ALL ON FUNCTION public.inventory_replenishment_rule_json(public.inventory_replenishment_rules) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.set_inventory_replenishment_rule(
  _organization_id uuid,
  _inventory_item_id uuid,
  _inventory_location_id uuid,
  _minimum_quantity numeric,
  _target_quantity numeric,
  _expected_updated_at timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _item public.inventory_items%ROWTYPE;
  _location public.inventory_locations%ROWTYPE;
  _rule public.inventory_replenishment_rules%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required' USING ERRCODE = '42501';
  END IF;
  IF _inventory_item_id IS NULL OR _inventory_location_id IS NULL THEN
    RAISE EXCEPTION 'Choose an inventory item and a location' USING ERRCODE = '22023';
  END IF;
  IF _minimum_quantity IS NULL OR _target_quantity IS NULL THEN
    RAISE EXCEPTION 'Enter a Minimum and a Target' USING ERRCODE = '22023';
  END IF;
  IF _minimum_quantity < 0 THEN
    RAISE EXCEPTION 'Minimum must be zero or more' USING ERRCODE = '22023';
  END IF;
  IF _target_quantity <= 0 THEN
    RAISE EXCEPTION 'Target must be greater than zero' USING ERRCODE = '22023';
  END IF;
  IF _minimum_quantity > 1000000000 OR _target_quantity > 1000000000
     OR scale(trim_scale(_minimum_quantity)) > 6 OR scale(trim_scale(_target_quantity)) > 6 THEN
    RAISE EXCEPTION 'Quantities must be at most 1,000,000,000 with up to six decimal places' USING ERRCODE = '22023';
  END IF;
  IF _target_quantity < _minimum_quantity THEN
    RAISE EXCEPTION 'Target must be at least the Minimum' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO _item FROM public.inventory_items
  WHERE id = _inventory_item_id AND organization_id = _organization_id FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Inventory item not found' USING ERRCODE = 'P0002'; END IF;
  SELECT * INTO _location FROM public.inventory_locations
  WHERE id = _inventory_location_id AND organization_id = _organization_id FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Inventory location not found' USING ERRCODE = 'P0002'; END IF;
  IF _location.kind <> 'storage' THEN
    RAISE EXCEPTION 'Unassigned cannot have a replenishment rule' USING ERRCODE = '22023';
  END IF;
  IF NOT _item.active THEN
    RAISE EXCEPTION '% is archived; it cannot have a replenishment rule', _item.name USING ERRCODE = '55000';
  END IF;
  IF NOT _location.active THEN
    RAISE EXCEPTION '% is archived; it cannot have a replenishment rule', _location.name USING ERRCODE = '55000';
  END IF;

  IF _expected_updated_at IS NULL THEN
    INSERT INTO public.inventory_replenishment_rules
      (organization_id, inventory_item_id, inventory_location_id, minimum_quantity, target_quantity,
       enabled, created_by, updated_by)
    VALUES (_organization_id, _item.id, _location.id, _minimum_quantity, _target_quantity, true, auth.uid(), auth.uid())
    ON CONFLICT (inventory_item_id, inventory_location_id) DO NOTHING
    RETURNING * INTO _rule;
    IF NOT FOUND THEN
      RAISE EXCEPTION '% already has a replenishment rule at %. Reload to edit it.', _item.name, _location.name
        USING ERRCODE = '23505';
    END IF;
    RETURN public.inventory_replenishment_rule_json(_rule) || jsonb_build_object('created', true);
  END IF;

  SELECT * INTO _rule FROM public.inventory_replenishment_rules
  WHERE organization_id = _organization_id AND inventory_item_id = _item.id AND inventory_location_id = _location.id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Replenishment rule not found' USING ERRCODE = 'P0002'; END IF;
  IF _rule.updated_at IS DISTINCT FROM _expected_updated_at THEN
    RAISE EXCEPTION 'This replenishment rule changed since you opened it. Reload and try again.' USING ERRCODE = '55000';
  END IF;

  UPDATE public.inventory_replenishment_rules
  SET minimum_quantity = _minimum_quantity, target_quantity = _target_quantity, updated_by = auth.uid()
  WHERE id = _rule.id
  RETURNING * INTO _rule;
  RETURN public.inventory_replenishment_rule_json(_rule) || jsonb_build_object('created', false);
END;
$$;
REVOKE ALL ON FUNCTION public.set_inventory_replenishment_rule(uuid, uuid, uuid, numeric, numeric, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_inventory_replenishment_rule(uuid, uuid, uuid, numeric, numeric, timestamptz) TO authenticated;

CREATE FUNCTION public.set_inventory_replenishment_rule_enabled(
  _organization_id uuid,
  _rule_id uuid,
  _enabled boolean,
  _expected_updated_at timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _rule public.inventory_replenishment_rules%ROWTYPE;
  _item public.inventory_items%ROWTYPE;
  _location public.inventory_locations%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required' USING ERRCODE = '42501';
  END IF;
  IF _rule_id IS NULL OR _enabled IS NULL OR _expected_updated_at IS NULL THEN
    RAISE EXCEPTION 'A rule, its new state and the version you saw are required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO _rule FROM public.inventory_replenishment_rules
  WHERE id = _rule_id AND organization_id = _organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Replenishment rule not found' USING ERRCODE = 'P0002'; END IF;
  IF _rule.updated_at IS DISTINCT FROM _expected_updated_at THEN
    RAISE EXCEPTION 'This replenishment rule changed since you opened it. Reload and try again.' USING ERRCODE = '55000';
  END IF;
  IF _rule.enabled = _enabled THEN
    RETURN public.inventory_replenishment_rule_json(_rule) || jsonb_build_object('changed', false);
  END IF;

  IF _enabled THEN
    SELECT * INTO _item FROM public.inventory_items
    WHERE id = _rule.inventory_item_id AND organization_id = _organization_id FOR SHARE;
    SELECT * INTO _location FROM public.inventory_locations
    WHERE id = _rule.inventory_location_id AND organization_id = _organization_id FOR SHARE;
    IF NOT _item.active THEN
      RAISE EXCEPTION '% is archived; its replenishment rule cannot be turned on', _item.name USING ERRCODE = '55000';
    END IF;
    IF NOT _location.active OR _location.kind <> 'storage' THEN
      RAISE EXCEPTION '% is archived; its replenishment rule cannot be turned on', _location.name USING ERRCODE = '55000';
    END IF;
  END IF;

  UPDATE public.inventory_replenishment_rules
  SET enabled = _enabled, updated_by = auth.uid()
  WHERE id = _rule.id
  RETURNING * INTO _rule;
  RETURN public.inventory_replenishment_rule_json(_rule) || jsonb_build_object('changed', true);
END;
$$;
REVOKE ALL ON FUNCTION public.set_inventory_replenishment_rule_enabled(uuid, uuid, boolean, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_inventory_replenishment_rule_enabled(uuid, uuid, boolean, timestamptz) TO authenticated;

-- ---------------------------------------------------------------------------------------
-- The calculation. Internal: no client EXECUTE, callers check the role first. One pass over the
-- organization's rules, their balances and the balances of ruled items; no per-rule lookups.
-- Donor candidates are ranked once per item (top four, so three remain after the rule's own
-- location is removed).
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.inventory_replenishment_rows(_organization_id uuid)
RETURNS TABLE (
  rule_id uuid,
  inventory_item_id uuid,
  item_name text,
  item_unit text,
  item_active boolean,
  inventory_location_id uuid,
  location_name text,
  location_active boolean,
  minimum_quantity numeric,
  target_quantity numeric,
  enabled boolean,
  updated_at timestamptz,
  category text,
  inactive_reason text,
  category_rank integer,
  current_quantity numeric,
  not_stocked_here boolean,
  shortage_quantity numeric,
  available_quantity numeric,
  move_quantity numeric,
  external_quantity numeric,
  organization_quantity numeric,
  unassigned_quantity numeric,
  donors jsonb,
  other_short_location_count integer
)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  WITH rules AS (
    SELECT rule.*, item.name AS item_name, item.unit AS item_unit, item.active AS item_active,
      item.quantity AS item_quantity, location.name AS location_name,
      (location.active AND location.kind = 'storage') AS location_active,
      (rule.enabled AND item.active AND location.active AND location.kind = 'storage') AS live
    FROM public.inventory_replenishment_rules rule
    JOIN public.inventory_items item ON item.id = rule.inventory_item_id AND item.organization_id = rule.organization_id
    JOIN public.inventory_locations location
      ON location.id = rule.inventory_location_id AND location.organization_id = rule.organization_id
    WHERE rule.organization_id = _organization_id
  ),
  live_items AS (
    SELECT DISTINCT rules.inventory_item_id FROM rules WHERE rules.live
  ),
  stock AS (
    SELECT balance.inventory_item_id, balance.inventory_location_id, balance.quantity, location.kind, location.name,
      CASE WHEN location.kind = 'unassigned' THEN balance.quantity
           ELSE greatest(0, balance.quantity - coalesce(minimum.minimum_quantity, 0)) END AS spare
    FROM public.inventory_location_balances balance
    JOIN live_items ON live_items.inventory_item_id = balance.inventory_item_id
    JOIN public.inventory_locations location
      ON location.id = balance.inventory_location_id AND location.organization_id = balance.organization_id
    LEFT JOIN rules minimum
      ON minimum.live AND minimum.inventory_item_id = balance.inventory_item_id
     AND minimum.inventory_location_id = balance.inventory_location_id
    WHERE balance.organization_id = _organization_id AND location.active
  ),
  totals AS (
    SELECT stock.inventory_item_id,
      sum(stock.spare) AS spare,
      coalesce(sum(stock.quantity) FILTER (WHERE stock.kind = 'unassigned'), 0) AS unassigned
    FROM stock GROUP BY stock.inventory_item_id
  ),
  ranked AS (
    SELECT stock.*, row_number() OVER (PARTITION BY stock.inventory_item_id
      ORDER BY (stock.kind = 'unassigned') DESC, stock.spare DESC, lower(stock.name), stock.inventory_location_id) AS position
    FROM stock WHERE stock.spare > 0
  ),
  candidates AS (
    SELECT ranked.inventory_item_id, jsonb_agg(jsonb_build_object('locationId', ranked.inventory_location_id,
      'name', ranked.name, 'kind', ranked.kind, 'spareQuantity', trim_scale(ranked.spare)) ORDER BY ranked.position) AS donors
    FROM ranked WHERE ranked.position <= 4 GROUP BY ranked.inventory_item_id
  ),
  calculated AS (
    SELECT rules.*, balance.quantity IS NULL AS not_stocked_here,
      coalesce(balance.quantity, 0) AS current_quantity,
      coalesce(totals.spare, 0) - coalesce(own.spare, 0) AS available,
      coalesce(totals.unassigned, 0) AS unassigned,
      candidates.donors AS candidate_donors
    FROM rules
    LEFT JOIN public.inventory_location_balances balance
      ON balance.inventory_item_id = rules.inventory_item_id AND balance.inventory_location_id = rules.inventory_location_id
    LEFT JOIN totals ON totals.inventory_item_id = rules.inventory_item_id
    LEFT JOIN stock own
      ON own.inventory_item_id = rules.inventory_item_id AND own.inventory_location_id = rules.inventory_location_id
    LEFT JOIN candidates ON candidates.inventory_item_id = rules.inventory_item_id
  ),
  decided AS (
    SELECT calculated.*,
      CASE WHEN calculated.live AND calculated.current_quantity <= calculated.minimum_quantity
        THEN calculated.target_quantity - calculated.current_quantity ELSE 0 END AS shortage
    FROM calculated
  ),
  moved AS (
    SELECT decided.*, least(decided.shortage, decided.available) AS move
    FROM decided
  )
  SELECT moved.id, moved.inventory_item_id, moved.item_name, moved.item_unit, moved.item_active,
    moved.inventory_location_id, moved.location_name, moved.location_active,
    trim_scale(moved.minimum_quantity), trim_scale(moved.target_quantity), moved.enabled, moved.updated_at,
    CASE
      WHEN NOT moved.live THEN 'inactive'
      WHEN moved.shortage = 0 THEN 'ok'
      WHEN moved.move >= moved.shortage THEN 'move_available'
      WHEN moved.move > 0 THEN 'partly_covered'
      ELSE 'needs_purchasing'
    END,
    CASE
      WHEN moved.live THEN NULL
      WHEN NOT moved.item_active THEN 'item_archived'
      WHEN NOT moved.location_active THEN 'location_archived'
      ELSE 'disabled'
    END,
    CASE
      WHEN NOT moved.live THEN 0
      WHEN moved.shortage = 0 THEN 0
      WHEN moved.move >= moved.shortage THEN 1
      WHEN moved.move > 0 THEN 2
      ELSE 3
    END,
    trim_scale(moved.current_quantity), moved.not_stocked_here,
    trim_scale(moved.shortage),
    CASE WHEN moved.live THEN trim_scale(moved.available) ELSE 0 END,
    trim_scale(moved.move),
    trim_scale(moved.shortage - moved.move),
    trim_scale(moved.item_quantity),
    trim_scale(moved.unassigned),
    -- Up to three donors in donor order, each with the part of the move it covers (taken in
    -- order: a donor gives min(its spare, what earlier donors left)).
    CASE WHEN moved.live AND moved.shortage > 0 THEN coalesce((
      SELECT jsonb_agg(taken.donor || jsonb_build_object('moveQuantity', trim_scale(taken.take)) ORDER BY taken.ordinality)
      FROM (
        SELECT listed.donor, listed.ordinality,
          greatest(0, least((listed.donor->>'spareQuantity')::numeric,
            moved.move - coalesce(sum((listed.donor->>'spareQuantity')::numeric) OVER (
              ORDER BY listed.ordinality ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0))) AS take
        FROM (SELECT entry.donor, entry.ordinality
              FROM jsonb_array_elements(coalesce(moved.candidate_donors, '[]'::jsonb)) WITH ORDINALITY AS entry(donor, ordinality)
              WHERE entry.donor->>'locationId' <> moved.inventory_location_id::text
              ORDER BY entry.ordinality LIMIT 3) listed
      ) taken), '[]'::jsonb)
      ELSE '[]'::jsonb END,
    CASE WHEN moved.live AND moved.shortage > 0
      THEN (count(*) FILTER (WHERE moved.live AND moved.shortage > 0) OVER (PARTITION BY moved.inventory_item_id))::integer - 1
      ELSE 0 END
  FROM moved;
$$;
REVOKE ALL ON FUNCTION public.inventory_replenishment_rows(uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------------------
-- Reads (owner + admin). Context columns (last count, location count state, open requests) are
-- looked up only for the returned page.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.list_inventory_replenishment(
  _organization_id uuid,
  _view text DEFAULT 'attention',
  _inventory_location_id uuid DEFAULT NULL,
  _limit integer DEFAULT 100,
  _after_rank integer DEFAULT NULL,
  _after_item text DEFAULT NULL,
  _after_location text DEFAULT NULL,
  _after_id uuid DEFAULT NULL
)
RETURNS TABLE (
  rule_id uuid,
  inventory_item_id uuid,
  item_name text,
  item_unit text,
  item_active boolean,
  inventory_location_id uuid,
  location_name text,
  location_active boolean,
  minimum_quantity numeric,
  target_quantity numeric,
  enabled boolean,
  updated_at timestamptz,
  category text,
  inactive_reason text,
  current_quantity numeric,
  not_stocked_here boolean,
  shortage_quantity numeric,
  available_quantity numeric,
  move_quantity numeric,
  external_quantity numeric,
  organization_quantity numeric,
  unassigned_quantity numeric,
  donors jsonb,
  other_short_location_count integer,
  last_counted_at timestamptz,
  location_count_state text,
  open_request_count integer,
  open_approved_request_count integer,
  open_ordered_request_count integer,
  sort_rank integer,
  sort_item text,
  sort_location text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_org_admin(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;
  IF _view IS NULL OR _view NOT IN ('attention', 'ok', 'inactive', 'all') THEN
    RAISE EXCEPTION 'Choose attention, ok, inactive or all' USING ERRCODE = '22023';
  END IF;
  IF _limit IS NULL OR _limit < 1 OR _limit > 500 THEN
    RAISE EXCEPTION 'Page size must be between 1 and 500' USING ERRCODE = '22023';
  END IF;
  IF (_after_id IS NULL) <> (_after_rank IS NULL) OR (_after_id IS NULL) <> (_after_item IS NULL)
     OR (_after_id IS NULL) <> (_after_location IS NULL) THEN
    RAISE EXCEPTION 'An incomplete page cursor was supplied' USING ERRCODE = '22023';
  END IF;

  -- The attention view is ordered by category (move available, partly covered, needs
  -- purchasing); every other view by item and location name only.
  RETURN QUERY
  WITH ordered AS (
    SELECT calc.*, CASE WHEN _view = 'attention' THEN calc.category_rank ELSE 0 END AS rank_key,
      lower(calc.item_name) AS item_key, lower(calc.location_name) AS location_key
    FROM public.inventory_replenishment_rows(_organization_id) calc
    WHERE (_view = 'all'
           OR (_view = 'attention' AND calc.category IN ('move_available', 'partly_covered', 'needs_purchasing'))
           OR (_view = 'ok' AND calc.category = 'ok')
           OR (_view = 'inactive' AND calc.category = 'inactive'))
      AND (_inventory_location_id IS NULL OR calc.inventory_location_id = _inventory_location_id)
  ),
  page AS (
    SELECT ordered.* FROM ordered
    WHERE _after_id IS NULL OR (ordered.rank_key, ordered.item_key, ordered.location_key, ordered.rule_id)
                                > (_after_rank, _after_item, _after_location, _after_id)
    ORDER BY ordered.rank_key, ordered.item_key, ordered.location_key, ordered.rule_id
    LIMIT _limit
  ),
  freshness AS (
    SELECT fresh.inventory_location_id, fresh.state
    FROM public.inventory_location_count_freshness(_organization_id, now()) fresh
  )
  SELECT page.rule_id, page.inventory_item_id, page.item_name, page.item_unit, page.item_active,
    page.inventory_location_id, page.location_name, page.location_active, page.minimum_quantity,
    page.target_quantity, page.enabled, page.updated_at, page.category, page.inactive_reason,
    page.current_quantity, page.not_stocked_here, page.shortage_quantity, page.available_quantity,
    page.move_quantity, page.external_quantity, page.organization_quantity, page.unassigned_quantity,
    page.donors, page.other_short_location_count,
    (SELECT line.created_at FROM public.inventory_count_lines line
     WHERE line.inventory_item_id = page.inventory_item_id AND line.inventory_location_id = page.inventory_location_id
     ORDER BY line.created_at DESC LIMIT 1),
    freshness.state,
    coalesce(requests.total, 0), coalesce(requests.approved, 0), coalesce(requests.ordered, 0),
    page.rank_key, page.item_key, page.location_key
  FROM page
  LEFT JOIN freshness ON freshness.inventory_location_id = page.inventory_location_id
  LEFT JOIN LATERAL (
    SELECT count(DISTINCT request.id)::integer AS total,
      (count(DISTINCT request.id) FILTER (WHERE request.status = 'approved'))::integer AS approved,
      (count(DISTINCT request.id) FILTER (WHERE request.status = 'ordered'))::integer AS ordered
    FROM public.supply_request_items line
    JOIN public.supply_requests request
      ON request.id = line.supply_request_id AND request.organization_id = line.organization_id
    WHERE line.organization_id = _organization_id AND line.inventory_item_id = page.inventory_item_id
      AND request.status IN ('approved', 'ordered')
  ) requests ON true
  ORDER BY page.rank_key, page.item_key, page.location_key, page.rule_id;
END;
$$;
REVOKE ALL ON FUNCTION public.list_inventory_replenishment(uuid, text, uuid, integer, integer, text, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_inventory_replenishment(uuid, text, uuid, integer, integer, text, text, uuid) TO authenticated;

CREATE FUNCTION public.get_inventory_replenishment_summary(_organization_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _result jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_org_admin(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;

  WITH calc AS (
    SELECT * FROM public.inventory_replenishment_rows(_organization_id)
  ),
  active_items AS (
    SELECT item.id FROM public.inventory_items item WHERE item.organization_id = _organization_id AND item.active
  ),
  storage AS (
    SELECT location.id FROM public.inventory_locations location
    WHERE location.organization_id = _organization_id AND location.active AND location.kind = 'storage'
  )
  SELECT jsonb_build_object(
    'rules', jsonb_build_object(
      'total', (SELECT count(*) FROM calc),
      'active', (SELECT count(*) FROM calc WHERE calc.category <> 'inactive'),
      'inactive', (SELECT count(*) FROM calc WHERE calc.category = 'inactive'),
      'disabled', (SELECT count(*) FROM calc WHERE NOT calc.enabled)),
    'categories', jsonb_build_object(
      'moveAvailable', (SELECT count(*) FROM calc WHERE calc.category = 'move_available'),
      'partlyCovered', (SELECT count(*) FROM calc WHERE calc.category = 'partly_covered'),
      'needsPurchasing', (SELECT count(*) FROM calc WHERE calc.category = 'needs_purchasing'),
      'ok', (SELECT count(*) FROM calc WHERE calc.category = 'ok'),
      'inactive', (SELECT count(*) FROM calc WHERE calc.category = 'inactive')),
    'notStockedHere', (SELECT count(*) FROM calc WHERE calc.category <> 'inactive' AND calc.not_stocked_here),
    'items', jsonb_build_object(
      'active', (SELECT count(*) FROM active_items),
      'withRule', (SELECT count(DISTINCT calc.inventory_item_id) FROM calc WHERE calc.category <> 'inactive'),
      'withoutRule', (SELECT count(*) FROM active_items WHERE NOT EXISTS (
        SELECT 1 FROM calc WHERE calc.inventory_item_id = active_items.id AND calc.category <> 'inactive'))),
    'locations', jsonb_build_object(
      'activeStorage', (SELECT count(*) FROM storage),
      'withRule', (SELECT count(DISTINCT calc.inventory_location_id) FROM calc WHERE calc.category <> 'inactive'),
      'withoutRule', (SELECT count(*) FROM storage WHERE NOT EXISTS (
        SELECT 1 FROM calc WHERE calc.inventory_location_id = storage.id AND calc.category <> 'inactive'))))
  INTO _result;
  RETURN _result;
END;
$$;
REVOKE ALL ON FUNCTION public.get_inventory_replenishment_summary(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_inventory_replenishment_summary(uuid) TO authenticated;

-- The rules on one location's detail page, every state (disabled and inactive included), with
-- the same calculated fields, by item name and paged by (item name, rule id). Unassigned has
-- none.
CREATE FUNCTION public.list_inventory_location_replenishment_rules(
  _organization_id uuid,
  _inventory_location_id uuid,
  _limit integer DEFAULT 500,
  _after_item text DEFAULT NULL,
  _after_id uuid DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _location_key text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_org_admin(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;
  IF (_after_id IS NULL) <> (_after_item IS NULL) THEN
    RAISE EXCEPTION 'An incomplete page cursor was supplied' USING ERRCODE = '22023';
  END IF;
  SELECT lower(name) INTO _location_key FROM public.inventory_locations
  WHERE id = _inventory_location_id AND organization_id = _organization_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Inventory location not found' USING ERRCODE = 'P0002'; END IF;

  RETURN QUERY
  SELECT to_jsonb(entry) - 'sort_rank' - 'sort_location'
  FROM public.list_inventory_replenishment(_organization_id, 'all', _inventory_location_id, _limit,
    CASE WHEN _after_id IS NULL THEN NULL ELSE 0 END, _after_item,
    CASE WHEN _after_id IS NULL THEN NULL ELSE _location_key END, _after_id) entry
  ORDER BY entry.sort_item, entry.rule_id;
END;
$$;
REVOKE ALL ON FUNCTION public.list_inventory_location_replenishment_rules(uuid, uuid, integer, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_inventory_location_replenishment_rules(uuid, uuid, integer, text, uuid) TO authenticated;

COMMENT ON TABLE public.inventory_replenishment_rules IS
  'Phase 7D: Minimum / Target per inventory item x storage location. Read and written only through owner/admin RPCs.';
COMMENT ON COLUMN public.inventory_transfers.source IS
  'manual, or replenishment when the owner confirmed the move from a replenishment recommendation (Phase 7D).';
COMMENT ON FUNCTION public.inventory_replenishment_rows(uuid) IS
  'Internal: the single replenishment calculation (Phase 7D). Never reads par_level.';
COMMENT ON FUNCTION public.set_inventory_replenishment_rule(uuid, uuid, uuid, numeric, numeric, timestamptz) IS
  'Owner: create (no expected updated_at) or edit (expected updated_at) a replenishment rule.';
COMMENT ON FUNCTION public.set_inventory_replenishment_rule_enabled(uuid, uuid, boolean, timestamptz) IS
  'Owner: disable or re-enable a replenishment rule. Rules are never deleted.';
COMMENT ON FUNCTION public.list_inventory_replenishment(uuid, text, uuid, integer, integer, text, text, uuid) IS
  'Owner/admin: replenishment rows with the calculation and context, paged. Read-only.';
COMMENT ON FUNCTION public.get_inventory_replenishment_summary(uuid) IS
  'Owner/admin: replenishment category counts and rule coverage. Read-only.';
COMMENT ON FUNCTION public.list_inventory_location_replenishment_rules(uuid, uuid, integer, text, uuid) IS
  'Owner/admin: one location''s replenishment rules in every state. Read-only.';

-- ---------------------------------------------------------------------------------------
-- In-migration postcheck. Any failure rolls the whole migration back.
-- ---------------------------------------------------------------------------------------
DO $postcheck$
DECLARE
  _fn regprocedure;
BEGIN
  FOREACH _fn IN ARRAY ARRAY[
    'public.move_inventory_stock(uuid, uuid, uuid, uuid, numeric, text, text)'::regprocedure,
    'public.set_inventory_replenishment_rule(uuid, uuid, uuid, numeric, numeric, timestamptz)'::regprocedure,
    'public.set_inventory_replenishment_rule_enabled(uuid, uuid, boolean, timestamptz)'::regprocedure,
    'public.list_inventory_replenishment(uuid, text, uuid, integer, integer, text, text, uuid)'::regprocedure,
    'public.get_inventory_replenishment_summary(uuid)'::regprocedure,
    'public.list_inventory_location_replenishment_rules(uuid, uuid, integer, text, uuid)'::regprocedure]
  LOOP
    IF NOT has_function_privilege('authenticated', _fn, 'EXECUTE')
       OR has_function_privilege('anon', _fn, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
                  WHERE p.oid = _fn AND acl.grantee = 0 AND acl.privilege_type = 'EXECUTE')
       OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = _fn) THEN
      RAISE EXCEPTION 'Phase 7D postcheck: unexpected security or grants on %', _fn;
    END IF;
  END LOOP;
  FOREACH _fn IN ARRAY ARRAY[
    'public.inventory_replenishment_rows(uuid)'::regprocedure,
    'public.inventory_replenishment_rule_json(public.inventory_replenishment_rules)'::regprocedure,
    'public.tg_guard_inventory_replenishment_rule()'::regprocedure]
  LOOP
    IF has_function_privilege('authenticated', _fn, 'EXECUTE') OR has_function_privilege('anon', _fn, 'EXECUTE')
       OR (SELECT prosecdef FROM pg_proc WHERE oid = _fn) THEN
      RAISE EXCEPTION 'Phase 7D postcheck: internal function % is callable by clients', _fn;
    END IF;
  END LOOP;
  IF pg_catalog.to_regprocedure('public.move_inventory_stock(uuid, uuid, uuid, uuid, numeric, text)') IS NOT NULL THEN
    RAISE EXCEPTION 'Phase 7D postcheck: the six-argument move_inventory_stock still exists';
  END IF;
  IF position('par_level' IN pg_get_functiondef('public.inventory_replenishment_rows(uuid)'::regprocedure)) > 0
     OR position('par_level' IN pg_get_functiondef('public.list_inventory_replenishment(uuid, text, uuid, integer, integer, text, text, uuid)'::regprocedure)) > 0
     OR position('par_level' IN pg_get_functiondef('public.get_inventory_replenishment_summary(uuid)'::regprocedure)) > 0 THEN
    RAISE EXCEPTION 'Phase 7D postcheck: replenishment must not read par_level';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.inventory_replenishment_rules'::regclass)
     OR EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'inventory_replenishment_rules')
     OR EXISTS (SELECT 1 FROM information_schema.role_table_grants WHERE table_schema = 'public'
                AND table_name = 'inventory_replenishment_rules'
                AND (grantee IN ('anon', 'authenticated', 'PUBLIC') OR (grantee = 'service_role' AND privilege_type <> 'SELECT'))) THEN
    RAISE EXCEPTION 'Phase 7D postcheck: the rules table must have RLS, no policies and no client grants';
  END IF;
  IF EXISTS (SELECT 1 FROM public.inventory_replenishment_rules) THEN
    RAISE EXCEPTION 'Phase 7D postcheck: the migration must not create rules';
  END IF;
  IF EXISTS (SELECT 1 FROM public.inventory_transfers WHERE source <> 'manual') THEN
    RAISE EXCEPTION 'Phase 7D postcheck: every existing transfer must be manual';
  END IF;
  IF current_setting('medspend.phase7d_inventory', true) IS DISTINCT FROM (SELECT md5(concat_ws('|',
    (SELECT md5(coalesce(string_agg(id::text || ':' || quantity::text || ':' || coalesce(par_level::text, '-'), ',' ORDER BY id), ''))
       FROM public.inventory_items),
    (SELECT md5(coalesce(string_agg(inventory_item_id::text || '/' || inventory_location_id::text || ':' || quantity::text
       || ':' || version::text, ',' ORDER BY inventory_item_id, inventory_location_id), ''))
       FROM public.inventory_location_balances),
    (SELECT count(*)::text FROM public.inventory_adjustments),
    (SELECT md5(coalesce(string_agg(id::text, ',' ORDER BY id), '')) FROM public.inventory_transfers)))) THEN
    RAISE EXCEPTION 'Phase 7D postcheck: inventory quantities, balances, adjustments or transfers changed';
  END IF;
END
$postcheck$;

COMMIT;
