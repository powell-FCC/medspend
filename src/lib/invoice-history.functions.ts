import { createServerFn } from '@tanstack/react-start';
import type { SupabaseClient } from '@supabase/supabase-js';
import { z } from 'zod';
import { requireSupabaseAuth } from '@/integrations/supabase/auth-middleware';
import type { Database } from '@/integrations/supabase/types';
import type { InvoiceHistoryRow, PurchaseHistoryRow, VendorHistoryRow } from '@/types/invoice-history';
import type { ProcessingStatus } from '@/types/invoice-processing';

const input = z.object({ organizationId: z.string().uuid() });

async function assertOwner(db: SupabaseClient<Database>, userId: string, organizationId: string) {
  const { data, error } = await db.from('organization_memberships').select('role')
    .eq('organization_id', organizationId).eq('user_id', userId).eq('active', true).maybeSingle();
  if (error) throw new Error(error.message);
  if (data?.role !== 'owner') throw new Error('Forbidden: owner access required');
}

async function loadHistory(db: SupabaseClient<Database>, organizationId: string) {
  const [sourcesResult, jobsResult, invoicesResult] = await Promise.all([
    db.from('vendor_invoices').select('id,original_filename,file_size,storage_path,status,created_at').eq('organization_id', organizationId).order('created_at', { ascending: false }),
    db.from('invoice_processing_jobs').select('invoice_id,status').eq('organization_id', organizationId),
    db.from('invoices').select('id,source_file_id,vendor_name,invoice_number,invoice_date,invoice_total,processing_status,created_at').eq('organization_id', organizationId),
  ]);
  if (sourcesResult.error) throw new Error(sourcesResult.error.message);
  if (jobsResult.error) throw new Error(jobsResult.error.message);
  if (invoicesResult.error) throw new Error(invoicesResult.error.message);
  const invoiceIds = (invoicesResult.data ?? []).map((row) => row.id);
  const itemsResult = invoiceIds.length
    ? await db.from('invoice_items').select('invoice_id').eq('organization_id', organizationId).in('invoice_id', invoiceIds)
    : { data: [], error: null };
  if (itemsResult.error) throw new Error(itemsResult.error.message);
  return { sources: sourcesResult.data ?? [], jobs: jobsResult.data ?? [], invoices: invoicesResult.data ?? [], items: itemsResult.data ?? [] };
}

export const listInvoiceHistoryFn = createServerFn({ method: 'POST' }).middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => input.parse(value)).handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const history = await loadHistory(context.supabase, data.organizationId);
    const rows: InvoiceHistoryRow[] = history.sources.map((source) => {
      const structured = history.invoices.find((invoice) => invoice.source_file_id === source.id);
      const job = history.jobs.find((candidate) => candidate.invoice_id === source.id);
      return { vendorInvoiceId: source.id, filename: source.original_filename, vendor: structured?.vendor_name === 'Vendor pending extraction' ? null : structured?.vendor_name ?? null,
        uploadedAt: source.created_at, status: (job?.status ?? source.status) as ProcessingStatus,
        itemsProcessed: structured ? history.items.filter((item) => item.invoice_id === structured.id).length : 0,
        fileSize: source.file_size, storagePath: source.storage_path };
    });
    return rows;
  });

export const listPurchaseHistoryFn = createServerFn({ method: 'POST' }).middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => input.parse(value)).handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const history = await loadHistory(context.supabase, data.organizationId);
    const rows: PurchaseHistoryRow[] = history.invoices.filter((invoice) => invoice.processing_status === 'completed' && invoice.vendor_name && invoice.vendor_name !== 'Vendor pending extraction').map((invoice) => ({
      invoiceId: invoice.id, date: invoice.invoice_date ?? invoice.created_at, vendor: invoice.vendor_name!, invoiceNumber: invoice.invoice_number,
      itemCount: history.items.filter((item) => item.invoice_id === invoice.id).length, total: invoice.invoice_total,
    })).sort((a, b) => (b.date ?? '').localeCompare(a.date ?? ''));
    return rows;
  });

export const listVendorHistoryFn = createServerFn({ method: 'POST' }).middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => input.parse(value)).handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const { data: invoices, error } = await context.supabase.from('invoices')
      .select('vendor_name,invoice_date,created_at').eq('organization_id', data.organizationId).not('vendor_name', 'is', null);
    if (error) throw new Error(error.message);
    const vendors = new Map<string, VendorHistoryRow>();
    for (const invoice of invoices ?? []) {
      const name = invoice.vendor_name?.trim(); if (!name || name === 'Vendor pending extraction') continue;
      const date = invoice.invoice_date ?? invoice.created_at; const current = vendors.get(name.toLowerCase());
      if (current) { current.invoiceCount += 1; if (!current.lastPurchaseDate || date > current.lastPurchaseDate) current.lastPurchaseDate = date; }
      else vendors.set(name.toLowerCase(), { vendorName: name, invoiceCount: 1, lastPurchaseDate: date });
    }
    return [...vendors.values()].sort((a, b) => a.vendorName.localeCompare(b.vendorName));
  });
