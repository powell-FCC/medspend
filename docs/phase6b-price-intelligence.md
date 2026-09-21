# Phase 6B — Price Intelligence MVP

## Purpose

Phase 6B gives SportSpend owners and administrators auditable historical price context for one exact organization product. It answers what the organization paid, how the latest valid USD purchase differs from the previous one, the observed range, and which vendors supplied those historical purchases.

The feature is decision support. It does not label a price good or bad, recommend a vendor, automate procurement, or change inventory, request, commitment, or accounting behavior.

## Source of truth

`inventory_price_history` is the only transactional source used for price intelligence. `post_reviewed_invoice` writes one immutable observation per posted invoice line, and the existing safe invoice-deletion flow removes that provenance and rebuilds denormalized inventory purchase metadata when a posted invoice is corrected by deletion.

The RPC joins every observation back to `invoices` and requires `invoices.posted_at IS NOT NULL`. Rows tied to draft, processing, review-required, failed, or otherwise unposted invoices do not enter results.

`purchase_date` retains the posting ledger's existing meaning: `post_reviewed_invoice` uses the invoice date when present and the posting transaction's current date otherwise. The response also carries `postedAt`, so an administrator can distinguish the business purchase date from the posting timestamp.

An observation price is `inventory_price_history.unit_price`, or `extended_price / quantity` only when the stored unit price is absent and the authoritative structured quantity permits that arithmetic. The RPC never reads a price from descriptions or other free text.

The following are deliberately not purchase-history sources:

- `inventory_items.last_purchase_price` is mutable denormalized metadata.
- `catalog_vendor_products.source_catalog_price` is a non-transactional catalog reference.
- supply-request commitments are immutable estimates, not purchases.
- the legacy `invoice_line_items` table is not the active posting ledger.

Catalog/reference prices are not mixed into summaries, history, or vendor groups.

## Canonical identity rules

The RPC accepts an organization-scoped `products.id`. Every observation must have the same `organization_id` and exact `product_id`. Vendor history is grouped only after that exact product filter is applied.

No identity is inferred from names, descriptions, manufacturer text, approximate SKUs, package text, or catalog search similarity. A `vendor_products` row contributes a display SKU only when it belongs to the same organization and the same canonical product as the observation.

Global catalog adoption links may establish the organization product shown by the admin catalog detail, but the price query itself is scoped to the adopted organization product. A catalog identity that has not been adopted has no organization product boundary and therefore shows an explicit unavailable state.

## Package comparison rules

Historical observations snapshot `package_size` and `unit_of_measure` as text. They do not snapshot the verified catalog package quantity, normalized unit, or the package verification status that existed at purchase time. Current catalog package metadata cannot safely be projected backward onto an old invoice.

Therefore Phase 6B:

- displays raw historical package and UOM evidence;
- labels every historical package observation `unverified`;
- returns `packageComparability.status = "not_verified"`;
- never calculates normalized unit economics;
- never declares one vendor cheaper than another;
- never claims savings.

Vendor history is evidence grouped by vendor, not a recommendation or a semantic price comparison. Normalized cross-vendor comparison is deferred until trustworthy package quantity, unit, and evidence status are snapshotted with each purchase observation.

## Currency rules

Only observations whose posted invoice explicitly records `currency_code = 'USD'` enter summary metrics, recent purchases, and vendor history.

- Null/unknown currency is excluded and counted.
- Non-USD currency is excluded and counted.
- No exchange-rate conversion is performed.
- A null currency is not assumed to be USD.

The response contains coverage counts so excluded evidence is visible rather than silently discarded.

## Historical metrics

For valid posted USD observations, the database calculates:

- latest price and purchase date;
- previous price;
- absolute change;
- percentage change;
- historical low and high;
- observation count;
- vendor-specific latest, previous, range, and count.

Percentage change is null when the previous price is missing or zero. Missing values remain null and are shown as unavailable; zero is never substituted for missing data.

Ordering is deterministic: `purchase_date DESC`, then observation `created_at DESC`, then observation `id DESC`. The response includes at most 20 recent observations and 12 vendor groups. The supporting index follows the organization, exact product, and deterministic observation order.

## Provenance

Every recent observation includes:

- purchase date;
- vendor identity and vendor SKU when available;
- raw purchase price and USD currency;
- authoritative line quantity;
- raw package/UOM evidence;
- invoice and invoice-line identifiers;
- invoice number when available;
- invoice posting timestamp;
- provenance type `posted_invoice_purchase_history`.

The invoice line is unique in `inventory_price_history`, preventing one posted line from appearing twice in the ledger.

Two distinct posted invoice lines remain two observations even when their descriptions or prices look alike. Phase 6B does not guess that separately identified lines are extraction duplicates; any correction must use the existing audited invoice correction/deletion workflow.

## Insufficient-data behavior

The admin UI explicitly distinguishes:

- a catalog identity that is not adopted;
- no comparable posted USD purchase history;
- no prior comparable purchase;
- unavailable percentage change because the prior value is zero or missing;
- excluded unknown-currency, non-USD, or missing-price observations;
- unavailable cross-vendor comparison because historical package normalization is not verified.

No state fabricates a price, average, trend, or comparison.

## Authorization

`get_product_price_intelligence(organization_id, product_id)` is callable only by `authenticated`; `PUBLIC` and `anon` have no execute privilege. The security-definer function uses `search_path = public` and immediately requires `is_org_admin`, which means an active owner or admin membership in the requested organization.

Staff, inactive/nonmembers, and administrators from another organization are denied. The exact product must also exist in the requested organization. The admin catalog UI is the only client surface; staff routes and components do not import the price-intelligence function or component.

## Performance bounds

The query is set-based and uses a single materialized exact-product slice. It does not issue per-observation queries. Recent purchase output is capped at 20 rows and vendor output at 12 groups. Ordering uses `inventory_price_history_product_observation_order_idx` on:

`(organization_id, product_id, purchase_date DESC, created_at DESC, id DESC)`.

## Explicit non-goals

Phase 6B does not implement:

- purchase orders, ordering, receiving, or fulfillment;
- inventory consumption or count changes;
- request-to-invoice matching or commitment settlement;
- contract or negotiated pricing;
- vendor APIs or preferred-vendor automation;
- package inference from text;
- currency conversion;
- forecasting, anomaly detection, or ML price prediction;
- reorder, vendor-switching, or savings recommendations;
- approval automation.
