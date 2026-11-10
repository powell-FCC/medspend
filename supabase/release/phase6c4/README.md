# Phase 6C.4 release checks

These scripts check the Phase 6C.4 migration on production. They are read-only and migrate nothing themselves.

Production is migrated by hand in the Supabase SQL Editor. Never use `supabase db push`: the migration history does not record hand-applied migrations (see `../phase7a1/README.md`, "Migration history").

Every file here works in the SQL Editor exactly as written: no psql meta-commands, no transaction control. `precheck.sql` and `postcheck.sql` are each one DO block of assertions followed by the shared fingerprint SELECT (`fingerprint.sql`), so the result grid is the full output. The migration creates two tables and enables RLS on each in the same file, so the Editor's "Run and enable RLS" check has nothing to flag and must not appear. `supabase/tests/phase6c4_release_check.sh` proves all of this on a seeded copy (40 invoice uploads with lines, 10 posted through `post_reviewed_invoice` with inventory and price history, a budget, stock, cadence OFF, plus the 5A.10 discovery and 7B.2 count-history fixtures and a small seed so that every fingerprinted data line hashes real rows), sending each file the way the Editor does.

`fingerprint.sql` is the source. `precheck.sql` and `postcheck.sql` are generated from it by `supabase/tests/support/phase6c4_release_generate.mjs` (expected values read, read-only, from a disposable database on main `33e42d3` and the same with this migration); never edit them by hand. The release check fails if the committed files are not exactly what the generator produces.

## What the checks pin

- **Functions (77 existing + 9 new)**, by body hash, SECURITY DEFINER and who may execute them; asserted in both DO blocks:
  - invoice upload, extraction, review, matching, posting and deletion (`post_reviewed_invoice`, `delete_invoice_permanently`, `seed_structured_invoice_draft`, `search_invoice_line_catalog_listings`, `match_invoice_item_to_catalog_listing`, …);
  - organization role helpers and `tg_set_updated_at`;
  - 5A.10 discovery and Saved Items (`search_supply_request_products`, `search_supply_request_products_with_signals`, `get_staff_product_discovery`, `save_staff_product`, `remove_staff_saved_product`, `staff_saved_product_identity_check`, …);
  - the request workflow (transitions, lifecycle guard, item replacement, submitted updates and cancellation, context, item costs, budget impact, inventory identities, specifications, product history and identities, staff updates), commitments, budget and inventory functions;
  - catalog adoption, stocking, admin detail, effective specifications, parent-link validation, the catalog normalization and search helpers and the four search-document trigger functions;
  - inventory count cadence (`get_inventory_count_policy`, `get_inventory_count_freshness`, `inventory_location_count_freshness`, `set_inventory_count_policy`).
- **Table definitions** (columns, types, NOT NULL, RLS), **policies** and **grants** of the new tables, `vendor_invoices`, `invoice_processing_jobs`, `invoices`, `invoice_items`, `inventory_items`, `inventory_adjustments`, `inventory_price_history`, `invoice_extraction_runs`, `invoice_extraction_candidates`, `invoice_line_items`, `vendor_identity_signatures`, `vendors` (read by duplicate detection), and the 5A.10 tables `staff_saved_products`, `catalog_search_terms`, `catalog_vendor_product_search_documents`. The definitions of the last eight are also asserted in both DO blocks.
- **Constraints** (primary, unique, foreign and check keys), **indexes** and **triggers** of the same invoice, pipeline, vendor and 5A.10 tables. Both DO blocks also assert the invoice file identity 6C.4 builds on: `invoices.source_file_id` is UNIQUE and a validated foreign key to `vendor_invoices(id)` `ON DELETE SET NULL`; `vendor_invoices.storage_path` is UNIQUE. There is no existing unique constraint on vendor + invoice number; that identity is the new partial unique index on `invoice_upload_batch_segments` plus the lookup in `register_invoice_batch_segment`.
- **Storage**: the `vendor-invoices` bucket and its owner-only storage policies.
- **Whole-row data hashes**: `vendor_invoices`, `invoice_processing_jobs`, `invoices`, `invoice_items`, `invoice_extraction_runs`, `invoice_extraction_candidates`, `invoice_line_items`, `vendor_identity_signatures`, `vendors`, `inventory_items`, `inventory_location_balances`, `inventory_adjustments`, `inventory_transfers`, `inventory_count_sessions`, `inventory_count_lines`, `inventory_price_history`, `supply_requests`, `supply_request_items`, `supply_request_commitments`, `organization_budgets`, `organizations`, `organization_memberships`, `products`, `vendor_products`, `product_aliases`, `catalog_products`, `catalog_vendor_products`, `catalog_vendors`, `catalog_source_records`; the `staff_saved_products` count and the cadence policies. Data is compared precheck → postcheck (production's own values; nothing is assumed from local fixtures).
- **Counts** of public functions, tables, indexes, policies and triggers, asserted in both DO blocks, and the absence of every 6C.4 object before the migration.

## One migration, before the deploy

**`20261109120000_phase6c4_batch_invoice_intake.sql`** adds:

- **Table `invoice_upload_batches`**: one row per uploaded PDF that held two or more invoices. The original file stays where it was uploaded (`storage_path`); `content_sha256` makes a re-upload of the same bytes return the same packet (unique per organization).
- **Table `invoice_upload_batch_segments`**: the page allocation of each packet. Contiguous page ranges that cover every page exactly once (checked when the packet is created; never updated afterwards). Kind `invoice` / `unresolved` / `non_invoice`; status `pending`, `created`, `duplicate`, `failed`, `held`, `ignored`. A created segment points at the ordinary `vendor_invoices` row made for it (`source_file_id`, `ON DELETE SET NULL`). Partial unique index: one created invoice per organization + identity (vendor key + normalized invoice number).
- Both tables: RLS on, no policies, `service_role` SELECT only, no `anon` / `authenticated` grants. One `updated_at` trigger.
- **Owner-only client functions** (`authenticated` EXECUTE, owner checked inside, like every invoice path): `create_invoice_upload_batch`, `register_invoice_batch_segment`, `fail_invoice_batch_segment`, `release_invoice_batch_segment`, `get_invoice_upload_batch`, `list_invoice_upload_batches`, `get_invoice_source_provenance`.
- **Internal** (no client EXECUTE): `invoice_batch_name_key`, `invoice_batch_identity_key`.

No existing table, column, index, policy, trigger, grant, function or row changes. A created segment is an ordinary upload: the existing `vendor_invoice_create_processing_job` trigger creates its job, and review, matching, `post_reviewed_invoice` and `delete_invoice_permanently` are unchanged (pinned by hash in both checks). The `vendor-invoices` bucket and its owner-only storage policies are unchanged (fingerprinted).

## Order (SQL Editor)

Run each file as its own query: paste the whole file, run it once, and read the result before going on.

1. **`precheck.sql`**
   - Success: a grid of fingerprint rows. Download as `phase6c4_pre.csv`.
   - STOP on any error. `precheck: Phase 6C.4 objects already exist` means step 2 already ran; do not run it again. `function is missing or differs from the reviewed production state`, `table is missing or differs from the reviewed production state`, `invoice file identity constraints differ` or `public object counts differ` means production drifted from main `33e42d3`.
2. **`20261109120000_phase6c4_batch_invoice_intake.sql`**
   - One transaction with a preflight; any error rolls everything back.
   - The Editor must **not** offer "Run and enable RLS". If it does, stop.
   - Success: no error, no rows. It creates empty tables only; it takes well under a second.
   - STOP on any error and run `precheck.sql` again: it passes with the same rows (nothing was left behind), or reports that 6C.4 objects exist (the migration committed; run `postcheck.sql`, never the migration again).
3. **`postcheck.sql`**
   - Success: fingerprint rows; save as `phase6c4_post.csv`. Compare with step 1: only the lines below may differ.
   - STOP on any error.
4. **Deploy the application.** The application needs the migration (the upload page calls `list_invoice_upload_batches`); deploying first would make the packet list fail to load on the upload page (single uploads would still work). Migrate first.

## Expected differences (precheck → postcheck)

- **New functions** (`absent` → hash): the nine above. The seven client functions are `secdef=true authenticated=true anon=false public=false`; the two internal ones `secdef=false authenticated=false anon=false public=false`. Their overloads go from 0 to 1.
- **New tables** (`absent` → column hash with `rls=true`), their `grants` lines (`none` → `service_role=SELECT`), `policies` stay `none`, new `constraint | invoice_upload_batch…` lines (their primary, unique, foreign and check keys), ten new `index | invoice_upload_batch…` lines and one new `trigger` line.
- **Counts**: public functions +9, tables +2, indexes +10, triggers +1; policies unchanged. On the current production baseline: functions 140 → 149, tables 46 → 48, indexes 171 → 181, triggers 75 → 76, policies 58.
- **Rows**: `invoice_upload_batches count` and `invoice_upload_batch_segments count` go from `absent` to `0`.

Everything else must be identical: every pinned function hash, every existing table, policy, grant, constraint, index and trigger line, the `vendor-invoices` bucket and storage policies, and every `rows` line listed under "What the checks pin". Real use between the precheck and the postcheck (an upload, a review) changes the matching `rows` lines; run the two back to back.

## Identity, duplicates and storage (for review)

- **Idempotency key of a created invoice**: `identity_key = <vendor key>:<invoice number, lower case, letters and digits only>` per organization (`henry-schein:52103732`). At most one created segment per key (partial unique index). Registration also refuses an invoice that already exists in `invoices` for the same organization, normalized invoice number and vendor (name containment either way, from `vendors.name` or `invoices.vendor_name`), for example one uploaded on its own and opened for review. Without a known vendor (generic detector), there is no cross-packet identity.
- **Packet identity**: `(organization_id, content_sha256)`. The same bytes uploaded again return the first packet; the second stored copy is removed by the application.
- **Retry**: `register_invoice_batch_segment` returns the existing invoice for a created segment; the application removes any file it stored that did not become a new invoice. Each segment is prepared and registered on its own (no packet-wide transaction).
- **Storage**: the original packet is kept once. Each created invoice also gets a PDF of exactly its pages (the existing review, extraction and deletion paths are keyed to one file per upload). The page subsets copy shared fonts and images, so together they are about the size of the packet again (26-page canonical packet: 7.5 MB original, 7.3 MB of subsets). Deleting one invoice removes only its subset; the packet and the other invoices stay.

## After the deploy: production acceptance

Owner: upload a normal one-invoice PDF: it opens invoice review exactly as before. Upload a multi-invoice packet: "Analyzing…", then the packet page ("Detected N invoices from M pages"), each invoice with its pages, items, amount and status, prepared a few at a time. Open one: invoice review shows "From pages X–Y of <packet>". Upload the same packet again: "This packet was already uploaded". Nothing is posted until the owner approves each invoice as usual. An acceptance upload creates real invoice records (decide beforehand whether to keep or delete them; deleting is the normal invoice deletion). Staff and admin are redirected / refused as for every invoice page.

## Provenance

Hashes come from a disposable `public.ecr.aws/supabase/postgres:17.6.1.167` migrated from main `33e42d3` (production's application commit, Phase 5A.10) plus this migration. The main-only database reproduces the production baseline counts (140 / 46 / 171 / 58 / 75), and every pinned function hash and table definition is identical before and after the migration. Regenerate with both databases running: `node supabase/tests/support/phase6c4_release_generate.mjs --pre <port> --post <port>` (`--check` compares without writing). `phase6c4_release_check.sh` runs the whole sequence on a seeded copy, including an induced failure before `COMMIT` (complete rollback), a refused second application and a refused repeat precheck.
