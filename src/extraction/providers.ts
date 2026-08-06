import type { CanonicalInvoiceExtraction, OCRResult } from './types.ts';

export interface OCRProvider {
  readonly name: string;
  extractText(pdf: Uint8Array): Promise<OCRResult>;
}

export interface InvoiceExtractionProvider {
  readonly name: string;
  extractInvoice(ocrText: string): Promise<CanonicalInvoiceExtraction>;
}

export interface ExtractionProviders {
  ocr: OCRProvider;
  invoice: InvoiceExtractionProvider;
}
