import { DERIVED_CONFIDENCE } from "../extraction/totals.ts";
import type {
  CanonicalInvoiceExtraction,
  ExtractedField,
  ExtractedInvoiceItem,
} from "../extraction/types.ts";
import { validateExtraction } from "../extraction/validation.ts";

export type DerivedTotalKey = "subtotal" | "total";
const DERIVED_KEYS: DerivedTotalKey[] = ["subtotal", "total"];

export interface CurrentInvoiceAmounts {
  subtotal: number | null;
  tax: number | null;
  shipping: number | null;
  total: number | null;
}

export interface CurrentInvoiceLine {
  description: string;
  quantity: number;
  unitPrice: number | null;
  totalPrice: number | null;
}

export interface DerivedTotalsRefresh {
  // The stored extraction with its calculated fields and reconciliation brought up to date.
  extraction: CanonicalInvoiceExtraction;
  // Only the calculated fields appear here; a printed or owner-entered amount is never returned.
  amounts: Partial<Record<DerivedTotalKey, number | null>>;
  changed: boolean;
}

/** Header totals this invoice holds as calculations, whether or not one currently has a value. */
export function derivedTotalKeys(
  extraction: CanonicalInvoiceExtraction | null | undefined,
): DerivedTotalKey[] {
  if (!extraction) return [];
  return DERIVED_KEYS.filter((key) => extraction.header[key]?.source === "Derived");
}

const entered = <T>(value: T): ExtractedField<T> => ({
  value,
  confidence: 100,
  source: "User",
  reviewed: true,
});

/**
 * Recalculates an invoice's calculated subtotal and total from the invoice as it stands now.
 *
 * There is no second algorithm here. The current header amounts and line items are put into a
 * canonical extraction and run through validateExtraction, the same path that calculated the
 * amounts at extraction time, with the document evidence recorded at extraction. So every
 * extraction-time rule still applies: integer cents, reliable line totals only, tax and
 * shipping both known for a total, nothing unexplained in the document, and a printed total
 * that must agree with the lines.
 *
 * Only fields whose stored source is 'Derived' are recalculated. If one can no longer be
 * calculated safely it is withdrawn (null, unreviewed) rather than left as it was. A field
 * that was printed on the document or entered by the owner is never changed, and a field
 * that was never calculated is never filled in.
 *
 * ownerEntered carries the subtotal and total an owner just saved on the header form: a
 * calculated field the owner changed becomes the owner's value and stops being recalculated.
 */
export function recalculateDerivedTotals(
  stored: CanonicalInvoiceExtraction,
  amounts: CurrentInvoiceAmounts,
  lines: CurrentInvoiceLine[],
  ownerEntered?: Partial<Record<DerivedTotalKey, number | null>>,
): DerivedTotalsRefresh {
  const next = structuredClone(stored);
  if (ownerEntered) {
    for (const key of derivedTotalKeys(next)) {
      if (key in ownerEntered && ownerEntered[key] !== next.header[key].value) {
        next.header[key] = entered(ownerEntered[key] ?? null);
      }
    }
  }
  const managed = derivedTotalKeys(next);
  if (!managed.length) {
    return {
      extraction: next,
      amounts: {},
      changed: JSON.stringify(next.header) !== JSON.stringify(stored.header),
    };
  }

  // The invoice as it stands: current amounts for everything that is not a calculation,
  // current line items, and the evidence the document gave at extraction.
  const current = structuredClone(next);
  const header = current.header;
  if (!managed.includes("subtotal")) header.subtotal.value = amounts.subtotal;
  if (!managed.includes("total")) header.total.value = amounts.total;
  header.tax.value = amounts.tax;
  header.shipping.value = amounts.shipping;
  current.items = lines.map(
    (line): ExtractedInvoiceItem => ({
      sku: entered(""),
      description: entered(line.description.trim() || "Line item"),
      manufacturer: entered(""),
      quantity: entered(line.quantity),
      unit: entered(""),
      unitPrice: entered(line.unitPrice as number),
      lineTotal: entered(line.totalPrice as number),
      suggestedCategory: entered(""),
    }),
  );

  let calculable = true;
  try {
    validateExtraction(current);
  } catch {
    // A line or amount the canonical validator rejects: nothing can be calculated from it.
    calculable = false;
  }

  const result: DerivedTotalsRefresh["amounts"] = {};
  for (const key of managed) {
    const calculated = calculable && header[key].source === "Derived" ? header[key].value : null;
    const previous = next.header[key];
    result[key] = calculated;
    next.header[key] =
      calculated === null
        ? { value: null, confidence: 0, source: "Derived", reviewed: false }
        : {
            value: calculated,
            confidence: DERIVED_CONFIDENCE,
            source: "Derived",
            // A recalculated amount that changed has not been reviewed.
            reviewed: previous.value === calculated ? previous.reviewed : false,
          };
  }
  if (calculable) next.reconciliation = current.reconciliation;

  return {
    extraction: next,
    amounts: result,
    changed:
      JSON.stringify(next.header) !== JSON.stringify(stored.header) ||
      JSON.stringify(next.reconciliation) !== JSON.stringify(stored.reconciliation) ||
      managed.some((key) => result[key] !== amounts[key]),
  };
}
