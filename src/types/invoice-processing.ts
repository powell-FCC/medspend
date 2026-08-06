export type ProcessingStatus = 'uploaded' | 'processing' | 'review_required' | 'completed' | 'failed';
export type InvoiceItemReviewStatus = 'pending_review' | 'approved' | 'rejected' | 'manual';

export interface ReviewItem {
  id: string;
  invoiceId: string;
  lineNumber: number | null;
  sku: string;
  description: string;
  manufacturer: string;
  category: string;
  quantity: number;
  unitOfMeasure: string;
  unitPrice: number;
  totalPrice: number;
  packageSize: string;
  vendorProductId: string | null;
  reviewStatus: InvoiceItemReviewStatus;
  extractionConfidence?: number;
}

export interface InvoiceReviewHeader {
  invoiceId: string;
  sourceFileId: string;
  organizationId: string;
  originalFilename: string;
  uploadedAt: string;
  vendorId: string | null;
  vendorName: string;
  invoiceNumber: string;
  invoiceDate: string;
  invoiceTotal: number | null;
  purchaseOrder: string;
  subtotal: number | null;
  tax: number | null;
  shipping: number | null;
  status: ProcessingStatus;
  extractionStatus: 'not_started' | 'processing' | 'succeeded' | 'failed';
  extractionError: string | null;
  extractionConfidence?: Record<string, number>;
  documentTextStatus: 'pending' | 'success' | 'ocr_required' | 'failed';
  documentTextProvider: string | null;
  documentPageCount: number | null;
  documentProcessingDurationMs: number | null;
}

export interface InvoiceReviewVendor {
  id: string;
  name: string;
}

export interface InvoiceReviewVendorProduct {
  id: string;
  vendorId: string;
  vendorName: string;
  productName: string;
  vendorSku: string;
  manufacturerSku: string;
  packageSize: string;
  unitOfMeasure: string;
}

export interface InvoiceReview {
  header: InvoiceReviewHeader;
  items: ReviewItem[];
  categories: string[];
  vendors: InvoiceReviewVendor[];
  vendorProducts: InvoiceReviewVendorProduct[];
}

export interface InvoiceHeaderInput {
  organizationId: string;
  sourceFileId: string;
  vendorId?: string | null;
  vendorName: string;
  invoiceNumber: string;
  invoiceDate: string;
  invoiceTotal: number | null;
  purchaseOrder: string;
  subtotal: number | null;
  tax: number | null;
  shipping: number | null;
}

export interface InvoiceItemInput {
  id?: string;
  organizationId: string;
  sourceFileId: string;
  sku: string;
  description: string;
  manufacturer: string;
  category: string;
  quantity: number;
  unitOfMeasure: string;
  unitPrice: number;
  totalPrice: number;
  packageSize: string;
  vendorProductId?: string | null;
}

export interface InvoiceApprovalResult {
  invoiceId: string;
  createdInventoryItems: number;
  updatedInventoryItems: number;
  alreadyCompleted: boolean;
}
