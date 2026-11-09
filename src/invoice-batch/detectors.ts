// Phase 6C.4 page-signal detectors. Each reads one page's printed identity signals; the generic
// grouping in segmentation.ts never knows which vendor it is looking at.
//
// Henry Schein is the first vendor-specific detector. Any other vendor uses the generic detector
// (explicit "Invoice #/No./Number" labels and "Page i of N"). Adding a vendor means adding a
// detector here, not changing batch intake.
import { normalizeDocumentText } from "../extraction/document-text-validation.ts";
import {
  HENRY_SCHEIN_VENDOR_NAME,
  henryScheinInvoiceNumbers,
} from "../extraction/layouts/henry-schein-invoice.ts";
import {
  groupPages,
  type PacketSegmentation,
  type PageOf,
  type PageSignals,
} from "./segmentation.ts";

export interface PageSignalDetector {
  readonly name: string;
  readonly vendorName: string | null;
  readonly vendorKey: string | null;
  /** Whether this detector should read the packet (a packet-level decision, made once). */
  recognizes(pages: string[]): boolean;
  read(text: string, page: number): PageSignals;
}

const lines = (text: string) => normalizeDocumentText(text).split("\n").filter(Boolean);
const INVOICE_VOCABULARY = /\binvoice\b|\bsubtotal\b|\bamount\s+due\b|\bunit\s+price\b/i;
const normalizeNumber = (value: string) => value.toUpperCase().replace(/[^A-Z0-9-]/g, "");

export function readPageOf(text: string): PageOf | null {
  const matches = [...text.matchAll(/\bpage\s+(\d{1,3})\s+of\s+(\d{1,3})(?!\d)/gi)]
    .map((match) => ({ index: Number(match[1]), count: Number(match[2]) }))
    .filter((value) => value.index >= 1 && value.count >= value.index);
  const distinct = new Map(matches.map((value) => [`${value.index}/${value.count}`, value]));
  // Two different page markers on one page are not a page number at all.
  return distinct.size === 1 ? [...distinct.values()][0] : null;
}

const HENRY_SCHEIN_PAGE =
  /please\s+remit\s+payments\s+to:\s*henry\s+schein|henryschein\.com|\bHSI\s+Federal\s+ID#/i;

export const henryScheinDetector: PageSignalDetector = {
  name: "henry-schein-invoice-v1",
  vendorName: HENRY_SCHEIN_VENDOR_NAME,
  vendorKey: "henry-schein",
  recognizes(pages) {
    const identified = pages.filter((page) => HENRY_SCHEIN_PAGE.test(page)).length;
    return identified > 0 && identified * 2 >= pages.length;
  },
  read(text, page) {
    const pageLines = lines(text);
    const identities = henryScheinInvoiceNumbers(pageLines);
    const numbers = [...new Set(identities.map((identity) => normalizeNumber(identity.value)))];
    const account = text.match(/\bBill-To:\s*(\d{4,})/i)?.[1] ?? null;
    return {
      page,
      hasText: pageLines.length > 0,
      invoiceNumbers: numbers,
      pageOf: readPageOf(text),
      invoiceDate: identities.find((identity) => identity.date)?.date || null,
      accountKey: account,
      invoiceMarkers: INVOICE_VOCABULARY.test(text),
    };
  },
};

const GENERIC_SAME_LINE =
  /\b(?:invoice|inv)\s*(?:#|no\.?|number)\s*[:#-]?\s*([A-Z0-9][A-Z0-9-]{2,24})\b/gi;
const GENERIC_LABEL_ALONE = /^(?:invoice|inv)\s*(?:#|no\.?|number)\s*[:#-]?$/i;

export const genericDetector: PageSignalDetector = {
  name: "generic-invoice-v1",
  vendorName: null,
  vendorKey: null,
  recognizes: () => true,
  read(text, page) {
    const pageLines = lines(text);
    const numbers = new Set<string>();
    for (const line of pageLines) {
      for (const match of line.matchAll(GENERIC_SAME_LINE)) {
        // "Invoice Number Invoice Date" style headings are labels, not values.
        if (/^(?:date|total|amount|number|no)$/i.test(match[1])) continue;
        if (/\d/.test(match[1])) numbers.add(normalizeNumber(match[1]));
      }
    }
    pageLines.forEach((line, index) => {
      if (!GENERIC_LABEL_ALONE.test(line)) return;
      const value = pageLines[index + 1]?.match(/^([A-Z0-9][A-Z0-9-]{2,24})\b/i)?.[1];
      if (value && /\d/.test(value)) numbers.add(normalizeNumber(value));
    });
    return {
      page,
      hasText: pageLines.length > 0,
      invoiceNumbers: [...numbers],
      pageOf: readPageOf(text),
      invoiceDate: null,
      accountKey: null,
      invoiceMarkers: INVOICE_VOCABULARY.test(text),
    };
  },
};

export const PAGE_SIGNAL_DETECTORS: PageSignalDetector[] = [henryScheinDetector, genericDetector];

export function chooseDetector(
  pages: string[],
  detectors = PAGE_SIGNAL_DETECTORS,
): PageSignalDetector {
  return detectors.find((detector) => detector.recognizes(pages)) ?? genericDetector;
}

/** One packet's page texts (index 0 = page 1) → its deterministic segmentation. */
export function segmentInvoicePacket(
  pages: string[],
  detectors = PAGE_SIGNAL_DETECTORS,
): PacketSegmentation {
  if (!pages.length) throw new Error("The PDF has no pages");
  const detector = chooseDetector(pages, detectors);
  const signals = pages.map((text, index) => detector.read(text, index + 1));
  return groupPages(signals, {
    detector: detector.name,
    vendorName: detector.vendorName,
    vendorKey: detector.vendorKey,
  });
}
