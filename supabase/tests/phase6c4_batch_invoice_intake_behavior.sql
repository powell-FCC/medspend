-- Phase 6C.4 rollback-only behavioral verification: batch invoice intake (packet page
-- allocation, segment statuses, duplicate identity, idempotent registration, provenance and
-- access). Run against a disposable database after every migration through
-- 20261109120000_phase6c4_batch_invoice_intake.sql. Every fixture is rolled back.

BEGIN;

DO $phase6c4_fixture_guard$
BEGIN
  IF EXISTS (SELECT 1 FROM auth.users
             WHERE id BETWEEN '6c400000-0000-4000-8000-000000000001'::uuid AND '6c400000-0000-4000-8000-000000000099'::uuid)
     OR EXISTS (SELECT 1 FROM public.organizations
             WHERE id BETWEEN '6c400000-0000-4000-8000-000000000101'::uuid AND '6c400000-0000-4000-8000-000000000199'::uuid) THEN
    RAISE EXCEPTION 'Phase 6C.4 rollback-test fixture IDs already exist';
  END IF;
END
$phase6c4_fixture_guard$;

CREATE FUNCTION pg_temp.expect_error(_statement text, _expected text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE _statement;
  EXCEPTION WHEN OTHERS THEN
    IF position(_expected IN SQLERRM) = 0 THEN
      RAISE EXCEPTION 'Expected error containing "%", got "%" (%)', _expected, SQLERRM, SQLSTATE;
    END IF;
    RETURN;
  END;
  RAISE EXCEPTION 'Statement unexpectedly succeeded; expected "%": %', _expected, _statement;
END;
$$;
CREATE FUNCTION pg_temp.as_user(_user_id uuid)
RETURNS void LANGUAGE sql AS $$ SELECT pg_catalog.set_config('request.jwt.claim.sub', coalesce(_user_id::text, ''), true) $$;
CREATE FUNCTION pg_temp.assert(_condition boolean, _message text)
RETURNS void LANGUAGE plpgsql AS $$ BEGIN IF _condition IS NOT TRUE THEN RAISE EXCEPTION 'Check failed: %', _message; END IF; END; $$;

CREATE TEMP TABLE phase6c4_values (name text PRIMARY KEY, value jsonb) ON COMMIT DROP;
GRANT ALL ON phase6c4_values TO authenticated, anon;
CREATE FUNCTION pg_temp.val(_name text) RETURNS jsonb LANGUAGE sql AS $$ SELECT value FROM phase6c4_values WHERE name = _name $$;
CREATE FUNCTION pg_temp.id(_name text) RETURNS uuid LANGUAGE sql AS $$ SELECT (value #>> '{}')::uuid FROM phase6c4_values WHERE name = _name $$;
-- Read as postgres (the tables have no client grants).
CREATE FUNCTION pg_temp.segment(_batch uuid, _index integer)
RETURNS public.invoice_upload_batch_segments LANGUAGE sql SECURITY DEFINER AS $$
  SELECT * FROM public.invoice_upload_batch_segments WHERE batch_id = _batch AND segment_index = _index $$;
CREATE FUNCTION pg_temp.count_rows(_table text, _org uuid)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE _count bigint;
BEGIN EXECUTE format('SELECT count(*) FROM public.%I WHERE organization_id = $1', _table) INTO _count USING _org; RETURN _count; END $$;

-- One segment object as batch intake sends it.
CREATE FUNCTION pg_temp.seg(_index integer, _kind text, _start integer, _end integer, _number text DEFAULT NULL,
  _reasons text[] DEFAULT '{}', _duplicate_of integer DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('index', _index, 'kind', _kind, 'startPage', _start, 'endPage', _end, 'invoiceNumber', _number,
    'invoiceDate', CASE WHEN _number IS NULL THEN NULL ELSE '2026-01-15' END, 'reasons', to_jsonb(_reasons),
    'duplicateOfIndex', _duplicate_of,
    'parse', CASE WHEN _kind = 'invoice' THEN jsonb_build_object('state', 'STRUCTURED_SUCCESS', 'itemCount', 3, 'total', 12.5, 'needsReview', false) END) $$;
CREATE FUNCTION pg_temp.path(_org uuid, _n integer)
RETURNS text LANGUAGE sql AS $$ SELECT _org::text || '/' || lpad(to_hex(_n), 8, '0') || '-0000-4000-8000-00000000c6c4.pdf' $$;
CREATE FUNCTION pg_temp.sha(_n integer) RETURNS text LANGUAGE sql AS $$ SELECT md5(_n::text) || md5((_n + 1)::text) $$;
CREATE FUNCTION pg_temp.create_batch(_org uuid, _path integer, _sha integer, _pages integer, _segments jsonb,
  _vendor_name text DEFAULT 'Henry Schein, Inc.', _vendor_key text DEFAULT 'henry-schein')
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.create_invoice_upload_batch(_org, pg_temp.path(_org, _path), 'Packet.pdf', 5000, pg_temp.sha(_sha), _pages,
    'henry-schein-invoice-v1', _vendor_name, _vendor_key, _segments) $$;

-- ---------------------------------------------------------------------------------------
-- Fixtures. A: owner 001, admin 002, staff 003. B: owner 004. 007 belongs to nothing.
-- ---------------------------------------------------------------------------------------
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('6c400000-0000-4000-8000-00000000000' || n)::uuid, 'authenticated', 'authenticated', 'phase6c4-' || n || '@example.invalid', '', now(), '{}', '{}', now(), now()
FROM unnest(ARRAY[1, 2, 3, 4, 7]) n;
INSERT INTO public.organizations (id, name, created_by) VALUES
  ('6c400000-0000-4000-8000-000000000101', 'Phase 6C.4 Organization', '6c400000-0000-4000-8000-000000000001'),
  ('6c400000-0000-4000-8000-000000000102', 'Phase 6C.4 Other Organization', '6c400000-0000-4000-8000-000000000004');
INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES
  ('6c400000-0000-4000-8000-000000000101', '6c400000-0000-4000-8000-000000000001', 'owner', true),
  ('6c400000-0000-4000-8000-000000000101', '6c400000-0000-4000-8000-000000000002', 'admin', true),
  ('6c400000-0000-4000-8000-000000000101', '6c400000-0000-4000-8000-000000000003', 'staff', true),
  ('6c400000-0000-4000-8000-000000000102', '6c400000-0000-4000-8000-000000000004', 'owner', true);

-- ---------------------------------------------------------------------------------------
-- 1. Grants: client functions for authenticated only; internals, tables: nobody.
-- ---------------------------------------------------------------------------------------
DO $grants$
DECLARE _fn text;
BEGIN
  FOREACH _fn IN ARRAY ARRAY[
    'public.create_invoice_upload_batch(uuid, text, text, bigint, text, integer, text, text, text, jsonb)',
    'public.register_invoice_batch_segment(uuid, uuid, text, bigint)', 'public.fail_invoice_batch_segment(uuid, uuid, text)',
    'public.release_invoice_batch_segment(uuid, uuid)', 'public.get_invoice_upload_batch(uuid, uuid)',
    'public.list_invoice_upload_batches(uuid, integer)', 'public.get_invoice_source_provenance(uuid, uuid)'] LOOP
    PERFORM pg_temp.assert(has_function_privilege('authenticated', _fn, 'EXECUTE'), _fn || ' executable by authenticated');
    PERFORM pg_temp.assert(NOT has_function_privilege('anon', _fn, 'EXECUTE'), _fn || ' not executable by anon');
    PERFORM pg_temp.assert((SELECT prosecdef FROM pg_proc WHERE oid = _fn::regprocedure), _fn || ' is SECURITY DEFINER');
  END LOOP;
  FOREACH _fn IN ARRAY ARRAY['public.invoice_batch_name_key(text)', 'public.invoice_batch_identity_key(text, text)'] LOOP
    PERFORM pg_temp.assert(NOT has_function_privilege('authenticated', _fn, 'EXECUTE') AND NOT has_function_privilege('anon', _fn, 'EXECUTE'), _fn || ' internal');
  END LOOP;
  FOREACH _fn IN ARRAY ARRAY['public.invoice_upload_batches', 'public.invoice_upload_batch_segments'] LOOP
    PERFORM pg_temp.assert(NOT has_table_privilege('authenticated', _fn, 'SELECT,INSERT,UPDATE,DELETE')
      AND NOT has_table_privilege('anon', _fn, 'SELECT,INSERT,UPDATE,DELETE'), _fn || ' has no client grants');
    PERFORM pg_temp.assert(has_table_privilege('service_role', _fn, 'SELECT') AND NOT has_table_privilege('service_role', _fn, 'INSERT'), _fn || ' service_role read only');
    PERFORM pg_temp.assert((SELECT relrowsecurity FROM pg_class WHERE oid = _fn::regclass), _fn || ' RLS on');
    PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname || '.' || tablename = _fn), _fn || ' no policies');
  END LOOP;
END
$grants$;

-- ---------------------------------------------------------------------------------------
-- 2. Owner creates a packet. Status is decided by the database from kind and reasons.
--    Pages: 1 A1 | 2-3 A2 | 4 unresolved | 5 A1 again (copy) | 6 not an invoice | 7-8 A3 flagged
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('6c400000-0000-4000-8000-000000000001');
INSERT INTO phase6c4_values VALUES ('batch1', pg_temp.create_batch('6c400000-0000-4000-8000-000000000101', 1, 1, 8, jsonb_build_array(
  pg_temp.seg(1, 'invoice', 1, 1, 'a1') || '{"status": "created"}',
  pg_temp.seg(2, 'invoice', 2, 3, 'A2'),
  pg_temp.seg(3, 'unresolved', 4, 4, NULL, ARRAY['NO_INVOICE_NUMBER']),
  pg_temp.seg(4, 'invoice', 5, 5, 'A1', ARRAY['DUPLICATE_IN_PACKET'], 1),
  pg_temp.seg(5, 'non_invoice', 6, 6),
  pg_temp.seg(6, 'invoice', 7, 8, 'A3', ARRAY['INCOMPLETE_PAGE_SEQUENCE']))));
RESET ROLE;
INSERT INTO phase6c4_values VALUES ('b1', pg_temp.val('batch1')->'batchId');
SELECT pg_temp.assert((pg_temp.val('batch1')->>'existing')::boolean = false, 'new packet');
SELECT pg_temp.assert(
  (SELECT string_agg(segment_index || ':' || status || ':' || coalesce(identity_key, '-') || ':' || page_start || '-' || page_end, ' ' ORDER BY segment_index)
   FROM public.invoice_upload_batch_segments WHERE batch_id = pg_temp.id('b1'))
  = '1:pending:henry-schein:a1:1-1 2:pending:henry-schein:a2:2-3 3:held:-:4-4 4:duplicate:henry-schein:a1:5-5 5:ignored:-:6-6 6:held:henry-schein:a3:7-8',
  'statuses come from kind and reasons, never from the caller');
SELECT pg_temp.assert((pg_temp.segment(pg_temp.id('b1'), 1)).invoice_number = 'A1', 'invoice number stored upper case');
SELECT pg_temp.assert((pg_temp.segment(pg_temp.id('b1'), 4)).duplicate_of_segment_index = 1, 'in-packet duplicate keeps its original');
SELECT pg_temp.assert((pg_temp.segment(pg_temp.id('b1'), 2)).parsed_item_count = 3 AND (pg_temp.segment(pg_temp.id('b1'), 2)).parsed_total = 12.5, 'parse summary stored');
SELECT pg_temp.assert((SELECT uploaded_by FROM public.invoice_upload_batches WHERE id = pg_temp.id('b1')) = '6c400000-0000-4000-8000-000000000001', 'uploaded_by is the caller');
SELECT pg_temp.assert(pg_temp.count_rows('vendor_invoices', '6c400000-0000-4000-8000-000000000101') = 0, 'creating a packet creates no invoice');

-- The same bytes again: the existing packet, nothing new.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('6c400000-0000-4000-8000-000000000001');
INSERT INTO phase6c4_values VALUES ('batch1again', pg_temp.create_batch('6c400000-0000-4000-8000-000000000101', 2, 1, 8,
  jsonb_build_array(pg_temp.seg(1, 'invoice', 1, 4, 'Z1'), pg_temp.seg(2, 'invoice', 5, 8, 'Z2'))));
RESET ROLE;
SELECT pg_temp.assert(pg_temp.val('batch1again')->>'batchId' = pg_temp.val('b1') #>> '{}' AND (pg_temp.val('batch1again')->>'existing')::boolean, 'same content returns the existing packet');
SELECT pg_temp.assert(pg_temp.count_rows('invoice_upload_batches', '6c400000-0000-4000-8000-000000000101') = 1, 'no second packet');
SELECT pg_temp.assert(pg_temp.count_rows('invoice_upload_batch_segments', '6c400000-0000-4000-8000-000000000101') = 6, 'no new segments');

-- ---------------------------------------------------------------------------------------
-- 3. Page allocation is enforced: every page exactly once, in order.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('6c400000-0000-4000-8000-000000000001');
SELECT pg_temp.expect_error($$SELECT pg_temp.create_batch('6c400000-0000-4000-8000-000000000101', 3, 3, 4, jsonb_build_array(pg_temp.seg(1, 'invoice', 1, 1, 'G1'), pg_temp.seg(2, 'invoice', 3, 4, 'G2')))$$, 'not allocated exactly once');
SELECT pg_temp.expect_error($$SELECT pg_temp.create_batch('6c400000-0000-4000-8000-000000000101', 3, 3, 4, jsonb_build_array(pg_temp.seg(1, 'invoice', 1, 2, 'G1'), pg_temp.seg(2, 'invoice', 2, 4, 'G2')))$$, 'not allocated exactly once');
SELECT pg_temp.expect_error($$SELECT pg_temp.create_batch('6c400000-0000-4000-8000-000000000101', 3, 3, 4, jsonb_build_array(pg_temp.seg(1, 'invoice', 1, 2, 'G1'), pg_temp.seg(2, 'invoice', 3, 3, 'G2')))$$, 'pages after 3 are unassigned');
SELECT pg_temp.expect_error($$SELECT pg_temp.create_batch('6c400000-0000-4000-8000-000000000101', 3, 3, 4, jsonb_build_array(pg_temp.seg(1, 'invoice', 1, 2, 'G1'), pg_temp.seg(2, 'invoice', 3, 5, 'G2')))$$, 'not allocated exactly once');
SELECT pg_temp.expect_error($$SELECT pg_temp.create_batch('6c400000-0000-4000-8000-000000000101', 3, 3, 4, jsonb_build_array(pg_temp.seg(2, 'invoice', 1, 2, 'G1'), pg_temp.seg(1, 'invoice', 3, 4, 'G2')))$$, 'out of order');
SELECT pg_temp.expect_error($$SELECT pg_temp.create_batch('6c400000-0000-4000-8000-000000000101', 3, 3, 4, jsonb_build_array(pg_temp.seg(1, 'invoice', 1, 2, 'G1'), pg_temp.seg(2, 'receipt', 3, 4, 'G2')))$$, 'Invalid invoice packet segment kind');
SELECT pg_temp.expect_error($$SELECT pg_temp.create_batch('6c400000-0000-4000-8000-000000000101', 3, 3, 4, jsonb_build_array(pg_temp.seg(1, 'invoice', 1, 2, 'G1', ARRAY['LOOKS_FINE']), pg_temp.seg(2, 'invoice', 3, 4, 'G2')))$$, 'Invalid invoice packet segment reason');
SELECT pg_temp.expect_error($$SELECT pg_temp.create_batch('6c400000-0000-4000-8000-000000000101', 3, 3, 4, jsonb_build_array(pg_temp.seg(1, 'invoice', 1, 3, 'G1'), pg_temp.seg(2, 'unresolved', 4, 4)))$$, 'at least two invoices');
SELECT pg_temp.expect_error($$SELECT pg_temp.create_batch('6c400000-0000-4000-8000-000000000101', 3, 3, 4, jsonb_build_array(pg_temp.seg(1, 'invoice', 1, 2, NULL), pg_temp.seg(2, 'invoice', 3, 4, 'G2')))$$, 'invoice_number');
SELECT pg_temp.expect_error($$SELECT pg_temp.create_batch('6c400000-0000-4000-8000-000000000101', 3, 3, 4, '[]'::jsonb)$$, 'Invalid invoice packet segmentation');
SELECT pg_temp.expect_error($$SELECT public.create_invoice_upload_batch('6c400000-0000-4000-8000-000000000101', pg_temp.path('6c400000-0000-4000-8000-000000000102', 3), 'P.pdf', 10, pg_temp.sha(3), 4, 'd', NULL, NULL, jsonb_build_array(pg_temp.seg(1, 'invoice', 1, 2, 'G1'), pg_temp.seg(2, 'invoice', 3, 4, 'G2')))$$, 'Invalid invoice packet storage path');
SELECT pg_temp.expect_error($$SELECT public.create_invoice_upload_batch('6c400000-0000-4000-8000-000000000101', pg_temp.path('6c400000-0000-4000-8000-000000000101', 3), 'P.pdf', 10, 'abc', 4, 'd', NULL, NULL, jsonb_build_array(pg_temp.seg(1, 'invoice', 1, 2, 'G1'), pg_temp.seg(2, 'invoice', 3, 4, 'G2')))$$, 'Invalid invoice packet fingerprint');
RESET ROLE;
SELECT pg_temp.assert(pg_temp.count_rows('invoice_upload_batches', '6c400000-0000-4000-8000-000000000101') = 1, 'refused packets left nothing behind');

-- ---------------------------------------------------------------------------------------
-- 4. Access: admin, staff, another organization's owner, a non-member, anon.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $access$
DECLARE _user uuid; _sql text;
BEGIN
  FOREACH _user IN ARRAY ARRAY['6c400000-0000-4000-8000-000000000002', '6c400000-0000-4000-8000-000000000003',
                               '6c400000-0000-4000-8000-000000000004', '6c400000-0000-4000-8000-000000000007']::uuid[] LOOP
    PERFORM pg_temp.as_user(_user);
    FOREACH _sql IN ARRAY ARRAY[
      format($$SELECT public.get_invoice_upload_batch('6c400000-0000-4000-8000-000000000101', %L)$$, pg_temp.id('b1')),
      $$SELECT public.list_invoice_upload_batches('6c400000-0000-4000-8000-000000000101')$$,
      $$SELECT pg_temp.create_batch('6c400000-0000-4000-8000-000000000101', 4, 4, 2, jsonb_build_array(pg_temp.seg(1, 'invoice', 1, 1, 'X1'), pg_temp.seg(2, 'invoice', 2, 2, 'X2')))$$,
      format($$SELECT public.register_invoice_batch_segment('6c400000-0000-4000-8000-000000000101', %L, pg_temp.path('6c400000-0000-4000-8000-000000000101', 40), 10)$$, (pg_temp.segment(pg_temp.id('b1'), 1)).id),
      format($$SELECT public.fail_invoice_batch_segment('6c400000-0000-4000-8000-000000000101', %L, 'x')$$, (pg_temp.segment(pg_temp.id('b1'), 1)).id),
      format($$SELECT public.release_invoice_batch_segment('6c400000-0000-4000-8000-000000000101', %L)$$, (pg_temp.segment(pg_temp.id('b1'), 3)).id),
      format($$SELECT public.get_invoice_source_provenance('6c400000-0000-4000-8000-000000000101', %L)$$, gen_random_uuid())] LOOP
      PERFORM pg_temp.expect_error(_sql, 'owner access required');
    END LOOP;
  END LOOP;
  -- Organization B's owner, asking about A's packet under B's own id: not found.
  PERFORM pg_temp.as_user('6c400000-0000-4000-8000-000000000004');
  PERFORM pg_temp.expect_error(format($$SELECT public.get_invoice_upload_batch('6c400000-0000-4000-8000-000000000102', %L)$$, pg_temp.id('b1')), 'Invoice packet not found');
  PERFORM pg_temp.expect_error(format($$SELECT public.register_invoice_batch_segment('6c400000-0000-4000-8000-000000000102', %L, pg_temp.path('6c400000-0000-4000-8000-000000000102', 41), 10)$$, (pg_temp.segment(pg_temp.id('b1'), 1)).id), 'segment not found');
  PERFORM pg_temp.expect_error(format($$SELECT public.release_invoice_batch_segment('6c400000-0000-4000-8000-000000000102', %L)$$, (pg_temp.segment(pg_temp.id('b1'), 3)).id), 'segment not found');
  PERFORM pg_temp.expect_error(format($$SELECT public.fail_invoice_batch_segment('6c400000-0000-4000-8000-000000000102', %L, 'x')$$, (pg_temp.segment(pg_temp.id('b1'), 1)).id), 'not found');
  PERFORM pg_temp.assert(public.list_invoice_upload_batches('6c400000-0000-4000-8000-000000000102') = '[]'::jsonb, 'B lists none of A''s packets');
  PERFORM pg_temp.expect_error('SELECT count(*) FROM public.invoice_upload_batch_segments', 'permission denied');
  PERFORM pg_temp.expect_error('SELECT count(*) FROM public.invoice_upload_batches', 'permission denied');
END
$access$;
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.expect_error(format($$SELECT public.get_invoice_upload_batch('6c400000-0000-4000-8000-000000000101', %L)$$, pg_temp.id('b1')), 'permission denied');
SELECT pg_temp.expect_error($$SELECT public.list_invoice_upload_batches('6c400000-0000-4000-8000-000000000101')$$, 'permission denied');
RESET ROLE;
SELECT pg_temp.assert((pg_temp.segment(pg_temp.id('b1'), 1)).status = 'pending' AND (pg_temp.segment(pg_temp.id('b1'), 3)).status = 'held', 'refused calls changed nothing');

-- ---------------------------------------------------------------------------------------
-- 5. Registration: an ordinary upload, idempotent, never twice, never for held/ignored.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('6c400000-0000-4000-8000-000000000001');
INSERT INTO phase6c4_values VALUES ('reg1', public.register_invoice_batch_segment('6c400000-0000-4000-8000-000000000101', (pg_temp.segment(pg_temp.id('b1'), 1)).id, pg_temp.path('6c400000-0000-4000-8000-000000000101', 11), 1234));
INSERT INTO phase6c4_values VALUES ('reg1again', public.register_invoice_batch_segment('6c400000-0000-4000-8000-000000000101', (pg_temp.segment(pg_temp.id('b1'), 1)).id, pg_temp.path('6c400000-0000-4000-8000-000000000101', 12), 1234));
SELECT pg_temp.expect_error(format($$SELECT public.register_invoice_batch_segment('6c400000-0000-4000-8000-000000000101', %L, pg_temp.path('6c400000-0000-4000-8000-000000000101', 13), 10)$$, (pg_temp.segment(pg_temp.id('b1'), 3)).id), 'not ready');
SELECT pg_temp.expect_error(format($$SELECT public.register_invoice_batch_segment('6c400000-0000-4000-8000-000000000101', %L, pg_temp.path('6c400000-0000-4000-8000-000000000101', 13), 10)$$, (pg_temp.segment(pg_temp.id('b1'), 5)).id), 'not ready');
SELECT pg_temp.expect_error(format($$SELECT public.register_invoice_batch_segment('6c400000-0000-4000-8000-000000000101', %L, pg_temp.path('6c400000-0000-4000-8000-000000000101', 1), 10)$$, (pg_temp.segment(pg_temp.id('b1'), 2)).id), 'Invalid invoice storage path');
SELECT pg_temp.expect_error(format($$SELECT public.register_invoice_batch_segment('6c400000-0000-4000-8000-000000000101', %L, pg_temp.path('6c400000-0000-4000-8000-000000000102', 13), 10)$$, (pg_temp.segment(pg_temp.id('b1'), 2)).id), 'Invalid invoice storage path');
INSERT INTO phase6c4_values VALUES ('regdup', public.register_invoice_batch_segment('6c400000-0000-4000-8000-000000000101', (pg_temp.segment(pg_temp.id('b1'), 4)).id, pg_temp.path('6c400000-0000-4000-8000-000000000101', 14), 10));
RESET ROLE;
INSERT INTO phase6c4_values VALUES ('src1', pg_temp.val('reg1')->'sourceFileId');
SELECT pg_temp.assert(pg_temp.val('reg1')->>'status' = 'created' AND (pg_temp.val('reg1')->>'existing')::boolean = false, 'first registration creates');
SELECT pg_temp.assert(pg_temp.val('reg1again')->>'sourceFileId' = pg_temp.val('src1') #>> '{}' AND (pg_temp.val('reg1again')->>'existing')::boolean, 'retry returns the same invoice');
SELECT pg_temp.assert(pg_temp.val('regdup')->>'status' = 'duplicate', 'an in-packet duplicate is never created');
SELECT pg_temp.assert(pg_temp.count_rows('vendor_invoices', '6c400000-0000-4000-8000-000000000101') = 1, 'exactly one uploaded invoice');
SELECT pg_temp.assert((SELECT original_filename = 'Packet - invoice A1 (page 1).pdf' AND storage_path = pg_temp.path('6c400000-0000-4000-8000-000000000101', 11)
  AND uploaded_by = '6c400000-0000-4000-8000-000000000001' AND file_size = 1234 FROM public.vendor_invoices WHERE id = pg_temp.id('src1')), 'child is an ordinary upload');
SELECT pg_temp.assert((SELECT status FROM public.invoice_processing_jobs WHERE invoice_id = pg_temp.id('src1')) = 'uploaded', 'the existing trigger created its processing job');
SELECT pg_temp.assert(NOT EXISTS (SELECT 1 FROM public.invoices WHERE source_file_id = pg_temp.id('src1')), 'nothing is parsed or posted at registration');
SELECT pg_temp.assert((pg_temp.segment(pg_temp.id('b1'), 1)).status = 'created' AND (pg_temp.segment(pg_temp.id('b1'), 1)).source_file_id = pg_temp.id('src1'), 'segment points at its invoice');

-- ---------------------------------------------------------------------------------------
-- 6. Duplicates across packets and against invoices uploaded on their own.
-- ---------------------------------------------------------------------------------------
-- An invoice uploaded individually and reviewed: Henry Schein B9. Another vendor's B8.
INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type) VALUES
  ('6c400000-0000-4000-8000-000000000701', '6c400000-0000-4000-8000-000000000101', '6c400000-0000-4000-8000-000000000001', pg_temp.path('6c400000-0000-4000-8000-000000000101', 701), 'B9.pdf', 10, 'application/pdf'),
  ('6c400000-0000-4000-8000-000000000702', '6c400000-0000-4000-8000-000000000101', '6c400000-0000-4000-8000-000000000001', pg_temp.path('6c400000-0000-4000-8000-000000000101', 702), 'B8.pdf', 10, 'application/pdf');
-- Organization B has its own Henry Schein B8: never a duplicate for A.
INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type) VALUES
  ('6c400000-0000-4000-8000-000000000703', '6c400000-0000-4000-8000-000000000102', '6c400000-0000-4000-8000-000000000004', pg_temp.path('6c400000-0000-4000-8000-000000000102', 703), 'B8.pdf', 10, 'application/pdf');
INSERT INTO public.invoices (organization_id, source_file_id, vendor_name, invoice_number, processing_status) VALUES
  ('6c400000-0000-4000-8000-000000000101', '6c400000-0000-4000-8000-000000000701', 'HENRY SCHEIN INC', 'b-9', 'review_required'),
  ('6c400000-0000-4000-8000-000000000101', '6c400000-0000-4000-8000-000000000702', 'Medline Industries', 'B8', 'review_required'),
  ('6c400000-0000-4000-8000-000000000102', '6c400000-0000-4000-8000-000000000703', 'Henry Schein', 'B8', 'review_required');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('6c400000-0000-4000-8000-000000000001');
INSERT INTO phase6c4_values VALUES ('b2', pg_temp.create_batch('6c400000-0000-4000-8000-000000000101', 2, 2, 4, jsonb_build_array(
  pg_temp.seg(1, 'invoice', 1, 1, 'A1'), pg_temp.seg(2, 'invoice', 2, 2, 'B9'), pg_temp.seg(3, 'invoice', 3, 3, 'B8'), pg_temp.seg(4, 'invoice', 4, 4, 'A2')))->'batchId');
INSERT INTO phase6c4_values VALUES ('b2r1', public.register_invoice_batch_segment('6c400000-0000-4000-8000-000000000101', (pg_temp.segment(pg_temp.id('b2'), 1)).id, pg_temp.path('6c400000-0000-4000-8000-000000000101', 21), 10));
INSERT INTO phase6c4_values VALUES ('b2r2', public.register_invoice_batch_segment('6c400000-0000-4000-8000-000000000101', (pg_temp.segment(pg_temp.id('b2'), 2)).id, pg_temp.path('6c400000-0000-4000-8000-000000000101', 22), 10));
INSERT INTO phase6c4_values VALUES ('b2r3', public.register_invoice_batch_segment('6c400000-0000-4000-8000-000000000101', (pg_temp.segment(pg_temp.id('b2'), 3)).id, pg_temp.path('6c400000-0000-4000-8000-000000000101', 23), 10));
RESET ROLE;
SELECT pg_temp.assert(pg_temp.val('b2r1')->>'status' = 'duplicate' AND pg_temp.val('b2r1')->>'duplicateOfSourceFileId' = pg_temp.val('src1') #>> '{}', 'same invoice in a second packet is a duplicate of the first');
SELECT pg_temp.assert(pg_temp.val('b2r2')->>'status' = 'duplicate' AND pg_temp.val('b2r2')->>'duplicateOfSourceFileId' = '6c400000-0000-4000-8000-000000000701', 'an individually uploaded invoice (same vendor, same number) is a duplicate');
SELECT pg_temp.assert(pg_temp.val('b2r3')->>'status' = 'created', 'the same number from another vendor is not a duplicate');
SELECT pg_temp.assert(pg_temp.count_rows('vendor_invoices', '6c400000-0000-4000-8000-000000000101') = 4, 'only the distinct invoice was added');

-- The database itself refuses two created segments with one identity.
SELECT pg_temp.expect_error(format($$UPDATE public.invoice_upload_batch_segments SET status = 'created', source_file_id = '6c400000-0000-4000-8000-000000000702' WHERE id = %L$$,
  (pg_temp.segment(pg_temp.id('b2'), 1)).id), 'invoice_upload_batch_segments_identity_uq');
-- Without a known vendor there is no cross-packet identity (two vendors may share a number).
SELECT pg_temp.assert(public.invoice_batch_identity_key(NULL, 'A1') IS NULL AND public.invoice_batch_identity_key('v', ' a-1 ') = 'v:a1', 'identity key rules');

-- ---------------------------------------------------------------------------------------
-- 7. Failure, retry, release; provenance; list and read shape.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('6c400000-0000-4000-8000-000000000001');
SELECT public.fail_invoice_batch_segment('6c400000-0000-4000-8000-000000000101', (pg_temp.segment(pg_temp.id('b1'), 2)).id, 'Storage upload failed');
SELECT pg_temp.expect_error(format($$SELECT public.fail_invoice_batch_segment('6c400000-0000-4000-8000-000000000101', %L, 'x')$$, (pg_temp.segment(pg_temp.id('b1'), 1)).id), 'not in progress');
RESET ROLE;
SELECT pg_temp.assert((pg_temp.segment(pg_temp.id('b1'), 2)).status = 'failed' AND (pg_temp.segment(pg_temp.id('b1'), 2)).error = 'Storage upload failed', 'failure recorded on that segment only');
SELECT pg_temp.assert((pg_temp.segment(pg_temp.id('b1'), 1)).status = 'created', 'a created segment cannot be failed');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('6c400000-0000-4000-8000-000000000001');
INSERT INTO phase6c4_values VALUES ('retry', public.register_invoice_batch_segment('6c400000-0000-4000-8000-000000000101', (pg_temp.segment(pg_temp.id('b1'), 2)).id, pg_temp.path('6c400000-0000-4000-8000-000000000101', 31), 10));
SELECT pg_temp.expect_error(format($$SELECT public.release_invoice_batch_segment('6c400000-0000-4000-8000-000000000101', %L)$$, (pg_temp.segment(pg_temp.id('b1'), 2)).id), 'Only a range held for review');
SELECT pg_temp.expect_error(format($$SELECT public.release_invoice_batch_segment('6c400000-0000-4000-8000-000000000101', %L)$$, (pg_temp.segment(pg_temp.id('b1'), 4)).id), 'Only a range held for review');
SELECT public.release_invoice_batch_segment('6c400000-0000-4000-8000-000000000101', (pg_temp.segment(pg_temp.id('b1'), 3)).id);
INSERT INTO phase6c4_values VALUES ('released', public.register_invoice_batch_segment('6c400000-0000-4000-8000-000000000101', (pg_temp.segment(pg_temp.id('b1'), 3)).id, pg_temp.path('6c400000-0000-4000-8000-000000000101', 32), 10));
INSERT INTO phase6c4_values VALUES ('prov', public.get_invoice_source_provenance('6c400000-0000-4000-8000-000000000101', (pg_temp.val('retry')->>'sourceFileId')::uuid));
INSERT INTO phase6c4_values VALUES ('provnone', coalesce(public.get_invoice_source_provenance('6c400000-0000-4000-8000-000000000101', '6c400000-0000-4000-8000-000000000701'), 'null'::jsonb));
INSERT INTO phase6c4_values VALUES ('read', public.get_invoice_upload_batch('6c400000-0000-4000-8000-000000000101', pg_temp.id('b1')));
INSERT INTO phase6c4_values VALUES ('list', public.list_invoice_upload_batches('6c400000-0000-4000-8000-000000000101'));
SELECT pg_temp.as_user('6c400000-0000-4000-8000-000000000004');
INSERT INTO phase6c4_values VALUES ('provcross', coalesce(public.get_invoice_source_provenance('6c400000-0000-4000-8000-000000000102', (pg_temp.val('retry')->>'sourceFileId')::uuid), 'null'::jsonb));
RESET ROLE;
SELECT pg_temp.assert(pg_temp.val('provcross') = 'null'::jsonb, 'another organization learns nothing about A''s invoice provenance');
SELECT pg_temp.assert(pg_temp.val('retry')->>'status' = 'created', 'a failed segment is retried by registering again');
SELECT pg_temp.assert(pg_temp.val('released')->>'status' = 'created'
  AND (SELECT original_filename FROM public.vendor_invoices WHERE id = (pg_temp.val('released')->>'sourceFileId')::uuid) = 'Packet (page 4).pdf', 'a released unresolved range becomes an invoice named by its pages');
SELECT pg_temp.assert(pg_temp.val('prov') = jsonb_build_object('batchId', pg_temp.id('b1'), 'originalFilename', 'Packet.pdf', 'packetPageCount', 8, 'pageStart', 2, 'pageEnd', 3, 'segmentIndex', 2), 'provenance: packet and page range');
SELECT pg_temp.assert(pg_temp.val('provnone') = 'null'::jsonb, 'a normal upload has no packet provenance');
SELECT pg_temp.assert(jsonb_array_length(pg_temp.val('read')->'segments') = 6
  AND (SELECT string_agg((s->>'index') || (s->>'status'), ',' ORDER BY (s->>'index')::int) FROM jsonb_array_elements(pg_temp.val('read')->'segments') s) = '1created,2created,3created,4duplicate,5ignored,6held'
  AND pg_temp.val('read') #>> '{batch,pageCount}' = '8', 'read returns every segment in page order');
SELECT pg_temp.assert(jsonb_array_length(pg_temp.val('list')) = 2 AND (pg_temp.val('list')->1->>'invoiceCount')::int = 4, 'list returns both packets, newest first');

-- ---------------------------------------------------------------------------------------
-- 8. A created invoice behaves like any upload: deleting it keeps the packet and the other
--    invoices, and frees its identity for a later upload.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('6c400000-0000-4000-8000-000000000001');
SELECT public.delete_invoice_permanently('6c400000-0000-4000-8000-000000000101', pg_temp.id('src1'));
RESET ROLE;
SELECT pg_temp.assert((pg_temp.segment(pg_temp.id('b1'), 1)).source_file_id IS NULL AND (pg_temp.segment(pg_temp.id('b1'), 1)).status = 'created', 'deleted invoice: segment keeps its record, loses its link');
SELECT pg_temp.assert(EXISTS (SELECT 1 FROM public.invoice_upload_batches WHERE id = pg_temp.id('b1')), 'the packet stays');
SELECT pg_temp.assert(pg_temp.count_rows('vendor_invoices', '6c400000-0000-4000-8000-000000000101') = 5, 'other invoices stay');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('6c400000-0000-4000-8000-000000000001');
INSERT INTO phase6c4_values VALUES ('b2again', public.register_invoice_batch_segment('6c400000-0000-4000-8000-000000000101', (pg_temp.segment(pg_temp.id('b2'), 4)).id, pg_temp.path('6c400000-0000-4000-8000-000000000101', 24), 10));
RESET ROLE;
SELECT pg_temp.assert(pg_temp.val('b2again')->>'status' = 'duplicate', 'A2 created from the first packet is still a duplicate');

SELECT 'phase6c4 batch invoice intake behavior: all checks passed' AS result;
ROLLBACK;
