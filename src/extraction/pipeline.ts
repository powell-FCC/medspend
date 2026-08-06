import { MockInvoiceExtractionProvider, MockOCRProvider } from './mock-providers.ts';
import type { ExtractionProviders, OCRProvider } from './providers.ts';
import type { CanonicalInvoiceExtraction, DocumentTextExtractionResult } from './types.ts';
import { validateExtraction } from './validation.ts';
import { validateUsableDocumentText } from './document-text-validation.ts';

export interface ExtractionPipelineResult {
  extraction: CanonicalInvoiceExtraction;
  ocrProvider: string;
  invoiceProvider: string;
}

export async function runExtractionPipeline(pdf: Uint8Array, providers: ExtractionProviders): Promise<ExtractionPipelineResult> {
  const ocr = await providers.ocr.extractText(pdf);
  const extraction = validateExtraction(await providers.invoice.extractInvoice(ocr.text));
  return { extraction, ocrProvider: ocr.provider, invoiceProvider: providers.invoice.name };
}

export function getExtractionProviders(enableMockInvoiceExtraction = false): ExtractionProviders | null {
  if (!enableMockInvoiceExtraction) return null;
  return { ocr: new MockOCRProvider(), invoice: new MockInvoiceExtractionProvider() };
}

export async function runDocumentTextExtraction(pdf: Uint8Array, provider: OCRProvider): Promise<DocumentTextExtractionResult> {
  const startedAt = performance.now();
  const result = await provider.extractText(pdf);
  const validation = validateUsableDocumentText(result.text);
  return {
    provider: result.provider,
    pageCount: result.pageCount,
    durationMs: Math.max(0, Math.round(performance.now() - startedAt)),
    status: validation.usable ? 'success' : 'ocr_required',
    ocrRequired: !validation.usable,
    text: validation.normalizedText,
  };
}
