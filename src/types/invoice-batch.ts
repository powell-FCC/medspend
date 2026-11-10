import type { VendorInvoice } from "./vendor-invoice.ts";

export type InvoiceBatchSegmentKind = "invoice" | "unresolved" | "non_invoice";
export type InvoiceBatchSegmentStatus =
  | "pending"
  | "created"
  | "duplicate"
  | "failed"
  | "held"
  | "ignored";

export interface InvoiceBatchSegment {
  id: string;
  index: number;
  kind: InvoiceBatchSegmentKind;
  status: InvoiceBatchSegmentStatus;
  pageStart: number;
  pageEnd: number;
  invoiceNumber: string | null;
  invoiceDate: string | null;
  reasons: string[];
  duplicateOfIndex: number | null;
  duplicateOfSourceFileId: string | null;
  parseState: string | null;
  parsedItemCount: number | null;
  parsedTotal: number | null;
  parseNeedsReview: boolean;
  error: string | null;
  sourceFileId: string | null;
  invoice: { processingStatus: string; itemCount: number; total: number | null } | null;
}

export interface InvoiceBatch {
  id: string;
  originalFilename: string;
  storagePath: string;
  fileSize: number;
  pageCount: number;
  detector: string;
  vendorName: string | null;
  createdAt: string;
  segments: InvoiceBatchSegment[];
}

export interface InvoiceBatchListEntry {
  id: string;
  originalFilename: string;
  pageCount: number;
  createdAt: string;
  invoiceCount: number;
  createdCount: number;
  attentionCount: number;
}

export interface InvoiceProvenance {
  batchId: string;
  originalFilename: string;
  packetPageCount: number;
  pageStart: number;
  pageEnd: number;
  segmentIndex: number;
}

export interface InvoiceIntakeTimings {
  textMs: number;
  segmentationMs: number;
  parsingMs: number;
  totalMs: number;
}

export type InvoiceIntakeResult =
  | { kind: "single"; invoice: VendorInvoice }
  | {
      kind: "batch";
      batchId: string;
      existing: boolean;
      pageCount: number;
      invoiceCount: number;
      timings: InvoiceIntakeTimings;
    };
