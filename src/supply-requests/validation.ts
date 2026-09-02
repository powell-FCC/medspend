import { z } from 'zod';

export const supplyRequestTypeSchema = z.enum(['reorder', 'low_stock', 'out_of_stock', 'new_item']);

export const supplyRequestItemSchema = z.object({
  productId: z.string().uuid().optional().nullable(),
  inventoryItemId: z.string().uuid().optional().nullable(),
  vendorProductId: z.string().uuid().optional().nullable(),
  catalogVendorProductId: z.string().uuid().optional().nullable(),
  freeTextItem: z.string().trim().min(1).max(200).optional().nullable(),
  quantity: z.number().int().positive(),
}).refine((item) => {
  const hasStructuredIdentity = Boolean(
    item.productId
      || item.inventoryItemId
      || item.vendorProductId
      || item.catalogVendorProductId,
  );
  return hasStructuredIdentity !== Boolean(item.freeTextItem);
}, {
  message: 'Each item must contain one structured identity or one custom item',
});

export const supplyRequestInputSchema = z.object({
  organizationId: z.string().uuid(),
  requestType: supplyRequestTypeSchema,
  productId: z.string().uuid().optional().nullable(),
  freeTextItem: z.string().optional().nullable(),
  quantity: z.number().int().positive().optional().nullable(),
  teamId: z.string().uuid().optional().nullable(),
  locationId: z.string().uuid().optional().nullable(),
  notes: z.string().optional().nullable(),
});

export const multiItemSupplyRequestInputSchema = z.object({
  organizationId: z.string().uuid(),
  requestType: supplyRequestTypeSchema,
  items: z.array(supplyRequestItemSchema).min(1).max(50),
  teamId: z.string().uuid().optional().nullable(),
  locationId: z.string().uuid().optional().nullable(),
  notes: z.string().max(5000).optional().nullable(),
});
