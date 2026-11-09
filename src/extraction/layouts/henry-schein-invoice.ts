// Henry Schein invoice layout (the "INVOICE" form with a detachable remittance stub), as
// unpdf prints it. Deterministic rules only: labels, line shapes and arithmetic.
//
// The layout stacks each label above its value ("Invoice#" / "60000001 Invoice Date" /
// "01/02/26 Due Date"), repeats the identity block in a footer on every page, prints totals as a
// column of labels followed by a column of amounts, and lists lines as
//   LINE  ITEM-CODE  UNIT/SIZE  DESCRIPTION  QTY-ORDERED  QTY-SHIPPED  [CODES]  UNIT-PRICE  EXT-PRICE  [BOX SHIP-FROM]
// A line shipped as 0 carries no prices: it is backordered and billed on a later invoice.
//
// The generic rules in deterministic-invoice-provider.ts misread this layout (no invoice number,
// the ship-to block as the vendor, the merchandise total as the invoice total, no lines), so the
// provider uses these rules whenever isHenryScheinInvoiceLayout() recognizes the text.

export interface HenryScheinValue<T> {
  value: T;
  line: number;
}

export interface HenryScheinRowCandidate {
  line: number;
  accepted: boolean;
  reason:
    | "HENRY_SCHEIN_ROW_ARITHMETIC_MATCH"
    | "HENRY_SCHEIN_ROW_ARITHMETIC_MISMATCH"
    | "HENRY_SCHEIN_ROW_UNRECOGNIZED"
    | "HENRY_SCHEIN_NOT_SHIPPED";
  value: string;
  quantity?: number;
  unitPrice?: number;
  expectedExtension?: number;
}

export interface HenryScheinRow {
  lineNumber: number;
  sku: string;
  unitSize: string;
  unit: string;
  description: string;
  quantityOrdered: number;
  quantity: number;
  unitPrice: number;
  lineTotal: number;
  sourceLine: number;
}

export interface HenryScheinInvoiceLayout {
  invoiceNumbers: string[];
  invoiceNumber: HenryScheinValue<string> | null;
  invoiceDate: HenryScheinValue<string> | null;
  purchaseOrder: HenryScheinValue<string> | null;
  headerTotal: HenryScheinValue<number> | null;
  subtotal: HenryScheinValue<number> | null;
  tax: HenryScheinValue<number> | null;
  shipping: HenryScheinValue<number> | null;
  total: HenryScheinValue<number> | null;
  totalsLines: number[];
  unknownTotalLabels: string[];
  rows: HenryScheinRow[];
  candidates: HenryScheinRowCandidate[];
  reasons: string[];
}

export const HENRY_SCHEIN_VENDOR_NAME = "Henry Schein, Inc.";

const REMIT = /please\s+remit\s+payments\s+to:\s*henry\s+schein,\s*inc\./i;
// The header prints the label alone; per-page footers print it after the bill-to account ("1000002 Invoice#").
const INVOICE_LABEL = /(?:^|\s)invoice#$/i;
const NUMBER_THEN_DATE_LABEL = /^([A-Z0-9-]{4,20})\s+invoice\s+date:?$/i;
const DATE_THEN_LABEL = /^(\d{1,2}\/\d{1,2}\/\d{2,4})\s+(?:due\s+date|invoice\s+total)$/i;
const AMOUNT_LINE = /^\$?\*?\s*-?[\d,]*\.\d{2}$/;
const ROW_START = /^(\d{1,3})\s+([A-Z0-9]{2,5}-[A-Z0-9]{3,6})\s+/;
// Codes are single-character flags such as T, *, $, C, M, B, W (never digits).
const PRICED_ROW =
  /^(\d{1,3})\s+([A-Z0-9]{2,5}-[A-Z0-9]{3,6})\s+(\S+)\s+(.+?)\s+(\d+)\s+(\d+)((?:\s+[^\s\d.,]\S{0,2})*)\s+([\d,]*\.\d{2})\s+([\d,]*\.\d{2})(?:\s+(\d+)\s+([A-Z]{2}))?$/;
const UNSHIPPED_ROW =
  /^(\d{1,3})\s+([A-Z0-9]{2,5}-[A-Z0-9]{3,6})\s+(\S+)\s+(.+?)\s+(\d+)\s+0((?:\s+[^\s\d.,]\S{0,2})*)$/;

const money = (value: string) => Number(value.replace(/[$*,\s]/g, ""));
const cents = (value: number) => Math.round(value * 100);

export function isHenryScheinInvoiceLayout(lines: string[]): boolean {
  return lines.some((line) => REMIT.test(line)) && lines.some((line) => INVOICE_LABEL.test(line));
}

export function normalizeHenryScheinDate(value: string): string {
  const match = value.match(/^(\d{1,2})\/(\d{1,2})\/(\d{2}|\d{4})$/);
  if (!match) return "";
  const year = match[3].length === 2 ? `20${match[3]}` : match[3];
  const iso = `${year}-${match[1].padStart(2, "0")}-${match[2].padStart(2, "0")}`;
  const date = new Date(`${iso}T00:00:00Z`);
  return !Number.isNaN(date.valueOf()) && date.toISOString().slice(0, 10) === iso ? iso : "";
}

/** Every invoice number the identity blocks (header and per-page footers) print, in order. */
export function henryScheinInvoiceNumbers(
  lines: string[],
): Array<{ value: string; line: number; date: string; dateLine: number }> {
  const found: Array<{ value: string; line: number; date: string; dateLine: number }> = [];
  for (let index = 0; index < lines.length - 1; index++) {
    if (!INVOICE_LABEL.test(lines[index])) continue;
    const number = lines[index + 1].match(NUMBER_THEN_DATE_LABEL);
    if (!number) continue;
    const date = lines[index + 2]?.match(DATE_THEN_LABEL);
    found.push({
      value: number[1].toUpperCase(),
      line: index + 1,
      date: date ? normalizeHenryScheinDate(date[1]) : "",
      dateLine: index + 2,
    });
  }
  return found;
}

function headerTotal(lines: string[]): HenryScheinValue<number> | null {
  for (let index = 0; index < lines.length - 1; index++) {
    if (!/\binvoice\s+total$/i.test(lines[index]) || !/^\S+\s+invoice\s+total$/i.test(lines[index]))
      continue;
    const next = lines[index + 1];
    if (AMOUNT_LINE.test(next)) return { value: money(next), line: index + 1 };
  }
  return null;
}

function purchaseOrder(lines: string[]): HenryScheinValue<string> | null {
  for (let index = 0; index < lines.length - 1; index++) {
    if (!/^purchase\s+order#$/i.test(lines[index])) continue;
    const match = lines[index + 1].match(/^(.*?)\s*payment\s+terms$/i);
    if (match) return { value: match[1].trim(), line: index + 1 };
  }
  return null;
}

// "MERCHANDISE TOTAL / SALES TAX / INVOICE TOTAL" then "$a / $b / $c". A label line may carry its
// amount inline ("INVOICE TOTAL $46.61"); that amount takes its place in the value column.
function totals(lines: string[]) {
  const start = lines.findIndex((line) => /^merchandise\s+total\b/i.test(line));
  const result = {
    subtotal: null as HenryScheinValue<number> | null,
    tax: null as HenryScheinValue<number> | null,
    shipping: null as HenryScheinValue<number> | null,
    total: null as HenryScheinValue<number> | null,
    lines: [] as number[],
    unknown: [] as string[],
    aligned: false,
  };
  if (start < 0) return result;
  const labels: Array<{ label: string; line: number }> = [];
  const values: HenryScheinValue<number>[] = [];
  let index = start;
  for (; index < lines.length && !AMOUNT_LINE.test(lines[index]); index++) {
    const inline = lines[index].match(/^(.*?[A-Za-z])\s+(\$?\*?[\d,]*\.\d{2})$/);
    labels.push({
      label: (inline ? inline[1] : lines[index]).replace(/^\*/, "").trim(),
      line: index,
    });
    if (inline) values.push({ value: money(inline[2]), line: index });
    result.lines.push(index);
    if (labels.length > 8) return result;
  }
  for (
    ;
    index < lines.length && AMOUNT_LINE.test(lines[index]) && values.length < labels.length;
    index++
  ) {
    values.push({ value: money(lines[index]), line: index });
    result.lines.push(index);
  }
  if (values.length !== labels.length) return result;
  result.aligned = true;
  let shipping = 0;
  let shippingLine = -1;
  labels.forEach(({ label }, position) => {
    const value = values[position];
    if (/^merchandise\s+total$/i.test(label)) result.subtotal = value;
    else if (/^(?:sales\s+)?tax$/i.test(label)) result.tax = value;
    else if (/^(?:freight|shipping|handling)(?:\s+(?:and\s+handling|charges?))?$/i.test(label)) {
      shipping += cents(value.value);
      shippingLine = value.line;
    } else if (/^invoice\s+total$/i.test(label)) result.total = value;
    else if (/^(?:paid\s+by\s+credit\s+card|balance\s+due)$/i.test(label)) {
      /* settlement, not a charge */
    } else result.unknown.push(label);
  });
  if (shippingLine >= 0) result.shipping = { value: shipping / 100, line: shippingLine };
  return result;
}

function rows(lines: string[]) {
  const accepted: HenryScheinRow[] = [];
  const candidates: HenryScheinRowCandidate[] = [];
  lines.forEach((line, index) => {
    if (!ROW_START.test(line)) return;
    const priced = line.match(PRICED_ROW);
    if (!priced) {
      if (UNSHIPPED_ROW.test(line))
        candidates.push({
          line: index,
          accepted: false,
          reason: "HENRY_SCHEIN_NOT_SHIPPED",
          value: line,
        });
      else
        candidates.push({
          line: index,
          accepted: false,
          reason: "HENRY_SCHEIN_ROW_UNRECOGNIZED",
          value: line,
        });
      return;
    }
    const [
      ,
      lineNumber,
      sku,
      unitSize,
      description,
      ordered,
      shipped,
      ,
      unitPriceText,
      extensionText,
    ] = priced;
    const quantity = Number(shipped);
    const unitPrice = money(unitPriceText);
    const lineTotal = money(extensionText);
    const expectedExtension = cents(quantity * unitPrice) / 100;
    const ok =
      quantity > 0 &&
      Math.abs(cents(expectedExtension) - cents(lineTotal)) <= 2 &&
      description.trim().length >= 2;
    candidates.push({
      line: index,
      accepted: ok,
      reason: ok ? "HENRY_SCHEIN_ROW_ARITHMETIC_MATCH" : "HENRY_SCHEIN_ROW_ARITHMETIC_MISMATCH",
      value: line,
      quantity,
      unitPrice,
      expectedExtension,
    });
    if (!ok) return;
    accepted.push({
      lineNumber: Number(lineNumber),
      sku,
      unitSize,
      unit: unitSize.includes("/") ? (unitSize.split("/").at(-1) ?? unitSize) : unitSize,
      description: description.trim(),
      quantityOrdered: Number(ordered),
      quantity,
      unitPrice,
      lineTotal,
      sourceLine: index,
    });
  });
  return { accepted, candidates };
}

export function parseHenryScheinInvoiceLayout(lines: string[]): HenryScheinInvoiceLayout {
  const identities = henryScheinInvoiceNumbers(lines);
  const invoiceNumbers = [...new Set(identities.map((identity) => identity.value))];
  const reasons: string[] = [];
  const single = invoiceNumbers.length === 1;
  if (invoiceNumbers.length > 1) reasons.push("HENRY_SCHEIN_MULTIPLE_INVOICE_NUMBERS");
  if (!invoiceNumbers.length) reasons.push("HENRY_SCHEIN_INVOICE_NUMBER_MISSING");
  const first = identities[0];
  const dated = identities.find((identity) => identity.date);
  const block = totals(lines);
  if (!block.aligned && lines.some((line) => /^merchandise\s+total\b/i.test(line)))
    reasons.push("HENRY_SCHEIN_TOTALS_UNALIGNED");
  if (block.unknown.length) reasons.push("HENRY_SCHEIN_UNKNOWN_TOTAL_LABEL");
  const printedTotal = headerTotal(lines);
  // Several invoices in one text (a packet uploaded as a single document) must never merge their
  // lines and totals into one invoice: identity, totals and lines are withheld for manual review.
  const { accepted, candidates } = single ? rows(lines) : { accepted: [], candidates: [] };
  return {
    invoiceNumbers,
    invoiceNumber: single && first ? { value: first.value, line: first.line } : null,
    invoiceDate: single && dated ? { value: dated.date, line: dated.dateLine } : null,
    purchaseOrder: single ? purchaseOrder(lines) : null,
    headerTotal: single ? printedTotal : null,
    subtotal: single ? block.subtotal : null,
    tax: single ? block.tax : null,
    shipping: single ? block.shipping : null,
    total: single ? (block.total ?? printedTotal) : null,
    totalsLines: single ? block.lines : [],
    unknownTotalLabels: block.unknown,
    rows: accepted,
    candidates,
    reasons,
  };
}
