import type { ProcessingStatus } from './invoice-processing';
import type { InvoiceDeletionEligibility, InvoiceDocumentType } from '@/invoice/deletion';

export interface InvoiceHistoryRow {
  vendorInvoiceId: string; filename: string; vendor: string | null; uploadedAt: string;
  status: ProcessingStatus; itemsProcessed: number; fileSize: number; storagePath: string;
  documentType: InvoiceDocumentType; documentNumber: string | null; documentDate: string | null;
  total: number | null; posted: boolean;
  /** Phase 7E: the posting time the removal must confirm, and the text the owner types. */
  postedAt: string | null; removalConfirmation: string;
  deletionEligibility: InvoiceDeletionEligibility;
}

export interface DeleteInvoiceResult { deleted: true; storageDeleted: boolean; warning: string | null }

export interface RemovePostedDocumentResult { removed: true; removalId: string; sourceFileRetained: true }

export interface PurchaseHistoryRow {
  invoiceId: string; date: string | null; vendor: string; invoiceNumber: string | null;
  itemCount: number; total: number | null;
}

export interface VendorHistoryRow { vendorName: string; invoiceCount: number; lastPurchaseDate: string | null }
