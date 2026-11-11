# Phase 6C.3 release checks

These scripts check the Phase 6C.3 migration on production. They are read-only and migrate nothing themselves.

Production is migrated by hand in the Supabase SQL Editor. Never use `supabase db push`: the migration history does not record hand-applied migrations (see `../phase7a1/README.md`, "Migration history").

Every file here works in the SQL Editor exactly as written: no psql meta-commands, no transaction control. `precheck.sql` and `postcheck.sql` are each one DO block of assertions followed by the shared fingerprint SELECT (`fingerprint.sql`), so the result grid is the full output. The migration creates three tables and enables RLS on each in the same file, so the Editor's "Run and enable RLS" check has nothing to flag and must not appear. `supabase/tests/phase6c3_release_check.sh` proves all of this on a seeded copy (organizations with owner, admin and staff memberships, requests submitted and decided through the real lifecycle, a commitment, a budget, invoices, the catalog, inventory and counts), sending each file the way the Editor does.

`fingerprint.sql` is the source. `precheck.sql` and `postcheck.sql` are generated from it by `supabase/tests/support/phase6c3_release_generate.mjs` (expected values read, read-only, from a disposable database on main `c2891f6` and the same with this migration); never edit them by hand. The release check fails if the committed files are not exactly what the generator produces.

## What the checks pin

- **Functions (32 existing + 12 new)**, by body hash, SECURITY DEFINER and who may execute them (authenticated, anon, service_role, PUBLIC); asserted in both DO blocks:
  - the request lifecycle (`submit_supply_request`, `decide_supply_request`, `transition_supply_request`, `apply_supply_request_transition`, the lifecycle guard, item replacement, requester edit and cancellation, context, item costs, staff updates, commitments). 6C.3 changes none of them: events are captured by two new triggers;
  - the organization role helpers `has_org_role`, `is_org_admin`, `is_org_member` (approver recipients are resolved with `is_org_admin`) and `tg_set_updated_at`;
  - budgets, invoice posting and deletion, inventory, count cadence, 6C.4 batch intake and 5A.10 discovery.
- **Table definitions** (columns, types, NOT NULL, RLS), **policies** and **grants** of the new tables and of `supply_requests`, `supply_request_updates`, `supply_request_items`, `supply_request_commitments`, `organizations`, `organization_memberships`, `profiles`, `organization_budgets` and the 6C.4 packet tables. The definitions of the request, membership, organization and profile tables are also asserted in both DO blocks, with the organization roles (`owner`, `admin`, `staff`) and request statuses.
- **Constraints, indexes and triggers** of the new tables, the request tables and memberships.
- **Whole-row data hashes**: `supply_requests`, `supply_request_updates`, `supply_request_items`, `supply_request_commitments`, `organizations`, `organization_memberships`, `profiles`, `organization_budgets`, `invoices`, `inventory_items`, `inventory_adjustments`, `invoice_upload_batches`, `invoice_upload_batch_segments`; row counts of the new tables. Data is compared precheck → postcheck (production's own values).
- **Counts** of public functions, tables, indexes, policies and triggers, asserted in both DO blocks, and the absence of every 6C.3 object before the migration.

## One migration, before the deploy

**`20261110120000_phase6c3_request_notifications.sql`** adds:

- **Table `notification_events`**: durable, provider- and channel-neutral events (organization, event type, entity and source record, actor, `dedupe_key` UNIQUE, status `pending` / `dispatched` / `suppressed` / `expired`). No rendered bodies.
- **Table `notification_deliveries`**: one per event, recipient and channel (UNIQUE), V1 channel `email`; status `pending` / `processing` / `sent` / `skipped` / `dead`, attempts, next attempt, lease (claim token and expiry), sent time, last error, and opaque `provider` / `provider_message_id` / `provider_metadata`.
- **Table `organization_notification_settings`**: `sending_enabled` (master switch, default OFF) with `sending_enabled_at` (the delivery boundary, see below), digest preference (enabled, `daily` / `weekdays` / `weekly`, send hour, weekly weekday, IANA time zone) and the ordered-without-receipt threshold (7 days). No rows are created: every organization uses the defaults, with sending OFF.
- All three: RLS on, no policies, `service_role` SELECT only, no `anon` / `authenticated` grants. Two `updated_at` triggers.
- **Sending boundary guard** (`organization_notification_settings_sending_boundary`, BEFORE INSERT OR UPDATE, function `guard_notification_sending_boundary`): turning sending ON (OFF → ON, or a new row created ON) records `sending_enabled_at = clock_timestamp()` after taking a SHARE ROW EXCLUSIVE lock on `notification_events`; every other write keeps the stored value, so it cannot be set or backdated directly. Events take `created_at` from `clock_timestamp()` at insert. Dispatch and delivery-time claim only accept events created at or after the current boundary (others are recorded as `created_before_sending_enabled`); digest slots scheduled before it are never enqueued.
- **Two event-capture triggers** (one INSERT each, no lookups): `supply_requests_submitted_notification` (AFTER INSERT, new submitted request) and `supply_request_updates_decision_notification` (AFTER INSERT, update row moving a request to approved or denied). If the event insert fails, the request write fails with it. Under review, ordered, received, completed, requester edits and cancellations raise no event.
- **Admin client functions** (`authenticated` EXECUTE, `is_org_admin` checked inside): `get_organization_notification_settings`, `update_organization_notification_settings` (digest preference only; the time zone must exist in `pg_timezone_names`).
- **Service-role functions** (no client EXECUTE): `enqueue_due_notification_digests`, `dispatch_notification_events`, `claim_notification_deliveries` (FOR UPDATE SKIP LOCKED, eligibility rechecked, sign-in email from `auth.users`), `complete_notification_delivery`, `set_organization_notification_sending`, `notification_request_items`, `notification_approver_digest_content`.

No existing table, column, policy, grant, function or row changes. The only additions to existing tables are the two AFTER INSERT triggers.

## Order (SQL Editor)

Run each file as its own query: paste the whole file, run it once, and read the result before going on. Run steps 1–3 back to back.

1. **`precheck.sql`**
   - Success: a grid of fingerprint rows. Download as `phase6c3_pre.csv`.
   - STOP on any error. `precheck: Phase 6C.3 objects already exist` means step 2 already ran; do not run it again. `function is missing or differs from the reviewed production state`, `table is missing or differs from the reviewed production state`, `organization roles or request statuses differ` or `public object counts differ` means production drifted from main `c2891f6`.
2. **`20261110120000_phase6c3_request_notifications.sql`**
   - One transaction with a preflight; any error rolls everything back.
   - The Editor must **not** offer "Run and enable RLS". If it does, stop.
   - Success: no error, no rows. It creates empty tables, triggers and functions only.
   - STOP on any error and run `precheck.sql` again: it passes with the same rows (nothing was left behind), or reports that 6C.3 objects exist (the migration committed; run `postcheck.sql`, never the migration again).
3. **`postcheck.sql`**
   - Success: fingerprint rows; save as `phase6c3_post.csv`. Compare with step 1: only the lines below may differ.
   - STOP on any error.
4. **Deploy the application.** The deploy adds the Settings section and the Worker's scheduled handler and cron trigger (`wrangler.jsonc`, every 5 minutes). Migrate first: the Settings section calls `get_organization_notification_settings`.

## Expected differences (precheck → postcheck)

- **New functions** (`absent` → hash): the twelve above. `get_organization_notification_settings` and `update_organization_notification_settings` are `secdef=true authenticated=true anon=false service_role=false public=false`; the seven worker and helper functions `secdef=true authenticated=false anon=false service_role=true public=false`; the three trigger functions `secdef=true authenticated=false anon=false service_role=false public=false`.
- **New tables** (`absent` → column hash with `rls=true`), their `grants` lines (`none` → `service_role=SELECT`), `policies` stay `none`, new `constraint` lines for them, twelve new `index` lines and five new `trigger` lines (two `updated_at`, `organization_notification_settings.organization_notification_settings_sending_boundary`, `supply_requests.supply_requests_submitted_notification`, `supply_request_updates.supply_request_updates_decision_notification`).
- **Counts**: public functions +12, tables +3, indexes +12, triggers +5; policies unchanged. On the current production baseline: functions 149 → 161, tables 48 → 51, indexes 181 → 193, triggers 76 → 81, policies 58.
- **Rows**: `notification_events count`, `notification_deliveries count` and `organization_notification_settings count` go from `absent` to `0`.

Everything else must be identical. Real use between the precheck and the postcheck (a request submitted or decided) changes the matching `rows` lines and, after the migration, adds pending `notification_events` rows; the postcheck accepts pending request events but no deliveries, settings rows or digests.

## Rollout after the deploy (separate, explicit acceptance step)

Nothing is emailed until all of these are true:

1. The Worker has the secrets `SUPABASE_SERVICE_ROLE_KEY` and `RESEND_API_KEY` (configured manually; this phase sets neither). Without them every scheduled run logs `notifications: skipped (…missing …)` by binding name and touches nothing.
2. `notify.sport-spend.com` is verified in Resend for the sender `SportSpend <notifications@notify.sport-spend.com>`.
3. The organization's master switch is turned on, only during production acceptance, with `SELECT public.set_organization_notification_sending('<organization id>', true);` (service role / SQL Editor). Turning it off again with `false` stops every send at the next claim, including deliveries already queued.

The switch is a durable delivery boundary enforced by the database, independent of the order of these steps or of Worker runs:

- Events created while sending is OFF, including every event recorded between the migration and an organization's first enablement, never become deliverable. When the Worker next sees them they are suppressed with the reason `created_before_sending_enabled` (or `sending_disabled` while still OFF). Enabling never sends a backlog.
- Turning sending ON sets a new boundary (`sending_enabled_at`); turning it OFF stops every send at the next claim; OFF → ON again sets a later boundary, so neither OFF-period events nor deliveries queued before the OFF ever replay.
- Enabling and event writes are serialized by the boundary lock: an event written by a transaction still open when sending is enabled is ordered before the boundary; one written while the enabling transaction is open waits and is ordered after it.
- Digests: only slots scheduled at or after the boundary are sent. Enabling at 10:00 with a daily 08:00 digest sends the next digest at 08:00 the following day; it summarizes the requests that need action at that time (current state, not a replay of past events).

## Provenance

Hashes come from a disposable `public.ecr.aws/supabase/postgres:17.6.1.167` migrated from main `c2891f6` (production's application commit, Phase 6C.4 and its hotfix) plus this migration. The main-only database reproduces the production baseline counts (149 / 48 / 181 / 58 / 76), and every pinned function hash and table definition is identical before and after the migration. Regenerate with both databases running: `node supabase/tests/support/phase6c3_release_generate.mjs --pre <port> --post <port>` (`--check` compares without writing). `phase6c3_release_check.sh` runs the whole sequence on a seeded copy, including an induced failure before `COMMIT` (complete rollback), a refused second application and a refused repeat precheck.
