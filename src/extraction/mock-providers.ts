import type { InvoiceExtractionProvider, OCRProvider } from './providers.ts';
import type { CanonicalInvoiceExtraction, ExtractedField } from './types.ts';

const field = <T>(value: T, confidence: number, source: 'OCR' | 'LLM' = 'OCR'): ExtractedField<T> =>
  ({ value, confidence, source, reviewed: false });

export const HENRY_SCHEIN_MOCK_EXTRACTION: CanonicalInvoiceExtraction = {
  header: {
    vendor: field('Henry Schein, Inc.', 99),
    invoiceNumber: field('HS-84729163', 97),
    invoiceDate: field('2026-07-29', 96),
    purchaseOrder: field('PO-10482', 82),
    subtotal: field(456.34, 98),
    tax: field(32.47, 91),
    shipping: field(12.5, 68),
    total: field(501.31, 99),
  },
  items: [
    { sku: field('112-7307', 98), description: field('Criterion Nitrile Exam Gloves, Medium, Box/100', 97), manufacturer: field('Henry Schein', 88), quantity: field(4, 99), unit: field('box', 96), unitPrice: field(18.75, 98), lineTotal: field(75, 99), suggestedCategory: field('PPE', 78, 'LLM') },
    { sku: field('570-1500', 97), description: field('Sterile Gauze Sponges 4 x 4, 12-Ply, Case/1200', 95), manufacturer: field('Cardinal Health', 84), quantity: field(2, 99), unit: field('case', 94), unitPrice: field(96.42, 98), lineTotal: field(192.84, 99), suggestedCategory: field('Wound Care', 74, 'LLM') },
    { sku: field('900-4682', 96), description: field('Disposable Prophy Angles, Soft Cup, Box/100', 93), manufacturer: field('Pac-Dent', 72), quantity: field(3, 98), unit: field('box', 90), unitPrice: field(62.5, 97), lineTotal: field(187.5, 98), suggestedCategory: field('Dental Supplies', 69, 'LLM') },
    { sku: field('100-9867', 91), description: field('Surface Disinfectant Wipes, 160 Count', 90), manufacturer: field('CaviCide', 63), quantity: field(1, 99), unit: field('canister', 87), unitPrice: field(1, 45), lineTotal: field(1, 45), suggestedCategory: field('Infection Control', 71, 'LLM') },
  ],
  reconciliation: { lineItemsMatchSubtotal: true, componentsMatchTotal: true, needsReview: false },
  quality: { state: 'STRUCTURED_SUCCESS', score: 100, detectedHeaderFields: 8, detectedLineItems: 4, reasonCodes: [] },
};

export class MockOCRProvider implements OCRProvider {
  readonly name = 'mock-ocr';
  async extractText(_pdf: Uint8Array) {
    return { provider: this.name, text: 'MOCK HENRY SCHEIN INVOICE HS-84729163' };
  }
}

export class MockInvoiceExtractionProvider implements InvoiceExtractionProvider {
  readonly name = 'mock-invoice-extraction';
  async extractInvoice(_ocrText: string): Promise<CanonicalInvoiceExtraction> {
    return structuredClone(HENRY_SCHEIN_MOCK_EXTRACTION);
  }
}
