export type ExtractionSource = 'OCR' | 'LLM' | 'User';

export interface ExtractedField<T> {
  value: T;
  confidence: number;
  source: ExtractionSource;
  reviewed: boolean;
}

export interface ExtractedInvoiceHeader {
  vendor: ExtractedField<string>;
  invoiceNumber: ExtractedField<string>;
  invoiceDate: ExtractedField<string>;
  purchaseOrder: ExtractedField<string>;
  subtotal: ExtractedField<number | null>;
  tax: ExtractedField<number | null>;
  shipping: ExtractedField<number | null>;
  total: ExtractedField<number | null>;
}

export interface ExtractedInvoiceItem {
  sku: ExtractedField<string>;
  description: ExtractedField<string>;
  manufacturer: ExtractedField<string>;
  quantity: ExtractedField<number>;
  unit: ExtractedField<string>;
  unitPrice: ExtractedField<number>;
  lineTotal: ExtractedField<number>;
  suggestedCategory: ExtractedField<string>;
}

export interface CanonicalInvoiceExtraction {
  header: ExtractedInvoiceHeader;
  items: ExtractedInvoiceItem[];
}

export interface OCRResult {
  text: string;
  provider: string;
  pageCount?: number;
}

export type DocumentTextStatus = 'pending' | 'success' | 'ocr_required' | 'failed';

export interface DocumentTextExtractionResult extends OCRResult {
  durationMs: number;
  status: Exclude<DocumentTextStatus, 'pending' | 'failed'>;
  ocrRequired: boolean;
}
