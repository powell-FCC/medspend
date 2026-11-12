import { z } from "zod";
import type { SupplyRequestItemViewModel } from "./staff-dashboard";

export const adminRequestDecisionSchema = z.object({
  organizationId: z.string().uuid(),
  id: z.string().uuid(),
  decision: z.enum(["approved", "denied"]),
  staffVisibleNote: z.string().trim().max(5000).nullable().optional(),
  internalNote: z.string().trim().max(5000).nullable().optional(),
  // Phase 6C: the request version (supply_requests.updated_at, as loaded) the admin
  // reviewed. The decision RPC rejects the decision if the request changed since.
  expectedUpdatedAt: z.string().datetime({ offset: true }),
}).refine((value) => value.decision !== "denied" || !!value.staffVisibleNote, {
  path: ["staffVisibleNote"],
  message: "A staff-visible reason is required to decline a request.",
});

// Phase 7C.0: Approve & Order, Mark Received and Receive & Complete. Approve & Order sends the
// reviewed version (required by the database); the receive actions need none.
export const adminWorkflowActionSchema = z.object({
  organizationId: z.string().uuid(),
  id: z.string().uuid(),
  staffVisibleNote: z.string().trim().max(5000).nullable().optional(),
  internalNote: z.string().trim().max(5000).nullable().optional(),
  expectedUpdatedAt: z.string().datetime({ offset: true }).optional(),
  // Phase 7C: the receiving destination (an active inventory location of the organization).
  inventoryLocationId: z.string().uuid().optional(),
});

export function requestItemIsCustom(item: SupplyRequestItemViewModel): boolean {
  return ![item.inventoryItemId, item.vendorProductId, item.productId, item.catalogVendorProductId].some(Boolean);
}

export function trustedRequestPackage(value: {
  package_status: string;
  package_quantity: number | null;
  package_unit: string | null;
  package_description: string | null;
}): string | null {
  if (value.package_status === "verified" && value.package_quantity && value.package_unit) {
    return `${value.package_quantity} ${value.package_unit}`;
  }
  if (value.package_status === "source_only") return value.package_description?.trim() || null;
  return null;
}

export function requestTimestamp(value: string): string {
  return new Intl.DateTimeFormat(undefined, {
    month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit",
  }).format(new Date(value));
}
