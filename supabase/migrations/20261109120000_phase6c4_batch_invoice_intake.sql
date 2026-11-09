-- Phase 6C.4: batch invoice intake (one uploaded PDF packet -> many invoices).
--
--   * invoice_upload_batches: one row per uploaded packet that held two or more invoices. The
--     original PDF stays in storage at storage_path (never copied N times). content_sha256 makes
--     a re-upload of the same bytes return the existing batch.
--   * invoice_upload_batch_segments: the deterministic page allocation of that packet. Segments
--     are contiguous, in source order, and cover every page exactly once (checked when the batch
--     is created; page ranges are never updated). kind: invoice | unresolved | non_invoice.
--     status: pending -> created | duplicate | failed; held (segmentation needs review, released
--     only by an owner); ignored (non-invoice page).
--   * A created segment points at an ordinary vendor_invoices row (source_file_id) holding a
--     page-subset PDF of the packet. From there the EXISTING per-upload workflow applies
--     unchanged: processing job trigger, embedded text, deterministic parser, review, matching,
--     post_reviewed_invoice, delete_invoice_permanently. Nothing here posts anything.
--   * Duplicate identity: vendor key + normalized invoice number (identity_key). At most one
--     created segment per organization and identity (partial unique index); registration also
--     refuses an invoice already present in public.invoices for the same vendor and number.
--
-- Owner only, like every invoice upload/review path. Tables: RLS on, no policies, no client
-- grants (service_role SELECT). Clients use the SECURITY DEFINER functions below.
--
-- Additive: two tables, their indexes, one trigger, nine functions. No existing table, column,
-- index, policy, trigger, grant or function changes.

BEGIN;

DO $preflight$
BEGIN
  IF pg_catalog.to_regclass('public.vendor_invoices') IS NULL
     OR pg_catalog.to_regclass('public.invoice_processing_jobs') IS NULL
     OR pg_catalog.to_regclass('public.invoices') IS NULL
     OR pg_catalog.to_regprocedure('public.has_org_role(uuid, uuid, public.org_role[])') IS NULL
     OR pg_catalog.to_regprocedure('public.tg_set_updated_at()') IS NULL
     OR pg_catalog.to_regprocedure('public.post_reviewed_invoice(uuid, uuid)') IS NULL THEN
    RAISE EXCEPTION 'Phase 6C.4 requires the invoice upload, processing and posting foundation';
  END IF;
  IF pg_catalog.to_regclass('public.invoice_upload_batches') IS NOT NULL
     OR pg_catalog.to_regclass('public.invoice_upload_batch_segments') IS NOT NULL
     OR EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public' AND p.proname IN (
                  'invoice_batch_identity_key', 'invoice_batch_name_key', 'create_invoice_upload_batch',
                  'register_invoice_batch_segment', 'fail_invoice_batch_segment', 'release_invoice_batch_segment',
                  'get_invoice_upload_batch', 'list_invoice_upload_batches', 'get_invoice_source_provenance')) THEN
    RAISE EXCEPTION 'Phase 6C.4 batch intake objects already exist unexpectedly';
  END IF;
END
$preflight$;

CREATE TABLE public.invoice_upload_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  uploaded_by uuid NOT NULL REFERENCES auth.users(id),
  storage_path text NOT NULL UNIQUE,
  original_filename text NOT NULL CHECK (btrim(original_filename) <> '' AND length(original_filename) <= 255),
  file_size bigint NOT NULL CHECK (file_size > 0 AND file_size <= 26214400),
  content_sha256 text NOT NULL CHECK (content_sha256 ~ '^[0-9a-f]{64}$'),
  page_count integer NOT NULL CHECK (page_count BETWEEN 2 AND 500),
  detector text NOT NULL CHECK (detector ~ '^[a-z0-9-]{1,60}$'),
  vendor_name text CHECK (vendor_name IS NULL OR (btrim(vendor_name) <> '' AND length(vendor_name) <= 200)),
  vendor_key text CHECK (vendor_key IS NULL OR vendor_key ~ '^[a-z0-9-]{1,60}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT invoice_upload_batches_org_content_uq UNIQUE (organization_id, content_sha256),
  CONSTRAINT invoice_upload_batches_id_org_uq UNIQUE (id, organization_id),
  CONSTRAINT invoice_upload_batches_path_org CHECK (split_part(storage_path, '/', 1) = organization_id::text)
);
CREATE INDEX invoice_upload_batches_org_created_idx ON public.invoice_upload_batches (organization_id, created_at DESC);

CREATE TABLE public.invoice_upload_batch_segments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL,
  batch_id uuid NOT NULL,
  segment_index integer NOT NULL CHECK (segment_index BETWEEN 1 AND 500),
  kind text NOT NULL CHECK (kind IN ('invoice', 'unresolved', 'non_invoice')),
  page_start integer NOT NULL CHECK (page_start >= 1),
  page_end integer NOT NULL,
  invoice_number text CHECK (invoice_number IS NULL OR invoice_number ~ '^[A-Z0-9-]{1,40}$'),
  invoice_date date,
  identity_key text,
  reasons text[] NOT NULL DEFAULT '{}'::text[],
  duplicate_of_segment_index integer,
  status text NOT NULL CHECK (status IN ('pending', 'created', 'duplicate', 'failed', 'held', 'ignored')),
  source_file_id uuid UNIQUE REFERENCES public.vendor_invoices(id) ON DELETE SET NULL,
  duplicate_of_source_file_id uuid REFERENCES public.vendor_invoices(id) ON DELETE SET NULL,
  parse_state text CHECK (parse_state IS NULL OR parse_state IN (
    'STRUCTURED_SUCCESS', 'STRUCTURED_PARTIAL', 'MANUAL_REVIEW_REQUIRED', 'STRUCTURED_FAILED', 'TEXT_UNAVAILABLE')),
  parsed_item_count integer CHECK (parsed_item_count IS NULL OR parsed_item_count >= 0),
  parsed_total numeric CHECK (parsed_total IS NULL OR parsed_total >= 0),
  parse_needs_review boolean NOT NULL DEFAULT false,
  error text CHECK (error IS NULL OR length(error) <= 500),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT invoice_upload_batch_segments_batch_fk FOREIGN KEY (batch_id, organization_id)
    REFERENCES public.invoice_upload_batches(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT invoice_upload_batch_segments_index_uq UNIQUE (batch_id, segment_index),
  CONSTRAINT invoice_upload_batch_segments_pages CHECK (page_end >= page_start),
  CONSTRAINT invoice_upload_batch_segments_invoice_number CHECK (kind <> 'invoice' OR invoice_number IS NOT NULL),
  CONSTRAINT invoice_upload_batch_segments_ignored CHECK ((kind = 'non_invoice') = (status = 'ignored'))
);
-- One created invoice per organization, vendor and invoice number: the database itself refuses
-- a second, whatever the application does.
CREATE UNIQUE INDEX invoice_upload_batch_segments_identity_uq
  ON public.invoice_upload_batch_segments (organization_id, identity_key)
  WHERE status = 'created' AND source_file_id IS NOT NULL AND identity_key IS NOT NULL;
CREATE INDEX invoice_upload_batch_segments_org_identity_idx
  ON public.invoice_upload_batch_segments (organization_id, identity_key) WHERE identity_key IS NOT NULL;
CREATE TRIGGER invoice_upload_batch_segments_updated_at BEFORE UPDATE ON public.invoice_upload_batch_segments
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

ALTER TABLE public.invoice_upload_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoice_upload_batch_segments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.invoice_upload_batches FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON public.invoice_upload_batch_segments FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.invoice_upload_batches TO service_role;
GRANT SELECT ON public.invoice_upload_batch_segments TO service_role;

-- Normalized comparison key for names and numbers: lower case letters and digits only.
CREATE FUNCTION public.invoice_batch_name_key(_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT NULLIF(pg_catalog.regexp_replace(pg_catalog.lower(COALESCE(_value, '')), '[^a-z0-9]+', '', 'g'), '')
$$;
REVOKE ALL ON FUNCTION public.invoice_batch_name_key(text) FROM PUBLIC, anon, authenticated;

-- vendor key + normalized invoice number; NULL when either is unknown (no cross-batch identity
-- without a known vendor: two vendors may print the same number).
CREATE FUNCTION public.invoice_batch_identity_key(_vendor_key text, _invoice_number text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT CASE
    WHEN NULLIF(btrim(COALESCE(_vendor_key, '')), '') IS NULL THEN NULL
    WHEN public.invoice_batch_name_key(_invoice_number) IS NULL THEN NULL
    ELSE pg_catalog.lower(btrim(_vendor_key)) || ':' || public.invoice_batch_name_key(_invoice_number)
  END
$$;
REVOKE ALL ON FUNCTION public.invoice_batch_identity_key(text, text) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.create_invoice_upload_batch(
  _organization_id uuid,
  _storage_path text,
  _original_filename text,
  _file_size bigint,
  _content_sha256 text,
  _page_count integer,
  _detector text,
  _vendor_name text,
  _vendor_key text,
  _segments jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _batch_id uuid;
  _segment jsonb;
  _position integer := 0;
  _expected_start integer := 1;
  _kind text;
  _start integer;
  _end integer;
  _reasons text[];
  _number text;
  _status text;
  _invoices integer := 0;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;
  IF _storage_path IS NULL OR _storage_path !~* ('^' || _organization_id::text || '/[0-9a-f-]{36}\.pdf$') THEN
    RAISE EXCEPTION 'Invalid invoice packet storage path';
  END IF;
  IF _content_sha256 IS NULL OR _content_sha256 !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Invalid invoice packet fingerprint';
  END IF;
  IF _segments IS NULL OR jsonb_typeof(_segments) <> 'array' OR jsonb_array_length(_segments) = 0
     OR jsonb_array_length(_segments) > 500 THEN
    RAISE EXCEPTION 'Invalid invoice packet segmentation';
  END IF;

  -- The same bytes uploaded again are the same packet: return it, create nothing.
  PERFORM pg_advisory_xact_lock(hashtextextended('invoice-packet:' || _organization_id::text || ':' || _content_sha256, 0));
  SELECT id INTO _batch_id FROM public.invoice_upload_batches
  WHERE organization_id = _organization_id AND content_sha256 = _content_sha256;
  IF FOUND THEN
    RETURN jsonb_build_object('batchId', _batch_id, 'existing', true);
  END IF;

  -- Page allocation: contiguous, in order, every page exactly once.
  FOR _segment IN SELECT value FROM jsonb_array_elements(_segments) LOOP
    _position := _position + 1;
    IF jsonb_typeof(_segment) <> 'object' OR (_segment->>'index')::integer IS DISTINCT FROM _position THEN
      RAISE EXCEPTION 'Invoice packet segment % is out of order', _position;
    END IF;
    _start := (_segment->>'startPage')::integer;
    _end := (_segment->>'endPage')::integer;
    IF _start IS DISTINCT FROM _expected_start OR _end IS NULL OR _end < _start OR _end > _page_count THEN
      RAISE EXCEPTION 'Invoice packet pages are not allocated exactly once (segment %)', _position;
    END IF;
    _expected_start := _end + 1;
    _kind := _segment->>'kind';
    IF _kind IS NULL OR _kind NOT IN ('invoice', 'unresolved', 'non_invoice') THEN
      RAISE EXCEPTION 'Invalid invoice packet segment kind (segment %)', _position;
    END IF;
    IF _kind = 'invoice' THEN _invoices := _invoices + 1; END IF;
  END LOOP;
  IF _expected_start IS DISTINCT FROM _page_count + 1 THEN
    RAISE EXCEPTION 'Invoice packet pages are not allocated exactly once (pages after % are unassigned)', _expected_start - 1;
  END IF;
  IF _invoices < 2 THEN
    RAISE EXCEPTION 'A batch needs at least two invoices; upload a single invoice normally';
  END IF;

  INSERT INTO public.invoice_upload_batches (
    organization_id, uploaded_by, storage_path, original_filename, file_size, content_sha256,
    page_count, detector, vendor_name, vendor_key
  ) VALUES (
    _organization_id, auth.uid(), _storage_path, btrim(_original_filename), _file_size, _content_sha256,
    _page_count, _detector, NULLIF(btrim(COALESCE(_vendor_name, '')), ''), NULLIF(btrim(COALESCE(_vendor_key, '')), '')
  ) RETURNING id INTO _batch_id;

  FOR _segment IN SELECT value FROM jsonb_array_elements(_segments) LOOP
    _kind := _segment->>'kind';
    _number := NULLIF(upper(btrim(COALESCE(_segment->>'invoiceNumber', ''))), '');
    SELECT COALESCE(array_agg(value ORDER BY ordinality), '{}'::text[]) INTO _reasons
    FROM jsonb_array_elements_text(COALESCE(_segment->'reasons', '[]'::jsonb)) WITH ORDINALITY;
    IF EXISTS (SELECT 1 FROM unnest(_reasons) reason WHERE reason NOT IN (
      'MISSING_FIRST_PAGE', 'INCOMPLETE_PAGE_SEQUENCE', 'PAGE_SEQUENCE_IRREGULAR', 'CONFLICTING_INVOICE_NUMBERS',
      'NO_INVOICE_NUMBER', 'NO_TEXT', 'HEADER_MISMATCH', 'DUPLICATE_IN_PACKET')) THEN
      RAISE EXCEPTION 'Invalid invoice packet segment reason';
    END IF;
    -- Status is decided here, never by the caller: anything the segmentation flagged is held for
    -- the owner, an in-packet duplicate is never created.
    _status := CASE
      WHEN _kind = 'non_invoice' THEN 'ignored'
      WHEN _kind = 'unresolved' THEN 'held'
      WHEN 'DUPLICATE_IN_PACKET' = ANY (_reasons) THEN 'duplicate'
      WHEN cardinality(_reasons) > 0 THEN 'held'
      ELSE 'pending'
    END;
    INSERT INTO public.invoice_upload_batch_segments (
      organization_id, batch_id, segment_index, kind, page_start, page_end, invoice_number, invoice_date,
      identity_key, reasons, duplicate_of_segment_index, status,
      parse_state, parsed_item_count, parsed_total, parse_needs_review
    ) VALUES (
      _organization_id, _batch_id, (_segment->>'index')::integer, _kind,
      (_segment->>'startPage')::integer, (_segment->>'endPage')::integer,
      CASE WHEN _kind = 'invoice' THEN _number END,
      NULLIF(_segment->>'invoiceDate', '')::date,
      CASE WHEN _kind = 'invoice' THEN public.invoice_batch_identity_key(_vendor_key, _number) END,
      _reasons,
      CASE WHEN _status = 'duplicate' THEN (_segment->>'duplicateOfIndex')::integer END,
      _status,
      NULLIF(_segment #>> '{parse,state}', ''),
      (_segment #>> '{parse,itemCount}')::integer,
      (_segment #>> '{parse,total}')::numeric,
      COALESCE((_segment #>> '{parse,needsReview}')::boolean, false)
    );
  END LOOP;

  RETURN jsonb_build_object('batchId', _batch_id, 'existing', false);
END;
$$;
REVOKE ALL ON FUNCTION public.create_invoice_upload_batch(uuid, text, text, bigint, text, integer, text, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_invoice_upload_batch(uuid, text, text, bigint, text, integer, text, text, text, jsonb) TO authenticated;

-- Turns one pending segment into an ordinary uploaded invoice whose file (_storage_path) the
-- caller has already stored: a PDF of exactly this segment's pages. Idempotent: a created
-- segment returns its invoice; a duplicate creates nothing. The caller removes its stored file
-- whenever the result is not a newly created invoice.
CREATE FUNCTION public.register_invoice_batch_segment(
  _organization_id uuid,
  _segment_id uuid,
  _storage_path text,
  _file_size bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _segment public.invoice_upload_batch_segments%ROWTYPE;
  _batch public.invoice_upload_batches%ROWTYPE;
  _duplicate uuid;
  _source_file_id uuid;
  _name text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;

  SELECT * INTO _segment FROM public.invoice_upload_batch_segments
  WHERE id = _segment_id AND organization_id = _organization_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice packet segment not found'; END IF;
  -- Serialize every registration of the same identity (retries, two tabs, two packets).
  IF _segment.identity_key IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('invoice-identity:' || _organization_id::text || ':' || _segment.identity_key, 0));
  END IF;
  SELECT * INTO _segment FROM public.invoice_upload_batch_segments
  WHERE id = _segment_id AND organization_id = _organization_id FOR UPDATE;

  IF _segment.status = 'created' AND _segment.source_file_id IS NOT NULL THEN
    RETURN jsonb_build_object('status', 'created', 'sourceFileId', _segment.source_file_id, 'existing', true);
  END IF;
  IF _segment.status = 'duplicate' THEN
    RETURN jsonb_build_object('status', 'duplicate', 'duplicateOfSourceFileId', _segment.duplicate_of_source_file_id, 'existing', true);
  END IF;
  IF _segment.status NOT IN ('pending', 'failed') OR _segment.kind = 'non_invoice' THEN
    RAISE EXCEPTION 'This part of the packet is not ready to become an invoice';
  END IF;

  SELECT * INTO _batch FROM public.invoice_upload_batches
  WHERE id = _segment.batch_id AND organization_id = _organization_id;
  IF _storage_path IS NULL OR _storage_path !~* ('^' || _organization_id::text || '/[0-9a-f-]{36}\.pdf$')
     OR _storage_path = _batch.storage_path THEN
    RAISE EXCEPTION 'Invalid invoice storage path';
  END IF;

  IF _segment.identity_key IS NOT NULL THEN
    SELECT source_file_id INTO _duplicate FROM public.invoice_upload_batch_segments
    WHERE organization_id = _organization_id AND identity_key = _segment.identity_key
      AND status = 'created' AND source_file_id IS NOT NULL AND id <> _segment.id
    LIMIT 1;
    IF _duplicate IS NULL AND _batch.vendor_name IS NOT NULL THEN
      -- An invoice uploaded on its own (or reviewed from any source) with the same vendor and number.
      SELECT invoice.source_file_id INTO _duplicate
      FROM public.invoices invoice
      LEFT JOIN public.vendors vendor ON vendor.id = invoice.vendor_id AND vendor.organization_id = invoice.organization_id
      WHERE invoice.organization_id = _organization_id
        AND invoice.source_file_id IS NOT NULL
        AND public.invoice_batch_name_key(invoice.invoice_number) = public.invoice_batch_name_key(_segment.invoice_number)
        AND (
          strpos(public.invoice_batch_name_key(COALESCE(vendor.name, invoice.vendor_name)), public.invoice_batch_name_key(_batch.vendor_name)) > 0
          OR strpos(public.invoice_batch_name_key(_batch.vendor_name), public.invoice_batch_name_key(COALESCE(vendor.name, invoice.vendor_name))) > 0
        )
      ORDER BY invoice.created_at, invoice.id
      LIMIT 1;
    END IF;
    IF _duplicate IS NOT NULL THEN
      UPDATE public.invoice_upload_batch_segments
      SET status = 'duplicate', duplicate_of_source_file_id = _duplicate, error = NULL
      WHERE id = _segment.id;
      RETURN jsonb_build_object('status', 'duplicate', 'duplicateOfSourceFileId', _duplicate, 'existing', false);
    END IF;
  END IF;

  _name := left(regexp_replace(_batch.original_filename, '\.pdf$', '', 'i'), 150)
    || CASE WHEN _segment.invoice_number IS NOT NULL THEN ' - invoice ' || _segment.invoice_number ELSE '' END
    || CASE WHEN _segment.page_start = _segment.page_end THEN ' (page ' || _segment.page_start || ')'
            ELSE ' (pages ' || _segment.page_start || '-' || _segment.page_end || ')' END
    || '.pdf';
  -- An ordinary upload: the existing trigger creates its processing job.
  INSERT INTO public.vendor_invoices (organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type)
  VALUES (_organization_id, auth.uid(), _storage_path, _name, _file_size, 'application/pdf')
  RETURNING id INTO _source_file_id;

  UPDATE public.invoice_upload_batch_segments
  SET status = 'created', source_file_id = _source_file_id, error = NULL
  WHERE id = _segment.id;
  RETURN jsonb_build_object('status', 'created', 'sourceFileId', _source_file_id, 'existing', false);
END;
$$;
REVOKE ALL ON FUNCTION public.register_invoice_batch_segment(uuid, uuid, text, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_invoice_batch_segment(uuid, uuid, text, bigint) TO authenticated;

-- Records why one segment could not be prepared. Other segments are unaffected; a failed
-- segment is retried by registering it again.
CREATE FUNCTION public.fail_invoice_batch_segment(_organization_id uuid, _segment_id uuid, _error text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;
  UPDATE public.invoice_upload_batch_segments
  SET status = 'failed', error = left(COALESCE(NULLIF(btrim(_error), ''), 'Preparing this invoice failed.'), 500)
  WHERE id = _segment_id AND organization_id = _organization_id AND status IN ('pending', 'failed');
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice packet segment not found or not in progress'; END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.fail_invoice_batch_segment(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fail_invoice_batch_segment(uuid, uuid, text) TO authenticated;

-- The one manual correction: an owner who has looked at a held range (flagged invoice pages or
-- unresolved pages) confirms it is one invoice. Page ranges never change.
CREATE FUNCTION public.release_invoice_batch_segment(_organization_id uuid, _segment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _segment public.invoice_upload_batch_segments%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;
  SELECT * INTO _segment FROM public.invoice_upload_batch_segments
  WHERE id = _segment_id AND organization_id = _organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice packet segment not found'; END IF;
  IF _segment.status <> 'held' THEN RAISE EXCEPTION 'Only a range held for review can be confirmed'; END IF;
  UPDATE public.invoice_upload_batch_segments SET status = 'pending', error = NULL WHERE id = _segment.id;
  RETURN jsonb_build_object('segmentId', _segment.id, 'status', 'pending');
END;
$$;
REVOKE ALL ON FUNCTION public.release_invoice_batch_segment(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.release_invoice_batch_segment(uuid, uuid) TO authenticated;

CREATE FUNCTION public.get_invoice_upload_batch(_organization_id uuid, _batch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _batch public.invoice_upload_batches%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;
  SELECT * INTO _batch FROM public.invoice_upload_batches WHERE id = _batch_id AND organization_id = _organization_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice packet not found'; END IF;
  RETURN jsonb_build_object(
    'batch', jsonb_build_object(
      'id', _batch.id, 'originalFilename', _batch.original_filename, 'storagePath', _batch.storage_path,
      'fileSize', _batch.file_size, 'pageCount', _batch.page_count, 'detector', _batch.detector,
      'vendorName', _batch.vendor_name, 'createdAt', _batch.created_at),
    'segments', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', segment.id, 'index', segment.segment_index, 'kind', segment.kind, 'status', segment.status,
        'pageStart', segment.page_start, 'pageEnd', segment.page_end,
        'invoiceNumber', segment.invoice_number, 'invoiceDate', segment.invoice_date,
        'reasons', to_jsonb(segment.reasons), 'duplicateOfIndex', segment.duplicate_of_segment_index,
        'duplicateOfSourceFileId', segment.duplicate_of_source_file_id,
        'parseState', segment.parse_state, 'parsedItemCount', segment.parsed_item_count,
        'parsedTotal', segment.parsed_total, 'parseNeedsReview', segment.parse_needs_review,
        'error', segment.error, 'sourceFileId', segment.source_file_id,
        'invoice', (
          SELECT jsonb_build_object(
            'processingStatus', invoice.processing_status,
            'itemCount', (SELECT count(*) FROM public.invoice_items item WHERE item.invoice_id = invoice.id AND item.organization_id = _organization_id),
            'total', COALESCE(invoice.total_amount, invoice.invoice_total))
          FROM public.invoices invoice
          WHERE invoice.source_file_id = segment.source_file_id AND invoice.organization_id = _organization_id)
      ) ORDER BY segment.segment_index)
      FROM public.invoice_upload_batch_segments segment
      WHERE segment.batch_id = _batch.id AND segment.organization_id = _organization_id), '[]'::jsonb)
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_invoice_upload_batch(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_invoice_upload_batch(uuid, uuid) TO authenticated;

CREATE FUNCTION public.list_invoice_upload_batches(_organization_id uuid, _limit integer DEFAULT 10)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(entry ORDER BY created_at DESC, id DESC)
    FROM (
      SELECT batch.id, batch.created_at, jsonb_build_object(
        'id', batch.id, 'originalFilename', batch.original_filename, 'pageCount', batch.page_count, 'createdAt', batch.created_at,
        'invoiceCount', (SELECT count(*) FROM public.invoice_upload_batch_segments s WHERE s.batch_id = batch.id AND s.kind = 'invoice'),
        'createdCount', (SELECT count(*) FROM public.invoice_upload_batch_segments s WHERE s.batch_id = batch.id AND s.status = 'created'),
        'attentionCount', (SELECT count(*) FROM public.invoice_upload_batch_segments s WHERE s.batch_id = batch.id AND s.status IN ('held', 'failed', 'pending'))
      ) AS entry
      FROM public.invoice_upload_batches batch
      WHERE batch.organization_id = _organization_id
      ORDER BY batch.created_at DESC, batch.id DESC
      LIMIT LEAST(GREATEST(COALESCE(_limit, 10), 1), 50)
    ) recent), '[]'::jsonb);
END;
$$;
REVOKE ALL ON FUNCTION public.list_invoice_upload_batches(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_invoice_upload_batches(uuid, integer) TO authenticated;

-- Where an invoice came from: its packet and page range, or null for a normal upload.
CREATE FUNCTION public.get_invoice_source_provenance(_organization_id uuid, _source_file_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;
  RETURN (
    SELECT jsonb_build_object(
      'batchId', batch.id, 'originalFilename', batch.original_filename, 'packetPageCount', batch.page_count,
      'pageStart', segment.page_start, 'pageEnd', segment.page_end, 'segmentIndex', segment.segment_index)
    FROM public.invoice_upload_batch_segments segment
    JOIN public.invoice_upload_batches batch ON batch.id = segment.batch_id AND batch.organization_id = segment.organization_id
    WHERE segment.source_file_id = _source_file_id AND segment.organization_id = _organization_id
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_invoice_source_provenance(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_invoice_source_provenance(uuid, uuid) TO authenticated;

COMMIT;
