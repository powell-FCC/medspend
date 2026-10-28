import type { InventoryLocationKind, InventoryStatus } from "@/types/inventory";

// Phase 7B.1 Inventory workspace read contracts. Owners and admins receive the same shapes;
// none of them carries purchase prices or dates.

export type InventoryWorkspaceStatusFilter = "active" | "archived" | "all";

export interface WorkspaceLocation {
  id: string;
  name: string;
  description: string | null;
  kind: InventoryLocationKind;
  active: boolean;
  stockedItemCount: number;
  // Null for Unassigned: it is never counted and has no labels.
  countableItemCount: number | null;
  lastCountedAt: string | null;
  lastCountedByName: string | null;
  activeLabelCount: number | null;
  lastLabelIssuedAt: string | null;
}

export interface WorkspaceLocationDetail extends WorkspaceLocation {
  archivedStockedItemCount: number;
}

export interface WorkspaceStockRow {
  inventoryItemId: string;
  name: string;
  sku: string | null;
  unit: string;
  quantity: number;
  itemActive: boolean;
  // Organization-wide values, never a threshold for this location.
  organizationQuantity: number;
  organizationParLevel: number | null;
  organizationStockStatus: InventoryStatus;
  lastCountedAt: string | null;
}

export interface WorkspaceItem {
  id: string;
  name: string;
  description: string | null;
  sku: string | null;
  vendorName: string | null;
  manufacturer: string | null;
  category: string | null;
  unit: string;
  active: boolean;
  quantity: number;
  parLevel: number | null;
  stockStatus: InventoryStatus;
  unassignedQuantity: number;
  physicalQuantity: number;
  physicalLocationCount: number;
  singlePhysicalLocationName: string | null;
}

export interface WorkspacePage<T> {
  rows: T[];
  // The last row's keyset position; null when this was the final page.
  nextCursor: { name: string; id: string } | null;
}
