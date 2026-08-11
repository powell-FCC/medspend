import type { CanonicalInvoiceExtraction, ExtractedField, ExtractionQuality } from './types.ts';

function assertField(field: ExtractedField<unknown>, name: string) {
  if (!field || typeof field !== 'object') throw new Error(`Missing extracted field: ${name}`);
  if (!Number.isFinite(field.confidence) || field.confidence < 0 || field.confidence > 100) {
    throw new Error(`Invalid confidence for ${name}`);
  }
  if (!['OCR', 'Parser', 'LLM', 'User'].includes(field.source)) throw new Error(`Invalid source for ${name}`);
  if (typeof field.reviewed !== 'boolean') throw new Error(`Invalid reviewed flag for ${name}`);
}

export function validateExtraction(extraction: CanonicalInvoiceExtraction): CanonicalInvoiceExtraction {
  for (const [name, field] of Object.entries(extraction.header)) assertField(field, `header.${name}`);
  extraction.items.forEach((item, index) => {
    for (const [name, field] of Object.entries(item)) assertField(field, `items.${index}.${name}`);
    if (!item.description.value.trim()) throw new Error(`Item ${index + 1} requires a description`);
    if (!(item.quantity.value > 0)) throw new Error(`Item ${index + 1} requires a positive quantity`);
    if (item.unitPrice.value < 0 || item.lineTotal.value < 0) throw new Error(`Item ${index + 1} has a negative price`);
    const gross = item.quantity.value * item.unitPrice.value;
    const expected = item.discountPercent ? gross * (1 - item.discountPercent.value / 100) : gross;
    if (Math.abs(expected - item.lineTotal.value) > Math.max(0.02, expected * 0.01)) {
      item.lineTotal.confidence = Math.min(item.lineTotal.confidence, 60);
    }
  });
  const { invoiceDate, subtotal, tax, shipping, total } = extraction.header;
  if (invoiceDate.value && !/^\d{4}-\d{2}-\d{2}$/.test(invoiceDate.value)) throw new Error('Invoice date is invalid');
  for (const [name, field] of Object.entries({ subtotal, tax, shipping, total })) {
    if (field.value !== null && (!Number.isFinite(field.value) || field.value < 0)) throw new Error(`${name} must be a non-negative amount`);
  }
  const tolerance = 0.02;
  const itemSum = extraction.items.reduce((sum, item) => sum + item.lineTotal.value, 0);
  const lineItemsMatchSubtotal = subtotal.value === null || !extraction.items.length
    ? null : Math.abs(itemSum - subtotal.value) <= tolerance;
  const componentsMatchTotal = subtotal.value === null || total.value === null
    ? null : Math.abs(subtotal.value + (tax.value ?? 0) + (shipping.value ?? 0) - total.value) <= tolerance;
  extraction.reconciliation = {
    lineItemsMatchSubtotal,
    componentsMatchTotal,
    needsReview: lineItemsMatchSubtotal === false || componentsMatchTotal === false,
  };
  extraction.quality = assessExtractionQuality(extraction);
  return extraction;
}

export function assessExtractionQuality(extraction: CanonicalInvoiceExtraction): ExtractionQuality {
  const header = extraction.header;
  const meaningful = [header.vendor, header.invoiceNumber, header.invoiceDate, header.purchaseOrder,
    header.subtotal, header.tax, header.shipping, header.total]
    .filter((field) => field.value !== '' && field.value !== null && field.confidence >= 60);
  const core = [header.vendor, header.invoiceNumber, header.invoiceDate, header.total]
    .filter((field) => field.value !== '' && field.value !== null && field.confidence >= 70).length;
  const itemCount = extraction.items.length;
  const reasons: string[] = [];
  if (!itemCount) reasons.push('NO_LINE_ITEMS');
  if (core < 2) reasons.push('INSUFFICIENT_CORE_HEADERS');
  if (extraction.reconciliation?.needsReview) reasons.push('FINANCIAL_MISMATCH');
  let state: ExtractionQuality['state'];
  if (itemCount > 0 && core >= 3 && meaningful.length >= 5) state = 'STRUCTURED_SUCCESS';
  else if (itemCount > 0 || meaningful.length >= 3) state = 'STRUCTURED_PARTIAL';
  else state = 'MANUAL_REVIEW_REQUIRED';
  const score = Math.min(100, Math.round(core * 15 + Math.min(itemCount, 3) * 12 + meaningful.length * 4
    - (extraction.reconciliation?.needsReview ? 15 : 0)));
  return { state, score: Math.max(0, score), detectedHeaderFields: meaningful.length, detectedLineItems: itemCount, reasonCodes: reasons };
}
