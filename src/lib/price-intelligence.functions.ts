import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import type { ProductPriceIntelligence } from "@/price-intelligence/price-intelligence";

const uuid = z.string().uuid();
const nullableMoney = z.number().nullable();

const priceIntelligenceSchema = z
  .object({
    organizationId: uuid,
    productId: uuid,
    productName: z.string(),
    currencyCode: z.literal("USD"),
    summary: z
      .object({
        latestPrice: nullableMoney,
        latestPriceDate: z.string().nullable(),
        previousPrice: nullableMoney,
        absoluteChange: nullableMoney,
        percentChange: nullableMoney,
        historicalLow: nullableMoney,
        historicalHigh: nullableMoney,
        observationCount: z.number().int().nonnegative(),
      })
      .strict(),
    recentPurchases: z.array(
      z
        .object({
          observationId: uuid,
          purchaseDate: z.string(),
          vendorId: uuid,
          vendorName: z.string(),
          vendorProductId: uuid.nullable(),
          vendorSku: z.string().nullable(),
          purchasePrice: z.number().nonnegative(),
          currencyCode: z.literal("USD"),
          quantity: z.number().positive(),
          packageDescription: z.string().nullable(),
          unitOfMeasure: z.string().nullable(),
          packageEvidenceStatus: z.literal("unverified"),
          invoiceId: uuid,
          invoiceItemId: uuid,
          invoiceNumber: z.string().nullable(),
          postedAt: z.string(),
          provenanceType: z.literal("posted_invoice_purchase_history"),
        })
        .strict(),
    ),
    vendorHistory: z.array(
      z
        .object({
          vendorId: uuid,
          vendorName: z.string(),
          latestPrice: z.number().nonnegative(),
          latestPriceDate: z.string(),
          previousPrice: nullableMoney,
          historicalLow: z.number().nonnegative(),
          historicalHigh: z.number().nonnegative(),
          observationCount: z.number().int().positive(),
        })
        .strict(),
    ),
    packageComparability: z
      .object({
        status: z.literal("not_verified"),
        normalizedUnitEconomicsAvailable: z.literal(false),
        reason: z.string(),
      })
      .strict(),
    coverage: z
      .object({
        postedObservationCount: z.number().int().nonnegative(),
        includedUsdObservationCount: z.number().int().nonnegative(),
        excludedUnknownCurrencyCount: z.number().int().nonnegative(),
        excludedNonUsdCount: z.number().int().nonnegative(),
        excludedMissingPriceCount: z.number().int().nonnegative(),
      })
      .strict(),
    historyLimit: z.literal(20),
    vendorLimit: z.literal(12),
  })
  .strict();

export const getProductPriceIntelligenceFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z.object({ organizationId: uuid, productId: uuid }).parse(value),
  )
  .handler(async ({ data, context }) => {
    const { data: result, error } = await context.supabase.rpc("get_product_price_intelligence", {
      _organization_id: data.organizationId,
      _product_id: data.productId,
    });
    if (error) {
      if (error.code === "42501") throw new Error("Forbidden");
      if (error.code === "P0002") throw new Error("This organization product no longer exists");
      throw new Error("Unable to load price intelligence");
    }
    return priceIntelligenceSchema.parse(result) as ProductPriceIntelligence;
  });
