# Phase 7D release checks

These scripts check the Phase 7D release (Replenishment V1) on production: one migration, `20261113120000_phase7d_inventory_replenishment.sql`. They are read-only and migrate nothing themselves.

Production is migrated by hand in the Supabase SQL Editor. Never use `supabase db push`: the migration history does not record hand-applied migrations (see `../phase7a1/README.md`, "Migration history").

Every file here works in the SQL Editor exactly as written: no psql meta-commands, no transaction control. `precheck.sql` and `postcheck.sql` are each one DO block of assertions followed by the shared fingerprint SELECT (`fingerprint.sql`), so the result grid is the full output. The migration creates one table and enables RLS on it in the same file, so the Editor's "Run and enable RLS" check has nothing to flag and must not appear. `supabase/tests/phase7d_release_check.sh` proves all of this on a seeded copy (stock moved between two storage locations, a request received to a location through 7C, one left ordered, count history, a budget, invoices and notification events), sending each file the way the Editor does.

`fingerprint.sql` is the source. `precheck.sql` and `postcheck.sql` are generated from it by `supabase/tests/support/phase7d_release_generate.mjs` (expected values read, read-only, from a disposable database on main `a4c9d81` and the same with this migration); never edit them by hand. The release check fails if the committed files are not exactly what the generator produces.

## What the migration does

Replenishment is **computed live** from current balances and rules. Nothing is purchased, requested, moved or notified automatically, and nothing reads `inventory_items.par_level`.

- **Table `inventory_replenishment_rules`**: at most one rule per inventory item × inventory location (`UNIQUE (inventory_item_id, inventory_location_id)`), with `minimum_quantity` (≥ 0), `target_quantity` (> 0, ≥ minimum; both at most 1,000,000,000 with up to six decimal places), `enabled`, created/updated by and at. Composite foreign keys keep the item and location in the rule's organization. The guard trigger `inventory_replenishment_rules_guard` refuses a rule at Unassigned (or any non-storage location) and any change of organization, item, location, id or created_at; `updated_at` is the optimistic version and moves only when Minimum, Target or enabled change. RLS on, no policies, `service_role` SELECT only, no client grants. **No rows are created.**
- **Column `inventory_transfers.source`**: `'manual'` (default) or `'replenishment'` (`inventory_transfers_source_check`). A constant default: no table rewrite, and every existing transfer reads `manual`.
- **Changed function** `move_inventory_stock`: dropped and re-created with a trailing `_source text DEFAULT 'manual'`. Same body otherwise (authorization owner-only, idempotency key, quantity and balance checks, locking, transfer semantics) and the same grants. Unknown sources are refused ("Unknown move source"). An idempotent replay keeps the first stored source.
- **New client functions** (`authenticated` EXECUTE only; access checked inside):
  - `set_inventory_replenishment_rule(org, item, location, minimum, target, expected_updated_at)` and `set_inventory_replenishment_rule_enabled(org, rule, enabled, expected_updated_at)`: owner only. A null expected version creates (a duplicate is refused, never overwritten); an edit or enable/disable needs the version the screen showed (an older one is refused with SQLSTATE `55000`, never `40001`). Creating, editing and turning a rule on require an active item and an active storage location.
  - `list_inventory_replenishment(org, view, location, limit, cursor…)`, `get_inventory_replenishment_summary(org)`, `list_inventory_location_replenishment_rules(org, location, limit, cursor…)`: owners and admins (`is_org_admin`).
- **Internal functions** (no client EXECUTE): `inventory_replenishment_rows` (the single calculation), `inventory_replenishment_rule_json`, and the trigger function `tg_guard_inventory_replenishment_rule`.

No existing row, policy or grant changes. No inventory balance, item, adjustment, count, request, receipt, commitment, invoice, budget, notification or digest logic changes.

## The calculation

For each enabled rule whose item is active and whose location is an active storage location: current = balance at that location (0, flagged *not stocked here*, when no balance row exists; none is created); below Minimum when current ≤ Minimum; shortage = Target − current. Spare stock: Unassigned's whole balance; another active storage location's balance above its own enabled Minimum (0 without a rule). Move = min(shortage, spare elsewhere); needs purchasing = shortage − move. Donors are listed Unassigned first, then by spare, then by name (three at most, each with its share of the move). Categories: `move_available`, `partly_covered`, `needs_purchasing`, `ok`, and `inactive` (disabled, item archived or location archived). Count freshness and the organization-level open-request note (approved/ordered request lines carrying this inventory item) are context only.

## Compatibility window (migrate first, then deploy)

Migrate before the deploy: the new Replenishment tab calls the new functions and Move Stock sends `_source`. Between the migration and the deploy, a browser still running the previous app keeps working: its Move Stock call (six arguments) resolves to the new function through the default and is recorded `manual`; nothing else it calls changes. Deploying before migrating would break Move Stock (the app would send an argument the old function does not have), so keep the order.

## FC Cincinnati

No rule is created by the release, and these scripts create none. FC Cincinnati's stock is all in Unassigned; replenishment becomes meaningful only after the operational work (placing stock into First Team ATR, FCC2 ATR and Academy ATR, counting them, and choosing rules for selected items), which is not part of this release. Until then the Replenishment tab shows the empty state and coverage.

## Order (SQL Editor)

Run each file as its own query: paste the whole file, run it once, and read the result before going on. Run steps 1–4 back to back.

1. **`precheck.sql`**
   - Success: a grid of fingerprint rows. Download as `phase7d_pre.csv`.
   - STOP on any error. `precheck: Phase 7D objects already exist` means step 2 already ran; do not run it again. `precheck: Phase 7C is not applied`, `function is missing or differs from the reviewed production state`, `table is missing or differs from the reviewed production state`, `organization roles or request statuses differ` or `public object counts differ` means production drifted from main `a4c9d81`.
2. **`20261113120000_phase7d_inventory_replenishment.sql`**
   - One transaction with a preflight; any error rolls the whole file back.
   - The Editor must **not** offer "Run and enable RLS". If it does, stop.
   - Success: no error, no rows.
   - STOP on any error, then run `precheck.sql` again: it passes with the same rows. A second application is refused (`Phase 7D replenishment objects already exist unexpectedly`); if you see that, the migration already committed: run `postcheck.sql`, never the migration again.
3. **`postcheck.sql`**
   - Success: fingerprint rows; save as `phase7d_post.csv`. Compare with step 1: only the lines below may differ.
   - STOP on any error.
4. **Deploy the application** (merge to main). Inventory gains the Replenishment tab and storage locations gain Minimum and Target on their Stock tab.

## Expected differences (precheck → postcheck)

- **New functions** (`absent` → hash): `set_inventory_replenishment_rule`, `set_inventory_replenishment_rule_enabled`, `list_inventory_replenishment`, `get_inventory_replenishment_summary`, `list_inventory_location_replenishment_rules` (`secdef=true authenticated=true anon=false service_role=false public=false`); `inventory_replenishment_rows`, `inventory_replenishment_rule_json`, `tg_guard_inventory_replenishment_rule` (`authenticated=false anon=false`). Their `overloads` lines go from 0 to 1.
- **Changed function** (new hash, same access): `move_inventory_stock`; its `overloads` line stays 1.
- **New table** `inventory_replenishment_rules` (`absent` → column hash with `rls=true`), its `grants` line (`none` → `service_role=SELECT`), `policies` stays `none`; new `constraint` lines for it; four new `index` lines (`inventory_replenishment_rules_pkey`, `_item_location_key`, `_org_location_idx`, `_location_idx`); one new `trigger` line (`inventory_replenishment_rules.inventory_replenishment_rules_guard`).
- **Changed table** `inventory_transfers` (new column hash, `rls=true`) and one new `constraint` line (`inventory_transfers.inventory_transfers_source_check`). Its grants and policies are unchanged.
- **Counts**: public functions +8, tables +1, indexes +4, triggers +1; policies unchanged. On the current production baseline: functions 174 → 182, tables 53 → 54, indexes 199 → 203, triggers 84 → 85, policies 58.
- **Rows**: `inventory_replenishment_rules count` goes from `absent` to `0`; `inventory_transfers not manual` from `absent` to `0`.

Everything else must be identical, including every inventory item (with `par_level`), location, balance, adjustment, count, count policy, request, history, item, receipt, commitment, notification, invoice and budget hash, and the transfer hash taken without the new column. Real use between the precheck and the postcheck (a request submitted or decided, stock moved) changes the matching `rows` lines.

## After the deploy (read/UI acceptance only)

Acceptance is read-only: do not create a production rule, transfer, count or request for it.

- Owner: Inventory → Replenishment shows the empty state ("No replenishment rules yet…") and the coverage line; a storage location's Stock tab shows "Minimum and Target here" with **Set Minimum / Target** (opening the dialog and closing it without saving is enough).
- Admin (if a real admin exists): the same pages read-only, with no Set, Edit, Turn off or Move stock buttons.
- Staff: still sent to their own workspace; `/inventory` stays closed.
- Move Stock from the Items or Stock tabs behaves as before.
- Notifications and the morning digest are unchanged; nothing about replenishment is emailed.

## Provenance

Hashes come from a disposable `public.ecr.aws/supabase/postgres:17.6.1.167` migrated from main `a4c9d81` (production's application commit, Phase 7C) plus this migration. The main-only database reproduces the production baseline counts (174 / 53 / 199 / 58 / 84), and every pinned function hash and table definition except the documented ones is identical before and after the migration. Regenerate with both databases running: `node supabase/tests/support/phase7d_release_generate.mjs --pre <port> --post <port>` (`--check` compares without writing). `phase7d_release_check.sh` runs the whole sequence on a seeded copy: an induced failure before `COMMIT` (complete rollback, precheck passes again), a refused second application, a refused repeat precheck, an old app's six-argument Move Stock recorded as manual, pre-release transfers read manual, and an owner rule read by the calculation without any stock, transfer, request or notification change.
