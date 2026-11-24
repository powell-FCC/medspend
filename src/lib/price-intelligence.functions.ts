import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import {
  getPriceIntelligenceSummary,
  getProductVendorHistory,
  getSupplyRequestPriceContext,
  listPriceIntelligenceProducts,
} from "@/price-intelligence/data";
import { PRICE_FILTERS } from "@/price-intelligence/vendor-intelligence";

const uuid = z.string().uuid();
const organizationInput = z.object({ organizationId: uuid });
const observationCursor = z
  .object({ purchaseDate: z.string(), createdAt: z.string(), observationId: uuid })
  .strict();
const listCursor = z.union([
  observationCursor,
  z.object({ normalizedName: z.string(), productId: uuid }).strict(),
]);

export const listPriceIntelligenceFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    organizationInput
      .extend({
        sort: z.enum(["recent", "product"]),
        filter: z.enum(PRICE_FILTERS),
        vendorId: uuid.nullable(),
        cursor: listCursor.nullable(),
      })
      .parse(value),
  )
  .handler(({ data, context }) =>
    listPriceIntelligenceProducts(context.supabase, context.userId, data.organizationId, data),
  );

export const getPriceIntelligenceSummaryFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => organizationInput.parse(value))
  .handler(({ data, context }) =>
    getPriceIntelligenceSummary(context.supabase, context.userId, data.organizationId),
  );

export const getProductVendorHistoryFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z
      .union([
        organizationInput.extend({ productId: uuid, cursor: observationCursor.nullable() }),
        organizationInput.extend({ inventoryItemId: uuid, cursor: observationCursor.nullable() }),
      ])
      .parse(value),
  )
  .handler(({ data, context }) =>
    getProductVendorHistory(
      context.supabase,
      context.userId,
      data.organizationId,
      "productId" in data
        ? { productId: data.productId }
        : { inventoryItemId: data.inventoryItemId },
      data.cursor,
    ),
  );

export const getSupplyRequestPriceContextFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => organizationInput.extend({ requestId: uuid }).parse(value))
  .handler(({ data, context }) =>
    getSupplyRequestPriceContext(
      context.supabase,
      context.userId,
      data.organizationId,
      data.requestId,
    ),
  );
