# Phase 7B.4 release checks

These scripts check the Phase 7B.4 migration on production. They are read-only and migrate nothing themselves.

Production is migrated by hand in the Supabase SQL Editor. Never use `supabase db push`: the migration history does not record hand-applied migrations (see `../phase7a1/README.md`, "Migration history").

Every file here works in the SQL Editor exactly as written: no psql meta-commands, no transaction control. `precheck.sql` and `postcheck.sql` are each one DO block of assertions followed by the shared fingerprint SELECT (`fingerprint.sql`), so the result grid is the full output. The migration creates no table (not even a temporary one), so the Editor's "Run and enable RLS" rewrite has nothing to append. `supabase/tests/phase7b4_release_check.sh` proves all of this on seeded data, sending each file the way the Editor does.

## One migration, before the deploy

**`20261030120000_phase7b4_inventory_overview.sql`** is additive: one new read function and its grants. It adds no table, column or index, changes no policy, table grant, existing function or row. The deployed 7B.3 application keeps working unchanged, because every function it calls keeps its reviewed body and grants (the pre/post fingerprint proves it).

- Owner+admin read (`authenticated` EXECUTE; the role check is inside; `STABLE`, `SECURITY DEFINER`, `search_path = public`): `get_inventory_overview(_organization_id uuid, _attention_limit integer DEFAULT 10)`, returning one JSON value: a snapshot and five needs-attention lists, each `{total, rows}` with at most `_attention_limit` (1–50) rows by name.

Recent counts, transfers and manual adjustments on the Overview use the existing 7B.2/7B.3 reads with a page of five, and the Unassigned workspace uses the existing 7B.1 location-stock read (which already returns only quantities above zero for Unassigned). No other database change was needed.

### Needs-attention rules (current state only; nothing is time-based)

- **Stock in Unassigned:** items whose Unassigned balance is > 0. Zero balances never appear.
- **Locations never counted:** active storage locations with at least one countable item (the 7A.2 rule: item active, or quantity > 0) and no submitted count session. A location with nothing to count is not listed.
- **Items never counted:** items countable at one or more active storage locations that no immutable count line has ever recorded. Items only in Unassigned are not listed here (they are in Stock in Unassigned); archived items count only while they still hold stock, as in 7A.2.
- **No active label:** active storage locations without an active QR label.
- **Active label on archived location:** archived storage locations with one or more active labels.

Unassigned is never part of a count or label rule. There is no overdue, stale or cadence state; that is Phase 7B.5. The snapshot's recorded quantity is a raw sum across units, shown as such, never a value.

### Index evidence (none added)

Measured on a disposable copy with one organization of 20,000 items, 300 locations, 60,000 balances, 3,750 count sessions and 300,000 count lines (600,000 across two organizations), and 198 active labels:

- The whole overview runs in about 70–115 ms, through existing indexes: `inventory_location_balances_org_idx`, `inventory_items_org_category_idx` / `inventory_items_pkey`, `inventory_count_sessions_location_submitted_idx` (one probe per active location) and the labels read.
- "Items never counted" was the one shape that scaled with history: a hash anti-join that sequentially read every count line in the table (all organizations). The function instead probes `inventory_count_lines_item_location_idx` once per candidate item (an index-only scan; `OFFSET 0` keeps it a per-item subplan), so its cost follows the number of items, not the length of count history (41 ms vs 59 ms at this size, and flat as history grows).

## Order (SQL Editor)

Run each file as its own query: paste the whole file, run it once, and read the result before going on.

1. **`precheck.sql`**
   - Success: a grid of fingerprint rows. Download as `phase7b4_pre.csv`.
   - STOP on any error. `precheck: Phase 7B.4 objects already exist` means step 2 already ran; do not run it again. `Phase 7B.3 is not applied`, `Phase 7B.3 function … differs`, `Phase 7B.3 index …`, `Phase 7B.2 function … differs`, `function differs from the reviewed production state` or `inventory policies differ` means production drifted from main.
2. **`20261030120000_phase7b4_inventory_overview.sql`**
   - One transaction with a preflight and an in-migration postcheck; any error rolls it back.
   - The Editor must **not** offer "Run and enable RLS". If it does, stop.
   - Success: no error, no rows.
   - STOP on any error and run `precheck.sql` again: it passes with the same rows (nothing was left behind), or reports that 7B.4 objects exist (the migration committed; run `postcheck.sql`, never the migration again).
3. **`postcheck.sql`**
   - Success: fingerprint rows; save as `phase7b4_post.csv`. Compare with step 1: only the lines below may differ.
   - STOP on any error.
4. **Deploy the application.**

## Expected differences (precheck → postcheck)

- **New function** (`absent` → hash): `get_inventory_overview`, `secdef=true authenticated=true anon=false public=false`.
- **Overloads:** `get_inventory_overview` goes from 0 to 1.
- **Counts:** public functions +1. On the current production baseline: 119 → 120. Tables, indexes, policies and triggers are unchanged.

Everything else must be identical: every 7B.3, 7B.2, 7B.1, 7A.2, 7A.1, role-helper and neighbouring function hash, every index (including the four 7B.3 indexes and the count, balance and label indexes the overview reads through), policy, trigger and grant line, and every `rows` and `org_total` line. The migration writes no rows. Rows written by real use between the precheck and the postcheck change the matching `rows` lines; run the two back to back.

## What the assertions cover

- **Precheck:** no 7B.4 objects; 7B.3, 7B.2 and 7B.1 applied; the two 7B.3 functions match the hashes and settings 7B.3's production postcheck pinned and its four indexes are present, exact and valid; the history tables carry exactly the reviewed index set; the two 7B.2 functions match their pinned hashes; then everything 7B.3's precheck asserted (7B.1, 7A.2, 7A.1 and role-helper hashes and grants, the owner-only inventory policies, no raw write or label read for application roles, the quantity invariant, pgcrypto).
- **Postcheck:** the new function's body, security, volatility, setting, single overload and grants; then everything the precheck asserts, unchanged.

The migration's in-transaction postcheck also proves every inventory table's grants and policies (including `inventory_location_labels`) are byte-for-byte unchanged. Pre-existing and left alone: `inventory_adjustments` carries `anon`/`authenticated` default-privilege grants limited by its owner-only SELECT policy.

## After the deploy: production acceptance

Owner and admin: `/inventory` opens on Overview; the tabs read Overview | Items | Locations | Counts | Activity, and `?tab=items` (and the other older links) still open their tab. Overview shows the snapshot, the five needs-attention lists (with totals and links: Unassigned stock → Unassigned, never-counted location → the location, label rows → the location's Labels tab) and the latest five counts, transfers and manual adjustments linking to Counts and Activity. Unassigned shows "Stock in Unassigned", its recent transfers and a link to its Activity; it still has no Labels or Counts, and no rename or archive. Admin pages show the Read-only badge and no mutation controls. Staff: `/inventory` still redirects to `/staff`; `/count` and requests are unchanged. On today's production data the expected lists are factual: e.g. the archived acceptance locations, and the items left in Unassigned.

## Provenance

Hashes come from a disposable `public.ecr.aws/supabase/postgres:17.6.1.167` migrated from main `94e1840` (production's application commit) plus this migration; the 7B.3, 7B.2, 7B.1, 7A.2 and 7A.1 hashes reproduce the values 7B.3's release files pinned. `phase7b4_release_check.sh` runs the whole sequence on a seeded copy, including an induced failure before `COMMIT` (complete rollback), a refused second application and a refused repeat precheck.
