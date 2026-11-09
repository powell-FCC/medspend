// Phase 6C.4 packet helpers: per-page text, the existing parser on one segment, and the
// page-subset PDF a created invoice is stored as. No framework or path-alias imports, so the
// integration tests run exactly this code.
import { PDFDocument } from "pdf-lib";
import { DeterministicInvoiceExtractionProvider } from "../extraction/deterministic-invoice-provider.ts";
import { validateUsableDocumentText } from "../extraction/document-text-validation.ts";
import { EmbeddedPdfTextProvider } from "../extraction/embedded-pdf-text-provider.ts";
import { validateExtraction } from "../extraction/validation.ts";
import type { CanonicalInvoiceExtraction } from "../extraction/types.ts";

export const MAX_PACKET_PAGES = 500;

export type SegmentParseState =
  | "STRUCTURED_SUCCESS"
  | "STRUCTURED_PARTIAL"
  | "MANUAL_REVIEW_REQUIRED"
  | "STRUCTURED_FAILED"
  | "TEXT_UNAVAILABLE";

export interface SegmentParseSummary {
  state: SegmentParseState;
  itemCount: number;
  total: number | null;
  needsReview: boolean;
  invoiceNumber: string;
  extraction: CanonicalInvoiceExtraction | null;
}

/** unpdf transfers (detaches) the buffer it is given; every caller keeps its own copy. */
export async function readPacketPages(bytes: Uint8Array): Promise<string[]> {
  const { pages, pageCount } = await new EmbeddedPdfTextProvider().extractPages(bytes.slice());
  if (pages.length !== pageCount)
    throw new Error("The PDF page text could not be read consistently");
  return pages;
}

/**
 * The text the existing review path will extract from this segment's own PDF (the same pages,
 * joined the same way), run through the existing validation and parser. Used only to describe
 * the packet; the invoice draft itself is seeded later by the unchanged review path.
 */
export async function summarizeSegment(
  pages: string[],
  startPage: number,
  endPage: number,
): Promise<SegmentParseSummary> {
  const validation = validateUsableDocumentText(pages.slice(startPage - 1, endPage).join("\n\n"));
  if (!validation.usable)
    return {
      state: "TEXT_UNAVAILABLE",
      itemCount: 0,
      total: null,
      needsReview: true,
      invoiceNumber: "",
      extraction: null,
    };
  try {
    const extraction = validateExtraction(
      await new DeterministicInvoiceExtractionProvider().extractInvoice(validation.normalizedText),
    );
    const quality = extraction.quality!;
    return {
      state: quality.state,
      itemCount: extraction.items.length,
      total: extraction.header.total.value,
      needsReview:
        quality.state !== "STRUCTURED_SUCCESS" || Boolean(extraction.reconciliation?.needsReview),
      invoiceNumber: extraction.header.invoiceNumber.value,
      extraction,
    };
  } catch {
    return {
      state: "STRUCTURED_FAILED",
      itemCount: 0,
      total: null,
      needsReview: true,
      invoiceNumber: "",
      extraction: null,
    };
  }
}

export async function loadPacket(bytes: Uint8Array): Promise<PDFDocument> {
  return PDFDocument.load(bytes.slice(), { updateMetadata: false });
}

/** A standalone PDF of pages startPage..endPage (1-based, inclusive), in source order. */
export async function buildSegmentPdf(
  packet: PDFDocument,
  startPage: number,
  endPage: number,
): Promise<Uint8Array> {
  if (startPage < 1 || endPage < startPage || endPage > packet.getPageCount())
    throw new Error("Invalid page range");
  const output = await PDFDocument.create({ updateMetadata: false });
  const indices = Array.from(
    { length: endPage - startPage + 1 },
    (_, offset) => startPage - 1 + offset,
  );
  for (const page of await output.copyPages(packet, indices)) output.addPage(page);
  return output.save();
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes.slice());
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
