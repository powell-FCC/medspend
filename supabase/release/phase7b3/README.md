# Phase 7B.3 release checks

These scripts check the Phase 7B.3 migration on production. They are read-only and migrate nothing themselves.

Production is migrated by hand in the Supabase SQL Editor. Never use `supabase db push`: the migration history does not record hand-applied migrations (see `../phase7a1/README.md`, "Migration history").

Every file here works in the SQL Editor exactly as written: no psql meta-commands, no transaction control. `precheck.sql` and `postcheck.sql` are each one DO block of assertions followed by the shared fingerprint SELECT (`fingerprint.sql`), so the result grid is the full output. The migration creates no table (not even a temporary one), so the Editor's "Run and enable RLS" rewrite has nothing to append. `supabase/tests/phase7b3_release_check.sh` proves all of this on seeded data, sending each file the way the Editor does.

## One migration, before the deploy

**`20261029140000_phase7b3_inventory_activity_history.sql`** is additive: two new read functions, their grants, and four indexes. It adds no table or column, changes no policy, table grant, existing function or row, and leaves transfer, adjustment and count semantics alone. The deployed 7B.2 application keeps working unchanged, because every function it calls keeps its reviewed body and grants (the pre/post fingerprint proves it).

- Owner+admin reads (`authenticated` EXECUTE; the role check is inside; both `STABLE`, `SET plan_cache_mode = force_custom_plan`): `list_inventory_transfer_history`, `list_inventory_adjustment_history`.
- Indexes (plain `CREATE INDEX` inside the migration's transaction; the tables are small in production, so the brief write lock is not a concern): see below.

### What the adjustment history contains

`list_inventory_adjustment_history` returns **manual** adjustments only: `source_type = 'manual'`, or rows written before adjustment provenance existed (`source_type IS NULL`) whose reason is not `Invoice received`.

- **Physical-count corrections** (`source_type = 'physical_count'`, which the schema ties to `reason = 'Physical count'` and an `inventory_count_line_id`) are excluded. They belong to Counts (7B.2), which keeps showing them.
- **Invoice receipts** (`source_type = 'invoice'`, and pre-provenance `Invoice received` rows from the old receiving helper) are excluded. They belong to their invoice, are deleted with it by `delete_invoice_permanently`, and the receiving packages (7C, 8B) own them.
- `source_type = 'system'` is allowed by the check constraint but nothing writes it; it is not shown.
- A manual adjustment whose owner chose the reason `Invoice received` (possible through the older `adjust_inventory_quantity`) is a manual adjustment and is shown with that stored reason.

`previous_quantity` and `new_quantity` on `inventory_adjustments` are the item's **organization total** (all locations) before and after the change, not the location's balance; the schema stores no per-location before/after. They are returned as stored and the UI labels them "Total before / Total after". Invoice deletion re-bases these stored totals for surviving rows; the history shows whatever is stored. Neither table keeps an item or location name snapshot, so names are current names.

### Index evidence

Measured on a disposable copy with 10 organizations × 30,000 transfers (300,000 rows) and 10 × 43,000 adjustments (40,000 physical-count, 2,000 manual, 1,000 invoice rows each), 20 locations and 300 items per organization; plans from `EXPLAIN (ANALYZE, BUFFERS)` and, for the functions themselves, `auto_explain` with nested statements.

| Index | Query it serves | Before (existing indexes) | After |
| --- | --- | --- | --- |
| `inventory_transfers_org_created_idx (organization_id, created_at DESC, id DESC)` | All transfers of an organization, newest first, keyset paged | `inventory_transfers` had only `(inventory_item_id, created_at DESC)` and the idempotency key. Page 1 was a parallel sequential scan of all 300,000 rows (6,757 buffers) plus a top-N sort; a deep keyset page read all 30,000 of the organization's rows through the idempotency index and sorted them. Cost grows with all history. | Index-only scan of 50 entries (4 buffers), also for deep pages (row-comparison index condition). |
| `inventory_transfers_from_created_idx (from_inventory_location_id, created_at DESC, id DESC)` and `inventory_transfers_to_created_idx (to_inventory_location_id, …)` | A location's transfers, out of or into it | Every page read the organization's 30,000 transfers and filtered to the location's 3,000, then sorted. | The function runs two ordered index scans (out, in) and merge-appends them: 57 buffers for a page. |
| `inventory_adjustments_manual_org_created_idx (organization_id, created_at DESC, id DESC) WHERE (source_type = 'manual' OR (source_type IS NULL AND reason <> 'Invoice received'))` | All manual adjustments of an organization, newest first | `inventory_adjustments_org_created_idx` is ordered but holds every adjustment; physical-count corrections (one per changed count line) dominate it. A first page stepped over 1,183 non-manual rows to find 50; a sparse filter (e.g. reason Expired with no matches) read all 43,000 rows. | Ordered scan of manual rows only: 50 rows for a page; the sparse case reads 2,000 (manual rows only). Count submissions never write this index. |

Not added, because the plans did not need them: an item index (`inventory_transfers_item_created_idx` and `inventory_adjustments_item_created_idx` already serve the item filter in under 1 ms), and a location-scoped manual adjustment index (tried; the planner kept choosing a bitmap AND of the existing location and the new organization index, about 0.3–0.5 ms, so it was removed). No index on person: that filter combines with the ordered organization scan.

## Order (SQL Editor)

Run each file as its own query: paste the whole file, run it once, and read the result before going on.

1. **`precheck.sql`**
   - Success: a grid of fingerprint rows. Download as `phase7b3_pre.csv`.
   - STOP on any error. `precheck: Phase 7B.3 objects already exist` means step 2 already ran; do not run it again. `Phase 7B.2 is not applied`, `Phase 7B.2 function is missing or differs`, `function differs from the reviewed production state`, `indexes … differ` or `inventory policies differ` means production drifted from main.
2. **`20261029140000_phase7b3_inventory_activity_history.sql`**
   - One transaction with a preflight and an in-migration postcheck; any error rolls it back.
   - The Editor must **not** offer "Run and enable RLS". If it does, stop.
   - Success: no error, no rows.
   - STOP on any error and run `precheck.sql` again: it passes with the same rows (nothing was left behind), or reports that 7B.3 objects exist (the migration committed; run `postcheck.sql`, never the migration again).
3. **`postcheck.sql`**
   - Success: fingerprint rows; save as `phase7b3_post.csv`. Compare with step 1: only the lines below may differ.
   - STOP on any error.
4. **Deploy the application.**

## Expected differences (precheck → postcheck)

- **New functions** (`absent` → hash): `list_inventory_adjustment_history` and `list_inventory_transfer_history`, both `secdef=true authenticated=true anon=false public=false`.
- **Overloads:** both go from 0 to 1.
- **New indexes** (`absent` → hash `valid=true`): `inventory_adjustments_manual_org_created_idx`, `inventory_transfers_from_created_idx`, `inventory_transfers_org_created_idx`, `inventory_transfers_to_created_idx`.
- **Counts:** public functions +2 (on the current production baseline: 117 → 119); public indexes +4. Tables, policies and triggers are unchanged.

Everything else must be identical: every 7B.2, 7B.1, 7A.2, 7A.1, role-helper and neighbouring function hash, every existing index, policy, trigger and grant line, and every `rows` and `org_total` line. The migration writes no rows. Rows written by real use between the precheck and the postcheck (a move, a staff count) change the matching `rows` lines; run the two back to back.

## What the assertions cover

- **Precheck:** no 7B.3 objects; 7B.2, 7B.1, 7A.2 applied; the two 7B.2 functions match the hashes 7B.2's production postcheck pinned; the history tables carry exactly the reviewed indexes; then everything 7B.2's precheck asserted (7B.1, 7A.2, 7A.1 and role-helper hashes and grants, the owner-only inventory policies, no raw write or label read for application roles, the quantity invariant, pgcrypto).
- **Postcheck:** the two new functions' bodies, security, volatility, settings and grants, and neither executable by PUBLIC; the four index definitions, valid and ready; then everything the precheck asserts, unchanged.

Pre-existing and left alone: `inventory_adjustments` carries `anon`/`authenticated` SELECT, UPDATE and DELETE table grants from Supabase default privileges (its only policy is the owner SELECT, so they match no rows for anyone else). The migration's in-transaction postcheck proves every inventory table's grants and policies are byte-for-byte unchanged.

## After the deploy: production acceptance

Owner and admin: Inventory shows Items, Locations, Counts and Activity. Activity has Transfers and Adjustments, each with its own filters and Load more. Transfers lists date, item, from, to, quantity and who moved it, newest first; Location (either side), Item, Moved by and date filters narrow it. Adjustments lists date, item, location, total before, adjustment, total after, reason and who; Location, Item, Adjusted by, Reason and date filters narrow it; physical-count corrections never appear there and are still in Counts. A storage location and Unassigned each have an Activity tab (Unassigned still has no Labels or Counts); a location's transfers are marked OUT or IN. Admin pages show the Read-only badge and no mutation controls. Staff: `/inventory` still redirects to `/staff`, and `/count` is unchanged. The 7B.1 acceptance records (two Hydrofilm transfers via the archived "Phase 7B.1 Acceptance" location) are expected to appear in Transfers; do not alter them.

## Provenance

Hashes come from a disposable `public.ecr.aws/supabase/postgres:17.6.1.167` migrated from main `0a28d78` (production's application commit) plus this migration; the 7B.2, 7B.1, 7A.2 and 7A.1 hashes reproduce the values 7B.2's release files pinned. `phase7b3_release_check.sh` runs the whole sequence on a seeded copy, including an induced failure before `COMMIT` (complete rollback), a refused second application and a refused repeat precheck.
