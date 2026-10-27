# Phase 7A.2 release checks

These scripts check the Phase 7A.2 migrations on production. They are read-only and migrate nothing themselves.

Production is migrated by hand in the Supabase SQL Editor. Never use `supabase db push`: the migration history does not record hand-applied migrations (see `../phase7a1/README.md`, "Migration history").

Every file here works in the SQL Editor exactly as written: no psql meta-commands, no transaction control. `precheck.sql`, `postcheck.sql` and `hardening_postcheck.sql` are each one DO block of assertions followed by the shared fingerprint SELECT (`fingerprint.sql`), so the result grid is the full output. Neither migration creates a table without enabling RLS in the same file, uses temp tables, or runs anything after `COMMIT`, so the Editor's "Run and enable RLS" rewrite has nothing to append (the 7A.1 incident). `supabase/tests/phase7a2_release_check.sh` proves all of this on seeded data, sending each file the way the Editor does.

## Two migrations, around the deploy

1. **`20261027120000_phase7a2_inventory_physical_counts.sql`** (before the deploy). Additive: count sessions and lines, QR labels, the count and label functions, and `get_supply_request_inventory_identities`. The deployed 7A.1 application keeps working unchanged (`run_phase7a1_old_app_compat.sh`, third run).
2. **Deploy the 7A.2 application.** Its staff screens read inventory names through `get_supply_request_inventory_identities` instead of `inventory_items`.
3. **`20261027120100_phase7a2_staff_inventory_read_hardening.sql`** (after the deploy). Drops `inventory_items_member_select`, so staff can no longer read inventory rows (purchase prices, par levels, quantities) through the API. Admins keep their read of active rows; owners keep everything. Applied before the deploy, the old application would show staff request lines without inventory names until it deploys. Its preflight refuses to run before step 1.

## Order (SQL Editor)

Run each file as its own query: paste the whole file, run it once, and read the result before going on.

1. **`precheck.sql`**
   - Success: a grid of fingerprint rows. Download as `phase7a2_pre.csv`.
   - STOP on any error. `precheck: Phase 7A.2 objects already exist` means step 2 already ran; do not run it again. `Phase 7A.1 function differs from the reviewed production state` means production drifted from main.
2. **`20261027120000_phase7a2_inventory_physical_counts.sql`**
   - One transaction with a preflight and an in-migration postcheck; any error rolls it back.
   - The Editor may ask to confirm destructive operations (it drops and recreates the `inventory_adjustments` reason check). It must **not** offer "Run and enable RLS". If it does, stop.
   - Success: no error, no rows.
   - STOP on any error and run `precheck.sql` again before anything else: it passes with the same rows (nothing was left behind), or reports that 7A.2 objects exist (the migration committed; run `postcheck.sql`, never the migration again).
3. **`postcheck.sql`**
   - Success: fingerprint rows; save as `phase7a2_post.csv`. Compare with step 1: only the lines below may differ.
   - STOP on any error.
4. **Deploy the application.** Verify it, then:
5. **`20261027120100_phase7a2_staff_inventory_read_hardening.sql`**. Success: no error.
6. **`hardening_postcheck.sql`**. Success: fingerprint rows. Compared with step 3, only `policies | inventory_items` may differ (plus count and label rows written by real use in between).

## Expected differences (precheck → postcheck)

- **New functions** (`absent` → hash), all `secdef=true` except the two trigger functions:
  - member-callable (`authenticated=true anon=false public=false`): `resolve_inventory_count_label`, `list_countable_inventory_locations`, `get_inventory_count_location`, `submit_inventory_count`, `get_supply_request_inventory_identities`;
  - owner-callable (same grants, owner check inside): `issue_inventory_location_label`, `revoke_inventory_location_labels`, `list_inventory_location_count_status`;
  - internal (`authenticated=false anon=false public=false`): `inventory_countable_balances`, `inventory_count_summary`, `inventory_count_replay`, `tg_guard_inventory_count_history`, `tg_guard_inventory_location_label`.
- **Overloads:** `submit_inventory_count`, `get_inventory_count_location`, `resolve_inventory_count_label`, `issue_inventory_location_label` go from 0 to 1.
- **Constraints:** `inventory_adjustments_reason_check` changes (adds `Physical count`); `inventory_adjustments_physical_count_check` and `inventory_adjustments_count_line_fk` go from `absent` to a hash.
- **Counts:** functions +13, tables +3, indexes +14, policies +2, triggers +3. On the current production baseline: 95/39/146/56/66 → 108/42/160/58/69.
- **New tables:** `policies`, `triggers` and `grants` lines for `inventory_count_sessions`, `inventory_count_lines` and `inventory_location_labels`. Labels: `service_role=SELECT` only; sessions and lines: `authenticated=SELECT,service_role=SELECT` (owner-only by policy).

Everything else must be identical: every 7A.1 and neighbouring function hash, every `rows` line (items, balances, locations, transfers, adjustments, invoices, budgets, requests, sites) and every `org_total` line. The migration writes no rows.

## What the assertions cover

- **Precheck:** no 7A.2 objects; the 7A.1 functions match the reviewed production hashes; the `source_type` and `reason` constraints and the `inventory_items` policies are the reviewed definitions; no `physical_count` rows; pgcrypto in `extensions`; the quantity invariant.
- **Postcheck:** the new tables with RLS enabled and no rows; the 13 new functions' bodies and grants; the ledger constraints; no direct writes for any application role, no label reads, owner-only history; the immutability triggers; 7A.1 unchanged; staff hardening not yet applied.
- **Hardening postcheck:** `inventory_items_member_select` gone and the reviewed policy set in place; the identities function unchanged.

## Provenance

Hashes come from a disposable `public.ecr.aws/supabase/postgres:17.6.1.167` migrated from main `a921299` (whose 7A.1 hashes equal production's). `phase7a2_release_check.sh` runs the whole sequence, including an induced failure before `COMMIT` (complete rollback), a refused second application and a refused hardening before the count migration.
