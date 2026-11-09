// Phase 6C.4: deterministic segmentation of multi-invoice PDF packets, the Henry Schein invoice
// layout in the existing parser, page-subset PDFs, and the owner-facing batch statuses.
//
// Fixtures are sanitized (tests/support/invoice-packet-fixtures.ts). The real 26-page packet is
// used only when it exists locally (never committed): set MEDSPEND_CANONICAL_PACKET or keep it at
// ~/Downloads/Requested_Documents.pdf.
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import test from "node:test";
import { DeterministicInvoiceExtractionProvider } from "../src/extraction/deterministic-invoice-provider.ts";
import { validateUsableDocumentText } from "../src/extraction/document-text-validation.ts";
import { EmbeddedPdfTextProvider } from "../src/extraction/embedded-pdf-text-provider.ts";
import { validateExtraction } from "../src/extraction/validation.ts";
import {
  genericDetector,
  henryScheinDetector,
  readPageOf,
  segmentInvoicePacket,
} from "../src/invoice-batch/detectors.ts";
import {
  buildSegmentPdf,
  loadPacket,
  readPacketPages,
  sha256Hex,
  summarizeSegment,
} from "../src/invoice-batch/packet.ts";
import {
  assertPageAllocation,
  groupPages,
  invoiceIdentityKey,
  isMultiInvoicePacket,
  type PageSignals,
  type PacketSegmentation,
} from "../src/invoice-batch/segmentation.ts";
import { batchCounts, batchRowStatus, pageRangeLabel } from "../src/invoice-batch/status.ts";
import type { InvoiceBatch, InvoiceBatchSegment } from "../src/types/invoice-batch.ts";
import {
  buildFixturePdf,
  henryScheinInvoicePages,
  invoiceAmounts,
  lines,
  packetPageTexts,
  pageText,
  structuralPacket,
  type FixtureInvoice,
} from "./support/invoice-packet-fixtures.ts";

const META = { detector: "test", vendorName: "Vendor", vendorKey: "vendor" };
const sig = (
  page: number,
  number: string | null,
  pageOf?: [number, number] | null,
  extra: Partial<PageSignals> = {},
): PageSignals => ({
  page,
  hasText: true,
  invoiceNumbers: number ? [number] : [],
  pageOf: pageOf ? { index: pageOf[0], count: pageOf[1] } : null,
  invoiceDate: null,
  accountKey: null,
  invoiceMarkers: true,
  ...extra,
});
const ranges = (result: PacketSegmentation) =>
  result.segments.map(
    (segment) =>
      `${segment.kind}:${segment.startPage}-${segment.endPage}:${segment.invoiceNumber ?? "-"}${segment.reasons.length ? `[${segment.reasons.join(",")}]` : ""}`,
  );

// ---------------------------------------------------------------------------------- grouping

test("a one-page invoice is one invoice and stays a normal (non-batch) upload", () => {
  const result = groupPages([sig(1, "A1", [1, 1])], META);
  assert.deepEqual(ranges(result), ["invoice:1-1:A1"]);
  assert.equal(isMultiInvoicePacket(result), false);
});

test("a two-page invoice groups both pages and stays a normal upload", () => {
  const result = groupPages([sig(1, "A1", [1, 2]), sig(2, "A1", [2, 2])], META);
  assert.deepEqual(ranges(result), ["invoice:1-2:A1"]);
  assert.equal(isMultiInvoicePacket(result), false);
});

test("a four-page invoice groups pages 1 through 4", () => {
  const result = groupPages(
    [1, 2, 3, 4].map((page) => sig(page, "B7", [page, 4])),
    META,
  );
  assert.deepEqual(ranges(result), ["invoice:1-4:B7"]);
});

test("several invoices in one file: an invoice-number change closes one and starts the next", () => {
  const result = groupPages(
    [
      sig(1, "A1", [1, 1]),
      sig(2, "A2", [1, 1]),
      sig(3, "A3", [1, 1]),
      sig(4, "A4", [1, 2]),
      sig(5, "A4", [2, 2]),
      sig(6, "A5", [1, 1]),
    ],
    META,
  );
  assert.deepEqual(ranges(result), [
    "invoice:1-1:A1",
    "invoice:2-2:A2",
    "invoice:3-3:A3",
    "invoice:4-5:A4",
    "invoice:6-6:A5",
  ]);
  assert.equal(isMultiInvoicePacket(result), true);
});

test("repeated vendor/customer headers alone never start an invoice", () => {
  // Continuation pages repeat the same account and date but carry no new number.
  const header = { accountKey: "1000002", invoiceDate: "2026-01-15" };
  const result = groupPages(
    [
      sig(1, "A1", [1, 3], header),
      sig(2, "A1", [2, 3], header),
      sig(3, "A1", [3, 3], header),
      sig(4, "A2", [1, 1], header),
    ],
    META,
  );
  assert.deepEqual(ranges(result), ["invoice:1-3:A1", "invoice:4-4:A2"]);
});

test("a page-number reset with the same invoice number is a repeated copy: a duplicate, never merged", () => {
  const result = groupPages(
    [sig(1, "A1", [1, 1]), sig(2, "A1", [1, 1]), sig(3, "A2", [1, 1])],
    META,
  );
  assert.deepEqual(ranges(result), [
    "invoice:1-1:A1",
    "invoice:2-2:A1[DUPLICATE_IN_PACKET]",
    "invoice:3-3:A2",
  ]);
  assert.equal(result.segments[1].duplicateOfIndex, 1);
});

test("an invoice-number change without a page reset still starts a new invoice (flagged)", () => {
  const result = groupPages([sig(1, "A1", [1, 2]), sig(2, "A2", [2, 2])], META);
  assert.deepEqual(ranges(result), [
    "invoice:1-1:A1[INCOMPLETE_PAGE_SEQUENCE]",
    "invoice:2-2:A2[MISSING_FIRST_PAGE,INCOMPLETE_PAGE_SEQUENCE]",
  ]);
});

test("the same purchase order, order or account never joins different invoice numbers (split shipments, backorders)", () => {
  const shared = { accountKey: "1000002", invoiceDate: "2026-01-15" };
  const result = groupPages(
    [
      sig(1, "52103732", [1, 1], shared),
      sig(2, "52103733", [1, 1], shared),
      sig(3, "52093891", [1, 1], shared),
    ],
    META,
  );
  assert.equal(result.segments.length, 3);
  assert.ok(result.segments.every((segment) => segment.reasons.length === 0));
});

test("without page markers, a shared account, PO or order still never joins different invoice numbers", () => {
  const shared = { accountKey: "1000002", invoiceDate: "2026-01-15" };
  const result = groupPages(
    [sig(1, "P1", null, shared), sig(2, "P2", null, shared), sig(3, "P2", null, shared)],
    META,
  );
  assert.deepEqual(ranges(result), ["invoice:1-1:P1", "invoice:2-3:P2"]);
});

test("malformed page numbering keeps the pages with their invoice number but holds it for review", () => {
  const out = groupPages([sig(1, "A1", [1, 3]), sig(2, "A1", [3, 3]), sig(3, "A1", [2, 3])], META);
  assert.deepEqual(ranges(out), ["invoice:1-3:A1[PAGE_SEQUENCE_IRREGULAR]"]);
  const count = groupPages([sig(1, "A1", [1, 2]), sig(2, "A1", [2, 3])], META);
  assert.deepEqual(ranges(count), ["invoice:1-2:A1[PAGE_SEQUENCE_IRREGULAR]"]);
});

test("missing page numbers: the invoice number alone groups pages", () => {
  const result = groupPages(
    [sig(1, "A1"), sig(2, "A1"), sig(3, "A2"), sig(4, "A2"), sig(5, "A2")],
    META,
  );
  assert.deepEqual(ranges(result), ["invoice:1-2:A1", "invoice:3-5:A2"]);
});

test("a continuation page without a number joins only as the exact next page; otherwise it is explicitly unresolved", () => {
  const joined = groupPages(
    [sig(1, "A1", [1, 2]), sig(2, null, [2, 2]), sig(3, "A2", [1, 1])],
    META,
  );
  assert.deepEqual(ranges(joined), ["invoice:1-2:A1", "invoice:3-3:A2"]);
  const ambiguous = groupPages(
    [sig(1, "A1", [1, 1]), sig(2, null, null), sig(3, null, [3, 3]), sig(4, "A2", [1, 1])],
    META,
  );
  assert.deepEqual(ranges(ambiguous), [
    "invoice:1-1:A1",
    "unresolved:2-3:-[NO_INVOICE_NUMBER]",
    "invoice:4-4:A2",
  ]);
});

test("pages with no text, two invoice numbers, or no invoice content are explicit, never dropped", () => {
  const result = groupPages(
    [
      sig(1, null, null, { invoiceMarkers: false }),
      sig(2, "A1", [1, 1]),
      sig(3, null, null, { hasText: false }),
      { ...sig(4, null), invoiceNumbers: ["A2", "A3"] },
      sig(5, "A4", [1, 1]),
    ],
    META,
  );
  assert.deepEqual(ranges(result), [
    "non_invoice:1-1:-",
    "invoice:2-2:A1",
    "unresolved:3-4:-[NO_TEXT,CONFLICTING_INVOICE_NUMBERS]",
    "invoice:5-5:A4",
  ]);
});

test("header conflicts inside one invoice number are held, not guessed", () => {
  const result = groupPages(
    [
      sig(1, "A1", [1, 2], { invoiceDate: "2026-01-02" }),
      sig(2, "A1", [2, 2], { invoiceDate: "2026-02-02" }),
    ],
    META,
  );
  assert.deepEqual(ranges(result), ["invoice:1-2:A1[HEADER_MISMATCH]"]);
});

test("the final invoice is never lost", () => {
  const result = groupPages(
    [sig(1, "A1", [1, 1]), sig(2, "A2", [1, 2]), sig(3, "A2", [2, 2])],
    META,
  );
  assert.equal(result.segments.at(-1)?.invoiceNumber, "A2");
  assert.equal(result.segments.at(-1)?.endPage, 3);
});

test("page allocation: random packets always assign every page exactly once, in order", () => {
  let seed = 6403;
  const random = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
  for (let run = 0; run < 400; run++) {
    const count = 1 + Math.floor(random() * 40);
    const signals = Array.from({ length: count }, (_, index) => {
      const roll = random();
      const number = roll < 0.15 ? null : `N${Math.floor(random() * 6)}`;
      const pageOf: [number, number] | null =
        random() < 0.3 ? null : [1 + Math.floor(random() * 4), 1 + Math.floor(random() * 4)];
      return sig(index + 1, number, pageOf && pageOf[0] <= pageOf[1] ? pageOf : null, {
        hasText: random() > 0.05,
        invoiceMarkers: random() > 0.1,
      });
    });
    const result = groupPages(signals, META);
    assert.doesNotThrow(() => assertPageAllocation(result));
    assert.equal(
      result.segments.reduce((sum, segment) => sum + segment.endPage - segment.startPage + 1, 0),
      count,
    );
  }
});

test("the allocation check rejects lost, doubled, reordered and out-of-range pages", () => {
  const valid = groupPages(
    [sig(1, "A1", [1, 1]), sig(2, "A2", [1, 2]), sig(3, "A2", [2, 2])],
    META,
  );
  const clone = () => structuredClone(valid);
  const lost = clone();
  lost.segments[1].endPage = 2;
  assert.throws(() => assertPageAllocation(lost), /not assigned/);
  const doubled = clone();
  doubled.segments[1].startPage = 1;
  assert.throws(() => assertPageAllocation(doubled), /assigned|order/);
  const reordered = clone();
  reordered.segments.reverse();
  assert.throws(() => assertPageAllocation(reordered), /order/);
  const beyond = clone();
  beyond.segments[1].endPage = 4;
  assert.throws(() => assertPageAllocation(beyond), /outside|not assigned/);
});

test("identity key: vendor + normalized invoice number", () => {
  assert.equal(invoiceIdentityKey("henry-schein", " 52103732 "), "henry-schein:52103732");
  assert.equal(invoiceIdentityKey("henry-schein", "5210-3732"), "henry-schein:52103732");
  assert.equal(invoiceIdentityKey("henry-schein", ""), null);
  assert.notEqual(invoiceIdentityKey("a", "1"), invoiceIdentityKey("b", "1"));
});

// ---------------------------------------------------------------------------------- detectors

test('page markers: "Page i of N" glued to following text is still read; two markers are not a page number', () => {
  assert.deepEqual(readPageOf("x\nPage 1 of 4Please remit payments to: Henry Schein"), {
    index: 1,
    count: 4,
  });
  assert.equal(readPageOf("Page 1 of 2 ... Page 2 of 2"), null);
  assert.equal(readPageOf("Page 5 of 2"), null);
  assert.equal(readPageOf("no marker"), null);
});

test("Henry Schein detector reads header and footer identity, and never the backorder reference", () => {
  const [page] = henryScheinInvoicePages({ ...structuralPacket()[1] });
  const signals = henryScheinDetector.read(pageText(page), 1);
  assert.deepEqual(signals.invoiceNumbers, ["60000002"]);
  assert.deepEqual(signals.pageOf, { index: 1, count: 1 });
  assert.equal(signals.invoiceDate, "2026-01-07");
  assert.equal(signals.accountKey, "1000002");
  assert.ok(pageText(page).includes("original invoice:60000009"));
});

test("a continuation page is identified by its footer, not by its repeated header", () => {
  const pages = henryScheinInvoicePages(structuralPacket()[3]);
  const second = henryScheinDetector.read(pageText(pages[1]), 2);
  assert.deepEqual(second.invoiceNumbers, ["60000004"]);
  assert.deepEqual(second.pageOf, { index: 2, count: 4 });
  const bare = henryScheinDetector.read(
    pageText(henryScheinInvoicePages({ ...structuralPacket()[3], footerless: [1] })[1]),
    2,
  );
  assert.deepEqual(bare.invoiceNumbers, []);
});

test("generic detector: explicit invoice labels and page markers, never a heading word", () => {
  const page = "ACME SUPPLY\nInvoice Number Invoice Date\nInvoice #: INV-2207\nPage 1 of 2";
  assert.deepEqual(genericDetector.read(page, 1).invoiceNumbers, ["INV-2207"]);
  assert.deepEqual(genericDetector.read("Invoice No.\nA-55120\nTotal 10.00", 1).invoiceNumbers, [
    "A-55120",
  ]);
  assert.equal(henryScheinDetector.recognizes([page, page]), false);
});

test("sanitized Henry Schein packet: one-page, two-page and four-page invoices, split shipment, backorders", () => {
  const result = segmentInvoicePacket(packetPageTexts(structuralPacket()));
  assert.equal(result.detector, "henry-schein-invoice-v1");
  assert.deepEqual(ranges(result), [
    "invoice:1-1:60000001",
    "invoice:2-2:60000002",
    "invoice:3-4:60000003",
    "invoice:5-8:60000004",
    "invoice:9-9:60000005",
    "invoice:10-10:60000006",
    "invoice:11-11:60000007",
  ]);
});

test("a continuation page that lost its footer still joins as the exact next page", () => {
  const invoices = structuralPacket();
  invoices[3] = { ...invoices[3], footerless: [2] };
  const result = segmentInvoicePacket(packetPageTexts(invoices));
  assert.ok(ranges(result).includes("invoice:5-8:60000004"));
});

test("a continuation page with neither footer nor page marker is unresolved, not attached by guesswork", () => {
  const invoices = structuralPacket();
  invoices[3] = {
    ...invoices[3],
    footerless: [2],
    pageMarkers: ["Page 1 of 4", "Page 2 of 4", null, "Page 4 of 4"],
  };
  const result = segmentInvoicePacket(packetPageTexts(invoices));
  assert.deepEqual(ranges(result).slice(3, 6), [
    "invoice:5-6:60000004[INCOMPLETE_PAGE_SEQUENCE]",
    "unresolved:7-7:-[NO_INVOICE_NUMBER]",
    "invoice:8-8:60000004[MISSING_FIRST_PAGE,INCOMPLETE_PAGE_SEQUENCE]",
  ]);
  assertPageAllocation(result);
});

test("the same invoice printed twice in one packet is detected as a duplicate", () => {
  const invoices = structuralPacket();
  const result = segmentInvoicePacket(packetPageTexts([...invoices, invoices[0]]));
  assert.equal(result.segments.at(-1)?.reasons.includes("DUPLICATE_IN_PACKET"), true);
  assert.equal(result.segments.at(-1)?.duplicateOfIndex, 1);
});

// ---------------------------------------------------------------------------------- parsing

const parse = async (text: string) => {
  const validation = validateUsableDocumentText(text);
  assert.ok(validation.usable, validation.reason);
  return validateExtraction(
    await new DeterministicInvoiceExtractionProvider().extractInvoice(validation.normalizedText),
  );
};

test("each segmented invoice goes through the existing parser with its own lines and totals", async () => {
  const invoices = structuralPacket();
  const pages = packetPageTexts(invoices);
  const result = segmentInvoicePacket(pages);
  for (const [position, segment] of result.segments.entries()) {
    const invoice = invoices[position];
    const expected = invoiceAmounts(invoice);
    const shipped = invoice.pages.flat().filter((line) => line.shipped > 0);
    const extraction = await parse(
      pages.slice(segment.startPage - 1, segment.endPage).join("\n\n"),
    );
    assert.equal(extraction.header.invoiceNumber.value, invoice.number);
    assert.equal(extraction.header.vendor.value, "Henry Schein, Inc.");
    assert.equal(extraction.items.length, shipped.length, `items for ${invoice.number}`);
    assert.deepEqual(
      extraction.items.map((item) => item.sku.value),
      shipped.map((line) => line.sku),
    );
    assert.equal(extraction.header.total.value, expected.total, `total for ${invoice.number}`);
    if (expected.merchandise > 0)
      assert.equal(extraction.header.subtotal.value, expected.merchandise);
    assert.equal(
      extraction.reconciliation?.needsReview,
      false,
      `reconciliation for ${invoice.number}`,
    );
  }
});

test("multi-page invoice: first-page and continuation lines kept in order; headers, notes and totals never become lines", async () => {
  const invoice = structuralPacket()[3];
  const extraction = await parse(henryScheinInvoicePages(invoice).map(pageText).join("\n\n"));
  const expected = invoice.pages.flat();
  assert.equal(extraction.items.length, 33);
  assert.equal(extraction.items[0].sku.value, expected[0].sku);
  assert.equal(extraction.items.at(-1)?.sku.value, expected.at(-1)?.sku);
  // Last line of page 1 and first line of page 2 survive the page transition.
  assert.equal(extraction.items[6].sku.value, invoice.pages[0].at(-1)?.sku);
  assert.equal(extraction.items[7].sku.value, invoice.pages[1][0].sku);
  assert.ok(
    extraction.items.every(
      (item) => !/total|tax|freight|special|invoice|line|page/i.test(item.description.value),
    ),
  );
  assert.equal(extraction.header.purchaseOrder.value, "PRESEASON ORDER");
  assert.equal(extraction.header.invoiceDate.value, "2026-01-15");
});

test("unshipped (backordered) lines are not billed lines and do not make the invoice look wrong", async () => {
  const invoice = structuralPacket()[6];
  const extraction = await parse(henryScheinInvoicePages(invoice).map(pageText).join("\n\n"));
  assert.equal(extraction.items.length, 2);
  // Billed quantity is the quantity shipped, not the quantity ordered.
  assert.deepEqual(
    extraction.items.map((line) => line.quantity.value),
    invoice.pages[0].filter((line) => line.shipped > 0).map((line) => line.shipped),
  );
  assert.notEqual(invoice.pages[0][0].ordered, invoice.pages[0][0].shipped);
  assert.equal(extraction.header.shipping.value, 9.95);
  assert.equal(extraction.header.tax.value, 2.1);
  assert.equal(extraction.financialEvidence?.rejectedLineCandidates, 0);
  const allBackordered = await parse(
    henryScheinInvoicePages(structuralPacket()[5]).map(pageText).join("\n\n"),
  );
  assert.equal(allBackordered.items.length, 0);
  assert.equal(allBackordered.header.total.value, 0);
});

test("a line whose arithmetic does not hold is rejected and flags the invoice", async () => {
  const text = henryScheinInvoicePages(structuralPacket()[0])
    .map(pageText)
    .join("\n\n")
    .replace(/ (\d+\.\d{2}) 1 IN$/m, " 999.99 1 IN");
  const extraction = await parse(text);
  assert.equal(extraction.items.length, 0);
  assert.equal(extraction.financialEvidence?.rejectedLineCandidates, 1);
});

test("a whole packet parsed as one document never merges invoices: identity, totals and lines are withheld", async () => {
  const extraction = await parse(packetPageTexts(structuralPacket()).join("\n\n"));
  assert.equal(extraction.items.length, 0);
  assert.equal(extraction.header.invoiceNumber.value, "");
  assert.equal(extraction.header.total.value, null);
});

test("the generic parser is unchanged for documents that are not the Henry Schein invoice form", async () => {
  const text =
    "Acme Medical Supply Inc.\nInvoice Number: 4471\nInvoice Date: 01/02/2026\nItem Description Qty Unit Price Amount\nABC-100 Gauze pads 2 EA 3.00 6.00\nSubtotal 6.00\nTotal 6.00";
  const extraction = await parse(text);
  assert.equal(extraction.header.invoiceNumber.value, "4471");
  assert.equal(extraction.header.vendor.value, "Acme Medical Supply Inc.");
});

// ---------------------------------------------------------------------------------- PDFs

test("page-subset PDFs keep exactly their pages, in source order, with identical text", async () => {
  const invoices = structuralPacket();
  const pdf = await buildFixturePdf(invoices.flatMap(henryScheinInvoicePages));
  const pages = await readPacketPages(pdf);
  assert.equal(pages.length, 11);
  const packet = await loadPacket(pdf);
  for (const [start, end] of [
    [1, 1],
    [3, 4],
    [5, 8],
    [11, 11],
  ]) {
    const subset = await buildSegmentPdf(packet, start, end);
    const { text, pageCount } = await new EmbeddedPdfTextProvider().extractText(subset.slice());
    assert.equal(pageCount, end - start + 1);
    assert.equal(text, pages.slice(start - 1, end).join("\n\n"));
  }
  await assert.rejects(buildSegmentPdf(packet, 0, 1));
  await assert.rejects(buildSegmentPdf(packet, 10, 12));
  assert.match(await sha256Hex(pdf), /^[0-9a-f]{64}$/);
  assert.equal(await sha256Hex(pdf), await sha256Hex(pdf.slice()));
});

test("segment summaries come from the existing parser and report text-less pages explicitly", async () => {
  const pages = packetPageTexts(structuralPacket());
  const summary = await summarizeSegment(pages, 5, 8);
  assert.equal(summary.state, "STRUCTURED_SUCCESS");
  assert.equal(summary.itemCount, 33);
  assert.equal(summary.needsReview, false);
  const empty = await summarizeSegment(["", ""], 1, 2);
  assert.equal(empty.state, "TEXT_UNAVAILABLE");
});

test("scale: a synthetic 60-page packet (30 invoices) segments and parses deterministically", async () => {
  const invoices: FixtureInvoice[] = Array.from({ length: 30 }, (_, index) => ({
    number: String(61000000 + index),
    date: "03/01/26",
    po: "BULK",
    order: String(71000000 + Math.floor(index / 3)),
    pages:
      index % 3 === 0
        ? [lines(index % 40, 6), lines((index + 7) % 40, 6), lines((index + 13) % 40, 5)]
        : index % 3 === 1
          ? [lines(index % 50, 3)]
          : [lines(index % 50, 4), lines((index + 4) % 50, 4)],
    tax: 1.11,
  }));
  const pdf = await buildFixturePdf(invoices.flatMap(henryScheinInvoicePages));
  const started = performance.now();
  const pages = await readPacketPages(pdf);
  const textMs = performance.now() - started;
  const segmentationStarted = performance.now();
  const result = segmentInvoicePacket(pages);
  const segmentationMs = performance.now() - segmentationStarted;
  assert.equal(pages.length, 60);
  assert.equal(result.segments.length, 30);
  assert.ok(
    result.segments.every(
      (segment, index) =>
        segment.invoiceNumber === invoices[index].number && segment.reasons.length === 0,
    ),
  );
  const parsingStarted = performance.now();
  for (const segment of result.segments) {
    const summary = await summarizeSegment(pages, segment.startPage, segment.endPage);
    assert.equal(summary.itemCount, invoices[segment.index - 1].pages.flat().length);
  }
  const parsingMs = performance.now() - parsingStarted;
  const packet = await loadPacket(pdf);
  const subsetStarted = performance.now();
  for (const segment of result.segments)
    await buildSegmentPdf(packet, segment.startPage, segment.endPage);
  const subsetMs = performance.now() - subsetStarted;
  console.log(
    `[6c4 scale] 60 pages: text ${textMs.toFixed(0)} ms, segmentation ${segmentationMs.toFixed(1)} ms, parsing ${parsingMs.toFixed(0)} ms, 30 subset PDFs ${subsetMs.toFixed(0)} ms, rss ${(process.memoryUsage().rss / 1e6).toFixed(0)} MB`,
  );
});

// ---------------------------------------------------------------------------------- statuses

const segment = (overrides: Partial<InvoiceBatchSegment>): InvoiceBatchSegment => ({
  id: "s",
  index: 1,
  kind: "invoice",
  status: "created",
  pageStart: 1,
  pageEnd: 1,
  invoiceNumber: "A1",
  invoiceDate: null,
  reasons: [],
  duplicateOfIndex: null,
  duplicateOfSourceFileId: null,
  parseState: "STRUCTURED_SUCCESS",
  parsedItemCount: 1,
  parsedTotal: 1,
  parseNeedsReview: false,
  error: null,
  sourceFileId: "f",
  invoice: null,
  ...overrides,
});

test("batch statuses: ready, needs review, parsing failed, duplicate, segmentation issue, failed, posted, removed", () => {
  assert.equal(batchRowStatus(segment({})), "ready");
  assert.equal(batchRowStatus(segment({ parseNeedsReview: true })), "needs_review");
  assert.equal(batchRowStatus(segment({ parseState: "STRUCTURED_FAILED" })), "parsing_failed");
  assert.equal(batchRowStatus(segment({ parseState: "TEXT_UNAVAILABLE" })), "parsing_failed");
  assert.equal(batchRowStatus(segment({ status: "duplicate", sourceFileId: null })), "duplicate");
  assert.equal(
    batchRowStatus(segment({ status: "held", sourceFileId: null })),
    "segmentation_issue",
  );
  assert.equal(
    batchRowStatus(segment({ status: "held", kind: "unresolved", sourceFileId: null })),
    "segmentation_issue",
  );
  assert.equal(batchRowStatus(segment({ status: "failed", sourceFileId: null })), "failed");
  assert.equal(batchRowStatus(segment({ status: "pending", sourceFileId: null })), "preparing");
  assert.equal(
    batchRowStatus(segment({ invoice: { processingStatus: "completed", itemCount: 1, total: 1 } })),
    "posted",
  );
  assert.equal(batchRowStatus(segment({ sourceFileId: null })), "removed");
  assert.equal(batchRowStatus(segment({ status: "ignored", kind: "non_invoice" })), "not_invoice");
  assert.equal(
    batchRowStatus(segment({ kind: "unresolved", invoiceNumber: null })),
    "needs_review",
  );
  assert.equal(pageRangeLabel({ pageStart: 7, pageEnd: 10 }), "Pages 7–10");
  assert.equal(pageRangeLabel({ pageStart: 1, pageEnd: 1 }), "Page 1");
  const batch = {
    segments: [
      segment({}),
      segment({ status: "pending" }),
      segment({ kind: "unresolved", status: "held" }),
    ],
  } as InvoiceBatch;
  const counts = batchCounts(batch);
  assert.equal(counts.invoices, 2);
  assert.equal(counts.pending, 1);
  assert.equal(counts.byStatus.ready, 1);
});

// ---------------------------------------------------------------------------------- canonical

const CANONICAL =
  process.env.MEDSPEND_CANONICAL_PACKET ?? `${homedir()}/Downloads/Requested_Documents.pdf`;
const canonicalSkip = existsSync(CANONICAL)
  ? false
  : `canonical 26-page Henry Schein packet not present (${CANONICAL})`;

test(
  "canonical 26-page Henry Schein packet: 22 invoices, every page once, own lines and totals",
  { skip: canonicalSkip },
  async () => {
    const bytes = new Uint8Array(await readFile(CANONICAL));
    const started = performance.now();
    const pages = await readPacketPages(bytes);
    const textMs = performance.now() - started;
    const segmentationStarted = performance.now();
    const result = segmentInvoicePacket(pages);
    const segmentationMs = performance.now() - segmentationStarted;
    assert.equal(pages.length, 26);
    assert.equal(result.detector, "henry-schein-invoice-v1");
    assertPageAllocation(result);
    assert.deepEqual(
      result.segments.map((s) => `${s.startPage}-${s.endPage}:${s.invoiceNumber}`),
      [
        "1-1:50902751",
        "2-2:51706237",
        "3-3:52092774",
        "4-5:52093808",
        "6-6:52093891",
        "7-10:52103732",
        "11-11:52103733",
        "12-12:52252469",
        "13-13:52281822",
        "14-14:52489324",
        "15-15:55049814",
        "16-16:55434794",
        "17-17:56012854",
        "18-18:56793162",
        "19-19:56793163",
        "20-20:57761097",
        "21-21:57761098",
        "22-22:58220214",
        "23-23:58542740",
        "24-24:59179794",
        "25-25:59179795",
        "26-26:59323982",
      ],
    );
    assert.ok(result.segments.every((s) => s.kind === "invoice" && s.reasons.length === 0));
    // No continuation page (5, 8, 9, 10) is its own invoice.
    for (const page of [5, 8, 9, 10]) assert.ok(!result.segments.some((s) => s.startPage === page));

    const parsingStarted = performance.now();
    const summaries = new Map<string, Awaited<ReturnType<typeof summarizeSegment>>>();
    for (const s of result.segments)
      summaries.set(s.invoiceNumber!, await summarizeSegment(pages, s.startPage, s.endPage));
    const parsingMs = performance.now() - parsingStarted;
    const first = summaries.get("50902751")!;
    assert.equal(first.itemCount, 1);
    assert.equal(first.total, 19054.88);
    assert.equal(first.extraction?.header.subtotal.value, 17850);
    assert.equal(first.extraction?.items[0].sku.value, "142-6502");
    const twoPage = summaries.get("52093808")!;
    assert.equal(twoPage.itemCount, 15);
    assert.equal(twoPage.total, 1107.89);
    const long = summaries.get("52103732")!;
    assert.equal(long.itemCount, 33);
    assert.equal(long.total, 1126.91);
    assert.equal(long.extraction?.header.subtotal.value, 1090.24);
    assert.deepEqual(long.extraction?.items.map((item) => item.sku.value).slice(0, 2), [
      "911-7087",
      "911-9465",
    ]);
    assert.equal(long.extraction?.items.at(-1)?.sku.value, "141-2446");
    assert.equal(long.extraction?.reconciliation?.needsReview, false);
    for (const [number, summary] of summaries) {
      assert.equal(summary.invoiceNumber, number);
      if (summary.itemCount)
        assert.equal(
          summary.extraction?.reconciliation?.needsReview,
          false,
          `${number} reconciles`,
        );
    }
    // Fully backordered invoices print $0.00 and carry no billable lines.
    for (const number of ["57761098", "59179795", "59323982"]) {
      assert.equal(summaries.get(number)?.itemCount, 0);
      assert.equal(summaries.get(number)?.total, 0);
    }
    assert.equal(
      [...summaries.values()].reduce((sum, summary) => sum + summary.itemCount, 0),
      75,
    );

    const packet = await loadPacket(bytes);
    const subset = await buildSegmentPdf(packet, 7, 10);
    const subsetText = await new EmbeddedPdfTextProvider().extractText(subset.slice());
    assert.equal(subsetText.text, pages.slice(6, 10).join("\n\n"));
    console.log(
      `[6c4 canonical] 26 pages: text ${textMs.toFixed(0)} ms, segmentation ${segmentationMs.toFixed(1)} ms, parsing ${parsingMs.toFixed(0)} ms, subset 7-10 ${subset.byteLength} bytes, rss ${(process.memoryUsage().rss / 1e6).toFixed(0)} MB`,
    );
  },
);
