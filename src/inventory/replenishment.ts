import { formatQuantity } from "./locations.ts";
import type {
  ReplenishmentCategory,
  ReplenishmentInactiveReason,
  ReplenishmentMovePrefill,
  ReplenishmentRow,
  ReplenishmentSummary,
  RuleDialogState,
} from "@/types/inventory-replenishment";

// Phase 7D Replenishment wording. The database decides every quantity and category
// (inventory_replenishment_rows); these helpers only turn its answer into words. Quantities are
// always in the inventory item's own unit: SportSpend does not know how many units a vendor
// package holds, so nothing here suggests an order quantity.

export const replenishmentCategoryLabel: Record<ReplenishmentCategory, string> = {
  move_available: "Move available",
  partly_covered: "Partly covered",
  needs_purchasing: "Needs purchasing",
  ok: "OK",
  inactive: "Inactive",
};

export const replenishmentInactiveReasonLabel: Record<ReplenishmentInactiveReason, string> = {
  disabled: "Turned off",
  item_archived: "Item archived",
  location_archived: "Location archived",
};

export const attentionCategories: ReplenishmentCategory[] = [
  "move_available",
  "partly_covered",
  "needs_purchasing",
];

export const quantityWithUnit = (quantity: number, unit: string) =>
  `${formatQuantity(quantity)} ${unit}`;

export function shortageText(row: ReplenishmentRow): string | null {
  return row.shortageQuantity > 0
    ? `Short ${quantityWithUnit(row.shortageQuantity, row.itemUnit)}`
    : null;
}

// "Move 8 from Unassigned" or "Move 3 from Unassigned, 6 from Academy ATR", from the donors'
// own share of the move.
export function moveText(row: ReplenishmentRow): string | null {
  if (row.moveQuantity <= 0) return null;
  const parts = row.donors.filter((donor) => donor.moveQuantity > 0);
  const listed = parts.reduce((total, donor) => total + donor.moveQuantity, 0);
  const text = parts.map((donor) => `${formatQuantity(donor.moveQuantity)} from ${donor.name}`);
  const rest = Number((row.moveQuantity - listed).toFixed(6));
  if (rest > 0) text.push(`${formatQuantity(rest)} from other locations`);
  return `Move ${text.join(", ")}`;
}

export function purchasingText(row: ReplenishmentRow): string | null {
  return row.externalQuantity > 0
    ? `Needs purchasing: ${quantityWithUnit(row.externalQuantity, row.itemUnit)}`
    : null;
}

// "Move 8 from Unassigned · Needs purchasing: 1 BX"
export function recommendationText(row: ReplenishmentRow): string | null {
  const parts = [moveText(row), purchasingText(row)].filter(Boolean);
  return parts.length ? parts.join(" · ") : null;
}

// Stock elsewhere that could be moved here. Unassigned is never physically counted.
export function donorContext(row: ReplenishmentRow): string[] {
  return row.donors.map((donor) =>
    donor.kind === "unassigned"
      ? `Unassigned: ${quantityWithUnit(donor.spareQuantity, row.itemUnit)} (not physically counted)`
      : `${donor.name}: ${quantityWithUnit(donor.spareQuantity, row.itemUnit)} above its Minimum`,
  );
}

// One donor per Move Stock action, in donor order. The owner still confirms the move.
export function nextMovePrefill(row: ReplenishmentRow): ReplenishmentMovePrefill | null {
  if (row.category !== "move_available" && row.category !== "partly_covered") return null;
  const donor = row.donors.find((entry) => entry.moveQuantity > 0);
  if (!donor) return null;
  return { fromId: donor.locationId, toId: row.inventoryLocationId, quantity: donor.moveQuantity };
}

const DAY_MS = 24 * 60 * 60 * 1000;

export function lastCountedText(row: ReplenishmentRow, now: Date = new Date()): string {
  if (!row.lastCountedAt) return "Not counted here yet";
  const days = Math.floor((now.getTime() - new Date(row.lastCountedAt).getTime()) / DAY_MS);
  if (days <= 0) return "Counted here today";
  if (days === 1) return "Counted here 1 day ago";
  return `Counted here ${days} days ago`;
}

// Only when the organization has a count cadence. A warning: it never hides a shortage.
export function countCadenceWarning(row: ReplenishmentRow): string | null {
  if (row.locationCountState === "overdue") return `${row.locationName} count is overdue`;
  if (row.locationCountState === "due") return `${row.locationName} count is due`;
  return null;
}

// Organization-level context only. It is never subtracted from the shortage.
export function openRequestText(row: ReplenishmentRow): string | null {
  const total = row.openRequestCount;
  if (total <= 0) return null;
  const label = (count: number, state: string) =>
    count <= 0 ? null : total === 1 ? state : `${count} ${state}`;
  const states = [
    label(row.openApprovedRequestCount, "approved"),
    label(row.openOrderedRequestCount, "ordered"),
  ].filter(Boolean);
  const noun = total === 1 ? "open request" : "open requests";
  return `${total} ${noun} (${states.join(", ")}) for this item`;
}

export function otherShortText(row: ReplenishmentRow): string | null {
  const count = row.otherShortLocationCount;
  if (count <= 0) return null;
  return `Also short at ${count} other ${count === 1 ? "location" : "locations"}`;
}

export const NOT_STOCKED_HERE_TEXT =
  "Not stocked here yet. Move stock in to start counting it here.";

export function coverageText(summary: ReplenishmentSummary): string {
  const rules = summary.rules.active;
  return [
    `${rules} ${rules === 1 ? "active rule" : "active rules"}`,
    `${summary.items.withoutRule} ${summary.items.withoutRule === 1 ? "item" : "items"} without a rule`,
    `${summary.locations.withoutRule} ${summary.locations.withoutRule === 1 ? "location" : "locations"} without a rule`,
  ].join(" · ");
}

export const MAX_RULE_QUANTITY = 1_000_000_000;

// Mirrors the database checks so the dialog can explain a problem before saving; the database
// still refuses anything invalid.
export function validateRuleInput(minimumText: string, targetText: string): string | null {
  if (minimumText.trim() === "" || targetText.trim() === "") return "Enter a Minimum and a Target.";
  const minimum = Number(minimumText);
  const target = Number(targetText);
  if (!Number.isFinite(minimum) || !Number.isFinite(target)) return "Enter numbers only.";
  if (minimum < 0) return "Minimum must be zero or more.";
  if (target <= 0) return "Target must be greater than zero.";
  if (target < minimum) return "Target must be at least the Minimum.";
  const decimals = (text: string) => (text.trim().split(".")[1] ?? "").length;
  if (
    minimum > MAX_RULE_QUANTITY ||
    target > MAX_RULE_QUANTITY ||
    decimals(minimumText) > 6 ||
    decimals(targetText) > 6
  )
    return "Quantities must be at most 1,000,000,000 with up to six decimal places.";
  return null;
}

export const replenishmentQueryKey = (organizationId: string) => [
  "inventory-replenishment",
  organizationId,
];

export const ruleDialogTitle = (state: RuleDialogState) =>
  state.mode === "edit" ? `${state.item.name} at ${state.locationName}` : "Set Minimum and Target";

export const ruleDialogDescription = (state: RuleDialogState) =>
  `SportSpend flags this item at ${state.locationName} when its quantity is at or below the Minimum, and suggests refilling it to the Target. Quantities are in the item's own unit.`;
