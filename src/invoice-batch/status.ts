// Phase 6C.4: what an owner sees for each part of an uploaded packet.
import type { InvoiceBatch, InvoiceBatchSegment } from "../types/invoice-batch.ts";

export type BatchRowStatus =
  | "ready"
  | "needs_review"
  | "parsing_failed"
  | "duplicate"
  | "segmentation_issue"
  | "preparing"
  | "failed"
  | "posted"
  | "removed"
  | "not_invoice";

export const BATCH_ROW_LABEL: Record<BatchRowStatus, string> = {
  ready: "Ready for review",
  needs_review: "Needs review",
  parsing_failed: "Parsing failed",
  duplicate: "Duplicate",
  segmentation_issue: "Segmentation issue",
  preparing: "Preparing",
  failed: "Couldn't prepare",
  posted: "Posted",
  removed: "Removed",
  not_invoice: "Not an invoice",
};

export function batchRowStatus(segment: InvoiceBatchSegment): BatchRowStatus {
  switch (segment.status) {
    case "ignored":
      return "not_invoice";
    case "held":
      return "segmentation_issue";
    case "duplicate":
      return "duplicate";
    case "pending":
      return "preparing";
    case "failed":
      return "failed";
    case "created":
      if (!segment.sourceFileId) return "removed";
      if (segment.invoice?.processingStatus === "completed") return "posted";
      if (segment.parseState === "STRUCTURED_FAILED" || segment.parseState === "TEXT_UNAVAILABLE")
        return "parsing_failed";
      if (segment.parseNeedsReview || segment.kind !== "invoice") return "needs_review";
      return "ready";
  }
}

const REASON_TEXT: Record<string, string> = {
  MISSING_FIRST_PAGE: "The first page of this invoice is not in the file.",
  INCOMPLETE_PAGE_SEQUENCE: "Some pages of this invoice are missing.",
  PAGE_SEQUENCE_IRREGULAR: "The page numbers are out of sequence.",
  CONFLICTING_INVOICE_NUMBERS: "The page shows more than one invoice number.",
  NO_INVOICE_NUMBER: "No invoice number was found on this page.",
  NO_TEXT: "This page has no readable text (it may be a scan).",
  HEADER_MISMATCH: "The pages disagree on the invoice date or account.",
  DUPLICATE_IN_PACKET: "The same invoice appears earlier in this file.",
};

export const reasonText = (reason: string) => REASON_TEXT[reason] ?? reason;

export const pageRangeLabel = (segment: Pick<InvoiceBatchSegment, "pageStart" | "pageEnd">) =>
  segment.pageStart === segment.pageEnd
    ? `Page ${segment.pageStart}`
    : `Pages ${segment.pageStart}–${segment.pageEnd}`;

export function batchCounts(batch: InvoiceBatch) {
  const counts = Object.fromEntries(Object.keys(BATCH_ROW_LABEL).map((key) => [key, 0])) as Record<
    BatchRowStatus,
    number
  >;
  for (const segment of batch.segments) counts[batchRowStatus(segment)]++;
  return {
    invoices: batch.segments.filter((segment) => segment.kind === "invoice").length,
    pending: batch.segments.filter((segment) => segment.status === "pending").length,
    byStatus: counts,
  };
}
