import type { UnifiedSupplyRequestSearchResult } from "../lib/supply-requests.functions";

type StructuredProductSelection = Pick<
  UnifiedSupplyRequestSearchResult,
  | "productName"
  | "manufacturer"
  | "vendorName"
  | "vendorSku"
  | "packageDisplay"
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
