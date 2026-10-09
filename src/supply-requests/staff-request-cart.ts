import type { UnifiedSupplyRequestSearchResult } from "../lib/supply-requests.functions";
import type { SupplyRequestItemViewModel } from "./staff-dashboard";

type StructuredProductSelection = Pick<
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
  StructuredProductSelection & {
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
  selection: StructuredProductSelection,
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
