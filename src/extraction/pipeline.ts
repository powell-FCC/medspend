import { MockInvoiceExtractionProvider, MockOCRProvider } from './mock-providers.ts';
import type { ExtractionProviders } from './providers.ts';
import type { CanonicalInvoiceExtraction } from './types.ts';
import { validateExtraction } from './validation.ts';

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
