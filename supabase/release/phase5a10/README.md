# Phase 5A.10 release checks

These scripts check the Phase 5A.10 migration on production. They are read-only and migrate nothing themselves.

Production is migrated by hand in the Supabase SQL Editor. Never use `supabase db push`: the migration history does not record hand-applied migrations (see `../phase7a1/README.md`, "Migration history").

Every file here works in the SQL Editor exactly as written: no psql meta-commands, no transaction control. `precheck.sql` and `postcheck.sql` are each one DO block of assertions followed by the shared fingerprint SELECT (`fingerprint.sql`), so the result grid is the full output. The migration creates three tables and enables RLS on each in the same file, so the Editor's "Run and enable RLS" check has nothing to flag and must not appear. `supabase/tests/phase5a10_release_check.sh` proves all of this on a seeded copy (100,004 catalog products, 3,600 requests, 400 invoices, cadence OFF), sending each file the way the Editor does.

## One migration, before the deploy

**`20261107120000_phase5a10_staff_product_discovery.sql`** adds:

- **Extension `pg_trgm`** in the `extensions` schema (`CREATE EXTENSION IF NOT EXISTS`). It provides only the GIN operator class for the search-document index; nothing calls a trigram function.
- **Table `catalog_vendor_product_search_documents`**: a derived search index, one row per catalog vendor product (normalized name, normalized search text, SKU values and keys). Rebuilt by six statement triggers on `catalog_products`, `catalog_vendors`, `catalog_vendor_products` and `catalog_source_records`; backfilled by the migration. Never read for display or eligibility. GIN trigram index on the text.
- **Table `catalog_search_terms`**: the catalog vocabulary (letter-only words, 4+ letters), insert-only, for typo correction.
- **Table `staff_saved_products`**: personal Saved Items. One identity per row (organization product, catalog product or inventory item), unique per organization, user and identity; cascades with the user, organization and identity.
- All three tables: RLS on, no policies, `service_role` SELECT only, no `anon` / `authenticated` grants.
- **`search_supply_request_products`**: replaced in place with the **same arguments and the same 12 columns**, so the currently deployed application keeps working before the deploy and gets the new ranking at once.
- **`search_supply_request_products_with_signals`**, **`get_staff_product_discovery`**, **`save_staff_product`**, **`remove_staff_saved_product`**: `authenticated` EXECUTE; active membership is checked inside.
- Internal (no client EXECUTE): `supply_request_product_search`, `supply_request_product_history`, `supply_request_product_identities`, `staff_saved_product_identity_check`, `refresh_catalog_vendor_product_search_documents`, the four trigger functions, and the pure helpers `catalog_search_text`, `catalog_search_token_pattern`, `catalog_search_edit_distance`.

No existing table, column, policy, grant or row changes. Request submission, editing, cancellation, approval, commitments, budgets, inventory and invoices are untouched; their functions are pinned by hash in both checks. Count cadence (7B.5) is neither read nor written: the fingerprint only reports its policy rows (FC Cincinnati's is OFF and must stay OFF).

## Order (SQL Editor)

Run each file as its own query: paste the whole file, run it once, and read the result before going on.

1. **`precheck.sql`**
   - Success: a grid of fingerprint rows. Download as `phase5a10_pre.csv`.
   - STOP on any error. `precheck: Phase 5A.10 objects already exist` means step 2 already ran; do not run it again. `function is missing or differs from the reviewed production state`, `signature differs` or `public object counts differ` means production drifted from main. `pg_trgm is not available` / `installed outside the extensions schema` means the extension cannot be created as written.
2. **`20261107120000_phase5a10_staff_product_discovery.sql`**
   - One transaction with a preflight; any error rolls everything back, the extension included.
   - The Editor must **not** offer "Run and enable RLS". If it does, stop.
   - Success: no error, no rows. On the current production catalog (about 9,000 catalog products) the backfill takes well under a second; on 100,000 it took 5 s.
   - STOP on any error and run `precheck.sql` again: it passes with the same rows (nothing was left behind), or reports that 5A.10 objects exist (the migration committed; run `postcheck.sql`, never the migration again).
3. **`postcheck.sql`**
   - Success: fingerprint rows; save as `phase5a10_post.csv`. Compare with step 1: only the lines below may differ.
   - STOP on any error.
4. **Deploy the application.**

## Expected differences (precheck → postcheck)

- **New functions** (`absent` → hash): the 16 listed above. `get_staff_product_discovery`, `save_staff_product`, `remove_staff_saved_product` and `search_supply_request_products_with_signals` are `secdef=true authenticated=true anon=false public=false`; the internal ones `authenticated=false`. Their overloads go from 0 to 1.
- **Replaced function**: `search_supply_request_products` changes hash; its `signature` line stays identical.
- **Extension**: `pg_trgm` goes from `absent` to `1.6 schema=extensions` (or stays, if it was already installed there).
- **New tables** (`absent` → column hash with `rls=true`), their `grants` lines (`none` → `service_role=SELECT`), `policies` stay `none`, six new indexes and six new `trigger` lines.
- **Counts**: public functions +16, tables +3, indexes +6, triggers +6; policies unchanged. On the current production baseline: functions 124 → 140, tables 43 → 46, indexes 165 → 171, triggers 69 → 75, policies 58.
- **Rows**: `catalog_vendor_product_search_documents count` equals `catalog_vendor_products count`; `catalog_search_terms count` is the vocabulary size; `staff_saved_products count` is 0.

Everything else must be identical: every pinned function hash, every other index, policy, trigger and grant line, and every catalog, product, alias, request, request-item, commitment, invoice, invoice-item and cadence line. Real use between the precheck and the postcheck (a new request, an invoice) changes the matching `rows` lines; run the two back to back.

## Search rules (for acceptance)

- Exact organization SKU, then exact catalog / manufacturer SKU (separators ignored), then exact product name or organization alias, then partial SKU (4+ characters with a digit), then the whole query inside the name or an alias, then every word in the name or an alias, then every word anywhere in the attributes, then typo-corrected matches.
- Inside a tier only: Saved by me, organization approvals (approved, ordered, received or completed requests; never denied, cancelled, submitted or under review), purchases on posted invoices (not credit memos), the existing source preference, recency, name. Popularity never crosses a tier.
- Words of 1–2 characters must start a word; numbers keep their boundaries (2" never matches 12" or 1/2"); fractions stay whole.
- Typos: a letter-only word of 4+ letters that appears nowhere in the catalog or the organization's own products, same first letter, 1 edit for 4–7 letters, 2 for 8+, at most 3 corrections. Numbers, sizes and SKUs are never corrected.
- Synonyms: the existing organization product aliases (managed by owners/admins on the product) are now searched. There is no global synonym dictionary.

## After the deploy: production acceptance

Staff: Request Supplies opens with search, then Saved items (empty at first: "Tap the bookmark…"), Frequently requested and Purchased before when the organization has that history. Saving an item shows it at once; it appears under Saved items on the next visit and ranks first among equally good matches. Search for an exact SKU, a product name, a size ("2 inch tape") and a misspelling; check that same-name variants show their size/color, package or SKU. Submitting, editing and cancelling a request are unchanged. Owner/admin: search and the composer behave the same and Saved Items are their own. A staff acceptance that saves items writes `staff_saved_products` rows for that user; remove them afterwards or keep them, as decided beforehand.

## Provenance

Hashes come from a disposable `public.ecr.aws/supabase/postgres:17.6.1.167` migrated from main `74384f4` (production's application commit) plus this migration; the 7B.5 and 7B.4 hashes reproduce the values their release files pinned. `phase5a10_release_check.sh` runs the whole sequence on a seeded copy, including an induced failure before `COMMIT` (complete rollback), a refused second application and a refused repeat precheck.
