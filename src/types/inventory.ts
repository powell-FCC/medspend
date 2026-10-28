export type InventoryStatus = "healthy" | "low" | "critical" | "inactive";
export type AdjustmentReason =
  | "Invoice received"
  | "Manual adjustment"
  | "Damaged"
  | "Expired"
  | "Correction";
// Reasons an owner may choose for a location adjustment. Receipts come only from invoices.
export type LocationAdjustmentReason = Exclude<AdjustmentReason, "Invoice received">;
export const locationAdjustmentReasons: LocationAdjustmentReason[] = [
  "Manual adjustment",
  "Damaged",
  "Expired",
  "Correction",
];

export interface InventoryItem {
  id: string;
  organizationId: string;
  name: string;
  description: string | null;
  sku: string | null;
  vendorName: string | null;
  category: string | null;
  manufacturer: string | null;
  quantity: number;
  unit: string;
  parLevel: number | null;
  active: boolean;
  createdAt: string;
  updatedAt: string;
}

export interface InventoryCategory {
  id: string;
  organizationId: string;
  name: string;
  createdAt: string;
}

export interface InventoryItemInput {
  id?: string;
  organizationId: string;
  name: string;
  description?: string | null;
  sku?: string | null;
  vendorName?: string | null;
  category?: string | null;
  manufacturer?: string | null;
  quantity: number;
  unit: string;
  parLevel?: number | null;
}

export type InventoryLocationKind = "unassigned" | "storage";

export interface InventoryLocation {
  id: string;
  organizationId: string;
  name: string;
  description: string | null;
  kind: InventoryLocationKind;
  active: boolean;
  createdAt: string;
  updatedAt: string;
}

export interface InventoryLocationBalance {
  inventoryItemId: string;
  inventoryLocationId: string;
  quantity: number;
  version: number;
  updatedAt: string;
}

// The fields the move and adjust dialogs need from a location or an item. Full rows and
// Phase 7B.1 workspace rows both satisfy them.
export type InventoryLocationRef = Pick<InventoryLocation, "id" | "name" | "kind" | "active">;
export type InventoryItemRef = Pick<InventoryItem, "id" | "name" | "unit" | "quantity">;
export type EditableInventoryItem = Pick<
  InventoryItem,
  | "id"
  | "name"
  | "description"
  | "sku"
  | "vendorName"
  | "category"
  | "manufacturer"
  | "quantity"
  | "unit"
  | "parLevel"
>;

export interface InventoryLocationSummary extends InventoryLocation {
  itemCount: number;
  hasStock: boolean;
}
