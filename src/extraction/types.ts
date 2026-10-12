// 'Derived' marks an amount calculated from other extracted values (never read from the document).
export type ExtractionSource = 'OCR' | 'Parser' | 'LLM' | 'User' | 'Derived';
import type { DocumentType, VendorEvidence } from './document-identity.ts';

export interface ExtractedField<T> {
  value: T;
  confidence: number;
  source: ExtractionSource;
  reviewed: boolean;
}

export interface ExtractedInvoiceHeader {
  documentType?: ExtractedField<DocumentType>;
  vendor: ExtractedField<string>;
  invoiceNumber: ExtractedField<string>;
  invoiceDate: ExtractedField<string>;
  orderNumber?: ExtractedField<string>;
  orderDate?: ExtractedField<string>;
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
  discountPercent?: ExtractedField<number>;
}

export interface ExtractionReconciliation {
  lineItemsMatchSubtotal: boolean | null;
  componentsMatchTotal: boolean | null;
  needsReview: boolean;
}

// What a provider saw in the document that its extracted fields do not account for. Totals are
// only derived without a corroborating document total when both counts are zero.
export interface ExtractionFinancialEvidence {
  rejectedLineCandidates: number;
  unexplainedAmounts: number;
}

export type StructuredExtractionState = 'STRUCTURED_SUCCESS' | 'STRUCTURED_PARTIAL' | 'MANUAL_REVIEW_REQUIRED' | 'STRUCTURED_FAILED';

export interface ExtractionQuality {
  state: StructuredExtractionState;
  score: number;
  detectedHeaderFields: number;
  detectedLineItems: number;
  reasonCodes: string[];
}

export interface CanonicalInvoiceExtraction {
  header: ExtractedInvoiceHeader;
  vendorEvidence?: VendorEvidence[];
  items: ExtractedInvoiceItem[];
  financialEvidence?: ExtractionFinancialEvidence;
  reconciliation?: ExtractionReconciliation;
  quality?: ExtractionQuality;
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
