import { createServerFn } from '@tanstack/react-start';
import type { SupabaseClient } from '@supabase/supabase-js';
import { z } from 'zod';
import { requireSupabaseAuth } from '@/integrations/supabase/auth-middleware';
import type { Database } from '@/integrations/supabase/types';
import type {
  InvoiceApprovalResult,
  InvoiceReview,
  InvoiceItemReviewStatus,
  ProcessingStatus,
} from '@/types/invoice-processing';

const uuid = z.string().uuid();
const reviewKey = z.object({ sourceFileId: uuid, organizationId: uuid });
const optionalText = z.string().trim().max(500).default('');
const headerInput = reviewKey.extend({
  vendorId: uuid.optional().nullable(),
  vendorName: z.string().trim().min(1).max(200),
  invoiceNumber: z.string().trim().max(120),
  invoiceDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).or(z.literal('')),
  invoiceTotal: z.number().nonnegative().optional().nullable(),
});
const itemInput = reviewKey.extend({
  id: uuid.optional(),
  sku: z.string().trim().max(120).default(''),
  description: z.string().trim().min(1).max(500),
  manufacturer: optionalText,
  category: z.string().trim().max(120).default(''),
  quantity: z.number().positive(),
  unitOfMeasure: z.string().trim().min(1).max(100),
  unitPrice: z.number().nonnegative(),
  totalPrice: z.number().nonnegative(),
  packageSize: z.string().trim().max(120).default(''),
  vendorProductId: uuid.optional().nullable(),
});

async function assertOwner(db: SupabaseClient<Database>, userId: string, organizationId: string) {
  const { data, error } = await db.from('organization_memberships').select('role')
    .eq('organization_id', organizationId).eq('user_id', userId).eq('active', true).maybeSingle();
  if (error) throw new Error(error.message);
  if (data?.role !== 'owner') throw new Error('Forbidden: owner access required');
}

async function requireDraftInvoice(db: SupabaseClient<Database>, organizationId: string, sourceFileId: string) {
  const { data, error } = await db.from('invoices')
    .select('id,processing_status,posted_at').eq('organization_id', organizationId)
    .eq('source_file_id', sourceFileId).single();
  if (error) throw new Error(error.message);
  if (data.processing_status === 'completed' || data.posted_at) throw new Error('Completed invoices cannot be edited.');
  return data;
}

export const getInvoiceReviewFn = createServerFn({ method: 'POST' })
  .inputValidator((value: unknown) => reviewKey.parse(value))
  .middleware([requireSupabaseAuth])
  .handler(async ({ data, context }): Promise<InvoiceReview> => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const [sourceResult, jobResult] = await Promise.all([
      context.supabase.from('vendor_invoices').select('id,organization_id,original_filename,created_at')
        .eq('id', data.sourceFileId).eq('organization_id', data.organizationId).single(),
      context.supabase.from('invoice_processing_jobs').select('status')
        .eq('invoice_id', data.sourceFileId).eq('organization_id', data.organizationId).single(),
    ]);
    if (sourceResult.error) throw new Error(sourceResult.error.message);
    if (jobResult.error) throw new Error(jobResult.error.message);

    const completed = jobResult.data.status === 'completed';
    const { data: invoice, error: invoiceError } = await context.supabase.from('invoices').upsert({
      organization_id: data.organizationId,
      source_file_id: data.sourceFileId,
      processing_status: completed ? 'completed' : 'review_required',
    }, { onConflict: 'source_file_id' }).select(
      'id,vendor_id,vendor_name,invoice_number,invoice_date,invoice_total,total_amount,processing_status',
    ).single();
    if (invoiceError) throw new Error(invoiceError.message);
    if (!completed) {
      const { error } = await context.supabase.from('invoice_processing_jobs').update({ status: 'review_required' })
        .eq('invoice_id', data.sourceFileId).eq('organization_id', data.organizationId);
      if (error) throw new Error(error.message);
    }

    const [itemsResult, categoriesResult, vendorsResult, mappingsResult, productsResult] = await Promise.all([
      context.supabase.from('invoice_items').select(
        'id,invoice_id,line_number,sku,description,manufacturer,category,quantity,unit_of_measure,unit_price,total_price,package_size,vendor_product_id,review_status',
      ).eq('organization_id', data.organizationId).eq('invoice_id', invoice.id)
        .order('line_number', { ascending: true }).order('created_at', { ascending: true }),
      context.supabase.from('inventory_categories').select('name').eq('organization_id', data.organizationId).order('name'),
      context.supabase.from('vendors').select('id,name').eq('organization_id', data.organizationId).eq('active', true).order('name'),
      context.supabase.from('vendor_products').select(
        'id,vendor_id,product_id,vendor_sku,manufacturer_sku,package_size,unit_of_measure',
      ).eq('organization_id', data.organizationId).eq('active', true).order('vendor_sku'),
      context.supabase.from('products').select('id,name').eq('organization_id', data.organizationId),
    ]);
    for (const result of [itemsResult, categoriesResult, vendorsResult, mappingsResult, productsResult]) {
      if (result.error) throw new Error(result.error.message);
    }
    const vendorNames = new Map((vendorsResult.data ?? []).map((vendor) => [vendor.id, vendor.name]));
    const productNames = new Map((productsResult.data ?? []).map((product) => [product.id, product.name]));
    return {
      header: {
        invoiceId: invoice.id,
        sourceFileId: sourceResult.data.id,
        organizationId: sourceResult.data.organization_id,
        originalFilename: sourceResult.data.original_filename,
        uploadedAt: sourceResult.data.created_at,
        vendorId: invoice.vendor_id,
        vendorName: invoice.vendor_name ?? '',
        invoiceNumber: invoice.invoice_number ?? '',
        invoiceDate: invoice.invoice_date ?? '',
        invoiceTotal: invoice.total_amount ?? invoice.invoice_total,
        status: (completed ? 'completed' : 'review_required') as ProcessingStatus,
      },
      items: (itemsResult.data ?? []).map((item) => ({
        id: item.id,
        invoiceId: item.invoice_id,
        lineNumber: item.line_number,
        sku: item.sku ?? '',
        description: item.description,
        manufacturer: item.manufacturer ?? '',
        category: item.category ?? '',
        quantity: item.quantity,
        unitOfMeasure: item.unit_of_measure ?? 'each',
        unitPrice: item.unit_price ?? 0,
        totalPrice: item.total_price ?? 0,
        packageSize: item.package_size ?? '',
        vendorProductId: item.vendor_product_id,
        reviewStatus: item.review_status as InvoiceItemReviewStatus,
      })),
      categories: (categoriesResult.data ?? []).map((category) => category.name),
      vendors: (vendorsResult.data ?? []).map((vendor) => ({ id: vendor.id, name: vendor.name })),
      vendorProducts: (mappingsResult.data ?? []).map((mapping) => ({
        id: mapping.id,
        vendorId: mapping.vendor_id,
        vendorName: vendorNames.get(mapping.vendor_id) ?? 'Unknown vendor',
        productName: productNames.get(mapping.product_id) ?? 'Unknown product',
        vendorSku: mapping.vendor_sku,
        manufacturerSku: mapping.manufacturer_sku ?? '',
        packageSize: mapping.package_size ?? '',
        unitOfMeasure: mapping.unit_of_measure ?? '',
      })),
    };
  });

export const saveInvoiceHeaderFn = createServerFn({ method: 'POST' })
  .inputValidator((value: unknown) => headerInput.parse(value)).middleware([requireSupabaseAuth])
  .handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const invoice = await requireDraftInvoice(context.supabase, data.organizationId, data.sourceFileId);
    let vendorName = data.vendorName;
    if (data.vendorId) {
      const { data: vendor, error } = await context.supabase.from('vendors').select('name')
        .eq('id', data.vendorId).eq('organization_id', data.organizationId).eq('active', true).single();
      if (error) throw new Error(error.message);
      vendorName = vendor.name;
    }
    const { error } = await context.supabase.from('invoices').update({
      vendor_id: data.vendorId ?? null,
      vendor_name: vendorName,
      invoice_number: data.invoiceNumber || null,
      invoice_date: data.invoiceDate || null,
      invoice_total: data.invoiceTotal ?? null,
      total_amount: data.invoiceTotal ?? null,
      processing_status: 'review_required',
    }).eq('id', invoice.id).eq('organization_id', data.organizationId);
    if (error) throw new Error(error.message);
    return { ok: true };
  });

export const saveInvoiceItemFn = createServerFn({ method: 'POST' })
  .inputValidator((value: unknown) => itemInput.parse(value)).middleware([requireSupabaseAuth])
  .handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const invoice = await requireDraftInvoice(context.supabase, data.organizationId, data.sourceFileId);
    const payload = {
      sku: data.sku || null,
      description: data.description,
      manufacturer: data.manufacturer || null,
      category: data.category || null,
      quantity: data.quantity,
      unit_of_measure: data.unitOfMeasure,
      unit_price: data.unitPrice,
      total_price: data.totalPrice,
      package_size: data.packageSize || null,
      vendor_product_id: data.vendorProductId ?? null,
      review_status: 'pending_review',
    };
    if (data.id) {
      const { error } = await context.supabase.from('invoice_items').update(payload)
        .eq('id', data.id).eq('invoice_id', invoice.id).eq('organization_id', data.organizationId);
      if (error) throw new Error(error.message);
      return { id: data.id };
    }
    const { count, error: countError } = await context.supabase.from('invoice_items')
      .select('id', { count: 'exact', head: true }).eq('invoice_id', invoice.id);
    if (countError) throw new Error(countError.message);
    const { data: item, error } = await context.supabase.from('invoice_items').insert({
      invoice_id: invoice.id,
      organization_id: data.organizationId,
      line_number: (count ?? 0) + 1,
      ...payload,
    }).select('id').single();
    if (error) throw new Error(error.message);
    return { id: item.id };
  });

export const deleteInvoiceItemFn = createServerFn({ method: 'POST' })
  .inputValidator((value: unknown) => reviewKey.extend({ id: uuid }).parse(value)).middleware([requireSupabaseAuth])
  .handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const invoice = await requireDraftInvoice(context.supabase, data.organizationId, data.sourceFileId);
    const { error } = await context.supabase.from('invoice_items').delete()
      .eq('id', data.id).eq('invoice_id', invoice.id).eq('organization_id', data.organizationId);
    if (error) throw new Error(error.message);
    return { ok: true };
  });

export const approveInvoiceFn = createServerFn({ method: 'POST' })
  .inputValidator((value: unknown) => reviewKey.parse(value)).middleware([requireSupabaseAuth])
  .handler(async ({ data, context }): Promise<InvoiceApprovalResult> => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const { data: result, error } = await context.supabase.rpc('post_reviewed_invoice', {
      _organization_id: data.organizationId,
      _source_file_id: data.sourceFileId,
    });
    if (error) throw new Error(error.message);
    if (!result || typeof result !== 'object' || Array.isArray(result)) throw new Error('Invoice approval returned an invalid result.');
    return {
      invoiceId: String(result.invoiceId),
      createdInventoryItems: Number(result.createdInventoryItems ?? 0),
      updatedInventoryItems: Number(result.updatedInventoryItems ?? 0),
      alreadyCompleted: Boolean(result.alreadyCompleted),
    };
  });
