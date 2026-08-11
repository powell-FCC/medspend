import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import { DeterministicInvoiceExtractionProvider } from '../src/extraction/deterministic-invoice-provider.ts';
import { validateExtraction } from '../src/extraction/validation.ts';

const realisticInvoice = `Henry Schein, Inc.
Invoice Number: 12345678
Invoice Date: 08/10/2026
Purchase Order: ABC-123

SKU  Description  Qty Unit Unit Price Line Total
123456  White Athletic Tape  4 case 87.00 348.00
654321  PowerFlex 4 inch  12 each 4.86 58.32

Subtotal: $406.32
Tax: $28.44
Shipping: $10.00
Total: $444.76`;

test('extracts canonical headers and multiple line items from realistic embedded text', async () => {
  const extraction = validateExtraction(await new DeterministicInvoiceExtractionProvider().extractInvoice(realisticInvoice));
  assert.equal(extraction.header.vendor.value, 'Henry Schein, Inc.');
  assert.equal(extraction.header.invoiceNumber.value, '12345678');
  assert.equal(extraction.header.invoiceDate.value, '2026-08-10');
  assert.equal(extraction.header.purchaseOrder.value, 'ABC-123');
  assert.deepEqual(
    [extraction.header.subtotal.value, extraction.header.tax.value, extraction.header.shipping.value, extraction.header.total.value],
    [406.32, 28.44, 10, 444.76],
  );
  assert.equal(extraction.items.length, 2);
  assert.deepEqual(extraction.items.map(({ sku, quantity, unitPrice, lineTotal }) =>
    [sku.value, quantity.value, unitPrice.value, lineTotal.value]), [
    ['123456', 4, 87, 348], ['654321', 12, 4.86, 58.32],
  ]);
  assert.equal(extraction.reconciliation?.needsReview, false);
  assert.equal(extraction.header.vendor.source, 'Parser');
});

test('preserves missing optional values as low-confidence blanks', async () => {
  const extraction = validateExtraction(await new DeterministicInvoiceExtractionProvider().extractInvoice(
    `Acme Medical\nInvoice #: INV-9\nSKU Description Qty Unit Price Amount\nA100  Gauze Pads  2 box 5.00 10.00\nTotal: 10.00`,
  ));
  assert.equal(extraction.header.purchaseOrder.value, '');
  assert.equal(extraction.header.purchaseOrder.confidence, 0);
  assert.equal(extraction.items[0].manufacturer.value, '');
  assert.equal(extraction.items[0].suggestedCategory.value, '');
});

test('rejects line candidates with bad arithmetic and flags financial reconciliation mismatches', async () => {
  const provider = new DeterministicInvoiceExtractionProvider();
  const diagnostics = await provider.extractInvoiceWithDiagnostics(
    realisticInvoice.replace('58.32', '60.00').replace('Subtotal: $406.32', 'Subtotal: $999.00'),
  );
  const extraction = validateExtraction(diagnostics.extraction);
  assert.equal(extraction.items.length, 1);
  assert.ok(diagnostics.lineItemCandidates.some((candidate) => !candidate.accepted && candidate.reason === 'ROW_ARITHMETIC_MISMATCH'));
  assert.equal(extraction.reconciliation?.lineItemsMatchSubtotal, false);
  assert.equal(extraction.reconciliation?.componentsMatchTotal, false);
  assert.equal(extraction.reconciliation?.needsReview, true);
});

test('rejects emails and partial emails as identity fields in the real-world failure class', async () => {
  const diagnostics = await new DeterministicInvoiceExtractionProvider().extractInvoiceWithDiagnostics(
    `buyer@example.test\nOrder Confirmation\nSHIP TO:\nExample Club\nMedical Supplies\nLINE NO ITEM CODE DESCRIPTION QTY UNIT PRICE EXTENSION\n1 1507575 100/Bx Needle Dry Click 6 DROP SHIP 21.66\n129.96`,
  );
  assert.equal(diagnostics.extraction.header.vendor.value, '');
  assert.equal(diagnostics.extraction.header.purchaseOrder.value, '');
  assert.ok(diagnostics.headerCandidates.some((candidate) => candidate.reason === 'EMAIL_ADDRESS' && !candidate.accepted));
});

test('malformed text fails safely', async () => {
  await assert.rejects(
    () => new DeterministicInvoiceExtractionProvider().extractInvoice('unstructured words with no recognizable fields'),
    /recognizable invoice structure/,
  );
});

test('reconstructs every displaced-extension row from right-boundary and arithmetic evidence', async () => {
  const text = await readFile(new URL('fixtures/invoices/displaced-multi-row-order.txt', import.meta.url), 'utf8');
  const diagnostics = await new DeterministicInvoiceExtractionProvider().extractInvoiceWithDiagnostics(text);
  const extraction = validateExtraction(diagnostics.extraction);
  assert.equal(diagnostics.lineItemCandidates.length, 4);
  assert.equal(diagnostics.lineItemCandidates.filter((candidate) => candidate.accepted).length, 4);
  assert.equal(diagnostics.extensionCandidates.length, 7);
  assert.deepEqual(extraction.items.map((item) => [item.sku.value, item.quantity.value, item.unitPrice.value, item.lineTotal.value]), [
    ['AX1001', 2, 12, 24], ['BX2002', 3, 11.25, 33.75], ['CX3003', 5, 6.2, 31], ['DX4004', 4, 18.75, 75],
  ]);
  assert.equal(extraction.header.shipping.value, 4.25);
  assert.equal(extraction.header.tax.value, 10);
  assert.equal(extraction.header.total.value, 178);
  assert.equal(extraction.header.invoiceNumber.value, '');
  assert.equal(extraction.header.invoiceDate.value, '');
  assert.ok(extraction.items.every((item) => !/shipping|tax|total amount/i.test(item.description.value)));
});

test('parses discounted columnar sales-invoice rows and exact monetary semantics', async () => {
  const text = await readFile(new URL('fixtures/invoices/discounted-columnar-sales-invoice.txt', import.meta.url), 'utf8');
  const diagnostics = await new DeterministicInvoiceExtractionProvider().extractInvoiceWithDiagnostics(text);
  const extraction = validateExtraction(diagnostics.extraction);
  assert.deepEqual(extraction.items.map((item) => [item.sku.value, item.quantity.value, item.unit.value, item.unitPrice.value, item.discountPercent?.value, item.lineTotal.value]), [
    ['AB12', 5, 'EA', 20, 5, 95], ['CD34', 3, 'EA', 40, 5, 114], ['EF56NC', 10, 'EA', 15, 5, 142.5], ['GH78', 8, 'EA', 25, 5, 190],
  ]);
  assert.equal(extraction.header.invoiceNumber.value, 'ZX-2026-0042');
  assert.equal(extraction.header.invoiceDate.value, '2026-08-05');
  assert.equal(extraction.header.subtotal.value, 541.5);
  assert.equal(extraction.header.tax.value, 37.91);
  assert.equal(extraction.header.total.value, 579.41);
  assert.equal(extraction.header.shipping.value, null);
  assert.equal(extraction.reconciliation?.needsReview, false);
  assert.equal(extraction.quality?.state, 'STRUCTURED_SUCCESS');
  assert.ok(diagnostics.lineItemCandidates.every((candidate) => candidate.reason === 'DISCOUNTED_COLUMNAR_ROW_ARITHMETIC_MATCH'));
});

test('never fabricates a discounted line amount when its source amount is absent', async () => {
  const text = (await readFile(new URL('fixtures/invoices/discounted-columnar-sales-invoice.txt', import.meta.url), 'utf8'))
    .replace('LOT104 08/05/26 8 EA 25.00 5.0 190.00', 'LOT104 08/05/26 8 EA 25.00 5.0');
  const diagnostics = await new DeterministicInvoiceExtractionProvider().extractInvoiceWithDiagnostics(text);
  assert.equal(diagnostics.extraction.items.length, 3);
  assert.ok(diagnostics.lineItemCandidates.some((candidate) => !candidate.accepted));
  assert.ok(diagnostics.extraction.items.every((item) => item.sku.value !== 'GH78'));
});

test('Total Tax and Total Applied cannot become invoice total', async () => {
  const provider = new DeterministicInvoiceExtractionProvider();
  const base = `Example Medical Company\nInvoice: INV-1\nInvoice Date: 08/05/2026\nSubtotal 100.00\nTotal Tax 7.00\nTotal Applied 0.00`;
  const withoutTrueTotal = validateExtraction(await provider.extractInvoice(base));
  assert.equal(withoutTrueTotal.header.tax.value, 7);
  assert.equal(withoutTrueTotal.header.total.value, null);
  const withTrueTotal = validateExtraction(await provider.extractInvoice(`${base}\nTotal USD 107.00`));
  assert.equal(withTrueTotal.header.tax.value, 7);
  assert.equal(withTrueTotal.header.total.value, 107);
});
