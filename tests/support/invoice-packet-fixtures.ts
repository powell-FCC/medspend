// Sanitized structural fixtures for Phase 6C.4: Henry Schein-form invoice pages with invented
// customers, accounts, orders, items and amounts. They reproduce the printed structure of the
// real packet (stacked header labels, remittance stub on page 1, per-page identity footers,
// "Page i of N", label column then amount column for totals, backorder and split-shipment
// notices, unshipped lines) without any of its data.
import { PDFDocument, StandardFonts } from "pdf-lib";

export interface FixtureLine {
  sku: string;
  unit: string;
  description: string;
  ordered?: number;
  shipped: number;
  price: number;
  codes?: string;
}

export interface FixtureInvoice {
  number: string;
  date: string; // MM/DD/YY
  po: string;
  order: string;
  account?: string;
  /** Lines per page; the invoice has as many pages as chunks. */
  pages: FixtureLine[][];
  tax?: number;
  freight?: number;
  notes?: string[];
  /** Omit the "Page i of N" marker (malformed/missing numbering cases). */
  pageMarkers?: Array<string | null>;
  /** Omit the identity footer on these page indexes (0-based). */
  footerless?: number[];
  /** Printed amounts that disagree with the lines (reconciliation cases). */
  amounts?: { merchandise: number; tax: number; freight: number; total: number };
}

const money = (value: number) => value.toFixed(2);
const grouped = (value: number) =>
  value.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const cents = (value: number) => Math.round(value * 100);

export function lineTotal(line: FixtureLine) {
  return cents(line.shipped * line.price) / 100;
}

export function invoiceAmounts(invoice: FixtureInvoice) {
  const merchandise =
    invoice.pages.flat().reduce((sum, line) => sum + cents(lineTotal(line)), 0) / 100;
  const tax = invoice.tax ?? 0;
  const freight = invoice.freight ?? 0;
  return {
    merchandise,
    tax,
    freight,
    total: (cents(merchandise) + cents(tax) + cents(freight)) / 100,
  };
}

const TABLE_HEADER = [
  "LINE",
  "NO.",
  "ITEM",
  "CODE",
  "UNIT",
  "SIZE DESCRIPTION QTY",
  "ORDERED",
  "QTY",
  "SHIPPED CODES UNIT",
  "PRICE",
  "EXT.",
  "PRICE",
  "BOX",
  "NO.",
  "SHIP",
  "FROM",
];
const REMIT =
  "Please remit payments to: Henry Schein, Inc. Box 000000 Pittsburgh, PA 15250-0000 US";
const TERMS =
  "Please refer to our standard Terms of Sale and disclosures at https://www.henryschein.com/us-en/medical/LegalTerms.aspx, including customer obligations regarding discounts/rebates.";

/** Page texts (one array of printed lines per page) for one invoice. */
export function henryScheinInvoicePages(invoice: FixtureInvoice): string[][] {
  const account = invoice.account ?? "1000002";
  const { merchandise, tax, freight, total } = invoice.amounts ?? invoiceAmounts(invoice);
  const count = invoice.pages.length;
  let lineNumber = 0;
  return invoice.pages.map((lines, index) => {
    const page: string[] = [];
    if (index === 0) {
      page.push(
        "INVOICE",
        "Ship/Sold-To: 1000001",
        "Example Sports Club",
        "100 Training Way",
        "Medical Supplies",
        "Exampleville, OH 45000-0000",
        `Bill-To: ${account}`,
        "Example Sports Club",
        "1 Main St Fl 3",
        "Exampleville, OH 45000-00000100000000000000000000000000000",
        "------------------------------Please detach here and mail above with your payment ------------------------------",
        "Example Sports Club",
        "1 Main St Fl 3",
        "Exampleville, OH 45000-0000",
        "Invoice#",
        `${invoice.number} Invoice Date`,
        `${invoice.date} Due Date`,
        "02/01/26 Invoice Total",
        `$${money(total)}`,
        "Purchase Order#",
        `${invoice.po} Payment Terms`,
        "Invoice Date + 30 days",
        "Customer DEA# Customer State Reg#",
        "HSI Federal ID#",
        "00-0000000 HSI D&B#",
        "00-000-0000",
      );
    } else {
      page.push(
        "INVOICE Ship/Sold-To: 1000001",
        "Example Sports Club",
        "100 Training Way",
        "Medical Supplies",
        "Exampleville, OH 45000-0000",
        `Bill-To: ${account}`,
        "Example Sports Club",
        "1 Main St Fl 3",
        "Exampleville, OH 45000-0000",
      );
    }
    page.push(...TABLE_HEADER);
    if (index === 0) page.push(...(invoice.notes ?? []));
    page.push("** SPECIAL CONTRACT PRICE **");
    for (const line of lines) {
      lineNumber++;
      const ordered = line.ordered ?? line.shipped;
      const codes = line.codes ? ` ${line.codes}` : "";
      page.push(
        line.shipped === 0
          ? `${lineNumber} ${line.sku} ${line.unit} ${line.description} ${ordered} 0${codes}`
          : `${lineNumber} ${line.sku} ${line.unit} ${line.description} ${ordered} ${line.shipped}${codes} ${grouped(line.price)} ${grouped(lineTotal(line))} 1 IN`,
      );
    }
    const last = index === count - 1;
    // An invoice whose every line is backordered prints no totals block (only the $0.00 header total).
    if (last && merchandise > 0) {
      const labels = [
        "MERCHANDISE TOTAL",
        ...(tax ? ["SALES TAX"] : []),
        ...(freight ? ["FREIGHT CHARGES"] : []),
        "INVOICE TOTAL",
      ];
      const values = [merchandise, ...(tax ? [tax] : []), ...(freight ? [freight] : []), total];
      page.push(
        ...labels,
        ...values.map((value) => `$${grouped(value)}`),
        TERMS,
        "Such terms are incorporated herein by reference.",
        "Thank you for your order!",
      );
    }
    if (!invoice.footerless?.includes(index)) {
      page.push(
        "Ship To#",
        `1000001 Bill To#`,
        `${account} Invoice#`,
        `${invoice.number} Invoice Date`,
        `${invoice.date} Invoice Total`,
        `$${money(total)}`,
        "Order#",
        `${invoice.order} Order Date`,
        `${invoice.date} # of Boxes`,
        `1 PO#`,
        invoice.po,
        "Distribution Names/Address",
      );
    }
    const marker = invoice.pageMarkers
      ? invoice.pageMarkers[index]
      : `Page ${index + 1} of ${count}`;
    page.push(`${marker ?? ""}${index === 0 ? REMIT : ""}`.trim() || "Distribution");
    return page;
  });
}

export const pageText = (page: string[]) => page.join("\n");

export async function buildFixturePdf(pages: string[][]): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  const font = await doc.embedFont(StandardFonts.Helvetica);
  for (const lines of pages) {
    const page = doc.addPage([612, 792]);
    if (!lines.length) continue;
    const step = Math.min(12, 760 / lines.length);
    lines.forEach((line, index) =>
      page.drawText(line.replace(/[^\x20-\x7e]/g, "-"), {
        x: 20,
        y: 772 - index * step,
        size: Math.min(8, step - 1),
        font,
      }),
    );
  }
  return doc.save();
}

const item = (
  sku: string,
  description: string,
  shipped: number,
  price: number,
  unit = "EA",
  codes = "T",
): FixtureLine => ({ sku, unit, description, shipped, price, codes });

/** A small catalog of invented supplies (SKU shape matches the vendor's). */
export const SUPPLIES: FixtureLine[] = Array.from({ length: 60 }, (_, index) =>
  item(
    `9${String(10 + (index % 90)).padStart(2, "0")}-${String(1000 + index * 37).slice(-4)}`,
    [
      `Training Tape ${index + 1}" White`,
      `Cold Pack Instant ${index + 2}x6`,
      `Gauze Sponge ${index + 3}x4 Sterile`,
      `Elastic Wrap ${index + 2}" Tan`,
      `Antiseptic Wipe Pack ${index + 10}`,
    ][index % 5],
    1 + (index % 4),
    Number((2.15 + index * 1.37).toFixed(2)),
    ["EA", "6/BX", "24/CA", "1/RL", "100/BX"][index % 5],
    ["T", "*", "T $", "", "C"][index % 5],
  ),
);

export const lines = (from: number, count: number) => SUPPLIES.slice(from, from + count);

/** The structural cases the canonical packet contains, in one invented packet. */
export function structuralPacket(): FixtureInvoice[] {
  return [
    {
      number: "60000001",
      date: "01/02/26",
      po: "TEAM KIT",
      order: "70000001",
      pages: [lines(0, 1)],
      tax: 1.2,
      notes: [
        "YOUR ORDER 70000001 HAS BEEN SPLIT INTO MULTIPLE SHIPMENTS.",
        "YOU WILL BE BILLED FOR THESE ITEMS WHEN THEY ARE SHIPPED.",
      ],
    },
    {
      number: "60000002",
      date: "01/07/26",
      po: "TEST-PO-1",
      order: "70000002",
      pages: [lines(1, 1)],
      tax: 0.5,
      notes: ["This is a backordered shipment for order:70000009 original invoice:60000009"],
    },
    {
      number: "60000003",
      date: "01/15/26",
      po: "TEST PRESEASON ORDER",
      order: "70000003",
      pages: [lines(2, 8), lines(10, 7)],
      tax: 4.11,
    },
    {
      number: "60000004",
      date: "01/15/26",
      po: "TEST PRESEASON ORDER",
      order: "70000003",
      pages: [lines(17, 7), lines(24, 13), lines(37, 12), [...lines(49, 1)]],
      tax: 3.67,
    },
    {
      number: "60000005",
      date: "01/26/26",
      po: "TEST PRESEASON ORDER",
      order: "70000003",
      pages: [lines(50, 1)],
      notes: ["YOUR ORDER 70000003 HAS BEEN SPLIT INTO MULTIPLE SHIPMENTS."],
    },
    {
      number: "60000006",
      date: "06/02/26",
      po: "TEST-PO-2",
      order: "70000006",
      pages: [[{ ...lines(51, 1)[0], ordered: 1, shipped: 0 }]],
      notes: ["YOUR ORDER 70000006 HAS BEEN SPLIT INTO MULTIPLE SHIPMENTS."],
    },
    {
      number: "60000007",
      date: "06/04/26",
      po: "TEST-PO-2",
      order: "70000006",
      pages: [
        [
          { ...lines(52, 1)[0], ordered: 3 },
          ...lines(53, 1),
          { ...lines(54, 1)[0], ordered: 2, shipped: 0 },
        ],
      ],
      tax: 2.1,
      freight: 9.95,
    },
  ];
}

export function packetPageTexts(invoices: FixtureInvoice[]): string[] {
  return invoices.flatMap(henryScheinInvoicePages).map(pageText);
}
