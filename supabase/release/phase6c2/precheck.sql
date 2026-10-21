-- Phase 6C.2 production precheck. Run BEFORE either Phase 6C.2 migration.
-- Read-only: the whole script runs in a READ ONLY transaction and is rolled back.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F ' | ' \
--     -f supabase/release/phase6c2/precheck.sql > phase6c2_pre.txt
--
-- Any failed assertion stops the release: production does not match the schema the
-- migrations were reviewed against. Keep phase6c2_pre.txt for the postcheck diff.

BEGIN READ ONLY;

SELECT 'precheck_at' AS section, now()::text AS value;

DO $phase6c2_precheck$
DECLARE
  _hash text;
BEGIN
  -- The enum has exactly the pre-6C.2 values.
  IF (SELECT string_agg(enumlabel, ',' ORDER BY enumsortorder) FROM pg_enum
      WHERE enumtypid = 'public.supply_request_status'::regtype)
     IS DISTINCT FROM 'submitted,under_review,approved,ordered,received,completed,denied' THEN
    RAISE EXCEPTION 'precheck: supply_request_status is not the expected pre-6C.2 enum';
  END IF;

  -- Nothing from 6C.2 exists yet.
  IF to_regprocedure('public.cancel_submitted_supply_request(uuid,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'precheck: cancel_submitted_supply_request already exists';
  END IF;
  IF EXISTS (SELECT 1 FROM public.supply_request_updates WHERE event_kind IS DISTINCT FROM NULL
             AND event_kind <> 'requester_edited') THEN
    RAISE EXCEPTION 'precheck: unexpected supply_request_updates.event_kind values exist';
  END IF;

  -- The Phase 6C objects 6C.2 depends on or replaces match the repository definitions
  -- (md5 of pg_get_functiondef / pg_get_constraintdef on a database migrated from main
  -- 5ddfe8a).
  FOR _hash IN
    SELECT format('%s=%s', expected.name, coalesce((
      SELECT md5(pg_get_functiondef(p.oid)) FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = expected.name), 'absent'))
    FROM (VALUES
      ('update_submitted_supply_request', '44e7e03982c7dd9ea27207bed0520fa4'),
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
    RAISE EXCEPTION 'precheck: function definition differs from repository main: %', _hash;
  END LOOP;

  IF (SELECT md5(pg_get_constraintdef(oid)) FROM pg_constraint
      WHERE conrelid = 'public.supply_request_updates'::regclass
        AND conname = 'supply_request_updates_event_kind_check')
     IS DISTINCT FROM 'c094b8e7839779b353989bfb6da92878' THEN
    RAISE EXCEPTION 'precheck: supply_request_updates_event_kind_check differs from Phase 6C';
  END IF;

  -- Each function the migration replaces has a single signature.
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = 'update_submitted_supply_request') <> 1 THEN
    RAISE EXCEPTION 'precheck: update_submitted_supply_request has an unexpected overload';
  END IF;
END
$phase6c2_precheck$;

SELECT 'precheck' AS section, 'assertions passed' AS value;

\ir fingerprint.sql

ROLLBACK;
