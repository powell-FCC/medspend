import type { AdminWorkflowActionKind } from "./workflow-profiles.ts";

// Phase 7C: receiving destinations. Every canonical receipt (ordered -> received) records where the
// delivery went: an active inventory location of the organization, or Unassigned as an explicit
// "not yet placed" choice. It is operational metadata only: receiving moves no stock.

export type ReceivingDestination = {
  id: string;
  name: string;
  kind: "unassigned" | "storage";
};

export function parseReceivingDestinations(rows: unknown): ReceivingDestination[] {
  if (!Array.isArray(rows)) return [];
  return rows.flatMap((row): ReceivingDestination[] => {
    const value = (row ?? {}) as Record<string, unknown>;
    if (typeof value.id !== "string" || typeof value.name !== "string") return [];
    if (value.kind !== "unassigned" && value.kind !== "storage") return [];
    return [{ id: value.id, name: value.name, kind: value.kind }];
  });
}

// Storage locations first by name, Unassigned last (the server orders them the same way).
export function orderReceivingDestinations(
  destinations: readonly ReceivingDestination[],
): ReceivingDestination[] {
  return [...destinations].sort((a, b) =>
    a.kind === b.kind ? a.name.localeCompare(b.name) : a.kind === "unassigned" ? 1 : -1,
  );
}

export const UNASSIGNED_DESTINATION_LABEL = "Unassigned / not yet placed";

export function receivingDestinationLabel(
  destination: Pick<ReceivingDestination, "name" | "kind">,
): string {
  return destination.kind === "unassigned" ? UNASSIGNED_DESTINATION_LABEL : destination.name;
}

// The two drawer actions that perform the canonical receipt and so need a destination.
export function actionNeedsDestination(kind: AdminWorkflowActionKind | null | undefined): boolean {
  return kind === "mark_received" || kind === "receive_and_complete";
}

// What staff and admins see after receipt. Uses the immutable name snapshot.
export function deliveredToLabel(destinationName: string, destinationKind?: string | null): string {
  return destinationKind === "unassigned"
    ? "Received, not yet placed"
    : `Delivered to ${destinationName}`;
}

export type ReceiptSummary = {
  supplyRequestId: string;
  supplyRequestUpdateId: string;
  destinationName: string;
  destinationKind: "unassigned" | "storage";
  receivedAt: string;
  compoundAction: string | null;
};

export function parseReceiptSummaries(rows: unknown): ReceiptSummary[] {
  if (!Array.isArray(rows)) return [];
  return rows.flatMap((row): ReceiptSummary[] => {
    const value = (row ?? {}) as Record<string, unknown>;
    if (
      typeof value.supply_request_id !== "string" ||
      typeof value.supply_request_update_id !== "string" ||
      typeof value.destination_name !== "string" ||
      typeof value.received_at !== "string"
    )
      return [];
    return [
      {
        supplyRequestId: value.supply_request_id,
        supplyRequestUpdateId: value.supply_request_update_id,
        destinationName: value.destination_name,
        destinationKind: value.destination_kind === "unassigned" ? "unassigned" : "storage",
        receivedAt: value.received_at,
        compoundAction: typeof value.compound_action === "string" ? value.compound_action : null,
      },
    ];
  });
}

// --- Last-used destination: a browser-only convenience, never server configuration ---------------

const lastUsedKey = (organizationId: string) => `sportspend.receivingDestination.${organizationId}`;

type Storage = Pick<globalThis.Storage, "getItem" | "setItem">;

function browserStorage(): Storage | null {
  try {
    return typeof window !== "undefined" ? window.localStorage : null;
  } catch {
    return null;
  }
}

export function readLastUsedDestination(
  organizationId: string,
  storage: Storage | null = browserStorage(),
): string | null {
  try {
    return storage?.getItem(lastUsedKey(organizationId)) ?? null;
  } catch {
    return null;
  }
}

export function rememberLastUsedDestination(
  organizationId: string,
  destinationId: string,
  storage: Storage | null = browserStorage(),
): void {
  try {
    storage?.setItem(lastUsedKey(organizationId), destinationId);
  } catch {
    // Private windows and blocked storage: the picker simply starts empty next time.
  }
}

// Preselect the last-used destination only while it is still an active option.
export function initialDestinationId(
  destinations: readonly ReceivingDestination[],
  lastUsedId: string | null,
): string {
  return lastUsedId && destinations.some((destination) => destination.id === lastUsedId)
    ? lastUsedId
    : "";
}
