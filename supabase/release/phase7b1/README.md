# Phase 7B.1 release checks

These scripts check the Phase 7B.1 migration on production. They are read-only and migrate nothing themselves.

Production is migrated by hand in the Supabase SQL Editor. Never use `supabase db push`: the migration history does not record hand-applied migrations (see `../phase7a1/README.md`, "Migration history").

Every file here works in the SQL Editor exactly as written: no psql meta-commands, no transaction control. `precheck.sql` and `postcheck.sql` are each one DO block of assertions followed by the shared fingerprint SELECT (`fingerprint.sql`), so the result grid is the full output. The migration creates no table, so the Editor's "Run and enable RLS" rewrite has nothing to append. `supabase/tests/phase7b1_release_check.sh` proves all of this on seeded data, sending each file the way the Editor does.

## One migration, before the deploy

**`20261028120000_phase7b1_inventory_admin_workspace.sql`** is additive: seven new functions and their grants. It adds no table or column, changes no policy, table grant, existing function or row, and leaves Phase 7A.2 count, label and countable-item semantics alone. The deployed 7A.2 application keeps working unchanged, because every function it calls keeps its reviewed body and grants (the pre/post fingerprint proves it).

- Owner+admin reads (`authenticated` EXECUTE; the role check is inside): `list_inventory_workspace_locations`, `get_inventory_workspace_location`, `list_inventory_workspace_location_stock`, `list_inventory_workspace_items`, `list_inventory_workspace_item_balances`.
- Owner mutation: `replace_inventory_location_labels` (atomic revoke-all plus one new label).
- Internal (no client EXECUTE): `inventory_workspace_stock_status`.

## Order (SQL Editor)

Run each file as its own query: paste the whole file, run it once, and read the result before going on.

1. **`precheck.sql`**
   - Success: a grid of fingerprint rows. Download as `phase7b1_pre.csv`.
   - STOP on any error. `precheck: Phase 7B.1 objects already exist` means step 2 already ran; do not run it again. `function differs from the reviewed production state` or `inventory policies differ` means production drifted from main.
2. **`20261028120000_phase7b1_inventory_admin_workspace.sql`**
   - One transaction with a preflight and an in-migration postcheck; any error rolls it back.
   - The Editor must **not** offer "Run and enable RLS". If it does, stop.
   - Success: no error, no rows.
   - STOP on any error and run `precheck.sql` again: it passes with the same rows (nothing was left behind), or reports that 7B.1 objects exist (the migration committed; run `postcheck.sql`, never the migration again).
3. **`postcheck.sql`**
   - Success: fingerprint rows; save as `phase7b1_post.csv`. Compare with step 1: only the lines below may differ.
   - STOP on any error.
4. **Deploy the application.**

## Expected differences (precheck → postcheck)

- **New functions** (`absent` → hash): the seven above. Reads and Replace: `secdef=true authenticated=true anon=false public=false`; `inventory_workspace_stock_status`: `secdef=false authenticated=false anon=false public=false`.
- **Overloads:** `list_inventory_workspace_locations`, `list_inventory_workspace_items`, `list_inventory_workspace_location_stock`, `replace_inventory_location_labels` go from 0 to 1.
- **Counts:** public functions +7. On the current production baseline: 108 → 115. Tables, indexes, policies and triggers are unchanged (42/160/58/69).

Everything else must be identical: every 7A.1, 7A.2, role-helper and neighbouring function hash, every policy, trigger and grant line, and every `rows` and `org_total` line. The migration writes no rows. Rows written by real use between the precheck and the postcheck (a staff count, a label issued) change the matching `rows` lines; run the two back to back.

## What the assertions cover

- **Precheck:** no 7B.1 objects; 7A.2 and its staff read hardening applied; the 7A.1 and 7A.2 inventory functions and the role helpers (`has_org_role`, `is_org_admin`, `is_org_member`, `list_organization_member_identities`) match the reviewed hashes and grants (7A.2's production postcheck pinned the same 7A.2 hashes); the inventory tables' policies are the reviewed owner-only set; no raw write or label read for application roles; the quantity invariant; pgcrypto.
- **Postcheck:** the seven new functions' bodies, security and grants, and none executable by PUBLIC; then everything the precheck asserts, unchanged.

## After the deploy: production acceptance

Owner: the workspace opens on Items; Locations lists Unassigned first; a location page shows Stock and Labels; Issue, Replace (one new label, earlier ones show "replaced" when scanned) and Revoke (nothing issued) work. Admin: Inventory appears in the navigation; the same pages show a Read-only badge and no mutation controls. Staff: `/inventory` still redirects to `/staff`, and `/count` is unchanged. Do not alter the Phase 7A.2 acceptance records; acceptance for 7B.1 should use its own clearly named location.

## Provenance

Hashes come from a disposable `public.ecr.aws/supabase/postgres:17.6.1.167` migrated from main `67259ae` (production's application commit). `phase7b1_release_check.sh` runs the whole sequence on a seeded copy, including an induced failure before `COMMIT` (complete rollback), a refused second application and a refused repeat precheck.
