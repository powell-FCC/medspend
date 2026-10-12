import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { DeterministicInvoiceExtractionProvider } from "../src/extraction/deterministic-invoice-provider.ts";
import { EmbeddedPdfTextProvider } from "../src/extraction/embedded-pdf-text-provider.ts";
import {
  DERIVED_CONFIDENCE,
  MONEY_TOLERANCE_CENTS,
  derivedTotalFields,
  fromCents,
  toCents,
} from "../src/extraction/totals.ts";
import type {
  CanonicalInvoiceExtraction,
  ExtractedField,
  ExtractionFinancialEvidence,
} from "../src/extraction/types.ts";
import { validateExtraction } from "../src/extraction/validation.ts";

const fixture = (name: string) =>
  readFile(new URL(`fixtures/invoices/${name}.txt`, import.meta.url), "utf8");
const extract = async (text: string) => {
  const diagnostics =
    await new DeterministicInvoiceExtractionProvider().extractInvoiceWithDiagnostics(text);
  return { diagnostics, extraction: validateExtraction(diagnostics.extraction) };
};
const field = <T>(value: T, confidence = 95): ExtractedField<T> => ({
  value,
  confidence,
  source: "Parser",
  reviewed: false,
});
const CLEAN: ExtractionFinancialEvidence = { rejectedLineCandidates: 0, unexplainedAmounts: 0 };

// A provider-independent extraction: only the amounts under test vary.
function canonical(options: {
  lines: Array<number | { value: number; confidence: number }>;
  subtotal?: number | null;
  tax?: number | null;
  shipping?: number | null;
  total?: number | null;
  evidence?: ExtractionFinancialEvidence;
}): CanonicalInvoiceExtraction {
  return {
    header: {
      vendor: field("Example Medical Supply"),
      invoiceNumber: field("INV-1"),
      invoiceDate: field("2026-09-17"),
      purchaseOrder: field(""),
      subtotal: field(options.subtotal ?? null, options.subtotal == null ? 0 : 94),
      tax: field(options.tax ?? null, options.tax == null ? 0 : 92),
      shipping: field(options.shipping ?? null, options.shipping == null ? 0 : 88),
      total: field(options.total ?? null, options.total == null ? 0 : 94),
    },
    items: options.lines.map((line, index) => {
      const lineTotal =
        typeof line === "number" ? field(line, 98) : field(line.value, line.confidence);
      return {
        sku: field(`SKU-${index + 1}`),
        description: field(`Item ${index + 1}`),
        manufacturer: field("", 0),
        quantity: field(1),
        unit: field("each"),
        unitPrice: field(lineTotal.value),
        lineTotal,
        suggestedCategory: field("", 0),
      };
    }),
    financialEvidence: options.evidence,
  };
}

test("printed subtotal and total are extracted with parser provenance and are never recalculated", async () => {
  const { extraction } = await extract(await fixture("standard"));
  assert.deepEqual(extraction.header.subtotal, {
    value: 406.32,
    confidence: 94,
    source: "Parser",
    reviewed: false,
  });
  assert.deepEqual(extraction.header.total, {
    value: 444.76,
    confidence: 94,
    source: "Parser",
    reviewed: false,
  });
  assert.deepEqual(derivedTotalFields(extraction), []);
  assert.deepEqual(extraction.reconciliation, {
    lineItemsMatchSubtotal: true,
    componentsMatchTotal: true,
    needsReview: false,
  });
});

test("the production order-confirmation layout: no dropped line, printed total, calculated subtotal", async () => {
  const { extraction, diagnostics } = await extract(await fixture("displaced-two-page-order"));
  // Root cause of the blank total: the ".77" unit price row was dropped, so the printed total
  // could not be corroborated against the extracted lines.
  assert.deepEqual(
    extraction.items.map((item) => [
      item.sku.value,
      item.quantity.value,
      item.unitPrice.value,
      item.lineTotal.value,
    ]),
    [
      ["AX1001", 3, 6.81, 20.43],
      ["BX2002", 1, 38.25, 38.25],
      ["CX3003", 10, 0.77, 7.7],
      ["DX4004", 1, 51.8, 51.8],
      ["FX6006", 2, 16.85, 33.7],
    ],
  );
  // The backordered row has no extension on this document and is not fabricated.
  assert.ok(!extraction.items.some((item) => item.sku.value === "EX5005"));
  assert.equal(
    diagnostics.lineItemCandidates.find((candidate) => candidate.value.includes("EX5005"))?.reason,
    "MISSING_CORROBORATING_EXTENSION",
  );
  // The printed total is read from the document, with full extraction confidence.
  assert.deepEqual(extraction.header.total, {
    value: 166.35,
    confidence: 94,
    source: "Parser",
    reviewed: false,
  });
  // Tax and shipping are unchanged.
  assert.deepEqual(extraction.header.tax, {
    value: 10.52,
    confidence: 92,
    source: "Parser",
    reviewed: false,
  });
  assert.deepEqual(extraction.header.shipping, {
    value: 3.95,
    confidence: 88,
    source: "Parser",
    reviewed: false,
  });
  // No subtotal is printed. It is calculated because the printed total corroborates the lines
  // (151.88 + 10.52 + 3.95 = 166.35), and it is labelled as calculated and review-suggested.
  assert.deepEqual(extraction.header.subtotal, {
    value: 151.88,
    confidence: DERIVED_CONFIDENCE,
    source: "Derived",
    reviewed: false,
  });
  assert.ok(DERIVED_CONFIDENCE < 75, "a calculated amount must stay under the review threshold");
  assert.deepEqual(derivedTotalFields(extraction), ["subtotal"]);
  assert.deepEqual(extraction.reconciliation, {
    lineItemsMatchSubtotal: null,
    componentsMatchTotal: true,
    needsReview: false,
  });
});

test("a calculated amount does not count as an extracted header", async () => {
  const text = await fixture("displaced-two-page-order");
  const { extraction } = await extract(text);
  const withoutDerivation = structuredClone(extraction);
  withoutDerivation.header.subtotal = field(null, 0);
  delete withoutDerivation.quality;
  const { assessExtractionQuality } = await import("../src/extraction/validation.ts");
  assert.deepEqual(extraction.quality, assessExtractionQuality(withoutDerivation));
});

test("validating twice does not turn a calculated amount into a printed one", async () => {
  const { extraction } = await extract(await fixture("displaced-two-page-order"));
  const again = validateExtraction(structuredClone(extraction));
  assert.deepEqual(again.header, extraction.header);
  assert.deepEqual(again.reconciliation, extraction.reconciliation);
  // If the support for the calculation disappears, the calculated value is withdrawn.
  const unsupported = structuredClone(extraction);
  unsupported.items.pop();
  validateExtraction(unsupported);
  assert.equal(unsupported.header.subtotal.value, null);
  assert.equal(unsupported.reconciliation?.needsReview, true);
});

test("subtotal is calculated from complete line totals when the document corroborates them", async () => {
  const { extraction } = await extract(await fixture("displaced-multi-row-order"));
  assert.deepEqual(extraction.header.subtotal, {
    value: 163.75,
    confidence: DERIVED_CONFIDENCE,
    source: "Derived",
    reviewed: false,
  });
  assert.equal(extraction.header.total.source, "Parser");
  assert.equal(extraction.header.total.value, 178);
});

test("with no printed total, subtotal and total are calculated only when nothing is unexplained", async () => {
  const noTotals =
    "Regional Medical Company\nInvoice: R-77\nInvoice Date: 08/07/2026\nSKU Product Quantity UOM Unit Price Amount\nR100 Exam Paper 3 roll 10.00 30.00\nR200 Table Paper 2 roll 4.50 9.00\nTax: 2.00\nFreight: 5.00";
  const { extraction } = await extract(noTotals);
  assert.deepEqual(extraction.financialEvidence, CLEAN);
  assert.deepEqual(extraction.header.subtotal, {
    value: 39,
    confidence: DERIVED_CONFIDENCE,
    source: "Derived",
    reviewed: false,
  });
  assert.deepEqual(extraction.header.total, {
    value: 46,
    confidence: DERIVED_CONFIDENCE,
    source: "Derived",
    reviewed: false,
  });
  assert.deepEqual(derivedTotalFields(extraction), ["subtotal", "total"]);

  // A printed subtotal is kept; only the missing total is calculated from it.
  const printedSubtotal = await extract(
    `${noTotals.replace("Tax: 2.00", "Subtotal: 39.00\nTax: 2.00")}`,
  );
  assert.equal(printedSubtotal.extraction.header.subtotal.source, "Parser");
  assert.deepEqual(printedSubtotal.extraction.header.total, {
    value: 46,
    confidence: DERIVED_CONFIDENCE,
    source: "Derived",
    reviewed: false,
  });

  // The displaced order layout without its TOTAL AMOUNT block.
  const order = (await fixture("email-near-header")).replace("\nTOTAL AMOUNT\n160.56", "");
  const displaced = await extract(order);
  assert.deepEqual(displaced.extraction.financialEvidence, CLEAN);
  assert.equal(displaced.extraction.header.subtotal.value, 129.96);
  assert.deepEqual(displaced.extraction.header.total, {
    value: 160.56,
    confidence: DERIVED_CONFIDENCE,
    source: "Derived",
    reviewed: false,
  });
});

test("money is summed in whole cents, not floating point", () => {
  // Sums that are wrong in floating point.
  assert.notEqual(0.1 + 0.2, 0.3);
  assert.notEqual(4.35 + 4.35 + 4.35, 13.05);
  assert.notEqual(0.1 + 0.7, 0.8);
  assert.equal(toCents(0.1), 10);
  assert.equal(toCents(20.43), 2043);
  assert.equal(toCents(1234567.89), 123456789);
  assert.equal(fromCents(15188), 151.88);
  for (const invalid of [
    10.005,
    -1,
    Number.NaN,
    Number.POSITIVE_INFINITY,
    null,
    undefined,
    "12.00",
  ])
    assert.equal(toCents(invalid), null);

  const dimes = validateExtraction(
    canonical({ lines: [0.1, 0.2], tax: 0, shipping: 0, evidence: CLEAN }),
  );
  assert.equal(dimes.header.subtotal.value, 0.3);
  assert.equal(dimes.header.total.value, 0.3);
  const repeated = validateExtraction(
    canonical({ lines: [4.35, 4.35, 4.35], tax: 0.1, shipping: 0.7, evidence: CLEAN }),
  );
  assert.equal(repeated.header.subtotal.value, 13.05);
  assert.equal(repeated.header.total.value, 13.85);
  // The existing two-cent convention, applied exactly: two cents apart agrees, three does not.
  assert.equal(MONEY_TOLERANCE_CENTS, 2);
  assert.equal(
    validateExtraction(canonical({ lines: [0.1, 0.2], subtotal: 0.32 })).reconciliation
      ?.lineItemsMatchSubtotal,
    true,
  );
  assert.equal(
    validateExtraction(canonical({ lines: [0.1, 0.2], subtotal: 0.33 })).reconciliation
      ?.lineItemsMatchSubtotal,
    false,
  );
});

test("a printed value always wins and a disagreement is surfaced, never overwritten", () => {
  const extraction = validateExtraction(
    canonical({ lines: [40, 50], subtotal: 100, tax: 5, shipping: 5, total: 110, evidence: CLEAN }),
  );
  assert.deepEqual(extraction.header.subtotal, {
    value: 100,
    confidence: 94,
    source: "Parser",
    reviewed: false,
  });
  assert.deepEqual(extraction.header.total, {
    value: 110,
    confidence: 94,
    source: "Parser",
    reviewed: false,
  });
  assert.deepEqual(extraction.reconciliation, {
    lineItemsMatchSubtotal: false,
    componentsMatchTotal: true,
    needsReview: true,
  });
  assert.ok(extraction.quality?.reasonCodes.includes("FINANCIAL_MISMATCH"));

  // A printed total that the line items contradict: nothing is calculated around it.
  const contradicted = validateExtraction(
    canonical({ lines: [40, 50], tax: 5, shipping: 5, total: 110, evidence: CLEAN }),
  );
  assert.equal(contradicted.header.subtotal.value, null);
  assert.equal(contradicted.header.total.value, 110);
  assert.deepEqual(contradicted.reconciliation, {
    lineItemsMatchSubtotal: null,
    componentsMatchTotal: false,
    needsReview: true,
  });

  // A printed subtotal the lines contradict blocks calculating the missing total.
  const noTotal = validateExtraction(
    canonical({ lines: [40, 50], subtotal: 100, tax: 5, shipping: 5, evidence: CLEAN }),
  );
  assert.equal(noTotal.header.total.value, null);
  assert.equal(noTotal.reconciliation?.needsReview, true);
});

test("a document total that the extracted lines do not explain is kept, flagged, and reviewed", async () => {
  // The same layout with a row the parser cannot read (an unrecognized status word).
  const text = (await fixture("displaced-two-page-order")).replace(
    "10 SHIPPING .77",
    "10 ALLOCATED .77",
  );
  const { extraction } = await extract(text);
  assert.equal(extraction.items.length, 4);
  // The total is still the document's own number, at review-level confidence, never a sum
  // of the four lines that were read (158.65).
  assert.deepEqual(extraction.header.total, {
    value: 166.35,
    confidence: 65,
    source: "Parser",
    reviewed: false,
  });
  assert.equal(extraction.header.subtotal.value, null);
  assert.deepEqual(extraction.reconciliation, {
    lineItemsMatchSubtotal: null,
    componentsMatchTotal: false,
    needsReview: true,
  });
  assert.ok(extraction.quality?.reasonCodes.includes("FINANCIAL_MISMATCH"));
  assert.notEqual(extraction.quality?.state, "STRUCTURED_SUCCESS");
  assert.ok((extraction.financialEvidence?.unexplainedAmounts ?? 0) > 0);
});

test("an unknown charge, discount, or other unexplained amount prevents calculating totals", async () => {
  const base =
    "Regional Medical Company\nInvoice: R-77\nInvoice Date: 08/07/2026\nSKU Product Quantity UOM Unit Price Amount\nR100 Exam Paper 3 roll 10.00 30.00\nTax: 2.00\nFreight: 5.00";
  for (const adjustment of [
    "Restocking fee: 4.00",
    "Discount: -5.00",
    "Deposit applied (10.00)",
    "Fuel surcharge 1.25",
    "Less credit memo CM-9 3.00",
  ]) {
    const { extraction } = await extract(`${base}\n${adjustment}`);
    assert.equal(extraction.financialEvidence?.unexplainedAmounts, 1, adjustment);
    assert.equal(extraction.header.subtotal.value, null, adjustment);
    assert.equal(extraction.header.total.value, null, adjustment);
    assert.equal(extraction.header.tax.value, 2, adjustment);
    assert.equal(extraction.header.shipping.value, 5, adjustment);
  }
  // A zero adjustment adds nothing and does not block.
  assert.equal((await extract(`${base}\nDiscount: 0.00`)).extraction.header.total.value, 37);

  // An unknown numbered charge in the displaced order layout.
  const order = (await fixture("email-near-header"))
    .replace("\nTOTAL AMOUNT\n160.56", "")
    .replace("3 TAX 10.15", "3 TAX 10.15\n4 HAZMAT FEE 12.00");
  const hazmat = await extract(order);
  assert.equal(hazmat.extraction.header.total.value, null);
  assert.equal(hazmat.extraction.header.subtotal.value, null);

  // Tax or shipping that is simply not known is not assumed to be zero.
  const unknownTax = validateExtraction(canonical({ lines: [30], shipping: 5, evidence: CLEAN }));
  assert.equal(unknownTax.header.subtotal.value, 30);
  assert.equal(unknownTax.header.total.value, null);
  const unknownShipping = validateExtraction(canonical({ lines: [30], tax: 2, evidence: CLEAN }));
  assert.equal(unknownShipping.header.total.value, null);

  // A provider that reports nothing about the document's structure gets no calculation.
  const noEvidence = validateExtraction(canonical({ lines: [30], tax: 2, shipping: 5 }));
  assert.equal(noEvidence.header.subtotal.value, null);
  assert.equal(noEvidence.header.total.value, null);
  for (const evidence of [
    { rejectedLineCandidates: 1, unexplainedAmounts: 0 },
    { rejectedLineCandidates: 0, unexplainedAmounts: 1 },
  ]) {
    const blocked = validateExtraction(canonical({ lines: [30], tax: 2, shipping: 5, evidence }));
    assert.equal(blocked.header.subtotal.value, null);
    assert.equal(blocked.header.total.value, null);
  }
});

test("a missing or unreliable line total prevents calculating the subtotal", async () => {
  // A shipped row whose extension is missing from the document, and no printed total.
  const text = (await fixture("displaced-two-page-order"))
    .replace("\n7.70\n", "\n")
    .replaceAll("\n166.35", "");
  const { extraction, diagnostics } = await extract(text);
  assert.ok(
    diagnostics.lineItemCandidates.some(
      (candidate) => candidate.value.includes("CX3003") && !candidate.accepted,
    ),
  );
  assert.ok((extraction.financialEvidence?.rejectedLineCandidates ?? 0) >= 1);
  assert.equal(extraction.header.subtotal.value, null);
  assert.equal(extraction.header.total.value, null);
  assert.equal(extraction.header.tax.value, 10.52);

  for (const lines of [
    [30, Number.NaN],
    [30, 10.005],
    [30, { value: 12, confidence: 60 }],
  ] as Array<Array<number | { value: number; confidence: number }>>) {
    const unreliable = validateExtraction(
      canonical({ lines, tax: 2, shipping: 5, evidence: CLEAN }),
    );
    assert.equal(unreliable.header.subtotal.value, null, JSON.stringify(lines));
    assert.equal(unreliable.header.total.value, null, JSON.stringify(lines));
  }
  // Even a printed total does not license a subtotal built on an unreliable line.
  const corroboratedButUnreliable = validateExtraction(
    canonical({ lines: [30, { value: 12, confidence: 60 }], tax: 2, shipping: 5, total: 49 }),
  );
  assert.equal(corroboratedButUnreliable.header.subtotal.value, null);
  // No line items at all: nothing to calculate from.
  const empty = validateExtraction(canonical({ lines: [], tax: 2, shipping: 5, evidence: CLEAN }));
  assert.equal(empty.header.subtotal.value, null);
  assert.equal(empty.header.total.value, null);
});

test("existing tax and shipping extraction is unchanged across the fixtures", async () => {
  const expected: Record<string, [number | null, number | null]> = {
    standard: [28.44, 10],
    "wrapped-description": [0, null],
    "no-po-zero-tax": [0, null],
    freight: [null, 5],
    "displaced-multi-row-order": [10, 4.25],
    "discounted-columnar-sales-invoice": [37.91, null],
    "email-near-header": [10.15, 20.45],
  };
  for (const [name, [tax, shipping]] of Object.entries(expected)) {
    const { extraction } = await extract(await fixture(name));
    assert.equal(extraction.header.tax.value, tax, name);
    assert.equal(extraction.header.shipping.value, shipping, name);
    assert.notEqual(extraction.header.tax.source, "Derived");
    assert.notEqual(extraction.header.shipping.source, "Derived");
    assert.equal(extraction.reconciliation?.needsReview, false, name);
  }
});

test(
  "the production Henry Schein document extracts every billed line, its printed total, and a calculated subtotal",
  { skip: !existsSync("/Users/aaronpowell/Downloads/81715662.pdf") },
  async () => {
    const text = await new EmbeddedPdfTextProvider().extractText(
      new Uint8Array(await readFile("/Users/aaronpowell/Downloads/81715662.pdf")),
    );
    const { extraction } = await extract(text.text);
    assert.deepEqual(
      extraction.items.map((item) => [item.sku.value, item.lineTotal.value]),
      [
        ["1439386", 20.43],
        ["3240025", 38.25],
        ["2677976", 7.7],
        ["7776538", 51.8],
        ["1519200", 33.7],
      ],
    );
    assert.equal(extraction.header.tax.value, 10.52);
    assert.equal(extraction.header.shipping.value, 3.95);
    assert.deepEqual(extraction.header.total, {
      value: 166.35,
      confidence: 94,
      source: "Parser",
      reviewed: false,
    });
    assert.deepEqual(extraction.header.subtotal, {
      value: 151.88,
      confidence: DERIVED_CONFIDENCE,
      source: "Derived",
      reviewed: false,
    });
    assert.equal(extraction.reconciliation?.needsReview, false);
  },
);
