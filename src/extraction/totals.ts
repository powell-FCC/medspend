import type {
  CanonicalInvoiceExtraction,
  ExtractedField,
  ExtractionReconciliation,
} from "./types.ts";

// Existing reconciliation convention: amounts agree when they are within two cents.
export const MONEY_TOLERANCE_CENTS = 2;
// Below the review form's 75% threshold, so a calculated amount always reads "Review suggested".
export const DERIVED_CONFIDENCE = 60;
const RELIABLE_LINE_CONFIDENCE = 75;

/** Whole cents for a non-negative amount with at most two decimals; null for anything else. */
export function toCents(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) return null;
  const cents = Math.round(value * 100);
  return Number.isSafeInteger(cents) && Math.abs(value * 100 - cents) < 1e-6 ? cents : null;
}

export const fromCents = (cents: number) => cents / 100;

// A printed amount that is not valid money compares as NaN: it never matches and never derives.
const printedCents = (field: ExtractedField<number | null>) =>
  field.value === null ? null : (toCents(field.value) ?? Number.NaN);
const known = (cents: number | null): cents is number => cents !== null && !Number.isNaN(cents);
const within = (left: number, right: number) => Math.abs(left - right) <= MONEY_TOLERANCE_CENTS;

/**
 * Compares the document's printed amounts with its line items and, only when it is safe, fills a
 * missing subtotal or total by calculation. Printed values are never replaced. Arithmetic is in
 * integer cents.
 *
 * Subtotal = sum of line totals, when every line total is reliable and either
 *   - the printed total equals line items + tax + shipping (the document corroborates the lines), or
 *   - no total is printed and the provider reports nothing unexplained in the document.
 * Total = subtotal + tax + shipping, when no total is printed, tax and shipping are both known,
 *   the line items do not contradict a printed subtotal, and nothing in the document is unexplained.
 */
export function reconcileInvoiceTotals(
  extraction: CanonicalInvoiceExtraction,
): ExtractionReconciliation {
  const { subtotal, tax, shipping, total } = extraction.header;
  // Validating twice must not mistake an earlier calculation for a printed value.
  for (const field of [subtotal, total]) {
    if (field.source === "Derived") {
      field.value = null;
      field.confidence = 0;
    }
  }

  const hasItems = extraction.items.length > 0;
  const lineCents = extraction.items.map((item) => toCents(item.lineTotal.value));
  const itemSum = lineCents.every((cents) => cents !== null)
    ? lineCents.reduce<number>((sum, cents) => sum + (cents ?? 0), 0)
    : null;
  const subtotalCents = printedCents(subtotal);
  const totalCents = printedCents(total);
  const taxCents = printedCents(tax);
  const shippingCents = printedCents(shipping);

  const lineItemsMatchSubtotal =
    subtotalCents === null || !hasItems ? null : itemSum !== null && within(itemSum, subtotalCents);
  const base = subtotalCents ?? (hasItems ? itemSum : null);
  const componentsMatchTotal =
    totalCents === null || base === null
      ? null
      : within(base + (taxCents ?? 0) + (shippingCents ?? 0), totalCents);

  const evidence = extraction.financialEvidence;
  const nothingUnexplained =
    evidence !== undefined &&
    evidence.rejectedLineCandidates === 0 &&
    evidence.unexplainedAmounts === 0;
  const linesReliable =
    hasItems &&
    itemSum !== null &&
    extraction.items.every((item) => item.lineTotal.confidence >= RELIABLE_LINE_CONFIDENCE);
  const derive = (field: ExtractedField<number | null>, cents: number) => {
    field.value = fromCents(cents);
    field.confidence = DERIVED_CONFIDENCE;
    field.source = "Derived";
    field.reviewed = false;
  };

  let effectiveSubtotal = subtotalCents;
  if (
    subtotalCents === null &&
    linesReliable &&
    itemSum !== null &&
    (totalCents === null ? nothingUnexplained : componentsMatchTotal === true)
  ) {
    derive(subtotal, itemSum);
    effectiveSubtotal = itemSum;
  }
  if (
    totalCents === null &&
    known(effectiveSubtotal) &&
    known(taxCents) &&
    known(shippingCents) &&
    nothingUnexplained &&
    lineItemsMatchSubtotal !== false
  ) {
    derive(total, effectiveSubtotal + taxCents + shippingCents);
  }

  return {
    lineItemsMatchSubtotal,
    componentsMatchTotal,
    needsReview: lineItemsMatchSubtotal === false || componentsMatchTotal === false,
  };
}

/** Header totals that were calculated rather than read from the document and are not yet reviewed. */
export function derivedTotalFields(
  extraction: CanonicalInvoiceExtraction | null | undefined,
): Array<"subtotal" | "total"> {
  if (!extraction) return [];
  return (["subtotal", "total"] as const).filter((key) => {
    const field = extraction.header[key];
    return field.source === "Derived" && !field.reviewed && field.value !== null;
  });
}
