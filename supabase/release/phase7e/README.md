# Phase 7E release checks

These scripts check the Phase 7E release (Budget Analytics & Financial Intelligence V1) on production: one migration, `20261117120000_phase7e_budget_analytics.sql`. They are read-only and migrate nothing themselves.

Production is migrated by hand in the Supabase SQL Editor. Never use `supabase db push`: the migration history does not record hand-applied migrations (see `../phase7a1/README.md`, "Migration history").

Every file here works in the SQL Editor exactly as written: no psql meta-commands, no transaction control. `precheck.sql` and `postcheck.sql` are each one DO block of assertions followed by the shared fingerprint SELECT (`fingerprint.sql`), so the result grid is the full output. The migration creates one table and enables RLS on it in the same file, so the Editor's "Run and enable RLS" check has nothing to flag and must not appear. `supabase/tests/phase7e_release_check.sh` proves all of this on a seeded FC Cincinnati-like copy, sending each file the way the Editor does.

`fingerprint.sql` is the source. `precheck.sql` and `postcheck.sql` are generated from it by `supabase/tests/support/phase7e_release_generate.mjs` (expected values read, read-only, from a disposable database on main `63b86bb` and the same with this migration); never edit them by hand. The release check fails if the committed files are not exactly what the generator produces.

## What the migration does

Locked product rules (2026-11-16): a budget is one organization-wide budget for a period; Actual Spend counts posted documents except credit memos and statements, in USD or with no currency recorded (legacy, treated as USD), dated by invoice date or the UTC day of posting; Remaining = Budget − Spent; commitments are reported separately (open; received, not settled) and never subtracted; posted documents are immutable and can only be removed by the owner with a recorded reason, keeping the source PDF; all financial dates are UTC calendar days.

- **Table `financial_document_removals`**: an append-only snapshot of each removed posted document (header, lines, spend amount, inventory reversal summary, storage path, reason, who, when). RLS on, no policies, `service_role` SELECT only; an append-only trigger refuses updates and deletes. **No rows are created.**
- **Index `invoices_org_posted_spend_idx`**: posted invoices by organization and spend date.
- **Triggers**: `organization_budgets_no_overlap` (active budget periods cannot overlap; SQLSTATE `23P01`; deactivating is always allowed), `invoices_posted_guard` and `invoice_items_posted_guard` (a posted document and its lines cannot change or be deleted, and `posted_at` changes only through invoice review, for every role including `service_role`), `financial_document_removals_append_only`. Only `post_reviewed_invoice` and `remove_posted_financial_document` pass the guards, through a transaction-local setting they set and clear themselves.
- **Changed functions** (same signatures and result shapes):
  - `post_reviewed_invoice` refuses `CREDIT_MEMO` and `STATEMENT` (SQLSTATE `22023`).
  - `delete_invoice_permanently` refuses posted documents (`55000`, "Posted documents must be removed with a recorded reason."); drafts and unprocessed uploads delete as before. Its body moved unchanged into the internal `delete_invoice_internal`.
  - `get_budget_summary`, `get_supply_request_budget_impact`, `get_budget_purchasing_overview`, `get_budget_lineage` read the new spend rows (identical figures on production data; identical JSON keys, because the deployed app parses them strictly). Recent purchases show an order confirmation's order number.
  - `get_price_intelligence_overview`, `get_product_price_intelligence` treat no currency recorded as USD (FC Cincinnati's prices now appear); other currencies stay excluded.
- **New client functions** (`authenticated` EXECUTE; access checked inside): `get_financial_spend_summary`, `get_financial_spend_series`, `list_financial_vendor_spend`, `list_financial_product_spend`, `list_financial_commitments` (owners and admins); `list_financial_spend_documents`, `get_financial_document_detail`, `list_financial_product_lines`, `list_financial_document_removals`, `remove_posted_financial_document` (owner only); `vendor_invoice_storage_deletable` (the storage policy's helper).
- **Internal functions** (no client EXECUTE): `financial_spend_rows` (the single definition of Actual Spend), `financial_spend_line_rows`, `financial_commitment_rows`, `financial_possible_duplicate_ids`, `financial_outside_budget_ids`, `financial_currency_basis`, `financial_context_is`, `financial_assert_range`, `financial_assert_access`, `financial_spend_row_json`, `delete_invoice_internal`, and the four trigger functions.
- **Storage policy** `vendor_invoices_storage_owner_delete` on `storage.objects` is re-created with one more condition: the file must not belong to a posted or removed document. Drafts and failed uploads stay deletable. If the SQL Editor role cannot replace a storage policy, the whole migration rolls back (one transaction).

The preflight refuses to run when 7D is missing, active budgets overlap, a posted credit memo or statement exists, or the database TimeZone is not UTC. Existing budgets are never altered.

## Compatibility window (migrate first, then deploy)

Migrate before the deploy: the Spend tab and the posted-document removal call the new functions. Between the migration and the deploy, a browser still running the previous app keeps working: budget summary and Command Center payloads keep their keys and figures; posting works; deleting a draft works; deleting a posted document is refused with a clear message (nothing changes); Price Intelligence shows more rows. Deploying before migrating would break the new tab, so keep the order.

## FC Cincinnati

Nothing about the "Tape" budget changes (name, amount, dates, active). Its Spent stays $20,256.15 (the postcheck proves 7E's Spent equals the pre-7E figure for every active budget). Renaming it is the owner's choice through the existing edit, not part of the release.

## Order (SQL Editor)

Run each file as its own query: paste the whole file, run it once, and read the result before going on. Run steps 1–4 back to back.

1. **`precheck.sql`**
   - Success: a grid of fingerprint rows. Download as `phase7e_pre.csv`. Check the `budget` row for Tape reads `actual=20256.15 | documents=5`.
   - STOP on any error. `precheck: Phase 7E objects already exist` means step 2 already ran; do not run it again. `Phase 7D is not applied`, `function is missing or differs`, `table is missing or differs`, `storage policy is missing or differs`, `organization roles or request statuses differ`, `TimeZone must be UTC`, `posted credit memos, statements or other-currency documents exist`, `active budgets overlap` or `public object counts differ` means production drifted from main `63b86bb`.
2. **`20261117120000_phase7e_budget_analytics.sql`**
   - One transaction with a preflight; any error rolls the whole file back.
   - The Editor must **not** offer "Run and enable RLS". If it does, stop. The Editor may warn about destructive operations because the file drops and re-creates a storage policy; that is expected.
   - Success: no error, no rows.
   - STOP on any error, then run `precheck.sql` again: it passes with the same rows. A second application is refused (`Phase 7E budget analytics objects already exist unexpectedly`); if you see that, the migration already committed: run `postcheck.sql`, never the migration again.
3. **`postcheck.sql`**
   - Success: fingerprint rows; save as `phase7e_post.csv`. Compare with step 1: only the lines below may differ.
   - STOP on any error.
4. **Deploy the application** (merge to main). Budget & Purchasing gains the Spend tab; Available becomes Remaining after posted spend; posted invoices get Remove instead of Delete.

## Expected differences (precheck → postcheck)

- **New functions** (`absent` → hash): the 26 listed above. Client RPCs: `secdef=true authenticated=true anon=false service_role=false public=false`; internal ones `authenticated=false anon=false service_role=false`.
- **Changed functions** (new hash, same access and one overload each): the 8 listed above.
- **New table** `financial_document_removals` (`absent` → column hash with `rls=true`), its `grants` line (`none` → `service_role=SELECT`), `policies` stays `none`; three new `constraint` lines; three new `index` lines for it plus `invoices_org_posted_spend_idx`; four new `trigger` lines.
- **Storage policy** `vendor_invoices_storage_owner_delete` changes; the insert and select policies do not.
- **Counts**: public functions +26, tables +1, indexes +4, triggers +4; policies unchanged. On the production baseline: functions 182 → 208, tables 54 → 55, indexes 203 → 207, triggers 85 → 89, policies 58.
- **Rows**: `financial_document_removals count` goes from `absent` to `0`.

Everything else must be identical, including every invoice, invoice line, upload, budget, commitment, request, inventory, transfer, rule, notification, organization, membership, vendor and product hash, and every `budget` line. Real use between the precheck and the postcheck (a request decided, a document posted) changes the matching `rows` and `budget` lines.

## After the deploy (read/UI acceptance only)

Acceptance is read-only: do not post, remove or delete a document and do not save a budget for it.

- Owner, Budget & Purchasing → Spend: scope line "Tape · … · Organization-wide · spend attributed by invoice date (UTC)"; Budget $50,000.00, Spent $20,256.15, Remaining $29,743.85; open commitments 3 ($36.78 priced, 0 of 3 fully priced, 1 partly); received, not settled 2; pace behind an even pace; coverage: 2 documents dated by posting day and 2 order confirmations ($244.28), 5 with no currency recorded; drill-down totals match the headlines.
- Overview: Remaining instead of Available; Price Intelligence lists FC Cincinnati's products.
- Invoices: a posted invoice shows Remove; open the dialog and cancel it without removing.
- Admin (if a real admin exists): the Spend figures without document drill-down. Staff: still sent to their own workspace.
- Notifications and the digest are unchanged.

## Provenance

Hashes come from a disposable `public.ecr.aws/supabase/postgres:17.6.1.167` migrated from main `63b86bb` (production's application commit, Phase 7D) plus this migration. The main-only database reproduces the production baseline counts (182 / 54 / 203 / 58 / 85). Regenerate with both databases running: `node supabase/tests/support/phase7e_release_generate.mjs --pre <port> --post <port>` (`--check` compares without writing).
