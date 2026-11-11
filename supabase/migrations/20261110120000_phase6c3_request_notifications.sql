-- Phase 6C.3: automatic request notifications and approver digests.
--
-- Durable, provider-neutral notification outbox. Email is the only V1 channel; the event model
-- carries no channel, provider or message body, so another channel (in_app) is one more
-- delivery row per recipient later, without changing events.
--
--   * notification_events: one row per notifiable source action. Written by two minimal
--     AFTER INSERT triggers in the SAME transaction as the source write (no network, no auth
--     lookups, no recipient lookup, no rendering): a new submitted supply request
--     (request_submitted; submission writes no supply_request_updates row) and an update row
--     moving a request to approved or denied (request_approved / request_denied). Every other
--     lifecycle change (under review, ordered, received, completed, requester edit, requester
--     cancel) creates no event. dedupe_key is unique, so the same source row can never produce
--     a second event; replayed decisions add no update row and therefore no event. Approver
--     digests are events too (approver_digest), one per organization per local date at most
--     (dedupe_key), written by enqueue_due_notification_digests.
--     If the event insert fails, the source transaction fails with it: a request transition
--     never commits without its event.
--   * notification_deliveries: one row per event, recipient and channel (unique), created by
--     dispatch_notification_events from the organization's CURRENT membership (approvers: every
--     active member satisfying is_org_admin, i.e. today owner and admin memberships; outcomes:
--     the requester). The actor is never notified of their own action. Status: pending ->
--     processing (claimed, leased) -> sent | pending (retry with backoff) | dead; or skipped
--     (eligibility rechecked at claim time). provider / provider_message_id / provider_metadata
--     are opaque values from whichever adapter sent it.
--   * organization_notification_settings: per organization. sending_enabled is the master
--     safety switch (default OFF; service role only; nothing is ever delivered while it is off,
--     and events raised while it is off are suppressed, never replayed later). The digest
--     preference (enabled, daily / weekdays / weekly, send hour, weekly weekday, IANA time
--     zone) is editable by organization admins. An organization without a row uses the
--     defaults: sending OFF, digest ON, daily, 08:00, Monday, America/New_York, 7 days.
--
-- Recipient email addresses are read from auth.users (the current sign-in address) only inside
-- claim_notification_deliveries, a service-role-only function. profiles.email is not used.
--
-- Access: all three tables have RLS on, no policies and no anon/authenticated grants
-- (service_role SELECT only). Admin clients use get/update_organization_notification_settings.
-- The worker (service role) uses enqueue_due_notification_digests,
-- dispatch_notification_events, claim_notification_deliveries and
-- complete_notification_delivery; set_organization_notification_sending is service role only.
--
-- Retry policy (complete_notification_delivery): at most 5 attempts; after a retryable failure
-- the next attempt waits 1, 5, 30, then 120 minutes; a permanent failure, the 5th failed
-- attempt, or an expired lease on the 5th attempt dead-letters the delivery. A lease (default
-- 300 s) that expires before completion makes the delivery claimable again (stale claim
-- recovery); a late completion with an old claim token is ignored. Events older than 24 hours
-- when first dispatched are expired instead of delivered.
--
-- Additive: three tables, their indexes, two triggers on supply_requests and
-- supply_request_updates, an updated_at trigger, and the functions below. No existing table,
-- column, policy, grant, function or row changes; request lifecycle functions are untouched.

BEGIN;

DO $preflight$
BEGIN
  IF pg_catalog.to_regclass('public.supply_requests') IS NULL
     OR pg_catalog.to_regclass('public.supply_request_updates') IS NULL
     OR pg_catalog.to_regclass('public.supply_request_items') IS NULL
     OR pg_catalog.to_regclass('public.organization_memberships') IS NULL
     OR pg_catalog.to_regprocedure('public.is_org_admin(uuid, uuid)') IS NULL
     OR pg_catalog.to_regprocedure('public.tg_set_updated_at()') IS NULL
     OR pg_catalog.to_regprocedure('public.cancel_submitted_supply_request(uuid, uuid)') IS NULL
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_enum e
                    WHERE e.enumtypid = 'public.supply_request_status'::regtype AND e.enumlabel = 'cancelled') THEN
    RAISE EXCEPTION 'Phase 6C.3 requires the request lifecycle through Phase 6C.2';
  END IF;
  IF pg_catalog.to_regclass('public.notification_events') IS NOT NULL
     OR pg_catalog.to_regclass('public.notification_deliveries') IS NOT NULL
     OR pg_catalog.to_regclass('public.organization_notification_settings') IS NOT NULL
     OR EXISTS (SELECT 1 FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public' AND p.proname IN (
                  'capture_supply_request_submitted_notification',
                  'capture_supply_request_decision_notification',
                  'get_organization_notification_settings',
                  'update_organization_notification_settings',
                  'set_organization_notification_sending',
                  'notification_request_items',
                  'notification_approver_digest_content',
                  'enqueue_due_notification_digests',
                  'dispatch_notification_events',
                  'claim_notification_deliveries',
                  'complete_notification_delivery')) THEN
    RAISE EXCEPTION 'Phase 6C.3 notification objects already exist unexpectedly';
  END IF;
END
$preflight$;

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------

CREATE TABLE public.organization_notification_settings (
  organization_id uuid PRIMARY KEY REFERENCES public.organizations(id) ON DELETE CASCADE,
  sending_enabled boolean NOT NULL DEFAULT false,
  digest_enabled boolean NOT NULL DEFAULT true,
  digest_frequency text NOT NULL DEFAULT 'daily'
    CONSTRAINT organization_notification_settings_frequency_check
      CHECK (digest_frequency IN ('daily', 'weekdays', 'weekly')),
  digest_send_hour smallint NOT NULL DEFAULT 8
    CONSTRAINT organization_notification_settings_hour_check CHECK (digest_send_hour BETWEEN 0 AND 23),
  digest_weekday smallint NOT NULL DEFAULT 1
    CONSTRAINT organization_notification_settings_weekday_check CHECK (digest_weekday BETWEEN 1 AND 7),
  timezone text NOT NULL DEFAULT 'America/New_York'
    CONSTRAINT organization_notification_settings_timezone_check
      CHECK (timezone ~ '^(UTC|[A-Za-z]+(/[A-Za-z0-9_+-]+){1,2})$'),
  ordered_receipt_threshold_days integer NOT NULL DEFAULT 7
    CONSTRAINT organization_notification_settings_threshold_check
      CHECK (ordered_receipt_threshold_days BETWEEN 1 AND 90),
  updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.notification_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  event_type text NOT NULL
    CONSTRAINT notification_events_type_check
      CHECK (event_type IN ('request_submitted', 'request_approved', 'request_denied', 'approver_digest')),
  entity_type text NOT NULL
    CONSTRAINT notification_events_entity_type_check CHECK (entity_type IN ('supply_request', 'organization')),
  entity_id uuid NOT NULL,
  source_type text NOT NULL
    CONSTRAINT notification_events_source_type_check
      CHECK (source_type IN ('supply_request', 'supply_request_update', 'digest_schedule')),
  source_id uuid,
  actor_id uuid,
  dedupe_key text NOT NULL CONSTRAINT notification_events_dedupe_key_key UNIQUE,
  context jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'pending'
    CONSTRAINT notification_events_status_check
      CHECK (status IN ('pending', 'dispatched', 'suppressed', 'expired')),
  status_reason text,
  recipient_count integer,
  created_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  CONSTRAINT notification_events_shape_check CHECK (
    (event_type = 'request_submitted' AND entity_type = 'supply_request' AND source_type = 'supply_request'
      AND source_id = entity_id)
    OR (event_type IN ('request_approved', 'request_denied') AND entity_type = 'supply_request'
      AND source_type = 'supply_request_update' AND source_id IS NOT NULL)
    OR (event_type = 'approver_digest' AND entity_type = 'organization' AND source_type = 'digest_schedule'
      AND entity_id = organization_id)
  ),
  CONSTRAINT notification_events_processed_check CHECK ((status = 'pending') = (processed_at IS NULL))
);

CREATE INDEX notification_events_pending_idx
  ON public.notification_events (created_at, id) WHERE status = 'pending';
CREATE INDEX notification_events_org_type_created_idx
  ON public.notification_events (organization_id, event_type, created_at DESC);
CREATE INDEX notification_events_entity_idx
  ON public.notification_events (entity_id);

CREATE TABLE public.notification_deliveries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  event_id uuid NOT NULL REFERENCES public.notification_events(id) ON DELETE CASCADE,
  channel text NOT NULL CONSTRAINT notification_deliveries_channel_check CHECK (channel IN ('email')),
  recipient_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  audience text NOT NULL CONSTRAINT notification_deliveries_audience_check CHECK (audience IN ('approver', 'requester')),
  status text NOT NULL DEFAULT 'pending'
    CONSTRAINT notification_deliveries_status_check
      CHECK (status IN ('pending', 'processing', 'sent', 'skipped', 'dead')),
  attempts integer NOT NULL DEFAULT 0 CONSTRAINT notification_deliveries_attempts_check CHECK (attempts BETWEEN 0 AND 5),
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  claim_token uuid,
  claimed_at timestamptz,
  claim_expires_at timestamptz,
  sent_at timestamptz,
  finished_at timestamptz,
  status_reason text,
  last_error text CONSTRAINT notification_deliveries_error_length_check CHECK (length(last_error) <= 500),
  provider text,
  provider_message_id text,
  provider_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT notification_deliveries_event_recipient_channel_key UNIQUE (event_id, recipient_user_id, channel),
  CONSTRAINT notification_deliveries_claim_check CHECK (
    (status = 'processing') = (claim_token IS NOT NULL AND claim_expires_at IS NOT NULL)
  ),
  CONSTRAINT notification_deliveries_sent_check CHECK ((status = 'sent') = (sent_at IS NOT NULL))
);

CREATE INDEX notification_deliveries_due_idx
  ON public.notification_deliveries (next_attempt_at, id) WHERE status = 'pending';
CREATE INDEX notification_deliveries_lease_idx
  ON public.notification_deliveries (claim_expires_at, id) WHERE status = 'processing';
CREATE INDEX notification_deliveries_org_created_idx
  ON public.notification_deliveries (organization_id, created_at DESC);
CREATE INDEX notification_deliveries_recipient_idx
  ON public.notification_deliveries (recipient_user_id);

CREATE TRIGGER organization_notification_settings_updated_at
  BEFORE UPDATE ON public.organization_notification_settings
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();
CREATE TRIGGER notification_deliveries_updated_at
  BEFORE UPDATE ON public.notification_deliveries
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

ALTER TABLE public.organization_notification_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notification_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notification_deliveries ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.organization_notification_settings, public.notification_events,
  public.notification_deliveries FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.organization_notification_settings, public.notification_events,
  public.notification_deliveries TO service_role;

-- ---------------------------------------------------------------------------------------------
-- Event capture (same transaction as the source write; one insert, nothing else)
-- ---------------------------------------------------------------------------------------------

CREATE FUNCTION public.capture_supply_request_submitted_notification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  INSERT INTO public.notification_events
    (organization_id, event_type, entity_type, entity_id, source_type, source_id, actor_id, dedupe_key)
  VALUES
    (NEW.organization_id, 'request_submitted', 'supply_request', NEW.id, 'supply_request', NEW.id,
     NEW.requested_by, 'request_submitted:' || NEW.id::text)
  ON CONFLICT ON CONSTRAINT notification_events_dedupe_key_key DO NOTHING;
  RETURN NULL;
END;
$$;

CREATE FUNCTION public.capture_supply_request_decision_notification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  _event_type text := CASE NEW.status_to WHEN 'approved' THEN 'request_approved' ELSE 'request_denied' END;
BEGIN
  INSERT INTO public.notification_events
    (organization_id, event_type, entity_type, entity_id, source_type, source_id, actor_id, dedupe_key)
  VALUES
    (NEW.organization_id, _event_type, 'supply_request', NEW.supply_request_id, 'supply_request_update', NEW.id,
     NEW.author_id, _event_type || ':' || NEW.id::text)
  ON CONFLICT ON CONSTRAINT notification_events_dedupe_key_key DO NOTHING;
  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.capture_supply_request_submitted_notification() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.capture_supply_request_decision_notification() FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER supply_requests_submitted_notification
  AFTER INSERT ON public.supply_requests
  FOR EACH ROW WHEN (NEW.status = 'submitted')
  EXECUTE FUNCTION public.capture_supply_request_submitted_notification();

CREATE TRIGGER supply_request_updates_decision_notification
  AFTER INSERT ON public.supply_request_updates
  FOR EACH ROW WHEN (NEW.status_to IN ('approved', 'denied'))
  EXECUTE FUNCTION public.capture_supply_request_decision_notification();

-- ---------------------------------------------------------------------------------------------
-- Organization settings (admin clients)
-- ---------------------------------------------------------------------------------------------

CREATE FUNCTION public.get_organization_notification_settings(_organization_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  _row public.organization_notification_settings%ROWTYPE;
BEGIN
  IF _organization_id IS NULL OR NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Forbidden: administrator access required' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO _row FROM public.organization_notification_settings WHERE organization_id = _organization_id;
  RETURN jsonb_build_object(
    'organizationId', _organization_id,
    'sendingEnabled', COALESCE(_row.sending_enabled, false),
    'digestEnabled', COALESCE(_row.digest_enabled, true),
    'digestFrequency', COALESCE(_row.digest_frequency, 'daily'),
    'digestSendHour', COALESCE(_row.digest_send_hour, 8),
    'digestWeekday', COALESCE(_row.digest_weekday, 1),
    'timezone', COALESCE(_row.timezone, 'America/New_York'),
    'orderedReceiptThresholdDays', COALESCE(_row.ordered_receipt_threshold_days, 7),
    'updatedAt', _row.updated_at
  );
END;
$$;

-- Digest preference only. The master sending switch and the aging threshold are not editable
-- here. The time zone must be a real IANA zone name known to the database.
CREATE FUNCTION public.update_organization_notification_settings(
  _organization_id uuid,
  _digest_enabled boolean,
  _digest_frequency text,
  _digest_send_hour integer,
  _digest_weekday integer,
  _timezone text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF _organization_id IS NULL OR NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Forbidden: administrator access required' USING ERRCODE = '42501';
  END IF;
  IF _digest_enabled IS NULL OR _digest_frequency IS NULL OR _digest_frequency NOT IN ('daily', 'weekdays', 'weekly') THEN
    RAISE EXCEPTION 'Choose Daily, Weekdays only or Weekly' USING ERRCODE = '22023';
  END IF;
  IF _digest_send_hour IS NULL OR _digest_send_hour NOT BETWEEN 0 AND 23 THEN
    RAISE EXCEPTION 'Choose a send time on the hour' USING ERRCODE = '22023';
  END IF;
  IF _digest_weekday IS NULL OR _digest_weekday NOT BETWEEN 1 AND 7 THEN
    RAISE EXCEPTION 'Choose a weekday' USING ERRCODE = '22023';
  END IF;
  IF _timezone IS NULL OR _timezone !~ '^(UTC|[A-Za-z]+(/[A-Za-z0-9_+-]+){1,2})$'
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name = _timezone) THEN
    RAISE EXCEPTION 'Choose a supported time zone' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.organization_notification_settings AS settings
    (organization_id, digest_enabled, digest_frequency, digest_send_hour, digest_weekday, timezone, updated_by)
  VALUES
    (_organization_id, _digest_enabled, _digest_frequency, _digest_send_hour, _digest_weekday, _timezone, auth.uid())
  ON CONFLICT (organization_id) DO UPDATE SET
    digest_enabled = EXCLUDED.digest_enabled,
    digest_frequency = EXCLUDED.digest_frequency,
    digest_send_hour = EXCLUDED.digest_send_hour,
    digest_weekday = EXCLUDED.digest_weekday,
    timezone = EXCLUDED.timezone,
    updated_by = EXCLUDED.updated_by;

  RETURN public.get_organization_notification_settings(_organization_id);
END;
$$;

-- The master safety switch. Service role only (release / acceptance operators).
CREATE FUNCTION public.set_organization_notification_sending(_organization_id uuid, _enabled boolean)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF _organization_id IS NULL OR _enabled IS NULL
     OR NOT EXISTS (SELECT 1 FROM public.organizations WHERE id = _organization_id) THEN
    RAISE EXCEPTION 'Organization not found' USING ERRCODE = 'P0002';
  END IF;
  INSERT INTO public.organization_notification_settings AS settings (organization_id, sending_enabled)
  VALUES (_organization_id, _enabled)
  ON CONFLICT (organization_id) DO UPDATE SET sending_enabled = EXCLUDED.sending_enabled;
  RETURN _enabled;
END;
$$;

-- ---------------------------------------------------------------------------------------------
-- Rendering context (service role only; rendered by the worker at delivery time)
-- ---------------------------------------------------------------------------------------------

-- The request's lines as they are NOW (multi-item requests insert their lines after the
-- request row, so this is never read at capture time).
CREATE FUNCTION public.notification_request_items(_organization_id uuid, _request_id uuid, _limit integer DEFAULT 10)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'itemCount', (SELECT count(*) FROM public.supply_request_items i
                  WHERE i.supply_request_id = _request_id AND i.organization_id = _organization_id),
    'items', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('label', listed.label, 'quantity', listed.quantity, 'unit', listed.unit)
                       ORDER BY listed.created_at, listed.id)
      FROM (
        SELECT i.id, i.created_at, i.quantity, i.unit,
          left(COALESCE(nullif(btrim(p.name), ''), nullif(btrim(i.free_text_item), ''), 'Item'), 200) AS label
        FROM public.supply_request_items i
        LEFT JOIN public.products p ON p.id = i.product_id AND p.organization_id = i.organization_id
        WHERE i.supply_request_id = _request_id AND i.organization_id = _organization_id
        ORDER BY i.created_at, i.id
        LIMIT GREATEST(_limit, 0)
      ) listed
    ), '[]'::jsonb)
  )
$$;

-- Actionable approver work at _now: awaiting review, under review, approved but not ordered,
-- ordered with no receipt for at least _threshold_days. Nothing else.
CREATE FUNCTION public.notification_approver_digest_content(
  _organization_id uuid,
  _now timestamptz,
  _threshold_days integer,
  _item_limit integer DEFAULT 10
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
  WITH candidates AS (
    SELECT r.id, r.status, r.requested_by, r.created_at,
      CASE
        WHEN r.status = 'submitted' THEN 'awaitingReview'
        WHEN r.status = 'under_review' THEN 'underReview'
        WHEN r.status = 'approved' THEN 'approvedNotOrdered'
        WHEN r.status = 'ordered' AND r.received_at IS NULL
             AND r.ordered_at <= _now - make_interval(days => _threshold_days) THEN 'orderedNotReceived'
      END AS section,
      CASE
        WHEN r.status = 'ordered' THEN r.ordered_at
        WHEN r.status IN ('under_review', 'approved') THEN COALESCE((
          SELECT max(u.created_at) FROM public.supply_request_updates u
          WHERE u.supply_request_id = r.id AND u.organization_id = r.organization_id AND u.status_to = r.status
        ), r.created_at)
        ELSE r.created_at
      END AS since
    FROM public.supply_requests r
    WHERE r.organization_id = _organization_id
      AND r.status IN ('submitted', 'under_review', 'approved', 'ordered')
  ),
  actionable AS (
    SELECT c.*, row_number() OVER (PARTITION BY c.section ORDER BY c.since, c.id) AS position
    FROM candidates c WHERE c.section IS NOT NULL
  ),
  sections AS (
    SELECT s.key,
      (SELECT count(*) FROM actionable a WHERE a.section = s.key) AS total,
      (SELECT min(a.since) FROM actionable a WHERE a.section = s.key) AS oldest,
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'requestId', a.id,
          'reference', upper(left(a.id::text, 8)),
          'requesterName', COALESCE(nullif(btrim(pr.full_name), ''), 'A team member'),
          'since', a.since,
          'items', public.notification_request_items(_organization_id, a.id, 3)
        ) ORDER BY a.position)
        FROM actionable a LEFT JOIN public.profiles pr ON pr.id = a.requested_by
        WHERE a.section = s.key AND a.position <= GREATEST(_item_limit, 0)
      ), '[]'::jsonb) AS items
    FROM (VALUES (1, 'awaitingReview'), (2, 'underReview'), (3, 'approvedNotOrdered'), (4, 'orderedNotReceived')) AS s(ord, key)
  )
  SELECT jsonb_build_object(
    'totalCount', (SELECT count(*) FROM actionable),
    'thresholdDays', _threshold_days,
    'sections', jsonb_object_agg(sections.key, jsonb_build_object(
      'count', sections.total, 'oldestAt', sections.oldest, 'items', sections.items))
  )
  FROM sections
$$;

-- ---------------------------------------------------------------------------------------------
-- Worker functions (service role only)
-- ---------------------------------------------------------------------------------------------

-- Creates the approver digest event of every organization that is due at _now, at most one per
-- organization per local date (dedupe_key) and, for Weekly, one per local ISO week. A due
-- organization with nothing actionable gets a suppressed event, so the day is evaluated once
-- and no empty digest is ever sent. Only organizations whose master switch is ON are considered.
CREATE FUNCTION public.enqueue_due_notification_digests(_now timestamptz DEFAULT now())
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  _settings record;
  _local timestamp;
  _local_date date;
  _iso_week text;
  _content jsonb;
  _created integer := 0;
  _inserted integer;
BEGIN
  IF _now IS NULL THEN
    RAISE EXCEPTION 'now is required' USING ERRCODE = '22004';
  END IF;
  FOR _settings IN
    SELECT s.* FROM public.organization_notification_settings s
    WHERE s.sending_enabled AND s.digest_enabled
    ORDER BY s.organization_id
  LOOP
    _local := _now AT TIME ZONE _settings.timezone;
    _local_date := _local::date;
    _iso_week := to_char(_local, 'IYYY-"W"IW');
    CONTINUE WHEN extract(hour FROM _local)::integer < _settings.digest_send_hour;
    CONTINUE WHEN _settings.digest_frequency = 'weekdays' AND extract(isodow FROM _local)::integer > 5;
    CONTINUE WHEN _settings.digest_frequency = 'weekly'
      AND extract(isodow FROM _local)::integer <> _settings.digest_weekday;
    CONTINUE WHEN EXISTS (
      SELECT 1 FROM public.notification_events e
      WHERE e.dedupe_key = 'approver_digest:' || _settings.organization_id::text || ':' || _local_date::text);
    CONTINUE WHEN _settings.digest_frequency = 'weekly' AND EXISTS (
      SELECT 1 FROM public.notification_events e
      WHERE e.organization_id = _settings.organization_id AND e.event_type = 'approver_digest'
        AND e.context ->> 'frequency' = 'weekly' AND e.context ->> 'isoWeek' = _iso_week);

    _content := public.notification_approver_digest_content(
      _settings.organization_id, _now, _settings.ordered_receipt_threshold_days, 0);

    INSERT INTO public.notification_events
      (organization_id, event_type, entity_type, entity_id, source_type, source_id, dedupe_key, context,
       status, status_reason, processed_at)
    VALUES
      (_settings.organization_id, 'approver_digest', 'organization', _settings.organization_id, 'digest_schedule', NULL,
       'approver_digest:' || _settings.organization_id::text || ':' || _local_date::text,
       jsonb_build_object('localDate', _local_date, 'isoWeek', _iso_week, 'frequency', _settings.digest_frequency,
                          'timezone', _settings.timezone, 'sendHour', _settings.digest_send_hour,
                          'thresholdDays', _settings.ordered_receipt_threshold_days),
       CASE WHEN (_content ->> 'totalCount')::integer > 0 THEN 'pending' ELSE 'suppressed' END,
       CASE WHEN (_content ->> 'totalCount')::integer > 0 THEN NULL ELSE 'nothing_actionable' END,
       CASE WHEN (_content ->> 'totalCount')::integer > 0 THEN NULL ELSE _now END)
    ON CONFLICT ON CONSTRAINT notification_events_dedupe_key_key DO NOTHING;
    GET DIAGNOSTICS _inserted = ROW_COUNT;
    _created := _created + _inserted;
  END LOOP;
  RETURN _created;
END;
$$;

-- Turns pending events into deliveries for the organization's current recipients. Events of an
-- organization whose master switch is OFF are suppressed (never delivered later); events older
-- than 24 hours are expired. Concurrent workers skip each other's locked events.
CREATE FUNCTION public.dispatch_notification_events(_limit integer DEFAULT 100, _now timestamptz DEFAULT now())
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  _event public.notification_events%ROWTYPE;
  _sending boolean;
  _requester uuid;
  _count integer;
  _processed integer := 0;
BEGIN
  FOR _event IN
    SELECT * FROM public.notification_events
    WHERE status = 'pending'
    ORDER BY created_at, id
    LIMIT GREATEST(COALESCE(_limit, 100), 0)
    FOR UPDATE SKIP LOCKED
  LOOP
    _processed := _processed + 1;
    SELECT s.sending_enabled INTO _sending
    FROM public.organization_notification_settings s WHERE s.organization_id = _event.organization_id;

    IF NOT COALESCE(_sending, false) THEN
      UPDATE public.notification_events
      SET status = 'suppressed', status_reason = 'sending_disabled', processed_at = _now, recipient_count = 0
      WHERE id = _event.id;
      CONTINUE;
    END IF;
    IF _event.created_at < _now - interval '24 hours' THEN
      UPDATE public.notification_events
      SET status = 'expired', status_reason = 'too_old', processed_at = _now, recipient_count = 0
      WHERE id = _event.id;
      CONTINUE;
    END IF;

    IF _event.event_type IN ('request_submitted', 'approver_digest') THEN
      INSERT INTO public.notification_deliveries (organization_id, event_id, channel, recipient_user_id, audience)
      SELECT DISTINCT _event.organization_id, _event.id, 'email', m.user_id, 'approver'
      FROM public.organization_memberships m
      WHERE m.organization_id = _event.organization_id
        AND m.active
        AND public.is_org_admin(_event.organization_id, m.user_id)
        AND m.user_id IS DISTINCT FROM _event.actor_id
      ON CONFLICT ON CONSTRAINT notification_deliveries_event_recipient_channel_key DO NOTHING;
    ELSE
      SELECT r.requested_by INTO _requester
      FROM public.supply_requests r
      WHERE r.id = _event.entity_id AND r.organization_id = _event.organization_id;
      IF _requester IS NOT NULL AND _requester IS DISTINCT FROM _event.actor_id THEN
        INSERT INTO public.notification_deliveries (organization_id, event_id, channel, recipient_user_id, audience)
        VALUES (_event.organization_id, _event.id, 'email', _requester, 'requester')
        ON CONFLICT ON CONSTRAINT notification_deliveries_event_recipient_channel_key DO NOTHING;
      END IF;
    END IF;

    SELECT count(*) INTO _count FROM public.notification_deliveries WHERE event_id = _event.id;
    UPDATE public.notification_events
    SET status = 'dispatched', processed_at = _now, recipient_count = _count,
        status_reason = CASE WHEN _count = 0 THEN 'no_recipients' END
    WHERE id = _event.id;
  END LOOP;
  RETURN _processed;
END;
$$;

-- Claims due deliveries (pending and due, or processing with an expired lease) for one worker.
-- Concurrent workers never claim the same row (FOR UPDATE SKIP LOCKED). Eligibility is checked
-- again here, immediately before delivery; ineligible deliveries are skipped, never sent. Returns
-- the recipient's current sign-in email and the rendering context (current request state; the
-- staff-visible note for denials; never an internal note).
CREATE FUNCTION public.claim_notification_deliveries(
  _limit integer DEFAULT 20,
  _lease_seconds integer DEFAULT 300,
  _now timestamptz DEFAULT now()
)
RETURNS TABLE (
  delivery_id uuid,
  claim_token uuid,
  attempt integer,
  channel text,
  event_type text,
  recipient_email text,
  context jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
  _delivery public.notification_deliveries%ROWTYPE;
  _event public.notification_events%ROWTYPE;
  _request public.supply_requests%ROWTYPE;
  _settings public.organization_notification_settings%ROWTYPE;
  _email text;
  _reason text;
  _context jsonb;
  _token uuid;
BEGIN
  IF COALESCE(_lease_seconds, 0) NOT BETWEEN 30 AND 3600 THEN
    RAISE EXCEPTION 'lease must be between 30 and 3600 seconds' USING ERRCODE = '22023';
  END IF;
  FOR _delivery IN
    SELECT * FROM public.notification_deliveries d
    WHERE (d.status = 'pending' AND d.next_attempt_at <= _now)
       OR (d.status = 'processing' AND d.claim_expires_at <= _now)
    ORDER BY CASE WHEN d.status = 'processing' THEN d.claim_expires_at ELSE d.next_attempt_at END, d.id
    LIMIT GREATEST(COALESCE(_limit, 20), 0)
    FOR UPDATE SKIP LOCKED
  LOOP
    -- An expired lease on the last allowed attempt dead-letters instead of retrying.
    IF _delivery.status = 'processing' AND _delivery.attempts >= 5 THEN
      UPDATE public.notification_deliveries
      SET status = 'dead', status_reason = 'lease_expired', claim_token = NULL, claim_expires_at = NULL,
          finished_at = _now
      WHERE id = _delivery.id;
      CONTINUE;
    END IF;

    SELECT * INTO _event FROM public.notification_events WHERE id = _delivery.event_id;
    SELECT * INTO _settings FROM public.organization_notification_settings WHERE organization_id = _delivery.organization_id;
    _reason := NULL;
    _email := NULL;
    _request := NULL;

    IF NOT COALESCE(_settings.sending_enabled, false) THEN
      _reason := 'sending_disabled';
    ELSIF NOT EXISTS (SELECT 1 FROM public.organization_memberships m
                      WHERE m.organization_id = _delivery.organization_id AND m.user_id = _delivery.recipient_user_id
                        AND m.active) THEN
      _reason := 'recipient_inactive';
    ELSIF _delivery.audience = 'approver'
          AND NOT COALESCE(public.is_org_admin(_delivery.organization_id, _delivery.recipient_user_id), false) THEN
      _reason := 'recipient_not_admin';
    END IF;

    IF _reason IS NULL AND _event.entity_type = 'supply_request' THEN
      SELECT * INTO _request FROM public.supply_requests
      WHERE id = _event.entity_id AND organization_id = _event.organization_id;
      IF NOT FOUND THEN
        _reason := 'source_missing';
      ELSIF _delivery.audience = 'requester' AND _request.requested_by IS DISTINCT FROM _delivery.recipient_user_id THEN
        _reason := 'recipient_not_requester';
      END IF;
    END IF;

    IF _reason IS NULL THEN
      SELECT nullif(btrim(u.email), '') INTO _email FROM auth.users u
      WHERE u.id = _delivery.recipient_user_id AND u.deleted_at IS NULL;
      IF _email IS NULL THEN
        _reason := 'no_email';
      END IF;
    END IF;

    IF _reason IS NULL THEN
      _context := jsonb_build_object(
        'organizationName', (SELECT o.name FROM public.organizations o WHERE o.id = _delivery.organization_id),
        'recipientName', (SELECT nullif(btrim(p.full_name), '') FROM public.profiles p WHERE p.id = _delivery.recipient_user_id),
        'audience', _delivery.audience,
        'timezone', COALESCE(_settings.timezone, 'America/New_York'));
      IF _event.event_type = 'approver_digest' THEN
        _context := _context || jsonb_build_object(
          'digest', public.notification_approver_digest_content(
            _delivery.organization_id, _now, COALESCE((_event.context ->> 'thresholdDays')::integer, 7), 10),
          'localDate', _event.context ->> 'localDate',
          'frequency', _event.context ->> 'frequency',
          'timezone', _event.context ->> 'timezone');
        IF ((_context -> 'digest') ->> 'totalCount')::integer = 0 THEN
          _reason := 'nothing_actionable';
        END IF;
      ELSE
        _context := _context || jsonb_build_object(
          'requestId', _request.id,
          'reference', upper(left(_request.id::text, 8)),
          'requestType', _request.request_type,
          'submittedAt', _request.created_at,
          'requesterName', COALESCE((SELECT nullif(btrim(p.full_name), '') FROM public.profiles p WHERE p.id = _request.requested_by), 'A team member'),
          'items', public.notification_request_items(_delivery.organization_id, _request.id, 10));
        IF _event.event_type = 'request_submitted' THEN
          _context := _context || jsonb_build_object('requestNote', left(nullif(btrim(_request.notes), ''), 1000));
        ELSE
          _context := _context || jsonb_build_object(
            'decidedAt', (SELECT u.created_at FROM public.supply_request_updates u WHERE u.id = _event.source_id));
          IF _event.event_type = 'request_denied' THEN
            -- Only the staff-visible note of the denial row. The internal note is never read.
            _context := _context || jsonb_build_object('staffVisibleNote', (
              SELECT left(nullif(btrim(u.staff_visible_note), ''), 2000)
              FROM public.supply_request_updates u
              WHERE u.id = _event.source_id AND u.organization_id = _delivery.organization_id));
          END IF;
        END IF;
      END IF;
    END IF;

    IF _reason IS NOT NULL THEN
      UPDATE public.notification_deliveries
      SET status = 'skipped', status_reason = _reason, claim_token = NULL, claim_expires_at = NULL, finished_at = _now
      WHERE id = _delivery.id;
      CONTINUE;
    END IF;

    _token := gen_random_uuid();
    UPDATE public.notification_deliveries
    SET status = 'processing', attempts = attempts + 1, claim_token = _token, claimed_at = _now,
        claim_expires_at = _now + make_interval(secs => _lease_seconds)
    WHERE id = _delivery.id;

    delivery_id := _delivery.id;
    claim_token := _token;
    attempt := _delivery.attempts + 1;
    channel := _delivery.channel;
    event_type := _event.event_type;
    recipient_email := _email;
    context := _context;
    RETURN NEXT;
  END LOOP;
END;
$$;

-- Records the outcome of one claimed delivery. Only the current claim may complete it: a late
-- completion after the lease expired and the row was reclaimed (different token) is ignored
-- and returns 'stale_claim'.
CREATE FUNCTION public.complete_notification_delivery(
  _delivery_id uuid,
  _claim_token uuid,
  _outcome text,
  _provider text DEFAULT NULL,
  _provider_message_id text DEFAULT NULL,
  _error text DEFAULT NULL,
  _provider_metadata jsonb DEFAULT NULL,
  _now timestamptz DEFAULT now()
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  _delivery public.notification_deliveries%ROWTYPE;
  _status text;
BEGIN
  IF _outcome IS NULL OR _outcome NOT IN ('sent', 'retryable_failure', 'permanent_failure') THEN
    RAISE EXCEPTION 'unknown delivery outcome' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO _delivery FROM public.notification_deliveries WHERE id = _delivery_id FOR UPDATE;
  IF NOT FOUND OR _delivery.status <> 'processing' OR _delivery.claim_token IS DISTINCT FROM _claim_token THEN
    RETURN 'stale_claim';
  END IF;

  IF _outcome = 'sent' THEN
    _status := 'sent';
    UPDATE public.notification_deliveries
    SET status = 'sent', sent_at = _now, finished_at = _now, claim_token = NULL, claim_expires_at = NULL,
        status_reason = NULL, last_error = NULL, provider = left(_provider, 50),
        provider_message_id = left(_provider_message_id, 200),
        provider_metadata = COALESCE(_provider_metadata, '{}'::jsonb)
    WHERE id = _delivery_id;
  ELSIF _outcome = 'permanent_failure' OR _delivery.attempts >= 5 THEN
    _status := 'dead';
    UPDATE public.notification_deliveries
    SET status = 'dead', finished_at = _now, claim_token = NULL, claim_expires_at = NULL,
        status_reason = CASE WHEN _outcome = 'permanent_failure' THEN 'rejected' ELSE 'retries_exhausted' END,
        last_error = left(_error, 500), provider = left(_provider, 50),
        provider_metadata = COALESCE(_provider_metadata, provider_metadata)
    WHERE id = _delivery_id;
  ELSE
    _status := 'pending';
    UPDATE public.notification_deliveries
    SET status = 'pending', claim_token = NULL, claim_expires_at = NULL,
        next_attempt_at = _now + CASE _delivery.attempts
          WHEN 1 THEN interval '1 minute'
          WHEN 2 THEN interval '5 minutes'
          WHEN 3 THEN interval '30 minutes'
          ELSE interval '120 minutes' END,
        status_reason = 'retry_scheduled', last_error = left(_error, 500), provider = left(_provider, 50)
    WHERE id = _delivery_id;
  END IF;
  RETURN _status;
END;
$$;

-- ---------------------------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.get_organization_notification_settings(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_organization_notification_settings(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.update_organization_notification_settings(uuid, boolean, text, integer, integer, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.update_organization_notification_settings(uuid, boolean, text, integer, integer, text)
  TO authenticated;

REVOKE ALL ON FUNCTION public.set_organization_notification_sending(uuid, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.notification_request_items(uuid, uuid, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.notification_approver_digest_content(uuid, timestamptz, integer, integer)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.enqueue_due_notification_digests(timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dispatch_notification_events(integer, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.claim_notification_deliveries(integer, integer, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.complete_notification_delivery(uuid, uuid, text, text, text, text, jsonb, timestamptz)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.set_organization_notification_sending(uuid, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.notification_request_items(uuid, uuid, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.notification_approver_digest_content(uuid, timestamptz, integer, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.enqueue_due_notification_digests(timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.dispatch_notification_events(integer, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.claim_notification_deliveries(integer, integer, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.complete_notification_delivery(uuid, uuid, text, text, text, text, jsonb, timestamptz)
  TO service_role;

COMMENT ON TABLE public.notification_events IS
  'Phase 6C.3 durable notification events (provider- and channel-neutral; no rendered bodies). Service role only.';
COMMENT ON TABLE public.notification_deliveries IS
  'Phase 6C.3 deliveries: one per event, recipient and channel; claimed with leases, retried with backoff, dead-lettered after 5 attempts.';
COMMENT ON TABLE public.organization_notification_settings IS
  'Phase 6C.3 organization notification settings: master sending switch (service role only, default off) and the approver digest preference (admins).';

COMMIT;
