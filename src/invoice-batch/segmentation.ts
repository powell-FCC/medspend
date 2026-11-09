// Phase 6C.4: deterministic segmentation of an uploaded PDF packet into logical invoices.
//
// Vendor-agnostic. A page-signal detector (see detectors.ts) reads each page's identity
// signals; this module only groups pages. No page is ever dropped, reordered or assigned twice:
// segments are contiguous, in source order, and together cover every page exactly once
// (assertPageAllocation proves it for every result).
//
// Rules, strongest first:
//   1. A different invoice number always starts a new invoice. Purchase order, order number,
//      account and products are never grouping signals.
//   2. "Page 1 of N" always starts a new invoice. With the same invoice number it is a repeated
//      copy: reported as a duplicate of the first, never merged into it.
//   3. A page without an invoice number joins the current invoice only as its exact next
//      "Page i of N"; otherwise it is an explicit unresolved page.
//   4. Repeated vendor/customer headers alone never start an invoice.
// Anything irregular (missing first page, gaps, page-count conflicts, header conflicts) is kept
// as a segment with reasons, never silently resolved.

export interface PageOf {
  index: number;
  count: number;
}

export interface PageSignals {
  /** 1-based page number in the source PDF. */
  page: number;
  hasText: boolean;
  /** Distinct invoice numbers printed on the page, normalized (upper case, no spaces). */
  invoiceNumbers: string[];
  pageOf: PageOf | null;
  /** ISO date, when printed. */
  invoiceDate: string | null;
  /** Customer/account identity printed on the page (validation only, never grouping). */
  accountKey: string | null;
  /** Any invoice vocabulary on the page at all. */
  invoiceMarkers: boolean;
}

export type SegmentKind = "invoice" | "unresolved" | "non_invoice";

export type SegmentReason =
  | "MISSING_FIRST_PAGE"
  | "INCOMPLETE_PAGE_SEQUENCE"
  | "PAGE_SEQUENCE_IRREGULAR"
  | "CONFLICTING_INVOICE_NUMBERS"
  | "NO_INVOICE_NUMBER"
  | "NO_TEXT"
  | "HEADER_MISMATCH"
  | "DUPLICATE_IN_PACKET";

export interface PacketSegment {
  /** 1-based, in source order. */
  index: number;
  kind: SegmentKind;
  startPage: number;
  endPage: number;
  invoiceNumber: string | null;
  invoiceDate: string | null;
  reasons: SegmentReason[];
  /** For DUPLICATE_IN_PACKET: the index of the first segment with the same identity. */
  duplicateOfIndex: number | null;
}

export interface PacketSegmentation {
  pageCount: number;
  detector: string;
  vendorName: string | null;
  vendorKey: string | null;
  segments: PacketSegment[];
}

interface OpenSegment {
  startPage: number;
  endPage: number;
  invoiceNumber: string;
  invoiceDate: string | null;
  accountKey: string | null;
  expectedCount: number | null;
  lastIndex: number | null;
  numberedPages: number;
  reasons: Set<SegmentReason>;
}

const addReason = (reasons: SegmentReason[], reason: SegmentReason) => {
  if (!reasons.includes(reason)) reasons.push(reason);
};

/** The identity two segments must share to be the same invoice: vendor + invoice number. */
export function invoiceIdentityKey(
  vendorKey: string | null,
  invoiceNumber: string | null,
): string | null {
  const number = (invoiceNumber ?? "").toUpperCase().replace(/[^A-Z0-9]/g, "");
  if (!number) return null;
  return `${(vendorKey ?? "unknown").toLowerCase()}:${number}`;
}

export function groupPages(
  signals: PageSignals[],
  meta: { detector: string; vendorName: string | null; vendorKey: string | null },
): PacketSegmentation {
  const segments: PacketSegment[] = [];
  let current: OpenSegment | null = null;

  const push = (segment: Omit<PacketSegment, "index" | "duplicateOfIndex">) => {
    const previous = segments.at(-1);
    // Consecutive unresolved (or non-invoice) pages form one explicit range.
    if (
      previous &&
      segment.kind !== "invoice" &&
      previous.kind === segment.kind &&
      previous.endPage === segment.startPage - 1
    ) {
      previous.endPage = segment.endPage;
      for (const reason of segment.reasons) addReason(previous.reasons, reason);
      return;
    }
    segments.push({ ...segment, index: segments.length + 1, duplicateOfIndex: null });
  };
  const close = () => {
    if (!current) return;
    const reasons = [...current.reasons];
    if (
      current.expectedCount !== null &&
      current.endPage - current.startPage + 1 !== current.expectedCount &&
      !reasons.includes("PAGE_SEQUENCE_IRREGULAR")
    )
      addReason(reasons, "INCOMPLETE_PAGE_SEQUENCE");
    push({
      kind: "invoice",
      startPage: current.startPage,
      endPage: current.endPage,
      invoiceNumber: current.invoiceNumber,
      invoiceDate: current.invoiceDate,
      reasons,
    });
    current = null;
  };
  for (const page of signals) {
    if (!page.hasText) {
      close();
      push({
        kind: "unresolved",
        startPage: page.page,
        endPage: page.page,
        invoiceNumber: null,
        invoiceDate: null,
        reasons: ["NO_TEXT"],
      });
      continue;
    }
    if (page.invoiceNumbers.length > 1) {
      close();
      push({
        kind: "unresolved",
        startPage: page.page,
        endPage: page.page,
        invoiceNumber: null,
        invoiceDate: null,
        reasons: ["CONFLICTING_INVOICE_NUMBERS"],
      });
      continue;
    }
    const number = page.invoiceNumbers[0] ?? null;
    if (number === null) {
      const open = current as OpenSegment | null;
      const continuation =
        open &&
        page.pageOf &&
        open.lastIndex !== null &&
        page.pageOf.index === open.lastIndex + 1 &&
        page.pageOf.count === open.expectedCount;
      if (open && continuation) {
        open.endPage = page.page;
        open.lastIndex = page.pageOf!.index;
        open.numberedPages++;
        continue;
      }
      close();
      if (!page.invoiceMarkers && !page.pageOf) {
        push({
          kind: "non_invoice",
          startPage: page.page,
          endPage: page.page,
          invoiceNumber: null,
          invoiceDate: null,
          reasons: [],
        });
      } else {
        push({
          kind: "unresolved",
          startPage: page.page,
          endPage: page.page,
          invoiceNumber: null,
          invoiceDate: null,
          reasons: ["NO_INVOICE_NUMBER"],
        });
      }
      continue;
    }

    const open = current as OpenSegment | null;
    const restart = page.pageOf?.index === 1;
    if (open && open.invoiceNumber === number && !restart) {
      // Same invoice continues.
      if (page.pageOf) {
        if (
          open.lastIndex === null ||
          page.pageOf.index !== open.lastIndex + 1 ||
          page.pageOf.count !== open.expectedCount
        ) {
          open.reasons.add("PAGE_SEQUENCE_IRREGULAR");
        }
        open.lastIndex = page.pageOf.index;
        open.numberedPages++;
      } else if (open.expectedCount !== null) {
        open.reasons.add("PAGE_SEQUENCE_IRREGULAR");
      }
      if (
        (page.invoiceDate && open.invoiceDate && page.invoiceDate !== open.invoiceDate) ||
        (page.accountKey && open.accountKey && page.accountKey !== open.accountKey)
      )
        open.reasons.add("HEADER_MISMATCH");
      open.invoiceDate ??= page.invoiceDate;
      open.accountKey ??= page.accountKey;
      open.endPage = page.page;
      continue;
    }

    close();
    current = {
      startPage: page.page,
      endPage: page.page,
      invoiceNumber: number,
      invoiceDate: page.invoiceDate,
      accountKey: page.accountKey,
      expectedCount: page.pageOf?.count ?? null,
      lastIndex: page.pageOf?.index ?? null,
      numberedPages: page.pageOf ? 1 : 0,
      reasons: new Set(page.pageOf && page.pageOf.index !== 1 ? ["MISSING_FIRST_PAGE"] : []),
    };
  }
  close();

  // The same vendor + invoice number twice in one packet is one invoice: a later copy that starts
  // at its first page is a duplicate and is never created. A fragment that starts mid-invoice is
  // already held (MISSING_FIRST_PAGE) and is not called a copy.
  const seen = new Map<string, number>();
  for (const segment of segments) {
    if (segment.kind !== "invoice" || segment.reasons.includes("MISSING_FIRST_PAGE")) continue;
    const key = invoiceIdentityKey(meta.vendorKey, segment.invoiceNumber);
    if (!key) continue;
    const first = seen.get(key);
    if (first === undefined) seen.set(key, segment.index);
    else {
      addReason(segment.reasons, "DUPLICATE_IN_PACKET");
      segment.duplicateOfIndex = first;
    }
  }

  const result: PacketSegmentation = {
    pageCount: signals.length,
    detector: meta.detector,
    vendorName: meta.vendorName,
    vendorKey: meta.vendorKey,
    segments,
  };
  assertPageAllocation(result);
  return result;
}

/**
 * Every source page resolves to exactly one segment (an invoice, an explicit non-invoice page,
 * or an explicit unresolved page), in source order: never dropped, never assigned twice.
 */
export function assertPageAllocation(
  segmentation: Pick<PacketSegmentation, "pageCount" | "segments">,
): void {
  const owner = new Array<number>(segmentation.pageCount + 1).fill(0);
  let expectedStart = 1;
  segmentation.segments.forEach((segment, position) => {
    if (segment.index !== position + 1) throw new Error(`Segment ${position + 1} is out of order`);
    if (
      !Number.isInteger(segment.startPage) ||
      !Number.isInteger(segment.endPage) ||
      segment.startPage > segment.endPage
    ) {
      throw new Error(`Segment ${segment.index} has an invalid page range`);
    }
    if (segment.startPage !== expectedStart)
      throw new Error(
        `Page ${expectedStart} is not assigned in order (segment ${segment.index} starts at ${segment.startPage})`,
      );
    for (let page = segment.startPage; page <= segment.endPage; page++) {
      if (page < 1 || page > segmentation.pageCount)
        throw new Error(`Segment ${segment.index} references page ${page} outside the document`);
      if (owner[page])
        throw new Error(`Page ${page} is assigned to segments ${owner[page]} and ${segment.index}`);
      owner[page] = segment.index;
    }
    expectedStart = segment.endPage + 1;
  });
  for (let page = 1; page <= segmentation.pageCount; page++) {
    if (!owner[page]) throw new Error(`Page ${page} is not assigned to any segment`);
  }
}

export const invoiceSegments = (segmentation: PacketSegmentation) =>
  segmentation.segments.filter((segment) => segment.kind === "invoice");

/** Batch intake applies only when a packet holds two or more invoices; anything else stays a normal upload. */
export const isMultiInvoicePacket = (segmentation: PacketSegmentation) =>
  invoiceSegments(segmentation).length >= 2;
