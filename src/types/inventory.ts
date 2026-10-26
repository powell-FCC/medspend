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

export interface InventoryLocationSummary extends InventoryLocation {
  itemCount: number;
  hasStock: boolean;
}
