import { z } from "zod";
import type { SupplyRequestItemViewModel } from "./staff-dashboard";

export const adminRequestDecisionSchema = z.object({
  organizationId: z.string().uuid(),
  id: z.string().uuid(),
  decision: z.enum(["approved", "denied"]),
  staffVisibleNote: z.string().trim().max(5000).nullable().optional(),
  internalNote: z.string().trim().max(5000).nullable().optional(),
}).refine((value) => value.decision !== "denied" || !!value.staffVisibleNote, {
  path: ["staffVisibleNote"],
  message: "A staff-visible reason is required to decline a request.",
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
