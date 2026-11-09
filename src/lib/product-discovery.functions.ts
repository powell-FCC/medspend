import { createServerFn } from "@tanstack/react-start";
import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import { requireMembership } from "@/lib/supply-requests.functions";
import {
  getStaffProductDiscovery,
  searchStaffProducts,
  setStaffProductSaved,
} from "@/supply-requests/discovery-reads";
import type { StaffDiscoveryProduct } from "@/supply-requests/product-discovery";

// Phase 5A.10 staff product discovery. Every read and write goes through a narrow RPC
// (src/supply-requests/discovery-reads.ts):
//   search_supply_request_products_with_signals  ranked search + explanation columns
//   get_staff_product_discovery                  Saved / Frequently requested / Purchased before
//   save_staff_product / remove_staff_saved_product   the caller's own Saved Items
// The RPCs check active membership themselves; nothing here reads a table directly.

type Db = SupabaseClient;

export const searchStaffProductsFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) =>
    z
      .object({
        organizationId: z.string().uuid(),
        q: z.string().trim().max(120),
        limit: z.number().int().min(1).max(50).default(20),
      })
      .parse(d),
  )
  .handler(async ({ data, context }) => {
    await requireMembership(context, data.organizationId);
    if (!data.q) return [] as StaffDiscoveryProduct[];
    return searchStaffProducts(
      context.supabase as unknown as Db,
      data.organizationId,
      data.q,
      data.limit,
    );
  });

export const getStaffProductDiscoveryFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) => z.object({ organizationId: z.string().uuid() }).parse(d))
  .handler(async ({ data, context }) => {
    await requireMembership(context, data.organizationId);
    return getStaffProductDiscovery(context.supabase as unknown as Db, data.organizationId);
  });

const savedIdentitySchema = z
  .object({
    organizationId: z.string().uuid(),
    productId: z.string().uuid().nullable(),
    catalogVendorProductId: z.string().uuid().nullable(),
    inventoryItemId: z.string().uuid().nullable(),
    saved: z.boolean(),
  })
  .refine(
    (value) =>
      [value.productId, value.catalogVendorProductId, value.inventoryItemId].filter(Boolean)
        .length === 1,
    { message: "Exactly one product identity is required" },
  );

export const setStaffProductSavedFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) => savedIdentitySchema.parse(d))
  .handler(async ({ data, context }) => {
    await requireMembership(context, data.organizationId);
    const { organizationId, saved, ...identity } = data;
    return setStaffProductSaved(context.supabase as unknown as Db, organizationId, identity, saved);
  });
