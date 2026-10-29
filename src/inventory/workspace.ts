import type { WorkspaceItem, WorkspaceLocation } from "@/types/inventory-workspace";

// Phase 7B.1 Inventory workspace rules shared by the UI and tests. The database functions
// are the authority; these only decide what the screen offers.

export type WorkspaceTab = "items" | "locations" | "counts";
export const workspaceTabs: WorkspaceTab[] = ["items", "locations", "counts"];
export type LocationDetailTab = "stock" | "labels" | "counts";

// Every workspace query sits under this key, so one invalidation refreshes them all.
export const workspaceQueryKey = (organizationId: string) => [
  "inventory-workspace",
  organizationId,
];

// Owners manage inventory; admins read it. Staff never reach the workspace.
export function inventoryWorkspaceAccess(role: string | undefined) {
  return {
    canRead: role === "owner" || role === "admin",
    canManage: role === "owner",
  };
}

const DAY_MS = 24 * 60 * 60 * 1000;

// Factual count state for a physical location. There is no count cadence yet, so nothing
// here says fresh, due or overdue.
export function countAgeLabel(
  location: Pick<WorkspaceLocation, "kind" | "countableItemCount" | "lastCountedAt">,
  now: Date = new Date(),
): string | null {
  if (location.kind === "unassigned") return null;
  if (location.lastCountedAt) {
    const days = Math.floor((now.getTime() - new Date(location.lastCountedAt).getTime()) / DAY_MS);
    if (days <= 0) return "Counted today";
    if (days === 1) return "Counted 1 day ago";
    return `Counted ${days} days ago`;
  }
  if (!location.countableItemCount) return "Nothing to count";
  return "Not counted yet";
}

export function formatWorkspaceDate(iso: string | null): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleDateString(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
  });
}

// Where an item's stock is, from the server summary. Same wording as stockLocationLabel:
// Unassigned is named whenever it holds some.
export function stockPlacementLabel(
  item: Pick<
    WorkspaceItem,
    "unassignedQuantity" | "physicalLocationCount" | "singlePhysicalLocationName"
  >,
): string {
  const inUnassigned = item.unassignedQuantity > 0;
  if (item.physicalLocationCount === 0) return inUnassigned ? "Unassigned" : "No stock";
  const base =
    item.physicalLocationCount === 1 && item.singlePhysicalLocationName
      ? item.singlePhysicalLocationName
      : `${item.physicalLocationCount} locations`;
  return inUnassigned ? `${base} + Unassigned` : base;
}

export function revokeLabelsCopy(
  location: Pick<WorkspaceLocation, "name" | "active">,
  count: number,
) {
  const lines = [
    `${count} active label${count === 1 ? "" : "s"} for ${location.name} will stop working immediately. No new label will be issued.`,
  ];
  if (!location.active) lines.push("Restoring this location will not reactivate revoked labels.");
  else
    lines.push(
      `Staff can still count ${location.name} by choosing it from the location list in Scan Inventory QR.`,
    );
  return lines;
}

export function replaceLabelsCopy(location: Pick<WorkspaceLocation, "name">, count: number) {
  return `${count} active label${count === 1 ? "" : "s"} for ${location.name} will stop working, and one new label is issued. Use this if a label was lost or photographed.`;
}

// Replace is atomic, so when it fails no earlier label was revoked. The error becomes a
// sentence first, without doubling punctuation it already has.
export function replaceFailureMessage(error: string) {
  const message = error.trim() || "Could not replace the labels";
  return `${/[.!?]$/.test(message) ? message : `${message}.`} No label was revoked.`;
}

// Client-side pre-check for archiving. The database is the authority (it re-checks stock
// under a row lock); this only explains why the action is unavailable.
export function canArchiveWorkspaceLocation(
  location: Pick<WorkspaceLocation, "kind" | "active" | "name" | "stockedItemCount">,
): { allowed: boolean; reason?: string } {
  if (location.kind === "unassigned")
    return { allowed: false, reason: "Unassigned is a protected system location." };
  if (!location.active) return { allowed: false, reason: "Already archived." };
  if (location.stockedItemCount > 0)
    return {
      allowed: false,
      reason: `Move all stock out of ${location.name} before archiving it.`,
    };
  return { allowed: true };
}
