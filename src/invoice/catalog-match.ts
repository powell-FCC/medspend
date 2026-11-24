import type {
  InvoiceCatalogConflictType,
  InvoiceCatalogListing,
  InvoiceCatalogMatchConflict,
  InvoiceCatalogSearch,
  InvoiceCatalogUnavailableReason,
  InvoiceReviewProduct,
} from "../types/invoice-processing";

const UNAVAILABLE_REASONS: InvoiceCatalogUnavailableReason[] = [
  "no_vendor",
  "vendor_unavailable",
  "vendor_not_linked_to_catalog",
  "catalog_vendor_inactive",
];

const text = (value: unknown) => (typeof value === "string" ? value : "");

const CONFLICT_TYPES: InvoiceCatalogConflictType[] = [
  "sku_mapped_to_other_product",
  "sku_mapped_to_other_listing",
  "name_twin_local",
  "name_twin_taken",
  "multiple_sku_mappings",
  "vendor_conflict",
  "adoption_inconsistent",
];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// The refusal match_invoice_item_to_catalog_listing raises when the chosen catalog item
// cannot be added. Its JSON hint names the conflicting product; anything else is not a
// catalog conflict (null), and an unreadable hint keeps the message with no product.
export function toCatalogMatchConflict(
  message: string,
  hint: string | null | undefined,
): InvoiceCatalogMatchConflict | null {
  if (!message.startsWith("This catalog item conflicts with")) return null;
  let record: Record<string, unknown> = {};
  try {
    const parsed: unknown = JSON.parse(hint ?? "");
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      record = parsed as Record<string, unknown>;
    }
  } catch {
    // No usable hint: the message alone is shown.
  }
  const productId = UUID.test(text(record.productId)) ? text(record.productId) : null;
  const productName = text(record.productName) || null;
  return {
    conflictType: CONFLICT_TYPES.find((type) => type === record.conflictType) ?? "unknown",
    message,
    productId,
    productName,
    vendorSku: text(record.vendorSku) || null,
    canMatchExisting: record.canMatchExisting === true && Boolean(productId && productName),
  };
}

// Shapes the search_invoice_line_catalog_listings result. Rows without an id or SKU are dropped.
export function toInvoiceCatalogSearch(value: unknown): InvoiceCatalogSearch {
  const record =
    value && typeof value === "object" && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : {};
  const reason = UNAVAILABLE_REASONS.find((candidate) => candidate === record.reason) ?? null;
  const results = (Array.isArray(record.results) ? record.results : []).flatMap(
    (row): InvoiceCatalogListing[] => {
      if (!row || typeof row !== "object") return [];
      const listing = row as Record<string, unknown>;
      if (!text(listing.catalogVendorProductId) || !text(listing.vendorSku)) return [];
      return [
        {
          catalogVendorProductId: text(listing.catalogVendorProductId),
          vendorSku: text(listing.vendorSku),
          name: text(listing.name),
          manufacturer: text(listing.manufacturer),
          packageDescription: text(listing.packageDescription),
          verified: listing.verified === true,
          organizationProductId: text(listing.organizationProductId) || null,
        },
      ];
    },
  );
  return {
    available: record.available === true,
    reason,
    catalogVendorName: text(record.catalogVendorName),
    results,
  };
}

// With nothing typed, the catalog is searched for the line's own printed SKU.
export function catalogSearchTerm(query: string, lineSku: string): string {
  return query.trim() || lineSku.trim();
}

export const MIN_CATALOG_SEARCH_LENGTH = 2;

export function describeCatalogUnavailable(
  reason: InvoiceCatalogUnavailableReason | null,
  vendorName: string,
): string {
  if (reason === "no_vendor")
    return "Select an existing vendor on this invoice to search that vendor's catalog.";
  if (reason === "vendor_not_linked_to_catalog")
    return `${vendorName || "This vendor"} is not linked to a catalog vendor, so only your products can be searched. An owner or admin can link it under Catalog Vendors.`;
  return `The catalog for ${vendorName || "this vendor"} is not available.`;
}

const alphanumeric = (value: string) => value.toLowerCase().replace(/[^a-z0-9]+/g, "");

// Filters the organization's own products for the match dialog. Item codes and this vendor's
// SKUs also match with separators ignored (3240025 finds 324-0025). This only narrows a list
// for a person to choose from; it never decides a product identity.
export function searchOrganizationProducts(
  products: InvoiceReviewProduct[],
  query: string,
  limit = 30,
): InvoiceReviewProduct[] {
  const needle = query.trim().toLowerCase();
  if (!needle) return products.slice(0, limit);
  const code = alphanumeric(needle);
  return products
    .filter((product) => {
      const codes = [product.internalItemCode, product.vendorItemNumber, ...product.vendorSkus];
      return (
        [product.name, product.description, product.manufacturer, ...codes].some((value) =>
          value.toLowerCase().includes(needle),
        ) ||
        (code.length >= 3 && codes.some((value) => alphanumeric(value).includes(code)))
      );
    })
    .slice(0, limit);
}
