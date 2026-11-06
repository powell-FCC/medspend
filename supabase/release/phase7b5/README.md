# Phase 7B.5 release checks

These scripts check the Phase 7B.5 migration on production. They are read-only and migrate nothing themselves.

Production is migrated by hand in the Supabase SQL Editor. Never use `supabase db push`: the migration history does not record hand-applied migrations (see `../phase7a1/README.md`, "Migration history").

Every file here works in the SQL Editor exactly as written: no psql meta-commands, no transaction control. `precheck.sql` and `postcheck.sql` are each one DO block of assertions followed by the shared fingerprint SELECT (`fingerprint.sql`), so the result grid is the full output. The migration creates one table and enables RLS on it in the same file, so the Editor's "Run and enable RLS" check has nothing to flag and must not appear. `supabase/tests/phase7b5_release_check.sh` proves all of this on seeded data, sending each file the way the Editor does.

## One migration, before the deploy

**`20261106120000_phase7b5_inventory_count_cadence.sql`** adds:

- **Table `inventory_count_policies`**: one optional row per organization (`organization_id` is the primary key) with `enabled`, `interval_days` (1..365, required when enabled), `created_at`, `updated_at`, `updated_by`. RLS is on with no policies; `anon` and `authenticated` have no grants (`service_role` may read). No row means cadence is off. The migration writes no rows.
- **`inventory_location_count_freshness(org, as_of)`**: internal (no client EXECUTE). The one place freshness is decided.
- **`get_inventory_count_policy`**, **`get_inventory_count_freshness`**: owner+admin reads (`authenticated` EXECUTE; the role check is inside; STABLE).
- **`set_inventory_count_policy`**: owner only.

No existing table, column, index, policy, grant, trigger, function or row changes. 7A.2 count submission, 7B.2 count history, 7B.3 activity and the 7B.4 overview are untouched; the deployed 7B.4 application keeps working before the deploy (it never calls the new functions).

No index is added beyond the new table's primary key. The newest count per location is one probe of the existing `inventory_count_sessions_location_submitted_idx`; `run_phase7b5_count_cadence_integration.sh` records the plan at 300 locations / 28,000 sessions and fails on a sequential scan of count history.

## Order (SQL Editor)

Run each file as its own query: paste the whole file, run it once, and read the result before going on.

1. **`precheck.sql`**
   - Success: a grid of fingerprint rows. Download as `phase7b5_pre.csv`.
   - STOP on any error. `precheck: Phase 7B.5 objects already exist` means step 2 already ran; do not run it again. `Phase 7B.4/7B.3/7B.2/7B.1 function is missing or differs`, `function differs from the reviewed production state` or `inventory policies differ` means production drifted from main.
2. **`20261106120000_phase7b5_inventory_count_cadence.sql`**
   - One transaction with a preflight and an in-migration postcheck; any error rolls it back.
   - The Editor must **not** offer "Run and enable RLS". If it does, stop.
   - Success: no error, no rows.
   - STOP on any error and run `precheck.sql` again: it passes with the same rows (nothing was left behind), or reports that 7B.5 objects exist (the migration committed; run `postcheck.sql`, never the migration again).
3. **`postcheck.sql`**
   - Success: fingerprint rows; save as `phase7b5_post.csv`. Compare with step 1: only the lines below may differ.
   - STOP on any error.
4. **Deploy the application.**

## Expected differences (precheck → postcheck)

- **New functions** (`absent` → hash): `get_inventory_count_freshness`, `get_inventory_count_policy`, `set_inventory_count_policy` (`secdef=true authenticated=true anon=false public=false`) and `inventory_location_count_freshness` (`secdef=false authenticated=false anon=false public=false`). Their overloads go from 0 to 1.
- **New index**: `inventory_count_policies_pkey` (`absent` → hash, `valid=true`).
- **New table lines**: `grants | inventory_count_policies` goes from `none` to `service_role=SELECT`; `policies | inventory_count_policies` stays `none`.
- **Counts**: public functions +4, tables +1, indexes +1. On the current production baseline: functions 120 → 124, tables 42 → 43, indexes 164 → 165. Policies (58) and triggers (69) are unchanged.

Everything else must be identical: every 7B.4, 7B.3, 7B.2, 7B.1, 7A.2, 7A.1, role-helper and neighbouring function hash, every other index, policy, trigger and grant line, and every `rows` and `org_total` line. The postcheck also asserts the new table has exactly the reviewed columns and constraints and no rows. Rows written by real use between the precheck and the postcheck (a staff count, a move) change the matching `rows` lines; run the two back to back.

## Freshness rule (for acceptance)

With cadence on and the newest submitted count at `last`: `next_due = last + interval_days days`; **Current** before `next_due`, **Due** for the 24 hours from `next_due`, **Overdue** after that; **Never counted** when an active location with countable items has no count. With cadence off nothing is current, due or overdue. Archived locations and Unassigned are never scheduled; active locations with nothing countable are "Nothing to count". All times are timestamps (the schema has no organization time zone); dates display in the viewer's locale.

## After the deploy: production acceptance

Owner: Settings shows "Physical count cadence" with the form; saving 30 days turns on the Overview "Count schedule" section and the schedule line on active storage locations; turning cadence off removes them and keeps the interval. Admin: Settings shows the cadence read-only; Overview and locations show the same schedule; no controls. Staff: Settings and Inventory still redirect to `/staff`; `/count` is unchanged. A production acceptance that turns cadence on writes one `inventory_count_policies` row; decide beforehand whether to leave it on or turn it off afterwards.

## Provenance

Hashes come from a disposable `public.ecr.aws/supabase/postgres:17.6.1.167` migrated from main `9e0b52e` (production's application commit) plus this migration; the 7B.4 overview hash reproduces the value 7B.4's release files pinned. `phase7b5_release_check.sh` runs the whole sequence on a seeded copy, including an induced failure before `COMMIT` (complete rollback), a refused second application and a refused repeat precheck.
