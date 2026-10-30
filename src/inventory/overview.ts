import { formatQuantity } from "./locations.ts";
import type { InventoryOverview, OverviewSnapshot } from "@/types/inventory-workspace";

// Phase 7B.4 Inventory Overview rules shared by the UI and tests. The overview reports
// current state only. Nothing here is time-based (count cadence is a later package), and
// nothing infers why stock is where it is.

export const UNASSIGNED_EXPLAINER =
  "Unassigned holds inventory that is not currently assigned to a physical storage location.";

export const RECORDED_QUANTITY_NOTE =
  "Raw recorded quantities added across every unit. Not comparable across units and not a value.";

export type AttentionKey = keyof InventoryOverview["attention"];

// Order and wording of the needs-attention lists.
export const attentionSections: Array<{ key: AttentionKey; title: string; description: string }> = [
  {
    key: "unassignedStock",
    title: "Stock in Unassigned",
    description: "Items with a quantity in Unassigned.",
  },
  {
    key: "neverCountedLocations",
    title: "Locations never counted",
    description: "Active storage locations with countable items and no submitted count.",
  },
  {
    key: "neverCountedItems",
    title: "Items never counted",
    description: "Items kept in an active storage location that no count has recorded.",
  },
  {
    key: "noActiveLabel",
    title: "No active label",
    description: "Active storage locations without an active QR label.",
  },
  {
    key: "archivedWithActiveLabel",
    title: "Active label on archived location",
    description: "Archived storage locations whose QR label still works.",
  },
];

export function attentionTotal(overview: InventoryOverview): number {
  return attentionSections.reduce((sum, section) => sum + overview.attention[section.key].total, 0);
}

export function moreRowsLabel(total: number, shown: number): string | null {
  const more = total - shown;
  return more > 0 ? `and ${more} more` : null;
}

export function plural(count: number, one: string, many = `${one}s`): string {
  return `${count} ${count === 1 ? one : many}`;
}

// The unit spread behind the raw recorded quantity: "Across 4 units", or "In 1 unit".
export function recordedUnitsLabel(snapshot: Pick<OverviewSnapshot, "stockedUnitCount">): string {
  return snapshot.stockedUnitCount === 1
    ? "In 1 unit"
    : `Across ${snapshot.stockedUnitCount} units`;
}
