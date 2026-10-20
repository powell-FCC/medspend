// Staff Workspace v2: requester-scoped quick picks (Frequent / Recent) and
// "Request again" availability. Pure logic only; the server functions in
// src/lib/staff-workspace.functions.ts load the rows.
//
// Availability mirrors the per-line rules of the canonical submission helper
// (replace_supply_request_items) as far as a staff member can see them. It only decides
// what to offer; submit_supply_request re-validates every line and stays authoritative.
// Organization vendor products are admin-only under RLS, so a vendor-product line is
// offered on the strength of its product and checked for real at submission.
import { trustedRequestPackage } from "./admin-request-inbox.ts";
import type { StaffProductSelection } from "./staff-request-cart.ts";
import type { SupplyRequestItemViewModel } from "./staff-dashboard.ts";

export type RequestLineIdentity = {
  productId: string | null;
  inventoryItemId: string | null;
  vendorProductId: string | null;
  catalogVendorProductId: string | null;
};

export type RequestHistoryLine = RequestLineIdentity & {
  requestId: string;
  requestedAt: string;
  freeTextItem: string | null;
  quantity: number;
  unit: string | null;
};

export type ProductAvailabilityRow = {
  id: string;
  name: string;
  unit_of_measure: string | null;
  manufacturer: string | null;
  pack_size: string | null;
  active: boolean;
  staff_requestable: boolean;
};

// Row-level security returns only active inventory, so presence means available.
export type InventoryAvailabilityRow = {
  id: string;
  name: string;
  unit: string | null;
  manufacturer: string | null;
  vendor_name: string | null;
  sku: string | null;
};

type OneOrMany<T> = T | T[] | null | undefined;

export type CatalogAvailabilityRow = {
  id: string;
  active: boolean;
  discontinued: boolean;
  vendor_sku: string;
  package_status: string;
  package_quantity: number | null;
  package_unit: string | null;
  package_description: string | null;
  product: OneOrMany<{ name: string; manufacturer: string | null; active: boolean }>;
  vendor: OneOrMany<{ name: string; active: boolean }>;
};

export type AvailabilityLookups = {
  products: ReadonlyMap<string, ProductAvailabilityRow>;
  inventory: ReadonlyMap<string, InventoryAvailabilityRow>;
  catalog: ReadonlyMap<string, CatalogAvailabilityRow>;
  specifications: ReadonlyMap<string, string>;
};

export type LineAvailability =
  | { status: "available" }
  | { status: "custom" }
  | { status: "unavailable"; reason: string };

export const UNAVAILABLE_REASON = "No longer available to request";

// Bounds: quick picks look at a requester's recent history only, never the whole
// organization and never an unbounded history.
export const QUICK_PICK_HISTORY_REQUESTS = 40;
export const QUICK_PICK_LIMIT = 6;
export const FREQUENT_MIN_REQUESTS = 2;

function one<T>(value: OneOrMany<T>): T | null {
  if (Array.isArray(value)) return value[0] ?? null;
  return value ?? null;
}

export function hasStructuredIdentity(identity: RequestLineIdentity): boolean {
  return Boolean(
    identity.productId ||
    identity.inventoryItemId ||
    identity.vendorProductId ||
    identity.catalogVendorProductId,
  );
}

// The same identity key search_supply_request_products deduplicates on, so one product
// appears once in Frequent/Recent even when it was requested through different sources.
export function quickPickKey(identity: RequestLineIdentity): string | null {
  if (identity.productId) return `organization-product:${identity.productId}`;
  if (identity.catalogVendorProductId)
    return `catalog-vendor-product:${identity.catalogVendorProductId}`;
  if (identity.inventoryItemId) return `inventory:${identity.inventoryItemId}`;
  return null;
}

export function classifyLineAvailability(
  identity: RequestLineIdentity,
  lookups: AvailabilityLookups,
): LineAvailability {
  if (!hasStructuredIdentity(identity)) return { status: "custom" };
  const unavailable = { status: "unavailable", reason: UNAVAILABLE_REASON } as const;

  if (identity.inventoryItemId && !lookups.inventory.has(identity.inventoryItemId)) {
    return unavailable;
  }
  if (identity.productId) {
    const product = lookups.products.get(identity.productId);
    if (!product || !product.active || !product.staff_requestable) return unavailable;
  }
  if (identity.catalogVendorProductId) {
    const catalog = lookups.catalog.get(identity.catalogVendorProductId);
    if (!catalog || !catalog.active || catalog.discontinued) return unavailable;
    if (!one(catalog.product)?.active || !one(catalog.vendor)?.active) return unavailable;
  }
  // A vendor product line always carries its product (the submission helper derives
  // it), so the product check above covers it as far as staff visibility allows.
  if (identity.vendorProductId && !identity.productId) return unavailable;
  return { status: "available" };
}

export function describeRequestLine(
  identity: RequestLineIdentity & { unit?: string | null },
  lookups: AvailabilityLookups,
  fallbackName: string,
): StaffProductSelection & { unit: string | null } {
  const product = identity.productId ? lookups.products.get(identity.productId) : undefined;
  const inventory = identity.inventoryItemId
    ? lookups.inventory.get(identity.inventoryItemId)
    : undefined;
  const catalog = identity.catalogVendorProductId
    ? lookups.catalog.get(identity.catalogVendorProductId)
    : undefined;
  const catalogProduct = one(catalog?.product);
  const catalogVendor = one(catalog?.vendor);
  return {
    productName: product?.name ?? catalogProduct?.name ?? inventory?.name ?? fallbackName,
    manufacturer:
      product?.manufacturer ?? catalogProduct?.manufacturer ?? inventory?.manufacturer ?? null,
    vendorName: catalogVendor?.name ?? inventory?.vendor_name ?? null,
    vendorSku: catalog?.vendor_sku ?? inventory?.sku ?? null,
    packageDisplay: catalog ? (trustedRequestPackage(catalog) ?? "") : (product?.pack_size ?? ""),
    specification: identity.catalogVendorProductId
      ? (lookups.specifications.get(identity.catalogVendorProductId) ?? null)
      : null,
    unit: identity.unit ?? product?.unit_of_measure ?? inventory?.unit ?? null,
    productId: identity.productId,
    inventoryItemId: identity.inventoryItemId,
    vendorProductId: identity.vendorProductId,
    catalogVendorProductId: identity.catalogVendorProductId,
  };
}

export type StaffQuickPick = StaffProductSelection & {
  key: string;
  unit: string | null;
  requestCount: number;
  lastRequestedAt: string;
};

export type StaffQuickPicks = {
  frequent: StaffQuickPick[];
  recent: StaffQuickPick[];
};

// Frequent: products in at least two of the requester's recent requests, ranked by how
// many requests included them (not by quantity), then by recency.
// Recent: the requester's most recently requested products, each shown once, excluding
// anything already shown under Frequent.
// Custom (free-text) lines and products that are no longer requestable are never offered.
export function buildQuickPicks(
  lines: RequestHistoryLine[],
  lookups: AvailabilityLookups,
  limit = QUICK_PICK_LIMIT,
): StaffQuickPicks {
  const newestFirst = [...lines].sort((a, b) => b.requestedAt.localeCompare(a.requestedAt));
  const groups = new Map<
    string,
    { line: RequestHistoryLine; requestIds: Set<string>; lastRequestedAt: string }
  >();
  for (const line of newestFirst) {
    const key = quickPickKey(line);
    if (!key) continue;
    const group = groups.get(key);
    if (group) {
      group.requestIds.add(line.requestId);
      continue;
    }
    groups.set(key, {
      line,
      requestIds: new Set([line.requestId]),
      lastRequestedAt: line.requestedAt,
    });
  }

  const picks: StaffQuickPick[] = [];
  for (const [key, group] of groups) {
    if (classifyLineAvailability(group.line, lookups).status !== "available") continue;
    picks.push({
      ...describeRequestLine(group.line, lookups, "Requested item"),
      key,
      requestCount: group.requestIds.size,
      lastRequestedAt: group.lastRequestedAt,
    });
  }

  const byName = (a: StaffQuickPick, b: StaffQuickPick) =>
    a.productName.localeCompare(b.productName);
  const frequent = picks
    .filter((pick) => pick.requestCount >= FREQUENT_MIN_REQUESTS)
    .sort(
      (a, b) =>
        b.requestCount - a.requestCount ||
        b.lastRequestedAt.localeCompare(a.lastRequestedAt) ||
        byName(a, b),
    )
    .slice(0, limit);
  const shown = new Set(frequent.map((pick) => pick.key));
  const recent = picks
    .filter((pick) => !shown.has(pick.key))
    .sort((a, b) => b.lastRequestedAt.localeCompare(a.lastRequestedAt) || byName(a, b))
    .slice(0, limit);
  return { frequent, recent };
}

export type RequestAgainLine = {
  lineId: string;
  name: string;
  quantity: number;
  availability: LineAvailability;
  // Present only for an available structured line: the stored identity, re-submitted
  // as-is and re-validated by the canonical submission RPC.
  selection: (StaffProductSelection & { unit: string | null }) | null;
  freeTextItem: string | null;
};

export function buildRequestAgainLines(
  items: SupplyRequestItemViewModel[],
  lookups: AvailabilityLookups,
): RequestAgainLine[] {
  return items.map((item) => {
    const availability = classifyLineAvailability(item, lookups);
    return {
      lineId: item.id,
      name: item.name,
      quantity: item.quantity,
      availability,
      selection:
        availability.status === "available" ? describeRequestLine(item, lookups, item.name) : null,
      freeTextItem:
        availability.status === "custom" ? (item.freeTextItem ?? item.name).trim() : null,
    };
  });
}
