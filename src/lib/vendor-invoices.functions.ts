import { createServerFn } from '@tanstack/react-start';
import type { SupabaseClient } from '@supabase/supabase-js';
import { z } from 'zod';
import { requireSupabaseAuth } from '@/integrations/supabase/auth-middleware';
import type { Database } from '@/integrations/supabase/types';
import type { VendorInvoice } from '@/types/vendor-invoice';

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

function toVendorInvoice(row: {
  id: string;
  organization_id: string;
  uploaded_by: string;
  storage_path: string;
  original_filename: string;
  file_size: number;
  mime_type: string;
  status: string;
  created_at: string;
}): VendorInvoice {
  return {
    id: row.id,
    organizationId: row.organization_id,
    uploadedBy: row.uploaded_by,
    storagePath: row.storage_path,
    originalFilename: row.original_filename,
    fileSize: row.file_size,
    mimeType: 'application/pdf',
    status: 'uploaded',
    createdAt: row.created_at,
  };
}

export const listVendorInvoicesFn = createServerFn({ method: 'POST' })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => z.object({ organizationId: organizationIdSchema }).parse(value))
  .handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const { data: rows, error } = await context.supabase
      .from('vendor_invoices')
      .select('id,organization_id,uploaded_by,storage_path,original_filename,file_size,mime_type,status,created_at')
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
    const expectedPath = new RegExp(`^${data.organizationId}/[0-9a-f-]{36}\\.pdf$`, 'i');
    if (!expectedPath.test(data.storagePath)) throw new Error('Invalid invoice storage path');

    const { data: row, error } = await context.supabase
      .from('vendor_invoices')
      .insert({
        organization_id: data.organizationId,
        uploaded_by: context.userId,
        storage_path: data.storagePath,
        original_filename: data.originalFilename,
        file_size: data.fileSize,
        mime_type: data.mimeType,
      })
      .select('id,organization_id,uploaded_by,storage_path,original_filename,file_size,mime_type,status,created_at')
      .single();
    if (error) throw new Error(error.message);
    return toVendorInvoice(row);
  });
