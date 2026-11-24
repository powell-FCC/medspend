# Phase 7F.1A release checks

These scripts check the Phase 7F.1A release (Core Multi-Vendor Catalog Foundation) on production. The release is one migration: `20261125120000_phase7f1a_core_catalog_foundation.sql`. The scripts are read-only and migrate nothing themselves.

Production is migrated by hand in the Supabase SQL Editor. Never use `supabase db push` (see `../phase7a1/README.md`, "Migration history").

## How the files work

- Every file here works in the SQL Editor exactly as written: no psql meta-commands, no transaction control.
- `precheck.sql` and `postcheck.sql` are each one DO block of assertions followed by the shared fingerprint SELECT (`fingerprint.sql`), so the result grid is the full output.
- The migration creates eight tables and enables RLS on each in the same file, so the Editor's "Run and enable RLS" modal must not appear.
- `supabase/tests/phase7f1a_release_check.sh` proves all of this on a seeded production-shaped copy, sending each file the way the Editor does.

`fingerprint.sql` is the source. `precheck.sql` and `postcheck.sql` are generated from it by `supabase/tests/support/phase7f1a_release_generate.mjs`; never edit them by hand.

- **Expected values:** read, read-only, from a disposable database on main `be439a0` and from the same database with this migration applied.
- **Strict assertions:** the DO blocks assert every structural fingerprint row (functions, tables, policies, grants, indexes, constraints, triggers, counts). A missing, extra or different row stops the file.
- **Generator self-check:** before writing, the generator proves that main → 7F.1A changes only the objects listed below and no data hash.

## What the migration does

It is additive only. It sets up global catalog identity, search grouping and provenance structures for future catalogs, and scopes staff catalog search to the catalog vendors an organization uses.

It does not include:
- any vendor adapter or import;
- any offer or price;
- any change to request semantics (one catalog-scope check at the request boundary, below);
- any backfill.

### New global tables

All eight have RLS on, one `FOR SELECT TO authenticated USING (true)` policy, `authenticated=SELECT`, `service_role=SELECT, INSERT, UPDATE, DELETE`, and nothing for `anon`.

| Table | What it holds |
|---|---|
| `catalog_brands` | Brand or manufacturer identity, separate from sellers. Unique normalized name; never merged automatically. |
| `catalog_product_families` | Optional groups of variants that a source explicitly proves belong together. Unique (brand, normalized name), brandless families included. Never inferred from names. |
| `catalog_concepts` | Requester search grouping. A concept is not product identity. Unique normalized name. |
| `catalog_concept_synonyms` | Extra search words for a concept, unique within the concept. |
| `catalog_product_concepts` | Many-to-many links between exact products and concepts. Each link records provenance: `manual`, `imported` (an import batch is required) or `deterministic_rule` (a rule key is required). Nothing assigns concepts automatically. |
| `catalog_certification_types` | Certification programs. Seeded with one reference row, `nsf_certified_for_sport`; this is the only row the migration writes. |
| `catalog_product_certifications` | A certification on one exact catalog product. Requires evidence (import batch, source record, URL or reference) and `verified_at`; `expires_at` is optional. One active row per product and type; superseded rows stay inactive. |
| `catalog_bundle_components` | Metadata only. The bundle must be a catalog product with `product_kind = 'bundle'` (composite FK). A component is a catalog product or unresolved source text. |

### New columns

No existing row is rewritten. Constant defaults are catalog metadata in PostgreSQL 11+, and every existing row reads the default.

- **`catalog_products`:**
  - `brand_id`, `normalized_mpn` (requires a brand) and `gtin` are lookup evidence and deliberately not unique.
  - `family_id`.
  - `attributes jsonb` defaults to `'{}'`. It must be an object and may not hold certification keys.
  - `product_kind` (`single` | `bundle`) defaults to `single`.
  - `purchase_restriction` (`none` | `licensed_professional` | `prescription` | `restricted` | `unknown`) defaults to `unknown`.
- **`catalog_vendor_products`:**
  - `listing_url`.
  - `last_seen_batch_id` and `last_seen_at`. The batch must be the same catalog vendor's (composite FK).
  - `availability_status` (`in_stock` | `out_of_stock` | `backorder` | `discontinued` | `unknown`) and `availability_observed_at`, both set or both null.
  - The existing `discontinued` flag alone still decides search eligibility.
- **`catalog_import_batches`:** `source_type` (`xlsx` | `csv` | `pdf` | `website` | `api` | `manual`) and `effective_date`. Both stay NULL on the existing Henry Schein batch; nothing is guessed.

### New indexes on existing tables

- `catalog_products_brand_mpn_idx` (partial, brand not null)
- `catalog_products_gtin_idx` (partial)
- `catalog_products_family_idx` (partial)
- `catalog_products_id_kind_uq`, the target of the bundle composite FK
- `catalog_vendor_products_last_seen_batch_idx` (partial)

There is no GIN index on `attributes`: nothing queries it yet, and every row is `'{}'`.

### Changed functions

Same signatures, same grants, internal only:

- `supply_request_product_search`, and through it `search_supply_request_products` and `search_supply_request_products_with_signals`;
- `supply_request_product_identities`, and through it `get_staff_product_discovery` and `save_staff_product`;
- `replace_supply_request_items`, and through it `submit_supply_request`, `update_submitted_supply_request` and the cancellation edit path.

Each is the Phase 5A.10 (search) or Phase 6C (request lines) definition plus the catalog scope (next section). Tiers, ranking, typo correction, columns, validation order, error messages and every other request-line shape are unchanged.

### Organization catalog scope (behaviour change)

An organization uses a catalog vendor exactly when it has an **active** organization vendor linked to it (`vendors.catalog_vendor_id`). That link:

- is unique per organization;
- cannot be written by client roles. Two owner/admin paths set it: `link_organization_vendor_to_catalog_vendor`, and `adopt_catalog_vendor_product`, which creates a linked organization vendor when a listing of a catalog the organization does not use yet is adopted. Adopting one listing therefore enables that whole catalog; this is an organization opt-in, not a platform entitlement;
- can never be repointed.

No enablement table was needed. For owners, admins and staff alike:

- staff search, discovery and Saved Items return global listings only from those catalog vendors, and an organization with no linked vendor sees no global listing at all;
- a request line naming a global listing of any other catalog vendor is refused at the request boundary itself (submit, requester edit, cancellation edit) with the existing "A selected global catalog product is unavailable" error. Lines reached through the organization's own vendor SKU mapping already require an active vendor tied to the listing's catalog, so every legitimate shape is unchanged.

The global identity tables stay authenticated-readable, as before. This is a search scope, not a secrecy boundary.

### Pricing boundary

`catalog_vendor_products.source_catalog_price` is readable by every authenticated user of every organization. It must **never** hold account-specific, wholesale, quoted, promotional or otherwise confidential prices; the migration records this in the column comment. Organization pricing belongs to organization-scoped tables (Phase 7F.1B). The column is kept for deployed compatibility.

## Production impact

- **Catalog scope lines:** the fingerprint's `catalog scope` lines list, per organization, the catalog vendors its staff search may show after the migration. On the 2026-11-24 audit, only FC Cincinnati had a vendor, linked to Henry Schein. The three other organizations have no vendor, so their staff search stops showing Henry Schein listings. Their own products are unaffected, and they had no products.
- **FC Cincinnati:** its results are unchanged (proven on the real Henry Schein catalog by the benchmark below).
- **No data changes:** no product, mapping, invoice, request, price history, inventory or budget row changes. All data hashes in the fingerprint must be identical.

## Order (SQL Editor)

Run each file as its own query: paste the whole file, run it once, and read the result before going on. Run steps 1–3 back to back.

1. **`precheck.sql`**
   - **Success:** a grid of fingerprint rows. Download as `phase7f1a_pre.csv`. `catalog | new metadata` reads `absent`.
   - **STOP on any error.**
     - `precheck: Phase 7F.1A objects already exist` means step 2 already ran; do not run it again.
     - `precheck: differs from the reviewed state: …` means production drifted from main `be439a0`; the message names the object.
2. **`20261125120000_phase7f1a_core_catalog_foundation.sql`**
   - It is one transaction with a preflight, so any error rolls the whole file back.
   - The Editor must **not** offer "Run and enable RLS". If it does, stop.
   - **Success:** no error, no rows.
   - **STOP on any error**, then run `precheck.sql` again: it passes with the same rows.
   - A second application is refused (`Phase 7F.1A objects already exist unexpectedly`). If you see that, the migration already committed: run `postcheck.sql`, never the migration again.
3. **`postcheck.sql`**
   - **Success:** fingerprint rows; save as `phase7f1a_post.csv`. Compare with step 1: only the lines below may differ.
   - **What it also asserts:**
     - nothing was backfilled;
     - every organization with an active linked catalog vendor still finds a listing of it by exact SKU;
     - every organization without one gets no global listing.
     - These searches run as a member of each organization with a transaction-local identity; nothing is written.
   - **STOP on any error.**
4. **Deploy the application (merge to main).** The application code is unchanged in this phase. The deploy only brings the tests and release files.

## Expected differences (precheck → postcheck)

- **Changed functions** (new hash, same access `secdef=true authenticated=false anon=false service_role=true public=false`): `supply_request_product_search`, `supply_request_product_identities`, `replace_supply_request_items`.
- **Tables:**
  - `catalog_products`, `catalog_vendor_products` and `catalog_import_batches` get new column hashes.
  - The eight new tables go from `absent` to a hash with `rls=true`, and gain `policies` and `grants` lines.
- **New indexes, constraints and triggers:**
  - those of the eight new tables;
  - the five indexes above;
  - the new constraints on `catalog_products` (`brand_id_fkey`, `family_id_fkey`, `normalized_mpn_format`, `mpn_requires_brand`, `gtin_format`, `attributes_object`, `product_kind_check`, `purchase_restriction_check`), `catalog_vendor_products` (`listing_url_format`, `last_seen_batch_fk`, `last_seen_consistent`, `availability_status_check`, `availability_observed`) and `catalog_import_batches` (`source_type_check`).
- **Counts:**
  - functions 227 (unchanged)
  - tables 55 → 63
  - indexes 209 → 233
  - policies 58 → 66
  - triggers 89 → 96
- **`catalog | new metadata`:** `absent` → `brands=0 concepts=0 synonyms=0 product_concepts=0 families=0 certification_types=nsf_certified_for_sport certifications=0 bundle_components=0 products_kind_single=<all> products_restriction_unknown=<all> products_attributes_empty=<all> products_with_brand_family_mpn_gtin=0 listings_with_url_seen_availability=0 batches_with_source_type_or_date=0` (`<all>` = 9059 on production).

Everything else must be identical, including:

- every existing function, policy, grant, index, constraint and trigger;
- `catalog | listings per catalog vendor` (`Henry Schein=9059`) and `catalog | catalog products` (9059);
- every `catalog scope` line;
- every `rows` hash. The three widened catalog tables are hashed without their new columns, so their existing values are proven byte-identical.

Real use between the precheck and the postcheck (a request submitted, an invoice reviewed) changes the matching `rows` lines.

## After the deploy (read-only acceptance)

Do not create, post or edit anything for acceptance.

- **FC Cincinnati staff, request search:**
  - "tape", "gauze", "gloves" and an exact Henry Schein SKU (for example `128-5853`) return the same results as before.
  - Saved Items and Frequently requested load.
- **Owner:**
  - Catalog, Invoice Review of an already-posted document, Budget & Purchasing and Price Intelligence load unchanged (76 products / 84 observations at the 2026-11-24 baseline).
  - Never open a draft invoice for acceptance: opening it runs the resolver, which writes.
- **Other organizations (if anyone can sign in to one):** request search shows only their own products.

## Benchmark and no-regression

`supabase/tests/phase7f1a_search_benchmark.sh <outputs/catalog/henry-schein/v28>` loads the real Henry Schein v28 catalog into a disposable database and links an FC Cincinnati-shaped organization to it. It keeps one copy on main and migrates another. The results are in the PR description and below.

Measured 2026-11-24 (40 real queries × 5 runs, staff of the linked organization, `search_supply_request_products_with_signals`, limit 50; p50 / p95 / max in ms; other integration runners shared the machine):

| Listings | main (unscoped) | 7F.1A (scoped) | 7F.1A, organization with no linked vendor |
|---|---|---|---|
| 9,059 (real Henry Schein) | 10.2 / 17.8 / 79.4 | 10.1 / 16.0 / 18.2 | 2.2 / 3.4 / 4.9 |
| 25,059 (+16k synthetic, 3 unlinked catalog vendors) | 26.4 / 37.5 / 61.5 | 18.7 / 28.9 / 34.3 | 2.1 / 3.9 / 5.1 |
| 100,059 (+91k synthetic) | 58.5 / 139.7 / 269.8 | 9.1 / 52.0 / 84.4 | 2.7 / 3.6 / 6.1 |

- **No regression:** all 1,278 result rows of the 40 queries are byte-identical between main and 7F.1A on the real catalog.
- **No leak:** on 7F.1A the linked organization's rows at 25k and 100k listings are identical to its 9,059-listing rows. On main, unscoped search changed 1,057 and 1,059 of them, because other catalogs leaked in.
- **Plan:** `global_hits` still finds candidates through the existing trigram index on the search documents. The vendor filter joins each hit to its listing by primary key *before* the expensive candidate assembly (adoption joins, attribute text, scoring), so other catalogs' hits never reach scoring. That is why the scoped search gets faster as unrelated catalogs grow. An organization with no linked catalog vendor skips the global scan entirely (`One-Time Filter: false`).
- **No new index:** no index was added for speculative scale. Putting `catalog_vendor_id` into the search documents would only matter if one organization used many large catalogs.

## Provenance

- **Hashes:** from a disposable `public.ecr.aws/supabase/postgres:17.6.1.167` migrated from main `be439a0`, plus this migration.
- **Baseline match:** the main-only database reproduces the production baseline counts recorded at the hotfix release (227 / 55 / 209 / 58 / 89).
- **Regenerate** with both databases running: `node supabase/tests/support/phase7f1a_release_generate.mjs --pre <port> --post <port>` (`--check` compares without writing).
