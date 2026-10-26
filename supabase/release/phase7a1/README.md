# Phase 7A.1 release checks

These scripts check the Phase 7A.1 migration on production. They are read-only and migrate nothing themselves.

Every file here works in the **Supabase SQL Editor** exactly as written. None of them contain psql meta-commands such as `\ir` (the problem Phase 6C.2 hit), and none of them control transactions. `precheck.sql` and `postcheck.sql` are each one DO block of assertions followed by one final SELECT, so the SQL Editor's result grid is the full output. `fingerprint.sql` is that same final SELECT on its own.

`supabase/tests/phase7a1_backfill_check.sh` runs these exact files on seeded data. It sends each file as one query, which is how the SQL Editor sends it, and it runs the checks with `default_transaction_read_only=on`.

## Order (SQL Editor)

Run each step as a separate SQL Editor query: paste the **whole file**, run it once, and read the result before going on.

1. **`precheck.sql`**
   - Success: a grid of fingerprint rows (`section | key | value`), ending with one `org_total` row per organization that has inventory. Download it as CSV and save it as `phase7a1_pre.csv`.
   - STOP on any error. `precheck: Phase 7A.1 tables already exist` means the migration is already applied; do **not** apply it again. `precheck: function definition differs from repository main: …` means production has drifted from main `f8a60fd`.
2. **`supabase/migrations/20261021120000_phase7a1_location_aware_inventory.sql`**
   - Paste the whole file and run it once. It is one transaction (`BEGIN … COMMIT`) with its own preflight and an in-migration postcheck. Any error rolls it back completely; that is tested with an induced failure just before `COMMIT`.
   - Success: no error.
   - STOP on any error. Run `precheck.sql` again: it should pass with the same rows as step 1, which proves nothing was left behind. Then investigate before retrying.
   - A second run is refused with `Phase 7A.1 inventory location tables already exist unexpectedly`. That is the intended guard against applying it twice.
3. **`postcheck.sql`**
   - Success: a grid of fingerprint rows. Download it as `phase7a1_post.csv`.
   - STOP on any error, for example `postcheck: delete_invoice_permanently grants are not authenticated-only` or `postcheck: % items differ from their location balances`.
4. **Compare** `phase7a1_pre.csv` and `phase7a1_post.csv`. Only the lines listed below may differ.
5. Only then merge and deploy the application. The currently deployed application keeps working against the migrated database, so there is no outage window. This is verified by `supabase/tests/run_phase7a1_old_app_compat.sh`, which replays its exact calls against a main-only database and a migrated one.

### psql alternative

The same files work with psql from the repository root:

```bash
PGOPTIONS='-c default_transaction_read_only=on' psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -At -F ' | ' -f supabase/release/phase7a1/precheck.sql > phase7a1_pre.txt
```

Run `postcheck.sql` the same way into `phase7a1_post.txt`, then `diff phase7a1_pre.txt phase7a1_post.txt`. Apply the migration itself without the read-only option.

## Expected differences

All 'function' lines read `<md5> secdef=… authenticated=… anon=… public=…`.

- **New functions** go from `absent` to a hash:
  - `adjust_inventory_location_quantity`, `create_inventory_location`, `update_inventory_location`, `set_inventory_location_active` and `move_inventory_stock` are `authenticated=true anon=false public=false`.
  - `apply_inventory_location_delta`, `inventory_apply_balance_delta` and `ensure_inventory_unassigned_location` are `authenticated=false anon=false public=false`.
- **Replaced functions** (body hash changes):
  - `post_reviewed_invoice`: grants are unchanged.
  - `delete_invoice_permanently`: `anon=true` becomes `anon=false`; it stays `authenticated=true public=false`.
  - `adjust_inventory_quantity` and `receive_invoice_inventory_item`: `anon=true public=true` becomes `anon=false public=false`.
- **Overloads:** `move_inventory_stock` and `adjust_inventory_location_quantity` go from 0 to 1. `adjust_inventory_quantity` stays at 1.
- **Constraint:** `inventory_adjustments_source_type_check` changes; it now also allows `physical_count`.
- **Counts:** `public functions` +16, `public tables` +3, `public indexes` +11, `public policies` +2 (3 added, 1 dropped), `public triggers` +10.
- **Policies, triggers and grants on inventory tables:**
  - `policies | inventory_adjustments` changes: the owner insert policy is dropped.
  - `triggers | inventory_items`, `triggers | inventory_adjustments` and `triggers | organizations` change: guards, seeding and the deferred invariant are added.
  - `grants | inventory_adjustments` loses `anon=INSERT` and `authenticated=INSERT`.
  - `grants | inventory_locations`, `grants | inventory_location_balances` and `grants | inventory_transfers` go from `none` to `authenticated=SELECT,service_role=SELECT`.

Everything else must be identical, in particular:

- every `rows` line:
  - inventory item count and quantity hash (no item changed quantity or disappeared)
  - organization totals
  - adjustment count and hash (no history added, removed or relabelled)
  - price history, invoices, invoice items, budgets, requests, request lines, commitments, commitment items and sites
- every `org_total` line;
- every function hash in the "must not change" group;
- the policies and triggers of every non-inventory table.

If the application served traffic between the two runs, receipts can legitimately change the inventory and adjustment lines. In that case the postcheck assertions must still pass. Run both scripts during a quiet window to get a clean comparison.

## What the assertions cover

- **Precheck:**
  - nothing from 7A.1 exists yet (tables, column, functions, triggers);
  - the four replaced functions and `stock_catalog_vendor_product` match main `f8a60fd` byte for byte, and so does the `source_type` constraint;
  - the single deployed `adjust_inventory_quantity(uuid,uuid,numeric,text)` signature;
  - the tables, indexes, helper functions, the `inventory_items.quantity` column type and the policy the migration relies on or drops;
  - no negative quantities.
- **Postcheck:**
  - the new tables, columns, indexes, constraints, policies and triggers;
  - `quantity = SUM(balances)` for every item;
  - no balance crosses organizations;
  - exactly one active Unassigned per organization;
  - no physical location, transfer or non-Unassigned stock yet;
  - the reviewed hashes of 12 replaced or new functions, plus the unchanged stocking function;
  - internal primitives are not client-executable;
  - RPC grants are authenticated-only;
  - `delete_invoice_permanently` is executable by authenticated only (not anon, not PUBLIC);
  - application roles cannot write balances, locations, transfers or the ledger directly;
  - the deferred invariant triggers are installed.

## Provenance

The precheck hashes come from a disposable Postgres (`public.ecr.aws/supabase/postgres:17.6.1.167`) migrated from `main` at `f8a60fd`; the postcheck hashes come from the same database after the migration.

`phase7a1_backfill_check.sh` reproduces the whole sequence on seeded pre-7A.1 history. That history includes integer, fractional, zero and archived items, posted invoices, manual adjustments, two tenants and an empty organization. The check also covers the induced-failure rollback, the refused second application and the refused repeat precheck. On that database the pre/post diff is exactly the list above.
