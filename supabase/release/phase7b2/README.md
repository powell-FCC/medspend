# Phase 7B.2 release checks

These scripts check the Phase 7B.2 migration on production. They are read-only and migrate nothing themselves.

Production is migrated by hand in the Supabase SQL Editor. Never use `supabase db push`: the migration history does not record hand-applied migrations (see `../phase7a1/README.md`, "Migration history").

Every file here works in the SQL Editor exactly as written: no psql meta-commands, no transaction control. `precheck.sql` and `postcheck.sql` are each one DO block of assertions followed by the shared fingerprint SELECT (`fingerprint.sql`), so the result grid is the full output. The migration creates no table, so the Editor's "Run and enable RLS" rewrite has nothing to append. `supabase/tests/phase7b2_release_check.sh` proves all of this on seeded data, sending each file the way the Editor does.

## One migration, before the deploy

**`20261029120000_phase7b2_inventory_count_history.sql`** is additive: two new read functions and their grants. It adds no table, column or index, changes no policy, table grant, existing function or row, and leaves Phase 7A.2 count semantics and the Phase 7B.1 workspace alone. The deployed 7B.1 application keeps working unchanged, because every function it calls keeps its reviewed body and grants (the pre/post fingerprint proves it).

- Owner+admin reads (`authenticated` EXECUTE; the role check is inside; both `STABLE`): `list_inventory_count_history`, `get_inventory_count_session`.

No index is added. The history list is served by the existing `inventory_count_sessions_org_submitted_idx (organization_id, submitted_at DESC)` and, with a location filter, `inventory_count_sessions_location_submitted_idx (inventory_location_id, submitted_at DESC)`; correction summaries and detail lines are read per session through the existing `UNIQUE (count_session_id, inventory_item_id)` index.

## Order (SQL Editor)

Run each file as its own query: paste the whole file, run it once, and read the result before going on.

1. **`precheck.sql`**
   - Success: a grid of fingerprint rows. Download as `phase7b2_pre.csv`.
   - STOP on any error. `precheck: Phase 7B.2 objects already exist` means step 2 already ran; do not run it again. `Phase 7B.1 function is missing or differs`, `function differs from the reviewed production state` or `inventory policies differ` means production drifted from main.
2. **`20261029120000_phase7b2_inventory_count_history.sql`**
   - One transaction with a preflight and an in-migration postcheck; any error rolls it back.
   - The Editor must **not** offer "Run and enable RLS". If it does, stop.
   - Success: no error, no rows.
   - STOP on any error and run `precheck.sql` again: it passes with the same rows (nothing was left behind), or reports that 7B.2 objects exist (the migration committed; run `postcheck.sql`, never the migration again).
3. **`postcheck.sql`**
   - Success: fingerprint rows; save as `phase7b2_post.csv`. Compare with step 1: only the lines below may differ.
   - STOP on any error.
4. **Deploy the application.**

## Expected differences (precheck → postcheck)

- **New functions** (`absent` → hash): `get_inventory_count_session` and `list_inventory_count_history`, both `secdef=true authenticated=true anon=false public=false`.
- **Overloads:** both go from 0 to 1.
- **Counts:** public functions +2. On the current production baseline: 115 → 117. Tables, indexes, policies and triggers are unchanged.

Everything else must be identical: every 7B.1, 7A.2, 7A.1, role-helper and neighbouring function hash, every policy, trigger and grant line, and every `rows` and `org_total` line. The migration writes no rows. Rows written by real use between the precheck and the postcheck (a staff count, a label issued) change the matching `rows` lines; run the two back to back.

## What the assertions cover

- **Precheck:** no 7B.2 objects; 7B.1, 7A.2 and its staff read hardening applied; the seven 7B.1 functions match the hashes 7B.1's production postcheck pinned; the 7A.1 and 7A.2 inventory functions and the role helpers (`has_org_role`, `is_org_admin`, `is_org_member`, `list_organization_member_identities`) match the reviewed hashes and grants; the inventory tables' policies are the reviewed owner-only set; no raw write or label read for application roles; the quantity invariant; pgcrypto.
- **Postcheck:** the two new functions' bodies, security, volatility and grants, and neither executable by PUBLIC; then everything the precheck asserts, unchanged.

## After the deploy: production acceptance

Owner and admin: Inventory shows Items, Locations and Counts; Counts lists submitted counts newest first with location, who counted, lines, corrections and a per-unit correction summary; the Location, Counted by, date and Has corrections filters narrow it; opening a count shows Recorded, Counted and Correction for changed lines first and the unchanged lines in "No change"; a storage location has a Counts tab (Unassigned does not). Admin pages show the Read-only badge and no mutation controls. Staff: `/inventory` and `/inventory/counts/...` still redirect to `/staff`, and `/count` is unchanged. Do not alter the Phase 7A.2 or 7B.1 acceptance records; reading them through Counts is expected and changes nothing.

## Provenance

Hashes come from a disposable `public.ecr.aws/supabase/postgres:17.6.1.167` migrated from main `30b97d2` (production's application commit) plus this migration; the 7B.1, 7A.2 and 7A.1 hashes reproduce the values 7B.1's release files pinned. `phase7b2_release_check.sh` runs the whole sequence on a seeded copy, including an induced failure before `COMMIT` (complete rollback), a refused second application and a refused repeat precheck.
