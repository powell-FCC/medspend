import type {
  InventoryLocation,
  InventoryLocationBalance,
  InventoryLocationRef,
  InventoryLocationSummary,
} from "@/types/inventory";

// Quantities stay numeric (fractions allowed). Display trims float noise without rounding
// away real precision: 2.75 stays 2.75, 0.1 + 0.2 shows 0.3.
export function formatQuantity(value: number): string {
  if (!Number.isFinite(value)) return "0";
  return Number(value.toFixed(6)).toString();
}

// Unassigned first, then active locations by name, then archived ones.
export function sortInventoryLocations<
  T extends Pick<InventoryLocation, "kind" | "active" | "name">,
>(locations: T[]): T[] {
  return [...locations].sort((a, b) => {
    if (a.kind !== b.kind) return a.kind === "unassigned" ? -1 : 1;
    if (a.active !== b.active) return a.active ? -1 : 1;
    return a.name.localeCompare(b.name, undefined, { sensitivity: "base" });
  });
}

export function summarizeInventoryLocations(
  locations: InventoryLocation[],
  balances: InventoryLocationBalance[],
): InventoryLocationSummary[] {
  return sortInventoryLocations(locations).map((location) => {
    const held = balances.filter(
      (balance) => balance.inventoryLocationId === location.id && balance.quantity > 0,
    );
    return { ...location, itemCount: held.length, hasStock: held.length > 0 };
  });
}

export interface ItemLocationQuantity<L extends InventoryLocationRef = InventoryLocation> {
  location: L;
  quantity: number;
}

// Every location holding this item, plus Unassigned even when it is empty.
export function itemLocationBreakdown<L extends InventoryLocationRef>(
  itemId: string,
  locations: L[],
  balances: InventoryLocationBalance[],
): ItemLocationQuantity<L>[] {
  const byLocation = new Map(
    balances
      .filter((balance) => balance.inventoryItemId === itemId)
      .map((balance) => [balance.inventoryLocationId, balance.quantity]),
  );
  return sortInventoryLocations(locations)
    .map((location) => ({ location, quantity: byLocation.get(location.id) ?? 0 }))
    .filter((entry) => entry.quantity > 0 || entry.location.kind === "unassigned");
}

export function physicalLocationCount(
  itemId: string,
  locations: InventoryLocationRef[],
  balances: InventoryLocationBalance[],
): number {
  return itemLocationBreakdown(itemId, locations, balances).filter(
    (entry) => entry.location.kind !== "unassigned" && entry.quantity > 0,
  ).length;
}

// Where an item's stock is, in one short label for the inventory table. Unassigned is named
// whenever it holds some, so a split like 9 in Unassigned + 1 in a cabinet never reads as
// "1 location".
export function stockLocationLabel(
  itemId: string,
  locations: InventoryLocationRef[],
  balances: InventoryLocationBalance[],
): string {
  const held = itemLocationBreakdown(itemId, locations, balances).filter(
    (entry) => entry.quantity > 0,
  );
  if (held.length === 0) return "No stock";
  const physical = held.filter((entry) => entry.location.kind !== "unassigned");
  if (physical.length === 0) return "Unassigned";
  const base = physical.length === 1 ? physical[0].location.name : `${physical.length} locations`;
  return held.some((entry) => entry.location.kind === "unassigned") ? `${base} + Unassigned` : base;
}

// The move form after balances refresh: if the chosen source no longer holds stock (for
// example the last unit just moved out), fall back to the first location that does and
// clear the destination, so the shown and submitted source never disagree.
export function reconcileMoveSource(
  current: { fromId: string; toId: string },
  sourceIds: string[],
): { fromId: string; toId: string } {
  if (current.fromId && sourceIds.includes(current.fromId)) return current;
  return { fromId: sourceIds[0] ?? "", toId: "" };
}

export function canArchiveInventoryLocation(
  location: InventoryLocation,
  balances: InventoryLocationBalance[],
): { allowed: boolean; reason?: string } {
  if (location.kind === "unassigned")
    return { allowed: false, reason: "Unassigned is a protected system location." };
  if (!location.active) return { allowed: false, reason: "Already archived." };
  if (
    balances.some((balance) => balance.inventoryLocationId === location.id && balance.quantity > 0)
  ) {
    return {
      allowed: false,
      reason: `Move all stock out of ${location.name} before archiving it.`,
    };
  }
  return { allowed: true };
}

// Client-side pre-check for the move form. The database is the authority; this only spares
// the owner an obvious round trip.
export function validateMove(input: {
  fromId: string;
  toId: string;
  quantity: number;
  available: number;
}): string | null {
  if (!input.fromId || !input.toId) return "Choose where the stock comes from and where it goes.";
  if (input.fromId === input.toId) return "Choose two different locations.";
  if (!Number.isFinite(input.quantity) || input.quantity <= 0)
    return "Move a quantity greater than zero.";
  if (input.quantity > input.available + 1e-9)
    return `Only ${formatQuantity(input.available)} available at the source location.`;
  return null;
}

export function validateLocationAdjustment(input: {
  amount: number;
  available: number;
}): string | null {
  if (!Number.isFinite(input.amount) || input.amount === 0) return "Enter a non-zero adjustment.";
  if (input.available + input.amount < -1e-9)
    return `This location has only ${formatQuantity(input.available)}; it cannot go below zero.`;
  return null;
}
