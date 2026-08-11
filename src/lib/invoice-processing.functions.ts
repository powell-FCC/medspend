import { createServerFn } from '@tanstack/react-start';
import type { SupabaseClient } from '@supabase/supabase-js';
import { z } from 'zod';
import { requireSupabaseAuth } from '@/integrations/supabase/auth-middleware';
import type { Database, Json } from '@/integrations/supabase/types';
import { getExtractionProviders, runDocumentTextExtraction, runExtractionPipeline } from '@/extraction/pipeline';
import type { CanonicalInvoiceExtraction } from '@/extraction/types';
import { EmbeddedPdfTextProvider } from '@/extraction/embedded-pdf-text-provider';
import { DeterministicInvoiceExtractionProvider } from '@/extraction/deterministic-invoice-provider';
import { assessExtractionQuality, validateExtraction } from '@/extraction/validation';
import { resolveVendor } from '@/extraction/document-identity';
import { matchInvoiceProduct } from '@/product-identity/matcher';
import type { OCRProvider } from '@/extraction/providers';
import type { InvoiceApprovalResult, InvoiceReview, InvoiceItemReviewStatus, ProcessingStatus } from '@/types/invoice-processing';

const uuid = z.string().uuid();
const reviewKey = z.object({ sourceFileId: uuid, organizationId: uuid });
const optionalText = z.string().trim().max(500).default('');
const headerInput = reviewKey.extend({
  vendorId: uuid.optional().nullable(),
  vendorName: z.string().trim().min(1).max(200),
  documentType: z.enum(['INVOICE', 'ORDER_CONFIRMATION', 'PURCHASE_ORDER', 'CREDIT_MEMO', 'STATEMENT', 'UNKNOWN']),
  orderNumber: z.string().trim().max(120).default(''),
  orderDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).or(z.literal('')),
  invoiceNumber: z.string().trim().max(120),
  invoiceDate: z
    .string()
    .regex(/^\d{4}-\d{2}-\d{2}$/)
    .or(z.literal('')),
  invoiceTotal: z.number().nonnegative().optional().nullable(),
  purchaseOrder: z.string().trim().max(120).default(''),
  subtotal: z.number().nonnegative().optional().nullable(),
  tax: z.number().nonnegative().optional().nullable(),
  shipping: z.number().nonnegative().optional().nullable(),
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
  const { data, error } = await db.from('organization_memberships').select('role').eq('organization_id', organizationId).eq('user_id', userId).eq('active', true).maybeSingle();
  if (error) throw new Error(error.message);
  if (data?.role !== 'owner') throw new Error('Forbidden: owner access required');
}

async function requireDraftInvoice(db: SupabaseClient<Database>, organizationId: string, sourceFileId: string) {
  const { data, error } = await db.from('invoices').select('id,processing_status,posted_at').eq('organization_id', organizationId).eq('source_file_id', sourceFileId).single();
  if (error) throw new Error(error.message);
  if (data.processing_status === 'completed' || data.posted_at) throw new Error('Completed invoices cannot be edited.');
  return data;
}

async function markExtractionReviewed(db: SupabaseClient<Database>, organizationId: string, sourceFileId: string, target: { header: true } | { itemIndex: number }) {
  const { data } = await db.from('invoice_processing_jobs').select('extraction_result').eq('invoice_id', sourceFileId).eq('organization_id', organizationId).maybeSingle();
  if (!data?.extraction_result) return;
  const extraction = structuredClone(data.extraction_result) as unknown as CanonicalInvoiceExtraction;
  const fields = 'header' in target ? Object.values(extraction.header) : Object.values(extraction.items[target.itemIndex] ?? {});
  for (const field of fields) field.reviewed = true;
  await db
    .from('invoice_processing_jobs')
    .update({ extraction_result: extraction as unknown as Json })
    .eq('invoice_id', sourceFileId)
    .eq('organization_id', organizationId);
}

async function attemptMockExtraction(db: SupabaseClient<Database>, organizationId: string, sourceFileId: string, storagePath: string, invoiceId: string, providers: NonNullable<ReturnType<typeof getExtractionProviders>>) {
  const { error: claimedError } = await db.from('invoice_processing_jobs').update({ status: 'processing', extraction_error: null }).eq('invoice_id', sourceFileId).eq('organization_id', organizationId).eq('status', 'uploaded');
  if (claimedError) throw new Error(claimedError.message);
  try {
    const { data: pdf, error: downloadError } = await db.storage.from('vendor-invoices').download(storagePath);
    if (downloadError) throw new Error(downloadError.message);
    const result = await runExtractionPipeline(new Uint8Array(await pdf.arrayBuffer()), providers);
    const extraction = result.extraction;
    const { error: headerError } = await db
      .from('invoices')
      .update({
        vendor_name: extraction.header.vendor.value || null,
        invoice_number: extraction.header.invoiceNumber.value || null,
        invoice_date: extraction.header.invoiceDate.value || null,
      purchase_order_number: extraction.header.purchaseOrder.value || null,
      subtotal: extraction.header.subtotal.value,
      tax_amount: extraction.header.tax.value,
      shipping_amount: extraction.header.shipping.value,
      invoice_total: extraction.header.total.value,
        total_amount: extraction.header.total.value,
        total: extraction.header.total.value,
        processing_status: 'review_required',
      })
      .eq('id', invoiceId)
      .eq('organization_id', organizationId);
    if (headerError) throw new Error(headerError.message);
    if (extraction.items.length) {
      const { error: itemError } = await db.from('invoice_items').insert(
        extraction.items.map((item, index) => ({
          invoice_id: invoiceId,
          organization_id: organizationId,
          line_number: index + 1,
          sku: item.sku.value || null,
          description: item.description.value,
          manufacturer: item.manufacturer.value || null,
          category: item.suggestedCategory.value || null,
          quantity: item.quantity.value,
          unit_of_measure: item.unit.value || 'each',
          unit_price: item.unitPrice.value,
          total_price: item.lineTotal.value,
          review_status: 'pending_review',
        })),
      );
      if (itemError) throw new Error(itemError.message);
    }
    const { error: completedError } = await db
      .from('invoice_processing_jobs')
      .update({
        status: 'review_required',
        extraction_result: extraction as unknown as Json,
        extraction_error: null,
        ocr_provider: result.ocrProvider,
        extraction_provider: result.invoiceProvider,
      })
      .eq('invoice_id', sourceFileId)
      .eq('organization_id', organizationId);
    if (completedError) throw new Error(completedError.message);
    return extraction;
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : 'Invoice extraction failed';
    await db.from('invoice_processing_jobs').update({ status: 'failed', extraction_error: message }).eq('invoice_id', sourceFileId).eq('organization_id', organizationId);
    // Extraction is optional. The review route must remain usable for manual entry.
    return null;
  }
}

async function attemptEmbeddedTextExtraction(db: SupabaseClient<Database>, organizationId: string, sourceFileId: string, storagePath: string, provider: OCRProvider) {
  const { data: claimed, error: claimError } = await db
    .from('invoice_processing_jobs')
    .update({
      status: 'processing',
      document_text_status: 'pending',
      extraction_error: null,
    })
    .eq('invoice_id', sourceFileId)
    .eq('organization_id', organizationId)
    .eq('status', 'uploaded')
    .select('id')
    .maybeSingle();
  if (claimError) throw new Error(claimError.message);
  if (!claimed) return { status: 'pending', error: null, text: null } as const;
  try {
    const { data: pdf, error: downloadError } = await db.storage.from('vendor-invoices').download(storagePath);
    if (downloadError) throw new Error(downloadError.message);
    const result = await runDocumentTextExtraction(new Uint8Array(await pdf.arrayBuffer()), provider);
    const { error } = await db
      .from('invoice_processing_jobs')
      .update({
        status: 'review_required',
        document_text_status: result.status,
        raw_extracted_text: result.status === 'success' ? result.text : null,
        ocr_provider: result.provider,
        document_page_count: result.pageCount ?? null,
        document_processing_duration_ms: result.durationMs,
        ocr_required: result.ocrRequired,
        extraction_error: null,
      })
      .eq('invoice_id', sourceFileId)
      .eq('organization_id', organizationId);
    if (error) throw new Error(error.message);
    return {
      status: result.status,
      error: null,
      text: result.status === 'success' ? result.text : null,
    } as const;
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : 'Document text extraction failed';
    await db
      .from('invoice_processing_jobs')
      .update({
        status: 'review_required',
        document_text_status: 'failed',
        raw_extracted_text: null,
        ocr_provider: provider.name,
        ocr_required: false,
        extraction_error: message,
      })
      .eq('invoice_id', sourceFileId)
      .eq('organization_id', organizationId);
    return { status: 'failed', error: message, text: null } as const;
  }
}

async function attemptStructuredExtraction(db: SupabaseClient<Database>, organizationId: string, sourceFileId: string, rawText: string) {
  const provider = new DeterministicInvoiceExtractionProvider();
  try {
    const extraction = validateExtraction(await provider.extractInvoice(rawText));
    const { data: seeded, error } = await db.rpc('seed_structured_invoice_draft', {
      _organization_id: organizationId,
      _source_file_id: sourceFileId,
      _extraction: extraction as unknown as Json,
      _provider: provider.name,
    });
    if (error) throw new Error(error.message);
    if (seeded) {
      const { error: identityError } = await db.rpc('persist_invoice_document_identity', {
        _organization_id: organizationId, _source_file_id: sourceFileId,
        _document_type: extraction.header.documentType?.value ?? 'UNKNOWN',
        _order_number: extraction.header.orderNumber?.value ?? '',
        _order_date: extraction.header.orderDate?.value || null,
      });
      if (identityError) throw new Error(identityError.message);
    }
    return { extraction, error: null };
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : 'Structured invoice extraction failed';
    await db.from('invoice_processing_jobs').update({ extraction_error: message, status: 'review_required' }).eq('invoice_id', sourceFileId).eq('organization_id', organizationId).is('extraction_result', null);
    return { extraction: null, error: message };
  }
}

export const getInvoiceReviewFn = createServerFn({ method: 'POST' })
  .inputValidator((value: unknown) => reviewKey.parse(value))
  .middleware([requireSupabaseAuth])
  .handler(async ({ data, context }): Promise<InvoiceReview> => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const [sourceResult, jobResult] = await Promise.all([
      context.supabase.from('vendor_invoices').select('id,organization_id,original_filename,storage_path,created_at').eq('id', data.sourceFileId).eq('organization_id', data.organizationId).single(),
      context.supabase
        .from('invoice_processing_jobs')
        .select('status,extraction_result,extraction_error,document_text_status,ocr_provider,document_page_count,document_processing_duration_ms')
        .eq('invoice_id', data.sourceFileId)
        .eq('organization_id', data.organizationId)
        .single(),
    ]);
    if (sourceResult.error) throw new Error(sourceResult.error.message);
    if (jobResult.error) throw new Error(jobResult.error.message);

    const completed = jobResult.data.status === 'completed';
    const { data: invoice, error: invoiceError } = await context.supabase
      .from('invoices')
      .upsert(
        {
          organization_id: data.organizationId,
          source_file_id: data.sourceFileId,
          processing_status: completed ? 'completed' : 'review_required',
        },
        { onConflict: 'source_file_id' },
      )
      .select('id,vendor_id,vendor_name,vendor_identity_reviewed,document_type,order_number,order_date,invoice_number,invoice_date,purchase_order_number,subtotal,tax_amount,shipping_amount,invoice_total,total_amount,processing_status')
      .single();
    if (invoiceError) throw new Error(invoiceError.message);
    let extraction = jobResult.data.extraction_result as unknown as CanonicalInvoiceExtraction | null;
    let extractionError = jobResult.data.extraction_error;
    let extractionStatus: InvoiceReview['header']['extractionStatus'] = extraction ? 'succeeded' : jobResult.data.status === 'failed' ? 'failed' : 'not_started';
    let documentTextStatus = jobResult.data.document_text_status as InvoiceReview['header']['documentTextStatus'];
    let documentTextProvider = jobResult.data.ocr_provider;
    let documentPageCount = jobResult.data.document_page_count;
    let documentProcessingDurationMs = jobResult.data.document_processing_duration_ms;
    const providers = getExtractionProviders(context.enableMockInvoiceExtraction);
    if (!completed && jobResult.data.status === 'uploaded' && providers) {
      extractionStatus = 'processing';
      extraction = await attemptMockExtraction(context.supabase, data.organizationId, data.sourceFileId, sourceResult.data.storage_path, invoice.id, providers);
      extractionStatus = extraction ? 'succeeded' : 'failed';
      if (!extraction) {
        const failure = await context.supabase.from('invoice_processing_jobs').select('extraction_error').eq('invoice_id', data.sourceFileId).single();
        extractionError = failure.data?.extraction_error ?? 'Extraction failed. Continue with manual review.';
      }
    } else if (!completed && jobResult.data.status === 'uploaded') {
      const documentResult = await attemptEmbeddedTextExtraction(context.supabase, data.organizationId, data.sourceFileId, sourceResult.data.storage_path, new EmbeddedPdfTextProvider());
      documentTextStatus = documentResult.status;
      documentTextProvider = 'unpdf-embedded-text';
      extractionError = documentResult.error;
      if (documentResult.text) {
        extractionStatus = 'processing';
        const structured = await attemptStructuredExtraction(context.supabase, data.organizationId, data.sourceFileId, documentResult.text);
        extraction = structured.extraction;
        extractionStatus = extraction ? 'succeeded' : 'failed';
        extractionError = structured.error;
        if (extraction) {
          if (invoice.document_type === 'UNKNOWN') invoice.document_type = extraction.header.documentType?.value ?? 'UNKNOWN';
          invoice.order_number ??= extraction.header.orderNumber?.value || null;
          invoice.order_date ??= extraction.header.orderDate?.value || null;
        }
      }
      const metadata = await context.supabase.from('invoice_processing_jobs').select('document_page_count,document_processing_duration_ms').eq('invoice_id', data.sourceFileId).single();
      documentPageCount = metadata.data?.document_page_count ?? null;
      documentProcessingDurationMs = metadata.data?.document_processing_duration_ms ?? null;
    }
    if (!completed && extractionStatus !== 'failed') {
      const { error } = await context.supabase.from('invoice_processing_jobs').update({ status: 'review_required' }).eq('invoice_id', data.sourceFileId).eq('organization_id', data.organizationId);
      if (error) throw new Error(error.message);
    }

    const [itemsResult, categoriesResult, vendorsResult, mappingsResult, productsResult, signaturesResult] = await Promise.all([
      context.supabase
        .from('invoice_items')
        .select('id,invoice_id,line_number,sku,description,manufacturer,category,quantity,unit_of_measure,unit_price,total_price,package_size,product_id,vendor_product_id,review_status')
        .eq('organization_id', data.organizationId)
        .eq('invoice_id', invoice.id)
        .order('line_number', { ascending: true })
        .order('created_at', { ascending: true }),
      context.supabase.from('inventory_categories').select('name').eq('organization_id', data.organizationId).order('name'),
      context.supabase.from('vendors').select('id,organization_id,name,normalized_name,email,phone,website').eq('organization_id', data.organizationId).eq('active', true).order('name'),
      context.supabase.from('vendor_products').select('id,organization_id,vendor_id,product_id,vendor_sku,manufacturer_sku,package_size,unit_of_measure').eq('organization_id', data.organizationId).eq('active', true).order('vendor_sku'),
      context.supabase
        .from('products')
        .select('id,organization_id,name,description,manufacturer,internal_item_code,vendor_item_number,preferred_vendor_id,unit_of_measure,pack_size')
        .eq('organization_id', data.organizationId)
        .eq('active', true)
        .order('name'),
      context.supabase.from('vendor_identity_signatures').select('id,organization_id,vendor_id,signature_type,normalized_value').eq('organization_id', data.organizationId).eq('active', true),
    ]);
    for (const result of [itemsResult, categoriesResult, vendorsResult, mappingsResult, productsResult, signaturesResult]) {
      if (result.error) throw new Error(result.error.message);
    }
    const vendorNames = new Map((vendorsResult.data ?? []).map((vendor) => [vendor.id, vendor.name]));
    const productNames = new Map((productsResult.data ?? []).map((product) => [product.id, product.name]));
    const vendorMatch = invoice.vendor_identity_reviewed ? { state: 'CONFIRMED' as const, vendorId: invoice.vendor_id, confidence: 100, reason: 'OWNER_CONFIRMED', evidence: extraction?.vendorEvidence ?? [] }
      : resolveVendor(data.organizationId, extraction?.vendorEvidence ?? [], (vendorsResult.data ?? []).map((vendor) => ({ id: vendor.id, organizationId: vendor.organization_id, name: vendor.name, normalizedName: vendor.normalized_name, email: vendor.email, phone: vendor.phone, website: vendor.website })), (signaturesResult.data ?? []).map((signature) => ({ id: signature.id, organizationId: signature.organization_id, vendorId: signature.vendor_id, signatureType: signature.signature_type as never, normalizedValue: signature.normalized_value })));
    if (!invoice.vendor_identity_reviewed && !invoice.vendor_id && vendorMatch.state === 'MATCHED' && vendorMatch.vendorId) {
      const matchedVendor = (vendorsResult.data ?? []).find((vendor) => vendor.id === vendorMatch.vendorId);
      if (matchedVendor) {
        const { error: vendorError } = await context.supabase.from('invoices').update({ vendor_id: matchedVendor.id, vendor_name: matchedVendor.name }).eq('id', invoice.id).eq('organization_id', data.organizationId).is('vendor_id', null);
        if (vendorError) throw new Error(vendorError.message);
        invoice.vendor_id = matchedVendor.id; invoice.vendor_name = matchedVendor.name;
        const { error: rematchError } = await context.supabase.rpc('rematch_invoice_vendor_products', { _organization_id: data.organizationId, _source_file_id: data.sourceFileId });
        if (rematchError) throw new Error(rematchError.message);
      }
    }
    const identityProducts = (productsResult.data ?? []).map((product) => ({
      organizationId: product.organization_id,
      id: product.id,
      name: product.name,
      description: product.description,
      manufacturer: product.manufacturer,
      internalItemCode: product.internal_item_code,
      vendorItemNumber: product.vendor_item_number,
      preferredVendorId: product.preferred_vendor_id,
      unitOfMeasure: product.unit_of_measure,
      packSize: product.pack_size,
    }));
    const identityMappings = (mappingsResult.data ?? []).map((mapping) => ({
      organizationId: mapping.organization_id,
      id: mapping.id,
      vendorId: mapping.vendor_id,
      productId: mapping.product_id,
      vendorSku: mapping.vendor_sku,
      unitOfMeasure: mapping.unit_of_measure,
      packageSize: mapping.package_size,
    }));
    const matchedItems = (itemsResult.data ?? []).map((item) => ({
      item,
      match: matchInvoiceProduct(
        {
          sku: item.sku ?? '',
          description: item.description,
          manufacturer: item.manufacturer ?? '',
          unitOfMeasure: item.unit_of_measure,
          packageSize: item.package_size,
          productId: item.product_id,
          vendorProductId: item.vendor_product_id,
        },
        data.organizationId,
        invoice.vendor_id,
        identityProducts,
        identityMappings,
      ),
    }));
    const automaticLinks = matchedItems
      .filter(({ item, match }) => !item.product_id && match.state === 'EXACT' && match.productId)
      .map(({ item, match }) =>
        context.supabase
          .from('invoice_items')
          .update({
            product_id: match.productId,
            vendor_product_id: match.vendorProductId,
          })
          .eq('id', item.id)
          .eq('invoice_id', invoice.id)
          .eq('organization_id', data.organizationId),
      );
    if (automaticLinks.length) {
      const results = await Promise.all(automaticLinks);
      const failed = results.find((result) => result.error);
      if (failed?.error) throw new Error(failed.error.message);
    }
    return {
      header: {
        invoiceId: invoice.id,
        sourceFileId: sourceResult.data.id,
        organizationId: sourceResult.data.organization_id,
        originalFilename: sourceResult.data.original_filename,
        uploadedAt: sourceResult.data.created_at,
        vendorId: invoice.vendor_id,
        vendorName: invoice.vendor_name ?? extraction?.header.vendor.value ?? '',
        vendorMatchState: vendorMatch.state,
        suggestedVendorId: vendorMatch.state === 'SUGGESTED' ? vendorMatch.vendorId : null,
        suggestedVendorName: vendorMatch.state === 'SUGGESTED' && vendorMatch.vendorId ? vendorNames.get(vendorMatch.vendorId) ?? '' : '',
        documentType: (invoice.document_type || extraction?.header.documentType?.value || 'UNKNOWN') as InvoiceReview['header']['documentType'],
        orderNumber: invoice.order_number ?? extraction?.header.orderNumber?.value ?? '',
        orderDate: invoice.order_date ?? extraction?.header.orderDate?.value ?? '',
        invoiceNumber: invoice.invoice_number ?? extraction?.header.invoiceNumber.value ?? '',
        invoiceDate: invoice.invoice_date ?? extraction?.header.invoiceDate.value ?? '',
        invoiceTotal: invoice.total_amount ?? invoice.invoice_total ?? extraction?.header.total.value ?? null,
        purchaseOrder: invoice.purchase_order_number ?? extraction?.header.purchaseOrder.value ?? '',
        subtotal: invoice.subtotal ?? extraction?.header.subtotal.value ?? null,
        tax: invoice.tax_amount ?? extraction?.header.tax.value ?? null,
        shipping: invoice.shipping_amount ?? extraction?.header.shipping.value ?? null,
        status: (completed ? 'completed' : 'review_required') as ProcessingStatus,
        extractionStatus,
        extractionError,
        extractionConfidence: extraction
          ? Object.fromEntries(
              Object.entries(extraction.header)
                .filter(([, field]) => !field.reviewed)
                .map(([key, field]) => [key, field.confidence]),
            )
          : undefined,
        totalsNeedReview: extraction?.reconciliation?.needsReview ?? false,
        structuredExtractionState: extraction ? (extraction.quality ?? assessExtractionQuality(extraction)).state : null,
        documentTextStatus,
        documentTextProvider,
        documentPageCount,
        documentProcessingDurationMs,
      },
      items: matchedItems.map(({ item, match }, index) => ({
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
        productId: item.product_id ?? (match.state === 'EXACT' ? match.productId : null),
        productMatch: {
          ...match,
          productName: match.productId ? (productNames.get(match.productId) ?? 'Unknown product') : '',
        },
        reviewStatus: item.review_status as InvoiceItemReviewStatus,
        extractionConfidence:
          extraction?.items[index] && Object.values(extraction.items[index]).some((field) => !field.reviewed)
            ? Math.min(
                ...Object.values(extraction.items[index])
                  .filter((field) => !field.reviewed)
                  .map((field) => field.confidence),
              )
            : undefined,
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
      products: (productsResult.data ?? []).map((product) => ({
        id: product.id,
        name: product.name,
        description: product.description ?? '',
        manufacturer: product.manufacturer ?? '',
        internalItemCode: product.internal_item_code ?? '',
        vendorItemNumber: product.vendor_item_number ?? '',
        unitOfMeasure: product.unit_of_measure ?? '',
        packSize: product.pack_size ?? '',
      })),
    };
  });

export const saveInvoiceHeaderFn = createServerFn({ method: 'POST' })
  .inputValidator((value: unknown) => headerInput.parse(value))
  .middleware([requireSupabaseAuth])
  .handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const invoice = await requireDraftInvoice(context.supabase, data.organizationId, data.sourceFileId);
    let vendorName = data.vendorName;
    if (data.vendorId) {
      const { data: vendor, error } = await context.supabase.from('vendors').select('name').eq('id', data.vendorId).eq('organization_id', data.organizationId).eq('active', true).single();
      if (error) throw new Error(error.message);
      vendorName = vendor.name;
    }
    const { error } = await context.supabase
      .from('invoices')
      .update({
        vendor_id: data.vendorId ?? null,
        vendor_name: vendorName,
        vendor_identity_reviewed: true,
        document_type: data.documentType,
        order_number: data.orderNumber || null,
        order_date: data.orderDate || null,
        invoice_number: data.invoiceNumber || null,
      invoice_date: data.invoiceDate || null,
      invoice_total: data.invoiceTotal ?? null,
      total_amount: data.invoiceTotal ?? null,
      total: data.invoiceTotal ?? null,
      purchase_order_number: data.purchaseOrder || null,
      subtotal: data.subtotal ?? null,
        tax_amount: data.tax ?? null,
        shipping_amount: data.shipping ?? null,
        processing_status: 'review_required',
      })
      .eq('id', invoice.id)
      .eq('organization_id', data.organizationId);
    if (error) throw new Error(error.message);
    if (data.vendorId) {
      const { data: job } = await context.supabase.from('invoice_processing_jobs').select('extraction_result').eq('invoice_id', data.sourceFileId).eq('organization_id', data.organizationId).maybeSingle();
      const rememberedExtraction = job?.extraction_result as unknown as CanonicalInvoiceExtraction | null;
      const { error: signatureError } = await context.supabase.rpc('remember_invoice_vendor_signatures', {
        _organization_id: data.organizationId, _source_file_id: data.sourceFileId,
        _vendor_id: data.vendorId, _evidence: (rememberedExtraction?.vendorEvidence ?? []) as unknown as Json,
      });
      if (signatureError) throw new Error(signatureError.message);
    } else {
      const { error: forgetError } = await context.supabase.rpc('forget_invoice_vendor_signatures', { _organization_id: data.organizationId, _source_file_id: data.sourceFileId });
      if (forgetError) throw new Error(forgetError.message);
    }
    const { error: rematchError } = await context.supabase.rpc('rematch_invoice_vendor_products', {
      _organization_id: data.organizationId,
      _source_file_id: data.sourceFileId,
    });
    if (rematchError) throw new Error(rematchError.message);
    await markExtractionReviewed(context.supabase, data.organizationId, data.sourceFileId, {
      header: true,
    });
    return { ok: true };
  });

export const saveInvoiceItemFn = createServerFn({ method: 'POST' })
  .inputValidator((value: unknown) => itemInput.parse(value))
  .middleware([requireSupabaseAuth])
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
      product_id: null as string | null,
      review_status: 'pending_review',
    };
    if (data.vendorProductId) {
      const { data: mapping, error: mappingError } = await context.supabase.from('vendor_products').select('product_id').eq('id', data.vendorProductId).eq('organization_id', data.organizationId).eq('active', true).single();
      if (mappingError) throw new Error(mappingError.message);
      payload.product_id = mapping.product_id;
    }
    if (data.id) {
      const { data: existing } = await context.supabase
        .from('invoice_items')
        .select('line_number,sku,description,manufacturer,unit_of_measure,package_size,product_id')
        .eq('id', data.id)
        .eq('invoice_id', invoice.id)
        .eq('organization_id', data.organizationId)
        .maybeSingle();
      if (!data.vendorProductId && existing?.product_id) {
        const identityUnchanged =
          (existing.sku ?? '') === data.sku &&
          existing.description === data.description &&
          (existing.manufacturer ?? '') === data.manufacturer &&
          (existing.unit_of_measure ?? '') === data.unitOfMeasure &&
          (existing.package_size ?? '') === data.packageSize;
        if (identityUnchanged) payload.product_id = existing.product_id;
      }
      const { error } = await context.supabase.from('invoice_items').update(payload).eq('id', data.id).eq('invoice_id', invoice.id).eq('organization_id', data.organizationId);
      if (error) throw new Error(error.message);
      if (existing?.line_number)
        await markExtractionReviewed(context.supabase, data.organizationId, data.sourceFileId, {
          itemIndex: existing.line_number - 1,
        });
      return { id: data.id };
    }
    const { count, error: countError } = await context.supabase.from('invoice_items').select('id', { count: 'exact', head: true }).eq('invoice_id', invoice.id);
    if (countError) throw new Error(countError.message);
    const { data: item, error } = await context.supabase
      .from('invoice_items')
      .insert({
        invoice_id: invoice.id,
        organization_id: data.organizationId,
        line_number: (count ?? 0) + 1,
        ...payload,
      })
      .select('id')
      .single();
    if (error) throw new Error(error.message);
    return { id: item.id };
  });

export const deleteInvoiceItemFn = createServerFn({ method: 'POST' })
  .inputValidator((value: unknown) => reviewKey.extend({ id: uuid }).parse(value))
  .middleware([requireSupabaseAuth])
  .handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const invoice = await requireDraftInvoice(context.supabase, data.organizationId, data.sourceFileId);
    const { error } = await context.supabase.from('invoice_items').delete().eq('id', data.id).eq('invoice_id', invoice.id).eq('organization_id', data.organizationId);
    if (error) throw new Error(error.message);
    return { ok: true };
  });

export const approveInvoiceFn = createServerFn({ method: 'POST' })
  .inputValidator((value: unknown) => reviewKey.parse(value))
  .middleware([requireSupabaseAuth])
  .handler(async ({ data, context }): Promise<InvoiceApprovalResult> => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const invoice = await requireDraftInvoice(context.supabase, data.organizationId, data.sourceFileId);
    const { count, error: unresolvedError } = await context.supabase.from('invoice_items').select('id', { count: 'exact', head: true }).eq('invoice_id', invoice.id).eq('organization_id', data.organizationId).is('product_id', null);
    if (unresolvedError) throw new Error(unresolvedError.message);
    if (count) throw new Error('Match or create a product for every invoice line before approval.');
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

const matchInput = reviewKey.extend({
  itemId: uuid,
  productId: uuid,
  rememberVendorSku: z.boolean().default(true),
});
export const confirmInvoiceItemProductFn = createServerFn({ method: 'POST' })
  .inputValidator((value: unknown) => matchInput.parse(value))
  .middleware([requireSupabaseAuth])
  .handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    await requireDraftInvoice(context.supabase, data.organizationId, data.sourceFileId);
    const { data: result, error } = await context.supabase.rpc('confirm_invoice_item_product', {
      _organization_id: data.organizationId,
      _source_file_id: data.sourceFileId,
      _invoice_item_id: data.itemId,
      _product_id: data.productId,
      _remember_vendor_sku: data.rememberVendorSku,
    });
    if (error) throw new Error(error.message);
    return result;
  });

export const unlinkInvoiceItemProductFn = createServerFn({ method: 'POST' })
  .inputValidator((value: unknown) => reviewKey.extend({ itemId: uuid, forgetMapping: z.boolean().default(false) }).parse(value))
  .middleware([requireSupabaseAuth])
  .handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    await requireDraftInvoice(context.supabase, data.organizationId, data.sourceFileId);
    const { error } = await context.supabase.rpc('unlink_invoice_item_product', {
      _organization_id: data.organizationId,
      _source_file_id: data.sourceFileId,
      _invoice_item_id: data.itemId,
      _forget_mapping: data.forgetMapping,
    });
    if (error) throw new Error(error.message);
    return { ok: true };
  });

export const createProductFromInvoiceItemFn = createServerFn({ method: 'POST' })
  .inputValidator((value: unknown) => reviewKey.extend({ itemId: uuid }).parse(value))
  .middleware([requireSupabaseAuth])
  .handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    await requireDraftInvoice(context.supabase, data.organizationId, data.sourceFileId);
    const { data: result, error } = await context.supabase.rpc('create_product_from_invoice_item', {
      _organization_id: data.organizationId,
      _source_file_id: data.sourceFileId,
      _invoice_item_id: data.itemId,
    });
    if (error) throw new Error(error.message);
    if (!result || typeof result !== 'object' || Array.isArray(result) || !result.productId) throw new Error('Product creation returned an invalid result.');
    const { error: mappingError } = await context.supabase.rpc('confirm_invoice_item_product', {
      _organization_id: data.organizationId,
      _source_file_id: data.sourceFileId,
      _invoice_item_id: data.itemId,
      _product_id: String(result.productId),
      _remember_vendor_sku: true,
    });
    if (mappingError) throw new Error(mappingError.message);
    return result;
  });
