import type { ProductMatchResult } from "../product-identity/matcher";

// Mirrors invoice_items.product_match_source (Phase 6C.1). The database resolver is the
// only writer of the automatic values; the browser only displays them.
export const AUTOMATIC_MATCH_SOURCES = [
  "org_vendor_sku",
  "org_vendor_sku_match_key",
  "catalog_vendor_sku",
  "catalog_vendor_sku_match_key",
] as const;
export type AutomaticMatchSource = (typeof AUTOMATIC_MATCH_SOURCES)[number];
export type InvoiceLineMatchSource = AutomaticMatchSource | "manual" | "manual_cleared";

export const AUTOMATIC_MATCH_LABEL = "Matched automatically by vendor SKU";

export function isAutomaticMatchSource(
  source: string | null | undefined,
): source is AutomaticMatchSource {
  return (AUTOMATIC_MATCH_SOURCES as readonly string[]).includes(source ?? "");
}

export function toInvoiceLineMatchSource(
  source: string | null | undefined,
): InvoiceLineMatchSource | null {
  return isAutomaticMatchSource(source) || source === "manual" || source === "manual_cleared"
    ? source
    : null;
}

// A linked line is settled; the reason reflects who decided it. An unlinked line is never
// shown as matched: browser-side evidence (including the matcher's EXACT state, which uses
// looser identifiers than the database) can only suggest a product for an owner to confirm.
export function presentInvoiceLineMatch(
  line: { productId: string | null; matchSource: string | null },
  match: ProductMatchResult,
): ProductMatchResult {
  if (line.productId) {
    return {
      state: "CONFIRMED",
      productId: line.productId,
      vendorProductId: match.vendorProductId,
      reasons: [
        isAutomaticMatchSource(line.matchSource)
          ? `AUTOMATIC_${line.matchSource.toUpperCase()}`
          : "OWNER_CONFIRMED",
      ],
    };
  }
  if (match.state === "EXACT") {
    return {
      ...match,
      state: "SUGGESTED",
      reasons: [...match.reasons, "OWNER_CONFIRMATION_REQUIRED"],
    };
  }
  return match;
}

// Exception-oriented subtitle for the review table: what was settled automatically and
// what still needs an owner. needsReview uses the same rule as the approval gate.
export function describeInvoiceLineReview(
  items: { productId: string | null; matchSource: string | null }[],
  completed: boolean,
): string {
  const automatic = items.filter(
    (item) => item.productId && isAutomaticMatchSource(item.matchSource),
  ).length;
  const needsReview = items.filter((item) => !item.productId).length;
  const parts = [`${items.length} item${items.length === 1 ? "" : "s"}`];
  if (automatic) parts.push(`${automatic} matched automatically by vendor SKU`);
  if (!completed && items.length)
    parts.push(
      needsReview ? `${needsReview} need${needsReview === 1 ? "s" : ""} review` : "all matched",
    );
  return parts.join(" · ");
}
