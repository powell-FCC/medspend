import type { CanonicalInvoiceExtraction, ExtractedField } from './types.ts';

function assertField(field: ExtractedField<unknown>, name: string) {
  if (!field || typeof field !== 'object') throw new Error(`Missing extracted field: ${name}`);
  if (!Number.isFinite(field.confidence) || field.confidence < 0 || field.confidence > 100) {
    throw new Error(`Invalid confidence for ${name}`);
  }
  if (!['OCR', 'LLM', 'User'].includes(field.source)) throw new Error(`Invalid source for ${name}`);
  if (typeof field.reviewed !== 'boolean') throw new Error(`Invalid reviewed flag for ${name}`);
}

export function validateExtraction(extraction: CanonicalInvoiceExtraction): CanonicalInvoiceExtraction {
  for (const [name, field] of Object.entries(extraction.header)) assertField(field, `header.${name}`);
  extraction.items.forEach((item, index) => {
    for (const [name, field] of Object.entries(item)) assertField(field, `items.${index}.${name}`);
    if (!item.description.value.trim()) throw new Error(`Item ${index + 1} requires a description`);
    if (!(item.quantity.value > 0)) throw new Error(`Item ${index + 1} requires a positive quantity`);
    if (item.unitPrice.value < 0 || item.lineTotal.value < 0) throw new Error(`Item ${index + 1} has a negative price`);
  });
  return extraction;
}
