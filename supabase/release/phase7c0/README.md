# Phase 7C.0 release checks

These scripts check the Phase 7C.0 release on production: two migrations, applied in order (a stale-screen fix to `decide_supply_request`, then the workflow profiles). They are read-only and migrate nothing themselves.

Production is migrated by hand in the Supabase SQL Editor. Never use `supabase db push`: the migration history does not record hand-applied migrations (see `../phase7a1/README.md`, "Migration history").

Every file here works in the SQL Editor exactly as written: no psql meta-commands, no transaction control. `precheck.sql` and `postcheck.sql` are each one DO block of assertions followed by the shared fingerprint SELECT (`fingerprint.sql`), so the result grid is the full output. The migration creates one table and enables RLS on it in the same file, so the Editor's "Run and enable RLS" check has nothing to flag and must not appear. `supabase/tests/phase7c0_release_check.sh` proves all of this on a seeded copy (organizations with owner, admin and staff memberships, requests submitted, decided and ordered through the real lifecycle, notification events, a commitment, a budget, invoices, the catalog, inventory and counts), sending each file the way the Editor does.

`fingerprint.sql` is the source. `precheck.sql` and `postcheck.sql` are generated from it by `supabase/tests/support/phase7c0_release_generate.mjs` (expected values read, read-only, from a disposable database on main `79a2c49` and the same with this migration); never edit them by hand. The release check fails if the committed files are not exactly what the generator produces.

## What the checks pin

- **Functions (42 unchanged + 2 changed + 10 new)**, by body hash, SECURITY DEFINER and who may execute them; asserted in both DO blocks:
  - the request lifecycle (`submit_supply_request`, `transition_supply_request`, `apply_supply_request_transition`, the lifecycle guard, item replacement, requester edit and cancellation, context, item costs, commitments). 7C.0 changes none of them: the compound actions call them;
  - the 6C.3 notification functions and the canonical digest (`capture_supply_request_decision_notification`, `notification_approver_digest_content`, dispatch, claim, settings). Unchanged;
  - the organization role helpers `has_org_role`, `is_org_admin`, `is_org_member` and `tg_set_updated_at`;
  - budgets, invoice posting and deletion, inventory, count cadence, 6C.4 batch intake and 5A.10 discovery.
- **The two changed functions**, each pinned at its reviewed body in the precheck and its new body in the postcheck:
  - `decide_supply_request`: identical except that a stale screen raises SQLSTATE `55000` instead of `40001` (first migration);
  - `list_staff_supply_request_updates`: same arguments, filter, ordering and grants, with `compound_action` appended to the result (7C.0).
- **Table definitions** (columns, types, NOT NULL, RLS), **policies** and **grants** of the new table and of the request, commitment, notification, organization, membership, profile, budget and 6C.4 packet tables. `supply_request_updates` is pinned before (precheck) and after (postcheck, one new nullable column).
- **Constraints, indexes and triggers** of the new table, the request tables and memberships.
- **Whole-row data hashes**: requests, request history (hashed without the new `compound_action` key, so the line compares across the migration), items, commitments, notification events and settings, organizations, memberships, profiles, budgets, invoices, inventory items and adjustments, and the 6C.4 packet tables; the number of history rows carrying a compound marker; row counts of the new table and of `notification_deliveries`.
- **Counts** of public functions, tables, indexes, policies and triggers, asserted in both DO blocks, and the absence of every 7C.0 object before the migration.

## Two migrations, in order, before the deploy

**1. `20261112110000_decide_stale_screen_sqlstate.sql`** re-creates `decide_supply_request` with its Phase 6C body, changing only the stale-screen refusal ("This request changed while you were reviewing it…") from SQLSTATE `40001` to `55000`. PostgREST treats `40001` as a serialization failure and retries the call: a stale Approve or Decline never answered, and PostgREST kept re-running the rolled-back transaction thousands of times per second, even after the client disconnected (reproduced locally on PostgREST v14.15; nothing was ever written). With `55000` the admin gets the stale-screen message at once. Signature, message, authorization, row lock, reviewed-version check, same-decision retry, transitions, commitments and notification events are unchanged; grants are restated unchanged. Its preflight refuses a second application. It sorts before 7C.0 and could also ship on its own.

**2. `20261112120000_phase7c0_request_workflow_profiles.sql`** adds:

- **Table `organization_request_workflow_settings`**: `organization_id` (primary key), `workflow_profile` (`lean` / `standard` / `detailed`, default `detailed`), `updated_by`, `created_at`, `updated_at`. RLS on, no policies, `service_role` SELECT only, no client grants; one `updated_at` trigger. **No rows are created: every organization, FC Cincinnati included, stays Detailed (today's behavior) until an admin chooses another profile.**
- **Column `supply_request_updates.compound_action`** (nullable text), with a check constraint (`approve_and_order` only on under_review / approved / ordered rows, `receive_and_complete` only on received / completed rows, never on requester events) and a guard trigger (`supply_request_updates_compound_action_guard`, BEFORE INSERT OR UPDATE OF compound_action) that refuses client-written markers. Existing rows stay NULL.
- **Client functions** (`authenticated` EXECUTE; access checked inside):
  - `get_request_workflow_profile` (any active member; returns the profile only),
  - `get_organization_request_workflow_settings`, `update_organization_request_workflow_settings` (`is_org_admin`: every active owner or admin),
  - `approve_and_order_supply_request` (Lean only; reviewed-version check; `decide_supply_request` for the approval, then the ordered transition),
  - `receive_and_complete_supply_request` (Lean and Standard; the shared receive path, then completion),
  - `receive_supply_request` (Mark Received through the shared receive path; any profile).
- **Private functions** (no client EXECUTE): `organization_request_workflow_profile`, `mark_supply_request_compound_action`, `apply_supply_request_receipt` (the one place a request becomes received; Phase 7C adds the receiving destination here), and the guard trigger function.
- **`list_staff_supply_request_updates`** recreated with `compound_action` appended to its result. The deployed app ignores the extra column, so migrating first is safe.

No existing row, policy or grant changes. No inventory, invoice, budget, notification or digest logic changes.

## Order (SQL Editor)

Run each file as its own query: paste the whole file, run it once, and read the result before going on. Run steps 1–3 back to back.

1. **`precheck.sql`**
   - Success: a grid of fingerprint rows. Download as `phase7c0_pre.csv`.
   - STOP on any error. `precheck: Phase 7C.0 objects already exist` means step 2 already ran; do not run it again. `function is missing or differs from the reviewed production state`, `table is missing or differs from the reviewed production state`, `organization roles or request statuses differ` or `public object counts differ` means production drifted from main `79a2c49`.
2. **`20261112110000_decide_stale_screen_sqlstate.sql`**, then **`20261112120000_phase7c0_request_workflow_profiles.sql`**, each as its own query, in that order
   - Each is one transaction with a preflight; any error rolls that file back.
   - The Editor must **not** offer "Run and enable RLS". If it does, stop.
   - Success: no error, no rows.
   - STOP on any error. If the first file failed, run `precheck.sql` again: it passes with the same rows. If the first file committed and the second failed, do not re-run the first (its preflight refuses: `decide_supply_request no longer raises 40001`); fix the cause and run only the second. If `precheck.sql` reports that 7C.0 objects exist, the second migration committed: run `postcheck.sql`, never a migration again.
3. **`postcheck.sql`**
   - Success: fingerprint rows; save as `phase7c0_post.csv`. Compare with step 1: only the lines below may differ.
   - STOP on any error.
4. **Deploy the application.** The deploy adds the Request Workflow section to Settings and the profile-aware request inbox, dashboard and staff screens. Migrate first: the new screens call `get_request_workflow_profile` and the new action RPCs.

## Expected differences (precheck → postcheck)

- **New functions** (`absent` → hash): the ten above. The six client functions are `secdef=true authenticated=true anon=false service_role=false public=false`; the three private helpers `secdef=true authenticated=false anon=false service_role=false public=false`; the guard trigger function `secdef=false authenticated=false anon=false service_role=false public=false`.
- **`function | decide_supply_request`** and **`function | list_staff_supply_request_updates`**: new hashes, same access (`secdef=true authenticated=true anon=false service_role=true public=false`).
- **`table | supply_request_updates`**: new column hash (`compound_action`), still `rls=true`; its policies and grants lines are unchanged.
- **New table** (`absent` → column hash with `rls=true`), its `grants` line (`none` → `service_role=SELECT`), `policies` stays `none`; new `constraint` lines for it and `supply_request_updates.supply_request_updates_compound_action_check`; one new `index` line (its primary key); two new `trigger` lines.
- **Counts**: public functions +10, tables +1, indexes +1, triggers +2; policies unchanged. On the current production baseline: functions 161 → 171, tables 51 → 52, indexes 193 → 194, triggers 81 → 83, policies 58.
- **Rows**: `organization_request_workflow_settings count` goes from `absent` to `0`; `supply_request_updates with compound_action` stays `0`.

Everything else must be identical. Real use between the precheck and the postcheck (a request submitted or decided) changes the matching `rows` lines.

## After the deploy

- Every organization is Detailed until an admin changes it in **Settings → Request Workflow**. Do not switch FC Cincinnati to Lean as part of the release; it is a separate, explicit acceptance step.
- Changing the profile only changes which actions are offered from then on. It never changes a request's status or history. A queue the profile normally hides (Awaiting Order in Lean, Ready for Staff in Lean and Standard) stays visible while it holds requests, with its plain action (Mark Ordered, Complete Request).
- Notifications are unchanged: Approve & Order sends exactly one Approved email (its approval step is the same audited approval row), Receive & Complete sends none, Decline and a corrective denial behave as before.

## Reporting

Canonical statuses, update rows, `ordered_at` and `received_at` remain the reporting source. `compound_action` marks the rows one bundled action wrote:

- `approve_and_order`: the approval and the order share one transaction timestamp, so **approval → order duration is intentionally 0**;
- `receive_and_complete`: the receipt and the completion share one timestamp, so **receipt → completion duration is intentionally 0**.

Segment these out of any stage-duration metric; a 0 there records how the action was taken, not operational speed. Time to approval, order → receipt and total cycle time stay comparable across profiles, but in Lean `ordered_at` is the approval time, so order → receipt includes any wait between approving and placing the order. A call that finds the request one step from the end (Approve & Order on an already approved request, Receive & Complete on an already received one) writes one ordinary, unmarked row.

## Provenance

Hashes come from a disposable `public.ecr.aws/supabase/postgres:17.6.1.167` migrated from main `79a2c49` (production's application commit, Phase 6C.3) plus these two migrations. The main-only database reproduces the production baseline counts (161 / 51 / 193 / 58 / 81), and every pinned function hash and table definition except the documented ones is identical before and after the migration. Regenerate with both databases running: `node supabase/tests/support/phase7c0_release_generate.mjs --pre <port> --post <port>` (`--check` compares without writing). `phase7c0_release_check.sh` runs the whole sequence on a seeded copy, including an induced failure before `COMMIT` in each migration (complete rollback), refused second applications of both, a refused repeat precheck, and a stale decision answering `55000` at once after the release.
