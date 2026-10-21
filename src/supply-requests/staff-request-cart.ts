import type { UnifiedSupplyRequestSearchResult } from "../lib/supply-requests.functions";
import type { SupplyRequestItemViewModel } from "./staff-dashboard";

export type StaffProductSelection = Pick<
  UnifiedSupplyRequestSearchResult,
  | "productName"
  | "manufacturer"
  | "vendorName"
  | "vendorSku"
  | "packageDisplay"
  | "specification"
  | "inventoryItemId"
  | "productId"
  | "vendorProductId"
  | "catalogVendorProductId"
>;

type StaffRequestCartItemBase = {
  key: string;
  name: string;
  quantity: number;
};

export type StructuredStaffRequestCartItem = StaffRequestCartItemBase &
  StaffProductSelection & {
    kind: "structured";
  };

export type CustomStaffRequestCartItem = StaffRequestCartItemBase & {
  kind: "custom";
  freeTextItem: string;
};

export type StaffRequestCartItem = StructuredStaffRequestCartItem | CustomStaffRequestCartItem;

export type StaffRequestSubmissionItem = {
  productId: string | null;
  inventoryItemId: string | null;
  vendorProductId: string | null;
  catalogVendorProductId: string | null;
  freeTextItem: string | null;
  quantity: number;
};

export function createStructuredCartItem(
  key: string,
  selection: StaffProductSelection,
  quantity: number,
): StructuredStaffRequestCartItem {
  return {
    kind: "structured",
    key,
    name: selection.productName,
    quantity,
    productName: selection.productName,
    manufacturer: selection.manufacturer,
    vendorName: selection.vendorName,
    vendorSku: selection.vendorSku,
    packageDisplay: selection.packageDisplay,
    specification: selection.specification,
    inventoryItemId: selection.inventoryItemId,
    productId: selection.productId,
    vendorProductId: selection.vendorProductId,
    catalogVendorProductId: selection.catalogVendorProductId,
  };
}

export function createCustomCartItem(
  key: string,
  freeTextItem: string,
  quantity: number,
): CustomStaffRequestCartItem {
  const name = freeTextItem.trim();
  return {
    kind: "custom",
    key,
    name,
    freeTextItem: name,
    quantity,
  };
}

export function changeCartItemQuantity(
  items: StaffRequestCartItem[],
  key: string,
  delta: number,
): StaffRequestCartItem[] {
  return items.map((item) =>
    item.key === key ? { ...item, quantity: Math.max(1, item.quantity + delta) } : item,
  );
}

// The submission RPC accepts at most this many lines per request.
export const STAFF_CART_MAX_LINES = 50;

// Exact identity of a structured line. Two lines merge only when every identity field
// matches, so adding an item never silently swaps one source for another.
export function cartSelectionIdentityKey(
  selection: Pick<
    StaffProductSelection,
    "productId" | "inventoryItemId" | "vendorProductId" | "catalogVendorProductId"
  >,
): string {
  return [
    selection.productId,
    selection.inventoryItemId,
    selection.vendorProductId,
    selection.catalogVendorProductId,
  ]
    .map((value) => value ?? "")
    .join("|");
}

export function findCartLineForSelection(
  items: StaffRequestCartItem[],
  selection: Parameters<typeof cartSelectionIdentityKey>[0],
): StructuredStaffRequestCartItem | undefined {
  const identity = cartSelectionIdentityKey(selection);
  return items.find(
    (item): item is StructuredStaffRequestCartItem =>
      item.kind === "structured" && cartSelectionIdentityKey(item) === identity,
  );
}

// One-tap add: a product already in the cart gains quantity instead of a second line.
export function addProductToCart(
  items: StaffRequestCartItem[],
  key: string,
  selection: StaffProductSelection,
  quantity = 1,
): StaffRequestCartItem[] {
  const existing = findCartLineForSelection(items, selection);
  if (existing) return changeCartItemQuantity(items, existing.key, quantity);
  if (items.length >= STAFF_CART_MAX_LINES) return items;
  return [...items, createStructuredCartItem(key, selection, quantity)];
}

export function addCustomItemToCart(
  items: StaffRequestCartItem[],
  key: string,
  freeTextItem: string,
  quantity = 1,
): StaffRequestCartItem[] {
  if (!freeTextItem.trim() || items.length >= STAFF_CART_MAX_LINES) return items;
  return [...items, createCustomCartItem(key, freeTextItem, quantity)];
}

export function describeItemCount(count: number): string {
  return `${count} ${count === 1 ? "item" : "items"}`;
}

export function describeCartCount(items: StaffRequestCartItem[]): string {
  return describeItemCount(items.length);
}

export function removeCartItem(items: StaffRequestCartItem[], key: string): StaffRequestCartItem[] {
  return items.filter((item) => item.key !== key);
}

export function toSubmissionItem(item: StaffRequestCartItem): StaffRequestSubmissionItem {
  if (item.kind === "custom") {
    return {
      productId: null,
      inventoryItemId: null,
      vendorProductId: null,
      catalogVendorProductId: null,
      freeTextItem: item.freeTextItem,
      quantity: item.quantity,
    };
  }

  return {
    productId: item.productId,
    inventoryItemId: item.inventoryItemId,
    vendorProductId: item.vendorProductId,
    catalogVendorProductId: item.catalogVendorProductId,
    freeTextItem: null,
    quantity: item.quantity,
  };
}

export function cartContainsCustomItem(items: StaffRequestCartItem[]) {
  return items.some((item) => item.kind === "custom");
}

export type StaffRequestProductDisplayLine = {
  kind: "specification" | "metadata";
  text: string;
};

export function getStaffRequestProductDisplayLines(
  product: Pick<
    UnifiedSupplyRequestSearchResult,
    "manufacturer" | "vendorName" | "vendorSku" | "packageDisplay" | "specification"
  >,
): StaffRequestProductDisplayLine[] {
  const lines: StaffRequestProductDisplayLine[] = [];
  const specification = product.specification?.trim();
  if (specification) lines.push({ kind: "specification", text: specification });

  const suppliers = [product.manufacturer, product.vendorName].filter(
    (value, index, values): value is string => !!value && values.indexOf(value) === index,
  );
  const packageDisplay = product.packageDisplay.trim();
  const metadata = [
    ...suppliers,
    product.vendorSku ? `SKU ${product.vendorSku}` : null,
    packageDisplay && packageDisplay.toLowerCase() !== "unknown" ? packageDisplay : null,
  ].filter((value): value is string => !!value);
  if (metadata.length > 0) lines.push({ kind: "metadata", text: metadata.join(" · ") });

  return lines;
}

export function resolveRequestContextId(
  membershipDefaultId: string | null | undefined,
  selectedId: string,
  availableOptions: ReadonlyArray<{ id: string }>,
): string | null {
  if (membershipDefaultId && availableOptions.some((option) => option.id === membershipDefaultId)) {
    return membershipDefaultId;
  }
  if (selectedId && availableOptions.some((option) => option.id === selectedId)) return selectedId;
  return availableOptions.length === 1 ? availableOptions[0]!.id : null;
}

// Phase 6C edit mode: rebuild cart lines from the stored request lines. Structured lines
// resubmit their stored identity tuple, which the server re-validates with the same
// rules as the original submission; nothing is inferred from display text.
export function cartItemFromRequestItem(item: SupplyRequestItemViewModel): StaffRequestCartItem {
  const hasStructuredIdentity = Boolean(
    item.productId || item.inventoryItemId || item.vendorProductId || item.catalogVendorProductId,
  );
  if (!hasStructuredIdentity) {
    return createCustomCartItem(item.id, item.freeTextItem ?? item.name, item.quantity);
  }
  return createStructuredCartItem(
    item.id,
    {
      productName: item.name,
      manufacturer: item.manufacturer ?? null,
      vendorName: item.vendorName ?? null,
      vendorSku: item.vendorSku ?? null,
      packageDisplay: item.packageDisplay ?? "",
      specification: null,
      inventoryItemId: item.inventoryItemId,
      productId: item.productId,
      vendorProductId: item.vendorProductId,
      catalogVendorProductId: item.catalogVendorProductId,
    },
    item.quantity,
  );
}

export type StaffRequestType = "reorder" | "low_stock" | "out_of_stock" | "new_item";

export function resolveStaffRequestType(
  explicitType: StaffRequestType | null | undefined,
  items: StaffRequestCartItem[],
): StaffRequestType {
  return explicitType ?? (cartContainsCustomItem(items) ? "new_item" : "reorder");
}

// Low/out-of-stock reports are explicit choices and survive edits; reorder/new_item is
// re-derived from the edited cart exactly as at creation.
export function editRequestTypeIntent(originalType: StaffRequestType): StaffRequestType | undefined {
  return originalType === "low_stock" || originalType === "out_of_stock" ? originalType : undefined;
}

export function describeSubmission(
  items: StaffRequestCartItem[],
  context: { teamName?: string | null; locationName?: string | null } = {},
) {
  const count = items.length;
  return {
    title: "Submit this request?",
    body: `${count} ${count === 1 ? "item" : "items"} will be sent for review.`,
    context: [context.teamName, context.locationName].filter(Boolean).join(" · ") || null,
  };
}

export function resolveEditRequestContextId(
  requestContextId: string | null | undefined,
  selectedId: string,
  membershipDefaultId: string | null | undefined,
  availableOptions: ReadonlyArray<{ id: string }>,
): string | null {
  if (selectedId && availableOptions.some((option) => option.id === selectedId)) return selectedId;
  if (requestContextId && availableOptions.some((option) => option.id === requestContextId)) {
    return requestContextId;
  }
  return resolveRequestContextId(membershipDefaultId, "", availableOptions);
}

// Phase 6C.2: a request can never be saved with zero items. When an edit removes the
// last line, the composer offers cancellation instead of a save it cannot make.
export type EditCompletion = "save" | "cancel_only";

export function editCompletion(items: StaffRequestCartItem[]): EditCompletion {
  return items.length > 0 ? "save" : "cancel_only";
}

export const EMPTY_EDIT_STATE = {
  title: "No items left in this request.",
  body: "A request can't be saved without items. Add an item to keep this request, or cancel it if you no longer need anything.",
} as const;

export const CANCEL_REQUEST_CONFIRMATION = {
  title: "Cancel this request?",
  body: "This request will no longer be reviewed or fulfilled. It will remain in your request history.",
  confirm: "Cancel request",
  keep: "Keep request",
} as const;
