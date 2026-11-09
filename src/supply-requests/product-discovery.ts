// Phase 5A.10 staff product discovery: pure presentation rules for search results and the
// Saved Items / Frequently requested / Purchased before sections. The server functions in
// src/lib/product-discovery.functions.ts load the rows; ranking itself happens in the
// database (supply_request_product_search) and is never re-ordered here.
import type { StaffProductSelection } from "./staff-request-cart.ts";

export type StaffDiscoverySignals = {
  isSaved: boolean;
  approvedRequestCount: number;
  lastApprovedAt: string | null;
  purchaseCount: number;
  lastPurchasedAt: string | null;
};

export type StaffDiscoveryProduct = StaffProductSelection &
  StaffDiscoverySignals & {
    resultId: string;
    identitySource:
      "inventory" | "organization_catalog" | "organization_product" | "global_catalog";
    packageStatus: "verified" | "source_only" | "unknown";
    variantDetail: string | null;
    unit: string | null;
    packSize: string | null;
    // Search only: the relevance tier the database matched on (0 = exact organization SKU).
    matchTier: number | null;
  };

export type StaffDiscoverySection = "saved" | "frequent" | "purchased";

export type StaffDiscoverySections = Record<StaffDiscoverySection, StaffDiscoveryProduct[]>;

export const STAFF_DISCOVERY_SECTIONS: ReadonlyArray<{
  id: StaffDiscoverySection;
  title: string;
}> = [
  { id: "saved", title: "Saved items" },
  { id: "frequent", title: "Frequently requested" },
  { id: "purchased", title: "Purchased before" },
];

// How many rows a section shows before "Show all".
export const STAFF_DISCOVERY_VISIBLE_ROWS = 4;

// A product is "frequently requested" from this many approved organization requests.
export const FREQUENTLY_REQUESTED_MIN = 3;

// Each product once, in the first section that holds it (the database already does this;
// the client keeps the guarantee if rows ever arrive out of order).
export function buildDiscoverySections(
  rows: ReadonlyArray<StaffDiscoveryProduct & { section: StaffDiscoverySection }>,
): StaffDiscoverySections {
  const sections: StaffDiscoverySections = { saved: [], frequent: [], purchased: [] };
  const seen = new Set<string>();
  for (const { id } of STAFF_DISCOVERY_SECTIONS) {
    for (const row of rows) {
      if (row.section !== id || seen.has(row.resultId)) continue;
      seen.add(row.resultId);
      const { section: _section, ...product } = row;
      sections[id].push(product);
    }
  }
  return sections;
}

// The identity a Saved Item is stored under: the most specific one the result carries,
// matching the search deduplication key (organization product, then catalog product, then
// inventory item).
export function savedIdentityFor(
  product: Pick<StaffProductSelection, "productId" | "catalogVendorProductId" | "inventoryItemId">,
):
  | { productId: string; catalogVendorProductId: null; inventoryItemId: null }
  | { productId: null; catalogVendorProductId: string; inventoryItemId: null }
  | { productId: null; catalogVendorProductId: null; inventoryItemId: string }
  | null {
  if (product.productId)
    return { productId: product.productId, catalogVendorProductId: null, inventoryItemId: null };
  if (product.catalogVendorProductId)
    return {
      productId: null,
      catalogVendorProductId: product.catalogVendorProductId,
      inventoryItemId: null,
    };
  if (product.inventoryItemId)
    return {
      productId: null,
      catalogVendorProductId: null,
      inventoryItemId: product.inventoryItemId,
    };
  return null;
}

function clean(value: string | null | undefined): string | null {
  const text = value?.trim();
  return text ? text : null;
}

function sameText(a: string | null, b: string | null) {
  return (a ?? "").toLowerCase() === (b ?? "").toLowerCase();
}

// The trusted package line ("24 roll", source package text), or the organization's own pack
// size; never the word "Unknown".
export function packageLabel(
  product: Pick<StaffDiscoveryProduct, "packageDisplay" | "packSize">,
): string | null {
  const display = clean(product.packageDisplay);
  if (display && display.toLowerCase() !== "unknown") return display;
  return clean(product.packSize);
}

type VariantAttribute = "variant" | "package" | "manufacturer" | "vendor" | "sku";

function attributeValue(product: StaffDiscoveryProduct, attribute: VariantAttribute) {
  switch (attribute) {
    case "variant":
      return clean(product.specification) ?? clean(product.variantDetail);
    case "package":
      return packageLabel(product);
    case "manufacturer":
      return clean(product.manufacturer);
    case "vendor":
      return clean(product.vendorName);
    case "sku":
      return clean(product.vendorSku);
  }
}

function attributeText(attribute: VariantAttribute, value: string) {
  return attribute === "sku" ? `SKU ${value}` : value;
}

export type ProductVariantLines = {
  // Shown under the name in the main text color: what tells this variant apart.
  primary: string | null;
  // Muted: who makes and sells it, and the SKU when it is not already distinguishing.
  secondary: string | null;
};

// Variant presentation. Size / color / specification and the package always lead. When
// other listed products share this product's name, a manufacturer or vendor that differs
// between them moves to the primary line, and the SKU does only when nothing else tells
// them apart, so near-identical variants can be distinguished without opening them.
// Nothing is repeated and nothing says "Unknown".
export function describeProductVariant(
  product: StaffDiscoveryProduct,
  listed: ReadonlyArray<StaffDiscoveryProduct> = [],
): ProductVariantLines {
  const siblings = listed.filter(
    (other) =>
      other.resultId !== product.resultId && sameText(other.productName, product.productName),
  );
  const differs = (attribute: VariantAttribute) =>
    siblings.some(
      (other) => !sameText(attributeValue(other, attribute), attributeValue(product, attribute)),
    );

  const primary: string[] = [];
  const secondary: string[] = [];
  const used = new Set<string>();
  const place = (attribute: VariantAttribute, target: string[]) => {
    const value = attributeValue(product, attribute);
    if (!value || used.has(value.toLowerCase())) return;
    used.add(value.toLowerCase());
    target.push(attributeText(attribute, value));
  };

  place("variant", primary);
  place("package", primary);
  for (const attribute of ["manufacturer", "vendor"] as const) {
    place(attribute, siblings.length > 0 && differs(attribute) ? primary : secondary);
  }
  place("sku", secondary);
  // Same-name variants that differ in nothing else: the SKU is the only way to tell them apart.
  if (siblings.length > 0 && primary.length === 0) {
    const sku = attributeValue(product, "sku");
    if (sku) {
      const text = attributeText("sku", sku);
      const index = secondary.indexOf(text);
      if (index !== -1) secondary.splice(index, 1);
      primary.push(text);
    }
  }
  return {
    primary: primary.length ? primary.join(" · ") : null,
    secondary: secondary.length ? secondary.join(" · ") : null,
  };
}

export type ProductBadge = { kind: "saved" | "frequent" | "approved" | "purchased"; label: string };

const shortDate = new Intl.DateTimeFormat("en-US", {
  month: "short",
  day: "numeric",
  timeZone: "UTC",
});

function approvedTimes(count: number) {
  return count === 1 ? "Approved once" : `Approved ${count} times`;
}

// At most two quiet badges, organization-level only: one approval badge and one purchase
// badge. "Saved" is shown by the save control itself, not as a badge.
export function productBadges(
  product: Pick<
    StaffDiscoverySignals,
    "approvedRequestCount" | "purchaseCount" | "lastPurchasedAt"
  >,
): ProductBadge[] {
  const badges: ProductBadge[] = [];
  if (product.approvedRequestCount >= FREQUENTLY_REQUESTED_MIN)
    badges.push({ kind: "frequent", label: "Frequently requested" });
  else if (product.approvedRequestCount > 0)
    badges.push({ kind: "approved", label: approvedTimes(product.approvedRequestCount) });
  if (product.purchaseCount > 0)
    badges.push({
      kind: "purchased",
      label: product.lastPurchasedAt
        ? `Purchased ${shortDate.format(new Date(product.lastPurchasedAt))}`
        : "Purchased before",
    });
  return badges;
}

// Saved state the UI shows: the server's value unless this session changed it.
export function effectiveSaved(
  product: Pick<StaffDiscoveryProduct, "resultId" | "isSaved">,
  overrides: ReadonlyMap<string, boolean>,
): boolean {
  return overrides.get(product.resultId) ?? product.isSaved;
}
