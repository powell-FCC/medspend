import type { InvoiceLineMatchSource } from '@/invoice/line-match';

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
  productId: string | null;
  productMatch: {
    state: 'EXACT' | 'SUGGESTED' | 'UNRESOLVED' | 'CONFIRMED';
    productId: string | null;
    productName: string;
    score?: number;
    reasons: string[];
  };
  matchSource: InvoiceLineMatchSource | null;
  // The line's current vendor SKU mapping came from catalog adoption; re-matching the line
  // to another product never changes that mapping.
  skuFromCatalog: boolean;
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
  vendorMatchState: 'MATCHED' | 'SUGGESTED' | 'UNRESOLVED' | 'CONFIRMED';
  suggestedVendorId: string | null;
  suggestedVendorName: string;
  documentType: 'INVOICE' | 'ORDER_CONFIRMATION' | 'PURCHASE_ORDER' | 'CREDIT_MEMO' | 'STATEMENT' | 'UNKNOWN';
  orderNumber: string;
  orderDate: string;
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
  // Amounts calculated from other fields rather than read from the document (not yet reviewed).
  derivedTotals: Array<'subtotal' | 'total'>;
  totalsNeedReview: boolean;
  structuredExtractionState: 'STRUCTURED_SUCCESS' | 'STRUCTURED_PARTIAL' | 'MANUAL_REVIEW_REQUIRED' | 'STRUCTURED_FAILED' | null;
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

export interface InvoiceReviewProduct {
  id: string;
  name: string;
  description: string;
  manufacturer: string;
  internalItemCode: string;
  vendorItemNumber: string;
  // SKUs this organization has mapped to the product for the invoice's vendor.
  vendorSkus: string[];
  unitOfMeasure: string;
  packSize: string;
}

export interface InvoiceCatalogListing {
  catalogVendorProductId: string;
  vendorSku: string;
  name: string;
  manufacturer: string;
  packageDescription: string;
  verified: boolean;
  // Set when this organization already has a product for the listing's catalog product.
  organizationProductId: string | null;
}

export type InvoiceCatalogUnavailableReason = 'no_vendor' | 'vendor_unavailable' | 'vendor_not_linked_to_catalog' | 'catalog_vendor_inactive';

export interface InvoiceCatalogSearch {
  available: boolean;
  reason: InvoiceCatalogUnavailableReason | null;
  catalogVendorName: string;
  results: InvoiceCatalogListing[];
}

export interface InvoiceReview {
  header: InvoiceReviewHeader;
  items: ReviewItem[];
  categories: string[];
  vendors: InvoiceReviewVendor[];
  vendorProducts: InvoiceReviewVendorProduct[];
  products: InvoiceReviewProduct[];
}

export interface InvoiceHeaderInput {
  organizationId: string;
  sourceFileId: string;
  vendorId?: string | null;
  vendorName: string;
  documentType: InvoiceReviewHeader['documentType'];
  orderNumber: string;
  orderDate: string;
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

export interface InvoiceMatchResult {
  productId: string;
  vendorProductId: string | null;
  vendorSkuRemembered: boolean;
  // Set when the line's vendor SKU is a catalog-adopted mapping for another product, which
  // was left unchanged: this match applies to this invoice only.
  preservedMapping: { vendorSku: string; productName: string } | null;
}

export interface InvoiceApprovalResult {
  invoiceId: string;
  createdInventoryItems: number;
  updatedInventoryItems: number;
  alreadyCompleted: boolean;
}
