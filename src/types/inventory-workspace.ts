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

// Phase 7B.2 count history. The count session and its lines are the immutable record; the
// names, SKUs and units below are count-time snapshots.

// One unit's corrections in a count. Units are never added together.
export interface CountCorrectionUnit {
  unit: string;
  changedLines: number;
  netDelta: number;
  // Sum of positive corrections, and of negative ones (zero or less).
  increase: number;
  decrease: number;
}

export interface CountHistoryRow {
  sessionId: string;
  submittedAt: string;
  locationId: string;
  // Current location name and state; the schema keeps no location-name snapshot.
  locationName: string;
  locationActive: boolean;
  countedBy: string;
  // "Former member" once the person no longer has a membership.
  countedByName: string;
  lineCount: number;
  changedCount: number;
  correctionSummary: CountCorrectionUnit[];
}

export interface CountHistoryFilters {
  locationId: string | null;
  countedBy: string | null;
  changedOnly: boolean;
  submittedFrom: string | null;
  submittedBefore: string | null;
}

export interface CountHistoryPage {
  rows: CountHistoryRow[];
  // The last row's keyset position; null when this was the final page.
  nextCursor: { submittedAt: string; id: string } | null;
}

export interface CountSessionLine {
  inventoryItemId: string;
  name: string;
  sku: string | null;
  unit: string;
  previousQuantity: number;
  countedQuantity: number;
  delta: number;
  // The item's state today; whether it was archived when counted is not recorded.
  itemArchivedNow: boolean;
}

export interface CountSessionDetail extends CountHistoryRow {
  lines: CountSessionLine[];
}

// Phase 7B.3 inventory activity. Transfers move stock between locations; manual adjustments
// change a total. Item and location names are current names: neither table keeps a snapshot.

export interface TransferHistoryRow {
  transferId: string;
  createdAt: string;
  inventoryItemId: string;
  itemName: string;
  itemSku: string | null;
  itemUnit: string;
  quantity: number;
  fromLocationId: string;
  fromLocationName: string;
  toLocationId: string;
  toLocationName: string;
  createdBy: string;
  // "Former member" once the person no longer has a membership.
  createdByName: string;
}

export interface AdjustmentHistoryRow {
  adjustmentId: string;
  createdAt: string;
  inventoryItemId: string;
  itemName: string;
  itemSku: string | null;
  itemUnit: string;
  // Null only for adjustments recorded before inventory locations existed.
  locationId: string | null;
  locationName: string | null;
  // The item's organization total (all locations) before and after, as stored.
  previousQuantity: number;
  adjustmentAmount: number;
  newQuantity: number;
  reason: string;
  sourceType: string | null;
  createdBy: string;
  createdByName: string;
}

export interface ActivityFilters {
  locationId: string | null;
  itemId: string | null;
  createdBy: string | null;
  createdFrom: string | null;
  createdBefore: string | null;
}

export interface AdjustmentFilters extends ActivityFilters {
  reason: string | null;
}

export type ActivityCursor = { createdAt: string; id: string };

export interface ActivityPage<T> {
  rows: T[];
  // The last row's keyset position; null when this was the final page.
  nextCursor: ActivityCursor | null;
}
