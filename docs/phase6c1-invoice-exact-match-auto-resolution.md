# Phase 6C.1: invoice exact-match auto-resolution

## Problem

Beta invoice review still asked owners to accept product identities SportSpend already knew. On a real Henry Schein invoice, lines such as `3980143 Ammex Black PF Nitrile Gl Medium`, `1127149 Sharps Container Sliding 1qt Red`, `1507581 Needle Dry Click APS w/Gu .30x50mm`, and `1200685 Sponge Nonwoven 4Ply ST 4x4"` needed a click each.

Three things caused this:

1. **Separator mismatch.** The verified Henry Schein catalog stores SKUs as `398-0143` (the importer enforces `^\d{3}-\d{4}$`). Invoices print `3980143`. The authoritative normalizer `normalize_catalog_sku` (trim + uppercase) keeps the hyphen, so neither the catalog nor catalog-adopted organization mappings (which store `398-0143`) ever matched.
2. **No catalog tier.** Invoice review never consulted the global catalog. A product the organization had not yet adopted could only be matched by hand.
3. **Two inconsistent auto-link paths.** The database `rematch_invoice_vendor_products` matched `lower(btrim(sku))` with no uniqueness check. Separately, `getInvoiceReviewFn` wrote links from a browser-side matcher that strips spaces, dots, underscores, and hyphens and also treats `products.internal_item_code` as exact *regardless of vendor*. Neither recorded why a line was linked, so automatic and human matches were indistinguishable.

## Scope

Product identity only. After extraction, each invoice line is linked to a product when, and only when, the invoice vendor plus the line's vendor SKU names exactly one product. Everything else stays for review. Approval and posting remain explicit owner actions. Posting is hardened so the database, not the application, guarantees that only reviewed identities are posted (see [Posting boundary](#posting-boundary)); its inventory accounting is unchanged.

## Trusted matching hierarchy

Implemented in the database (`find_invoice_line_exact_identity`), evaluated per line, vendor-scoped throughout:

| Tier | Source | Lookup | Provenance |
| --- | --- | --- | --- |
| 1a | organization mapping (`vendor_products`) for the invoice vendor | authoritative SKU: `normalize_catalog_sku(vendor_sku) = normalize_catalog_sku(line.sku)` | `org_vendor_sku` |
| 1b | same, only if 1a found **no rows** and the invoice SKU has **no separators** | `normalize_catalog_sku_match_key` (letters and digits only) | `org_vendor_sku_match_key` |
| 2a | verified global catalog listing for the catalog vendor that the invoice vendor is **explicitly linked** to (`vendors.catalog_vendor_id`) | `catalog_vendor_products.normalized_vendor_sku` | `catalog_vendor_sku` |
| 2b | same, only if 2a found **no rows** and the invoice SKU has **no separators** | `catalog_vendor_products.vendor_sku_match_key` | `catalog_vendor_sku_match_key` |
| — | descriptions, manufacturers, package text, units | never resolve identity; the existing browser matcher may still **suggest** | none |

Rules at every tier:

- **Strict first, fallback second.** The separator-insensitive key is the repo's existing, documented non-authoritative lookup key. It is used only when the strict lookup returns nothing *and* the invoice SKU is already bare (`normalize_catalog_sku(sku) = normalize_catalog_sku_match_key(sku)`). `3980143` may find `398-0143`; `39-80143` never finds `398-0143`.
- **Exactly one.** If more than one organization mapping (active or not) or more than one catalog listing shares the strict SKU or key, the line goes to review. There is no "best" match.
- **A tier that finds a row decides.** If tier 1 finds a row that is unusable (deactivated by an owner, or its product is inactive), the line goes to review; the catalog is not consulted to route around that decision.
- **Separator-variant conflicts block adoption.** Before tier 2, any organization mapping for the vendor whose key equals the line's key (for example a remembered `3980143` when the invoice says `398-0143`) sends the line to review instead of adopting a second identity.
- **Catalog authority.** A tier 2 listing qualifies only if the listing is `active`, not `discontinued`, `verification_status = 'verified'`, and its canonical product is `active` and `verified`. The catalog vendor must be active.
- **Unlinked vendors.** If the organization vendor has no `catalog_vendor_id`, tier 2 is skipped. The resolver never links vendors by name. Tier 1 still applies.
- No new normalization function was added; stored and canonical SKUs are never rewritten.

## Safety invariants

- SKUs never cross vendors: every lookup filters by the invoice's vendor (tier 1) or by that vendor's linked catalog vendor (tier 2). After adoption, the resolver also requires the adopted mapping's vendor to equal the invoice vendor; if not, the adoption is rolled back and the line goes to review.
- Description, manufacturer, package, and unit text never participate in the decision function (a test asserts the function body does not reference them).
- The browser can no longer link lines. Its matcher's `EXACT` result on an unlinked line is shown as a suggestion that needs confirmation.
- Resolution never approves lines, posts invoices, stocks inventory, or writes requests, commitments, purchasing, receiving, price history, or global catalog rows.

## Package / UOM non-goals

An identity match does not prove package equivalence. The invoice's unit and package text stay raw. Adoption carries over only what Phase 5A.5 already carries (raw `package_description`, and a unit only when the listing's package is `verified`). No cost-per-each, cheaper-vendor, savings, or equivalent-package claim is introduced.

## Auto-adoption semantics

A tier 2 match calls the existing `adopt_catalog_vendor_product` RPC unchanged:

- per-organization advisory lock plus the Phase 5A.5 unique adoption indexes: one organization product per canonical product, one mapping per listing;
- idempotent: an already-adopted listing returns the existing rows;
- no inventory record or quantity is created;
- no team or location is assigned;
- catalog provenance (`catalog_product_id`, `catalog_vendor_product_id`) is preserved.

Adoption runs in a subtransaction. If it needs reconciliation (for example an existing active organization product with the same name), its partial writes roll back and the line goes to review with reason `catalog_adoption_requires_review`.

Adoption remains an owner/admin capability. The resolver itself is owner-only, like every other invoice review RPC.

## Provenance

New columns on `invoice_items`:

| Column | Meaning |
| --- | --- |
| `product_match_source` | `NULL` (undecided; also legacy links made before 6C.1), `manual`, `manual_cleared`, `org_vendor_sku`, `org_vendor_sku_match_key`, `catalog_vendor_sku`, `catalog_vendor_sku_match_key` |
| `product_match_decided_at` | when that decision was made |

A check constraint requires automatic sources to carry `product_id`, `vendor_product_id`, and a timestamp. Together with `vendor_product_id` (and its `catalog_vendor_product_id` for adopted listings) this answers "why was this line matched?". The resolver also returns a per-run summary with counts and review reasons.

## Manual-match protection

- `confirm_invoice_item_product` and `create_product_from_invoice_item` record `manual`.
- `unlink_invoice_item_product` records `manual_cleared`. An owner who removes an automatic match is not overridden on the next page load.
- The resolver only considers lines with `product_id IS NULL AND product_match_source IS NULL`, re-checked under a row lock, so a manual decision is never overwritten, upgraded, or switched.
- Direct API writes to `invoice_items` (the owner RLS policy) go through a trigger. Any client change to a line's product link is recorded as `manual`. Clients cannot set or change provenance themselves. Correcting the SKU of an unlinked line clears its decision so the corrected SKU can be resolved.
- Editing a line without changing its identity keeps its existing product and mapping, so its provenance is unchanged. (Previously, an identity-unchanged edit that submitted no vendor mapping cleared `vendor_product_id`.)
- Changing the invoice vendor still clears vendor-scoped links whose mapping belongs to another vendor (Phase 3A.4.1 behavior, triggered by an explicit owner action). Those lines lose their provenance and are re-resolved under the new vendor. Manual product-only links are untouched.

## Posting boundary

Before 6C.1, the only guarantee that every line had a reviewed product was in the application: `approveInvoiceFn` counted lines with `product_id IS NULL`, then separately called `post_reviewed_invoice`. The two steps were not atomic, and any authenticated owner could call the RPC directly. The Phase 2D function still contained identity inference for lines without a product:

1. a vendor-SKU mapping lookup;
2. an organization inventory lookup by SKU alone, not scoped to the vendor;
3. a product lookup by normalized description;
4. product (and category) creation from the line.

Phase 6C.1 redefines `post_reviewed_invoice` (same signature and grants, plus an `anon` revoke) so the database is the authority:

- **Gate before any write.** After the owner check, the invoice lock, and the unchanged completed-invoice no-op, the function locks every line and raises `Match or create a product for every invoice line before approval (N unresolved)` (`23502`) if any line has no product. Nothing is written: no vendor, product, mapping, inventory item, adjustment, price observation, line, invoice, or job change. A second check inside the loop is a backstop.
- **Inference removed, not just skipped.** All four branches above are deleted.
- **A reviewed mapping is validated, not trusted to override.** A line's `vendor_product_id` must belong to the organization and the invoice vendor, be active, and map to the line's own product. Phase 2D silently replaced the line's product with the mapping's product; that now raises `A selected vendor product maps to a different product than the invoice line`.
- **No silent remembering.** Investigated before changing (reproduced on a disposable database): when a line had a product but no `vendor_product_id`, Phase 2D found or created a mapping for the invoice vendor and line SKU and pointed it at the line's product. For a match confirmed with `rememberVendorSku = false`, posting therefore:
  - **created** a remembered mapping for a new SKU;
  - **repointed** an existing remembered mapping for that SKU to the newly chosen product, changing future matches.

  Posting now leaves `vendor_product_id` exactly as reviewed. The review UI always sends `rememberVendorSku = true`, so in the app this affected lines linked without a mapping by other paths: direct API links, and lines linked by the pre-6C.1 browser matcher through internal item codes.
- **Unchanged:**
  - vendor resolution and creation from the invoice vendor name;
  - the empty-invoice check;
  - the package/unit refresh of a reviewed mapping;
  - inventory lookup by product, quantity accumulation, inventory item creation;
  - adjustments with their idempotency keys, price history rows;
  - line approval, invoice completion, the job status, and the result shape.

  The node suite asserts these statements are identical to Phase 2D.
- **Price data:** an un-remembered line's price observation has `vendor_product_id = NULL`. Phase 6B already left-joins mappings and groups by vendor, and Phase 6A.2 falls back to product purchase history, so both keep working.

## Idempotency

Re-running resolution (every review load, header save, or vendor change) skips decided lines, so it writes nothing for them. Their `updated_at` is unchanged. It creates no further products, mappings, or adoptions. A repeated SKU on one invoice reuses the first line's adoption through tier 1.

## Concurrency

`resolve_invoice_exact_product_identities` takes the same invoice row lock as confirm, unlink, rematch, and posting, then locks candidate lines `FOR UPDATE`. Adoption serializes per organization and is backed by unique indexes. Verified against a disposable database with two live sessions:

- **Same invoice:** the second call blocked until the first committed, then reported zero work.
- **Two invoices adopting the same listing:** the second adoption waited on the advisory lock, then reused the first adoption (`adoptedCatalogProducts: 0`). One product and one mapping existed, and both lines linked to the same product.

## Security

- `resolve_invoice_exact_product_identities(org, source_file)`: `SECURITY DEFINER`, owner-only (`has_org_role(..., 'owner')`), organization-scoped invoice lookup, `EXECUTE` for `authenticated` only (`PUBLIC` and `anon` revoked).
- `find_invoice_line_exact_identity`, `apply_invoice_exact_product_identities`, and the trigger function are revoked from `PUBLIC`, `anon`, and `authenticated`.
- The redefined `rematch_invoice_vendor_products`, `confirm_invoice_item_product`, `unlink_invoice_item_product`, and `create_product_from_invoice_item` keep their signatures and owner checks. `anon` `EXECUTE` (a Supabase default grant) is now revoked.
- Global catalog rows remain globally readable as before; organization data is reached only through the caller's organization. No service-role path is used.

## Database changes

Migration `supabase/migrations/20261010120000_phase6c1_invoice_exact_match_auto_resolution.sql` (local only, not applied). It is one transaction with a preflight that requires the 2D/3A.4/3A.4.1/5A.4A/5A.5 objects and refuses to run twice. It is safe to paste into the Supabase SQL Editor.

| Object | Change |
| --- | --- |
| `invoice_items.product_match_source`, `product_match_decided_at` | new nullable columns and two check constraints (no backfill) |
| `guard_invoice_item_match_provenance` + `invoice_items_match_provenance_guard` | new API-role provenance trigger |
| `find_invoice_line_exact_identity` | new private decision function |
| `apply_invoice_exact_product_identities` | new private apply function |
| `resolve_invoice_exact_product_identities` | new owner RPC |
| `rematch_invoice_vendor_products` | same signature; clears provenance on cleared links and delegates matching to the resolver |
| `confirm_invoice_item_product`, `unlink_invoice_item_product`, `create_product_from_invoice_item` | same bodies plus provenance |
| `post_reviewed_invoice` | same signature; unresolved-line gate before any write, identity inference and implicit mapping creation removed, reviewed mapping must match the line's product; `anon` revoked |

`adopt_catalog_vendor_product`, catalog tables, inventory schema, requests, commitments, budgets, and price intelligence are not modified.

## Application changes

- `getInvoiceReviewFn` calls the resolver after vendor identification (or relies on rematch when the vendor was just identified). It then reads lines, products, and mappings so freshly adopted products have names. The browser-side automatic link writes are removed.
- `src/invoice/line-match.ts`: linked lines show as matched with their provenance, and an unlinked line's matcher `EXACT` is presented as a suggestion. It also builds the review subtitle.
- Review table: matched lines resolved by the database show "Matched automatically by vendor SKU". The subtitle reads, for example, "4 items · 3 matched automatically by vendor SKU · 1 needs review". There are no per-line Accept clicks for automatic matches; **Approve invoice** is unchanged.
- `src/integrations/supabase/types.ts` was hand-edited for the two columns and the RPC.

## Tests

- `supabase/tests/phase6c1_invoice_exact_match_auto_resolution_behavior.sql`: rollback-only, 24 checks with a realistic Henry Schein fixture (invoice `3980143`/`1127149`/`1507581`/`1200685` vs catalog `398-0143`/`112-7149`/`150-7581`/`120-0685`). It covers:
  - the trusted organization mapping, the catalog-adopted mapping via key, and strict and key catalog adoption;
  - exactly one adoption per listing, with canonical SKU and raw package text untouched;
  - nine exception lines left for review: description-only, manufacturer plus description, package/unit, catalog key collision, pending listing, discontinued listing, organization key collision, deactivated mapping, separator variant;
  - the exact summary and reasons;
  - manual and cleared lines untouched;
  - an idempotent rerun (no row or `updated_at` changes);
  - no cross-vendor match, with the other vendor's own listing still resolving;
  - an unlinked vendor and a missing vendor;
  - forged API provenance rejected and client links recorded as manual;
  - a new line resolved, an unlink of an automatic match kept, and a SKU correction re-resolved;
  - a vendor change via rematch;
  - no inventory, request, commitment (pre-existing approved request and commitment unchanged), purchasing, price-history, or catalog changes;
  - complete provenance;
  - organization isolation, plus admin, staff, anon, and private-helper denial;
  - posting still a separate owner action that behaves as before;
  - completed invoices skipped by the resolver;
  - a direct owner `post_reviewed_invoice` call on an invoice with unresolved lines fails at the gate. Those lines would each have been resolved by a legacy fallback: SKU mapping, other-vendor inventory SKU, name equality, product creation. Nothing changes (products, vendors, mappings, inventory, adjustments, price history, lines, invoice, job);
  - posting a completed invoice again is a no-op;
  - the ordinary reviewed path posts manual (remembered and not), automatic, name-colliding, and SKU-colliding lines with exactly their reviewed product and mapping. One adjustment and one price observation per line. The remembered `1127149` mapping is not repointed, un-remembered SKUs gain no mapping, and other-vendor inventory is untouched;
  - a reviewed mapping for another product, another vendor, or a deactivated mapping is refused with no side effects.
- `supabase/tests/phase6c1_mutation_check.sh <template_db>`: applies 16 mutants of the migration and requires the behavior suite to fail for each:
  - resolution: dropping vendor scoping at either tier, accepting ambiguity at either tier, allowing the key for SKUs with separators, adopting unverified listings, reusing deactivated mappings, ignoring separator-variant conflicts, revisiting manual decisions, not recording unlinks, letting the API forge provenance, letting unlinked vendors reach the catalog;
  - posting: removing the unresolved-line gate, removing every unresolved-line guard, accepting a mapping for another product, keeping the legacy Phase 2D posting function.

  All 16 are killed. Separately, with the legacy function in place and Check 19 removed from the suite, Check 21 fails on the repointed `1127149` mapping.
- `tests/phase6c1-invoice-exact-match-auto-resolution.test.ts`: presentation helpers (including the legacy matcher's cross-vendor `EXACT` becoming a suggestion), migration structure and grants, server and UI wiring, the posting gate's position before every write, removal of each Phase 2D inference branch, and byte-identical inventory accounting.

## Deliberate non-goals

- fuzzy or AI-decided authoritative identity; description, manufacturer, or package matching beyond existing suggestions;
- implicit vendor-to-catalog linking by name (a future, human-confirmed suggestion at most);
- package equivalence, unit-price normalization, cheapest-vendor or savings claims;
- purchasing automation, PO generation, request-to-invoice matching, receiving, inventory stocking;
- automatic invoice approval or posting;
- ToteScan replacement; broad catalog redesign; changes to posting accounting (quantities, adjustments, price history, vendor creation from the invoice name).

## Deployment (not performed)

1. Apply the migration in a disposable/staging database and run the 6C.1 behavior suite and mutation check, plus the existing 5A.5 adoption, 5A.6 stocking, 6A.2, 6B, and 6C suites.
2. Apply the migration in production (SQL Editor, single transaction).
3. Regenerate Supabase types and compare with the hand edits.
4. Deploy the application. The hardened posting function raises the same message the application already shows for unresolved lines, so the old and new app both work against it. Order matters only loosely: the old UI ignores the new columns, but until the new UI ships its browser-side matcher still writes links (they are now recorded as `manual` by the trigger). Ship the application promptly after the migration.
5. To let Henry Schein lines resolve from the catalog, make sure the organization's Henry Schein vendor is linked to the catalog vendor (adopting any one Henry Schein product in Catalog admin does this).
