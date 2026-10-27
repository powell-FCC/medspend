-- Phase 7A.2: QR inventory physical counts.
--
-- A physical count is an absolute, complete snapshot of one storage location: someone
-- checked every countable item there and recorded what is physically on the shelf.
-- SportSpend does not log routine consumption; a count only corrects reality.
--
--   * inventory_count_sessions / inventory_count_lines record every submitted count,
--     including lines whose quantity did not change. They are immutable.
--   * Every count line writes one physical_count inventory_adjustments row, including a
--     zero delta, so the existing invoice-deletion guard treats it as a checkpoint.
--   * inventory_location_labels are QR identities for storage locations. Only a SHA-256
--     hash of each opaque token is stored, and a token alone never authorizes anything.
--   * Staff reach counts and request identities only through SECURITY DEFINER functions
--     that return safe fields.
--
-- Additive and safe to apply before the application deploys: no existing function,
-- policy or grant the deployed application uses changes. Staff read hardening of
-- inventory_items ships separately (20261027120100), after the application deploys.

BEGIN;

DO $preflight$
BEGIN
  IF pg_catalog.to_regclass('public.inventory_count_sessions') IS NOT NULL
     OR pg_catalog.to_regclass('public.inventory_count_lines') IS NOT NULL
     OR pg_catalog.to_regclass('public.inventory_location_labels') IS NOT NULL THEN
    RAISE EXCEPTION 'Phase 7A.2 inventory count tables already exist unexpectedly';
  END IF;
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'inventory_adjustments'
      AND column_name = 'inventory_count_line_id'
  ) THEN
    RAISE EXCEPTION 'Phase 7A.2 inventory_adjustments.inventory_count_line_id already exists unexpectedly';
  END IF;
  IF pg_catalog.to_regclass('public.inventory_location_balances') IS NULL
     OR pg_catalog.to_regprocedure('public.inventory_apply_balance_delta(uuid, uuid, uuid, numeric)') IS NULL THEN
    RAISE EXCEPTION 'Phase 7A.2 requires the Phase 7A.1 location-aware inventory foundation';
  END IF;
  IF (SELECT pg_get_constraintdef(oid) FROM pg_constraint
      WHERE conrelid = 'public.inventory_adjustments'::regclass
        AND conname = 'inventory_adjustments_reason_check')
     IS DISTINCT FROM 'CHECK ((reason = ANY (ARRAY[''Invoice received''::text, ''Manual adjustment''::text, ''Damaged''::text, ''Expired''::text, ''Correction''::text])))' THEN
    RAISE EXCEPTION 'Phase 7A.2 found an unexpected inventory_adjustments_reason_check';
  END IF;
  IF EXISTS (SELECT 1 FROM public.inventory_adjustments WHERE source_type = 'physical_count') THEN
    RAISE EXCEPTION 'Phase 7A.2 found physical_count adjustments written before count sessions existed';
  END IF;
END
$preflight$;

-- ---------------------------------------------------------------------------------------
-- QR labels. A label names one storage location. The raw token is returned once, when the
-- label is issued; only its SHA-256 hash is kept. Several active labels may exist for one
-- location. Revocation is permanent; archiving the location only suspends its labels.
-- ---------------------------------------------------------------------------------------
CREATE TABLE public.inventory_location_labels (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  inventory_location_id uuid NOT NULL,
  token_hash text NOT NULL CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  created_by uuid NOT NULL REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  revoked_by uuid REFERENCES auth.users(id),
  CHECK ((revoked_at IS NULL) = (revoked_by IS NULL)),
  FOREIGN KEY (inventory_location_id, organization_id)
    REFERENCES public.inventory_locations(id, organization_id)
);
CREATE UNIQUE INDEX inventory_location_labels_token_hash_uq ON public.inventory_location_labels (token_hash);
CREATE INDEX inventory_location_labels_active_idx
  ON public.inventory_location_labels (inventory_location_id) WHERE revoked_at IS NULL;

-- ---------------------------------------------------------------------------------------
-- Count sessions and lines. A session exists only after a complete, successful count;
-- there are no drafts.
-- ---------------------------------------------------------------------------------------
CREATE TABLE public.inventory_count_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  inventory_location_id uuid NOT NULL,
  counted_by uuid NOT NULL REFERENCES auth.users(id),
  submitted_at timestamptz NOT NULL,
  line_count integer NOT NULL CHECK (line_count > 0),
  changed_count integer NOT NULL CHECK (changed_count >= 0 AND changed_count <= line_count),
  idempotency_key text NOT NULL CHECK (btrim(idempotency_key) <> '' AND char_length(idempotency_key) <= 200),
  request_hash text NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (inventory_location_id, organization_id)
    REFERENCES public.inventory_locations(id, organization_id)
);
CREATE UNIQUE INDEX inventory_count_sessions_idempotency_uq
  ON public.inventory_count_sessions (organization_id, idempotency_key);
CREATE UNIQUE INDEX inventory_count_sessions_identity_uq
  ON public.inventory_count_sessions (id, organization_id, inventory_location_id);
CREATE INDEX inventory_count_sessions_location_submitted_idx
  ON public.inventory_count_sessions (inventory_location_id, submitted_at DESC);
CREATE INDEX inventory_count_sessions_org_submitted_idx
  ON public.inventory_count_sessions (organization_id, submitted_at DESC);

CREATE TABLE public.inventory_count_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  count_session_id uuid NOT NULL,
  inventory_item_id uuid NOT NULL,
  inventory_location_id uuid NOT NULL,
  previous_quantity numeric NOT NULL CHECK (previous_quantity >= 0),
  counted_quantity numeric NOT NULL CHECK (counted_quantity >= 0),
  delta numeric NOT NULL,
  observed_version bigint NOT NULL CHECK (observed_version > 0),
  item_name text NOT NULL,
  item_sku text,
  item_unit text NOT NULL,
  created_at timestamptz NOT NULL,
  CHECK (delta = counted_quantity - previous_quantity),
  UNIQUE (count_session_id, inventory_item_id),
  FOREIGN KEY (count_session_id, organization_id, inventory_location_id)
    REFERENCES public.inventory_count_sessions(id, organization_id, inventory_location_id) ON DELETE CASCADE,
  FOREIGN KEY (inventory_item_id, organization_id)
    REFERENCES public.inventory_items(id, organization_id) ON DELETE CASCADE,
  FOREIGN KEY (inventory_location_id, organization_id)
    REFERENCES public.inventory_locations(id, organization_id)
);
CREATE UNIQUE INDEX inventory_count_lines_identity_uq
  ON public.inventory_count_lines (id, inventory_item_id, inventory_location_id);
CREATE INDEX inventory_count_lines_item_location_idx
  ON public.inventory_count_lines (inventory_item_id, inventory_location_id, created_at DESC);
CREATE INDEX inventory_count_lines_location_idx
  ON public.inventory_count_lines (inventory_location_id, created_at DESC);

-- ---------------------------------------------------------------------------------------
-- Ledger link. Every physical_count adjustment belongs to exactly one count line at the
-- same item and location, and only count lines write physical_count rows.
-- ---------------------------------------------------------------------------------------
ALTER TABLE public.inventory_adjustments ADD COLUMN inventory_count_line_id uuid;
ALTER TABLE public.inventory_adjustments ADD CONSTRAINT inventory_adjustments_count_line_fk
  FOREIGN KEY (inventory_count_line_id, inventory_item_id, inventory_location_id)
  REFERENCES public.inventory_count_lines(id, inventory_item_id, inventory_location_id);
CREATE UNIQUE INDEX inventory_adjustments_count_line_uq
  ON public.inventory_adjustments (inventory_count_line_id) WHERE inventory_count_line_id IS NOT NULL;
ALTER TABLE public.inventory_adjustments DROP CONSTRAINT inventory_adjustments_reason_check;
ALTER TABLE public.inventory_adjustments ADD CONSTRAINT inventory_adjustments_reason_check
  CHECK (reason IN ('Invoice received', 'Manual adjustment', 'Damaged', 'Expired', 'Correction', 'Physical count'));
ALTER TABLE public.inventory_adjustments ADD CONSTRAINT inventory_adjustments_physical_count_check
  CHECK (
    (source_type IS NOT DISTINCT FROM 'physical_count') = (inventory_count_line_id IS NOT NULL)
    AND (source_type IS NOT DISTINCT FROM 'physical_count') = (reason = 'Physical count')
  );

-- ---------------------------------------------------------------------------------------
-- RLS and grants. Nobody writes these tables directly. Owners may read count history;
-- labels are read only through the functions below.
-- ---------------------------------------------------------------------------------------
ALTER TABLE public.inventory_location_labels ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_count_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_count_lines ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inventory_location_labels, public.inventory_count_sessions, public.inventory_count_lines
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.inventory_count_sessions, public.inventory_count_lines TO authenticated;
GRANT SELECT ON public.inventory_location_labels, public.inventory_count_sessions, public.inventory_count_lines
  TO service_role;
CREATE POLICY inventory_count_sessions_owner_select ON public.inventory_count_sessions FOR SELECT TO authenticated
  USING (public.has_org_role(organization_id, auth.uid(), ARRAY['owner']::public.org_role[]));
CREATE POLICY inventory_count_lines_owner_select ON public.inventory_count_lines FOR SELECT TO authenticated
  USING (public.has_org_role(organization_id, auth.uid(), ARRAY['owner']::public.org_role[]));

-- ---------------------------------------------------------------------------------------
-- Immutability. Count history is never edited; it disappears only with its organization
-- (or, for lines, its inventory item). Labels change only by being revoked once.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.tg_guard_inventory_count_history()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF NOT EXISTS (SELECT 1 FROM public.organizations WHERE id = OLD.organization_id)
       OR (TG_TABLE_NAME = 'inventory_count_lines'
           AND NOT EXISTS (SELECT 1 FROM public.inventory_items WHERE id = OLD.inventory_item_id)) THEN
      RETURN OLD;
    END IF;
    RAISE EXCEPTION 'Inventory count history cannot be deleted' USING ERRCODE = '42501';
  END IF;
  RAISE EXCEPTION 'Inventory count history cannot be changed' USING ERRCODE = '42501';
END;
$$;
CREATE TRIGGER inventory_count_sessions_guard BEFORE UPDATE OR DELETE ON public.inventory_count_sessions
  FOR EACH ROW EXECUTE FUNCTION public.tg_guard_inventory_count_history();
CREATE TRIGGER inventory_count_lines_guard BEFORE UPDATE OR DELETE ON public.inventory_count_lines
  FOR EACH ROW EXECUTE FUNCTION public.tg_guard_inventory_count_history();

CREATE FUNCTION public.tg_guard_inventory_location_label()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF NOT EXISTS (SELECT 1 FROM public.organizations WHERE id = OLD.organization_id) THEN
      RETURN OLD;
    END IF;
    RAISE EXCEPTION 'Inventory location labels are revoked, not deleted' USING ERRCODE = '42501';
  END IF;
  IF OLD.revoked_at IS NOT NULL
     OR NEW.id IS DISTINCT FROM OLD.id
     OR NEW.organization_id IS DISTINCT FROM OLD.organization_id
     OR NEW.inventory_location_id IS DISTINCT FROM OLD.inventory_location_id
     OR NEW.token_hash IS DISTINCT FROM OLD.token_hash
     OR NEW.created_by IS DISTINCT FROM OLD.created_by
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
     OR NEW.revoked_at IS NULL THEN
    RAISE EXCEPTION 'An inventory location label can only be revoked, once' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER inventory_location_labels_guard BEFORE UPDATE OR DELETE ON public.inventory_location_labels
  FOR EACH ROW EXECUTE FUNCTION public.tg_guard_inventory_location_label();

REVOKE ALL ON FUNCTION public.tg_guard_inventory_count_history() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.tg_guard_inventory_location_label() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------------------
-- Countable items. A storage location's balance rows are its V1 membership:
--   * an active item with a balance row is always countable, even at zero, so stock that
--     was never recorded can still be found and entered;
--   * an archived item is countable while it still has stock there;
--   * an archived item with no stock there is not.
-- Count history never changes membership. The page and the submission use this one rule.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.inventory_countable_balances(_organization_id uuid, _inventory_location_id uuid)
RETURNS TABLE (
  inventory_item_id uuid,
  quantity numeric,
  version bigint,
  item_name text,
  item_sku text,
  item_manufacturer text,
  item_unit text,
  item_active boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT balance.inventory_item_id, balance.quantity, balance.version,
         item.name, item.sku, item.manufacturer, item.unit, item.active
  FROM public.inventory_location_balances balance
  JOIN public.inventory_items item
    ON item.id = balance.inventory_item_id AND item.organization_id = balance.organization_id
  WHERE balance.organization_id = _organization_id
    AND balance.inventory_location_id = _inventory_location_id
    AND (item.active OR balance.quantity > 0);
$$;
REVOKE ALL ON FUNCTION public.inventory_countable_balances(uuid, uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------------------
-- Label issue, revoke and summary (owners).
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.issue_inventory_location_label(_organization_id uuid, _inventory_location_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _location public.inventory_locations%ROWTYPE;
  _token text;
  _label public.inventory_location_labels%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO _location FROM public.inventory_locations
  WHERE id = _inventory_location_id AND organization_id = _organization_id
  FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Inventory location not found' USING ERRCODE = 'P0002'; END IF;
  IF _location.kind <> 'storage' THEN
    RAISE EXCEPTION 'Unassigned is not a physical location and has no QR label' USING ERRCODE = '22023';
  END IF;
  IF NOT _location.active THEN
    RAISE EXCEPTION 'Restore % before issuing a QR label for it', _location.name USING ERRCODE = '55000';
  END IF;

  -- 32 random bytes, base64url without padding: 43 characters, nothing else encoded.
  _token := translate(rtrim(encode(extensions.gen_random_bytes(32), 'base64'), '='), E'+/\n', '-_');
  INSERT INTO public.inventory_location_labels (organization_id, inventory_location_id, token_hash, created_by)
  VALUES (_organization_id, _location.id, encode(extensions.digest(_token, 'sha256'), 'hex'), auth.uid())
  RETURNING * INTO _label;

  RETURN jsonb_build_object('labelId', _label.id, 'token', _token, 'issuedAt', _label.created_at,
    'locationId', _location.id, 'locationName', _location.name);
END;
$$;
REVOKE ALL ON FUNCTION public.issue_inventory_location_label(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.issue_inventory_location_label(uuid, uuid) TO authenticated;

CREATE FUNCTION public.revoke_inventory_location_labels(_organization_id uuid, _inventory_location_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _revoked integer;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.inventory_locations
                 WHERE id = _inventory_location_id AND organization_id = _organization_id) THEN
    RAISE EXCEPTION 'Inventory location not found' USING ERRCODE = 'P0002';
  END IF;
  UPDATE public.inventory_location_labels
  SET revoked_at = now(), revoked_by = auth.uid()
  WHERE organization_id = _organization_id AND inventory_location_id = _inventory_location_id
    AND revoked_at IS NULL;
  GET DIAGNOSTICS _revoked = ROW_COUNT;
  RETURN _revoked;
END;
$$;
REVOKE ALL ON FUNCTION public.revoke_inventory_location_labels(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.revoke_inventory_location_labels(uuid, uuid) TO authenticated;

CREATE FUNCTION public.list_inventory_location_count_status(_organization_id uuid)
RETURNS TABLE (
  inventory_location_id uuid,
  active_label_count integer,
  last_label_issued_at timestamptz,
  last_counted_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT location.id,
    (SELECT count(*)::integer FROM public.inventory_location_labels label
     WHERE label.inventory_location_id = location.id AND label.revoked_at IS NULL),
    (SELECT max(label.created_at) FROM public.inventory_location_labels label
     WHERE label.inventory_location_id = location.id AND label.revoked_at IS NULL),
    (SELECT max(session.submitted_at) FROM public.inventory_count_sessions session
     WHERE session.inventory_location_id = location.id)
  FROM public.inventory_locations location
  WHERE location.organization_id = _organization_id AND location.kind = 'storage'
  ORDER BY location.id;
END;
$$;
REVOKE ALL ON FUNCTION public.list_inventory_location_count_status(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_inventory_location_count_status(uuid) TO authenticated;

-- ---------------------------------------------------------------------------------------
-- Member read boundaries for counting. Any active member may count; nothing here returns
-- prices, vendors, organization totals, other locations or history.
-- ---------------------------------------------------------------------------------------

-- Resolves a scanned token. The token only identifies a label: the caller must already be
-- an active member of the label's organization. Unknown tokens, other organizations' labels
-- and malformed input all return the same bare 'unavailable'.
CREATE FUNCTION public.resolve_inventory_count_label(_token text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _label public.inventory_location_labels%ROWTYPE;
  _location public.inventory_locations%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sign in to open this inventory location' USING ERRCODE = '42501';
  END IF;
  IF _token IS NULL OR _token !~ '^[A-Za-z0-9_-]{43}$' THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT * INTO _label FROM public.inventory_location_labels
  WHERE token_hash = encode(extensions.digest(_token, 'sha256'), 'hex');
  IF NOT FOUND OR NOT public.is_org_member(_label.organization_id, auth.uid()) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  IF _label.revoked_at IS NOT NULL THEN
    RETURN jsonb_build_object('status', 'replaced');
  END IF;
  SELECT * INTO _location FROM public.inventory_locations
  WHERE id = _label.inventory_location_id AND organization_id = _label.organization_id;
  IF NOT FOUND OR _location.kind <> 'storage' OR NOT _location.active THEN
    RETURN jsonb_build_object('status', 'location_unavailable');
  END IF;
  RETURN jsonb_build_object('status', 'available', 'organizationId', _location.organization_id,
    'locationId', _location.id, 'locationName', _location.name);
END;
$$;
REVOKE ALL ON FUNCTION public.resolve_inventory_count_label(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolve_inventory_count_label(text) TO authenticated;

-- The scanner fallback: this organization's active storage locations, names only.
CREATE FUNCTION public.list_countable_inventory_locations(_organization_id uuid)
RETURNS TABLE (inventory_location_id uuid, name text, last_counted_at timestamptz)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_org_member(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: organization membership required' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT location.id, location.name,
    (SELECT max(session.submitted_at) FROM public.inventory_count_sessions session
     WHERE session.inventory_location_id = location.id)
  FROM public.inventory_locations location
  WHERE location.organization_id = _organization_id AND location.kind = 'storage' AND location.active
  ORDER BY lower(location.name), location.id;
END;
$$;
REVOKE ALL ON FUNCTION public.list_countable_inventory_locations(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_countable_inventory_locations(uuid) TO authenticated;

-- The count page: one location and its countable items, with the balance versions the
-- submission must echo back. Quantities are exact decimal text, never binary floats.
CREATE FUNCTION public.get_inventory_count_location(_organization_id uuid, _inventory_location_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _location public.inventory_locations%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_org_member(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: organization membership required' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO _location FROM public.inventory_locations
  WHERE id = _inventory_location_id AND organization_id = _organization_id;
  IF NOT FOUND OR _location.kind <> 'storage' OR NOT _location.active THEN
    RAISE EXCEPTION 'This inventory location is not available for counting' USING ERRCODE = 'P0002';
  END IF;
  RETURN jsonb_build_object(
    'location', jsonb_build_object('id', _location.id, 'name', _location.name,
      'lastCountedAt', (SELECT max(submitted_at) FROM public.inventory_count_sessions
                        WHERE inventory_location_id = _location.id)),
    'items', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
          'inventoryItemId', countable.inventory_item_id,
          'name', countable.item_name,
          'sku', countable.item_sku,
          'manufacturer', countable.item_manufacturer,
          'unit', countable.item_unit,
          'quantity', trim_scale(countable.quantity)::text,
          'version', countable.version,
          'archived', NOT countable.item_active)
        ORDER BY lower(countable.item_name), countable.inventory_item_id)
      FROM public.inventory_countable_balances(_organization_id, _location.id) countable), '[]'::jsonb)
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_inventory_count_location(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_inventory_count_location(uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------------------------
-- The count. One transaction: validate, lock, prove nothing changed since the page loaded,
-- then record the session, every line, every balance change (zero included) and one
-- physical_count ledger row per line.
--
-- Lock order matches every other quantity mutation: inventory items (id order), then the
-- location, then balances (via inventory_apply_balance_delta, item order). Locking the
-- location FOR UPDATE waits for any in-flight move, adjustment or archive that touches it,
-- so the countable set and versions checked below cannot change before commit.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.submit_inventory_count(
  _organization_id uuid,
  _inventory_location_id uuid,
  _lines jsonb,
  _idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _key text := btrim(coalesce(_idempotency_key, ''));
  _element jsonb;
  _item_ids uuid[] := '{}';
  _versions bigint[] := '{}';
  _quantities numeric[] := '{}';
  _raw_quantity text;
  _quantity numeric;
  _hash text;
  _existing public.inventory_count_sessions%ROWTYPE;
  _location public.inventory_locations%ROWTYPE;
  _countable record;
  _countable_count integer;
  _matched integer;
  _submitted_at timestamptz;
  _session_id uuid;
  _line_id uuid;
  _previous numeric;
  _changed integer := 0;
  _result jsonb;
  _i integer;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_org_member(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: organization membership required' USING ERRCODE = '42501';
  END IF;
  IF _key = '' OR char_length(_key) > 200 THEN
    RAISE EXCEPTION 'A count request key is required' USING ERRCODE = '22023';
  END IF;
  IF _inventory_location_id IS NULL THEN
    RAISE EXCEPTION 'Choose an inventory location' USING ERRCODE = '22023';
  END IF;
  IF _lines IS NULL OR jsonb_typeof(_lines) <> 'array' OR jsonb_array_length(_lines) = 0 THEN
    RAISE EXCEPTION 'A count must include every item at the location' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(_lines) > 1000 THEN
    RAISE EXCEPTION 'A count can include at most 1000 items' USING ERRCODE = '22023';
  END IF;

  -- Parse and validate every line before touching anything. Quantities arrive as JSON
  -- strings or numbers, never with a sign or exponent, at most six decimal places.
  FOR _element IN
    SELECT value FROM jsonb_array_elements(_lines) ORDER BY value->>'inventoryItemId'
  LOOP
    IF jsonb_typeof(_element) <> 'object'
       OR coalesce(_element->>'inventoryItemId', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       OR coalesce(_element->>'observedVersion', '') !~ '^[1-9][0-9]{0,17}$' THEN
      RAISE EXCEPTION 'Invalid count line' USING ERRCODE = '22023';
    END IF;
    _raw_quantity := btrim(coalesce(_element->>'countedQuantity', ''));
    IF jsonb_typeof(_element->'countedQuantity') NOT IN ('string', 'number') OR _raw_quantity = '' THEN
      RAISE EXCEPTION 'Enter a quantity for every item (0 if there is none)' USING ERRCODE = '22023';
    END IF;
    IF _raw_quantity !~ '^[0-9]{1,10}(\.[0-9]+)?$' THEN
      RAISE EXCEPTION 'Quantities must be zero or more' USING ERRCODE = '22023';
    END IF;
    _quantity := _raw_quantity::numeric;
    IF _quantity > 1000000000 OR scale(trim_scale(_quantity)) > 6 THEN
      RAISE EXCEPTION 'Quantities must be at most 1,000,000,000 with up to six decimal places' USING ERRCODE = '22023';
    END IF;
    IF (_element->>'inventoryItemId')::uuid = ANY (_item_ids) THEN
      RAISE EXCEPTION 'Each item can be counted only once' USING ERRCODE = '22023';
    END IF;
    _item_ids := _item_ids || (_element->>'inventoryItemId')::uuid;
    _versions := _versions || (_element->>'observedVersion')::bigint;
    _quantities := _quantities || trim_scale(_quantity);
  END LOOP;

  -- Canonical request hash: equal counts hash equally (1, 1.0 and 1.00 are one quantity).
  SELECT encode(extensions.digest(
      _organization_id::text || '|' || _inventory_location_id::text || '|' || string_agg(
        _item_ids[i]::text || ':' || _versions[i]::text || ':' || _quantities[i]::text, ',' ORDER BY _item_ids[i]),
      'sha256'), 'hex')
  INTO _hash
  FROM generate_subscripts(_item_ids, 1) AS i;

  SELECT * INTO _existing FROM public.inventory_count_sessions
  WHERE organization_id = _organization_id AND idempotency_key = _key;
  IF FOUND THEN
    RETURN public.inventory_count_replay(_existing, _inventory_location_id, _hash);
  END IF;

  PERFORM 1 FROM public.inventory_items
  WHERE organization_id = _organization_id AND id = ANY (_item_ids)
  ORDER BY id FOR UPDATE;

  SELECT * INTO _location FROM public.inventory_locations
  WHERE id = _inventory_location_id AND organization_id = _organization_id
  FOR UPDATE;
  IF NOT FOUND OR _location.kind <> 'storage' OR NOT _location.active THEN
    RAISE EXCEPTION 'This inventory location is not available for counting' USING ERRCODE = 'P0002';
  END IF;

  -- A concurrent retry of this request committed while we waited for the locks.
  SELECT * INTO _existing FROM public.inventory_count_sessions
  WHERE organization_id = _organization_id AND idempotency_key = _key;
  IF FOUND THEN
    RETURN public.inventory_count_replay(_existing, _inventory_location_id, _hash);
  END IF;

  -- The submitted set must be exactly the countable set, at exactly the versions seen. Not
  -- SQLSTATE 40001: PostgREST retries serialization failures, and a stale count must come
  -- straight back to the person counting.
  SELECT count(*),
         count(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM generate_subscripts(_item_ids, 1) AS i
           WHERE _item_ids[i] = countable.inventory_item_id AND _versions[i] = countable.version))
  INTO _countable_count, _matched
  FROM public.inventory_countable_balances(_organization_id, _location.id) countable;
  IF _countable_count <> cardinality(_item_ids) OR _matched <> _countable_count THEN
    RAISE EXCEPTION 'Inventory changed while you were counting. Reload this location and confirm the quantities again.'
      USING ERRCODE = '55000';
  END IF;

  SELECT count(*) INTO _changed
  FROM public.inventory_countable_balances(_organization_id, _location.id) countable
  JOIN generate_subscripts(_item_ids, 1) AS i ON _item_ids[i] = countable.inventory_item_id
  WHERE _quantities[i] <> countable.quantity;

  _submitted_at := clock_timestamp();
  INSERT INTO public.inventory_count_sessions
    (organization_id, inventory_location_id, counted_by, submitted_at, line_count, changed_count,
     idempotency_key, request_hash)
  VALUES (_organization_id, _location.id, auth.uid(), _submitted_at, cardinality(_item_ids), _changed, _key, _hash)
  RETURNING id INTO _session_id;

  FOR _i IN 1 .. cardinality(_item_ids) LOOP
    SELECT * INTO _countable FROM public.inventory_countable_balances(_organization_id, _location.id) countable
    WHERE countable.inventory_item_id = _item_ids[_i];
    _previous := _countable.quantity;

    INSERT INTO public.inventory_count_lines
      (organization_id, count_session_id, inventory_item_id, inventory_location_id, previous_quantity,
       counted_quantity, delta, observed_version, item_name, item_sku, item_unit, created_at)
    VALUES (_organization_id, _session_id, _item_ids[_i], _location.id, _previous, _quantities[_i],
       _quantities[_i] - _previous, _versions[_i], _countable.item_name, _countable.item_sku,
       _countable.item_unit, _submitted_at)
    RETURNING id INTO _line_id;

    -- Zero deltas still go through the primitive: the quantity stays, the version moves,
    -- so any other count opened before this one is now stale.
    _result := public.inventory_apply_balance_delta(
      _organization_id, _item_ids[_i], _location.id, _quantities[_i] - _previous);

    INSERT INTO public.inventory_adjustments
      (organization_id, inventory_item_id, inventory_location_id, adjustment_amount, previous_quantity,
       new_quantity, reason, created_by, created_at, source_type, inventory_count_line_id)
    VALUES (_organization_id, _item_ids[_i], _location.id, _quantities[_i] - _previous,
       (_result->>'itemPreviousQuantity')::numeric, (_result->>'itemQuantity')::numeric, 'Physical count',
       auth.uid(), _submitted_at, 'physical_count', _line_id);
  END LOOP;

  RETURN public.inventory_count_summary(_session_id, false);
END;
$$;

-- The summary the count page shows after saving, and what a replay returns.
CREATE FUNCTION public.inventory_count_summary(_session_id uuid, _replayed boolean)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'sessionId', session.id,
    'locationId', session.inventory_location_id,
    'locationName', location.name,
    'submittedAt', session.submitted_at,
    'lineCount', session.line_count,
    'changedCount', session.changed_count,
    'replayed', _replayed)
  FROM public.inventory_count_sessions session
  JOIN public.inventory_locations location ON location.id = session.inventory_location_id
  WHERE session.id = _session_id;
$$;

-- Same key, same location and same canonical request: the original result. Anything
-- else under a used key is refused.
CREATE FUNCTION public.inventory_count_replay(
  _existing public.inventory_count_sessions,
  _inventory_location_id uuid,
  _request_hash text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF _existing.inventory_location_id = _inventory_location_id AND _existing.request_hash = _request_hash THEN
    RETURN public.inventory_count_summary(_existing.id, true);
  END IF;
  RAISE EXCEPTION 'This count request key was already used for a different count' USING ERRCODE = '23505';
END;
$$;

REVOKE ALL ON FUNCTION public.inventory_count_summary(uuid, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.inventory_count_replay(public.inventory_count_sessions, uuid, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.submit_inventory_count(uuid, uuid, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_inventory_count(uuid, uuid, jsonb, text) TO authenticated;

-- ---------------------------------------------------------------------------------------
-- Staff-safe inventory identities for supply-request lines (Phase 7A.2-0). Staff read
-- inventory item names through this instead of the inventory_items table, which
-- 20261027120100 then closes to them. Fields: identity and display only. No quantities,
-- prices, purchase dates or par levels. Owners also see archived items; everyone else
-- sees active items, exactly as the table policies allowed before.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.get_supply_request_inventory_identities(
  _organization_id uuid,
  _inventory_item_ids uuid[]
)
RETURNS TABLE (
  id uuid,
  name text,
  unit text,
  manufacturer text,
  vendor_name text,
  sku text,
  active boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_org_member(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: organization membership required' USING ERRCODE = '42501';
  END IF;
  IF cardinality(_inventory_item_ids) > 500 THEN
    RAISE EXCEPTION 'Too many inventory items requested' USING ERRCODE = '22023';
  END IF;
  RETURN QUERY
  SELECT item.id, item.name, item.unit, item.manufacturer, item.vendor_name, item.sku, item.active
  FROM public.inventory_items item
  WHERE item.organization_id = _organization_id
    AND item.id = ANY (coalesce(_inventory_item_ids, '{}'))
    AND (item.active OR public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]))
  ORDER BY item.id;
END;
$$;
REVOKE ALL ON FUNCTION public.get_supply_request_inventory_identities(uuid, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_supply_request_inventory_identities(uuid, uuid[]) TO authenticated;

COMMENT ON TABLE public.inventory_count_sessions IS
  'One complete physical count of one storage location. Immutable; exists only after a successful submission.';
COMMENT ON TABLE public.inventory_count_lines IS
  'Every item checked in a count, including unchanged ones: proof it was physically counted there and then.';
COMMENT ON TABLE public.inventory_location_labels IS
  'QR identities for storage locations. Only token hashes are stored; a token alone never authorizes access.';
COMMENT ON FUNCTION public.submit_inventory_count(uuid, uuid, jsonb, text) IS
  'Member physical count of one storage location: complete, version-checked, idempotent and atomic.';

-- ---------------------------------------------------------------------------------------
-- In-migration postcheck. Any failure rolls the whole migration back.
-- ---------------------------------------------------------------------------------------
DO $postcheck$
BEGIN
  IF EXISTS (SELECT 1 FROM public.inventory_adjustments WHERE inventory_count_line_id IS NOT NULL)
     OR EXISTS (SELECT 1 FROM public.inventory_count_sessions)
     OR EXISTS (SELECT 1 FROM public.inventory_location_labels) THEN
    RAISE EXCEPTION 'Phase 7A.2 postcheck: the migration must not write count or label rows';
  END IF;
  IF has_table_privilege('authenticated', 'public.inventory_location_labels', 'SELECT')
     OR has_table_privilege('anon', 'public.inventory_count_sessions', 'SELECT')
     OR has_table_privilege('authenticated', 'public.inventory_count_lines', 'INSERT')
     OR has_function_privilege('authenticated', 'public.inventory_countable_balances(uuid, uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.submit_inventory_count(uuid, uuid, jsonb, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Phase 7A.2 postcheck: unexpected grants on count objects';
  END IF;
END
$postcheck$;

COMMIT;
