# Phase 7C release checks

These scripts check the Phase 7C release (Receiving Destination) on production: one migration, `20261112140000_phase7c_receiving_destination.sql`. They are read-only and migrate nothing themselves.

Production is migrated by hand in the Supabase SQL Editor. Never use `supabase db push`: the migration history does not record hand-applied migrations (see `../phase7a1/README.md`, "Migration history").

Every file here works in the SQL Editor exactly as written: no psql meta-commands, no transaction control. `precheck.sql` and `postcheck.sql` are each one DO block of assertions followed by the shared fingerprint SELECT (`fingerprint.sql`), so the result grid is the full output. The migration creates one table and enables RLS on it in the same file, so the Editor's "Run and enable RLS" check has nothing to flag and must not appear. `supabase/tests/phase7c_release_check.sh` proves all of this on a seeded copy (requests decided, ordered and received through the real 7C.0 lifecycle, one left ordered across the release, a storage location, stock, a budget, invoices and notification events), sending each file the way the Editor does.

`fingerprint.sql` is the source. `precheck.sql` and `postcheck.sql` are generated from it by `supabase/tests/support/phase7c_release_generate.mjs` (expected values read, read-only, from a disposable database on main `8448f4c` and the same with this migration); never edit them by hand. The release check fails if the committed files are not exactly what the generator produces.

## What the migration does

Receiving records **where a delivery was received**. It is destination-only: it does not add, subtract or transfer inventory, change invoice stock, create inventory items or change budget actuals.

- **Table `supply_request_receipts`**: one immutable row per receipt (`ordered → received`), at most one per request (unique `supply_request_id` and `supply_request_update_id`). It records the inventory location, a name snapshot (`destination_name_snapshot`, so a later rename does not rewrite history), the kind (`storage` / `unassigned`), who received it and when, the `received` history row it belongs to, and `compound_action` for Receive & Complete. Composite foreign keys keep the request and the location in the same organization (RESTRICT). A BEFORE UPDATE trigger (`supply_request_receipts_immutable`) refuses changes. RLS on, no policies, `service_role` SELECT only, no client grants. **No rows are created: requests received before 7C have no receipt** and show no destination.
- **New client functions** (`authenticated` EXECUTE only; access checked inside):
  - `list_receiving_destinations(org)`: owners and admins (`is_org_admin`); active locations of the organization, storage first by name, Unassigned last. Returns id, name and kind only (no balances).
  - `list_supply_request_receipts(org, request_ids)`: any active member; admins see every receipt, staff only their own requests' receipts, without the location id.
- **Changed functions**:
  - `apply_supply_request_receipt` (private, no client EXECUTE) is dropped and re-created with a required `_inventory_location_id`. It is the only place a request becomes received: it locks the request, validates the destination (this organization, active), refuses a second receipt, runs the canonical `received` transition and writes the receipt in the same transaction.
  - `receive_supply_request` and `receive_and_complete_supply_request` are dropped and re-created with a trailing `_inventory_location_id uuid DEFAULT NULL`. A retry naming the same destination answers `alreadyApplied`; a different destination is refused ("…already received to X. A receiving destination cannot be changed."). Receive & Complete from `received` (a request received before 7C, or by Mark Received) completes only and records no receipt.
  - `transition_supply_request` is identical except that `received` is refused: "Use the receiving action to choose a receiving destination." (SQLSTATE `55000`). Its grants are unchanged (it already had `anon` EXECUTE before 7C and checks membership itself; 7C neither adds nor removes grants on it).

No existing row, policy or grant on another table changes. No inventory, invoice, budget, commitment, notification or digest logic changes.

## Compatibility window (migrate first, then deploy)

The migration must run before the deploy: the new drawer calls `list_receiving_destinations` and passes `_inventory_location_id`. Between the migration and the deploy, a browser still running the previous app sends Mark Received or Receive & Complete without a destination. Those calls are **refused**, with nothing written:

> Refresh SportSpend and choose a receiving destination to receive this request.

There is deliberately no destination-less fallback: a receipt never defaults silently. Every other action (approve, deny, order, complete, cancel, Approve & Order) works unchanged across the window. Keep the window short (run the steps below back to back) and tell admins to refresh if they see the message.

## Before the release: storage locations

FC Cincinnati currently has only **Unassigned** as an active inventory location, so after the release Unassigned ("Unassigned / not yet placed") is the only choice. If the owner wants real destinations (for example a first-team athletic training room), the owner creates them in Inventory before rollout. Creating locations is not part of this release and is never done by these scripts.

## Order (SQL Editor)

Run each file as its own query: paste the whole file, run it once, and read the result before going on. Run steps 1–4 back to back.

1. **`precheck.sql`**
   - Success: a grid of fingerprint rows. Download as `phase7c_pre.csv`.
   - STOP on any error. `precheck: Phase 7C objects already exist` means step 2 already ran; do not run it again. `precheck: Phase 7C.0 is not applied`, `function is missing or differs from the reviewed production state`, `table is missing or differs from the reviewed production state`, `organization roles or request statuses differ` or `public object counts differ` means production drifted from main `8448f4c`.
2. **`20261112140000_phase7c_receiving_destination.sql`**
   - One transaction with a preflight; any error rolls the whole file back.
   - The Editor must **not** offer "Run and enable RLS". If it does, stop.
   - Success: no error, no rows.
   - STOP on any error, then run `precheck.sql` again: it passes with the same rows. A second application is refused (`Phase 7C receiving destination objects already exist unexpectedly`); if you see that, the migration already committed: run `postcheck.sql`, never the migration again.
3. **`postcheck.sql`**
   - Success: fingerprint rows; save as `phase7c_post.csv`. Compare with step 1: only the lines below may differ.
   - STOP on any error.
4. **Deploy the application** (merge to main). The drawer gains the required receiving-destination picker; history and the staff request page show the destination.

## Expected differences (precheck → postcheck)

- **New functions** (`absent` → hash): `list_receiving_destinations`, `list_supply_request_receipts` (`secdef=true authenticated=true anon=false service_role=false public=false`) and the trigger function `guard_supply_request_receipt_immutable` (`secdef=false authenticated=false anon=false service_role=false public=false`).
- **Changed functions** (new hash, same access): `apply_supply_request_receipt` (`authenticated=false`), `receive_supply_request`, `receive_and_complete_supply_request` (`authenticated=true anon=false`), `transition_supply_request` (unchanged access line). Their `overloads` lines show the new argument lists.
- **New table** `supply_request_receipts` (`absent` → column hash with `rls=true`), its `grants` line (`none` → `service_role=SELECT`), `policies` stays `none`; new `constraint` lines for it; five new `index` lines (`supply_request_receipts_pkey`, `_request_key`, `_update_key`, `_org_location_idx`, `_org_received_idx`); one new `trigger` line (`supply_request_receipts.supply_request_receipts_immutable`).
- **Counts**: public functions +3, tables +1, indexes +5, triggers +1; policies unchanged. On the current production baseline: functions 171 → 174, tables 52 → 53, indexes 194 → 199, triggers 83 → 84, policies 58.
- **Rows**: `supply_request_receipts count` goes from `absent` to `0`.

Everything else must be identical, including every request, history, item, commitment, notification, inventory, invoice and budget hash. Real use between the precheck and the postcheck (a request submitted or decided) changes the matching `rows` lines.

## After the deploy

- Mark Received and Receive & Complete (Lean and Standard) show **Receiving destination (required)** in the drawer. The button stays disabled until a destination is chosen; there is no confirmation screen. The request's team and location appear as context only ("Requested for: …"): they are request locations, not inventory locations, and never choose the destination.
- The last destination used is remembered in that browser only (`localStorage`), and preselected only while it is still an active option.
- History shows "Received — First Team ATR" (or "Received & completed — …"). Staff see "Delivered to First Team ATR", or "Received, not yet placed" for Unassigned. Internal notes stay hidden from staff.
- Notifications are unchanged: receiving sends no email.
- Partial receipts and inventory placement (8B) are out of scope.

## Provenance

Hashes come from a disposable `public.ecr.aws/supabase/postgres:17.6.1.167` migrated from main `8448f4c` (production's application commit, Phase 7C.0) plus this migration. The main-only database reproduces the production baseline counts (171 / 52 / 194 / 58 / 83), and every pinned function hash and table definition except the documented ones is identical before and after the migration. Regenerate with both databases running: `node supabase/tests/support/phase7c_release_generate.mjs --pre <port> --post <port>` (`--check` compares without writing). `phase7c_release_check.sh` runs the whole sequence on a seeded copy: an induced failure before `COMMIT` (complete rollback, precheck passes again), a refused second application, a refused repeat precheck, the destination-less call of an old browser refused with the refresh message, the generic transition refused, the request left ordered across the release received with exactly one receipt and no inventory, invoice or commitment change, and a request received before the release completing without a receipt.
