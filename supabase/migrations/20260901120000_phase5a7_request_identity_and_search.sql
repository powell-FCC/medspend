-- Phase 5A.7 backend prerequisite: canonical request-line identity and unified staff search.
--
-- This migration performs no request backfill, catalog adoption, inventory creation,
-- or global catalog mutation. Existing product-only and free-text submission payloads
-- remain valid through the unchanged submit_supply_request function signature.

DO $phase5a7_preflight$
DECLARE
  _identity_definition text;
BEGIN
  IF pg_catalog.to_regprocedure(
    'public.submit_supply_request(uuid,public.supply_request_type,uuid,uuid,text,jsonb)'
  ) IS NULL THEN
    RAISE EXCEPTION 'Phase 5A.7 requires the existing submit_supply_request RPC signature';
  END IF;

  SELECT pg_catalog.pg_get_constraintdef(constraint_definition.oid)
  INTO _identity_definition
  FROM pg_catalog.pg_constraint constraint_definition
  WHERE constraint_definition.conrelid = 'public.supply_request_items'::pg_catalog.regclass
    AND constraint_definition.conname = 'supply_request_items_identity_check';

  IF _identity_definition IS NULL
     OR lower(_identity_definition) NOT LIKE '%product_id is not null%free_text_item is null%'
     OR lower(_identity_definition) NOT LIKE '%product_id is null%free_text_item%' THEN
    RAISE EXCEPTION 'Phase 5A.7 found unexpected supply_request_items identity semantics: %',
      COALESCE(_identity_definition, 'missing');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'supply_request_items'
      AND column_name IN (
        'inventory_item_id',
        'vendor_product_id',
        'catalog_vendor_product_id'
      )
  ) THEN
    RAISE EXCEPTION 'Phase 5A.7 request identity columns already exist unexpectedly';
  END IF;

  IF pg_catalog.to_regclass('public.inventory_items_id_org_uq') IS NOT NULL THEN
    RAISE EXCEPTION 'Phase 5A.7 inventory_items_id_org_uq already exists unexpectedly';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_constraint constraint_definition
    WHERE constraint_definition.conrelid = 'public.supply_request_items'::pg_catalog.regclass
      AND constraint_definition.conname IN (
        'supply_request_items_inventory_org_fk',
        'supply_request_items_vendor_product_org_fk',
        'supply_request_items_catalog_vendor_product_fk'
      )
  ) THEN
    RAISE EXCEPTION 'Phase 5A.7 request identity constraint names already exist unexpectedly';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc procedure
    JOIN pg_catalog.pg_namespace procedure_namespace
      ON procedure_namespace.oid = procedure.pronamespace
    WHERE procedure_namespace.nspname = 'public'
      AND procedure.proname = 'search_supply_request_products'
  ) THEN
    RAISE EXCEPTION 'Phase 5A.7 found an unexpected existing search_supply_request_products RPC';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class index_relation
    JOIN pg_catalog.pg_namespace index_namespace
      ON index_namespace.oid = index_relation.relnamespace
    JOIN pg_catalog.pg_index index_definition
      ON index_definition.indexrelid = index_relation.oid
    WHERE index_namespace.nspname = 'public'
      AND index_relation.relname = 'vendor_products_id_org_uq'
      AND index_definition.indisunique
      AND index_definition.indisvalid
      AND index_definition.indisready
      AND pg_catalog.pg_get_indexdef(index_relation.oid) =
        'CREATE UNIQUE INDEX vendor_products_id_org_uq ON public.vendor_products USING btree (id, organization_id)'
  ) THEN
    RAISE EXCEPTION 'Phase 5A.7 requires vendor_products_id_org_uq';
  END IF;
END
$phase5a7_preflight$;

-- inventory_items already has a globally unique id. This additional key exists only
-- to support an organization-consistent request-line foreign key.
CREATE UNIQUE INDEX inventory_items_id_org_uq
  ON public.inventory_items (id, organization_id);

ALTER TABLE public.supply_request_items
  ADD COLUMN inventory_item_id uuid,
  ADD COLUMN vendor_product_id uuid,
  ADD COLUMN catalog_vendor_product_id uuid;

ALTER TABLE public.supply_request_items
  ADD CONSTRAINT supply_request_items_inventory_org_fk
    FOREIGN KEY (inventory_item_id, organization_id)
    REFERENCES public.inventory_items(id, organization_id) ON DELETE RESTRICT,
  ADD CONSTRAINT supply_request_items_vendor_product_org_fk
    FOREIGN KEY (vendor_product_id, organization_id)
    REFERENCES public.vendor_products(id, organization_id) ON DELETE RESTRICT,
  ADD CONSTRAINT supply_request_items_catalog_vendor_product_fk
    FOREIGN KEY (catalog_vendor_product_id)
    REFERENCES public.catalog_vendor_products(id) ON DELETE RESTRICT;

ALTER TABLE public.supply_request_items
  DROP CONSTRAINT supply_request_items_identity_check,
  ADD CONSTRAINT supply_request_items_identity_check CHECK (
    (
      nullif(btrim(free_text_item), '') IS NOT NULL
      AND product_id IS NULL
      AND inventory_item_id IS NULL
      AND vendor_product_id IS NULL
      AND catalog_vendor_product_id IS NULL
    )
    OR
    (
      free_text_item IS NULL
      AND (
        product_id IS NOT NULL
        OR inventory_item_id IS NOT NULL
        OR vendor_product_id IS NOT NULL
        OR catalog_vendor_product_id IS NOT NULL
      )
    )
  );

CREATE INDEX supply_request_items_org_inventory_idx
  ON public.supply_request_items (organization_id, inventory_item_id)
  WHERE inventory_item_id IS NOT NULL;
CREATE INDEX supply_request_items_org_vendor_product_idx
  ON public.supply_request_items (organization_id, vendor_product_id)
  WHERE vendor_product_id IS NOT NULL;
CREATE INDEX supply_request_items_catalog_vendor_product_idx
  ON public.supply_request_items (catalog_vendor_product_id)
  WHERE catalog_vendor_product_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.submit_supply_request(
  _organization_id uuid,
  _request_type public.supply_request_type,
  _team_id uuid,
  _location_id uuid,
  _notes text,
  _items jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid uuid := auth.uid();
  _membership public.organization_memberships%ROWTYPE;
  _request_id uuid;
  _item jsonb;
  _inventory public.inventory_items%ROWTYPE;
  _vendor_product public.vendor_products%ROWTYPE;
  _product public.products%ROWTYPE;
  _catalog_vendor_product public.catalog_vendor_products%ROWTYPE;
  _inventory_item_id uuid;
  _vendor_product_id uuid;
  _product_id uuid;
  _catalog_vendor_product_id uuid;
  _free_text text;
  _quantity numeric;
  _unit text;
  _first_product_id uuid;
  _first_free_text text;
  _first_quantity integer;
BEGIN
  IF _uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  SELECT *
  INTO _membership
  FROM public.organization_memberships
  WHERE organization_id = _organization_id
    AND user_id = _uid
    AND active = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Not a member of this organization' USING ERRCODE = '42501';
  END IF;

  _team_id := coalesce(_team_id, _membership.default_team_id);
  _location_id := coalesce(_location_id, _membership.default_location_id);
  IF _team_id IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.teams
    WHERE id = _team_id
      AND organization_id = _organization_id
      AND active = true
  ) THEN
    RAISE EXCEPTION 'Select an available team for this request';
  END IF;
  IF _location_id IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.locations
    WHERE id = _location_id
      AND organization_id = _organization_id
      AND active = true
  ) THEN
    RAISE EXCEPTION 'Select an available location for this request';
  END IF;
  IF _items IS NULL
     OR jsonb_typeof(_items) <> 'array'
     OR jsonb_array_length(_items) = 0 THEN
    RAISE EXCEPTION 'Add at least one item to the request';
  END IF;

  INSERT INTO public.supply_requests (
    organization_id,
    requested_by,
    request_type,
    team_id,
    location_id,
    notes,
    status
  ) VALUES (
    _organization_id,
    _uid,
    _request_type,
    _team_id,
    _location_id,
    nullif(btrim(_notes), ''),
    'submitted'
  )
  RETURNING id INTO _request_id;

  FOR _item IN SELECT value FROM jsonb_array_elements(_items)
  LOOP
    IF jsonb_typeof(_item) <> 'object' THEN
      RAISE EXCEPTION 'Each request line must be an object';
    END IF;

    _inventory_item_id := nullif(_item->>'inventoryItemId', '')::uuid;
    _vendor_product_id := nullif(_item->>'vendorProductId', '')::uuid;
    _product_id := nullif(_item->>'productId', '')::uuid;
    _catalog_vendor_product_id := nullif(_item->>'catalogVendorProductId', '')::uuid;
    _free_text := nullif(btrim(_item->>'freeTextItem'), '');
    _unit := NULL;

    BEGIN
      _quantity := (_item->>'quantity')::numeric;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'Each requested quantity must be a positive whole number';
    END;
    IF _quantity IS NULL OR _quantity <= 0 OR _quantity <> trunc(_quantity) THEN
      RAISE EXCEPTION 'Each requested quantity must be a positive whole number';
    END IF;

    IF _free_text IS NOT NULL AND (
      _inventory_item_id IS NOT NULL
      OR _vendor_product_id IS NOT NULL
      OR _product_id IS NOT NULL
      OR _catalog_vendor_product_id IS NOT NULL
    ) THEN
      RAISE EXCEPTION 'A custom request line cannot include structured identity IDs'
        USING ERRCODE = '22023';
    END IF;
    IF _free_text IS NULL
       AND _inventory_item_id IS NULL
       AND _vendor_product_id IS NULL
       AND _product_id IS NULL
       AND _catalog_vendor_product_id IS NULL THEN
      RAISE EXCEPTION 'Each line must contain a structured identity or one custom item'
        USING ERRCODE = '22023';
    END IF;

    IF _inventory_item_id IS NOT NULL THEN
      SELECT *
      INTO _inventory
      FROM public.inventory_items
      WHERE id = _inventory_item_id
        AND organization_id = _organization_id
        AND active = true;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'A selected inventory item is unavailable for this organization'
          USING ERRCODE = 'P0002';
      END IF;

      IF _inventory.product_id IS NULL THEN
        IF _product_id IS NOT NULL OR _vendor_product_id IS NOT NULL
           OR _catalog_vendor_product_id IS NOT NULL THEN
          RAISE EXCEPTION 'The selected inventory item has no proven product identity chain'
            USING ERRCODE = '22023';
        END IF;
      ELSIF _product_id IS NOT NULL AND _product_id <> _inventory.product_id THEN
        RAISE EXCEPTION 'The selected inventory item does not belong to the supplied product'
          USING ERRCODE = '22023';
      ELSE
        _product_id := _inventory.product_id;
      END IF;
      _unit := _inventory.unit;
    END IF;

    IF _vendor_product_id IS NOT NULL THEN
      SELECT vendor_product.*
      INTO _vendor_product
      FROM public.vendor_products vendor_product
      JOIN public.vendors vendor
        ON vendor.id = vendor_product.vendor_id
       AND vendor.organization_id = vendor_product.organization_id
       AND vendor.active = true
      WHERE vendor_product.id = _vendor_product_id
        AND vendor_product.organization_id = _organization_id
        AND vendor_product.active = true;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'A selected vendor product is unavailable for this organization'
          USING ERRCODE = 'P0002';
      END IF;

      IF _product_id IS NOT NULL AND _product_id <> _vendor_product.product_id THEN
        RAISE EXCEPTION 'The selected vendor product does not belong to the supplied product'
          USING ERRCODE = '22023';
      END IF;
      _product_id := _vendor_product.product_id;

      IF _vendor_product.catalog_vendor_product_id IS NOT NULL THEN
        IF _catalog_vendor_product_id IS NOT NULL
           AND _catalog_vendor_product_id <> _vendor_product.catalog_vendor_product_id THEN
          RAISE EXCEPTION 'The selected vendor product does not link to the supplied global catalog identity'
            USING ERRCODE = '22023';
        END IF;
        _catalog_vendor_product_id := _vendor_product.catalog_vendor_product_id;
      ELSIF _catalog_vendor_product_id IS NOT NULL THEN
        RAISE EXCEPTION 'The selected vendor product has no proven global catalog link'
          USING ERRCODE = '22023';
      END IF;
    END IF;

    IF _product_id IS NOT NULL THEN
      SELECT *
      INTO _product
      FROM public.products
      WHERE id = _product_id
        AND organization_id = _organization_id
        AND active = true
        AND staff_requestable = true;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'A selected product is unavailable for this organization'
          USING ERRCODE = 'P0002';
      END IF;
      IF _unit IS NULL THEN
        _unit := _product.unit_of_measure;
      END IF;
    END IF;

    IF _catalog_vendor_product_id IS NOT NULL THEN
      SELECT catalog_vendor_product.*
      INTO _catalog_vendor_product
      FROM public.catalog_vendor_products catalog_vendor_product
      JOIN public.catalog_products catalog_product
        ON catalog_product.id = catalog_vendor_product.catalog_product_id
       AND catalog_product.active = true
      JOIN public.catalog_vendors catalog_vendor
        ON catalog_vendor.id = catalog_vendor_product.catalog_vendor_id
       AND catalog_vendor.active = true
      WHERE catalog_vendor_product.id = _catalog_vendor_product_id
        AND catalog_vendor_product.active = true
        AND catalog_vendor_product.discontinued = false;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'A selected global catalog product is unavailable'
          USING ERRCODE = 'P0002';
      END IF;

      IF _vendor_product_id IS NULL AND (
        _product_id IS NOT NULL OR _inventory_item_id IS NOT NULL
      ) THEN
        RAISE EXCEPTION 'A local product cannot claim an unproven global catalog identity'
          USING ERRCODE = '22023';
      END IF;
    END IF;

    INSERT INTO public.supply_request_items (
      organization_id,
      supply_request_id,
      product_id,
      inventory_item_id,
      vendor_product_id,
      catalog_vendor_product_id,
      free_text_item,
      quantity,
      unit
    ) VALUES (
      _organization_id,
      _request_id,
      _product_id,
      _inventory_item_id,
      _vendor_product_id,
      _catalog_vendor_product_id,
      _free_text,
      _quantity::integer,
      _unit
    );

    IF _first_quantity IS NULL THEN
      _first_product_id := _product_id;
      _first_free_text := _free_text;
      _first_quantity := _quantity::integer;
    END IF;
  END LOOP;

  -- Preserve the established first-line compatibility mirror. A global-only or
  -- unlinked-inventory first line intentionally leaves both legacy identity fields null.
  UPDATE public.supply_requests
  SET product_id = _first_product_id,
      free_text_item = _first_free_text,
      quantity = _first_quantity
  WHERE id = _request_id;

  RETURN _request_id;
END;
$$;

REVOKE ALL ON FUNCTION public.submit_supply_request(
  uuid,
  public.supply_request_type,
  uuid,
  uuid,
  text,
  jsonb
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.submit_supply_request(
  uuid,
  public.supply_request_type,
  uuid,
  uuid,
  text,
  jsonb
) FROM anon;
GRANT EXECUTE ON FUNCTION public.submit_supply_request(
  uuid,
  public.supply_request_type,
  uuid,
  uuid,
  text,
  jsonb
) TO authenticated;

CREATE OR REPLACE FUNCTION public.search_supply_request_products(
  _organization_id uuid,
  _query text,
  _limit integer DEFAULT 20
)
RETURNS TABLE (
  result_key text,
  identity_source text,
  product_name text,
  manufacturer text,
  vendor_name text,
  vendor_sku text,
  package_display text,
  package_status text,
  inventory_item_id uuid,
  product_id uuid,
  vendor_product_id uuid,
  catalog_vendor_product_id uuid
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid uuid := auth.uid();
  _raw_query text := btrim(COALESCE(_query, ''));
  _normalized_text text;
  _normalized_sku text;
  _bounded_limit integer := LEAST(GREATEST(COALESCE(_limit, 20), 1), 50);
BEGIN
  IF _uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;
  IF _organization_id IS NULL THEN
    RAISE EXCEPTION 'organization_id is required' USING ERRCODE = '22004';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.organization_memberships membership
    WHERE membership.organization_id = _organization_id
      AND membership.user_id = _uid
      AND membership.active = true
  ) THEN
    RAISE EXCEPTION 'Not a member of this organization' USING ERRCODE = '42501';
  END IF;
  IF length(_raw_query) > 120 THEN
    RAISE EXCEPTION 'Search query cannot exceed 120 characters' USING ERRCODE = '22001';
  END IF;
  IF _raw_query = '' THEN
    RETURN;
  END IF;

  _normalized_text := public.normalize_catalog_text(_raw_query);
  _normalized_sku := public.normalize_catalog_sku(_raw_query);

  RETURN QUERY
  WITH organization_adoptions AS (
    SELECT
      organization_vendor_product.id AS vendor_product_id,
      organization_vendor_product.product_id,
      organization_vendor_product.catalog_vendor_product_id,
      organization_vendor_product.vendor_sku,
      organization_product.name AS product_name,
      organization_product.normalized_name,
      organization_product.manufacturer,
      organization_product.description,
      organization_vendor.name AS vendor_name,
      inventory.id AS inventory_item_id
    FROM public.vendor_products organization_vendor_product
    JOIN public.products organization_product
      ON organization_product.id = organization_vendor_product.product_id
     AND organization_product.organization_id = organization_vendor_product.organization_id
     AND organization_product.active = true
     AND organization_product.staff_requestable = true
    JOIN public.vendors organization_vendor
      ON organization_vendor.id = organization_vendor_product.vendor_id
     AND organization_vendor.organization_id = organization_vendor_product.organization_id
     AND organization_vendor.active = true
    LEFT JOIN public.inventory_items inventory
      ON inventory.organization_id = organization_vendor_product.organization_id
     AND inventory.product_id = organization_vendor_product.product_id
     AND inventory.active = true
    WHERE organization_vendor_product.organization_id = _organization_id
      AND organization_vendor_product.active = true
      AND organization_vendor_product.catalog_vendor_product_id IS NOT NULL
  ),
  global_candidates AS (
    SELECT
      CASE
        WHEN adoption.product_id IS NOT NULL
          THEN 'organization-product:' || adoption.product_id::text
        ELSE 'catalog-vendor-product:' || catalog_vendor_product.id::text
      END AS identity_key,
      CASE
        WHEN adoption.inventory_item_id IS NOT NULL THEN 'inventory'
        WHEN adoption.vendor_product_id IS NOT NULL THEN 'organization_catalog'
        ELSE 'global_catalog'
      END AS identity_source,
      COALESCE(adoption.product_name, catalog_product.name) AS product_name,
      COALESCE(adoption.manufacturer, catalog_product.manufacturer) AS manufacturer,
      COALESCE(adoption.vendor_name, catalog_vendor.name) AS vendor_name,
      catalog_vendor_product.vendor_sku,
      CASE catalog_vendor_product.package_status
        WHEN 'verified' THEN concat_ws(
          ' ',
          catalog_vendor_product.package_quantity::text,
          catalog_vendor_product.package_unit
        )
        WHEN 'source_only' THEN COALESCE(
          catalog_vendor_product.package_description,
          'Source package text unavailable'
        )
        ELSE 'Unknown'
      END AS package_display,
      catalog_vendor_product.package_status,
      adoption.inventory_item_id,
      adoption.product_id,
      adoption.vendor_product_id,
      catalog_vendor_product.id AS catalog_vendor_product_id,
      public.normalize_catalog_sku(adoption.vendor_sku) AS organization_sku,
      catalog_vendor_product.normalized_vendor_sku AS global_sku,
      COALESCE(adoption.normalized_name, catalog_product.normalized_name) AS primary_name,
      catalog_product.normalized_name AS alternate_name,
      public.normalize_catalog_text(
        concat_ws(' ', adoption.product_name, catalog_product.name)
      ) AS product_search,
      public.normalize_catalog_text(
        concat_ws(' ', adoption.manufacturer, catalog_product.manufacturer)
      ) AS manufacturer_search,
      public.normalize_catalog_text(
        concat_ws(' ', adoption.vendor_name, catalog_vendor.name)
      ) AS vendor_search,
      public.normalize_catalog_text(
        concat_ws(' ', adoption.description, catalog_product.description)
      ) AS description_search,
      CASE
        WHEN adoption.inventory_item_id IS NOT NULL THEN 0
        WHEN adoption.vendor_product_id IS NOT NULL THEN 1
        ELSE 3
      END AS source_priority
    FROM public.catalog_vendor_products catalog_vendor_product
    JOIN public.catalog_products catalog_product
      ON catalog_product.id = catalog_vendor_product.catalog_product_id
     AND catalog_product.active = true
    JOIN public.catalog_vendors catalog_vendor
      ON catalog_vendor.id = catalog_vendor_product.catalog_vendor_id
     AND catalog_vendor.active = true
    LEFT JOIN organization_adoptions adoption
      ON adoption.catalog_vendor_product_id = catalog_vendor_product.id
    WHERE catalog_vendor_product.active = true
      AND catalog_vendor_product.discontinued = false
  ),
  local_vendor_candidates AS (
    SELECT
      'organization-product:' || organization_product.id::text AS identity_key,
      CASE
        WHEN inventory.id IS NOT NULL THEN 'inventory'
        ELSE 'organization_catalog'
      END AS identity_source,
      organization_product.name AS product_name,
      organization_product.manufacturer,
      organization_vendor.name AS vendor_name,
      organization_vendor_product.vendor_sku,
      'Unknown'::text AS package_display,
      'unknown'::text AS package_status,
      inventory.id AS inventory_item_id,
      organization_product.id AS product_id,
      organization_vendor_product.id AS vendor_product_id,
      NULL::uuid AS catalog_vendor_product_id,
      public.normalize_catalog_sku(organization_vendor_product.vendor_sku) AS organization_sku,
      NULL::text AS global_sku,
      organization_product.normalized_name AS primary_name,
      NULL::text AS alternate_name,
      organization_product.normalized_name AS product_search,
      public.normalize_catalog_text(organization_product.manufacturer) AS manufacturer_search,
      public.normalize_catalog_text(organization_vendor.name) AS vendor_search,
      public.normalize_catalog_text(organization_product.description) AS description_search,
      CASE WHEN inventory.id IS NOT NULL THEN 0 ELSE 1 END AS source_priority
    FROM public.vendor_products organization_vendor_product
    JOIN public.products organization_product
      ON organization_product.id = organization_vendor_product.product_id
     AND organization_product.organization_id = organization_vendor_product.organization_id
     AND organization_product.active = true
     AND organization_product.staff_requestable = true
    JOIN public.vendors organization_vendor
      ON organization_vendor.id = organization_vendor_product.vendor_id
     AND organization_vendor.organization_id = organization_vendor_product.organization_id
     AND organization_vendor.active = true
    LEFT JOIN public.inventory_items inventory
      ON inventory.organization_id = organization_product.organization_id
     AND inventory.product_id = organization_product.id
     AND inventory.active = true
    WHERE organization_vendor_product.organization_id = _organization_id
      AND organization_vendor_product.active = true
      AND organization_vendor_product.catalog_vendor_product_id IS NULL
  ),
  local_product_candidates AS (
    SELECT
      'organization-product:' || organization_product.id::text AS identity_key,
      CASE
        WHEN inventory.id IS NOT NULL THEN 'inventory'
        ELSE 'organization_product'
      END AS identity_source,
      organization_product.name AS product_name,
      organization_product.manufacturer,
      NULL::text AS vendor_name,
      NULL::text AS vendor_sku,
      'Unknown'::text AS package_display,
      'unknown'::text AS package_status,
      inventory.id AS inventory_item_id,
      organization_product.id AS product_id,
      NULL::uuid AS vendor_product_id,
      NULL::uuid AS catalog_vendor_product_id,
      public.normalize_catalog_sku(
        COALESCE(organization_product.vendor_item_number, organization_product.internal_item_code)
      ) AS organization_sku,
      NULL::text AS global_sku,
      organization_product.normalized_name AS primary_name,
      NULL::text AS alternate_name,
      organization_product.normalized_name AS product_search,
      public.normalize_catalog_text(organization_product.manufacturer) AS manufacturer_search,
      ''::text AS vendor_search,
      public.normalize_catalog_text(organization_product.description) AS description_search,
      CASE WHEN inventory.id IS NOT NULL THEN 0 ELSE 2 END AS source_priority
    FROM public.products organization_product
    LEFT JOIN public.inventory_items inventory
      ON inventory.organization_id = organization_product.organization_id
     AND inventory.product_id = organization_product.id
     AND inventory.active = true
    WHERE organization_product.organization_id = _organization_id
      AND organization_product.active = true
      AND organization_product.staff_requestable = true
  ),
  unlinked_inventory_candidates AS (
    SELECT
      'inventory:' || inventory.id::text AS identity_key,
      'inventory'::text AS identity_source,
      inventory.name AS product_name,
      inventory.manufacturer,
      inventory.vendor_name,
      inventory.sku AS vendor_sku,
      'Unknown'::text AS package_display,
      'unknown'::text AS package_status,
      inventory.id AS inventory_item_id,
      NULL::uuid AS product_id,
      NULL::uuid AS vendor_product_id,
      NULL::uuid AS catalog_vendor_product_id,
      public.normalize_catalog_sku(inventory.sku) AS organization_sku,
      NULL::text AS global_sku,
      public.normalize_catalog_text(inventory.name) AS primary_name,
      NULL::text AS alternate_name,
      public.normalize_catalog_text(inventory.name) AS product_search,
      public.normalize_catalog_text(inventory.manufacturer) AS manufacturer_search,
      public.normalize_catalog_text(inventory.vendor_name) AS vendor_search,
      public.normalize_catalog_text(inventory.description) AS description_search,
      0 AS source_priority
    FROM public.inventory_items inventory
    WHERE inventory.organization_id = _organization_id
      AND inventory.active = true
      AND inventory.product_id IS NULL
  ),
  candidates AS (
    SELECT * FROM global_candidates
    UNION ALL
    SELECT * FROM local_vendor_candidates
    UNION ALL
    SELECT * FROM local_product_candidates
    UNION ALL
    SELECT * FROM unlinked_inventory_candidates
  ),
  scored AS (
    SELECT
      candidate.*,
      CASE
        WHEN _normalized_sku <> ''
             AND candidate.organization_sku = _normalized_sku THEN 0
        WHEN _normalized_sku <> ''
             AND candidate.global_sku = _normalized_sku THEN 1
        WHEN _normalized_text <> ''
             AND (
               candidate.primary_name = _normalized_text
               OR candidate.alternate_name = _normalized_text
             ) THEN 2
        WHEN (
          _normalized_sku <> ''
          AND (
            pg_catalog.strpos(COALESCE(candidate.organization_sku, ''), _normalized_sku) > 0
            OR pg_catalog.strpos(COALESCE(candidate.global_sku, ''), _normalized_sku) > 0
          )
        ) OR (
          _normalized_text <> ''
          AND pg_catalog.strpos(candidate.product_search, _normalized_text) > 0
        ) THEN 3
        WHEN _normalized_text <> ''
             AND (
               pg_catalog.strpos(candidate.manufacturer_search, _normalized_text) > 0
               OR pg_catalog.strpos(candidate.vendor_search, _normalized_text) > 0
             ) THEN 4
        WHEN _normalized_text <> ''
             AND pg_catalog.strpos(candidate.description_search, _normalized_text) > 0 THEN 5
        ELSE 99
      END AS match_rank
    FROM candidates candidate
  ),
  deduplicated AS (
    SELECT
      scored.*,
      pg_catalog.row_number() OVER (
        PARTITION BY scored.identity_key
        ORDER BY
          scored.match_rank,
          scored.source_priority,
          scored.catalog_vendor_product_id NULLS LAST,
          scored.vendor_product_id NULLS LAST,
          scored.inventory_item_id NULLS LAST,
          lower(scored.product_name),
          COALESCE(scored.vendor_sku, ''),
          scored.identity_key
      ) AS identity_rank
    FROM scored
    WHERE scored.match_rank < 99
  )
  SELECT
    deduplicated.identity_key,
    deduplicated.identity_source,
    deduplicated.product_name,
    deduplicated.manufacturer,
    deduplicated.vendor_name,
    deduplicated.vendor_sku,
    deduplicated.package_display,
    deduplicated.package_status,
    deduplicated.inventory_item_id,
    deduplicated.product_id,
    deduplicated.vendor_product_id,
    deduplicated.catalog_vendor_product_id
  FROM deduplicated
  WHERE deduplicated.identity_rank = 1
  ORDER BY
    deduplicated.match_rank,
    deduplicated.source_priority,
    lower(deduplicated.product_name),
    COALESCE(deduplicated.vendor_name, ''),
    COALESCE(deduplicated.vendor_sku, ''),
    deduplicated.identity_key
  LIMIT _bounded_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.search_supply_request_products(uuid, text, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.search_supply_request_products(uuid, text, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.search_supply_request_products(uuid, text, integer)
  TO authenticated;
