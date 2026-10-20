-- Phase 6C.2 production postcheck. Run AFTER both migrations and BEFORE the application
-- deploy (no cancellation can exist yet). Read-only; rolled back.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F ' | ' \
--     -f supabase/release/phase6c2/postcheck.sql > phase6c2_post.txt
--   diff phase6c2_pre.txt phase6c2_post.txt
--
-- The only expected fingerprint differences are listed in README.md. Any other line that
-- differs is unrelated drift (or live traffic between the two runs) and must be explained.

BEGIN READ ONLY;

SELECT 'postcheck_at' AS section, now()::text AS value;

DO $phase6c2_postcheck$
DECLARE
  _proc oid;
  _hash text;
BEGIN
  -- 'cancelled' exists exactly once, appended after every existing value.
  IF (SELECT string_agg(enumlabel, ',' ORDER BY enumsortorder) FROM pg_enum
      WHERE enumtypid = 'public.supply_request_status'::regtype)
     IS DISTINCT FROM 'submitted,under_review,approved,ordered,received,completed,denied,cancelled' THEN
    RAISE EXCEPTION 'postcheck: supply_request_status is not the expected 6C.2 enum';
  END IF;

  -- The cancellation RPC: one signature, the reviewed body, SECURITY DEFINER,
  -- executable by authenticated only.
  _proc := to_regprocedure('public.cancel_submitted_supply_request(uuid,uuid)');
  IF _proc IS NULL THEN
    RAISE EXCEPTION 'postcheck: cancel_submitted_supply_request is missing';
  END IF;
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = 'cancel_submitted_supply_request') <> 1 THEN
    RAISE EXCEPTION 'postcheck: cancel_submitted_supply_request has more than one signature';
  END IF;
  IF md5(pg_get_functiondef(_proc)) <> 'f2bcba7dc4c6656a1eb2b69f9ea7c288'
     OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = _proc)
     OR NOT has_function_privilege('authenticated', _proc, 'EXECUTE')
     OR has_function_privilege('anon', _proc, 'EXECUTE') THEN
    RAISE EXCEPTION 'postcheck: cancel_submitted_supply_request definition or grants are wrong';
  END IF;

  -- Phase 6C functions still exist. The edit RPC has the reviewed 6C.2 body and keeps
  -- its grants; every other lifecycle function is byte-for-byte unchanged.
  FOR _hash IN
    SELECT format('%s=%s', expected.name, coalesce((
      SELECT md5(pg_get_functiondef(p.oid)) FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = expected.name), 'absent'))
    FROM (VALUES
      ('update_submitted_supply_request', '6da72bb6d7bf813a3a226545517ef8dd'),
      ('list_staff_supply_request_updates', '956703dc601e8d41206f21c3ea3036c7'),
      ('decide_supply_request', '17f05c0ff76d128f2e3a3b7c3126b2f9'),
      ('transition_supply_request', '6430f28ddd75800c8ac3c95bc813d733'),
      ('apply_supply_request_transition', '847dd999535fc5eafee807a151f6864e'),
      ('guard_supply_request_lifecycle', '4f2ab5044e84fbdc5b20a668f1910907'),
      ('create_supply_request_commitment', 'd74eab8279a2a5eedc21801a57d14e95')
    ) AS expected(name, md5)
    WHERE (
      SELECT md5(pg_get_functiondef(p.oid)) FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = expected.name
    ) IS DISTINCT FROM expected.md5
  LOOP
    RAISE EXCEPTION 'postcheck: unexpected function definition: %', _hash;
  END LOOP;
  _proc := to_regprocedure(
    'public.update_submitted_supply_request(uuid,uuid,public.supply_request_type,uuid,uuid,text,jsonb)'
  );
  IF _proc IS NULL
     OR NOT has_function_privilege('authenticated', _proc, 'EXECUTE')
     OR has_function_privilege('anon', _proc, 'EXECUTE') THEN
    RAISE EXCEPTION 'postcheck: update_submitted_supply_request signature or grants changed';
  END IF;

  -- The audit constraint is the reviewed three-branch definition, validated, and it
  -- names the requester_cancelled shape.
  IF (SELECT md5(pg_get_constraintdef(oid)) || ':' || convalidated FROM pg_constraint
      WHERE conrelid = 'public.supply_request_updates'::regclass
        AND conname = 'supply_request_updates_event_kind_check')
     IS DISTINCT FROM '529f020a6720feee987615936fc38cb0:true' THEN
    RAISE EXCEPTION 'postcheck: supply_request_updates_event_kind_check is not the 6C.2 definition';
  END IF;

  -- No request was moved to 'cancelled' by the migration (the app is not deployed yet).
  IF EXISTS (SELECT 1 FROM public.supply_requests WHERE status = 'cancelled')
     OR EXISTS (SELECT 1 FROM public.supply_request_updates
                WHERE status_to = 'cancelled' OR event_kind = 'requester_cancelled') THEN
    RAISE EXCEPTION 'postcheck: cancelled rows exist before the cancellation UI shipped';
  END IF;
END
$phase6c2_postcheck$;

SELECT 'postcheck' AS section, 'assertions passed' AS value;

\ir fingerprint.sql

ROLLBACK;
