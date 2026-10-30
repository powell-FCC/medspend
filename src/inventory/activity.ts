import { countDateRange, displayUnit, formatSignedQuantity } from "./count-history.ts";
import { formatQuantity } from "./locations.ts";
import type { TransferHistoryRow } from "@/types/inventory-workspace";

// Phase 7B.3 inventory activity rules shared by the UI and tests. Transfers move existing
// stock between locations; manual adjustments are other explicit quantity changes. Physical
// counts are reconciliation checkpoints and live in Counts. Nothing here infers why a
// quantity changed beyond the reason that was recorded.

export type ActivityView = "transfers" | "adjustments";

// Reasons a manual adjustment can carry, as stored. "Invoice received" appears only on older
// manual adjustments where an owner chose it; invoice receipts themselves are not listed.
export const adjustmentHistoryReasons = [
  "Manual adjustment",
  "Damaged",
  "Expired",
  "Correction",
  "Invoice received",
] as const;
export type AdjustmentHistoryReason = (typeof adjustmentHistoryReasons)[number];

// Stored reasons are already written for people; anything unexpected is shown as stored.
export function adjustmentReasonLabel(reason: string): string {
  return reason.trim() || "No reason recorded";
}

export const ADJUSTMENT_TOTALS_NOTE =
  "Before and after are the item's recorded total across all locations at the time.";

export const NO_LOCATION_LABEL = "No location (recorded before locations)";

export function adjustmentLocationLabel(locationName: string | null): string {
  return locationName ?? NO_LOCATION_LABEL;
}

// "6 each", "0.25 box". Units are shown as recorded, without plural forms.
export function formatActivityQuantity(value: number, unit: string): string {
  return `${formatQuantity(value)} ${displayUnit(unit)}`;
}

// "+2", "-3", "0".
export function formatAdjustmentAmount(value: number): string {
  return formatSignedQuantity(value);
}

// Seen from one location: stock left it (out) or arrived (in).
export function transferDirection(
  row: Pick<TransferHistoryRow, "fromLocationId" | "toLocationId">,
  locationId: string,
): "out" | "in" | null {
  if (row.fromLocationId === locationId) return "out";
  if (row.toLocationId === locationId) return "in";
  return null;
}

export function transferRouteLabel(
  row: Pick<TransferHistoryRow, "fromLocationName" | "toLocationName">,
) {
  return `${row.fromLocationName} → ${row.toLocationName}`;
}

export function transferEmptyMessage({
  filtered,
  forLocation,
}: {
  filtered: boolean;
  forLocation: boolean;
}) {
  if (filtered) return "No transfers match these filters.";
  return forLocation
    ? "No transfers have been recorded for this location yet."
    : "No inventory transfers have been recorded yet.";
}

export function adjustmentEmptyMessage({
  filtered,
  forLocation,
}: {
  filtered: boolean;
  forLocation: boolean;
}) {
  if (filtered) return "No adjustments match these filters.";
  return forLocation
    ? "No manual adjustments have been recorded for this location yet."
    : "No manual inventory adjustments have been recorded yet.";
}

// Date inputs (YYYY-MM-DD) to the server's half-open range, as for count history.
export function activityDateRange(from: string, to: string) {
  const range = countDateRange(from, to);
  return { createdFrom: range.submittedFrom, createdBefore: range.submittedBefore };
}
