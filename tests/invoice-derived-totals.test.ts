import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { DERIVED_CONFIDENCE } from "../src/extraction/totals.ts";
import type {
  CanonicalInvoiceExtraction,
  ExtractedField,
  ExtractionFinancialEvidence,
  ExtractionSource,
} from "../src/extraction/types.ts";
import { validateExtraction } from "../src/extraction/validation.ts";
import {
  derivedTotalKeys,
  recalculateDerivedTotals,
  type CurrentInvoiceLine,
} from "../src/invoice/derived-totals.ts";
import {
  INVENTORY_SKU_CONFLICT_MESSAGE,
  InvoiceReviewError,
  MAPPING_CONFLICT_MESSAGE,
  NOT_DEPLOYED_MESSAGE,
  toInvoiceReviewError,
} from "../src/invoice/review-actions.ts";

const read = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");
const field = <T>(
  value: T,
  source: ExtractionSource = "Parser",
  confidence = 94,
): ExtractedField<T> => ({
  value,
  confidence,
  source,
  reviewed: false,
});
const CLEAN: ExtractionFinancialEvidence = { rejectedLineCandidates: 0, unexplainedAmounts: 0 };
const line = (
  quantity: number,
  unitPrice: number,
  totalPrice = quantity * unitPrice,
): CurrentInvoiceLine => ({
  description: "Line",
  quantity,
  unitPrice,
  totalPrice,
});

// An extraction as stored after validateExtraction, built from what the document printed.
function stored(options: {
  lines: number[];
  subtotal?: number | null;
  tax?: number | null;
  shipping?: number | null;
  total?: number | null;
  evidence?: ExtractionFinancialEvidence;
}): CanonicalInvoiceExtraction {
  const amount = (value: number | null | undefined) =>
    field(value ?? null, "Parser", value == null ? 0 : 94);
  return validateExtraction({
    header: {
      vendor: field("Example Medical Supply"),
      invoiceNumber: field("INV-1"),
      invoiceDate: field("2026-09-17"),
      purchaseOrder: field(""),
      subtotal: amount(options.subtotal),
      tax: amount(options.tax),
      shipping: amount(options.shipping),
      total: amount(options.total),
    },
    items: options.lines.map((value, index) => ({
      sku: field(`SKU-${index + 1}`),
      description: field(`Item ${index + 1}`),
      manufacturer: field("", "Parser", 0),
      quantity: field(1),
      unit: field("each"),
      unitPrice: field(value),
      lineTotal: field(value, "Parser", 98),
      suggestedCategory: field("", "Parser", 0),
    })),
    financialEvidence: options.evidence ?? CLEAN,
  });
}
const derived = (value: number | null, reviewed = false) =>
  value === null
    ? { value: null, confidence: 0, source: "Derived", reviewed: false }
    : { value, confidence: DERIVED_CONFIDENCE, source: "Derived", reviewed };

// No total printed: subtotal 30 and total 37 are both calculated.
const bothCalculated = () => stored({ lines: [20, 10], tax: 2, shipping: 5 });
// Total 37 printed: only the subtotal is calculated.
const subtotalCalculated = () => stored({ lines: [20, 10], tax: 2, shipping: 5, total: 37 });
const printed = () => stored({ lines: [20, 10], subtotal: 30, tax: 2, shipping: 5, total: 37 });
const amounts = (
  subtotal: number | null,
  total: number | null,
  tax: number | null = 2,
  shipping: number | null = 5,
) => ({
  subtotal,
  tax,
  shipping,
  total,
});

test("fixtures: which totals are calculations", () => {
  assert.deepEqual(derivedTotalKeys(bothCalculated()), ["subtotal", "total"]);
  assert.deepEqual(derivedTotalKeys(subtotalCalculated()), ["subtotal"]);
  assert.deepEqual(derivedTotalKeys(printed()), []);
  assert.deepEqual(derivedTotalKeys(null), []);
  assert.deepEqual(bothCalculated().header.total, derived(37));
});

test("a calculated subtotal and total follow a quantity or price edit", () => {
  const refresh = recalculateDerivedTotals(bothCalculated(), amounts(30, 37), [
    line(3, 10.1, 30.3),
    line(1, 10),
  ]);
  assert.deepEqual(refresh.amounts, { subtotal: 40.3, total: 47.3 });
  assert.deepEqual(refresh.extraction.header.subtotal, derived(40.3));
  assert.deepEqual(refresh.extraction.header.total, derived(47.3));
  assert.equal(refresh.changed, true);
  assert.equal(refresh.extraction.reconciliation?.needsReview, false);
  // Nothing else in the stored extraction is rewritten.
  const before = bothCalculated();
  assert.deepEqual(refresh.extraction.header.tax, before.header.tax);
  assert.deepEqual(refresh.extraction.items, before.items);
  assert.deepEqual(refresh.extraction.quality, before.quality);
  assert.deepEqual(refresh.extraction.financialEvidence, before.financialEvidence);
});

test("deleting and adding lines recalculate, in whole cents", () => {
  const afterDelete = recalculateDerivedTotals(bothCalculated(), amounts(30, 37), [line(2, 10)]);
  assert.deepEqual(afterDelete.amounts, { subtotal: 20, total: 27 });
  const afterAdd = recalculateDerivedTotals(bothCalculated(), amounts(30, 37), [
    line(2, 10),
    line(1, 10),
    line(1, 4.35),
    line(1, 4.35),
    line(1, 4.35),
  ]);
  assert.notEqual(20 + 10 + 4.35 + 4.35 + 4.35, 43.05);
  assert.deepEqual(afterAdd.amounts, { subtotal: 43.05, total: 50.05 });
  // No lines left: nothing to calculate from.
  const empty = recalculateDerivedTotals(bothCalculated(), amounts(30, 37), []);
  assert.deepEqual(empty.amounts, { subtotal: null, total: null });
  assert.deepEqual(empty.extraction.header.subtotal, derived(null));
});

test("the same rules as extraction: the recalculation is the canonical validator", () => {
  // Whatever lines the invoice has now, recalculating gives exactly what extraction would
  // have calculated for a document with those lines.
  for (const lines of [[20, 10], [12.34, 0.01, 99.99], [4.35, 4.35, 4.35], [100]]) {
    const fromExtraction = stored({ lines, tax: 2, shipping: 5 });
    const recalculated = recalculateDerivedTotals(
      bothCalculated(),
      amounts(30, 37),
      lines.map((value) => line(1, value)),
    );
    assert.deepEqual(
      recalculated.extraction.header.subtotal,
      fromExtraction.header.subtotal,
      JSON.stringify(lines),
    );
    assert.deepEqual(
      recalculated.extraction.header.total,
      fromExtraction.header.total,
      JSON.stringify(lines),
    );
    assert.deepEqual(recalculated.extraction.reconciliation, fromExtraction.reconciliation);
  }
  // And there is one implementation: this module adds no arithmetic of its own.
  const source = read("../src/invoice/derived-totals.ts").replace(/\/\*[\s\S]*?\*\/|\/\/.*$/gm, "");
  assert.match(source, /validateExtraction\(current\)/);
  assert.doesNotMatch(
    source,
    /reduce\(|toCents|Math\.|[-+*/] *100\b|\+ *amounts\.|\.tax *\+|\.shipping *\+/,
  );
  const actions = read("../src/invoice/review-actions.ts").replace(
    /\/\*[\s\S]*?\*\/|\/\/.*$/gm,
    "",
  );
  assert.match(actions, /recalculateDerivedTotals\(/);
  assert.doesNotMatch(actions, /reduce\(|toCents|Math\./);
});

test("a printed subtotal or total is never changed by a line change", () => {
  const everythingChanged = [line(5, 10), line(1, 7)];
  const none = recalculateDerivedTotals(printed(), amounts(30, 37), everythingChanged);
  assert.deepEqual(none.amounts, {});
  assert.equal(none.changed, false);
  assert.deepEqual(none.extraction, printed());

  // A printed total beside a calculated subtotal: the total stands. The subtotal is
  // withdrawn, not recalculated to 57, because the lines no longer agree with the document.
  const partial = recalculateDerivedTotals(
    subtotalCalculated(),
    amounts(30, 37),
    everythingChanged,
  );
  assert.deepEqual(partial.amounts, { subtotal: null });
  assert.ok(!("total" in partial.amounts));
  assert.deepEqual(partial.extraction.header.total, subtotalCalculated().header.total);
  assert.equal(partial.extraction.header.total.source, "Parser");
  assert.deepEqual(partial.extraction.header.subtotal, derived(null));
  assert.equal(partial.extraction.reconciliation?.needsReview, true);
  // Lines that still agree with the printed total keep the calculation.
  const agreeing = recalculateDerivedTotals(subtotalCalculated(), amounts(30, 37), [
    line(1, 12),
    line(1, 18),
  ]);
  assert.deepEqual(agreeing.amounts, { subtotal: 30 });
  assert.equal(agreeing.changed, false);

  // A printed subtotal the owner corrected on the form is used as it stands now.
  const printedSubtotal = stored({ lines: [20, 10], subtotal: 30, tax: 2, shipping: 5 });
  assert.deepEqual(derivedTotalKeys(printedSubtotal), ["total"]);
  const corrected = recalculateDerivedTotals(printedSubtotal, amounts(35, 37), [
    line(1, 20),
    line(1, 15),
  ]);
  assert.deepEqual(corrected.amounts, { total: 42 });
  assert.equal(corrected.extraction.header.subtotal.source, "Parser");
});

test("an unexplained amount or an unreliable line withdraws the calculation instead of updating it", () => {
  // The document had an amount nothing explains. With no printed total to corroborate the
  // lines, nothing may be calculated, whatever the lines now say.
  const ambiguous = bothCalculated();
  ambiguous.financialEvidence = { rejectedLineCandidates: 0, unexplainedAmounts: 1 };
  for (const lines of [[line(2, 10), line(1, 10)], [line(3, 10)]]) {
    const refresh = recalculateDerivedTotals(ambiguous, amounts(30, 37), lines);
    assert.deepEqual(refresh.amounts, { subtotal: null, total: null });
    assert.deepEqual(refresh.extraction.header.subtotal, derived(null));
    assert.deepEqual(refresh.extraction.header.total, derived(null));
  }
  const rejected = bothCalculated();
  rejected.financialEvidence = { rejectedLineCandidates: 1, unexplainedAmounts: 0 };
  assert.deepEqual(recalculateDerivedTotals(rejected, amounts(30, 37), [line(3, 10)]).amounts, {
    subtotal: null,
    total: null,
  });
  const noEvidence = bothCalculated();
  delete noEvidence.financialEvidence;
  assert.deepEqual(recalculateDerivedTotals(noEvidence, amounts(30, 37), [line(3, 10)]).amounts, {
    subtotal: null,
    total: null,
  });

  // A line whose total does not follow from its quantity and price, a line with no total,
  // an amount that is not money, and a line the validator rejects outright.
  for (const lines of [
    [line(2, 10), line(2, 4.35, 5)],
    [line(2, 10), { description: "No total", quantity: 1, unitPrice: 10, totalPrice: null }],
    [line(2, 10), line(1, 10.005)],
    [line(2, 10), line(0, 10, 10)],
    [line(2, 10), line(1, -1)],
  ] as CurrentInvoiceLine[][]) {
    const refresh = recalculateDerivedTotals(bothCalculated(), amounts(30, 37), lines);
    assert.deepEqual(refresh.amounts, { subtotal: null, total: null }, JSON.stringify(lines));
    assert.equal(refresh.changed, true);
  }
  // Tax or shipping no longer known: the subtotal stands, the total is withdrawn.
  assert.deepEqual(
    recalculateDerivedTotals(bothCalculated(), amounts(30, 37, null, 5), [line(2, 10), line(1, 10)])
      .amounts,
    { subtotal: 30, total: null },
  );
  assert.deepEqual(
    recalculateDerivedTotals(bothCalculated(), amounts(30, 37, 2, null), [line(2, 10), line(1, 10)])
      .amounts,
    { subtotal: 30, total: null },
  );
});

test("a stale calculated value cannot survive: every outcome is recalculated or withdrawn", () => {
  const cases: CurrentInvoiceLine[][] = [
    [line(3, 10), line(1, 10)],
    [line(1, 10)],
    [],
    [line(2, 10), line(1, 10), line(1, 0.01)],
    [line(2, 10), line(2, 4.35, 5)],
  ];
  for (const lines of cases) {
    const refresh = recalculateDerivedTotals(bothCalculated(), amounts(30, 37), lines);
    const reliable =
      lines.length > 0 &&
      lines.every(
        (entry) =>
          Math.abs(entry.quantity * (entry.unitPrice ?? 0) - (entry.totalPrice ?? 0)) < 0.005,
      );
    const cents = lines.reduce((sum, entry) => sum + Math.round((entry.totalPrice ?? 0) * 100), 0);
    const expected = reliable
      ? { subtotal: cents / 100, total: (cents + 700) / 100 }
      : { subtotal: null, total: null };
    assert.deepEqual(refresh.amounts, expected, JSON.stringify(lines));
    // The old values are gone unless they are still exactly right.
    assert.notDeepEqual(refresh.amounts, { subtotal: 30, total: 37 });
    for (const key of ["subtotal", "total"] as const) {
      assert.equal(refresh.extraction.header[key].source, "Derived");
      assert.equal(refresh.extraction.header[key].reviewed, false);
      assert.ok(refresh.extraction.header[key].confidence < 75, "stays review-suggested");
    }
  }
  // A value already withdrawn comes back when the invoice can be calculated again.
  const withdrawn = recalculateDerivedTotals(bothCalculated(), amounts(30, 37), [
    line(2, 4.35, 5),
  ]).extraction;
  assert.deepEqual(derivedTotalKeys(withdrawn), ["subtotal", "total"]);
  assert.deepEqual(
    recalculateDerivedTotals(withdrawn, amounts(null, null), [line(2, 10), line(1, 10)]).amounts,
    { subtotal: 30, total: 37 },
  );
});

test("review state: unchanged amounts keep it, changed amounts lose it, an owner's amount is the owner's", () => {
  const reviewed = bothCalculated();
  reviewed.header.subtotal.reviewed = true;
  reviewed.header.total.reviewed = true;
  // Tax changed on the header form; the form was saved with the calculated amounts as shown.
  const taxChanged = recalculateDerivedTotals(
    reviewed,
    amounts(30, 37, 3, 5),
    [line(2, 10), line(1, 10)],
    { subtotal: 30, total: 37 },
  );
  assert.deepEqual(taxChanged.amounts, { subtotal: 30, total: 38 });
  assert.deepEqual(taxChanged.extraction.header.subtotal, derived(30, true));
  assert.deepEqual(taxChanged.extraction.header.total, derived(38, false));

  // The owner typed a different total: it is theirs now, and is never recalculated again.
  // It no longer agrees with lines + tax + shipping (37), so the calculated subtotal beside
  // it is withdrawn and the invoice is flagged, exactly as for a printed total.
  const overridden = recalculateDerivedTotals(
    reviewed,
    amounts(30, 40),
    [line(2, 10), line(1, 10)],
    { subtotal: 30, total: 40 },
  );
  assert.deepEqual(overridden.amounts, { subtotal: null });
  assert.equal(overridden.extraction.reconciliation?.needsReview, true);
  assert.deepEqual(overridden.extraction.header.total, {
    value: 40,
    confidence: 100,
    source: "User",
    reviewed: true,
  });
  assert.deepEqual(derivedTotalKeys(overridden.extraction), ["subtotal"]);
  const later = recalculateDerivedTotals(overridden.extraction, amounts(30, 40), [line(5, 10)]);
  assert.ok(!("total" in later.amounts));
  assert.equal(later.extraction.header.total.value, 40);
  // The owner cleared a calculated amount: it stays cleared.
  const cleared = recalculateDerivedTotals(
    reviewed,
    amounts(null, 37),
    [line(2, 10), line(1, 10)],
    { subtotal: null, total: 37 },
  );
  assert.deepEqual(cleared.extraction.header.subtotal, {
    value: null,
    confidence: 100,
    source: "User",
    reviewed: true,
  });
  assert.ok(
    !(
      "subtotal" in
      recalculateDerivedTotals(cleared.extraction, amounts(null, 37), [line(9, 10)]).amounts
    ),
  );
  // A total that was never calculated or printed is never filled in.
  const neverCalculated = stored({
    lines: [20, 10],
    tax: 2,
    shipping: 5,
    evidence: { rejectedLineCandidates: 0, unexplainedAmounts: 1 },
  });
  assert.deepEqual(derivedTotalKeys(neverCalculated), []);
  assert.deepEqual(
    recalculateDerivedTotals(neverCalculated, amounts(null, null), [line(2, 10), line(1, 10)])
      .amounts,
    {},
  );
});

test("database errors become reviewer-facing errors, and nothing raw passes through", () => {
  // Messages our own functions raise on purpose pass through.
  const domain = toInvoiceReviewError(
    {
      code: "P0001",
      message: "This line's product match has changed; reload the invoice before changing it",
    },
    "fallback",
  );
  assert.ok(domain instanceof InvoiceReviewError);
  assert.deepEqual(
    [domain.code, domain.message],
    ["rejected", "This line's product match has changed; reload the invoice before changing it"],
  );
  assert.equal(
    toInvoiceReviewError({ code: "P0001", message: "Forbidden: owner access required" }, "fallback")
      .code,
    "forbidden",
  );
  assert.equal(
    toInvoiceReviewError({ code: "42501", message: "permission denied for function x" }, "fallback")
      .message,
    "Forbidden: owner access required",
  );
  const gate = toInvoiceReviewError(
    {
      code: "23502",
      message: "Match or create a product for every invoice line before approval (2 unresolved)",
    },
    "fallback",
  );
  assert.deepEqual(
    [gate.code, gate.message],
    ["rejected", "Match or create a product for every invoice line before approval (2 unresolved)"],
  );

  // Constraint and trigger failures are replaced.
  const raw = [
    {
      code: "23514",
      message:
        "Organization product be120000-0000-4000-8000-000000000401 is not linked to catalog product be120000-0000-4000-8000-000000000211",
    },
    {
      code: "23505",
      message:
        'duplicate key value violates unique constraint "vendor_products_active_vendor_sku_uq"',
    },
    { code: "23503", message: "insert or update on table violates foreign key constraint" },
    { code: "23502", message: 'null value in column "product_id" violates not-null constraint' },
  ];
  for (const error of raw) {
    const translated = toInvoiceReviewError(error, "fallback");
    assert.deepEqual(
      [translated.code, translated.message],
      ["conflict", MAPPING_CONFLICT_MESSAGE],
      error.message,
    );
  }
  const inventory = toInvoiceReviewError(
    {
      code: "23505",
      message:
        'duplicate key value violates unique constraint "inventory_items_org_vendor_sku_unique"',
    },
    "fallback",
  );
  assert.deepEqual(
    [inventory.code, inventory.message],
    ["conflict", INVENTORY_SKU_CONFLICT_MESSAGE],
  );
  // A function the database does not have yet (migration not applied).
  assert.equal(
    toInvoiceReviewError(
      {
        code: "PGRST202",
        message: "Could not find the function public.match_invoice_item_to_catalog_listing",
      },
      "fallback",
    ).message,
    NOT_DEPLOYED_MESSAGE,
  );
  // Anything else, including an empty or shapeless error, gets the caller's fallback.
  for (const error of [
    { code: "XX000", message: "internal error: relation 12345" },
    { code: "P0001", message: "" },
    { message: "fetch failed" },
    {},
  ]) {
    const translated = toInvoiceReviewError(error, "Could not update the product match.");
    assert.deepEqual(
      [translated.code, translated.message],
      ["failed", "Could not update the product match."],
    );
  }
  for (const message of [
    MAPPING_CONFLICT_MESSAGE,
    INVENTORY_SKU_CONFLICT_MESSAGE,
    NOT_DEPLOYED_MESSAGE,
  ]) {
    assert.doesNotMatch(message, /constraint|duplicate key|violates|_uq|_unique|SQLSTATE/i);
  }
});
