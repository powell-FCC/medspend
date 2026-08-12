import { z } from 'zod';

export const supplyRequestTypeSchema = z.enum(['reorder', 'low_stock', 'out_of_stock', 'new_item']);

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

