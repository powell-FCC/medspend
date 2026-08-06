import type { ProcessingStatus } from './invoice-processing';

export interface InvoiceHistoryRow {
  vendorInvoiceId: string; filename: string; vendor: string | null; uploadedAt: string;
  status: ProcessingStatus; itemsProcessed: number; fileSize: number; storagePath: string;
}

export interface PurchaseHistoryRow {
  invoiceId: string; date: string | null; vendor: string; invoiceNumber: string | null;
  itemCount: number; total: number | null;
}

export interface VendorHistoryRow { vendorName: string; invoiceCount: number; lastPurchaseDate: string | null }
