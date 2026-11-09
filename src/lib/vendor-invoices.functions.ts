import { createServerFn } from '@tanstack/react-start';
import type { SupabaseClient } from '@supabase/supabase-js';
import { z } from 'zod';
import { requireSupabaseAuth } from '@/integrations/supabase/auth-middleware';
import type { Database } from '@/integrations/supabase/types';
import { recordVendorInvoiceRow, toVendorInvoice, VENDOR_INVOICE_COLUMNS } from '@/invoice/upload-record';

const organizationIdSchema = z.string().uuid();
const metadataSchema = z.object({
  organizationId: organizationIdSchema,
  storagePath: z.string().min(1).max(500),
  originalFilename: z.string().trim().min(1).max(255),
  fileSize: z.number().int().positive().max(25 * 1024 * 1024),
  mimeType: z.literal('application/pdf'),
});

async function assertOwner(
  supabase: SupabaseClient<Database>,
  userId: string,
  organizationId: string,
): Promise<void> {
  const { data, error } = await supabase
    .from('organization_memberships')
    .select('role')
    .eq('organization_id', organizationId)
    .eq('user_id', userId)
    .eq('active', true)
    .maybeSingle();
  if (error) throw new Error(error.message);
  if (data?.role !== 'owner') throw new Error('Forbidden: owner access required');
}

export const listVendorInvoicesFn = createServerFn({ method: 'POST' })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => z.object({ organizationId: organizationIdSchema }).parse(value))
  .handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const { data: rows, error } = await context.supabase
      .from('vendor_invoices')
      .select(VENDOR_INVOICE_COLUMNS)
      .eq('organization_id', data.organizationId)
      .order('created_at', { ascending: false });
    if (error) throw new Error(error.message);
    return (rows ?? []).map(toVendorInvoice);
  });

export const recordVendorInvoiceFn = createServerFn({ method: 'POST' })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => metadataSchema.parse(value))
  .handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    return recordVendorInvoiceRow(context.supabase, context.userId, data);
  });
