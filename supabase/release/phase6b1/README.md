# Phase 6B.1 release checks

These scripts check the Phase 6B.1 release (Multi-Vendor Intelligence V1) on production: one migration, `20261123120000_phase6b1_multi_vendor_intelligence.sql`. They are read-only and migrate nothing themselves.

Production is migrated by hand in the Supabase SQL Editor. Never use `supabase db push` (see `../phase7a1/README.md`, "Migration history").

Every file here works in the SQL Editor exactly as written: no psql meta-commands, no transaction control. `precheck.sql` and `postcheck.sql` are each one DO block of assertions followed by the shared fingerprint SELECT (`fingerprint.sql`), so the result grid is the full output. The migration creates no table, so the Editor's "Run and enable RLS" check has nothing to flag and must not appear. `supabase/tests/phase6b1_release_check.sh` proves all of this on a seeded FC Cincinnati-like copy, sending each file the way the Editor does.

`fingerprint.sql` is the source. `precheck.sql` and `postcheck.sql` are generated from it by `supabase/tests/support/phase6b1_release_generate.mjs` (expected values read, read-only, from a disposable database on main `18ab8ba` and the same with this migration); never edit them by hand. The release check fails if the committed files are not exactly what the generator produces.

## What the migration does

Locked product rules (2026-11-22): a price observation is a posted invoice or order-confirmation line already in `inventory_price_history`; nothing is copied or persisted. Same-SKU history compares only the same vendor, SKU identity and unit. A product is Insufficient identity when one vendor has more than one SKU identity for it (observed SKUs plus active mappings), an observation has no SKU, or a vendor's latest observation has a missing or malformed unit. Vendors are compared numerically only with a proven-equal unit and package and only when both observations are 180 UTC days old or less; a structurally comparable stale pair stays Comparable with the Stale marker and no numbers. No base-unit normalization, no current or market price, no savings, no vendor recommendation. Owners and admins read; staff do not. Nothing here writes.

- **Indexes** on `inventory_price_history`: `inventory_price_history_product_vendor_order_idx` (organization, product, vendor, purchase date, created, id) and `inventory_price_history_org_recent_idx` (organization, purchase date, created, id, newest first, for the keyset list).
- **New client functions** (`authenticated` EXECUTE; owner/admin checked inside through 7E's `financial_assert_access`): `list_price_intelligence_products` (keyset pages by last purchase or product name; filters scan at most 1,000 products per call and return a cursor), `get_price_intelligence_summary`, `get_product_vendor_price_history` (product or inventory item), `get_supply_request_price_context`.
- **New internal functions** (no client EXECUTE): `price_unit_key`, `price_unit_is_valid`, `price_recency`, `price_catalog_unit_agrees`, `price_package_agreement`, `price_catalog_package_agreement`, `price_row_is_valid`, `price_observation_rows`, `price_recent_anchors`, `price_name_anchors`, `price_observation_evidence`, `price_product_state` (the canonical comparison rules), and the summary's counting path `price_summary_flagged_invoices`, `price_summary_groups`, `price_summary_product_states` (the same rules executed for counts only; the behaviour suite and the benchmark assert it equals `price_product_state` for every product).
- **Changed functions** (same signatures, exactly the same JSON keys): `get_price_intelligence_overview` and `get_product_price_intelligence` now follow the rules above. Changes never cross SKU, vendor or unit; `bestAlternative` appears only when strictly comparable and recent; `unitSavings` and `recentAverage` are always `null`.

The preflight refuses to run when 7E is missing, any 6B.1 object exists, or the database TimeZone is not UTC. No row of any table is written.

## Compatibility window (migrate first, then deploy)

Migrate before the deploy: the new Price Intelligence list, product history, request-review line and Replenishment link call the new functions. Between the migration and the deploy, a browser still running the previous app keeps working: Budget & Purchasing, Price Intelligence and catalog product detail load, the previous app's strict schemas parse the changed payloads (the release check replays them through main's schemas), the two false increases disappear, and savings show as none. Deploying before migrating would break the new list, so keep the order.

## FC Cincinnati

Expected `price` line for FC Cincinnati after the migration (production data as audited on 2026-11-22; posting more documents changes it):

`products=74 | observations=81 | insufficient_identity=5 | multiple_skus=5 | one_purchase=67 | single_vendor=2 | comparable=0 | missing_package_details=0 | incompatible_units=0 | same_sku_increases=0 | lower_comparable=0`

The five Insufficient identity products are the Ammex gloves, the Eco-Flex tape, the APS needles, Athletic Tape 950 and Protex (several Henry Schein SKUs under one product each). The two price increases shown before the release (Ammex, Eco-Flex) compared different SKUs and disappear. Leukotape and Mediproxen show No change. No demo vendors or observations are created.

## Order (SQL Editor)

Run each file as its own query: paste the whole file, run it once, and read the result before going on. Run steps 1–3 back to back.

1. **`precheck.sql`**
   - Success: a grid of fingerprint rows. Download as `phase6b1_pre.csv`. Every `price` line reads `absent`.
   - STOP on any error. `precheck: Phase 6B.1 objects already exist` means step 2 already ran; do not run it again. `Phase 7E is not applied`, `function is missing or differs`, `the Price Intelligence signatures differ`, `table is missing or differs`, `cannot create the 6B.1 functions and indexes`, `organization roles or request statuses differ`, `TimeZone must be UTC` or `public object counts differ` means production drifted from main `18ab8ba`.
2. **`20261123120000_phase6b1_multi_vendor_intelligence.sql`**
   - One transaction with a preflight; any error rolls the whole file back.
   - The Editor must **not** offer "Run and enable RLS". If it does, stop.
   - Success: no error, no rows.
   - STOP on any error, then run `precheck.sql` again: it passes with the same rows. A second application is refused (`Phase 6B.1 multi-vendor intelligence objects already exist unexpectedly`); if you see that, the migration already committed: run `postcheck.sql`, never the migration again.
3. **`postcheck.sql`**
   - Success: fingerprint rows; save as `phase6b1_post.csv`. Compare with step 1: only the lines below may differ. It also calls the two changed reads as an owner of the first organization with price history (transaction-local, nothing written) and checks their keys.
   - STOP on any error.
4. **Deploy the application** (merge to main).

## Expected differences (precheck → postcheck)

- **New functions** (`absent` → hash): the 19 listed above. Client RPCs: `secdef=true authenticated=true anon=false service_role=true public=false`; internal ones `secdef=false authenticated=false anon=false service_role=false public=false`. Their `overloads` lines go from `0` to `1`.
- **Changed functions** (new hash, same access, one overload each): `get_price_intelligence_overview`, `get_product_price_intelligence`.
- **New indexes**: `inventory_price_history_product_vendor_order_idx`, `inventory_price_history_org_recent_idx`.
- **Counts**: public functions +19, indexes +2; tables, policies and triggers unchanged. On the production baseline: functions 208 → 227, tables 55, indexes 207 → 209, policies 58, triggers 89.
- **Price lines**: `absent` → the per-organization figures (FC Cincinnati above).

Everything else must be identical, including every price history, invoice, line, upload, vendor, mapping, product, alias, catalog listing, budget, request, commitment, inventory, rule, removal, notification, organization, membership and profile hash. Real use between the precheck and the postcheck (a document posted) changes the matching `rows` lines.

## After the deploy (read/UI acceptance only)

Acceptance is read-only: do not post, remove or edit anything for it.

- Owner, Budget & Purchasing → Overview → Price Intelligence: 74 products; filter counts Insufficient identity 5, One purchase recorded 67, Single vendor observed 2, Comparable 0; "Same-SKU price increased" 0. No "Current price", "Savings" or "Recommended" anywhere; no 500-row note; Load more appears only when more remain.
- Open Ammex gloves: Insufficient identity, both SKUs listed, "Prices are not compared", both source lines visible. Eco-Flex likewise with its three SKUs. Mediproxen: No change, last purchase labelled "Order confirmation · Posting date". Leukotape: No change. Protex: the `EA)` line is shown as an unreadable unit.
- Owner: a document number opens the posted document. Admin (if a real admin exists): the same history with the source reference and no document action.
- Catalog: an adopted product shows the same purchase history.
- Request review (owner or admin): each resolvable line shows "Last purchased from Henry Schein at $…/… on …" and a "View purchase history" link that opens the product in Budget & Purchasing. Nothing about the request changes.
- Inventory → Replenishment: FC Cincinnati has no rules, so no "Needs purchasing" row exists to show the link (covered by tests).
- Staff: still sent to their own workspace; no Price Intelligence.

## Benchmark exception

`supabase/tests/run_phase6b1_price_integration.sh` measures every read through PostgREST at 250,000 and 1,000,000 observations. List pages, filtered scans, product history and request context are well inside their targets. The summary (filter counts) reads every observation once, in one hash-aggregated pass with one index probe per product and vendor; it builds no evidence and spills nothing to disk. At 250,000 observations it takes p50 212 ms / p95 240 ms. At 1,000,000 observations it takes p50 1,046 ms / p95 1,233 ms (an earlier run: p95 1,180 ms), down from about 3.7 s before the counting path. The 1M summary p95 modestly exceeds the original 1.0 s target but is accepted for V1 because direct SQL is exact, bounded, substantially improved from ~3.7 s, and avoiding persistent derived state is preferable at this stage. The harness asserts that the counting path equals `price_product_state` for every product at both sizes, that no sort reaches disk, and that temporary writes stay under 8 MB (587 blocks measured). The list never waits for the summary (counts appear when it arrives). FC Cincinnati has 81 observations.

## Provenance

Hashes come from a disposable `public.ecr.aws/supabase/postgres:17.6.1.167` migrated from main `18ab8ba` (production's application commit, Phase 7E) plus this migration. The main-only database reproduces the production baseline counts (208 / 55 / 207 / 58 / 89). Regenerate with both databases running: `node supabase/tests/support/phase6b1_release_generate.mjs --pre <port> --post <port>` (`--check` compares without writing).
