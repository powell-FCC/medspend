# Phase 7A.1 release checks

These are read-only SQL scripts for applying the Phase 7A.1 migration to production. They do not migrate anything themselves.

## Order

1. Run `precheck.sql` and save its output as `phase7a1_pre.txt`. Stop if any assertion fails.
2. Apply `supabase/migrations/20261021120000_phase7a1_location_aware_inventory.sql`. It runs its own preflight and an in-migration postcheck, and rolls back on any mismatch.
3. Run `postcheck.sql` and save its output as `phase7a1_post.txt`. Stop if any assertion fails.
4. Run `diff phase7a1_pre.txt phase7a1_post.txt`.
5. Only then merge and deploy the application. The deployed application keeps working against the migrated database, so there is no outage window.

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F ' | ' -f supabase/release/phase7a1/precheck.sql > phase7a1_pre.txt
```

Run each script from the repository root; they include `fingerprint.sql` with `\ir`.

## Expected diff

Besides the `precheck_at` / `postcheck_at` and assertion lines, only these fingerprint lines change:

- **New functions:** `function` lines for the 8 functions go from `absent` to a hash:
  - `adjust_inventory_location_quantity`, `create_inventory_location`, `update_inventory_location`, `set_inventory_location_active` and `move_inventory_stock` are `authenticated=true anon=false`.
  - `apply_inventory_location_delta`, `inventory_apply_balance_delta` and `ensure_inventory_unassigned_location` are `authenticated=false anon=false`.
- **Replaced functions:** `function` lines change for `adjust_inventory_quantity`, `receive_invoice_inventory_item`, `post_reviewed_invoice` and `delete_invoice_permanently`. The first two also go from `anon=true` to `anon=false`. `delete_invoice_permanently` keeps main's grants.
- **Overloads:** `overloads | move_inventory_stock` and `overloads | adjust_inventory_location_quantity` go from 0 to 1. `adjust_inventory_quantity` stays at 1.
- **Constraint:** `constraint | inventory_adjustments_source_type_check` changes; it now also allows `physical_count`.
- **Counts:** `public functions` +16, `public tables` +3, `public indexes` +11, `public policies` +2 (3 added, 1 dropped), `public triggers` +10.
- **Policies, triggers and grants on inventory tables:**
  - `policies | inventory_adjustments` changes: the owner insert policy is dropped.
  - `triggers | inventory_items`, `triggers | inventory_adjustments` and `triggers | organizations` change: guards, seeding and the deferred invariant are added.
  - `grants | inventory_adjustments` loses `anon=INSERT` and `authenticated=INSERT`.
  - `grants | inventory_locations`, `grants | inventory_location_balances` and `grants | inventory_transfers` go from `none` to `authenticated=SELECT,service_role=SELECT`.

Everything else must be identical, in particular:

- `rows | inventory_items count` and `rows | inventory_items quantity hash`: no item changed quantity or disappeared;
- `rows | inventory organization totals hash` and the `org_total` lines;
- `rows | inventory_adjustments count` and `rows | inventory_adjustments hash`: no history added, removed or changed;
- the price history, invoices, invoice items, budgets, requests, commitments and sites hashes;
- every function hash in the "must not change" group, and the policies and triggers of every non-inventory table.

If the application served traffic between the two runs, receipts can legitimately change the inventory and adjustment lines. In that case the postcheck assertions must still pass, and the new adjustment rows must name the Unassigned location. Run both scripts during a quiet window to get a clean diff.

## Provenance

The expected hashes in `precheck.sql` come from a disposable Postgres (`public.ecr.aws/supabase/postgres:17.6.1.167`) migrated from `main` at `f8a60fd`. The `postcheck.sql` hashes come from the same database after this migration.

`supabase/tests/phase7a1_backfill_check.sh` reproduces the whole sequence on seeded pre-7A.1 history. That history includes integer, fractional, zero and archived items, posted invoices, manual adjustments, two tenants and an empty organization. On that database both scripts pass, and the pre/post diff is exactly the list above.
