-- Phase 5A.10: Staff product discovery, Saved Items and deterministic ranking.
--
-- No generative AI, embeddings or external services: every result is explained by the
-- signals below and is reproducible from the source tables.
--
--   * catalog_vendor_product_search_documents: a DERIVED search index for the global
--     catalog (one normalized text document per catalog vendor product). It is never read
--     for display and never decides eligibility; active/discontinued/vendor/product checks
--     are always made against the source tables at query time. Triggers keep it in step
--     with catalog_products, catalog_vendors, catalog_vendor_products and
--     catalog_source_records. A pg_trgm GIN index makes token matching an index probe
--     instead of re-normalizing the whole catalog on every keystroke (Phase 5A.8B cost
--     ~175 ms at 9k, ~0.9 s at 54k and ~1.7 s at 100k catalog products).
--   * catalog_search_terms: the catalog's vocabulary (letter-only words, 4+ letters), used
--     only to correct a misspelled query word. Insert-only: a term that no longer occurs
--     produces a correction that matches nothing.
--   * staff_saved_products: personal Saved Items (organization + user + one identity).
--     RLS on, no policies, no client grants; managed through the RPCs below only.
--   * supply_request_product_search (internal): the one search implementation.
--     search_supply_request_products keeps its exact Phase 5A.8B signature and columns (so
--     the currently deployed app keeps working) and now returns the new ranking;
--     search_supply_request_products_with_signals returns the same rows plus the
--     explanation columns (tier, saved, organization history).
--   * get_staff_product_discovery: Saved Items, Frequently requested, Purchased before.
--   * save_staff_product / remove_staff_saved_product: own Saved Items only.
--
-- Matching (query and documents share public.normalize_catalog_search_text; every token is
-- [a-z0-9]+):
--   * tokens of 1-2 characters must start a word ("xl" does not match "axle");
--   * longer tokens match anywhere in a word, as before ("wrap" matches "prewrap");
--   * a token that starts with a digit must not follow a digit, and one that ends with a
--     digit must not be followed by a digit: "2 inch" never matches "12 inch", "30" never
--     matches "300" or "130";
--   * a query that normalizes to fewer than 2 characters returns nothing.
-- Relevance tiers (lower wins; a tier is never crossed by any boost):
--   0 exact organization SKU (vendor product, product item number/code, inventory SKU)
--   1 exact catalog vendor SKU or manufacturer SKU (separator-insensitive)
--   2 exact product name or exact organization alias
--   3 partial SKU (4+ characters containing a digit)
--   4 the whole query as a phrase inside the product name or an alias
--   5 every token in the product name or an alias
--   6 every token anywhere in the product's attributes (manufacturer, vendor, SKUs,
--     package, size/color specification, description, unit)
--   7 typo-corrected: every token matches once each misspelled word is replaced by a
--     catalog word within the edit-distance limit
-- Within a tier: Saved by me, then organization approved-request count, then purchase
-- count (posted invoices), then the existing source preference (inventory, organization
-- catalog, organization product, global catalog), then most recent approval/purchase, then
-- name. Organization history never names or counts individual requesters.
-- Typo tolerance: only for a letter-only query word of 4+ letters that is part of no catalog
-- word and occurs nowhere in the organization's own products, inventory or aliases;
-- candidates share its first letter; 1 edit (insert, delete,
-- substitute or swap two adjacent letters) for 4-7 letters, 2 edits for 8+; at most 3
-- corrections per word. Numbers, sizes and SKUs are never corrected.

BEGIN;

DO $preflight$
BEGIN
  IF pg_catalog.to_regprocedure('public.normalize_catalog_search_text(text)') IS NULL
     OR pg_catalog.to_regprocedure('public.normalize_catalog_sku(text)') IS NULL
     OR pg_catalog.to_regprocedure('public.normalize_catalog_sku_match_key(text)') IS NULL
     OR pg_catalog.to_regprocedure('public.get_catalog_vendor_product_effective_specifications(uuid[])') IS NULL
     OR pg_catalog.to_regprocedure('public.search_supply_request_products(uuid, text, integer)') IS NULL
     OR pg_catalog.to_regprocedure('public.get_inventory_count_freshness(uuid, uuid, integer)') IS NULL THEN
    RAISE EXCEPTION 'Phase 5A.10 requires Phase 5A.8B search and Phase 7B.5';
  END IF;
  IF pg_catalog.to_regnamespace('extensions') IS NULL THEN
    RAISE EXCEPTION 'Phase 5A.10 requires the extensions schema';
  END IF;
  IF pg_catalog.to_regclass('public.staff_saved_products') IS NOT NULL
     OR pg_catalog.to_regclass('public.catalog_vendor_product_search_documents') IS NOT NULL
     OR pg_catalog.to_regprocedure('public.supply_request_product_search(uuid, text, integer)') IS NOT NULL THEN
    RAISE EXCEPTION 'Phase 5A.10 staff product discovery objects already exist unexpectedly';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_extension e JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace
             WHERE e.extname = 'pg_trgm' AND n.nspname <> 'extensions') THEN
    RAISE EXCEPTION 'Phase 5A.10 requires pg_trgm in the extensions schema';
  END IF;
END
$preflight$;

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;

-- ---------------------------------------------------------------------------------------
-- Matching helpers (pure, internal).
-- ---------------------------------------------------------------------------------------

-- The Phase 5A.8B search normalization, keeping numeric fractions whole: 1/2" and 1⁄2"
-- become "1/2inch" instead of "1 2inch", so "2 inch" can never match a half-inch item.
CREATE OR REPLACE FUNCTION public.catalog_search_text(_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
-- Deliberately no SET clause: a single pg_catalog-qualified expression is search_path-safe
-- and lets the planner inline it (it runs once per candidate row on every search). It is
-- normalize_catalog_search_text step for step (lower-case; quotes, inches and millimetres as
-- in 5A.8B; everything but letters and digits to one space), plus the fraction rule.
AS $$
  SELECT pg_catalog.replace(
    pg_catalog.btrim(
      pg_catalog.regexp_replace(
        pg_catalog.regexp_replace(
          pg_catalog.regexp_replace(
            pg_catalog.regexp_replace(
              pg_catalog.lower(
                pg_catalog.regexp_replace(COALESCE(_value, ''), '([0-9])[[:space:]]*[/⁄∕][[:space:]]*([0-9])', '\1qqfractionqq\2', 'g')
              ),
              '["“”″]+', ' inch ', 'g'
            ),
            '([0-9])[[:space:]]*(mm|millimeters?|millimetres?)\y', '\1mm', 'g'
          ),
          '([0-9])[[:space:]]*(inches|inch|in)\y', '\1inch', 'g'
        ),
        '[^[:alnum:]]+', ' ', 'g'
      )
    ),
    'qqfractionqq',
    '/'
  );
$$;

COMMENT ON FUNCTION public.catalog_search_text(text) IS
  'Phase 5A.10 search text: normalize_catalog_search_text with numeric fractions kept as one token (1/2inch).';

-- ---------------------------------------------------------------------------------------

-- The regular expression one query token must match inside a space-padded document.
CREATE OR REPLACE FUNCTION public.catalog_search_token_pattern(_token text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = public
AS $$
  SELECT CASE
           WHEN pg_catalog.length(_token) <= 2 THEN ' '
           WHEN _token ~ '^[0-9]' THEN '[^0-9/]'
           ELSE ''
         END
         || _token
         || CASE
              WHEN _token ~ '[0-9]$' THEN '[^0-9/]'
              WHEN pg_catalog.length(_token) = 1 THEN ' '
              ELSE ''
            END;
$$;

COMMENT ON FUNCTION public.catalog_search_token_pattern(text) IS
  'Phase 5A.10 token rule: 1-2 character tokens start a word; digits keep their boundaries (2inch never matches 12inch).';

-- Optimal string alignment distance (insert, delete, substitute, adjacent swap), giving up
-- as soon as it exceeds _max. Used only on the small set of vocabulary candidates.
CREATE OR REPLACE FUNCTION public.catalog_search_edit_distance(_a text, _b text, _max integer)
RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
SET search_path = public
AS $$
DECLARE
  _la integer := pg_catalog.length(_a);
  _lb integer := pg_catalog.length(_b);
  _prev2 integer[];
  _prev integer[];
  _cur integer[];
  _i integer;
  _j integer;
  _cost integer;
  _row_min integer;
  _value integer;
BEGIN
  IF pg_catalog.abs(_la - _lb) > _max THEN
    RETURN _max + 1;
  END IF;
  _prev := ARRAY(SELECT pg_catalog.generate_series(0, _lb));
  FOR _i IN 1 .. _la LOOP
    _cur := ARRAY[_i];
    _row_min := _i;
    FOR _j IN 1 .. _lb LOOP
      _cost := CASE WHEN pg_catalog.substr(_a, _i, 1) = pg_catalog.substr(_b, _j, 1) THEN 0 ELSE 1 END;
      _value := LEAST(_prev[_j + 1] + 1, _cur[_j] + 1, _prev[_j] + _cost);
      IF _i > 1 AND _j > 1
         AND pg_catalog.substr(_a, _i, 1) = pg_catalog.substr(_b, _j - 1, 1)
         AND pg_catalog.substr(_a, _i - 1, 1) = pg_catalog.substr(_b, _j, 1) THEN
        _value := LEAST(_value, _prev2[_j - 1] + 1);
      END IF;
      _cur := _cur || _value;
      _row_min := LEAST(_row_min, _value);
    END LOOP;
    IF _row_min > _max THEN
      RETURN _max + 1;
    END IF;
    _prev2 := _prev;
    _prev := _cur;
  END LOOP;
  RETURN LEAST(_prev[_lb + 1], _max + 1);
END;
$$;

COMMENT ON FUNCTION public.catalog_search_edit_distance(text, text, integer) IS
  'Phase 5A.10 bounded optimal-string-alignment distance for typo correction; returns _max + 1 when the limit is exceeded.';

REVOKE ALL ON FUNCTION public.catalog_search_text(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.catalog_search_text(text) FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.catalog_search_token_pattern(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.catalog_search_token_pattern(text) FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.catalog_search_edit_distance(text, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.catalog_search_edit_distance(text, text, integer) FROM anon, authenticated;

-- ---------------------------------------------------------------------------------------
-- Derived global-catalog search documents and vocabulary.
-- ---------------------------------------------------------------------------------------

CREATE TABLE public.catalog_vendor_product_search_documents (
  catalog_vendor_product_id uuid PRIMARY KEY
    REFERENCES public.catalog_vendor_products(id) ON DELETE CASCADE,
  -- ' ' || normalized catalog product name || ' '
  name_text text NOT NULL,
  -- ' ' || normalized name, manufacturer, vendor, description, SKUs, package and trusted
  -- specification || ' ' || SKU match keys || ' '
  document text NOT NULL,
  -- normalize_catalog_sku of the vendor and manufacturer SKUs, and their match keys
  sku_values text[] NOT NULL DEFAULT '{}',
  sku_keys text[] NOT NULL DEFAULT '{}',
  refreshed_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);

COMMENT ON TABLE public.catalog_vendor_product_search_documents IS
  'Phase 5A.10 derived search index for the global catalog. Rebuilt by triggers from the catalog tables; never read for display or eligibility.';

CREATE INDEX catalog_vendor_product_search_documents_trgm_idx
  ON public.catalog_vendor_product_search_documents
  USING gin (document extensions.gin_trgm_ops);

CREATE TABLE public.catalog_search_terms (
  term text COLLATE "C" PRIMARY KEY,
  CONSTRAINT catalog_search_terms_letters CHECK (term ~ '^[a-z]{4,40}$')
);

COMMENT ON TABLE public.catalog_search_terms IS
  'Phase 5A.10 catalog vocabulary for deterministic typo correction. Insert-only; a stale term can only yield a correction that matches nothing.';

ALTER TABLE public.catalog_vendor_product_search_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalog_search_terms ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.catalog_vendor_product_search_documents FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON TABLE public.catalog_search_terms FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.catalog_vendor_product_search_documents TO service_role;
GRANT SELECT ON TABLE public.catalog_search_terms TO service_role;

-- Rebuild the documents of the given catalog vendor products (NULL = all). Rows whose
-- catalog vendor product no longer exists are removed by the foreign key.
CREATE OR REPLACE FUNCTION public.refresh_catalog_vendor_product_search_documents(
  _catalog_vendor_product_ids uuid[]
)
RETURNS integer
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _count integer;
BEGIN
  IF _catalog_vendor_product_ids IS NOT NULL
     AND pg_catalog.cardinality(_catalog_vendor_product_ids) = 0 THEN
    RETURN 0;
  END IF;

  WITH targets AS (
    SELECT catalog_vendor_product.id,
      catalog_vendor_product.vendor_sku,
      catalog_vendor_product.manufacturer_sku,
      catalog_vendor_product.vendor_sku_match_key,
      catalog_vendor_product.package_description,
      catalog_vendor_product.package_quantity,
      catalog_vendor_product.package_unit,
      catalog_product.name AS product_name,
      catalog_product.manufacturer,
      catalog_product.description,
      catalog_vendor.name AS vendor_name
    FROM public.catalog_vendor_products catalog_vendor_product
    JOIN public.catalog_products catalog_product
      ON catalog_product.id = catalog_vendor_product.catalog_product_id
    JOIN public.catalog_vendors catalog_vendor
      ON catalog_vendor.id = catalog_vendor_product.catalog_vendor_id
    WHERE _catalog_vendor_product_ids IS NULL
       OR catalog_vendor_product.id = ANY(_catalog_vendor_product_ids)
  ),
  specifications AS (
    SELECT effective.catalog_vendor_product_id, effective.specification
    FROM public.get_catalog_vendor_product_effective_specifications(_catalog_vendor_product_ids) effective
  ),
  built AS (
    SELECT targets.id,
      ' ' || public.catalog_search_text(targets.product_name) || ' ' AS name_text,
      ' ' || pg_catalog.btrim(pg_catalog.concat_ws(' ',
        public.catalog_search_text(pg_catalog.concat_ws(' ',
          targets.product_name,
          targets.manufacturer,
          targets.vendor_name,
          targets.description,
          targets.vendor_sku,
          targets.manufacturer_sku,
          targets.package_description,
          targets.package_quantity::text,
          targets.package_unit,
          specifications.specification)),
        pg_catalog.lower(NULLIF(targets.vendor_sku_match_key, '')),
        pg_catalog.lower(NULLIF(public.normalize_catalog_sku_match_key(targets.manufacturer_sku), ''))
      )) || ' ' AS document,
      pg_catalog.array_remove(ARRAY[
        public.normalize_catalog_sku(targets.vendor_sku),
        NULLIF(public.normalize_catalog_sku(targets.manufacturer_sku), '')
      ], NULL) AS sku_values,
      pg_catalog.array_remove(ARRAY[
        NULLIF(targets.vendor_sku_match_key, ''),
        NULLIF(public.normalize_catalog_sku_match_key(targets.manufacturer_sku), '')
      ], NULL) AS sku_keys
    FROM targets
    LEFT JOIN specifications ON specifications.catalog_vendor_product_id = targets.id
  ),
  upserted AS (
    INSERT INTO public.catalog_vendor_product_search_documents AS existing (
      catalog_vendor_product_id, name_text, document, sku_values, sku_keys, refreshed_at
    )
    SELECT built.id, built.name_text, built.document, built.sku_values, built.sku_keys, pg_catalog.now()
    FROM built
    ON CONFLICT (catalog_vendor_product_id) DO UPDATE
      SET name_text = EXCLUDED.name_text,
          document = EXCLUDED.document,
          sku_values = EXCLUDED.sku_values,
          sku_keys = EXCLUDED.sku_keys,
          refreshed_at = EXCLUDED.refreshed_at
      WHERE existing.name_text IS DISTINCT FROM EXCLUDED.name_text
         OR existing.document IS DISTINCT FROM EXCLUDED.document
         OR existing.sku_values IS DISTINCT FROM EXCLUDED.sku_values
         OR existing.sku_keys IS DISTINCT FROM EXCLUDED.sku_keys
    RETURNING existing.document
  ),
  vocabulary AS (
    INSERT INTO public.catalog_search_terms (term)
    SELECT DISTINCT word.word
    FROM upserted,
      LATERAL pg_catalog.regexp_split_to_table(pg_catalog.btrim(upserted.document), ' ') AS word(word)
    WHERE word.word ~ '^[a-z]{4,40}$'
    ON CONFLICT (term) DO NOTHING
    RETURNING 1
  )
  SELECT pg_catalog.count(*) INTO _count FROM upserted;

  RETURN _count;
END;
$$;

REVOKE ALL ON FUNCTION public.refresh_catalog_vendor_product_search_documents(uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.refresh_catalog_vendor_product_search_documents(uuid[]) FROM anon, authenticated;

COMMENT ON FUNCTION public.refresh_catalog_vendor_product_search_documents(uuid[]) IS
  'Phase 5A.10: rebuilds derived search documents (NULL = whole catalog). Internal; called by catalog triggers.';

-- Statement-level triggers: one set-based rebuild per statement, so bulk catalog imports do
-- not pay a per-row cost.
CREATE OR REPLACE FUNCTION public.tg_catalog_vendor_products_search_document()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.refresh_catalog_vendor_product_search_documents(
    ARRAY(SELECT changed.id FROM new_rows changed)
  );
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.tg_catalog_products_search_document()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.refresh_catalog_vendor_product_search_documents(
    ARRAY(
      SELECT catalog_vendor_product.id
      FROM public.catalog_vendor_products catalog_vendor_product
      WHERE catalog_vendor_product.catalog_product_id IN (SELECT changed.id FROM new_rows changed)
    )
  );
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.tg_catalog_vendors_search_document()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.refresh_catalog_vendor_product_search_documents(
    ARRAY(
      SELECT catalog_vendor_product.id
      FROM public.catalog_vendor_products catalog_vendor_product
      WHERE catalog_vendor_product.catalog_vendor_id IN (SELECT changed.id FROM new_rows changed)
    )
  );
  RETURN NULL;
END;
$$;

-- Source records decide the trusted specification; both the old and the new match count.
CREATE OR REPLACE FUNCTION public.tg_catalog_source_records_search_document()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM public.refresh_catalog_vendor_product_search_documents(
      ARRAY(SELECT DISTINCT changed.matched_catalog_vendor_product_id FROM new_rows changed
            WHERE changed.matched_catalog_vendor_product_id IS NOT NULL)
    );
  ELSE
    PERFORM public.refresh_catalog_vendor_product_search_documents(
      ARRAY(
        SELECT DISTINCT affected.id FROM (
          SELECT changed.matched_catalog_vendor_product_id AS id FROM new_rows changed
          UNION
          SELECT previous.matched_catalog_vendor_product_id FROM old_rows previous
        ) affected
        WHERE affected.id IS NOT NULL
      )
    );
  END IF;
  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.tg_catalog_vendor_products_search_document() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.tg_catalog_products_search_document() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.tg_catalog_vendors_search_document() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.tg_catalog_source_records_search_document() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER catalog_vendor_products_search_document_insert
  AFTER INSERT ON public.catalog_vendor_products
  REFERENCING NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION public.tg_catalog_vendor_products_search_document();
CREATE TRIGGER catalog_vendor_products_search_document_update
  AFTER UPDATE ON public.catalog_vendor_products
  REFERENCING NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION public.tg_catalog_vendor_products_search_document();
CREATE TRIGGER catalog_products_search_document_update
  AFTER UPDATE ON public.catalog_products
  REFERENCING NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION public.tg_catalog_products_search_document();
CREATE TRIGGER catalog_vendors_search_document_update
  AFTER UPDATE ON public.catalog_vendors
  REFERENCING NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION public.tg_catalog_vendors_search_document();
CREATE TRIGGER catalog_source_records_search_document_insert
  AFTER INSERT ON public.catalog_source_records
  REFERENCING NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION public.tg_catalog_source_records_search_document();
CREATE TRIGGER catalog_source_records_search_document_update
  AFTER UPDATE ON public.catalog_source_records
  REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION public.tg_catalog_source_records_search_document();

-- Backfill every existing catalog vendor product (no output: the SQL Editor run stays silent).
DO $backfill$
BEGIN
  PERFORM public.refresh_catalog_vendor_product_search_documents(NULL);
END
$backfill$;

-- ---------------------------------------------------------------------------------------
-- Saved Items.
-- ---------------------------------------------------------------------------------------

CREATE TABLE public.staff_saved_products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  product_id uuid,
  catalog_vendor_product_id uuid REFERENCES public.catalog_vendor_products(id) ON DELETE CASCADE,
  inventory_item_id uuid,
  identity_key text GENERATED ALWAYS AS (
    CASE
      WHEN product_id IS NOT NULL THEN 'organization-product:' || product_id::text
      WHEN catalog_vendor_product_id IS NOT NULL THEN 'catalog-vendor-product:' || catalog_vendor_product_id::text
      ELSE 'inventory:' || inventory_item_id::text
    END
  ) STORED,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  CONSTRAINT staff_saved_products_one_identity CHECK (
    num_nonnulls(product_id, catalog_vendor_product_id, inventory_item_id) = 1
  ),
  CONSTRAINT staff_saved_products_product_org_fk FOREIGN KEY (product_id, organization_id)
    REFERENCES public.products(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT staff_saved_products_inventory_org_fk FOREIGN KEY (inventory_item_id, organization_id)
    REFERENCES public.inventory_items(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT staff_saved_products_user_identity_uq UNIQUE (organization_id, user_id, identity_key)
);

COMMENT ON TABLE public.staff_saved_products IS
  'Phase 5A.10 personal Saved Items. Exactly one identity per row; one row per user, organization and identity. RPC access only.';

CREATE INDEX staff_saved_products_user_created_idx
  ON public.staff_saved_products (organization_id, user_id, created_at DESC, id DESC);

ALTER TABLE public.staff_saved_products ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.staff_saved_products FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.staff_saved_products TO service_role;

-- ---------------------------------------------------------------------------------------
-- Organization history signals (internal). Organization-level only: no requester identity
-- leaves this function. Approved = current status approved, ordered, received or completed
-- (a request denied after approval no longer counts; submitted, under review, denied and
-- cancelled never count). Purchased = a line on a posted invoice (not a credit memo).
-- ---------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.supply_request_product_history(_organization_id uuid)
RETURNS TABLE (
  signal text,
  product_id uuid,
  catalog_vendor_product_id uuid,
  inventory_item_id uuid,
  event_id uuid,
  event_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT DISTINCT 'approved'::text, item.product_id, item.catalog_vendor_product_id,
    item.inventory_item_id, request.id, request.created_at
  FROM public.supply_requests request
  JOIN public.supply_request_items item
    ON item.supply_request_id = request.id
   AND item.organization_id = request.organization_id
  WHERE request.organization_id = _organization_id
    AND request.status IN ('approved', 'ordered', 'received', 'completed')
    AND item.free_text_item IS NULL
  UNION ALL
  SELECT DISTINCT 'purchased'::text, item.product_id, NULL::uuid, NULL::uuid, invoice.id,
    COALESCE(invoice.invoice_date::timestamptz, invoice.posted_at)
  FROM public.invoices invoice
  JOIN public.invoice_items item
    ON item.invoice_id = invoice.id
   AND item.organization_id = invoice.organization_id
  WHERE invoice.organization_id = _organization_id
    AND invoice.posted_at IS NOT NULL
    AND invoice.document_type <> 'CREDIT_MEMO'
    AND item.product_id IS NOT NULL;
$$;

REVOKE ALL ON FUNCTION public.supply_request_product_history(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.supply_request_product_history(uuid) FROM anon, authenticated;

-- ---------------------------------------------------------------------------------------
-- Search.
-- ---------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.supply_request_product_search(
  _organization_id uuid,
  _query text,
  _limit integer
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
  catalog_vendor_product_id uuid,
  variant_detail text,
  unit text,
  pack_size text,
  match_tier integer,
  is_saved boolean,
  approved_request_count integer,
  last_approved_at timestamptz,
  purchase_count integer,
  last_purchased_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET plan_cache_mode = force_custom_plan
AS $$
DECLARE
  _uid uuid := auth.uid();
  _raw_query text := pg_catalog.btrim(COALESCE(_query, ''));
  _normalized_text text;
  _normalized_sku text;
  _sku_key text;
  _sku_partial boolean;
  _tokens text[];
  _patterns text[];
  _fuzzy_patterns text[];
  _phrase_pattern text;
  _first_word text;
  _last_word text;
  _corrected boolean := false;
  _index_patterns text[];
  _p1 text;
  _p2 text;
  _p3 text;
  _p4 text;
  _token text;
  _corrections text[];
  _limit_edits integer;
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
  IF pg_catalog.length(_raw_query) > 120 THEN
    RAISE EXCEPTION 'Search query cannot exceed 120 characters' USING ERRCODE = '22001';
  END IF;

  _normalized_text := public.catalog_search_text(_raw_query);
  IF pg_catalog.length(_normalized_text) < 2 THEN
    RETURN;
  END IF;
  _normalized_sku := public.normalize_catalog_sku(_raw_query);
  _sku_key := public.normalize_catalog_sku_match_key(_raw_query);
  _sku_partial := pg_catalog.length(_sku_key) >= 4 AND _sku_key ~ '[0-9]';

  SELECT pg_catalog.array_agg(token.value ORDER BY token.first_position)
  INTO _tokens
  FROM (
    SELECT split.value, pg_catalog.min(split.position) AS first_position
    FROM pg_catalog.regexp_split_to_table(_normalized_text, ' ') WITH ORDINALITY AS split(value, position)
    WHERE split.value <> ''
    GROUP BY split.value
  ) token;
  _tokens := _tokens[1:8];
  _patterns := ARRAY(SELECT public.catalog_search_token_pattern(token) FROM pg_catalog.unnest(_tokens) token);
  -- The whole query as one phrase, with the token rule's boundaries at both ends.
  _first_word := pg_catalog.split_part(_normalized_text, ' ', 1);
  _last_word := pg_catalog.regexp_replace(_normalized_text, '^.* ', '');
  _phrase_pattern :=
    CASE
      WHEN pg_catalog.length(_first_word) <= 2 THEN ' '
      WHEN _first_word ~ '^[0-9]' THEN '[^0-9/]'
      ELSE ''
    END
    || _normalized_text
    || CASE
         WHEN _last_word ~ '[0-9]$' THEN '[^0-9/]'
         WHEN pg_catalog.length(_last_word) = 1 THEN ' '
         ELSE ''
       END;

  -- Typo correction: only a letter-only word of 4+ letters that occurs nowhere in the
  -- searchable text of this organization and the global catalog.
  _fuzzy_patterns := _patterns;
  FOR _i IN 1 .. pg_catalog.cardinality(_tokens) LOOP
    _token := _tokens[_i];
    CONTINUE WHEN _token !~ '^[a-z]{4,40}$';
    -- A letter-only word "occurs" in the global catalog when it is part of a catalog word
    -- (the vocabulary holds every letter-only document word of 4+ letters). Checking the
    -- vocabulary keeps a missing word from scanning every document.
    CONTINUE WHEN EXISTS (
      SELECT 1 FROM public.catalog_search_terms terms
      WHERE pg_catalog.strpos(terms.term, _token) > 0
    );
    CONTINUE WHEN EXISTS (
      SELECT 1 FROM public.products organization_product
      WHERE organization_product.organization_id = _organization_id
        AND organization_product.active AND organization_product.staff_requestable
        AND (' ' || public.catalog_search_text(pg_catalog.concat_ws(' ',
              organization_product.name, organization_product.manufacturer, organization_product.description,
              organization_product.pack_size, organization_product.unit_of_measure)) || ' ') ~ _patterns[_i]
    );
    CONTINUE WHEN EXISTS (
      SELECT 1 FROM public.inventory_items inventory
      WHERE inventory.organization_id = _organization_id AND inventory.active
        AND (' ' || public.catalog_search_text(pg_catalog.concat_ws(' ',
              inventory.name, inventory.manufacturer, inventory.vendor_name, inventory.description,
              inventory.category, inventory.unit)) || ' ') ~ _patterns[_i]
    );
    CONTINUE WHEN EXISTS (
      SELECT 1 FROM public.product_aliases alias
      WHERE alias.organization_id = _organization_id
        AND (' ' || public.catalog_search_text(alias.alias) || ' ') ~ _patterns[_i]
    );

    _limit_edits := CASE WHEN pg_catalog.length(_token) >= 8 THEN 2 ELSE 1 END;
    SELECT pg_catalog.array_agg(candidate.term ORDER BY candidate.distance, candidate.term)
    INTO _corrections
    FROM (
      SELECT vocabulary.term,
        public.catalog_search_edit_distance(_token, vocabulary.term, _limit_edits) AS distance
      FROM (
        SELECT terms.term::text AS term
        FROM public.catalog_search_terms terms
        WHERE terms.term >= pg_catalog.left(_token, 1) COLLATE "C"
          AND terms.term < pg_catalog.chr(pg_catalog.ascii(pg_catalog.left(_token, 1)) + 1) COLLATE "C"
          AND pg_catalog.length(terms.term) BETWEEN pg_catalog.length(_token) - _limit_edits
                                                AND pg_catalog.length(_token) + _limit_edits
        UNION
        SELECT local_word.word
        FROM (
          SELECT pg_catalog.regexp_split_to_table(public.catalog_search_text(pg_catalog.concat_ws(' ',
                   organization_product.name, organization_product.manufacturer)), ' ') AS word
          FROM public.products organization_product
          WHERE organization_product.organization_id = _organization_id
            AND organization_product.active AND organization_product.staff_requestable
          UNION
          SELECT pg_catalog.regexp_split_to_table(public.catalog_search_text(pg_catalog.concat_ws(' ',
                   inventory.name, inventory.manufacturer)), ' ')
          FROM public.inventory_items inventory
          WHERE inventory.organization_id = _organization_id AND inventory.active
          UNION
          SELECT pg_catalog.regexp_split_to_table(public.catalog_search_text(alias.alias), ' ')
          FROM public.product_aliases alias
          WHERE alias.organization_id = _organization_id
        ) local_word
        WHERE local_word.word ~ '^[a-z]{4,40}$'
          AND pg_catalog.left(local_word.word, 1) = pg_catalog.left(_token, 1)
          AND pg_catalog.length(local_word.word) BETWEEN pg_catalog.length(_token) - _limit_edits
                                                     AND pg_catalog.length(_token) + _limit_edits
      ) vocabulary
      WHERE vocabulary.term <> _token
    ) candidate
    WHERE candidate.distance <= _limit_edits;

    IF COALESCE(pg_catalog.cardinality(_corrections), 0) > 0 THEN
      _corrections := _corrections[1:3];
      _fuzzy_patterns[_i] := '(' || pg_catalog.array_to_string(_corrections, '|') || ')';
      _corrected := true;
    END IF;
  END LOOP;

  -- Index probes: the (up to) four longest token patterns. Every token is still checked
  -- when the candidates are scored.
  _index_patterns := ARRAY(
    SELECT pattern.value
    FROM ROWS FROM (pg_catalog.unnest(_fuzzy_patterns), pg_catalog.unnest(_tokens)) WITH ORDINALITY AS pattern(value, token, position)
    ORDER BY pg_catalog.length(pattern.token) DESC, pattern.position
    LIMIT 4
  );
  _p1 := _index_patterns[1];
  _p2 := _index_patterns[2];
  _p3 := _index_patterns[3];
  _p4 := _index_patterns[4];

  RETURN QUERY
  WITH organization_aliases AS MATERIALIZED (
    SELECT alias.product_id,
      pg_catalog.string_agg(' ' || public.catalog_search_text(alias.alias) || ' ', '|'
        ORDER BY alias.normalized_alias) AS alias_text
    FROM public.product_aliases alias
    WHERE alias.organization_id = _organization_id
    GROUP BY alias.product_id
  ),
  organization_adoptions AS MATERIALIZED (
    SELECT
      organization_vendor_product.id AS vendor_product_id,
      organization_vendor_product.product_id,
      organization_vendor_product.catalog_vendor_product_id,
      organization_vendor_product.vendor_sku,
      organization_vendor_product.manufacturer_sku,
      organization_vendor_product.package_size,
      organization_vendor_product.unit_of_measure AS vendor_unit,
      organization_product.name AS product_name,
      organization_product.manufacturer,
      organization_product.description,
      organization_product.pack_size,
      organization_product.unit_of_measure,
      organization_vendor.name AS vendor_name,
      inventory.id AS inventory_item_id,
      ' ' || public.catalog_search_text(organization_product.name) || ' ' AS name_text,
      pg_catalog.array_remove(ARRAY[
        public.normalize_catalog_sku(organization_vendor_product.vendor_sku),
        public.normalize_catalog_sku(organization_vendor_product.manufacturer_sku)
      ], '') AS skus,
      pg_catalog.array_remove(ARRAY[
        public.normalize_catalog_sku_match_key(organization_vendor_product.vendor_sku),
        public.normalize_catalog_sku_match_key(organization_vendor_product.manufacturer_sku)
      ], '') AS sku_keys,
      public.catalog_search_text(pg_catalog.concat_ws(' ',
        organization_product.name,
        organization_product.manufacturer,
        organization_vendor.name,
        organization_product.description,
        organization_vendor_product.vendor_sku,
        organization_vendor_product.manufacturer_sku,
        organization_vendor_product.package_size,
        organization_product.pack_size,
        organization_product.unit_of_measure,
        organization_vendor_product.unit_of_measure)) || ' ' AS search_text
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
  global_hits AS MATERIALIZED (
    SELECT doc.catalog_vendor_product_id
    FROM public.catalog_vendor_product_search_documents doc
    WHERE doc.document ~ _p1
      AND (_p2 IS NULL OR doc.document ~ _p2)
      AND (_p3 IS NULL OR doc.document ~ _p3)
      AND (_p4 IS NULL OR doc.document ~ _p4)
    UNION
    -- Exact SKUs through the existing per-vendor unique and match-key indexes.
    SELECT catalog_vendor_product.id
    FROM public.catalog_vendors catalog_vendor
    JOIN public.catalog_vendor_products catalog_vendor_product
      ON catalog_vendor_product.catalog_vendor_id = catalog_vendor.id
     AND catalog_vendor_product.normalized_vendor_sku = _normalized_sku
    UNION
    SELECT catalog_vendor_product.id
    FROM public.catalog_vendors catalog_vendor
    JOIN public.catalog_vendor_products catalog_vendor_product
      ON catalog_vendor_product.catalog_vendor_id = catalog_vendor.id
     AND catalog_vendor_product.vendor_sku_match_key = _sku_key
    WHERE _sku_key <> ''
    UNION
    SELECT catalog_vendor_product.id
    FROM public.catalog_vendor_products catalog_vendor_product
    WHERE catalog_vendor_product.normalized_manufacturer_sku = _normalized_sku
    UNION
    SELECT doc.catalog_vendor_product_id
    FROM public.catalog_vendor_product_search_documents doc
    WHERE _sku_partial AND doc.document ~ pg_catalog.lower(_sku_key)
    UNION
    SELECT adoption.catalog_vendor_product_id FROM organization_adoptions adoption
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
        WHEN 'verified' THEN pg_catalog.concat_ws(
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
      COALESCE(adoption.description, catalog_product.description) AS description,
      COALESCE(adoption.unit_of_measure, adoption.vendor_unit) AS unit,
      COALESCE(NULLIF(pg_catalog.btrim(adoption.package_size), ''), NULLIF(pg_catalog.btrim(adoption.pack_size), '')) AS pack_size,
      COALESCE(adoption.skus, ARRAY[]::text[]) AS organization_skus,
      COALESCE(adoption.sku_keys, ARRAY[]::text[]) AS organization_sku_keys,
      doc.sku_values AS global_skus,
      doc.sku_keys AS global_sku_keys,
      CASE WHEN adoption.name_text IS NULL THEN ARRAY[doc.name_text]
           ELSE ARRAY[adoption.name_text, doc.name_text] END AS names,
      organization_alias.alias_text,
      doc.document
        || COALESCE(adoption.search_text, '')
        || COALESCE(pg_catalog.replace(organization_alias.alias_text, '|', ''), '') AS search_text,
      CASE
        WHEN adoption.inventory_item_id IS NOT NULL THEN 0
        WHEN adoption.vendor_product_id IS NOT NULL THEN 1
        ELSE 3
      END AS source_priority
    FROM global_hits hit
    JOIN public.catalog_vendor_products catalog_vendor_product
      ON catalog_vendor_product.id = hit.catalog_vendor_product_id
     AND catalog_vendor_product.active = true
     AND catalog_vendor_product.discontinued = false
    JOIN public.catalog_vendor_product_search_documents doc
      ON doc.catalog_vendor_product_id = catalog_vendor_product.id
    JOIN public.catalog_products catalog_product
      ON catalog_product.id = catalog_vendor_product.catalog_product_id
     AND catalog_product.active = true
    JOIN public.catalog_vendors catalog_vendor
      ON catalog_vendor.id = catalog_vendor_product.catalog_vendor_id
     AND catalog_vendor.active = true
    LEFT JOIN organization_adoptions adoption
      ON adoption.catalog_vendor_product_id = catalog_vendor_product.id
    LEFT JOIN organization_aliases organization_alias
      ON organization_alias.product_id = adoption.product_id
  ),
  local_vendor_candidates AS (
    SELECT
      'organization-product:' || organization_product.id::text AS identity_key,
      CASE WHEN inventory.id IS NOT NULL THEN 'inventory' ELSE 'organization_catalog' END AS identity_source,
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
      organization_product.description,
      COALESCE(organization_product.unit_of_measure, organization_vendor_product.unit_of_measure) AS unit,
      COALESCE(NULLIF(pg_catalog.btrim(organization_vendor_product.package_size), ''), NULLIF(pg_catalog.btrim(organization_product.pack_size), '')) AS pack_size,
      pg_catalog.array_remove(ARRAY[
        public.normalize_catalog_sku(organization_vendor_product.vendor_sku),
        public.normalize_catalog_sku(organization_vendor_product.manufacturer_sku)
      ], '') AS organization_skus,
      pg_catalog.array_remove(ARRAY[
        public.normalize_catalog_sku_match_key(organization_vendor_product.vendor_sku),
        public.normalize_catalog_sku_match_key(organization_vendor_product.manufacturer_sku)
      ], '') AS organization_sku_keys,
      ARRAY[]::text[] AS global_skus,
      ARRAY[]::text[] AS global_sku_keys,
      ARRAY[' ' || public.catalog_search_text(organization_product.name) || ' '] AS names,
      organization_alias.alias_text,
      ' ' || public.catalog_search_text(pg_catalog.concat_ws(' ',
        organization_product.name,
        organization_product.manufacturer,
        organization_product.description,
        organization_product.pack_size,
        organization_product.vendor_item_number,
        organization_product.internal_item_code,
        organization_product.unit_of_measure,
        organization_vendor.name,
        organization_vendor_product.vendor_sku,
        organization_vendor_product.manufacturer_sku,
        organization_vendor_product.package_size,
        organization_vendor_product.unit_of_measure)) || ' '
        || COALESCE(pg_catalog.replace(organization_alias.alias_text, '|', ''), '') AS search_text,
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
    LEFT JOIN organization_aliases organization_alias
      ON organization_alias.product_id = organization_product.id
    WHERE organization_vendor_product.organization_id = _organization_id
      AND organization_vendor_product.active = true
      AND organization_vendor_product.catalog_vendor_product_id IS NULL
  ),
  local_product_candidates AS (
    SELECT
      'organization-product:' || organization_product.id::text AS identity_key,
      CASE WHEN inventory.id IS NOT NULL THEN 'inventory' ELSE 'organization_product' END AS identity_source,
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
      organization_product.description,
      organization_product.unit_of_measure AS unit,
      NULLIF(pg_catalog.btrim(organization_product.pack_size), '') AS pack_size,
      pg_catalog.array_remove(ARRAY[
        public.normalize_catalog_sku(organization_product.vendor_item_number),
        public.normalize_catalog_sku(organization_product.internal_item_code)
      ], '') AS organization_skus,
      pg_catalog.array_remove(ARRAY[
        public.normalize_catalog_sku_match_key(organization_product.vendor_item_number),
        public.normalize_catalog_sku_match_key(organization_product.internal_item_code)
      ], '') AS organization_sku_keys,
      ARRAY[]::text[] AS global_skus,
      ARRAY[]::text[] AS global_sku_keys,
      ARRAY[' ' || public.catalog_search_text(organization_product.name) || ' '] AS names,
      organization_alias.alias_text,
      ' ' || public.catalog_search_text(pg_catalog.concat_ws(' ',
        organization_product.name,
        organization_product.manufacturer,
        organization_product.description,
        organization_product.pack_size,
        organization_product.vendor_item_number,
        organization_product.internal_item_code,
        organization_product.unit_of_measure)) || ' '
        || COALESCE(pg_catalog.replace(organization_alias.alias_text, '|', ''), '') AS search_text,
      CASE WHEN inventory.id IS NOT NULL THEN 0 ELSE 2 END AS source_priority
    FROM public.products organization_product
    LEFT JOIN public.inventory_items inventory
      ON inventory.organization_id = organization_product.organization_id
     AND inventory.product_id = organization_product.id
     AND inventory.active = true
    LEFT JOIN organization_aliases organization_alias
      ON organization_alias.product_id = organization_product.id
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
      inventory.description,
      inventory.unit,
      NULL::text AS pack_size,
      pg_catalog.array_remove(ARRAY[public.normalize_catalog_sku(inventory.sku)], '') AS organization_skus,
      pg_catalog.array_remove(ARRAY[public.normalize_catalog_sku_match_key(inventory.sku)], '') AS organization_sku_keys,
      ARRAY[]::text[] AS global_skus,
      ARRAY[]::text[] AS global_sku_keys,
      ARRAY[' ' || public.catalog_search_text(inventory.name) || ' '] AS names,
      NULL::text AS alias_text,
      ' ' || public.catalog_search_text(pg_catalog.concat_ws(' ',
        inventory.name,
        inventory.manufacturer,
        inventory.vendor_name,
        inventory.sku,
        inventory.description,
        inventory.category,
        inventory.unit)) || ' ' AS search_text,
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
  scored AS MATERIALIZED (
    SELECT
      candidate.*,
      CASE
        WHEN _normalized_sku = ANY(candidate.organization_skus)
             OR (pg_catalog.length(_sku_key) >= 3 AND _sku_key = ANY(candidate.organization_sku_keys)) THEN 0
        WHEN _normalized_sku = ANY(candidate.global_skus)
             OR (pg_catalog.length(_sku_key) >= 3 AND _sku_key = ANY(candidate.global_sku_keys)) THEN 1
        WHEN EXISTS (SELECT 1 FROM pg_catalog.unnest(candidate.names) name WHERE name = ' ' || _normalized_text || ' ')
             OR pg_catalog.strpos('|' || COALESCE(candidate.alias_text, '') || '|', '| ' || _normalized_text || ' |') > 0 THEN 2
        WHEN _sku_partial AND EXISTS (
               SELECT 1 FROM pg_catalog.unnest(candidate.organization_sku_keys || candidate.global_sku_keys) sku_key
               WHERE pg_catalog.strpos(sku_key, _sku_key) > 0
             ) THEN 3
        WHEN EXISTS (SELECT 1 FROM pg_catalog.unnest(candidate.names) name WHERE name ~ _phrase_pattern)
             OR COALESCE(candidate.alias_text, '') ~ _phrase_pattern THEN 4
        WHEN EXISTS (
               SELECT 1 FROM pg_catalog.unnest(candidate.names || COALESCE(pg_catalog.string_to_array(candidate.alias_text, '|'), ARRAY[]::text[])) name
               WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.unnest(_patterns) pattern WHERE name !~ pattern)
             ) THEN 5
        WHEN NOT EXISTS (SELECT 1 FROM pg_catalog.unnest(_patterns) pattern WHERE candidate.search_text !~ pattern) THEN 6
        WHEN _corrected
             AND NOT EXISTS (SELECT 1 FROM pg_catalog.unnest(_fuzzy_patterns) pattern WHERE candidate.search_text !~ pattern) THEN 7
        ELSE 99
      END AS match_rank
    FROM candidates candidate
  ),
  deduplicated AS MATERIALIZED (
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
          pg_catalog.lower(scored.product_name),
          COALESCE(scored.vendor_sku, ''),
          scored.identity_key
      ) AS identity_rank
    FROM scored
    WHERE scored.match_rank < 99
  ),
  matched AS MATERIALIZED (
    SELECT * FROM deduplicated WHERE deduplicated.identity_rank = 1
  ),
  history AS MATERIALIZED (
    SELECT * FROM public.supply_request_product_history(_organization_id)
  ),
  signal_links AS (
    SELECT matched.identity_key, history.signal, history.event_id, history.event_at
    FROM matched JOIN history ON history.product_id = matched.product_id
    UNION
    SELECT matched.identity_key, history.signal, history.event_id, history.event_at
    FROM matched JOIN history ON history.catalog_vendor_product_id = matched.catalog_vendor_product_id
    UNION
    SELECT matched.identity_key, history.signal, history.event_id, history.event_at
    FROM matched JOIN history ON history.inventory_item_id = matched.inventory_item_id
  ),
  signals AS (
    SELECT signal_links.identity_key,
      pg_catalog.count(DISTINCT signal_links.event_id) FILTER (WHERE signal_links.signal = 'approved')::integer AS approved_count,
      pg_catalog.max(signal_links.event_at) FILTER (WHERE signal_links.signal = 'approved') AS last_approved,
      pg_catalog.count(DISTINCT signal_links.event_id) FILTER (WHERE signal_links.signal = 'purchased')::integer AS purchase_count,
      pg_catalog.max(signal_links.event_at) FILTER (WHERE signal_links.signal = 'purchased') AS last_purchased
    FROM signal_links
    GROUP BY signal_links.identity_key
  ),
  saved AS (
    SELECT DISTINCT matched.identity_key
    FROM matched
    JOIN public.staff_saved_products saved_product
      ON saved_product.organization_id = _organization_id
     AND saved_product.user_id = _uid
     AND (saved_product.product_id = matched.product_id
          OR saved_product.catalog_vendor_product_id = matched.catalog_vendor_product_id
          OR saved_product.inventory_item_id = matched.inventory_item_id)
  )
  SELECT
    matched.identity_key,
    matched.identity_source,
    matched.product_name,
    matched.manufacturer,
    matched.vendor_name,
    matched.vendor_sku,
    matched.package_display,
    matched.package_status,
    matched.inventory_item_id,
    matched.product_id,
    matched.vendor_product_id,
    matched.catalog_vendor_product_id,
    CASE
      -- A short description is the variant (size, color, sterility); one the name already
      -- says is not repeated.
      WHEN pg_catalog.length(pg_catalog.btrim(matched.description)) BETWEEN 1 AND 80
       AND pg_catalog.strpos(' ' || public.catalog_search_text(matched.product_name) || ' ',
                             ' ' || public.catalog_search_text(matched.description) || ' ') = 0
        THEN pg_catalog.btrim(matched.description)
    END,
    NULLIF(pg_catalog.btrim(matched.unit), ''),
    matched.pack_size,
    matched.match_rank,
    saved.identity_key IS NOT NULL,
    COALESCE(signals.approved_count, 0),
    signals.last_approved,
    COALESCE(signals.purchase_count, 0),
    signals.last_purchased
  FROM matched
  LEFT JOIN signals ON signals.identity_key = matched.identity_key
  LEFT JOIN saved ON saved.identity_key = matched.identity_key
  ORDER BY
    matched.match_rank,
    (saved.identity_key IS NOT NULL) DESC,
    COALESCE(signals.approved_count, 0) DESC,
    COALESCE(signals.purchase_count, 0) DESC,
    matched.source_priority,
    GREATEST(signals.last_approved, signals.last_purchased) DESC NULLS LAST,
    pg_catalog.lower(matched.product_name),
    COALESCE(matched.vendor_name, ''),
    COALESCE(matched.vendor_sku, ''),
    matched.identity_key
  LIMIT _bounded_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.supply_request_product_search(uuid, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.supply_request_product_search(uuid, text, integer) FROM anon, authenticated;

COMMENT ON FUNCTION public.supply_request_product_search(uuid, text, integer) IS
  'Phase 5A.10 internal search: deterministic relevance tiers first, then Saved and organization history inside a tier. See the migration header.';

-- The Phase 5A.7 / 5A.8B contract, unchanged in shape: same arguments, same 12 columns.
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
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT search.result_key, search.identity_source, search.product_name, search.manufacturer,
    search.vendor_name, search.vendor_sku, search.package_display, search.package_status,
    search.inventory_item_id, search.product_id, search.vendor_product_id,
    search.catalog_vendor_product_id
  FROM public.supply_request_product_search(_organization_id, _query, _limit) search;
$$;

REVOKE ALL ON FUNCTION public.search_supply_request_products(uuid, text, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.search_supply_request_products(uuid, text, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.search_supply_request_products(uuid, text, integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.search_supply_request_products_with_signals(
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
  catalog_vendor_product_id uuid,
  variant_detail text,
  unit text,
  pack_size text,
  match_tier integer,
  is_saved boolean,
  approved_request_count integer,
  last_approved_at timestamptz,
  purchase_count integer,
  last_purchased_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT * FROM public.supply_request_product_search(_organization_id, _query, _limit);
$$;

REVOKE ALL ON FUNCTION public.search_supply_request_products_with_signals(uuid, text, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.search_supply_request_products_with_signals(uuid, text, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.search_supply_request_products_with_signals(uuid, text, integer) TO authenticated;

COMMENT ON FUNCTION public.search_supply_request_products_with_signals(uuid, text, integer) IS
  'Phase 5A.10 staff search with explanation columns (tier, Saved, organization approved/purchase history). Active members only.';

-- ---------------------------------------------------------------------------------------
-- Identity resolution for discovery sections: the current display row for each requested
-- identity, under exactly the eligibility rules of search. Internal.
-- ---------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.supply_request_product_identities(
  _organization_id uuid,
  _product_ids uuid[],
  _catalog_vendor_product_ids uuid[],
  _inventory_item_ids uuid[]
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
  catalog_vendor_product_id uuid,
  variant_detail text,
  unit text,
  pack_size text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH requested_catalog AS (
    -- A catalog identity is shown through its organization product once adopted.
    SELECT catalog_vendor_product_id FROM pg_catalog.unnest(COALESCE(_catalog_vendor_product_ids, ARRAY[]::uuid[])) catalog_vendor_product_id
    UNION
    SELECT vendor_product.catalog_vendor_product_id
    FROM public.vendor_products vendor_product
    WHERE vendor_product.organization_id = _organization_id
      AND vendor_product.active = true
      AND vendor_product.product_id = ANY(COALESCE(_product_ids, ARRAY[]::uuid[]))
      AND vendor_product.catalog_vendor_product_id IS NOT NULL
  ),
  adoptions AS (
    SELECT
      organization_vendor_product.id AS vendor_product_id,
      organization_vendor_product.product_id,
      organization_vendor_product.catalog_vendor_product_id,
      organization_vendor_product.package_size,
      organization_vendor_product.unit_of_measure AS vendor_unit,
      organization_product.name AS product_name,
      organization_product.manufacturer,
      organization_product.description,
      organization_product.pack_size,
      organization_product.unit_of_measure,
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
      AND organization_vendor_product.catalog_vendor_product_id IN (SELECT catalog_vendor_product_id FROM requested_catalog)
  ),
  candidates AS (
    SELECT
      CASE WHEN adoption.product_id IS NOT NULL
        THEN 'organization-product:' || adoption.product_id::text
        ELSE 'catalog-vendor-product:' || catalog_vendor_product.id::text END AS identity_key,
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
        WHEN 'verified' THEN pg_catalog.concat_ws(' ', catalog_vendor_product.package_quantity::text, catalog_vendor_product.package_unit)
        WHEN 'source_only' THEN COALESCE(catalog_vendor_product.package_description, 'Source package text unavailable')
        ELSE 'Unknown'
      END AS package_display,
      catalog_vendor_product.package_status,
      adoption.inventory_item_id,
      adoption.product_id,
      adoption.vendor_product_id,
      catalog_vendor_product.id AS catalog_vendor_product_id,
      COALESCE(adoption.description, catalog_product.description) AS description,
      COALESCE(adoption.unit_of_measure, adoption.vendor_unit) AS unit,
      COALESCE(NULLIF(pg_catalog.btrim(adoption.package_size), ''), NULLIF(pg_catalog.btrim(adoption.pack_size), '')) AS pack_size,
      CASE
        WHEN adoption.inventory_item_id IS NOT NULL THEN 0
        WHEN adoption.vendor_product_id IS NOT NULL THEN 1
        ELSE 3
      END AS source_priority
    FROM requested_catalog requested
    JOIN public.catalog_vendor_products catalog_vendor_product
      ON catalog_vendor_product.id = requested.catalog_vendor_product_id
     AND catalog_vendor_product.active = true
     AND catalog_vendor_product.discontinued = false
    JOIN public.catalog_products catalog_product
      ON catalog_product.id = catalog_vendor_product.catalog_product_id
     AND catalog_product.active = true
    JOIN public.catalog_vendors catalog_vendor
      ON catalog_vendor.id = catalog_vendor_product.catalog_vendor_id
     AND catalog_vendor.active = true
    LEFT JOIN adoptions adoption
      ON adoption.catalog_vendor_product_id = catalog_vendor_product.id
    UNION ALL
    SELECT
      'organization-product:' || organization_product.id::text,
      CASE WHEN inventory.id IS NOT NULL THEN 'inventory'
           WHEN organization_vendor_product.id IS NOT NULL THEN 'organization_catalog'
           ELSE 'organization_product' END,
      organization_product.name,
      organization_product.manufacturer,
      organization_vendor.name,
      organization_vendor_product.vendor_sku,
      'Unknown'::text,
      'unknown'::text,
      inventory.id,
      organization_product.id,
      organization_vendor_product.id,
      NULL::uuid,
      organization_product.description,
      COALESCE(organization_product.unit_of_measure, organization_vendor_product.unit_of_measure),
      COALESCE(NULLIF(pg_catalog.btrim(organization_vendor_product.package_size), ''), NULLIF(pg_catalog.btrim(organization_product.pack_size), '')),
      CASE WHEN inventory.id IS NOT NULL THEN 0
           WHEN organization_vendor_product.id IS NOT NULL THEN 1
           ELSE 2 END
    FROM public.products organization_product
    LEFT JOIN public.vendor_products organization_vendor_product
      ON organization_vendor_product.organization_id = organization_product.organization_id
     AND organization_vendor_product.product_id = organization_product.id
     AND organization_vendor_product.active = true
     AND organization_vendor_product.catalog_vendor_product_id IS NULL
     AND EXISTS (
       SELECT 1 FROM public.vendors organization_vendor_check
       WHERE organization_vendor_check.id = organization_vendor_product.vendor_id
         AND organization_vendor_check.organization_id = organization_vendor_product.organization_id
         AND organization_vendor_check.active = true
     )
    LEFT JOIN public.vendors organization_vendor
      ON organization_vendor.id = organization_vendor_product.vendor_id
     AND organization_vendor.organization_id = organization_vendor_product.organization_id
    LEFT JOIN public.inventory_items inventory
      ON inventory.organization_id = organization_product.organization_id
     AND inventory.product_id = organization_product.id
     AND inventory.active = true
    WHERE organization_product.organization_id = _organization_id
      AND organization_product.active = true
      AND organization_product.staff_requestable = true
      AND (
        organization_product.id = ANY(COALESCE(_product_ids, ARRAY[]::uuid[]))
        OR inventory.id = ANY(COALESCE(_inventory_item_ids, ARRAY[]::uuid[]))
      )
    UNION ALL
    SELECT
      'inventory:' || inventory.id::text,
      'inventory'::text,
      inventory.name,
      inventory.manufacturer,
      inventory.vendor_name,
      inventory.sku,
      'Unknown'::text,
      'unknown'::text,
      inventory.id,
      NULL::uuid,
      NULL::uuid,
      NULL::uuid,
      inventory.description,
      inventory.unit,
      NULL::text,
      0
    FROM public.inventory_items inventory
    WHERE inventory.organization_id = _organization_id
      AND inventory.active = true
      AND inventory.product_id IS NULL
      AND inventory.id = ANY(COALESCE(_inventory_item_ids, ARRAY[]::uuid[]))
  ),
  ranked AS (
    SELECT candidates.*,
      pg_catalog.row_number() OVER (
        PARTITION BY candidates.identity_key
        ORDER BY candidates.source_priority,
          candidates.catalog_vendor_product_id NULLS LAST,
          candidates.vendor_product_id NULLS LAST,
          candidates.inventory_item_id NULLS LAST,
          COALESCE(candidates.vendor_sku, '')
      ) AS identity_rank
    FROM candidates
  )
  SELECT ranked.identity_key, ranked.identity_source, ranked.product_name, ranked.manufacturer,
    ranked.vendor_name, ranked.vendor_sku, ranked.package_display, ranked.package_status,
    ranked.inventory_item_id, ranked.product_id, ranked.vendor_product_id,
    ranked.catalog_vendor_product_id,
    CASE
      -- A short description is the variant (size, color, sterility); one the name already
      -- says is not repeated.
      WHEN pg_catalog.length(pg_catalog.btrim(ranked.description)) BETWEEN 1 AND 80
       AND pg_catalog.strpos(' ' || public.catalog_search_text(ranked.product_name) || ' ',
                             ' ' || public.catalog_search_text(ranked.description) || ' ') = 0
        THEN pg_catalog.btrim(ranked.description)
    END,
    NULLIF(pg_catalog.btrim(ranked.unit), ''),
    ranked.pack_size
  FROM ranked
  WHERE ranked.identity_rank = 1;
$$;

REVOKE ALL ON FUNCTION public.supply_request_product_identities(uuid, uuid[], uuid[], uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.supply_request_product_identities(uuid, uuid[], uuid[], uuid[]) FROM anon, authenticated;

-- ---------------------------------------------------------------------------------------
-- Discovery: what to show before anything is typed.
--   saved      the caller's own Saved Items that are still requestable, newest first
--   frequent   approved in 2+ organization requests, most requests first
--   purchased  on posted invoices, most recent purchase first
-- A product appears once, in the first section that holds it.
-- ---------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_staff_product_discovery(
  _organization_id uuid,
  _limit integer DEFAULT 6
)
RETURNS TABLE (
  section text,
  section_rank integer,
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
  catalog_vendor_product_id uuid,
  variant_detail text,
  unit text,
  pack_size text,
  is_saved boolean,
  approved_request_count integer,
  last_approved_at timestamptz,
  purchase_count integer,
  last_purchased_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid uuid := auth.uid();
  _bounded_limit integer := LEAST(GREATEST(COALESCE(_limit, 6), 1), 20);
BEGIN
  IF _uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;
  IF _organization_id IS NULL THEN
    RAISE EXCEPTION 'organization_id is required' USING ERRCODE = '22004';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.organization_memberships membership
    WHERE membership.organization_id = _organization_id
      AND membership.user_id = _uid
      AND membership.active = true
  ) THEN
    RAISE EXCEPTION 'Not a member of this organization' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH history AS MATERIALIZED (
    SELECT * FROM public.supply_request_product_history(_organization_id)
  ),
  saved_rows AS MATERIALIZED (
    SELECT saved_product.product_id, saved_product.catalog_vendor_product_id,
      saved_product.inventory_item_id, saved_product.created_at, saved_product.id
    FROM public.staff_saved_products saved_product
    WHERE saved_product.organization_id = _organization_id
      AND saved_product.user_id = _uid
    ORDER BY saved_product.created_at DESC, saved_product.id DESC
    LIMIT 200
  ),
  -- The identities history and saved items point at; history lines are keyed by their
  -- most specific identity (product, then catalog product, then inventory item).
  history_keys AS (
    SELECT history.signal,
      CASE
        WHEN history.product_id IS NOT NULL THEN 'p:' || history.product_id::text
        WHEN history.catalog_vendor_product_id IS NOT NULL THEN 'c:' || history.catalog_vendor_product_id::text
        ELSE 'i:' || history.inventory_item_id::text
      END AS line_key,
      history.product_id, history.catalog_vendor_product_id, history.inventory_item_id,
      history.event_id, history.event_at
    FROM history
    WHERE COALESCE(history.product_id, history.catalog_vendor_product_id, history.inventory_item_id) IS NOT NULL
  ),
  top_lines AS (
    -- Bounded before identities are resolved: a generous candidate pool per signal.
    SELECT ranked.* FROM (
      SELECT history_keys.signal, history_keys.line_key,
        pg_catalog.min(history_keys.product_id::text)::uuid AS product_id,
        pg_catalog.min(history_keys.catalog_vendor_product_id::text)::uuid AS catalog_vendor_product_id,
        pg_catalog.min(history_keys.inventory_item_id::text)::uuid AS inventory_item_id,
        pg_catalog.count(DISTINCT history_keys.event_id) AS event_count,
        pg_catalog.max(history_keys.event_at) AS last_event,
        pg_catalog.row_number() OVER (
          PARTITION BY history_keys.signal
          ORDER BY pg_catalog.count(DISTINCT history_keys.event_id) DESC,
            pg_catalog.max(history_keys.event_at) DESC, history_keys.line_key
        ) AS signal_rank
      FROM history_keys
      GROUP BY history_keys.signal, history_keys.line_key
    ) ranked
    WHERE ranked.signal_rank <= 100
  ),
  resolved AS MATERIALIZED (
    SELECT * FROM public.supply_request_product_identities(
      _organization_id,
      ARRAY(SELECT DISTINCT ids.product_id FROM (
        SELECT saved_rows.product_id FROM saved_rows
        UNION ALL SELECT top_lines.product_id FROM top_lines) ids WHERE ids.product_id IS NOT NULL),
      ARRAY(SELECT DISTINCT ids.catalog_vendor_product_id FROM (
        SELECT saved_rows.catalog_vendor_product_id FROM saved_rows
        UNION ALL SELECT top_lines.catalog_vendor_product_id FROM top_lines) ids WHERE ids.catalog_vendor_product_id IS NOT NULL),
      ARRAY(SELECT DISTINCT ids.inventory_item_id FROM (
        SELECT saved_rows.inventory_item_id FROM saved_rows
        UNION ALL SELECT top_lines.inventory_item_id FROM top_lines) ids WHERE ids.inventory_item_id IS NOT NULL)
    )
  ),
  signal_links AS (
    SELECT resolved.result_key, history.signal, history.event_id, history.event_at
    FROM resolved JOIN history ON history.product_id = resolved.product_id
    UNION
    SELECT resolved.result_key, history.signal, history.event_id, history.event_at
    FROM resolved JOIN history ON history.catalog_vendor_product_id = resolved.catalog_vendor_product_id
    UNION
    SELECT resolved.result_key, history.signal, history.event_id, history.event_at
    FROM resolved JOIN history ON history.inventory_item_id = resolved.inventory_item_id
  ),
  signals AS (
    SELECT signal_links.result_key,
      pg_catalog.count(DISTINCT signal_links.event_id) FILTER (WHERE signal_links.signal = 'approved')::integer AS approved_count,
      pg_catalog.max(signal_links.event_at) FILTER (WHERE signal_links.signal = 'approved') AS last_approved,
      pg_catalog.count(DISTINCT signal_links.event_id) FILTER (WHERE signal_links.signal = 'purchased')::integer AS purchase_count,
      pg_catalog.max(signal_links.event_at) FILTER (WHERE signal_links.signal = 'purchased') AS last_purchased
    FROM signal_links
    GROUP BY signal_links.result_key
  ),
  saved_keys AS (
    SELECT resolved.result_key, pg_catalog.max(saved_rows.created_at) AS saved_at
    FROM resolved
    JOIN saved_rows
      ON saved_rows.product_id = resolved.product_id
      OR saved_rows.catalog_vendor_product_id = resolved.catalog_vendor_product_id
      OR saved_rows.inventory_item_id = resolved.inventory_item_id
    GROUP BY resolved.result_key
  ),
  placed AS (
    SELECT resolved.*,
      saved_keys.saved_at,
      COALESCE(signals.approved_count, 0) AS approved_count,
      signals.last_approved,
      COALESCE(signals.purchase_count, 0) AS purchase_count,
      signals.last_purchased,
      CASE
        WHEN saved_keys.result_key IS NOT NULL THEN 'saved'
        WHEN COALESCE(signals.approved_count, 0) >= 2 THEN 'frequent'
        WHEN COALESCE(signals.purchase_count, 0) >= 1 THEN 'purchased'
      END AS section
    FROM resolved
    LEFT JOIN signals ON signals.result_key = resolved.result_key
    LEFT JOIN saved_keys ON saved_keys.result_key = resolved.result_key
  ),
  ordered AS (
    SELECT placed.*,
      pg_catalog.row_number() OVER (
        PARTITION BY placed.section
        ORDER BY
          CASE WHEN placed.section = 'saved' THEN placed.saved_at END DESC,
          CASE WHEN placed.section = 'frequent' THEN placed.approved_count END DESC,
          CASE WHEN placed.section = 'frequent' THEN placed.last_approved END DESC,
          CASE WHEN placed.section = 'purchased' THEN placed.last_purchased END DESC,
          CASE WHEN placed.section = 'purchased' THEN placed.purchase_count END DESC,
          pg_catalog.lower(placed.product_name),
          placed.result_key
      )::integer AS position
    FROM placed
    WHERE placed.section IS NOT NULL
  )
  SELECT ordered.section, ordered.position, ordered.result_key, ordered.identity_source,
    ordered.product_name, ordered.manufacturer, ordered.vendor_name, ordered.vendor_sku,
    ordered.package_display, ordered.package_status, ordered.inventory_item_id,
    ordered.product_id, ordered.vendor_product_id, ordered.catalog_vendor_product_id,
    ordered.variant_detail, ordered.unit, ordered.pack_size,
    ordered.section = 'saved', ordered.approved_count, ordered.last_approved,
    ordered.purchase_count, ordered.last_purchased
  FROM ordered
  WHERE ordered.section = 'saved' AND ordered.position <= 50
     OR ordered.section <> 'saved' AND ordered.position <= _bounded_limit
  ORDER BY CASE ordered.section WHEN 'saved' THEN 1 WHEN 'frequent' THEN 2 ELSE 3 END,
    ordered.position;
END;
$$;

REVOKE ALL ON FUNCTION public.get_staff_product_discovery(uuid, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_staff_product_discovery(uuid, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_staff_product_discovery(uuid, integer) TO authenticated;

COMMENT ON FUNCTION public.get_staff_product_discovery(uuid, integer) IS
  'Phase 5A.10 Request Supplies start sections: own Saved Items, organization Frequently requested and Purchased before, each product once. Active members only.';

-- ---------------------------------------------------------------------------------------
-- Saved Items mutations: the caller's own rows only, in an organization they actively
-- belong to, for an identity that is requestable there right now.
-- ---------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.staff_saved_product_identity_check(
  _organization_id uuid,
  _product_id uuid,
  _catalog_vendor_product_id uuid,
  _inventory_item_id uuid
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid uuid := auth.uid();
BEGIN
  IF _uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;
  IF _organization_id IS NULL THEN
    RAISE EXCEPTION 'organization_id is required' USING ERRCODE = '22004';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.organization_memberships membership
    WHERE membership.organization_id = _organization_id
      AND membership.user_id = _uid
      AND membership.active = true
  ) THEN
    RAISE EXCEPTION 'Not a member of this organization' USING ERRCODE = '42501';
  END IF;
  IF num_nonnulls(_product_id, _catalog_vendor_product_id, _inventory_item_id) <> 1 THEN
    RAISE EXCEPTION 'Exactly one product identity is required' USING ERRCODE = '22023';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.staff_saved_product_identity_check(uuid, uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_saved_product_identity_check(uuid, uuid, uuid, uuid) FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.save_staff_product(
  _organization_id uuid,
  _product_id uuid DEFAULT NULL,
  _catalog_vendor_product_id uuid DEFAULT NULL,
  _inventory_item_id uuid DEFAULT NULL
)
RETURNS TABLE (identity_key text, saved boolean, created_at timestamptz)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid uuid := auth.uid();
  _key text;
  _created_at timestamptz;
BEGIN
  PERFORM public.staff_saved_product_identity_check(
    _organization_id, _product_id, _catalog_vendor_product_id, _inventory_item_id
  );
  IF NOT EXISTS (
    SELECT 1 FROM public.supply_request_product_identities(
      _organization_id,
      CASE WHEN _product_id IS NULL THEN ARRAY[]::uuid[] ELSE ARRAY[_product_id] END,
      CASE WHEN _catalog_vendor_product_id IS NULL THEN ARRAY[]::uuid[] ELSE ARRAY[_catalog_vendor_product_id] END,
      CASE WHEN _inventory_item_id IS NULL THEN ARRAY[]::uuid[] ELSE ARRAY[_inventory_item_id] END
    ) resolved
    WHERE resolved.product_id = _product_id
       OR resolved.catalog_vendor_product_id = _catalog_vendor_product_id
       OR resolved.inventory_item_id = _inventory_item_id
  ) THEN
    RAISE EXCEPTION 'This product is not available to request' USING ERRCODE = 'P0002';
  END IF;

  -- One user's saves are serialized so the cap below cannot be raced past.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('staff_saved_products:' || _organization_id::text || ':' || _uid::text, 0)
  );
  _key := CASE
    WHEN _product_id IS NOT NULL THEN 'organization-product:' || _product_id::text
    WHEN _catalog_vendor_product_id IS NOT NULL THEN 'catalog-vendor-product:' || _catalog_vendor_product_id::text
    ELSE 'inventory:' || _inventory_item_id::text
  END;
  SELECT saved_product.created_at INTO _created_at
  FROM public.staff_saved_products saved_product
  WHERE saved_product.organization_id = _organization_id
    AND saved_product.user_id = _uid
    AND saved_product.identity_key = _key;
  IF FOUND THEN
    RETURN QUERY SELECT _key, true, _created_at;
    RETURN;
  END IF;
  IF (SELECT pg_catalog.count(*) FROM public.staff_saved_products saved_product
      WHERE saved_product.organization_id = _organization_id AND saved_product.user_id = _uid) >= 200 THEN
    RAISE EXCEPTION 'You can save up to 200 items. Remove one to save another.' USING ERRCODE = '54000';
  END IF;

  INSERT INTO public.staff_saved_products (organization_id, user_id, product_id, catalog_vendor_product_id, inventory_item_id)
  VALUES (_organization_id, _uid, _product_id, _catalog_vendor_product_id, _inventory_item_id)
  RETURNING staff_saved_products.created_at INTO _created_at;
  RETURN QUERY SELECT _key, true, _created_at;
END;
$$;

REVOKE ALL ON FUNCTION public.save_staff_product(uuid, uuid, uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.save_staff_product(uuid, uuid, uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.save_staff_product(uuid, uuid, uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.save_staff_product(uuid, uuid, uuid, uuid) IS
  'Phase 5A.10: saves one requestable identity for the caller (idempotent; at most 200 per user and organization).';

CREATE OR REPLACE FUNCTION public.remove_staff_saved_product(
  _organization_id uuid,
  _product_id uuid DEFAULT NULL,
  _catalog_vendor_product_id uuid DEFAULT NULL,
  _inventory_item_id uuid DEFAULT NULL
)
RETURNS TABLE (identity_key text, saved boolean, removed boolean)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid uuid := auth.uid();
  _key text;
  _removed integer;
BEGIN
  PERFORM public.staff_saved_product_identity_check(
    _organization_id, _product_id, _catalog_vendor_product_id, _inventory_item_id
  );
  _key := CASE
    WHEN _product_id IS NOT NULL THEN 'organization-product:' || _product_id::text
    WHEN _catalog_vendor_product_id IS NOT NULL THEN 'catalog-vendor-product:' || _catalog_vendor_product_id::text
    ELSE 'inventory:' || _inventory_item_id::text
  END;
  DELETE FROM public.staff_saved_products saved_product
  WHERE saved_product.organization_id = _organization_id
    AND saved_product.user_id = _uid
    AND saved_product.identity_key = _key;
  GET DIAGNOSTICS _removed = ROW_COUNT;
  RETURN QUERY SELECT _key, false, _removed > 0;
END;
$$;

REVOKE ALL ON FUNCTION public.remove_staff_saved_product(uuid, uuid, uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.remove_staff_saved_product(uuid, uuid, uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.remove_staff_saved_product(uuid, uuid, uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.remove_staff_saved_product(uuid, uuid, uuid, uuid) IS
  'Phase 5A.10: removes one of the caller''s own Saved Items (idempotent).';

COMMIT;
