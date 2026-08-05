import { createServerFn } from '@tanstack/react-start';
import type { SupabaseClient } from '@supabase/supabase-js';
import { z } from 'zod';
import { requireSupabaseAuth } from '@/integrations/supabase/auth-middleware';
import type { Database } from '@/integrations/supabase/types';
import { MOCK_REVIEW_ITEMS, type InvoiceReview, type ProcessingStatus } from '@/types/invoice-processing';

const uuid = z.string().uuid();
const itemSchema = z.object({
  id: z.string().min(1), sku: z.string().trim().max(100), description: z.string().trim().min(1).max(500),
  quantity: z.number().positive(), unitPrice: z.number().nonnegative(), category: z.string().trim().max(100),
  unitOfMeasure: z.string().trim().max(100),
});

async function assertOwner(supabase: SupabaseClient<Database>, userId: string, organizationId: string) {
  const { data, error } = await supabase.from('organization_memberships').select('role')
    .eq('organization_id', organizationId).eq('user_id', userId).eq('active', true).maybeSingle();
  if (error) throw new Error(error.message);
  if (data?.role !== 'owner') throw new Error('Forbidden: owner access required');
}

export const getInvoiceReviewFn = createServerFn({ method: 'POST' })
  .inputValidator((value: unknown) => z.object({ sourceFileId: uuid, organizationId: uuid }).parse(value))
  .middleware([requireSupabaseAuth])
  .handler(async ({ data, context }): Promise<InvoiceReview> => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const [sourceResult, jobResult, invoiceResult] = await Promise.all([
      context.supabase.from('vendor_invoices').select('id,organization_id,original_filename').eq('id', data.sourceFileId).eq('organization_id', data.organizationId).single(),
      context.supabase.from('invoice_processing_jobs').select('status').eq('invoice_id', data.sourceFileId).eq('organization_id', data.organizationId).single(),
      context.supabase.from('invoices').select('vendor_name,invoice_number,invoice_date,invoice_total,processing_status').eq('source_file_id', data.sourceFileId).maybeSingle(),
    ]);
    if (sourceResult.error) throw new Error(sourceResult.error.message);
    if (jobResult.error) throw new Error(jobResult.error.message);

    let status = jobResult.data.status as ProcessingStatus;
    if (status === 'uploaded' || status === 'processing') {
      const { error } = await context.supabase.from('invoice_processing_jobs')
        .update({ status: 'review_required' }).eq('invoice_id', data.sourceFileId);
      if (error) throw new Error(error.message);
      status = 'review_required';
    }
    return {
      sourceFileId: sourceResult.data.id, organizationId: sourceResult.data.organization_id,
      originalFilename: sourceResult.data.original_filename, vendorName: invoiceResult.data?.vendor_name ?? null,
      invoiceNumber: invoiceResult.data?.invoice_number ?? null, invoiceDate: invoiceResult.data?.invoice_date ?? null,
      invoiceTotal: invoiceResult.data?.invoice_total ?? null, status, items: MOCK_REVIEW_ITEMS,
    };
  });

export const addApprovedItemsToInventoryFn = createServerFn({ method: 'POST' })
  .inputValidator((value: unknown) => z.object({ sourceFileId: uuid, organizationId: uuid, items: z.array(itemSchema).min(1) }).parse(value))
  .middleware([requireSupabaseAuth])
  .handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const { data: job, error: jobError } = await context.supabase.from('invoice_processing_jobs')
      .select('status').eq('invoice_id', data.sourceFileId).eq('organization_id', data.organizationId).single();
    if (jobError) throw new Error(jobError.message);
    if (job.status === 'completed') {
      const { data: completedInvoice, error } = await context.supabase.from('invoices')
        .select('id').eq('source_file_id', data.sourceFileId).single();
      if (error) throw new Error(error.message);
      return { invoiceId: completedInvoice.id, createdInventoryItems: 0 };
    }
    const { data: invoice, error: invoiceError } = await context.supabase.from('invoices').upsert({
      organization_id: data.organizationId, source_file_id: data.sourceFileId, vendor_name: 'Vendor pending extraction',
      processing_status: 'review_required',
    }, { onConflict: 'source_file_id' }).select('id').single();
    if (invoiceError) throw new Error(invoiceError.message);

    const { error: lineError } = await context.supabase.from('invoice_items').insert(data.items.map((item) => ({
      invoice_id: invoice.id, organization_id: data.organizationId, sku: item.sku || null,
      description: item.description, quantity: item.quantity, unit_price: item.unitPrice,
      total_price: item.quantity * item.unitPrice, unit_of_measure: item.unitOfMeasure || null,
    })));
    if (lineError) throw new Error(lineError.message);

    let createdInventoryItems = 0;
    for (const item of data.items) {
      const { data: received, error: inventoryError } = await context.supabase.rpc('receive_invoice_inventory_item', {
        _organization_id: data.organizationId, _sku: item.sku, _name: item.description,
        _vendor_name: 'Vendor pending extraction', _quantity: item.quantity, _unit: item.unitOfMeasure,
        _category: item.category, _unit_price: item.unitPrice,
      });
      if (inventoryError) throw new Error(inventoryError.message);
      if (received?.[0]?.created) createdInventoryItems += 1;
    }
    const [invoiceUpdate, jobUpdate] = await Promise.all([
      context.supabase.from('invoices').update({ processing_status: 'completed' }).eq('id', invoice.id),
      context.supabase.from('invoice_processing_jobs').update({ status: 'completed' }).eq('invoice_id', data.sourceFileId),
    ]);
    if (invoiceUpdate.error) throw new Error(invoiceUpdate.error.message);
    if (jobUpdate.error) throw new Error(jobUpdate.error.message);
    return { invoiceId: invoice.id, createdInventoryItems };
  });
